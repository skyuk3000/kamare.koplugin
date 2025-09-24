local Document = require("document/document")
local DrawContext = require("ffi/drawcontext")
local Geom = require("ui/geometry")
local logger = require("logger")
local Blitbuffer = require("ffi/blitbuffer")
local TileCacheItem = require("document/tilecacheitem")
local DocCache = require("document/doccache")

local mupdf = nil -- Declared as nil initially

local VirtualImageDocument = Document:extend{
    provider = "virtualimagedocument",
    provider_name = "Virtual Image Document",

    title = "Virtual Image Document",

    -- Table of image data: array of strings (raw data) or functions () -> string
    images_list = nil,
    pages_override = nil,  -- For lazy tables with known length

    cache_id = nil,        -- Stable ID for caching (e.g., session ID)

    sw_dithering = false,

    -- Number of images/pages
    _pages = 0,

    -- DC for null renders (e.g., getSize)
    dc_null = DrawContext.new(),

    render_color = true,  -- Render in color if possible
}

local function detectImageMagic(raw_data)
    if not raw_data or #raw_data < 4 then return nil end
    local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12 = raw_data:byte(1, 12)
    -- PNG: 89 50 4E 47
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then
        return "image/png"
    -- JPEG: FF D8 FF
    elseif b1 == 0xFF and b2 == 0xD8 and b3 == 0xFF then
        return "image/jpeg"
    -- GIF: 47 49 46 38
    elseif b1 == 0x47 and b2 == 0x49 and b3 == 0x46 and b4 == 0x38 then
        return "image/gif"
    -- WEBP: "RIFF" .... "WEBP"
    elseif b1 == 0x52 and b2 == 0x49 and b3 == 0x46 and b4 == 0x46
        and b9 == 0x57 and b10 == 0x45 and b11 == 0x42 and b12 == 0x50 then
        return "image/webp"
    end
    return nil  -- Invalid/unsupported
end

-- Helpers to extract image dimensions directly from headers without decoding via MuPDF
local bit = bit

local function u16be(s, o)
    local b1, b2 = s:byte(o, o+1)
    if not b1 then return nil end
    return b1*256 + b2
end

local function u32be(s, o)
    local b1, b2, b3, b4 = s:byte(o, o+3)
    if not b1 then return nil end
    return ((b1*256 + b2)*256 + b3)*256 + b4
end

local function u16le(s, o)
    local b1, b2 = s:byte(o, o+1)
    if not b1 then return nil end
    return b1 + b2*256
end

local function u32le(s, o)
    local b1, b2, b3, b4 = s:byte(o, o+3)
    if not b1 then return nil end
    return b1 + b2*256 + b3*65536 + b4*16777216
end

local function u24le(s, o)
    local b1, b2, b3 = s:byte(o, o+2)
    if not b1 then return nil end
    return b1 + b2*256 + b3*65536
end

local function getImageSizeFromHeader(raw)
    if type(raw) ~= "string" or #raw < 12 then return nil end

    local b1, b2, b3, b4, b5, b6 = raw:byte(1, 6)

    -- PNG: 89 50 4E 47 0D 0A 1A 0A, IHDR must be first chunk
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then
        if #raw < 24 then return nil end
        local w = u32be(raw, 17)
        local h = u32be(raw, 21)
        if w and h and w > 0 and h > 0 then return w, h end
        return nil
    end

    -- JPEG: FF D8 FF ... scan to SOF markers
    if b1 == 0xFF and b2 == 0xD8 and b3 == 0xFF then
        local i = 3
        local n = #raw
        while i < n do
            while i < n and raw:byte(i) ~= 0xFF do i = i + 1 end
            while i < n and raw:byte(i) == 0xFF do i = i + 1 end
            if i >= n then break end
            local marker = raw:byte(i); i = i + 1

            if (marker >= 0xD0 and marker <= 0xD9) or marker == 0x01 then
                -- standalone markers
            else
                if i + 1 > n then break end
                local seglen = u16be(raw, i); i = i + 2
                if not seglen or seglen < 2 or i + seglen - 2 > n then break end

                if (marker >= 0xC0 and marker <= 0xCF) and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                    if seglen < 7 then break end
                    local _precision = raw:byte(i)
                    local h = u16be(raw, i+1)
                    local w = u16be(raw, i+3)
                    if w and h and w > 0 and h > 0 then return w, h end
                    break
                end
                i = i + seglen - 2
            end
        end
        return nil
    end

    -- GIF: "GIF87a" or "GIF89a"
    if raw:sub(1, 6) == "GIF87a" or raw:sub(1, 6) == "GIF89a" then
        if #raw < 10 then return nil end
        local w = u16le(raw, 7)
        local h = u16le(raw, 9)
        if w and h and w > 0 and h > 0 then return w, h end
        return nil
    end

    -- WebP: RIFF....WEBP with chunks VP8X/VP8 /VP8L
    if raw:sub(1, 4) == "RIFF" and raw:sub(9, 12) == "WEBP" then
        local n = #raw
        local i = 13 -- first chunk header offset
        while i + 7 <= n do
            local fourcc = raw:sub(i, i+3)
            local size = u32le(raw, i+4) or 0
            local data_start = i + 8
            local data_end = data_start + size - 1
            if data_end > n then break end

            if fourcc == "VP8X" and size >= 10 then
                local w = u24le(raw, data_start + 4)
                local h = u24le(raw, data_start + 7)
                if w and h then return (w + 1), (h + 1) end
            elseif fourcc == "VP8 " and size >= 10 then
                local s1, s2, s3 = raw:byte(data_start+3, data_start+5)
                if s1 == 0x9D and s2 == 0x01 and s3 == 0x2A then
                    local w = u16le(raw, data_start+6)
                    local h = u16le(raw, data_start+8)
                    if w and h then return w, h end
                end
            elseif fourcc == "VP8L" and size >= 5 then
                if raw:byte(data_start) == 0x2F then
                    local b0, b1, b2, b3 = raw:byte(data_start+1, data_start+4)
                    if b0 then
                        local bits = b0 + b1*256 + b2*65536 + b3*16777216
                        local w = bit.band(bits, 0x3FFF) + 1
                        local h = bit.band(bit.rshift(bits, 14), 0x3FFF) + 1
                        if w > 0 and h > 0 then return w, h end
                    end
                end
            end

            i = data_end + (size % 2 == 1 and 2 or 1) -- pad to even
        end
        return nil
    end

    return nil
end

function VirtualImageDocument:init()
    Document._init(self)  -- Call base init

    if not mupdf then mupdf = require("ffi/mupdf") end -- Loaded here

    -- Default render mode required by base Document hashing
    self.render_mode = 0

    self.images_list = self.images_list or {}
    self._pages = self.pages_override or #self.images_list
    -- Lazy cache for native dimensions
    self._dims_cache = {}

    logger.dbg("VirtualImageDocument:init - images_list type:", type(self.images_list))
    logger.dbg("VirtualImageDocument:init - images_list length:", self._pages)
    -- (debug peek suppressed to avoid triggering lazy fetches)

    if self._pages == 0 then
        logger.warn("VirtualImageDocument: No images provided")
        self.is_open = false
        return
    end

    -- Provide stable identifiers for hashing/caching (must remain stable across sessions)
    self.file = "virtualimage://" .. (self.cache_id or self.title or "session")
    self.mod_time = self.cache_mod_time or 0

    self.is_open = true
    self.info.has_pages = true
    self.info.number_of_pages = self._pages
    self.info.configurable = false

    self:updateColorRendering()

    logger.dbg("VirtualImageDocument: Initialized with", self._pages, "images (lazy dims)")
end

function VirtualImageDocument:close()
    -- Not registered in DocumentRegistry; avoid calling Document.close().
    -- Just mark as closed and let GC handle any transient resources.
    self.is_open = false
    self._dims_cache = nil
    return true
end

function VirtualImageDocument:getDocumentProps()
    -- Minimal metadata for virtual doc
    return {
        title = "Virtual Image Collection",
        pages = self._pages,
    }
end

function VirtualImageDocument:getPageCount()
    return self._pages
end

function VirtualImageDocument:getNativePageDimensions(pageno)
    if pageno < 1 or pageno > self._pages then
        logger.warn("Invalid pageno:", pageno, "valid range: 1 -", self._pages)
        return Geom:new{ w = 0, h = 0 }
    end

    -- Return cached dims if available
    local cached = self._dims_cache and self._dims_cache[pageno]
    if cached then
        return cached
    end

    -- No fetching here: return a sane fallback until renderPage computes real dims.
    return Geom:new{ w = 800, h = 1200 }
end

-- Preload per-page native dimensions from a list of FileDimensionDto.
function VirtualImageDocument:preloadDimensions(list)
    if type(list) ~= "table" then return end
    self._dims_cache = self._dims_cache or {}
    local count = 0
    for _, d in ipairs(list) do
        local pn = d.pageNumber or d.page or d.page_num
        local w, h = d.width, d.height
        if type(pn) == "number" and w and h and w > 0 and h > 0 then
            self._dims_cache[pn] = Geom:new{ w = w, h = h }
            count = count + 1
        end
    end
    logger.dbg("VirtualImageDocument: preloaded dims for", count, "pages")
end

function VirtualImageDocument:getUsedBBox(pageno)
    -- Full image rect as bbox (no content detection needed)
    local native_dims = self:getNativePageDimensions(pageno)
    return {
        x0 = 0, y0 = 0,
        x1 = native_dims.w,
        y1 = native_dims.h,
    }
end

function VirtualImageDocument:getPageBBox(pageno)
    local native_dims = self:getNativePageDimensions(pageno)
    return {
        x0 = 0, y0 = 0,
        x1 = native_dims.w,
        y1 = native_dims.h,
    }
end

function VirtualImageDocument:_calculateVirtualLayout()
    self.virtual_layout = {}
    local current_y = 0
    local gap_between_images = 20  -- pixels between images

    for i = 1, self._pages do
        local native_dims = self:getNativePageDimensions(i)
        if native_dims.w == 0 or native_dims.h == 0 then
            logger.warn("Page", i, "has zero dimensions, using fallback")
            native_dims = Geom:new{ w = 800, h = 1200 }  -- Fallback dimensions
        end

        self.virtual_layout[i] = {
            y_offset = current_y,
            width = native_dims.w,
            height = native_dims.h,
            page_num = i
        }
        current_y = current_y + native_dims.h + gap_between_images
    end

    self.total_virtual_height = math.max(0, current_y - gap_between_images)
    logger.dbg("Virtual document height:", self.total_virtual_height)
end

function VirtualImageDocument:getVirtualHeight(zoom)
    if not self.total_virtual_height then
        logger.warn("total_virtual_height is nil, recalculating layout")
        self:_calculateVirtualLayout()
    end
    return (self.total_virtual_height or 0) * (zoom or 1.0)
end

function VirtualImageDocument:getVisiblePagesAtOffset(offset_y, viewport_height, zoom)
    local visible_pages = {}
    local scaled_zoom = zoom or 1.0

    for i, layout in ipairs(self.virtual_layout) do
        local page_top = layout.y_offset * scaled_zoom
        local page_bottom = page_top + (layout.height * scaled_zoom)

        -- Check if page overlaps with viewport
        if page_bottom >= offset_y and page_top <= offset_y + viewport_height then
            table.insert(visible_pages, {
                page_num = i,
                page_top = page_top,
                page_bottom = page_bottom,
                visible_top = math.max(page_top, offset_y),
                visible_bottom = math.min(page_bottom, offset_y + viewport_height),
                layout = layout
            })
        end
    end

    return visible_pages
end

-- Transform native rect by zoom/rotation (inherit from Document)
function VirtualImageDocument:transformRect(native_rect, zoom, rotation)
    return Document.transformRect(self, native_rect, zoom, rotation)
end

function VirtualImageDocument:getPageDimensions(pageno, zoom, rotation)
    local native_rect = self:getNativePageDimensions(pageno)
    return self:transformRect(native_rect, zoom, rotation)
end

function VirtualImageDocument:getToc()
    -- No TOC for images
    return {}
end

function VirtualImageDocument:getPageLinks(pageno)
    -- No links, but for consistency, open mini-doc
    local raw_data = self.images_list[pageno]
    if type(raw_data) == "function" then
        local ok, result = pcall(raw_data)
        if ok then raw_data = result end
    end
    if type(raw_data) ~= "string" or #raw_data == 0 then
        return {}
    end

    local magic = detectImageMagic(raw_data)
    if not magic then return {} end

    local ok, doc_or_err = pcall(mupdf.openDocumentFromText, raw_data, magic, nil)
    if not ok or not doc_or_err or doc_or_err.doc == nil then
        return {}
    end

    local img_doc = doc_or_err
    img_doc:setColorRendering(self.render_color)
    local page = img_doc:openPage(1)
    local links = page:getPageLinks()
    page:close()
    img_doc:close()
    return links
end

function VirtualImageDocument:renderPage(pageno, rect, zoom, rotation, gamma)
    -- Validate page
    if pageno < 1 or pageno > self._pages then
        logger.warn("Invalid pageno:", pageno)
        return nil
    end

    -- Hash for cache (full or partial)
    local hash
    if rect then
        hash = self:getPagePartHash(pageno, zoom, rotation, gamma, rect)
    else
        hash = self:getFullPageHash(pageno, zoom, rotation, gamma)
    end

    -- Check cache first
    local tile = DocCache:check(hash, TileCacheItem)
    if tile then
        if self.tile_cache_validity_ts and tile.created_ts < self.tile_cache_validity_ts then
            logger.dbg("Stale tile, discarding")
        else
            return tile
        end
    end

    -- Resolve raw data from supplier (single touch per render)
    local raw_data = self.images_list[pageno]
    if type(raw_data) == "function" then
        local ok, result = pcall(raw_data)
        if ok then
            raw_data = result
        else
            logger.warn("Supplier failed for page", pageno, ":", result)
            raw_data = nil
        end
    end
    logger.dbg("Rendering page", pageno, "- raw_data type:", type(raw_data), "length:", type(raw_data)=="string" and #raw_data or "N/A")
    if type(raw_data) ~= "string" or #raw_data == 0 then
        logger.warn("Invalid image data for page", pageno, "- creating placeholder")
        local placeholder_w, placeholder_h = 800, 1200
        local tile = TileCacheItem:new{
            persistent = not rect,
            doc_path = self.file,
            created_ts = os.time(),
            excerpt = Geom:new{ w = placeholder_w, h = placeholder_h },
            pageno = pageno,
            bb = Blitbuffer.new(placeholder_w, placeholder_h, self.render_color and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8),
        }
        tile.bb:fill(Blitbuffer.COLOR_LIGHT_GRAY)
        tile.size = tonumber(tile.bb.stride) * tile.bb.h + 512
        return tile
    end

    -- Determine native dimensions from data, and cache them
    local w, h
    local w_hdr, h_hdr = getImageSizeFromHeader(raw_data)
    if w_hdr and h_hdr then
        w, h = w_hdr, h_hdr
    else
        local magic_dims = detectImageMagic(raw_data)
        if magic_dims then
            local ok_m, doc_or_err_m = pcall(mupdf.openDocumentFromText, raw_data, magic_dims, nil)
            if ok_m and doc_or_err_m and doc_or_err_m.doc then
                local img_doc_m = doc_or_err_m
                local page_m = img_doc_m:openPage(1)
                w, h = page_m:getSize(self.dc_null)
                page_m:close()
                img_doc_m:close()
            end
        end
    end
    if not (w and h and w > 0 and h > 0) then
        w, h = 800, 1200
    end
    local native_dims = Geom:new{ w = w, h = h }
    if self._dims_cache then
        self._dims_cache[pageno] = native_dims
    end

    -- Compute render size & offsets (mirror core Document semantics) without fetching
    local page_size = self:transformRect(native_dims, zoom, rotation)
    if page_size.w == 0 or page_size.h == 0 then
        logger.warn("Zero page size for", pageno, "- cannot render")
        return nil
    end

    local size = page_size
    local offset_x, offset_y = 0, 0
    if rect then
        if rect.scaled_rect then
            size = rect.scaled_rect
        else
            local r = Geom:new(rect)
            r:transformByScale(zoom)
            size = r
        end
        offset_x = rect.x or 0
        offset_y = rect.y or 0
    end

    -- Create BB and TileCacheItem
    local tile = TileCacheItem:new{
        persistent = not rect,  -- Don't persist excerpts
        doc_path = self.file,
        created_ts = os.time(),
        excerpt = size,
        pageno = pageno,
        bb = Blitbuffer.new(size.w, size.h, self.render_color and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8),
    }
    tile.size = tonumber(tile.bb.stride) * tile.bb.h + 512

    -- Try MuPDF mini-doc rendering
    local magic = detectImageMagic(raw_data)
    local rendered_bb = nil
    if magic then
        local ok, doc_or_err = pcall(mupdf.openDocumentFromText, raw_data, magic, nil)
        if ok and doc_or_err and doc_or_err.doc then
            local img_doc = doc_or_err
            img_doc:setColorRendering(self.render_color)
            local page = img_doc:openPage(1)

            -- Setup DC
            local dc = DrawContext.new()
            dc:setRotate(rotation)
            if rotation == 90 then
                dc:setOffset(page_size.w, 0)
            elseif rotation == 180 then
                dc:setOffset(page_size.w, page_size.h)
            elseif rotation == 270 then
                dc:setOffset(0, page_size.h)
            end
            dc:setZoom(zoom)
            if gamma ~= self.GAMMA_NO_GAMMA then
                dc:setGamma(gamma)
            end

            -- Draw directly into the destination tile
            page:draw(dc, tile.bb, offset_x, offset_y, self.render_mode or 0)
            page:close()
            img_doc:close()
            rendered_bb = tile.bb
        else
            logger.warn("Failed to open mini-doc for rendering page", pageno, ":", doc_or_err)
        end
    end

    if not rendered_bb then
        logger.warn("Failed to render page", pageno, "- using placeholder")
        tile.bb:fill(Blitbuffer.COLOR_LIGHT_GRAY)
    end

    -- Cache only if we actually rendered real content (not a placeholder)
    if rendered_bb then
        DocCache:insert(hash, tile)
    end

    logger.dbg("Rendered page", pageno, "to tile (excerpt:", rect and "yes" or "no", ")")
    return tile
end

function VirtualImageDocument:drawPage(target, x, y, rect, pageno, zoom, rotation, gamma)
    local tile = self:renderPage(pageno, rect, zoom, rotation, gamma)
    if tile and tile.bb then
        -- The tile.bb already contains the rendered content for the specified rect and zoom.
        -- We blit it directly to the target at the given screen coordinates (x, y).
        -- The source rectangle for blitFrom should be the full extent of tile.bb.
        target:blitFrom(tile.bb,
            x, y,
            0, 0, -- Source x, y (start from top-left of tile.bb)
            tile.bb:getWidth(), tile.bb:getHeight())
        return true
    end
    return false
end

-- Register with DocumentRegistry (add to end of file or in init)
function VirtualImageDocument:register(registry)
    -- Virtual docs aren't file-based; no extension/mimetype
    -- Call manually in viewer: VirtualImageDocument:new{ images_list = ... }
end

function VirtualImageDocument:prefetchPage(pageno, zoom, rotation, gamma)
    -- Full-page render; persistent flag is set by renderPage when rect == nil.
    return self:renderPage(pageno, nil, zoom, rotation, gamma)
end

return VirtualImageDocument

local Document = require("document/document")
local DrawContext = require("ffi/drawcontext")
local Geom = require("ui/geometry")
local logger = require("logger")
local Blitbuffer = require("ffi/blitbuffer")
local TileCacheItem = require("document/tilecacheitem")
local DocCache = require("document/doccache")
local mupdf = require("ffi/mupdf")

-- Default dimensions for pages when dimensions cannot be determined
local DEFAULT_PAGE_WIDTH = 800
local DEFAULT_PAGE_HEIGHT = 1200

local VirtualImageDocument = Document:extend{
    provider = "virtualimagedocument",
    provider_name = "Virtual Image Document",

    title = "Virtual Image Document",

    images_list = nil,
    images_dimensions = nil,

    pages_override = nil,

    cache_id = nil,

    sw_dithering = false,

    _pages = 0,

    dc_default = DrawContext.new(),

    render_color = true,

    gamma = 1.0,

    page_gap_height = 20,
    _virtual_layout_cache = nil,
    _virtual_layout_dirty = true,

    tile_px = 1024, -- default tile size in page coords (px)
    _batch_doc = nil,
    _batch_doc_pageno = nil,
}

local function detectImageMagic(raw_data)
    if not raw_data or #raw_data < 4 then return nil end
    local b1, b2, b3, b4 = raw_data:byte(1, 4)
    local b9, b10, b11, b12 = raw_data:byte(9, 12)
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then
        return "image/png"
    elseif b1 == 0xFF and b2 == 0xD8 and b3 == 0xFF then
        return "image/jpeg"
    elseif b1 == 0x47 and b2 == 0x49 and b3 == 0x46 and b4 == 0x38 then
        return "image/gif"
    elseif b1 == 0x52 and b2 == 0x49 and b3 == 0x46 and b4 == 0x46
        and b9 == 0x57 and b10 == 0x45 and b11 == 0x42 and b12 == 0x50 then
        return "image/webp"
    end
    return nil
end

local function isPositiveDimension(w, h)
    return w and h and w > 0 and h > 0
end

-- Return intersection rect (Geom) or nil
local function intersectRects(a, b)
    local ax1, ay1 = a.x or 0, a.y or 0
    local ax2, ay2 = ax1 + (a.w or 0), ay1 + (a.h or 0)
    local bx1, by1 = b.x or 0, b.y or 0
    local bx2, by2 = bx1 + (b.w or 0), by1 + (b.h or 0)

    local x1 = math.max(ax1, bx1)
    local y1 = math.max(ay1, by1)
    local x2 = math.min(ax2, bx2)
    local y2 = math.min(ay2, by2)
    if x2 <= x1 or y2 <= y1 then return nil end

    return Geom:new{ x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

function VirtualImageDocument:_hasCompleteDimensions()
    if not self._dims_cache then
        return false
    end
    if (self._pages or 0) == 0 then
        return false
    end
    for i = 1, self._pages do
        local dims = self._dims_cache[i]
        if not (dims and isPositiveDimension(dims.w, dims.h)) then
            return false
        end
    end
    return true
end

function VirtualImageDocument:init()
    Document._init(self)

    self.render_mode = 0

    self.images_list = self.images_list or {}
    self._pages = self.pages_override or #self.images_list
    self._dims_cache = {}
    if self.images_dimensions then
        self:preloadDimensions(self.images_dimensions)
    end

    self.page_gap_height = math.max(0, self.page_gap_height or 20)
    self._virtual_layout_cache = {}
    self._virtual_layout_dirty = true

    if self._pages == 0 then
        logger.warn("VirtualImageDocument: No images provided")
        self.is_open = false
        return
    end

    self.file = "virtualimage://" .. (self.cache_id or self.title or "session")
    self.mod_time = self.cache_mod_time or 0

    self.is_open = true
    self.info.has_pages = true
    self.info.number_of_pages = self._pages
    self.info.configurable = false

    -- Invalidate old cached tiles (forces re-render with new zoom logic)
    self.tile_cache_validity_ts = os.time()

    self:updateColorRendering()
    logger.info("VID:init complete", "pages", self._pages, "gap", self.page_gap_height, "cache_ts", self.tile_cache_validity_ts)
end

function VirtualImageDocument:clearCache()
    -- Clear all cached tiles for this document from DocCache
    if not self.file then return end

    local doc_path = self.file
    local keys_to_delete = {}

    -- Collect all keys for this document
    for key, item in DocCache.cache:pairs() do
        if item and item.doc_path == doc_path then
            table.insert(keys_to_delete, key)
        end
    end

    -- Delete them
    local count = #keys_to_delete
    if count > 0 then
        logger.info("VID:clearCache removing", count, "cached items for", doc_path)
        for _, key in ipairs(keys_to_delete) do
            DocCache.cache:delete(key)
        end
        -- Force garbage collection to free blitbuffers
        collectgarbage()
        collectgarbage()
    end
end

function VirtualImageDocument:close()
    logger.info("VID:close")
    -- Clear all cached tiles before closing
    self:clearCache()

    self.is_open = false
    self._dims_cache = nil
    self._virtual_layout_cache = nil
    self.virtual_layout = nil
    self.total_virtual_height = nil
    if self._batch_doc then self._batch_doc:close() end
    self._batch_doc = nil
    self._batch_doc_pageno = nil
    return true
end

function VirtualImageDocument:_getDimsWithDefault(pageno)
    local dims = self._dims_cache and self._dims_cache[pageno]
    if dims and isPositiveDimension(dims.w, dims.h) then
        return dims
    end
    return Geom:new{ w = DEFAULT_PAGE_WIDTH, h = DEFAULT_PAGE_HEIGHT }
end

function VirtualImageDocument:_storeDims(pageno, w, h)
    self._dims_cache = self._dims_cache or {}
    if not isPositiveDimension(w, h) then
        w, h = DEFAULT_PAGE_WIDTH, DEFAULT_PAGE_HEIGHT
    end
    local prev = self._dims_cache[pageno]
    local function diff(a, b)
        return math.abs((a or 0) - (b or 0))
    end
    if prev then
        local delta_w = diff(prev.w, w)
        local delta_h = diff(prev.h, h)
        if delta_w < 0.5 and delta_h < 0.5 then
            return
        end
    end
    self._dims_cache[pageno] = Geom:new{ w = w, h = h }
end

function VirtualImageDocument:setPageGapHeight(height)
    height = tonumber(height) or 0
    height = math.max(0, height)
    if math.abs(height - (self.page_gap_height or 0)) > 0.5 then
        logger.info("VID:setPageGapHeight", "from", self.page_gap_height or 0, "to", height)
        self.page_gap_height = height
    end
end

function VirtualImageDocument:getPageGapHeight()
    return self.page_gap_height or 0
end

function VirtualImageDocument:_ensureVirtualLayout(rotation)
    rotation = rotation or 0
    self._virtual_layout_cache = self._virtual_layout_cache or {}
    if self._virtual_layout_dirty then
        logger.info("VID:_ensureVirtualLayout clearing cache", "rotation", rotation)
        self._virtual_layout_cache = {}
        self._virtual_layout_dirty = false
    end

    local gap = self:getPageGapHeight()
    local cache_key = string.format("%d:%d:%d", rotation, gap, self._pages)
    local entry = self._virtual_layout_cache[cache_key]
    if entry then
        self.virtual_layout = entry.pages
        self.total_virtual_height = entry.rotated_total_height
        logger.info("VID:_ensureVirtualLayout reuse", "cache_key", cache_key, "pages", self._pages, "total_h", entry.rotated_total_height, "max_w", entry.rotated_max_width)
        return entry
    end

    logger.info("VID:_ensureVirtualLayout rebuild", "cache_key", cache_key, "pages", self._pages, "gap", gap)
    entry = {
        rotation = rotation,
        gap = gap,
        pages = {},
        native_total_height = 0,
        rotated_total_height = 0,
        native_max_width = 0,
        rotated_max_width = 0,
    }

    local native_offset = 0
    local rotated_offset = 0

    for i = 1, self._pages do
        local dims = self:_getDimsWithDefault(i)
        local native_w = dims.w
        local native_h = dims.h

        local rotated_dims = self:transformRect(Geom:new{ w = native_w, h = native_h }, 1, rotation)
        local rotated_w = rotated_dims and rotated_dims.w or native_w
        local rotated_h = rotated_dims and rotated_dims.h or native_h
        if rotated_w <= 0 or rotated_h <= 0 then
            rotated_w, rotated_h = native_w, native_h
        end

        entry.pages[i] = {
            page_num = i,
            native_width = native_w,
            native_height = native_h,
            rotated_width = rotated_w,
            rotated_height = rotated_h,
            native_y_offset = native_offset,
            rotated_y_offset = rotated_offset,
        }

        entry.native_max_width = math.max(entry.native_max_width, native_w)
        entry.rotated_max_width = math.max(entry.rotated_max_width, rotated_w)

        native_offset = native_offset + native_h + gap
        rotated_offset = rotated_offset + rotated_h + gap
    end

    if self._pages > 0 then
        entry.native_total_height = math.max(0, native_offset - gap)
        entry.rotated_total_height = math.max(0, rotated_offset - gap)
    end

    self._virtual_layout_cache[cache_key] = entry
    self.virtual_layout = entry.pages
    self.total_virtual_height = entry.rotated_total_height

    logger.info("VID:_ensureVirtualLayout stats", "cache_key", cache_key, "pages", self._pages, "native_total_h", entry.native_total_height, "rotated_total_h", entry.rotated_total_height, "rotated_max_w", entry.rotated_max_width)


    return entry
end

function VirtualImageDocument:_getRawImageData(pageno)
    local entry = self.images_list and self.images_list[pageno]

    if type(entry) == "function" then
        local ok, result = pcall(entry)
        if ok then
            entry = result
        else
            logger.warn("VID:_getRawImageData supplier error", "page", pageno, "error", result)
            return nil
        end
    end

    return entry
end

function VirtualImageDocument:_openImageDoc(raw_data, magic, opts)
    opts = opts or {}
    if not magic then return nil end
    local ok, doc_or_err = pcall(mupdf.openDocumentFromText, raw_data, magic, nil)
    if ok and doc_or_err and doc_or_err.doc then
        return doc_or_err
    end
    if not opts.silent then
        logger.warn("VID:_openImageDoc failed", "page", opts.pageno, "error", doc_or_err)
    end
    return nil
end

function VirtualImageDocument:_beginTileBatch(pageno)
    if self._batch_doc and self._batch_doc_pageno == pageno then
        return true
    end
    local raw_data = self:_getRawImageData(pageno)
    local magic = raw_data and detectImageMagic(raw_data) or nil
    if not magic then return false end
    local doc = self:_openImageDoc(raw_data, magic, { pageno = pageno, silent = true })
    if not doc then return false end
    doc:setColorRendering(self.render_color)
    self._batch_doc = doc
    self._batch_doc_pageno = pageno
    return true
end

function VirtualImageDocument:_endTileBatch()
    if self._batch_doc then
        self._batch_doc:close()
        self._batch_doc = nil
        self._batch_doc_pageno = nil
    end
end


function VirtualImageDocument:getDocumentProps()
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
        logger.warn("VID:getNativePageDimensions invalid", "page", pageno, "valid", 1, self._pages)
        return Geom:new{ w = 0, h = 0 }
    end

    local cached = self._dims_cache and self._dims_cache[pageno]
    if cached then
        return cached
    end

    self:validateDims(pageno)
    cached = self._dims_cache and self._dims_cache[pageno]
    if cached then
        return cached
    end

    return Geom:new{ w = DEFAULT_PAGE_WIDTH, h = DEFAULT_PAGE_HEIGHT }
end

function VirtualImageDocument:preloadDimensions(list)
    if type(list) ~= "table" then return end
    for _, d in ipairs(list) do
        local pn = d.pageNumber or d.page or d.page_num
        local w, h = d.width, d.height
        if type(pn) == "number" and w and h and w > 0 and h > 0 then
            self:_storeDims(pn, w, h)
        end
    end
    logger.info("VID:preloadDimensions", "count", #list)
end

function VirtualImageDocument:validateDims(pageno)
    if pageno < 1 or pageno > self._pages then return end
    self._dims_cache = self._dims_cache or {}
    local cached = self._dims_cache[pageno]
    if not (cached and isPositiveDimension(cached.w, cached.h)) then
        logger.warn("VirtualImageDocument: missing or invalid dims for page", pageno)
    end
end

function VirtualImageDocument:getUsedBBox(pageno)
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
    logger.info("VID:_calculateVirtualLayout invoking ensure layout")
    local entry = self:_ensureVirtualLayout(0)
    if entry then
        self.virtual_layout = entry.pages
        self.total_virtual_height = entry.rotated_total_height
    end
end

function VirtualImageDocument:getVirtualHeight(zoom, rotation)
    zoom = zoom or 1.0
    local entry = self:_ensureVirtualLayout(rotation or 0)
    if not entry then
        logger.warn("VID:getVirtualHeight no layout", "rotation", rotation, "zoom", zoom)
        return 0
    end
    local height = math.max(0, entry.rotated_total_height) * zoom
    return height
end

function VirtualImageDocument:getVisiblePagesAtOffset(offset_y, viewport_height, zoom, rotation)
    offset_y = math.max(0, offset_y or 0)
    viewport_height = math.max(0, viewport_height or 0)
    zoom = zoom or 1.0
    if zoom <= 0 then
        zoom = 1.0
    end
    if viewport_height <= 0 then
        logger.warn("VID:getVisiblePagesAtOffset invalid viewport", "viewport_height", viewport_height)
        return {}
    end

    local entry = self:_ensureVirtualLayout(rotation or 0)
    if not entry or not entry.pages then
        logger.warn("VID:getVisiblePagesAtOffset no entry", "rotation", rotation)
        return {}
    end

    local result = {}
    local bottom = offset_y + viewport_height
    for _, page in ipairs(entry.pages) do
        local page_top = page.rotated_y_offset * zoom
        local page_bottom = page_top + page.rotated_height * zoom
        if page_bottom >= offset_y and page_top <= bottom then
            local visible_top = math.max(page_top, offset_y)
            local visible_bottom = math.min(page_bottom, bottom)
            table.insert(result, {
                page_num = page.page_num,
                page_top = page_top,
                page_bottom = page_bottom,
                visible_top = visible_top,
                visible_bottom = visible_bottom,
                layout = page,
                rotation = entry.rotation,
                zoom = zoom,
                max_rotated_width = entry.rotated_max_width,
            })
        end
    end

    if #result == 0 then
        logger.warn("VID:getVisiblePagesAtOffset empty", "offset", offset_y, "viewport", viewport_height, "zoom", zoom, "rotation", rotation, "entry_height", entry.rotated_total_height)
    end

    return result
end

function VirtualImageDocument:getScrollPositionForPage(pageno, zoom, rotation)
    zoom = zoom or 1.0
    if zoom <= 0 then zoom = 1.0 end
    local entry = self:_ensureVirtualLayout(rotation or 0)
    if not entry or not entry.pages then
        logger.warn("VID:getScrollPositionForPage no entry", "page", pageno, "rotation", rotation)
        return 0
    end
    local page = entry.pages[pageno]
    if not page then
        logger.warn("VID:getScrollPositionForPage missing page", "page", pageno)
        return 0
    end
    local position = page.rotated_y_offset * zoom
    logger.info("VID:getScrollPositionForPage", "page", pageno, "zoom", zoom, "rotation", rotation, "position", position)
    return position
end

function VirtualImageDocument:getPageAtOffset(offset_y, zoom, rotation)
    zoom = zoom or 1.0
    if zoom <= 0 then zoom = 1.0 end
    offset_y = math.max(0, offset_y or 0)

    local entry = self:_ensureVirtualLayout(rotation or 0)
    if not entry or not entry.pages then
        logger.warn("VID:getPageAtOffset no entry", "offset", offset_y, "rotation", rotation)
        return 1
    end

    for _, page in ipairs(entry.pages) do
        local page_top = page.rotated_y_offset * zoom
        local page_bottom = page_top + page.rotated_height * zoom
        if offset_y >= page_top and offset_y < page_bottom then
            logger.info("VID:getPageAtOffset", "offset", offset_y, "zoom", zoom, "rotation", rotation, "page", page.page_num)
            return page.page_num
        end
    end
    logger.info("VID:getPageAtOffset defaulting to last page", "offset", offset_y, "zoom", zoom, "rotation", rotation, "last", entry.pages[#entry.pages].page_num)
    return entry.pages[#entry.pages].page_num
end

function VirtualImageDocument:transformRect(native_rect, zoom, rotation)
    return Document.transformRect(self, native_rect, zoom, rotation)
end

function VirtualImageDocument:_computeTileRects(rect, tile_px)
    tile_px = math.max(16, tonumber(tile_px or self.tile_px or 1024))
    local rx, ry = rect.x or 0, rect.y or 0
    local rw, rh = rect.w or 0, rect.h or 0

    -- Calculate rect boundaries
    local rect_x1 = rx
    local rect_y1 = ry
    local rect_x2 = rx + rw
    local rect_y2 = ry + rh

    -- Align to FIXED tile grid (0, tile_px, 2*tile_px, ...)
    -- This ensures tiles are always at the same coordinates regardless of input rect
    local tile_x_start = math.floor(rect_x1 / tile_px) * tile_px
    local tile_y_start = math.floor(rect_y1 / tile_px) * tile_px
    local tile_x_end = math.ceil(rect_x2 / tile_px) * tile_px
    local tile_y_end = math.ceil(rect_y2 / tile_px) * tile_px

    local tiles = {}
    local y = tile_y_start
    while y < tile_y_end do
        local x = tile_x_start
        while x < tile_x_end do
            -- Create tile at fixed boundary with full tile size
            local tile = Geom:new{
                x = x,
                y = y,
                w = tile_px,
                h = tile_px
            }

            -- Only include tiles that intersect the requested rect
            if intersectRects(tile, rect) then
                tiles[#tiles + 1] = tile
            end

            x = x + tile_px
        end
        y = y + tile_px
    end

    return tiles
end

function VirtualImageDocument:_tileHash(pageno, zoom, rotation, gamma, rect)
    local qg = math.floor((gamma or 1) * 1000 + 0.5)
    local x = math.floor((rect.x or 0) + 0.5)
    local y = math.floor((rect.y or 0) + 0.5)
    local w = math.floor((rect.w or 0) + 0.5)
    local h = math.floor((rect.h or 0) + 0.5)
    local color = self.render_color and "color" or "bw"
    return table.concat({
        "nativetile",  -- Changed prefix for native-resolution tiles
        self.file or "",
        tostring(self.mod_time or 0),
        tostring(pageno or 0),
        tostring(x), tostring(y), tostring(w), tostring(h),
        tostring(rotation or 0),
        tostring(qg),
        tostring(self.render_mode or 0),
        color,
        -- Note: NO zoom in hash - tiles are cached at native resolution
    }, "|")
end

function VirtualImageDocument:getFullPageHash(pageno, zoom, rotation, gamma)
    -- Override parent to remove zoom from hash - full pages cached at native resolution
    local qg = math.floor((gamma or 1) * 1000 + 0.5)
    local color = self.render_color and "color" or "bw"
    return table.concat({
        "nativefullpage",
        self.file or "",
        tostring(self.mod_time or 0),
        tostring(pageno or 0),
        tostring(rotation or 0),
        tostring(qg),
        tostring(self.render_mode or 0),
        color,
        -- Note: NO zoom in hash - pages are cached at native resolution
    }, "|")
end

function VirtualImageDocument:getPageDimensions(pageno, zoom, rotation)
    local native_rect = self:getNativePageDimensions(pageno)
    local transformed = self:transformRect(native_rect, zoom, rotation)
    return transformed
end

function VirtualImageDocument:getToc()
    return {}
end

--- Unified rendering function for both page and scroll modes
-- Uses page:draw() API which works for both full pages and partial rects
function VirtualImageDocument:renderPage(pageno, rect, zoom, rotation)
    -- Validation
    if pageno < 1 or pageno > self._pages then
        logger.warn("VID:renderPage invalid page", "page", pageno, "total", self._pages)
        return nil
    end

    -- Generate cache hash
    local hash
    if rect then
        hash = self:_tileHash(pageno, zoom, rotation, self.gamma, rect)
    else
        hash = self:getFullPageHash(pageno, zoom, rotation, self.gamma)
    end

    -- Check cache (native resolution tiles)
    local native_tile = DocCache:check(hash, TileCacheItem)
    if native_tile then
        -- Cached tile is at native resolution - scale to requested zoom before returning
        return self:_scaleToZoom(native_tile, zoom, rotation)
    end

    -- Get native dimensions
    local native_dims = self:getNativePageDimensions(pageno)

    -- Determine native rect to render (always in native pixel coordinates)
    local native_rect = rect or Geom:new{ x = 0, y = 0, w = native_dims.w, h = native_dims.h }
    local offset_x = native_rect.x or 0
    local offset_y = native_rect.y or 0
    local native_w = native_rect.w or native_dims.w
    local native_h = native_rect.h or native_dims.h

    if native_w <= 0 or native_h <= 0 then
        logger.warn("VID:renderPage zero native size", "page", pageno, "w", native_w, "h", native_h)
        return nil
    end

    -- Create tile at NATIVE resolution for caching
    local tile = TileCacheItem:new{
        persistent = true,
        doc_path = self.file,
        created_ts = os.time(),
        excerpt = native_rect,
        pageno = pageno,
        bb = Blitbuffer.new(native_w, native_h, self.render_color and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8),
    }
    tile.size = tonumber(tile.bb.stride) * tile.bb.h + 512

    -- Open document
    local doc_for_render = self._batch_doc
    local opened_here = false
    if not doc_for_render then
        local raw_data = self:_getRawImageData(pageno)
        local magic = raw_data and detectImageMagic(raw_data) or nil
        if magic then
            doc_for_render = self:_openImageDoc(raw_data, magic, { pageno = pageno })
            if doc_for_render then
                doc_for_render:setColorRendering(self.render_color)
                opened_here = true
            end
        end
    end

    -- Render
    local rendered_bb = nil
    if doc_for_render then
        local page = doc_for_render:openPage(1)

        -- Get MuPDF's internal page dimensions (in points, calculated from image DPI)
        local doc_w, doc_h = page:getSize(self.dc_default)

        -- Calculate MuPDF zoom for NATIVE resolution rendering:
        -- We always render at native resolution (zoom=1.0 relative to native pixels)
        -- mu_zoom = 1.0 / px_to_pt
        -- px_to_pt = mupdf_points / native_pixels
        local px_to_pt = (doc_w and doc_w > 0) and (doc_w / native_dims.w) or 1
        local mu_zoom = 1.0 / px_to_pt  -- Always render at native resolution

        -- Setup DrawContext
        local dc = DrawContext.new()
        dc:setZoom(mu_zoom)
        dc:setRotate(rotation)

        -- Convert offsets from native pixels to MuPDF points
        local offset_x_pt = offset_x * px_to_pt
        local offset_y_pt = offset_y * px_to_pt

        -- Render using page:draw (works for both full pages and tiles)
        page:draw(dc, tile.bb, offset_x_pt, offset_y_pt, self.render_mode or 0)

        rendered_bb = tile.bb
        page:close()
        if opened_here then
            doc_for_render:close()
        end
    else
        logger.warn("VID:renderPage failed to render, using placeholder", "page", pageno)
        tile.bb:fill(Blitbuffer.COLOR_LIGHT_GRAY)
    end

    -- Cache the native resolution result
    if rendered_bb then
        DocCache:insert(hash, tile)
    end

    -- Scale to requested zoom before returning
    return self:_scaleToZoom(tile, zoom, rotation)
end

function VirtualImageDocument:_scaleToZoom(native_tile, zoom, rotation)
    if not (native_tile and native_tile.bb) then
        return native_tile
    end

    -- If zoom is 1.0, return native tile directly
    if math.abs(zoom - 1.0) < 0.001 then
        return native_tile
    end

    -- Calculate target size at requested zoom
    local native_w = native_tile.bb:getWidth()
    local native_h = native_tile.bb:getHeight()
    local target_w = math.floor(native_w * zoom + 0.5)
    local target_h = math.floor(native_h * zoom + 0.5)

    if target_w <= 0 or target_h <= 0 then
        return native_tile
    end

    -- Scale using MuPDF's high-quality scaler (on-demand, no caching)
    local scaled_bb = mupdf.scaleBlitBuffer(native_tile.bb, target_w, target_h)

    -- Create a new tile with the scaled blitbuffer (transient, not cached)
    local scaled_tile = TileCacheItem:new{
        persistent = false,
        doc_path = native_tile.doc_path,
        created_ts = native_tile.created_ts,
        excerpt = Geom:new{x = native_tile.excerpt and native_tile.excerpt.x or 0,
                          y = native_tile.excerpt and native_tile.excerpt.y or 0,
                          w = native_w, h = native_h},
        pageno = native_tile.pageno,
        bb = scaled_bb,
    }
    scaled_tile.size = tonumber(scaled_bb.stride) * scaled_bb.h + 512

    return scaled_tile
end

function VirtualImageDocument:drawPage(target, x, y, rect, pageno, zoom, rotation)
    local tile = self:renderPage(pageno, rect, zoom, rotation)
    if tile and tile.bb then
        target:blitFrom(tile.bb,
            x, y,
            0, 0,
            tile.bb:getWidth(), tile.bb:getHeight())
        return true
    end
    return false
end

function VirtualImageDocument:_preSplitPageTiles(pageno, zoom, rotation, tile_px, page_mode)
    local native = self:getNativePageDimensions(pageno)
    if not native or native.w <= 0 or native.h <= 0 then return end

    local full_rect = Geom:new{ x = 0, y = 0, w = native.w, h = native.h }
    local tp = math.max(16, tonumber(tile_px or self.tile_px or 1024))
    local tiles = self:_computeTileRects(full_rect, tp)
    if #tiles == 0 then return end

    local missing = {}
    for _, t in ipairs(tiles) do
        local key = self:_tileHash(pageno, zoom, rotation, self.gamma, t)
        local exists = DocCache:check(key, TileCacheItem)
        if not (exists and exists.bb) then
            table.insert(missing, t)
        end
    end
    if #missing == 0 then
        return
    end

    local started = self:_beginTileBatch(pageno)
    local ok, err = pcall(function()
        for _, t in ipairs(missing) do
            self:renderPage(pageno, t, zoom, rotation)
        end
    end)
    if started then
        self:_endTileBatch()
    end
    if not ok then
        logger.warn("VID:_preSplitPageTiles error during render", "page", pageno, "error", err)
    end
end

function VirtualImageDocument:drawPageTiled(target, x, y, rect, pageno, zoom, rotation, tile_px, prefetch_rows, page_mode)
    -- If no rect is provided, fall back to the full path.
    if not rect then
        local full = self:renderPage(pageno, nil, zoom, rotation)
        if not (full and full.bb) then return false end
        target:blitFrom(full.bb, x, y, 0, 0, full.bb:getWidth(), full.bb:getHeight())
        return true
    end

    -- Ensure the entire page is split and cached on first tiled retrieval
    self:_preSplitPageTiles(pageno, zoom, rotation, tile_px, page_mode)

    local base_rect = rect
    local tp = math.max(16, tonumber(tile_px or self.tile_px or 1024))
    local rows = tonumber(prefetch_rows) or 0

    -- Expand fetch window by rows of tiles above/below the visible rect (native coords)
    local prefetch_rect = base_rect
    if rows > 0 then
        local native = self:getNativePageDimensions(pageno) or { w = 0, h = 0 }
        local pad = rows * tp
        local y0 = math.max(0, (base_rect.y or 0) - pad)
        local y1 = math.min((native.h or math.huge), (base_rect.y or 0) + (base_rect.h or 0) + pad)
        prefetch_rect = Geom:new{
            x = base_rect.x or 0,
            y = y0,
            w = base_rect.w or (native.w or 0),
            h = math.max(0, y1 - y0),
        }
    end

    -- Open a batch only if at least one needed tile is missing
    local need_batch = false
    do
        local probe_tiles = self:_computeTileRects(prefetch_rect, tp)
        for _, t in ipairs(probe_tiles) do
            local key = self:_tileHash(pageno, zoom, rotation, self.gamma, t)
            local hit = DocCache:check(key, TileCacheItem)
            if not (hit and hit.bb) then
                need_batch = true
                break
            end
        end
    end
    local batch_started = need_batch and self:_beginTileBatch(pageno) or false

    local tiles = self:_computeTileRects(prefetch_rect, tp)
    if #tiles == 0 then return true end

    local ok, err = pcall(function()
        for _, t in ipairs(tiles) do
            -- Always render tiles in the expanded window to warm the cache
            local ttile = self:renderPage(pageno, t, zoom, rotation)

            -- Only draw the visible overlap against the original (non-expanded) rect
            local overlap = intersectRects(t, base_rect)
            if overlap and ttile and ttile.bb then
                -- Tile is already scaled to requested zoom by renderPage
                -- Calculate source position in the tile
                local src_x = math.floor((overlap.x - t.x) * zoom + 0.5)
                local src_y = math.floor((overlap.y - t.y) * zoom + 0.5)
                local dst_x = math.floor(x + (overlap.x - base_rect.x) * zoom + 0.5)
                local dst_y = math.floor(y + (overlap.y - base_rect.y) * zoom + 0.5)
                local w = math.floor(overlap.w * zoom + 0.5)
                local h = math.floor(overlap.h * zoom + 0.5)
                if w > 0 and h > 0 then
                    target:blitFrom(ttile.bb, dst_x, dst_y, src_x, src_y, w, h)
                end
            end
        end
    end)
    if batch_started then
        self:_endTileBatch()
    end
    if not ok then
        logger.warn("VID:drawPageTiled error during render", "page", pageno, "error", err)
        return false
    end
    return true
end

function VirtualImageDocument:register(registry)
end

function VirtualImageDocument:prefetchPage(pageno, zoom, rotation)
    return self:renderPage(pageno, nil, zoom, rotation)
end

return VirtualImageDocument

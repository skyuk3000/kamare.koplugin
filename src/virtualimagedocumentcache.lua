local LRUCache = require("lrucache")
local logger = require("logger")
local util = require("util")

local function calcTileCacheSize()
    local min = 32 * 1024 * 1024
    local max = 256 * 1024 * 1024

    local memfree, _ = util.calcFreeMem() or 0, 0
    local calc = memfree * 0.15

    return math.min(max, math.max(min, calc))
end

local function computeNativeCacheSize()
    local total = calcTileCacheSize()
    -- Allocate ALL memory to native resolution tiles
    -- Scaled tiles are cheap to generate (4ms) so we don't cache them
    -- Native tiles are expensive (200ms decode), so we cache aggressively
    local native_size = total

    local mb_size = native_size / 1024 / 1024
    if mb_size >= 8 then
        logger.dbg(string.format("Allocating %dMB for VirtualImageDocument native tile cache (scaled cache disabled)", mb_size))
        return native_size
    else
        logger.dbg("VirtualImageDocument native cache below minimum, using 8MB")
        return 8 * 1024 * 1024
    end
end

-- Singleton cache instance
local VIDCache = {
    _native_cache = nil,
}

function VIDCache:init()
    if self._native_cache then
        -- Already initialized
        return
    end

    self._native_cache = LRUCache:new{
        name = "VID-Native",
        max_size = computeNativeCacheSize(),
        on_evict = function(tile)
            if tile and tile.bb and tile.bb.free then
                tile.bb:free()
                tile.bb = nil
            end
        end,
    }
end

function VIDCache:getNativeTile(hash)
    if not self._native_cache then
        self:init()
    end
    return self._native_cache:get(hash)
end

function VIDCache:setNativeTile(hash, tile, size)
    if not self._native_cache then
        self:init()
    end
    self._native_cache:set(hash, tile, size)
end

function VIDCache:clear()
    if self._native_cache then
        self._native_cache:clear()
    end
end

function VIDCache:stats()
    if not self._native_cache then
        self:init()
    end

    local native_stats = self._native_cache:stats()

    return {
        native = native_stats,
        scaled = nil,  -- Scaled cache disabled
        utilization = native_stats.utilization,
        total_size = native_stats.total_size,
        max_size = native_stats.max_size,
        count = native_stats.count,
    }
end

return VIDCache

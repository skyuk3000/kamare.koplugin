local LRUCache = require("lrucache")
local util = require("util")

local function calcTileCacheSize()
    local min = 32 * 1024 * 1024
    local max = 256 * 1024 * 1024

    local memfree, _ = util.calcFreeMem() or 0, 0
    local calc = memfree * 0.25

    return math.min(max, math.max(min, calc))
end

local function computeNativeCacheSize()
    local total = calcTileCacheSize()
    local native_size = total

    local mb_size = native_size / 1024 / 1024
    if mb_size >= 8 then
        return native_size
    else
        return 8 * 1024 * 1024
    end
end

local VIDCache = {
    _native_cache = nil,
    _stats = {
        hits = 0,
        misses = 0,
        stores = 0,
        evictions = 0,
    },
}

function VIDCache:init()
    if self._native_cache then
        return
    end

    local cache_size = computeNativeCacheSize()
    self._native_cache = LRUCache:new{
        name = "VID-Native",
        max_size = cache_size,
        on_evict = function(tile)
            self._stats.evictions = self._stats.evictions + 1
            if tile and tile.bb and tile.bb.free then
                tile.bb:free()
                tile.bb = nil
            end
        end,
    }
end

function VIDCache:getNativeTile(hash, is_navigation)
    if not self._native_cache then
        self:init()
    end
    local tile = self._native_cache:get(hash)

    if is_navigation then
        if tile then
            self._stats.hits = self._stats.hits + 1
        else
            self._stats.misses = self._stats.misses + 1
        end
    end

    return tile
end

function VIDCache:setNativeTile(hash, tile, size)
    if not self._native_cache then
        self:init()
    end
    self._stats.stores = self._stats.stores + 1
    self._native_cache:set(hash, tile, size)
end

function VIDCache:clear()
    if self._native_cache then
        self._native_cache:clear()
    end
    -- Reset stats
    self._stats.hits = 0
    self._stats.misses = 0
    self._stats.stores = 0
    self._stats.evictions = 0
end

function VIDCache:stats()
    if not self._native_cache then
        self:init()
    end

    local native_stats = self._native_cache:stats()
    local hit_rate = 0
    local total_requests = self._stats.hits + self._stats.misses
    if total_requests > 0 then
        hit_rate = self._stats.hits / total_requests
    end

    -- Count unique pages in cache
    local pages = {}
    if self._native_cache and self._native_cache.items then
        for _, entry in ipairs(self._native_cache.items) do
            if entry.value and entry.value.pageno then
                pages[entry.value.pageno] = true
            end
        end
    end
    local unique_pages = 0
    for _ in pairs(pages) do
        unique_pages = unique_pages + 1
    end

    return {
        native = native_stats,
        utilization = native_stats.utilization,
        total_size = native_stats.total_size,
        max_size = native_stats.max_size,
        count = native_stats.count,
        pages = unique_pages,
        hits = self._stats.hits,
        misses = self._stats.misses,
        stores = self._stats.stores,
        evictions = self._stats.evictions,
        hit_rate = hit_rate,
    }
end

return VIDCache

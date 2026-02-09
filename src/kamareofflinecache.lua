local DataStorage = require("datastorage")
local logger = require("logger")
local md5 = require("ffi/sha2").md5

local lfs
local has_mkdir_p = true
do
    local ok, module = pcall(require, "lfs")
    if ok then
        lfs = module
    else
        logger.warn("OfflineCache: lfs unavailable, falling back to mkdir -p:", module)
        local ok_exec = pcall(function()
            return os.execute("mkdir -p /tmp") ~= nil
        end)
        if not ok_exec then
            has_mkdir_p = false
            logger.warn("OfflineCache: mkdir -p unavailable, disabling disk cache")
        end
    end
end

local OfflineCache = {}

local function ensureDir(path)
    if not lfs and not has_mkdir_p then
        return false
    end
    if not path or path == "" then
        return false
    end
    if not lfs then
        local quoted = path:gsub("'", "'\\''")
        local ok = os.execute("mkdir -p '" .. quoted .. "'")
        return ok == true or ok == 0
    end
    local normalized = path:gsub("/+$", "")
    local current = ""
    for part in normalized:gmatch("[^/]+") do
        current = current .. "/" .. part
        local attr = lfs.attributes(current)
        if not attr then
            local ok, err = lfs.mkdir(current)
            if not ok then
                logger.warn("OfflineCache: failed to create dir", current, err)
                return false
            end
        end
    end
    return true
end

local function getCacheRoot()
    local base = DataStorage:getDataDir() .. "/kamare_cache"
    ensureDir(base)
    return base
end

local function serverHash(server_url)
    if not server_url or server_url == "" then
        return "unknown"
    end
    return md5(server_url)
end

local function getChapterDir(server_url, chapter_id, extract_pdf)
    local root = getCacheRoot()
    local server_dir = root .. "/" .. serverHash(server_url)
    local chapter_dir = server_dir .. "/chapter_" .. tostring(chapter_id)
    if extract_pdf then
        chapter_dir = chapter_dir .. "_extract"
    end
    ensureDir(chapter_dir)
    return chapter_dir
end

function OfflineCache:getPagePath(server_url, chapter_id, page0, extract_pdf)
    if not chapter_id or page0 == nil then
        return nil
    end
    local chapter_dir = getChapterDir(server_url, chapter_id, extract_pdf)
    return string.format("%s/page_%04d.bin", chapter_dir, tonumber(page0) or 0)
end

function OfflineCache:readPage(server_url, chapter_id, page0, extract_pdf)
    local path = self:getPagePath(server_url, chapter_id, page0, extract_pdf)
    if not path then return nil end
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*all")
    file:close()
    return data
end

function OfflineCache:writePage(server_url, chapter_id, page0, extract_pdf, data)
    if not data then return false end
    local path = self:getPagePath(server_url, chapter_id, page0, extract_pdf)
    if not path then return false end
    local file = io.open(path, "wb")
    if not file then
        logger.warn("OfflineCache: failed to open cache file for write", path)
        return false
    end
    file:write(data)
    file:close()
    return true
end

return OfflineCache

local Cache = require("cache")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local rapidjson = require("rapidjson")
local md5 = require("ffi/sha2").md5

-- Redact sensitive query params in debug logs
local function redact_api_key_in_url(u)
    if type(u) ~= "string" then return u end
    return (u:gsub("([?&]apiKey=)[^&]+", "%1REDACTED"))
end

local ApiCache = Cache:new{
    slots = 20,
}

local KavitaClient = {}


function KavitaClient:authenticate(server_url, apiKey)
    local base_endpoint = (server_url:gsub("/+$", "")) .. "/api/Plugin/authenticate"
    local auth_url = base_endpoint .. "?apiKey=" .. url.escape(apiKey) .. "&pluginName=" .. url.escape("KaMaRe.koplugin")
    local sink = {}

    logger.dbg("KavitaClient:authenticate: auth_endpoint =", base_endpoint, "apiKey_len =", (apiKey and #apiKey or 0))

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, http.request{
            url     = auth_url,
            method  = "POST",
            headers = {
                ["Accept"] = "application/json",
            },
            sink    = ltn12.sink.table(sink),
        })
    end)
    socketutil:reset_timeout()

    if not ok then
        logger.warn("KavitaClient:authenticate: request failed with LuaSocket error:", code)
        return nil, -1, nil, code
    end
    logger.dbg("KavitaClient:authenticate: HTTP response code =", code, "status =", status)

    if code ~= 200 and code ~= 201 then
        logger.warn("KavitaClient:authenticate: non-OK status:", code, status)
        return nil, code, headers, status
    end

    local body = table.concat(sink)
    logger.dbg("KavitaClient:authenticate: response body length =", (body and #body or 0))
    local okj, decoded = pcall(rapidjson.decode, body)
    if not okj or type(decoded) ~= "table" then
        logger.warn("KavitaClient:authenticate: JSON decode failed")
        return nil, code, headers, "Invalid JSON auth response"
    end

    local keys = {}
    for k, _ in pairs(decoded) do table.insert(keys, k) end
    table.sort(keys)
    logger.dbg("KavitaClient:authenticate: decoded JSON keys =", table.concat(keys, ", "))

    local token = decoded.token
    logger.dbg("KavitaClient:authenticate: token present =", (type(token) == "string"), "token_len =", (type(token) == "string" and #token or 0))
    if type(token) ~= "string" or token == "" then
        logger.warn("KavitaClient:authenticate: token missing in JSON response")
        return nil, code, headers, "No token in JSON response"
    end

    -- Persist on the client for subsequent API calls
    self.bearer   = token
    self.base_url = (server_url:gsub("/+$", ""))
    self.api_key  = apiKey

    return token, code, headers, status
end

-- Internal: build a URL-encoded query string from a table
function KavitaClient:_buildQueryString(params)
    if type(params) ~= "table" or not next(params) then return "" end
    local parts = {}
    for k, v in pairs(params) do
        local key = url.escape(tostring(k))
        if type(v) == "table" then
            for _, vv in ipairs(v) do
                table.insert(parts, key .. "=" .. url.escape(tostring(vv)))
            end
        else
            table.insert(parts, key .. "=" .. url.escape(tostring(v)))
        end
    end
    return (#parts > 0) and ("?" .. table.concat(parts, "&")) or ""
end

function KavitaClient:_makeCacheKey(method, path, query, body)
    local base = tostring(self.base_url or "")
    local method_str = tostring(method or "GET")
    local q = self:_buildQueryString(query) or ""
    local b = (type(body) == "table") and rapidjson.encode(body) or (body ~= nil and tostring(body) or "")
    local raw = table.concat({ base, method_str, q, b }, "|")
    local hash = md5(raw)
    return string.format("kavita|json|%s|%s", tostring(path or ""), hash)
end

function KavitaClient:_cacheGet(key, ttl)
    local ok, cached = pcall(ApiCache.check, ApiCache, key)
    if ok and cached and cached.timestamp then
        local age = os.time() - cached.timestamp
        if age >= 0 and age < (ttl or 300) then
            return cached.data
        end
    end
end

function KavitaClient:_cachePut(key, data)
    local payload = { data = data, timestamp = os.time() }
    local ok, err = pcall(ApiCache.insert, ApiCache, key, payload)
    if not ok then
        logger.warn("KavitaClient:_cachePut failed:", err)
    end
end

-- Cached JSON helper: returns decoded JSON with TTL
function KavitaClient:apiJSONCached(path, opts, ttl, ns)
    opts = opts or {}
    local key = self:_makeCacheKey(opts.method or "GET", path, opts.query, opts.body)
    local hit = self:_cacheGet(key, ttl or 300)
    if hit ~= nil then
        return hit, 200, nil, "cached", nil
    end
    local data, code, headers, status, body = self:apiJSON(path, opts)
    if data ~= nil then
        self:_cachePut(key, data)
    end
    return data, code, headers, status, body
end

-- Generic API request with Authorization: Bearer
-- Returns: code, headers, status, body_string
function KavitaClient:apiRequest(path, opts)
    opts = opts or {}
    local method = opts.method or "GET"
    local query = opts.query
    local body = opts.body
    local extra_headers = opts.headers or {}

    if not self.base_url or not self.bearer then
        logger.warn("KavitaClient:apiRequest: missing base_url or bearer")
        return -1, nil, "Missing base_url or bearer", nil
    end

    local base = self.base_url:gsub("/+$", "")
    local p = tostring(path or "")
    if p == "" then
        logger.warn("KavitaClient:apiRequest: empty path")
        return -1, nil, "Empty path", nil
    end
    local full_url = base .. (p:sub(1,1) == "/" and p or ("/" .. p))
    local qs = self:_buildQueryString(query)
    full_url = full_url .. qs

    local headers = {
        ["Accept"] = "application/json",
        ["Authorization"] = "Bearer " .. self.bearer,
        ["Accept-Encoding"] = "identity",
    }
    local source
    if type(body) == "table" then
        local payload = rapidjson.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#payload)
        source = ltn12.source.string(payload)
    elseif type(body) == "string" then
        headers["Content-Length"] = tostring(#body)
        source = ltn12.source.string(body)
    end
    for k, v in pairs(extra_headers) do headers[k] = v end

    local sink_tbl = {}
    logger.dbg("KavitaClient:apiRequest:", method, redact_api_key_in_url(full_url))

    local bt = opts.block_timeout
    local tt = opts.total_timeout
    if not bt or not tt then
        if opts.timeout_profile == "file" then
            bt = socketutil.FILE_BLOCK_TIMEOUT
            tt = socketutil.FILE_TOTAL_TIMEOUT
        else
            bt = socketutil.LARGE_BLOCK_TIMEOUT
            tt = socketutil.LARGE_TOTAL_TIMEOUT
        end
    end
    socketutil:set_timeout(bt, tt)
    local ok, code, resp_headers, status = pcall(function()
        return socket.skip(1, http.request{
            url     = full_url,
            method  = method,
            headers = headers,
            source  = source,
            sink    = ltn12.sink.table(sink_tbl),
        })
    end)
    socketutil:reset_timeout()

    if not ok then
        logger.warn("KavitaClient:apiRequest: LuaSocket error:", code)
        return -1, nil, code, nil
    end

    local body_str = table.concat(sink_tbl)
    logger.dbg("KavitaClient:apiRequest: code =", code, "status =", status, "body_len =", (body_str and #body_str or 0))
    return code, resp_headers, status, body_str
end

-- Same as apiRequest, but decodes JSON body on 200-range responses
function KavitaClient:apiJSON(path, opts)
    local code, headers, status, body = self:apiRequest(path, opts)
    if type(code) ~= "number" or code < 200 or code >= 300 then
        return nil, code, headers, status, body
    end
    local s = body or ""
    -- Strip UTF-8 BOM if present
    if #s >= 3 and s:byte(1) == 0xEF and s:byte(2) == 0xBB and s:byte(3) == 0xBF then
        s = s:sub(4)
    end
    -- Trim leading/trailing whitespace
    s = s:match("^%s*(.-)%s*$")

    local ok, decoded = pcall(rapidjson.decode, s)
    if not ok or type(decoded) ~= "table" then
        local ct = headers and (headers["content-type"] or headers["Content-Type"]) or "unknown"
        logger.warn("KavitaClient:apiJSON: JSON decode failed; content-type=", ct)
        local prefix = s:sub(1, 200):gsub("[%c]", " ")
        logger.dbg("KavitaClient:apiJSON: body prefix =", prefix)
        return nil, code, headers, "Invalid JSON", body
    end
    return decoded, code, headers, status, body
end

-- Dashboard: GET /api/Stream/dashboard (cached)
function KavitaClient:getDashboard()
    return self:apiJSONCached("/api/Stream/dashboard", {
        method = "GET",
        query  = { visibleOnly = true },
    }, 300, "kavita|dashboard")
end

-- Fetch a Series by id: GET /api/Series/{seriesId}
-- Returns: seriesDto_tbl, code, headers, status, raw_body
function KavitaClient:getSeriesById(seriesId)
    if seriesId == nil then
        logger.warn("KavitaClient:getSeriesById: seriesId is required")
        return nil, nil, nil, "seriesId required", nil
    end
    local path = "/api/Series/" .. tostring(seriesId)
    logger.dbg("KavitaClient:getSeriesById:", path)
    local data, code, headers, status, body = self:apiJSONCached(path, { method = "GET" }, 600, "kavita|series")
    return data, code, headers, status, body
end

-- Fetch a stream’s series by name.
-- Uses POST /api/Series/... for known dashboard streams, otherwise falls back to GET /api/Stream/{name}.
-- Returns: array_of_SeriesDto, code, headers, status, raw_body
function KavitaClient:getStreamSeries(name, params)
    if not name or name == "" then
        logger.warn("KavitaClient:getStreamSeries: name is required")
        return nil, nil, nil, "name required", nil
    end

    local method = "GET"
    local path
    local body
    local query = {}

    -- Extract known paging params if provided
    if type(params) == "table" then
        query.PageNumber = params.PageNumber or params.page or params.pageNumber
        query.PageSize   = params.PageSize   or params.page_size or params.pageSize
        query.libraryId  = params.libraryId
    end

    -- Default FilterV2Dto to include only manga (filter out non-manga)
    -- Caller may override by passing params.filter (a full FilterV2Dto table)
    local default_filter_v2 = { statements = { { comparison = 0, field = 21, value = "1" } } }
    local filter_v2 = (type(params) == "table" and params.filter) or default_filter_v2

    if name == "on-deck" then
        method = "POST"
        path = "/api/Series/on-deck"
        body = filter_v2
    elseif name == "recently-updated" or name == "recently-updated-series" then
        method = "POST"
        path = "/api/Series/recently-updated-series"
        body = filter_v2
    elseif name == "newly-added" or name == "recently-added" or name == "recently-added-v2" then
        method = "POST"
        path = "/api/Series/recently-added-v2"
        body = filter_v2
    else
        -- Fallback to Stream endpoint
        method = "GET"
        path = "/api/Stream/" .. tostring(name)
        if type(params) == "table" then
            for k, v in pairs(params) do
                if query[k] == nil then query[k] = v end
            end
        end
        if query.visibleOnly == nil then query.visibleOnly = true end
    end

    logger.dbg("KavitaClient:getStreamSeries:", method, path)
    local data, code, headers, status, body_str = self:apiJSONCached(path, {
        method = method,
        query  = query,
        body   = body,
    }, 120, "kavita|stream")
    return data, code, headers, status, body_str
end

-- Fetch SeriesDetailDto: GET /api/Series/series-detail?seriesId={id}
-- Returns: seriesDetailDto_tbl, code, headers, status, raw_body
function KavitaClient:getSeriesDetail(seriesId)
    if seriesId == nil then
        logger.warn("KavitaClient:getSeriesDetail: seriesId is required")
        return nil, nil, nil, "seriesId required", nil
    end
    local path = "/api/Series/series-detail"
    logger.dbg("KavitaClient:getSeriesDetail:", path, "seriesId=", seriesId)
    local data, code, headers, status, body = self:apiJSONCached(path, {
        method = "GET",
        query  = { seriesId = seriesId },
    }, 300, "kavita|series_detail")
    return data, code, headers, status, body
end

-- Creates a page table for Kavita Reader images
function KavitaClient:createReaderPageTable(chapter_id, ctx)
    local page_table = { image_disposable = true }
    local extractPdf = false

    setmetatable(page_table, { __index = function(_, key)
        if type(key) ~= "number" then
            return nil
        end
        -- Kavita pages are 1-based
        local page = key

        -- Build query
        local query = {
            chapterId  = chapter_id,
            page       = page,
            extractPdf = extractPdf and "true" or "false",
        }
        -- Some deployments require apiKey as query param in addition to Bearer
        if self.api_key and self.api_key ~= "" then
            query.apiKey = self.api_key
        end

        local code, _, status, body_str = self:apiRequest("/api/Reader/image", {
            method  = "GET",
            query   = query,
            headers = { ["Accept"] = "*/*" },
            timeout_profile = "file",
        })

        if type(code) ~= "number" then
            logger.dbg("KavitaClient: Reader image request failed:", status or code)
            return nil
        end

        if code == 200 then
            -- Post reading progress (fire-and-forget) if context is provided
            if ctx and ctx.series_id and ctx.library_id and ctx.volume_id then
                local progress = {
                    volumeId  = ctx.volume_id,
                    chapterId = chapter_id,
                    pageNum   = page,
                    seriesId  = ctx.series_id,
                    libraryId = ctx.library_id,
                }
                local okp, pcode, _, pstatus = pcall(function()
                    return self:postReaderProgress(progress)
                end)
                if not okp then
                    logger.warn("KavitaClient:postReaderProgress pcall failed")
                elseif type(pcode) == "number" and (pcode < 200 or pcode >= 300) then
                    logger.warn("KavitaClient:postReaderProgress non-OK:", pcode, pstatus)
                end
            end
            return body_str
        else
            logger.dbg("KavitaClient: Reader image request failed:", status or code)
            return nil
        end
    end })

    return page_table
end

-- Convenience wrapper to return page table
function KavitaClient:streamChapter(chapter_id, ctx)
    local page_table = self:createReaderPageTable(chapter_id, ctx)
    return page_table
end

-- Save page progress for authenticated user: POST /api/Reader/progress
-- progress = { volumeId, chapterId, pageNum, seriesId, libraryId, bookScrollId?, lastModifiedUtc? }
function KavitaClient:postReaderProgress(progress)
    if type(progress) ~= "table" then
        logger.warn("KavitaClient:postReaderProgress: progress must be table")
        return -1, nil, "invalid progress", nil
    end
    if not (progress.volumeId and progress.chapterId and progress.pageNum and progress.seriesId and progress.libraryId) then
        logger.warn("KavitaClient:postReaderProgress: missing required fields")
        return -1, nil, "invalid progress", nil
    end
    return self:apiRequest("/api/Reader/progress", {
        method = "POST",
        body = progress,
    })
end

-- Search: GET /api/Search/search
-- params: { queryString = "...", includeChapterAndFiles = false }
-- Returns: SearchResultGroupDto table on success
function KavitaClient:getSearch(queryString, includeChapterAndFiles)
    if not queryString or queryString == "" then
        logger.warn("KavitaClient:getSearch: empty queryString")
        return nil, nil, nil, "empty query", nil
    end
    local path = "/api/Search/search"
    local params = {
        queryString = queryString,
        includeChapterAndFiles = includeChapterAndFiles == nil and false or includeChapterAndFiles,
    }
    logger.dbg("KavitaClient:getSearch:", path, "q=", queryString)
    local data, code, headers, status, body = self:apiJSONCached(path, {
        method = "GET",
        query  = params,
    }, 120, "kavita|search")
    return data, code, headers, status, body
end

return KavitaClient

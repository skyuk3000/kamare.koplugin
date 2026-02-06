local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local rapidjson = require("rapidjson")
local mime = require("mime")

local KomgaClient = {}

local function basicAuth(username, password)
    return "Basic " .. mime.b64((username or "") .. ":" .. (password or ""))
end

function KomgaClient:configure(server_url, username, password)
    self.base_url = (server_url or ""):gsub("/+$", "")
    self.username = username
    self.password = password
    self.authorization = basicAuth(username, password)
end

function KomgaClient:_buildQueryString(params)
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

function KomgaClient:apiRequest(path, opts)
    opts = opts or {}
    if not self.base_url or self.base_url == "" then
        return -1, nil, "Missing base_url", nil
    end

    local p = tostring(path or "")
    local full_url = self.base_url .. (p:sub(1,1) == "/" and p or ("/" .. p)) .. self:_buildQueryString(opts.query)

    local headers = {
        ["Accept"] = "application/json",
        ["Authorization"] = self.authorization,
        ["Accept-Encoding"] = "identity",
    }

    local source
    if type(opts.body) == "table" then
        local payload = rapidjson.encode(opts.body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#payload)
        source = ltn12.source.string(payload)
    elseif type(opts.body) == "string" then
        headers["Content-Length"] = tostring(#opts.body)
        source = ltn12.source.string(opts.body)
    end

    if type(opts.headers) == "table" then
        for k, v in pairs(opts.headers) do
            headers[k] = v
        end
    end

    local sink_tbl = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, resp_headers, status = pcall(function()
        return socket.skip(1, http.request{
            url = full_url,
            method = opts.method or "GET",
            headers = headers,
            source = source,
            sink = ltn12.sink.table(sink_tbl),
        })
    end)
    socketutil:reset_timeout()

    if not ok then
        logger.warn("KomgaClient:apiRequest socket error:", code)
        return -1, nil, code, nil
    end

    return code, resp_headers, status, table.concat(sink_tbl)
end

function KomgaClient:apiJSON(path, opts)
    local code, headers, status, body = self:apiRequest(path, opts)
    if type(code) ~= "number" or code < 200 or code >= 300 then
        return nil, code, headers, status, body
    end
    local ok, data = pcall(rapidjson.decode, body or "")
    if not ok then
        return nil, code, headers, "Invalid JSON", body
    end
    return data, code, headers, status, body
end

function KomgaClient:authenticate(server_url, username, password)
    self:configure(server_url, username, password)
    local data, code, headers, status = self:apiJSON("/api/v1/libraries", { method = "GET", query = { size = 1 } })
    if not data then
        return nil, code, headers, status
    end
    return true, code, headers, status
end

function KomgaClient:getLibraries()
    return self:apiJSON("/api/v1/libraries", { method = "GET", query = { size = 1000 } })
end

function KomgaClient:getSeriesByLibrary(library_id)
    return self:apiJSON("/api/v1/series", {
        method = "GET",
        query = { library_id = library_id, size = 1000, sort = "metadata.title,asc" },
    })
end

function KomgaClient:getBooksBySeries(series_id)
    return self:apiJSON("/api/v1/books", {
        method = "GET",
        query = { series_id = series_id, size = 1000, sort = "metadata.numberSort,asc" },
    })
end

function KomgaClient:getBookPages(book_id)
    return self:apiJSON("/api/v1/books/" .. tostring(book_id) .. "/pages", {
        method = "GET",
        query = { size = 2000 },
    })
end

function KomgaClient:createBookPageTable(book_id, pages)
    local page_numbers = {}
    for idx, page in ipairs(pages or {}) do
        page_numbers[idx] = page.number or idx
    end

    local page_table = { image_disposable = true }
    setmetatable(page_table, {
        __index = function(_, key)
            if type(key) ~= "number" then return nil end
            local page_number = page_numbers[key] or key
            local code, _, _, body = self:apiRequest("/api/v1/books/" .. tostring(book_id) .. "/pages/" .. tostring(page_number), {
                method = "GET",
                headers = { ["Accept"] = "*/*" },
                timeout_profile = "file",
            })
            if type(code) ~= "number" or code < 200 or code >= 300 then
                return nil
            end
            return body
        end,
    })
    return page_table
end

return KomgaClient

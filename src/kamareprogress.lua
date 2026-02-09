local KavitaClient = require("kavitaclient")
local logger = require("logger")

local ProgressQueue = {}

local function buildPayload(ctx, page_num)
    return {
        volumeId  = ctx.volume_id or ctx.volumeId,
        chapterId = ctx.chapter_id or ctx.chapterId,
        pageNum   = page_num,
        seriesId  = ctx.series_id or ctx.seriesId,
        libraryId = ctx.library_id or ctx.libraryId,
    }
end

local function normalizeServerUrl(ctx)
    return ctx.server_url or ctx.serverUrl or ctx.kavita_url or ctx.kavitaUrl
end

function ProgressQueue:queueProgress(settings, ctx, page_num)
    if not settings or type(ctx) ~= "table" or type(page_num) ~= "number" then
        return
    end

    local payload = buildPayload(ctx, page_num)
    if not (payload.volumeId and payload.chapterId and payload.seriesId and payload.libraryId) then
        logger.warn("ProgressQueue: missing required progress payload fields")
        return
    end

    local server_url = normalizeServerUrl(ctx)
    local key = string.format("%s|%s", server_url or "unknown", tostring(payload.chapterId))
    local pending = settings:readSetting("pending_progress", {}) or {}
    if type(pending) ~= "table" then
        pending = {}
    end

    local existing = pending[key]
    if not existing or (payload.pageNum > (existing.progress and existing.progress.pageNum or 0)) then
        pending[key] = {
            server_url = server_url,
            progress = payload,
            updated_at = os.time(),
        }
    end

    settings:saveSetting("pending_progress", pending)
end

local function findServerEntry(servers, server_url)
    if type(servers) ~= "table" or not server_url then
        return nil
    end
    for _, server in ipairs(servers) do
        if type(server) == "table" and server.kavita_url == server_url then
            return server
        end
    end
    return nil
end

function ProgressQueue:syncPending(settings)
    if not settings then return 0 end

    local pending = settings:readSetting("pending_progress", {}) or {}
    if type(pending) ~= "table" or not next(pending) then
        return 0
    end

    local servers = settings:readSetting("servers", {}) or {}
    local synced = 0

    for key, entry in pairs(pending) do
        local server_url = entry and entry.server_url
        local progress = entry and entry.progress
        if type(progress) == "table" and server_url then
            local server = findServerEntry(servers, server_url)
            if server and server.api_key and server.kavita_url then
                local token, code = KavitaClient:authenticate(server.kavita_url, server.api_key)
                if token and type(code) == "number" and code >= 200 and code < 300 then
                    KavitaClient.api_key = server.api_key
                    local post_code = KavitaClient:postReaderProgress(progress)
                    if type(post_code) == "number" and post_code >= 200 and post_code < 300 then
                        pending[key] = nil
                        synced = synced + 1
                    else
                        logger.warn("ProgressQueue: failed to post progress for", key, post_code)
                    end
                else
                    logger.warn("ProgressQueue: auth failed for", server_url, code)
                end
            else
                logger.warn("ProgressQueue: missing server entry for", server_url)
            end
        end
    end

    settings:saveSetting("pending_progress", pending)
    return synced
end

return ProgressQueue

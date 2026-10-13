local _ = require("gettext")

local GrimmoryAPI = require("grimmory/grimmory_api")
local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

-- Server responses are kept in memory for this long.  Going back to a list,
-- turning back a page or reopening the browser within this time needs no
-- request; "Refresh" clears everything.  Nothing is kept across restarts
-- (covers are, on disk: see covers.lua).
local CACHE_TTL_SECONDS = 600

-- Shared by all browser instances (FileManager and ReaderUI each have their
-- own plugin instance).
local response_cache = {}

---@class GrimmoryLibraryData
---@field api GrimmoryAPI
---@field reconnect function(on_ready: function(), on_failed: function(reason: string))
---@field is_connected function(): boolean
---@field before_request function | nil Called before a request goes to the server
local LibraryData = {}

function LibraryData:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function LibraryData.clearCache()
    response_cache = {}
end

local function getCached(key)
    local entry = response_cache[key]
    if entry and os.time() - entry.time < CACHE_TTL_SECONDS then
        return entry.value
    end
    response_cache[key] = nil
    return nil
end

--- Short, user facing reason for a failed request.
---@param connected boolean | nil Whether the device is connected (nil: unknown)
function LibraryData.describeError(result, connected)
    if GrimmoryAPI.isNetworkError(result) then
        if connected == false then
            return _("No network connection")
        end
        if connected then
            return _("The Grimmory server is not reachable.")
        end
        return _("No network connection")
    end

    local text = tostring(result)
    if text:lower():find("not found", 1, true) then
        return _("Not available on this Grimmory server. Is Grimmory up to date?")
    end

    return text
end

--- Run `request` (returning ok, result) unless its result is cached.  If it
--- fails because the network is gone (e.g. WiFi was dropped while browsing),
--- reconnect and try once more.  `on_done(ok, result_or_reason)` may be called
--- synchronously.
---@param key string | nil Cache key, nil to not cache
function LibraryData:fetch(key, request, on_done)
    if key then
        local cached = getCached(key)
        if cached ~= nil then
            on_done(true, cached)
            return
        end
    end

    local function attempt(may_retry)
        if self.before_request then
            self.before_request()
        end

        local call_ok, ok, result = pcall(request)

        if not call_ok then
            ok, result = false, ok
        end

        if ok then
            if key then
                response_cache[key] = { time = os.time(), value = result }
            end
            on_done(true, result)
            return
        end

        logger:warn("Library request failed:", key, result)

        if may_retry and (GrimmoryAPI.isNetworkError(result) or not self.is_connected()) then
            self.reconnect(
                function()
                    attempt(false)
                end,
                function(reason)
                    on_done(false, reason or LibraryData.describeError(result, self.is_connected()))
                end
            )
            return
        end

        on_done(false, LibraryData.describeError(result, self.is_connected()))
    end

    attempt(true)
end

return LibraryData

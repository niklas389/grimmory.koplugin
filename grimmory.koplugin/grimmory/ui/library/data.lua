local _ = require("gettext")

local Cooperative = require("grimmory/cooperative")
local GrimmoryAPI = require("grimmory/grimmory_api")
local GrimmoryLogger = require("grimmory/logger")
local HttpClient = require("grimmory/http_client")

local logger = GrimmoryLogger:new()

-- Server responses are kept in memory for this long.  Going back to a list,
-- turning back a page or reopening the browser within this time needs no
-- request; "Refresh" clears everything.  Nothing is kept across restarts
-- (covers are, on disk: see covers.lua).
local CACHE_TTL_SECONDS = 600

-- Seconds without any data from the server before a request gives up
local READ_TIMEOUT_SECONDS = 30

-- Shared by all browser instances (FileManager and ReaderUI each have their
-- own plugin instance).
local response_cache = {}

---@class GrimmoryLibraryData
---@field api GrimmoryAPI
---@field reconnect function(on_ready: function(), on_failed: function(reason: string))
---@field is_connected function(): boolean
---@field before_request function | nil Called before a request goes to the server
---@field after_requests function | nil Called when no request is running any more
local LibraryData = {}

function LibraryData:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.running = {}
    o.waiting = {}
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

--- Whether requests are running
function LibraryData:isBusy()
    return next(self.running) ~= nil
end

--- Give up all running requests (the browser closes): their callbacks are
--- not called.
function LibraryData:cancelAll()
    self.cancelled = true
    for handle in pairs(self.running) do
        handle.cancel()
    end
    self.running = {}
    self.waiting = {}
end

--- Run `request` (returning ok, result) unless its result is cached.  The
--- request does not block KOReader: `on_done(ok, result_or_reason)` is called
--- when the answer arrives, or right away (cached, or failed at once).
--- If it fails because the network is gone (e.g. WiFi was dropped while
--- browsing), reconnect and try once more.  The same key requested again
--- while it runs gets the same answer.
---@param key string | nil Cache key, nil to not cache
function LibraryData:fetch(key, request, on_done)
    if key then
        local cached = getCached(key)
        if cached ~= nil then
            on_done(true, cached)
            return
        end
        if self.waiting[key] then
            table.insert(self.waiting[key], on_done)
            return
        end
    end

    local callbacks = { on_done }
    if key then
        self.waiting[key] = callbacks
    end

    local function finish(ok, result)
        if key and self.waiting[key] == callbacks then
            self.waiting[key] = nil
        end
        if self.cancelled then
            return
        end
        for _, callback in ipairs(callbacks) do
            callback(ok, result)
        end
    end

    local attempt

    local function answered(may_retry, ok, result)
        if ok then
            if key then
                response_cache[key] = { time = os.time(), value = result }
            end
            finish(true, result)
            return
        end

        logger:warn("Library request failed:", key, result)

        -- WiFi dropped: reconnect and try again.  Not when the server did not
        -- answer while connected (e.g. a firewall blocks it): that would only
        -- wait as long again.
        local connected = self.is_connected()
        local network_error = GrimmoryAPI.isNetworkError(result)
        if may_retry and (not connected or (network_error and not HttpClient.isTimeout(result))) then
            self.reconnect(
                function()
                    attempt(false)
                end,
                function(reason)
                    finish(false, reason or LibraryData.describeError(result, self.is_connected()))
                end
            )
            return
        end

        finish(false, LibraryData.describeError(result, connected))
    end

    attempt = function(may_retry)
        if self.cancelled then
            return
        end
        if self.before_request then
            self.before_request()
        end

        local handle
        local finished_at_once = false
        handle = Cooperative.run(request, function(call_ok, ok, result)
            if handle then
                self.running[handle] = nil
            else
                finished_at_once = true
            end
            if not call_ok then
                ok, result = false, ok
            end
            if not self:isBusy() and self.after_requests then
                self.after_requests()
            end
            answered(may_retry, ok, result)
        end, { read_timeout = READ_TIMEOUT_SECONDS })

        if not finished_at_once then
            self.running[handle] = true
        end
    end

    attempt(true)
end

return LibraryData

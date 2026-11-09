--[[
Run server requests without blocking KOReader.

`Cooperative.run(fn, on_done)` runs `fn` in a coroutine.  While one of its
requests (grimmory/http_client.lua) waits for the server, the coroutine
sleeps in small steps through UIManager, so KOReader keeps drawing and
handling taps (e.g. Back) meanwhile.  `on_done(true, ...)` gets what `fn`
returned, or `on_done(false, error)` if it raised an error; it is called
right away when `fn` did not need to wait.

The returned handle's `cancel()` gives the requests up: their sockets are
closed and `on_done` is not called.

Not for code that runs in a subprocess (it would sleep through the parent's
UIManager): there, requests simply wait.
--]]

local UIManager = require("ui/uimanager")

local GrimmoryLogger = require("grimmory/logger")
local HttpClient = require("grimmory/http_client")

local logger = GrimmoryLogger:new()

local Cooperative = {}

-- LuaJIT (KOReader) has the global; newer Lua (e.g. the tests' CI) only table.unpack
local unpack = unpack or table.unpack

local function pack(...)
    return { n = select("#", ...), ... }
end

---@param fn function
---@param on_done function(call_ok: boolean, ...)
---@param options table | nil { read_timeout = seconds without data from the server }
---@return table handle { cancel = function() }
function Cooperative.run(fn, on_done, options)
    local handle = { cancelled = false }
    -- (fn may be any callable)
    local co = coroutine.create(function()
        return fn()
    end)

    local function resume()
        local results = pack(coroutine.resume(co))
        if coroutine.status(co) ~= "dead" then
            -- Sleeping until the next step
            return
        end
        HttpClient.setContext(co, nil)
        if not handle.cancelled then
            -- Usually called from a scheduled task: an error must not end
            -- KOReader
            local ok, err = xpcall(function()
                on_done(unpack(results, 1, results.n))
            end, debug.traceback)
            if not ok then
                logger:err("Handling a server answer failed:", err)
            end
        end
    end

    HttpClient.setContext(co, {
        read_timeout = options and options.read_timeout,
        sleep = function(seconds)
            UIManager:scheduleIn(seconds, resume)
            coroutine.yield()
            return not handle.cancelled
        end,
    })

    function handle.cancel()
        handle.cancelled = true
    end

    resume()
    return handle
end

return Cooperative

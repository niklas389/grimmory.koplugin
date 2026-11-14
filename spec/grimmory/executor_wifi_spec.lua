local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

-- KOReader's scheduler: run the scheduled functions when the test says so
local scheduled = {}
local function run_scheduled()
    local guard = 0
    while #scheduled > 0 and guard < 1000 do
        guard = guard + 1
        table.remove(scheduled, 1)()
    end
end

local clock = 0
local wifi_on = false
local net_connect_calls = 0

local function load_executor()
    package.loaded["grimmory/executor"] = nil
    package.loaded["ffi/util"] = {}
    package.loaded["ffi"] = { C = {} }
    package.loaded["json"] = {}
    package.loaded["socket"] = { gettime = function() clock = clock + 1; return clock end }
    package.loaded["device"] = {
        hasWifiToggle = function() return true end,
        hasWifiRestore = function() return false end,
        isPocketBook = function() return true end,
    }
    package.loaded["ui/event"] = { new = function() return {} end }
    package.loaded["ui/uimanager"] = {
        scheduleIn = function(_, _, fn) table.insert(scheduled, fn) end,
        forceRePaint = function() end,
        broadcastEvent = function() end,
        preventStandby = function() end,
        allowStandby = function() end,
    }
    package.loaded["ui/network/manager"] = {
        isWifiOn = function() return wifi_on end,
        isConnected = function() return wifi_on end,
        -- PocketBook's NetConnect, e.g. in flight mode: its dialog, then no WiFi
        enableWifi = function() net_connect_calls = net_connect_calls + 1 end,
        _abortWifiConnection = function() end,
        disableWifi = function() end,
    }
    local quiet = function() end
    package.loaded["grimmory/logger"] = {
        new = function() return { err = quiet, warn = quiet, info = quiet, dbg = quiet } end,
    }
    return require("grimmory/executor")
end

describe("Turning WiFi on", function()
    local Executor, executor

    before_each(function()
        scheduled, clock, wifi_on, net_connect_calls = {}, 0, false, 0
        Executor = load_executor()
        executor = Executor:new({})
    end)

    teardown(function()
        for _, name in ipairs({ "grimmory/executor", "ffi/util", "ffi", "json", "socket", "device", "ui/event",
            "ui/uimanager", "ui/network/manager", "grimmory/logger" }) do
            package.loaded[name] = nil
        end
    end)

    local function automatic_sync()
        local result
        executor:background(function(run)
            result = { run(function() end) }
        end, true, true)
        run_scheduled()
        return result
    end

    it("tries once for an automatic action, then pauses", function()
        assert.are.same({ false, Executor.ERROR_WIFI_FAILED }, automatic_sync())
        assert.are.equal(1, net_connect_calls)
        assert.is_true(Executor.isAutoWifiPaused())

        -- The next automatic action does not show the WiFi dialog again
        assert.are.same({ false, Executor.ERROR_WIFI_PAUSED }, automatic_sync())
        assert.are.equal(1, net_connect_calls)
    end)

    it("still tries when started by hand, while paused", function()
        automatic_sync()
        assert.are.equal(1, net_connect_calls)

        executor:holdWifi(function() end, function() end)
        run_scheduled()

        -- (A second attempt follows after a pause; plain Lua 5.1 cannot run
        -- it here: the coroutine cannot yield inside xpcall, LuaJIT can)
        assert.is_true(net_connect_calls >= 2)
    end)

    it("turns WiFi on by itself again once it worked", function()
        automatic_sync()
        Executor.resumeAutoWifi()

        automatic_sync()
        assert.are.equal(2, net_connect_calls)
    end)

    it("takes Suspend / Resume right after its own attempt as its own (PocketBook's WiFi dialog)", function()
        assert.is_false(Executor.isOwnConnectionEvent())
        automatic_sync()
        assert.is_true(Executor.isOwnConnectionEvent())
    end)
end)

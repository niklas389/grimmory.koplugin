local assert = require 'luassert'
local spy = require 'luassert.spy'

package.path = "grimmory.koplugin/?.lua;" .. package.path

package.preload["grimmory/logger"] = function()
    local noop = function() end
    return { new = function() return { err = noop, warn = noop, info = noop, dbg = noop } end }
end

package.preload["gettext"] = function()
    return function(text) return text end
end

-- Only isNetworkError is used from the API module
package.preload["grimmory/grimmory_api"] = function()
    return {
        isNetworkError = function(message)
            return type(message) == "string" and (message:find("refused") or message:find("name resolution")) ~= nil
        end,
    }
end

local LibraryData = require("grimmory/ui/library/data")

local function new_data(opts)
    LibraryData.clearCache()
    return LibraryData:new({
        reconnect = opts.reconnect or function(on_ready) on_ready() end,
        is_connected = opts.is_connected or function() return true end,
        before_request = opts.before_request,
    })
end

describe("LibraryData", function()
    it("caches successful answers", function()
        local data = new_data({})
        local request = spy.new(function() return true, { "a" } end)
        local results = {}

        data:fetch("key", request, function(ok, result) table.insert(results, { ok, result }) end)
        data:fetch("key", request, function(ok, result) table.insert(results, { ok, result }) end)

        assert.spy(request).was.called(1)
        assert.are.same({ { true, { "a" } }, { true, { "a" } } }, results)
    end)

    it("does not cache failures", function()
        local data = new_data({})
        local request = spy.new(function() return false, "Not found" end)

        data:fetch("key", request, function() end)
        data:fetch("key", request, function() end)

        assert.spy(request).was.called(2)
    end)

    it("announces requests that go to the server", function()
        local before = spy.new(function() end)
        local data = new_data({ before_request = before })

        data:fetch("key", function() return true, 1 end, function() end)
        data:fetch("key", function() return true, 1 end, function() end)

        assert.spy(before).was.called(1)
    end)

    it("reconnects and retries once when the network is gone", function()
        local reconnect = spy.new(function(on_ready) on_ready() end)
        local data = new_data({ reconnect = reconnect })
        local attempts = 0
        local answer

        data:fetch("key", function()
            attempts = attempts + 1
            if attempts == 1 then
                return false, "temporary failure in name resolution"
            end
            return true, "books"
        end, function(ok, result) answer = { ok, result } end)

        assert.spy(reconnect).was.called(1)
        assert.are.equal(2, attempts)
        assert.are.same({ true, "books" }, answer)
    end)

    it("reconnects when the device lost its connection, whatever the error", function()
        local reconnect = spy.new(function(on_ready) on_ready() end)
        local data = new_data({ reconnect = reconnect, is_connected = function() return false end })

        data:fetch("key", function() return false, "weird error" end, function() end)

        assert.spy(reconnect).was.called(1)
    end)

    it("does not reconnect for server errors", function()
        local reconnect = spy.new(function(on_ready) on_ready() end)
        local data = new_data({ reconnect = reconnect })
        local answer

        data:fetch("key", function() return false, "Not found" end, function(ok, result) answer = { ok, result } end)

        assert.spy(reconnect).was_not.called()
        assert.is_false(answer[1])
        assert.are.equal("Not available on this Grimmory server. Is Grimmory up to date?", answer[2])
    end)

    it("reports why reconnecting failed", function()
        local data = new_data({
            reconnect = function(_, on_failed) on_failed("WiFi didn't turn on") end,
            is_connected = function() return false end,
        })
        local answer

        data:fetch("key", function() return false, "connection refused" end, function(ok, result)
            answer = { ok, result }
        end)

        assert.are.same({ false, "WiFi didn't turn on" }, answer)
    end)

    it("tells an unreachable server from a missing connection", function()
        assert.are.equal("No network connection", LibraryData.describeError("connection refused", false))
        assert.are.equal("The Grimmory server is not reachable.", LibraryData.describeError("connection refused", true))
    end)
end)

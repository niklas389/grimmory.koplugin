local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

package.preload["grimmory/logger"] = function()
    local quiet = function() end
    return { new = function() return { err = quiet, warn = quiet, info = quiet, dbg = quiet } end }
end

local scheduled = {}
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_, _, fn) table.insert(scheduled, fn) end,
    unschedule = function(_, fn)
        for i, task in ipairs(scheduled) do
            if task == fn then
                table.remove(scheduled, i)
                return
            end
        end
    end,
}

local ReadingRecorder = require("grimmory/reading/recorder")

local function recorder()
    local page = 0
    local writes = {}
    local r = ReadingRecorder:new({
        repository = {
            upsertBook = function() return true, 1 end,
            insertSession = function() return true, 7 end,
            insertBookEvents = function(_, events)
                local types = {}
                for _, event in ipairs(events) do
                    table.insert(types, event.event_type .. ":" .. event.current_page)
                end
                table.insert(writes, types)
            end,
        },
        ui = {
            getCurrentPage = function() return page end,
            document = { file = "/b.epub", info = { has_pages = true }, getPageCount = function() return 100 end },
        },
    })
    return r, writes, function(new_page) page = new_page end
end

describe("ReadingRecorder", function()
    before_each(function()
        for i = #scheduled, 1, -1 do
            scheduled[i] = nil
        end
    end)

    it("writes page turns together, later, and session starts at once", function()
        local r, writes, turn = recorder()

        turn(1)
        r:onPageUpdate()
        turn(2)
        r:onPageUpdate()
        turn(3)
        r:onPageUpdate()

        -- The session start right away; the page turns wait
        assert.are.same({ { "session-start:1" } }, writes)
        assert.are.equal(1, #scheduled)

        table.remove(scheduled, 1)()
        assert.are.same({ { "session-start:1" }, { "page:1", "page:2", "page:3" } }, writes)
    end)

    it("writes waiting page turns with the end of the session, in order", function()
        local r, writes, turn = recorder()

        turn(1)
        r:onPageUpdate()
        turn(2)
        r:onPageUpdate()
        r:onSessionEnd()

        assert.are.same({ { "session-start:1" }, { "page:1", "page:2", "session-end:2" } }, writes)
        assert.are.equal(0, #scheduled)
    end)

    it("writes waiting page turns when flushed (before a sync)", function()
        local r, writes, turn = recorder()

        turn(5)
        r:onPageUpdate()
        r:flush()
        r:flush()

        assert.are.same({ { "session-start:5" }, { "page:5" } }, writes)
    end)
end)

local assert = require 'luassert'
local spy = require 'luassert.spy'

package.path = "grimmory.koplugin/?.lua;" .. package.path

package.preload["ui/event"] = function() return { new = function() return {} end } end
package.preload["util"] = function() return {} end
package.preload["ffi/sha2"] = function() return { md5 = function(text) return text end } end
package.preload["grimmory/logger"] = function()
    local quiet = function() end
    return { new = function() return { err = quiet, warn = quiet, info = quiet, dbg = quiet } end }
end

local ReadingProgressManager = require("grimmory/reading/progress_manager")

local function manager(local_percent, remote_percent)
    local m = ReadingProgressManager:new({
        ui = {},
        repository = {
            upsertBook = function() return true, 1 end,
            getReadingProgress = function()
                return true, { end_progress = local_percent, end_time = 100, book_path = "/b.epub" }
            end,
        },
    })
    m.getRemoteProgressForBook = spy.new(function()
        return "Phone", "phone", { end_progress = remote_percent, end_time = 200 }
    end)
    return m
end

describe("ReadingProgressManager:getNewerProgressForBook", function()
    it("does not ask the server when the book list shows the same progress", function()
        local m = manager(42.5, 80)

        assert.is_nil((m:getNewerProgressForBook("/b.epub", 42.505)))
        assert.spy(m.getRemoteProgressForBook).was_not.called()
    end)

    it("asks the server when the book list shows other progress", function()
        local m = manager(42.5, 80)

        local _, _, progress = m:getNewerProgressForBook("/b.epub", 80)
        assert.spy(m.getRemoteProgressForBook).was.called(1)
        assert.are.equal(80, progress.end_progress)
    end)

    it("asks the server without a hint", function()
        local m = manager(42.5, 80)

        m:getNewerProgressForBook("/b.epub")
        assert.spy(m.getRemoteProgressForBook).was.called(1)
    end)
end)

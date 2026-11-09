local assert = require 'luassert'
local spy = require 'luassert.spy'
local unpack = table.unpack or unpack -- luacheck: ignore

package.path = "grimmory.koplugin/?.lua;" .. package.path

local quiet = function() end
package.preload["grimmory/logger"] = function()
    return { new = function() return { err = quiet, warn = quiet, info = quiet, dbg = quiet } end }
end
package.preload["gettext"] = function() return function(text) return text end end
package.preload["readcollection"] = function() return {} end
package.preload["ffi/MD5"] = function() return {} end
package.preload["util"] = function() return {} end

local GrimmorySynchronize = require("grimmory/synchronize")

local function synchronizer(push_result)
    local events = {}
    local sync = GrimmorySynchronize:new({
        settings = {
            getSyncReadingProgress = function() return true end,
            getSyncReadingSessions = function() return false end,
        },
        repository = {
            upsertBook = function() return true, 1, nil end,
            getReadingProgress = function()
                return true, { end_time = 200, end_progress = 40, book_path = "/b.epub", book_md5 = "abc" }
            end,
            getBookSyncTimestamp = function() return true, 100 end,
            updateBookSyncTimestamp = spy.new(function() return true end),
        },
        reading_progress_manager = {
            pushRemoteProgress = function() return unpack(push_result, 1, 3) end,
        },
        api = {
            isGrimmoryFormat = function(path) return path:match("%.epub$") ~= nil end,
            getServerVersion = function() return true, "v1" end,
        },
    })
    return sync, events, function(event) table.insert(events, event) end
end

describe("Pushing reading progress", function()
    it("does not count a book Grimmory does not have as a failure", function()
        local sync, events, callback = synchronizer({ false, "Book not found for hash abc", 404 })

        sync:pushBookProgress(1, callback)

        assert.are.same({}, events)
        -- Not sent again with every sync
        assert.spy(sync.repository.updateBookSyncTimestamp).was.called_with(sync.repository, 1, "progress", 200)
    end)

    it("reports other failures", function()
        local sync, events, callback = synchronizer({ false, "Internal error", 500 })

        sync:pushBookProgress(1, callback)

        assert.are.equal("progress-failed", events[1].state)
        assert.spy(sync.repository.updateBookSyncTimestamp).was_not.called()
    end)

    it("sends nothing for files that cannot be Grimmory books", function()
        local sync, events, callback = synchronizer({ true })
        sync.repository.upsertBook = spy.new(function() return true, 1 end)

        sync:pushBookProgressAndSessions("/ebrmain/license/about_firmware.txt", callback)

        assert.are.same({}, events)
        assert.spy(sync.repository.upsertBook).was_not.called()
    end)
end)

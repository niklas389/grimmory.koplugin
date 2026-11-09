local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

package.preload["gettext"] = function()
    return function(text) return text end
end

package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local args = { ... }
            return (text:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
        end,
    }
end

local SyncProgress = require("grimmory/ui/sync_progress")

describe("SyncProgress", function()
    it("names the step and counts the books of a download", function()
        local progress = SyncProgress:new()

        assert.are.same({
            step = "Downloading books",
            detail = "3 of 6 · Glass Harbor",
            fraction = 2 / 6,
        }, progress:handle({ state = "stage", stage = "download", current = 3, total = 6, title = "Glass Harbor" }))
    end)

    it("moves the bar with the download of the current book", function()
        local progress = SyncProgress:new()
        progress:handle({ state = "stage", stage = "download", current = 3, total = 6, title = "Glass Harbor" })

        assert.are.same({ fraction = (2 + 0.5) / 6 },
            progress:handle({ state = "download-progress", bytes = 512, total = 1024 }))
    end)

    it("counts books for steps that go through the whole list", function()
        local progress = SyncProgress:new()

        assert.are.same({ step = "Checking the library", detail = "120 of 480 books", fraction = 0.25 },
            progress:handle({ state = "stage", stage = "check", current = 120, total = 480 }))
    end)

    it("shows steps without counts", function()
        assert.are.same({ step = "Updating shelves", detail = "", fraction = 0 },
            SyncProgress:new():handle({ state = "stage", stage = "shelves" }))
    end)

    it("shows how much arrived when the size of the download is unknown", function()
        local progress = SyncProgress:new()
        progress:handle({ state = "stage", stage = "download", current = 1, total = 2, title = "Riverbend" })

        assert.are.same({ detail = "1 of 2 · Riverbend · 2.5 MB" },
            progress:handle({ state = "download-progress", bytes = 2.5 * 1048576 }))
    end)

    it("ignores other events", function()
        local progress = SyncProgress:new()
        progress:handle({ state = "stage", stage = "download", current = 1, total = 2 })

        assert.is_nil(progress:handle({ state = "book-downloaded" }))
        assert.is_nil(progress:handle(nil))
    end)
end)

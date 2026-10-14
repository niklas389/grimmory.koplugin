local assert = require 'luassert'
local spy = require 'luassert.spy'

package.path = "grimmory.koplugin/?.lua;" .. package.path

for _, name in ipairs({ "socket.http", "ssl.https", "json", "ltn12", "socket", "socket.url" }) do
    package.preload[name] = function() return {} end
end

package.preload["gettext"] = function()
    return function(text) return text end
end

package.preload["grimmory/plugin_metadata"] = function() return {} end

local fake_logger = {
    err = function() end,
    warn = function() end,
    info = function() end,
    dbg = function() end,
}
package.preload["grimmory/logger"] = function()
    return { new = function() return fake_logger end }
end

package.preload["readcollection"] = function() return {} end
package.preload["ffi/MD5"] = function() return {} end
package.preload["util"] = function() return {} end

local GrimmoryAPI = require("grimmory/grimmory_api")
local GrimmorySynchronize = require("grimmory/synchronize")

describe("Reading progress from the server", function()
    describe("normalizeProgress", function()
        local normalize = GrimmoryAPI.normalizeProgress

        it("takes KOReader fractions as fractions", function()
            assert.are.equal(88, normalize(0.88, "READING"))
            assert.are.equal(12, normalize(0.12, "READING"))
        end)

        it("keeps percentages", function()
            assert.are.equal(47.5, normalize(47.5, "READING"))
        end)

        it("treats finished books as 100 %", function()
            assert.are.equal(100, normalize(1.0, "READ"))
            assert.are.equal(100, normalize(nil, "READ"))
        end)

        it("has no progress for unread books", function()
            assert.is_nil(normalize(nil, "UNREAD"))
            assert.is_nil(normalize(0, "UNREAD"))
        end)
    end)

    describe("parseServerProgress", function()
        local parse = GrimmoryAPI.parseServerProgress

        it("prefers KOReader progress, which is a fraction", function()
            local progress = parse({
                koreaderProgress = { percentage = 0.5 },
                epubProgress = { percentage = 20 },
            }, "READING")
            assert.are.same({ percent = 50 }, progress)
        end)

        it("uses Grimmory's reader progress in percent", function()
            assert.are.same({ percent = 20 }, parse({ epubProgress = { percentage = 20 } }, "READING"))
        end)

        it("keeps the page of page based formats", function()
            assert.are.same({ percent = 30, page = 42 }, parse({ pdfProgress = { page = 42, percentage = 30 } }))
        end)

        it("falls back to the summary's progress", function()
            assert.are.same({ percent = 64 }, parse({}, "READING", 64))
        end)

        it("has nothing without any progress", function()
            assert.is_nil(parse({}, "UNREAD"))
        end)
    end)

    describe("applyServerProgress", function()
        local function synchronizer(has_position, sync_progress)
            local doc_metadata = {
                hasPosition = function() return has_position end,
                setProgress = spy.new(function() end),
            }
            local sync = GrimmorySynchronize:new({
                settings = { getSyncReadingProgress = function() return sync_progress end },
                doc_metadata = doc_metadata,
            })
            return sync, doc_metadata
        end

        it("writes the server position of a new book", function()
            local sync, doc_metadata = synchronizer(false, true)

            sync:applyServerProgress("/books/a.epub", { percent = 88 })

            assert.spy(doc_metadata.setProgress).was.called_with(doc_metadata, "/books/a.epub", 88, nil, nil)
        end)

        it("keeps a position the KOReader sync already set", function()
            local sync, doc_metadata = synchronizer(true, true)

            sync:applyServerProgress("/books/a.epub", { percent = 88 })

            assert.spy(doc_metadata.setProgress).was_not.called()
        end)

        it("does nothing when progress sync is off", function()
            local sync, doc_metadata = synchronizer(false, false)

            sync:applyServerProgress("/books/a.epub", { percent = 88 })

            assert.spy(doc_metadata.setProgress).was_not.called()
        end)
    end)
end)

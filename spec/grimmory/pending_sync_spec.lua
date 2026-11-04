local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local quiet = function() end

local stored_settings
local existing_files

local FAKES = {
    ["grimmory/logger"] = { new = function() return { err = quiet, warn = quiet, info = quiet, dbg = quiet } end },
    ["gettext"] = function(text) return text end,
    ["datastorage"] = { getSettingsDir = function() return "/tmp" end },
    ["random"] = { uuid = function() return "device-uuid" end },
    ["device"] = { model = "Test" },
    ["readcollection"] = {},
    ["ffi/MD5"] = {},
    ["util"] = { makePath = quiet },
    ["grimmory/smart_download"] = {},
    ["libs/libkoreader-lfs"] = {
        attributes = function(path, what)
            return what == "mode" and existing_files[path] and "file" or nil
        end,
    },
}

local function load_modules()
    for name, fake in pairs(FAKES) do
        package.loaded[name] = fake
    end
    package.loaded["luasettings"] = {
        open = function()
            return {
                readSetting = function(_, key) return stored_settings[key] end,
                saveSetting = function(_, key, value) stored_settings[key] = value end,
                flush = quiet,
            }
        end,
    }
    package.loaded["grimmory/settings"] = nil
    package.loaded["grimmory/synchronize"] = nil
    return require("grimmory/settings"), require("grimmory/synchronize")
end

describe("Pending syncs", function()
    local GrimmorySettings, GrimmorySynchronize
    local settings, sync, reports

    before_each(function()
        stored_settings = {}
        existing_files = { ["/books/a.epub"] = true, ["/books/b.epub"] = true }
        GrimmorySettings, GrimmorySynchronize = load_modules()
        settings = GrimmorySettings:new()
        sync = GrimmorySynchronize:new({ settings = settings })
        reports = {}
    end)

    teardown(function()
        for name in pairs(FAKES) do
            package.loaded[name] = nil
        end
        for _, name in ipairs({ "luasettings", "grimmory/settings", "grimmory/synchronize" }) do
            package.loaded[name] = nil
        end
    end)

    local function report(state)
        if state.state == "pending-synced" then
            table.insert(reports, state.kind .. ":" .. state.book_path)
        end
    end

    describe("settings", function()
        it("remembers what is pending per book until it is cleared", function()
            settings:markPendingSync("/books/a.epub", "progress")
            settings:markPendingSync("/books/a.epub", "annotations")
            assert.are.same({ ["/books/a.epub"] = { progress = true, annotations = true } },
                settings:getPendingSyncBooks())

            settings:clearPendingSync("/books/a.epub", "progress")
            assert.are.same({ ["/books/a.epub"] = { annotations = true } }, settings:getPendingSyncBooks())

            settings:clearPendingSync("/books/a.epub", "annotations")
            assert.are.same({}, settings:getPendingSyncBooks())
        end)

        it("remembers a failed sync of all books", function()
            assert.is_false(settings:getPendingSyncPush())
            settings:setPendingSyncPush(true)
            assert.is_true(GrimmorySettings:new():getPendingSyncPush())
        end)
    end)

    describe("sending", function()
        it("sends a book's progress and forgets it once accepted", function()
            local pushed = {}
            sync.pushBookProgressAndSessions = function(_, path) table.insert(pushed, path) end

            sync:pushPendingBooks({ ["/books/a.epub"] = { progress = true } }, nil, report)

            assert.are.same({ "/books/a.epub" }, pushed)
            assert.are.same({ "progress:/books/a.epub" }, reports)
        end)

        it("keeps a book's progress when the server did not accept it", function()
            sync.pushBookProgressAndSessions = function(_, _, callback)
                callback({ state = "progress-failed" })
            end
            sync:pushPendingBooks({ ["/books/a.epub"] = { progress = true } }, nil, report)
            assert.are.same({}, reports)

            -- No connection: an error
            sync.pushBookProgressAndSessions = function() error("Cannot connect to valid server") end
            sync:pushPendingBooks({ ["/books/a.epub"] = { progress = true } }, nil, report)
            assert.are.same({}, reports)
        end)

        it("pushes highlights, except those of the open book", function()
            local pushed = {}
            sync.pushPendingAnnotations = function(_, path)
                table.insert(pushed, path)
                return true
            end

            sync:pushPendingBooks({
                ["/books/a.epub"] = { annotations = true },
                ["/books/b.epub"] = { annotations = true },
            }, "/books/b.epub", report)

            assert.are.same({ "/books/a.epub" }, pushed)
            assert.are.same({ "annotations:/books/a.epub" }, reports)
        end)

        it("keeps highlights that could not all be pushed", function()
            sync.pushPendingAnnotations = function() return false end
            sync:pushPendingBooks({ ["/books/a.epub"] = { annotations = true } }, nil, report)
            assert.are.same({}, reports)
        end)

        it("forgets highlights when highlight sync is off", function()
            settings.data.sync_annotations = false
            sync.pushPendingAnnotations = function() error("must not push") end

            sync:pushPendingBooks({ ["/books/a.epub"] = { annotations = true } }, nil, report)

            assert.are.same({ "annotations:/books/a.epub" }, reports)
        end)

        it("forgets books that were deleted", function()
            sync.pushBookProgressAndSessions = function() error("must not push") end

            sync:pushPendingBooks({ ["/books/gone.epub"] = { progress = true, annotations = true } }, nil, report)

            table.sort(reports)
            assert.are.same({ "annotations:/books/gone.epub", "progress:/books/gone.epub" }, reports)
        end)

        it("does not push highlights of a book that is not in Grimmory", function()
            sync.repository = { upsertBook = function() return true, 1, nil end }
            sync.associateBook = function() return nil end
            sync.pushBookAnnotations = function() error("must not push") end

            assert.is_true(sync:pushPendingAnnotations("/books/a.epub"))
        end)
    end)

    describe("closing a book", function()
        it("sends its highlights and what earlier syncs left, besides its progress", function()
            local progress, highlights = {}, {}
            sync.pushBookProgressAndSessions = function(_, path) table.insert(progress, path) end
            sync.pushPendingAnnotations = function(_, path)
                table.insert(highlights, path)
                return true
            end

            sync:synchronizeBookProgress("/books/a.epub", report, false, {
                ["/books/a.epub"] = { progress = true, annotations = true },
                ["/books/b.epub"] = { progress = true },
            })

            table.sort(progress)
            -- Its own progress once (not again as a pending one)
            assert.are.same({ "/books/a.epub", "/books/b.epub" }, progress)
            assert.are.same({ "/books/a.epub" }, highlights)
        end)
    end)
end)

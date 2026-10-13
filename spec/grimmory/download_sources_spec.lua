local assert = require 'luassert'
local spy = require 'luassert.spy'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local fake_logger = {
    err = spy.new(function() end),
    warn = spy.new(function() end),
    info = spy.new(function() end),
    dbg = spy.new(function() end),
}

package.preload["grimmory/logger"] = function()
    return { new = function() return fake_logger end }
end

package.preload["gettext"] = function()
    return function(text) return text end
end

package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/tmp" end }
end

-- In-memory settings file
local stored_settings = {}

package.preload["luasettings"] = function()
    return {
        open = function()
            return {
                readSetting = function(_, key) return stored_settings[key] end,
                saveSetting = function(_, key, value) stored_settings[key] = value end,
                flush = function() end,
            }
        end,
    }
end

package.preload["random"] = function()
    return { uuid = function() return "device-uuid" end }
end

package.preload["device"] = function()
    return { model = "Test" }
end

package.preload["readcollection"] = function()
    return {}
end

package.preload["ffi/MD5"] = function()
    return {}
end

package.preload["util"] = function()
    return {}
end

local GrimmorySettings = require("grimmory/settings")
local GrimmorySynchronize = require("grimmory/synchronize")

local function new_settings(data)
    stored_settings = { grimmory = data }
    return GrimmorySettings:new()
end

local function book(fields)
    local result = {
        id = 1,
        shelves = {},
        primary_file = { filename = "book.epub" },
        metadata = {},
    }
    for key, value in pairs(fields or {}) do
        result[key] = value
    end
    return result
end

describe("Download sources", function()
    describe("everything", function()
        it("defaults to everything when no source was ever chosen", function()
            local settings = new_settings({})
            assert.is_true(settings:getDownloadEverything())
        end)

        it("keeps the old single shelf selection as the only source", function()
            local settings = new_settings({ sync_target_shelves = { { id = 3, name = "To read" } } })

            assert.is_false(settings:getDownloadEverything())
            assert.is_true(settings:isDownloadSource("shelves", 3))
        end)

        it("does not switch to everything when the last source is removed", function()
            local settings = new_settings({ sync_target_shelves = { { id = 3, name = "To read" } } })

            settings:setDownloadSource("shelves", { id = 3, name = "To read" }, false)

            assert.is_false(settings:hasDownloadSources())
            assert.is_false(settings:getDownloadEverything())
        end)

        it("does not switch everything off when a source is added", function()
            local settings = new_settings({})

            settings:setDownloadSource("libraries", { id = 1, name = "Books" }, true)

            assert.is_true(settings:getDownloadEverything())
            assert.is_true(settings:isDownloadSource("libraries", 1))
        end)
    end)

    describe("sources", function()
        it("adds and removes sources without duplicates", function()
            local settings = new_settings({ download_everything = false })

            settings:setDownloadSource("series", { name = "Dune" }, true)
            settings:setDownloadSource("series", { name = "Dune" }, true)
            assert.are.equal(1, #settings:getDownloadSources("series"))

            settings:setDownloadSource("series", { name = "Dune" }, false)
            assert.are.equal(0, #settings:getDownloadSources("series"))
        end)

        it("persists sources", function()
            local settings = new_settings({ download_everything = false })
            settings:setDownloadSource("magic_shelves", { id = 9, name = "Unread" }, true)

            local reloaded = GrimmorySettings:new()
            assert.is_true(reloaded:isDownloadSource("magic_shelves", 9))
        end)

        it("remembers books kept from the library browser", function()
            local settings = new_settings({})

            settings:setKeptBook(42, true)
            assert.is_true(settings:isKeptBook(42))

            settings:setKeptBook(42, false)
            assert.is_false(settings:isKeptBook(42))
        end)
    end)

    describe("isTargetBook", function()
        local function synchronizer(data)
            return GrimmorySynchronize:new({ settings = new_settings(data) })
        end

        it("needs a file", function()
            local sync = synchronizer({})
            local without_file = book()
            without_file.primary_file = nil

            assert.is_false(sync:isTargetBook(without_file))
        end)

        it("takes every book when downloading everything", function()
            local sync = synchronizer({ download_everything = true })
            assert.is_true(sync:isTargetBook(book()))
        end)

        it("matches shelves, libraries and series", function()
            local sync = synchronizer({
                download_everything = false,
                sync_target_shelves = { { id = 3, name = "To read" } },
                sync_target_libraries = { { id = 5, name = "Comics" } },
                sync_target_series = { { name = "Dune" } },
            })

            assert.is_true(sync:isTargetBook(book({ shelves = { 7, 3 } })))
            assert.is_true(sync:isTargetBook(book({ library_id = 5 })))
            assert.is_true(sync:isTargetBook(book({ series_name = "Dune" })))
            assert.is_false(sync:isTargetBook(book({ shelves = { 7 }, library_id = 1, series_name = "Other" })))
        end)

        it("keeps books downloaded from the browser", function()
            local sync = synchronizer({ download_everything = false, browser_kept_books = { ["12"] = true } })

            assert.is_true(sync:isTargetBook(book({ id = 12 })))
            assert.is_false(sync:isTargetBook(book({ id = 13 })))
        end)

        it("matches magic shelf books loaded from the server", function()
            local sync = synchronizer({
                download_everything = false,
                sync_target_magic_shelves = { { id = 9, name = "Unread" } },
            })
            sync.api = {
                getAppBookIds = spy.new(function() return true, { 20, 21 } end),
            }

            sync:loadMagicShelfBookIds()

            assert.spy(sync.api.getAppBookIds).was.called(1)
            assert.is_true(sync:isTargetBook(book({ id = 21 })))
            assert.is_false(sync:isTargetBook(book({ id = 22 })))
        end)

        it("stops instead of removing books when a magic shelf cannot be loaded", function()
            local sync = synchronizer({
                download_everything = false,
                sync_target_magic_shelves = { { id = 9, name = "Unread" } },
            })
            sync.api = {
                getAppBookIds = function() return false, "offline" end,
            }

            assert.has_error(function() sync:loadMagicShelfBookIds() end)
        end)
    end)
end)

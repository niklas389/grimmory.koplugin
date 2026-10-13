local assert = require 'luassert'
local spy = require 'luassert.spy'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local fake_logger = {
    err = function() end,
    warn = function() end,
    info = function() end,
    dbg = function() end,
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

-- Files on the "device"
local existing_files = {}

package.preload["util"] = function()
    return {
        makePath = function() end,
        fileExists = function(path) return existing_files[path] == true end,
    }
end

local SmartDownload = require("grimmory/smart_download")
local GrimmorySettings = require("grimmory/settings")
local GrimmorySynchronize = require("grimmory/synchronize")

local function new_settings(data)
    stored_settings = { grimmory = data }
    return GrimmorySettings:new()
end

--- A series with one volume per status, e.g. series("READ", "READING", "UNREAD")
local function series(...)
    local books = {}
    for index, status in ipairs({ ... }) do
        table.insert(books, {
            id = index,
            title = "Volume " .. index,
            series_name = "Saga",
            series_number = index,
            read_status = status,
            primary_file_name = "volume_" .. index .. ".epub",
            primary_file_type = "EPUB",
        })
    end
    return books
end

local function ids(volumes)
    local result = {}
    for _, volume in ipairs(volumes) do
        table.insert(result, volume.id)
    end
    return result
end

local function as_comics(books)
    for _, book in ipairs(books) do
        book.primary_file_type = "CBZ"
        book.primary_file_name = book.primary_file_name:gsub("%.epub$", ".cbz")
    end
    return books
end

describe("Smart download", function()
    describe("selectVolumes", function()
        it("keeps the volume being read and the next book", function()
            local books = series("READ", "READ", "READ", "READ", "READ", "READING",
                "UNREAD", "UNREAD", "UNREAD", "UNREAD")
            assert.are.same({ 6, 7 }, ids(SmartDownload.selectVolumes(books, 1, 3)))
        end)

        it("keeps more comic volumes ahead", function()
            local books = as_comics(series("READ", "READING", "UNREAD", "UNREAD", "UNREAD", "UNREAD"))
            assert.are.same({ 2, 3, 4, 5 }, ids(SmartDownload.selectVolumes(books, 1, 3)))
        end)

        it("starts after the last finished volume when none is being read", function()
            local books = series("READ", "READ", "UNREAD", "UNREAD")
            assert.are.same({ 3 }, ids(SmartDownload.selectVolumes(books, 1, 3)))
        end)

        it("starts at the first volume of a series not started yet", function()
            local books = series("UNREAD", "UNREAD", "UNREAD")
            assert.are.same({ 1, 2 }, ids(SmartDownload.selectVolumes(books, 2, 3)))
        end)

        it("skips finished and abandoned volumes ahead", function()
            local books = series("READING", "READ", "WONT_READ", "UNREAD")
            assert.are.same({ 1, 4 }, ids(SmartDownload.selectVolumes(books, 1, 3)))
        end)

        it("takes the latest volume being read", function()
            local books = series("READING", "READ", "RE_READING", "UNREAD", "UNREAD")
            assert.are.same({ 3, 4 }, ids(SmartDownload.selectVolumes(books, 1, 3)))
        end)

        it("keeps only the volume being read with nothing ahead", function()
            local books = series("READ", "READING", "UNREAD")
            assert.are.same({ 2 }, ids(SmartDownload.selectVolumes(books, 0, 0)))
        end)

        it("has nothing to do for a finished series", function()
            assert.are.same({}, ids(SmartDownload.selectVolumes(series("READ", "READ"), 1, 3)))
        end)

        it("skips volumes without a file", function()
            local books = series("READING", "UNREAD", "UNREAD")
            books[2].primary_file_name = nil
            assert.are.same({ 1, 3 }, ids(SmartDownload.selectVolumes(books, 1, 3)))
        end)
    end)

    describe("isComic", function()
        it("knows comic archives by file type or extension", function()
            assert.is_true(SmartDownload.isComic({ primary_file_type = "CBZ" }))
            assert.is_true(SmartDownload.isComic({ primary_file_type = "cbr" }))
            assert.is_true(SmartDownload.isComic({ primary_file_name = "volume.cb7" }))
            assert.is_false(SmartDownload.isComic({ primary_file_type = "EPUB", primary_file_name = "a.epub" }))
            assert.is_false(SmartDownload.isComic({}))
        end)
    end)

    describe("isInProgress", function()
        it("is in progress while a volume is being read", function()
            assert.is_true(SmartDownload.isInProgress(series("READ", "RE_READING")))
            assert.is_false(SmartDownload.isInProgress(series("READ", "UNREAD")))
        end)
    end)

    describe("isSmartDownloadSeries", function()
        it("handles no series when off", function()
            local settings = new_settings({ smart_download_series = { Saga = true } })
            assert.is_false(settings:isSmartDownloadSeries("Saga", true))
        end)

        it("handles series being read unless excluded", function()
            local settings = new_settings({
                smart_download_mode = "in_progress",
                smart_download_series = { Excluded = false, Chosen = true },
            })
            assert.is_true(settings:isSmartDownloadSeries("Saga", true))
            assert.is_false(settings:isSmartDownloadSeries("Saga", false))
            assert.is_false(settings:isSmartDownloadSeries("Excluded", true))
            assert.is_true(settings:isSmartDownloadSeries("Chosen", false))
        end)

        it("handles only chosen series", function()
            local settings = new_settings({
                smart_download_mode = "chosen",
                smart_download_series = { Chosen = true },
            })
            assert.is_true(settings:isSmartDownloadSeries("Chosen", false))
            assert.is_false(settings:isSmartDownloadSeries("Saga", true))
        end)

        it("defaults to one book and three comic volumes ahead", function()
            local settings = new_settings({})
            assert.are.equal(1, settings:getSmartAheadBooks())
            assert.are.equal(3, settings:getSmartAheadComics())
        end)
    end)

    describe("smartDownload", function()
        local function synchronizer(settings_data, books, in_progress)
            local settings = new_settings(settings_data)
            settings.write = function() end
            settings.getDownloadDirectory = function() return "/books" end

            local sync = GrimmorySynchronize:new({
                settings = settings,
                api = {
                    getAppSeriesInProgress = function() return true, in_progress end,
                    getAppSeriesBooks = function()
                        return true, { items = books, has_next = false }
                    end,
                },
                repository = {
                    findBooksByGrimmoryId = function(_, id)
                        return true, { { book_path = "/books/volume_" .. id .. ".epub" } }
                    end,
                },
            })
            sync.pullBook = spy.new(function(_, book)
                return "/books/" .. book.primary_file.filename
            end)
            return sync
        end

        it("downloads the missing volumes of series being read", function()
            existing_files = { ["/books/volume_2.epub"] = true }
            local sync = synchronizer({ smart_download_mode = "in_progress" },
                series("READ", "READING", "UNREAD", "UNREAD"), { "Saga" })
            local events = {}

            sync:smartDownload(function(event)
                table.insert(events, event)
            end)

            -- Volume 2 is on the device already
            assert.spy(sync.pullBook).was.called(1)
            assert.are.same({
                { state = "smart-download", book_id = 3, book_path = "/books/volume_3.epub", title = "Volume 3" },
            }, events)
            assert.is_true(sync.settings:isKeptBook(3))
        end)

        it("leaves excluded series alone", function()
            existing_files = {}
            local sync = synchronizer({
                smart_download_mode = "in_progress",
                smart_download_series = { Saga = false },
            }, series("READ", "READING", "UNREAD"), { "Saga" })

            sync:smartDownload(function() end)

            assert.spy(sync.pullBook).was_not.called()
        end)

        it("does nothing when off", function()
            existing_files = {}
            local sync = synchronizer({}, series("READING", "UNREAD"), { "Saga" })

            sync:smartDownload(function() end)

            assert.spy(sync.pullBook).was_not.called()
        end)
    end)
end)

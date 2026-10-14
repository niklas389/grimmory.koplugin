local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

-- Other specs may have loaded these with their own fakes
for _, name in ipairs({ "docsettings", "util", "cache", "grimmory/doc_metadata" }) do
    package.loaded[name] = nil
end

local quiet = function() end
package.preload["grimmory/logger"] = function()
    return { new = function() return { err = quiet, warn = quiet, info = quiet, dbg = quiet } end }
end

package.preload["cache"] = function()
    return { new = function() return { get = function() end, insert = function() end } end }
end

package.preload["document/documentregistry"] = function()
    return { hasProvider = function() return false end }
end

package.preload["util"] = function()
    return {
        trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
        splitFilePathName = function(path) return path:match("^(.*/)"), path:match("([^/]+)$") end,
        partialMD5 = function() return "md5" end,
    }
end

-- Fake custom metadata files: path -> { data, flushed }
local custom_files
local book_doc_props

package.preload["docsettings"] = function()
    local DocSettings = {}

    function DocSettings:findCustomMetadataFile(path)
        return custom_files[path] and path .. ".sdr/custom_metadata.lua" or nil
    end

    function DocSettings.openSettingsFile(file)
        local book = file and file:gsub("%.sdr/custom_metadata%.lua$", "")
        local data = book and custom_files[book] or {}
        return {
            data = data,
            readSetting = function(self, key) return self.data[key] end,
            saveSetting = function(self, key, value) self.data[key] = value end,
            flushCustomMetadata = function(self, path) custom_files[path] = self.data end,
        }
    end

    function DocSettings:open()
        return { readSetting = function(_, key) return key == "doc_props" and book_doc_props or nil end }
    end

    function DocSettings.removeSidecarDir() end

    return DocSettings
end

local real_remove = os.remove
local DocMetadata = require("grimmory/doc_metadata")

describe("Book information from Grimmory", function()
    local doc_metadata

    before_each(function()
        custom_files = {}
        book_doc_props = { title = "file title", authors = "File Author", pages = 300 }
        doc_metadata = DocMetadata:new()
        os.remove = function(file) -- luacheck: ignore 122
            custom_files[file:gsub("%.sdr/custom_metadata%.lua$", "")] = nil
            return true
        end
    end)

    after_each(function()
        os.remove = real_remove -- luacheck: ignore 122
    end)

    local metadata = {
        title = "The Ember Throne",
        authors = { "Mara Ellison", "Jonas Berg" },
        series_name = "The Ember Cycle",
        series_number = 3,
        language = "en",
        keywords = { "Fantasy", "Adventure", "Fantasy" },
    }

    it("converts Grimmory metadata into KOReader fields", function()
        assert.are.same({
            title = "The Ember Throne",
            authors = "Mara Ellison\nJonas Berg",
            series = "The Ember Cycle",
            series_index = 3,
            language = "en",
            keywords = "Adventure\nFantasy",
        }, DocMetadata.toCustomProps(metadata))
    end)

    it("writes the book's custom metadata and keeps the file's own values", function()
        local changed = doc_metadata:applyGrimmoryMetadata("/books/a.epub", metadata)

        assert.are.same({ "title", "authors", "series", "series_index", "language", "keywords" }, changed)
        local file = custom_files["/books/a.epub"]
        assert.are.equal("The Ember Throne", file.custom_props.title)
        assert.are.equal("Mara Ellison\nJonas Berg", file.custom_props.authors)
        assert.are.equal(3, file.custom_props.series_index)
        assert.are.same(book_doc_props, file.doc_props)
    end)

    it("does not count values the file already shows", function()
        book_doc_props.title = "The Ember Throne"

        local changed = doc_metadata:applyGrimmoryMetadata("/books/a.epub", metadata)

        assert.are.same({ "authors", "series", "series_index", "language", "keywords" }, changed)
        assert.are.equal("The Ember Throne", custom_files["/books/a.epub"].custom_props.title)
    end)

    it("writes nothing when nothing changed", function()
        doc_metadata:applyGrimmoryMetadata("/books/a.epub", metadata)
        local flushed = custom_files["/books/a.epub"]
        custom_files["/books/a.epub"].marker = true

        local changed = doc_metadata:applyGrimmoryMetadata("/books/a.epub", metadata)

        assert.are.same({}, changed)
        assert.are.equal(flushed, custom_files["/books/a.epub"])
    end)

    it("uses the file's value when Grimmory has none", function()
        doc_metadata:applyGrimmoryMetadata("/books/a.epub", metadata)

        local without_series = {}
        for key, value in pairs(metadata) do
            without_series[key] = value
        end
        without_series.series_name = nil

        local changed = doc_metadata:applyGrimmoryMetadata("/books/a.epub", without_series)

        assert.are.same({ "series", "series_index" }, changed)
        assert.is_nil(custom_files["/books/a.epub"].custom_props.series)
        assert.is_nil(custom_files["/books/a.epub"].custom_props.series_index)
    end)

    it("leaves the description alone when Grimmory did not send it", function()
        custom_files["/books/a.epub"] = { custom_props = { description = "kept" }, doc_props = {} }

        doc_metadata:applyGrimmoryMetadata("/books/a.epub", metadata)

        assert.are.equal("kept", custom_files["/books/a.epub"].custom_props.description)
    end)

    it("removes the custom metadata when Grimmory has nothing", function()
        doc_metadata:applyGrimmoryMetadata("/books/a.epub", metadata)

        doc_metadata:applyGrimmoryMetadata("/books/a.epub", { authors = {}, keywords = {} })

        assert.is_nil(custom_files["/books/a.epub"])
    end)
end)

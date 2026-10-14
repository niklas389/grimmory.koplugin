local Cache = require("cache")
local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local util = require("util")

local GrimmoryLogger = require("grimmory/logger")
local logger = GrimmoryLogger:new()

local function apply_dom_version(settings)
    -- Hack to prevent us from getting a weird message from koreader
    -- There may be another way but this seems to be the simplest
    -- and we only set it if it's not already set.
    settings:saveSetting(
        "cre_dom_version",
        settings:readSetting("cre_dom_version", 20200223)
    )
end

---@class GrimmoryDocMetadata
---@field private props_cache any
---@field private ui any
local DocMetadata = {
    -- Doc setting: percent to jump to when the book is opened (set when the
    -- position came from the server without an exact location)
    OPEN_AT_PERCENT = "grimmory_open_at_percent",
}

function DocMetadata:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function DocMetadata:init()
    self.props_cache = Cache:new({ slots = 1024 })
end

function DocMetadata:purge(path)
    local settings = self:getDocSettings(path)

    if settings ~= nil then
        settings:purge()
    end
end

function DocMetadata:getDocSettings(path, fresh)
    if self.ui and self.ui.document ~= nil and self.ui.document.file ~= nil then
        if self.ui.document.file == path and self.ui.doc_settings then
            if fresh then
                local settings = DocSettings:open(path)

                self.ui.doc_settings.data = settings.data
            end

            return self.ui.doc_settings
        end
    end

    return DocSettings:open(path)
end

function DocMetadata:getDocProps(path)
    local book_md5 = util.partialMD5(path)

    local cache_value = self.props_cache:get(book_md5)
    if cache_value ~= nil then
        logger:dbg("Props Cache Hit", path)
        return cache_value
    end

    local settings = self:getDocSettings(path)

    local props = settings:readSetting("doc_props")

    if props ~= nil then
        self.props_cache:insert(book_md5, props)
        return props
    end

    logger:dbg("Falling back to reading document directly")

    -- If still no book_props, open the document to get them
    local document = DocumentRegistry:hasProvider(path) and DocumentRegistry:openDocument(path)
    if document then
        local loaded = true
        if document.loadDocument then -- CreDocument
            -- load only metadata
            if not document:loadDocument(false) then
                -- failed loading, calling other methods would segfault
                loaded = false
            end
        end

        if loaded then
            props = document:getProps()
        end
        document:close()
    end

    if props ~= nil then
        self.props_cache:insert(book_md5, props)
        return props
    end

    logger:dbg("No props can be found")

    self.props_cache:insert(book_md5, {})
    return {}
end

function DocMetadata:getIdentifiers(path)
    local props = self:getDocProps(path)
    if type(props.identifiers) ~= "string" or props.identifiers == "" then
        return {}
    end

    local identifiers = {}

    for key, value in props.identifiers:gmatch("([^\n]+):([^\n:]+)") do
        identifiers[key:lower()] = value
    end

    return identifiers
end

function DocMetadata:getIdentifier(path, typeOrTypes)
    local identifiers = self:getIdentifiers(path)

    if type(typeOrTypes) ~= "table" then
        typeOrTypes = { typeOrTypes }
    end

    for _, key in ipairs(typeOrTypes) do
        if identifiers[key] then
            return identifiers[key]
        end
    end

    return nil
end

function DocMetadata:getISBN(path)
    return self:getIdentifier(
        path,
        {
            "isbn13",
            "urn:isbn13",
            "isbn10",
            "isbn",
            "urn:isbn",
        }
    )
end

function DocMetadata:getASIN(path)
    return self:getIdentifier(
        path,
        { "amazon", "urn:amazon", "mobi-asin" }
    )
end

-- KOReader's book information fields that Grimmory can set
local CUSTOM_PROP_KEYS = { "title", "authors", "series", "series_index", "language", "keywords", "description" }

local function as_text(value)
    if type(value) == "string" then
        value = util.trim(value)
        return value ~= "" and value or nil
    end
    return nil
end

local function as_lines(values, sorted)
    if type(values) ~= "table" then
        return nil
    end
    local seen, lines = {}, {}
    for _, value in ipairs(values) do
        value = as_text(value)
        if value and not seen[value] then
            seen[value] = true
            table.insert(lines, value)
        end
    end
    if sorted then
        -- Grimmory sends sets in any order
        table.sort(lines)
    end
    return #lines > 0 and table.concat(lines, "\n") or nil
end

--- KOReader custom props from Grimmory metadata.  Keys Grimmory did not
--- send (e.g. the description in list responses) are left out; keys it
--- sent empty are false (use the file's own value).
---@param metadata table title, authors (list), series_name, series_number, language, keywords (list), description
function DocMetadata.toCustomProps(metadata)
    local props = {
        title = as_text(metadata.title) or false,
        authors = as_lines(metadata.authors) or false,
        series = as_text(metadata.series_name) or false,
        language = as_text(metadata.language) or false,
        keywords = as_lines(metadata.keywords, true) or false,
    }
    props.series_index = props.series and tonumber(metadata.series_number) or false
    if metadata.description ~= nil then
        props.description = as_text(metadata.description) or false
    end
    return props
end

--- Show Grimmory's metadata in KOReader: written as the book's custom
--- metadata (as when editing it in Book information), so it overrides the
--- file's own and can be reset there.  Writes only when something changed.
---@return string[] changed The KOReader fields whose shown value changed
function DocMetadata:applyGrimmoryMetadata(path, metadata)
    local wanted = DocMetadata.toCustomProps(metadata)

    local custom_file = DocSettings:findCustomMetadataFile(path)
    local custom_settings = DocSettings.openSettingsFile(custom_file)
    local custom_props = custom_settings:readSetting("custom_props") or {}
    -- The file's own values (kept in the custom metadata file once it exists)
    local original = custom_settings:readSetting("doc_props")
        or self:getDocSettings(path):readSetting("doc_props") or {}

    local written, changed = false, {}
    for _, key in ipairs(CUSTOM_PROP_KEYS) do
        local value = wanted[key]
        if value ~= nil then
            -- false: Grimmory has none, use the file's own value
            value = value or nil
            if custom_props[key] ~= value then
                local shown_before = custom_props[key] or original[key]
                custom_props[key] = value
                written = true
                if (value or original[key]) ~= shown_before then
                    table.insert(changed, key)
                end
            end
        end
    end

    if not written then
        return changed
    end

    if next(custom_props) == nil then
        if custom_file then
            os.remove(custom_file)
            DocSettings.removeSidecarDir(util.splitFilePathName(custom_file))
        end
        return changed
    end

    if not custom_file then
        -- Like KOReader: keep the file's own values, for "reset"
        local copy = {}
        for key, value in pairs(original) do
            if key ~= "display_title" then
                copy[key] = value
            end
        end
        custom_settings:saveSetting("doc_props", copy)
    end

    custom_settings:saveSetting("custom_props", custom_props)
    custom_settings:flushCustomMetadata(path)

    logger:dbg("Book information updated from Grimmory:", path, table.concat(changed, ", "))
    return changed
end

function DocMetadata:getTitle(path)
    return self:getDocProps(path).title
end

function DocMetadata:getAuthor(path)
    return self:getDocProps(path).authors
end

---@param path string
---@param book Book
function DocMetadata:isBook(path, book)
    local isbn = self:getISBN(path)
    local asin = self:getASIN(path)

    if isbn and isbn == book.metadata.isbn10 then
        return true
    end

    if isbn and isbn == book.metadata.isbn13 then
        return true
    end

    if asin and asin == book.metadata.asin then
        return true
    end

    return false
end

---@param path string
function DocMetadata:clearProgress(path)
    local settings = self:getDocSettings(path)

    apply_dom_version(settings)

    settings:delSetting("percent_finished")
    settings:delSetting("last_xpointer")
    settings:delSetting("last_page")

    settings:flush()
end

---@param path string
---@param percent number | nil
---@param xpointer string | nil
---@param page number | nil
function DocMetadata:setProgress(path, percent, xpointer, page)
    local settings = self:getDocSettings(path)

    apply_dom_version(settings)

    if percent ~= nil then
        settings:saveSetting("percent_finished", percent / 100)
    end

    if xpointer ~= nil then
        settings:saveSetting("last_xpointer", xpointer)
    elseif percent ~= nil and page == nil then
        -- Without an exact position KOReader opens a book at its start (it
        -- ignores `percent_finished`, and `last_percent` is applied before
        -- the book is fully laid out).  Jump there once it is open instead.
        settings:saveSetting(DocMetadata.OPEN_AT_PERCENT, percent)
    end

    if page ~= nil then
        settings:saveSetting("last_page", page)
    end

    settings:flush()
end

--- Whether KOReader knows where the book was left (an exact position)
function DocMetadata:hasPosition(path)
    local settings = self:getDocSettings(path)

    return settings:readSetting("last_xpointer") ~= nil
        or settings:readSetting("last_page") ~= nil
        or settings:readSetting(DocMetadata.OPEN_AT_PERCENT) ~= nil
end

function DocMetadata:getAnnotations(path)
    local settings = self:getDocSettings(path)

    return settings:readSetting("annotations") or {}
end

function DocMetadata:setAnnotations(path, annotations)
    local settings = self:getDocSettings(path)

    settings:saveSetting("annotations_externally_modified", true)
    settings:saveSetting("annotations", annotations)

    settings:flush()
end

---@param book_path string
---@return integer[]
function DocMetadata:getModifiedGrimmoryAnnotations(path)
    local settings = self:getDocSettings(path)

    return settings:readSetting("modified_grimmory_annotations") or {}
end

---@param book_path string
---@param grimmory_id integer
function DocMetadata:removeModifiedGrimmoryAnnotation(path, grimmory_id)
    local settings = self:getDocSettings(path)
    local existing_grimmory_ids = settings:readSetting("modified_grimmory_annotations") or {}

    local new_grimmory_ids = {}
    for _, v in ipairs(existing_grimmory_ids) do
        if v ~= grimmory_id then
            table.insert(new_grimmory_ids, v)
        end
    end

    if #new_grimmory_ids == #existing_grimmory_ids then
        -- No change, skip save
        return
    end

    if #new_grimmory_ids == 0 then
        settings:delSetting("modified_grimmory_annotations")
    else
        settings:saveSetting("modified_grimmory_annotations", new_grimmory_ids)
    end

    settings:flush()
end

---@param book_path string
---@param grimmory_id integer
function DocMetadata:appendModifiedGrimmoryAnnotation(path, grimmory_id)
    local settings = self:getDocSettings(path)
    local grimmory_ids = settings:readSetting("modified_grimmory_annotations") or {}

    for _, v in ipairs(grimmory_ids) do
        if v == grimmory_id then
            -- Already exists, skip everything else.
            return
        end
    end

    table.insert(grimmory_ids, grimmory_id)

    settings:saveSetting("modified_grimmory_annotations", grimmory_ids)
    settings:flush()
end

return DocMetadata
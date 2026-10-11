local DocumentRegistry = require("document/documentregistry")

local GrimmoryCFIResolver = require("grimmory/cfi_resolver")
local GrimmoryDateTime = require("grimmory/datetime")
local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()


---@param value integer
---@return string
local function to_annotation_datetime(value)
    if value == nil then
        return nil
    end

    local parsed = os.date("!*t", value)
    return string.format(
        "%04d-%02d-%02d %02d:%02d:%02dZ",
        parsed.year,
        parsed.month,
        parsed.day,
        parsed.hour,
        parsed.min,
        parsed.sec
    )
end

---@param value string
---@return integer | nil timestamp
local function from_annotation_datetime(value)
    if type(value) ~= "string" then
        return nil
    end

    -- Values written by this plugin are UTC with a "Z" suffix, values
    -- written by KOReader itself are local time without a suffix.
    if value:match("Z%s*$") then
        return GrimmoryDateTime.parseUtc(value)
    end

    return GrimmoryDateTime.parseLocal(value)
end

---@param document_path string
---@param callback (fun(resolver: GrimmoryCFIResolver): nil)
---@return boolean resolved whether a resolver could be created and the callback ran
local function with_cfi_resolver(document_path, callback)
    local document = (
        DocumentRegistry:hasProvider(document_path) and
        DocumentRegistry:openDocument(document_path)
    )

    if not document then
        return false
    end

    local resolved = false

    -- CFIs only exist for reflowable (CRE / EPUB) documents
    local loaded = document.loadDocument ~= nil and document.getHTMLFromXPointer ~= nil
    if loaded then
        loaded = document:loadDocument(true)
    end

    if loaded then
        local cfi_resolver = GrimmoryCFIResolver:new(document)

        local ok, err = pcall(callback, cfi_resolver)
        if ok then
            resolved = true
        else
            logger:err("Annotation conversion failed:", document_path, "-", err)
        end
    else
        logger:dbg("Document does not support CFI annotations:", document_path)
    end

    document:close()

    return resolved
end

local KOREADER_COLOR_MAP = {
    yellow = "#FFC107",
    green = "#4ADE80",
    cyan = "#38BDF8",
    pink = "#F472B6",
    orange = "#FB923C",
    red = "#FB523C",
    purple = "#F452FC",
    blue = "#0248F8",
    gray = "#AAAAAA",
    white = "#FAFAFA",
}

local GRIMMORY_COLOR_MAP = {
    ["#FFC107"] = "yellow",
    ["#4ADE80"] = "green",
    ["#38BDF8"] = "cyan",
    ["#F472B6"] = "pink",
    ["#FB923C"] = "orange",
    ["#FB523C"] = "red",
    ["#F452FC"] = "purple",
    ["#0248F8"] = "blue",
    ["#AAAAAA"] = "gray",
    ["#FAFAFA"] = "white",
}

local KOREADER_STYLE_MAP = {
    lighten    = "highlight",
    underscore = "underline",
    strikeout  = "strikethrough",
}

local GRIMMORY_STYLE_MAP = {
    highlight = "lighten",
    underline = "underscore",
    strikethrough = "strikeout",
}

local DEFAULT_KOREADER_COLOR = "yellow"
local DEFAULT_KOREADER_STYLE = "lighten"
local DEFAULT_GRIMMORY_COLOR = KOREADER_COLOR_MAP[DEFAULT_KOREADER_COLOR]
local DEFAULT_GRIMMORY_STYLE = KOREADER_STYLE_MAP[DEFAULT_KOREADER_STYLE]

---@class GrimmoryReadingAnnotations
---@field doc_metadata GrimmoryDocMetadata
local GrimmoryReadingAnnotations = {}

function GrimmoryReadingAnnotations:new(doc_metadata)
    local o = {
        doc_metadata = doc_metadata,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

local function normalize_xpointer(xpointer)
    if xpointer == nil then
        return ""
    end

    -- /p[1]/ -> /p/
    xpointer = xpointer:gsub("%[1%]", "")

    -- /text().0 -> /text()
    xpointer = xpointer:gsub("%.0$", "")

    return xpointer
end

---@param a string
---@param b string
---@return bool
local function is_same_xpointer(a, b)
    return normalize_xpointer(a) == normalize_xpointer(b)
end

---@param local_annotations table[]
---@param remote_annotations table[]
---@param unresolved_grimmory_ids? { [string]: boolean } remote annotations that exist
---       but could not be converted; local copies are kept untouched
local function merge_annotations(local_annotations, remote_annotations, unresolved_grimmory_ids)
    unresolved_grimmory_ids = unresolved_grimmory_ids or {}

    local remote_grimmory_ids = {}
    for _, a in ipairs(remote_annotations) do
        if a.grimmory_id ~= nil then
            remote_grimmory_ids[tostring(a.grimmory_id)] = a
        end
    end

    local local_grimmory_ids = {}
    local new_annotations = {}

    -- Filter out existing records with Grimmory IDs that do not
    -- exist on the Grimmory side anymore.
    for _, a in ipairs(local_annotations) do
        if a.grimmory_id ~= nil then
            local_grimmory_ids[tostring(a.grimmory_id)] = a
        end

        if (
            a.grimmory_id == nil or
            remote_grimmory_ids[tostring(a.grimmory_id)] or
            unresolved_grimmory_ids[tostring(a.grimmory_id)]
        ) then
            table.insert(new_annotations, a)
        end
    end

    for grimmory_id, annotation in pairs(remote_grimmory_ids) do
        if local_grimmory_ids[grimmory_id] == nil then
            local found_annotation = false
            for _, existing_annotation in ipairs(new_annotations) do
                if (
                    existing_annotation.grimmory_id == nil and
                    existing_annotation.pos0 ~= nil and
                    existing_annotation.pos1 ~= nil and
                    is_same_xpointer(existing_annotation.pos0, annotation.pos0) and
                    is_same_xpointer(existing_annotation.pos1, annotation.pos1)
                ) then
                    found_annotation = true

                    -- Just apply, don't think too hard about it.
                    existing_annotation.grimmory_id = annotation.grimmory_id
                    existing_annotation.datetime = annotation.datetime
                    existing_annotation.datetime_updated = annotation.datetime_updated
                    existing_annotation.color = annotation.color
                    existing_annotation.drawer = annotation.drawer
                    existing_annotation.chapter = annotation.chapter
                    existing_annotation.text = annotation.text
                    existing_annotation.page = annotation.page
                    existing_annotation.note = annotation.note
                end
            end

            if not found_annotation then
                -- This is a new annotation and can be added to the table
                table.insert(new_annotations, annotation)
            end
        else
            -- Apply to matching grimmory ID
            local existing_annotation = local_grimmory_ids[grimmory_id]

            existing_annotation.pos0 = annotation.pos0
            existing_annotation.pos1 = annotation.pos1
            existing_annotation.datetime = annotation.datetime
            existing_annotation.datetime_updated = annotation.datetime_updated
            existing_annotation.color = annotation.color
            existing_annotation.drawer = annotation.drawer
            existing_annotation.chapter = annotation.chapter
            existing_annotation.text = annotation.text
            existing_annotation.page = annotation.page
            existing_annotation.note = annotation.note
        end
    end

    -- TODO: Merge overlapping annotations
    -- If there are annotations that overlap exactly, select the "latest"
    -- and delete the older ones
    -- For imperfect overlap, combine and prioritize the later ones.

    return new_annotations
end

---@param book_path string
---@param annotations GrimmoryAnnotation[]
function GrimmoryReadingAnnotations:applyAnnotations(book_path, grimmory_annotations)
    local remote_annotations = {}
    local unresolved_grimmory_ids = {}

    local resolved = with_cfi_resolver(
        book_path,
        function (cfi_resolver)
            for _, annotation in ipairs(grimmory_annotations) do
                local convert_ok, xpointer_start, xpointer_end = false, nil, nil

                if type(annotation.cfi) == "string" then
                    convert_ok, xpointer_start, xpointer_end = pcall(
                        cfi_resolver.cfiRangeToXPointers,
                        cfi_resolver,
                        annotation.cfi
                    )
                end

                if not convert_ok or type(xpointer_start) ~= "string" or type(xpointer_end) ~= "string" then
                    -- Never write an annotation without a position: KOReader
                    -- would treat it as a broken bookmark.
                    logger:warn("Skipping annotation that cannot be resolved:", annotation.id, annotation.cfi)

                    if annotation.id ~= nil then
                        unresolved_grimmory_ids[tostring(annotation.id)] = true
                    end
                else
                    local koreader_annotation = {
                        grimmory_id = annotation.id,

                        datetime = to_annotation_datetime(annotation.created_at),
                        datetime_updated = to_annotation_datetime(annotation.updated_at),

                        color = GRIMMORY_COLOR_MAP[annotation.color] or DEFAULT_KOREADER_COLOR,
                        drawer = GRIMMORY_STYLE_MAP[annotation.style] or DEFAULT_KOREADER_STYLE,

                        chapter = annotation.chapter,
                        text = annotation.text,
                        note = annotation.note,

                        page = xpointer_start,

                        pos0 = xpointer_start,
                        pos1 = xpointer_end,
                    }

                    table.insert(remote_annotations, koreader_annotation)
                end
            end
        end
    )

    if not resolved then
        -- Without a resolver nothing could be converted.  Merging an empty
        -- remote list would delete every synced local annotation.
        logger:warn("Not applying annotations, document could not be resolved:", book_path)
        return
    end

    local local_annotations = self.doc_metadata:getAnnotations(book_path)

    local new_annotations = merge_annotations(local_annotations, remote_annotations, unresolved_grimmory_ids)

    self.doc_metadata:setAnnotations(book_path, new_annotations)
end

---@return GrimmoryAnnotation[] annotations
function GrimmoryReadingAnnotations:getAnnotations(book_path)
    -- Get annotations for book
    local annotations = self.doc_metadata:getAnnotations(book_path)

    local grimmory_annotations = {}

    with_cfi_resolver(
        book_path,
        function(cfi_resolver)
            for local_index, annotation in ipairs(annotations) do
                -- Annotations without pos0 / pos1 are bookmarks; non-string
                -- positions (tables) come from paged documents (PDF/DjVu)
                -- and have no CFI representation.
                local cfi = nil
                if type(annotation.pos0) == "string" and type(annotation.pos1) == "string" then
                    local cfi_ok, cfi_result = pcall(
                        cfi_resolver.xpointerRangeToCFI,
                        cfi_resolver,
                        annotation.pos0,
                        annotation.pos1
                    )

                    if cfi_ok then
                        cfi = cfi_result
                    else
                        logger:warn("Skipping annotation that cannot be converted to CFI:", annotation.pos0, cfi_result)
                    end
                end

                if cfi ~= nil then
                    ---@type GrimmoryAnnotation
                    local grimmory_annotation = {
                        local_index = local_index,
                        id = annotation.grimmory_id,
                        book_id = -1,
                        created_at = from_annotation_datetime(annotation.datetime),
                        updated_at = from_annotation_datetime(annotation.datetime_updated),
                        cfi = cfi,
                        chapter = annotation.chapter,
                        text = annotation.text,
                        note = annotation.note,
                        color = KOREADER_COLOR_MAP[annotation.color] or DEFAULT_GRIMMORY_COLOR,
                        style = KOREADER_STYLE_MAP[annotation.drawer] or DEFAULT_GRIMMORY_STYLE,
                    }

                    table.insert(grimmory_annotations, grimmory_annotation)
                end
            end
        end
    )

    return grimmory_annotations
end

return GrimmoryReadingAnnotations
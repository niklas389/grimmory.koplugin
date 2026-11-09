--[[
Sync: Grimmory shelves as KOReader collections, and which books the download
sources take in.  Methods of GrimmorySynchronize (grimmory/synchronize.lua).
--]]

local ReadCollection = require("readcollection")

local GrimmoryLogger = require("grimmory/logger")
local SyncEvents = require("grimmory/sync/events")

local logger = GrimmoryLogger:new()
local stage = SyncEvents.stage

---@class GrimmorySynchronizeMethods
local GrimmorySynchronize = {}

---@param book Book
---@return boolean
--- Whether the sync should download / keep this book: it is in one of the
--- download sources, or was downloaded from the library browser.
---@param book Book
function GrimmorySynchronize:isTargetBook(book)
    if not book.primary_file or not book.primary_file.filename then
        return false
    end

    if self.settings:getDownloadEverything() or self.settings:isKeptBook(book.id) then
        return true
    end

    if book.library_id and self.settings:isDownloadSource("libraries", book.library_id) then
        return true
    end

    if book.series_name and self.settings:isDownloadSource("series", book.series_name) then
        return true
    end

    for _, shelf_id in ipairs(book.shelves or {}) do
        if self.settings:isDownloadSource("shelves", shelf_id) then
            return true
        end
    end

    if self.magic_shelf_book_ids and self.magic_shelf_book_ids[tostring(book.id)] then
        return true
    end

    return false
end

--- Magic shelves are rule based, so their books are not part of the book
--- data; ask the server which books they contain.
function GrimmorySynchronize:loadMagicShelfBookIds()
    self.magic_shelf_book_ids = {}

    if self.settings:getDownloadEverything() then
        return
    end

    for _, magic_shelf in ipairs(self.settings:getDownloadSources("magic_shelves")) do
        local ok, ids = self.api:getAppBookIds({ magicShelfId = magic_shelf.id })

        if not ok then
            -- Continuing would treat the shelf's books as removed (and might
            -- delete them), so stop the book download instead.
            error("Could not load magic shelf " .. tostring(magic_shelf.name) .. ": " .. tostring(ids))
        end

        for _, id in ipairs(ids) do
            self.magic_shelf_book_ids[tostring(id)] = true
        end
    end
end

function GrimmorySynchronize:synchronizeShelves(callback)
    if not self.settings:getSyncShelves() then
        logger:info("Shelf sync skipped because feature is disabled")
        return
    end

    stage(callback, "shelves")

    local ok, shelves = self.api:getShelves()

    if not ok or type(shelves) == "string" then
        logger:err("Could not connect to Grimmory to get shelves", shelves)
        return
    end

    local shelf_id_to_name = {}
    local shelf_name_to_id = {}
    local shelf_ids = {}

    -- Make sure we have our unique shelf names and ID mappings
    for _, shelf in ipairs(shelves) do
        if shelf.id and shelf.name then
            local shelf_name = shelf.name

            logger:dbg("Shelf received from Grimmory", shelf.id, shelf_name)

            -- If there's a shelf with a duplicate name, we can't support
            -- that in koreader.  Instead, add something to the shelf name
            -- until it's unique.
            local unique_shelf_name = shelf_name
            local unique_shelf_index = 0
            while shelf_name_to_id[unique_shelf_name:lower()] do
                unique_shelf_index = unique_shelf_index + 1
                unique_shelf_name = shelf_name .. " (" .. unique_shelf_index .. ")"
            end

            if unique_shelf_name ~= shelf_name then
                logger:dbg("Duplicate shelf name found", shelf_name, "- used new name", unique_shelf_name)
            end

            shelf_name_to_id[unique_shelf_name:lower()] = shelf.id

            -- use tostring to get a sparse table
            shelf_id_to_name[tostring(shelf.id)] = unique_shelf_name
            shelf_ids[tostring(shelf.id)] = shelf.id
        end
    end

    -- Snapshot names first: renaming a collection adds a key to
    -- `ReadCollection.coll`, which is undefined behaviour inside `pairs()`.
    local collection_names = {}
    for collection_name, _ in pairs(ReadCollection.coll) do
        table.insert(collection_names, collection_name)
    end

    -- Read through existing collections and compare against shelves
    for _, collection_name in ipairs(collection_names) do
        local collection_settings = ReadCollection.coll_settings[collection_name] or {}
        ReadCollection.coll_settings[collection_name] = collection_settings

        local shelf_id = collection_settings.connectorId

        if shelf_id then
            if shelf_id_to_name[tostring(shelf_id)] then
                local shelf_name = shelf_id_to_name[tostring(shelf_id)]

                -- This collection exists as a shelf so we should update it
                -- if there's anything that needs to change.
                if shelf_name:lower() ~= collection_name:lower() then
                    -- This collection has been renamed!
                    logger:info("Renaming collection to match shelf name:", collection_name, ";", shelf_name)

                    ReadCollection:renameCollection(collection_name, shelf_name)
                    collection_name = shelf_name

                    callback({
                        state = "shelf-rename",
                        shelf_id = shelf_id,
                        shelf_name = shelf_name,
                    })
                end
            else
                logger:info("Disconnecting collection from shelf:", collection_name)
                -- This was a shelf but the shelf is gone in the connector
                -- Don't delete the shelf but break the connection.
                collection_settings.connectorId = nil

                callback({
                    state = "shelf-disconnect",
                    shelf_id = shelf_id,
                    shelf_name = collection_name,
                })

                -- Set the shelf ID to nil so the block below will pick
                -- it up if it's a shelf being deleted and recreated
                shelf_id = nil
            end
        end

        if shelf_id == nil and shelf_name_to_id[collection_name:lower()] then
            -- If there is no shelf attached to this collection but we
            -- know one exists we should attach it.
            shelf_id = shelf_name_to_id[collection_name:lower()]

            logger:info(
                "Found an existing collection that can be attached to a shelf:",
                collection_name, ";" , shelf_id
            )

            ReadCollection.coll_settings[collection_name].connectorId = shelf_id

            callback({
                state = "shelf-connect",
                shelf_id = shelf_id,
                shelf_name = collection_name,
            })
        end
    end

    -- Shelves that already have a connected collection (by ID, independent
    -- of the collection name's case)
    local connected_shelves = {}
    for collection_name, _ in pairs(ReadCollection.coll) do
        local collection_settings = ReadCollection.coll_settings[collection_name]
        if collection_settings and collection_settings.connectorId ~= nil then
            connected_shelves[tostring(collection_settings.connectorId)] = true
        end
    end

    -- Make sure every shelf has a collection and create them if not
    for shelf_key, shelf_name in pairs(shelf_id_to_name) do
        local shelf_id = shelf_ids[shelf_key]

        if not connected_shelves[shelf_key] and not ReadCollection.coll_settings[shelf_name] then
            logger:info("Adding a collection from a shelf", shelf_name, shelf_id)

            ReadCollection:addCollection(shelf_name)
            ReadCollection.coll_settings[shelf_name].connectorId = shelf_id

            callback({
                state = "shelf-add",
                shelf_id = shelf_id,
                shelf_name = shelf_name,
            })
        end
    end

    -- Persist collections to the database now that we've finished our sync
    ReadCollection:write()
end

function GrimmorySynchronize:removeEmptyShelves(callback)
    if self.settings:getSyncRetainEmptyShelves() then
        logger:info("Shelf clean up sync skipped because feature is disabled")
        return
    end

    local collection_names = {}
    for collection_name, _ in pairs(ReadCollection.coll) do
        table.insert(collection_names, collection_name)
    end

    -- Read through existing collections and compare against shelves
    for _, collection_name in ipairs(collection_names) do
        local collection_settings = ReadCollection.coll_settings[collection_name] or {}
        local shelf_id = collection_settings.connectorId
        local books = ReadCollection:getOrderedCollection(collection_name)

        if shelf_id and #books == 0 then
            -- This is a grimmory shelf and is empty
            logger:info("Removing empty shelf:", collection_name)

            callback({
                state = "shelf-remove",
                shelf_id = shelf_id,
                shelf_name = collection_name,
            })

            ReadCollection:removeCollection(collection_name)
        end
    end

    -- Persist collections to the database now that we've finished our sync
    ReadCollection:write()
end

---@param book_path string
---@param shelves integer[]
function GrimmorySynchronize:associateWithShelves(book_path, shelves)
    local local_shelves = {}
    local shelf_id_to_name = {}
    for collection_name, _ in pairs(ReadCollection.coll) do
        local collection_settings = ReadCollection.coll_settings[collection_name] or {}
        local shelf_id = collection_settings.connectorId

        if shelf_id then
            shelf_id_to_name[tostring(shelf_id)] = collection_name

            if ReadCollection.coll[collection_name][book_path] ~= nil then
                local_shelves[collection_name] = true
            end
        end
    end

    local remote_shelves = {}
    for _, shelf_id in ipairs(shelves) do
        local collection_name = shelf_id_to_name[tostring(shelf_id)]

        if collection_name then
            remote_shelves[collection_name] = true

            if not local_shelves[collection_name] then
                logger:dbg("Adding book to collection:", book_path, collection_name)
                ReadCollection:addItem(book_path, collection_name)
            end
        end
    end

    -- Remove any current collections that are not current shelves.
    for collection_name, _ in pairs(local_shelves) do
        if not remote_shelves[collection_name] then
            logger:dbg("Removing book from collection:", book_path, collection_name)
            ReadCollection:removeItem(book_path, collection_name)
        end
    end
end

return GrimmorySynchronize

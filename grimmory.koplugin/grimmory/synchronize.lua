local ReadCollection = require("readcollection")
local md5 = require("ffi/MD5")
local util = require("util")

local GrimmoryLogger = require("grimmory/logger")
local SmartDownload = require("grimmory/smart_download")

local logger = GrimmoryLogger:new()

--- Tell the UI what the sync is doing (shown in the progress sheet): a step
--- of the sync, and where it is in it (e.g. book 3 of 6, and its title).
---@param name string push | highlights | shelves | check | update | download | cleanup | book-info |
---  smart-check | smart-download | book-info-one | book-highlights | book-progress
local function stage(callback, name, current, total, title)
    callback({ state = "stage", stage = name, current = current, total = total, title = title })
end

--- Report a download's progress (throttled by the API) to the UI.
local function downloadProgress(callback)
    return function(bytes, total)
        callback({ state = "download-progress", bytes = bytes, total = total })
    end
end

---@param book Book
local function bookTitle(book)
    return (book.metadata and book.metadata.title)
        or (book.primary_file and book.primary_file.filename)
        or tostring(book.id)
end

---@class GrimmorySynchronize
---@field repository GrimmoryLocalRepository
---@field reading_annotations GrimmoryReadingAnnotations
---@field reading_progress_manager ReadingProgressManager
---@field settings GrimmorySettings
---@field api GrimmoryAPI
---@field doc_metadata GrimmoryDocMetadata
local GrimmorySynchronize = {}

function GrimmorySynchronize:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

---@param book_id integer
---@param callback function
function GrimmorySynchronize:pushBookProgress(book_id, callback)
    if not self.settings:getSyncReadingProgress() then
        logger:info("Reading progress skipped because feature is disabled for:", book_id)
        return
    end

    local progress_ok, progress = self.repository:getReadingProgress(book_id)

    if not progress_ok or progress == nil then
        logger:dbg("No local reading progress for book:", book_id)
        return
    end

    local sync_status_ok, last_synced_at = self.repository:getBookSyncTimestamp(book_id, "progress")

    if not sync_status_ok then
        logger:err("Unable to get sync status for book, not blindly syncing:", book_id)
        return
    end

    if last_synced_at ~= nil and last_synced_at >= progress.end_time then
        logger:dbg("Book progress already synced, skipping:", book_id, "-", last_synced_at)
        return
    end

    logger:info("Synchronizing reading progress for:", book_id, ";", last_synced_at, "->", progress.end_time)
    local ok = self.reading_progress_manager:pushRemoteProgress(progress)

    if ok then
        callback({
            state = "progress-pushed",
            book_path = progress.book_path,
            book_md5 = progress.book_md5,
        })

        self.repository:updateBookSyncTimestamp(book_id, "progress", progress.end_time)
    else
        callback({
            state = "progress-failed",
            book_path = progress.book_path,
            book_md5 = progress.book_md5,
        })
    end
end

---@param book_id integer
---@param callback function
function GrimmorySynchronize:pushBookSessions(book_id, callback)
    if not self.settings:getSyncReadingSessions() then
        -- Since the reading session sync is disabled, skip them.
        logger:dbg("Reading sessions skipped because feature is disabled for:", book_id)
        return
    end

    local threshold_pages = self.settings:getSessionThresholdPages()
    local threshold_seconds = self.settings:getSessionThresholdSeconds()

    logger:info("Synchronizing reading sessions for:", book_id)

    local sessions = self.repository:getPendingSessions(book_id)

    for _, session in ipairs(sessions) do
        local total_seconds = session.end_time - session.start_time
        local total_pages = session.end_page - session.start_page + 1

        if total_seconds < threshold_seconds then
            logger:info("Skipped session below time threshold for book", book_id)
            callback({
                state = "session-skip",
                bookPath = session.book_path,
                since = session.end_time,
            })

        elseif total_pages < threshold_pages then
            logger:info("Skipped session below page threshold for book", book_id)
            callback({
                state = "session-skip",
                bookPath = session.book_path,
                since = session.end_time,
            })

        elseif session.grimmory_id == nil then
            logger:err("Session failed recording with error for book: ", book_id, " - ", "No Grimmory ID")
            callback({
                state = "session-error",
                bookPath = session.book_path,
            })

            -- If an error happens for this session we bail early so
            -- retries can happen again later
            break
        else
            logger:dbg(
                "Recording session",
                session.grimmory_id,
                session.book_path,
                session.start_time,
                session.end_time,
                session.start_progress,
                session.end_progress,
                session.start_page,
                session.end_page
            )

            local ok, body = self.api:recordSession(
                session.grimmory_id,
                session.start_time,
                session.end_time,
                session.start_progress,
                session.end_progress,
                tostring(session.start_page),
                tostring(session.end_page)
            )

            if ok then
                logger:info("Session recorded successfully for book:", book_id)
                callback({
                    state = "session-recorded",
                    bookPath = session.book_path,
                    since = session.end_time,
                })

                self.repository:updateBookSyncTimestamp(book_id, "sessions", session.end_time)
            else
                logger:err("Session failed recording with error for book: ", book_id, " - ", body)
                callback({
                    state = "session-error",
                    bookPath = session.book_path,
                    since = session.end_time,
                })

                -- If an error happens for this session we bail early so
                -- retries can happen again later
                break
            end
        end
    end
end

---@param book_path string
---@param book_grimmory_id integer
---@return { sent: integer, deleted: integer, failed: integer } counts
function GrimmorySynchronize:pushBookAnnotations(book_path, book_grimmory_id)
    local counts = { sent = 0, deleted = 0, failed = 0 }
    local local_annotations = self.reading_annotations:getAnnotations(book_path)

    local modified_grimmory_annotations = self.doc_metadata:getModifiedGrimmoryAnnotations(book_path)

    local is_modified_by_id = {}
    for _, modified_id in ipairs(modified_grimmory_annotations) do
        is_modified_by_id[tostring(modified_id)] = true

        logger:dbg("Deleting annotation frim Grimmory:", book_path, "-", modified_id)
        self.api:deleteAnnotation(modified_id)

        -- Even if the delete fails - which it does today with a 5xx instead of 404 - we
        -- should continue to remove the annotation and assume it's just gone.
        --
        -- Once this bug (grimmory-tools/grimmory#1858) is fixed we can add the check
        -- back in for the `ok` of `deleteAnnotation` calls.
        self.doc_metadata:removeModifiedGrimmoryAnnotation(book_path, modified_id)
        counts.deleted = counts.deleted + 1
    end

    ---@type { [integer]: integer }
    local created_ids_by_local_index = {}
    local created_any = false

    for _, annotation in ipairs(local_annotations) do
        if annotation.id ~= nil and is_modified_by_id[tostring(annotation.id)] then
            annotation.id = nil
        end

        if annotation.id == nil and annotation.cfi == nil then
            logger:warn("Skipping annotation without CFI:", book_path)
        elseif annotation.id == nil then
            -- This is a "new" annotation.
            local create_ok, remote_annotation = self.api:createAnnotation(
                book_grimmory_id,
                annotation.cfi,
                annotation.chapter,
                annotation.text,
                annotation.color,
                annotation.style,
                annotation.note
            )

            if create_ok then
                logger:dbg("Created annotation for book:", book_path)
                counts.sent = counts.sent + 1

                local remote_id = type(remote_annotation) == "table" and tonumber(remote_annotation.id) or nil
                if remote_id and annotation.local_index then
                    created_ids_by_local_index[annotation.local_index] = remote_id
                    created_any = true
                end
            else
                logger:err("Failed to push annotation", remote_annotation)
                counts.failed = counts.failed + 1
            end
        end
    end

    if created_any then
        -- Link the local annotations to what was just created, so they are
        -- matched by ID (not only by position) and never pushed twice.
        local doc_annotations = self.doc_metadata:getAnnotations(book_path)

        for local_index, remote_id in pairs(created_ids_by_local_index) do
            if doc_annotations[local_index] ~= nil then
                doc_annotations[local_index].grimmory_id = remote_id
            end
        end

        self.doc_metadata:setAnnotations(book_path, doc_annotations)
    end

    return counts
end

---@param book_path string
---@param book_grimmory_id integer
---@return { added: integer, updated: integer, removed: integer } | nil counts
function GrimmorySynchronize:pullBookAnnotations(book_path, book_grimmory_id)
    local annotations_ok, annotations = self.api:getAnnotations(book_grimmory_id)

    if not annotations_ok or annotations == nil then
        logger:err("Failed pulling annotations from Grimmory:", book_grimmory_id)
        return
    end

    logger:dbg("Writing annotations to:", book_path)

    return self.reading_annotations:applyAnnotations(
        book_path,
        annotations
    )
end

---@param book_id integer
---@param callback function
function GrimmorySynchronize:pushBookMetadata(book_id, callback)
    self:pushBookProgress(book_id, callback)
    self:pushBookSessions(book_id, callback)
end

function GrimmorySynchronize:pushAllPendingBookMetadata(callback)
    local book_ids = self.repository:getBooksPendingSync(
        self.settings:getSyncReadingSessions(),
        self.settings:getSyncReadingProgress()
    )

    for index, book_id in ipairs(book_ids) do
        if book_id == nil then
            break
        end

        stage(callback, "push", index, #book_ids)
        pcall(self.pushBookMetadata, self, book_id, callback)

        callback({
            state = "book-push-metadata",
            book_id = book_id,
            pushed_books = index,
            total_books = #book_ids,
        })

    end
end

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

---@return number | nil percent The position taken over from Grimmory, if any
---@param server_progress GrimmoryServerProgress | nil From the book list, if known
function GrimmorySynchronize:pullBookProgress(book_path, server_progress)
    if not self.settings:getSyncReadingProgress() then
        return nil
    end

    local ui = self.reading_progress_manager.ui
    if ui and ui.document and ui.document.file == book_path then
        -- This runs in the sync subprocess, where navigating the open
        -- document has no effect.  The open book is handled in the
        -- foreground by the "Go to latest location" confirmation.
        logger:dbg("Skipping progress pull for open book:", book_path)
        return nil
    end

    -- Only adopt remote progress when it is newer than what was recorded
    -- locally, otherwise local reading that has not been pushed yet (e.g.
    -- a failed push) would be overwritten by older remote progress.
    local _, _, progress = self.reading_progress_manager:getNewerProgressForBook(
        book_path, server_progress and server_progress.koreader_percent)

    if progress then
        self.reading_progress_manager:applyProgress(progress)
        return tonumber(progress.end_progress) or 0
    end

    return nil
end

function GrimmorySynchronize:downloadBook(book_id, download_path, on_progress, size_kb)
    local success, result, message = pcall(function()
        return self.api:downloadBook(book_id, download_path, on_progress, size_kb)
    end)

    if not success then
        logger:err("Book download failed:", book_id, " - ", result)
        return false, result
    end

    if not result then
        return false, message
    end

    return true, nil
end

---@param book Book
---@return string download_path
function GrimmorySynchronize:getBookDownloadPath(book)
    local existing_book_ok, existing_books = self.repository:findBooksByGrimmoryId(book.id)
    if existing_book_ok then
        for _, local_book in ipairs(existing_books) do
            if (
                util.fileExists(local_book.book_path) and
                util.partialMD5(local_book.book_path) == local_book.book_md5
            ) then
                return local_book.book_path
            end
        end
    end

    local download_directory = self.settings:getDownloadDirectory()

    if not download_directory or download_directory == "" then
        error("Download directory is invalid")
    end

    if book.primary_file then
        local download_path = download_directory .. "/" .. util.getSafeFilename(book.primary_file.filename)

        -- If this path doesn't exist yet, we're good, bail early
        if not util.fileExists(download_path) then
            return download_path
        end

        -- If the path exists we have to check to make sure that it is actually the book we care about
        if self.doc_metadata:isBook(download_path, book) then
            -- We have a match, this path is safe.
            return download_path
        end
    end

    -- At this point we need a fallback name.  `downloaded-${BOOK_ID}.${EXT}` is not
    -- great but I don't know a better safe way off hand.

    local file_extension = nil

    if book.primary_file ~= nil then
        file_extension = util.getFileNameSuffix(book.primary_file.filename)
    end

    if file_extension == "" or file_extension == nil then
        file_extension = "bin"
    end

    local download_path = download_directory .. "/downloaded-" .. tonumber(book.id) .. "." .. file_extension

    -- If this path doesn't exist yet, we're good?
    if not util.fileExists(download_path) then
        return download_path
    end

    -- Okay, this file exists.  It's GOT to be our file, though, right?
    if self.doc_metadata:isBook(download_path, book) then
        -- We have a match, this path is safe.
        return download_path
    end

    -- Give up.
    logger:warn("Could not verify book, but proceeding anyway with path:", book.id, "at", download_path)
    return download_path
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

---@param book_path string
---@return integer | nil grimmory_id
function GrimmorySynchronize:associateBook(book_path)
    for book in self.api:getBooks() do
        if self.doc_metadata:isBook(book_path, book) then
            local ok = self.repository:upsertBook(book_path, book.id)

            if not ok then
                logger:err("Failed to write book association:", book_path)
                return nil
            end

            return book.id
        end
    end

    return nil
end

---@param book_path string
---@param grimmory_id number
function GrimmorySynchronize:refreshBook(book_path, book_id, grimmory_id)
    local temp_path = book_path .. ".tmp"

    -- Download book to temp path
    local download_ok, download_message = self:downloadBook(grimmory_id, temp_path)
    if not download_ok then
        util.removeFile(temp_path)
        return false, download_message
    end

    local temp_md5 = md5.sumFile(temp_path)
    local book_md5 = md5.sumFile(book_path)

    if temp_md5 == book_md5 then
        -- Things were completely the same so we can delete the temp file
        logger:info("File is identical with Grimmory:", book_path, "-", temp_md5)
        util.removeFile(temp_path)
        return true, book_id, false
    end

    local temp_partial_md5 = util.partialMD5(temp_path)
    local book_partial_md5 = util.partialMD5(book_path)


    local backup_path = book_path .. ".bak"

    if util.fileExists(backup_path) then
        logger:dbg("Cleaning up existing backup file")
        util.removeFile(backup_path)
    end

    local finalize_ok, finalize_message = pcall(function()
        local backup_ok, backup_message = os.rename(book_path, backup_path)

        if not backup_ok then
            error(backup_message)
        end

        local move_ok, move_message = os.rename(temp_path, book_path)

        if not move_ok then
            error(move_message)
        end

        if temp_partial_md5 == book_partial_md5 then
            logger:dbg("Partial md5 is a match, no database changes needed")
        else
            logger:info("Partial MD5 is a mismatch so we need to rewrite database")
            -- Update session data from old_book_id to new_book_id
            local update_book_ok, update_book_message = self.repository:updateBook(book_id, temp_partial_md5)

            if not update_book_ok then
                error(update_book_message)
            end
        end
    end)

    if not finalize_ok then
        if util.fileExists(backup_path) then
            logger:dbg("Rolling back: Renaming", backup_path, "to", book_path)
            os.rename(backup_path, book_path)
        end

        util.removeFile(backup_path)
        util.removeFile(temp_path)

        logger:err("Failed to replace files:", book_path, finalize_message)
        return false, finalize_message
    end

    logger:dbg("Cleaning up files from rename")
    util.removeFile(backup_path)
    util.removeFile(temp_path)

    return true, book_id, true
end

---@param book Book
---@return string download_path
---@return boolean is_downloaded
---@param known_download_path string | nil getBookDownloadPath(book), if already known
function GrimmorySynchronize:pullBook(book, on_download_progress, known_download_path)
    local book_exists = false
    local is_downloaded = false

    local download_path = known_download_path or self:getBookDownloadPath(book)

    -- TODO: Search through known books from collections for this book
    --       If found, set the `download path to that value.

    if download_path ~= nil and util.fileExists(download_path) then
        book_exists = true
    end

    if not book_exists then
        if download_path ~= nil then
            is_downloaded = true

            logger:dbg("Downloading book", book.id, "to", download_path)

            local ok, message = self:downloadBook(book.id, download_path, on_download_progress, book.file_size_kb)
            if ok then
                logger:info("Book downloaded:", book.id, " - ", download_path)
                book_exists = true
            else
                error(message)
            end
        else
            error("Download path could not be found")
        end
    end

    if book_exists and download_path then
        self.repository:upsertBook(download_path, book.id)

        -- After we're done, if the book exists we should attach it
        -- to associated shelves and pull the book progress.
        self:associateWithShelves(download_path, book.shelves or {})
        self:pullBookProgress(download_path, book.server_progress)

        if is_downloaded then
            self:applyServerProgress(download_path, book.server_progress)
        end
    end

    return download_path, is_downloaded
end

--- Open a newly downloaded book where it was left on the server, when the
--- KOReader sync had no position for it (e.g. read in Grimmory's reader).
---@param server_progress GrimmoryServerProgress | nil
function GrimmorySynchronize:applyServerProgress(book_path, server_progress)
    if not server_progress or not self.settings:getSyncReadingProgress() then
        return
    end

    if self.doc_metadata:hasPosition(book_path) then
        return
    end

    logger:info("Applying server reading progress:", book_path, server_progress.percent, server_progress.page)
    self.doc_metadata:setProgress(book_path, server_progress.percent, nil, server_progress.page)
end

--- Download one book chosen in the library browser.  Runs in the sync
--- subprocess; collections are written so the main process can reload them.
---@param grimmory_id number
---@param on_progress function(bytes: number, total: number|nil) | nil
---@return string book_path
function GrimmorySynchronize:downloadLibraryBook(grimmory_id, on_progress)
    local download_directory = self.settings:getDownloadDirectory()
    if not download_directory or download_directory == "" then
        error("Download directory is not set")
    end

    local directory_exists, directory_error_message = util.makePath(download_directory)
    if not directory_exists then
        error("Failed to create download directory: " .. tostring(directory_error_message))
    end

    local ok, detail = self.api:getAppBookDetail(grimmory_id)
    if not ok then
        error("Could not load book: " .. tostring(detail))
    end

    if not detail.primary_file_name then
        error("Book has no file to download")
    end

    ---@type Book
    local book = {
        id = detail.id,
        library_id = detail.library_id,
        series_name = detail.series_name,
        shelves = detail.shelves or {},
        metadata = {
            title = detail.title,
            isbn13 = detail.isbn13,
        },
        primary_file = { filename = detail.primary_file_name },
        server_progress = detail.server_progress,
        file_size_kb = detail.file_size_kb,
    }

    local book_path = self:pullBook(book, on_progress)
    ReadCollection:write()

    return book_path
end

-- Smart download loads at most this many pages of a list (50 per page)
local MAX_PAGES = 20

--- All volumes of a series, in series order
---@return boolean ok
---@return LibraryBook[] | string books
function GrimmorySynchronize:loadSeriesBooks(series_name)
    local books = {}

    for page = 0, MAX_PAGES - 1 do
        local ok, result = self.api:getAppSeriesBooks(series_name, page, 50)
        if not ok then
            return false, result
        end
        for _, book in ipairs(result.items) do
            table.insert(books, book)
        end
        if not result.has_next then
            break
        end
    end

    return true, books
end

---@return boolean on_device
function GrimmorySynchronize:isOnDevice(grimmory_id)
    local ok, local_books = self.repository:findBooksByGrimmoryId(grimmory_id)
    if ok then
        for _, local_book in ipairs(local_books) do
            if util.fileExists(local_book.book_path) then
                return true
            end
        end
    end
    return false
end

--- Smart download: make sure the volume being read and the next unread
--- volumes of the handled series are on the device.  Volumes downloaded
--- this way are kept (reported as "smart-download" so the UI process
--- remembers them).
---@param only_series string | nil Only this series (e.g. of a closed book)
function GrimmorySynchronize:smartDownload(callback, only_series)
    if self.settings:getSmartDownloadMode() == "off" then
        return
    end

    local download_directory = self.settings:getDownloadDirectory()
    if not download_directory or download_directory == "" then
        logger:err("Smart download skipped because download directory is not set")
        return
    end
    util.makePath(download_directory)

    local names = {}
    local seen = {}
    local function add(name)
        if name and not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end

    if only_series then
        add(only_series)
    else
        if self.settings:getSmartDownloadMode() == "in_progress" then
            local ok, in_progress = self.api:getAppSeriesInProgress()
            if not ok then
                logger:err("Smart download: could not load series in progress:", in_progress)
                return
            end
            for _, name in ipairs(in_progress) do
                add(name)
            end
        end
        for _, name in ipairs(self.settings:getChosenSmartDownloadSeries()) do
            add(name)
        end
    end

    local ahead_books = self.settings:getSmartAheadBooks()
    local ahead_comics = self.settings:getSmartAheadComics()

    -- First what is missing in all series (so downloads can count "1 of 3")
    local missing = {}
    local seen_ids = {}
    for index, series_name in ipairs(names) do
        stage(callback, "smart-check", index, #names, series_name)
        local ok, books = self:loadSeriesBooks(series_name)

        if not ok then
            logger:err("Smart download: could not load series", series_name, books)
        elseif self.settings:isSmartDownloadSeries(series_name, SmartDownload.isInProgress(books)) then
            local volumes = SmartDownload.selectVolumes(books, ahead_books, ahead_comics)
            logger:info("Smart download:", series_name, "- volumes:",
                SmartDownload.describe(SmartDownload.sortVolumes(books)),
                "- to keep:", SmartDownload.describe(volumes))
            for _, volume in ipairs(volumes) do
                if not seen_ids[volume.id] and not self:isOnDevice(volume.id) then
                    seen_ids[volume.id] = true
                    table.insert(missing, volume)
                end
            end
        end
    end

    for index, volume in ipairs(missing) do
        stage(callback, "smart-download", index, #missing, volume.title)
        self:smartDownloadVolume(volume, callback)
    end
end

---@param volume LibraryBook
function GrimmorySynchronize:smartDownloadVolume(volume, callback)
    logger:info("Smart download:", volume.series_name, volume.series_number, volume.title)

    ---@type Book
    local book = {
        id = volume.id,
        library_id = volume.library_id,
        series_name = volume.series_name,
        -- The next full sync puts it on its Grimmory shelves
        shelves = {},
        metadata = { title = volume.title },
        primary_file = { filename = volume.primary_file_name },
        file_size_kb = volume.file_size_kb,
        server_progress = volume.read_progress and { percent = volume.read_progress } or nil,
    }

    local ok, book_path = pcall(self.pullBook, self, book, downloadProgress(callback))

    if not ok then
        logger:err("Smart download failed:", volume.id, book_path)
        callback({ state = "book-error", book_id = volume.id, message = book_path })
        return
    end

    -- Protect it from the clean up of this sync, too
    self.settings:setKeptBook(volume.id, true, true)

    callback({
        state = "smart-download",
        book_id = volume.id,
        book_path = book_path,
        title = volume.title,
    })
end

--- Smart download for the series of a (just closed) book
function GrimmorySynchronize:smartDownloadForBook(book_path, callback)
    if self.settings:getSmartDownloadMode() == "off" then
        return
    end

    local book_ok, _, grimmory_id = self.repository:upsertBook(book_path)
    if not book_ok or not grimmory_id then
        return
    end

    local ok, detail = self.api:getAppBookDetail(grimmory_id)
    if not ok or not detail.series_name then
        return
    end

    self:smartDownload(callback, detail.series_name)
end

---@param book_path string
function GrimmorySynchronize:removeBook(book_path)
    logger:info("Removing book at:", book_path)

    -- Remove book file
    local ok = util.removeFile(book_path)

    if not ok then
        logger:err("Failed to remove file at:", book_path)
        return
    end

    -- Remove from all collections (skip writes)
    ReadCollection:removeItem(book_path, nil, true)

    -- Remove sidecar
    self.doc_metadata:purge(book_path)
end

function GrimmorySynchronize:pullBooks(callback)
    if not self.settings:getDownloadsBooks() then
        logger:info("Book download skipped because feature is disabled")
        return
    end

    local download_directory = self.settings:getDownloadDirectory()
    if not download_directory or download_directory == "" then
        logger:err("Book download skipped because download directory is not set")
        return
    end

    -- Ensure that the download directory exists
    local directory_exists, directory_error_message = util.makePath(download_directory)
    if not directory_exists then
        logger:err("Failed to create download directory", directory_error_message)
        error("Failed to create download directory: " .. tostring(directory_error_message))
    end

    self:loadMagicShelfBookIds()

    local seen_books = {}
    local seen_grimmory_ids = {}

    local sync_book_info = self.settings:getSyncBookInfo()

    -- First the whole list: which books to keep, and which of them are not
    -- on the device yet (so downloads can count "3 of 6")
    local on_device = {}
    local to_download = {}
    for book, element_count, total_books in self.api:getBooks() do
        stage(callback, "check", element_count, total_books)

        if self:isTargetBook(book) then
            seen_grimmory_ids[tostring(book.id)] = true

            -- (pullBook reports a failure here, e.g. no download folder)
            local path_ok, download_path = pcall(self.getBookDownloadPath, self, book)
            local entry = { book = book, path = path_ok and download_path or nil }
            if entry.path and util.fileExists(entry.path) then
                table.insert(on_device, entry)
            else
                table.insert(to_download, entry)
            end
        elseif sync_book_info then
            -- Not downloaded by the sync, but on the device (e.g. linked)
            for _, path in ipairs(self:getLocalPaths(book.id)) do
                self:applyBookInfo(path, book.metadata, callback)
            end
        end
    end

    local total = #on_device + #to_download
    local done = 0

    local function pull(entry, on_download_progress)
        local book = entry.book
        done = done + 1
        local pull_ok, pull_path_or_message, is_downloaded = pcall(
            self.pullBook, self, book, on_download_progress, entry.path)
        if pull_ok then
            seen_books[pull_path_or_message] = true

            if sync_book_info then
                self:applyBookInfo(pull_path_or_message, book.metadata, callback)
            end

            callback({
                state = is_downloaded and "book-downloaded" or "book-pull-metadata",
                book_id = book.id,
                book_path = pull_path_or_message,
                viewed_books = done,
                total_books = total,
            })
        else
            logger:err("Book failed to pull:", book.id, "-", pull_path_or_message)
            callback({
                state = "book-error",
                book_id = book.id,
                message = pull_path_or_message,
                viewed_books = done,
                total_books = total,
            })
        end
    end

    -- The books already here first (quick: progress and shelves), then the
    -- downloads
    for index, entry in ipairs(on_device) do
        stage(callback, "update", index, #on_device, bookTitle(entry.book))
        pull(entry)
    end
    for index, entry in ipairs(to_download) do
        stage(callback, "download", index, #to_download, bookTitle(entry.book))
        pull(entry, downloadProgress(callback))
    end

    logger:dbg("Checking existing books on disk in download directory")
    stage(callback, "cleanup")

    -- Iterate through books in download directory and
    -- remove when not in the `seen_books` set
    util.findFiles(
        download_directory,
        function(path)
            local ok, result = pcall(function()
                if path:match("%.sdr/") then
                    -- Ignore sidecar directory
                    return
                end

                if seen_books[path] then
                    -- We saw this specific file and can skip
                    -- We don't need to do the database lookup
                    return
                end

                local partial_md5 = util.partialMD5(path)
                local found_ok, _, grimmory_id = self.repository:findBookByFile(path, partial_md5)

                if not found_ok or not grimmory_id then
                    -- Skip file, not tracked in database for some reason
                    logger:dbg("Skipping file removal, not in database:", path, partial_md5)
                    return
                end

                if seen_grimmory_ids[tostring(grimmory_id)] then
                    -- We saw this Grimmory ID as a valid book to keep on-device.
                    return
                end

                logger:dbg("Book removed from upstream:", path)

                if self.settings:getDownloadRemoveBooks() then
                    self:removeBook(path)
                else
                    -- Even if we don't remove the book we should remove it
                    -- from all Grimmory shelves.
                    self:associateWithShelves(path, {})
                end
            end)

            if not ok then
                logger:err("Failed during cleanup:", path, "-", result)
            end
        end,
        true
    )

    -- During pulling books we may have updated the collections that
    -- books are in which need to be persisted to disk
    ReadCollection:write()
end

---@return boolean ok
function GrimmorySynchronize:checkForHealthyServer()
    local ok, version = self.api:getServerVersion()

    if not ok then
        logger:err("Failed to contact server, cannot sync:", version)
        return false
    end

    return true
end

--- Show a book's metadata from Grimmory in KOReader
---@param metadata table See GrimmoryDocMetadata.toCustomProps
---@return string[] changed KOReader fields that changed
function GrimmorySynchronize:applyBookInfo(book_path, metadata, callback)
    local ok, changed = pcall(self.doc_metadata.applyGrimmoryMetadata, self.doc_metadata, book_path, metadata)

    if not ok then
        logger:err("Could not update book information:", book_path, "-", changed)
        return {}
    end

    if #changed > 0 then
        callback({ state = "book-info-updated", book_path = book_path })
    end

    return changed
end

--- Paths of the copies of a Grimmory book on the device
---@return string[]
function GrimmorySynchronize:getLocalPaths(grimmory_id)
    local paths = {}
    local ok, local_books = self.repository:findBooksByGrimmoryId(grimmory_id)
    if ok then
        for _, local_book in ipairs(local_books) do
            if util.fileExists(local_book.book_path) then
                table.insert(paths, local_book.book_path)
            end
        end
    end
    return paths
end

--- Book information of every Grimmory book on the device, for when the
--- book pull (which does it on the way) is off
function GrimmorySynchronize:updateAllBookInfo(callback)
    for book, element_count, total_books in self.api:getBooks() do
        stage(callback, "book-info", element_count, total_books)
        for _, path in ipairs(self:getLocalPaths(book.id)) do
            self:applyBookInfo(path, book.metadata, callback)
        end
    end
end

--- Push the highlights of one book (new, changed and deleted ones).
---@return boolean done Nothing is left to push (also: not a Grimmory book)
function GrimmorySynchronize:pushPendingAnnotations(book_path)
    local _, _, grimmory_id = self.repository:upsertBook(book_path)
    if grimmory_id == nil then
        grimmory_id = self:associateBook(book_path)
    end
    if grimmory_id == nil then
        logger:info("Not a Grimmory book, no highlights to push:", book_path)
        return true
    end

    local counts = self:pushBookAnnotations(book_path, grimmory_id)
    return counts.failed == 0
end

--- Push what earlier syncs could not send: per book its reading progress
--- and sessions and / or its highlights.  Each book that is done is
--- reported ("pending-synced"), so the main process can forget it.
---@param pending table | nil settings:getPendingSyncBooks()
---@param open_book_path string | nil Its highlights wait until it is closed
---  (the reader would overwrite the IDs written for them)
function GrimmorySynchronize:pushPendingBooks(pending, open_book_path, callback)
    local lfs = require("libs/libkoreader-lfs")

    local paths = {}
    for book_path in pairs(pending or {}) do
        table.insert(paths, book_path)
    end
    table.sort(paths)

    for index, book_path in ipairs(paths) do
        local kinds = pending[book_path]
        stage(callback, "highlights", index, #paths)

        local function done(kind)
            callback({ state = "pending-synced", book_path = book_path, kind = kind })
        end

        if lfs.attributes(book_path, "mode") ~= "file" then
            -- Deleted meanwhile: nothing left to send
            logger:info("Pending book is gone:", book_path)
            if kinds.progress then
                done("progress")
            end
            if kinds.annotations then
                done("annotations")
            end
        else
            if kinds.progress then
                local failed = false
                local ok, push_error = pcall(self.pushBookProgressAndSessions, self, book_path, function(state)
                    local name = type(state) == "table" and state.state
                    if name == "progress-failed" or name == "session-error" then
                        failed = true
                    end
                    callback(state)
                end)
                if ok and not failed then
                    done("progress")
                else
                    logger:err("Pending progress not sent:", book_path, push_error)
                end
            end

            if kinds.annotations and book_path ~= open_book_path then
                if not self.settings:getSyncAnnotations() then
                    done("annotations")
                else
                    local ok, result = pcall(self.pushPendingAnnotations, self, book_path)
                    if ok and result then
                        done("annotations")
                    else
                        logger:err("Pending highlights not sent:", book_path, result)
                    end
                end
            end
        end
    end
end

--- Retry after a failed or skipped sync: only what is pending, no downloads.
function GrimmorySynchronize:pushPending(pending, open_book_path, callback)
    if not self:checkForHealthyServer() then
        error("Cannot connect to valid server")
    end

    self:pushAllPendingBookMetadata(callback)
    self:pushPendingBooks(pending, open_book_path, callback)
end

---@param pending table | nil Books with something left over from earlier syncs (settings:getPendingSyncBooks())
---@param open_book_path string | nil The book open in the reader (its highlights are pushed when it is closed)
function GrimmorySynchronize:synchronizeAll(callback, pending, open_book_path)
    if not self:checkForHealthyServer() then
        return error("Cannot connect to valid server")
    end

    -- First, tell Grimmory about all of our reading
    logger:info("Pushing pending book metadata")
    self:pushAllPendingBookMetadata(callback)
    self:pushPendingBooks(pending, open_book_path, callback)

    -- Then pull the shelves
    logger:info("Synchronizing shelves")
    self:synchronizeShelves(callback)

    -- And only afterwards, pull new books because our
    -- reading progress may change the books we sync down
    logger:info("Pulling books")
    self:pullBooks(callback)

    if self.settings:getSyncBookInfo() and not self.settings:getDownloadsBooks() then
        local info_ok, info_error = pcall(self.updateAllBookInfo, self, callback)
        if not info_ok then
            logger:err("Could not update book information:", info_error)
        end
    end

    -- Clean up empty shelves
    self:removeEmptyShelves(callback)

    -- Next volumes of the series being read
    local smart_ok, smart_error = pcall(self.smartDownload, self, callback)
    if not smart_ok then
        logger:err("Smart download failed:", smart_error)
    end

    logger:info("Done synchronizing")
end

--- Push only the local reading progress and sessions of one book.
--- Sessions need the book to be known to Grimmory; it is linked if needed.
--- Used when a document is closed: no annotations, shelves, downloads or
--- remote progress pulls, so it finishes quickly.
---@param book_path string
---@param callback function
---@param smart boolean | nil Also smart download the next volumes of its series
---@param pending table | nil Books with something left over from earlier syncs (settings:getPendingSyncBooks())
function GrimmorySynchronize:synchronizeBookProgress(book_path, callback, smart, pending)
    self:pushBookProgressAndSessions(book_path, callback)

    -- This book's changed highlights (it is closed now), and what earlier
    -- syncs could not send, while connected anyway
    local others = {}
    for path, kinds in pairs(pending or {}) do
        others[path] = path == book_path and { annotations = kinds.annotations } or kinds
    end
    self:pushPendingBooks(others, nil, callback)

    if smart and self.settings:getSmartDownloadMode() ~= "off" then
        -- After the push, so the server knows how far the book was read
        callback({ state = "smart-check" })
        local ok, smart_error = pcall(self.smartDownloadForBook, self, book_path, callback)
        if not ok then
            logger:err("Smart download failed:", smart_error)
        end
    end
end

function GrimmorySynchronize:pushBookProgressAndSessions(book_path, callback)
    if not self:checkForHealthyServer() then
        error("Cannot connect to valid server")
    end

    local book_ok, book_id, grimmory_id = self.repository:upsertBook(book_path)

    if not book_ok or not book_id then
        error("Could not track book")
    end

    logger:info("Pushing reading progress:", book_path)
    self:pushBookProgress(book_id, callback)

    if not self.settings:getSyncReadingSessions() then
        return
    end

    if grimmory_id == nil then
        -- Sessions are recorded against the Grimmory book, so link it once
        -- (the association is stored, later closes skip this search).
        logger:info("Searching Grimmory for book:", book_path)
        grimmory_id = self:associateBook(book_path)
    end

    if grimmory_id == nil then
        -- Not a Grimmory book: nothing to record the sessions against.
        logger:info("Book not found in Grimmory, not pushing sessions:", book_path)
        return
    end

    self:pushBookSessions(book_id, callback)

    logger:info("Done pushing reading progress:", book_path)
end

function GrimmorySynchronize:synchronizeBook(book_path, refresh_book, callback)
    if not self:checkForHealthyServer() then
        error("Cannot connect to valid server")
    end

    -- Get book ID
    local book_ok, book_id, grimmory_id = self.repository:upsertBook(book_path)

    if not book_ok or not book_id then
        error("Could not track book")
    end

    -- What happened, for the summary shown afterwards
    local result = { linked = grimmory_id ~= nil }

    if refresh_book then
        if not grimmory_id then
            error("Book not associated to Grimmory")
        end

        local refresh_ok, refreshed_book_id, replaced = self:refreshBook(book_path, book_id, grimmory_id)
        result.file_replaced = replaced == true

        if not refresh_ok or not refreshed_book_id then
            logger:err("Could not refresh book:", book_path, refreshed_book_id)
            error("Could not refresh book")
        end
    end

    if grimmory_id == nil then
        -- Try to find a grimmory ID for this book
        logger:info("Searching Grimmory for book:", book_path)

        grimmory_id = self:associateBook(book_path)
        if grimmory_id ~= nil then
            logger:info("Found book in Grimmory:", book_path)
            result.linked = true
            result.newly_linked = true
        else
            logger:warn("Unable to locate book in Grimmory:", book_path)
        end
    end

    -- Title, authors, series, ... from Grimmory
    if grimmory_id and self.settings:getSyncBookInfo() then
        stage(callback, "book-info-one")
        local detail_ok, detail = self.api:getAppBookDetail(grimmory_id)
        if detail_ok then
            result.info_changed = self:applyBookInfo(book_path, {
                title = detail.title,
                authors = detail.authors,
                series_name = detail.series_name,
                series_number = detail.series_number,
                language = detail.language,
                keywords = detail.keywords,
                description = detail.description or "",
            }, callback)
        else
            logger:err("Could not load book information:", grimmory_id, detail)
            result.info_failed = true
        end
    end

    -- Push / pull annotations with Grimmory
    if grimmory_id and self.settings:getSyncAnnotations() then
        stage(callback, "book-highlights")
        -- Annotation errors (e.g. a position that cannot be converted to a
        -- CFI) must not prevent progress and sessions from being pushed.
        logger:info("Pushing book annotations:", book_path)
        local push_ok, pushed = pcall(self.pushBookAnnotations, self, book_path, grimmory_id)
        if push_ok then
            result.annotations_pushed = pushed
            if pushed.failed > 0 then
                result.annotations_failed = true
            end
        else
            logger:err("Failed pushing annotations:", book_path, "-", pushed)
            result.annotations_failed = true
        end

        logger:info("Pulling book annotations:", book_path)
        local pull_ok, pulled = pcall(self.pullBookAnnotations, self, book_path, grimmory_id)
        if pull_ok and pulled then
            result.annotations_pulled = pulled
        elseif not pull_ok then
            logger:err("Failed pulling annotations:", book_path, "-", pulled)
            result.annotations_failed = true
        end
    elseif grimmory_id then
        logger:info("Annotation sync skipped because feature is disabled:", book_path)
    end

    -- First, tell Grimmory about all of our reading
    logger:info("Pushing pending book metadata:", book_path)
    stage(callback, "book-progress")
    self:pushBookMetadata(book_id, callback)

    callback({
        state = "book-push-metadata",
        book_id = book_id,
        pushed_books = 1,
        total_books = 1,
    })

    -- Then, try to get progress
    result.progress_pulled = self:pullBookProgress(book_path)

    callback({ state = "book-sync-result", result = result })

    logger:info("Done synchronizing book:", book_path)
end

return GrimmorySynchronize
--[[
Sync: downloading books, keeping them up to date (progress, shelves, book
information) and removing the ones gone from Grimmory.  Methods of
GrimmorySynchronize (grimmory/synchronize.lua).
--]]

local ReadCollection = require("readcollection")
local md5 = require("ffi/MD5")
local util = require("util")

local Fingerprint = require("grimmory/fingerprint")
local GrimmoryLogger = require("grimmory/logger")
local SyncEvents = require("grimmory/sync/events")

local logger = GrimmoryLogger:new()
local stage = SyncEvents.stage
local downloadProgress = SyncEvents.downloadProgress
local bookTitle = SyncEvents.bookTitle

---@class GrimmorySynchronizeMethods
local GrimmorySynchronize = {}

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
                Fingerprint.partialMD5(local_book.book_path) == local_book.book_md5
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

    local temp_partial_md5 = Fingerprint.partialMD5(temp_path)
    local book_partial_md5 = Fingerprint.partialMD5(book_path)


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

        -- Finished in Grimmory: finished in KOReader too (not undone the
        -- other way: a book finished on the device stays so)
        if book.read_status == "READ" and self.settings:getSyncReadingProgress()
            and self.doc_metadata:markFinished(download_path) then
            logger:info("Marked as finished, as in Grimmory:", download_path)
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
        read_status = detail.read_status,
    }

    local book_path = self:pullBook(book, on_progress)
    ReadCollection:write()

    return book_path
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
            elseif self:isInDownloadSources(book) then
                table.insert(to_download, entry)
            else
                -- Kept (downloaded from the library browser or by smart
                -- download), but deleted from the device since: keeping it
                -- means not removing it, not bringing it back.  Forget it
                -- (smart download fetches it again if it is still needed).
                logger:info("Kept book deleted from the device, not downloaded again:", book.id)
                seen_grimmory_ids[tostring(book.id)] = nil
                self.settings:setKeptBook(book.id, false, true)
                callback({ state = "kept-book-removed", book_id = book.id })
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

                local partial_md5 = Fingerprint.partialMD5(path)
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

return GrimmorySynchronize

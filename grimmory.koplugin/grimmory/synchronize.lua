
local GrimmoryLogger = require("grimmory/logger")
local SyncEvents = require("grimmory/sync/events")

local logger = GrimmoryLogger:new()

local stage = SyncEvents.stage

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

---@return boolean ok
function GrimmorySynchronize:checkForHealthyServer()
    local ok, version = self.api:getServerVersion()

    if not ok then
        logger:err("Failed to contact server, cannot sync:", version)
        return false
    end

    return true
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

-- Methods kept in their own files, by subject
for _, module in ipairs({
    "grimmory/sync/push",
    "grimmory/sync/shelves",
    "grimmory/sync/books",
    "grimmory/sync/smart",
}) do
    for name, method in pairs(require(module)) do
        GrimmorySynchronize[name] = method
    end
end

return GrimmorySynchronize

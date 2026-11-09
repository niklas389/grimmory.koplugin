--[[
Sync: smart download for series (see grimmory/smart_download.lua for which
volumes).  Methods of GrimmorySynchronize (grimmory/synchronize.lua).
--]]

local util = require("util")

local GrimmoryLogger = require("grimmory/logger")
local SmartDownload = require("grimmory/smart_download")
local SyncEvents = require("grimmory/sync/events")

local logger = GrimmoryLogger:new()
local stage = SyncEvents.stage
local downloadProgress = SyncEvents.downloadProgress

---@class GrimmorySynchronizeMethods
local GrimmorySynchronize = {}

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

return GrimmorySynchronize

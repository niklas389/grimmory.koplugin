--[[
Smart download for series: keep the volume being read and the next unread
volumes of a series on the device, e.g. one book or three comic volumes
ahead.  This module only decides which volumes; synchronize.lua downloads.
--]]

local SmartDownload = {}

-- Comic / manga archives get their own (usually larger) count ahead
local COMIC_TYPES = { CBZ = true, CBR = true, CB7 = true, CBT = true, CBX = true }

-- Volumes that are done with, or not to be read
local SKIPPED_STATUS = { READ = true, WONT_READ = true, ABANDONED = true }

local READING_STATUS = { READING = true, RE_READING = true }

---@param book LibraryBook
function SmartDownload.isComic(book)
    local file_type = book.primary_file_type and book.primary_file_type:upper() or nil
    if file_type and COMIC_TYPES[file_type] then
        return true
    end

    local extension = book.primary_file_name and book.primary_file_name:match("%.(%w+)$")
    return extension ~= nil and COMIC_TYPES[extension:upper()] == true
end

--- Whether a volume of the series is being read
---@param books LibraryBook[]
function SmartDownload.isInProgress(books)
    for _, book in ipairs(books) do
        if READING_STATUS[book.read_status or ""] then
            return true
        end
    end
    return false
end

--- The volumes to have on the device: the one being read (the latest, if
--- several are) and the next unread ones after it.  Without one being read,
--- the next unread ones after the last finished volume (from the start for
--- a series not started yet).
---@param books LibraryBook[] The series' volumes, in series order
---@param ahead_books number Unread book volumes to keep ahead
---@param ahead_comics number Unread comic volumes to keep ahead
---@return LibraryBook[]
function SmartDownload.selectVolumes(books, ahead_books, ahead_comics)
    local current_index = nil
    local last_finished_index = 0

    for index, book in ipairs(books) do
        local status = book.read_status or ""
        if READING_STATUS[status] then
            current_index = index
        elseif status == "READ" then
            last_finished_index = index
        end
    end

    local volumes = {}
    local start_index = last_finished_index + 1

    if current_index then
        if books[current_index].primary_file_name then
            table.insert(volumes, books[current_index])
        end
        start_index = current_index + 1
    end

    local taken = { book = 0, comic = 0 }
    local limit = { book = ahead_books, comic = ahead_comics }

    for index = start_index, #books do
        local book = books[index]
        if book.primary_file_name and not SKIPPED_STATUS[book.read_status or ""] then
            local kind = SmartDownload.isComic(book) and "comic" or "book"
            if taken[kind] < limit[kind] then
                table.insert(volumes, book)
                taken[kind] = taken[kind] + 1
            end
        end

        if taken.book >= limit.book and taken.comic >= limit.comic then
            break
        end
    end

    return volumes
end

return SmartDownload

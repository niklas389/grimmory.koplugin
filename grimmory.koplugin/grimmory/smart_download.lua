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

-- A volume marked as being read counts only from this much progress on
-- (percent): opening a volume for a moment marks it "reading" on the
-- server (e.g. a peek in Grimmory's reader, or a sync of a book opened
-- briefly), and resetting its progress in Grimmory keeps that status.
SmartDownload.MIN_READING_PERCENT = 1

--- Whether the volume is really being read: marked so, and read a little.
--- Without progress (0 % arrives as none) it is not: a status left over.
---@param book LibraryBook
function SmartDownload.isReading(book)
    if not READING_STATUS[book.read_status or ""] then
        return false
    end
    local progress = tonumber(book.read_progress)
    return progress ~= nil and progress >= SmartDownload.MIN_READING_PERCENT
end

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
        if SmartDownload.isReading(book) then
            return true
        end
    end
    return false
end

--- A volume's place in its series: its series number, else a number the
--- file name starts with ("03 Title (2020).cbz"), else nil.
---@param book LibraryBook
---@return number | nil
function SmartDownload.volumeNumber(book)
    if type(book.series_number) == "number" then
        return book.series_number
    end
    local name = book.primary_file_name or ""
    local number = name:match("^%s*(%d+%.?%d*)")
    return number and tonumber(number) or nil
end

--- The volumes in series order, whatever order the server listed them in:
--- by number; volumes without one after them, in the server's order.
---@param books LibraryBook[]
---@return LibraryBook[]
function SmartDownload.sortVolumes(books)
    local entries = {}
    for index, book in ipairs(books) do
        table.insert(entries, { book = book, number = SmartDownload.volumeNumber(book), index = index })
    end
    table.sort(entries, function(a, b)
        if a.number and b.number and a.number ~= b.number then
            return a.number < b.number
        end
        if (a.number == nil) ~= (b.number == nil) then
            return a.number ~= nil
        end
        return a.index < b.index
    end)

    local sorted = {}
    for _, entry in ipairs(entries) do
        table.insert(sorted, entry.book)
    end
    return sorted
end

--- How the volumes look to smart download, for the log: "1 READ, 2 READING, 3, ..."
---@param books LibraryBook[]
function SmartDownload.describe(books)
    local parts = {}
    for _, book in ipairs(books) do
        local number = SmartDownload.volumeNumber(book)
        local text = number and string.format("%g", number) or ("#" .. tostring(book.id))
        if book.read_status and book.read_status ~= "UNREAD" then
            text = text .. " " .. book.read_status
            if READING_STATUS[book.read_status] then
                text = text .. (book.read_progress and string.format(" %g%%", book.read_progress)
                    or " (no progress)")
            end
        end
        table.insert(parts, text)
    end
    return table.concat(parts, ", ")
end

--- The volumes to have on the device: the one being read (the latest, if
--- several are; see isReading) and the next unread ones after it.  Without
--- one being read, the next unread ones after the last finished volume (from
--- the start for a series not started yet).  Volumes only opened briefly
--- count as unread.
---@param books LibraryBook[] The series' volumes (sorted here into series order)
---@param ahead_books number Unread book volumes to keep ahead
---@param ahead_comics number Unread comic volumes to keep ahead
---@return LibraryBook[]
function SmartDownload.selectVolumes(books, ahead_books, ahead_comics)
    books = SmartDownload.sortVolumes(books)
    local current_index = nil
    local last_finished_index = 0

    for index, book in ipairs(books) do
        if SmartDownload.isReading(book) then
            current_index = index
        elseif book.read_status == "READ" then
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

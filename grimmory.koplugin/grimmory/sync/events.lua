--[[
What the sync tells the UI while it runs (synchronize.lua and its parts):
its steps, for the progress popup (grimmory/ui/sync_progress.lua).
--]]

local SyncEvents = {}

--- Tell the UI what the sync is doing (shown in the progress sheet): a step
--- of the sync, and where it is in it (e.g. book 3 of 6, and its title).
---@param name string push | highlights | shelves | check | update | download | cleanup | book-info |
---  smart-check | smart-download | book-info-one | book-highlights | book-progress
function SyncEvents.stage(callback, name, current, total, title)
    callback({ state = "stage", stage = name, current = current, total = total, title = title })
end

--- Report a download's progress (throttled by the API) to the UI.
function SyncEvents.downloadProgress(callback)
    return function(bytes, total)
        callback({ state = "download-progress", bytes = bytes, total = total })
    end
end

---@param book Book
function SyncEvents.bookTitle(book)
    return (book.metadata and book.metadata.title)
        or (book.primary_file and book.primary_file.filename)
        or tostring(book.id)
end

return SyncEvents

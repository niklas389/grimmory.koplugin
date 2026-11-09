--[[
What the sync progress popup says, from the sync's events (synchronize.lua):
the step ("Downloading books"), where it is ("3 of 6 · Title") and how far
the step is (0..1, including the progress of a download).

    local progress = SyncProgress:new()
    local state = progress:handle(event)  -- nil: nothing to show for it
--]]

local T = require("ffi/util").template
local _ = require("gettext")

local SyncProgress = {}

local STEPS = {
    push = _("Uploading reading progress"),
    highlights = _("Uploading highlights"),
    shelves = _("Updating shelves"),
    check = _("Checking the library"),
    update = _("Updating books on the device"),
    download = _("Downloading books"),
    cleanup = _("Checking the download folder"),
    ["book-info"] = _("Updating book information"),
    ["smart-check"] = _("Checking series (smart download)"),
    ["smart-download"] = _("Downloading next volumes"),
    ["book-info-one"] = _("Updating book information"),
    ["book-highlights"] = _("Syncing highlights"),
    ["book-progress"] = _("Syncing reading progress"),
}

-- Counted in books ("12 of 340 books") rather than "12 of 340 · Title"
local COUNTED_BOOKS = { push = true, highlights = true, check = true, ["book-info"] = true }

function SyncProgress:new()
    local o = { stage = nil }
    setmetatable(o, self)
    self.__index = self
    return o
end

--- The text and bar for an event.
---@return table | nil state { step, detail, fraction }
function SyncProgress:handle(event)
    if type(event) ~= "table" then
        return nil
    end

    if event.state == "stage" then
        local step = STEPS[event.stage]
        if not step then
            return nil
        end
        self.stage = event

        local detail = ""
        local fraction = 0
        local current, total = tonumber(event.current), tonumber(event.total)
        if current and total and total > 0 then
            if COUNTED_BOOKS[event.stage] then
                detail = T(_("%1 of %2 books"), current, total)
                fraction = current / total
            else
                detail = T(_("%1 of %2"), current, total)
                -- This one is under way
                fraction = (current - 1) / total
            end
        end
        if event.title and event.title ~= "" then
            detail = detail ~= "" and (detail .. " · " .. event.title) or event.title
        end
        self.detail = detail

        return { step = step, detail = detail, fraction = fraction }
    end

    if event.state == "download-progress" then
        local stage = self.stage
        local bytes, size = tonumber(event.bytes), tonumber(event.total)
        local current, total = stage and tonumber(stage.current), stage and tonumber(stage.total)
        if not (bytes and current and total and total > 0) then
            return nil
        end
        if not (size and size > 0) then
            -- Size unknown: how much has arrived
            return { detail = self.detail .. " · " .. T(_("%1 MB"), string.format("%.1f", bytes / 1048576)) }
        end
        local done = math.min(1, bytes / size)
        return { fraction = (current - 1 + done) / total }
    end

    return nil
end

return SyncProgress

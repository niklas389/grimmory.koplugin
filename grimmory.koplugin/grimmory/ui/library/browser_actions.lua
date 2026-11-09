--[[
Library browser: download sources and smart download bars, the long press
sheets and the search.  Methods of LibraryBrowser
(grimmory/ui/library/browser.lua).
--]]

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local InputSheet = require("grimmory/ui/input_sheet")
local Sheet = require("grimmory/ui/sheet")
local Widgets = require("grimmory/ui/library/widgets")

---@class LibraryBrowserMethods
local LibraryBrowser = {}

function LibraryBrowser:downloadSourceBar(source)
    local kind, collection = source.kind, source.collection
    local id_or_name = kind == "series" and collection.name or collection.id

    return Widgets.checkboxRow({
        width = self.width,
        text = _("Download with automatic sync"),
        checked = self.settings:isDownloadSource(kind, id_or_name),
        on_tap = function()
            self:toggleDownloadSource(kind, collection)
        end,
    })
end

function LibraryBrowser:toggleDownloadSource(kind, collection)
    local id_or_name = kind == "series" and collection.name or collection.id
    local enable = not self.settings:isDownloadSource(kind, id_or_name)

    self.settings:setDownloadSource(kind, { id = collection.id, name = collection.name }, enable)
    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

    local message
    if enable and self.settings:getDownloadEverything() then
        message = T(_("“%1” will be downloaded by the sync (all books are, as “Everything” is on)."), collection.name)
    elseif enable then
        message = T(_("“%1” will be downloaded by the sync."), collection.name)
    else
        message = T(_("“%1” is no longer downloaded by the sync."), collection.name)
    end
    self.dialog_manager:notify(message, 3)

    -- The home rows include the download sources
    if self.tab_screens.home then
        self.tab_screens.home.sections = nil
    end

    self:show()
end

--- Whether a volume of the series is being read (as the server says; cached)
function LibraryBrowser:isSeriesInProgress(series_name)
    local in_progress = false
    local returned = false

    -- Cached after the first time; the first answer arrives later and shows
    -- the screen again (with the answer cached)
    self.data:fetch("series-in-progress", function()
        return self.api:getAppSeriesInProgress()
    end, function(ok, names)
        if returned then
            if ok and not self.closed then
                self:show()
            end
            return
        end
        if ok then
            for _, name in ipairs(names) do
                if name == series_name then
                    in_progress = true
                    break
                end
            end
        end
    end)

    returned = true
    return in_progress
end

--- Whether smart download is on for the series
function LibraryBrowser:isSmartDownloadOn(collection)
    local in_progress = false
    if self.settings:getSmartDownloadMode() == "in_progress"
        and self.settings:getSmartDownloadSeries(collection.name) == nil then
        in_progress = self:isSeriesInProgress(collection.name)
    end

    return self.settings:isSmartDownloadSeries(collection.name, in_progress)
end

function LibraryBrowser:smartDownloadBar(collection)
    local checked = self:isSmartDownloadOn(collection)

    return Widgets.checkboxRow({
        width = self.width,
        text = _("Smart download: keep the next volumes"),
        checked = checked,
        on_tap = function()
            self:toggleSmartDownload(collection, checked)
        end,
    })
end

function LibraryBrowser:toggleSmartDownload(collection, checked)
    local choice
    if not checked then
        choice = true
    elseif self.settings:getSmartDownloadMode() == "in_progress" then
        -- Excluded even while being read
        choice = false
    end

    self.settings:setSmartDownloadSeries(collection.name, choice)
    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

    if checked then
        self.dialog_manager:notify(T(_("Smart download is off for “%1”."), collection.name), 3)
    else
        self.dialog_manager:notify(T(_("The next volumes of “%1” are downloaded by the sync."), collection.name), 3)
    end

    self:show()
end


--- Actions for a book: read / download, details, series, delete
---@param book LibraryBook
---@param screen table | nil The screen of the book (to start selecting there)
function LibraryBrowser:showBookSheet(book, screen)
    local local_path = self:getLocalPath(book.id)

    local function downloadFromDetails(open_after)
        self:openDetails(book)
        self:downloadBook(self:current(), open_after)
    end

    local tiles = {}
    if local_path then
        table.insert(tiles, { text = _("Read"), sui_icon = "book_open", callback = function()
            self:openBook(local_path)
        end })
    elseif book.primary_file_name then
        table.insert(tiles, { text = _("Download & read"), sui_icon = "book_open", callback = function()
            downloadFromDetails(true)
        end })
    end
    table.insert(tiles, { text = _("Details"), sui_icon = "info", callback = function()
        self:openDetails(book)
    end })
    if book.series_name then
        table.insert(tiles, { text = _("Series"), sui_icon = "series", callback = function()
            self:push(self:collectionBooksScreen("series", { name = book.series_name }))
        end })
    end

    local rows = {}
    if screen and screen.type == "books" and self:isSelectable(book) then
        table.insert(rows, { text = _("Select books to download"), sui_icon = "select", callback = function()
            self:startSelection(screen, book)
        end })
    end
    if local_path then
        table.insert(rows, { text = _("Delete from device"), sui_icon = "delete", callback = function()
            self:confirmDelete({ book = book }, local_path)
        end })
    elseif book.primary_file_name then
        table.insert(rows, { text = _("Download only"), sui_icon = "import", callback = function()
            downloadFromDetails(false)
        end })
    end

    local message = {}
    if #book.authors > 0 then
        table.insert(message, table.concat(book.authors, ", "))
    end
    table.insert(message, Widgets.seriesText(book))

    Sheet.show({
        title = book.title,
        icon = "book_open",
        message = table.concat(message, " · "),
        auto_close = true,
        sections = { { type = "tiles", items = tiles }, Sheet.list(rows) },
    })
end

--- Actions for a series / shelf / library: open, download settings
function LibraryBrowser:showCollectionSheet(kind, collection)
    local id_or_name = kind == "series" and collection.name or collection.id

    local rows = {
        { text = _("Show books"), sui_icon = "list", callback = function()
            self:push(self:collectionBooksScreen(kind, collection))
        end },
        {
            text = _("Download with automatic sync"),
            sui_icon = "import",
            checked = self.settings:isDownloadSource(kind, id_or_name),
            callback = function()
                self:toggleDownloadSource(kind, collection)
            end,
        },
    }

    if kind == "series" and self.settings:getSmartDownloadMode() ~= "off" then
        local checked = self:isSmartDownloadOn(collection)
        table.insert(rows, {
            text = _("Smart download: keep the next volumes"),
            sui_icon = "series",
            checked = checked,
            callback = function()
                self:toggleSmartDownload(collection, checked)
            end,
        })
    end

    Sheet.show({
        title = collection.name,
        icon = kind == "series" and "series" or "library",
        auto_close = true,
        sections = { Sheet.list(rows) },
    })
end


function LibraryBrowser:showSearch(screen)
    local search_series = screen.kind == "series"

    InputSheet.show({
        title = search_series and _("Search series") or _("Search books"),
        icon = "search",
        hint = search_series and _("Series name") or _("Title, author, series…"),
        ok_text = _("Search"),
        on_ok = function(text)
            if search_series then
                self:push({
                    type = "collections",
                    kind = "series",
                    title = T(_("Series: “%1”"), text),
                    paged = true,
                    page = 1,
                    with_covers = true,
                    load = function(page, size, done)
                        self.data:fetch("series-search:" .. text .. ":" .. size .. ":" .. page, function()
                            return self.api:getAppSeries({ page = page, size = size, search = text })
                        end, done)
                    end,
                })
            else
                self:push(self:filteredBooksScreen(
                    T(_("Search: “%1”"), text),
                    "search:" .. text,
                    { search = text, sort = "title", dir = "asc" }
                ))
            end
        end,
    })
end

function LibraryBrowser:setLayout(layout)
    self.layout = layout
    self.settings:setBrowserLayout(layout)
    self:show()
end

return LibraryBrowser

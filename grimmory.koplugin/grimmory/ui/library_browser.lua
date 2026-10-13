local _ = require("gettext")
local T = require("ffi/util").template

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local ReadCollection = require("readcollection")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

-- Server responses are kept for a few minutes, so going back, reopening the
-- browser or paging through a list again needs no request.  Shared by all
-- browser instances (FileManager and ReaderUI each have a plugin instance).
local CACHE_TTL_SECONDS = 300
local response_cache = {}

local COVER_CACHE_DIRECTORY = DataStorage:getDataDir() .. "/cache/grimmory/covers"

local function getCached(key)
    local entry = response_cache[key]
    if entry and os.time() - entry.time < CACHE_TTL_SECONDS then
        return entry.value
    end
    response_cache[key] = nil
    return nil
end

local function setCached(key, value)
    response_cache[key] = { time = os.time(), value = value }
end

local function fileExists(path)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

local function formatSize(size_kb)
    if not size_kb then
        return nil
    end
    if size_kb >= 1024 then
        return string.format("%.1f MB", size_kb / 1024)
    end
    return string.format("%d KB", size_kb)
end

local function formatSeriesNumber(number)
    if not number then
        return nil
    end
    if number == math.floor(number) then
        return string.format("%d", number)
    end
    return tostring(number)
end

---@class GrimmoryLibraryBrowser
---@field api GrimmoryAPI
---@field settings GrimmorySettings
---@field repository GrimmoryLocalRepository
---@field executor GrimmoryExecutor
---@field synchronizer GrimmorySynchronize
---@field dialog_manager DialogManager
---@field is_sync_running function(): boolean
---@field release_wifi function | nil Releases the WiFi held for browsing
local LibraryBrowser = Menu:extend{
    title = _("Grimmory Library"),
    is_borderless = true,
    is_popout = false,
    covers_fullscreen = true,
    title_bar_fm_style = true,
    title_bar_left_icon = "appbar.search",
}

function LibraryBrowser:init()
    self.item_table = {}
    Menu.init(self)

    -- One query for all Grimmory books on the device (by Grimmory ID)
    self.local_paths = self.repository:getGrimmoryBookPaths()

    self.views = {}
    self:pushView(self:getRootView())
end

function LibraryBrowser:onCloseWidget()
    if self.release_wifi then
        self.release_wifi()
        self.release_wifi = nil
    end

    return Menu.onCloseWidget(self)
end

-------------------------------------------------------------------------------
-- Loading
-------------------------------------------------------------------------------

--- Run a request with a "Loading…" message and the response cache.
---@return boolean ok
---@return any result
function LibraryBrowser:load(cache_key, request)
    local cached = getCached(cache_key)
    if cached ~= nil then
        return true, cached
    end

    local message = InfoMessage:new({ text = _("Loading…") })
    UIManager:show(message)
    UIManager:forceRePaint()

    local call_ok, ok, result = pcall(request)

    UIManager:close(message)

    if not call_ok then
        logger:err("Library request failed:", cache_key, ok)
        ok, result = false, ok
    end

    if not ok then
        UIManager:show(InfoMessage:new({
            text = T(_("Could not load from Grimmory:\n%1"), tostring(result)),
        }))
        return false, result
    end

    setCached(cache_key, result)
    return true, result
end

--- Local path of a downloaded Grimmory book, or nil.
function LibraryBrowser:getLocalPath(grimmory_id)
    for _, path in ipairs(self.local_paths[tostring(grimmory_id)] or {}) do
        if fileExists(path) then
            return path
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- Views: a view knows how to load its (paged) entries and turn them into menu
-- items.  The navigation stack is a list of views.
-------------------------------------------------------------------------------

--- Load a view and show it; on a failed load the current view stays.
function LibraryBrowser:pushView(view)
    view.entries = view.entries or {}
    view.next_page = view.next_page or 0

    if view.paged and #view.entries == 0 then
        if not self:loadNextPage(view) then
            return false
        end
    elseif view.load and not view.loaded then
        local ok, entries = self:load(view.cache_key, view.load)
        if not ok then
            return false
        end
        view.entries = entries
        view.loaded = true
    end

    if self.current_view then
        -- Remember the position to come back to
        self.current_view.return_page = self.page
        table.insert(self.paths, self.current_view)
    end

    self.current_view = view
    self:showView(view, 1)
    return true
end

function LibraryBrowser:onReturn()
    if #self.paths == 0 then
        return true
    end

    local view = table.remove(self.paths)
    self.current_view = view
    self:showView(view, nil, view.return_page)
    return true
end

---@return boolean ok
function LibraryBrowser:loadNextPage(view)
    local page = view.next_page
    local ok, result = self:load(view.cache_key .. "#" .. page, function()
        return view.load_page(page)
    end)

    if not ok then
        return false
    end

    for _, entry in ipairs(result.items) do
        table.insert(view.entries, entry)
    end

    view.next_page = page + 1
    view.has_next = result.has_next
    view.total = result.total

    return true
end

function LibraryBrowser:showView(view, item_number, page)
    local items = {}

    if view.header_items then
        for _, item in ipairs(view.header_items()) do
            table.insert(items, item)
        end
    end

    for _, entry in ipairs(view.entries) do
        table.insert(items, view.to_item(entry))
    end

    if view.paged and view.has_next then
        table.insert(items, {
            text = T(_("Load more… (%1 of %2)"), #view.entries, view.total or "?"),
            is_load_more = true,
            callback = function()
                self:loadMore()
            end,
        })
    end

    if #items == 0 then
        table.insert(items, { text = _("Nothing here"), dim = true, select_enabled = false })
    end

    self:switchItemTable(view.title, items, item_number, nil, view.subtitle or "")

    if page and page > 1 then
        self:onGotoPage(math.min(page, self.page_num))
    end
end

function LibraryBrowser:loadMore()
    local view = self.current_view
    if not view or not view.has_next then
        return
    end

    local first_new = #view.entries + 1 + (view.header_items and #view.header_items() or 0)

    if self:loadNextPage(view) then
        self:showView(view, first_new)
    end
end

--- Swiping past the last page loads the next server page instead of
--- cycling back to the first one.
function LibraryBrowser:onNextPage()
    local view = self.current_view
    if view and view.paged and view.has_next and self.page >= self.page_num then
        self:loadMore()
        return true
    end

    return Menu.onNextPage(self)
end

function LibraryBrowser:onMenuHold(item)
    if item.hold_callback then
        item.hold_callback()
    end
    return true
end

function LibraryBrowser:onLeftButtonTap()
    local view = self.current_view
    if view and view.search_series then
        self:showSearchDialog(_("Search series"), function(text)
            self:pushView(self:getSeriesView(text))
        end)
    else
        self:showSearchDialog(_("Search books"), function(text)
            self:pushView(self:getBooksView(T(_("Search: %1"), text), "search:" .. text, { search = text }))
        end)
    end
end

function LibraryBrowser:showSearchDialog(title, on_search)
    local dialog
    dialog = InputDialog:new({
        title = title,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local text = util.trim(dialog:getInputText() or "")
                        UIManager:close(dialog)
                        if text ~= "" then
                            on_search(text)
                        end
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-------------------------------------------------------------------------------
-- View definitions
-------------------------------------------------------------------------------

function LibraryBrowser:getRootView()
    local function entry(text, open)
        return { text = text, open = open }
    end

    return {
        title = _("Grimmory Library"),
        entries = {
            entry(_("All Books"), function()
                return self:getBooksView(_("All Books"), "all", { sort = "title", dir = "asc" })
            end),
            entry(_("Recently Added"), function()
                return self:getBooksView(_("Recently Added"), "recent", { sort = "addedOn", dir = "desc" })
            end),
            entry(_("Libraries"), function()
                return self:getCollectionsView("libraries")
            end),
            entry(_("Shelves"), function()
                return self:getCollectionsView("shelves")
            end),
            entry(_("Magic Shelves"), function()
                return self:getCollectionsView("magic_shelves")
            end),
            entry(_("Series"), function()
                return self:getSeriesView()
            end),
        },
        to_item = function(root_entry)
            return {
                text = root_entry.text .. " ›",
                callback = function()
                    self:pushView(root_entry.open())
                end,
            }
        end,
    }
end

local COLLECTION_KINDS = {
    libraries = {
        title = _("Libraries"),
        load = function(api) return api:getAppLibraries() end,
        filter = "libraryId",
    },
    shelves = {
        title = _("Shelves"),
        load = function(api) return api:getAppShelves() end,
        filter = "shelfId",
    },
    magic_shelves = {
        title = _("Magic Shelves"),
        load = function(api) return api:getAppMagicShelves() end,
    },
}

---@param kind "libraries" | "shelves" | "magic_shelves"
function LibraryBrowser:getCollectionsView(kind)
    local definition = COLLECTION_KINDS[kind]

    return {
        title = definition.title,
        cache_key = "collections:" .. kind,
        load = function()
            return definition.load(self.api)
        end,
        to_item = function(collection)
            local is_source = self.settings:isDownloadSource(kind, collection.id)
            local count = collection.book_count and tostring(collection.book_count) or ""

            return {
                text = collection.name,
                mandatory = is_source and ("⇩ " .. count) or count,
                callback = function()
                    self:pushView(self:getCollectionBooksView(kind, collection))
                end,
                hold_callback = function()
                    self:toggleDownloadSource(kind, collection)
                end,
            }
        end,
    }
end

function LibraryBrowser:getCollectionBooksView(kind, collection)
    local definition = COLLECTION_KINDS[kind]
    local view

    if kind == "magic_shelves" then
        view = self:getPagedBooksView(collection.name, "magic:" .. collection.id, function(page)
            return self.api:getAppMagicShelfBooks(collection.id, page)
        end)
    else
        view = self:getBooksView(collection.name, kind .. ":" .. collection.id, {
            [definition.filter] = collection.id,
            sort = "title",
            dir = "asc",
        })
    end

    view.header_items = function()
        return { self:getDownloadSourceItem(kind, collection) }
    end

    return view
end

function LibraryBrowser:getSeriesView(search)
    return {
        title = search and T(_("Series: %1"), search) or _("Series"),
        cache_key = "series:" .. (search or ""),
        paged = true,
        search_series = true,
        load_page = function(page)
            return self.api:getAppSeries({ page = page, search = search })
        end,
        to_item = function(series)
            local is_source = self.settings:isDownloadSource("series", series.name)
            local count = tostring(series.book_count or "")
            local source = { name = series.name }

            return {
                text = series.name,
                mandatory = is_source and ("⇩ " .. count) or count,
                callback = function()
                    local books_view = self:getPagedBooksView(
                        series.name,
                        "series-books:" .. series.name,
                        function(page)
                            return self.api:getAppSeriesBooks(series.name, page)
                        end
                    )
                    books_view.header_items = function()
                        return { self:getDownloadSourceItem("series", source) }
                    end
                    self:pushView(books_view)
                end,
                hold_callback = function()
                    self:toggleDownloadSource("series", source)
                end,
            }
        end,
    }
end

function LibraryBrowser:getBooksView(title, cache_key, params)
    return self:getPagedBooksView(title, "books:" .. cache_key, function(page)
        local query = { page = page }
        for key, value in pairs(params) do
            query[key] = value
        end
        return self.api:getAppBooks(query)
    end)
end

function LibraryBrowser:getPagedBooksView(title, cache_key, load_page)
    return {
        title = title,
        cache_key = cache_key,
        paged = true,
        load_page = load_page,
        to_item = function(book)
            return self:getBookItem(book)
        end,
    }
end

---@param book LibraryBook
function LibraryBrowser:getBookItem(book)
    local text = book.title ~= "" and book.title or (book.primary_file_name or tostring(book.id))

    local series_number = formatSeriesNumber(book.series_number)
    if book.series_name and series_number then
        text = text .. " (#" .. series_number .. ")"
    end

    if #book.authors > 0 then
        text = text .. " – " .. table.concat(book.authors, ", ")
    end

    local mandatory = {}
    if self:getLocalPath(book.id) then
        table.insert(mandatory, "✔")
    end
    if book.read_progress and book.read_progress > 0 then
        table.insert(mandatory, string.format("%d%%", math.floor(book.read_progress + 0.5)))
    end

    return {
        text = text,
        mandatory = #mandatory > 0 and table.concat(mandatory, " ") or nil,
        dim = book.primary_file_name == nil,
        callback = function()
            self:showBookDialog(book)
        end,
    }
end

-------------------------------------------------------------------------------
-- Download sources (what the automatic sync downloads)
-------------------------------------------------------------------------------

function LibraryBrowser:getDownloadSourceItem(kind, source)
    local id_or_name = kind == "series" and source.name or source.id

    return {
        text = _("Download with automatic sync"),
        mandatory = self.settings:isDownloadSource(kind, id_or_name) and _("On") or _("Off"),
        bold = true,
        callback = function()
            self:toggleDownloadSource(kind, source)
        end,
    }
end

function LibraryBrowser:toggleDownloadSource(kind, source)
    local id_or_name = kind == "series" and source.name or source.id
    local enable = not self.settings:isDownloadSource(kind, id_or_name)

    self.settings:setDownloadSource(kind, source, enable)
    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

    local message
    if enable and self.settings:getDownloadEverything() then
        message = T(
            _("“%1” will be downloaded by the sync.\n\n" ..
                "“Download everything” is on, so all books are downloaded anyway."),
            source.name
        )
    elseif enable then
        message = T(_("“%1” will be downloaded by the sync."), source.name)
    else
        message = T(_("“%1” is no longer downloaded by the sync."), source.name)
    end

    UIManager:show(InfoMessage:new({ text = message, timeout = 3 }))

    -- Refresh the "⇩" marks / On-Off item in place
    self:showView(self.current_view, nil, self.page)
end

-------------------------------------------------------------------------------
-- Book details and actions
-------------------------------------------------------------------------------

---@param book LibraryBook
function LibraryBrowser:getBookInfoText(book)
    local lines = { book.title ~= "" and book.title or (book.primary_file_name or "") }

    if #book.authors > 0 then
        table.insert(lines, table.concat(book.authors, ", "))
    end

    if book.series_name then
        local number = formatSeriesNumber(book.series_number)
        table.insert(lines, number and T(_("Series: %1 #%2"), book.series_name, number)
            or T(_("Series: %1"), book.series_name))
    end

    local details = {}
    if book.primary_file_type then
        table.insert(details, book.primary_file_type:upper())
    end
    if book.file_size_kb then
        table.insert(details, formatSize(book.file_size_kb))
    end
    if book.page_count then
        table.insert(details, T(_("%1 pages"), book.page_count))
    end
    if book.published_date then
        table.insert(details, book.published_date:sub(1, 4))
    end
    if #details > 0 then
        table.insert(lines, table.concat(details, " · "))
    end

    if book.read_progress and book.read_progress > 0 then
        table.insert(lines, T(_("Read: %1%"), math.floor(book.read_progress + 0.5)))
    end

    if self:getLocalPath(book.id) then
        table.insert(lines, _("On this device"))
    elseif not book.primary_file_name then
        table.insert(lines, _("No file to download"))
    end

    return table.concat(lines, "\n")
end

---@param book LibraryBook
function LibraryBrowser:showBookDialog(book)
    local dialog
    local local_path = self:getLocalPath(book.id)

    local function close_then(action)
        return function()
            UIManager:close(dialog)
            action()
        end
    end

    local file_row
    if local_path then
        file_row = {
            { text = _("Open"), callback = close_then(function() self:openBook(local_path) end) },
            {
                text = _("Delete from device"),
                callback = close_then(function() self:confirmDelete(book, local_path) end),
            },
        }
    else
        local can_download = book.primary_file_name ~= nil
        file_row = {
            {
                text = _("Download"),
                enabled = can_download,
                callback = close_then(function() self:downloadBook(book, false) end),
            },
            {
                text = _("Download & open"),
                enabled = can_download,
                callback = close_then(function() self:downloadBook(book, true) end),
            },
        }
    end

    dialog = ButtonDialog:new({
        title = self:getBookInfoText(book),
        title_align = "left",
        buttons = {
            {
                { text = _("Cover"), callback = function() self:showCover(book) end },
                { text = _("Description"), callback = function() self:showDescription(book) end },
            },
            file_row,
            {
                { text = _("Close"), callback = function() UIManager:close(dialog) end },
            },
        },
    })

    UIManager:show(dialog)
end

---@param book LibraryBook
function LibraryBrowser:showDescription(book)
    local ok, detail = self:load("detail:" .. book.id, function()
        return self.api:getAppBookDetail(book.id)
    end)

    if not ok then
        return
    end

    local description = detail.description or _("No description available.")
    local plain_ok, plain = pcall(util.htmlToPlainTextIfHtml, description)

    UIManager:show(TextViewer:new({
        title = book.title,
        text = plain_ok and plain or description,
    }))
end

---@param book LibraryBook
function LibraryBrowser:showCover(book)
    -- Thumbnails are cached on the device; the cover's update time is part of
    -- the name, so a changed cover is downloaded again.
    local version = (book.cover_updated_on or "0"):gsub("[^%w]", "")
    local cover_path = COVER_CACHE_DIRECTORY .. "/" .. tostring(book.id) .. "-" .. version .. ".jpg"

    if not fileExists(cover_path) then
        util.makePath(COVER_CACHE_DIRECTORY)

        local ok = self:load("cover:" .. cover_path, function()
            return self.api:downloadThumbnail(book.id, cover_path)
        end)

        if not ok then
            return
        end
    end

    local ImageViewer = require("ui/widget/imageviewer")
    UIManager:show(ImageViewer:new({
        file = cover_path,
        with_title_bar = false,
        fullscreen = true,
    }))
end

function LibraryBrowser:openBook(path)
    UIManager:close(self)

    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
end

---@param book LibraryBook
function LibraryBrowser:downloadBook(book, open_after)
    if self.is_sync_running() then
        UIManager:show(InfoMessage:new({
            text = _("A sync is running. Please try again when it has finished."),
            timeout = 3,
        }))
        return
    end

    local close_notification = self.dialog_manager:notify(T(_("Grimmory: downloading “%1”…"), book.title))

    self.executor:background(
        function(run)
            local run_ok, ok, result = pcall(run, function()
                return self.synchronizer:downloadLibraryBook(book.id)
            end)

            pcall(close_notification)

            if not run_ok or not ok or type(result) ~= "string" then
                local error_result = run_ok and result or ok
                logger:err("Book download failed:", book.id, error_result)
                UIManager:show(InfoMessage:new({
                    text = T(_("Could not download “%1”:\n%2"), book.title, tostring(error_result)),
                }))
                return
            end

            -- Keep it on the device even if it is in no download source
            self.settings:setKeptBook(book.id, true)

            local paths = self.local_paths[tostring(book.id)] or {}
            table.insert(paths, 1, result)
            self.local_paths[tostring(book.id)] = paths

            -- The download ran in a subprocess: reload what it changed
            ReadCollection.last_read_time = 0
            pcall(ReadCollection._read, ReadCollection)
            UIManager:broadcastEvent(Event:new("RefreshContent"))

            if open_after then
                self:openBook(result)
            else
                self.dialog_manager:notify(T(_("Grimmory: downloaded “%1”"), book.title), 3)
                if self.current_view then
                    self:showView(self.current_view, nil, self.page)
                end
            end
        end,
        true
    )
end

---@param book LibraryBook
function LibraryBrowser:confirmDelete(book, path)
    UIManager:show(ConfirmBox:new({
        text = T(
            _("Delete “%1” from this device?\n\nIf it is in a download source, the next sync downloads it again."),
            book.title
        ),
        ok_text = _("Delete"),
        ok_callback = function()
            self.synchronizer:removeBook(path)
            self.settings:setKeptBook(book.id, false)

            ReadCollection:write()
            UIManager:broadcastEvent(Event:new("RefreshContent"))

            if self.current_view then
                self:showView(self.current_view, nil, self.page)
            end
        end,
    }))
end

return LibraryBrowser

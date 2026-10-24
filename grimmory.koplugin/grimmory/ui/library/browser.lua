--[[
Grimmory library browser: a full screen view with a tab strip (Home, Books,
Series, Shelves, Libraries), book lists as cover list or cover grid, and a
book details page with one-tap "Download & read".

Each screen page is one server request of exactly one page of items, so a
page shows as soon as its (small) response arrives; covers are downloaded
afterwards in a subprocess and shown as they arrive.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local IconWidget = require("ui/widget/iconwidget")
local InputDialog = require("ui/widget/inputdialog")
local LineWidget = require("ui/widget/linewidget")
local TopContainer = require("ui/widget/container/topcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local ReadCollection = require("readcollection")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local CenterContainer = require("ui/widget/container/centercontainer")
local Covers = require("grimmory/ui/library/covers")
local LibraryData = require("grimmory/ui/library/data")
local Sheet = require("grimmory/ui/sheet")
local Style = require("grimmory/ui/style")
local Widgets = require("grimmory/ui/library/widgets")
local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()
local Screen = Device.screen

local TABS = {
    { id = "home", text = _("Home") },
    { id = "books", text = _("Books") },
    { id = "series", text = _("Series") },
    { id = "shelves", text = _("Shelves") },
    { id = "libraries", text = _("Libraries") },
}

---@class GrimmoryLibraryBrowser
---@field api GrimmoryAPI
---@field settings GrimmorySettings
---@field repository GrimmoryLocalRepository
---@field executor GrimmoryExecutor
---@field synchronizer GrimmorySynchronize
---@field dialog_manager DialogManager
---@field release_wifi function | nil
---@field connect function(on_ready: function(release: function), on_failed: function(reason: string)) | nil
---  Connects in the background while the browser is already shown; nil when connected before opening
---@field reconnect function(on_ready: function(), on_failed: function(reason: string))
---@field is_connected function(): boolean
---@field is_sync_running function(): boolean
local LibraryBrowser = InputContainer:extend{
    name = "grimmory_library",
    covers_fullscreen = true,
}

function LibraryBrowser:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new({ x = 0, y = 0, w = self.width, h = self.height })

    self.data = LibraryData:new({
        api = self.api,
        reconnect = self.reconnect,
        is_connected = self.is_connected,
        before_request = function()
            self:showLoadingIndicator()
        end,
    })

    -- One query for all Grimmory books on the device (by Grimmory ID)
    self.local_paths = self.repository:getGrimmoryBookPaths()
    self.layout = self.settings:getBrowserLayout()
    Covers.prune()

    self.ges_events = {
        Swipe = { GestureRange:new({ ges = "swipe", range = self.dimen }) },
    }

    if Device:hasKeys() then
        local Input = Device.input
        self.key_events = {
            Back = { { Input.group.Back } },
            NextPage = { { Input.group.PgFwd } },
            PrevPage = { { Input.group.PgBack } },
        }
    end

    self.tab_screens = {}
    self.stack = {}

    -- Show the browser right away and connect meanwhile
    self.connected = self.connect == nil
    self:selectTab("home")
    if not self.connected then
        self:startConnecting()
    end
end

function LibraryBrowser:startConnecting()
    if self.connecting then
        return
    end

    self.connecting = true
    self.connect_error = nil

    self.connect(
        function(release)
            self.connecting = false
            if self.closed then
                release()
                return
            end
            self.connected = true
            self.release_wifi = release
            self:show()
        end,
        function(reason)
            self.connecting = false
            if self.closed then
                return
            end
            self.connect_error = reason
            self:show()
        end
    )
end

function LibraryBrowser:onCloseWidget()
    self.closed = true
    self:cancelCovers()

    if self.release_wifi then
        self.release_wifi()
        self.release_wifi = nil
    end
end

function LibraryBrowser:close()
    UIManager:close(self)
end

--- While requests run (they block the UI) a cloud shows in the top
--- bar, left of "⋯".  Only its area is refreshed, which is cheaper on e-ink
--- than a notice opening and closing; the next screen replaces it.
function LibraryBrowser:showLoadingIndicator()
    local slot = self.loading_area
    if self.loading_shown or not slot then
        return
    end
    self.loading_shown = true

    -- The cloud of the sync indicator (Material Symbols, see icons/), a bit
    -- larger than its slot: the drawing does not fill its box
    local size = math.floor(slot.w * 1.3)
    local offset = math.floor((size - slot.w) / 2)
    local area = Geom:new({ x = slot.x - offset, y = slot.y - offset, w = size, h = size })
    local icon = IconWidget:new({
        file = Widgets.pluginIcon("cloud_download"),
        width = size,
        height = size,
        alpha = true,
    })
    Screen.bb:paintRect(area.x, area.y, area.w, area.h, Blitbuffer.COLOR_WHITE)
    icon:paintTo(Screen.bb, area.x, area.y)
    icon:free()

    UIManager:setDirty(nil, "fast", area)
    UIManager:forceRePaint()

    -- Usually the screen shown next paints over it; a request that does not
    -- change the screen (e.g. from a sheet) leaves it: repaint its area then
    UIManager:nextTick(function()
        if self.loading_shown and not self.closed then
            self.loading_shown = false
            UIManager:setDirty(self, function()
                return "fast", area
            end)
        end
    end)
end

function LibraryBrowser:hideLoadingIndicator()
    -- The screen shown next is painted over it
    self.loading_shown = false
end

-------------------------------------------------------------------------------
-- Navigation
-------------------------------------------------------------------------------

function LibraryBrowser:current()
    return self.stack[#self.stack]
end

--- Leaving a screen ends selecting books on it
function LibraryBrowser:endSelection()
    local screen = self:current()
    if screen then
        screen.selection = nil
    end
end

function LibraryBrowser:selectTab(tab_id)
    self:endSelection()
    if not self.tab_screens[tab_id] then
        self.tab_screens[tab_id] = self:createTabScreen(tab_id)
    end

    self.stack = { self.tab_screens[tab_id] }
    self:show()
end

function LibraryBrowser:push(screen)
    self:endSelection()
    table.insert(self.stack, screen)
    self:show()
end

function LibraryBrowser:goBack()
    local screen = self:current()
    if screen and screen.selection then
        -- Back ends selecting first
        screen.selection = nil
        self:show()
        return
    end

    if #self.stack <= 1 then
        self:close()
        return
    end

    table.remove(self.stack)
    self:show()
end

function LibraryBrowser:onBack()
    self:goBack()
    return true
end

function LibraryBrowser:turnPage(delta)
    local screen = self:current()
    if not screen.paged or not screen.pages then
        return false
    end

    local page = screen.page + delta
    if page < 1 or page > screen.pages then
        return false
    end

    screen.page = page
    self:show()
    return true
end

function LibraryBrowser:onNextPage()
    return self:turnPage(1)
end

function LibraryBrowser:onPrevPage()
    return self:turnPage(-1)
end

function LibraryBrowser:onSwipe(_, ges)
    local direction = ges.direction
    if direction == "west" then
        return self:turnPage(1)
    elseif direction == "east" then
        return self:turnPage(-1)
    end
    return false
end

function LibraryBrowser:refresh()
    LibraryData.clearCache()
    self.local_paths = self.repository:getGrimmoryBookPaths()

    for _, screen in ipairs(self.stack) do
        screen.items = nil
        screen.loaded_page = nil
        screen.detail = nil
        screen.sections = nil
    end
    for _, screen in pairs(self.tab_screens) do
        screen.items = nil
        screen.loaded_page = nil
        screen.sections = nil
    end

    self:show()
end

-------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------

--- Space left and right of the cover grids: the covers (inset by the cells'
--- padding) line up with the top bar's side margin.
function LibraryBrowser:gridInset()
    return math.max(0, Style.SIDE_MARGIN - Widgets.PADDING)
end

--- Rows and columns of a book page in the current layout.
function LibraryBrowser:getBookGrid(content_h)
    local padding = Widgets.PADDING

    if self.layout == "grid" then
        local grid_w = self.width - 2 * self:gridInset()
        -- About 1.15" wide covers (3 columns on a 6" screen, 5 on 10")
        local cols = math.max(3, math.min(6, math.floor(grid_w / Screen:scaleByDPI(185))))
        local cell_w = math.floor(grid_w / cols)
        local cell_h = Widgets.coverHeight(cell_w - 2 * padding) + Widgets.gridLabelHeight()
            + 4 * padding + Screen:scaleBySize(7)
        -- Round, and let the covers shrink a little to fill the height
        local rows = math.max(1, math.floor(content_h / cell_h + 0.5))
        return { rows = rows, cols = cols, cell_w = cell_w, cell_h = math.floor(content_h / rows) }
    end

    -- About 0.85" high rows
    local rows = math.max(3, math.min(12, math.floor(content_h / Screen:scaleByDPI(140))))
    return { rows = rows, cols = 1, cell_w = self.width, cell_h = math.floor(content_h / rows) }
end

function LibraryBrowser:getCollectionRowHeight(with_covers)
    if with_covers then
        return Screen:scaleByDPI(125)
    end
    -- Name and subtitle with some air
    return Widgets.linesHeight(Widgets.faces.title, 1) + Widgets.linesHeight(Widgets.faces.small, 1)
        + 5 * Widgets.PADDING
end

-------------------------------------------------------------------------------
-- Screens
-------------------------------------------------------------------------------

--- A screen showing books page by page.  `load(page, size, done)` loads one
--- page (0-based) with `size` books and calls `done(ok, LibraryPage|reason)`.
function LibraryBrowser:booksScreen(title, cache_key, load, extra)
    local screen = {
        type = "books",
        title = title,
        paged = true,
        page = 1,
        cache_key = cache_key,
        load = load,
    }
    for key, value in pairs(extra or {}) do
        screen[key] = value
    end
    return screen
end

--- Books of the server's book list with the given filter
function LibraryBrowser:filteredBooksScreen(title, cache_key, params, extra)
    return self:booksScreen(title, cache_key, function(page, size, done)
        local query = { page = page, size = size }
        for key, value in pairs(params) do
            query[key] = value
        end
        self.data:fetch(cache_key .. ":" .. size .. ":" .. page, function()
            return self.api:getAppBooks(query)
        end, done)
    end, extra)
end

--- Books of a fixed list (e.g. "continue reading"), paged on the device
function LibraryBrowser:listBooksScreen(title, cache_key, request)
    return self:booksScreen(title, cache_key, function(page, size, done)
        self.data:fetch(cache_key, request, function(ok, books)
            if not ok then
                done(false, books)
                return
            end
            local items = {}
            for i = page * size + 1, math.min(#books, (page + 1) * size) do
                table.insert(items, books[i])
            end
            done(true, { items = items, total = #books, has_next = (page + 1) * size < #books })
        end)
    end)
end

---@param kind "shelves" | "libraries" | "magic_shelves" | "series"
function LibraryBrowser:collectionBooksScreen(kind, collection)
    local source = { kind = kind, collection = collection }

    if kind == "series" then
        return self:booksScreen(collection.name, "series-books:" .. collection.name, function(page, size, done)
            self.data:fetch("series-books:" .. collection.name .. ":" .. size .. ":" .. page, function()
                return self.api:getAppSeriesBooks(collection.name, page, size)
            end, done)
        end, { source = source, subtitle = _("Series") })
    elseif kind == "magic_shelves" then
        return self:booksScreen(collection.name, "magic:" .. collection.id, function(page, size, done)
            self.data:fetch("magic:" .. collection.id .. ":" .. size .. ":" .. page, function()
                return self.api:getAppMagicShelfBooks(collection.id, page, size)
            end, done)
        end, { source = source, subtitle = _("Magic shelf") })
    end

    local filter = kind == "libraries" and "libraryId" or "shelfId"
    return self:filteredBooksScreen(collection.name, kind .. ":" .. collection.id, {
        [filter] = collection.id,
        sort = "title",
        dir = "asc",
    }, { source = source, subtitle = kind == "libraries" and _("Library") or _("Shelf") })
end

function LibraryBrowser:createTabScreen(tab_id)
    if tab_id == "home" then
        return { type = "home", title = _("Grimmory Library"), tab = "home" }
    elseif tab_id == "books" then
        return self:filteredBooksScreen(
            _("Grimmory Library"), "all", { sort = "title", dir = "asc" }, { tab = "books" }
        )
    elseif tab_id == "series" then
        return {
            type = "collections",
            kind = "series",
            tab = "series",
            title = _("Grimmory Library"),
            paged = true,
            page = 1,
            with_covers = true,
            load = function(page, size, done)
                self.data:fetch("series:" .. size .. ":" .. page, function()
                    return self.api:getAppSeries({ page = page, size = size })
                end, done)
            end,
        }
    elseif tab_id == "shelves" then
        return {
            type = "collections",
            kind = "shelves",
            tab = "shelves",
            title = _("Grimmory Library"),
            paged = true,
            page = 1,
            load = function(page, size, done)
                self.data:fetch("shelves", function()
                    local ok, shelves = self.api:getAppShelves()
                    if not ok then
                        return false, shelves
                    end
                    local magic_ok, magic_shelves = self.api:getAppMagicShelves()
                    local entries = {}
                    for _, shelf in ipairs(shelves) do
                        table.insert(entries, { kind = "shelves", collection = shelf })
                    end
                    -- Older servers may not have magic shelves; show the shelves anyway
                    for _, shelf in ipairs(magic_ok and magic_shelves or {}) do
                        table.insert(entries, { kind = "magic_shelves", collection = shelf })
                    end
                    return true, entries
                end, function(ok, entries)
                    self:pageList(ok, entries, page, size, done)
                end)
            end,
        }
    elseif tab_id == "libraries" then
        return {
            type = "collections",
            kind = "libraries",
            tab = "libraries",
            title = _("Grimmory Library"),
            paged = true,
            page = 1,
            load = function(page, size, done)
                self.data:fetch("libraries", function()
                    local ok, libraries = self.api:getAppLibraries()
                    if not ok then
                        return false, libraries
                    end
                    local entries = {}
                    for _, library in ipairs(libraries) do
                        table.insert(entries, { kind = "libraries", collection = library })
                    end
                    return true, entries
                end, function(ok, entries)
                    self:pageList(ok, entries, page, size, done)
                end)
            end,
        }
    end
end

--- Page a list that was loaded completely
function LibraryBrowser:pageList(ok, entries, page, size, done)
    if not ok then
        done(false, entries)
        return
    end

    local items = {}
    for i = page * size + 1, math.min(#entries, (page + 1) * size) do
        table.insert(items, entries[i])
    end

    done(true, { items = items, total = #entries, has_next = (page + 1) * size < #entries })
end

--- Home rows: continue reading, recently added, then the download sources
function LibraryBrowser:getHomeSections(count)
    local sections = {
        {
            title = _("Continue Reading"),
            load = function(done)
                self.data:fetch("home:continue:" .. count, function()
                    return self.api:getAppContinueReading(count)
                end, done)
            end,
            open = function()
                return self:listBooksScreen(_("Continue Reading"), "continue:50", function()
                    return self.api:getAppContinueReading(50)
                end)
            end,
        },
        {
            title = _("Recently Added"),
            load = function(done)
                self.data:fetch("home:recent:" .. count, function()
                    return self.api:getAppRecentlyAdded(count)
                end, done)
            end,
            open = function()
                return self:filteredBooksScreen(_("Recently Added"), "recent", { sort = "addedOn", dir = "desc" })
            end,
        },
    }

    for _, kind in ipairs({ "shelves", "magic_shelves", "libraries", "series" }) do
        for _, source in ipairs(self.settings:getDownloadSources(kind)) do
            local screen_template = self:collectionBooksScreen(kind, source)
            table.insert(sections, {
                title = source.name,
                load = function(done)
                    screen_template.load(0, count, function(ok, result)
                        done(ok, ok and result.items or result)
                    end)
                end,
                open = function()
                    return self:collectionBooksScreen(kind, source)
                end,
            })
        end
    end

    return sections
end

-------------------------------------------------------------------------------
-- Rendering
-------------------------------------------------------------------------------

function LibraryBrowser:getLocalPath(grimmory_id)
    for _, path in ipairs(self.local_paths[tostring(grimmory_id)] or {}) do
        if lfs.attributes(path, "mode") == "file" then
            return path
        end
    end
    return nil
end

--- Top bar: on a tab, [‹] tabs [search] ... [⋯]; deeper, [‹] screen title
--- ... [⋯].  "‹" on a tab closes the library.
function LibraryBrowser:topBar(screen)
    local opts = {
        width = self.width,
        on_back = function() self:goBack() end,
        on_more = function() self:showMoreMenu(screen) end,
        -- Where the loading indicator is painted (the same place on every screen)
        on_loading_area = function(area)
            self.loading_area = area
        end,
    }

    if screen.selection then
        local count = screen.selection.count
        opts.label = count == 0 and _("Select books") or T(N_("%1 book selected", "%1 books selected", count), count)
        opts.on_more = function() self:showSelectionMenu(screen) end
    elseif #self.stack == 1 then
        opts.tabs = TABS
        opts.selected = screen.tab
        opts.on_select = function(tab_id)
            self:selectTab(tab_id)
        end
        opts.on_search = function()
            self:showSearch(screen)
        end
    else
        opts.label = screen.type == "details" and screen.book.title or screen.title
    end

    return Widgets.topBar(opts)
end

--- The "⋯" menu: layout, refresh, close
function LibraryBrowser:showMoreMenu(screen)
    local sections = {}

    if screen.type == "books" or screen.type == "home" or screen.with_covers then
        table.insert(sections, {
            type = "segments",
            items = {
                {
                    text = _("Grid"),
                    selected = self.layout == "grid",
                    callback = function() self:setLayout("grid") end,
                },
                {
                    text = _("List"),
                    selected = self.layout == "list",
                    callback = function() self:setLayout("list") end,
                },
            },
        })
    end

    local rows = {}
    if screen.type == "books" then
        table.insert(rows, {
            text = _("Select books to download"),
            sui_icon = "select",
            callback = function() self:startSelection(screen) end,
        })
    end
    table.insert(rows, { text = _("Refresh"), sui_icon = "update", callback = function() self:refresh() end })
    table.insert(rows, { text = _("Close library"), sui_icon = "close", callback = function() self:close() end })
    table.insert(sections, Sheet.list(rows))

    Sheet.show({
        title = _("Grimmory Library"),
        icon = "library",
        fit_width = true,
        auto_close = true,
        sections = sections,
    })
end

--- Rebuild the whole screen for the current state.  Loads what is missing
--- (showing the loading indicator meanwhile) and then shows it.
function LibraryBrowser:show()
    self:cancelCovers()

    local screen = self:current()
    local parts = VerticalGroup:new({ align = "left" })

    table.insert(parts, self:topBar(screen))

    if screen.source then
        table.insert(parts, self:downloadSourceBar(screen.source))
        if screen.source.kind == "series" and self.settings:getSmartDownloadMode() ~= "off" then
            table.insert(parts, self:smartDownloadBar(screen.source.collection))
        end
    end

    local content_h = self.height - parts:getSize().h - (screen.paged and Widgets.footerHeight() or 0)

    if not self.connected then
        if self.connect_error then
            self:showMessage(screen, content_h, self.connect_error, function()
                self:startConnecting()
                self:show()
            end)
        else
            self:showMessage(screen, content_h, _("Connecting…"))
        end
        return
    end

    local content
    if screen.type == "home" then
        content = self:homeContent(screen, content_h)
    elseif screen.type == "details" then
        content = self:detailsContent(screen, content_h)
    else
        content = self:pagedContent(screen, content_h)
    end

    if not content then
        -- Loading started; show() is called again when it is done
        return
    end

    table.insert(parts, content)

    if screen.paged then
        table.insert(parts, self:footer(screen))
    end

    -- Children were added after measuring: drop the cached layout
    parts:resetLayout()

    self[1] = FrameContainer:new({
        width = self.width,
        height = self.height,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        parts,
    })

    self:hideLoadingIndicator()

    UIManager:setDirty(self, function()
        return "ui", self.dimen, true
    end)

    self:loadCovers()
end

--- Show a message (loading / error) as content
function LibraryBrowser:showMessage(screen, content_h, text, retry)
    local message = Widgets.message({
        width = self.width,
        height = content_h,
        text = text,
        button_text = retry and _("Retry") or nil,
        on_button = retry,
    })

    local parts = VerticalGroup:new({ align = "left" })
    table.insert(parts, self:topBar(screen))
    table.insert(parts, message)
    self:hideLoadingIndicator()

    self[1] = FrameContainer:new({
        width = self.width,
        height = self.height,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        parts,
    })
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function LibraryBrowser:pagedContent(screen, content_h)
    local grid
    local size

    if screen.type == "books" or (screen.with_covers and self.layout == "grid") then
        grid = self:getBookGrid(content_h)
        size = grid.rows * grid.cols
    else
        local row_h = self:getCollectionRowHeight(screen.with_covers)
        local rows = math.max(1, math.floor(content_h / row_h))
        grid = { rows = rows, cols = 1, cell_w = self.width, cell_h = math.floor(content_h / rows) }
        size = rows
    end

    -- Page size changed (layout switch / rotation): keep the first item shown
    if screen.size and screen.size ~= size then
        local first_index = (screen.page - 1) * screen.size
        screen.page = math.floor(first_index / size) + 1
        screen.loaded_page = nil
    end
    screen.size = size

    if screen.loaded_page ~= screen.page then
        local requested_page = screen.page
        local waiting = false
        local answer = nil

        -- A cached page answers synchronously (no loading indicator); a
        -- network answer arrives later and shows the screen again.
        screen.load(requested_page - 1, size, function(ok, result)
            if not waiting then
                answer = { ok = ok, result = result }
                return
            end
            if self:current() == screen and screen.page == requested_page then
                self:applyPage(screen, requested_page, ok, result, content_h)
            end
        end)

        if not answer then
            -- Reconnecting first; shown again when the answer arrives
            waiting = true
            self:showMessage(screen, content_h, _("Connecting…"))
            return nil
        end

        if not answer.ok then
            self:showMessage(screen, content_h, answer.result, function() self:show() end)
            return nil
        end

        screen.items = answer.result.items
        screen.total = answer.result.total
        screen.pages = math.max(1, math.ceil((answer.result.total or #answer.result.items) / size))
        screen.loaded_page = requested_page
    end

    return self:pageWidget(screen, grid)
end

function LibraryBrowser:applyPage(screen, requested_page, ok, result, content_h)
    if not ok then
        self:showMessage(screen, content_h, result, function() self:show() end)
        return
    end

    screen.items = result.items
    screen.total = result.total
    screen.pages = math.max(1, math.ceil((result.total or #result.items) / screen.size))
    screen.loaded_page = requested_page
    self:show()
end

function LibraryBrowser:pageWidget(screen, grid)
    self.visible_covers = {}
    local items = screen.items or {}

    if #items == 0 then
        return Widgets.message({
            width = self.width,
            height = grid.rows * grid.cell_h,
            text = _("Nothing here"),
        })
    end

    local rows = VerticalGroup:new({ align = "left" })
    local row = nil

    for index, entry in ipairs(items) do
        local widget = self:entryWidget(screen, entry, grid)

        if grid.cols == 1 then
            table.insert(rows, widget)
        else
            if (index - 1) % grid.cols == 0 then
                row = HorizontalGroup:new({ align = "top", HorizontalSpan:new({ width = self:gridInset() }) })
                table.insert(rows, row)
            end
            table.insert(row, widget)
        end

        if widget.cover then
            table.insert(self.visible_covers, widget.cover)
        end
    end

    return TopContainer:new({
        dimen = Geom:new({ w = self.width, h = grid.rows * grid.cell_h }),
        VerticalGroup:new({ align = "left", rows }),
    })
end

function LibraryBrowser:entryWidget(screen, entry, grid)
    if screen.type == "books" then
        local opts = {
            width = grid.cell_w,
            height = grid.cell_h,
            on_device = self:getLocalPath(entry.id) ~= nil,
            on_tap = function()
                self:openDetails(entry)
            end,
            on_hold = function()
                self:showBookSheet(entry, screen)
            end,
        }
        if screen.selection then
            -- A check box on the books that can be selected
            if self:isSelectable(entry) then
                opts.selected = screen.selection.ids[tostring(entry.id)] ~= nil
            end
            opts.on_tap = function()
                self:toggleSelected(screen, entry)
            end
            opts.on_hold = opts.on_tap
        end
        if self.layout == "grid" then
            return Widgets.bookGridCell(entry, opts)
        end
        return Widgets.bookListItem(entry, opts)
    end

    -- Series, shelves, libraries
    local kind = screen.kind == "series" and "series" or entry.kind
    local collection = screen.kind == "series" and entry or entry.collection
    local id_or_name = kind == "series" and collection.name or collection.id
    local is_source = self.settings:isDownloadSource(kind, id_or_name)

    local subtitle
    if kind == "series" then
        subtitle = T(_("%1 books"), collection.book_count or "?")
        if collection.authors and #collection.authors > 0 then
            subtitle = subtitle .. " · " .. table.concat(collection.authors, ", ")
        end
    elseif kind == "magic_shelves" then
        subtitle = _("Magic shelf")
    elseif collection.book_count then
        subtitle = T(_("%1 books"), collection.book_count)
    end

    local cover = (kind == "series" and collection.cover_book_id) and {
        book_id = collection.cover_book_id,
        cover_updated_on = collection.cover_updated_on,
    } or nil

    local function open()
        self:push(self:collectionBooksScreen(kind, collection))
    end

    local function actions()
        self:showCollectionSheet(kind, collection)
    end

    if grid.cols > 1 then
        return Widgets.collectionGridCell({
            width = grid.cell_w,
            height = grid.cell_h,
            title = collection.name,
            subtitle = (is_source and "⇩ " or "") .. T(_("%1 books"), collection.book_count or "?"),
            cover = cover,
            on_tap = open,
            on_hold = actions,
        })
    end

    return Widgets.collectionRow({
        width = grid.cell_w,
        height = grid.cell_h,
        title = collection.name,
        subtitle = subtitle,
        badge = is_source and _("⇩ Auto") or nil,
        cover = cover,
        on_tap = open,
        on_hold = actions,
    })
end

local HOME_SECTIONS = 3

function LibraryBrowser:homeContent(screen, content_h)
    local padding = Widgets.PADDING
    local section_header_h = Widgets.sectionHeader({ width = self.width, title = "Ag" }):getSize().h
    local max_sections = HOME_SECTIONS

    -- Size the covers so that three rows fit
    local title_h = Widgets.gridLabelHeight()
    local cell_h = math.floor(content_h / max_sections) - section_header_h
    local cover_h = cell_h - title_h - 4 * padding - Screen:scaleBySize(5)
    local cell_w = Widgets.coverWidth(cover_h) + 2 * padding
    local grid_w = self.width - 2 * self:gridInset()
    local cols = math.max(3, math.floor(grid_w / cell_w))
    cell_w = math.floor(grid_w / cols)

    if not screen.sections then
        local definitions = self:getHomeSections(cols)
        local sections = {}
        local index = 0
        local finished = false

        -- Load the sections one after another, then show them
        local function load_next()
            index = index + 1
            local definition = definitions[index]
            if not definition or #sections >= max_sections then
                finished = true
                if self:current() == screen then
                    screen.sections = sections
                    self:show()
                end
                return
            end

            definition.load(function(ok, books)
                if not ok then
                    if index == 1 then
                        -- The first request failing means no connection / server
                        finished = true
                        self:showMessage(screen, content_h, books, function() self:show() end)
                        return
                    end
                    logger:warn("Home section failed:", definition.title, books)
                elseif #books > 0 then
                    table.insert(sections, { definition = definition, books = books })
                end
                load_next()
            end)
        end

        load_next()

        if not finished then
            -- Still waiting (reconnecting); shown again when done
            self:showMessage(screen, content_h, _("Connecting…"))
        end
        return nil
    end

    self.visible_covers = {}

    if #screen.sections == 0 then
        return Widgets.message({
            width = self.width,
            height = content_h,
            text = _("Nothing to show yet. Browse the Books, Series, Shelves and Libraries tabs."),
        })
    end

    local group = VerticalGroup:new({ align = "left" })
    for _, section in ipairs(screen.sections) do
        table.insert(group, Widgets.sectionHeader({
            width = self.width,
            title = section.definition.title,
            on_tap = function()
                self:push(section.definition.open())
            end,
        }))

        local row = HorizontalGroup:new({ align = "top", HorizontalSpan:new({ width = self:gridInset() }) })
        for i = 1, math.min(cols, #section.books) do
            local book = section.books[i]
            local cell = Widgets.bookGridCell(book, {
                width = cell_w,
                height = cell_h,
                on_device = self:getLocalPath(book.id) ~= nil,
                on_tap = function()
                    self:openDetails(book)
                end,
                on_hold = function()
                    self:showBookSheet(book)
                end,
            })
            table.insert(row, cell)
            table.insert(self.visible_covers, cell.cover)
        end
        table.insert(group, row)
    end

    return TopContainer:new({
        dimen = Geom:new({ w = self.width, h = content_h }),
        group,
    })
end

-------------------------------------------------------------------------------
-- Covers
-------------------------------------------------------------------------------

function LibraryBrowser:cancelCovers()
    if self.cancel_cover_download then
        self.cancel_cover_download()
        self.cancel_cover_download = nil
    end
end

--- Download the covers of the shown page that are not on the device yet
function LibraryBrowser:loadCovers()
    local slots_by_id = {}
    local requests = {}

    for _, slot in ipairs(self.visible_covers or {}) do
        if slot.book_id and not slot:hasCover() then
            local key = tostring(slot.book_id) .. (slot.full and "f" or "")
            if not slots_by_id[key] then
                slots_by_id[key] = {}
                table.insert(requests, { id = slot.book_id, path = slot:getCoverPath(), full = slot.full, key = key })
            end
            table.insert(slots_by_id[key], slot)
        end
    end

    if #requests == 0 then
        return
    end

    local by_id = {}
    for _, request in ipairs(requests) do
        by_id[request.id] = by_id[request.id] or {}
        table.insert(by_id[request.id], request.key)
    end

    self.cancel_cover_download = Covers.download(self.executor, self.api, requests, function(book_id)
        for _, key in ipairs(by_id[book_id] or {}) do
            for _, slot in ipairs(slots_by_id[key] or {}) do
                if slot:hasCover() then
                    slot:update()
                    local region = slot.painted_at
                    UIManager:setDirty(self, function()
                        return "ui", region or self.dimen, true
                    end)
                end
            end
        end
    end)
end

-------------------------------------------------------------------------------
-- Download sources
-------------------------------------------------------------------------------

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

    -- Answered synchronously unless reconnecting; then the screen is shown
    -- again anyway once connected, with the answer cached.
    self.data:fetch("series-in-progress", function()
        return self.api:getAppSeriesInProgress()
    end, function(ok, names)
        if ok then
            for _, name in ipairs(names) do
                if name == series_name then
                    in_progress = true
                    break
                end
            end
        end
    end)

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

-------------------------------------------------------------------------------
-- Long press sheets
-------------------------------------------------------------------------------

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

-------------------------------------------------------------------------------
-- Selecting books and downloading them together
-------------------------------------------------------------------------------

--- Books that can be selected: with a file, and not on the device yet
function LibraryBrowser:isSelectable(book)
    return book.primary_file_name ~= nil and self:getLocalPath(book.id) == nil
end

---@param book LibraryBook | nil Selected right away
function LibraryBrowser:startSelection(screen, book)
    screen.selection = { ids = {}, order = {}, count = 0 }
    if book then
        self:toggleSelected(screen, book)
    else
        self:show()
    end
end

local function setSelected(selection, book, selected)
    local key = tostring(book.id)
    if selected and not selection.ids[key] then
        selection.ids[key] = book
        table.insert(selection.order, key)
        selection.count = selection.count + 1
    elseif not selected and selection.ids[key] then
        selection.ids[key] = nil
        for i, order_key in ipairs(selection.order) do
            if order_key == key then
                table.remove(selection.order, i)
                break
            end
        end
        selection.count = selection.count - 1
    end
end

function LibraryBrowser:toggleSelected(screen, book)
    local selection = screen.selection
    if not selection then
        return
    end

    if not self:isSelectable(book) then
        self.dialog_manager:notify(book.primary_file_name and _("Already on this device.")
            or _("No file to download"), 2)
        return
    end

    setSelected(selection, book, selection.ids[tostring(book.id)] == nil)
    self:show()
end

--- Select (or deselect) the selectable books of the page shown
function LibraryBrowser:selectPage(screen, selected)
    for _, book in ipairs(screen.items or {}) do
        if self:isSelectable(book) then
            setSelected(screen.selection, book, selected)
        end
    end
    self:show()
end

function LibraryBrowser:showSelectionMenu(screen)
    local count = screen.selection.count
    Sheet.show({
        title = _("Select books"),
        icon = "select",
        fit_width = true,
        auto_close = true,
        sections = {
            Sheet.list({
                { text = _("Select all on this page"), sui_icon = "select_all", callback = function()
                    self:selectPage(screen, true)
                end },
                { text = _("Deselect all on this page"), sui_icon = "deselect", callback = function()
                    self:selectPage(screen, false)
                end },
                {
                    text = T(_("Download (%1)"), count),
                    sui_icon = "import",
                    enabled = count > 0,
                    callback = function() self:downloadSelected(screen) end,
                },
                { text = _("Stop selecting"), sui_icon = "close", callback = function()
                    screen.selection = nil
                    self:show()
                end },
            }),
        },
    })
end

--- The bar at the bottom of a paged screen: pager, selection, or the
--- progress of a batch download
function LibraryBrowser:footer(screen)
    local on_page = function(page) self:turnPage(page - screen.page) end

    if screen.batch then
        return Widgets.footerWith(self:downloadProgressWidget(screen, self.width - 2 * Style.SIDE_MARGIN), self.width)
    elseif screen.selection then
        return Widgets.selectionFooter({
            width = self.width,
            page = screen.page,
            pages = screen.pages or 1,
            on_page = on_page,
            count = screen.selection.count,
            on_cancel = function()
                screen.selection = nil
                self:show()
            end,
            on_download = function()
                self:downloadSelected(screen)
            end,
        })
    end

    return Widgets.footer({
        width = self.width,
        page = screen.page,
        pages = screen.pages or 1,
        on_page = on_page,
    })
end

--- Download the selected books one after another (in one background run),
--- with the progress in the bottom bar and a summary at the end.
function LibraryBrowser:downloadSelected(screen)
    local selection = screen.selection
    if not selection or selection.count == 0 then
        return
    end

    if self.is_sync_running() then
        self.dialog_manager:notify(_("A sync is running. Please try again when it has finished."), 3)
        return
    end
    if self.batch_running then
        self.dialog_manager:notify(_("Books are being downloaded. Please wait until they are done."), 3)
        return
    end

    local books = {}
    for _, key in ipairs(selection.order) do
        table.insert(books, selection.ids[key])
    end

    screen.selection = nil
    screen.batch = { index = 1, total = #books, title = books[1].title }
    screen.download_fraction = 0
    self.batch_running = true
    self:show()

    self.executor:background(function(run)
        local run_ok, ok, results = pcall(run, function(report)
            local results = {}
            for index, book in ipairs(books) do
                report({ batch_index = index })
                local download_ok, path = pcall(function()
                    return self.synchronizer:downloadLibraryBook(book.id, function(bytes, total)
                        report({ download_bytes = bytes, download_total = total })
                    end)
                end)
                table.insert(results, {
                    path = (download_ok and type(path) == "string") and path or nil,
                    error = (not download_ok) and tostring(path) or nil,
                })
            end
            return results
        end, function(state)
            if type(state) ~= "table" then
                return
            end
            local batch = screen.batch
            if not batch then
                return
            end
            if state.batch_index then
                batch.index = state.batch_index
                batch.title = books[state.batch_index].title
                batch.book_fraction = 0
            elseif state.download_bytes then
                local total = state.download_total
                    or ((books[batch.index].file_size_kb or 0) * 1024)
                batch.book_fraction = total > 0 and math.min(1, state.download_bytes / total) or 0
            end
            screen.download_fraction = ((batch.index - 1) + (batch.book_fraction or 0)) / batch.total
            self:updateDownloadProgress(screen)
        end)

        self.batch_running = false
        screen.batch = nil
        self.download_widgets = nil

        if not run_ok or not ok or type(results) ~= "table" then
            local error_result = run_ok and results or ok
            logger:err("Downloading the selected books failed:", error_result)
            UIManager:show(InfoMessage:new({
                text = T(_("Could not download the books:\n%1"), LibraryData.describeError(error_result)),
            }))
            if self:current() == screen then
                self:show()
            end
            return
        end

        local failed = {}
        local downloaded = 0
        for index, result in ipairs(results) do
            local book = books[index]
            if result.path then
                downloaded = downloaded + 1
                -- Keep them on the device even if they are in no download source
                self.settings:setKeptBook(book.id, true)
                local paths = self.local_paths[tostring(book.id)] or {}
                table.insert(paths, 1, result.path)
                self.local_paths[tostring(book.id)] = paths
            else
                logger:err("Book download failed:", book.id, result.error)
                table.insert(failed, book.title)
            end
        end

        -- The downloads ran in a subprocess: reload what they changed
        ReadCollection.last_read_time = 0
        pcall(ReadCollection._read, ReadCollection)
        UIManager:broadcastEvent(Event:new("RefreshContent"))

        if #failed == 0 then
            self.dialog_manager:notify(T(N_("Grimmory: downloaded %1 book", "Grimmory: downloaded %1 books",
                downloaded), downloaded), 3)
        else
            UIManager:show(InfoMessage:new({
                text = T(_("Downloaded %1 of %2 books. Could not download:\n%3"),
                    downloaded, #books, table.concat(failed, "\n")),
            }))
        end

        if self:current() == screen then
            self:show()
        end
    end, true)
end

-------------------------------------------------------------------------------
-- Search
-------------------------------------------------------------------------------

function LibraryBrowser:showSearch(screen)
    local search_series = screen.kind == "series"
    local dialog

    dialog = InputDialog:new({
        title = search_series and _("Search series") or _("Search books"),
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
                        if text == "" then
                            return
                        end

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
                },
            },
        },
    })

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function LibraryBrowser:setLayout(layout)
    self.layout = layout
    self.settings:setBrowserLayout(layout)
    self:show()
end

-------------------------------------------------------------------------------
-- Book details
-------------------------------------------------------------------------------

---@param book LibraryBook
function LibraryBrowser:openDetails(book)
    self:push({ type = "details", title = "", book = book })
end

function LibraryBrowser:detailsContent(screen, content_h)
    local book = screen.book
    local padding = Widgets.PADDING
    local width = self.width
    local local_path = self:getLocalPath(book.id)

    -- Description and shelves come with the details request; show the page
    -- right away and fill them in when they arrive.
    if not screen.detail and not screen.detail_requested then
        screen.detail_requested = true
        UIManager:nextTick(function()
            self.data:fetch("detail:" .. book.id, function()
                return self.api:getAppBookDetail(book.id)
            end, function(ok, detail)
                screen.detail = ok and detail or { description = nil, failed = true }
                if self:current() == screen then
                    self:show()
                end
            end)
        end)
    end

    local cover_w = math.floor(width * 0.38)
    local cover_h = Widgets.coverHeight(cover_w)
    local cover = Widgets.CoverSlot:new({
        width = cover_w,
        height = cover_h,
        book_id = book.id,
        cover_updated_on = book.cover_updated_on,
        title = book.title,
        full = true,
    })
    self.visible_covers = { cover }

    local margin = Style.SIDE_MARGIN
    local info_w = width - cover_w - 2 * margin - 2 * padding
    local info = VerticalGroup:new({
        align = "left",
        TextBoxWidget:new({
            text = book.title,
            face = Style.face(Style.FS_TITLE),
            bold = true,
            width = info_w,
        }),
    })

    local function add_line(text, size, color)
        if text and text ~= "" then
            table.insert(info, VerticalSpan:new({ width = math.floor(padding / 2) }))
            table.insert(info, TextBoxWidget:new({
                text = text,
                face = Style.face(size),
                width = info_w,
                fgcolor = color,
            }))
        end
    end

    if #book.authors > 0 then
        add_line(table.concat(book.authors, ", "), Style.FS_BODY)
    end
    add_line(Widgets.seriesText(book), Style.FS_DETAIL, Style.COLOR.text_secondary)

    local facts = {}
    if book.primary_file_type then
        table.insert(facts, book.primary_file_type:upper())
    end
    table.insert(facts, Widgets.formatSize(book.file_size_kb))
    if book.page_count then
        table.insert(facts, T(_("%1 pages"), book.page_count))
    end
    if book.published_date then
        table.insert(facts, book.published_date:sub(1, 4))
    end
    add_line(table.concat(facts, " · "), Style.FS_DETAIL, Style.COLOR.text_secondary)

    if screen.detail and screen.detail.library_name then
        add_line(T(_("Library: %1"), screen.detail.library_name), Style.FS_DETAIL, Style.COLOR.text_secondary)
    end

    if book.read_progress and book.read_progress > 0 then
        table.insert(info, VerticalSpan:new({ width = 2 * padding }))
        table.insert(info, HorizontalGroup:new({
            align = "center",
            ProgressWidget:new({
                width = math.floor(info_w * 0.7),
                height = Screen:scaleBySize(8),
                percentage = math.min(1, book.read_progress / 100),
                margin_h = 0,
                margin_v = 0,
                radius = Screen:scaleBySize(4),
                bordersize = 0,
                bgcolor = Style.COLOR.track,
                fillcolor = Style.COLOR.text,
            }),
            TextWidget:new({
                text = string.format("  %d%%", math.floor(book.read_progress + 0.5)),
                face = Style.face(Style.FS_DETAIL),
            }),
        }))
    end

    if local_path then
        table.insert(info, VerticalSpan:new({ width = padding }))
        local icon = Screen:scaleBySize(20)
        table.insert(info, HorizontalGroup:new({
            align = "center",
            Style.glyph("tick", icon),
            HorizontalSpan:new({ width = padding }),
            TextWidget:new({ text = _("On this device"), face = Style.face(Style.FS_DETAIL) }),
        }))
    end

    -- Actions as SimpleUI's segments: the main one black, a progress bar
    -- in its place while downloading
    local button_w = width - 2 * margin
    local primary

    if screen.downloading then
        primary = self:downloadProgressWidget(screen, button_w)
    else
        primary = Widgets.segments({
            {
                text = local_path and _("Read") or _("Download & read"),
                selected = true,
                enabled = local_path ~= nil or book.primary_file_name ~= nil,
                callback = function()
                    if local_path then
                        self:openBook(local_path)
                    else
                        self:downloadBook(screen, true)
                    end
                end,
            },
        }, button_w)
    end

    local secondary_buttons = {}
    if local_path then
        table.insert(secondary_buttons, {
            text = _("Delete from device"),
            callback = function() self:confirmDelete(screen, local_path) end,
        })
    elseif book.primary_file_name then
        table.insert(secondary_buttons, {
            text = _("Download only"),
            enabled = not screen.downloading,
            callback = function() self:downloadBook(screen, false) end,
        })
    end
    if book.series_name then
        table.insert(secondary_buttons, {
            text = _("Series"),
            callback = function()
                self:push(self:collectionBooksScreen("series", { name = book.series_name }))
            end,
        })
    end

    local top = HorizontalGroup:new({
        align = "top",
        HorizontalSpan:new({ width = margin }),
        cover,
        HorizontalSpan:new({ width = 2 * padding }),
        info,
    })

    local body = VerticalGroup:new({
        align = "left",
        VerticalSpan:new({ width = 2 * padding }),
        top,
        VerticalSpan:new({ width = 3 * padding }),
        HorizontalGroup:new({ HorizontalSpan:new({ width = margin }), primary }),
    })

    if #secondary_buttons > 0 then
        table.insert(body, VerticalSpan:new({ width = Screen:scaleBySize(10) }))
        table.insert(body, HorizontalGroup:new({
            HorizontalSpan:new({ width = margin }),
            Widgets.segments(secondary_buttons, button_w),
        }))
    end

    table.insert(body, VerticalSpan:new({ width = 2 * padding }))
    table.insert(body, HorizontalGroup:new({
        HorizontalSpan:new({ width = margin }),
        LineWidget:new({
            dimen = Geom:new({ w = button_w, h = Size.line.thin }),
            background = Style.COLOR.separator,
        }),
    }))
    table.insert(body, VerticalSpan:new({ width = 2 * padding }))

    local description_h = content_h - body:getSize().h - padding
    body:resetLayout()
    if description_h > Widgets.faces.text.size * 3 then
        local description
        if screen.detail then
            description = screen.detail.description and Widgets.plainText(screen.detail.description)
                or (screen.detail.failed and _("Could not load the description.") or _("No description."))
        else
            description = _("Loading description…")
        end

        table.insert(body, HorizontalGroup:new({
            HorizontalSpan:new({ width = margin }),
            ScrollTextWidget:new({
                text = description,
                face = Style.face(Style.FS_DETAIL + 1),
                width = button_w,
                height = description_h,
                dialog = self,
            }),
        }))
    end

    return TopContainer:new({
        dimen = Geom:new({ w = width, h = content_h }),
        body,
    })
end

local function downloadProgressText(bytes, total)
    if not bytes or bytes <= 0 then
        return _("Downloading…")
    end
    local done = Widgets.formatSize(math.floor(bytes / 1024))
    if total and total > 0 then
        return T(_("Downloading… %1 % (%2 of %3)"),
            math.min(99, math.floor(100 * bytes / total)), done, Widgets.formatSize(math.floor(total / 1024)))
    end
    return T(_("Downloading… %1"), done)
end

--- The progress text of a screen: one book, or "2 of 5: title" of a batch
local function screenProgressText(screen)
    local batch = screen.batch
    if batch then
        return T(_("Downloading %1 of %2: %3"), batch.index, batch.total, batch.title)
    end
    return downloadProgressText(screen.download_bytes, screen.download_total)
end

--- Progress bar and text shown instead of the "Download & read" button
function LibraryBrowser:downloadProgressWidget(screen, width)
    local bar = ProgressWidget:new({
        width = width,
        height = Screen:scaleBySize(16),
        percentage = screen.download_fraction or 0,
        margin_h = 0,
        margin_v = 0,
        radius = Size.radius.button,
    })
    local label = TextWidget:new({
        text = screenProgressText(screen),
        face = Widgets.faces.text,
        max_width = width,
    })

    local tracker = Widgets.PaintTracker:new({
        VerticalGroup:new({
            align = "center",
            bar,
            VerticalSpan:new({ width = Widgets.PADDING }),
            -- Fixed width, so the refreshed area covers longer texts too
            CenterContainer:new({
                dimen = Geom:new({ w = width, h = label:getSize().h }),
                label,
            }),
        }),
    })

    self.download_widgets = { screen = screen, bar = bar, label = label, tracker = tracker }
    return tracker
end

--- Update the progress bar in place (refreshing only its area)
function LibraryBrowser:updateDownloadProgress(screen)
    local widgets = self.download_widgets
    if not widgets or widgets.screen ~= screen or self:current() ~= screen then
        return
    end

    widgets.bar:setPercentage(screen.download_fraction or 0)
    widgets.label:setText(screenProgressText(screen))

    local region = widgets.tracker.painted_at
    if region then
        UIManager:setDirty(self, function()
            return "ui", region
        end)
    end
end

function LibraryBrowser:openBook(path)
    self:close()

    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
end

function LibraryBrowser:downloadBook(screen, open_after)
    local book = screen.book

    if self.is_sync_running() then
        UIManager:show(InfoMessage:new({
            text = _("A sync is running. Please try again when it has finished."),
            timeout = 3,
        }))
        return
    end

    screen.downloading = true
    screen.download_bytes = nil
    screen.download_total = book.file_size_kb and book.file_size_kb * 1024 or nil
    screen.download_fraction = 0
    self:show()

    self.executor:background(function(run)
        local run_ok, ok, result = pcall(run, function(report)
            return self.synchronizer:downloadLibraryBook(book.id, function(bytes, total)
                report({ download_bytes = bytes, download_total = total })
            end)
        end, function(state)
            if type(state) ~= "table" or not state.download_bytes then
                return
            end
            screen.download_bytes = state.download_bytes
            screen.download_total = state.download_total or screen.download_total
            if screen.download_total and screen.download_total > 0 then
                screen.download_fraction = math.min(0.99, state.download_bytes / screen.download_total)
            end
            self:updateDownloadProgress(screen)
        end)

        screen.downloading = false
        self.download_widgets = nil

        if not run_ok or not ok or type(result) ~= "string" then
            local error_result = run_ok and result or ok
            logger:err("Book download failed:", book.id, error_result)
            UIManager:show(InfoMessage:new({
                text = T(_("Could not download “%1”:\n%2"), book.title, LibraryData.describeError(error_result)),
            }))
            if self:current() == screen then
                self:show()
            end
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
            if self:current() == screen then
                self:show()
            end
        end
    end, true)
end

function LibraryBrowser:confirmDelete(screen, path)
    local book = screen.book

    Sheet.confirm({
        title = _("Delete from device?"),
        icon = "delete",
        message = T(
            _("“%1” is removed from this device. If it is in a download source, the next sync downloads it again."),
            book.title
        ),
        ok_text = _("Delete"),
        ok_callback = function()
            self.synchronizer:removeBook(path)
            self.settings:setKeptBook(book.id, false)

            ReadCollection:write()
            UIManager:broadcastEvent(Event:new("RefreshContent"))

            self:show()
        end,
    })
end

return LibraryBrowser

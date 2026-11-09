--[[
Library browser: drawing a screen (top bar, pages of books and collections,
home rows, footer) and its covers.  Methods of LibraryBrowser
(grimmory/ui/library/browser.lua).
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local N_ = _.ngettext

local T = require("ffi/util").template

local Covers = require("grimmory/ui/library/covers")
local Sheet = require("grimmory/ui/sheet")
local Widgets = require("grimmory/ui/library/widgets")
local GrimmoryLogger = require("grimmory/logger")
local HttpClient = require("grimmory/http_client")

local logger = GrimmoryLogger:new()
local Screen = Device.screen

---@class LibraryBrowserMethods
local LibraryBrowser = {}

local TABS = {
    { id = "home", text = _("Home") },
    { id = "books", text = _("Books") },
    { id = "series", text = _("Series") },
    { id = "shelves", text = _("Shelves") },
    { id = "libraries", text = _("Libraries") },
}

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
        if self._navbar_container then
            -- SimpleUI's bottom bar leaves the library (as in SimpleUI's own
            -- library, no "‹" on the top level)
            opts.on_back = nil
        end
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
    -- A "Loading…" still to come is for an older state
    self.loading_token = nil

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
                HttpClient.forgetUnreachable()
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

    self:setContent(parts)

    self:hideLoadingIndicator()

    UIManager:setDirty(self, function()
        return "ui", self:contentRegion(), true
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

    self:setContent(parts)
    UIManager:setDirty(self, function() return "ui", self:contentRegion() end)
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
        if screen.loading_page == requested_page and screen.loading_size == size then
            -- Already asked (e.g. left and opened again meanwhile)
            self:showLoading(screen, content_h)
            return nil
        end

        local waiting = false
        local answer = nil

        -- A cached page answers synchronously (no loading indicator); a
        -- network answer arrives later and shows the screen again.
        screen.loading_page, screen.loading_size = requested_page, size
        screen.load(requested_page - 1, size, function(ok, result)
            if screen.loading_page == requested_page and screen.loading_size == size then
                screen.loading_page, screen.loading_size = nil, nil
            end
            if not waiting then
                answer = { ok = ok, result = result }
                return
            end
            if not self.closed and self:current() == screen and screen.page == requested_page
                and screen.size == size then
                self:applyPage(screen, requested_page, ok, result, content_h)
            end
        end)

        if not answer then
            -- Shown again when the answer arrives
            waiting = true
            self:showLoading(screen, content_h)
            return nil
        end

        if not answer.ok then
            self:showMessage(screen, content_h, answer.result, function() self:retry() end)
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
        self:showMessage(screen, content_h, result, function() self:retry() end)
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

    if not screen.sections and screen.home_loading then
        -- Still loading (e.g. left and opened again meanwhile)
        self:showLoading(screen, content_h)
        return nil
    end

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
                screen.home_loading = nil
                screen.sections = sections
                if not self.closed and self:current() == screen then
                    self:show()
                end
                return
            end

            definition.load(function(ok, books)
                if not ok then
                    if index == 1 then
                        -- The first request failing means no connection / server
                        finished = true
                        screen.home_loading = nil
                        if not self.closed and self:current() == screen then
                            self:showMessage(screen, content_h, books, function() self:retry() end)
                        end
                        return
                    end
                    logger:warn("Home section failed:", definition.title, books)
                elseif #books > 0 then
                    table.insert(sections, { definition = definition, books = books })
                end
                load_next()
            end)
        end

        screen.home_loading = true
        load_next()

        if not finished then
            -- Shown again when done
            self:showLoading(screen, content_h)
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


-- Seconds to collect arriving covers before showing them (see loadCovers)
local COVER_REFRESH_DELAY = 0.5

function LibraryBrowser:cancelCovers()
    if self.cancel_cover_download then
        self.cancel_cover_download()
        self.cancel_cover_download = nil
    end
    -- The next screen is shown (refreshed) as a whole anyway
    if self.cover_refresh then
        UIManager:unschedule(self.cover_refresh)
        self.cover_refresh = nil
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

    -- Covers arriving close together are shown with one refresh of the area
    -- around them: many small e-ink refreshes in quick succession flicker,
    -- and on PocketBook they can collide (parts of the screen are left as
    -- they were).  Also, the first one comes well after the page's own.
    local pending_regions = {}
    local function flush()
        self.cover_refresh = nil
        if self.closed or #pending_regions == 0 then
            return
        end
        local region = pending_regions[1]:copy()
        for i = 2, #pending_regions do
            region = region:combine(pending_regions[i])
        end
        pending_regions = {}
        UIManager:setDirty(self, function()
            return "ui", region, true
        end)
    end

    self.cancel_cover_download = Covers.download(self.executor, self.api, requests, function(book_id)
        for _, key in ipairs(by_id[book_id] or {}) do
            for _, slot in ipairs(slots_by_id[key] or {}) do
                if slot:hasCover() then
                    slot:update()
                    table.insert(pending_regions, slot.painted_at or self:contentRegion())
                end
            end
        end
        if not self.cover_refresh and #pending_regions > 0 then
            self.cover_refresh = flush
            UIManager:scheduleIn(COVER_REFRESH_DELAY, flush)
        end
    end)
end

return LibraryBrowser

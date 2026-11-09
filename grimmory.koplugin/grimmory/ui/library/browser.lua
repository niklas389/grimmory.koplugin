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
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local IconWidget = require("ui/widget/iconwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Covers = require("grimmory/ui/library/covers")
local LibraryData = require("grimmory/ui/library/data")
local SimpleUIIntegration = require("grimmory/simpleui")
local Style = require("grimmory/ui/style")
local Widgets = require("grimmory/ui/library/widgets")
local HttpClient = require("grimmory/http_client")

local Screen = Device.screen

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
        after_requests = function()
            self:loadingFinished()
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
    self.data:cancelAll()

    if self.release_wifi then
        self.release_wifi()
        self.release_wifi = nil
    end
end

function LibraryBrowser:close()
    UIManager:close(self)
end

--- SimpleUI closes the browser this way when another tab of its bottom bar
--- is tapped.
function LibraryBrowser:onClose()
    self:close()
    return true
end

--- SimpleUI put its bars around the browser (grimmory/simpleui.lua): show
--- the screen again in the area between them.
function LibraryBrowser:onNavbarInjected()
    local top, height = SimpleUIIntegration.contentArea()
    if not height then
        return
    end
    self.content_top = top
    self.height = height
    self:show()
end

--- Where the content is on the screen (below SimpleUI's top bar, if shown)
function LibraryBrowser:contentRegion()
    return Geom:new({ x = 0, y = self.content_top or 0, w = self.width, h = self.height })
end

--- Show `parts` as the browser's content: the whole screen, or with
--- SimpleUI's bars, the area between them (SimpleUI keeps the bars in a
--- container around the content, which must not be replaced).
function LibraryBrowser:setContent(parts)
    self.content_shown = true
    local frame = FrameContainer:new({
        width = self.width,
        height = self.height,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        parts,
    })

    local container = self._navbar_container
    if container and container[1] then
        frame.overlap_offset = container[1].overlap_offset or { 0, self.content_top or 0 }
        container[1] = frame
        self._navbar_inner = frame
    else
        self[1] = frame
    end
end

--- While requests run a cloud shows in the top bar, left of "⋯".  Only its
--- area is refreshed, which is cheaper on e-ink than a notice opening and
--- closing; the next screen replaces it.
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
    self.loading_indicator_area = area

    UIManager:setDirty(nil, "fast", area)
    UIManager:forceRePaint()
end

--- No request runs any more.  Usually the screen shown next paints over the
--- cloud; a request that does not change the screen (e.g. from a sheet)
--- leaves it: repaint its area then.
function LibraryBrowser:loadingFinished()
    UIManager:nextTick(function()
        local area = self.loading_indicator_area
        if self.loading_shown and area and not self.closed and not self.data:isBusy() then
            self.loading_shown = false
            UIManager:setDirty(self, function()
                return "fast", area
            end)
        end
    end)
end

-- A screen still loading keeps showing the previous one this long, then
-- "Loading…" (most answers arrive sooner: one refresh instead of two)
local LOADING_MESSAGE_DELAY = 1

--- The screen's content is loading: keep what is shown for a moment (the
--- cloud shows that something happens), then say so.  Nothing shown yet:
--- say so at once.  Taps keep working meanwhile (e.g. Back).
function LibraryBrowser:showLoading(screen, content_h)
    local token = {}
    self.loading_token = token

    local function show_message()
        self:showMessage(screen, content_h, _("Loading…"))
        -- The message's top bar has no cloud: paint it again once the
        -- message is on the screen
        UIManager:scheduleIn(0.1, function()
            if not self.closed and self.loading_token == token and self.data:isBusy() then
                self:showLoadingIndicator()
            end
        end)
    end

    if not self.content_shown then
        show_message()
        return
    end
    UIManager:scheduleIn(LOADING_MESSAGE_DELAY, function()
        if not self.closed and self.loading_token == token and self:current() == screen then
            show_message()
        end
    end)
end

--- Try again after an error: also servers that did not answer just now.
function LibraryBrowser:retry()
    HttpClient.forgetUnreachable()
    self:show()
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

-- Methods kept in their own files, by subject
for _, module in ipairs({
    "grimmory/ui/library/browser_screens",
    "grimmory/ui/library/browser_render",
    "grimmory/ui/library/browser_actions",
    "grimmory/ui/library/browser_selection",
    "grimmory/ui/library/browser_details",
}) do
    for name, method in pairs(require(module)) do
        LibraryBrowser[name] = method
    end
end

return LibraryBrowser

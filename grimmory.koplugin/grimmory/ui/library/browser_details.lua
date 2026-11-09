--[[
Library browser: the book details screen and downloading a book from it.
Methods of LibraryBrowser (grimmory/ui/library/browser.lua).
--]]

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
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
local _ = require("gettext")
local T = require("ffi/util").template
local CenterContainer = require("ui/widget/container/centercontainer")

local LibraryData = require("grimmory/ui/library/data")
local Sheet = require("grimmory/ui/sheet")
local Style = require("grimmory/ui/style")
local Widgets = require("grimmory/ui/library/widgets")
local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()
local Screen = Device.screen

---@class LibraryBrowserMethods
local LibraryBrowser = {}

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

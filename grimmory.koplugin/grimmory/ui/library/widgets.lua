--[[
Widgets of the Grimmory library browser: cover slots, book list rows, grid
cells, collection rows, the header, tab strip and page footer.

The cover list / grid approach (cover beside or above the text, covers loaded
after the page is shown) follows opds_plus.koplugin (AGPL-3.0,
https://github.com/greywolf1499/opds_plus.koplugin); the top bar, the grid
labels, rows and buttons follow the look of simpleui.koplugin 3 (GPL-3.0,
https://github.com/doctorhetfield-cmd/simpleui.koplugin).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local TopContainer = require("ui/widget/container/topcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Covers = require("grimmory/ui/library/covers")
local PluginMetadata = require("grimmory/plugin_metadata")
local Style = require("grimmory/ui/style")

local Screen = Device.screen

local Widgets = {}

Widgets.faces = {
    title = Font:getFace("cfont", 19),
    text = Font:getFace("cfont", 16),
    small = Font:getFace("cfont", 14),
    -- Below the covers of the grid: title (bold) and author, one line each
    grid_title = Font:getFace("cfont", Style.FS_DETAIL),
    grid_subtitle = Font:getFace("cfont", Style.FS_CAPTION + 1),
}

--- Height of the two label lines below a grid cover
function Widgets.gridLabelHeight()
    return Widgets.linesHeight(Widgets.faces.grid_title, 1) + Widgets.linesHeight(Widgets.faces.grid_subtitle, 1)
end

--- Title and subtitle lines of a grid cell, centered, one line each.
local function gridLabels(group, title, subtitle, width)
    table.insert(group, TextWidget:new({
        text = title,
        face = Widgets.faces.grid_title,
        bold = true,
        max_width = width,
    }))
    if subtitle and subtitle ~= "" then
        table.insert(group, TextWidget:new({
            text = subtitle,
            face = Widgets.faces.grid_subtitle,
            fgcolor = Style.COLOR.text_secondary,
            max_width = width,
        }))
    end
end

Widgets.PADDING = Screen:scaleBySize(8)
Widgets.ICON_SIZE = Screen:scaleBySize(34)

-- Height / width of cover slots: Grimmory crops its thumbnails to 250 x 350
Widgets.COVER_RATIO = 7 / 5

function Widgets.coverHeight(width)
    return math.floor(width * Widgets.COVER_RATIO)
end

function Widgets.coverWidth(height)
    return math.floor(height / Widgets.COVER_RATIO)
end

function Widgets.pluginIcon(name)
    return PluginMetadata.getPluginPath() .. "/icons/" .. name .. ".svg"
end

--- Height of `lines` lines of text in a TextBoxWidget with `face`
function Widgets.linesHeight(face, lines)
    return lines * math.floor((1 + 0.3) * face.size + 0.5) + 1
end

function Widgets.formatSeriesNumber(number)
    if not number then
        return nil
    end
    if number == math.floor(number) then
        return string.format("%d", number)
    end
    return tostring(number)
end

function Widgets.formatSize(size_kb)
    if not size_kb then
        return nil
    end
    if size_kb >= 1024 then
        return string.format("%.1f MB", size_kb / 1024)
    end
    return string.format("%d KB", size_kb)
end

--- "Series name #3" or nil
function Widgets.seriesText(book)
    if not book.series_name then
        return nil
    end
    local number = Widgets.formatSeriesNumber(book.series_number)
    return number and (book.series_name .. " #" .. number) or book.series_name
end

-------------------------------------------------------------------------------
-- Tappable area
-------------------------------------------------------------------------------

--- An InputContainer of fixed size calling `on_tap` / `on_hold`.
local Tappable = InputContainer:extend{
    width = nil,
    height = nil,
    on_tap = nil,
    on_hold = nil,
}

function Tappable:init()
    self.dimen = Geom:new({ x = 0, y = 0, w = self.width, h = self.height })
    self.ges_events = {
        TapItem = { GestureRange:new({ ges = "tap", range = self.dimen }) },
        HoldItem = { GestureRange:new({ ges = "hold", range = self.dimen }) },
    }
end

function Tappable:onTapItem()
    if self.on_tap then
        self.on_tap()
    end
    return true
end

function Tappable:onHoldItem()
    if self.on_hold then
        self.on_hold()
        return true
    end
    return self.on_tap ~= nil
end

Widgets.Tappable = Tappable

function Widgets.iconButton(icon, callback, size, enabled)
    size = size or Widgets.ICON_SIZE
    return IconButton:new({
        icon = icon,
        width = size,
        height = size,
        callback = callback,
        enabled = enabled ~= false,
    })
end

-------------------------------------------------------------------------------
-- Covers
-------------------------------------------------------------------------------

--- A fixed size slot showing a book cover, or a placeholder with the title
--- until the cover file is on the device.  Call `:update()` once it is.
local CoverSlot = WidgetContainer:extend{
    width = nil,
    height = nil,
    book_id = nil,
    cover_updated_on = nil,
    title = nil,
    on_device = false,
    full = false, -- full size cover instead of the thumbnail
}

function CoverSlot:init()
    self.dimen = Geom:new({ x = 0, y = 0, w = self.width, h = self.height })
    self:update()
end

function CoverSlot:getCoverPath()
    if not self.book_id then
        return nil
    end
    return Covers.path(self.book_id, self.cover_updated_on, self.full)
end

function CoverSlot:hasCover()
    local path = self:getCoverPath()
    return path ~= nil and Covers.exists(path)
end

function CoverSlot:update()
    local border = Size.border.thin
    local path = self:getCoverPath()
    local content
    -- Size of the framed cover (smaller than the slot for covers of another shape)
    local cover_w, cover_h = self.width, self.height

    if path and Covers.exists(path) then
        local fitted = ImageWidget:new({
            file = path,
            width = self.width - 2 * border,
            height = self.height - 2 * border,
            scale_factor = 0, -- fit, keeping the aspect ratio
        })
        -- The frame hugs the image, so there are no blank bands in it.
        -- getSize() renders it but answers the box size, and the image
        -- would be centered in that box: make it again at the fitted size
        -- (the decoded image is cached).
        fitted:getSize()
        local image_w, image_h = fitted:getCurrentWidth(), fitted:getCurrentHeight()
        fitted:free()
        local image = ImageWidget:new({
            file = path,
            width = image_w,
            height = image_h,
            scale_factor = 0,
        })
        cover_w = image_w + 2 * border
        cover_h = image_h + 2 * border
        content = FrameContainer:new({
            padding = 0,
            margin = 0,
            bordersize = border,
            image,
        })
    else
        local inner_w = self.width - 2 * border
        local inner_h = self.height - 2 * border
        content = FrameContainer:new({
            padding = 0,
            margin = 0,
            bordersize = border,
            background = Blitbuffer.COLOR_GRAY_E,
            CenterContainer:new({
                dimen = Geom:new({ w = inner_w, h = inner_h }),
                TextBoxWidget:new({
                    text = self.title or "",
                    face = Widgets.faces.small,
                    width = math.max(1, inner_w - 2 * Widgets.PADDING),
                    height = math.max(1, inner_h - 2 * Widgets.PADDING),
                    height_overflow_show_ellipsis = true,
                    alignment = "center",
                    bgcolor = Blitbuffer.COLOR_GRAY_E,
                }),
            }),
        })
    end

    local children = {
        dimen = Geom:new({ w = self.width, h = self.height }),
        CenterContainer:new({ dimen = Geom:new({ w = self.width, h = self.height }), content }),
    }

    if self.on_device then
        -- "On this device" corner badge, top right, in the style of
        -- SimpleUI's cover badges: small rounded rectangle, thin border
        local cover_min = math.min(cover_w, cover_h)
        local icon_size = math.max(8, math.floor(cover_min * 0.17))
        local pad = math.max(1, math.floor(icon_size * 0.15))
        local badge_border = Size.border.thin
        local badge_w = icon_size + 2 * pad + 2 * badge_border
        local badge = FrameContainer:new({
            padding = pad,
            margin = 0,
            bordersize = badge_border,
            radius = math.max(1, math.floor(badge_w * 0.12)),
            background = Blitbuffer.COLOR_WHITE,
            IconWidget:new({
                file = Widgets.pluginIcon("downloaded"),
                width = icon_size,
                height = icon_size,
                alpha = true,
            }),
        })
        -- Inside the cover (centered in the slot), inset from its corner
        local cover_x = math.floor((self.width - cover_w) / 2)
        local cover_y = math.floor((self.height - cover_h) / 2)
        badge.overlap_offset = {
            cover_x + cover_w - badge_w - math.max(1, math.floor(cover_min * 0.06)),
            cover_y + math.max(1, math.floor(cover_min * 0.04)),
        }
        table.insert(children, badge)
    end

    self[1] = OverlapGroup:new(children)
end

function CoverSlot:getSize()
    return self.dimen
end

function CoverSlot:paintTo(bb, x, y)
    -- Remember where we were painted, to refresh only this area when the
    -- cover arrives (dimen.x/y would be used as an offset by WidgetContainer)
    self.painted_at = Geom:new({ x = x, y = y, w = self.width, h = self.height })
    self[1]:paintTo(bb, x, y)
end

Widgets.CoverSlot = CoverSlot

--- Wraps a widget and remembers where it was painted, to refresh only that
--- area when it changes (e.g. a download progress bar).
local PaintTracker = WidgetContainer:extend{}

function PaintTracker:paintTo(bb, x, y)
    local size = self[1]:getSize()
    self.painted_at = Geom:new({ x = x, y = y, w = size.w, h = size.h })
    self[1]:paintTo(bb, x, y)
    if self.on_paint then
        self.on_paint(self.painted_at)
    end
end

function PaintTracker:getSize()
    return self[1]:getSize()
end

Widgets.PaintTracker = PaintTracker

-------------------------------------------------------------------------------
-- Books
-------------------------------------------------------------------------------

local function progressLine(book, width)
    if not book.read_progress or book.read_progress <= 0 then
        return nil
    end

    local percent_text = TextWidget:new({
        text = string.format(" %d%%", math.floor(book.read_progress + 0.5)),
        face = Widgets.faces.small,
    })

    return HorizontalGroup:new({
        align = "center",
        ProgressWidget:new({
            width = math.max(1, width - percent_text:getSize().w),
            height = Screen:scaleBySize(7),
            percentage = math.min(1, book.read_progress / 100),
            margin_h = 0,
            margin_v = 0,
            radius = Screen:scaleBySize(3),
        }),
        percent_text,
    })
end

--- One book in the list layout: cover on the left, details on the right.
---@param book LibraryBook
function Widgets.bookListItem(book, opts)
    local width, height = opts.width, opts.height
    local padding = Widgets.PADDING
    local margin = Style.SIDE_MARGIN
    local cover_h = height - 2 * padding
    local cover_w = Widgets.coverWidth(cover_h)
    local text_w = width - cover_w - 2 * margin - 2 * padding

    local cover = CoverSlot:new({
        width = cover_w,
        height = cover_h,
        book_id = book.id,
        cover_updated_on = book.cover_updated_on,
        title = book.title,
        on_device = opts.on_device,
    })

    -- Fit the text into the row: two title lines if there is room, else one;
    -- then author and series share a line.
    local authors = #book.authors > 0 and table.concat(book.authors, ", ") or nil
    local series = Widgets.seriesText(book)
    local has_progress = book.read_progress and book.read_progress > 0
    local no_file = not book.primary_file_name

    local title_line_h = Widgets.linesHeight(Widgets.faces.title, 1)
    local text_line_h = Widgets.linesHeight(Widgets.faces.text, 1)
    local small_line_h = Widgets.linesHeight(Widgets.faces.small, 1)

    local function extras_height()
        return (authors and text_line_h or 0)
            + (series and small_line_h or 0)
            + (has_progress and (padding + small_line_h) or 0)
            + (no_file and small_line_h or 0)
    end

    local title_lines = 2
    if 2 * title_line_h + extras_height() > cover_h then
        title_lines = 1
    end
    if title_line_h + extras_height() > cover_h and authors and series then
        authors = authors .. " · " .. series
        series = nil
    end

    local lines = VerticalGroup:new({
        align = "left",
        TextBoxWidget:new({
            text = book.title ~= "" and book.title or (book.primary_file_name or ""),
            face = Widgets.faces.title,
            bold = true,
            width = text_w,
            height = Widgets.linesHeight(Widgets.faces.title, title_lines),
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        }),
    })

    if authors then
        table.insert(lines, TextWidget:new({
            text = authors,
            face = Widgets.faces.text,
            max_width = text_w,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }))
    end

    if series then
        table.insert(lines, TextWidget:new({
            text = series,
            face = Widgets.faces.small,
            max_width = text_w,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }))
    end

    if has_progress then
        table.insert(lines, VerticalSpan:new({ width = padding }))
        table.insert(lines, progressLine(book, math.floor(text_w * 0.6)))
    end

    if no_file then
        table.insert(lines, TextWidget:new({
            text = _("No file to download"),
            face = Widgets.faces.small,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }))
    end

    local item = Tappable:new({ width = width, height = height, on_tap = opts.on_tap, on_hold = opts.on_hold })
    item[1] = VerticalGroup:new({
        align = "left",
        HorizontalGroup:new({
            align = "center",
            HorizontalSpan:new({ width = margin }),
            cover,
            HorizontalSpan:new({ width = 2 * padding }),
            LeftContainer:new({
                dimen = Geom:new({ w = text_w + margin, h = height - Size.line.thin }),
                lines,
            }),
        }),
        LineWidget:new({
            dimen = Geom:new({ w = width, h = Size.line.thin }),
            background = Blitbuffer.COLOR_GRAY_B,
        }),
    })
    item.cover = cover

    return item
end

--- One book in the grid layout: cover with title and author below.
---@param book LibraryBook
function Widgets.bookGridCell(book, opts)
    local width, height = opts.width, opts.height
    local padding = Widgets.PADDING
    local cover_w = width - 2 * padding
    local title_h = Widgets.gridLabelHeight()
    local cover_h = math.min(Widgets.coverHeight(cover_w), height - title_h - 3 * padding - Screen:scaleBySize(7))
    cover_w = math.min(cover_w, Widgets.coverWidth(cover_h))

    local cover = CoverSlot:new({
        width = cover_w,
        height = cover_h,
        book_id = book.id,
        cover_updated_on = book.cover_updated_on,
        title = book.title,
        on_device = opts.on_device,
    })

    local group = VerticalGroup:new({
        align = "center",
        VerticalSpan:new({ width = padding }),
        cover,
        VerticalSpan:new({ width = math.floor(padding / 2) }),
    })

    -- The progress bar's space is kept for every book, so the covers and
    -- titles of a row line up
    local bar_h = Screen:scaleBySize(5)
    if book.read_progress and book.read_progress > 0 then
        table.insert(group, ProgressWidget:new({
            width = cover_w,
            height = bar_h,
            percentage = math.min(1, book.read_progress / 100),
            margin_h = 0,
            margin_v = 0,
            radius = 0,
        }))
    else
        table.insert(group, VerticalSpan:new({ width = bar_h }))
    end
    table.insert(group, VerticalSpan:new({ width = math.floor(padding / 2) }))

    gridLabels(
        group,
        book.title ~= "" and book.title or (book.primary_file_name or ""),
        #book.authors > 0 and table.concat(book.authors, ", ") or nil,
        width - padding
    )

    local item = Tappable:new({ width = width, height = height, on_tap = opts.on_tap, on_hold = opts.on_hold })
    item[1] = TopContainer:new({
        dimen = Geom:new({ w = width, h = height }),
        group,
    })
    item.cover = cover

    return item
end

-------------------------------------------------------------------------------
-- Collections (series, shelves, libraries)
-------------------------------------------------------------------------------

--- A series (or other collection with a cover) in the grid layout: cover,
--- name and a small subtitle (book count).
function Widgets.collectionGridCell(opts)
    local width, height = opts.width, opts.height
    local padding = Widgets.PADDING
    local cover_w = width - 2 * padding
    local cover_h = math.min(Widgets.coverHeight(cover_w), height - Widgets.gridLabelHeight() - 3 * padding)
    cover_w = math.min(cover_w, Widgets.coverWidth(cover_h))

    local cover = CoverSlot:new({
        width = cover_w,
        height = cover_h,
        book_id = opts.cover and opts.cover.book_id,
        cover_updated_on = opts.cover and opts.cover.cover_updated_on,
        title = opts.title,
    })

    local group = VerticalGroup:new({
        align = "center",
        VerticalSpan:new({ width = padding }),
        cover,
        VerticalSpan:new({ width = math.floor(padding / 2) }),
    })
    gridLabels(group, opts.title, opts.subtitle, width - padding)

    local item = Tappable:new({ width = width, height = height, on_tap = opts.on_tap, on_hold = opts.on_hold })
    item[1] = TopContainer:new({
        dimen = Geom:new({ w = width, h = height }),
        group,
    })
    item.cover = cover

    return item
end

--- A row for a series / shelf / library.  `opts.cover` (book id + update
--- time) shows a cover on the left, `opts.badge` text is shown on the right.
function Widgets.collectionRow(opts)
    local width, height = opts.width, opts.height
    local padding = Widgets.PADDING
    local margin = Style.SIDE_MARGIN
    local left = HorizontalGroup:new({ align = "center", HorizontalSpan:new({ width = margin }) })
    local cover

    if opts.cover then
        local cover_h = height - 2 * padding
        cover = CoverSlot:new({
            width = Widgets.coverWidth(cover_h),
            height = cover_h,
            book_id = opts.cover.book_id,
            cover_updated_on = opts.cover.cover_updated_on,
            title = opts.title,
        })
        table.insert(left, cover)
        table.insert(left, HorizontalSpan:new({ width = 2 * padding }))
    end

    local badge = opts.badge and TextWidget:new({
        text = opts.badge,
        face = Widgets.faces.text,
        bold = true,
    }) or nil
    local badge_w = badge and (badge:getSize().w + 2 * padding) or padding
    local used_w = margin + (cover and (cover.width + 2 * padding) or 0)
    local text_w = width - used_w - badge_w - margin

    local lines = VerticalGroup:new({
        align = "left",
        TextWidget:new({
            text = opts.title,
            face = Widgets.faces.title,
            bold = true,
            max_width = text_w,
        }),
    })

    if opts.subtitle and opts.subtitle ~= "" then
        table.insert(lines, TextWidget:new({
            text = opts.subtitle,
            face = Widgets.faces.small,
            max_width = text_w,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }))
    end

    table.insert(left, lines)

    local row_h = height - Size.line.thin
    local content = OverlapGroup:new({
        dimen = Geom:new({ w = width, h = row_h }),
        LeftContainer:new({ dimen = Geom:new({ w = width, h = row_h }), left }),
    })
    if badge then
        table.insert(content, RightContainer:new({
            dimen = Geom:new({ w = width - margin, h = row_h }),
            badge,
        }))
    end

    local item = Tappable:new({ width = width, height = height, on_tap = opts.on_tap, on_hold = opts.on_hold })
    item[1] = VerticalGroup:new({
        content,
        LineWidget:new({
            dimen = Geom:new({ w = width, h = Size.line.thin }),
            background = Blitbuffer.COLOR_GRAY_B,
        }),
    })
    item.cover = cover

    return item
end

-------------------------------------------------------------------------------
-- Top bar, rows, buttons, footer (in the style of SimpleUI 3's library)
-------------------------------------------------------------------------------

--- Metrics of the top bar: the icons are as high as the tab labels.
local function topBarMetrics()
    local face = Style.face(Style.FS_BODY)
    local probe = TextWidget:new({ text = "A", face = face, padding = 0 })
    local text_h = probe:getSize().h
    probe:free()
    return {
        face = face,
        icon = text_h,
        height = text_h + 2 * Screen:scaleBySize(16),
        margin = Style.SIDE_MARGIN,
        tap_pad = Screen:scaleBySize(8),
        back_gap = Screen:scaleBySize(14),
        tab_pad = Screen:scaleBySize(14),
        underline = Screen:scaleBySize(2),
    }
end

function Widgets.topBarHeight()
    return topBarMetrics().height
end

--- An icon with a tap area `tap_pad` wider on each side and as high as the bar.
local function barButton(icon_widget, icon_w, bar_h, tap_pad, callback)
    local button = Tappable:new({ width = icon_w + 2 * tap_pad, height = bar_h, on_tap = callback })
    button[1] = CenterContainer:new({
        dimen = Geom:new({ w = icon_w + 2 * tap_pad, h = bar_h }),
        icon_widget,
    })
    return button
end

--- The tab cells: labels left aligned with their natural width, the
--- selected one bold and underlined, then the search icon.
local function tabCells(opts, m, strip_w)
    local entries, content_w = {}, 0
    local search_w = opts.on_search and (m.icon + 2 * m.tap_pad) or 0
    local max_label_w = math.floor((strip_w - search_w) / math.max(1, #opts.tabs))

    for _, tab in ipairs(opts.tabs) do
        local selected = tab.id == opts.selected
        local function label(bold)
            return TextWidget:new({ text = tab.text, face = m.face, padding = 0, bold = bold, max_width = max_label_w })
        end
        local regular, bold = label(false), label(true)
        -- The widest variant, so selecting a tab does not move the others
        local w = math.max(regular:getWidth(), bold:getWidth())
        if selected then
            regular:free()
        else
            bold:free()
        end
        table.insert(entries, { tab = tab, text = selected and bold or regular, w = w, selected = selected })
        content_w = content_w + w
    end

    -- Less space between the tabs when they do not fit
    local pad = math.min(m.tab_pad, math.max(0, math.floor((strip_w - search_w - content_w) / (2 * #entries))))

    local row = HorizontalGroup:new({ align = "top" })
    for i, entry in ipairs(entries) do
        local lead = i == 1 and 0 or pad
        local cell_w = lead + entry.w + pad
        local cell = Tappable:new({
            width = cell_w,
            height = m.height,
            on_tap = function()
                opts.on_select(entry.tab.id)
            end,
        })
        local dimen = Geom:new({ w = cell_w, h = m.height })
        local content = OverlapGroup:new({
            dimen = dimen,
            LeftContainer:new({
                dimen = dimen,
                HorizontalGroup:new({ HorizontalSpan:new({ width = lead }), entry.text }),
            }),
        })
        if entry.selected then
            local underline = LineWidget:new({
                dimen = Geom:new({ w = entry.w, h = m.underline }),
                background = Style.COLOR.text,
            })
            underline.overlap_offset = { lead, m.height - m.underline }
            table.insert(content, underline)
        end
        cell[1] = content
        table.insert(row, cell)
    end

    if opts.on_search then
        table.insert(row, barButton(Style.glyph("search", m.icon), m.icon, m.height, m.tap_pad, opts.on_search))
    end

    return row
end

--- The browser's top bar: [‹] tabs (or a label) [search] ... [loading] [⋯]
---@param opts table width, tabs ({ id, text }), selected, on_select, label,
---  on_back, on_search, on_more, on_loading_area (the area of the loading
---  indicator, when painted)
function Widgets.topBar(opts)
    local m = topBarMetrics()
    local width = opts.width
    local children = { dimen = Geom:new({ w = width, h = m.height }) }

    local x = m.margin
    if opts.on_back then
        local back = barButton(
            IconWidget:new({ icon = "chevron.left", width = m.icon, height = m.icon }),
            m.icon, m.height, m.tap_pad, opts.on_back
        )
        back.overlap_offset = { x - m.tap_pad, 0 }
        table.insert(children, back)
        x = x + m.icon + m.back_gap
    end

    local more_x = width - m.margin - m.icon - m.tap_pad
    if opts.on_more then
        local more = barButton(Style.glyph("more", m.icon), m.icon, m.height, m.tap_pad, opts.on_more)
        more.overlap_offset = { more_x, 0 }
        table.insert(children, more)
    end

    -- The loading indicator is painted here (blank while idle)
    local loading_x = more_x - m.icon - m.tap_pad
    local loading = PaintTracker:new({
        WidgetContainer:new({ dimen = Geom:new({ w = m.icon, h = m.icon }) }),
        on_paint = opts.on_loading_area,
    })
    loading.overlap_offset = { loading_x, math.floor((m.height - m.icon) / 2) }
    table.insert(children, loading)

    local strip_w = loading_x - m.tap_pad - x
    local strip
    if opts.tabs then
        strip = tabCells(opts, m, strip_w)
    else
        strip = LeftContainer:new({
            dimen = Geom:new({ w = strip_w, h = m.height }),
            TextWidget:new({
                text = opts.label or "",
                face = m.face,
                bold = true,
                max_width = strip_w,
                padding = 0,
            }),
        })
    end
    strip.overlap_offset = { x, 0 }
    table.insert(children, strip)

    return OverlapGroup:new(children)
end

--- Rounded buttons in a row, SimpleUI's "segments": `selected` ones are
--- black (the main action), the others gray.
---@param items table { text, callback, selected, enabled }
function Widgets.segments(items, width)
    local gap = Screen:scaleBySize(10)
    local height = Screen:scaleBySize(44)
    local face = Style.face(Style.FS_BODY)
    local w = math.floor((width - gap * (#items - 1)) / math.max(1, #items))

    local row = HorizontalGroup:new({ align = "center" })
    for i, item in ipairs(items) do
        if i > 1 then
            table.insert(row, HorizontalSpan:new({ width = gap }))
        end
        local enabled = item.enabled ~= false
        local fgcolor = item.selected and Style.COLOR.surface or (enabled and Style.COLOR.text or Style.COLOR.text_dim)
        local frame = FrameContainer:new({
            bordersize = 0,
            padding = 0,
            margin = 0,
            radius = Style.RADIUS,
            background = item.selected and Style.COLOR.text or Style.COLOR.surface_flat,
            CenterContainer:new({
                dimen = Geom:new({ w = w, h = height }),
                TextWidget:new({
                    text = item.text,
                    face = face,
                    bold = item.selected,
                    fgcolor = fgcolor,
                    padding = 0,
                    max_width = w - 2 * Widgets.PADDING,
                }),
            }),
        })
        if enabled and item.callback then
            local button = Tappable:new({ width = w, height = height, on_tap = item.callback })
            button[1] = frame
            table.insert(row, button)
        else
            table.insert(row, frame)
        end
    end
    return row
end

--- A full width row with a check box: [☑] text
function Widgets.checkboxRow(opts)
    local margin = Style.SIDE_MARGIN
    local height = Screen:scaleBySize(46)
    local icon = Screen:scaleBySize(24)

    local item = Tappable:new({ width = opts.width, height = height, on_tap = opts.on_tap })
    item[1] = VerticalGroup:new({
        LeftContainer:new({
            dimen = Geom:new({ w = opts.width, h = height - Size.line.thin }),
            HorizontalGroup:new({
                align = "center",
                HorizontalSpan:new({ width = margin }),
                Style.glyph(opts.checked and "check" or "uncheck", icon),
                HorizontalSpan:new({ width = Screen:scaleBySize(12) }),
                TextWidget:new({
                    text = opts.text,
                    face = Style.face(Style.FS_BODY),
                    max_width = opts.width - 2 * margin - icon - Screen:scaleBySize(12),
                    padding = 0,
                }),
            }),
        }),
        LineWidget:new({
            dimen = Geom:new({ w = opts.width, h = Size.line.thin }),
            background = Style.COLOR.separator,
        }),
    })

    return item
end

--- Page footer: «  ‹  Page 2 of 7  ›  »
function Widgets.footer(opts)
    local width = opts.width
    local icon = Screen:scaleBySize(26)
    local height = icon + 2 * Widgets.PADDING

    if not opts.pages or opts.pages <= 1 then
        -- Nothing to turn: keep the space, so all lists have the same height
        return VerticalSpan:new({ width = height })
    end

    local function button(name, page, enabled)
        return Widgets.iconButton(name, function() opts.on_page(page) end, icon, enabled)
    end
    local gap = HorizontalSpan:new({ width = 2 * Widgets.PADDING })

    return CenterContainer:new({
        dimen = Geom:new({ w = width, h = height }),
        HorizontalGroup:new({
            align = "center",
            button("chevron.first", 1, opts.page > 1),
            gap,
            button("chevron.left", opts.page - 1, opts.page > 1),
            gap,
            TextWidget:new({ text = T(_("Page %1 of %2"), opts.page, opts.pages), face = Style.face(Style.FS_DETAIL) }),
            gap,
            button("chevron.right", opts.page + 1, opts.page < opts.pages),
            gap,
            button("chevron.last", opts.pages, opts.page < opts.pages),
        }),
    })
end

--- A centered message filling `height` (loading, empty, error) with an
--- optional button.
function Widgets.message(opts)
    local group = VerticalGroup:new({
        align = "center",
        TextBoxWidget:new({
            text = opts.text,
            face = Style.face(Style.FS_BODY),
            fgcolor = Style.COLOR.text_secondary,
            width = math.floor(opts.width * 0.8),
            alignment = "center",
        }),
    })

    if opts.button_text then
        table.insert(group, VerticalSpan:new({ width = 3 * Widgets.PADDING }))
        table.insert(group, Widgets.segments({
            { text = opts.button_text, callback = opts.on_button, selected = true },
        }, math.floor(opts.width * 0.4)))
    end

    return CenterContainer:new({
        dimen = Geom:new({ w = opts.width, h = opts.height }),
        group,
    })
end

--- Section title of a home row: "Recently added          See all ›"
function Widgets.sectionHeader(opts)
    local margin = Style.SIDE_MARGIN
    local title = TextWidget:new({
        text = opts.title,
        face = Style.face(Style.FS_BODY),
        bold = true,
        max_width = math.floor(opts.width * 0.7),
    })
    local height = title:getSize().h + 2 * Widgets.PADDING

    local item = Tappable:new({ width = opts.width, height = height, on_tap = opts.on_tap })
    local content = OverlapGroup:new({
        dimen = Geom:new({ w = opts.width, h = height }),
        LeftContainer:new({
            dimen = Geom:new({ w = opts.width, h = height }),
            HorizontalGroup:new({ HorizontalSpan:new({ width = margin }), title }),
        }),
    })
    if opts.on_tap then
        table.insert(content, RightContainer:new({
            dimen = Geom:new({ w = opts.width - margin, h = height }),
            TextWidget:new({
                text = _("See all ›"),
                face = Style.face(Style.FS_DETAIL),
                fgcolor = Style.COLOR.text_secondary,
            }),
        }))
    end
    item[1] = content

    return item
end

--- Plain text without HTML
function Widgets.plainText(text)
    local ok, plain = pcall(util.htmlToPlainTextIfHtml, text)
    return ok and plain or text
end

return Widgets

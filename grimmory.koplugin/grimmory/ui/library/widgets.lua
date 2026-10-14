--[[
Widgets of the Grimmory library browser: cover slots, book list rows, grid
cells, collection rows, the header, tab strip and page footer.

The cover list / grid approach (cover beside or above the text, covers loaded
after the page is shown) follows opds_plus.koplugin (AGPL-3.0,
https://github.com/greywolf1499/opds_plus.koplugin); the tab strip and the
compact header follow the look of simpleui.koplugin (MIT,
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

local Screen = Device.screen

local Widgets = {}

Widgets.faces = {
    title = Font:getFace("cfont", 19),
    text = Font:getFace("cfont", 16),
    small = Font:getFace("cfont", 14),
    header = Font:getFace("smalltfont"),
    tab = Font:getFace("cfont", 18),
}

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

--- A square icon button from a plugin SVG file.
function Widgets.fileIconButton(icon_name, callback, size)
    size = size or Widgets.ICON_SIZE
    local button = Tappable:new({ width = size, height = size, on_tap = callback })
    button[1] = IconWidget:new({ file = Widgets.pluginIcon(icon_name), width = size, height = size, alpha = true })
    return button
end

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
    local cover_h = height - 2 * padding
    local cover_w = Widgets.coverWidth(cover_h)
    local text_w = width - cover_w - 4 * padding

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
            HorizontalSpan:new({ width = padding }),
            cover,
            HorizontalSpan:new({ width = 2 * padding }),
            LeftContainer:new({
                dimen = Geom:new({ w = text_w + padding, h = height - Size.line.thin }),
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

--- One book in the grid layout: cover with the title below.
---@param book LibraryBook
function Widgets.bookGridCell(book, opts)
    local width, height = opts.width, opts.height
    local padding = Widgets.PADDING
    local cover_w = width - 2 * padding
    local title_h = Widgets.linesHeight(Widgets.faces.small, opts.title_lines)
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

    table.insert(group, TextBoxWidget:new({
        text = book.title ~= "" and book.title or (book.primary_file_name or ""),
        face = Widgets.faces.small,
        width = width - padding,
        height = math.floor(title_h),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
    }))

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
    local title_h = Widgets.linesHeight(Widgets.faces.small, 2)
    local subtitle_h = Widgets.linesHeight(Widgets.faces.small, 1)
    local cover_w = width - 2 * padding
    local cover_h = math.min(Widgets.coverHeight(cover_w), height - title_h - subtitle_h - 3 * padding)
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
        TextBoxWidget:new({
            text = opts.title,
            face = Widgets.faces.small,
            bold = true,
            width = width - padding,
            height = title_h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            alignment = "center",
        }),
    })

    if opts.subtitle and opts.subtitle ~= "" then
        table.insert(group, TextWidget:new({
            text = opts.subtitle,
            face = Widgets.faces.small,
            max_width = width - padding,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }))
    end

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
    local left = HorizontalGroup:new({ align = "center", HorizontalSpan:new({ width = padding }) })
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
    local used_w = padding + (cover and (cover.width + 2 * padding) or 0)
    local text_w = width - used_w - badge_w - padding

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
            dimen = Geom:new({ w = width - padding, h = row_h }),
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
-- Header, tabs, footer
-------------------------------------------------------------------------------

--- Header: [back] title ... [icons].  `opts.icons` is a list of widgets.
function Widgets.header(opts)
    local width = opts.width
    local padding = Widgets.PADDING
    local title_face_h = TextWidget:new({ text = "Mg", face = Widgets.faces.header, bold = true }):getSize().h
    local subtitle_face_h = TextWidget:new({ text = "Mg", face = Widgets.faces.small }):getSize().h
    -- Always room for a title and a subtitle line, so the header has the
    -- same height on every screen
    local height = math.max(Widgets.ICON_SIZE, title_face_h + subtitle_face_h) + 2 * padding

    local left = HorizontalGroup:new({ align = "center", HorizontalSpan:new({ width = padding }) })
    if opts.on_back then
        table.insert(left, Widgets.iconButton("chevron.left", opts.on_back))
        table.insert(left, HorizontalSpan:new({ width = padding }))
    end

    local right = HorizontalGroup:new({ align = "center" })
    for _, icon in ipairs(opts.icons or {}) do
        table.insert(right, icon)
        table.insert(right, HorizontalSpan:new({ width = 2 * padding }))
    end

    local title_w = width - left:getSize().w - right:getSize().w - 2 * padding
    local title = VerticalGroup:new({
        align = "left",
        TextWidget:new({
            text = opts.title or "",
            face = Widgets.faces.header,
            bold = true,
            max_width = title_w,
        }),
    })
    if opts.subtitle and opts.subtitle ~= "" then
        table.insert(title, TextWidget:new({
            text = opts.subtitle,
            face = Widgets.faces.small,
            max_width = title_w,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }))
    end
    table.insert(left, title)
    -- Children were added after measuring: drop the cached layout
    left:resetLayout()

    return VerticalGroup:new({
        OverlapGroup:new({
            dimen = Geom:new({ w = width, h = height }),
            LeftContainer:new({ dimen = Geom:new({ w = width, h = height }), left }),
            RightContainer:new({ dimen = Geom:new({ w = width, h = height }), right }),
        }),
        LineWidget:new({ dimen = Geom:new({ w = width, h = Size.line.medium }) }),
    })
end

--- One-tap tab strip.  `opts.tabs` = { { id, text } }, `opts.selected` = id.
function Widgets.tabStrip(opts)
    local width = opts.width
    local padding = Widgets.PADDING
    local tab_w = math.floor(width / #opts.tabs)
    local label_h = TextWidget:new({ text = "Ag", face = Widgets.faces.tab }):getSize().h
    local underline_h = Screen:scaleBySize(3)
    local height = label_h + 2 * padding + underline_h

    local row = HorizontalGroup:new({})
    for _, tab in ipairs(opts.tabs) do
        local selected = tab.id == opts.selected
        local cell = Tappable:new({
            width = tab_w,
            height = height,
            on_tap = function()
                opts.on_select(tab.id)
            end,
        })
        cell[1] = VerticalGroup:new({
            CenterContainer:new({
                dimen = Geom:new({ w = tab_w, h = height - underline_h }),
                TextWidget:new({
                    text = tab.text,
                    face = Widgets.faces.tab,
                    bold = selected,
                    max_width = tab_w - padding,
                    fgcolor = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
                }),
            }),
            selected and LineWidget:new({
                dimen = Geom:new({ w = tab_w, h = underline_h }),
            }) or VerticalSpan:new({ width = underline_h }),
        })
        table.insert(row, cell)
    end

    return VerticalGroup:new({
        row,
        LineWidget:new({
            dimen = Geom:new({ w = width, h = Size.line.thin }),
            background = Blitbuffer.COLOR_GRAY_B,
        }),
    })
end

--- A full width checkbox row: [✓] text
function Widgets.checkboxRow(opts)
    local padding = Widgets.PADDING
    local box_size = Widgets.linesHeight(Widgets.faces.text, 1)
    local height = box_size + 2 * padding

    local inner = box_size - 2 * Size.border.thick
    local box = FrameContainer:new({
        padding = 0,
        margin = 0,
        bordersize = Size.border.thick,
        radius = Size.radius.default,
        CenterContainer:new({
            dimen = Geom:new({ w = inner, h = inner }),
            opts.checked and IconWidget:new({ icon = "check", width = inner, height = inner })
                or HorizontalSpan:new({ width = 0 }),
        }),
    })

    local item = Tappable:new({ width = opts.width, height = height, on_tap = opts.on_tap })
    item[1] = VerticalGroup:new({
        LeftContainer:new({
            dimen = Geom:new({ w = opts.width, h = height - Size.line.thin }),
            HorizontalGroup:new({
                align = "center",
                HorizontalSpan:new({ width = 2 * padding }),
                box,
                HorizontalSpan:new({ width = 2 * padding }),
                TextWidget:new({
                    text = opts.text,
                    face = Widgets.faces.text,
                    bold = opts.checked,
                    max_width = opts.width - box_size - 5 * padding,
                }),
            }),
        }),
        LineWidget:new({
            dimen = Geom:new({ w = opts.width, h = Size.line.thin }),
            background = Blitbuffer.COLOR_GRAY_B,
        }),
    })

    return item
end

--- Page footer: ‹  Page 2 of 7  ›
function Widgets.footer(opts)
    local width = opts.width
    local padding = Widgets.PADDING
    local height = Widgets.ICON_SIZE + 2 * padding

    if not opts.pages or opts.pages <= 1 then
        -- Nothing to turn: keep the space, so all lists have the same height
        return VerticalGroup:new({
            LineWidget:new({
                dimen = Geom:new({ w = width, h = Size.line.thin }),
                background = Blitbuffer.COLOR_GRAY_B,
            }),
            VerticalSpan:new({ width = height }),
        })
    end

    local prev_button = Widgets.iconButton("chevron.left", opts.on_prev, nil, opts.page > 1)
    local next_button = Widgets.iconButton("chevron.right", opts.on_next, nil, opts.page < opts.pages)

    local text = T(_("Page %1 of %2"), opts.page, opts.pages)

    return VerticalGroup:new({
        LineWidget:new({
            dimen = Geom:new({ w = width, h = Size.line.thin }),
            background = Blitbuffer.COLOR_GRAY_B,
        }),
        CenterContainer:new({
            dimen = Geom:new({ w = width, h = height }),
            HorizontalGroup:new({
                align = "center",
                prev_button,
                HorizontalSpan:new({ width = 4 * padding }),
                TextWidget:new({ text = text, face = Widgets.faces.text }),
                HorizontalSpan:new({ width = 4 * padding }),
                next_button,
            }),
        }),
    })
end

--- A centered message filling `height` (loading, empty, error) with an
--- optional button.
function Widgets.message(opts)
    local Button = require("ui/widget/button")
    local group = VerticalGroup:new({
        align = "center",
        TextBoxWidget:new({
            text = opts.text,
            face = Widgets.faces.text,
            width = math.floor(opts.width * 0.8),
            alignment = "center",
        }),
    })

    if opts.button_text then
        table.insert(group, VerticalSpan:new({ width = 3 * Widgets.PADDING }))
        table.insert(group, Button:new({
            text = opts.button_text,
            callback = opts.on_button,
            radius = Size.radius.button,
        }))
    end

    return CenterContainer:new({
        dimen = Geom:new({ w = opts.width, h = opts.height }),
        group,
    })
end

--- Section title of a home row: "Recently added          See all ›"
function Widgets.sectionHeader(opts)
    local padding = Widgets.PADDING
    local title = TextWidget:new({
        text = opts.title,
        face = Widgets.faces.title,
        bold = true,
        max_width = math.floor(opts.width * 0.7),
    })
    local height = title:getSize().h + 2 * padding

    local item = Tappable:new({ width = opts.width, height = height, on_tap = opts.on_tap })
    local content = OverlapGroup:new({
        dimen = Geom:new({ w = opts.width, h = height }),
        LeftContainer:new({
            dimen = Geom:new({ w = opts.width, h = height }),
            HorizontalGroup:new({ HorizontalSpan:new({ width = 2 * padding }), title }),
        }),
    })
    if opts.on_tap then
        table.insert(content, RightContainer:new({
            dimen = Geom:new({ w = opts.width - 2 * padding, h = height }),
            TextWidget:new({ text = _("See all ›"), face = Widgets.faces.text, fgcolor = Blitbuffer.COLOR_DARK_GRAY }),
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

--[[
Design tokens of the plugin's screens: colors, fonts, spacing and icon
glyphs.  They follow simpleui.koplugin 3 (GPL-3.0,
https://github.com/doctorhetfield-cmd/simpleui.koplugin), so the library
browser looks like SimpleUI's library with or without SimpleUI installed.
The glyphs come from the symbol font bundled with KOReader.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Screen = require("device").screen

local Style = {}

Style.COLOR = {
    text = Blitbuffer.COLOR_BLACK,
    text_secondary = Blitbuffer.COLOR_DARK_GRAY,
    text_dim = Blitbuffer.gray(0.45),
    surface = Blitbuffer.COLOR_WHITE,
    surface_flat = Blitbuffer.gray(0.08),
    separator = Blitbuffer.gray(0.85),
    border = Blitbuffer.gray(0.72),
    track = Blitbuffer.gray(0.15),
}

-- Font sizes (KOReader scales them with the screen)
Style.FS_TITLE = 22
Style.FS_SUBTITLE = 20
Style.FS_BODY = 18
Style.FS_DETAIL = 15
Style.FS_CAPTION = 12

Style.FACE_REGULAR = "cfont"
Style.FACE_BOLD = "tfont"
Style.FACE_ICONS = "symbols"

function Style.face(size)
    return Font:getFace(Style.FACE_REGULAR, size)
end

-- Horizontal margin of full width surfaces (SimpleUI's SIDE_M)
Style.SIDE_MARGIN = Screen:scaleBySize(24) - 3
Style.PAD = Screen:scaleBySize(14)
Style.PAD_SMALL = Screen:scaleBySize(8)
Style.RADIUS = Screen:scaleBySize(10)

-- Icon glyphs; the keys are the same as SimpleUI's, so they can be passed to
-- its action sheets too
Style.ICON = {
    back = "\u{E5C4}",
    more = "\u{E8D7}",
    search = "\u{F002}",
    tick = "\u{F00C}",
    check = "\u{E832}",
    uncheck = "\u{E82F}",
    delete = "\u{F014}",
    update = "\u{E769}",
    book_open = "\u{E28B}",
    info = "\u{F449}",
    series = "\u{E7BA}",
    library = "\u{EA30}",
    list = "\u{E978}",
    group = "\u{E73A}",
    import = "\u{E27D}",
    close = "\u{E855}",
    settings = "\u{F423}",
    plugin = "\u{EB30}",
    hourglass = "\u{F254}",
    first_page = "\u{F100}",
    last_page = "\u{F101}",
    previous_page = "\u{F104}",
    next_page = "\u{F105}",
}

--- Face for a glyph drawn in a square box of `box` pixels (the ink of the
--- symbol font takes about 0.83 em, like SimpleUI's GLYPH_RATIO).
function Style.glyphFace(box)
    -- getFace scales its size again; convert the pixels back
    local unit = Screen:scaleBySize(1000) / 1000
    return Font:getFace(Style.FACE_ICONS, (math.max(1, math.floor(box * 0.95)) - 0.5) / unit)
end

--- A glyph centered in a square of `box` pixels.
function Style.glyph(name, box, color)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom = require("ui/geometry")
    local TextWidget = require("ui/widget/textwidget")

    return CenterContainer:new({
        dimen = Geom:new({ w = box, h = box }),
        TextWidget:new({
            text = Style.ICON[name] or "",
            face = Style.glyphFace(box),
            fgcolor = color or Style.COLOR.text,
            padding = 0,
        }),
    })
end

return Style

--[[
Icons of the library browser's bar and pager.  With simpleui.koplugin 3
installed they are SimpleUI's, including the icons chosen in its settings
(Style -> icons: back, search, menu and pagination buttons); otherwise
KOReader's own.
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local IconWidget = require("ui/widget/iconwidget")
local TextWidget = require("ui/widget/textwidget")

local Style = require("grimmory/ui/style")

local Icons = {}

-- name -> SimpleUI slot, SimpleUI's own default file (key of its
-- Config.ICON), KOReader's icon
local SLOTS = {
    back = { slot = "sui_back", sui_file = "back", koreader = "chevron.left" },
    search = { slot = "sui_search", koreader = "appbar.search" },
    menu = { slot = "sui_menu", sui_file = "menu", koreader = "appbar.menu" },
    first = { slot = "sui_pager_first", koreader = "chevron.first" },
    previous = { slot = "sui_pager_prev", koreader = "chevron.left" },
    next = { slot = "sui_pager_next", koreader = "chevron.right" },
    last = { slot = "sui_pager_last", koreader = "chevron.last" },
}

local simpleui -- nil: not looked up yet; false: not installed

local function simpleUI()
    if simpleui == nil then
        local style_ok, style = pcall(require, "features/sui_style")
        local config_ok, config = pcall(require, "infra/sui_config")
        if style_ok and config_ok and type(style) == "table" and type(config) == "table"
            and type(style.resolveIcon) == "function" and type(config.nerdIconChar) == "function" then
            simpleui = { style = style, config = config }
        else
            simpleui = false
        end
    end
    return simpleui or nil
end

--- SimpleUI's icon for `name`: a file path or "nerd:XXXX", or nil.
local function simpleUIIcon(name)
    local sui = simpleUI()
    local spec = SLOTS[name]
    if not sui or not spec then
        return nil
    end

    local ok, icon = pcall(sui.style.resolveIcon, spec.slot)
    if ok and icon then
        return icon
    end
    if spec.sui_file and type(sui.config.ICON) == "table" then
        return sui.config.ICON[spec.sui_file]
    end
    return nil
end

--- SimpleUI's face for the tab labels (its title bar size setting), or nil.
function Icons.tabsFace()
    local ok, titlebar = pcall(require, "screens/sui_titlebar")
    if ok and type(titlebar) == "table" and type(titlebar.getTabsFace) == "function" then
        local face_ok, face = pcall(titlebar.getTabsFace)
        if face_ok and face then
            return face
        end
    end
    return nil
end

--- The icon `name` (see SLOTS) in a square of `size` pixels; `dim` grays it
--- out (a disabled button).
function Icons.widget(name, size, dim)
    local icon = simpleUIIcon(name)
    local widget

    local glyph = icon and simpleUI().config.nerdIconChar(icon)
    if glyph then
        widget = TextWidget:new({
            text = glyph,
            face = Style.glyphFace(size),
            fgcolor = dim and Style.COLOR.text_dim or Style.COLOR.text,
            padding = 0,
        })
    elseif icon then
        widget = IconWidget:new({ file = icon, width = size, height = size, dim = dim })
    else
        widget = IconWidget:new({ icon = SLOTS[name].koreader, width = size, height = size, dim = dim })
    end

    return CenterContainer:new({ dimen = Geom:new({ w = size, h = size }), widget })
end

return Icons

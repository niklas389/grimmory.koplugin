--[[
A text input popup in the look of the action sheets (ui/sheet.lua): icon and
title centered above a line, a rounded text field, and the buttons as
segments.  KOReader's InputDialog does the work (keyboard, its position,
Enter, tapping outside); only what it shows is replaced.

    InputSheet.show({
        title = "Search books", icon = "search", hint = "Title, author…",
        ok_text = "Search",
        on_ok = function(text) end,
    })
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputDialog = require("ui/widget/inputdialog")
local InputText = require("ui/widget/inputtext")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local util = require("util")
local _ = require("gettext")

local Style = require("grimmory/ui/style")
local Widgets = require("grimmory/ui/library/widgets")

local Screen = Device.screen

-- Its own rounded frame draws the border
local BorderlessInputText = InputText:extend{
    bordersize = 0,
}

local InputSheet = InputDialog:extend{
    icon = nil,
    inputtext_class = BorderlessInputText,
    is_movable = false,
}

local function sheetPadding()
    return Screen:scaleBySize(20)
end

function InputSheet:init()
    -- SimpleUI's sheets are 5/6 of the portrait width
    local portrait_w = math.min(Screen:getWidth(), Screen:getHeight())
    self.width = math.floor(portrait_w * 5 / 6)
    self.text_width = self.width - 2 * sheetPadding() - 2 * Screen:scaleBySize(12) - 2 * Size.border.thin
    self.input_padding = Screen:scaleBySize(6)
    self.input_margin = 0

    InputDialog.init(self)

    local pad = sheetPadding()
    local inner_w = self.width - 2 * pad

    local heading = HorizontalGroup:new({ align = "center" })
    if self.icon then
        local icon_size = Screen:scaleBySize(26)
        table.insert(heading, Style.glyph(self.icon, icon_size))
        table.insert(heading, HorizontalSpan:new({ width = Screen:scaleBySize(12) }))
    end
    table.insert(heading, TextWidget:new({
        text = self.title or "",
        face = Font:getFace(Style.FACE_BOLD, Style.FS_TITLE),
        max_width = inner_w,
        padding = 0,
    }))

    local field = FrameContainer:new({
        radius = Style.RADIUS,
        bordersize = Size.border.thin,
        color = Style.COLOR.border,
        background = Style.COLOR.surface,
        padding = 0,
        padding_left = Screen:scaleBySize(12) - self.input_padding,
        padding_right = Screen:scaleBySize(12) - self.input_padding,
        margin = 0,
        self._input_widget,
    })

    local segments = {}
    for _, button in ipairs(self.buttons[1] or {}) do
        table.insert(segments, {
            text = button.text,
            selected = button.is_enter_default,
            callback = button.callback,
        })
    end

    local group = VerticalGroup:new({
        align = "center",
        VerticalSpan:new({ width = Screen:scaleBySize(14) }),
        CenterContainer:new({ dimen = Geom:new({ w = inner_w, h = heading:getSize().h }), heading }),
        VerticalSpan:new({ width = Screen:scaleBySize(12) }),
        LineWidget:new({ dimen = Geom:new({ w = inner_w, h = Size.line.medium }), background = Style.COLOR.text }),
        VerticalSpan:new({ width = Screen:scaleBySize(16) }),
        field,
        VerticalSpan:new({ width = Screen:scaleBySize(16) }),
        Widgets.segments(segments, inner_w),
        VerticalSpan:new({ width = pad }),
    })

    self.dialog_frame = FrameContainer:new({
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = 0,
        padding_left = pad,
        padding_right = pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        group,
    })

    -- Above the keyboard, as InputDialog places its own frame
    local keyboard_height = self.keyboard_visible and self._input_widget:getKeyboardDimen().h or 0
    self[1] = CenterContainer:new({
        dimen = Geom:new({ w = self.screen_width, h = self.screen_height - keyboard_height }),
        ignore_if_over = "height",
        self.dialog_frame,
    })
end

--- Show the popup with its keyboard.
---@param opts table title, icon, hint, input, ok_text, on_ok(text) (trimmed, not empty), on_cancel
function InputSheet.show(opts)
    local dialog
    dialog = InputSheet:new({
        title = opts.title,
        icon = opts.icon,
        input = opts.input,
        input_hint = opts.hint,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                        if opts.on_cancel then
                            opts.on_cancel()
                        end
                    end,
                },
                {
                    text = opts.ok_text or _("OK"),
                    is_enter_default = true,
                    callback = function()
                        local text = util.trim(dialog:getInputText() or "")
                        UIManager:close(dialog)
                        if text ~= "" then
                            opts.on_ok(text)
                        end
                    end,
                },
            },
        },
    })

    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return dialog
end

return InputSheet

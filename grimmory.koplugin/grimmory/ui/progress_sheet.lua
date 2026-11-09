--[[
A progress popup in the look of the action sheets (ui/sheet.lua): icon and
title above a line, what is being done ("Downloading books"), where it is
("3 of 6 · Title"), a progress bar and a Stop button.

    local sheet = ProgressSheet.show({
        title = "Synchronizing with Grimmory", icon = "update",
        on_stop = function() end,   -- nil: no Stop button
    })
    sheet:update({ step = "Downloading books", detail = "3 of 6 · Title", fraction = 0.4 })
    sheet:close()

The size stays the same while it is shown, so only the popup is refreshed.
A new step is shown at once; details and the bar at most once a second (on
e-ink, every refresh costs).
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
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Style = require("grimmory/ui/style")
local Widgets = require("grimmory/ui/library/widgets")

local Screen = Device.screen

-- Details and the bar are redrawn at most this often
local REFRESH_SECONDS = 1

local ProgressSheet = InputContainer:extend{
    name = "grimmory_progress",
    -- Not modal: KOReader keeps modal widgets above all others, also above
    -- the "Stop synchronizing?" question.  Taps outside are caught anyway.
    title = nil,
    icon = nil,
    on_stop = nil,
}

function ProgressSheet:init()
    self.dimen = Geom:new({ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() })
    self.state = { step = "", detail = "", fraction = 0 }

    -- SimpleUI's sheets are 5/6 of the portrait width
    local portrait_w = math.min(Screen:getWidth(), Screen:getHeight())
    self.width = math.floor(portrait_w * 5 / 6)
    self.pad = Screen:scaleBySize(20)
    self.inner_w = self.width - 2 * self.pad

    -- Taps outside the popup do nothing (the sync goes on)
    self.ges_events = {
        TapOutside = { GestureRange:new({ ges = "tap", range = self.dimen }) },
    }
    if Device:hasKeys() then
        self.key_events = { Stop = { { Device.input.group.Back } } }
    end

    self.frame = FrameContainer:new({
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = 0,
        padding_left = self.pad,
        padding_right = self.pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        self:content(),
    })
    self[1] = CenterContainer:new({ dimen = self.dimen, self.frame })
end

--- One line of text, of a fixed height (the popup keeps its size)
function ProgressSheet:line(text, face, bold, color)
    local widget = TextWidget:new({
        text = text ~= "" and text or " ",
        face = face,
        bold = bold,
        fgcolor = color,
        max_width = self.inner_w,
        padding = 0,
    })
    return CenterContainer:new({
        dimen = Geom:new({ w = self.inner_w, h = widget:getSize().h }),
        widget,
    })
end

function ProgressSheet:content()
    local heading = HorizontalGroup:new({ align = "center" })
    if self.icon then
        table.insert(heading, Style.glyph(self.icon, Screen:scaleBySize(26)))
        table.insert(heading, HorizontalSpan:new({ width = Screen:scaleBySize(12) }))
    end
    table.insert(heading, TextWidget:new({
        text = self.title or "",
        face = Font:getFace(Style.FACE_BOLD, Style.FS_TITLE),
        max_width = self.inner_w,
        padding = 0,
    }))

    local group = VerticalGroup:new({
        align = "center",
        VerticalSpan:new({ width = Screen:scaleBySize(14) }),
        CenterContainer:new({ dimen = Geom:new({ w = self.inner_w, h = heading:getSize().h }), heading }),
        VerticalSpan:new({ width = Screen:scaleBySize(12) }),
        LineWidget:new({
            dimen = Geom:new({ w = self.inner_w, h = Size.line.medium }),
            background = Style.COLOR.text,
        }),
        VerticalSpan:new({ width = Screen:scaleBySize(16) }),
        self:line(self.state.step, Style.face(Style.FS_BODY), true),
        VerticalSpan:new({ width = Screen:scaleBySize(6) }),
        self:line(self.state.detail, Style.face(Style.FS_DETAIL), false, Style.COLOR.text_secondary),
        VerticalSpan:new({ width = Screen:scaleBySize(14) }),
        ProgressWidget:new({
            width = self.inner_w,
            height = Screen:scaleBySize(8),
            percentage = math.max(0, math.min(1, self.state.fraction or 0)),
            margin_h = 0,
            margin_v = 0,
            radius = Screen:scaleBySize(4),
            bordersize = 0,
            bgcolor = Style.COLOR.track,
            fillcolor = Style.COLOR.text,
        }),
    })

    if self.on_stop then
        table.insert(group, VerticalSpan:new({ width = Screen:scaleBySize(18) }))
        table.insert(group, Widgets.segments({
            { text = _("Stop"), callback = function() self:onStop() end },
        }, self.inner_w))
    end
    table.insert(group, VerticalSpan:new({ width = self.pad }))

    return group
end

--- Show the current state (the popup's size does not change)
function ProgressSheet:render()
    if self.closed then
        return
    end
    self.frame[1] = self:content()
    UIManager:setDirty(self, function()
        return "ui", self.frame.dimen
    end)
end

---@param state table { step = string, detail = string, fraction = number 0..1 } (any of them)
function ProgressSheet:update(state)
    local new_step = state.step ~= nil and state.step ~= self.state.step
    for key, value in pairs(state) do
        self.state[key] = value
    end

    if new_step then
        -- A new step: at once
        if self.render_task then
            UIManager:unschedule(self.render_task)
            self.render_task = nil
        end
        self:render()
        return
    end

    if not self.render_task then
        self.render_task = function()
            self.render_task = nil
            self:render()
        end
        UIManager:scheduleIn(REFRESH_SECONDS, self.render_task)
    end
end

function ProgressSheet:onTapOutside()
    return true
end

function ProgressSheet:onStop()
    if self.on_stop then
        self.on_stop()
    end
    return true
end

function ProgressSheet:close()
    if self.closed then
        return
    end
    self.closed = true
    if self.render_task then
        UIManager:unschedule(self.render_task)
        self.render_task = nil
    end
    UIManager:close(self, "ui")
end

function ProgressSheet:onCloseWidget()
    self.closed = true
    UIManager:setDirty(nil, function()
        return "ui", self.frame.dimen
    end)
end

---@param opts table title, icon, on_stop
function ProgressSheet.show(opts)
    local sheet = ProgressSheet:new({
        title = opts.title,
        icon = opts.icon,
        on_stop = opts.on_stop,
    })
    UIManager:show(sheet, "ui")
    return sheet
end

return ProgressSheet

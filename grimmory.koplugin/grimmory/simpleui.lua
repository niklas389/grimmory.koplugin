--[[
Integration with simpleui.koplugin 3, through its plugin APIs:

- a "Grimmory" Quick Action (QA.register): it can be chosen as a tab of
  SimpleUI's bottom navigation bar (or as a Quick Action), and opens the
  library browser;
- a bar injection (BarInjection.register): SimpleUI shows its bars inside
  the library browser, with the Grimmory tab active, like in its own screens.

Without SimpleUI, nothing happens.
--]]

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local PluginMetadata = require("grimmory/plugin_metadata")

local SimpleUI = {}

-- Also the tab's id in SimpleUI's settings: keep it stable
SimpleUI.ACTION_ID = "grimmory_library"
-- LibraryBrowser.name
SimpleUI.WIDGET_NAME = "grimmory_library"

local registered = false

local function load(module)
    local ok, loaded = pcall(require, module)
    return ok and type(loaded) == "table" and loaded or nil
end

--- SimpleUI's Quick Actions and bar injection, when installed
local function apis()
    local QA = load("features/sui_quickactions")
    local UI = load("infra/sui_core")
    if not (QA and type(QA.register) == "function" and UI and type(UI.BarInjection) == "table"
        and type(UI.BarInjection.register) == "function") then
        return nil
    end
    return QA, UI
end

--- The open library browser, if any
function SimpleUI.openBrowser()
    for i = #UIManager._window_stack, 1, -1 do
        local widget = UIManager._window_stack[i].widget
        if widget and widget.name == SimpleUI.WIDGET_NAME then
            return widget
        end
    end
    return nil
end

--- Register once per KOReader start (SimpleUI keeps its registry in memory).
function SimpleUI.register()
    if registered then
        return
    end
    local QA, UI = apis()
    if not QA then
        return
    end
    registered = true

    QA.register({
        id = SimpleUI.ACTION_ID,
        label = _("Grimmory"),
        icon = PluginMetadata.getPluginPath() .. "/icons/local_library.svg",
        -- Opens a screen of its own (like SimpleUI's Custom Screens)
        is_in_place = false,
        execute = function()
            local browser = SimpleUI.openBrowser()
            if browser then
                -- Tapped again: back to the start
                browser:selectTab("home")
            else
                UIManager:broadcastEvent(Event:new("GrimmoryBrowseLibrary"))
            end
        end,
    })

    UI.BarInjection.register({
        id = SimpleUI.ACTION_ID,
        widget_name = SimpleUI.WIDGET_NAME,
        active_action_id = SimpleUI.ACTION_ID,
        -- The browser has its own page buttons
        is_pageable = false,
        on_inject = function(widget)
            if widget.onNavbarInjected then
                widget:onNavbarInjected()
            end
        end,
    })

    -- SimpleUI may have read its tab settings before this registration and
    -- left out the unknown Grimmory tab: read them again
    local Config = load("infra/sui_config")
    if Config and type(Config.invalidateTabsCache) == "function" then
        pcall(Config.invalidateTabsCache)
    end
end

--- Content area between SimpleUI's top and bottom bars, while the browser
--- shows them.
---@return number | nil top
---@return number | nil height
function SimpleUI.contentArea()
    local UI = load("infra/sui_core")
    if not (UI and type(UI.getContentTop) == "function" and type(UI.getContentHeight) == "function") then
        return nil
    end
    local ok_top, top = pcall(UI.getContentTop)
    local ok_height, height = pcall(UI.getContentHeight)
    if ok_top and ok_height then
        return top, height
    end
    return nil
end

return SimpleUI

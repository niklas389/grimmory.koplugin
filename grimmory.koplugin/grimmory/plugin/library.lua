--[[
Grimmory plugin: opening the library browser, and the network it needs.
Methods of the plugin (main.lua).
--]]

local _ = require("gettext")
local T = require("ffi/util").template
local NetworkManager = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local Shared = require("grimmory/plugin/shared")

---@class GrimmoryMethods
local Grimmory = {}

function Grimmory:onGrimmoryBrowseLibrary()
    if self.settings:getBaseUri() == "" then
        self.dialog_manager:toast(_("Set up the Grimmory connection first"))
        return true
    end

    local function show(release_wifi, connect)
        local LibraryBrowser = require("grimmory/ui/library/browser")

        UIManager:show(LibraryBrowser:new({
            connect = connect,
            api = self.api,
            settings = self.settings,
            repository = self.repository,
            executor = self.executor,
            synchronizer = self.synchronizer,
            dialog_manager = self.dialog_manager,
            release_wifi = release_wifi,
            is_connected = function()
                return self:isWifiConnected()
            end,
            reconnect = function(on_ready, on_failed)
                self:reconnect(on_ready, on_failed)
            end,
            is_sync_running = function()
                return self.is_synchronizing or Shared.sync_in_progress
            end,
        }))
    end

    -- WiFi is kept on while browsing and turned off again on close if the
    -- plugin turned it on.
    if self.settings:getSyncEnableWifi() or self:isWifiConnected() then
        -- Open right away and connect meanwhile (the browser shows
        -- "Connecting…" and loads once connected)
        show(nil, function(on_ready, on_failed)
            self:withNetwork(on_ready, on_failed, true)
        end)
    else
        -- KOReader asks whether to turn on WiFi first; it does not tell
        -- when that is declined, so the browser opens afterwards.
        self:withNetwork(show, function(reason)
            self.dialog_manager:toast(T(_("Cannot open the Grimmory library:\n%1"), reason))
        end)
    end

    return true
end

--- Run `on_ready(release)` once the device is online; `release()` ends the
--- need for the connection.  With "Turn On WiFi When Needed" WiFi is turned
--- on (and later off again) by the plugin, otherwise KOReader asks.
---@param on_ready function(release: function)
---@param on_failed function(reason: string) | nil
---@param silent boolean | nil No "connecting…" notification (the caller shows its own)
function Grimmory:withNetwork(on_ready, on_failed, silent)
    on_failed = on_failed or function() end

    if self.settings:getSyncEnableWifi() then
        local close_notification
        if not silent and not self:isWifiConnected() then
            close_notification = self.dialog_manager:notify(_("Grimmory: connecting…"))
        end

        self.executor:holdWifi(
            function(release)
                if close_notification then
                    pcall(close_notification)
                end
                on_ready(release)
            end,
            function(connect_error)
                if close_notification then
                    pcall(close_notification)
                end
                on_failed(Shared.describeSyncError(connect_error) or _("No network connection"))
            end
        )
    elseif self:isWifiConnected() then
        on_ready(function() end)
    else
        -- WiFi may not be turned on automatically: let KOReader ask.  When
        -- the user declines, nothing happens, as everywhere in KOReader.
        NetworkManager:runWhenOnline(function()
            on_ready(function() end)
        end)
    end
end

--- Connect again after the connection was lost (e.g. while browsing).
---@param on_ready function()
---@param on_failed function(reason: string)
function Grimmory:reconnect(on_ready, on_failed)
    if self.settings:getSyncEnableWifi() then
        local close_notification = self.dialog_manager:notify(_("Grimmory: reconnecting…"))

        self.executor:reconnectWifi(
            function()
                pcall(close_notification)
                on_ready()
            end,
            function(connect_error)
                pcall(close_notification)
                on_failed(Shared.describeSyncError(connect_error) or _("No network connection"))
            end
        )
    elseif self:isWifiConnected() then
        on_ready()
    else
        NetworkManager:runWhenOnline(on_ready)
    end
end

return Grimmory

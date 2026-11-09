--[[
Grimmory plugin: the reading position of the open book from the server
(when opening it, on wake).  Methods of the plugin (main.lua).
--]]

local _ = require("gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local Event = require("ui/event")

local GrimmoryAPI = require("grimmory/grimmory_api")
local GrimmoryDocMetadata = require("grimmory/doc_metadata")
local GrimmoryLogger = require("grimmory/logger")
local Shared = require("grimmory/plugin/shared")

local logger = GrimmoryLogger:new()

---@class GrimmoryMethods
local Grimmory = {}

--- A book downloaded from Grimmory with only a percentage as position (e.g.
--- read in Grimmory's reader) jumps there once it is open.
function Grimmory:applyOpenAtPercent()
    local doc_settings = self.ui and self.ui.doc_settings
    if not doc_settings then
        return
    end

    local percent = tonumber(doc_settings:readSetting(GrimmoryDocMetadata.OPEN_AT_PERCENT))
    if not percent then
        return
    end

    doc_settings:delSetting(GrimmoryDocMetadata.OPEN_AT_PERCENT)
    logger:info("Opening at the server's reading position:", percent)

    UIManager:nextTick(function()
        if self.ui and self.ui.document then
            self.ui:handleEvent(Event:new("GotoPercent", percent))
        end
    end)
end

function Grimmory:pullProgressForOpenBook()
    if self.ui == nil or self.ui.document == nil or self.ui.document.file == nil then
        return
    end

    -- E.g. a .txt or an image: never a Grimmory book, no need to ask
    if not GrimmoryAPI.isGrimmoryFormat(self.ui.document.file) then
        return
    end

    if self.settings:getBaseUri() == "" then
        -- Not configured, don't try to reach a server (or turn on WiFi)
        return
    end

    if not self.settings:getSyncEnableWifi() and not self:isWifiConnected() then
        logger:dbg("No connectivity and WiFi may not be enabled, skipping progress check")
        return
    end

    local book_path = self.ui.document.file

    -- Tell everything to flush so we have data available for our sync
    UIManager:broadcastEvent(Event:new("FlushSettings"))

    self.executor:background(
        function(run)
            -- Connecting WiFi and asking the server can take a while, so show
            -- that something is happening (a small corner icon, not to
            -- distract from reading).
            local sync_indicator = self.dialog_manager:showSyncIndicator("download")

            local run_ok, ok, latest_progress = pcall(
                run,
                function()
                    local _, _, latest_progress = self.reading_progress_manager:getNewerProgressForBook(book_path)
                    return latest_progress
                end
            )

            sync_indicator:done(run_ok and ok)

            if not run_ok or not ok then
                local error_result = run_ok and latest_progress or ok
                logger:err("Could not check reading progress", error_result)

                local reason = Shared.describeSyncError(error_result)
                if reason then
                    self.dialog_manager:notify(T(_("Grimmory: could not check reading progress: %1"), reason), 3)
                else
                    self.dialog_manager:notify(_("Grimmory: could not check reading progress"), 3)
                end
                return
            end

            if not latest_progress then
                return
            end

            self.dialog_manager:showApplyProgressConfirmation(latest_progress)
        end,
        self.settings:getSyncEnableWifi()
    )
end

return Grimmory

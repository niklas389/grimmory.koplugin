local _ = require("gettext")
local T = require("ffi/util").template

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local PathChooser = require("ui/widget/pathchooser")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local Size = require("ui/size")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

-- KOReader's Notification has square corners; give it the rounded corners
-- of InfoMessage and the other dialogs.
local RoundedNotification = Notification:extend{}

function RoundedNotification:init()
    Notification.init(self)
    self.frame.radius = Size.radius.window
end

---@param value any
---@param fallback number
---@param minimum number
---@return number
local function parse_number(value, fallback, minimum)
    local number = tonumber(value)

    if number == nil or number ~= number then
        number = fallback
    end

    return math.max(minimum, number)
end

---@class DialogManager
---@field settings GrimmorySettings
---@field api GrimmoryAPI
---@field updater GrimmorySelfUpdater
---@field reading_progress_manager ReadingProgressManager
local DialogManager = {}

function DialogManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function DialogManager:toast(text, timeout)
    if self.info_message then
        UIManager:close(self.info_message)
    end

    if timeout == nil then
        timeout = 2
    elseif timeout <= 0 then
        timeout = nil
    end

    local info_message = InfoMessage:new({
        text = text,
        timeout = timeout,
    })

    UIManager:show(info_message)
    self.info_message = info_message

    return function() UIManager:close(info_message) end
end

--- Show a small notification at the top of the screen.  Unlike `toast` it
--- does not block input: any tap or key press closes it and still reaches
--- the reader, so it can stay up while work runs in the background.
---@param text string
---@param timeout number | nil Seconds until it closes; `nil` keeps it until closed
---@return function close
function DialogManager:notify(text, timeout)
    local notification = RoundedNotification:new({
        text = text,
        timeout = timeout,
    })

    UIManager:show(notification)

    return function() UIManager:close(notification) end
end

function DialogManager:showConnectionSettings()
    local dialog
    dialog = MultiInputDialog:new({
        title = _("Grimmory Connection"),
        fields = {
            {
                text = self.settings:getBaseUri(),
                description = _("Server URL"),
                hint = _("http://example.com:port"),
            },
            {
                text = self.settings:getUsername(),
                description = _("Username"),
            },
            {
                text = self.settings:getPassword(),
                description = _("Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Test"),
                callback = function()
                    local fields = dialog:getFields()

                    local ok, version = self.api:testConnection(
                        fields[1],
                        fields[2],
                        fields[3]
                    )

                    if ok then
                        self:toast(T(_("Connection successful\nGrimmory (%1)"), tostring(version)))
                    else
                        self:toast(T(_("Unable to connect to Grimmory\nError: %1"), tostring(version)))
                    end
                end,
            },
            {
                text = _("Apply"),
                callback = function()
                    local fields = dialog:getFields()

                    self.settings:setBaseUri(fields[1])
                    self.settings:setUsername(fields[2])
                    self.settings:setPassword(fields[3])

                    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                    UIManager:close(dialog)
                end,
            },
            },
        },
    })

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function DialogManager:showTargetShelvesSettings()
    local dialog
    local ok, result = self.api:getShelves()

    if not ok or type(result) ~= "table" then
        logger:err("Something went wrong loading shelves", result)
        self:toast(T(_("Could not load shelves: %1"), tostring(result)))
        return
    end

    local buttons = {
        {
            {
                text = _("Cancel Selection"),
                callback = function()
                    UIManager:close(dialog)
                end,
            }
        },
        {
            {
                text = _("All Shelves"),
                callback = function()
                    logger:dbg("Set target shelves to All Shelves")
                    self.settings:setDownloadTargetShelves({})

                    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                    UIManager:close(dialog)
                end,
            }
        }
    }

    local shelfNameToId = {}

    for _, shelf in ipairs(result) do
        local shelfName = shelf.name
        local shelfId = shelf.id

        local uniqueShelfName = shelfName
        local uniqueShelfIndex = 0
        while shelfNameToId[uniqueShelfName] do
            uniqueShelfIndex = uniqueShelfIndex + 1
            uniqueShelfName = shelfName .. " " .. uniqueShelfIndex
        end

        table.insert(
            buttons,
            {
                {
                    text = uniqueShelfName,
                    callback = function()
                        logger:dbg("Set target shelves to shelf ID", shelfId)
                        self.settings:setDownloadTargetShelves({ { id = shelfId, name = uniqueShelfName } })

                        UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                        UIManager:close(dialog)
                    end
                }
            }
        )
    end

    dialog = ButtonDialog:new({
        title = _("Target Shelf"),
        buttons = buttons,
    })

    UIManager:show(dialog)
end

function DialogManager:showSyncFrequencySettings()
    local dialog
    dialog = MultiInputDialog:new({
        title = _("Periodic Sync Frequency"),
        fields = {
            {
                text = tostring(self.settings:getSyncFrequency()),
                description = _("Minutes between synchronization"),
                input_type = "number"
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Apply"),
                    callback = function()
                        local fields = dialog:getFields()

                        self.settings:setSyncFrequency(
                            parse_number(fields[1], self.settings:getSyncFrequency(), 1)
                        )

                        UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                        UIManager:close(dialog)
                    end,
                },
            },
        },
    })

    UIManager:show(dialog)
end

function DialogManager:showSessionThresholdSettings()
    local dialog
    dialog = MultiInputDialog:new({
        title = _("Session Thresholds"),
        fields = {
            {
                text = tostring(self.settings:getSessionThresholdSeconds()),
                description = _("Minimum Session Seconds"),
                input_type = "number",
            },
            {
                text = tostring(self.settings:getSessionThresholdPages()),
                description = _("Minimum Session Pages"),
                input_type = "number",
            },
        },
        buttons = {
            {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Apply"),
                callback = function()
                    local fields = dialog:getFields()

                    self.settings:setSessionThresholdSeconds(
                        parse_number(fields[1], self.settings:getSessionThresholdSeconds(), 0)
                    )
                    self.settings:setSessionThresholdPages(
                        parse_number(fields[2], self.settings:getSessionThresholdPages(), 0)
                    )

                    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                    UIManager:close(dialog)
                end,
            },
            },
        },
    })

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function DialogManager:showDownloadDirectorySettings()
    local dialog
    dialog = PathChooser:new({
        title = "Download Directory",
        select_file = false,
        show_files = false,
        path = self.settings:getDownloadDirectory(),
        onConfirm = function(newPath)
            self.settings:setDownloadDirectory(newPath)
        end,
    })

    UIManager:show(dialog)
end

---@param skip_version_check boolean | nil
---@param check_error string | nil Error of a check that already ran
function DialogManager:showPluginUpdateCheck(skip_version_check, check_error)
    if not skip_version_check then
        -- Refresh the latest version on open.
        local close_message = self:toast(_("Checking for Updates"), 0)
        check_error = select(2, self.updater:fetchLatestVersion())
        pcall(close_message)
    end

    local dialog
    local latest_version = self.updater:getLatestReleaseVersion()
    local is_update_available = self.updater:isUpdateAvailable()

    local update_button_text = _("No update available")
    local title = _("Grimmory.koplugin is currently up-to-date.")

    if check_error then
        -- Don't claim to be up-to-date when the check itself failed.
        title = T(_("Could not check for updates.\n%1"), check_error)
    end

    if is_update_available then
        update_button_text = T(_("Update to %1"), latest_version)
        title = _("Update available for Grimmory.koplugin.")
    end

    dialog = ButtonDialog:new({
        title = title,
        buttons = {
            {
                {
                    text = update_button_text,
                    callback = function()
                        if is_update_available then
                            UIManager:close(dialog)

                            self:showPluginUpdater()
                        end
                    end,
                },
                {
                    text = _("Check for Updates"),
                    callback = function()
                        local fetch_error = select(2, self.updater:fetchLatestVersion())
                        UIManager:close(dialog)
                        self:showPluginUpdateCheck(true, fetch_error)
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    })

    UIManager:show(dialog)
end

function DialogManager:showPluginUpdater()
    local dialog = ProgressbarDialog:new({
        title = _("Updating Grimmory Plugin"),
        progress_max = 100,
        refresh_time_seconds = 3,
        dismissable = false,
    })

    UIManager:show(dialog)

    UIManager:nextTick(function()
        self.updater:update(
            function(state, progress, message)
                dialog:reportProgress(progress)

                if state == "complete" then
                    UIManager:close(dialog)

                    UIManager:askForRestart(_("Grimmory plugin update will apply on next Restart."))
                elseif state == "failed" then
                    UIManager:close(dialog)

                    self:toast(T(_("Failed to update\n%1"), message), 0)
                end
            end
        )
    end)
end

function DialogManager:showProgressDialog(title, dismiss_callback, dismiss_text)
    local dialog
    local is_external_closing = false

    if dismiss_text == nil then
        dismiss_text = _("Terminate this task?")
    end

    dialog = ProgressbarDialog:new({
        title = _(title),
        progress_max = 100,
        refresh_time_seconds = 3,
        dismiss_text = dismiss_text,
        dismissable = dismiss_callback ~= nil,
        dismiss_callback = function ()
            if not is_external_closing then
                -- Only call the dismiss callback if we are closing
                -- from the progress bar dialog itself.
                pcall(dismiss_callback)
            end
        end
    })

    dialog:show()

    local close_callback = function()
        is_external_closing = true
        dialog:close()
    end

    local function update_callback(progress, total_progress)
        dialog.progress_max = total_progress
        dialog:reportProgress(progress)
    end

    return update_callback, close_callback
end

---@param progress ReadingSessionProgress
function DialogManager:showApplyProgressConfirmation(progress)
    -- TODO:

    -- Reading Progress is Available from Grimmory
    -- Go to page 25 from 25 minutes ago?

    local dialog = ConfirmBox:new({
        text = T(
            _("Go to latest location %1% from Grimmory?"),
            string.format("%.1f", tonumber(progress.end_progress) or 0)
        ),
        ok_callback = function()
            self.reading_progress_manager:applyProgress(progress)
        end,
    })

    UIManager:show(dialog)
end

return DialogManager
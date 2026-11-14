--[[--
Grimmory KOReader Plugin

@module koplugin.Grimmory
--]]--
local _ = require("gettext")

local Dispatcher = require("dispatcher")
local FileManager = require("apps/filemanager/filemanager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local GrimmoryDocMetadata = require("grimmory/doc_metadata")
local GrimmoryDialogManager = require("grimmory/ui/dialog_manager")
local GrimmoryExecutor = require("grimmory/executor")
local GrimmoryMenu = require("grimmory/ui/menu")
local GrimmorySettings = require("grimmory/settings")
local GrimmorySimpleUI = require("grimmory/simpleui")
local GrimmoryAPI = require("grimmory/grimmory_api")
local GrimmorySynchronize = require("grimmory/synchronize")
local GrimmoryScheduler = require("grimmory/scheduler")
local GrimmorySelfUpdater = require("grimmory/ota/self_updater")
local GithubAPI = require("grimmory/ota/github_api")
local HttpClient = require("grimmory/http_client")
local GrimmoryLogger = require("grimmory/logger")
local GrimmoryReadingRecorder = require("grimmory/reading/recorder")
local GrimmoryLocalRepository = require("grimmory/repository")
local GrimmoryReadingAnnotations = require("grimmory/reading/annotations")
local GrimmoryReadingProgressManager = require("grimmory/reading/progress_manager")
local Shared = require("grimmory/plugin/shared")

local logger = GrimmoryLogger:new()

-- Shared by all instances, see Grimmory:init
local shared_settings = nil

-- Retrying what earlier syncs could not send (see Shared.RETRY_DELAY_SECONDS)
local retry_task = nil  -- scheduled retry (one for all plugin instances)
local retry_owner = nil -- the instance that scheduled it

---@class Grimmory
---@field dialog_manager DialogManager
---@field scheduler GrimmoryScheduler
---@field synchronizer GrimmorySynchronize
---@field ui any This is a ReaderUI
local Grimmory = WidgetContainer:extend{
    name = "grimmory",
    is_doc_only = false,
    periodic_sync_cancel = nil,
    periodic_sync_update = nil,
    release_check_cancel = nil,
    menu = nil,
    is_synchronizing = false,
}

function Grimmory:onDispatcherRegisterActions()
  Dispatcher:registerAction("grimmory_browse_library", {
    category = "none",
    event = "GrimmoryBrowseLibrary",
    title = _("Grimmory: Browse Library"),
    general = true,
  })

  Dispatcher:registerAction("grimmory_sync_foreground", {
    category = "none",
    event = "GrimmorySyncForegound",
    title = _("Grimmory: Sync Now"),
    general = true,
  })

  Dispatcher:registerAction("grimmory_sync_background", {
    category = "none",
    event = "GrimmorySyncBackground",
    title = _("Grimmory: Sync in Background"),
    general = true,
  })

  Dispatcher:registerAction("grimmory_sync_open_book_foreground", {
    category = "none",
    event = "GrimmorySyncOpenBookForeground",
    title = _("Grimmory: Sync Open Book Now"),
    general = true,
  })

  Dispatcher:registerAction("grimmory_sync_open_book_background", {
    category = "none",
    event = "GrimmorySyncOpenBookBackground",
    title = _("Grimmory: Sync Open Book in Background"),
    general = true,
  })
end

function Grimmory:init()
    self.scheduler = GrimmoryScheduler:new()
    -- One settings object for all instances: the reader's instance may still
    -- save something (e.g. after the sync on closing a book) when the file
    -- manager's has already loaded the settings, and would be overwritten
    shared_settings = shared_settings or GrimmorySettings:new()
    self.settings = shared_settings

    self.repository = GrimmoryLocalRepository:new({
        settings = self.settings,
    })

    self.doc_metadata = GrimmoryDocMetadata:new({
        ui = self.ui,
    })

    self.reading_recorder = GrimmoryReadingRecorder:new({
        repository = self.repository,
        settings = self.settings,
        ui = self.ui,
    })

    self.updater = GrimmorySelfUpdater:new({
        github_api = GithubAPI:new(),
        settings = self.settings,
        scheduler = self.scheduler,
    })

    self.api = GrimmoryAPI:new({
        settings = self.settings
    })

    self.reading_annotations = GrimmoryReadingAnnotations:new(self.doc_metadata)

    self.reading_progress_manager = GrimmoryReadingProgressManager:new({
        ui = self.ui,
        api = self.api,
        settings = self.settings,
        repository = self.repository,
        reading_recorder = self.reading_recorder,
        doc_metadata = self.doc_metadata,
    })

    self.dialog_manager = GrimmoryDialogManager:new({
        settings = self.settings,
        api = self.api,
        updater = self.updater,
        reading_progress_manager = self.reading_progress_manager,
    })

    self.menu = GrimmoryMenu:new({
        ui = self.ui,
        settings = self.settings,
        api = self.api,
        dialog_manager = self.dialog_manager,
        updater = self.updater,
    })

    self.synchronizer = GrimmorySynchronize:new({
        settings = self.settings,
        repository = self.repository,
        api = self.api,
        doc_metadata = self.doc_metadata,
        reading_progress_manager = self.reading_progress_manager,
        reading_annotations = self.reading_annotations,
    })

    self.executor = GrimmoryExecutor:new({
        settings = self.settings,
    })

    self.dialog_manager.with_network = function(on_ready, on_failed)
        return self:withNetwork(on_ready, on_failed)
    end

    self:onGrimmorySettingsChanged()

    self.ui.menu:registerToMainMenu(self.menu)

    FileManager:addFileDialogButtons(
        "grimmory_actions",
        function(file, is_file)
            if not is_file then
                return nil
            end

            return {
                {
                    text = _("Sync with Grimmory"),
                    -- Icon in SimpleUI's book sheet (KOReader ignores it)
                    sui_icon = "update",
                    callback = function()
                        local file_chooser = FileManager.instance.file_chooser

                        if file_chooser and file_chooser.file_dialog then
                            UIManager:close(file_chooser.file_dialog)
                        end

                        self:onGrimmorySync(true, file)
                    end,
                },
                {
                    text = _("Reload from Grimmory"),
                    sui_icon = "import",
                    callback = function()
                        local file_chooser = FileManager.instance.file_chooser

                        if file_chooser and file_chooser.file_dialog then
                            UIManager:close(file_chooser.file_dialog)
                        end

                        -- Mark book for refresh
                        self:onGrimmorySync(true, file, true)
                    end
                }
            }
        end
    )

    self:onDispatcherRegisterActions()

    -- Something left over from before (e.g. KOReader closed while offline)
    self:scheduleRetry(Shared.RETRY_DELAY_SECONDS)

    -- A "Grimmory" tab for SimpleUI's bottom bar, if SimpleUI is installed
    GrimmorySimpleUI.register()

    logger:dbg("Initialized")
end

function Grimmory:onExit()
    logger:dbg("Exiting")

    self.scheduler:clear()
    self.executor:clear()
end

function Grimmory:onCloseWidget()
    -- The FileManager / ReaderUI owning this plugin instance is being closed.
    -- A new instance (with its own interval) is created for the next UI, so
    -- this instance's periodic sync must stop or syncs pile up over time.
    logger:dbg("Closing widget, cancelling scheduled tasks")

    if self.periodic_sync_cancel then
        self.periodic_sync_cancel()
    end

    self.periodic_sync_cancel = nil
    self.periodic_sync_update = nil

    self.scheduler:clear()

    -- The next instance (file manager / reader) schedules its own
    if retry_owner == self then
        UIManager:unschedule(retry_task)
        retry_task, retry_owner = nil, nil
    end
end

function Grimmory:onSuspend()
    logger:dbg("Device is suspending")

    if GrimmoryExecutor.isOwnConnectionEvent() then
        -- PocketBook: the system WiFi dialog of our own connection attempt
        -- opened, the device is not going to sleep
        logger:dbg("Suspend from our own WiFi connection attempt, ignored")
        return
    end

    self.reading_recorder:onSessionEnd()

    if self.settings:getSyncOnSuspend() then
       -- KOReader turns WiFi off right after the Suspend event (WiFi left on
       -- can deadlock suspend on Kobo), so only sync over an existing connection.
       self:onGrimmorySync(false, nil, nil, { allow_enable_wifi = false })
    end
end

function Grimmory:onResume()
    logger:dbg("Device is resuming")

    if GrimmoryExecutor.isOwnConnectionEvent() then
        -- PocketBook: the system WiFi dialog of our own connection attempt
        -- closed.  Checking the progress again would turn WiFi on again,
        -- show the dialog again, and so on.
        logger:dbg("Resume from our own WiFi connection attempt, ignored")
        return
    end

    if self.settings:getSyncReadingProgress() and self.settings:getSyncProgressOnResume() then
        self:pullProgressForOpenBook()
    end

    self.reading_recorder:onSessionStart()

    self:scheduleRetry(Shared.RETRY_DELAY_SECONDS)
end

function Grimmory:onPowerOff()
    logger:dbg("Device is powering off")

    self.reading_recorder:onSessionEnd()

    if self.settings:getSyncOnPowerOff() then
       -- The device shuts down before WiFi could connect, so only sync
       -- over an existing connection.
       self:onGrimmorySync(false, nil, nil, { allow_enable_wifi = false })
    end
end

function Grimmory:onReaderReady()
    logger:dbg("Document open and ready")

    self:applyOpenAtPercent()

    if self.settings:getSyncReadingProgress() and self.settings:getSyncProgressOnOpen() then
        self:pullProgressForOpenBook()
    end

    self.reading_recorder:onSessionStart()
end

--- Before a sync (and whenever KOReader saves its settings): write the page
--- turns the recorder has not written yet
function Grimmory:onFlushSettings()
    if self.reading_recorder then
        self.reading_recorder:flush()
    end
end

function Grimmory:onPageUpdate(page)
    logger:dbg("Page Update", page)

    -- Run after everything else does for a page event.
    -- This prevents issues like the previous page's xpointer being
    -- returned for a given page.
    UIManager:nextTick(function()
        self.reading_recorder:onPageUpdate()
    end)
end

function Grimmory:onCloseDocument()
    logger:dbg("Document closing")

    self.reading_recorder:onSessionEnd()

    local close_sync = self.settings:getSyncOnCloseDocument()
    local smart = self.settings:getSmartDownloadMode() ~= "off"

    if (close_sync or smart) and self.ui and self.ui.document and self.ui.document.file
        and GrimmoryAPI.isGrimmoryFormat(self.ui.document.file) then
        -- Only push this book's reading progress (the whole library is
        -- synchronized by the periodic / manual sync), and with smart
        -- download get the next volumes of its series.
        local book_path = self.ui.document.file

        -- Do not block the UI thread
        UIManager:nextTick(function()
            self:onGrimmorySync(false, book_path, nil, {
                notify = close_sync,
                progress_only = true,
                smart = smart,
                automatic = true,
            })
        end)
    end
end

function Grimmory:onAnnotationsModified(annotation_info)
    logger:dbg("Annotations modified", annotation_info)

    if type(annotation_info) ~= "table" then
        return
    end

    local annotation = annotation_info[1]

    local is_modified = false
    if annotation_info.index_modified == nil then
        self.reading_recorder:onAnnotationUpdated()
        is_modified = true
    elseif annotation_info.index_modified < 0 then
        self.reading_recorder:onAnnotationRemoved()
        is_modified = true
    else
        self.reading_recorder:onAnnotationAdded()
    end

    -- Every change (new, changed, deleted) is pushed by the next sync that
    -- gets through, see Grimmory:onGrimmorySync
    if self.settings:getSyncAnnotations() and self.ui and self.ui.document and self.ui.document.file then
        self.settings:markPendingSync(self.ui.document.file, "annotations")
    end

    if is_modified and self.ui ~= nil and self.ui.document ~= nil and self.ui.document.file ~= nil then
        if type(annotation) == "table" and annotation.grimmory_id ~= nil then
            self.doc_metadata:appendModifiedGrimmoryAnnotation(
                self.ui.document.file,
                annotation.grimmory_id
            )
        end
    end
end

function Grimmory:onGrimmorySettingsChanged()
    logger:dbg("Settings Changed")

    self:onSchedulePeriodicPush()
end

function Grimmory:onSchedulePeriodicPush()
    if self.settings:getSyncPeriodically() then
        -- If we want to sync we need to either update
        -- and existing schedule if we already scheduled

        local frequency_seconds = self.settings:getSyncFrequency() * 60

        if self.periodic_sync_update then
            -- We already have an interval set up, so we should update
            -- it with a new frequency
            self.periodic_sync_update(frequency_seconds)
        else
            -- We don't have an existing sync update helper so we need
            -- to schedule a new interval.
            local cancel, update = self.scheduler:interval(
                frequency_seconds,
                function()
                    self:onGrimmorySync(false, nil, nil, { automatic = true })
                end
            )

            self.periodic_sync_cancel = cancel
            self.periodic_sync_update = update
        end
    else
        -- We don't want to sync anymore so we need to cancel
        -- if it's defined and clean up the cancel / update props
        if self.periodic_sync_cancel then
            self.periodic_sync_cancel()
        end

        self.periodic_sync_cancel = nil
        self.periodic_sync_update = nil
    end
end

--- Whether an earlier sync left something unsent that can be sent now: a
--- sync of all books that failed, a book's progress, or highlights of a
--- book that is not open (those of the open book wait until it is closed).
function Grimmory:hasPendingSync()
    if self.settings:getPendingSyncPush() then
        return true
    end

    local open_book_path = self.ui and self.ui.document and self.ui.document.file or nil
    for path, kinds in pairs(self.settings:getPendingSyncBooks()) do
        if kinds.progress or (kinds.annotations and path ~= open_book_path) then
            return true
        end
    end
    return false
end

function Grimmory:scheduleRetry(delay)
    if retry_task then
        UIManager:unschedule(retry_task)
    end
    retry_owner = self
    retry_task = function()
        retry_task, retry_owner = nil, nil
        self:retryPendingSync()
    end
    UIManager:scheduleIn(delay, retry_task)
end

--- Send what earlier syncs could not, if connected (WiFi is not turned on
--- for this: it would drain the battery).
function Grimmory:retryPendingSync()
    if self.settings:getBaseUri() == "" or not self:isWifiConnected() then
        return
    end

    if not self:hasPendingSync() then
        return
    end

    if self.is_synchronizing or Shared.sync_in_progress then
        -- That sync sends the pending things too; check again afterwards
        self:scheduleRetry(60)
        return
    end

    logger:info("Retrying what earlier syncs could not send")
    self:onGrimmorySync(false, nil, nil, {
        pending_only = true,
        allow_enable_wifi = false,
        indicator = true,
    })
end

--- WiFi connected (by the user, KOReader or a plugin): send what is pending
function Grimmory:onNetworkConnected()
    -- A new connection (maybe another network): try servers again that did
    -- not answer before, and turn WiFi on by itself again when needed
    HttpClient.forgetUnreachable()
    GrimmoryExecutor.resumeAutoWifi()
    self:scheduleRetry(Shared.RETRY_DELAY_SECONDS)
end

-- Methods kept in their own files, by subject
for _, module in ipairs({
    "grimmory/plugin/sync",
    "grimmory/plugin/library",
    "grimmory/plugin/reading",
}) do
    for name, method in pairs(require(module)) do
        Grimmory[name] = method
    end
end

return Grimmory

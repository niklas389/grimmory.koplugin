--[[--
Grimmory KOReader Plugin

@module koplugin.Grimmory
--]]--
local _ = require("gettext")
local T = require("ffi/util").template

local Dispatcher = require("dispatcher")
local FileManager = require("apps/filemanager/filemanager")
local NetworkManager = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local ReadCollection = require("readcollection")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local GrimmoryDocMetadata = require("grimmory/doc_metadata")
local GrimmoryDialogManager = require("grimmory/ui/dialog_manager")
local GrimmoryExecutor = require("grimmory/executor")
local GrimmoryMenu = require("grimmory/ui/menu")
local GrimmorySettings = require("grimmory/settings")
local GrimmoryAPI = require("grimmory/grimmory_api")
local GrimmorySynchronize = require("grimmory/synchronize")
local GrimmoryScheduler = require("grimmory/scheduler")
local GrimmorySelfUpdater = require("grimmory/ota/self_updater")
local GithubAPI = require("grimmory/ota/github_api")
local GrimmoryLogger = require("grimmory/logger")
local GrimmoryReadingRecorder = require("grimmory/reading/recorder")
local GrimmoryLocalRepository = require("grimmory/repository")
local GrimmoryReadingAnnotations = require("grimmory/reading/annotations")
local GrimmoryReadingProgressManager = require("grimmory/reading/progress_manager")


local logger = GrimmoryLogger:new()

--- Short, user facing reason for a failed sync / progress check.
---@param result any The error returned by the executor or the sync
---@return string|nil reason
local function describeSyncError(result)
    if result == GrimmoryExecutor.ERROR_WIFI_FAILED then
        return _("WiFi didn't turn on")
    elseif result == GrimmoryExecutor.ERROR_NO_CONNECTION then
        return _("No network connection")
    elseif type(result) ~= "string" then
        return nil
    elseif result:find("Cannot connect to valid server", 1, true) then
        return _("Grimmory server not reachable")
    elseif result:find("Could not track book", 1, true) then
        return _("Book could not be read")
    end

    return nil
end

-- KOReader instantiates the plugin separately for the FileManager and for
-- every ReaderUI.  Track synchronization at module level so two instances
-- can never run a sync at the same time against the same database.
local sync_in_progress = false

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
    self.settings = GrimmorySettings:new()

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
end

function Grimmory:onSuspend()
    logger:dbg("Device is suspending")

    self.reading_recorder:onSessionEnd()

    if self.settings:getSyncOnSuspend() then
       -- KOReader turns WiFi off right after the Suspend event (WiFi left on
       -- can deadlock suspend on Kobo), so only sync over an existing connection.
       self:onGrimmorySync(false, nil, nil, { allow_enable_wifi = false })
    end
end

function Grimmory:onResume()
    logger:dbg("Device is resuming")

    if self.settings:getSyncReadingProgress() and self.settings:getSyncProgressOnResume() then
        self:pullProgressForOpenBook()
    end

    self.reading_recorder:onSessionStart()
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

    if (close_sync or smart) and self.ui and self.ui.document and self.ui.document.file then
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
                    self:onGrimmorySync(false)
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

function Grimmory:pullProgressForOpenBook()
    if self.ui == nil or self.ui.document == nil or self.ui.document.file == nil then
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
            -- that something is happening (without blocking reading).
            local close_notification = self.dialog_manager:notify(
                _("Grimmory: checking reading progress…")
            )

            local run_ok, ok, latest_progress = pcall(
                run,
                function()
                    local _, _, latest_progress = self.reading_progress_manager:getNewerProgressForBook(book_path)
                    return latest_progress
                end
            )

            pcall(close_notification)

            if not run_ok or not ok then
                local error_result = run_ok and latest_progress or ok
                logger:err("Could not check reading progress", error_result)

                local reason = describeSyncError(error_result)
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
                return self.is_synchronizing or sync_in_progress
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
                on_failed(describeSyncError(connect_error) or _("No network connection"))
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
                on_failed(describeSyncError(connect_error) or _("No network connection"))
            end
        )
    elseif self:isWifiConnected() then
        on_ready()
    else
        NetworkManager:runWhenOnline(on_ready)
    end
end

function Grimmory:isReadyToSync()
    if self.settings:getBaseUri() == "" then
        logger:info("BaseURI is not configured, cannot sync")
        return false
    end

    if self.is_synchronizing or sync_in_progress then
        logger:info("Synchronization is already happening, not ready to sync again")
        return false
    end

    return true
end

function Grimmory:isWifiConnected()
    local ok, result = pcall(function()
        return NetworkManager:isConnected()
    end)

    if not ok then
        logger:err("Something went wrong checking wifi connectivity", result)
        return true
    end

    return result
end

function Grimmory:onGrimmorySyncForegound()
    return self:onGrimmorySync(true)
end

function Grimmory:onGrimmorySyncBackground()
    return self:onGrimmorySync(false)
end

function Grimmory:onGrimmorySyncOpenBookForeground()
    return self:onGrimmorySyncOpenBook(true)
end

function Grimmory:onGrimmorySyncOpenBookBackground()
    return self:onGrimmorySyncOpenBook(false)
end

function Grimmory:onGrimmorySyncOpenBook(verbose)
    if self.ui == nil or self.ui.document == nil or self.ui.document.file == nil then
        logger:info("No open book, skipping sync")
        return
    end

    local book_path = self.ui.document.file

    return self:onGrimmorySync(verbose, book_path)
end

function Grimmory:refreshUI()
   if self.ui == nil then
        return
    end

    if self.ui.document == nil or self.ui.document.file == nil then
        logger:dbg("No file is open, cannot refresh")
        return
    end

    local settings = self.doc_metadata:getDocSettings(self.ui.document.file, true)

    if self.ui.annotation then
        -- Refresh annotations for any open document
        self.ui.annotation.annotations = settings:readSetting("annotations")
        pcall(self.ui.annotation.updateAnnotations, self.ui.annotation, true, true)
    end

    -- Reload document so any changes apply
    self.ui:reloadDocument()
end

---@param verbose boolean
---@param book_path string|nil Only synchronize this book
---@param refresh_book boolean|nil
---@param options table|nil { allow_enable_wifi, notify, progress_only, smart }
---  allow_enable_wifi: set to false to never turn on WiFi for this sync.
---  notify: show a non-blocking notification while a non-verbose sync runs.
---  progress_only: only push reading progress and sessions of `book_path`.
---  smart: with progress_only, also smart download the next volumes of its series.
function Grimmory:onGrimmorySync(verbose, book_path, refresh_book, options)
    options = options or {}
    local enable_wifi = options.allow_enable_wifi ~= false and self.settings:getSyncEnableWifi()

    -- Tell everything to flush so we have data available for our sync
    UIManager:broadcastEvent(Event:new("FlushSettings"))

    local function notifyFailure(reason)
        if verbose then
            if reason then
                self.dialog_manager:toast(T(_("Failed to Synchronize with Grimmory\n%1"), reason))
            else
                self.dialog_manager:toast(_("Failed to Synchronize with Grimmory"))
            end
        elseif options.notify then
            if reason then
                self.dialog_manager:notify(T(_("Grimmory sync failed: %1"), reason), 4)
            else
                self.dialog_manager:notify(_("Grimmory sync failed"), 4)
            end
        end
    end

    local function background_callback(run, terminate)
        if not self:isReadyToSync() then
            if options.notify and (self.is_synchronizing or sync_in_progress) then
                self.dialog_manager:notify(_("Grimmory: another sync is running, skipped"), 3)
            end
            return
        end

        -- Run in the foreground, as something with background tasks and
        -- network management causes Android devices to SIGABRT.
        --
        -- When "Enable WiFi" is active, the executor turns WiFi on (in the
        -- foreground) before starting the subprocess and checks connectivity
        -- itself, so this pre-check must not abort the sync early.
        if not enable_wifi and not self:isWifiConnected() then
            logger:err("Cannot sync without connectivity")
            notifyFailure(_("No network connection"))
            return
        end

        logger:info("Synchronizing to Grimmory")

        local terminated_early = false

        local queue_terminate = function()
            logger:dbg("Terminate requested")
            terminated_early = true
            terminate()
        end

        self.is_synchronizing = true
        sync_in_progress = true
        self.menu:onGrimmorySyncStart(queue_terminate)

        local update_callback, close_callback
        if verbose then
            update_callback, close_callback = self.dialog_manager:showProgressDialog(
                _("Synchronizing to Grimmory"),
                queue_terminate,
                _("Continue synchronization?")
            )
        elseif options.notify then
            close_callback = self.dialog_manager:notify(_("Grimmory: synchronizing…"))
        end

        local last_progress_step = 0
        local session_count = 0
        local session_error_count = 0
        local book_download_count = 0
        local book_refresh_count = 0
        local book_error_count = 0
        local progress_error_count = 0
        local smart_titles = {}

        local update_progress_step = function(progress_step)
            if progress_step <= last_progress_step then
                return
            end

            last_progress_step = progress_step

            if update_callback ~= nil then
                pcall(update_callback, progress_step, 10)
            end
        end

        -- In the future, we should limit what we sync
        -- to current or recent books.  For now, we sync everything.

        -- Protect the call so the "synchronizing" flags are always reset,
        -- otherwise a single unexpected error blocks every later sync.
        local run_ok, ok, result = pcall(
            run,
            function(progress_callback)
                if book_path and options.progress_only then
                    self.synchronizer:synchronizeBookProgress(book_path, progress_callback, options.smart)
                elseif book_path then
                    self.synchronizer:synchronizeBook(book_path, refresh_book, progress_callback)
                else
                    self.synchronizer:synchronizeAll(progress_callback)
                end
            end,
            function(progress)
                if type(progress) ~= "table" or type(progress.state) ~= "string" then
                    return
                end

                if progress.state == "book-push-metadata" then
                    local pushed_books = progress.pushed_books or 0
                    local total_books = progress.total_books or 0

                    if total_books == 0 then
                        pushed_books = 1
                        total_books = 1
                    end

                    -- Pushing sessions is 1, 2, and 3
                    update_progress_step(math.floor((pushed_books / total_books) * 3))
                end

                if progress.state:find("^shelf-") ~= nil then
                    -- If we are still seeing shelves we are at step 3
                    -- Because complete with shelves is step 4.
                    update_progress_step(3)
                end

                if (
                    progress.state == "book-downloaded" or
                    progress.state == "book-error" or
                    progress.state == "book-pull-metadata"
                ) then
                    local viewed_books = progress.viewed_books or 0
                    local total_books = progress.total_books or 0

                    if total_books == 0 then
                        viewed_books = 1
                        total_books = 1
                    end

                    -- Step 5, 6, 7, 8, 9 are all pulling books down
                    update_progress_step(4 + math.floor((viewed_books / total_books) * 5))
                end

                if progress.state == "progress-failed" then
                    progress_error_count = progress_error_count + 1
                end

                if progress.state == "smart-download" then
                    -- Keep it on the device (the subprocess cannot save that)
                    self.settings:setKeptBook(progress.book_id, true)
                    book_download_count = book_download_count + 1
                    table.insert(smart_titles, progress.title or "")
                end

                if progress.state == "session-recorded" then
                    session_count = session_count + 1
                elseif progress.state == "session-error" then
                    session_error_count = session_error_count + 1
                elseif progress.state == "book-downloaded" then
                    book_download_count = book_download_count + 1

                    if book_download_count % 20 == 0 then
                        -- If we're updating a lot of books we should
                        -- emit a refresh event every once in a while
                        -- so background refresh sees these come
                        -- through quickly
                        UIManager:broadcastEvent(Event:new("RefreshContent"))

                        -- Also refresh collections in this process
                        ReadCollection:_read()
                    end

                elseif progress.state == "book-error" then
                    book_error_count = book_error_count + 1
                elseif progress.state == "book-pull-metadata" then
                    book_refresh_count = book_refresh_count + 1
                end
            end
        )

        if not run_ok then
            result = ok
            ok = false
        end

        self.is_synchronizing = false
        sync_in_progress = false
        self.menu:onGrimmorySyncComplete()

        if close_callback then
            pcall(close_callback)
        end

        if not ok then
            if terminated_early then
                logger:info("Sync was interrupted by user")

                if verbose then
                    self.dialog_manager:toast(
                        _("Grimmory synchronization has been interrupted")
                    )
                end
            else
                logger:err("Failed sync", result)
                notifyFailure(describeSyncError(result))
            end

            return
        end

        if options.progress_only then
            -- Nothing on the device changed, so there is nothing to refresh.
            -- Reloading here would also reopen the document being closed.
            if progress_error_count > 0 then
                logger:err("Failed pushing reading progress for:", book_path)
                notifyFailure(_("Server did not accept reading progress"))
            elseif session_error_count > 0 then
                logger:err("Failed pushing reading sessions for:", book_path)
                notifyFailure(_("Server did not accept reading sessions"))
            end

            if #smart_titles > 0 then
                -- New volumes arrived: let the file manager show them
                UIManager:broadcastEvent(Event:new("RefreshContent"))
                ReadCollection.last_read_time = 0
                ReadCollection:_read()

                if #smart_titles == 1 then
                    self.dialog_manager:notify(T(_("Grimmory: downloaded next volume “%1”"), smart_titles[1]), 4)
                else
                    self.dialog_manager:notify(T(_("Grimmory: downloaded %1 next volumes"), #smart_titles), 4)
                end
            end

            return
        end

        -- If we have any books downloaded we need to emit a refresh
        -- event so the file manager knows it should refresh
        UIManager:broadcastEvent(Event:new("RefreshContent"))

        -- Also force refresh collections in this process
        ReadCollection.last_read_time = 0
        ReadCollection:_read()

        if book_path ~= nil then
            logger:info("Invalidating cache for book:", book_path)

            UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", book_path))

            if self.ui and self.ui.file_chooser then
                if type(self.ui.file_chooser.resetBookInfoCache) == "function" then
                    self.ui.file_chooser.resetBookInfoCache(book_path)
                end
                self.ui.file_chooser:init()
            end
        end

        -- Only reload the open document when this sync was for that document.
        -- Reloading after every full / periodic / on-suspend sync interrupts
        -- reading, and a full sync never rewrites the open book's settings.
        if (
            book_path ~= nil and
            self.ui ~= nil and
            self.ui.document ~= nil and
            self.ui.document.file == book_path
        ) then
            self:refreshUI()
        end

        if verbose then
            local message = {
                _("Completed Grimmory sync")
            }

            if session_count > 0 then
                table.insert(message, T(_("%1 session(s) recorded"), session_count))
            end

            if session_error_count > 0 then
                table.insert(message, T(_("%1 session(s) failed"), session_error_count))
            end

            if book_download_count > 0 then
                table.insert(message, T(_("%1 book(s) downloaded"), book_download_count))
            end

            if book_refresh_count > 0 then
                table.insert(message, T(_("%1 book(s) refreshed"), book_refresh_count))
            end

            if book_error_count > 0 then
                table.insert(message, T(_("%1 book(s) failed"), book_error_count))
            end

            self.dialog_manager:toast(table.concat(message, "\n"))
        end
    end

    self.executor:background(
        background_callback,
        enable_wifi
    )
end

return Grimmory
--[[
Grimmory plugin: running a sync (the progress popup or the corner icon, what
it reports afterwards) and its menu and gesture actions.  Methods of the
plugin (main.lua).
--]]

local _ = require("gettext")

local N_ = _.ngettext

local util = require("util")
local T = require("ffi/util").template
local NetworkManager = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local ReadCollection = require("readcollection")

local ProgressSheet = require("grimmory/ui/progress_sheet")
local Sheet = require("grimmory/ui/sheet")
local SyncProgress = require("grimmory/ui/sync_progress")
local GrimmoryDocMetadata = require("grimmory/doc_metadata")
local GrimmoryLogger = require("grimmory/logger")
local Shared = require("grimmory/plugin/shared")

local logger = GrimmoryLogger:new()

---@class GrimmoryMethods
local Grimmory = {}

function Grimmory:isReadyToSync()
    if self.settings:getBaseUri() == "" then
        logger:info("BaseURI is not configured, cannot sync")
        return false
    end

    if self.is_synchronizing or Shared.sync_in_progress then
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
--- Summary of a one book sync / reload from Grimmory
---@param result table From the "book-sync-result" progress event
function Grimmory:describeBookSync(book_path, refresh_book, result, counts)
    local title = self.doc_metadata:getTitle(book_path)
    if not title or title == "" then
        title = select(2, util.splitFilePathName(book_path))
    end

    local lines = {
        refresh_book and T(_("Reloaded “%1” from Grimmory"), title) or T(_("Synced “%1” with Grimmory"), title),
    }

    local function add(text)
        table.insert(lines, "• " .. text)
    end

    if not result.linked then
        add(_("Not found in Grimmory: only kept locally"))
        return table.concat(lines, "\n")
    end

    if result.newly_linked then
        add(_("Linked to the book in Grimmory"))
    end

    local field_names = {
        title = _("title"),
        authors = _("authors"),
        series = _("series"),
        series_index = _("series number"),
        language = _("language"),
        keywords = _("tags"),
        description = _("description"),
    }
    if result.info_changed and #result.info_changed > 0 then
        local fields = {}
        for _, key in ipairs(result.info_changed) do
            table.insert(fields, field_names[key] or key)
        end
        add(T(_("Book information updated: %1"), table.concat(fields, ", ")))
    end
    if result.info_failed then
        add(_("Book information could not be loaded"))
    end

    if refresh_book then
        if result.file_replaced then
            add(_("File replaced with the version from Grimmory"))
        else
            add(_("File is already the same as in Grimmory"))
        end
    end

    if counts.progress_pushed then
        add(_("Reading position sent"))
    end
    if counts.progress_error_count > 0 then
        add(_("Reading position not accepted by the server"))
    end
    if result.progress_pulled then
        add(T(_("Reading position from Grimmory: %1 %"), math.floor(result.progress_pulled + 0.5)))
    end

    if counts.session_count > 0 then
        add(T(N_("1 reading session sent", "%1 reading sessions sent", counts.session_count), counts.session_count))
    end
    if counts.session_error_count > 0 then
        add(_("Reading sessions not accepted by the server"))
    end

    local pushed = result.annotations_pushed or {}
    local pulled = result.annotations_pulled or {}
    local annotation_parts = {}
    if (pushed.sent or 0) > 0 then
        table.insert(annotation_parts, T(_("%1 sent"), pushed.sent))
    end
    if (pushed.deleted or 0) > 0 then
        table.insert(annotation_parts, T(_("%1 deleted in Grimmory"), pushed.deleted))
    end
    if (pulled.added or 0) > 0 then
        table.insert(annotation_parts, T(_("%1 received"), pulled.added))
    end
    if (pulled.updated or 0) > 0 then
        table.insert(annotation_parts, T(_("%1 updated"), pulled.updated))
    end
    if (pulled.removed or 0) > 0 then
        table.insert(annotation_parts, T(_("%1 removed"), pulled.removed))
    end
    if #annotation_parts > 0 then
        add(T(_("Highlights and notes: %1"), table.concat(annotation_parts, ", ")))
    end
    if result.annotations_failed then
        add(_("Highlights and notes could not be fully synced"))
    end

    if #lines == 1 then
        add(_("Everything was already up to date"))
    end

    return table.concat(lines, "\n")
end

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

    -- What earlier syncs could not send goes along with this one (a copy:
    -- the sync runs in a subprocess, the settings change meanwhile)
    local pending = {}
    for path, kinds in pairs(self.settings:getPendingSyncBooks()) do
        pending[path] = { progress = kinds.progress, annotations = kinds.annotations }
    end
    -- Its highlights wait until it is closed (the reader keeps its own copy)
    local open_book_path = self.ui and self.ui.document and self.ui.document.file or nil
    if options.progress_only and open_book_path == book_path then
        -- Being closed
        open_book_path = nil
    end

    --- What this sync should have sent is retried later: this book's
    --- progress, or (a sync of all books) the pending progress of all
    local function markPending()
        if book_path then
            self.settings:markPendingSync(book_path, "progress")
        else
            self.settings:setPendingSyncPush(true)
        end
    end

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
            -- (Another sync of all books sends the same, nothing to retry)
            if (self.is_synchronizing or Shared.sync_in_progress) and book_path then
                markPending()
                if options.notify then
                    self.dialog_manager:notify(_("Grimmory: another sync is running, sent later"), 3)
                end
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
            markPending()
            if not options.pending_only then
                notifyFailure(_("No network connection"))
            end
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
        Shared.sync_in_progress = true
        self.menu:onGrimmorySyncStart(queue_terminate)

        local progress_sheet, sync_progress, close_callback, sync_indicator
        if verbose then
            -- What the sync is doing, step by step ("Downloading books, 3 of 6")
            sync_progress = SyncProgress:new()
            progress_sheet = ProgressSheet.show({
                title = _("Synchronizing with Grimmory"),
                icon = "update",
                on_stop = function()
                    Sheet.confirm({
                        title = _("Stop synchronizing?"),
                        icon = "update",
                        ok_text = _("Stop"),
                        cancel_text = _("Continue"),
                        ok_callback = queue_terminate,
                    })
                end,
            })
            progress_sheet:update({ step = _("Connecting to Grimmory"), detail = "", fraction = 0 })
            close_callback = function()
                progress_sheet:close()
            end
        elseif options.notify or options.indicator then
            -- Book closed, retry: a small corner icon, not to distract
            sync_indicator = self.dialog_manager:showSyncIndicator("upload")
        end

        local session_count = 0
        local session_error_count = 0
        local session_error_reason = nil
        local book_download_count = 0
        local book_refresh_count = 0
        local book_error_count = 0
        local progress_error_count = 0
        local smart_titles = {}
        local progress_pushed = false
        local book_result = nil
        local info_updated_paths = {}

        -- In the future, we should limit what we sync
        -- to current or recent books.  For now, we sync everything.

        -- Protect the call so the "synchronizing" flags are always reset,
        -- otherwise a single unexpected error blocks every later sync.
        local run_ok, ok, result = pcall(
            run,
            function(progress_callback)
                if options.pending_only then
                    self.synchronizer:pushPending(pending, open_book_path, progress_callback)
                elseif book_path and options.progress_only then
                    self.synchronizer:synchronizeBookProgress(book_path, progress_callback, options.smart, pending)
                elseif book_path then
                    self.synchronizer:synchronizeBook(book_path, refresh_book, progress_callback)
                else
                    self.synchronizer:synchronizeAll(progress_callback, pending, open_book_path)
                end
            end,
            function(progress)
                if type(progress) ~= "table" or type(progress.state) ~= "string" then
                    return
                end

                if type(progress.book_path) == "string" then
                    -- Status and progress may have changed (e.g. finished
                    -- in Grimmory): the file browser reads them again
                    GrimmoryDocMetadata.forgetCachedInfo(progress.book_path)
                end

                if progress_sheet then
                    local state = sync_progress:handle(progress)
                    if state then
                        progress_sheet:update(state)
                    end
                end

                if progress.state == "smart-check" and sync_indicator then
                    -- Pushed; now fetching the next volumes
                    sync_indicator:setDirection("download")
                end

                if progress.state == "pending-synced" and progress.book_path then
                    -- Accepted by Grimmory: forget it (the subprocess cannot save settings)
                    self.settings:clearPendingSync(progress.book_path, progress.kind)
                end

                if progress.state == "progress-failed" then
                    progress_error_count = progress_error_count + 1
                elseif progress.state == "progress-pushed" then
                    progress_pushed = true
                elseif progress.state == "book-sync-result" and type(progress.result) == "table" then
                    book_result = progress.result
                elseif progress.state == "book-info-updated" and progress.book_path then
                    table.insert(info_updated_paths, progress.book_path)
                end

                if progress.state == "kept-book-removed" then
                    -- Deleted from the device: no longer kept (the subprocess cannot save that)
                    self.settings:setKeptBook(progress.book_id, false)
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
                    session_error_reason = session_error_reason or progress.message
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
        Shared.sync_in_progress = false
        self.menu:onGrimmorySyncComplete()

        if close_callback then
            pcall(close_callback)
        end

        if sync_indicator then
            sync_indicator:done(ok and progress_error_count == 0 and session_error_count == 0)
        end

        if not ok then
            markPending()

            if options.pending_only and self:isWifiConnected() then
                -- Connected, but the server is not reachable: try again later
                self:scheduleRetry(Shared.RETRY_AGAIN_SECONDS)
            end

            if terminated_early then
                logger:info("Sync was interrupted by user")

                if verbose then
                    self.dialog_manager:toast(
                        _("Grimmory synchronization has been interrupted")
                    )
                end
            else
                logger:err("Failed sync", result)
                notifyFailure(Shared.describeSyncError(result))
            end

            return
        end

        if book_path then
            -- This book: sent, or kept for the next sync
            if progress_error_count > 0 or session_error_count > 0 then
                markPending()
            else
                self.settings:clearPendingSync(book_path, "progress")
            end
            if book_result and (not book_result.linked
                or (book_result.annotations_pushed and not book_result.annotations_failed)) then
                -- Its highlights were pushed (or it is not a Grimmory book)
                self.settings:clearPendingSync(book_path, "annotations")
            end
        else
            -- All books' progress was sent (failed books are marked by now)
            self.settings:setPendingSyncPush(false)
        end

        if options.pending_only then
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

        -- Book information changed: drop KOReader's cached title, authors, ...
        for _, path in ipairs(info_updated_paths) do
            if path ~= book_path then
                UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", path))
            end
        end
        if #info_updated_paths > 0 then
            UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
            if self.ui and self.ui.file_chooser and #info_updated_paths > 0 then
                self.ui.file_chooser:refreshPath()
            end
        end

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

        if verbose and book_path and book_result then
            -- One book (file context menu): say what happened to it
            self.dialog_manager:toast(self:describeBookSync(book_path, refresh_book, book_result, {
                progress_pushed = progress_pushed,
                session_count = session_count,
                session_error_count = session_error_count,
                progress_error_count = progress_error_count,
            }), 6)
        elseif verbose then
            local message = {
                _("Completed Grimmory sync")
            }

            if session_count > 0 then
                table.insert(message, T(_("%1 session(s) recorded"), session_count))
            end

            if session_error_count > 0 then
                if session_error_reason and session_error_reason ~= "" then
                    table.insert(message, T(_("%1 session(s) failed: %2"), session_error_count, session_error_reason))
                else
                    table.insert(message, T(_("%1 session(s) failed"), session_error_count))
                end
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

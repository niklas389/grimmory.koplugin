--[[
Sync: sending reading progress, reading sessions and highlights to Grimmory
(and highlights back), and what earlier syncs could not send.  Methods of
GrimmorySynchronize (grimmory/synchronize.lua).
--]]

local GrimmoryLogger = require("grimmory/logger")
local SyncEvents = require("grimmory/sync/events")

local logger = GrimmoryLogger:new()
local stage = SyncEvents.stage

---@class GrimmorySynchronizeMethods
local GrimmorySynchronize = {}

---@param book_id integer
---@param callback function
function GrimmorySynchronize:pushBookProgress(book_id, callback)
    if not self.settings:getSyncReadingProgress() then
        logger:info("Reading progress skipped because feature is disabled for:", book_id)
        return
    end

    local progress_ok, progress = self.repository:getReadingProgress(book_id)

    if not progress_ok or progress == nil then
        logger:dbg("No local reading progress for book:", book_id)
        return
    end

    local sync_status_ok, last_synced_at = self.repository:getBookSyncTimestamp(book_id, "progress")

    if not sync_status_ok then
        logger:err("Unable to get sync status for book, not blindly syncing:", book_id)
        return
    end

    if last_synced_at ~= nil and last_synced_at >= progress.end_time then
        logger:dbg("Book progress already synced, skipping:", book_id, "-", last_synced_at)
        return
    end

    logger:info("Synchronizing reading progress for:", book_id, ";", last_synced_at, "->", progress.end_time)
    local ok = self.reading_progress_manager:pushRemoteProgress(progress)

    if ok then
        callback({
            state = "progress-pushed",
            book_path = progress.book_path,
            book_md5 = progress.book_md5,
        })

        self.repository:updateBookSyncTimestamp(book_id, "progress", progress.end_time)
    else
        callback({
            state = "progress-failed",
            book_path = progress.book_path,
            book_md5 = progress.book_md5,
        })
    end
end

---@param book_id integer
---@param callback function
function GrimmorySynchronize:pushBookSessions(book_id, callback)
    if not self.settings:getSyncReadingSessions() then
        -- Since the reading session sync is disabled, skip them.
        logger:dbg("Reading sessions skipped because feature is disabled for:", book_id)
        return
    end

    local threshold_pages = self.settings:getSessionThresholdPages()
    local threshold_seconds = self.settings:getSessionThresholdSeconds()

    logger:info("Synchronizing reading sessions for:", book_id)

    local sessions = self.repository:getPendingSessions(book_id)

    for _, session in ipairs(sessions) do
        local total_seconds = session.end_time - session.start_time
        local total_pages = session.end_page - session.start_page + 1

        if total_seconds < threshold_seconds then
            logger:info("Skipped session below time threshold for book", book_id)
            callback({
                state = "session-skip",
                bookPath = session.book_path,
                since = session.end_time,
            })

        elseif total_pages < threshold_pages then
            logger:info("Skipped session below page threshold for book", book_id)
            callback({
                state = "session-skip",
                bookPath = session.book_path,
                since = session.end_time,
            })

        elseif session.grimmory_id == nil then
            logger:err("Session failed recording with error for book: ", book_id, " - ", "No Grimmory ID")
            callback({
                state = "session-error",
                bookPath = session.book_path,
            })

            -- If an error happens for this session we bail early so
            -- retries can happen again later
            break
        else
            logger:dbg(
                "Recording session",
                session.grimmory_id,
                session.book_path,
                session.start_time,
                session.end_time,
                session.start_progress,
                session.end_progress,
                session.start_page,
                session.end_page
            )

            local ok, body = self.api:recordSession(
                session.grimmory_id,
                session.start_time,
                session.end_time,
                session.start_progress,
                session.end_progress,
                tostring(session.start_page),
                tostring(session.end_page),
                self.api.bookTypeOf(session.book_path)
            )

            if ok then
                logger:info("Session recorded successfully for book:", book_id)
                callback({
                    state = "session-recorded",
                    bookPath = session.book_path,
                    since = session.end_time,
                })

                self.repository:updateBookSyncTimestamp(book_id, "sessions", session.end_time)
            else
                logger:err("Session failed recording with error for book: ", book_id, session.book_path, " - ", body)
                callback({
                    state = "session-error",
                    bookPath = session.book_path,
                    since = session.end_time,
                    -- Why, as the server says (shown after the sync)
                    message = type(body) == "string" and body or nil,
                })

                -- If an error happens for this session we bail early so
                -- retries can happen again later
                break
            end
        end
    end
end

---@param book_path string
---@param book_grimmory_id integer
---@return { sent: integer, deleted: integer, failed: integer } counts
function GrimmorySynchronize:pushBookAnnotations(book_path, book_grimmory_id)
    local counts = { sent = 0, deleted = 0, failed = 0 }
    local local_annotations = self.reading_annotations:getAnnotations(book_path)

    local modified_grimmory_annotations = self.doc_metadata:getModifiedGrimmoryAnnotations(book_path)

    local is_modified_by_id = {}
    for _, modified_id in ipairs(modified_grimmory_annotations) do
        is_modified_by_id[tostring(modified_id)] = true

        logger:dbg("Deleting annotation frim Grimmory:", book_path, "-", modified_id)
        self.api:deleteAnnotation(modified_id)

        -- Even if the delete fails - which it does today with a 5xx instead of 404 - we
        -- should continue to remove the annotation and assume it's just gone.
        --
        -- Once this bug (grimmory-tools/grimmory#1858) is fixed we can add the check
        -- back in for the `ok` of `deleteAnnotation` calls.
        self.doc_metadata:removeModifiedGrimmoryAnnotation(book_path, modified_id)
        counts.deleted = counts.deleted + 1
    end

    ---@type { [integer]: integer }
    local created_ids_by_local_index = {}
    local created_any = false

    for _, annotation in ipairs(local_annotations) do
        if annotation.id ~= nil and is_modified_by_id[tostring(annotation.id)] then
            annotation.id = nil
        end

        if annotation.id == nil and annotation.cfi == nil then
            logger:warn("Skipping annotation without CFI:", book_path)
        elseif annotation.id == nil then
            -- This is a "new" annotation.
            local create_ok, remote_annotation = self.api:createAnnotation(
                book_grimmory_id,
                annotation.cfi,
                annotation.chapter,
                annotation.text,
                annotation.color,
                annotation.style,
                annotation.note
            )

            if create_ok then
                logger:dbg("Created annotation for book:", book_path)
                counts.sent = counts.sent + 1

                local remote_id = type(remote_annotation) == "table" and tonumber(remote_annotation.id) or nil
                if remote_id and annotation.local_index then
                    created_ids_by_local_index[annotation.local_index] = remote_id
                    created_any = true
                end
            else
                logger:err("Failed to push annotation", remote_annotation)
                counts.failed = counts.failed + 1
            end
        end
    end

    if created_any then
        -- Link the local annotations to what was just created, so they are
        -- matched by ID (not only by position) and never pushed twice.
        local doc_annotations = self.doc_metadata:getAnnotations(book_path)

        for local_index, remote_id in pairs(created_ids_by_local_index) do
            if doc_annotations[local_index] ~= nil then
                doc_annotations[local_index].grimmory_id = remote_id
            end
        end

        self.doc_metadata:setAnnotations(book_path, doc_annotations)
    end

    return counts
end

---@param book_path string
---@param book_grimmory_id integer
---@return { added: integer, updated: integer, removed: integer } | nil counts
function GrimmorySynchronize:pullBookAnnotations(book_path, book_grimmory_id)
    local annotations_ok, annotations = self.api:getAnnotations(book_grimmory_id)

    if not annotations_ok or annotations == nil then
        logger:err("Failed pulling annotations from Grimmory:", book_grimmory_id)
        return
    end

    logger:dbg("Writing annotations to:", book_path)

    return self.reading_annotations:applyAnnotations(
        book_path,
        annotations
    )
end

---@param book_id integer
---@param callback function
function GrimmorySynchronize:pushBookMetadata(book_id, callback)
    self:pushBookProgress(book_id, callback)
    self:pushBookSessions(book_id, callback)
end

function GrimmorySynchronize:pushAllPendingBookMetadata(callback)
    local book_ids = self.repository:getBooksPendingSync(
        self.settings:getSyncReadingSessions(),
        self.settings:getSyncReadingProgress()
    )

    for index, book_id in ipairs(book_ids) do
        if book_id == nil then
            break
        end

        stage(callback, "push", index, #book_ids)
        pcall(self.pushBookMetadata, self, book_id, callback)

        callback({
            state = "book-push-metadata",
            book_id = book_id,
            pushed_books = index,
            total_books = #book_ids,
        })

    end
end

---@return number | nil percent The position taken over from Grimmory, if any
---@param server_progress GrimmoryServerProgress | nil From the book list, if known
function GrimmorySynchronize:pullBookProgress(book_path, server_progress)
    if not self.settings:getSyncReadingProgress() then
        return nil
    end

    local ui = self.reading_progress_manager.ui
    if ui and ui.document and ui.document.file == book_path then
        -- This runs in the sync subprocess, where navigating the open
        -- document has no effect.  The open book is handled in the
        -- foreground by the "Go to latest location" confirmation.
        logger:dbg("Skipping progress pull for open book:", book_path)
        return nil
    end

    -- Only adopt remote progress when it is newer than what was recorded
    -- locally, otherwise local reading that has not been pushed yet (e.g.
    -- a failed push) would be overwritten by older remote progress.
    local _, _, progress = self.reading_progress_manager:getNewerProgressForBook(
        book_path, server_progress and server_progress.koreader_percent)

    if progress then
        self.reading_progress_manager:applyProgress(progress)
        return tonumber(progress.end_progress) or 0
    end

    return nil
end

--- Push the highlights of one book (new, changed and deleted ones).
---@return boolean done Nothing is left to push (also: not a Grimmory book)
function GrimmorySynchronize:pushPendingAnnotations(book_path)
    local _, _, grimmory_id = self.repository:upsertBook(book_path)
    if grimmory_id == nil then
        grimmory_id = self:associateBook(book_path)
    end
    if grimmory_id == nil then
        logger:info("Not a Grimmory book, no highlights to push:", book_path)
        return true
    end

    local counts = self:pushBookAnnotations(book_path, grimmory_id)
    return counts.failed == 0
end

--- Push what earlier syncs could not send: per book its reading progress
--- and sessions and / or its highlights.  Each book that is done is
--- reported ("pending-synced"), so the main process can forget it.
---@param pending table | nil settings:getPendingSyncBooks()
---@param open_book_path string | nil Its highlights wait until it is closed
---  (the reader would overwrite the IDs written for them)
function GrimmorySynchronize:pushPendingBooks(pending, open_book_path, callback)
    local lfs = require("libs/libkoreader-lfs")

    local paths = {}
    for book_path in pairs(pending or {}) do
        table.insert(paths, book_path)
    end
    table.sort(paths)

    for index, book_path in ipairs(paths) do
        local kinds = pending[book_path]
        stage(callback, "highlights", index, #paths)

        local function done(kind)
            callback({ state = "pending-synced", book_path = book_path, kind = kind })
        end

        if lfs.attributes(book_path, "mode") ~= "file" then
            -- Deleted meanwhile: nothing left to send
            logger:info("Pending book is gone:", book_path)
            if kinds.progress then
                done("progress")
            end
            if kinds.annotations then
                done("annotations")
            end
        else
            if kinds.progress then
                local failed = false
                local ok, push_error = pcall(self.pushBookProgressAndSessions, self, book_path, function(state)
                    local name = type(state) == "table" and state.state
                    if name == "progress-failed" or name == "session-error" then
                        failed = true
                    end
                    callback(state)
                end)
                if ok and not failed then
                    done("progress")
                else
                    logger:err("Pending progress not sent:", book_path, push_error)
                end
            end

            if kinds.annotations and book_path ~= open_book_path then
                if not self.settings:getSyncAnnotations() then
                    done("annotations")
                else
                    local ok, result = pcall(self.pushPendingAnnotations, self, book_path)
                    if ok and result then
                        done("annotations")
                    else
                        logger:err("Pending highlights not sent:", book_path, result)
                    end
                end
            end
        end
    end
end

function GrimmorySynchronize:pushBookProgressAndSessions(book_path, callback)
    if not self:checkForHealthyServer() then
        error("Cannot connect to valid server")
    end

    local book_ok, book_id, grimmory_id = self.repository:upsertBook(book_path)

    if not book_ok or not book_id then
        error("Could not track book")
    end

    logger:info("Pushing reading progress:", book_path)
    self:pushBookProgress(book_id, callback)

    if not self.settings:getSyncReadingSessions() then
        return
    end

    if grimmory_id == nil then
        -- Sessions are recorded against the Grimmory book, so link it once
        -- (the association is stored, later closes skip this search).
        logger:info("Searching Grimmory for book:", book_path)
        grimmory_id = self:associateBook(book_path)
    end

    if grimmory_id == nil then
        -- Not a Grimmory book: nothing to record the sessions against.
        logger:info("Book not found in Grimmory, not pushing sessions:", book_path)
        return
    end

    self:pushBookSessions(book_id, callback)

    logger:info("Done pushing reading progress:", book_path)
end

return GrimmorySynchronize

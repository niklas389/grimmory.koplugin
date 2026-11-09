local GrimmoryLogger = require("grimmory/logger")

-- Page turns are written this long after the first unwritten one, together
-- (not while the page changes: a database write per page turn costs time on
-- e-readers).  A crash loses at most these seconds of page turns.
local PAGE_WRITE_DELAY = 2

local logger = GrimmoryLogger:new()

---@class ReadingRecorder
---@field repository GrimmoryLocalRepository
---@field ui any
---@field last_page integer | nil
---@field session_book_path string | nil
---@field session_id integer | nil
local ReadingRecorder = {}

function ReadingRecorder:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function ReadingRecorder:init()
    self.pending_events = {}
end

--- Write the page turns not written yet (before anything reads the events:
--- a sync, the end of a session, suspend).
function ReadingRecorder:flush()
    if self.flush_task then
        require("ui/uimanager"):unschedule(self.flush_task)
        self.flush_task = nil
    end
    if #self.pending_events == 0 then
        return
    end
    local events = self.pending_events
    self.pending_events = {}
    self.repository:insertBookEvents(events)
end

---@return number page
function ReadingRecorder:getOpenBookCurrentPage()
    if not self.ui then
        -- Not in a document or something else has gone wrong.
        return 0
    end

    return self.ui:getCurrentPage()
end

---@return number page_count
function ReadingRecorder:getOpenBookTotalPages()
    if not self.ui or not self.ui.document then
        return 0
    end

    return self.ui.document:getPageCount()
end

function ReadingRecorder:getOpenBookReadPercent()
    if not self.ui or not self.ui.document then
        return 0
    end

    if self.ui.document.info.has_pages then
        return self.ui.paging:getLastPercent()
    else
        return self.ui.rolling:getLastPercent()
    end
end

---@return string | nil xpointer
function ReadingRecorder:getOpenBookXPointer()
    if not self.ui or not self.ui.document or self.ui.document.info.has_pages then
        return nil
    end

    return self.ui.rolling:getLastProgress()
end

---@return string | nil book_path current book path
function ReadingRecorder:getOpenBookPath()
    if not self.ui or not self.ui.document then
        return nil
    end

    return self.ui.document.file
end

---@param session_id number
---@param event_type ReadingSessionEventType
function ReadingRecorder:emitSessionEvent(session_id, event_type)
    if session_id == nil then
        -- `book_event.session_id` is NOT NULL; without a session the insert
        -- would only fail with a constraint error.
        logger:dbg("No active session, skipping event:", event_type)
        return
    end

    table.insert(self.pending_events, {
        session_id = session_id,
        created_at = os.time(),
        event_type = event_type,
        current_page = self:getOpenBookCurrentPage(),
        page_count = self:getOpenBookTotalPages(),
        xpointer = self:getOpenBookXPointer(),
    })

    if event_type ~= "page" then
        -- Session starts and ends, highlights: at once (with the page turns
        -- before them, in their order)
        self:flush()
    elseif not self.flush_task then
        self.flush_task = function()
            self.flush_task = nil
            self:flush()
        end
        require("ui/uimanager"):scheduleIn(PAGE_WRITE_DELAY, self.flush_task)
    end
end

function ReadingRecorder:onSessionStart()
    local book_path = self:getOpenBookPath()

    if self.session_id ~= nil then
        if book_path ~= self.session_book_path then
            -- If the session is active and the book path has changed we
            -- somehow missed the end session event
            self:onSessionEnd()
        else
            return
        end
    end

    if self.session_id ~= nil then
        -- If an existing session exists, do nothing
        return
    end

    if not book_path then
        logger:dbg("No book currently open for session, skipping")
        return
    end

    local book_ok, book_id = self.repository:upsertBook(book_path)
    if not book_ok or not book_id then
        logger:err("Failed to create session for book:", book_path)
        return
    end

    local new_session_ok, new_session_id = self.repository:insertSession(book_id)
    if not new_session_ok or not new_session_id then
        logger:err("Failed to create session for book:", book_path)
        return
    end

    self.session_id = new_session_id
    self.session_book_path = book_path

    self:emitSessionEvent(self.session_id, "session-start")
end

function ReadingRecorder:onAnnotationAdded()
    -- A session may not be active yet (e.g. right after adopting progress)
    self:onSessionStart()
    self:emitSessionEvent(self.session_id, "annotation-added")
end

function ReadingRecorder:onAnnotationRemoved()
    self:onSessionStart()
    self:emitSessionEvent(self.session_id, "annotation-removed")
end

function ReadingRecorder:onAnnotationUpdated()
    self:onSessionStart()
    self:emitSessionEvent(self.session_id, "annotation-updated")
end

function ReadingRecorder:onPageUpdate()
    -- If the session is active and the book path has changed we
    -- somehow missed the end session event
    local book_path = self:getOpenBookPath()
    if self.session_id and book_path ~= self.session_book_path then
        self:onSessionEnd()
    end

    local current_page = self:getOpenBookCurrentPage()
    if current_page == self.last_page then
        -- In some cases we get duplicate page update events
        -- This filters them out.
        return
    end

    -- Kick the session start in case it needs to be started
    self:onSessionStart()

    self.last_page = current_page


    self:emitSessionEvent(self.session_id, "page")
end

function ReadingRecorder:onSessionEnd()
    if self.session_id ~= nil then
        self:emitSessionEvent(self.session_id, "session-end")
    end
    self:flush()

    self.last_page = nil
    self.session_id = nil
    self.session_book_path = nil
end

return ReadingRecorder
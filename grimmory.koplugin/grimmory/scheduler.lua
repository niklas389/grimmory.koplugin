local UIManager = require("ui/uimanager")
local Random = require("random")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

---@class GrimmoryScheduler
local GrimmoryScheduler = {}

function GrimmoryScheduler:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    -- Per-instance state.  These must not live on the class table, otherwise
    -- every plugin instance (FileManager, each ReaderUI) shares them and one
    -- instance's `clear()` cancels another instance's tasks.
    o.intervals = o.intervals or {}
    o.cancellables = o.cancellables or {}

    return o
end

function GrimmoryScheduler:clear()
    self.intervals = {}

    -- Copy first, `cancel()` mutates `self.cancellables`
    local cancels = {}
    for _, cancel in pairs(self.cancellables) do
        table.insert(cancels, cancel)
    end

    for _, cancel in ipairs(cancels) do
        cancel()
    end

    self.cancellables = {}
end


---@param timeout number seconds to wait before firing the callback
---@param callback function the function to call
---@param ... any parameters to pass to the callback
function GrimmoryScheduler:schedule(timeout, callback, ...)
    local task_id = Random:uuid()

    local scheduled_task = function(...)
        -- Once fired, the task can no longer be cancelled; drop the
        -- reference so `cancellables` does not grow with every run.
        self.cancellables[task_id] = nil
        callback(...)
    end

    logger:dbg("Scheduling task", task_id, "in", timeout, "seconds")
    UIManager:scheduleIn(timeout, scheduled_task, ...)

    local cancel = function()
        self.cancellables[task_id] = nil

        UIManager:unschedule(scheduled_task)
    end

    self.cancellables[task_id] = cancel

    return cancel
end

---@param frequency number seconds in between firing the callback
---@param callback function the function to call
---@param ... any parameters to pass to the callback
function GrimmoryScheduler:interval(frequency, callback, ...)
    -- `table.pack` / `table.unpack` only exist with Lua 5.2 compat enabled
    local extra_parameters = { n = select("#", ...), ... }
    local unpack_fn = table.unpack or unpack

    local interval_id = Random:uuid()

    self.intervals[interval_id] = {
        frequency = frequency,
        last_schedule = os.time(),
        task = nil,
        cancel = nil,
    }

    local interval_task = function()
        local interval = self.intervals[interval_id]

        if interval == nil then
            logger:dbg("Ignoring Interval", interval_id, "because it has already been cancelled")
            return
        end

        -- Use the `interval.frequency` value so we change with the updates
        logger:dbg("Scheduling interval", interval_id, "in", interval.frequency, "seconds")
        local recurring_cancel = self:schedule(interval.frequency, interval.task)

        interval.last_schedule = os.time()
        interval.cancel = recurring_cancel

        callback(unpack_fn(extra_parameters, 1, extra_parameters.n))
    end

    logger:dbg("Scheduling interval", interval_id, "in", frequency, "seconds")
    self.intervals[interval_id].task = interval_task
    self.intervals[interval_id].cancel = self:schedule(frequency, interval_task)

    local cancel = function()
        local interval = self.intervals[interval_id]
        if interval and interval.cancel then
            logger:info("Cancelling interval", interval_id)
            interval.cancel()
        end

        self.intervals[interval_id] = nil
    end

    local update = function(new_frequency)
        local interval = self.intervals[interval_id]
        if not interval or not interval.cancel or not interval.last_schedule then
            logger:warn("Tried to update a schedule that has already been cancelled")
            return
        end

        if interval.frequency == new_frequency then
            -- Do nothing, there's no change
            return
        end

        interval.frequency = new_frequency

        -- Figure out how many seconds are left
        local elapsed_seconds = os.time() - interval.last_schedule
        local remaining_seconds = math.max(0, interval.frequency - elapsed_seconds)

        logger:dbg("Rescheduling", interval_id, "in", remaining_seconds, "seconds")

        interval.cancel()

        interval.cancel = self:schedule(
            remaining_seconds,
            interval_task
        )
    end

    return cancel, update
end

return GrimmoryScheduler
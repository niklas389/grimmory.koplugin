local ffiutil = require("ffi/util")
local ffi = require("ffi")
local json = require("json")
local Device = require("device")
local Event = require("ui/event")
local NetworkManager = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

local function readFromFD(fd)
    local ffi_buffer = ffi.new('char[?]', 1, {0})
    local data = {}

    if ffiutil.getNonBlockingReadSize(fd) == 0 then
        return ""
    end

    while true do
        local bytes_read = tonumber(ffi.C.read(fd, ffi.cast('void*', ffi_buffer), 1))
        if bytes_read < 0 then
            local err = ffi.errno()
            logger:err("readFromFD()", ffi.string(ffi.C.strerror(err)))
            break
        elseif bytes_read == 0 then -- EOF, no more data to read
            break
        else
            local bytes_str = ffi.string(ffi_buffer, bytes_read)

            if bytes_str == "\0" then
                break
            end

            table.insert(data, bytes_str)
        end
    end

    return table.concat(data)
end

local function writeToFD(fd, data)
    local size = #data
    local ptr = ffi.cast("uint8_t *", data)

    ffi.C.write(fd, ptr, size)
    ffi.C.fdatasync(fd)
end

local function writeObjectToFD(fd, obj)
    -- Encode with JSON so we can delineate "entries" with null bytes.
    local ok, str = pcall(json.encode, obj)

    if not ok then
        logger:err("Could not serialize progress state from subprocess:", str)
        return false, str
    end

    local write_ok, write_result = pcall(writeToFD, fd, str .. "\0")

    if not write_ok then
        logger:err("Could not write progress state back from subprocess:", write_result)
        return false, write_result
    end

    return true, nil
end

-- Why connecting failed, returned as the result of a failed run.
local ERROR_WIFI_FAILED = "wifi-failed"
local ERROR_NO_CONNECTION = "no-connection"

---@class GrimmoryExecutor
---@field private running_subprocesses any[]
---@field settings GrimmorySettings|nil
local GrimmoryExecutor = {
    ERROR_WIFI_FAILED = ERROR_WIFI_FAILED,
    ERROR_NO_CONNECTION = ERROR_NO_CONNECTION,
}

function GrimmoryExecutor:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function GrimmoryExecutor:init()
    self.running_subprocesses = self.running_subprocesses or {}
end

function GrimmoryExecutor:clear()
    while true do
        local subprocess_pid = table.remove(self.running_subprocesses)

        if not subprocess_pid then
            break
        end

        ffiutil.terminateSubProcess(subprocess_pid)
    end
end

local function wrap_coroutine(func)
    -- Catch and log any error happening in func (an error happening
    -- in a coroutine just aborts silently the coroutine)
    local pcalled_func = function()
        -- we use xpcall as it can give a whole stacktrace, unlike pcall
        local ok, err = xpcall(func, debug.traceback)

        if not ok then
            logger:warn("error in wrapped function:", err)
            return false
        end
        return true
        -- As a coroutine, we will return at first coroutine.yield(),
        -- and the above true/false won't probably be caught by
        -- any code, but let's do it anyway.
    end
    local co = coroutine.create(pcalled_func)
    return coroutine.resume(co)
end

-- Waiting for a connection, in seconds.  KOReader's own background WiFi
-- restore can take over 45 seconds, so allow a bit more.
local WIFI_CONNECT_TIMEOUT = 60
-- How long a background (non-blocking) connection may take before falling
-- back to KOReader's regular, blocking connection.
local WIFI_BACKGROUND_CONNECT_TIMEOUT = 30

-- WiFi state shared by every executor (the FileManager and each ReaderUI get
-- their own plugin instance), so a sync that finishes never turns off WiFi
-- that another sync (e.g. the progress check of the next book) still uses.
local wifi_users = 0
local wifi_enabled_by_us = false

-- PocketBook's system network tool.  Unlike inkview's NetConnect (used by
-- KOReader), it can run in the background.  Not documented by PocketBook and
-- reported to behave differently between models, hence opt-in.
local POCKETBOOK_NETAGENT = "/ebrmain/bin/netagent"

local function file_exists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

local function start_pocketbook_background_connect()
    -- The subshell with `&` returns at once; netagent connects meanwhile.
    os.execute(
        "(" .. POCKETBOOK_NETAGENT .. " net on; " .. POCKETBOOK_NETAGENT .. " connect)" ..
        " >/dev/null 2>&1 &"
    )
end

---@param use_pocketbook_netagent boolean
---@return function|nil start Starts connecting without blocking the UI
local function get_background_connect(use_pocketbook_netagent)
    if NetworkManager.turn_on_wifi_async then
        -- A KOReader patch already turns WiFi on in the background
        -- (2-pocketbook-background-wifi.lua): use the regular way
        return nil
    end

    if Device:hasWifiRestore() then
        -- Same as KOReader restoring WiFi after resume (Kobo, Kindle, ...)
        return function() NetworkManager:restoreWifiAsync() end
    end

    if use_pocketbook_netagent and Device:isPocketBook() and file_exists(POCKETBOOK_NETAGENT) then
        return start_pocketbook_background_connect
    end

    return nil
end

local function is_wifi_connected()
    return NetworkManager:isWifiOn() and NetworkManager:isConnected()
end

local function is_wifi_connecting()
    -- Internal NetworkManager flags, set while KOReader (or another plugin)
    -- is connecting, e.g. while restoring WiFi after resume.
    return NetworkManager.pending_connection or NetworkManager.pending_connectivity_check
end

--- Yield the running coroutine until `is_done()` returns true or `timeout`
--- seconds passed, without blocking the UI.
---@return boolean done
local function wait_until(is_done, timeout)
    if is_done() then
        return true
    end

    local running_coroutine = coroutine.running()
    local result = nil
    local iteration = 0

    local function check()
        if is_done() then
            result = true
        elseif iteration >= timeout * 4 then
            result = false
        else
            iteration = iteration + 1
            UIManager:scheduleIn(0.25, check)
            return
        end

        coroutine.resume(running_coroutine)
    end

    UIManager:scheduleIn(0.25, check)

    -- Give control back to UIManager
    coroutine.yield()

    return result == true
end

local function connection_failure()
    -- WiFi is on, but there is no connection (e.g. network out of range).
    -- On PocketBook "on" already means associated, so this is a missing route.
    if NetworkManager:isWifiOn() then
        return false, ERROR_NO_CONNECTION
    end

    return false, ERROR_WIFI_FAILED
end

--- Connect to WiFi, turning it on if needed.  Must run inside a coroutine.
---@param use_pocketbook_netagent boolean
---@return boolean connected
---@return string|nil error ERROR_WIFI_FAILED or ERROR_NO_CONNECTION
local function connect_wifi(use_pocketbook_netagent)
    if is_wifi_connected() then
        logger:dbg("WiFi is already Active")
        return true
    end

    if not Device:hasWifiToggle() then
        logger:err("Requested with wifi but cannot enable")
        if NetworkManager:isConnected() then
            return true
        end
        return false, ERROR_NO_CONNECTION
    end

    if is_wifi_connecting() then
        logger:dbg("WiFi connection attempt already ongoing, waiting for it")

        if wait_until(is_wifi_connected, WIFI_CONNECT_TIMEOUT) then
            return true
        end

        if is_wifi_connecting() then
            logger:err("Ongoing WiFi connection attempt did not finish")
            return connection_failure()
        end
    end

    -- Only turn WiFi off afterwards if it was off before.
    if not NetworkManager:isWifiOn() then
        wifi_enabled_by_us = true
    end

    local background_connect = get_background_connect(use_pocketbook_netagent)

    if background_connect then
        -- Connect in the background.  `enableWifi` scans for networks (Kobo)
        -- or calls NetConnect (PocketBook) on the UI thread, which freezes the
        -- reader for several seconds when a book is opened or closed.
        logger:dbg("Connecting to WiFi in the background")

        NetworkManager.pending_connection = true
        UIManager:broadcastEvent(Event:new("NetworkConnecting"))

        local restore_ok, restore_error = pcall(background_connect)
        if not restore_ok then
            logger:err("Background WiFi connection failed to start:", restore_error)
        end

        local connected = restore_ok and wait_until(is_wifi_connected, WIFI_BACKGROUND_CONNECT_TIMEOUT)
        NetworkManager.pending_connection = false

        if connected then
            logger:dbg("Connection succesful")
            UIManager:broadcastEvent(Event:new("NetworkConnected"))
            return true
        end

        -- e.g. the network is only known to KOReader, not to the system, or
        -- netagent does not work on this PocketBook model.
        logger:warn("Background WiFi connection failed, trying a regular connection")
    end

    -- PocketBook's NetConnect is synchronous: when it returns without a link,
    -- the attempt failed (it sometimes does, e.g. right after wake-up), so
    -- it is worth a second try.  Elsewhere the result is only known later.
    -- (Unless a patch made it asynchronous, see turn_on_wifi_async below.)
    local pocketbook_sync_connect = Device:isPocketBook() and not NetworkManager.turn_on_wifi_async
    local attempts = pocketbook_sync_connect and 2 or 1

    for attempt = 1, attempts do
        -- Turning WiFi on below blocks the UI (scanning, PocketBook's
        -- NetConnect), so paint the opened book / file manager and our
        -- notification first instead of freezing on the previous screen.
        UIManager:forceRePaint()

        -- `enableWifi` (not `requestToTurnOnWifi`) so KOReader's connectivity
        -- check runs: only it clears `pending_connection` again and broadcasts
        -- NetworkConnected.  Non-interactive, so no network list is shown.
        local result = NetworkManager:enableWifi(nil, false)

        if result == false then
            -- `enableWifi` has already torn the attempt down.
            logger:err("Failed to turn on wifi, attempt", attempt)
        elseif pocketbook_sync_connect and not NetworkManager:isWifiOn() then
            logger:err("PocketBook NetConnect failed, attempt", attempt)
            -- Stop KOReader's pending connectivity check, otherwise the next
            -- attempt is rejected as busy for the next 45 seconds.
            pcall(NetworkManager._abortWifiConnection, NetworkManager)
        else
            -- Stop waiting early once KOReader gave up on the connection.
            local function is_done()
                return is_wifi_connected() or not is_wifi_connecting()
            end

            wait_until(is_done, WIFI_CONNECT_TIMEOUT)

            if is_wifi_connected() then
                logger:dbg("Connection succesful")
                return true
            end

            logger:err("No connection after turning on wifi, attempt", attempt)
        end

        if attempt < attempts then
            -- Give the system a moment before trying again.
            wait_until(function() return false end, 2)
        end
    end

    return connection_failure()
end

-- PocketBook's firmware drops WiFi after ~100 s without traffic.  KOReader
-- pings to prevent that, but only for connections it made with NetConnect,
-- not for the background (netagent) connection; and while the library
-- browser is open there may be no traffic for minutes.  So ping while the
-- plugin uses WiFi, like KOReader does.
local KEEPALIVE_INTERVAL_SECONDS = 30
local keepalive_scheduled = false

local function pocketbook_ping()
    local ok, err = pcall(function()
        local inkview = require("ffi/inkview")
        if ffi.C.POCKETBOOK_VERSION >= 508 then
            inkview.NetMgrPing()
        end
    end)

    if not ok then
        logger:warn("WiFi keep-alive ping failed:", err)
    end
end

local function keep_wifi_alive()
    if wifi_users == 0 or not NetworkManager:isWifiOn() then
        keepalive_scheduled = false
        return
    end

    pocketbook_ping()
    UIManager:scheduleIn(KEEPALIVE_INTERVAL_SECONDS, keep_wifi_alive)
end

local function start_keepalive()
    if Device:isPocketBook() and not keepalive_scheduled then
        keepalive_scheduled = true
        UIManager:scheduleIn(KEEPALIVE_INTERVAL_SECONDS, keep_wifi_alive)
    end
end

local function release_wifi()
    wifi_users = math.max(0, wifi_users - 1)

    if wifi_users == 0 and wifi_enabled_by_us then
        wifi_enabled_by_us = false

        logger:dbg("Disabling WiFi after execution")
        -- `disableWifi` cancels any pending connectivity check and
        -- broadcasts NetworkDisconnected.  Flagged interactive so
        -- `wifi_was_on` is reset and KOReader does not restore the
        -- WiFi we only turned on for this sync after resume / restart.
        NetworkManager:disableWifi(nil, true)
    end
end

--- Connect to the network (turning WiFi on) and keep the connection until
--- the returned `release` is called, e.g. while the library browser is open.
--- WiFi turned on here is turned off again once nothing uses it any more.
---@param on_ready function(release: function)
---@param on_failed function(error: string)
function GrimmoryExecutor:holdWifi(on_ready, on_failed)
    return wrap_coroutine(function()
        wifi_users = wifi_users + 1

        local released = false
        local function release()
            if not released then
                released = true
                release_wifi()
            end
        end

        local use_pocketbook_netagent = self.settings ~= nil and
            self.settings:getSyncPocketBookBackgroundWifi()

        local connected, connect_error = connect_wifi(use_pocketbook_netagent)

        if not connected then
            release()
            on_failed(connect_error)
            return
        end

        start_keepalive()
        on_ready(release)
    end)
end

--- Connect again after the connection was lost (e.g. while the library
--- browser was open), without registering another WiFi user.
---@param on_ready function()
---@param on_failed function(error: string)
function GrimmoryExecutor:reconnectWifi(on_ready, on_failed)
    return wrap_coroutine(function()
        local use_pocketbook_netagent = self.settings ~= nil and
            self.settings:getSyncPocketBookBackgroundWifi()

        local connected, connect_error = connect_wifi(use_pocketbook_netagent)

        if connected then
            start_keepalive()
            on_ready()
        else
            on_failed(connect_error)
        end
    end)
end

---@alias GrimmoryRunnableProgressCallback function(state: any, terminate: function): bool
---@alias GrimmoryRunnable function(callback: BackgroundRunnableProgressCallback)
---@alias GrimmoryBackgroundStart function(runnable: GrimmoryRunnable, progress: GrimmoryRunnableProgressCallback)

---@param callback function(run_in_background: GrimmoryBackgroundStart)
---@param with_wifi bool
---@return boolean ok
---@return any result
function GrimmoryExecutor:background(callback, with_wifi)
    return wrap_coroutine(function()
        local subprocess_pid = nil
        local was_terminated = false

        local terminate = function()
            if subprocess_pid ~= nil then
                ffiutil.terminateSubProcess(subprocess_pid)
            end

            was_terminated = true
        end

        local function run_in_background(runnable, on_progress)
            UIManager:preventStandby()

            -- We want the executor to attempt to connect to wifi before it runs
            -- anything, and if it turns this on we should disable it afterwards, too.
            local uses_wifi = false

            local function finish()
                UIManager:allowStandby()

                if uses_wifi then
                    uses_wifi = false
                    release_wifi()
                end
            end

            if with_wifi then
                logger:dbg("Execution requested WiFi")

                -- Register before connecting, so a sync finishing meanwhile
                -- does not turn WiFi off underneath this one.
                wifi_users = wifi_users + 1
                uses_wifi = true

                local use_pocketbook_netagent = self.settings ~= nil and
                    self.settings:getSyncPocketBookBackgroundWifi()

                local connected, connect_error = connect_wifi(use_pocketbook_netagent)

                if not connected then
                    logger:err("No connectivity after trying to enable WiFi:", connect_error)
                    finish()
                    return false, connect_error
                end
            end

            if was_terminated then
                finish()
                return false, "Terminated before starting subprocess"
            end

            local running_coroutine = coroutine.running()

            local new_subprocess_pid, parent_read_fd = ffiutil.runInSubProcess(
                function(my_pid, child_write_fd)
                    ---@type GrimmoryRunnableProgressCallback
                    local function progress_callback(state)
                        local write_ok, write_result = writeObjectToFD(child_write_fd, state)

                        if not write_ok then
                            logger:err("Could not write progress state back from subprocess:", write_result)
                        end

                        return true
                    end

                    local runnable_ok, runnable_result = pcall(runnable, progress_callback)

                    local runnable_state = {
                        __runnable_ok = runnable_ok,
                        __runnable_result = runnable_result,
                    }

                    local write_ok, write_result = writeObjectToFD(child_write_fd, runnable_state)

                    if not write_ok then
                        logger:err("Could not write final state back from subprocess:", write_result)
                    end

                    -- Close the handle manually.
                    pcall(ffi.C.close, child_write_fd)

                    -- Kill the subprocess because nothing else seems to stop
                    -- it when we are using the `runInSubProcess` helper.
                    ffi.C.kill(my_pid, 9)
                end,
                true
            )

            subprocess_pid = new_subprocess_pid

            if was_terminated then
                if subprocess_pid then
                    ffiutil.terminateSubProcess(subprocess_pid)
                end
                if parent_read_fd then
                    pcall(ffi.C.close, parent_read_fd)
                end
                finish()
                return false, "Terminated before starting subprocess"
            end

            local subprocess_ok = false
            local subprocess_result = nil

            if subprocess_pid then
                table.insert(self.running_subprocesses, subprocess_pid)

                while true do
                    local messages_received = 0
                    local state_data = readFromFD(parent_read_fd)
                    while state_data ~= "" do
                        local decode_ok, state = pcall(json.decode, state_data)
                        if decode_ok then
                            if state and state.__runnable_ok ~= nil then
                                subprocess_ok = state.__runnable_ok
                                subprocess_result = state.__runnable_result
                            else
                                pcall(on_progress, state)
                            end
                        else
                            logger:err("Failed to decode state data received from subprocess:", state)
                        end

                        messages_received = messages_received + 1

                        if messages_received > 100 then
                            -- If we keep receiving messages we should hand
                            -- back to the UI thread for a bit.
                            break
                        end

                        state_data = readFromFD(parent_read_fd)
                    end

                    -- Even if the subprocess is done, if we haven't exhausted
                    -- all of the messages we have to keep running.
                    local is_subprocess_done = ffiutil.isSubProcessDone(subprocess_pid)
                    if is_subprocess_done and messages_received == 0 then
                        break
                    end

                    pcall(on_progress, nil)

                    local continue_func = function() coroutine.resume(running_coroutine) end
                    UIManager:scheduleIn(0.1, continue_func)

                    -- gives control back to UIManager
                    coroutine.yield()
                end

                -- Search for and remove the running subprocess PID
                for i, running_subprocess_id in ipairs(self.running_subprocesses) do
                    if running_subprocess_id == subprocess_pid then
                        table.remove(self.running_subprocesses, i)
                        break
                    end
                end
            else
                logger:err("Failed to start subprocess")
                subprocess_result = "Failed to start subprocess"
            end

            -- The parent end of the pipe is never closed by `runInSubProcess`,
            -- so close it here or every sync leaks a file descriptor.
            if parent_read_fd then
                pcall(ffi.C.close, parent_read_fd)
            end

            finish()

            return subprocess_ok, subprocess_result
        end

        callback(run_in_background, terminate)
    end)
end


return GrimmoryExecutor
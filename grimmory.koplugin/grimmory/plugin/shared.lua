--[[
What the plugin's instances share (KOReader starts one for the FileManager
and one for every ReaderUI), and what main.lua and its parts
(grimmory/plugin/*.lua) all use.
--]]

local _ = require("gettext")

local GrimmoryExecutor = require("grimmory/executor")

local Shared = {
    -- Whether a sync runs: tracked here so two instances can never run a
    -- sync at the same time against the same database
    sync_in_progress = false,
}

-- Retrying what earlier syncs could not send: once WiFi is connected again,
-- after waking up and when KOReader starts.  WiFi is never turned on for it.
Shared.RETRY_DELAY_SECONDS = 10
-- While connected but the server is not reachable
Shared.RETRY_AGAIN_SECONDS = 15 * 60

--- Short, user facing reason for a failed sync / progress check.
---@param result any The error returned by the executor or the sync
---@return string|nil reason
function Shared.describeSyncError(result)
    if result == GrimmoryExecutor.ERROR_WIFI_FAILED then
        return _("WiFi didn't turn on")
    elseif result == GrimmoryExecutor.ERROR_NO_CONNECTION then
        return _("No network connection")
    elseif result == GrimmoryExecutor.ERROR_WIFI_PAUSED then
        return _("WiFi is not turned on by itself after it failed to connect")
    elseif type(result) ~= "string" then
        return nil
    elseif result:find("Cannot connect to valid server", 1, true) then
        return _("Grimmory server not reachable")
    elseif result:find("Could not track book", 1, true) then
        return _("Book could not be read")
    end

    return nil
end

--- Whether a failure is not worth a message: an automatic action that did
--- not try, as WiFi failed to connect before (that was said once already)
function Shared.isQuietFailure(result)
    return result == GrimmoryExecutor.ERROR_WIFI_PAUSED
end

--- Said once, when an automatic action could not turn WiFi on: it pauses
Shared.WIFI_PAUSED_NOTE = _("Not turned on again by itself until WiFi works or you sync or browse by hand.")

return Shared

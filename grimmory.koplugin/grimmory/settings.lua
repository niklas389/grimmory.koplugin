local _ = require("gettext")

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local random = require("random")
local Device = require("device")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

-- Contains all of the stored settings and settings UI
-- elements to control Grimmory connections & sync.

---@class GrimmoryTargetShelf
---@field id number
---@field name string

---@alias GrimmoryDownloadSourceKind "shelves" | "libraries" | "series" | "magic_shelves"

---@class GrimmoryDownloadSource
---@field id number | nil Shelf / library / magic shelf ID (nil for series)
---@field name string

---@class GrimmorySettingsData
---@field automatic_check_updates boolean
---@field base_uri string
---@field username string
---@field password string
---@field extra_headers { [string]: string }
---@field session_threshold_seconds number
---@field session_threshold_pages number
---@field sync_on_close_document boolean
---@field sync_on_suspend boolean
---@field sync_on_power_off boolean
---@field sync_enable_wifi boolean
---@field sync_pocketbook_background_wifi boolean
---@field sync_progress_on_open boolean
---@field sync_progress_on_resume boolean
---@field browser_layout "list" | "grid"
---@field smart_download_mode "off" | "in_progress" | "chosen"
---@field smart_download_series { [string]: boolean } Per series: true = chosen, false = excluded
---@field smart_ahead_books number Unread book volumes kept on the device ahead
---@field smart_ahead_comics number Unread comic / manga volumes kept on the device ahead
---@field sync_periodically boolean
---@field sync_frequency number
---@field sync_shelves boolean
---@field download_remove_books boolean
---@field sync_target_shelves GrimmoryTargetShelf[]
---@field sync_target_libraries GrimmoryDownloadSource[]
---@field sync_target_series GrimmoryDownloadSource[]
---@field sync_target_magic_shelves GrimmoryDownloadSource[]
---@field download_everything boolean | nil nil: derived from the sources (legacy)
---@field browser_kept_books { [string]: boolean } Grimmory IDs downloaded from the browser
---@field sync_download_directory string
---@field sync_reading_sessions boolean
---@field sync_reading_progress boolean
---@field sync_annotations boolean
---@field sync_shelves_as_collections boolean
---@field sync_retain_empty_shelves boolean
---@field device_id string
---@field device_name string

---@type GrimmorySettingsData
local DEFAULTS = {
    automatic_check_updates = false,
    extra_headers = {},
    base_uri = "",
    username = "",
    password = "",
    session_threshold_seconds = 30,
    session_threshold_pages = 0,
    sync_on_close_document = false,
    sync_on_suspend = false,
    sync_on_power_off = false,
    sync_enable_wifi = false,
    sync_pocketbook_background_wifi = false,
    sync_progress_on_open = true,
    sync_progress_on_resume = false,
    browser_layout = "list",
    smart_download_mode = "off",
    smart_download_series = {},
    smart_ahead_books = 1,
    smart_ahead_comics = 3,
    sync_periodically = false,
    sync_frequency = 120,
    sync_shelves = true,
    download_remove_books = false,
    sync_target_shelves = {},
    sync_target_libraries = {},
    sync_target_series = {},
    sync_target_magic_shelves = {},
    browser_kept_books = {},
    sync_download_directory = "grimmory/",
    sync_reading_sessions = true,
    sync_reading_progress = true,
    sync_annotations = true,
    sync_shelves_as_collections = true,
    sync_retain_empty_shelves = false,
    device_id = random.uuid(),
    device_name = Device.model,
}

---@class GrimmorySettings
---@field settings any Underlying lua settings interactions
---@field data GrimmorySettingsData In-memory setting values
local GrimmorySettings = {
    data = DEFAULTS,
}

local SETTING_KEY = "grimmory"

local function openSettingsHandle()
  local path = DataStorage:getSettingsDir() .. "/" .. SETTING_KEY .. ".lua"
  return LuaSettings:open(path)
end

function GrimmorySettings:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function GrimmorySettings:init()
    self.settings = openSettingsHandle()
    local success, result = pcall(function()
        return self.settings:readSetting(SETTING_KEY, {}) or {}
    end)

    if success and type(result) == "table" then
        self.data = result
    else
        logger:err("Error reading settings, using defaults", result)

        -- Copy so later setters do not mutate the shared DEFAULTS table
        self.data = {}
        for key, value in pairs(DEFAULTS) do
            self.data[key] = value
        end

        self:write()
    end

    -- DEFAULTS.device_id is regenerated every time KOReader starts.  Persist
    -- one so the server sees a stable device across restarts.
    if type(self.data.device_id) ~= "string" or self.data.device_id == "" then
        self.data.device_id = DEFAULTS.device_id
        self:write()
    end
end

function GrimmorySettings:write()
    local success, error_msg = pcall(function()
        if not self.settings then
            logger:err("No settings object available for write")
            return false
        end

        logger:dbg("Saving settings data", self.data)
        self.settings:saveSetting(SETTING_KEY, self.data)
        self.settings:flush()
        logger:dbg("Settings saved and flushed successfully")
        return true
    end)

    if not success then
        logger:err("Error writing settings:", error_msg)
        return false
    end

    return true
end

function GrimmorySettings:getDeviceId()
    return self.data.device_id or DEFAULTS.device_id
end

function GrimmorySettings:setDeviceId(device_id)
    self.data.device_id = device_id
    self:write()
end

function GrimmorySettings:getDeviceName()
    return self.data.device_name or DEFAULTS.device_name
end

function GrimmorySettings:setDeviceName(device_name)
    self.data.device_name = device_name
    self:write()
end

function GrimmorySettings:getBaseUri()
    return self.data.base_uri or DEFAULTS.base_uri
end

function GrimmorySettings:setBaseUri(uri)
    uri = tostring(uri or ""):gsub("/*$", "")
    self.data.base_uri = uri
    self:write()
end

function GrimmorySettings:getExtraHeaders()
    return self.data.extra_headers or DEFAULTS.extra_headers
end

function GrimmorySettings:setExtraHeaders(headers)
    self.data.extra_headers = headers
    self:write()
end

function GrimmorySettings:getUsername()
    return self.data.username or DEFAULTS.username
end

function GrimmorySettings:setUsername(username)
    self.data.username = username
    self:write()
end

function GrimmorySettings:getPassword()
    return self.data.password or DEFAULTS.password
end

function GrimmorySettings:setPassword(password)
    self.data.password = password
    self:write()
end

function GrimmorySettings:getSessionThresholdSeconds()
    return self.data.session_threshold_seconds or DEFAULTS.session_threshold_seconds
end

---@param seconds integer
function GrimmorySettings:setSessionThresholdSeconds(seconds)
    self.data.session_threshold_seconds = seconds
    self:write()
end

function GrimmorySettings:getSessionThresholdPages()
    return self.data.session_threshold_pages or DEFAULTS.session_threshold_pages
end

---@param pages integer
function GrimmorySettings:setSessionThresholdPages(pages)
    self.data.session_threshold_pages = pages
    self:write()
end

function GrimmorySettings:getDownloadsBooks()
    if self.data.sync_shelves == nil then
        return DEFAULTS.sync_shelves
    end

    return self.data.sync_shelves
end

function GrimmorySettings:toggleDownloadsBooks()
    self.data.sync_shelves = not self:getDownloadsBooks()
    self:write()
end

function GrimmorySettings:getDownloadRemoveBooks()
    if self.data.download_remove_books == nil then
        return DEFAULTS.download_remove_books
    end

    return self.data.download_remove_books
end

function GrimmorySettings:toggleDownloadRemoveBooks()
    self.data.download_remove_books = not self:getDownloadRemoveBooks()
    self:write()
end

function GrimmorySettings:getDownloadDirectory()
    local directory = self.data.sync_download_directory or DEFAULTS.sync_download_directory

    if type(directory) ~= "string" then
        return nil
    end

    -- Strip trailing slashes (but keep "/") so joined paths do not contain
    -- "//" and match the paths produced when scanning the directory.
    directory = directory:gsub("(.)/+$", "%1")

    return directory
end

---@param directory string
function GrimmorySettings:setDownloadDirectory(directory)
    self.data.sync_download_directory = directory
    self:write()
end

local DOWNLOAD_SOURCE_KEYS = {
    shelves = "sync_target_shelves",
    libraries = "sync_target_libraries",
    series = "sync_target_series",
    magic_shelves = "sync_target_magic_shelves",
}

---@param kind GrimmoryDownloadSourceKind
---@return GrimmoryDownloadSource[]
function GrimmorySettings:getDownloadSources(kind)
    local key = DOWNLOAD_SOURCE_KEYS[kind]
    local sources = key and self.data[key]

    if type(sources) ~= "table" then
        return {}
    end

    return sources
end

local function sourceMatches(kind, source, id_or_name)
    if kind == "series" then
        return source.name == id_or_name
    end

    return source.id == id_or_name
end

---@param kind GrimmoryDownloadSourceKind
---@param id_or_name number | string ID, or the name for series
function GrimmorySettings:isDownloadSource(kind, id_or_name)
    for _, source in ipairs(self:getDownloadSources(kind)) do
        if sourceMatches(kind, source, id_or_name) then
            return true
        end
    end

    return false
end

---@param kind GrimmoryDownloadSourceKind
---@param source GrimmoryDownloadSource
---@param enabled boolean
function GrimmorySettings:setDownloadSource(kind, source, enabled)
    local key = DOWNLOAD_SOURCE_KEYS[kind]
    local id_or_name = kind == "series" and source.name or source.id
    local sources = {}

    -- Fix the "everything" choice before the sources change, otherwise the
    -- legacy "no sources means everything" rule would flip it.
    self.data.download_everything = self:getDownloadEverything()

    for _, existing in ipairs(self:getDownloadSources(kind)) do
        if not sourceMatches(kind, existing, id_or_name) then
            table.insert(sources, existing)
        end
    end

    if enabled then
        table.insert(sources, { id = source.id, name = source.name })
    end

    self.data[key] = sources
    self:write()
end

---@return boolean
function GrimmorySettings:hasDownloadSources()
    for kind, _ in pairs(DOWNLOAD_SOURCE_KEYS) do
        if #self:getDownloadSources(kind) > 0 then
            return true
        end
    end

    return false
end

--- Download every book of the library, ignoring the sources.
function GrimmorySettings:getDownloadEverything()
    if self.data.download_everything == nil then
        -- Before sources existed, "no shelf selected" meant "all books".
        return not self:hasDownloadSources()
    end

    return self.data.download_everything == true
end

function GrimmorySettings:toggleDownloadEverything()
    self.data.download_everything = not self:getDownloadEverything()
    self:write()
end

--- Books downloaded from the library browser.  The sync keeps them on the
--- device (and syncs them) even when they are not in a download source.
---@param grimmory_id number
function GrimmorySettings:isKeptBook(grimmory_id)
    local kept = self.data.browser_kept_books
    return type(kept) == "table" and kept[tostring(grimmory_id)] == true
end

---@param grimmory_id number
---@param kept boolean
---@param in_memory_only boolean | nil Do not write the settings file (in the sync subprocess)
function GrimmorySettings:setKeptBook(grimmory_id, kept, in_memory_only)
    if type(self.data.browser_kept_books) ~= "table" then
        self.data.browser_kept_books = {}
    end

    self.data.browser_kept_books[tostring(grimmory_id)] = kept or nil
    if not in_memory_only then
        self:write()
    end
end

function GrimmorySettings:getSyncReadingProgress()
    if self.data.sync_reading_progress == nil then
        return DEFAULTS.sync_reading_progress
    end

    return self.data.sync_reading_progress
end

function GrimmorySettings:toggleSyncReadingProgress()
    self.data.sync_reading_progress = not self:getSyncReadingProgress()
    self:write()
end

function GrimmorySettings:getSyncReadingSessions()
    if self.data.sync_reading_sessions == nil then
        return DEFAULTS.sync_reading_sessions
    end

    return self.data.sync_reading_sessions
end

function GrimmorySettings:toggleSyncReadingSessions()
    self.data.sync_reading_sessions = not self:getSyncReadingSessions()
    self:write()
end

function GrimmorySettings:getSyncAnnotations()
    if self.data.sync_annotations == nil then
        return DEFAULTS.sync_annotations
    end

    return self.data.sync_annotations
end

function GrimmorySettings:toggleSyncAnnotations()
    self.data.sync_annotations = not self:getSyncAnnotations()
    self:write()
end

function GrimmorySettings:getSyncShelves()
    if self.data.sync_shelves_as_collections == nil then
        return DEFAULTS.sync_shelves_as_collections
    end

    return self.data.sync_shelves_as_collections
end

function GrimmorySettings:toggleSyncShelves()
    self.data.sync_shelves_as_collections = not self:getSyncShelves()
    self:write()
end

function GrimmorySettings:getSyncRetainEmptyShelves()
    if self.data.sync_retain_empty_shelves == nil then
        return DEFAULTS.sync_retain_empty_shelves
    end

    return self.data.sync_retain_empty_shelves
end

function GrimmorySettings:toggleSyncRetainEmptyShelves()
    self.data.sync_retain_empty_shelves = not self:getSyncRetainEmptyShelves()
    self:write()
end

function GrimmorySettings:getSyncPeriodically()
    if self.data.sync_periodically == nil then
        return DEFAULTS.sync_periodically
    end

    return self.data.sync_periodically
end

function GrimmorySettings:toggleSyncPeriodically()
    self.data.sync_periodically = not self:getSyncPeriodically()
    self:write()
end

function GrimmorySettings:getSyncFrequency()
    return self.data.sync_frequency or DEFAULTS.sync_frequency
end

function GrimmorySettings:setSyncFrequency(seconds)
    self.data.sync_frequency = seconds
    self:write()
end

function GrimmorySettings:getSyncOnCloseDocument()
    if self.data.sync_on_close_document == nil then
        return DEFAULTS.sync_on_close_document
    end

    return self.data.sync_on_close_document
end

function GrimmorySettings:toggleSyncOnCloseDocument()
    self.data.sync_on_close_document = not self:getSyncOnCloseDocument()
    self:write()
end

function GrimmorySettings:getSyncOnSuspend()
    if self.data.sync_on_suspend == nil then
        return DEFAULTS.sync_on_suspend
    end

    return self.data.sync_on_suspend
end

function GrimmorySettings:toggleSyncOnSuspend()
    self.data.sync_on_suspend = not self:getSyncOnSuspend()
    self:write()
end

function GrimmorySettings:getSyncOnPowerOff()
    if self.data.sync_on_power_off == nil then
        return DEFAULTS.sync_on_power_off
    end

    return self.data.sync_on_power_off
end

function GrimmorySettings:toggleSyncOnPowerOff()
    self.data.sync_on_power_off = not self:getSyncOnPowerOff()
    self:write()
end

function GrimmorySettings:getSyncEnableWifi()
    if self.data.sync_enable_wifi == nil then
        return DEFAULTS.sync_enable_wifi
    end

    return self.data.sync_enable_wifi
end

function GrimmorySettings:toggleSyncEnableWifi()
    self.data.sync_enable_wifi = not self:getSyncEnableWifi()
    self:write()
end

function GrimmorySettings:getSyncPocketBookBackgroundWifi()
    if self.data.sync_pocketbook_background_wifi == nil then
        return DEFAULTS.sync_pocketbook_background_wifi
    end

    return self.data.sync_pocketbook_background_wifi
end

function GrimmorySettings:toggleSyncPocketBookBackgroundWifi()
    self.data.sync_pocketbook_background_wifi = not self:getSyncPocketBookBackgroundWifi()
    self:write()
end

--- Smart download: keep the next volumes of series on the device
---@return "off" | "in_progress" | "chosen"
function GrimmorySettings:getSmartDownloadMode()
    local mode = self.data.smart_download_mode
    if mode == "in_progress" or mode == "chosen" then
        return mode
    end
    return "off"
end

---@param mode "off" | "in_progress" | "chosen"
function GrimmorySettings:setSmartDownloadMode(mode)
    self.data.smart_download_mode = mode
    self:write()
end

--- The explicit choice for a series: true (chosen), false (excluded) or nil
function GrimmorySettings:getSmartDownloadSeries(series_name)
    local series = self.data.smart_download_series
    if type(series) ~= "table" then
        return nil
    end
    return series[series_name]
end

---@param enabled boolean | nil
function GrimmorySettings:setSmartDownloadSeries(series_name, enabled)
    if type(self.data.smart_download_series) ~= "table" then
        self.data.smart_download_series = {}
    end
    self.data.smart_download_series[series_name] = enabled
    self:write()
end

--- Series chosen explicitly (downloaded even when not being read)
---@return string[]
function GrimmorySettings:getChosenSmartDownloadSeries()
    local names = {}
    for name, enabled in pairs(self.data.smart_download_series or {}) do
        if enabled == true then
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end

--- Whether smart download handles a series
---@param in_progress boolean A volume of it is being read
function GrimmorySettings:isSmartDownloadSeries(series_name, in_progress)
    local mode = self:getSmartDownloadMode()
    local choice = self:getSmartDownloadSeries(series_name)

    if mode == "in_progress" then
        return choice ~= false and (in_progress or choice == true)
    elseif mode == "chosen" then
        return choice == true
    end

    return false
end

function GrimmorySettings:getSmartAheadBooks()
    return tonumber(self.data.smart_ahead_books) or DEFAULTS.smart_ahead_books
end

function GrimmorySettings:setSmartAheadBooks(count)
    self.data.smart_ahead_books = math.max(0, math.floor(count))
    self:write()
end

function GrimmorySettings:getSmartAheadComics()
    return tonumber(self.data.smart_ahead_comics) or DEFAULTS.smart_ahead_comics
end

function GrimmorySettings:setSmartAheadComics(count)
    self.data.smart_ahead_comics = math.max(0, math.floor(count))
    self:write()
end

--- Layout of book lists in the library browser
---@return "list" | "grid"
function GrimmorySettings:getBrowserLayout()
    return self.data.browser_layout == "grid" and "grid" or "list"
end

---@param layout "list" | "grid"
function GrimmorySettings:setBrowserLayout(layout)
    self.data.browser_layout = layout
    self:write()
end

function GrimmorySettings:getSyncProgressOnOpen()
    if self.data.sync_progress_on_open == nil then
        return DEFAULTS.sync_progress_on_open
    end

    return self.data.sync_progress_on_open
end

function GrimmorySettings:toggleSyncProgressOnOpen()
    self.data.sync_progress_on_open = not self:getSyncProgressOnOpen()
    self:write()
end

function GrimmorySettings:getSyncProgressOnResume()
    if self.data.sync_progress_on_resume == nil then
        return DEFAULTS.sync_progress_on_resume
    end

    return self.data.sync_progress_on_resume
end

function GrimmorySettings:toggleSyncProgressOnResume()
    self.data.sync_progress_on_resume = not self:getSyncProgressOnResume()
    self:write()
end

return GrimmorySettings

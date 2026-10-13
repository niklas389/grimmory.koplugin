local _ = require("gettext")
local T = require("ffi/util").template

local Device = require("device")
local Event = require("ui/event")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")

local PluginMetadata = require("grimmory/plugin_metadata")
---@class GrimmoryMenu
---@field ui any This is a ReaderUI
---@field settings GrimmorySettings
---@field api GrimmoryAPI
---@field dialog_manager DialogManager
---@field updater GrimmorySelfUpdater
---@field interrupt_sync function
local GrimmoryMenu = {}

function GrimmoryMenu:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function GrimmoryMenu:onGrimmorySyncStart(interrupt_sync_callback)
    self.interrupt_sync = interrupt_sync_callback
end

function GrimmoryMenu:onGrimmorySyncComplete()
    self.interrupt_sync = nil
end

function GrimmoryMenu:getAboutMenu()
    -- These won't change after the plugin starts up
    local repository = PluginMetadata.getRepository()
    local version = PluginMetadata.getVersion()

    return {
        {
            text = repository,
            keep_menu_open = true,
        },
        {
            text = T(_("Version %1"), version),
            keep_menu_open = true,
            separator = true,
        },
        {
            text_func = function()
                if self.updater:isPendingRestart() then
                    return _("Update Pending Restart")
                end

                if self.updater:isUpdateAvailable() then
                    local latest_version = self.updater:getLatestReleaseVersion()
                    return T(_("Update to %1"), latest_version)
                end

                return _("Check for Updates")
            end,
            callback = function()
                if self.updater:isPendingRestart() then
                    UIManager:askForRestart(_("Grimmory plugin update will apply on next Restart."))
                else
                    self.dialog_manager:showPluginUpdateCheck()
                end
            end,
        },
    }
end

local function settingsChanged()
    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
end

--- A checkbox menu entry for a boolean setting.
function GrimmoryMenu:toggleItem(text, getter, toggler, extra)
    local item = {
        text = text,
        checked_func = function()
            return self.settings[getter](self.settings)
        end,
        callback = function()
            self.settings[toggler](self.settings)
            settingsChanged()
        end,
        keep_menu_open = true,
    }

    for key, value in pairs(extra or {}) do
        item[key] = value
    end

    return item
end

function GrimmoryMenu:isConfigured()
    return self.settings:getBaseUri() ~= ""
end

--- What is synchronized (independent of when and what is downloaded)
function GrimmoryMenu:getWhatToSyncMenu()
    return {
        self:toggleItem(_("Reading Progress"), "getSyncReadingProgress", "toggleSyncReadingProgress"),
        self:toggleItem(_("Reading Sessions"), "getSyncReadingSessions", "toggleSyncReadingSessions"),
        {
            text = _("Reading Session Thresholds"),
            enabled_func = function()
                return self.settings:getSyncReadingSessions()
            end,
            callback = function()
                self.dialog_manager:showSessionThresholdSettings()
            end,
        },
        self:toggleItem(_("Annotations"), "getSyncAnnotations", "toggleSyncAnnotations", { separator = true }),
        self:toggleItem(_("Shelves as Collections"), "getSyncShelves", "toggleSyncShelves"),
        self:toggleItem(_("Keep Empty Shelves"), "getSyncRetainEmptyShelves", "toggleSyncRetainEmptyShelves", {
            enabled_func = function()
                return self.settings:getSyncShelves()
            end,
        }),
    }
end

--- Checkbox entries for the shelves / libraries / magic shelves of the server
---@param kind GrimmoryDownloadSourceKind
function GrimmoryMenu:getSourceCollectionsMenu(kind, load)
    local ok, collections = load()

    if not ok or type(collections) ~= "table" then
        return {
            {
                text = T(_("Could not load from Grimmory: %1"), tostring(collections)),
                enabled = false,
            },
        }
    end

    local items = {}

    for _, collection in ipairs(collections) do
        table.insert(items, {
            text = collection.name,
            checked_func = function()
                return self.settings:isDownloadSource(kind, collection.id)
            end,
            callback = function()
                local enabled = self.settings:isDownloadSource(kind, collection.id)
                self.settings:setDownloadSource(kind, collection, not enabled)
                settingsChanged()
            end,
            keep_menu_open = true,
        })
    end

    if #items == 0 then
        table.insert(items, { text = _("None on the server"), enabled = false })
    end

    return items
end

---@param kind GrimmoryDownloadSourceKind
function GrimmoryMenu:getSourceSummary(kind)
    local names = {}
    for _, source in ipairs(self.settings:getDownloadSources(kind)) do
        table.insert(names, source.name)
    end

    if #names == 0 then
        return _("none")
    end

    return table.concat(names, ", ")
end

--- Where the automatic sync downloads books from
function GrimmoryMenu:getDownloadSourcesMenu()
    local function sources_enabled()
        return self:isConfigured() and not self.settings:getDownloadEverything()
    end

    local function collection_source(kind, title, load)
        return {
            text_func = function()
                return T(title, self:getSourceSummary(kind))
            end,
            enabled_func = sources_enabled,
            sub_item_table_func = function()
                return self:getSourceCollectionsMenu(kind, load)
            end,
        }
    end

    return {
        self:toggleItem(_("Everything"), "getDownloadEverything", "toggleDownloadEverything", {
            help_text = _("Download every book of the library. Turn off to choose shelves, libraries or series."),
            separator = true,
        }),
        collection_source("shelves", _("Shelves: %1"), function()
            return self.api:getAppShelves()
        end),
        collection_source("libraries", _("Libraries: %1"), function()
            return self.api:getAppLibraries()
        end),
        collection_source("magic_shelves", _("Magic Shelves: %1"), function()
            return self.api:getAppMagicShelves()
        end),
        {
            text_func = function()
                return T(_("Series: %1"), self:getSourceSummary("series"))
            end,
            enabled_func = sources_enabled,
            sub_item_table_func = function()
                local items = {}

                for _, source in ipairs(self.settings:getDownloadSources("series")) do
                    table.insert(items, {
                        text = source.name,
                        checked_func = function()
                            return self.settings:isDownloadSource("series", source.name)
                        end,
                        callback = function()
                            local enabled = self.settings:isDownloadSource("series", source.name)
                            self.settings:setDownloadSource("series", source, not enabled)
                            settingsChanged()
                        end,
                        keep_menu_open = true,
                    })
                end

                table.insert(items, {
                    text = _("Add series in the library browser"),
                    help_text = _("Open a series in Browse Library and turn on “Download with automatic sync”."),
                    callback = function()
                        UIManager:broadcastEvent(Event:new("GrimmoryBrowseLibrary"))
                    end,
                })

                return items
            end,
            separator = true,
        },
        {
            text = _("Books downloaded from the library browser are always kept and synced."),
            enabled = false,
        },
    }
end

--- Keep the next volumes of series on the device
function GrimmoryMenu:getSmartDownloadMenu()
    local function mode_item(mode, text, help)
        return {
            text = text,
            help_text = help,
            radio = true,
            checked_func = function()
                return self.settings:getSmartDownloadMode() == mode
            end,
            callback = function()
                self.settings:setSmartDownloadMode(mode)
                settingsChanged()
            end,
            keep_menu_open = true,
        }
    end

    local function enabled()
        return self.settings:getSmartDownloadMode() ~= "off"
    end

    local off_item = mode_item("off", _("Off"))
    local in_progress_item = mode_item("in_progress", _("Series Being Read"),
        _("Every series with a volume being read. Series can be excluded in the library browser."))
    local chosen_item = mode_item("chosen", _("Only Chosen Series"),
        _("Only series ticked for smart download in the library browser."))
    chosen_item.separator = true

    return {
        off_item,
        in_progress_item,
        chosen_item,
        {
            text_func = function()
                return T(_("Books Ahead: %1"), self.settings:getSmartAheadBooks())
            end,
            enabled_func = enabled,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.dialog_manager:showNumberSetting(
                    _("Books Ahead"),
                    _("Unread book volumes to keep on the device after the one being read"),
                    self.settings:getSmartAheadBooks(),
                    0,
                    function(count)
                        self.settings:setSmartAheadBooks(count)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end
                )
            end,
        },
        {
            text_func = function()
                return T(_("Comics / Manga Ahead: %1"), self.settings:getSmartAheadComics())
            end,
            help_text = _("Comic and manga volumes are CBZ, CBR and CB7 files."),
            enabled_func = enabled,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.dialog_manager:showNumberSetting(
                    _("Comics / Manga Ahead"),
                    _("Unread comic volumes to keep on the device after the one being read"),
                    self.settings:getSmartAheadComics(),
                    0,
                    function(count)
                        self.settings:setSmartAheadComics(count)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end
                )
            end,
        },
    }
end

function GrimmoryMenu:getDownloadsMenu()
    return {
        self:toggleItem(_("Download Books with Sync"), "getDownloadsBooks", "toggleDownloadsBooks", {
            help_text = _("The full sync downloads the books of the download sources."),
        }),
        {
            text = _("Download Sources"),
            enabled_func = function()
                return self.settings:getDownloadsBooks()
            end,
            sub_item_table_func = function()
                return self:getDownloadSourcesMenu()
            end,
        },
        {
            text_func = function()
                local mode = self.settings:getSmartDownloadMode()
                local state = mode == "in_progress" and _("series being read")
                    or mode == "chosen" and _("chosen series")
                    or _("off")
                return T(_("Smart Download for Series: %1"), state)
            end,
            help_text = _("Keep the volume being read and the next volumes of series on the device. " ..
                "Runs with every sync and after closing a book of a series. Downloaded volumes stay on the device."),
            sub_item_table_func = function()
                return self:getSmartDownloadMenu()
            end,
        },
        {
            text_func = function()
                return T(_("Download Folder: %1"), self.settings:getDownloadDirectory() or "")
            end,
            callback = function()
                self.dialog_manager:showDownloadDirectorySettings()
            end,
            separator = true,
        },
        self:toggleItem(_("Delete Books No Longer in Sources"), "getDownloadRemoveBooks", "toggleDownloadRemoveBooks", {
            help_text = _("Delete downloaded books that are no longer in a download source. " ..
                "When off, they only leave their Grimmory collections."),
        }),
    }
end

--- When the plugin syncs automatically
function GrimmoryMenu:getWhenToSyncMenu()
    local function progress_enabled()
        return self.settings:getSyncReadingProgress()
    end

    return {
        self:toggleItem(_("Check Progress When Opening a Book"), "getSyncProgressOnOpen", "toggleSyncProgressOnOpen", {
            enabled_func = progress_enabled,
        }),
        self:toggleItem(_("Check Progress on Wake"), "getSyncProgressOnResume", "toggleSyncProgressOnResume", {
            enabled_func = progress_enabled,
        }),
        self:toggleItem(_("Sync Book When Closing It"), "getSyncOnCloseDocument", "toggleSyncOnCloseDocument", {
            help_text = _("Send the closed book's reading progress and sessions."),
            separator = true,
        }),
        self:toggleItem(_("Sync on Suspend"), "getSyncOnSuspend", "toggleSyncOnSuspend", {
            help_text = _("Only uses an existing connection; WiFi is not turned on."),
        }),
        self:toggleItem(_("Sync on Power Off"), "getSyncOnPowerOff", "toggleSyncOnPowerOff", {
            help_text = _("Only uses an existing connection; WiFi is not turned on."),
            separator = true,
        }),
        self:toggleItem(_("Sync Everything Periodically"), "getSyncPeriodically", "toggleSyncPeriodically"),
        {
            text_func = function()
                return T(_("Every %1 minutes"), self.settings:getSyncFrequency())
            end,
            enabled_func = function()
                return self.settings:getSyncPeriodically()
            end,
            callback = function()
                self.dialog_manager:showSyncFrequencySettings()
            end,
        },
    }
end

function GrimmoryMenu:getLibraryBrowserMenu()
    return {
        {
            text = _("Show Books as Cover Grid"),
            checked_func = function()
                return self.settings:getBrowserLayout() == "grid"
            end,
            callback = function()
                self.settings:setBrowserLayout(self.settings:getBrowserLayout() == "grid" and "list" or "grid")
            end,
            keep_menu_open = true,
            separator = true,
        },
        {
            text = _("Clear Cache"),
            help_text = _("Remove the cached covers and server answers of the library browser. " ..
                "They are loaded again when needed."),
            keep_menu_open = true,
            callback = function()
                local Covers = require("grimmory/ui/library/covers")
                local LibraryData = require("grimmory/ui/library/data")

                LibraryData.clearCache()
                local files, bytes = Covers.clear()

                self.dialog_manager:notify(
                    T(_("Library cache cleared: %1 covers, %2 MB"), files, string.format("%.1f", bytes / 1024 / 1024)),
                    3
                )
            end,
        },
    }
end

function GrimmoryMenu:getNetworkMenu()
    local menu = {
        self:toggleItem(_("Turn On WiFi When Needed"), "getSyncEnableWifi", "toggleSyncEnableWifi", {
            enabled = Device:hasWifiToggle(),
            help_text = _("Turn WiFi on for syncs and the library browser, and off again afterwards."),
        }),
    }

    if Device:isPocketBook() then
        table.insert(menu, self:toggleItem(
            _("Connect WiFi in Background (experimental)"),
            "getSyncPocketBookBackgroundWifi",
            "toggleSyncPocketBookBackgroundWifi",
            {
                help_text = _(
                    "Turn on WiFi with PocketBook's system network tool instead of KOReader's " ..
                    "connection, so reading is not interrupted while connecting.\n\n" ..
                    "If the background connection does not work on this device, the regular " ..
                    "(blocking) connection is used after 30 seconds."
                ),
                enabled_func = function()
                    return self.settings:getSyncEnableWifi()
                end,
            }
        ))
    end

    return menu
end

function GrimmoryMenu:getTopMenu()
    local menu = {
        {
            text = _("Browse Library"),
            enabled_func = function()
                return self:isConfigured()
            end,
            callback = function()
                UIManager:broadcastEvent(Event:new("GrimmoryBrowseLibrary"))
            end,
        },
    }

    if self.ui ~= nil and self.ui.document ~= nil then
        table.insert(menu, {
            text = _("Sync This Book Now"),
            enabled_func = function()
                return self:isConfigured() and self.interrupt_sync == nil
            end,
            callback = function()
                UIManager:broadcastEvent(Event:new("GrimmorySyncOpenBook", true))
            end,
        })
    end

    if self.interrupt_sync == nil then
        table.insert(menu, {
            text = _("Sync Everything Now"),
            enabled_func = function()
                return self:isConfigured()
            end,
            callback = function()
                UIManager:broadcastEvent(Event:new("GrimmorySync", true))
            end,
            separator = true,
        })
    else
        table.insert(menu, {
            text = _("Interrupt Current Sync"),
            callback = function()
                if self.interrupt_sync ~= nil then
                    UIManager:show(ConfirmBox:new({
                        text = _("Are you sure you want to interrupt synchronization?"),
                        ok_callback = function()
                            pcall(self.interrupt_sync)
                        end,
                    }))
                end
            end,
            separator = true,
        })
    end

    local settings_entries = {
        { text = _("What to Sync"), sub_item_table_func = function() return self:getWhatToSyncMenu() end },
        { text = _("When to Sync"), sub_item_table_func = function() return self:getWhenToSyncMenu() end },
        { text = _("Downloads"), sub_item_table_func = function() return self:getDownloadsMenu() end },
        { text = _("Library Browser"), sub_item_table_func = function() return self:getLibraryBrowserMenu() end },
        {
            text = _("Network"),
            sub_item_table_func = function() return self:getNetworkMenu() end,
            separator = true,
        },
        {
            text = _("Server Connection"),
            callback = function()
                self.dialog_manager:showConnectionSettings()
            end,
        },
        { text = _("About Grimmory Sync"), sub_item_table = self:getAboutMenu() },
    }

    for _, entry in ipairs(settings_entries) do
        table.insert(menu, entry)
    end

    return menu
end

function GrimmoryMenu:addToMainMenu(menu_items)
    menu_items.grimmory = {
        text = "Grimmory",
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getTopMenu()
        end,
    }
end

return GrimmoryMenu
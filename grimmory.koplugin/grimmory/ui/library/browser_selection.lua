--[[
Library browser: selecting books and downloading them together.  Methods
of LibraryBrowser (grimmory/ui/library/browser.lua).
--]]

local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local ReadCollection = require("readcollection")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local N_ = _.ngettext

local T = require("ffi/util").template

local LibraryData = require("grimmory/ui/library/data")
local Sheet = require("grimmory/ui/sheet")
local Style = require("grimmory/ui/style")
local Widgets = require("grimmory/ui/library/widgets")
local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

---@class LibraryBrowserMethods
local LibraryBrowser = {}

--- Books that can be selected: with a file, and not on the device yet
function LibraryBrowser:isSelectable(book)
    return book.primary_file_name ~= nil and self:getLocalPath(book.id) == nil
end

---@param book LibraryBook | nil Selected right away
function LibraryBrowser:startSelection(screen, book)
    screen.selection = { ids = {}, order = {}, count = 0 }
    if book then
        self:toggleSelected(screen, book)
    else
        self:show()
    end
end

local function setSelected(selection, book, selected)
    local key = tostring(book.id)
    if selected and not selection.ids[key] then
        selection.ids[key] = book
        table.insert(selection.order, key)
        selection.count = selection.count + 1
    elseif not selected and selection.ids[key] then
        selection.ids[key] = nil
        for i, order_key in ipairs(selection.order) do
            if order_key == key then
                table.remove(selection.order, i)
                break
            end
        end
        selection.count = selection.count - 1
    end
end

function LibraryBrowser:toggleSelected(screen, book)
    local selection = screen.selection
    if not selection then
        return
    end

    if not self:isSelectable(book) then
        self.dialog_manager:notify(book.primary_file_name and _("Already on this device.")
            or _("No file to download"), 2)
        return
    end

    setSelected(selection, book, selection.ids[tostring(book.id)] == nil)
    self:show()
end

--- Select (or deselect) the selectable books of the page shown
function LibraryBrowser:selectPage(screen, selected)
    for _, book in ipairs(screen.items or {}) do
        if self:isSelectable(book) then
            setSelected(screen.selection, book, selected)
        end
    end
    self:show()
end

function LibraryBrowser:showSelectionMenu(screen)
    local count = screen.selection.count
    Sheet.show({
        title = _("Select books"),
        icon = "select",
        fit_width = true,
        auto_close = true,
        sections = {
            Sheet.list({
                { text = _("Select all on this page"), sui_icon = "select_all", callback = function()
                    self:selectPage(screen, true)
                end },
                { text = _("Deselect all on this page"), sui_icon = "deselect", callback = function()
                    self:selectPage(screen, false)
                end },
                {
                    text = T(_("Download (%1)"), count),
                    sui_icon = "import",
                    enabled = count > 0,
                    callback = function() self:downloadSelected(screen) end,
                },
                { text = _("Stop selecting"), sui_icon = "close", callback = function()
                    screen.selection = nil
                    self:show()
                end },
            }),
        },
    })
end

--- The bar at the bottom of a paged screen: pager, selection, or the
--- progress of a batch download
function LibraryBrowser:footer(screen)
    local on_page = function(page) self:turnPage(page - screen.page) end

    if screen.batch then
        return Widgets.footerWith(self:downloadProgressWidget(screen, self.width - 2 * Style.SIDE_MARGIN), self.width)
    elseif screen.selection then
        return Widgets.selectionFooter({
            width = self.width,
            page = screen.page,
            pages = screen.pages or 1,
            on_page = on_page,
            count = screen.selection.count,
            on_cancel = function()
                screen.selection = nil
                self:show()
            end,
            on_download = function()
                self:downloadSelected(screen)
            end,
        })
    end

    return Widgets.footer({
        width = self.width,
        page = screen.page,
        pages = screen.pages or 1,
        on_page = on_page,
    })
end

--- Download the selected books one after another (in one background run),
--- with the progress in the bottom bar and a summary at the end.
function LibraryBrowser:downloadSelected(screen)
    local selection = screen.selection
    if not selection or selection.count == 0 then
        return
    end

    if self.is_sync_running() then
        self.dialog_manager:notify(_("A sync is running. Please try again when it has finished."), 3)
        return
    end
    if self.batch_running then
        self.dialog_manager:notify(_("Books are being downloaded. Please wait until they are done."), 3)
        return
    end

    local books = {}
    for _, key in ipairs(selection.order) do
        table.insert(books, selection.ids[key])
    end

    screen.selection = nil
    screen.batch = { index = 1, total = #books, title = books[1].title }
    screen.download_fraction = 0
    self.batch_running = true
    self:show()

    self.executor:background(function(run)
        local run_ok, ok, results = pcall(run, function(report)
            local results = {}
            for index, book in ipairs(books) do
                report({ batch_index = index })
                local download_ok, path = pcall(function()
                    return self.synchronizer:downloadLibraryBook(book.id, function(bytes, total)
                        report({ download_bytes = bytes, download_total = total })
                    end)
                end)
                table.insert(results, {
                    path = (download_ok and type(path) == "string") and path or nil,
                    error = (not download_ok) and tostring(path) or nil,
                })
            end
            return results
        end, function(state)
            if type(state) ~= "table" then
                return
            end
            local batch = screen.batch
            if not batch then
                return
            end
            if state.batch_index then
                batch.index = state.batch_index
                batch.title = books[state.batch_index].title
                batch.book_fraction = 0
            elseif state.download_bytes then
                local total = state.download_total
                    or ((books[batch.index].file_size_kb or 0) * 1024)
                batch.book_fraction = total > 0 and math.min(1, state.download_bytes / total) or 0
            end
            screen.download_fraction = ((batch.index - 1) + (batch.book_fraction or 0)) / batch.total
            self:updateDownloadProgress(screen)
        end)

        self.batch_running = false
        screen.batch = nil
        self.download_widgets = nil

        if not run_ok or not ok or type(results) ~= "table" then
            local error_result = run_ok and results or ok
            logger:err("Downloading the selected books failed:", error_result)
            UIManager:show(InfoMessage:new({
                text = T(_("Could not download the books:\n%1"), LibraryData.describeError(error_result)),
            }))
            if self:current() == screen then
                self:show()
            end
            return
        end

        local failed = {}
        local downloaded = 0
        for index, result in ipairs(results) do
            local book = books[index]
            if result.path then
                downloaded = downloaded + 1
                -- Keep them on the device even if they are in no download source
                self.settings:setKeptBook(book.id, true)
                local paths = self.local_paths[tostring(book.id)] or {}
                table.insert(paths, 1, result.path)
                self.local_paths[tostring(book.id)] = paths
            else
                logger:err("Book download failed:", book.id, result.error)
                table.insert(failed, book.title)
            end
        end

        -- The downloads ran in a subprocess: reload what they changed
        ReadCollection.last_read_time = 0
        pcall(ReadCollection._read, ReadCollection)
        UIManager:broadcastEvent(Event:new("RefreshContent"))

        if #failed == 0 then
            self.dialog_manager:notify(T(N_("Grimmory: downloaded %1 book", "Grimmory: downloaded %1 books",
                downloaded), downloaded), 3)
        else
            UIManager:show(InfoMessage:new({
                text = T(_("Downloaded %1 of %2 books. Could not download:\n%3"),
                    downloaded, #books, table.concat(failed, "\n")),
            }))
        end

        if self:current() == screen then
            self:show()
        end
    end, true)
end

return LibraryBrowser

--[[
Library browser: its screens (tabs, book lists, collections, home rows)
and what each loads from the server.  Methods of LibraryBrowser
(grimmory/ui/library/browser.lua).
--]]

local _ = require("gettext")

---@class LibraryBrowserMethods
local LibraryBrowser = {}

--- A screen showing books page by page.  `load(page, size, done)` loads one
--- page (0-based) with `size` books and calls `done(ok, LibraryPage|reason)`.
function LibraryBrowser:booksScreen(title, cache_key, load, extra)
    local screen = {
        type = "books",
        title = title,
        paged = true,
        page = 1,
        cache_key = cache_key,
        load = load,
    }
    for key, value in pairs(extra or {}) do
        screen[key] = value
    end
    return screen
end

--- Books of the server's book list with the given filter
function LibraryBrowser:filteredBooksScreen(title, cache_key, params, extra)
    return self:booksScreen(title, cache_key, function(page, size, done)
        local query = { page = page, size = size }
        for key, value in pairs(params) do
            query[key] = value
        end
        self.data:fetch(cache_key .. ":" .. size .. ":" .. page, function()
            return self.api:getAppBooks(query)
        end, done)
    end, extra)
end

--- Books of a fixed list (e.g. "continue reading"), paged on the device
function LibraryBrowser:listBooksScreen(title, cache_key, request)
    return self:booksScreen(title, cache_key, function(page, size, done)
        self.data:fetch(cache_key, request, function(ok, books)
            if not ok then
                done(false, books)
                return
            end
            local items = {}
            for i = page * size + 1, math.min(#books, (page + 1) * size) do
                table.insert(items, books[i])
            end
            done(true, { items = items, total = #books, has_next = (page + 1) * size < #books })
        end)
    end)
end

---@param kind "shelves" | "libraries" | "magic_shelves" | "series"
function LibraryBrowser:collectionBooksScreen(kind, collection)
    local source = { kind = kind, collection = collection }

    if kind == "series" then
        return self:booksScreen(collection.name, "series-books:" .. collection.name, function(page, size, done)
            self.data:fetch("series-books:" .. collection.name .. ":" .. size .. ":" .. page, function()
                return self.api:getAppSeriesBooks(collection.name, page, size)
            end, done)
        end, { source = source, subtitle = _("Series") })
    elseif kind == "magic_shelves" then
        return self:booksScreen(collection.name, "magic:" .. collection.id, function(page, size, done)
            self.data:fetch("magic:" .. collection.id .. ":" .. size .. ":" .. page, function()
                return self.api:getAppMagicShelfBooks(collection.id, page, size)
            end, done)
        end, { source = source, subtitle = _("Magic shelf") })
    end

    local filter = kind == "libraries" and "libraryId" or "shelfId"
    return self:filteredBooksScreen(collection.name, kind .. ":" .. collection.id, {
        [filter] = collection.id,
        sort = "title",
        dir = "asc",
    }, { source = source, subtitle = kind == "libraries" and _("Library") or _("Shelf") })
end

function LibraryBrowser:createTabScreen(tab_id)
    if tab_id == "home" then
        return { type = "home", title = _("Grimmory Library"), tab = "home" }
    elseif tab_id == "books" then
        return self:filteredBooksScreen(
            _("Grimmory Library"), "all", { sort = "title", dir = "asc" }, { tab = "books" }
        )
    elseif tab_id == "series" then
        return {
            type = "collections",
            kind = "series",
            tab = "series",
            title = _("Grimmory Library"),
            paged = true,
            page = 1,
            with_covers = true,
            load = function(page, size, done)
                self.data:fetch("series:" .. size .. ":" .. page, function()
                    return self.api:getAppSeries({ page = page, size = size })
                end, done)
            end,
        }
    elseif tab_id == "shelves" then
        return {
            type = "collections",
            kind = "shelves",
            tab = "shelves",
            title = _("Grimmory Library"),
            paged = true,
            page = 1,
            load = function(page, size, done)
                self.data:fetch("shelves", function()
                    local ok, shelves = self.api:getAppShelves()
                    if not ok then
                        return false, shelves
                    end
                    local magic_ok, magic_shelves = self.api:getAppMagicShelves()
                    local entries = {}
                    for _, shelf in ipairs(shelves) do
                        table.insert(entries, { kind = "shelves", collection = shelf })
                    end
                    -- Older servers may not have magic shelves; show the shelves anyway
                    for _, shelf in ipairs(magic_ok and magic_shelves or {}) do
                        table.insert(entries, { kind = "magic_shelves", collection = shelf })
                    end
                    return true, entries
                end, function(ok, entries)
                    self:pageList(ok, entries, page, size, done)
                end)
            end,
        }
    elseif tab_id == "libraries" then
        return {
            type = "collections",
            kind = "libraries",
            tab = "libraries",
            title = _("Grimmory Library"),
            paged = true,
            page = 1,
            load = function(page, size, done)
                self.data:fetch("libraries", function()
                    local ok, libraries = self.api:getAppLibraries()
                    if not ok then
                        return false, libraries
                    end
                    local entries = {}
                    for _, library in ipairs(libraries) do
                        table.insert(entries, { kind = "libraries", collection = library })
                    end
                    return true, entries
                end, function(ok, entries)
                    self:pageList(ok, entries, page, size, done)
                end)
            end,
        }
    end
end

--- Page a list that was loaded completely
function LibraryBrowser:pageList(ok, entries, page, size, done)
    if not ok then
        done(false, entries)
        return
    end

    local items = {}
    for i = page * size + 1, math.min(#entries, (page + 1) * size) do
        table.insert(items, entries[i])
    end

    done(true, { items = items, total = #entries, has_next = (page + 1) * size < #entries })
end

--- Home rows: continue reading, recently added, then the download sources
function LibraryBrowser:getHomeSections(count)
    local sections = {
        {
            title = _("Continue Reading"),
            load = function(done)
                self.data:fetch("home:continue:" .. count, function()
                    return self.api:getAppContinueReading(count)
                end, done)
            end,
            open = function()
                return self:listBooksScreen(_("Continue Reading"), "continue:50", function()
                    return self.api:getAppContinueReading(50)
                end)
            end,
        },
        {
            title = _("Recently Added"),
            load = function(done)
                self.data:fetch("home:recent:" .. count, function()
                    return self.api:getAppRecentlyAdded(count)
                end, done)
            end,
            open = function()
                return self:filteredBooksScreen(_("Recently Added"), "recent", { sort = "addedOn", dir = "desc" })
            end,
        },
    }

    for _, kind in ipairs({ "shelves", "magic_shelves", "libraries", "series" }) do
        for _, source in ipairs(self.settings:getDownloadSources(kind)) do
            local screen_template = self:collectionBooksScreen(kind, source)
            table.insert(sections, {
                title = source.name,
                load = function(done)
                    screen_template.load(0, count, function(ok, result)
                        done(ok, ok and result.items or result)
                    end)
                end,
                open = function()
                    return self:collectionBooksScreen(kind, source)
                end,
            })
        end
    end

    return sections
end

return LibraryBrowser

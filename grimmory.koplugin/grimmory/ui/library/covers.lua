local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

-- Cover thumbnails are kept on the device.  The cover's update time is part
-- of the file name, so a changed cover is downloaded again; old files are
-- pruned (oldest first) when there are too many.
local COVER_DIRECTORY = DataStorage:getDataDir() .. "/cache/grimmory/covers"
local MAX_CACHED_COVERS = 3000

local Covers = {}

---@param full boolean | nil The full size cover instead of the thumbnail
---@return string path
function Covers.path(book_id, updated_on, full)
    local version = tostring(updated_on or "0"):gsub("[^%w]", "")
    return COVER_DIRECTORY .. "/" .. tostring(book_id) .. "-" .. version .. (full and "-full" or "") .. ".jpg"
end

function Covers.exists(path)
    return lfs.attributes(path, "mode") == "file"
end

function Covers.prune()
    if lfs.attributes(COVER_DIRECTORY, "mode") ~= "directory" then
        return
    end

    local files = {}
    for name in lfs.dir(COVER_DIRECTORY) do
        if name:match("%.jpg$") then
            local path = COVER_DIRECTORY .. "/" .. name
            table.insert(files, { path = path, time = lfs.attributes(path, "modification") or 0 })
        end
    end

    if #files <= MAX_CACHED_COVERS then
        return
    end

    table.sort(files, function(a, b) return a.time < b.time end)
    for i = 1, #files - MAX_CACHED_COVERS do
        os.remove(files[i].path)
    end
end

--- Delete all cached covers.
---@return number files
---@return number bytes
function Covers.clear()
    local files, bytes = 0, 0

    if lfs.attributes(COVER_DIRECTORY, "mode") ~= "directory" then
        return files, bytes
    end

    for name in lfs.dir(COVER_DIRECTORY) do
        local path = COVER_DIRECTORY .. "/" .. name
        if lfs.attributes(path, "mode") == "file" then
            bytes = bytes + (lfs.attributes(path, "size") or 0)
            if os.remove(path) then
                files = files + 1
            end
        end
    end

    return files, bytes
end

-- Covers downloaded at the same time (one subprocess and connection each):
-- over the Internet most of the time per cover is waiting for the server
local DOWNLOAD_WORKERS = 3

--- Download the given covers in subprocesses, so the browser stays usable
--- while they load.  They are shared out in turns, so the first covers of
--- the page come first.  `on_cover(book_id)` is called in the UI process as
--- each one arrives.
---@param executor GrimmoryExecutor
---@param api GrimmoryAPI
---@param requests { id: number, path: string, full: boolean|nil }[]
---@param on_cover function(book_id: number)
---@return function cancel
function Covers.download(executor, api, requests, on_cover)
    local cancelled = false
    local terminators = {}

    if #requests == 0 then
        return function() end
    end

    util.makePath(COVER_DIRECTORY)

    local shares = {}
    for index, request in ipairs(requests) do
        local worker = (index - 1) % DOWNLOAD_WORKERS + 1
        shares[worker] = shares[worker] or {}
        table.insert(shares[worker], request)
    end

    for _, share in ipairs(shares) do
        executor:background(function(run, terminate)
            if cancelled then
                return
            end
            table.insert(terminators, terminate)

            local ok, result = run(
                function(report)
                    for _, request in ipairs(share) do
                        local partial_path = request.path .. ".part"
                        local downloaded = api:downloadThumbnail(request.id, partial_path, request.full)

                        if downloaded and os.rename(partial_path, request.path) then
                            report({ cover_id = request.id })
                        else
                            os.remove(partial_path)
                        end
                    end
                end,
                function(state)
                    if not cancelled and type(state) == "table" and state.cover_id then
                        on_cover(state.cover_id)
                    end
                end
            )

            if not ok and not cancelled then
                logger:warn("Cover download failed:", result)
            end
        end, false)
    end

    return function()
        cancelled = true
        for _, terminate in ipairs(terminators) do
            terminate()
        end
    end
end

return Covers

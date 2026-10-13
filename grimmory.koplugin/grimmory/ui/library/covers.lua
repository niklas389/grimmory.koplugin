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

--- Download the given covers in a subprocess, so the browser stays usable
--- while they load (each one is an HTTPS request).  `on_cover(book_id)` is
--- called in the UI process as each one arrives.
---@param executor GrimmoryExecutor
---@param api GrimmoryAPI
---@param requests { id: number, path: string, full: boolean|nil }[]
---@param on_cover function(book_id: number)
---@return function cancel
function Covers.download(executor, api, requests, on_cover)
    local cancelled = false
    local terminate_subprocess = nil

    if #requests == 0 then
        return function() end
    end

    util.makePath(COVER_DIRECTORY)

    executor:background(function(run, terminate)
        terminate_subprocess = terminate

        local ok, result = run(
            function(report)
                for _, request in ipairs(requests) do
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

    return function()
        cancelled = true
        if terminate_subprocess then
            terminate_subprocess()
        end
    end
end

return Covers

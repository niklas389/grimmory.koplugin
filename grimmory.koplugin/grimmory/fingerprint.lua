--[[
A book file's fingerprint (KOReader's partial MD5), computed once per file.

During a sync the same file is fingerprinted several times (finding its
download path, its local record, its reading progress on the server); each
time parts of the file are read.  Here the result is kept until the file
changes: its size, modification time or identity on disk (inode, e.g.
replaced by a refreshed copy) differ.
--]]

local util = require("util")

local Fingerprint = {}

-- path -> { size, modification, ino, md5 }
local cache = {}

local function attributes(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not lfs then
        return nil
    end
    local attr = lfs.attributes(path)
    if type(attr) ~= "table" or attr.mode ~= "file" then
        return nil
    end
    return attr
end

--- The partial MD5 of a file (nil when it cannot be read)
---@param path string | nil
---@return string | nil
function Fingerprint.partialMD5(path)
    if not path then
        return nil
    end

    local attr = attributes(path)
    if not attr then
        cache[path] = nil
        return util.partialMD5(path)
    end

    local entry = cache[path]
    if entry and entry.size == attr.size and entry.modification == attr.modification and entry.ino == attr.ino then
        return entry.md5
    end

    local md5 = util.partialMD5(path)
    if md5 then
        cache[path] = { size = attr.size, modification = attr.modification, ino = attr.ino, md5 = md5 }
    else
        cache[path] = nil
    end
    return md5
end

--- Forget what is known about a file (e.g. it was just written)
function Fingerprint.forget(path)
    if path then
        cache[path] = nil
    end
end

return Fingerprint

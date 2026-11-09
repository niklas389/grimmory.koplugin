local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local files, hashed

describe("Fingerprint", function()
    local Fingerprint

    setup(function()
        package.loaded["util"] = {
            partialMD5 = function(path)
                hashed = hashed + 1
                return files[path] and files[path].content
            end,
        }
        package.loaded["libs/libkoreader-lfs"] = {
            attributes = function(path)
                local file = files[path]
                return file and { mode = "file", size = #file.content, modification = file.time, ino = file.ino } or nil
            end,
        }
        package.loaded["grimmory/fingerprint"] = nil
        Fingerprint = require("grimmory/fingerprint")
    end)

    teardown(function()
        package.loaded["util"] = nil
        package.loaded["libs/libkoreader-lfs"] = nil
        package.loaded["grimmory/fingerprint"] = nil
    end)

    before_each(function()
        files = { ["/b.epub"] = { content = "aaa", time = 1, ino = 10 } }
        hashed = 0
        Fingerprint.forget("/b.epub")
    end)

    it("reads an unchanged file once", function()
        assert.are.equal("aaa", Fingerprint.partialMD5("/b.epub"))
        assert.are.equal("aaa", Fingerprint.partialMD5("/b.epub"))
        assert.are.equal(1, hashed)
    end)

    it("reads it again when it changed or was replaced", function()
        Fingerprint.partialMD5("/b.epub")

        files["/b.epub"] = { content = "bbb", time = 2, ino = 10 }
        assert.are.equal("bbb", Fingerprint.partialMD5("/b.epub"))

        -- Same size and time, another file (e.g. renamed over it)
        files["/b.epub"] = { content = "ccc", time = 2, ino = 11 }
        assert.are.equal("ccc", Fingerprint.partialMD5("/b.epub"))
        assert.are.equal(3, hashed)
    end)

    it("has nothing for a missing file", function()
        files = {}
        assert.is_nil(Fingerprint.partialMD5("/b.epub"))
        assert.is_nil(Fingerprint.partialMD5(nil))
    end)
end)

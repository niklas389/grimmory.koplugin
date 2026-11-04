local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local quiet = function() end
local fake_logger = { err = quiet, warn = quiet, info = quiet, dbg = quiet }

-- Fakes, also replacing what other spec files loaded
local FAKES = {
    ["grimmory/logger"] = { new = function() return fake_logger end },
    ["gettext"] = function(text) return text end,
    ["datastorage"] = { getSettingsDir = function() return "/tmp" end },
    ["random"] = { uuid = function() return "device-uuid" end },
    ["device"] = { model = "Test" },
    ["readcollection"] = {},
    ["ffi/MD5"] = {},
    ["util"] = {},
    ["ssl.https"] = { request = function() error("no https in this spec") end },
    ["json"] = { encode = function() return "{}" end, decode = function() return {} end },
    ["socket"] = { gettime = function() return 0 end },
    ["socket.url"] = { escape = function(text) return text end },
    ["grimmory/plugin_metadata"] = {
        getVersion = function() return "test" end,
        getRepository = function() return "test/repo" end,
    },
    ["grimmory/datetime"] = {},
}

local stored_settings
local last_request

local function load_modules()
    for name, fake in pairs(FAKES) do
        package.loaded[name] = fake
    end
    package.loaded["luasettings"] = {
        open = function()
            return {
                readSetting = function(_, key) return stored_settings[key] end,
                saveSetting = function(_, key, value) stored_settings[key] = value end,
                flush = function() end,
            }
        end,
    }
    package.loaded["grimmory/http_client"] = {
        request = function(request)
            last_request = request
            return 1, 200, {}
        end,
    }
    package.loaded["ltn12"] = {
        source = { string = function() return nil end },
        sink = { table = function() return nil end },
    }
    package.loaded["grimmory/settings"] = nil
    package.loaded["grimmory/grimmory_api"] = nil

    return require("grimmory/settings"), require("grimmory/grimmory_api")
end

describe("Custom HTTP headers", function()
    local GrimmorySettings, GrimmoryAPI
    local settings

    before_each(function()
        stored_settings = {}
        last_request = nil
        GrimmorySettings, GrimmoryAPI = load_modules()
        settings = GrimmorySettings:new()
    end)

    teardown(function()
        for name in pairs(FAKES) do
            package.loaded[name] = nil
        end
        local others = {
            "luasettings", "grimmory/http_client", "ltn12", "grimmory/settings", "grimmory/grimmory_api",
        }
        for _, name in ipairs(others) do
            package.loaded[name] = nil
        end
    end)

    describe("validation", function()
        it("accepts a token name and a plain value", function()
            assert.is_true(GrimmorySettings.validateHeader("X-Api-Key", "s3cr3t value"))
        end)

        it("rejects names with spaces or a colon", function()
            assert.are.same({ false, "name" }, { GrimmorySettings.validateHeader("X Api", "a") })
            assert.are.same({ false, "name" }, { GrimmorySettings.validateHeader("X-Api:", "a") })
            assert.are.same({ false, "name" }, { GrimmorySettings.validateHeader("", "a") })
        end)

        it("rejects headers the plugin sets itself, in any case", function()
            assert.are.same({ false, "reserved" }, { GrimmorySettings.validateHeader("authorization", "Basic x") })
            assert.are.same({ false, "reserved" }, { GrimmorySettings.validateHeader("Content-Length", "1") })
            assert.are.same({ false, "reserved" }, { GrimmorySettings.validateHeader("X-Auth-User", "u") })
        end)

        it("rejects values with line breaks", function()
            assert.are.same({ false, "value" }, { GrimmorySettings.validateHeader("X-Api-Key", "a\r\nX-Evil: 1") })
        end)
    end)

    describe("editing", function()
        it("adds, renames and removes headers, ignoring the case of names", function()
            assert.is_true(settings:setExtraHeader(" X-Api-Key ", " one "))
            assert.are.same({ ["X-Api-Key"] = "one" }, settings:getExtraHeaders())

            -- Same name in another case replaces it
            settings:setExtraHeader("x-api-key", "two")
            assert.are.same({ ["x-api-key"] = "two" }, settings:getExtraHeaders())

            -- Renaming replaces the old one
            settings:setExtraHeader("X-Token", "three", "x-api-key")
            assert.are.same({ ["X-Token"] = "three" }, settings:getExtraHeaders())

            settings:removeExtraHeader("x-token")
            assert.are.same({}, settings:getExtraHeaders())
        end)

        it("keeps the headers when the new one is invalid", function()
            settings:setExtraHeader("X-Api-Key", "one")

            assert.are.same({ false, "reserved" }, { settings:setExtraHeader("Authorization", "Basic x") })
            assert.are.same({ ["X-Api-Key"] = "one" }, settings:getExtraHeaders())
        end)
    end)

    describe("requests", function()
        it("sends the custom headers", function()
            settings:setExtraHeader("X-Api-Key", "secret")
            local api = GrimmoryAPI:new({ settings = settings })

            api:rawRequest("GET", "http://grimmory.local/api/v1/healthcheck")

            assert.are.equal("secret", last_request.headers["X-Api-Key"])
            assert.is_not_nil(last_request.headers["User-Agent"])
        end)

        it("lets the request's own headers win over custom ones", function()
            -- Stored directly, as an older version allowed it
            settings:setExtraHeaders({ ["authorization"] = "Basic proxy", ["X-Api-Key"] = "secret" })
            local api = GrimmoryAPI:new({ settings = settings })

            api:rawRequest("GET", "http://grimmory.local/api/v1/books", nil, { Authorization = "Bearer grimmory" })

            assert.are.equal("Bearer grimmory", last_request.headers["Authorization"])
            assert.is_nil(last_request.headers["authorization"])
            assert.are.equal("secret", last_request.headers["X-Api-Key"])
        end)

        it("does not send stored headers that are invalid", function()
            settings:setExtraHeaders({ ["X-Evil"] = "a\r\nHost: other" })
            local api = GrimmoryAPI:new({ settings = settings })

            api:rawRequest("GET", "http://grimmory.local/api/v1/books")

            assert.is_nil(last_request.headers["X-Evil"])
        end)
    end)
end)

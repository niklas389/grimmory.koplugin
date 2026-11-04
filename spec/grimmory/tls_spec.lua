local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local calls

local function load_tls()
    calls = {}
    package.loaded["socket"] = { try = function(ok, message) if not ok then error({ message }) end return ok end }
    package.loaded["socket.http"] = {
        request = function(reqt)
            table.insert(calls, { client = "http", reqt = reqt })
            return 1, 200
        end,
    }
    package.loaded["ssl.https"] = {
        request = function(reqt)
            table.insert(calls, { client = "https", reqt = reqt })
            return 1, 200
        end,
        tcp = function(params)
            return function() return { params = params } end
        end,
    }
    package.loaded["datastorage"] = { getDataDir = function() return "/nonexistent" end }
    package.loaded["grimmory/tls"] = nil
    return require("grimmory/tls")
end

--- A LuaSec certificate with these DNS names (and common name)
local function certificate(dns_names, common_name, ip_addresses)
    return {
        extensions = function()
            if not dns_names and not ip_addresses then
                return {}
            end
            return { ["2.5.29.17"] = { dNSName = dns_names, iPAddress = ip_addresses } }
        end,
        subject = function()
            return { { name = "commonName", value = common_name } }
        end,
    }
end

describe("TLS", function()
    local Tls

    before_each(function()
        Tls = load_tls()
    end)

    teardown(function()
        for _, name in ipairs({ "socket", "socket.http", "ssl.https", "datastorage", "grimmory/tls" }) do
            package.loaded[name] = nil
        end
    end)

    describe("host names", function()
        it("matches exact names, ignoring case and a trailing dot", function()
            assert.is_true(Tls.nameMatches("grimmory.example.com", "Grimmory.Example.com."))
            assert.is_false(Tls.nameMatches("grimmory.example.com", "example.com"))
        end)

        it("matches a wildcard for exactly one label", function()
            assert.is_true(Tls.nameMatches("*.example.com", "grimmory.example.com"))
            assert.is_false(Tls.nameMatches("*.example.com", "example.com"))
            assert.is_false(Tls.nameMatches("*.example.com", "a.b.example.com"))
            assert.is_false(Tls.nameMatches("*.example.com", "grimmory.example.com.evil.net"))
        end)

        it("does not accept wildcards for a whole top level domain or in other places", function()
            assert.is_false(Tls.nameMatches("*.com", "example.com"))
            assert.is_false(Tls.nameMatches("gr*.example.com", "grimmory.example.com"))
            assert.is_false(Tls.nameMatches("*.*.example.com", "a.b.example.com"))
        end)
    end)

    describe("certificates", function()
        it("checks the DNS names", function()
            local cert = certificate({ "example.com", "*.example.com" }, "example.com")
            assert.is_true(Tls.certificateMatches(cert, "grimmory.example.com"))
            assert.is_false(Tls.certificateMatches(cert, "grimmory.other.com"))
        end)

        it("ignores the common name when there are DNS names", function()
            local cert = certificate({ "other.com" }, "grimmory.example.com")
            assert.is_false(Tls.certificateMatches(cert, "grimmory.example.com"))
        end)

        it("uses the common name without DNS names", function()
            assert.is_true(Tls.certificateMatches(certificate(nil, "grimmory.example.com"), "grimmory.example.com"))
        end)

        it("checks IP addresses against the certificate's addresses only", function()
            assert.is_true(Tls.certificateMatches(certificate(nil, "x", { "192.168.1.5" }), "192.168.1.5"))
            assert.is_false(Tls.certificateMatches(certificate(nil, "192.168.1.5"), "192.168.1.5"))
        end)
    end)

    describe("requests", function()
        it("passes plain http requests to LuaSocket", function()
            Tls.request({ url = "http://grimmory.local/api" }, true)
            assert.are.equal("http", calls[1].client)
            assert.is_nil(calls[1].reqt.create)
        end)

        it("uses LuaSec's unchecked request when checking is off", function()
            Tls.request({ url = "https://grimmory.example.com/api" }, false)
            assert.are.equal("https", calls[1].client)
        end)

        it("refuses to connect without CA certificates", function()
            local original = Tls.findCaFile
            Tls.findCaFile = function() return nil end

            local result, message = Tls.request({ url = "https://grimmory.example.com/api" }, true)

            Tls.findCaFile = original
            assert.is_nil(result)
            assert.truthy(message:find("CA certificates", 1, true))
            assert.are.equal(0, #calls)
        end)

        it("connects with the certificate check", function()
            Tls.findCaFile = function() return "/ca.crt" end

            Tls.request({ url = "https://grimmory.example.com/api" }, true)

            assert.are.equal("http", calls[1].client)
            local conn = calls[1].reqt.create()
            assert.are.same({ "peer", "fail_if_no_peer_cert" }, conn.params.verify)
            assert.are.equal("/ca.crt", conn.params.cafile)
        end)

        it("ends the connection when the certificate is for another host", function()
            local closed = false
            local sock = {
                getpeercertificate = function() return certificate({ "evil.net" }, "evil.net") end,
                close = function() closed = true end,
            }
            package.loaded["ssl.https"].tcp = function()
                return function()
                    return { sock = sock, connect = function() end }
                end
            end

            local conn = Tls.create({})()
            local ok, err = pcall(conn.connect, conn, "grimmory.example.com", 443)

            assert.is_false(ok)
            assert.truthy(err[1]:find("does not match", 1, true))
            assert.is_true(closed)
        end)

        it("explains certificate errors", function()
            assert.truthy(Tls.describeError("certificate verify failed"):find("date and time", 1, true))
            assert.is_nil(Tls.describeError("connection refused"))
        end)
    end)
end)

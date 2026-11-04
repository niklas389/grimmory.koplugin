local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

-- Fake connections: each new connection takes the next script, a list of
-- responses (raw text) or false (the server closed the connection)
local scripts
local connections

local function fake_socket()
    local conn = { sent = {}, closed = false, buffer = "", responses = table.remove(scripts, 1) or {} }
    table.insert(connections, conn)

    function conn:settimeout() end
    function conn:connect() return 1 end
    function conn:close() self.closed = true end

    function conn:send(data)
        if self.closed then
            return nil, "closed"
        end
        table.insert(self.sent, data)
        local response = table.remove(self.responses, 1)
        if response == false then
            self.dead = true
        elseif response then
            self.buffer = self.buffer .. response
        end
        return #data
    end

    function conn:receive(pattern)
        if pattern == "*l" then
            local line, rest = self.buffer:match("^(.-)\r?\n(.*)$")
            if not line then
                return nil, "closed"
            end
            self.buffer = rest
            return line
        end
        if #self.buffer == 0 then
            return nil, "closed", ""
        end
        local chunk = self.buffer:sub(1, pattern)
        self.buffer = self.buffer:sub(pattern + 1)
        return chunk
    end

    return conn
end

local function response(code, headers, body)
    local lines = { "HTTP/1.1 " .. code .. " X" }
    for name, value in pairs(headers or {}) do
        table.insert(lines, name .. ": " .. value)
    end
    if body and not (headers and headers["Transfer-Encoding"]) then
        table.insert(lines, "Content-Length: " .. #body)
    end
    return table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or "")
end

local now = 0

local function load_client()
    scripts, connections = {}, {}
    package.loaded["socket"] = { tcp = fake_socket, gettime = function() return now end }
    package.loaded["socket.http"] = { TIMEOUT = 5 }
    package.loaded["socket.url"] = {
        parse = function(url)
            local scheme, host, port, path = url:match("^(%a+)://([^/:]+):?(%d*)(.*)$")
            return { scheme = scheme, host = host, port = port ~= "" and port or nil, path = path }
        end,
        absolute = function(base, location)
            if location:match("^%a+://") then
                return location
            end
            return base:match("^(%a+://[^/]+)") .. location
        end,
    }
    package.loaded["ltn12"] = {
        sink = {
            table = function(t)
                return function(chunk)
                    if chunk then
                        table.insert(t, chunk)
                    end
                    return 1
                end
            end,
            null = function() return function() return 1 end end,
        },
    }
    package.loaded["grimmory/tls"] = { describeError = function() return nil end }
    package.loaded["grimmory/http_client"] = nil
    return require("grimmory/http_client")
end

describe("HTTP client", function()
    local HttpClient

    before_each(function()
        now = 0
        HttpClient = load_client()
    end)

    teardown(function()
        local fakes = { "socket", "socket.http", "socket.url", "ltn12", "grimmory/tls", "grimmory/http_client" }
        for _, name in ipairs(fakes) do
            package.loaded[name] = nil
        end
    end)

    local function get(url, method)
        local body = {}
        local ok, code = HttpClient.request({
            url = url,
            method = method or "GET",
            headers = { ["User-Agent"] = "test" },
            sink = package.loaded["ltn12"].sink.table(body),
        })
        return ok, code, table.concat(body)
    end

    it("reuses the connection for the next request", function()
        scripts = { { response(200, {}, "one"), response(200, {}, "two") } }

        assert.are.same({ 1, 200, "one" }, { get("http://grimmory.local/a") })
        assert.are.same({ 1, 200, "two" }, { get("http://grimmory.local/b") })

        assert.are.equal(1, #connections)
        assert.truthy(connections[1].sent[1]:find("^GET /a HTTP/1.1\r\n"))
        assert.truthy(connections[1].sent[1]:find("Host: grimmory.local\r\n", 1, true))
        assert.truthy(connections[1].sent[1]:find("Connection: keep%-alive"))
    end)

    it("reads chunked bodies", function()
        scripts = { { response(200, { ["Transfer-Encoding"] = "chunked" }, "3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n") } }

        assert.are.same({ 1, 200, "abcde" }, { get("http://grimmory.local/a") })
    end)

    it("does not reuse a connection the server closes", function()
        scripts = { { response(200, { Connection = "close" }, "one") }, { response(200, {}, "two") } }

        get("http://grimmory.local/a")
        get("http://grimmory.local/b")

        assert.are.equal(2, #connections)
        assert.is_true(connections[1].closed)
    end)

    it("sends the request again when a reused connection was closed meanwhile", function()
        scripts = { { response(200, {}, "one"), false }, { response(200, {}, "two") } }

        get("http://grimmory.local/a")
        assert.are.same({ 1, 200, "two" }, { get("http://grimmory.local/b") })

        assert.are.equal(2, #connections)
    end)

    it("does not reuse a connection idle for too long", function()
        scripts = { { response(200, {}, "one") }, { response(200, {}, "two") } }

        get("http://grimmory.local/a")
        now = 31
        get("http://grimmory.local/b")

        assert.are.equal(2, #connections)
    end)

    it("follows redirects on the same server, without their body", function()
        scripts = { { response(302, { Location = "/b" }, "moved"), response(200, {}, "file") } }

        assert.are.same({ 1, 200, "file" }, { get("http://grimmory.local/a") })
    end)

    it("does not follow redirects to another server", function()
        scripts = { { response(302, { Location = "http://elsewhere.net/b" }, "") } }

        local ok, message = get("http://grimmory.local/a")

        assert.is_nil(ok)
        assert.truthy(message:find("another server", 1, true))
        assert.are.equal(1, #connections)
    end)

    it("skips 100 Continue", function()
        scripts = { { "HTTP/1.1 100 Continue\r\n\r\n" .. response(201, {}, "created") } }

        assert.are.same({ 1, 201, "created" }, { get("http://grimmory.local/a", "POST") })
    end)

    it("starts without connections in a subprocess", function()
        scripts = { { response(200, {}, "one") }, { response(200, {}, "two") } }

        get("http://grimmory.local/a")
        HttpClient.forgetConnections()
        get("http://grimmory.local/b")

        assert.are.equal(2, #connections)
        -- The parent's connection is left alone
        assert.is_false(connections[1].closed)
    end)
end)

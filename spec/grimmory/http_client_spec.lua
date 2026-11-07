local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

-- Fake connections that never block, like the client's: each new connection
-- takes the next script, a list of responses (raw text) or false (the server
-- closed the connection).  Waiting (select) moves the fake clock on.
local scripts
local connections
local now = 0
-- Options for the next connections: { hang_connect = true } (no answer to
-- connecting), { hang_read = true } (no answer to requests)
local next_options

local function fake_socket()
    local options = table.remove(next_options, 1) or {}
    local conn = {
        sent = {},
        closed = false,
        buffer = "",
        responses = options.hang_connect and {} or (table.remove(scripts, 1) or {}),
        hang_connect = options.hang_connect,
        hang_read = options.hang_read,
    }
    table.insert(connections, conn)

    function conn:settimeout() end
    function conn:connect()
        self.connect_calls = (self.connect_calls or 0) + 1
        if self.hang_connect then
            return nil, "timeout"
        end
        self.connected = true
        return 1
    end
    function conn:getpeername()
        if self.connected then
            return "10.0.0.1", 443
        end
        return nil, "Transport endpoint is not connected"
    end
    function conn:close() self.closed = true end

    function conn:send(data, i)
        i = i or 1
        if self.closed or self.dead then
            return nil, "closed", i - 1
        end
        table.insert(self.sent, data:sub(i))
        if not self.hang_read then
            local response = table.remove(self.responses, 1)
            if response == false then
                self.dead = true
            elseif response then
                self.buffer = self.buffer .. response
            end
        end
        return #data
    end

    function conn:receive(size)
        if #self.buffer >= size then
            local chunk = self.buffer:sub(1, size)
            self.buffer = self.buffer:sub(size + 1)
            return chunk
        end
        local partial = self.buffer
        self.buffer = ""
        if self.dead and partial == "" then
            return nil, "closed", ""
        end
        return nil, "timeout", partial
    end

    function conn:readable()
        return #self.buffer > 0 or self.dead
    end

    function conn:writable()
        return not self.hang_connect
    end

    return conn
end

local function fake_select(readers, writers, timeout)
    local readable, writable = {}, {}
    for _, sock in ipairs(readers or {}) do
        if sock:readable() then
            table.insert(readable, sock)
        end
    end
    for _, sock in ipairs(writers or {}) do
        if sock:writable() then
            table.insert(writable, sock)
        end
    end
    if #readable == 0 and #writable == 0 then
        now = now + (timeout or 0)
        return readable, writable, "timeout"
    end
    return readable, writable
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

local function load_client()
    scripts, connections, next_options = {}, {}, {}
    package.loaded["socket"] = {
        tcp = fake_socket,
        tcp4 = fake_socket,
        tcp6 = fake_socket,
        select = fake_select,
        gettime = function() return now end,
        dns = {
            getaddrinfo = function(host)
                return { { family = "inet", addr = host } }
            end,
        },
    }
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
        source = {
            string = function(text) return function() local chunk = text; text = nil; return chunk end end,
        },
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
    package.loaded["grimmory/tls"] = { describeError = function() return nil end, findCaFile = function() end }
    local quiet = function() end
    package.loaded["grimmory/logger"] = {
        new = function() return { err = quiet, warn = quiet, info = quiet, dbg = quiet } end,
    }
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
        local fakes = {
            "socket", "socket.http", "socket.url", "ltn12", "grimmory/tls", "grimmory/logger", "grimmory/http_client",
        }
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

    it("gives up connecting after the connect timeout", function()
        next_options = { { hang_connect = true } }

        local started = now
        local ok, message = get("http://grimmory.local/a")

        assert.is_nil(ok)
        assert.truthy(message:find("timed out", 1, true))
        assert.are.equal(HttpClient.CONNECT_TIMEOUT, now - started)
        assert.is_true(connections[1].closed)
    end)

    it("fails at once while a server that did not answer counts as unreachable", function()
        next_options = { { hang_connect = true } }
        scripts = { { response(200, {}, "two") } }

        get("http://grimmory.local/a")
        local started = now
        local ok, message = get("http://grimmory.local/b")

        assert.is_nil(ok)
        assert.truthy(message:find("not reachable", 1, true))
        assert.are.equal(started, now)
        assert.are.equal(1, #connections)

        -- Later, or once forgotten, it is tried again
        HttpClient.forgetUnreachable()
        assert.are.same({ 1, 200, "two" }, { get("http://grimmory.local/b") })
    end)

    it("tries an unreachable server again after a while", function()
        next_options = { { hang_connect = true } }
        scripts = { { response(200, {}, "two") } }

        get("http://grimmory.local/a")
        now = now + HttpClient.UNREACHABLE_SECONDS + 1

        assert.are.same({ 1, 200, "two" }, { get("http://grimmory.local/b") })
    end)

    it("gives up reading after the read timeout, without sending again", function()
        scripts = { { response(200, {}, "one") } }

        get("http://grimmory.local/a")
        -- From now on the server does not answer
        connections[1].hang_read = true

        local started = now
        local body = {}
        local ok, message = HttpClient.request({
            url = "http://grimmory.local/b",
            sink = package.loaded["ltn12"].sink.table(body),
            read_timeout = 7,
        })

        assert.is_nil(ok)
        assert.truthy(message:find("timeout", 1, true))
        assert.are.equal(7, now - started)
        -- Not sent again on a new connection: that would only wait as long again
        assert.are.equal(1, #connections)
    end)

    it("waits cooperatively inside a registered coroutine, and can be given up", function()
        next_options = { { hang_connect = true } }
        local sleeps = 0
        local result
        local co = coroutine.create(function()
            result = { get("http://grimmory.local/a") }
        end)
        HttpClient.setContext(co, {
            sleep = function(seconds)
                sleeps = sleeps + 1
                now = now + seconds
                coroutine.yield()
                -- Given up after three steps
                return sleeps < 3
            end,
        })

        for _ = 1, 3 do
            assert.is_true(coroutine.resume(co))
            assert.are.equal("suspended", coroutine.status(co))
        end
        assert.is_true(coroutine.resume(co))

        assert.are.equal("dead", coroutine.status(co))
        assert.are.equal(3, sleeps)
        assert.are.same({ nil, "cancelled" }, { result[1], result[2] })
        assert.is_true(connections[1].closed)
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

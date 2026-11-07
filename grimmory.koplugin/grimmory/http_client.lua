--[[
HTTP/1.1 requests that keep the connection open for the next request, with
short timeouts, and without blocking KOReader when run cooperatively.

LuaSocket's http.request opens a new connection for every request (DNS
lookup, TCP connect and TLS handshake: 3-5 round trips before the request
is even sent).  Over the Internet, that dominates loading many small things
like covers.  Here an idle connection to the same server is reused instead.

- HTTPS is checked like grimmory/tls.lua (chain and host name).
- Connecting (TCP and TLS) gives up after CONNECT_TIMEOUT seconds, reading
  after `read_timeout` seconds without any data.  LuaSocket waits 60 s for
  each, and a server behind a firewall that drops packets (e.g. a CrowdSec
  ban) never answers.
- After connecting to a server timed out, it counts as unreachable for
  UNREACHABLE_SECONDS: requests to it fail at once instead of each waiting
  again.  A successful request or HttpClient.forgetUnreachable() (WiFi
  reconnected, the user retries) ends this.
- A reused connection the server has closed meanwhile is noticed before any
  response arrived: the request is then sent once more on a new connection.
- Connections idle for longer than IDLE_SECONDS are not reused (servers and
  proxies close them).
- Subprocesses (forked) must not use their parent's connections (both would
  talk over the same socket): call HttpClient.forgetConnections() first.
- Redirects are followed (GET / HEAD) only to the same server, so the
  login and custom headers never go anywhere else.
- With a proxy configured in KOReader, LuaSocket is used as before.

The sockets never block: waiting is done with socket.select, or, inside a
coroutine registered with HttpClient.setContext (see grimmory/cooperative.lua),
by sleeping in small steps through the context, so KOReader keeps running.
Only looking up the server's name (DNS) still blocks.

    HttpClient.request({ url, method, headers, body, sink, verify, read_timeout })
        -> 1, code, headers, status  or  nil, error
--]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local url_util = require("socket.url")

local GrimmoryLogger = require("grimmory/logger")
local Tls = require("grimmory/tls")

local logger = GrimmoryLogger:new()

local HttpClient = {}

local IDLE_SECONDS = 30
local MAX_REDIRECTS = 5
local BLOCK = 16 * 1024
local MAX_LINE = 64 * 1024

-- Connecting: TCP (per address of the server) and the TLS handshake
HttpClient.CONNECT_TIMEOUT = 10
-- All addresses together (e.g. IPv6, then IPv4)
local CONNECT_TOTAL_TIMEOUT = 15
-- How long a server counts as unreachable after connecting timed out
HttpClient.UNREACHABLE_SECONDS = 30
-- Steps in which a cooperative request checks its socket
local POLL_SECONDS = 0.02

HttpClient.ERROR_CANCELLED = "cancelled"

-- "scheme://host:port" -> { conn, last_used }
local idle_connections = {}
-- "scheme://host:port" -> { until_time, reason }
local unreachable = {}
-- coroutine -> { sleep = function(seconds): boolean, read_timeout = number|nil }
local contexts = setmetatable({}, { __mode = "k" })

local function defaultReadTimeout()
    return http.TIMEOUT or 60
end

local function currentContext()
    local co = coroutine.running()
    return co and contexts[co] or nil
end

--- Run the requests made by coroutine `co` cooperatively: instead of
--- blocking, they call `context.sleep(seconds)`, which yields and returns
--- false once the request is to be given up (cancelled).
---@param co thread
---@param context table | nil { sleep = function, read_timeout = number | nil }; nil to unregister
function HttpClient.setContext(co, context)
    contexts[co] = context
end

--- Drop the connections without closing them: in a forked subprocess they
--- still belong to the parent process (as do the cooperative coroutines).
function HttpClient.forgetConnections()
    idle_connections = {}
    contexts = setmetatable({}, { __mode = "k" })
end

--- Close all idle connections (e.g. before WiFi is turned off).
function HttpClient.closeConnections()
    for _, idle in pairs(idle_connections) do
        pcall(idle.conn.sock.close, idle.conn.sock)
    end
    idle_connections = {}
end

--- Try unreachable servers again (WiFi reconnected, the user retries).
function HttpClient.forgetUnreachable()
    unreachable = {}
end

--- Whether an error means connecting timed out (the server did not answer).
function HttpClient.isTimeout(message)
    local text = tostring(message or ""):lower()
    return text:find("timeout", 1, true) ~= nil or text:find("timed out", 1, true) ~= nil
end

-------------------------------------------------------------------------------
-- Waiting without blocking
-------------------------------------------------------------------------------

--- Wait until `sock` is readable ("r") or writable ("w"), at most until
--- `deadline`.
---@return boolean | nil ready
---@return string | nil error "timeout" or ERROR_CANCELLED
local function waitFor(sock, mode, deadline)
    local readers = mode == "r" and { sock } or nil
    local writers = mode == "w" and { sock } or nil
    local context = currentContext()

    while true do
        local remaining = deadline - socket.gettime()
        if context then
            local readable, writable = socket.select(readers, writers, 0)
            if (readable and #readable > 0) or (writable and #writable > 0) then
                return true
            end
            if remaining <= 0 then
                return nil, "timeout"
            end
            if not context.sleep(math.min(POLL_SECONDS, remaining)) then
                return nil, HttpClient.ERROR_CANCELLED
            end
        else
            if remaining <= 0 then
                return nil, "timeout"
            end
            local readable, writable = socket.select(readers, writers, remaining)
            if (readable and #readable > 0) or (writable and #writable > 0) then
                return true
            end
        end
    end
end

--- What a non-blocking socket operation wants before it can go on.
local function wantsWait(err)
    if err == "timeout" or err == "wantread" then
        return "r"
    elseif err == "wantwrite" then
        return "w"
    end
    return nil
end

--- A connection: the socket and what was received but not read yet.
local function newConnection(sock)
    return { sock = sock, buffer = "", eof = false }
end

--- Receive more data into conn.buffer.
---@return boolean | nil ok
---@return string | nil error
local function fill(conn, timeout)
    if conn.eof then
        return nil, "closed"
    end
    local deadline = socket.gettime() + timeout
    while true do
        local data, err, partial = conn.sock:receive(BLOCK)
        data = data or partial
        if data and #data > 0 then
            conn.buffer = conn.buffer .. data
            if err == "closed" then
                conn.eof = true
            end
            return true
        end
        local mode = wantsWait(err)
        if not mode then
            return nil, err or "closed"
        end
        -- "timeout" from a socket that never blocks: nothing there yet
        local ready, wait_error = waitFor(conn.sock, err == "wantwrite" and "w" or "r", deadline)
        if not ready then
            return nil, wait_error
        end
    end
end

local function receiveLine(conn, timeout)
    while true do
        local line_end = conn.buffer:find("\n", 1, true)
        if line_end then
            local line = conn.buffer:sub(1, line_end - 1):gsub("\r$", "")
            conn.buffer = conn.buffer:sub(line_end + 1)
            return line
        end
        if #conn.buffer > MAX_LINE then
            return nil, "line too long"
        end
        local ok, err = fill(conn, timeout)
        if not ok then
            return nil, err
        end
    end
end

local function sendAll(conn, data, timeout)
    local deadline = socket.gettime() + timeout
    local index = 1
    while index <= #data do
        local last, err, partial_last = conn.sock:send(data, index)
        if last then
            index = last + 1
        else
            if partial_last and partial_last >= index then
                index = partial_last + 1
            end
            local mode = wantsWait(err)
            if not mode then
                return nil, err
            end
            local ready, wait_error = waitFor(conn.sock, err == "wantread" and "r" or "w", deadline)
            if not ready then
                return nil, wait_error
            end
        end
    end
    return true
end

-------------------------------------------------------------------------------
-- Connecting
-------------------------------------------------------------------------------

--- The server's addresses: { { family, addr } }, or the host itself when it
--- cannot be looked up here (LuaSocket then looks it up when connecting).
local function addresses(host)
    if socket.dns and socket.dns.getaddrinfo and socket.tcp4 then
        local found, lookup_error = socket.dns.getaddrinfo(host)
        if not found then
            return nil, lookup_error
        end
        local list = {}
        for _, address in ipairs(found) do
            if address.family == "inet" or address.family == "inet6" then
                table.insert(list, address)
            end
        end
        if #list > 0 then
            return list
        end
    end
    return { { family = nil, addr = host } }
end

local function newSocket(family)
    if family == "inet6" and socket.tcp6 then
        return socket.tcp6()
    elseif family == "inet" and socket.tcp4 then
        return socket.tcp4()
    end
    return socket.tcp()
end

--- TCP connection to one address, without blocking.
local function connectAddress(address, port, deadline)
    local sock, create_error = newSocket(address.family)
    if not sock then
        return nil, create_error
    end
    sock:settimeout(0)

    local ok, err = sock:connect(address.addr, port)
    if ok then
        return sock
    end
    if err ~= "timeout" then
        sock:close()
        return nil, err
    end

    -- In progress: connected once writable
    local ready, wait_error = waitFor(sock, "w", deadline)
    if not ready then
        sock:close()
        return nil, wait_error == "timeout" and "connection timed out" or wait_error
    end
    if sock:getpeername() then
        return sock
    end
    -- Failed: connecting again tells why (e.g. "connection refused")
    local _, reason = sock:connect(address.addr, port)
    sock:close()
    return nil, reason or "connection failed"
end

local function tlsHandshake(sock, host, verify)
    local ssl = require("ssl")
    local params = {
        mode = "client",
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
        verify = "none",
    }
    if verify then
        local cafile = Tls.findCaFile()
        if not cafile then
            sock:close()
            return nil, "no CA certificates found to verify the server's certificate"
        end
        params.verify = { "peer", "fail_if_no_peer_cert" }
        params.cafile = cafile
    end

    local tls_sock, wrap_error = ssl.wrap(sock, params)
    if not tls_sock then
        sock:close()
        return nil, wrap_error
    end
    tls_sock:sni(host)
    tls_sock:settimeout(0)

    local deadline = socket.gettime() + HttpClient.CONNECT_TIMEOUT
    while true do
        local ok, err = tls_sock:dohandshake()
        if ok then
            break
        end
        local mode = wantsWait(err)
        if not mode then
            tls_sock:close()
            return nil, err
        end
        local ready, wait_error = waitFor(tls_sock, err == "wantwrite" and "w" or "r", deadline)
        if not ready then
            tls_sock:close()
            return nil, wait_error == "timeout" and "TLS handshake timed out" or wait_error
        end
    end

    if verify then
        local cert = tls_sock:getpeercertificate()
        if not (cert and Tls.certificateMatches(cert, host)) then
            tls_sock:close()
            return nil, "certificate does not match host " .. tostring(host)
        end
    end
    return tls_sock
end

local function connect(scheme, host, port, verify)
    local started = socket.gettime()
    local list, lookup_error = addresses(host)
    if not list then
        return nil, lookup_error
    end
    local looked_up = socket.gettime()

    local total_deadline = looked_up + CONNECT_TOTAL_TIMEOUT
    local sock, connect_error
    for _, address in ipairs(list) do
        local deadline = math.min(socket.gettime() + HttpClient.CONNECT_TIMEOUT, total_deadline)
        sock, connect_error = connectAddress(address, port, deadline)
        if sock or connect_error == HttpClient.ERROR_CANCELLED or socket.gettime() >= total_deadline then
            break
        end
    end
    if not sock then
        return nil, connect_error
    end
    local connected_at = socket.gettime()

    if scheme == "https" then
        local tls_error
        sock, tls_error = tlsHandshake(sock, host, verify)
        if not sock then
            return nil, tls_error
        end
    end

    logger:info(string.format(
        "Connection timing: %s looked up in %.2f s, connected in %.2f s%s",
        host, looked_up - started, connected_at - looked_up,
        scheme == "https" and string.format(", TLS in %.2f s", socket.gettime() - connected_at) or ""))
    return newConnection(sock)
end

--- A connection to the server: an idle one if there is one, else a new one.
---@return table | nil conn
---@return boolean | string reused, or the error
local function getConnection(key, scheme, host, port, verify)
    local idle = idle_connections[key]
    idle_connections[key] = nil
    if idle then
        if socket.gettime() - idle.last_used <= IDLE_SECONDS then
            return idle.conn, true
        end
        pcall(idle.conn.sock.close, idle.conn.sock)
    end

    local blocked = unreachable[key]
    if blocked then
        if socket.gettime() < blocked.until_time then
            return nil, blocked.reason
        end
        unreachable[key] = nil
    end

    local conn, connect_error = connect(scheme, host, port, verify)
    if not conn then
        if HttpClient.isTimeout(connect_error) then
            unreachable[key] = {
                until_time = socket.gettime() + HttpClient.UNREACHABLE_SECONDS,
                reason = connect_error .. " (server not reachable)",
            }
        end
        return nil, connect_error
    end
    return conn, false
end

-------------------------------------------------------------------------------
-- Requests
-------------------------------------------------------------------------------

local function readHeaders(conn, timeout)
    local headers = {}
    local name
    while true do
        local line, receive_error = receiveLine(conn, timeout)
        if not line then
            return nil, receive_error
        end
        if line == "" then
            return headers
        end
        local continuation = line:match("^%s+(.*)$")
        if continuation and name then
            headers[name] = headers[name] .. " " .. continuation
        else
            local key, value = line:match("^([^:]+):%s*(.-)%s*$")
            if not key then
                return nil, "malformed header line: " .. line
            end
            name = key:lower()
            headers[name] = headers[name] and (headers[name] .. ", " .. value) or value
        end
    end
end

--- Pass `length` bytes (or, with nil, everything until the server closes)
--- to the sink.
local function readBody(conn, length, sink, timeout)
    local remaining = length
    while remaining == nil or remaining > 0 do
        if #conn.buffer == 0 then
            local ok, receive_error = fill(conn, timeout)
            if not ok then
                if remaining == nil and receive_error == "closed" then
                    break
                end
                return nil, receive_error
            end
        end
        local take = remaining and math.min(remaining, #conn.buffer) or #conn.buffer
        local chunk = conn.buffer:sub(1, take)
        conn.buffer = conn.buffer:sub(take + 1)
        local sink_ok, sink_error = sink(chunk)
        if not sink_ok then
            return nil, sink_error
        end
        if remaining then
            remaining = remaining - take
        end
    end
    return 1
end

local function readChunkedBody(conn, sink, timeout)
    while true do
        local line, receive_error = receiveLine(conn, timeout)
        if not line then
            return nil, receive_error
        end
        local size = tonumber(line:match("^%s*(%x+)"), 16)
        if not size then
            return nil, "malformed chunk size: " .. line
        end
        if size == 0 then
            -- Trailers, until an empty line
            local _, trailer_error = readHeaders(conn, timeout)
            if trailer_error then
                return nil, trailer_error
            end
            return 1
        end
        local body_ok, body_error = readBody(conn, size, sink, timeout)
        if not body_ok then
            return nil, body_error
        end
        local _, crlf_error = receiveLine(conn, timeout)
        if crlf_error then
            return nil, crlf_error
        end
    end
end

local function isRedirect(method, code, headers)
    return (method == "GET" or method == "HEAD") and headers["location"] ~= nil
        and (code == 301 or code == 302 or code == 303 or code == 307 or code == 308)
end

--- One request on one connection.  The body of a redirect is dropped (it
--- must not end up in a download).
---@return table | nil response { code, status, headers, reusable }
---@return string | nil error
---@return boolean | nil before_response The error happened before any response byte (safe to repeat)
local function exchange(conn, method, target, headers, body, sink, timeout)
    local lines = { string.format("%s %s HTTP/1.1", method, target) }
    for name, value in pairs(headers) do
        table.insert(lines, name .. ": " .. tostring(value))
    end
    table.insert(lines, "")
    table.insert(lines, "")
    local request = table.concat(lines, "\r\n") .. (body or "")

    local sent, send_error = sendAll(conn, request, timeout)
    if not sent then
        return nil, send_error, true
    end

    local status, version, code, response_headers
    local first_line = true
    repeat
        local status_error
        status, status_error = receiveLine(conn, timeout)
        if not status then
            return nil, status_error, first_line and #conn.buffer == 0
        end
        first_line = false
        version, code = status:match("^HTTP/(%d%.%d) (%d%d%d)")
        code = tonumber(code)
        if not code then
            return nil, "malformed status line: " .. status
        end

        local headers_error
        response_headers, headers_error = readHeaders(conn, timeout)
        if not response_headers then
            return nil, headers_error
        end
    -- 1xx (e.g. 100 Continue): no body, the real answer follows
    until code >= 200

    if isRedirect(method, code, response_headers) then
        sink = ltn12.sink.null()
    end

    local connection_header = (response_headers["connection"] or ""):lower()
    local reusable = version == "1.1" and not connection_header:find("close", 1, true)

    local has_body = method ~= "HEAD" and code ~= 204 and code ~= 304
    if has_body then
        local transfer_encoding = (response_headers["transfer-encoding"] or ""):lower()
        local length = tonumber(response_headers["content-length"])
        local body_ok, body_error
        if transfer_encoding ~= "" and transfer_encoding ~= "identity" then
            body_ok, body_error = readChunkedBody(conn, sink, timeout)
        elseif length then
            body_ok, body_error = readBody(conn, length, sink, timeout)
        else
            -- Until the server closes the connection
            reusable = false
            body_ok, body_error = readBody(conn, nil, sink, timeout)
        end
        if not body_ok then
            return nil, body_error
        end
    end
    sink(nil)

    -- Left-over bytes would be read as the next response
    if #conn.buffer > 0 or conn.eof then
        reusable = false
    end

    return { code = code, status = status, headers = response_headers, reusable = reusable }
end

local function sameServer(a, b)
    return a.scheme == b.scheme and a.host == b.host and a.port == b.port
end

local function parseUrl(url)
    local parsed = url_util.parse(url)
    if not parsed or not parsed.host or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        return nil
    end
    parsed.host = parsed.host:lower()
    parsed.port = tonumber(parsed.port) or (parsed.scheme == "https" and 443 or 80)
    parsed.target = (parsed.path and parsed.path ~= "" and parsed.path or "/")
        .. (parsed.params and (";" .. parsed.params) or "")
        .. (parsed.query and ("?" .. parsed.query) or "")
    return parsed
end

--- Like LuaSocket's http.request(table), keeping the connection open.
---@param reqt table url, method, headers, body (string), sink, verify (HTTPS certificate check),
---  read_timeout (seconds without data; default: LuaSocket's, or the cooperative context's)
function HttpClient.request(reqt)
    if http.PROXY or reqt.proxy then
        -- As before (LuaSocket), with the request body as a source
        return Tls.request({
            url = reqt.url,
            method = reqt.method,
            headers = reqt.headers,
            source = reqt.body and ltn12.source.string(reqt.body) or nil,
            sink = reqt.sink,
        }, reqt.verify)
    end

    local method = reqt.method or "GET"
    local sink = reqt.sink or ltn12.sink.null()
    local url = reqt.url
    local first = parseUrl(url)
    if not first then
        return nil, "unsupported url: " .. tostring(url)
    end
    local context = currentContext()
    local timeout = reqt.read_timeout or (context and context.read_timeout) or defaultReadTimeout()

    for _ = 0, MAX_REDIRECTS do
        local target = parseUrl(url)
        if not target or not sameServer(first, target) then
            return nil, "redirect to another server not followed: " .. tostring(url)
        end

        local key = target.scheme .. "://" .. target.host .. ":" .. target.port
        local headers = {}
        for name, value in pairs(reqt.headers or {}) do
            headers[name] = value
        end
        local default_port = (target.scheme == "https" and 443 or 80)
        headers["Host"] = target.port == default_port and target.host or (target.host .. ":" .. target.port)
        headers["Connection"] = "keep-alive"
        if reqt.body then
            headers["Content-Length"] = #reqt.body
        end

        local response, response_error
        -- A reused connection may have been closed by the server meanwhile
        for attempt = 1, 2 do
            local conn, reused = getConnection(key, target.scheme, target.host, target.port, reqt.verify)
            if not conn then
                local message = reused
                return nil, Tls.describeError(message) or message
            end

            local before_response
            response, response_error, before_response = exchange(
                conn, method, target.target, headers, reqt.body, sink, timeout)

            if response and response.reusable then
                -- Two requests at the same time (cooperative) each had a
                -- connection: keep one
                local previous = idle_connections[key]
                if previous then
                    pcall(previous.conn.sock.close, previous.conn.sock)
                end
                idle_connections[key] = { conn = conn, last_used = socket.gettime() }
            else
                pcall(conn.sock.close, conn.sock)
            end

            if response then
                unreachable[key] = nil
            end

            -- Closed meanwhile: try again.  Not after a timeout (the server
            -- or the network does not answer: waiting again would not help)
            -- or when the request was given up.
            local retry = not response and reused and before_response and attempt == 1
                and not HttpClient.isTimeout(response_error) and response_error ~= HttpClient.ERROR_CANCELLED
            if not retry then
                break
            end
        end

        if not response then
            return nil, response_error
        end

        if not isRedirect(method, response.code, response.headers) then
            return 1, response.code, response.headers, response.status
        end
        url = url_util.absolute(url, response.headers["location"])
    end

    return nil, "too many redirects"
end

return HttpClient

--[[
HTTP/1.1 requests that keep the connection open for the next request.

LuaSocket's http.request opens a new connection for every request (DNS
lookup, TCP connect and TLS handshake: 3-5 round trips before the request
is even sent).  Over the Internet, that dominates loading many small things
like covers.  Here an idle connection to the same server is reused instead.

- HTTPS is checked like grimmory/tls.lua (chain and host name).
- A reused connection the server has closed meanwhile is noticed before any
  response arrived: the request is then sent once more on a new connection.
- Connections idle for longer than IDLE_SECONDS are not reused (servers and
  proxies close them).
- Subprocesses (forked) must not use their parent's connections (both would
  talk over the same socket): call HttpClient.forgetConnections() first.
- Redirects are followed (GET / HEAD) only to the same server, so the
  login and custom headers never go anywhere else.
- With a proxy configured in KOReader, LuaSocket is used as before.

    HttpClient.request({ url, method, headers, body, sink, verify })
        -> 1, code, headers, status  or  nil, error
--]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local url_util = require("socket.url")

local Tls = require("grimmory/tls")

local HttpClient = {}

local IDLE_SECONDS = 30
local MAX_REDIRECTS = 5
local BLOCK = 16 * 1024

-- "scheme://host:port" -> { sock, last_used }
local idle_connections = {}

local function timeout()
    return http.TIMEOUT or 60
end

--- Drop the connections without closing them: in a forked subprocess they
--- still belong to the parent process.
function HttpClient.forgetConnections()
    idle_connections = {}
end

--- Close all idle connections (e.g. before WiFi is turned off).
function HttpClient.closeConnections()
    for _, connection in pairs(idle_connections) do
        pcall(connection.sock.close, connection.sock)
    end
    idle_connections = {}
end

local function connect(scheme, host, port, verify)
    local sock = socket.tcp()
    sock:settimeout(timeout())
    local ok, connect_error = sock:connect(host, port)
    if not ok then
        sock:close()
        return nil, connect_error
    end

    if scheme ~= "https" then
        return sock
    end

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
    tls_sock:settimeout(timeout())

    local handshake_ok, handshake_error = tls_sock:dohandshake()
    if not handshake_ok then
        tls_sock:close()
        return nil, handshake_error
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

--- A connection to the server: an idle one if there is one, else a new one.
---@return table | nil sock
---@return boolean | string reused, or the error
local function getConnection(key, scheme, host, port, verify)
    local idle = idle_connections[key]
    idle_connections[key] = nil
    if idle then
        if socket.gettime() - idle.last_used <= IDLE_SECONDS then
            return idle.sock, true
        end
        pcall(idle.sock.close, idle.sock)
    end

    local sock, connect_error = connect(scheme, host, port, verify)
    if not sock then
        return nil, connect_error
    end
    return sock, false
end

local function readHeaders(sock)
    local headers = {}
    local name
    while true do
        local line, receive_error = sock:receive("*l")
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
local function readBody(sock, length, sink)
    local remaining = length
    while remaining == nil or remaining > 0 do
        local size = remaining and math.min(BLOCK, remaining) or BLOCK
        local chunk, receive_error, partial = sock:receive(size)
        chunk = chunk or partial
        if chunk and #chunk > 0 then
            local sink_ok, sink_error = sink(chunk)
            if not sink_ok then
                return nil, sink_error
            end
            if remaining then
                remaining = remaining - #chunk
            end
        end
        if receive_error then
            if remaining == nil and receive_error == "closed" then
                break
            end
            return nil, receive_error
        end
    end
    return 1
end

local function readChunkedBody(sock, sink)
    while true do
        local line, receive_error = sock:receive("*l")
        if not line then
            return nil, receive_error
        end
        local size = tonumber(line:match("^%s*(%x+)"), 16)
        if not size then
            return nil, "malformed chunk size: " .. line
        end
        if size == 0 then
            -- Trailers, until an empty line
            local _, trailer_error = readHeaders(sock)
            if trailer_error then
                return nil, trailer_error
            end
            return 1
        end
        local body_ok, body_error = readBody(sock, size, sink)
        if not body_ok then
            return nil, body_error
        end
        local _, crlf_error = sock:receive("*l")
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
local function exchange(sock, method, target, headers, body, sink)
    local lines = { string.format("%s %s HTTP/1.1", method, target) }
    for name, value in pairs(headers) do
        table.insert(lines, name .. ": " .. tostring(value))
    end
    table.insert(lines, "")
    table.insert(lines, "")
    local request = table.concat(lines, "\r\n") .. (body or "")

    local sent, send_error = sock:send(request)
    if not sent then
        return nil, send_error, true
    end

    local status, version, code, response_headers
    local first_line = true
    repeat
        local status_error
        status, status_error = sock:receive("*l")
        if not status then
            return nil, status_error, first_line
        end
        first_line = false
        version, code = status:match("^HTTP/(%d%.%d) (%d%d%d)")
        code = tonumber(code)
        if not code then
            return nil, "malformed status line: " .. status
        end

        local headers_error
        response_headers, headers_error = readHeaders(sock)
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
            body_ok, body_error = readChunkedBody(sock, sink)
        elseif length then
            body_ok, body_error = readBody(sock, length, sink)
        else
            -- Until the server closes the connection
            reusable = false
            body_ok, body_error = readBody(sock, nil, sink)
        end
        if not body_ok then
            return nil, body_error
        end
    end
    sink(nil)

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
---@param reqt table url, method, headers, body (string), sink, verify (HTTPS certificate check)
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
            local sock, reused = getConnection(key, target.scheme, target.host, target.port, reqt.verify)
            if not sock then
                local message = reused
                return nil, Tls.describeError(message) or message
            end

            local before_response
            response, response_error, before_response = exchange(sock, method, target.target, headers, reqt.body, sink)

            if response and response.reusable then
                idle_connections[key] = { sock = sock, last_used = socket.gettime() }
            else
                pcall(sock.close, sock)
            end

            if response or not (reused and before_response) or attempt == 2 then
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

--[[
HTTPS requests that check the server's certificate.

KOReader's HTTPS client (LuaSec) accepts any certificate by default
(`verify = "none"`), and LuaSec never checks that a certificate belongs to
the host it connects to.  Here both are checked: the certificate chain
against the CA certificates KOReader ships (data/ca-bundle.crt, the same
list as Mozilla's, with Let's Encrypt), and the host name against the
certificate's names.  A failed check ends the connection before anything
(login, headers) is sent.
--]]

local http = require("socket.http")
local https = require("ssl.https")
local socket = require("socket")

local Tls = {}

local VERIFY = { "peer", "fail_if_no_peer_cert" }

-- First found is used: KOReader's own bundle, then the system's
local function caCandidates()
    local candidates = { "data/ca-bundle.crt" }
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage and DataStorage.getDataDir then
        local data_dir_ok, data_dir = pcall(DataStorage.getDataDir, DataStorage)
        if data_dir_ok and data_dir then
            table.insert(candidates, data_dir .. "/data/ca-bundle.crt")
        end
    end
    table.insert(candidates, "/etc/ssl/certs/ca-certificates.crt")
    table.insert(candidates, "/etc/ssl/cert.pem")
    return candidates
end

local ca_file -- nil: not looked up yet; false: none found

--- Path of the CA certificates, or nil when there are none.
function Tls.findCaFile()
    if ca_file == nil then
        ca_file = false
        for _, path in ipairs(caCandidates()) do
            local file = io.open(path, "r")
            if file then
                file:close()
                ca_file = path
                break
            end
        end
    end
    return ca_file or nil
end

local function normalize(name)
    return (tostring(name):lower():gsub("%.$", ""))
end

--- Whether a certificate name (possibly "*.example.com") covers `host`.
--- A wildcard stands for exactly one leftmost label, and needs at least two
--- labels after it ("*.com" covers nothing).
function Tls.nameMatches(pattern, host)
    pattern, host = normalize(pattern), normalize(host)
    if pattern == host then
        return true
    end

    local suffix = pattern:match("^%*%.(.+)$")
    if not suffix or suffix:find("*", 1, true) or not suffix:find(".", 1, true) then
        return false
    end
    local host_suffix = host:match("^[^.]+%.(.+)$")
    return host_suffix ~= nil and host_suffix == suffix
end

local function isIpAddress(host)
    return host:match("^%d+%.%d+%.%d+%.%d+$") ~= nil or host:find(":", 1, true) ~= nil
end

--- Whether a LuaSec certificate belongs to `host`: its DNS names (or IP
--- addresses), or its common name when it has no DNS names.
function Tls.certificateMatches(cert, host)
    local extensions_ok, extensions = pcall(cert.extensions, cert)
    local alt_names = extensions_ok and extensions and extensions["2.5.29.17"] or {}

    if isIpAddress(host) then
        for _, address in ipairs(alt_names.iPAddress or {}) do
            if normalize(address) == normalize(host) then
                return true
            end
        end
        return false
    end

    local dns_names = alt_names.dNSName or {}
    for _, name in ipairs(dns_names) do
        if Tls.nameMatches(name, host) then
            return true
        end
    end

    if #dns_names == 0 then
        local subject_ok, subject = pcall(cert.subject, cert)
        for _, entry in ipairs(subject_ok and subject or {}) do
            if entry.name == "commonName" and Tls.nameMatches(entry.value, host) then
                return true
            end
        end
    end

    return false
end

--- LuaSocket `create` function: LuaSec's TLS connection, plus the host name
--- check right after the handshake (it checks the chain itself).  The host
--- is the one actually connected to, so redirects are checked too.
function Tls.create(params)
    local tcp = https.tcp(params)
    return function()
        local conn = tcp()
        local connect = conn.connect
        function conn:connect(host, port)
            connect(self, host, port)
            local cert = self.sock:getpeercertificate()
            if not (cert and Tls.certificateMatches(cert, host)) then
                pcall(self.sock.close, self.sock)
                -- Raised like LuaSocket's own errors: http.request returns it
                socket.try(nil, "certificate does not match host " .. tostring(host))
            end
            return 1
        end
        return conn
    end
end

--- Explain a failed check (e.g. for a notice), or nil for other errors.
function Tls.describeError(message)
    message = tostring(message or "")
    if message:find("certificate", 1, true) then
        return "The server's HTTPS certificate could not be verified (" .. message .. "). " ..
            "Check the device's date and time, and that the server uses a valid certificate."
    end
    return nil
end

--- Like LuaSec's https.request(table), checking the certificate when
--- `verify` is set; plain http:// requests are passed to LuaSocket.
---@return any, any, any, any The results of http.request
function Tls.request(reqt, verify)
    if not reqt.url:match("^https:") then
        return http.request(reqt)
    end
    if not verify then
        return https.request(reqt)
    end

    if http.PROXY or reqt.proxy then
        -- As LuaSec: a proxy would get the TLS connection
        return nil, "proxy not supported"
    end

    local cafile = Tls.findCaFile()
    if not cafile then
        return nil, "no CA certificates found to verify the server's certificate"
    end

    reqt.create = Tls.create({ verify = VERIFY, cafile = cafile })
    local result, code, headers, status = http.request(reqt)
    if result == nil then
        code = Tls.describeError(code) or code
    end
    return result, code, headers, status
end

return Tls

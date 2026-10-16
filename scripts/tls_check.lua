-- tls_check.lua
-- Prints what Lunar's TLS stack negotiates with a server.
--
-- A request that succeeds proves little after an OpenSSL rebuild: a handshake that
-- quietly fell back to TLS 1.2 or a weaker cipher still returns 200. This shows the
-- negotiated protocol and cipher for the default client config, forced TLS 1.3 and
-- forced TLS 1.2, and checks the certificate against the bundled CA list.
--
-- Run from the repo root, after a build:
--   build\win\bin\LunarExtensionHostCLI.exe scripts\tls_check.lua <host> [port]

local lfs = require("lfs")
local repo = os.getenv("LUNAR_REPO") or lfs.currentdir()

local LS  = repo .. "\\vendor\\luasocket\\src\\"
local SEC = repo .. "\\vendor\\luasec\\src\\"
local function pre(name, file) package.preload[name] = assert(loadfile(file)) end
pre("socket", LS .. "socket.lua")
pre("ssl",    SEC .. "ssl.lua")

local socket = require("socket")
local ssl    = require("ssl")

local args = arg or {}
local HOST, PORT = args[1], tonumber(args[2] or 443)
if not HOST or not PORT then
	print("usage: LunarExtensionHostCLI.exe scripts\\tls_check.lua <host> [port]")
	os.exit(2)
end
local CAFILE = repo .. "\\vendor\\certs\\cacert.pem"

local function probe(name, params)
	io.write(string.format("\n[%s]\n", name))
	local sock = assert(socket.tcp())
	sock:settimeout(15)
	local ok, err = sock:connect(HOST, PORT)
	if not ok then print("  connect failed: " .. tostring(err)); return false end

	local conn, werr = ssl.wrap(sock, params)
	if not conn then print("  wrap failed: " .. tostring(werr)); sock:close(); return false end
	conn:settimeout(15)
	conn:sni(HOST)

	local hok, herr = conn:dohandshake()
	if not hok then print("  handshake failed: " .. tostring(herr)); conn:close(); return false end

	local info = conn:info()
	print(string.format("  protocol   : %s", tostring(info.protocol)))
	print(string.format("  cipher     : %s", tostring(info.cipher)))
	print(string.format("  bits       : %s", tostring(info.bits)))
	local cert = conn:getpeercertificate()
	if cert then
		local subj = cert:subject()
		print(string.format("  peer cert  : %s", tostring(subj and subj[1] and subj[1].value or "?")))
	end
	conn:close()
	return true
end

print("=== TLS against " .. HOST .. ":" .. PORT .. " ===")

local ok = probe("default client config, verified against vendor\\certs\\cacert.pem", {
	mode = "client", protocol = "any", options = { "all" },
	verify = "peer", cafile = CAFILE,
})
-- TLS 1.3 must still be reachable: a build that lost it falls back to 1.2 and every
-- functional test still passes.
local ok13 = probe("forced TLS 1.3", { mode = "client", protocol = "tlsv1_3", verify = "none" })
-- Reported, not fatal: a server may refuse TLS 1.2.
local ok12 = probe("forced TLS 1.2", { mode = "client", protocol = "tlsv1_2", verify = "none" })

print(string.format("\ndefault=%s  tls1.3=%s  tls1.2=%s", tostring(ok), tostring(ok13), tostring(ok12)))
os.exit((ok and ok13) and 0 or 1)

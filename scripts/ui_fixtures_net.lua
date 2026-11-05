-- scripts/ui_fixtures_net.lua -- sample data for the iLO Redfish and Black Duck pages, for
-- scripts/ui_fixtures.lua. Same rules as that file: dev builds only, never packaged, and
-- everything here is made up. Addresses come from the documentation range (RFC 5737) and
-- host names from example.test.
--
-- The Server and Review pages run for real against a canned server: the fixture stands in
-- for the host's HTTP and secrets, so what's on screen is what those pages really draw.
local cjson = require("cjson")
local M = {}

local SYSTEM = [[{"@odata.context":"/redfish/v1/$metadata#ComputerSystem.ComputerSystem","@odata.id":"/redfish/v1/Systems/1/","@odata.type":"#ComputerSystem.v1_17_0.ComputerSystem","Id":"1","Name":"Computer System","HostName":"bench-07.example.test","Manufacturer":"Example Corp","Model":"Example DL380 Gen11","SerialNumber":"EXAMPLE0042","SKU":"P00000-B21","PowerState":"On","BiosVersion":"U54 v2.10 (08/14/2026)","IndicatorLED":"Off","MemorySummary":{"TotalSystemMemoryGiB":512,"Status":{"HealthRollup":"OK"}},"ProcessorSummary":{"Count":2,"Model":"Example Xeon 6430","Status":{"HealthRollup":"OK"}},"Status":{"Health":"OK","State":"Enabled"},"Boot":{"BootSourceOverrideEnabled":"Disabled","BootSourceOverrideTarget":"None"},"Bios":{"@odata.id":"/redfish/v1/Systems/1/Bios/"},"EthernetInterfaces":{"@odata.id":"/redfish/v1/Systems/1/EthernetInterfaces/"},"LogServices":{"@odata.id":"/redfish/v1/Systems/1/LogServices/"},"Memory":{"@odata.id":"/redfish/v1/Systems/1/Memory/"},"NetworkInterfaces":{"@odata.id":"/redfish/v1/Systems/1/NetworkInterfaces/"},"Processors":{"@odata.id":"/redfish/v1/Systems/1/Processors/"},"SecureBoot":{"@odata.id":"/redfish/v1/Systems/1/SecureBoot/"},"Storage":{"@odata.id":"/redfish/v1/Systems/1/Storage/"},"Actions":{"#ComputerSystem.Reset":{"target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset/","ResetType@Redfish.AllowableValues":["On","ForceOff","ForceRestart","Nmi","PushPowerButton"]}}}]]

-- forward: stands in for the host once the canned server below is defined
local stand_in

function M.ilo_redfish(page)
	if os.getenv("LUNAR_FIXTURE_ILO_ACTIONS") then page.actions.flat_action(page.actions) end
	page.show({
		address = "192.0.2.10", user = "admin", generation = "iLO 6",
		uri = "/redfish/v1/Systems/1/", body = SYSTEM, task = os.getenv("LUNAR_FIXTURE_ILO_TASK"),
		method = os.getenv("LUNAR_FIXTURE_ILO_METHOD"),
	})
end

local function item(path, state, reason)
	return { type = "item", id = path, state = state, reason = reason }
end

function M.scan(page)
	stand_in(rawget(_G, "LUNAR_DEV_SHELL").host)
	page.show({
		release = "675.30", share = [[\\share.example.test\OfficialComponents]],
		status = "Preview of 675.30 finished: 11 to scan, 3 skipped, 2 to review.",
		events = {
			item("firmware/ssa_675.30_ctrl.bin", "kept"),
			item("firmware/ssa_675.30_boot.bin", "kept"),
			item("firmware/ssa_675.30_cpld.bin", "kept"),
			item("drivers/smartpqi-2.1.30/smartpqi.ko", "kept"),
			item("drivers/smartpqi-2.1.30/smartpqi.sys", "kept"),
			item("tools/arcconf-4.21/arcconf", "kept"),
			item("tools/arcconf-4.21/arcconf.exe", "kept"),
			item("tools/ssacli-6.45/ssacli", "kept"),
			item("tools/ssacli-6.45/ssacli.exe", "kept"),
			item("tools/ssaducli-6.45/ssaducli", "kept"),
			item("sdk/maxview-4.21/maxview.jar", "kept"),
			item("docs/release_notes.pdf", "skipped", "documentation"),
			item("docs/readme.txt", "skipped", "documentation"),
			item("logs/build.log", "skipped", "build output"),
			item("firmware/ssa_675.30_new_ctrl", "unrecognized", "no matching project rule"),
			item("vendor/bundle.tar", "unrecognized", "no matching project rule"),
			{ type = "result", ok = true, summary = "11 to scan", data = {
				needs_review = { "firmware/ssa_675.30_new_ctrl", "vendor/bundle.tar" },
				inventory_sha256 = "fixture",
			} },
		},
	})
end

-- The canned scan server --------------------------------------------------------------
local NOW = os.time()
local HOUR = 3600

local function log_lines()
	local lines = {}
	for i, text in ipairs({ "collect started", "found 16 items on the share", "packaged firmware.zip (41.2 MB)",
		"packaged drivers.zip (9.6 MB)", "packaged tools.zip (63.0 MB)", "uploaded firmware.zip",
		"uploaded drivers.zip", "uploaded tools.zip", "firmware.zip scanned: 2 components, 0 critical",
		"drivers.zip scanned: 1 component, 0 critical", "tools.zip scanned: 6 components, 1 critical",
		"run finished" }) do
		lines[i] = cjson.encode({ ts = os.date("%H:%M:%S", NOW - 40 * 60 + i * 73), kind = "bdscan", message = text })
	end
	return table.concat(lines, "\n")
end

local RUNS = {
	{ id = 42, trigger = "schedule", state = "ok", created_at = NOW - 40 * 60, finished_at = NOW - 19 * 60,
	  summary = "1 release scanned", releases = { "675.30" } },
	{ id = 41, trigger = "manual", state = "failed", created_at = NOW - 26 * HOUR, finished_at = NOW - 25 * HOUR,
	  summary = "upload failed", releases = { "675.30" } },
	{ id = 40, trigger = "schedule", state = "ok", created_at = NOW - 50 * HOUR, finished_at = NOW - 49 * HOUR,
	  summary = "1 release scanned", releases = { "675.20" } },
	{ id = 39, trigger = "schedule", state = "ok", created_at = NOW - 74 * HOUR, finished_at = NOW - 73 * HOUR,
	  summary = "1 release scanned", releases = { "675.10" } },
	{ id = 38, trigger = "manual", state = "abandoned", created_at = NOW - 98 * HOUR, finished_at = NOW - 97 * HOUR,
	  summary = "the server stopped during the run", releases = { "675.10" } },
}

local function review_item(id, component, version, source, critical, high, kind, match)
	return { id = id, component = component, version = version, source = source, kind = kind or "vuln",
		match_type = match, counts = { critical = critical, high = high, medium = 2, low = 1 },
		statuses = { NEW = critical + high } }
end

local REVIEWS = {
	review_item("r1", "openssl", "1.1.1k", "both", 2, 4),
	review_item("r2", "zlib", "1.2.11", "hub", 1, 1),
	review_item("r3", "busybox", "1.33.0", "bdba", 1, 0),
	review_item("r4", "curl", "7.79.1", "both", 0, 3),
	review_item("r5", "libxml2", "2.9.10", "hub", 0, 2),
	review_item("r6", "sqlite", "3.34.0", "hub", 0, 1),
	review_item("r7", "expat", "2.2.9", "bdba", 0, 1),
	review_item("r8", "libarchive", "3.5.1", "bdba", 0, 0, "match", "UNKNOWN_VERSION"),
	review_item("r9", "vendor-blob", "", "bdba", 0, 0, "match", "UNMATCHED"),
}

local function review_detail(id)
	local found = REVIEWS[1]
	for _, r in ipairs(REVIEWS) do if r.id == id then found = r end end
	return { item = found, refreshing = false,
		hub = {
			vulnerabilities = {
				{ name = "CVE-2026-0001", severity = "CRITICAL", score = 9.8, status = "NEW", cwe = 787,
				  description = "A buffer overflow in the X.509 name parser lets a crafted certificate write past the end of a heap buffer.",
				  solution = "Upgrade to 1.1.1w or later." },
				{ name = "CVE-2026-0002", severity = "CRITICAL", score = 9.1, status = "NEW", cwe = 125,
				  description = "An out-of-bounds read in the record layer." },
				{ name = "CVE-2026-0003", severity = "HIGH", score = 7.5, status = "NEEDS_REVIEW",
				  description = "A denial of service through crafted ASN.1 input." },
				{ name = "BDSA-2026-0004", severity = "HIGH", score = 7.4, status = "NEW",
				  description = "A timing side channel in RSA decryption." },
			},
			upgrade_guidance = {
				short_term = { version = "1.1.1w", remaining_risk = { critical = 0, high = 1, medium = 3, low = 2 } },
				long_term = { version = "3.0.13", remaining_risk = { critical = 0, high = 0, medium = 0, low = 1 } },
			},
			files = { "tools/ssacli-6.45/libcrypto.so.1.1", "tools/arcconf-4.21/libssl.so.1.1" },
		},
		bdba = { scans = { { product_id = 1042, scan = "tools.zip", verdict = "vulnerable", latest_version = "3.0.13",
			detected_versions = { "1.1.1k" }, objects = { "tools/ssacli-6.45/libcrypto.so.1.1" },
			vulnerabilities = { { cve = "CVE-2026-0001", severity = "CRITICAL", score = 9.8, triaged = false, exact = true,
				summary = "Buffer overflow in the X.509 name parser" } } } } },
	}
end

local function route(path)
	if path == "/health" then
		return { ok = true, busy = false, next_run_at = NOW + 5 * HOUR, poll_hours = 6, dry_run = false,
			last_listing = { at = NOW - HOUR, summary = "4 release(s), 3 settled" },
			bdba_token = true, hub_token = true }
	elseif path == "/releases" then
		return { releases = {
			{ release = "675.30", state = "done", done_run = 42, summary = "3 zips" },
			{ release = "675.20", state = "done", done_run = 40, summary = "3 zips" },
			{ release = "675.10", state = "dry_ok", summary = "dry run" },
		}, on_share = { { release = "675.40", settled = false }, { release = "675.30", settled = true },
			{ release = "675.20", settled = true }, { release = "675.10", settled = true } }, settling = { "675.40" } }
	elseif path == "/runs" then
		return { runs = RUNS }
	elseif path == "/hub-versions" then
		return { versions = { { name = "SR4.2.4", phase = "RELEASED" }, { name = "SR4.2.3", phase = "RELEASED" },
			{ name = "SR4.3.0", phase = "DEVELOPMENT" } }, refreshing = false }
	elseif path == "/reviews" then
		return { items = REVIEWS, cached_at = NOW - 3 * 60, refreshing = false }
	end
	local review = path:match("^/reviews/(.+)$")
	if review then return review_detail(review) end
	if path:match("/log/") then return nil, log_lines() end
	local run = tonumber(path:match("^/runs/(%d+)$"))
	for _, r in ipairs(RUNS) do
		if r.id == run then
			local out = {}
			for k, v in pairs(r) do out[k] = v end
			out.releases = {}
			for i, name in ipairs(r.releases) do
				out.releases[i] = { release = name, state = r.state, summary = r.summary }
			end
			return out
		end
	end
	return {}
end

-- Pages keep calling the host after a fixture has run, so these stay in place.
stand_in = function(host)
	if host.fixture_server then return end
	host.fixture_server = true
	host.getSecret = function() return "fixture" end
	host.http = function(_, req, callback)
		local data, raw = route(req.url:match("/ext/blackduck(/[^?]*)"))
		callback({ status = 200, headers = {}, body = raw or cjson.encode(data) })
	end
end

function M.server(page)
	stand_in(rawget(_G, "LUNAR_DEV_SHELL").host)
	page.refresh()
end

function M.review(page)
	stand_in(rawget(_G, "LUNAR_DEV_SHELL").host)
	page.refresh()
end

return M

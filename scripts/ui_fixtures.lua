-- scripts/ui_fixtures.lua -- sample data for tool pages, for scripts/ui_capture.lua.
--
-- A page has to be judged with data in it as well as empty, and a capture run has no build
-- repository, share or scan file behind it. Pages hand this file their parts through
-- LUNAR_DEV_SHELL.pages, which exists only in a dev build; scripts/ is not packaged, so none
-- of this reaches a release. Everything here is made up. Screenshots leave the machine, so no
-- real host, share or address belongs in this file.
--
-- Each fixture may run twice, a tick apart: its first pass can start asynchronous work (a
-- scan of a family that doesn't exist) that the second pass then paints over.
local M = {}

local function tool(name, source, location)
	return {
		name = name, source = source, location = location, status = "pending",
		path = [[C:\Work\rom-tools\]] .. name,
	}
end

local BUILD_OUTPUT = table.concat({
	"[Build 1/5] AcpiTables - (A66)",
	"cl /nologo /W4 /O2 /DSMM_BUILD acpi.c tables.c",
	"link /OUT:AcpiTables.efi acpi.obj tables.obj",
	"AcpiTables.efi - 0 error(s), 0 warning(s)",
	"",
	"[Build 2/5] MemTrain - (A66)",
	"cl /nologo /W4 /O2 train.c margins.c",
	"MemTrain.efi - 0 error(s), 2 warning(s)",
	"",
	"[Build 3/5] PcieLink - (Common)",
	"cl /nologo /W4 /O2 link.c width.c",
	"width.c(214): error C2065: 'LANE_MAX': undeclared identifier",
	"PcieLink.efi - 1 error(s), 0 warning(s)",
	"",
	"Build stopped on error. See errors.txt for details.",
}, "\n")

function M.build_queue(page)
	local bq, panel = page.bq, page.panel
	if not page.fixture_families then
		page.fixture_families = true
		bq.repo_path = [[C:\Work\rom-tools]]
		panel.refresh_family_dropdown({
			{ name = "A66", path = [[C:\Work\rom-tools\MRelease\A66]] },
			{ name = "U63", path = [[C:\Work\rom-tools\MRelease\U63]] },
		}, true)
		panel.sync_path_dropdown_title("(no folder selected)", bq.repo_path)
		return
	end
	bq.items = {}
	for _, name in ipairs({ "AcpiTables", "BootOrder", "DimmPopulation", "FanCurve", "MemTrain",
		"NvmeHotPlug", "OptionRomScan", "PcieLink", "PowerCap", "SecureBoot", "SmbiosTables",
		"TpmAttest", "UefiVarStore", "UsbEnum", "Watchdog" }) do
		bq.items[#bq.items + 1] = tool(name, "mrelease", name == "PcieLink" and "Common" or "A66")
	end
	for _, name in ipairs({ "CpldTool", "DumpSmbios", "FwFlash", "IpmiUtil", "NvramTool", "RomBuilder" }) do
		bq.items[#bq.items + 1] = tool(name, "tools")
	end
	panel.refresh_tool_list()
	panel.set_selection({ ["FanCurve"] = true, ["PowerCap"] = true, ["TpmAttest"] = true })

	local entries = panel.get_queued_entries()
	for i = #entries, 1, -1 do entries[i] = nil end
	for _, row in ipairs({
		{ "AcpiTables", "ok" }, { "MemTrain", "ok" }, { "PcieLink", "fail" },
		{ "SecureBoot", "pending" }, { "RomBuilder", "pending", true },
	}) do
		for _, item in ipairs(bq.items) do
			if item.name == row[1] then
				entries[#entries + 1] = { tool = item, status = row[2], _rebuild = not row[3] }
			end
		end
	end
	panel.refresh_queue_list()
	panel.set_output_empty(false)
	require("iup").SetAttribute(panel.output_text, "VALUE", BUILD_OUTPUT)
	panel.set_last_built_text("Last built (PcieLink): today 14:02")
	if panel.page then
		panel.page:setState("error", "Build failed in PcieLink: 1 error")
		panel.page:setDockSummary("error", "Build stopped on error in PcieLink", function() panel.page:openDock(true) end)
	end
end

local LOG_LINES = {
	"14:02:11 Starting unit 0042 on ROM A66 v2.14",
	"14:02:12 Memory training: 16 DIMMs, 4800 MT/s",
	"14:02:40 PCIe link width check slot 3",
	"14:02:41 FAILED Link trained x8, expected x16 (slot 3)",
	"14:02:41 Retrying link training, attempt 2 of 3",
	"14:02:47 Fan curve validation",
	"14:03:12 FAILED Fan 4 did not reach target within 25 s",
	"14:03:15 Thermal throttle check",
	"14:03:20 Secure boot keys present",
	"14:03:21 Watchdog recovery",
	"14:04:21 FAILED Timed out waiting for BMC failover",
	"14:04:22 Run finished with 3 failures",
}

function M.log_parser(page)
	local dir = (os.getenv("TEMP") or ".") .. "\\platform-diagnostics.log"
	local file = assert(io.open(dir, "wb"))
	file:write(table.concat(LOG_LINES, "\r\n"))
	file:close()
	local other = (os.getenv("TEMP") or ".") .. "\\thermal-diagnostics.042"
	file = assert(io.open(other, "wb"))
	file:write("13:58:02 FAILED Sensor 12 read 96 C over limit\r\n13:58:03 FAILED CRC mismatch in SMBIOS table\r\n")
	file:close()
	local results = page.results
	results:render({
		metadata = {}, filesScanned = 214, totalFailures = 5,
		failuresByFile = {
			{ file = dir, failureCount = 3, failures = {
				{ line = 4, message = "FAILED Link trained x8, expected x16 (slot 3)" },
				{ line = 7, message = "FAILED Fan 4 did not reach target within 25 s" },
				{ line = 11, type = "0x2A", message = "FAILED Timed out waiting for BMC failover" },
			} },
			{ file = other, failureCount = 2, failures = {
				{ line = 1, message = "FAILED Sensor 12 read 96 C over limit" },
				{ line = 2, message = "FAILED CRC mismatch in SMBIOS table" },
			} },
		},
	}, {
		classify = page.classify, signature = page.signature,
		lookup = function(sig)
			if sig:find("timeout", 1, true) then
				return { count = 4, scans = 3, last_at = 1793800000 }
			end
		end,
		onOpenFile = function() end,
	})
	repeat until results:renderStep(50)
	results._list:select(4)
	results:_chooseRow(4)
	if results._page then results._page:setState("warning", "5 failures in 2 of 214 files") end
end

local SCAN_REPORT = table.concat({
	"Installed Devices Report",
	"========================",
	"",
	">>> Processors:",
	"  - CPU1: 32 cores, 2.4 GHz [0x03:bits0-7]",
	"  - CPU2: 32 cores, 2.4 GHz [0x04:bits0-7]",
	"",
	">>> Memory:",
	"  - DIMM slots populated: 16 of 32 [0x07:bits0-7]",
	"",
	">>> M.2:",
	"  - Slot 1: NVMe x4 [0x0C:bits0-3]",
	"",
	">>> OCP:",
	"  - OCP1 Card: x16 OCP Retimer Card (PCIe Gen5) [0x16:bits0-3]",
	"",
	">>> ROC:",
	"  - Embedded RAID controller present [0x18:bit2]",
	"",
	">>> Storage:",
	"  - Drive cage 1: 8 SFF NVMe [0x1A:bits0-7]",
	"  - Drive cage 2: empty [0x1B:bits0-7]",
	"",
	">>> CPLD Versions:",
	"  - System CPLD: 0x2A",
	"  - Backplane CPLD: 0x11",
	"",
}, "\n")

function M.scan_chain(page)
	page.show("memid_0042.log", SCAN_REPORT)
end

for name, fixture in pairs(dofile((LUNAR_SOURCE_DIR or ".") .. "/scripts/ui_fixtures_net.lua")) do
	M[name] = fixture
end

--- The fixture for a tab, by its title, if it has one and the page has registered.
function M.for_tab(shell, title)
	local page = shell.pages and shell.pages[title]
	local name = title == "Black Duck" and "scan" or title:lower():gsub("%s+", "_")
	if page and M[name] then
		return function() M[name](page) end
	end
end

function M.time_clock(page)
	page.show({ employee = "Alex Morgan", available = { "meal_start", "clock_out" },
		response = "Clock In confirmed at 08:00. Next action: Meal Start.",
		history = { "2026-11-16 08:00  Clock In confirmed", "2026-11-13 17:02  Clock Out confirmed" } })
	local tool = rawget(_G, "LUNAR_DEV_SHELL").toolPages["Time Clock"]
	if tool then tool:setDockSummary("success", "Clock In confirmed at 08:00") end
end

local OUTPUT = {
    ["Build Queue"] = { working = "[Build 1/5] AcpiTables - (A66)\ncl /nologo /W4 /O2 acpi.c tables.c\nCompiling acpi.c...", failed = BUILD_OUTPUT, summary = "Build stopped on error in PcieLink" },
    ["Log Parser"] = { working = "Scanning C:\\Work\\diagnostics\n128 of 214 files scanned...", failed = "Scanning C:\\Work\\diagnostics\nERROR: Cannot open platform-diagnostics.log (access denied).\nScan stopped. Check file permissions, then run again.", summary = "Log scan stopped: file access denied" },
    ["Scan Chain"] = { working = "Reading memid_0042.log\nDecoding installed device sections...", failed = "Reading memid_0042.log\nERROR at byte 0x18: incomplete device record (expected 4 bytes, read 2).\nParse stopped. Choose a complete capture, then retry.", summary = "Parse stopped at byte 0x18: incomplete record" },
    ["Black Duck"] = { working = "Connecting to scan server...\nUploading source manifest (128 of 256 files)...", failed = "POST /api/scans\nHTTP 401 Unauthorized: scan token expired.\nUpdate the token in connection settings, then retry.", summary = "Scan rejected: token expired" },
    ["iLO Redfish"] = { working = "GET /redfish/v1/Systems/1/\nRequest sent; awaiting response...", failed = "GET /redfish/v1/Systems/1/\nHTTP 503 Service Unavailable\nThe management controller is restarting. Wait for it to become available, then retry.", summary = "Request failed: controller unavailable" },
    ["Time Clock"] = { working = "Submitting Meal Start...\nWaiting for clock service confirmation.", failed = "Meal Start request\nHTTP 503 Service Unavailable\nNo punch was confirmed. Check the service before retrying.", summary = "Meal Start was not confirmed" },
}

-- Deterministic presentation states: never start jobs or make network requests.
function M.tool_state(page, state)
	if page.opts and tostring(page.opts.id):match("^media%-") then
		if page.mediaCaptureState then page.mediaCaptureState(state) end
		return
	end
    page.captureState = state
    local iup = page.iup
    local Kit = require("core.ui.Kit")
    local names = { ["Build Queue"]="Build", ["iLO Redfish"]="Request", ["Log Parser"]="Log scan", ["Scan Chain"]="Parse", ["Black Duck"]="Scan", ["Time Clock"]="Clock request" }
    local name = names[page.opts.title] or "Operation"
    local transcript = OUTPUT[page.opts.title]
    if transcript and not page.dockContent then
        page:ensureDock{ widget = iup.text{ MULTILINE="YES", READONLY="YES", EXPAND="YES", THEMEROLE="outputlog" } }
    end
    if not page.capturePlaceholder then
        page.capturePlaceholder = Kit.statusLine(iup, "info", "")
        iup.Append(page.mainHost, page.capturePlaceholder)
    end
    local queue = page.opts.title == "Build Queue" and rawget(_G, "LUNAR_DEV_SHELL").pages["Build Queue"] or nil
    if queue then
        for n,entry in ipairs(queue.panel.get_queued_entries()) do
            entry.status = state == "working" and (n == 1 and "running" or "pending") or (n < 3 and "ok" or (n == 3 and "fail" or "skip"))
            entry.duration = nil
        end
        queue.panel.refresh_queue_list()
    end
    if page.inspector then page:openInspector(false) end
    Kit.show(iup, page.main, queue ~= nil, page.stateLine)
    Kit.show(iup, page.capturePlaceholder, queue == nil, page.stateLine)
    local working = state == "working"
    local sentence = working and (name .. " in progress") or (name .. " failed. Review the output and retry.")
    Kit.setStatus(iup, page.capturePlaceholder, working and "info" or "error", working and "Waiting for results..." or "No results were produced.")
    page:setState(working and "working" or "error", sentence)
    page:setRunState(working and "working" or "failed", working and 0.5 or nil)
    if not (page.opts.primary and page.opts.primary.widget) then iup.SetAttribute(page.primary, "TITLE", working and "Stop" or "Retry") end
    if page.opts.primary and page.opts.primary.widget then
        local target = page.primaryIconTarget
        local n = 0
        while iup.GetChild(page.primary, n) do
            local child = iup.GetChild(page.primary, n)
            Kit.show(iup, child, child == target, page.stateLine)
            n = n + 1
        end
        iup.SetAttribute(target, "TITLE", working and "Stop" or "Retry")
        iup.SetAttribute(target, "ACTIVE", "YES")
    end
    if page.dockContent then
        local function output(w)
            local class = iup.GetClassName(w)
            if class == "text" then iup.SetAttribute(w, "VALUE", transcript and transcript[state] or (name .. " started.")) end
            local n=0
            while iup.GetChild(w,n) do output(iup.GetChild(w,n)); n=n+1 end
        end
        output(page.dockContent)
        page:setDockSummary(working and "info" or "error", working and "Waiting for output" or (transcript and transcript.summary or "Operation stopped before completion"), not working and function() page:openDock(true) end or nil)
        if working then page:openDock(false) end
    end
end

return M

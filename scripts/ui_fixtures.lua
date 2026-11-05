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
	local dir = (os.getenv("TEMP") or ".") .. "\\lunar-fixture-result.log"
	local file = assert(io.open(dir, "wb"))
	file:write(table.concat(LOG_LINES, "\r\n"))
	file:close()
	local other = (os.getenv("TEMP") or ".") .. "\\lunar-fixture-thermal.042"
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
	local name = title:lower():gsub("%s+", "_")
	if page and M[name] then
		return function() M[name](page) end
	end
end

return M

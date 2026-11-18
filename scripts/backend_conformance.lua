-- scripts/backend_conformance.lua -- hold the native backend to the backend contract.
--   Lunar scripts/backend_conformance.lua <out.json>
-- Writes { missing, capabilities, problems, renderer, ok } and exits 0 when it conforms.
-- Run it off-screen (it opens a window); spec/imgui_backend_contract_spec.lua covers the
-- headless backend.
do
	local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
	local root = here:match("^(.*)/scripts/[^/]+$")
	if root and root ~= "" then
		local mine = root .. "/src/lua/?.lua;" .. root .. "/src/lua/?/init.lua"
		table.insert(package.loaders, 2, function(name)
			local file = package.searchpath(name, mine)
			if not file then return nil end
			return assert(loadfile(file))
		end)
	end
end
local contract = require("core.imgui.backend.contract")
local B = require("core.imgui.backend.Native")
local report = {}
local ok, err = xpcall(function()
	report.missing, report.capabilities = contract.check(B)
	-- the system clipboard is the user's (shared by every desktop in the session): only
	-- with LUNAR_CONFORMANCE_CLIPBOARD=1
	report.problems = contract.exercise(B, { skip_clipboard = os.getenv("LUNAR_CONFORMANCE_CLIPBOARD") ~= "1" })
	report.renderer = B.renderer and B.renderer() or nil
end, debug.traceback)
report.error = not ok and tostring(err) or nil
report.ok = ok and #report.missing == 0 and #report.problems == 0
local out = assert(io.open(assert(arg[1], "output path required"), "w"))
out:write(require("cjson").encode(report)); out:close()
os.exit(report.ok and 0 or 1)

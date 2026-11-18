-- scripts/ui_unthemed.lua -- controls still drawn in Windows' system colours under a theme.
--   Lunar <ABSOLUTE path>/scripts/ui_unthemed.lua <out_dir>     (ImGui build; off-screen)
-- Boots the app (the theme comes from settings), waits for it to settle, then lists every
-- element whose resolved colour attributes still hold one of Windows' system greys
-- (240/227/160/133/105 or white), with its class, THEMEROLE and parent chain, to
-- unthemed-imgui.txt. Nothing a callback hands to the OS shell runs.
local ROOT
do
	local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
	ROOT = here:match("^(.*)/scripts/[^/]+$")
	if ROOT and ROOT ~= "" then
		local mine = ROOT .. "/src/lua/?.lua;" .. ROOT .. "/src/lua/?/init.lua"
		table.insert(package.loaders, 1, function(name)
			local file = package.searchpath(name, mine)
			if not file then return nil end
			return assert(loadfile(file))
		end)
	end
end
local iup = require("iup")
local out_dir = assert(arg and arg[1], "output directory required")
local out = assert(io.open(out_dir .. "/unthemed-imgui.txt", "w"))
local function say(fmt, ...) out:write(string.format(fmt, ...), "\n"); out:flush() end

do
	local platform = require("core.platform")
	local os_backend = require(platform.is_windows and "core.platform.win32" or "core.platform.posix")
	for _, t in ipairs({ platform, os_backend }) do
		if t.open then t.open = function() return true end end
		if t.elevate then t.elevate = function() return true end end
	end
	iup.Message = function() end
	require("core.lib.async").probeTcp = function() return false, "probe" end
end

local SYSTEM = { ["240 240 240"] = true, ["227 227 227"] = true, ["160 160 160"] = true,
	["133 133 133"] = true, ["105 105 105"] = true, ["255 255 255"] = true, ["128 128 128"] = true }
local COLOR_ATTRS = { "BGCOLOR", "FGCOLOR", "BORDERCOLOR", "TABSLINECOLOR", "FRAMECOLOR", "TABSBACKCOLOR",
	"HLCOLOR", "TABSHIGHCOLOR", "SB_BACKCOLOR", "SB_FORECOLOR", "FOCUSCOLOR" }

local function chain(Element, el)
	local parts, e = {}, el
	while e do
		local st = Element.state(e)
		if not st then break end
		local role = Element.own(e, "THEMEROLE")
		parts[#parts + 1] = st.classname .. (role and ("[" .. role .. "]") or "")
		e = st.parent
	end
	return table.concat(parts, " < ")
end

local mainloop = iup.MainLoop
iup.MainLoop = function()
	local ticks = 0
	local timer = iup.timer{ time = 100 }
	function timer:action_cb()
		ticks = ticks + 1
		if ticks < 30 then return iup.DEFAULT end
		local ok, err = xpcall(function()
			local Element = require("core.imgui.Element")
			local R = require("core.imgui.Runtime")
			local n = 0
			for el, st in pairs(Element.STATE) do
				local hits = {}
				for _, a in ipairs(COLOR_ATTRS) do
					local v = Element.getAttribute(el, a)
					if v and SYSTEM[tostring(v)] then hits[#hits + 1] = a .. "=" .. tostring(v) end
				end
				-- a box outline only counts when it is drawn
				if #hits > 0 then
					local cls = st.classname
					local shown = R.isVisible and R.isVisible(el)
					local lines = Element.getAttribute(el, "SHOWLINES")
					n = n + 1
					say("%s %s visible=%s SHOWLINES=%s SHOWTABS=%s  %s", cls, table.concat(hits, " "),
						tostring(shown), tostring(lines), tostring(Element.getAttribute(el, "SHOWTABS")), chain(Element, el))
				end
			end
			say("DONE %d", n)
		end, debug.traceback)
		if not ok then say("ERROR %s", tostring(err)) end
		out:close()
		os.exit(0)
	end
	timer.run = "YES"
	return mainloop()
end

dofile((ROOT or LUNAR_SOURCE_DIR) .. "/src/lua/core/main.lua")

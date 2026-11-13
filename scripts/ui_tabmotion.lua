-- scripts/ui_tabmotion.lua -- does switching tabs animate? On either build.
--   Lunar <ABSOLUTE path>/scripts/ui_tabmotion.lua <out_dir>
-- Boots the app, clicks each tab header of every visible tab strip through real window
-- messages, and writes tabmotion-<build>.txt: core.ui.TabTransition's report() (the
-- switch path counters: armed, committed, played, shown, frames) after the clicks, and
-- each click with the strip, the tab and whether a transition was running 60 ms later.
-- Run it off-screen (it opens the app). Nothing a click hands to the OS shell runs.
-- Load this checkout's Lua, whichever executable runs the script.
local ROOT
do
	local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
	ROOT = here:match("^(.*)/scripts/[^/]+$")
	if ROOT and ROOT ~= "" then
		local mine = ROOT .. "/src/lua/?.lua;" .. ROOT .. "/src/lua/?/init.lua"
		-- first, ahead of the preload searcher: an exe embeds its own checkout's core modules
		table.insert(package.loaders, 1, function(name)
			local file = package.searchpath(name, mine)
			if not file then return nil end
			return assert(loadfile(file))
		end)
	end
end
local ffi = require("ffi")
local iup = require("iup")
local IMGUI = rawget(iup, "_IMGUI") == true
local tag = IMGUI and "imgui" or "iup"
local out_dir = assert(arg and arg[1], "output directory required")
local out = assert(io.open(out_dir .. "/tabmotion-" .. tag .. ".txt", "w"))
local function say(fmt, ...) out:write(string.format(fmt, ...), "\n"); out:flush() end

pcall(ffi.cdef, "typedef struct { long x, y; } TM2_POINT;")
for _, d in ipairs({ "void* WindowFromPoint(TM2_POINT);", "int ScreenToClient(void*, TM2_POINT*);",
	"int PostMessageW(void*, unsigned, uintptr_t, intptr_t);" }) do pcall(ffi.cdef, d) end
local user32 = ffi.load("user32")

-- Nothing may reach the user's desktop (see scripts/ui_probe.lua).
do
	local platform = require("core.platform")
	local os_backend = require(platform.is_windows and "core.platform.win32" or "core.platform.posix")
	for _, t in ipairs({ platform, os_backend }) do
		if t.open then t.open = function() return true end end
		if t.elevate then t.elevate = function() return true end end
	end
	iup.Message = function() end
	iup.Alarm = function() return 2 end
	require("core.lib.async").probeTcp = function() return false, "probe" end
end

local transition, host
local TabOrder = require("core.classes.TabOrder")
local set = TabOrder.setTransition
TabOrder.setTransition = function(self, t, ...) transition = t; return set(self, t, ...) end
local Manager = require("core.classes.ExtensionManager")
local load = Manager.loadAll
Manager.loadAll = function(self, ctx) host = ctx; return load(self, ctx) end

-- every visible tab strip that shows its tabs, depth first
local function strips(root)
	local list = {}
	local function walk(h)
		if not h then return end
		if iup.GetClassName(h) == "flattabs" and iup.GetAttribute(h, "VISIBLE") ~= "NO"
			and (iup.GetAttribute(h, "SHOWTABS") or "YES") ~= "NO" then
			list[#list + 1] = h
		end
		local c = iup.GetChild(h, 0)
		while c do walk(c); c = iup.GetBrother(c) end
	end
	walk(root)
	return list
end

-- the strip-local x of each tab's middle, by asking ConvertXYToPos along the strip
local function tab_centers(strip, y)
	local w = tonumber((iup.GetAttribute(strip, "RASTERSIZE") or "0x0"):match("^(%d+)")) or 0
	local spans = {}
	for x = 0, w - 1, 2 do
		local p = iup.ConvertXYToPos(strip, x, y)
		if p and p >= 0 then
			local s = spans[p]
			if not s then s = { x, x }; spans[p] = s else s[2] = x end
		end
	end
	local out_list = {}
	for p, s in pairs(spans) do out_list[#out_list + 1] = { pos = p, x = math.floor((s[1] + s[2]) / 2) } end
	table.sort(out_list, function(a, b) return a.pos < b.pos end)
	return out_list
end

local function click(strip, lx, ly)
	local sx, sy = (iup.GetAttribute(strip, "SCREENPOSITION") or "0,0"):match("(-?%d+),(-?%d+)")
	local pt = ffi.new("TM2_POINT", tonumber(sx) + lx, tonumber(sy) + ly)
	local target = user32.WindowFromPoint(pt)
	local cp = ffi.new("TM2_POINT", pt.x, pt.y)
	user32.ScreenToClient(target, cp)
	local l = bit.bor(bit.band(cp.x, 0xFFFF), bit.lshift(bit.band(cp.y, 0xFFFF), 16))
	user32.PostMessageW(target, 0x0200, 0, l)
	user32.PostMessageW(target, 0x0201, 1, l)
	user32.PostMessageW(target, 0x0202, 0, l)
end

local queue, qi, phase, wait, q_busy = {}, 1, "boot", 0, nil
-- LUNAR_TABMOTION_SHOTS=1 (ImGui): every frame drawn while the first page transition
-- runs, as tabmotion-<n>.bmp (the request lands on the frame it is made in)
if IMGUI and os.getenv("LUNAR_TABMOTION_SHOTS") == "1" then
	local R = require("core.imgui.Runtime")
	local frame, shots = R.frame, 0
	-- the snapshot transition (IUP-style) or the strip's own live one (ImGui flattabs)
	local function busy()
		if transition and transition:busy() then return true end
		local ok, FT = pcall(require, "core.imgui.widgets.flattabs")
		local q = queue and queue[qi]
		-- the first page-strip switch (iLO Redfish), not the group strip's
		if not (q and q.name == (os.getenv("LUNAR_TABMOTION_TAB") or "iLO Redfish")) then return false end
		return ok and type(FT) == "table" and FT.pageTransition and FT.pageTransition(q.strip) ~= nil
	end
	R.frame = function(...)
		if busy() and shots < 24 then
			shots = shots + 1
			R.backend().screenshot(string.format("%s/tabmotion-%02d.bmp", out_dir, shots))
		end
		return frame(...)
	end
end
local mainloop = iup.MainLoop
iup.MainLoop = function()
	local timer = iup.timer{ time = 30 }
	function timer:action_cb()
		local ok, err = xpcall(function()
			if phase == "boot" then
				wait = wait + 1
				if wait < 60 then return end -- about 2 s: extensions settle
				for _, s in ipairs(strips(host.dialog)) do
					for _, t in ipairs(tab_centers(s, 8)) do
						queue[#queue + 1] = { strip = s, pos = t.pos, x = t.x,
							name = tostring(iup.GetAttribute(s, "TABTITLE" .. t.pos)) }
					end
				end
				say("strip tabs to click: %d", #queue)
				phase, wait = "click", 0
			elseif phase == "click" then
				local q = queue[qi]
				if not q then phase = "done"; return end
				if tonumber(iup.GetAttribute(q.strip, "VALUEPOS")) == q.pos then qi = qi + 1; return end
				click(q.strip, q.x, 8)
				phase, wait = "check", 0
			elseif phase == "check" then
				wait = wait + 1
				if wait == 2 then
					q_busy = transition and transition:busy()
					local ok, FT = pcall(require, "core.imgui.widgets.flattabs")
					if not q_busy and ok and type(FT) == "table" and FT.pageTransition then
						local live = FT.pageTransition(queue[qi].strip)
						q_busy = live and ("live " .. tostring(live.name)) or q_busy
					end
				end

				if wait < 20 then return end -- 600 ms: the transition (240 ms) finishes
				local q = queue[qi]
				say("click %-28s -> pos %s now %s, transition running 60 ms in: %s", q.name, q.pos,
					tostring(iup.GetAttribute(q.strip, "VALUEPOS")), tostring(q_busy))
				qi, phase = qi + 1, "click"
			elseif phase == "done" then
				if transition then
					local r = transition:report()
					local keys = {}
					for k in pairs(r) do keys[#keys + 1] = k end
					table.sort(keys)
					for _, k in ipairs(keys) do say("%-24s %s", k, r[k]) end
				else
					say("no TabTransition was attached")
				end
				out:close()
				os.exit(0)
			end
		end, debug.traceback)
		if not ok then say("ERROR %s", tostring(err)); out:close(); os.exit(1) end
		return iup.DEFAULT
	end
	timer.run = "YES"
	return mainloop()
end

dofile((ROOT or LUNAR_SOURCE_DIR) .. "/src/lua/core/main.lua")

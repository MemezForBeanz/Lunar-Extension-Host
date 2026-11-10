-- scripts/imgui_idle.lua -- why the ImGui host draws frames while nobody touches it.
--
--   Lunar scripts/imgui_idle.lua <out_dir>
--
-- After start-up settles, counts for five seconds: frames, invalidations (by element
-- class, kind and the Lua line that caused them), animation requests and timer
-- callbacks. Writes <out_dir>/idle.txt.
local out_dir = (arg and arg[1]) or "."
local iup = require("iup")
local Runtime = require("core.imgui.Runtime")
local Element = require("core.imgui.Element")
local out = assert(io.open(out_dir .. "/idle.txt", "w"))
local function say(...) out:write(string.format(...), "\n"); out:flush() end

local counting = false
local counts = { frames = 0 }
local reasons = {}
local function note(kind)
	if not counting then return end
	local info = debug.traceback("", 3)
	local where = {}
	for line in info:gmatch("[^\n]+") do
		if not line:find("imgui_idle", 1, true) then
			-- embedded modules show as [string "core.x.Y"]:N, files as path/name.lua:N
			local name, n = line:match('%[string "([^"]+)"%]:(%d+)')
			local m = name and (name .. ":" .. n) or line:match("([^\\/]+%.lua:%d+)")
			if m and not m:find("core.imgui.Element:", 1, true) then where[#where + 1] = m end
			if #where >= 5 then break end
		end
	end
	local key = kind .. " <- " .. table.concat(where, " < ")
	reasons[key] = (reasons[key] or 0) + 1
end

local real_mainloop = iup.MainLoop
iup.MainLoop = function()
	local real_frame = Runtime.frame
	Runtime.frame = function(...)
		if counting then counts.frames = counts.frames + 1 end
		return real_frame(...)
	end
	local real_inv = Element.hooks.invalidate
	Element.hooks.invalidate = function(el, kind, ...)
		local st = Element.state(el)
		note("invalidate " .. tostring(kind) .. " " .. (st and st.classname or "?"))
		return real_inv(el, kind, ...)
	end
	local real_anim, real_redraw = Runtime.animate, Runtime.redraw
	Runtime.animate = function(...) note("animate"); return real_anim(...) end
	Runtime.redraw = function(...) note("redraw"); return real_redraw(...) end

	local start = iup.timer({ time = 8000 })
	function start:action_cb()
		self.run = "NO"
		counting = true
		return iup.DEFAULT
	end
	start.run = "YES"
	local stop = iup.timer({ time = 13000 })
	function stop:action_cb()
		self.run = "NO"
		counting = false
		say("frames in 5 s: %d", counts.frames)
		local keys = {}
		for k in pairs(reasons) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return reasons[a] > reasons[b] end)
		for i = 1, math.min(40, #keys) do say("%6d  %s", reasons[keys[i]], keys[i]) end
		out:close()
		iup.ExitLoop()
		return iup.CLOSE
	end
	stop.run = "YES"
	return real_mainloop()
end

local ok, err = pcall(dofile, (LUNAR_SOURCE_DIR or ".") .. "/src/lua/core/main.lua")
if not ok then say("main.lua: %s", tostring(err)); out:close(); os.exit(1) end
os.exit(0)

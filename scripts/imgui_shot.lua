-- scripts/imgui_shot.lua — start Lunar on the ImGui host, save one shot of the main
-- window after a delay, and exit. A quick check that the whole shell builds and paints.
--
--   Lunar scripts/imgui_shot.lua <out.bmp> [delay_ms] [width] [height]
--
-- Errors logged by the runtime (failed callbacks, paint errors) go to <out>.log.
local out = (arg and arg[1]) or "imgui-shot.bmp"
local delay = tonumber(arg and arg[2]) or 4000
local width, height = tonumber(arg and arg[3]), tonumber(arg and arg[4])

local Runtime = require("core.imgui.Runtime")
local log = io.open(out .. ".log", "w")
local real_warn = Runtime.warn
Runtime.warn = function(msg)
	if log then log:write(tostring(msg), "\n"); log:flush() end
	pcall(real_warn, msg)
end
require("core.imgui.Element").hooks.error = function(el, name, err)
	Runtime.warn(string.format("%s %s failed: %s", tostring(el), name, tostring(err)))
end

local real_mainloop = iup.MainLoop
iup.MainLoop = function()
	local B = Runtime.backend()
	if width and height then
		B.window("restore")
		B.window("size", width, height)
	end
	local t = iup.timer({ time = delay })
	function t:action_cb()
		self.run = "NO"
		B.screenshot(out)
		Runtime.frame()
		-- The laid-out tree, one line per element: class, rect, natural size, key attributes.
		local Element = require("core.imgui.Element")
		local f = io.open(out .. ".tree", "w")
		local function walk(el, depth)
			local st = Element.state(el)
			if not st then return end
			local a = st.attrs
			f:write(string.rep("  ", depth), string.format("%s %d,%d %dx%d nat %dx%d", st.classname, st.x, st.y, st.w, st.h, st.nat_w or 0, st.nat_h or 0))
			for _, k in ipairs({ "EXPAND", "RASTERSIZE", "SIZE", "MARGIN", "GAP", "ALIGNMENT", "VISIBLE", "FLOATING", "TITLE", "THEMEROLE", "VALUE", "NAME" }) do
				if a[k] then f:write(" ", k, "=", tostring(a[k]):sub(1, 40)) end
			end
			f:write(string.char(10))
			for _, c in ipairs(st.children) do walk(c, depth + 1) end
		end
		for _, d in ipairs(Runtime.dialogs()) do walk(d, 0) end
		f:close()
		if log then log:write("frames ok\n"); log:close(); log = nil end
		return iup.CLOSE
	end
	t.run = "YES"
	return real_mainloop()
end

local ok, err = xpcall(dofile, debug.traceback, (LUNAR_SOURCE_DIR or ".") .. "/src/lua/core/main.lua")
if not ok then
	if log then log:write("main.lua failed: ", tostring(err), "\n"); log:close() end
	os.exit(1)
end
os.exit(0)

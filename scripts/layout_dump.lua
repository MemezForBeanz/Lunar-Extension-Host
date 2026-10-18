-- scripts/layout_dump.lua — start Lunar normally, then dump the main window's
-- widget tree (class, position, size, natural size) and quit.
--
-- For comparing layout across platforms: run it on Windows and on Linux and
-- diff the output. Sizes are IUP's view of the layout, in pixels.
--
-- Run: LunarExtensionHost scripts/layout_dump.lua [delay_ms]
--   (from the repo, a dev build: it loads src/lua/core/main.lua like the host does)

local iup = require("iup")
local delay = tonumber(arg and arg[1]) or 3000

local function attr(h, name)
	local ok, v = pcall(iup.GetAttribute, h, name)
	return ok and v or nil
end

local function describe(h, depth, out)
	local cls = attr(h, "CLASSNAME") or iup.GetClassName(h) or "?"
	local label = attr(h, "TITLE") or attr(h, "TABTITLE") or ""
	if #label > 24 then label = label:sub(1, 24) .. "..." end
	local extra = ""
	if cls == "text" or cls == "label" or cls == "flatlabel" or cls == "dropbutton" or cls == "flatbutton" then
		extra = string.format(" font=%s char=%s pad=%s", tostring(attr(h, "FONT")),
			tostring(attr(h, "CHARSIZE")), tostring(attr(h, "PADDING")))
	end
	out[#out + 1] = string.format("%s%-12s pos=%-9s size=%-9s natural=%-9s role=%s %s%s%s",
		string.rep("  ", depth), cls,
		tostring(attr(h, "POSITION")), tostring(attr(h, "RASTERSIZE")), tostring(attr(h, "NATURALSIZE")),
		tostring(attr(h, "THEMEROLE") or "-"),
		attr(h, "VISIBLE") == "NO" and "[hidden] " or "",
		label ~= "" and ("'" .. label .. "'") or "", extra)
	local child = iup.GetChild(h, 0)
	local i = 0
	while child do
		describe(child, depth + 1, out)
		i = i + 1
		child = iup.GetChild(h, i)
		if depth > 7 then break end   -- deep enough for the shell and the settings page
	end
end

local real_mainloop = iup.MainLoop
iup.MainLoop = function()
	local t = iup.timer({ time = delay })
	function t:action_cb()
		self.run = "NO"
		local dlg = iup.GetDialog(iup.GetFocus() or iup.GetByName("lunar_main") or iup.GetChild(nil, 0))
		-- Fall back to the first visible dialog with a menu.
		if not dlg then
			for _, name in ipairs(iup.GetAllDialogs() or {}) do
				local d = iup.GetHandle(name)
				if d and attr(d, "VISIBLE") == "YES" then dlg = d break end
			end
		end
		local out = {}
		if dlg then
			out[#out + 1] = string.format("DIALOG size=%s clientsize=%s clientoffset=%s menu=%s driver=%s font=%s",
				tostring(attr(dlg, "RASTERSIZE")), tostring(attr(dlg, "CLIENTSIZE")),
				tostring(attr(dlg, "CLIENTOFFSET")), tostring(attr(dlg, "MENU")),
				tostring(iup.GetGlobal("DRIVER")), tostring(iup.GetGlobal("DEFAULTFONT")))
			describe(dlg, 0, out)
		else
			out[#out + 1] = "no dialog found"
		end
		io.stdout:write(table.concat(out, "\n"), "\n")
		io.stdout:flush()
		iup.ExitLoop()
		return iup.CLOSE
	end
	t.run = "YES"
	return real_mainloop()
end

local main = (LUNAR_SOURCE_DIR or ".") .. "/src/lua/core/main.lua"
dofile(main)

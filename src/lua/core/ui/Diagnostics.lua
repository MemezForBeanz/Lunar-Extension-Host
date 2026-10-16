--- Help > Window Diagnostics: the numbers that decide the layout, the org pack
-- and extension picture, and why tab transitions did or didn't animate.
--
-- Window layout bugs (the bottom of the UI clipped on some displays only) survived
-- several plausible fixes, and each guess cost a rebuild. This reports what the
-- shell says is usable, what the window got and what the content asked for;
-- whichever pair disagrees names the culprit. The org and extension sections
-- answer "why isn't my pack's tool showing" the same way.
--
-- `window_report` is pure: `core.main` gathers the values and shows the text.
--
-- @module core.ui.Diagnostics

local M = {}

local function list_or_dash(t, sep)
	return (t and #t > 0) and table.concat(t, sep) or "-"
end

local function rect_text(r)
	if not r then return "(startup primary-monitor values)" end
	return string.format("%dx%d (%d,%d to %d,%d)",
		r.right - r.left, r.bottom - r.top, r.left, r.top, r.right, r.bottom)
end

--- Build the report text.
-- @tparam table d
-- @tparam string d.fullsize raw screen size, from IUP's FULLSIZE
-- @tparam string d.screensize work area, from IUP's SCREENSIZE
-- @tparam table d.work `{ w, h }` computed usable area
-- @tparam[opt] table d.monitor the current monitor's work rect (`left`, `top`, `right`, `bottom`)
-- @tparam table d.taskbar `{ available, autohide, edge, thickness }`
-- @tparam[opt] table d.profile the selected org profile
-- @tparam table d.org_info `OrgProfile.resolve`'s info (`reason`, `available`, `errors`, `warnings`)
-- @tparam boolean d.dev_build
-- @tparam table d.roots extension roots (`source`, `dir`)
-- @tparam table d.loaded loaded extensions (`source`, `name`/`id`)
-- @tparam table d.skipped skipped extensions (`source`, `name`/`id`, `reason`)
-- @tparam table d.window `{ RASTERSIZE, CLIENTSIZE, MAXIMIZED, MAXSIZE, MINSIZE }`
-- @tparam table d.layout `{ tabs_raster, statusbar_raster, statusbar_expand }`
-- @tparam table|string d.transition the tab transition's report, or why it is unavailable
-- @tparam[opt] table d.native report lines from `core.lib.NativeStatus.lines`
-- @treturn string
function M.window_report(d)
	local info, profile = d.org_info or {}, d.profile
	local tb = d.taskbar or {}
	local lines = {
		"Screen",
		"  FULLSIZE (raw)      : " .. tostring(d.fullsize),
		"  SCREENSIZE (work)   : " .. tostring(d.screensize),
		"  Computed usable     : " .. tostring(d.work.w) .. "x" .. tostring(d.work.h),
		"  Current monitor     : " .. rect_text(d.monitor),
		"",
		"Taskbar",
		"  queried ok          : " .. tostring(tb.available),
		"  auto-hide           : " .. tostring(tb.autohide),
		"  edge / thickness    : " .. tostring(tb.edge) .. " / " .. tostring(tb.thickness or 0),
		"",
		"Organization",
		"  profile             : " .. (profile
			and string.format("%s (%s, %s)", profile.id, tostring(info.reason), profile.trusted and "trusted" or "untrusted")
			or "none (" .. tostring(info.reason) .. ")"),
		"  tool group          : " .. (profile and profile.tool_group or "-"),
		"  installed           : " .. list_or_dash(info.available, ", "),
		"  rejected            : " .. list_or_dash(info.errors, "; "),
		"  warnings            : " .. list_or_dash(info.warnings, "; "),
		"",
		"Extensions (" .. (d.dev_build and "dev build" or "installed build") .. ")",
	}
	for _, root in ipairs(d.roots or {}) do
		lines[#lines + 1] = string.format("  %-20s: %s", tostring(root.source), tostring(root.dir))
	end
	for _, ext in ipairs(d.loaded or {}) do
		lines[#lines + 1] = string.format("  loaded  %-12s: %s", tostring(ext.source), tostring(ext.name or ext.id))
	end
	for _, s in ipairs(d.skipped or {}) do
		lines[#lines + 1] = string.format("  skipped %-12s: %s (%s)", tostring(s.source), tostring(s.name or s.id), tostring(s.reason))
	end

	local w, l = d.window or {}, d.layout or {}
	for _, line in ipairs({
		"",
		"Window",
		"  dialog RASTERSIZE   : " .. tostring(w.RASTERSIZE),
		"  dialog CLIENTSIZE   : " .. tostring(w.CLIENTSIZE),
		"  dialog MAXIMIZED    : " .. tostring(w.MAXIMIZED),
		"  MAXSIZE (applied)   : " .. tostring(w.MAXSIZE),
		"  MINSIZE (applied)   : " .. tostring(w.MINSIZE),
		"",
		"Layout (natural vs actual)",
		"  tabs RASTERSIZE     : " .. tostring(l.tabs_raster),
		"  statusbar RASTERSIZE: " .. tostring(l.statusbar_raster),
		"  statusbar EXPAND    : " .. tostring(l.statusbar_expand),
		"",
		-- The transition declines silently by design (a press that became a drag
		-- must not animate), so "nothing moves when I switch tabs" is invisible
		-- from outside; exactly one of these lines is the answer.
		"Tab transition:",
	}) do
		lines[#lines + 1] = line
	end
	if type(d.transition) == "table" then
		local keys = {}
		for k in pairs(d.transition) do keys[#keys + 1] = k end
		table.sort(keys)
		for _, k in ipairs(keys) do
			lines[#lines + 1] = string.format("  %-22s: %s", k, tostring(d.transition[k]))
		end
	else
		lines[#lines + 1] = "  unavailable: " .. tostring(d.transition)
	end
	if d.native then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Native modules"
		for _, line in ipairs(d.native) do lines[#lines + 1] = line end
	end
	return table.concat(lines, "\n")
end

return M

--- Which optional native pieces loaded, for the startup log and Help > Window
-- Diagnostics.
--
-- Each of these has a fallback, and the callers load them with `pcall(require)`
-- on purpose so a missing one never stops Lunar. The cost is that a broken
-- binding fails silently: theming gets slower, icons turn into text, folder scans
-- drop to pure Lua, and nothing says why. This names what is on and what is off.
--
-- @module core.lib.NativeStatus

local M = {}

--- The optional native modules, in report order. `windows` marks the ones that
-- only exist on Windows, which are "n/a" rather than "off" elsewhere.
M.MODULES = {
	{ name = "ffi", what = "LuaJIT FFI: window effects, precise clock" },
	{ name = "iupraw", what = "raw IUP handles for the FFI fast paths" },
	{ name = "themeapply", what = "batch theme apply" },
	{ name = "svgicon", what = "SVG icons" },
	{ name = "logscan", what = "fast folder scans" },
	{ name = "winredraw", what = "flicker-free redraws", windows = true },
}

--- Try to load each module.
-- @tparam function require_fn `require`, or a stand-in in specs
-- @tparam boolean is_windows
-- @treturn table `{ { name, what, state = "on"|"off"|"n/a", err } }`
function M.probe(require_fn, is_windows)
	local out = {}
	for _, m in ipairs(M.MODULES) do
		local row = { name = m.name, what = m.what }
		if m.windows and not is_windows then
			row.state = "n/a"
		else
			local ok, err = pcall(require_fn, m.name)
			row.state = ok and "on" or "off"
			if not ok then row.err = tostring(err):match("^[^\n]*") end
		end
		out[#out + 1] = row
	end
	return out
end

--- One log line: what's on, then what's off. Off entries are the news.
-- @tparam table rows from `probe`
-- @tparam[opt] table theme `ThemeManager:fastPaths()`
-- @treturn string
-- @treturn boolean true when something that should be there is off
function M.summary(rows, theme)
	local on, off = {}, {}
	for _, r in ipairs(rows) do
		if r.state == "on" then on[#on + 1] = r.name
		elseif r.state == "off" then off[#off + 1] = r.name end
	end
	local theme_off = theme and not (theme.themeapply and theme.ffi)
	if theme_off then
		off[#off + 1] = "theme fast paths (" .. tostring(theme.error or "not loaded") .. ")"
	end
	local text = "native: " .. (#on > 0 and table.concat(on, ", ") or "none")
	if #off > 0 then text = text .. "; OFF: " .. table.concat(off, ", ") end
	return text, #off > 0
end

--- Report lines for Help > Window Diagnostics.
-- @tparam table rows from `probe`
-- @tparam[opt] table theme `ThemeManager:fastPaths()`
-- @treturn table lines
function M.lines(rows, theme)
	local lines = {}
	for _, r in ipairs(rows) do
		lines[#lines + 1] = string.format("  %-11s %-4s %s%s", r.name, r.state, r.what,
			r.err and ("  [" .. r.err .. "]") or "")
	end
	if theme then
		local state = (theme.themeapply and theme.ffi) and "on"
			or ("partial: themeapply " .. (theme.themeapply and "on" or "off")
				.. ", IupFFI " .. (theme.ffi and "on" or "off"))
		lines[#lines + 1] = "  theme fast paths: " .. state
			.. (theme.error and ("  [" .. theme.error .. "]") or "")
	end
	return lines
end

return M

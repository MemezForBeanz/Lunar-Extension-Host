--- Thin Lua API for the native seek bar.
--
-- A thin line with a tall hit area. Values are in whatever unit `max` is, normally seconds.
-- A drag shows the new place at once and commits on release, and `setValue` from a playback
-- tick is ignored during a drag, so a timer can call it freely.
--
-- ```lua
-- local bar = SeekBar.new(iup, {
--     max = 5400,
--     on_seek = function(seconds) player:seek(seconds) end,    -- release, click or key
--     on_changing = function(seconds) end,                     -- during a drag
--     on_hover = function(seconds, x) end,                     -- x is -1 when the pointer leaves
-- })
-- bar:setBuffered({ { 0, 120 }, { 300, 360 } })
-- bar:setMarks({ { at = 95, to = 180 }, { at = 1200 } })       -- a range, and a chapter tick
-- ```
--
-- Keys: Left and Right move by `step`, Ctrl+arrows and Page keys by `page_step`, Home and End
-- to the ends. A key commits at once.
--
-- @module core.ui.SeekBar
local M = {}

--- Format a list of `{ from, to }` pairs for BUFFERED.
-- @tparam table ranges
-- @treturn string
function M.formatRanges(ranges)
	local parts = {}
	for _, range in ipairs(ranges or {}) do
		parts[#parts + 1] = string.format("%.3f-%.3f", range[1], range[2])
	end
	return table.concat(parts, ",")
end

--- Format a list of `{ at, to }` marks for MARKS. A mark without `to` is a tick.
-- @tparam table marks
-- @treturn string
function M.formatMarks(marks)
	local parts = {}
	for _, mark in ipairs(marks or {}) do
		parts[#parts + 1] = mark.to and string.format("%.3f-%.3f", mark.at, mark.to) or string.format("%.3f", mark.at)
	end
	return table.concat(parts, ",")
end

--- Create a seek bar.
-- @tparam userdata iup
-- @tparam[opt] table opts `max`, `value`, `step`, `page_step`, `role`, `on_seek`,
-- `on_changing`, `on_hover`
-- @treturn table `widget`, `setValue`, `setMax`, `setBuffered`, `setMarks`, `value`
function M.new(iup, opts)
	opts = opts or {}
	local raw = opts.raw or require("iupraw")
	local widget = raw.flatseek()
	local set = function(name, value) iup.SetAttribute(widget, name, tostring(value)) end
	set("THEMEROLE", opts.role or "flatseek")
	set("MAX", opts.max or 0)
	set("VALUE", opts.value or 0)
	if opts.step then set("STEP", opts.step) end
	if opts.page_step then set("PAGESTEP", opts.page_step) end
	local function first_only(fn)
		return fn and function(value) return fn(value) end or nil
	end
	raw.bindseek(widget, {
		seek = first_only(opts.on_seek),
		changing = first_only(opts.on_changing),
		hover = opts.on_hover,
	})
	local api = { widget = widget }
	--- Move the line. Ignored during a drag.
	function api:setValue(value) set("VALUE", value or 0) end
	--- Set the length.
	function api:setMax(max) set("MAX", max or 0) end
	--- Show what is buffered, as a list of `{ from, to }`.
	function api:setBuffered(ranges) set("BUFFERED", M.formatRanges(ranges)) end
	--- Show chapters and ranges, as a list of `{ at, to }`.
	function api:setMarks(marks) set("MARKS", M.formatMarks(marks)) end
	--- The current position.
	function api:value() return tonumber(iup.GetAttribute(widget, "VALUE")) or 0 end
	return api
end

return M

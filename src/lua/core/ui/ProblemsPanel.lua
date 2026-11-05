--- The Problems page: every diagnostic the language servers have published, in
-- one list, errors first. Opening a row opens the file at that line.
--
-- It reads `core.lsp.Diagnostics` and nothing else, so it shows a problem in a
-- file that is not open as readily as one in the file in front.
--
-- @classmod core.ui.ProblemsPanel
local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")
local Uri = require("core.lsp.Uri")
local Diagnostics = require("core.lsp.Diagnostics")

local ProblemsPanel = {}
ProblemsPanel.__index = ProblemsPanel

--- The Carbon glyph and colour role for each severity.
ProblemsPanel.GLYPHS = {
	error = { icon = "error--filled", role = "error" },
	warning = { icon = "warning--alt--filled", role = "warning" },
	info = { icon = "information--filled", role = "info" },
	hint = { icon = "information--filled", role = "neutral" },
}

--- How long the list waits after a change before it redraws, in ms. A server
-- republishes on every keystroke; the list should not flicker with it.
ProblemsPanel.SETTLE_MS = 120

--- One row's two lines of text.
-- @tparam table entry a `core.lsp.Diagnostics` entry
-- @treturn string the message's first line
-- @treturn string `file:line:column`, then where it came from
function ProblemsPanel.describe(entry)
	local message = tostring(entry.message or ""):match("^[^\r\n]*") or ""
	local path = Uri.toPath(entry.uri) or tostring(entry.uri)
	local name = path:match("([^/\\]+)$") or path
	local where = string.format("%s:%d:%d", name, (entry.line or 0) + 1, (entry.character or 0) + 1)
	local origin = entry.source or entry.server
	if origin and entry.code then origin = origin .. " " .. entry.code end
	local folder = path:match("^(.*)[/\\][^/\\]+$")
	local parts = { where }
	if origin then parts[#parts + 1] = origin end
	if folder then parts[#parts + 1] = folder end
	return message, table.concat(parts, "    ")
end

--- @tparam table opts
-- @tparam userdata opts.iup
-- @tparam core.lsp.Diagnostics opts.diagnostics
-- @tparam function opts.on_open `fn(entry)`: open the file at the problem
-- @tparam[opt] function opts.idle_hint `fn() -> string`: what to say under
--   "No problems" (which servers are running, or that none is)
function ProblemsPanel.new(opts)
	local iup = opts.iup
	local self = setmetatable({
		_iup = iup,
		_diagnostics = opts.diagnostics,
		_on_open = opts.on_open,
		_idle_hint = opts.idle_hint,
		_entries = {},
		_icons = {},
	}, ProblemsPanel)

	self._summary = iup.flatlabel({ TITLE = "No problems", THEMEROLE = "sectiontitle", EXPAND = "HORIZONTAL" })
	self._rows = Kit.rowList(iup, {
		row_height = 44,
		empty_title = "No problems",
		empty_hint = "Errors and warnings from language servers are listed here.",
		on_activate = function(row) self:_open(row) end,
	})
	iup.SetAttribute(self._rows.widget, "EXPAND", "YES")
	self._widget = L.page(iup, {
		self._summary,
		Kit.rowFrame(iup, self._rows.widget),
		MARGIN = L.margin(L.ROLE.page, 3), GAP = L.gap(3), EXPAND = "YES",
	})

	self._timer = iup.timer({ TIME = tostring(ProblemsPanel.SETTLE_MS), RUN = "NO" })
	local panel = self
	function self._timer:action_cb()
		self.run = "NO"
		panel:refresh()
		return iup.DEFAULT
	end
	self._stop = self._diagnostics:onChange(function() panel:schedule() end)
	self:refresh()
	return self
end

--- The page widget.
function ProblemsPanel:widget() return self._widget end

--- Redraw soon. Called on every diagnostics change.
function ProblemsPanel:schedule()
	pcall(function()
		self._timer.run = "NO"
		self._timer.run = "YES"
	end)
end

function ProblemsPanel:_icon(kind)
	local glyph = ProblemsPanel.GLYPHS[kind] or ProblemsPanel.GLYPHS.error
	return Kit.icon(self._iup, glyph.icon, 16, glyph.role)
end

function ProblemsPanel:_open(row)
	local entry = self._entries[row]
	if entry and self._on_open then self._on_open(entry) end
end

--- Redraw the list from the store now.
function ProblemsPanel:refresh()
	local iup = self._iup
	local entries = self._diagnostics:list()
	self._entries = entries
	local rows = {}
	for i, entry in ipairs(entries) do
		local title, secondary = ProblemsPanel.describe(entry)
		rows[i] = { title = title, secondary = secondary, image = self:_icon(entry.kind) }
	end
	local ok = pcall(function()
		local counts = self._diagnostics:counts()
		local summary = Diagnostics.summary(counts)
		if counts.files > 1 then summary = summary .. " in " .. counts.files .. " files" end
		iup.SetAttribute(self._summary, "TITLE", summary)
		self._rows:setEmpty("No problems", self._idle_hint and self._idle_hint()
			or "Errors and warnings from language servers are listed here.")
		self._rows:setRows(rows)
	end)
	if not ok and self._stop then
		self._stop()   -- the page is gone
		self._stop = nil
	end
end

return ProblemsPanel

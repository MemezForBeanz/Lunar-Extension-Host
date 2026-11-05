--- The Activity popover: what is running, what just ended, and a way back to it.
--
-- It opens over the left end of the status bar and wears the command palette's look:
-- the same roles, read from the active theme at paint time, and the same habit of
-- closing the moment focus leaves it. What it lists comes from `core.classes.Activity`.
--
-- This module also keeps the status bar's activity slot up to date, because the two
-- show one store and share one timer. That timer runs only while something would
-- change without the store saying so, so an idle app pays nothing.
--
-- ### Rows
--
-- `ActivityPanel.rows` turns entries into plain tables whose fields are the ones
-- `core.ui.RowList` takes: `title`, `secondary`, `column1` and `action`. Everything
-- that draws them is the section marked "Row drawing". To move to `RowList`, build one
-- in `_build`, give it those tables from `_refreshRows`, and delete that section.
-- Until then a single canvas draws them, because a row built from flat widgets costs
-- several windows and has no way to host per-row actions in a flat list.
--
-- @classmod core.ui.ActivityPanel

local L = require("core.lib.CarbonLayout")
local Activity = require("core.classes.Activity")

local ActivityPanel = {}
ActivityPanel.__index = ActivityPanel

local WIDTH, ROW_HEIGHT, MAX_ROWS = 420, 44, 7
local HEADER_HEIGHT, HINT_HEIGHT = 36, 28
-- The header, its rule, the hint, the frame's edge and the padding around the rows.
local CHROME = HEADER_HEIGHT + 1 + HINT_HEIGHT + 2 + L.SPACING[3]
-- Room for the empty state.
local EMPTY_ROWS = 2

-- A click on the status bar takes focus from the panel first, which closes it. Without
-- this the same click would then open it again.
local REOPEN_GUARD_SECONDS = 0.35
-- As in core.ui.CommandPalette: wait, then look at where focus really went.
local FOCUS_SETTLE_MS = 90
local SPIN_MS, IDLE_MS = 90, 1000
local SPIN_FRAMES = 12

local SEPARATOR = "  |  "
local STATE_WORDS = { running = "Running", ok = "Finished", failed = "Failed", cancelled = "Cancelled" }
local GLYPHS = { ok = "activity_ok", failed = "activity_failed", cancelled = "activity_stopped" }

--- Turn the store's entries into rows, newest first.
-- @tparam table store a `core.classes.Activity`
-- @tparam[opt] table opts
-- @tparam[opt] number opts.now
-- @tparam[opt] function opts.can_show `fn(item) -> boolean`: its tab can be revealed
-- @treturn {table,...} `{ id, state, title, secondary, column1, progress, actions,
--   action }`; `action` is the one to lead with, `actions` everything on offer
function ActivityPanel.rows(store, opts)
	opts = opts or {}
	local now = opts.now or store._now()
	local rows = {}
	for _, item in ipairs(store:list()) do
		local line = item.summary
		if item.state == "running" then
			line = item.cancelling and "Cancelling..." or item.message
		end
		line = line or STATE_WORDS[item.state]
		-- `tool` is whose work it is. A title that already says so needs no repeating.
		if item.tool and item.tool ~= item.title then line = item.tool .. SEPARATOR .. line end

		local actions = {}
		if opts.can_show and opts.can_show(item) then actions[#actions + 1] = "show" end
		if item.state == "running" and item.cancel and not item.cancelling then
			actions[#actions + 1] = "cancel"
		end
		rows[#rows + 1] = {
			id = item.id,
			state = item.state,
			title = Activity.label(item),
			secondary = line,
			column1 = Activity.elapsed((item.ended or now) - item.started),
			progress = item.state == "running" and Activity.fraction(item) or nil,
			actions = actions,
			action = actions[#actions],
		}
	end
	return rows
end

--- The hint line for a row: only the keys that do something on it.
-- @tparam[opt] table row
-- @treturn string
function ActivityPanel.hint(row)
	local parts = {}
	for _, action in ipairs(row and row.actions or {}) do
		parts[#parts + 1] = action == "show" and "Enter to show" or "Delete to cancel"
	end
	parts[#parts + 1] = "Esc to close"
	return table.concat(parts, "    ")
end

--- What the `activity ` prefix lists in the palette.
-- @tparam table store
-- @tparam string query
-- @tparam table opts
-- @tparam function opts.score `fn(query, text) -> number|nil`
-- @tparam function opts.open opens the panel
-- @tparam[opt] function opts.show `fn(item) -> boolean`: reveals the entry's tab
-- @tparam[opt] function opts.can_show `fn(item) -> boolean`
-- @treturn {table,...} palette items
function ActivityPanel.commandItems(store, query, opts)
	local out = {}
	local rows = ActivityPanel.rows(store, { can_show = opts.can_show })
	for _, row in ipairs(rows) do
		local item = store:get(row.id)
		if opts.score(query, row.title) then
			out[#out + 1] = {
				id = "activity." .. row.id, title = row.title, group = "Activity",
				detail = STATE_WORDS[row.state] .. "  " .. row.column1,
				run = function()
					if not (opts.show and opts.show(item)) then opts.open() end
					return true
				end,
			}
			if item.cancel and not item.cancelling then
				out[#out + 1] = {
					id = "activity.cancel." .. row.id, title = "Cancel " .. item.title, group = "Activity",
					run = function()
						local ok, why = store:cancel(row.id)
						if ok then return true end
						return nil, why or "That can no longer be cancelled"
					end,
				}
			end
		end
	end
	return out
end

--- Create the panel. The window is built on first use.
-- @tparam table opts
-- @tparam userdata opts.iup
-- @tparam table opts.store a `core.classes.Activity`
-- @tparam table opts.status_bar a `core.ui.StatusBar`
-- @tparam userdata opts.parent the main dialog
-- @tparam function opts.anchor `fn() -> x, y`: the screen point to sit above
-- @tparam function opts.role `fn(name) -> rule`: a role of the active theme
-- @tparam string opts.icon_dir assets/Icons
-- @tparam function opts.show `fn(item) -> boolean`: reveal the entry's tab
-- @tparam function opts.can_show `fn(item) -> boolean`
-- @tparam[opt] function opts.notify_tree_change themes a new widget tree
-- @tparam[opt] function opts.round `fn(dialog)`: rounds the window's corners
function ActivityPanel.new(opts)
	local self = setmetatable({
		_iup = opts.iup,
		_store = opts.store,
		_status_bar = opts.status_bar,
		_parent = opts.parent,
		_anchor = opts.anchor,
		_role = opts.role,
		_icon_dir = opts.icon_dir,
		_show = opts.show,
		_can_show = opts.can_show,
		_theme = opts.notify_tree_change,
		_round = opts.round,
		_rows = {},
		_top = 0,          -- rows scrolled off the top
		_frame = 0,
		_hits = {},
		_corners = {},
	}, ActivityPanel)
	self._store:subscribe(function() self:_sync() end)
	opts.status_bar:onActivity(function() self:toggle() end)

	self._timer = self._iup.timer({ time = IDLE_MS })
	local panel = self
	function self._timer:action_cb()
		panel._frame = (panel._frame + 1) % SPIN_FRAMES
		panel:_sync()
		return panel._iup.DEFAULT
	end
	return self
end

function ActivityPanel:_build()
	if self._dialog then return end
	local iup, panel = self._iup, self

	-- Heights are given, not measured. These measure before the theme's type reaches
	-- them, and an empty one measures to nothing and stays that way.
	local title = iup.flatlabel({ TITLE = "Activity", EXPAND = "HORIZONTAL", THEMEROLE = "palette_text",
		ALIGNMENT = "ALEFT:ACENTER", RASTERSIZE = "x" .. HEADER_HEIGHT })
	local count = iup.flatlabel({ TITLE = "", ALIGNMENT = "ARIGHT:ACENTER",
		RASTERSIZE = "96x" .. HEADER_HEIGHT, THEMEROLE = "palette_hint" })
	local canvas = iup.canvas({
		EXPAND = "YES",
		BORDER = "NO",
		SCROLLBAR = "NO",
		CANFOCUS = "YES",
		THEMEROLE = "palette_list",
	})
	local hint = iup.flatlabel({ TITLE = "", EXPAND = "HORIZONTAL", THEMEROLE = "palette_hint",
		ALIGNMENT = "ALEFT:ACENTER", RASTERSIZE = "x" .. HINT_HEIGHT })
	local frame = iup.flatframe({
		iup.vbox({
			iup.hbox({ title, count, MARGIN = L.margin(5, 0), ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL" }),
			iup.flatseparator({ ORIENTATION = "HORIZONTAL", STYLE = "LINE", BARSIZE = "1" }),
			iup.vbox({ canvas, MARGIN = L.margin(0, 2) }),
			iup.hbox({ hint, MARGIN = L.margin(5, 0), ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL" }),
			MARGIN = "1x1",
		}),
		TITLE = "",
		EXPAND = "YES",
		THEMEROLE = "palette_frame",
	})
	self._dialog = iup.dialog({
		frame,
		BORDER = "NO",
		MENUBOX = "NO",
		MAXBOX = "NO",
		MINBOX = "NO",
		RESIZE = "NO",
		RASTERSIZE = WIDTH .. "x" .. (CHROME + ROW_HEIGHT * EMPTY_ROWS),
		PARENTDIALOG = self._parent,
		THEMEROLE = "palette_frame",
	})
	self._canvas, self._count, self._hint = canvas, count, hint

	function canvas:action()
		panel:_paint()
		return iup.DEFAULT
	end
	function canvas:motion_cb(x, y)
		panel:_hover(x, y)
		return iup.DEFAULT
	end
	function canvas:leavewindow_cb()
		panel:_hover(-1, -1)
		return iup.DEFAULT
	end
	function canvas:button_cb(button, pressed, x, y)
		if button == iup.BUTTON1 and pressed == 0 then panel:_click(x, y) end
		return iup.DEFAULT
	end
	function canvas:wheel_cb(delta)
		panel:_scroll(delta > 0 and -1 or 1)
		return iup.DEFAULT
	end
	function canvas:k_any(c)
		if c == iup.K_ESC then
			panel:close()
		elseif c == iup.K_DOWN then
			panel:_move(1)
		elseif c == iup.K_UP then
			panel:_move(-1)
		elseif c == iup.K_PGDN then
			panel:_move(MAX_ROWS)
		elseif c == iup.K_PGUP then
			panel:_move(-MAX_ROWS)
		elseif c == iup.K_CR then
			panel:_act(panel:_selectedRow(), "show")
		elseif c == iup.K_DEL then
			panel:_act(panel:_selectedRow(), "cancel")
		else
			return iup.CONTINUE
		end
		return iup.IGNORE
	end
	function canvas:killfocus_cb()
		panel._focus_timer.run = "NO"
		panel._focus_timer.run = "YES"
		return iup.DEFAULT
	end

	self._focus_timer = iup.timer({ time = FOCUS_SETTLE_MS })
	function self._focus_timer:action_cb()
		self.run = "NO"
		if panel:isOpen() and not panel:_hasFocus() then panel:close() end
		return iup.DEFAULT
	end

	iup.Map(self._dialog)
	if self._theme then pcall(self._theme, self._dialog) end
	if self._round then pcall(self._round, self._dialog) end
end

function ActivityPanel:_hasFocus()
	local iup = self._iup
	local focus = iup.GetFocus()
	if not focus then return false end
	local dialog = iup.GetDialog(focus)
	return dialog ~= nil and require("core.lib.handle").same(iup, dialog, self._dialog)
end

--- Is the panel showing?
function ActivityPanel:isOpen()
	return self._dialog ~= nil and self._iup.GetAttribute(self._dialog, "VISIBLE") == "YES"
end

-- Bring everything that shows the store up to date. Called on every change, so it
-- does no more than the moment needs.
function ActivityPanel:_sync()
	self._status_bar:setActivity(self._store:status())
	if self:isOpen() then self:_refreshRows() end
	self:_arm()
end

-- Run the timer only while something changes on its own: a spinner and elapsed times
-- in the open panel, or a result about to leave the status bar.
function ActivityPanel:_arm()
	local open = self:isOpen()
	local wanted
	if open and self._store:running()[1] then
		wanted = SPIN_MS
	elseif open or self._store:needsTick() then
		wanted = IDLE_MS
	end
	if wanted == self._armed then return end
	self._armed = wanted
	local timer = self._timer
	timer.run = "NO"
	if wanted then
		timer.time = wanted
		timer.run = "YES"
	end
end

function ActivityPanel:_refreshRows()
	local iup = self._iup
	self._rows = ActivityPanel.rows(self._store, { can_show = self._can_show })
	if not self:_selectedRow() then self._selected_id = self._rows[1] and self._rows[1].id end
	self:_clampTop()

	local running = #self._store:running()
	iup.SetAttribute(self._count, "TITLE", running > 0 and (running .. " running") or "")
	iup.SetAttribute(self._hint, "TITLE", ActivityPanel.hint(self:_selectedRow()))
	if self:_visibleRows() ~= self._placed_rows and self:isOpen() then self:_place() end
	iup.Update(self._canvas)
end

function ActivityPanel:_visibleRows()
	if #self._rows == 0 then return EMPTY_ROWS end
	return math.min(#self._rows, MAX_ROWS)
end

function ActivityPanel:_clampTop()
	self._top = math.max(0, math.min(self._top, #self._rows - MAX_ROWS))
end

function ActivityPanel:_selectedIndex()
	for i, row in ipairs(self._rows) do
		if row.id == self._selected_id then return i end
	end
	return nil
end

function ActivityPanel:_selectedRow()
	return self._rows[self:_selectedIndex() or 0]
end

function ActivityPanel:_select(index)
	local row = self._rows[index]
	if not row or row.id == self._selected_id then return end
	self._selected_id = row.id
	self._iup.SetAttribute(self._hint, "TITLE", ActivityPanel.hint(row))
	self._iup.Update(self._canvas)
end

function ActivityPanel:_move(delta)
	if not self._rows[1] then return end
	local target = math.max(1, math.min(#self._rows, (self:_selectedIndex() or 1) + delta))
	if target <= self._top then
		self._top = target - 1
	elseif target > self._top + MAX_ROWS then
		self._top = target - MAX_ROWS
	end
	self:_select(target)
	self._iup.Update(self._canvas)
end

function ActivityPanel:_scroll(delta)
	self._top = self._top + delta
	self:_clampTop()
	self._iup.Update(self._canvas)
end

function ActivityPanel:_hitAt(x, y)
	for _, hit in ipairs(self._hits) do
		if x >= hit.x1 and x <= hit.x2 and y >= hit.y1 and y <= hit.y2 then return hit end
	end
	return nil
end

function ActivityPanel:_rowAt(y)
	local index = self._top + math.floor(y / ROW_HEIGHT) + 1
	return y >= 0 and self._rows[index] and index or nil
end

function ActivityPanel:_hover(x, y)
	local iup = self._iup
	local index = self:_rowAt(y)
	if index then self:_select(index) end
	local hit = self:_hitAt(x, y)
	local key = hit and (hit.row.id .. hit.action) or nil
	if key ~= self._hover_key then
		self._hover_key = key
		iup.SetAttribute(self._canvas, "CURSOR", hit and "HAND" or "ARROW")
		iup.Update(self._canvas)
	end
end

function ActivityPanel:_click(x, y)
	local hit = self:_hitAt(x, y)
	if hit then return self:_act(hit.row, hit.action) end
	local index = self:_rowAt(y)
	if index then self:_act(self._rows[index], "show") end
end

function ActivityPanel:_act(row, action)
	if not row then return end
	local offered = false
	for _, name in ipairs(row.actions) do offered = offered or name == action end
	if not offered then return end
	if action == "cancel" then
		self._store:cancel(row.id)
		return
	end
	local item = self._store:get(row.id)
	self:close()
	if item and self._show then self._show(item) end
end

function ActivityPanel:_place()
	local iup = self._iup
	self._placed_rows = self:_visibleRows()
	local wanted = ROW_HEIGHT * self._placed_rows
	local height = CHROME + wanted
	local function resize()
		iup.SetAttribute(self._dialog, "RASTERSIZE", WIDTH .. "x" .. height)
		iup.Refresh(self._dialog)
	end
	resize()
	-- A sliced row is the one thing that must not happen, and the frame's own padding
	-- isn't this module's to know. So measure what the rows got, and make up the rest.
	local got = tonumber(tostring(iup.GetAttribute(self._canvas, "RASTERSIZE")):match("x(%d+)"))
	if got and got ~= wanted then
		height = height + wanted - got
		resize()
	end
	local x, y = self._anchor()
	if not x then
		iup.ShowXY(self._dialog, iup.CENTERPARENT, iup.CENTERPARENT)
	else
		iup.ShowXY(self._dialog, x, y - height - L.SPACING[3])
	end
end

--- Open the panel. Opening it counts as seeing what failed.
function ActivityPanel:open()
	self:_build()
	self._top, self._selected_id, self._hover_key = 0, nil, nil
	self._store:markViewed()
	self._rows = ActivityPanel.rows(self._store, { can_show = self._can_show })
	self:_place()
	self:_refreshRows()
	self._iup.SetFocus(self._canvas)
	self:_arm()
end

--- Close the panel and hand focus back to the main window.
function ActivityPanel:close()
	if not self:isOpen() then return end
	self._iup.Hide(self._dialog)
	self._closed_at = self._store._now()
	self:_arm()
	pcall(self._iup.SetAttribute, self._parent, "BRINGFRONT", "YES")
end

--- Open the panel, or close it if it is open.
function ActivityPanel:toggle()
	if self:isOpen() then return self:close() end
	if self._closed_at and self._store._now() - self._closed_at < REOPEN_GUARD_SECONDS then return end
	self:open()
end

-- Row drawing ------------------------------------------------------------------------
--
-- Temporary, until `core.ui.RowList` is available everywhere; see the note at the top.

local GLYPH_SIZE = 16
local PILL_INSET = 6
local TEXT_X = PILL_INSET + 34
local CHIP_HEIGHT = 24
local CHIP_PADDING = L.SPACING[3]
local ELAPSED_WIDTH = 56
local ACTION_TITLES = { show = "Show", cancel = "Cancel" }

function ActivityPanel:_fill(x1, y1, x2, y2, color)
	local iup, canvas = self._iup, self._canvas
	iup.SetAttribute(canvas, "DRAWSTYLE", "FILL")
	iup.SetAttribute(canvas, "DRAWCOLOR", color)
	iup.DrawRectangle(canvas, x1, y1, x2, y2)
end

function ActivityPanel:_text(text, x, y, w, h, color, font, align)
	local iup, canvas = self._iup, self._canvas
	iup.SetAttribute(canvas, "DRAWCOLOR", color)
	if font then iup.SetAttribute(canvas, "DRAWFONT", font) end
	iup.SetAttribute(canvas, "DRAWTEXTALIGNMENT", align or "ALEFT")
	iup.SetAttribute(canvas, "DRAWTEXTELLIPSIS", "YES")
	iup.DrawText(canvas, text, x, y, w, h)
end

-- The draw API has no rounded rectangle, so the corners are images: the fill colour
-- with its alpha worked out by supersampling, which is what keeps them smooth.
function ActivityPanel:_corner(color, radius)
	local key = color .. "/" .. radius
	if self._corners[key] then return self._corners[key] end
	local iup = self._iup
	local r, g, b = color:match("(%d+)%s+(%d+)%s+(%d+)")
	r, g, b = tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0
	local SAMPLES = 4
	local function coverage(px, py)
		local inside = 0
		for sy = 1, SAMPLES do
			for sx = 1, SAMPLES do
				local dx = px + (sx - 0.5) / SAMPLES - radius
				local dy = py + (sy - 0.5) / SAMPLES - radius
				if dx * dx + dy * dy <= radius * radius then inside = inside + 1 end
			end
		end
		return math.floor(255 * inside / (SAMPLES * SAMPLES) + 0.5)
	end
	local names = {}
	for corner, flip in pairs({ tl = { false, false }, tr = { true, false },
		bl = { false, true }, br = { true, true } }) do
		local pixels = {}
		for y = 0, radius - 1 do
			for x = 0, radius - 1 do
				local alpha = coverage(flip[1] and radius - 1 - x or x, flip[2] and radius - 1 - y or y)
				pixels[#pixels + 1], pixels[#pixels + 2] = r, g
				pixels[#pixels + 1], pixels[#pixels + 2] = b, alpha
			end
		end
		local name = string.format("ActivityCorner_%s_%s", key:gsub("%W", "_"), corner)
		iup.SetHandle(name, iup.imagergba({ width = radius, height = radius, pixels = pixels }))
		names[corner] = name
	end
	self._corners[key] = names
	return names
end

function ActivityPanel:_pill(x1, y1, x2, y2, color, radius)
	local iup, canvas = self._iup, self._canvas
	local corners = self:_corner(color, radius)
	self:_fill(x1 + radius, y1, x2 - radius, y2, color)
	self:_fill(x1, y1 + radius, x1 + radius - 1, y2 - radius, color)
	self:_fill(x2 - radius + 1, y1 + radius, x2, y2 - radius, color)
	iup.DrawImage(canvas, corners.tl, x1, y1)
	iup.DrawImage(canvas, corners.tr, x2 - radius + 1, y1)
	iup.DrawImage(canvas, corners.bl, x1, y2 - radius + 1)
	iup.DrawImage(canvas, corners.br, x2 - radius + 1, y2 - radius + 1)
end

function ActivityPanel:_glyph(row)
	local iup = self._iup
	local VectorIcon = require("core.ui.VectorIcon")
	if not VectorIcon.available then return nil end
	if row.state == "running" then
		return VectorIcon.imageHandle(iup, {
			path = self._icon_dir .. "/in-progress.svg",
			size = GLYPH_SIZE,
			color = VectorIcon.roleColor("info"),
			rotation = self._frame * (360 / SPIN_FRAMES),
		})
	end
	return require("core.ui.StatusIcon").imageHandle(iup, self._icon_dir, GLYPHS[row.state], GLYPH_SIZE)
end

function ActivityPanel:_paintRow(row, y, w, colors, selected)
	local iup, canvas = self._iup, self._canvas
	local right = w - (L.SPACING[4] + PILL_INSET)
	if selected then
		self:_pill(PILL_INSET, y + 1, w - 1 - PILL_INSET, y + ROW_HEIGHT - 2, colors.selected, colors.radius)
		-- The same leading mark a selected palette row carries.
		self:_fill(PILL_INSET, y + 14, PILL_INSET + 2, y + ROW_HEIGHT - 15, colors.marker)
	end
	local glyph = self:_glyph(row)
	if glyph then iup.DrawImage(canvas, glyph, PILL_INSET + 10, y + math.floor((ROW_HEIGHT - GLYPH_SIZE) / 2)) end

	-- Actions only on the selected row, right to left, so the list stays quiet.
	if selected then
		iup.SetAttribute(canvas, "DRAWFONT", colors.font_small)
		for i = #row.actions, 1, -1 do
			local action = row.actions[i]
			local title = ACTION_TITLES[action]
			local text_w = iup.DrawGetTextSize(canvas, title)
			local chip_w = text_w + CHIP_PADDING * 2
			local x1, y1 = right - chip_w, y + math.floor((ROW_HEIGHT - CHIP_HEIGHT) / 2)
			local x2, y2 = right - 1, y1 + CHIP_HEIGHT - 1
			self._hits[#self._hits + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, row = row, action = action }
			if self._hover_key == row.id .. action then
				self:_pill(x1, y1, x2, y2, colors.bg, math.min(colors.radius, 4))
			end
			self:_text(title, x1, y1, chip_w, CHIP_HEIGHT, colors.text, colors.font_small, "ACENTER")
			right = x1 - L.SPACING[1]
		end
	end

	local meta_x = right - ELAPSED_WIDTH
	self:_text(row.column1, meta_x, y + 5, ELAPSED_WIDTH, 16, colors.muted, colors.font_small, "ARIGHT")
	local text_w = meta_x - L.SPACING[3] - TEXT_X
	self:_text(row.title, TEXT_X, y + 3, text_w, 18, colors.text, colors.font)
	self:_text(row.secondary, TEXT_X, y + 20, text_w, 16, colors.muted, colors.font_small)

	if row.progress then
		-- Clear of the line above, or it reads as an underline on that text.
		local bar_y = y + ROW_HEIGHT - 6
		self:_fill(TEXT_X, bar_y, TEXT_X + text_w - 1, bar_y + 1, colors.track)
		if row.progress > 0 then
			self:_fill(TEXT_X, bar_y, TEXT_X + math.floor(text_w * row.progress) - 1, bar_y + 1, colors.marker)
		end
	end
end

function ActivityPanel:_paintEmpty(w, h, colors)
	self:_text("Nothing running", 0, math.floor(h / 2) - 20, w, 20, colors.text, colors.font, "ACENTER")
	self:_text("Work from any tool shows up here while it runs.", 0, math.floor(h / 2) + 2, w, 18,
		colors.muted, colors.font_small, "ACENTER")
end

-- The palette's own roles, so a theme restyles both at once.
function ActivityPanel:_colors()
	local list = self._role("palette_list") or {}
	local hint = self._role("palette_hint") or {}
	return {
		bg = list.bg or "255 255 255",
		text = list.fg or "30 30 30",
		muted = hint.fg or "110 110 110",
		selected = list.selbg or list.hover or "225 225 225",
		marker = list.itemmarker or list.fg or "30 30 30",
		track = list.scrollfg or hint.fg or "200 200 200",
		radius = tonumber(list.itemradius) or tonumber(list.radius) or 4,
		font = list.font or "Segoe UI, 10",
		font_small = hint.font or "Segoe UI, 9",
	}
end

function ActivityPanel:_paint()
	local iup, canvas = self._iup, self._canvas
	local colors = self:_colors()
	iup.DrawBegin(canvas)
	local w, h = iup.DrawGetSize(canvas)
	self:_fill(0, 0, w - 1, h - 1, colors.bg)
	self._hits = {}
	if not self._rows[1] then
		self:_paintEmpty(w, h, colors)
	else
		local last = math.min(#self._rows, self._top + MAX_ROWS)
		for i = self._top + 1, last do
			local row = self._rows[i]
			self:_paintRow(row, (i - self._top - 1) * ROW_HEIGHT, w, colors, row.id == self._selected_id)
		end
		if #self._rows > MAX_ROWS then
			local track = h - L.SPACING[2]
			local thumb = math.max(24, math.floor(track * MAX_ROWS / #self._rows))
			local y = L.SPACING[1] + math.floor((track - thumb) * self._top / (#self._rows - MAX_ROWS))
			self:_fill(w - 4, y, w - 2, y + thumb - 1, colors.track)
		end
	end
	iup.DrawEnd(canvas)
end

return ActivityPanel

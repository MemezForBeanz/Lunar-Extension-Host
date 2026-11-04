--- Split the workspace: show any tabs side by side, whoever wrote them.
--
-- The window's content is a 2x2 grid of tab strips. `main` is the strip the app has
-- always had; `right`, `bottom` and `corner` are empty and take no space until a tab
-- is moved into one.
--
--     +--------+--------+
--     |  main  | right  |
--     +--------+--------+
--     | bottom | corner |
--     +--------+--------+
--
-- Moving a tab is the same reparent `core.classes.TabGroups` uses to regroup one, so
-- no extension has to know panes exist: its page keeps its native windows and its
-- state, and it simply lays out in a different rectangle. The tab bars in every pane
-- are ordinary strips, so tabs drag between panes the way they drag between groups.
--
-- ### Why a fixed grid and not a tree of splits
--
-- A grid never has to rebuild its containers, because every split exists from the
-- start. Dissolving a pane is then a matter of setting a number, where a tree would
-- have to reparent the survivors through splits being destroyed around them, and it
-- gives snapping four obvious targets instead of an unbounded set of them.
--
-- @classmod core.classes.PaneGrid

local class = require("middleclass")
local handle = require("core.lib.handle")
local SplitMotion = require("core.lib.SplitMotion")

local PaneGrid = class("PaneGrid")

--- The panes the user can move a tab to, in display order.
PaneGrid.ZONES = { "main", "right", "bottom", "corner" }

-- The band along an edge of the grid that means "split here". A quarter gives a
-- generous target without taking over the middle, where a drop joins the pane.
local EDGE = 0.25

-- A split's full range. IUP stores VALUE in thousandths.
local FULL = 1000
local HALF = 500

-- How long after the last sash movement the sizes are saved.
local SAVE_DELAY_MS = 400

--- Which zone a point falls in. Pure, so the geometry is testable without a window.
--
-- @tparam number fx pointer position across the grid, 0 to 1
-- @tparam number fy pointer position down the grid, 0 to 1
-- @tparam table used which panes hold tabs: `{ right = bool, bottom = bool, corner = bool }`
-- @tparam number split_x where the column split sits, 0 to 1
-- @treturn string|nil a zone name, or nil when the point is outside the grid
function PaneGrid.zoneAt(fx, fy, used, split_x)
	if fx < 0 or fx > 1 or fy < 0 or fy > 1 then return nil end
	local right = fx > 1 - EDGE
	local bottom = fy > 1 - EDGE
	if right and bottom then return "corner" end
	if right then return "right" end
	if bottom then return "bottom" end
	-- The middle of the grid: whichever pane is under the pointer.
	if (used.right or used.corner) and fx >= (split_x or 0.5) then
		return used.right and "right" or "corner"
	end
	return "main"
end

--- The rectangle a zone will cover once a tab lands in it, for the snap preview.
-- @tparam string zone
-- @tparam table rect the grid: `{ x, y, w, h }`
-- @tparam table used as for `zoneAt`
-- @treturn table `{ x, y, w, h }`
function PaneGrid.zoneRect(zone, rect, used)
	local half_w, half_h = math.floor(rect.w / 2), math.floor(rect.h / 2)
	local has_right = used.right or used.corner or zone == "right" or zone == "corner"
	local x, y, w, h = rect.x, rect.y, has_right and half_w or rect.w, rect.h
	if zone == "right" or zone == "corner" then
		x, w = rect.x + half_w, rect.w - half_w
	end
	if zone == "bottom" or zone == "corner" then
		y, h = rect.y + half_h, rect.h - half_h
	elseif (zone == "main" and used.bottom) or (zone == "right" and used.corner) then
		h = half_h
	end
	return { x = x, y = y, w = w, h = h }
end

--- Build the grid around the main strip.
-- @tparam table opts
-- @tparam userdata opts.iup
-- @tparam userdata opts.main the main `iup.flattabs`
-- @tparam[opt] table opts.settings `core.classes.SettingsManager`
function PaneGrid:initialize(opts)
	local iup = opts.iup
	self._iup, self._settings = iup, opts.settings
	self._strips = {
		main = opts.main,
		right = iup.flattabs({}),
		bottom = iup.flattabs({}),
		corner = iup.flattabs({}),
	}

	local function split(first, second, orientation, name)
		local s = iup.split({ first, second, ORIENTATION = orientation, AUTOHIDE = "YES", VALUE = tostring(FULL) })
		SplitMotion.attach(iup, s, { on_change = function() self:_sizesChanged(name) end })
		return s
	end
	self._left = split(self._strips.main, self._strips.bottom, "HORIZONTAL", "left")
	self._right = split(self._strips.right, self._strips.corner, "HORIZONTAL", "right")
	self._grid = split(self._left, self._right, "VERTICAL", "grid")

	local saved = opts.settings and opts.settings:get("pane_sizes")
	self._sizes = type(saved) == "table" and saved or {}
end

--- The widget that goes in the window in place of the main strip.
function PaneGrid:widget()
	return self._grid
end

--- The extra strips, keyed by zone (`right`, `bottom`, `corner`).
function PaneGrid:extraStrips()
	return { right = self._strips.right, bottom = self._strips.bottom, corner = self._strips.corner }
end

--- The strip of a zone.
function PaneGrid:strip(zone)
	return self._strips[zone]
end

--- Run `fn` whenever panes change size, so pages can re-centre themselves.
function PaneGrid:onLayout(fn)
	self._on_layout = fn
end

--- Connect the tab tree. Called once; `TabGroups` then treats the panes as roots.
function PaneGrid:setGroups(groups)
	self._groups = groups
end

function PaneGrid:_count(zone)
	return #self._groups:_children(self._strips[zone])
end

function PaneGrid:_used()
	return {
		right = self:_count("right") > 0,
		bottom = self:_count("bottom") > 0,
		corner = self:_count("corner") > 0,
	}
end

--- Which zone holds a strip (or a page in it), or nil.
function PaneGrid:zoneOf(widget)
	local iup, cur, guard = self._iup, widget, 0
	while cur and guard < 64 do
		for zone, strip in pairs(self._strips) do
			if handle.same(iup, cur, strip) then return zone end
		end
		cur = self._groups:stripOf(cur)
		guard = guard + 1
	end
	return nil
end

function PaneGrid:_rect()
	local iup = self._iup
	local px, py = tostring(iup.GetAttribute(self._grid, "SCREENPOSITION") or ""):match("(-?%d+),(-?%d+)")
	local w, h = tostring(iup.GetAttribute(self._grid, "RASTERSIZE") or ""):match("(%d+)x(%d+)")
	if not (px and w) then return nil end
	return { x = tonumber(px), y = tonumber(py), w = tonumber(w), h = tonumber(h) }
end

--- The zone under a screen position, for a tab being dragged.
-- @treturn string|nil zone
-- @treturn table|nil the rectangle it will cover
function PaneGrid:zoneAtScreen(x, y)
	local rect = self:_rect()
	if not rect or rect.w <= 0 or rect.h <= 0 then return nil end
	local used = self:_used()
	local value = tonumber(self._iup.GetAttribute(self._grid, "VALUE")) or FULL
	local zone = PaneGrid.zoneAt((x - rect.x) / rect.w, (y - rect.y) / rect.h, used, value / FULL)
	if not zone then return nil end
	return zone, PaneGrid.zoneRect(zone, rect, used)
end

--- Can `widget` go to `zone`? The main pane may not be left empty: it holds the
-- Settings tab's home and is where a restored layout puts unknown tabs.
function PaneGrid:canMove(widget, zone)
	if not (self._groups and widget and self._strips[zone]) then return false end
	local from = self:zoneOf(widget)
	if from == zone then return false end
	if from == "main" and self._groups:stripOf(widget)
		and handle.same(self._iup, self._groups:stripOf(widget), self._strips.main)
		and self:_count("main") <= 1 then
		return false
	end
	return true
end

--- Move a tab or a whole group to a zone and show it there.
-- @treturn boolean moved
function PaneGrid:move(widget, zone)
	if not self:canMove(widget, zone) then return false end
	self._groups:moveInto(widget, self._strips[zone])
	self._groups:setActiveRoot(self._strips[zone])
	self:sync()
	return true
end

--- Put every pane's tabs back in the main strip.
function PaneGrid:reset()
	for _, zone in ipairs({ "right", "bottom", "corner" }) do
		for _, page in ipairs(self._groups:_children(self._strips[zone])) do
			self._groups:moveInto(page, self._strips.main)
		end
	end
	self._groups:setActiveRoot(self._strips.main)
	self:sync()
end

function PaneGrid:_apply(split, value, bar)
	local iup = self._iup
	iup.SetAttribute(split, "BARSIZE", bar and "7" or "0")
	iup.SetAttribute(split, "VALUE", tostring(value))
end

--- Size the splits to the panes in use. Empty panes take no space and show no sash.
-- Run after any move, and after a theme switch (which rewrites BARSIZE).
function PaneGrid:sync()
	if not self._groups then return end
	local used = self:_used()
	local sizes = self._sizes
	local has_right = used.right or used.corner

	self:_apply(self._grid, has_right and (sizes.grid or HALF) or FULL, has_right)
	self:_apply(self._left, used.bottom and (sizes.left or HALF) or FULL, used.bottom)
	if used.right and used.corner then
		self:_apply(self._right, sizes.right or HALF, true)
	else
		self:_apply(self._right, used.corner and 0 or FULL, false)
	end
	-- Before the window exists there is nothing to lay out, and IupRefresh on an
	-- unmapped tree walks handles that are not there yet.
	if self._iup.GetAttribute(self._grid, "WID") then
		pcall(self._iup.Refresh, self._grid)
	end
	if self._on_layout then self._on_layout() end
end

function PaneGrid:_sizesChanged(name)
	local iup = self._iup
	local split = ({ left = self._left, right = self._right, grid = self._grid })[name]
	self._sizes[name] = tonumber(iup.GetAttribute(split, "VALUE"))
	if self._on_layout then self._on_layout() end
	if not self._settings then return end

	if not self._save_timer then
		local grid = self
		self._save_timer = iup.timer({ time = SAVE_DELAY_MS })
		function self._save_timer:action_cb()
			self.run = "NO"
			grid._settings:set("pane_sizes", grid._sizes)
			pcall(function() grid._settings:save() end)
			return iup.DEFAULT
		end
	end
	self._save_timer.run = "NO"
	self._save_timer.run = "YES"
end

-- The snap preview: a translucent accent block over where the pane will land. It is a
-- window of its own because it has to float over native child windows, which no
-- amount of drawing inside the main dialog can do.
function PaneGrid:_previewDialog(parent)
	if self._preview then return self._preview end
	local iup = self._iup
	self._preview = iup.dialog({
		iup.flatframe({ iup.fill({}), TITLE = "", EXPAND = "YES", THEMEROLE = "snap_preview" }),
		BORDER = "NO", MENUBOX = "NO", MAXBOX = "NO", MINBOX = "NO", RESIZE = "NO",
		OPACITY = "96",
		SHOWNOACTIVATE = "YES",
		PARENTDIALOG = parent,
		THEMEROLE = "snap_preview",
	})
	local theme = require("core.ui.ThemeReactor").themeManager()
	if theme then pcall(theme.themeWidget, theme, self._preview) end
	return self._preview
end

--- Show where a dragged tab would land.
-- @tparam userdata parent the main dialog
-- @tparam table rect `{ x, y, w, h }` in screen coordinates
function PaneGrid:showPreview(parent, rect)
	local iup = self._iup
	local dialog = self:_previewDialog(parent)
	local key = string.format("%d,%d,%d,%d", rect.x, rect.y, rect.w, rect.h)
	if key == self._preview_key then return end
	self._preview_key = key
	iup.SetAttribute(dialog, "RASTERSIZE", rect.w .. "x" .. rect.h)
	iup.ShowXY(dialog, rect.x, rect.y)
end

--- Hide the snap preview.
function PaneGrid:hidePreview()
	if self._preview and self._preview_key then
		self._preview_key = nil
		self._iup.Hide(self._preview)
	end
end

return PaneGrid

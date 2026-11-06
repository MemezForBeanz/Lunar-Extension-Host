--- Thin Lua API for the native virtual cell grid (a contact sheet, or a horizontal shelf).
--
-- The C control queries and paints only the cells in view, so a list of any length costs the
-- same to scroll. Positions are 1 based. A provider is called as `value(position, field)`
-- with the field in capitals: TITLE, SECONDARY, BADGE (short text tag on the image), PROGRESS
-- (0 to 100, a line along the bottom of the image) or STATE ("unplayed" marks the cell,
-- "offline" mutes its title). A plain item table uses the lowercase names.
--
-- ```lua
-- local grid = CellGrid.new(iup, {
--     count = #films, value = function(pos, field) ... end,
--     cell_width = 150, aspect = "2:3",
--     on_select = function(pos) end,            -- the cursor moved here
--     on_activate = function(pos, how) end,     -- "enter" or "double"
--     on_context = function(pos) end,
-- })
-- local drain = CellGrid.posters(grid, cache, function(pos) return films[pos].poster_path end)
-- ctx:addTimer({ time = 30, run = true, action = drain }, M)
-- ```
--
-- `opts`: `items` or `count` and `value`, `cell_width` (image width in pixels), `aspect`
-- ("2:3" or a number), `gutter`, `padding`, `shelf` (true for one horizontal line; `rows` for
-- more), `show_text` (false hides the title lines), `multiple`, `bits`, `type_ahead`,
-- `empty_title`, `empty_hint`, `role`, `on_select`, `on_activate`, `on_context`, `on_change`.
--
-- `bits(pos, w, h)` returns a lightuserdata to w x h BGRA pixels, top row first, and the
-- stride in bytes, or nil to draw a placeholder tile with the title. The pixels must stay
-- valid until the paint returns; `media_native` caches keep that promise.
--
-- `type_ahead(text)` returns the position to go to, 0 for none, or nil to let the grid scan
-- titles itself. Give one when titles are not all in memory: the scan asks for every title.
--
-- Keyboard: arrows, Page Up, Page Down, Home, End, Enter, type-ahead; with `multiple`, Shift
-- extends, Ctrl+click and Space toggle, Ctrl+A selects all.
--
-- @module core.ui.CellGrid
local M = {}

local fields = { TITLE = "title", SECONDARY = "secondary", BADGE = "badge", PROGRESS = "progress", STATE = "state" }

--- Turn a SELECTIONMASK string into a list of positions.
-- @tparam string mask one `+` or `-` per cell
-- @treturn table positions, ascending
function M.parseMask(mask)
	local list = {}
	local pos = (mask or ""):find("+", 1, true)
	while pos do
		list[#list + 1] = pos
		pos = mask:find("+", pos + 1, true)
	end
	return list
end

--- Create a grid.
-- @tparam userdata iup
-- @tparam[opt] table opts see the module description
-- @treturn table `widget`, `setItems`, `setProvider`, `setEmpty`, `select`, `selected`,
-- `selection`, `scrollTo`, `refreshCell`, `visibleRange`, `setCellWidth`
function M.new(iup, opts)
	opts = opts or {}
	local raw = opts.raw or require("iupraw")
	local widget = raw.flatgrid()
	local set = function(name, value) iup.SetAttribute(widget, name, tostring(value)) end
	set("THEMEROLE", opts.role or "flatgrid")
	local shelf = opts.shelf or (opts.rows and opts.rows > 0)
	set("ORIENTATION", shelf and "HORIZONTAL" or "VERTICAL")
	set("FLATSCROLLBAR", shelf and "HORIZONTAL" or "VERTICAL")
	if shelf then
		set("ROWS", opts.rows or 1)
		set("EXPAND", "HORIZONTAL")
	end
	if opts.cell_width then set("CELLWIDTH", opts.cell_width) end
	if opts.aspect then set("ASPECT", opts.aspect) end
	if opts.gutter then set("GUTTER", opts.gutter) end
	if opts.padding then set("PADDING", opts.padding) end
	if opts.show_text == false then set("SHOWTEXT", "NO") end
	if opts.multiple then set("MULTIPLE", "YES") end
	set("EMPTYTITLE", opts.empty_title or "Nothing here yet")
	set("EMPTYHINT", opts.empty_hint or "")

	local items = opts.items or {}
	local value = opts.value
	local api = { widget = widget }
	raw.bindgrid(widget, {
		value = function(pos, field)
			if value then return value(pos, field) end
			local item = items[pos]
			return item and item[fields[field]] or nil
		end,
		bits = function(pos, w, h)
			if api.bits then return api.bits(pos, w, h) end
		end,
		action = opts.on_select,
		activate = opts.on_activate,
		context = opts.on_context,
		changed = opts.on_change,
		type_ahead = opts.type_ahead,
	})
	api.bits = opts.bits
	set("COUNT", opts.count or #items)

	--- Show a plain list of items.
	function api:setItems(next_items)
		items = next_items or {}
		value = nil
		set("COUNT", #items)
	end
	--- Show `count` virtual cells.
	function api:setProvider(count, fn)
		value = fn
		items = {}
		set("COUNT", count or 0)
	end
	--- Set the words shown when there are no cells.
	function api:setEmpty(title, hint)
		set("EMPTYTITLE", title or "")
		set("EMPTYHINT", hint or "")
		iup.Update(widget)
	end
	--- Move the cursor without firing a callback. 0 clears it.
	function api:select(pos) set("VALUE", pos or 0) end
	--- The cursor's position, 0 for none.
	function api:selected() return tonumber(iup.GetAttribute(widget, "VALUE")) or 0 end
	--- Every selected position.
	function api:selection() return M.parseMask(iup.GetAttribute(widget, "SELECTIONMASK")) end
	--- Bring a cell to the start of the view.
	function api:scrollTo(pos) set("SCROLLTO", pos) end
	--- Repaint one cell and nothing else.
	function api:refreshCell(pos) set("REDRAWCELL", pos) end
	--- The first and last positions in view.
	-- @treturn number first @treturn number last
	function api:visibleRange()
		local first, last = (iup.GetAttribute(widget, "VISIBLERANGE") or ""):match("^(%d+):(%d+)$")
		return tonumber(first) or 0, tonumber(last) or 0
	end
	--- Change the image width, keeping the first cell in view.
	function api:setCellWidth(width) set("CELLWIDTH", width) end
	return api
end

--- Feed a grid from a `media_native` cache.
--
-- Sets `grid.bits`: a cell in view looks itself up, and a miss asks the cache for that poster
-- at exactly the cell's pixel size. The returned function collects finished decodes and
-- repaints only their cells; call it from a host timer.
--
-- @tparam table grid from `M.new`
-- @param cache a `media_native` cache
-- @tparam function source `source(pos)` returns a file path or nil, or `path, id`, where `id`
-- names the image if several paths can hold it. Use `{ bytes = data, id = id }` for an image
-- already in memory.
-- @treturn function `drain()`, returning how many posters arrived
function M.posters(grid, cache, source)
	local waiting = {}
	grid.bits = function(pos, w, h)
		local path, id = source(pos)
		if not path then return nil end
		local bytes = type(path) == "table" and path.bytes or nil
		if bytes then id = path.id end
		local key = (id or path) .. "@" .. w .. "x" .. h
		local pixels, stride = cache:get(key)
		if pixels then return pixels, stride end
		waiting[key] = pos
		if bytes then cache:requestBytes(key, bytes, w, h) else cache:request(key, path, w, h) end
		return nil
	end
	return function()
		local finished = cache:drain()
		for _, key in ipairs(finished) do
			local pos = waiting[key]
			if pos then
				waiting[key] = nil
				grid:refreshCell(pos)
			end
		end
		return #finished
	end
end

return M

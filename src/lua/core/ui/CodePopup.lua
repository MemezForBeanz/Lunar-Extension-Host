--- The two small windows a code view raises: the hover card and the completion list.
--
-- Both are borderless child dialogs that never take the keyboard (the editor
-- keeps it, so typing carries on), and both are drawn here, line by line, with
-- colours read from the active theme each time they paint. Scintilla's own
-- calltip and autocomplete list are native windows no theme reaches.
--
-- A language server answers hover in Markdown. It is reduced to what can be
-- drawn safely: fenced code keeps its monospaced face, everything else becomes
-- plain wrapped text with the markup removed. Nothing in it is ever executed,
-- followed or loaded.
--
-- @classmod core.ui.CodePopup
local ok_reactor, ThemeReactor = pcall(require, "core.ui.ThemeReactor")
if not ok_reactor then ThemeReactor = nil end

local CodePopup = {}
CodePopup.__index = CodePopup

local WINDOWS = package.config:sub(1, 1) == "\\"
local MONO = (WINDOWS and "Consolas" or "DejaVu Sans Mono")

--- Widest a hover card's text may be, in characters, and how many lines it shows.
CodePopup.HOVER_COLUMNS = 76
CodePopup.HOVER_LINES = 18
--- Completion: rows shown at once, row height and width in pixels.
CodePopup.ROWS = 9
CodePopup.ROW_HEIGHT = 24
CodePopup.LIST_WIDTH = 380

local PAD_X, PAD_Y = 12, 8

--- What the protocol calls each completion kind, shortened for the list.
CodePopup.KINDS = {
	"text", "method", "function", "constructor", "field", "variable", "class", "interface", "module",
	"property", "unit", "value", "enum", "keyword", "snippet", "color", "file", "reference", "folder",
	"enum member", "constant", "struct", "event", "operator", "type",
}

-- ---------------------------------------------------------------------------
-- Text (pure)
-- ---------------------------------------------------------------------------

--- Break text into lines no wider than `columns`, at spaces where it can.
-- @treturn {string,...}
function CodePopup.wrap(text, columns)
	local out = {}
	for line in (tostring(text or "") .. "\n"):gmatch("(.-)\r?\n") do
		line = line:gsub("\t", "    ")
		if #line <= columns then
			out[#out + 1] = line
		else
			local indent = line:match("^%s*") or ""
			local rest = line
			while #rest > columns do
				local cut = columns
				local space = rest:sub(1, columns + 1):match(".*()%s")
				if space and space > #indent + 8 then cut = space - 1 end
				out[#out + 1] = (rest:sub(1, cut):gsub("%s+$", ""))
				rest = indent .. rest:sub(cut + 1):gsub("^%s+", "")
				if rest == indent then rest = "" end
			end
			if rest ~= "" then out[#out + 1] = rest end
		end
	end
	if out[#out] == "" then out[#out] = nil end
	return out
end

-- Markdown, with its markup removed: what is left is plain prose.
local function plain(text)
	text = text:gsub("\r", "")
	text = text:gsub("!%[([^%]]*)%]%([^%)]*%)", "%1")       -- images: keep the alt text
	text = text:gsub("%[([^%]]+)%]%([^%)]*%)", "%1")        -- links: keep the text, drop the target
	text = text:gsub("<[%a/][^>]->", "")                    -- inline HTML
	text = text:gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")
	local lines = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		if not line:match("^%s*[-*_][-*_%s]+$") or line:match("%w") then   -- a rule is dropped
			line = line:gsub("^%s*#+%s*", "")
			line = line:gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1")
			line = line:gsub("`([^`]*)`", "%1")
			line = line:gsub("\\([%*_`%[%]%(%)#\\<>])", "%1")
			lines[#lines + 1] = line
		end
	end
	-- Collapse runs of blank lines and trim the ends.
	local out, blank = {}, true
	for _, line in ipairs(lines) do
		local empty = line:match("^%s*$") ~= nil
		if not (empty and blank) then out[#out + 1] = empty and "" or line end
		blank = empty
	end
	while out[#out] == "" do out[#out] = nil end
	return table.concat(out, "\n")
end

local function markdown_blocks(text, out)
	local pos = 1
	while true do
		local from, open_end = text:find("```[^\n]*\n", pos)
		if not from then break end
		local close = text:find("\n```", open_end, true)
		local before = plain(text:sub(pos, from - 1))
		if before ~= "" then out[#out + 1] = { text = before } end
		local code = text:sub(open_end + 1, (close or #text + 1) - 1):gsub("%s+$", "")
		if code ~= "" then out[#out + 1] = { text = code, code = true } end
		if not close then return end
		pos = close + 4
	end
	local rest = plain(text:sub(pos))
	if rest ~= "" then out[#out + 1] = { text = rest } end
end

--- Turn a server's hover `contents` into drawable blocks.
-- Accepts every shape the protocol allows: `MarkupContent`, a `MarkedString`
-- (a string or `{ language, value }`), or an array of those.
-- @treturn {table,...} `{ text, code = boolean }`
function CodePopup.blocks(contents)
	local out = {}
	local function add(item)
		if type(item) == "string" then
			markdown_blocks(item, out)
		elseif type(item) == "table" then
			if type(item.value) == "string" then
				if item.language then
					if item.value ~= "" then out[#out + 1] = { text = item.value, code = true } end
				elseif item.kind == "plaintext" then
					if item.value ~= "" then out[#out + 1] = { text = item.value } end
				else
					markdown_blocks(item.value, out)
				end
			else
				for _, part in ipairs(item) do add(part) end
			end
		end
	end
	add(contents)
	return out
end

--- Lay blocks out as lines, wrapped and capped.
-- @treturn {table,...} `{ text, code, kind }`; `kind` is a diagnostic severity
--   name on the lines that came from one, and `"rule"` between sections
function CodePopup.lines(blocks, columns, max_lines)
	columns = columns or CodePopup.HOVER_COLUMNS
	max_lines = max_lines or CodePopup.HOVER_LINES
	local out = {}
	for index, block in ipairs(blocks) do
		if index > 1 then out[#out + 1] = { text = "", kind = "rule" } end
		for _, line in ipairs(CodePopup.wrap(block.text, columns)) do
			out[#out + 1] = { text = line, code = block.code, kind = block.kind }
		end
	end
	if #out > max_lines then
		for i = #out, max_lines + 1, -1 do out[i] = nil end
		out[max_lines] = { text = "...", kind = "more" }
	end
	return out
end

--- Filter and order completion items for what has been typed.
--
-- A prefix match (ignoring case) ranks above a match of the letters in order;
-- within each, the server's own order (`sortText`) is kept.
-- @tparam {table,...} items protocol completion items
-- @tparam string typed the word before the caret
-- @treturn {table,...}
function CodePopup.filter(items, typed)
	typed = (typed or ""):lower()
	local ranked = {}
	for index, item in ipairs(items or {}) do
		local label = tostring(item.label or ""):gsub("^%s+", "")
		local key = tostring(item.filterText or label):gsub("^%s+", ""):lower()
		local rank
		if typed == "" or key:sub(1, #typed) == typed then
			rank = 1
		else
			local at = 1
			rank = 2
			for i = 1, #typed do
				at = key:find(typed:sub(i, i), at, true)
				if not at then rank = nil; break end
				at = at + 1
			end
		end
		if rank then
			ranked[#ranked + 1] = { item = item, label = label, rank = rank,
				sort = tostring(item.sortText or label):lower(), index = index }
		end
	end
	table.sort(ranked, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		if a.sort ~= b.sort then return a.sort < b.sort end
		return a.index < b.index
	end)
	local out = {}
	for i, entry in ipairs(ranked) do
		entry.item._label = entry.label
		out[i] = entry.item
	end
	return out
end

--- The text an accepted completion item inserts.
function CodePopup.insertion(item)
	local edit = item.textEdit
	local text = (type(edit) == "table" and type(edit.newText) == "string" and edit.newText)
		or (type(item.insertText) == "string" and item.insertText)
		or tostring(item.label or "")
	return (text:gsub("^%s+", ""))
end

-- ---------------------------------------------------------------------------
-- Windows
-- ---------------------------------------------------------------------------

local function parse_rgb(value)
	local r, g, b = tostring(value or ""):match("^%s*(%d+)%s+(%d+)%s+(%d+)")
	if not r then return 128, 128, 128 end
	return tonumber(r), tonumber(g), tonumber(b)
end

local function mix(a, b, t)
	local ar, ag, ab = parse_rgb(a)
	local br, bg, bb = parse_rgb(b)
	return string.format("%d %d %d", ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t)
end

--- The popup's colours, from a theme palette.
function CodePopup.colors(palette)
	local p = palette or {}
	local surface = p.layer02 or p.surface2 or p.surface or p.bg or "255 255 255"
	local text = p.text or "0 0 0"
	return {
		surface = surface,
		border = p.borderStrong01 or p.borderStrong or p.border or mix(surface, text, 0.3),
		text = text,
		muted = p.textMuted or mix(text, surface, 0.4),
		selection = p.accentSoft or p.layerSelected01 or mix(surface, text, 0.15),
		accent = p.accentBright or p.accent or text,
		rule = p.borderSubtle01 or p.border or mix(surface, text, 0.15),
		error = p.error or text, warning = p.warning or text, info = p.info or text, hint = p.textMuted or text,
	}
end

--- @tparam table opts
-- @tparam userdata opts.iup
-- @tparam userdata opts.parent the dialog the popup belongs to
-- @tparam[opt] function opts.round `fn(dialog)`: round the window's corners
function CodePopup.new(opts)
	return setmetatable({
		_iup = opts.iup,
		_parent = opts.parent,
		_round = opts.round,
		_mode = nil,       -- "hover" or "list" while showing
		_lines = {},
		_items = {},
		_selected = 1,
		_top = 1,
	}, CodePopup)
end

function CodePopup:_palette()
	local p = (ThemeReactor and ThemeReactor.palette()) or {}
	local size = tonumber(tostring(p.font or ""):match("(%d+)%s*$")) or 10
	local face = tostring(p.font or "Segoe UI, 10"):match("^(.-)%s*,") or "Segoe UI"
	return CodePopup.colors(p), face .. ", " .. size, MONO .. ", " .. size, face .. ", " .. math.max(8, size - 1)
end

function CodePopup:_build()
	if self._dialog then return end
	local iup, popup = self._iup, self
	local canvas = iup.canvas({ BORDER = "NO", EXPAND = "YES", CANFOCUS = "NO" })
	self._canvas = canvas
	self._dialog = iup.dialog({
		canvas,
		BORDER = "NO", MENUBOX = "NO", MAXBOX = "NO", MINBOX = "NO", RESIZE = "NO",
		-- The editor keeps the keyboard: showing this must not activate it.
		SHOWNOACTIVATE = "YES", TOOLBOX = "YES",
		PARENTDIALOG = self._parent,
	})
	function canvas:action()
		popup:_paint()
		return iup.DEFAULT
	end
	function canvas:button_cb(button, pressed, _, y)
		if popup._mode == "list" and button == iup.BUTTON1 and pressed == 1 then
			local row = popup._top + math.floor((y - 4) / CodePopup.ROW_HEIGHT)
			if popup._items[row] then
				popup._selected = row
				if popup._on_accept then popup._on_accept(popup._items[row]) end
			end
		end
		return iup.DEFAULT
	end
	function canvas:wheel_cb(delta)
		if popup._mode == "list" then popup:move(delta > 0 and -3 or 3) end
		return iup.DEFAULT
	end
	iup.Map(self._dialog)
	if self._round then pcall(self._round, self._dialog) end
end

local function fill(iup, canvas, color, x1, y1, x2, y2)
	iup.SetAttribute(canvas, "DRAWSTYLE", "FILL")
	iup.SetAttribute(canvas, "DRAWCOLOR", color)
	iup.DrawRectangle(canvas, x1, y1, x2, y2)
end

local function outline(iup, canvas, color, w, h)
	iup.SetAttribute(canvas, "DRAWSTYLE", "STROKE")
	iup.SetAttribute(canvas, "DRAWCOLOR", color)
	iup.DrawRectangle(canvas, 0, 0, w - 1, h - 1)
end

function CodePopup:_paint()
	local iup, canvas = self._iup, self._canvas
	local colors, body, mono, small = self:_palette()
	iup.DrawBegin(canvas)
	local w, h = iup.DrawGetSize(canvas)
	fill(iup, canvas, colors.surface, 0, 0, w - 1, h - 1)
	iup.SetAttribute(canvas, "DRAWTEXTALIGNMENT", "ALEFT")
	iup.SetAttribute(canvas, "DRAWTEXTELLIPSIS", "YES")
	iup.SetAttribute(canvas, "DRAWTEXTCLIP", "YES")

	if self._mode == "hover" then
		local y = PAD_Y
		for _, line in ipairs(self._lines) do
			if line.kind == "rule" then
				fill(iup, canvas, colors.rule, PAD_X, y + 4, w - PAD_X - 1, y + 4)
				y = y + 9
			else
				iup.SetAttribute(canvas, "DRAWFONT", line.code and mono or body)
				iup.SetAttribute(canvas, "DRAWCOLOR",
					(line.kind and colors[line.kind]) or (line.kind == "more" and colors.muted) or colors.text)
				iup.DrawText(canvas, line.text, PAD_X, y, w - 2 * PAD_X, self._line_height)
				y = y + self._line_height
			end
		end
	elseif self._mode == "list" then
		local row_h = CodePopup.ROW_HEIGHT
		local detail_w = math.floor(w * 0.36)
		for i = 0, CodePopup.ROWS - 1 do
			local item = self._items[self._top + i]
			if not item then break end
			local y = 4 + i * row_h
			if self._top + i == self._selected then
				fill(iup, canvas, colors.selection, 4, y, w - 5, y + row_h - 1)
				fill(iup, canvas, colors.accent, 4, y + 5, 5, y + row_h - 6)
			end
			iup.SetAttribute(canvas, "DRAWFONT", mono)
			iup.SetAttribute(canvas, "DRAWCOLOR", colors.text)
			iup.DrawText(canvas, item._label or tostring(item.label or ""), PAD_X, y + 3, w - detail_w - PAD_X - 8, row_h - 6)
			local detail = (type(item.detail) == "string" and item.detail ~= "" and item.detail)
				or CodePopup.KINDS[tonumber(item.kind) or 0] or ""
			iup.SetAttribute(canvas, "DRAWFONT", small)
			iup.SetAttribute(canvas, "DRAWCOLOR", colors.muted)
			iup.SetAttribute(canvas, "DRAWTEXTALIGNMENT", "ARIGHT")
			iup.DrawText(canvas, (detail:gsub("%s+", " ")), w - detail_w - PAD_X, y + 4, detail_w, row_h - 8)
			iup.SetAttribute(canvas, "DRAWTEXTALIGNMENT", "ALEFT")
		end
		-- Where the window is in the list, when it does not all fit.
		local count = #self._items
		if count > CodePopup.ROWS then
			local track = CodePopup.ROWS * row_h
			local size = math.max(16, math.floor(track * CodePopup.ROWS / count))
			local start = 4 + math.floor((track - size) * (self._top - 1) / (count - CodePopup.ROWS))
			fill(iup, canvas, colors.border, w - 4, start, w - 3, start + size - 1)
		end
	end
	outline(iup, canvas, colors.border, w, h)
	iup.DrawEnd(canvas)
end

-- The pixel size of text in a font, measured on the popup's own canvas.
function CodePopup:_measure(font, text)
	local iup, canvas = self._iup, self._canvas
	local ok, w, h = pcall(function()
		iup.DrawBegin(canvas)
		iup.SetAttribute(canvas, "DRAWFONT", font)
		local tw, th = iup.DrawGetTextSize(canvas, text)
		iup.DrawEnd(canvas)
		return tw, th
	end)
	if ok and w and h and h > 0 then return w, h end
	local size = tonumber(font:match("(%d+)%s*$")) or 10
	return math.floor(#text * size * 0.75), math.floor(size * 1.9)
end

-- Put the window at a text position: below the line, or above it when there is
-- no room, and pulled left when it would run off the screen.
function CodePopup:_showAt(point, width, height)
	local iup = self._iup
	local screen_w, screen_h = tostring(iup.GetGlobal("SCREENSIZE") or ""):match("^(%d+)x(%d+)")
	screen_w, screen_h = tonumber(screen_w) or 1920, tonumber(screen_h) or 1080
	local x = math.max(4, math.min(point.x, screen_w - width - 8))
	local y = point.y + point.line_height + 2
	if y + height > screen_h - 8 then y = math.max(4, point.y - height - 2) end
	iup.SetAttribute(self._dialog, "RASTERSIZE", width .. "x" .. height)
	iup.Refresh(self._dialog)
	iup.ShowXY(self._dialog, x, y)
	iup.Update(self._canvas)
end

--- Is the popup showing? @tparam[opt] string mode `"hover"` or `"list"` to ask for one
function CodePopup:isOpen(mode)
	if not self._mode then return false end
	return mode == nil or self._mode == mode
end

--- Show a hover card.
-- @tparam table point `{ x, y, line_height }` in screen pixels (`CodeView:pointOf`)
-- @tparam {table,...} blocks `{ text, code, kind }` (`CodePopup.blocks`, with a
--   severity name in `kind` for a diagnostic)
-- @treturn boolean false when there was nothing to show
function CodePopup:showHover(point, blocks)
	local lines = CodePopup.lines(blocks)
	if #lines == 0 then
		self:hide("hover")
		return false
	end
	self:_build()
	local _, body, mono = self:_palette()
	local width, text_height = 0, 0
	for _, line in ipairs(lines) do
		if line.kind ~= "rule" then
			local w, h = self:_measure(line.code and mono or body, line.text == "" and " " or line.text)
			width = math.max(width, w)
			text_height = math.max(text_height, h)
		end
	end
	self._line_height = text_height + 2
	local height = 2 * PAD_Y
	for _, line in ipairs(lines) do height = height + (line.kind == "rule" and 9 or self._line_height) end
	self._mode, self._lines = "hover", lines
	self:_showAt(point, math.min(width + 2 * PAD_X + 2, 720), height)
	return true
end

--- Show the completion list.
-- @tparam table point where the word being completed starts
-- @tparam {table,...} items already filtered (`CodePopup.filter`)
-- @tparam function on_accept `fn(item)` for a click on a row
-- @treturn boolean false when the list is empty
function CodePopup:showList(point, items, on_accept)
	if #items == 0 then
		self:hide("list")
		return false
	end
	self:_build()
	self._mode, self._items, self._selected, self._top, self._on_accept = "list", items, 1, 1, on_accept
	local rows = math.min(#items, CodePopup.ROWS)
	self:_showAt(point, CodePopup.LIST_WIDTH, rows * CodePopup.ROW_HEIGHT + 8)
	return true
end

--- Move the selection in the list by a number of rows.
function CodePopup:move(delta)
	if self._mode ~= "list" then return end
	local count = #self._items
	self._selected = math.max(1, math.min(count, self._selected + delta))
	if self._selected < self._top then self._top = self._selected end
	if self._selected >= self._top + CodePopup.ROWS then self._top = self._selected - CodePopup.ROWS + 1 end
	self._iup.Update(self._canvas)
end

--- The selected completion item, or nil.
function CodePopup:selected()
	if self._mode ~= "list" then return nil end
	return self._items[self._selected]
end

--- Hide the popup. With a mode, only when it is showing that.
function CodePopup:hide(mode)
	if not self._mode or (mode and self._mode ~= mode) then return end
	self._mode = nil
	if self._dialog then pcall(self._iup.Hide, self._dialog) end
end

return CodePopup

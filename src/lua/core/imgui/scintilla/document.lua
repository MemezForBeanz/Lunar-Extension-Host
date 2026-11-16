-- Scintilla's Document: the text and everything Scintilla keeps per document, shared by
-- every view attached to it. Ported from scintilla3112 Document.cxx, CellBuffer.cxx
-- (UndoHistory), PerLine.cxx (markers) and RunStyles.cxx (indicators).
-- Positions are byte offsets (SC_CP_UTF8); lines are zero-based.
-- @module core.imgui.scintilla.document
local bit = require("bit")
local bor, band = bit.bor, bit.band

local M = {}
local Doc = {}
Doc.__index = Doc

-- SC_MOD_* / SC_PERFORMED_* (Scintilla.h)
local MOD = {
	INSERTTEXT = 0x1, DELETETEXT = 0x2, CHANGESTYLE = 0x4, USER = 0x10, UNDO = 0x20, REDO = 0x40,
	MULTISTEP = 0x80, LASTSTEP = 0x100, CHANGEMARKER = 0x200, BEFOREINSERT = 0x400,
	BEFOREDELETE = 0x800, MULTILINE = 0x1000, STARTACTION = 0x2000, CHANGEINDICATOR = 0x4000,
	CHANGEANNOTATION = 0x20000, LEXERSTATE = 0x80000,
}
M.MOD = MOD

local WINDOWS = package.config:sub(1, 1) == "\\"
local INSERT, REMOVE, START = 1, 2, 3

-- Handles: SCI_GETDOCPOINTER answers a number, as the native pointer was.
local live, next_handle = {}, 0

--- A new empty document with no references (Document::Document).
function M.new()
	next_handle = next_handle + 1
	local d = setmetatable({
		handle = next_handle, refs = 0, watchers = {},
		text = "", starts = { 0 },
		read_only = false, entered = 0,
		tab_width = 8, eol_mode = WINDOWS and 0 or 2, code_page = 0,
		-- undo history (UndoHistory): a flat list with start markers between groups
		actions = { [0] = { at = START } }, current = 0, max_action = 0, save_point = 0,
		undo_depth = 0, collecting = true,
		-- styling (one byte per byte of text) and the lexer that fills it
		styles = {}, end_styled = 0, styling_pos = 0,
		style_clock = 0, lexer = "", lexer_id = 0, keywords = {}, properties = {},
		marks = {}, next_mark = 0,
		indicators = {}, annotations = {}, annotation_style = {},
	}, Doc)
	return d
end

--- The document a handle names, or nil once it has been released.
function M.from_handle(handle) return live[handle] end

function Doc:add_ref()
	self.refs = self.refs + 1
	live[self.handle] = self
	return self.refs
end

--- Drop a reference; a document nobody refers to is forgotten (Document::Release).
function Doc:release()
	self.refs = self.refs - 1
	if self.refs <= 0 then
		live[self.handle] = nil
		self.released = true
		for _, w in ipairs(self.watchers) do if w.on_deleted then w:on_deleted(self) end end
		self.watchers = {}
	end
	return self.refs
end

function Doc:add_watcher(w)
	for _, x in ipairs(self.watchers) do if x == w then return false end end
	self.watchers[#self.watchers + 1] = w
	return true
end

function Doc:remove_watcher(w)
	for i, x in ipairs(self.watchers) do
		if x == w then table.remove(self.watchers, i); return true end
	end
	return false
end

local function each_watcher(self, method, ...)
	local list = self.watchers
	if #list == 1 then
		if list[1][method] then list[1][method](list[1], self, ...) end
		return
	end
	local copy = {}
	for i, w in ipairs(list) do copy[i] = w end
	for _, w in ipairs(copy) do if w[method] then w[method](w, self, ...) end end
end

function Doc:notify(mh) each_watcher(self, "on_modified", mh) end

-- Lines -------------------------------------------------------------------------------------

function Doc:length() return #self.text end
function Doc:lines_total() return #self.starts end

--- Document::LineStart: past the last line is the end of the text.
function Doc:line_start(line)
	if line < 0 then return 0 end
	return self.starts[line + 1] or #self.text
end

--- Document::LineEnd: where the line's text stops, before its line end characters.
function Doc:line_end(line)
	local starts, text = self.starts, self.text
	if line >= #starts - 1 then return #text end
	if line < 0 then return 0 end
	local p = starts[line + 2] - 1
	if p > starts[line + 1] and text:byte(p) == 13 and text:byte(p + 1) == 10 then p = p - 1 end
	return p
end

--- Document::LineFromPosition.
function Doc:line_from_position(pos)
	local starts = self.starts
	local lo, hi = 1, #starts
	if pos >= starts[hi] then return hi - 1 end
	if pos <= 0 then return 0 end
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if starts[mid] <= pos then lo = mid else hi = mid - 1 end
	end
	return lo - 1
end

function Doc:line_end_position(pos) return self:line_end(self:line_from_position(pos)) end
function Doc:is_line_end_position(pos) return self:line_end_position(pos) == pos end
function Doc:line_text(line) return self.text:sub(self:line_start(line) + 1, self:line_end(line)) end

-- Line starts x with from < x <= to: after "\n", or after a "\r" no "\n" follows.
local function scan_starts(s, from, to, out)
	local p = from + 1
	if p < 1 then p = 1 end
	while true do
		local i = s:find("[\r\n]", p)
		if not i or i > to then return out end
		if s:byte(i) == 10 or s:byte(i + 1) ~= 10 then out[#out + 1] = i end
		p = i + 1
	end
end

-- Characters --------------------------------------------------------------------------------

local function utf8_len(b)
	if not b or b < 192 then return 1 end
	if b < 224 then return 2 end
	if b < 240 then return 3 end
	return 4
end
M.utf8_len = utf8_len

--- Document::MovePositionOutsideChar: never inside a UTF-8 sequence or between CR and LF.
function Doc:outside_char(pos, dir)
	local text = self.text
	if pos <= 0 then return 0 end
	if pos >= #text then return #text end
	if text:byte(pos) == 13 and text:byte(pos + 1) == 10 then
		return dir > 0 and pos + 1 or pos - 1
	end
	local b = text:byte(pos + 1)
	if b >= 128 and b < 192 then
		local start = pos
		while start > 0 and pos - start < 3 do
			local c = text:byte(start + 1)
			if c < 128 or c >= 192 then break end
			start = start - 1
		end
		local lead = text:byte(start + 1)
		if lead >= 192 and start + utf8_len(lead) > pos then
			return dir > 0 and math.min(#text, start + utf8_len(lead)) or start
		end
	end
	return pos
end

--- Document::NextPosition: one character on, a CR LF pair counting as one.
function Doc:next_position(pos, dir)
	local text = self.text
	if dir > 0 then
		if pos >= #text then return #text end
		local b = text:byte(pos + 1)
		if b == 13 and text:byte(pos + 2) == 10 then return pos + 2 end
		return math.min(#text, pos + utf8_len(b))
	end
	if pos <= 0 then return 0 end
	if pos >= 2 and text:byte(pos) == 10 and text:byte(pos - 1) == 13 then return pos - 2 end
	pos = pos - 1
	while pos > 0 do
		local b = text:byte(pos + 1)
		if b < 128 or b >= 192 then break end
		pos = pos - 1
	end
	return pos
end

-- CharClassify: 0 space, 1 line end, 2 punctuation, 3 word
local function char_class(b)
	if not b then return 0 end
	if b == 13 or b == 10 then return 1 end
	if b < 33 then return 0 end
	if b >= 128 or b == 95 or (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then return 3 end
	return 2
end

function Doc:class_after(pos) return char_class(self.text:byte(pos + 1)) end
function Doc:class_before(pos) return char_class(self.text:byte(self:next_position(pos, -1) + 1)) end

--- Document::NextWordStart (SCI_WORDLEFT / SCI_WORDRIGHT).
function Doc:next_word_start(pos, delta)
	local n = #self.text
	if delta < 0 then
		while pos > 0 and self:class_before(pos) == 0 do pos = self:next_position(pos, -1) end
		if pos > 0 then
			local start = self:class_before(pos)
			while pos > 0 and self:class_before(pos) == start do pos = self:next_position(pos, -1) end
		end
	else
		local start = self:class_after(pos)
		while pos < n and self:class_after(pos) == start do pos = self:next_position(pos, 1) end
		while pos < n and self:class_after(pos) == 0 do pos = self:next_position(pos, 1) end
	end
	return pos
end

--- Document::ExtendWordSelect (SCI_WORDSTARTPOSITION / SCI_WORDENDPOSITION).
function Doc:extend_word_select(pos, delta, only_word)
	local n = #self.text
	local start = 3
	if delta < 0 then
		if not only_word then start = self:class_before(pos) end
		while pos > 0 and self:class_before(pos) == start do pos = self:next_position(pos, -1) end
	else
		if not only_word and pos < n then start = self:class_after(pos) end
		while pos < n and self:class_after(pos) == start do pos = self:next_position(pos, 1) end
	end
	return self:outside_char(pos, delta)
end

--- Document::VCHomePosition: the first non-blank of the line, or its start when already there.
function Doc:vc_home_position(pos)
	local line = self:line_from_position(pos)
	local start, finish = self:line_start(line), self:line_end(line)
	local at = start
	while at < finish do
		local b = self.text:byte(at + 1)
		if b ~= 32 and b ~= 9 then break end
		at = at + 1
	end
	if pos == at then return start end
	return at
end

--- Document::GetColumn: tabs go to the next tab stop, every other character is one column.
function Doc:column(pos)
	local line = self:line_from_position(pos)
	local i, col, tab, text = self:line_start(line), 0, self.tab_width, self.text
	while i < pos do
		local b = text:byte(i + 1)
		if not b or b == 13 or b == 10 then return col end
		if b == 9 then col = (math.floor(col / tab) + 1) * tab; i = i + 1
		else col = col + 1; i = i + utf8_len(b) end
	end
	return col
end

--- Document::FindColumn.
function Doc:find_column(line, column)
	local pos, finish, col, tab, text = self:line_start(line), self:line_end(line), 0, self.tab_width, self.text
	if line < 0 or line >= #self.starts then return pos end
	while col < column and pos < finish do
		local b = text:byte(pos + 1)
		if b == 9 then
			col = (math.floor(col / tab) + 1) * tab
			if col > column then return pos end
			pos = pos + 1
		else col = col + 1; pos = pos + utf8_len(b) end
	end
	return math.min(pos, finish)
end

function Doc:line_indentation(line)
	local pos, finish, col, tab, text = self:line_start(line), self:line_end(line), 0, self.tab_width, self.text
	while pos < finish do
		local b = text:byte(pos + 1)
		if b == 32 then col = col + 1
		elseif b == 9 then col = (math.floor(col / tab) + 1) * tab
		else break end
		pos = pos + 1
	end
	return col, pos
end

--- Document::SetLineIndentation (tabs then spaces, as USETABS=YES does).
function Doc:set_line_indentation(line, indent)
	local now, text_start = self:line_indentation(line)
	if indent < 0 then indent = 0 end
	if indent == now then return end
	local tab = self.tab_width
	local lead = string.rep("\t", math.floor(indent / tab)) .. string.rep(" ", indent % tab)
	local start = self:line_start(line)
	self:begin_undo()
	self:delete_chars(start, text_start - start)
	self:insert_string(start, lead)
	self:end_undo()
end

-- Text and undo -----------------------------------------------------------------------------

-- Replace `removed` bytes at `pos` with `s`: the text, its line index and its style bytes.
local function splice(self, pos, removed, s)
	local text, starts = self.text, self.starts
	local old_len, added = #text, #s
	local delta = added - removed
	local tail = old_len - pos - removed
	if delta > 0 then
		for i = old_len - 1, pos + removed, -1 do self.styles[i + delta] = self.styles[i] end
	elseif delta < 0 then
		for i = pos + removed, old_len - 1 do self.styles[i + delta] = self.styles[i] end
		for i = old_len + delta, old_len - 1 do self.styles[i] = nil end
	end
	for i = pos, pos + added - 1 do self.styles[i] = nil end
	self.revision = (self.revision or 0) + 1

	text = text:sub(1, pos) .. s .. text:sub(pos + removed + 1)
	self.text = text
	-- starts in [pos, pos + removed + 1] can change; later ones only move
	local n = #starts
	local lo, hi = 2, n + 1
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		if starts[mid] >= pos then hi = mid else lo = mid + 1 end
	end
	local first = lo
	local last = first - 1
	while last < n and starts[last + 1] <= pos + removed + 1 do last = last + 1 end
	local fresh = scan_starts(text, pos - 1, pos + added + 1, {})
	-- a start exactly at old pos + removed + 1 survives the rescan as pos + added + 1
	local gone, came = last - first + 1, #fresh
	if gone == came then
		for i = 1, came do starts[first + i - 1] = fresh[i] end
		if delta ~= 0 then for i = last + 1, n do starts[i] = starts[i] + delta end end
	else
		local shift = came - gone
		if shift > 0 then
			for i = n, last + 1, -1 do starts[i + shift] = starts[i] + delta end
		else
			for i = last + 1, n do starts[i + shift] = starts[i] + delta end
			for i = n + shift + 1, n do starts[i] = nil end
		end
		for i = 1, came do starts[first + i - 1] = fresh[i] end
	end
	return came - gone
end

local function modified_at(self, pos)
	if self.end_styled > pos then self.end_styled = pos end
end

-- UndoHistory::AppendAction; true when the action starts a new undo step.
local function append_action(self, at, pos, data, may_coalesce)
	local actions = self.actions
	if self.current < self.save_point then self.save_point = -1 end
	local old = self.current
	if self.current >= 1 then
		if self.undo_depth == 0 then
			local prev = actions[self.current - 1]
			if self.current == self.save_point then self.current = self.current + 1
			elseif not actions[self.current].may_coalesce then self.current = self.current + 1
			elseif not may_coalesce or not prev.may_coalesce then self.current = self.current + 1
			elseif at ~= prev.at and prev.at ~= START then self.current = self.current + 1
			elseif at == INSERT and pos ~= prev.pos + #prev.data then self.current = self.current + 1
			elseif at == REMOVE then
				if #data == 1 or #data == 2 then
					-- backspace and delete runs stay one step
					if pos + #data ~= prev.pos and pos ~= prev.pos then self.current = self.current + 1 end
				else self.current = self.current + 1 end
			end
		elseif not actions[self.current].may_coalesce then
			self.current = self.current + 1
		end
	else
		self.current = self.current + 1
	end
	local started = old ~= self.current
	actions[self.current] = { at = at, pos = pos, data = data, may_coalesce = may_coalesce }
	self.current = self.current + 1
	actions[self.current] = { at = START, may_coalesce = true }
	for i = self.current + 1, self.max_action do actions[i] = nil end
	self.max_action = self.current
	return started
end

--- UndoHistory::BeginUndoAction: what follows is one undo step.
function Doc:begin_undo()
	if self.undo_depth == 0 then
		if self.actions[self.current].at ~= START then
			self.current = self.current + 1
			self.actions[self.current] = { at = START }
			self.max_action = self.current
		end
		self.actions[self.current].may_coalesce = false
	end
	self.undo_depth = self.undo_depth + 1
end

function Doc:end_undo()
	if self.undo_depth == 0 then return end
	self.undo_depth = self.undo_depth - 1
	if self.undo_depth == 0 then
		if self.actions[self.current].at ~= START then
			self.current = self.current + 1
			self.actions[self.current] = { at = START }
			self.max_action = self.current
		end
		self.actions[self.current].may_coalesce = false
	end
end

function Doc:can_undo() return self.current > 0 and self.max_action > 0 end
function Doc:can_redo() return self.max_action > self.current end
function Doc:is_save_point() return self.save_point == self.current end

--- SCI_EMPTYUNDOBUFFER: the history goes and the document counts as saved.
function Doc:delete_undo_history()
	self.actions = { [0] = { at = START } }
	self.current, self.max_action, self.save_point, self.undo_depth = 0, 0, 0, 0
end

function Doc:set_undo_collection(on)
	self.collecting = on and true or false
	self.undo_depth = 0
end

--- SCI_SETSAVEPOINT; every view hears SCN_SAVEPOINTREACHED.
function Doc:set_save_point()
	self.save_point = self.current
	each_watcher(self, "on_save_point", true)
end

local function check_read_only(self)
	if self.read_only then each_watcher(self, "on_modify_attempt") end
end

local function shift_lines(self, line, added)
	if added == 0 then return end
	for _, map in ipairs({ self.marks, self.annotations, self.annotation_style }) do
		if next(map) then
			local moved, merged = {}, nil
			for l, v in pairs(map) do
				if l < line then moved[l] = v
				elseif added > 0 then moved[l + added] = v
				elseif l >= line - added then moved[l + added] = v
				elseif map == self.marks then merged = merged or {}; for _, m in ipairs(v) do merged[#merged + 1] = m end end
			end
			-- LineMarkers::RemoveLine: a deleted line's markers stay, on the line before
			if merged and line > 0 then
				local keep = moved[line - 1] or {}
				for _, m in ipairs(merged) do keep[#keep + 1] = m end
				moved[line - 1] = keep
			end
			if map == self.marks then self.marks = moved
			elseif map == self.annotations then self.annotations = moved
			else self.annotation_style = moved end
		end
	end
end

local function shift_indicators(self, pos, removed, added)
	for _, ranges in pairs(self.indicators) do
		local out = 0
		for i = 1, #ranges do
			local r = ranges[i]
			local a, b = r[1], r[2]
			if removed > 0 then
				local stop = pos + removed
				if a > pos then a = a >= stop and a - removed or pos end
				if b > pos then b = b >= stop and b - removed or pos end
			end
			if added > 0 then
				-- RunStyles::InsertSpace: inside a run lengthens it, at either edge does not
				if a >= pos then a = a + added; b = b + added
				elseif b > pos then b = b + added end
			end
			if b > a then
				r[1], r[2] = a, b
				out = out + 1; ranges[out] = r
			end
		end
		for i = out + 1, #ranges do ranges[i] = nil end
	end
end

local function basic_insert(self, pos, s)
	local line = self:line_from_position(pos)
	local at_line_start = pos == self:line_start(line)
	local lines = splice(self, pos, 0, s)
	shift_indicators(self, pos, 0, #s)
	-- CellBuffer::InsertLine: text put in at a line start pushes that line's markers down
	if lines ~= 0 then shift_lines(self, at_line_start and line or line + 1, lines) end
	return lines
end

local function basic_delete(self, pos, len)
	local line = self:line_from_position(pos)
	local lines = splice(self, pos, len, "")
	shift_indicators(self, pos, len, 0)
	if lines ~= 0 then shift_lines(self, line + 1, lines) end
	return lines
end

--- Document::InsertString. Returns the number of bytes inserted (0 when refused).
function Doc:insert_string(pos, s)
	s = tostring(s or "")
	if #s == 0 then return 0 end
	check_read_only(self)
	if self.read_only or self.entered ~= 0 then return 0 end
	pos = math.max(0, math.min(#self.text, pos))
	self.entered = self.entered + 1
	self:notify({ type = bor(MOD.BEFOREINSERT, MOD.USER), position = pos, length = #s, lines_added = 0, text = s })
	local was_saved = self:is_save_point()
	local started = false
	if self.collecting then started = append_action(self, INSERT, pos, s, true) end
	local lines = basic_insert(self, pos, s)
	if was_saved and self.collecting then each_watcher(self, "on_save_point", false) end
	modified_at(self, pos)
	self:notify({ type = bor(MOD.INSERTTEXT, MOD.USER, started and MOD.STARTACTION or 0),
		position = pos, length = #s, lines_added = lines, text = s })
	self.entered = self.entered - 1
	return #s
end

--- Document::DeleteChars.
function Doc:delete_chars(pos, len)
	if len <= 0 or pos < 0 or pos + len > #self.text then return false end
	check_read_only(self)
	if self.entered ~= 0 then return false end
	self.entered = self.entered + 1
	if not self.read_only then
		self:notify({ type = bor(MOD.BEFOREDELETE, MOD.USER), position = pos, length = len, lines_added = 0 })
		local was_saved = self:is_save_point()
		local data = self.text:sub(pos + 1, pos + len)
		local started = false
		if self.collecting then started = append_action(self, REMOVE, pos, data, true) end
		local lines = basic_delete(self, pos, len)
		if was_saved and self.collecting then each_watcher(self, "on_save_point", false) end
		modified_at(self, pos)
		self:notify({ type = bor(MOD.DELETETEXT, MOD.USER, started and MOD.STARTACTION or 0),
			position = pos, length = len, lines_added = lines, text = data })
	end
	self.entered = self.entered - 1
	return not self.read_only
end

-- One step of an undo (`redo` false) or redo; `flags` carry SC_PERFORMED_UNDO/REDO.
local function perform(self, action, insert, flags, steps, last, state)
	local pos, data = action.pos, action.data
	self:notify({ type = bor(insert and MOD.BEFOREINSERT or MOD.BEFOREDELETE, flags), position = pos,
		length = #data, lines_added = 0, text = data })
	local lines = insert and basic_insert(self, pos, data) or basic_delete(self, pos, #data)
	modified_at(self, pos)
	local mod = bor(flags, insert and MOD.INSERTTEXT or MOD.DELETETEXT)
	if steps > 1 then mod = bor(mod, MOD.MULTISTEP) end
	if lines ~= 0 then state.multiline = true end
	if last then
		mod = bor(mod, MOD.LASTSTEP)
		if state.multiline then mod = bor(mod, MOD.MULTILINE) end
	end
	self:notify({ type = mod, position = pos, length = #data, lines_added = lines, text = data })
end

--- Document::Undo. Returns where the caret belongs, or -1 when nothing was undone.
function Doc:undo()
	local new_pos = -1
	check_read_only(self)
	if self.entered ~= 0 or not self.collecting or self.read_only then return new_pos end
	self.entered = self.entered + 1
	local was_saved = self:is_save_point()
	local actions = self.actions
	if actions[self.current].at == START and self.current > 0 then self.current = self.current - 1 end
	local act = self.current
	while actions[act].at ~= START and act > 0 do act = act - 1 end
	local steps = self.current - act
	local state = {}
	local joined_pos, joined_len, prev_pos, prev_len = -1, 0, -1, 0
	for step = 1, steps do
		local action = actions[self.current]
		local reinsert = action.at == REMOVE
		self.current = self.current - 1
		perform(self, action, reinsert, MOD.UNDO, steps, step == steps, state)
		new_pos = action.pos
		if reinsert then
			new_pos = new_pos + #action.data
			-- a run of backspaces or deletes comes back as one stretch
			if joined_len > 0 and (action.pos == prev_pos or action.pos == prev_pos + prev_len) then
				joined_len = joined_len + #action.data
				new_pos = joined_pos + joined_len
			else
				joined_pos, joined_len = action.pos, #action.data
			end
			prev_pos, prev_len = action.pos, #action.data
		else
			joined_pos, joined_len, prev_pos, prev_len = -1, 0, -1, 0
		end
	end
	local saved = self:is_save_point()
	if was_saved ~= saved then each_watcher(self, "on_save_point", saved) end
	self.entered = self.entered - 1
	return new_pos
end

--- Document::Redo.
function Doc:redo()
	local new_pos = -1
	check_read_only(self)
	if self.entered ~= 0 or not self.collecting or self.read_only then return new_pos end
	self.entered = self.entered + 1
	local was_saved = self:is_save_point()
	local actions = self.actions
	if actions[self.current].at == START and self.current < self.max_action then self.current = self.current + 1 end
	local act = self.current
	while actions[act].at ~= START and act < self.max_action do act = act + 1 end
	local steps = act - self.current
	local state = {}
	for step = 1, steps do
		local action = actions[self.current]
		local insert = action.at == INSERT
		self.current = self.current + 1
		perform(self, action, insert, MOD.REDO, steps, step == steps, state)
		new_pos = action.pos
		if insert then new_pos = new_pos + #action.data end
	end
	local saved = self:is_save_point()
	if was_saved ~= saved then each_watcher(self, "on_save_point", saved) end
	self.entered = self.entered - 1
	return new_pos
end

-- Styling and the lexer ---------------------------------------------------------------------

function Doc:style_at(pos)
	if pos < 0 or pos >= #self.text then return 0 end
	return self.styles[pos] or 0
end

local function style_changed(self, pos, len)
	self.style_clock = self.style_clock + 1
	self:notify({ type = bor(MOD.CHANGESTYLE, MOD.USER), position = pos, length = len, lines_added = 0 })
end

--- SCI_STARTSTYLING.
function Doc:start_styling(pos)
	self.styling_pos = math.max(0, math.min(#self.text, pos))
	self.end_styled = self.styling_pos
end

--- SCI_SETSTYLING (Document::SetStyleFor).
function Doc:set_style_for(len, style)
	local pos = self.styling_pos
	len = math.max(0, math.min(len, #self.text - pos))
	for i = pos, pos + len - 1 do self.styles[i] = band(style, 0xFF) end
	self.styling_pos = pos + len
	self.end_styled = self.styling_pos
	if len > 0 then style_changed(self, pos, len) end
end

--- SCI_CLEARDOCUMENTSTYLE.
function Doc:clear_style()
	self.styles = {}
	self.end_styled = 0
	style_changed(self, 0, #self.text)
end

--- SCI_SETLEXERLANGUAGE / SCI_SETLEXER: "" is the container, which styles the text itself.
function Doc:set_lexer(name, id)
	self.lexer, self.lexer_id = name, id
	self.end_styled = 0
	self.style_clock = self.style_clock + 1
	self:notify({ type = MOD.LEXERSTATE, position = 0, length = #self.text, lines_added = 0 })
end

function Doc:set_keywords(set, words)
	self.keywords[set] = tostring(words or "")
	self.keyword_set = nil
	self.end_styled = 0
	self.style_clock = self.style_clock + 1
end

local function keyword_set(self)
	local set = self.keyword_set
	if not set then
		set = {}
		for _, list in pairs(self.keywords) do
			for word in list:gmatch("[%w_]+") do set[word] = true end
		end
		self.keyword_set = set
	end
	return set
end

-- The emulation's one lexer: strings 6, line comments 1, keywords 5, numbers 4, as the
-- Lua and C++ lexers number them. It restarts at a token boundary and runs to `target`.
local function lex(self, target)
	local text, styles, n = self.text, self.styles, #self.text
	local from = self:line_start(self:line_from_position(self.end_styled))
	-- a string may span lines: go back to where it opened
	while from > 0 and styles[from - 1] == 6 do from = from - 1 end
	local stop = self:line_start(self:line_from_position(target) + 1)
	local words = keyword_set(self)
	local pos = from + 1
	while pos <= stop do
		local c = text:byte(pos)
		if not c then break end
		local b, style
		if c == 34 or c == 39 or c == 96 then
			b = text:find(string.char(c), pos + 1, true) or n; style = 6
		elseif c == 35 or ((c == 45 or c == 47) and text:byte(pos + 1) == c) then
			b = text:find("\n", pos, true) or n; style = 1
		elseif c == 95 or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) then
			b = select(2, text:find("^[%a_][%w_]*", pos)); style = words[text:sub(pos, b)] and 5 or 0
		elseif c >= 48 and c <= 57 then
			b = select(2, text:find("^%d+%.?%d*", pos)); style = 4
		end
		if b then
			for i = pos - 1, b - 1 do styles[i] = style end
			pos = b + 1
		else
			styles[pos - 1] = 0
			pos = pos + 1
		end
	end
	self.end_styled = math.min(n, pos - 1)
end

--- Document::EnsureStyledTo: lex up to `pos` if the lexer has not got there yet.
function Doc:ensure_styled_to(pos)
	if pos > #self.text then pos = #self.text end
	if self.end_styled >= pos then return end
	if self.lexer == "" then return end -- the container styles (SCN_STYLENEEDED)
	if self.lexer == "null" then
		for i = self.end_styled, #self.text - 1 do self.styles[i] = nil end
		self.end_styled = #self.text
		return
	end
	lex(self, pos)
end

--- SCI_COLOURISE.
function Doc:colourise(from, to)
	if to < 0 or to > #self.text then to = #self.text end
	if self.end_styled > from then self.end_styled = math.max(0, from) end
	self:ensure_styled_to(to)
	self.style_clock = self.style_clock + 1
end

-- Markers -----------------------------------------------------------------------------------

--- SCI_MARKERADD. Returns the marker's handle, or -1.
function Doc:marker_add(line, number)
	if line < 0 or line >= #self.starts then return -1 end
	self.next_mark = self.next_mark + 1
	local set = self.marks[line] or {}
	self.marks[line] = set
	set[#set + 1] = { handle = self.next_mark, number = number }
	self:notify({ type = MOD.CHANGEMARKER, position = self:line_start(line), length = 0, lines_added = 0, line = line })
	return self.next_mark
end

--- SCI_MARKERDELETE; -1 removes every marker of the line.
function Doc:marker_delete(line, number)
	local set = self.marks[line]
	if not set then return end
	for i = #set, 1, -1 do
		if number == -1 or set[i].number == number then
			table.remove(set, i)
			if number ~= -1 then break end
		end
	end
	if #set == 0 then self.marks[line] = nil end
	self:notify({ type = MOD.CHANGEMARKER, position = self:line_start(line), length = 0, lines_added = 0, line = line })
end

--- SCI_MARKERDELETEALL; -1 removes every marker.
function Doc:marker_delete_all(number)
	for line, set in pairs(self.marks) do
		for i = #set, 1, -1 do
			if number == -1 or set[i].number == number then table.remove(set, i) end
		end
		if #set == 0 then self.marks[line] = nil end
	end
	self:notify({ type = MOD.CHANGEMARKER, position = 0, length = 0, lines_added = 0, line = -1 })
end

--- SCI_MARKERGET: a bit per marker number on the line.
function Doc:marker_get(line)
	local mask = 0
	for _, m in ipairs(self.marks[line] or {}) do
		if m.number < 32 then mask = bor(mask, bit.lshift(1, m.number)) end
	end
	return mask
end

--- SCI_MARKERNEXT / SCI_MARKERPREVIOUS.
function Doc:marker_next(line, mask, dir)
	local last = #self.starts - 1
	local step = dir and dir < 0 and -1 or 1
	if step < 0 then line = math.min(line, last) else line = math.max(line, 0) end
	while line >= 0 and line <= last do
		if band(self:marker_get(line), mask) ~= 0 then return line end
		line = line + step
	end
	return -1
end

function Doc:marker_line_from_handle(handle)
	for line, set in pairs(self.marks) do
		for _, m in ipairs(set) do if m.handle == handle then return line end end
	end
	return -1
end

function Doc:marker_delete_handle(handle)
	for line, set in pairs(self.marks) do
		for i, m in ipairs(set) do
			if m.handle == handle then
				table.remove(set, i)
				if #set == 0 then self.marks[line] = nil end
				return
			end
		end
	end
end

-- Indicators --------------------------------------------------------------------------------

--- SCI_INDICATORFILLRANGE: ranges stay sorted and apart.
function Doc:indicator_fill(indicator, pos, len, value)
	local a, b = math.max(0, pos), math.min(#self.text, pos + len)
	if b <= a then return end
	self:indicator_clear(indicator, a, b - a, true)
	local ranges = self.indicators[indicator] or {}
	self.indicators[indicator] = ranges
	local at = 1
	while at <= #ranges and ranges[at][1] < a do at = at + 1 end
	local fresh = { a, b }
	if value and value ~= 1 then fresh[3] = value end
	-- join a neighbour that touches and carries the same value
	local before, after = ranges[at - 1], ranges[at]
	if before and before[2] == a and before[3] == fresh[3] then
		before[2] = b; fresh = before; at = at - 1
	else
		table.insert(ranges, at, fresh)
	end
	if after and after[1] == b and after[3] == fresh[3] then
		fresh[2] = after[2]
		table.remove(ranges, at + 1)
	end
	self:notify({ type = bor(MOD.CHANGEINDICATOR, MOD.USER), position = a, length = b - a, lines_added = 0 })
end

--- SCI_INDICATORCLEARRANGE.
function Doc:indicator_clear(indicator, pos, len, quiet)
	local ranges = self.indicators[indicator]
	if not ranges then return end
	local a, b = pos, pos + len
	local out = {}
	for _, r in ipairs(ranges) do
		if r[2] <= a or r[1] >= b then out[#out + 1] = r
		else
			if r[1] < a then out[#out + 1] = { r[1], a, r[3] } end
			if r[2] > b then out[#out + 1] = { b, r[2], r[3] } end
		end
	end
	self.indicators[indicator] = out
	if not quiet then
		self:notify({ type = bor(MOD.CHANGEINDICATOR, MOD.USER), position = a, length = len, lines_added = 0 })
	end
end

--- SCI_INDICATORVALUEAT.
function Doc:indicator_value_at(indicator, pos)
	for _, r in ipairs(self.indicators[indicator] or {}) do
		if pos >= r[1] and pos < r[2] then return r[3] or 1 end
	end
	return 0
end

M.Doc = Doc
return M

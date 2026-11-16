local Document = require("core.imgui.scintilla.document")
local Element = require("core.imgui.Element")
local bit = require("bit")
local M = {}
local fields = {
	text = "text", readonly = "read_only", lexer = "lexer", lexer_id = "lexer_id",
	keywords = "keywords", properties = "properties", tab_width = "tab_width",
	indicators = "indicators", annotations = "annotations", annotation_style = "annotation_style",
}
function M.detach(st)
	local d = st.data
	if d.doc then d.doc:remove_watcher(d.watcher); d.doc:release(); d.doc = nil end
end
function M.attach(e, st, doc)
	local d = st.data
	doc:add_ref()
	M.detach(st)
	d.doc = doc
	for k in pairs(fields) do rawset(d, k, nil) end
	rawset(d, "modified", nil)
	rawset(d, "markers", nil)
	setmetatable(d, {
		__index = function(t, k)
			if k == "markers" then
				local markers = {}
				for line, marks in pairs(t.doc.marks) do for _, mark in ipairs(marks) do markers[mark.number] = line end end
				return markers
			end
			if k == "modified" then return not t.doc:is_save_point() end
			if fields[k] then return t.doc[fields[k]] end
		end,
		__newindex = function(t, k, v)
			if fields[k] then t.doc[fields[k]] = v
			elseif k ~= "modified" then rawset(t, k, v) end
		end,
	})
	d.caret, d.anchor, d.first_line, d.x_offset, d.last_x = 0, 0, 0, 0, nil
	d.target_start, d.target_end = 0, 0
	d.wrap_cache = nil
	local function shift(p, mh)
		if bit.band(mh.type, 1) ~= 0 then return p >= mh.position and p + mh.length or p end
		return p > mh.position and math.max(mh.position, p - mh.length) or p
	end
	d.watcher = {
		on_modified = function(_, _, mh)
			if bit.band(mh.type, 3) ~= 0 then
				d.caret, d.anchor = shift(d.caret, mh), shift(d.anchor, mh)
				d.wrap_cache = nil
				Element.call(e, "VALUECHANGED_CB")
				Element.call(e, "UPDATECONTENT_CB")
				if mh.lines_added ~= 0 then Element.call(e, "LINESCHANGED_CB", doc:line_from_position(mh.position), mh.lines_added) end
			end
			Element.call(e, "MODIFIED_CB", mh.position, mh.type, mh.text or "", mh.length, mh.lines_added or 0, mh.line or 0, 0, 0)
		end,
		on_save_point = function(_, _, saved) Element.call(e, "SAVEPOINT_CB", saved and 1 or 0) end,
		on_modify_attempt = function() Element.call(e, "READONLY_CB") end,
	}
	doc:add_watcher(d.watcher)
end
function M.create(e, st)
	local text = st.data.text or ""
	local doc = Document.new()
	doc.tab_width, doc.lexer = 4, "null"
	doc:insert_string(0, text)
	doc:delete_undo_history()
	doc.read_only = st.data.readonly or false
	M.attach(e, st, doc)
	st.data.caret, st.data.anchor = #text, #text
end
function M.edit(st, a, b, value)
	local d, doc = st.data, st.data.doc
	if doc.read_only then return false end
	doc:begin_undo()
	if b > a then doc:delete_chars(a, b - a) end
	doc:insert_string(a, value)
	doc:end_undo()
	d.caret, d.anchor = a + #value, a + #value
	return true
end
return M

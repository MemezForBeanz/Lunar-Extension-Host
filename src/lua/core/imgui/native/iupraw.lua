--- The `iupraw` module on the ImGui host: a port of src/c/libs/iupraw_wrap.c.
--
-- The C bridge stores each control's Lua callback table and installs C callbacks under the
-- names the fork's controls look up (CELLVALUE_CB, ROWBITS_CB, SEEK_CB...), each forwarding
-- to the Lua function with the arguments below. Here the control is an element, so the
-- forwarding functions become the element's callbacks under the same names, and a callback
-- set later on the element replaces one of them exactly as IupSetCallback would.
--
--   value(pos, field) -> string|nil         CELLVALUE_CB / ROWVALUE_CB
--   bits(pos, w, h) -> pixels, stride        CELLBITS_CB / ROWBITS_CB (ROWBITS_CB only when
--                                            bits is given: it reserves the row's art slot)
--   action(pos, "")                          CELL_ACTION_CB / ROW_ACTION_CB
--   part(pos, part)                          ROW_PART_CB
--   activate(pos, how) / context(pos, how)   CELL_/ROW_ACTIVATE_CB, CELL_/ROW_CONTEXT_CB
--   changed(VALUE, "")                       VALUECHANGED_CB (rows, grid)
--   header(column, "")                       HEADER_CB
--   type_ahead(text) -> pos|nil              TYPEAHEAD_CB (-1 when it returns no number)
--   seek(value, 0) / changing(value, 0) / hover(value, x)   SEEK_CB / VALUECHANGING_CB / HOVER_CB
--   changed(VALUEPOS)                        VALUECHANGED_CB (segmented)
-- @module core.imgui.native.iupraw
local Element = require("core.imgui.Element")

local M = {}

local function new(name)
	return function(init) return Element.new(name, init) end
end

M.flatrows = new("flatrows")
M.flatsegmented = new("flatsegmented")
M.flatgrid = new("flatgrid")
M.flatseek = new("flatseek")
M.videohost = new("videohost")

--- iupraw.ptr: the handle itself stands for the Ihandle* here, nil for anything else.
function M.ptr(handle)
	return Element.is(handle) and handle or nil
end

local function check(handle, values)
	if not Element.is(handle) then error("bad argument #1 to 'bind' (iuplua handle expected)", 3) end
	if type(values) ~= "table" then error("bad argument #2 to 'bind' (table expected)", 3) end
end

local function int(e, name) return math.floor(tonumber(Element.getAttribute(e, name)) or 0) end

-- position_event: fn(pos, part or "")
local function position(values, key)
	return function(_, pos, part)
		local fn = values[key]
		if type(fn) == "function" then pcall(fn, pos, part or "") end
		return -2 -- IUP_DEFAULT
	end
end
-- provider_value: tostring'd value or nil
local function value(values)
	return function(_, pos, field)
		local fn = values.value
		if type(fn) ~= "function" then return nil end
		local ok, v = pcall(fn, pos, field)
		if not ok or v == nil then return nil end
		if type(v) == "number" then return tostring(v) end
		if type(v) ~= "string" then return nil end
		return v
	end
end
-- provider_bits: (pixels, stride) when pixels are a pointer
local function bits(values)
	return function(_, pos, w, h)
		local fn = values.bits
		if type(fn) ~= "function" then return nil end
		local ok, px, stride = pcall(fn, pos, w, h)
		if not ok then return nil end
		local t = type(px)
		if t ~= "userdata" and t ~= "cdata" and t ~= "string" then return nil end
		return px, tonumber(stride) or 0
	end
end
local function changed(values)
	return function(e)
		local fn = values.changed
		if type(fn) == "function" then pcall(fn, int(e, "VALUE"), "") end
		return -2
	end
end

function M.bindrows(handle, values)
	check(handle, values)
	handle.ROWVALUE_CB = value(values)
	handle.ROW_ACTION_CB = position(values, "action")
	handle.ROW_PART_CB = position(values, "part")
	handle.ROW_ACTIVATE_CB = position(values, "activate")
	handle.ROW_CONTEXT_CB = position(values, "context")
	handle.VALUECHANGED_CB = changed(values)
	handle.HEADER_CB = position(values, "header")
	-- Its presence is what reserves the art slot on every row.
	local st = Element.state(handle)
	st.cbs.ROWBITS_CB = type(values.bits) == "function" and bits(values) or nil
end

function M.bindgrid(handle, values)
	check(handle, values)
	handle.CELLVALUE_CB = value(values)
	handle.CELLBITS_CB = bits(values)
	handle.CELL_ACTION_CB = position(values, "action")
	handle.CELL_ACTIVATE_CB = position(values, "activate")
	handle.CELL_CONTEXT_CB = position(values, "context")
	handle.TYPEAHEAD_CB = function(_, text)
		local fn = values.type_ahead
		if type(fn) ~= "function" then return -1 end
		local ok, pos = pcall(fn, text)
		if ok and type(pos) == "number" then return math.floor(pos) end
		return -1
	end
	handle.VALUECHANGED_CB = changed(values)
end

function M.bindseek(handle, values)
	check(handle, values)
	local function seek_event(key)
		return function(_, v, x)
			local fn = values[key]
			if type(fn) == "function" then pcall(fn, v, x or 0) end
			return -2
		end
	end
	handle.SEEK_CB = seek_event("seek")
	handle.VALUECHANGING_CB = seek_event("changing")
	handle.HOVER_CB = seek_event("hover")
end

function M.bindsegmented(handle, values)
	check(handle, values)
	handle.VALUECHANGED_CB = function(e)
		local fn = values.changed
		if type(fn) == "function" then pcall(fn, int(e, "VALUEPOS")) end
		return -2
	end
end

return M

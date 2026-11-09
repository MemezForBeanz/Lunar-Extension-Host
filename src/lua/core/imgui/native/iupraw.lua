-- Lua replacement for the small iupraw bridge used by Lunar's virtual controls.
-- Native builds expose lightuserdata; the ImGui tree uses the element handle itself.
-- @module core.imgui.native.iupraw
local Element = require("core.imgui.Element")
local Raw = require("core.imgui.widgets.raw")

local M = {}

local function new(name)
	return function(init)
		return Element.new(name, init)
	end
end

M.flatrows = new("flatrows")
M.flatsegmented = new("flatsegmented")
M.flatgrid = new("flatgrid")
M.flatseek = new("flatseek")
M.videohost = new("videohost")

function M.ptr(handle)
	return Element.is(handle) and handle or nil
end

local function bind(handle, values)
	if not Element.is(handle) then error("iupraw: widget handle expected", 2) end
	if type(values) ~= "table" then error("iupraw: callback table expected", 2) end
	return values
end

function M.bindrows(handle, values)
	values = bind(handle, values)
	Raw.bind(handle, "value", values.value)
	Raw.bind(handle, "action", values.action)
	Raw.bind(handle, "part", values.part)
	Raw.bind(handle, "activate", values.activate)
	Raw.bind(handle, "context", values.context)
	Raw.bind(handle, "changed", values.changed)
	Raw.bind(handle, "header", values.header)
	Raw.bind(handle, "bits", values.bits)
end

function M.bindgrid(handle, values)
	values = bind(handle, values)
	Raw.bind(handle, "value", values.value)
	Raw.bind(handle, "bits", values.bits)
	Raw.bind(handle, "action", values.action)
	Raw.bind(handle, "activate", values.activate)
	Raw.bind(handle, "context", values.context)
	Raw.bind(handle, "changed", values.changed)
	Raw.bind(handle, "type_ahead", values.type_ahead)
end

function M.bindseek(handle, values)
	values = bind(handle, values)
	Raw.bind(handle, "seek", values.seek)
	Raw.bind(handle, "changing", values.changing)
	Raw.bind(handle, "hover", values.hover)
end

function M.bindsegmented(handle, values)
	values = bind(handle, values)
	Raw.bind(handle, "changed", values.changed)
end

return M

-- Native child surface for libmpv. The IUP videohost class creates a native child
-- during mapping and keeps it aligned with the placed rectangle.
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")

local M = {}

local function backend()
	return require("core.imgui.Runtime").backend()
end

local function attr(e, name)
	return Element.getAttribute(e, name)
end

local function native_id(e)
	return Element.state(e).data.window_id
end

local function ensure(e, B)
	local st = Element.state(e)
	if st.data.window_id then return st.data.window_id end
	B = B or backend()
	if B and B.window then
		local id = B.window("videohost_create", attr(e, "BGCOLOR") or "0 0 0")
		if id and id ~= 0 then st.data.window_id = id end
	end
	return st.data.window_id
end

Classes.define{
	name = "videohost",
	children = 0,
	expandDefault = "YES", -- vh_create: IupSetAttribute(ih, "EXPAND", "YES")
	defaults = { BGCOLOR = "0 0 0", BORDER = "NO", EXPAND = "YES" },
	map = function(e)
		-- Native windows are created lazily if the dialog has not opened yet.
		local st = Element.state(e)
		st.data.mapped = true
		if st.data.window_id == 0 then st.data.window_id = nil end
	end,
	unmap = function(e)
		local id = native_id(e)
		local B = backend()
		if id and B and B.window then B.window("videohost_destroy", id) end
		Element.state(e).data.window_id = nil
	end,
	destroy = function(e)
		local id = native_id(e)
		local B = backend()
		if id and B and B.window then B.window("videohost_destroy", id) end
	end,
	natural = function() return 320, 180 end,
	draw = function(e, st, dc)
		local B = backend()
		local id = st.mapped and ensure(e, B) or 0
		if not st.mapped and not st.data.window_id then st.data.window_id = 0 end
		dc:fill(st.x, st.y, st.w, st.h, attr(e, "BGCOLOR") or "0 0 0")
		if id and B and B.window then
			B.window("videohost", id, { x = st.x, y = st.y, w = st.w, h = st.h }, true)
		end
		st.data.rect = { x = st.x, y = st.y, w = st.w, h = st.h }
	end,
	get = {
		-- the native child exists from map, as IUP's does
		WINDOWID = function(e)
			local id = Element.state(e).mapped and ensure(e) or native_id(e)
			return id and tostring(id) or nil
		end,
		WID = function(e)
			local id = native_id(e)
			return id and tostring(id) or nil
		end,
		HWND = function(e)
			local id = native_id(e)
			return id and tostring(id) or nil
		end,
	},
	methods = {
		windowId = function(e)
			local st = Element.state(e)
			local id = st.mapped and ensure(e) or 0
			return id and tostring(id) or nil
		end,
		rect = function(e) return Element.state(e).data.rect end,
	},
}

return M

local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Draw = require("core.imgui.Draw")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")

describe("ImGui raw widgets", function()
	local B, dc, rt, raw
	before_each(function()
		B = Null.new(); Fonts.backend = B; Fonts.reset()
		Element.globals.DEFAULTFONT = "Segoe UI, 10"
		Element.globals.DLGBGCOLOR = "240 240 240"
		Element.globals.DLGFGCOLOR = "0 0 0"
		dc = Draw.new(B); dc:begin(800, 600)
		rt = { backend = B, redraw = function() end, capture = function() end, release = function() end, setFocus = function() end }
		raw = require("core.imgui.native.iupraw")
	end)

	it("binds virtual rows and only queries visible rows", function()
		local seen = {}
		local w = raw.flatrows(); iup.SetAttribute(w, "COUNT", 1000)
		raw.bindrows(w, { value = function(pos, field) seen[#seen + 1] = { pos, field }; return field .. pos end })
		local st = Element.state(w); st.x, st.y, st.w, st.h = 0, 0, 300, 64
		require("core.imgui.Classes").get("flatrows").draw(w, st, dc, rt)
		assert.is_true(#seen < 20)
		local found = false
		for _, item in ipairs(seen) do if item[2] == "TITLE" and item[1] == 1 then found = true end end
		assert.is_true(found)
	end)

	it("handles segmented selection and seek callbacks", function()
		local selected, seeked
		local seg = raw.flatsegmented(); iup.SetAttribute(seg, "COUNT", 3)
		raw.bindsegmented(seg, { changed = function(pos) selected = pos end })
		local ss = Element.state(seg); ss.x, ss.y, ss.w, ss.h = 0, 0, 300, 32
		local cls = require("core.imgui.Classes").get("flatsegmented")
		cls.event(seg, ss, { type = "press", button = 1, lx = 210, ly = 10 }, rt)
		assert.equals(2, selected)
		local seek = raw.flatseek(); iup.SetAttribute(seek, "MAX", "100")
		raw.bindseek(seek, { seek = function(v) seeked = v end })
		local ks = Element.state(seek); ks.x, ks.y, ks.w, ks.h = 0, 0, 100, 24
		require("core.imgui.Classes").get("flatseek").event(seek, ks, { type = "press", button = 1, lx = 50, ly = 10 }, rt)
		require("core.imgui.Classes").get("flatseek").event(seek, ks, { type = "release", button = 1, lx = 50, ly = 10 }, rt)
		assert.equals(50, math.floor(seeked + .5))
	end)

	it("exposes video host geometry and backend window handle", function()
		local host = raw.videohost(); local st = Element.state(host); st.x, st.y, st.w, st.h = 10, 20, 320, 180
		require("core.imgui.Classes").get("videohost").draw(host, st, dc, rt)
		assert.equals("0", iup.GetAttribute(host, "WINDOWID"))
		assert.same({ x = 10, y = 20, w = 320, h = 180 }, host:rect())
	end)
end)

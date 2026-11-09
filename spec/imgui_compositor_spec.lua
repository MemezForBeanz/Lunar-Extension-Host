local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Element = require("core.imgui.Element")
local Draw = require("core.imgui.Draw")
local iup = require("core.imgui.iup")
local Runtime = require("core.imgui.Runtime")
local compositor = require("core.imgui.native.compositor")
local Compositor = require("core.lib.Compositor")
local Scrim = require("core.ui.Scrim")

describe("ImGui compositor", function()
	local B, dc, dialog, canvas, overlay

	before_each(function()
		B = Null.new({ w = 320, h = 200 })
		Fonts.backend = B
		Fonts.reset()
		Element.globals.DEFAULTFONT = "Segoe UI, 10"
		Runtime.init(B)
		canvas = iup.canvas({ BGCOLOR = "20 30 40", BORDER = "NO" })
		dialog = iup.dialog(iup.vbox({ canvas }))
		Runtime.show(dialog, 0, 0)
		local ds = Element.state(dialog)
		local cs = Element.state(canvas)
		ds.w, ds.h, ds.data.layout_dirty = 320, 200, false
		cs.x, cs.y, cs.w, cs.h, cs.mapped = 10, 12, 40, 20, true
		dc = Runtime.dc()
		overlay = assert(compositor.overlay(dialog))
	end)

	it("reports support and records snapshots without drawing them", function()
		local before = #B.frame_calls
		local snap = assert(overlay:snapshot(canvas))
		assert.equals(40, snap.w)
		assert.equals(20, snap.h)
		assert.is_true(#snap.calls > 0)
		assert.equals(before, #B.frame_calls)
	end)

	it("replays image and solid sprites at an offset and alpha", function()
		local snap = assert(overlay:snapshot(canvas))
		assert.is_true(overlay:present({
			{ kind = "image", x = 70, y = 30, snap = snap, alpha = 1 },
			{ kind = "fill", x = 2, y = 3, w = 8, h = 6, color = 0xff0000, alpha = 0.5 },
		}, {}, 0.5))
		B.queue({})
		Runtime.frame()
		local found_image, found_fill = false, false
		for _, call in ipairs(B.lastFrame()) do
			if call[1] == "rect_filled" and call[2] == 70 and call[3] == 30 then found_image = true end
			if call[1] == "rect_filled" and call[2] == 2 and call[3] == 3 then found_fill = true end
		end
		assert.is_true(found_image)
		assert.is_true(found_fill)
		overlay:fade(0.25)
		assert.is_true(overlay:isOpen())
		overlay:hide()
		assert.is_false(overlay:isOpen())
	end)

	it("keeps a crossfade live across advancing frames", function()
		local first = assert(overlay:snapshot(canvas))
		local second = assert(overlay:snapshot(canvas))
		overlay:present({
			{ kind = "image", x = 0, y = 0, snap = first, alpha = 1 },
			{ kind = "image", x = 0, y = 0, snap = second, alpha = 1 },
		}, {}, 0.4)
		for _ = 1, 3 do
			B.queue({})
			Runtime.frame()
			B.advance(0.016)
		end
		assert.is_true(overlay:isOpen())
		overlay:hide()
		B.queue({})
		Runtime.frame()
		assert.is_false(overlay:isOpen())
	end)

	it("draws a passive scrim over the dialog", function()
		local manager = Compositor.new(overlay)
		local scrim = Scrim:new({
			dialog = dialog,
			cover = dialog,
			compositor = function() return manager end,
		})
		assert.is_true(scrim:prepare())
		scrim._alpha = 128
		scrim:_place()
		assert.is_true(manager:commit())
		B.queue({})
		Runtime.frame()
		local dimmed = false
		local seen = {}
		for _, call in ipairs(B.lastFrame()) do
			seen[#seen + 1] = table.concat({ tostring(call[1]), tostring(call[2]), tostring(call[3]),
				tostring(call[4]), tostring(call[5]) }, ",")
			if call[1] == "rect_filled" and call[2] == 0 and call[3] == 0 and
				call[4] == 320 and call[5] == 200 then
				dimmed = true
			end
		end
		assert.is_true(dimmed, "no scrim fill in " .. table.concat(seen, ";"))
		scrim:reset()
	end)
end)

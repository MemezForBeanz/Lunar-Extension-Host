-- spec/imgui_scrim_video_spec.lua -- the modal scrim covers native video too.
--
-- On IUP the page under a modal dims through a layered window above everything, native
-- video included. On the ImGui host the dim is drawn on the main surface, and a native
-- video child sits above that surface, so the host adds a click-through overlay window over
-- each video rectangle, filled with the scrim colour and stacked directly under the modal
-- dialog's own window (overlay_open's `under`), so it never dims the modal itself.

local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")

describe("modal scrim over native video", function()
	local B, main, video
	before_each(function()
		B = Null.new({ w = 800, h = 600, dialog_windows = true, overlay_windows = true })
		R.init(B)
		video = iup.videohost{ RASTERSIZE = "320x180" }
		main = iup.dialog{ iup.vbox{ video }, RASTERSIZE = "800x600" }
		iup.Show(main); R.frame()
	end)
	after_each(function() R.close() end)

	local function scrims()
		local list = {}
		for id, o in pairs(B.overlays) do
			if o.visible and o.under ~= 0 then list[#list + 1] = { id = id, o = o } end
		end
		return list
	end

	-- Runs `body(d)` from a timer while `d` is up as a modal (iup.Popup blocks), and hides
	-- it afterwards.
	local function while_modal(body)
		local d = iup.dialog{ iup.vbox{ iup.label{ TITLE = "Sure?" } }, TITLE = "Confirm", RASTERSIZE = "240x120" }
		local frames, done = 0, false
		local t = iup.timer{ TIME = 10 }
		t.action_cb = function()
			frames = frames + 1
			if frames >= 3 and not done then
				done = true
				body(d)
				t.run = "NO"
				iup.Hide(d)
			end
			return iup.DEFAULT
		end
		t.run = "YES"
		iup.Popup(d, iup.CENTER, iup.CENTER)
		return d
	end

	it("puts one click-through patch over the video, under the modal's window", function()
		local seen
		while_modal(function(d)
			R.frame()
			local st, vs = Element.state(d), Element.state(video)
			seen = scrims()
			assert.equal(1, #seen)
			local o = seen[1].o
			assert.is_true(o.passthrough)
			assert.equal(st.data.win, o.under)
			-- the patch covers the whole video rectangle
			assert.is_true(o.x <= vs.x and o.y <= vs.y)
			assert.is_true(o.x + o.w >= vs.x + vs.w and o.y + o.h >= vs.y + vs.h)
		end)
		assert.equal(1, #seen)
		R.frame()
		assert.equal(0, #scrims()) -- gone with the modal
	end)

	it("fills the patch with the scrim colour on the patch's own surface", function()
		local filled = false
		while_modal(function()
			R.frame()
			local id = scrims()[1].id
			local on = 0
			for _, c in ipairs(B.lastFrame()) do
				if c[1] == "surface" then on = c[2]
				elseif on == id and c[1] == "rect_filled" then filled = true end
			end
		end)
		assert.is_true(filled)
	end)

	it("adds nothing when no video is visible", function()
		video.visible = "NO"; R.frame()
		local count
		while_modal(function() R.frame(); count = #scrims() end)
		assert.equal(0, count)
	end)

	it("adds nothing for a modeless dialog", function()
		local d = iup.dialog{ iup.vbox{ iup.label{ TITLE = "tool" } }, TITLE = "Tool", RASTERSIZE = "200x100" }
		iup.Show(d); R.frame(); R.frame()
		assert.equal(0, #scrims())
	end)
end)

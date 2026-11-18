-- spec/imgui_dialog_windows_spec.lua -- secondary dialogs as their own native windows.
--
-- On IUP a secondary dialog is a window of its own: Windows draws its frame and caption,
-- the user moves and sizes it, and its close button runs CLOSE_CB. The ImGui host gives
-- such a dialog an owned native window (lunarimgui's window("popup_*")) whose client sits
-- at the dialog's (ox, oy) in main-window coordinates, and draws its tree there. The Null
-- backend plays lunarimgui here (opts.dialog_windows) and records which surface each draw
-- call lands on.

local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")

describe("secondary dialogs as native windows", function()
	local B, main
	before_each(function()
		B = Null.new({ w = 800, h = 600, dialog_windows = true })
		R.init(B)
		main = iup.dialog{ iup.vbox{ iup.label{ TITLE = "main page" } }, RASTERSIZE = "800x600" }
		iup.Show(main); R.frame()
	end)

	local function secondary(extra)
		local attrs = { iup.vbox{ iup.label{ TITLE = "inside" }, iup.button{ TITLE = "Go", RASTERSIZE = "60x24" } },
			TITLE = "Settings", RASTERSIZE = "300x200", MINBOX = "NO", MAXBOX = "NO" }
		for k, v in pairs(extra or {}) do attrs[k] = v end
		return iup.dialog(attrs)
	end
	local function only_popup()
		local id, p = next(B.popups)
		return id, p
	end
	it("retains the logical dialog as a panel if its swap chain cannot be restored", function()
		local dlg=secondary()
		iup.Show(dlg); R.frame()
		local id=only_popup()
		local window=B.window
		B.window=function(op,...)
			if op=="popup_ready" and select(1,...)==id then return false end
			return window(op,...)
		end
		R.frame()
		assert.is_false(Element.state(dlg).data.win)
		assert.is_nil(B.popups[id])
		assert.equal(2,#R.dialogs())
		R.frame()
	end)
	-- the surface each text was drawn on in the last frame
	local function text_surfaces()
		local out, surface = {}, 0
		for _, c in ipairs(B.lastFrame()) do
			if c[1] == "surface" then surface = c[2]
			elseif c[1] == "text" then out[c[7]] = surface end
		end
		return out
	end

	it("opens an owned window with IUP's frame styles and places its client at (ox, oy)", function()
		local d = secondary({ RESIZE = "YES" })
		iup.Show(d); R.frame()
		local id, p = only_popup()
		assert.is_not_nil(id)
		assert.is_true(p.opts.caption)
		assert.is_true(p.opts.menubox)
		assert.is_false(p.opts.minbox)
		assert.is_false(p.opts.maxbox)
		assert.is_true(p.opts.resize)
		assert.equal("Settings", p.opts.title)
		local st = Element.state(d)
		assert.is_true(p.visible)
		assert.equal(st.data.ox, p.x); assert.equal(st.data.oy, p.y)
		assert.equal(st.w, p.w); assert.equal(st.h, p.h)
		assert.equal("Settings", p.title)
	end)

	it("follows winDialogMapMethod: RESIZE=NO drops MAXBOX, PARENTDIALOG owns it", function()
		local d = secondary({ RESIZE = "NO", MAXBOX = "YES", PARENTDIALOG = main })
		iup.Show(d); R.frame()
		local _, p = only_popup()
		assert.is_false(p.opts.maxbox)
		assert.is_false(p.opts.resize)
		assert.is_true(p.opts.border)
		assert.is_true(p.opts.owned)
		assert.equal(0, p.opts.parent)
		iup.Destroy(d)
		local free = secondary()
		iup.Show(free); R.frame()
		local _, q = only_popup()
		assert.is_false(q.opts.owned) -- a top-level window with a taskbar button, as on IUP
	end)

	it("routes the pointer by the window it is over, whatever the stacking order", function()
		local d = secondary()
		local hits = 0
		iup.Show(d); R.frame()
		local id = only_popup()
		local btn = iup.GetChild(iup.GetChild(d, 0), 1)
		btn.action = function() hits = hits + 1 end
		local st, bs = Element.state(d), Element.state(btn)
		local x, y = st.data.ox + bs.x + 10, st.data.oy + bs.y + 10
		-- the main window is over the dialog here (an unowned dialog behind it)
		B.queue({ events = { { type = "press", button = 1, x = x, y = y, win = 0 } } }); R.frame()
		B.queue({ events = { { type = "release", button = 1, x = x, y = y, win = 0 } } }); R.frame()
		assert.equal(0, hits)
		B.queue({ events = { { type = "press", button = 1, x = x, y = y, win = id } } }); R.frame()
		B.queue({ events = { { type = "release", button = 1, x = x, y = y, win = id } } }); R.frame()
		assert.equal(1, hits)
	end)

	it("has its window from IupMap on, so the app can theme the frame before it shows", function()
		local d = secondary()
		iup.Map(d)
		-- core.ui.WindowChrome.adopt reads the HWND right after mapping (ModalMotion.popup)
		local IupFFI = require("core.imgui.native.iupffi")
		local h = IupFFI.getptr(d, "HWND")
		assert.is_not_nil(h)
		local id, p = only_popup()
		assert.equal(5000 + id, tonumber(require("ffi").cast("uintptr_t", h)))
		assert.is_false(p.visible) -- made, not shown
		assert.equal(tostring(5000 + id), iup.GetAttribute(d, "HWND"))
		iup.Show(d); R.frame()
		assert.equal(id, (only_popup())) -- the same window shows
		assert.is_true(B.popups[id].visible)
	end)

	it("draws the dialog's tree on its window and the main page on the main one", function()
		local d = secondary()
		iup.Show(d); R.frame()
		local id = only_popup()
		local at = text_surfaces()
		assert.equal(id, at["inside"])
		assert.equal(0, at["main page"])
		-- Windows draws the caption: no title band painted by the host
		assert.is_nil(at["Settings"])
	end)

	it("follows the window when the user moves it, with MOVE_CB", function()
		local d = secondary()
		local moved
		d.move_cb = function(_, x, y) moved = { x, y } end
		iup.Show(d); R.frame()
		local _, p = only_popup()
		p.x, p.y = -150, 40 -- dragged left of the main window
		R.frame()
		local st = Element.state(d)
		assert.equal(-150, st.data.ox); assert.equal(40, st.data.oy)
		assert.same({ -150, 40 }, moved)
	end)

	it("routes a click on the window, even outside the main window's area", function()
		local d = secondary()
		local hits = 0
		iup.Show(d); R.frame()
		local _, p = only_popup()
		p.x, p.y = -150, 40
		R.frame()
		local btn = iup.GetChild(iup.GetChild(d, 0), 1)
		btn.action = function() hits = hits + 1 end
		local bs = Element.state(btn)
		local x, y = -150 + bs.x + 10, 40 + bs.y + 10
		B.queue({ events = { { type = "move", x = x, y = y }, { type = "press", button = 1, x = x, y = y } } }); R.frame()
		B.queue({ events = { { type = "release", button = 1, x = x, y = y } } }); R.frame()
		assert.equal(1, hits)
	end)

	it("lays the dialog out again when the user sizes the window (RESIZE_CB)", function()
		local d = secondary({ RESIZE = "YES" })
		local got
		d.resize_cb = function(_, w, h) got = { w, h } end
		iup.Show(d); R.frame()
		local _, p = only_popup()
		p.w, p.h = 420, 260
		R.frame()
		local st = Element.state(d)
		assert.equal(420, st.w); assert.equal(260, st.h)
		assert.same({ 420, 260 }, got)
		R.frame() -- the user's size holds over RASTERSIZE
		assert.equal(420, st.w)
	end)

	it("runs CLOSE_CB from the close button and hides the dialog", function()
		local d = secondary()
		local asked = 0
		d.close_cb = function() asked = asked + 1 end
		iup.Show(d); R.frame()
		local id, p = only_popup()
		p.close = true
		R.frame()
		assert.equal(1, asked)
		assert.equal("NO", iup.GetAttribute(d, "VISIBLE"))
		assert.is_false(B.popups[id].visible)
	end)

	it("keeps the dialog when CLOSE_CB returns IGNORE", function()
		local d = secondary()
		d.close_cb = function() return iup.IGNORE end
		iup.Show(d); R.frame()
		local id, p = only_popup()
		p.close = true
		R.frame()
		assert.equal("YES", iup.GetAttribute(d, "VISIBLE"))
		assert.is_true(B.popups[id].visible)
	end)

	it("reuses the window across hide and show, and closes it on destroy", function()
		local d = secondary()
		iup.Show(d); R.frame()
		local id = only_popup()
		iup.Hide(d); R.frame()
		assert.is_false(B.popups[id].visible)
		iup.Show(d); R.frame()
		assert.is_true(B.popups[id].visible)
		assert.equal(id, (only_popup()))
		iup.Show(d) -- already shown: brought to the front
		assert.equal(1, B.popups[id].focused)
		iup.Destroy(d); R.frame()
		assert.is_nil(B.popups[id])
	end)

	it("marks a modal dialog's window modal (the main window takes no input)", function()
		local d = secondary()
		local seen
		local t = iup.timer{ TIME = 10 }
		t.action_cb = function()
			local _, p = only_popup()
			seen = p and p.modal
			t.run = "NO"
			iup.Hide(d)
			return iup.DEFAULT
		end
		t.run = "YES"
		iup.Popup(d, iup.CENTER, iup.CENTER)
		assert.is_true(seen)
	end)

	it("draws a tooltip of an element on the dialog on that window", function()
		local lbl = iup.label{ TITLE = "tipped", TIP = "about this" }
		local d = iup.dialog{ iup.vbox{ lbl }, TITLE = "Tips", RASTERSIZE = "200x120" }
		iup.Show(d); R.frame()
		local id = only_popup()
		local st, ls = Element.state(d), Element.state(lbl)
		local x, y = st.data.ox + ls.x + 3, st.data.oy + ls.y + 3
		B.queue({ events = { { type = "move", x = x, y = y } }, mx = x, my = y }); R.frame()
		B.advance(1); R.frame()
		assert.equal(id, text_surfaces()["about this"])
	end)
end)

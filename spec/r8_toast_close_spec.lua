-- Round 8: a toast never takes the keyboard, and its close button has no outline at rest
-- (an outline is drawn for keyboard focus only).
describe("toast close at rest", function()
	local iup, Element, Layout
	before_each(function()
		iup = require("core.lui.test").boot({})
		Element = require("core.imgui.Element")
		Layout = require("core.imgui.Layout")
	end)

	-- A draw context that records the primitives drawn.
	local function draw(button)
		local calls = {}
		local dc = setmetatable({}, { __index = function(_, name)
			return function() calls[#calls + 1] = name; return true end
		end })
		local st = Element.state(button)
		st.class.draw(button, st, dc)
		return table.concat(calls, " ")
	end

	local function close_button()
		return iup.flatbutton{ TITLE = "x", PADDING = "2x2", BORDERWIDTH = "0", CANFOCUS = "YES", FOCUSFEEDBACK = "YES" }
	end

	it("draws only its fill and glyph at rest and under the pointer", function()
		local close = close_button()
		local dlg = iup.dialog{ iup.vbox{ close } }
		Layout.run(dlg, 200, 60)
		local st = Element.state(close)
		assert.equals("fill clip_push text clip_pop", draw(close))
		st.data.highlighted = true
		assert.equals("fill clip_push text clip_pop", draw(close))
		st.data.highlighted = false
		st.data.has_focus = true
		assert.are_not.equal("fill clip_push text clip_pop", draw(close))
	end)

	it("a SHOWNOFOCUS dialog leaves the keyboard where it was", function()
		local field = iup.text{}
		local main = iup.dialog{ iup.vbox{ field } }
		iup.ShowXY(main, 0, 0)
		iup.SetFocus(field)
		assert.equals(field, iup.GetFocus())
		local close = close_button()
		local toast = iup.dialog{ iup.vbox{ close }, SHOWNOFOCUS = "YES", PARENTDIALOG = main }
		iup.ShowXY(toast, 10, 10)
		assert.equals(field, iup.GetFocus())
		assert.equals("NO", iup.GetAttribute(close, "HASFOCUS"))
		local other_close = close_button()
		local plain = iup.dialog{ iup.vbox{ other_close } }
		iup.ShowXY(plain, 20, 20)
		assert.equals(other_close, iup.GetFocus())
	end)
end)

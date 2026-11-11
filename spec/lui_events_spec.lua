-- core.lui events: stable trampolines, return values, raw callbacks, controlled inputs,
-- error boundaries, and the test helper's own queries and input.
local T = require("core.lui.test")
local ui = require("core.lui")

describe("lui event trampolines", function()
	it("installs one callback and keeps it across renders with new closures", function()
		local clicks = {}
		local function App()
			local n, set = ui.useState(0)
			return ui.Button{ "Add " .. n, onClick = function() clicks[#clicks + 1] = n; set(n + 1) end }
		end
		local r = T.render(App)
		local btn = r:getByText("Add 0")
		local cb = r.Element.state(btn).cbs.FLAT_ACTION
		r:click(btn)
		r:click(btn)
		assert.equal("Add 2", r:attr(btn, "TITLE"), "each click saw the latest closure")
		assert.same({ 0, 1 }, clicks)
		assert.equal(cb, r.Element.state(btn).cbs.FLAT_ACTION, "the same trampoline")
		r:unmount()
	end)

	it("returns iup.DEFAULT unless the handler returns something", function()
		local ret
		local r = T.render(ui.VBox{
			ui.Button{ "a", onClick = function() end },
			ui.Button{ "b", onClick = function() return ret end },
		})
		local iup = r.iup
		local a, b = r:getByText("a"), r:getByText("b")
		assert.equal(iup.DEFAULT, r.Element.call(a, "FLAT_ACTION"))
		ret = iup.IGNORE
		assert.equal(iup.IGNORE, r.Element.call(b, "FLAT_ACTION"))
		r:unmount()
	end)

	it("passes adapted arguments: Toggle checked, List index and text, Tabs index", function()
		local got = {}
		local r = T.render(ui.VBox{
			ui.Toggle{ "t", onChange = function(c) got.toggle = c end },
			ui.List{ items = { "x", "y" }, onChange = function(i, t) got.list = { i, t } end },
			ui.Tabs{ onChange = function(i, old) got.tabs = { i, old } end, ui.VBox{ tabTitle = "1" }, ui.VBox{ tabTitle = "2" } },
		})
		local E = r.Element
		local tg = r:queryAllByClass("flattoggle")[1]
		E.call(tg, "FLAT_ACTION", 1)
		assert.is_true(got.toggle)
		E.call(tg, "FLAT_ACTION", 0)
		assert.is_false(got.toggle)
		local list = r:queryAllByClass("flatlist")[1]
		E.call(list, "FLAT_ACTION", "y", 2, 1)
		assert.same({ 2, "y" }, got.list)
		local tabs = r:queryAllByClass("flattabs")[1]
		E.call(tabs, "TABCHANGEPOS_CB", 1, 0)
		assert.same({ 2, 1 }, got.tabs)
		r:unmount()
	end)

	it("installs raw *_cb props and gives them iup's own arguments", function()
		local got
		local r = T.render(ui.Label{ "status", button_cb = function(self, b, pressed) got = { self, b, pressed } end })
		local l = r:getByText("status")
		r.Element.call(l, "BUTTON_CB", 49, 1, 0, 0, "")
		assert.equal(l, got[1])
		assert.equal(49, got[2])
		r:unmount()
	end)

	it("reports a handler that throws and returns DEFAULT", function()
		local r = T.render(ui.Button{ "x", onClick = function() error("handler boom") end })
		local ret = r.Element.call(r:getByText("x"), "FLAT_ACTION")
		assert.equal(r.iup.DEFAULT, ret)
		assert.equal(1, #r.errors)
		assert.truthy(r.errors[1]:find("handler boom"))
		r:unmount()
	end)

	it("updates the widgets before the handler returns to iup", function()
		local seen
		local function App()
			local v, set = ui.useState("before")
			return ui.VBox{ ui.Text{ v, name = "out" }, ui.Button{ "go", onClick = function() set("after") end } }
		end
		local r = T.render(App)
		r.Element.call(r:getByText("go"), "FLAT_ACTION")
		seen = r:attr(r:getByName("out"), "TITLE")
		assert.equal("after", seen)
		r:unmount()
	end)
end)

describe("lui controlled input", function()
	it("keeps the caret: VALUE is written only when it differs from the widget", function()
		local writes = 0
		local function App()
			local v, set = ui.useState("")
			return ui.VBox{ ui.Input{ value = v, onChange = set, name = "in" }, ui.Text{ "[" .. v .. "]", name = "echo" } }
		end
		local r = T.render(App)
		local input = r:getByName("in")
		local raw = r.iup.SetAttribute
		r.iup.SetAttribute = function(h, k, v) if h == input and k == "VALUE" then writes = writes + 1 end; return raw(h, k, v) end
		r:type(input, "hey")
		r.iup.SetAttribute = raw
		assert.equal("hey", r:attr(input, "VALUE"))
		assert.equal("[hey]", r:attr(r:getByName("echo"), "TITLE"))
		assert.equal(0, writes, "typing never rewrote VALUE")
		assert.equal("3", tostring(r:attr(input, "CARETPOS")))
		r:unmount()
	end)

	it("puts the value back when the handler refuses the change", function()
		local r = T.render(ui.Input{ value = "fixed", onChange = function() end, name = "in" })
		local input = r:getByName("in")
		r:type(input, "x")
		assert.equal("fixed", r:attr(input, "VALUE"))
		r:unmount()
	end)

	it("filters input through state", function()
		local function Digits()
			local v, set = ui.useState("")
			return ui.Input{ value = v, name = "in", onChange = function(s) set((s:gsub("%D", ""))) end }
		end
		local r = T.render(Digits)
		r:type(r:getByName("in"), "a1b2")
		assert.equal("12", r:attr(r:getByName("in"), "VALUE"))
		r:unmount()
	end)
end)

describe("lui error boundaries", function()
	local function Bomb(p) if p.explode then error("kaboom") end return ui.Text{ "fine" } end

	it("renders the fallback and calls onError when a child throws", function()
		local caught
		local function App(p)
			return ui.VBox{ name = "box", ui.ErrorBoundary{
				fallback = function(err) return ui.Text{ "failed: " .. tostring(err):match("kaboom") } end,
				onError = function(err) caught = err end,
				ui.h(Bomb, { explode = p.explode }),
			} }
		end
		local r = T.render(App, { explode = false })
		assert.truthy(r:getByText("fine"))
		r:rerender({ explode = true })
		assert.truthy(r:getByText("failed: kaboom"))
		assert.truthy(tostring(caught):find("kaboom"))
		assert.equal(0, #r:queryAllByText("fine"))
		r:unmount()
	end)

	it("resets to its children on request", function()
		local reset
		local exploding = true
		local function Flaky() if exploding then error("once") end return ui.Text{ "recovered" } end
		local r = T.render(ui.ErrorBoundary{
			fallback = function(_, rs) reset = rs; return ui.Text{ "oops" } end,
			ui.h(Flaky, {}),
		})
		assert.truthy(r:getByText("oops"))
		exploding = false
		ui.flushSync(reset)
		assert.truthy(r:getByText("recovered"))
		r:unmount()
	end)

	it("without a boundary keeps the previous output and reports", function()
		local r = T.render(Bomb, { explode = false })
		r:rerender({ explode = true })
		assert.truthy(r:getByText("fine"))
		assert.equal(1, #r.errors)
		assert.truthy(r.errors[1]:find("kaboom"))
		r:unmount()
	end)

	it("drops the effects and state of the subtree that failed", function()
		local effects = 0
		local function Good() ui.useEffect(function() effects = effects + 1 end, {}); return ui.Text{ "g" } end
		local r = T.render(ui.ErrorBoundary{ fallback = ui.Text{ "fb" },
			ui.VBox{ ui.h(Good, {}), ui.h(Bomb, { explode = true }) } })
		assert.equal(0, effects, "the sibling that rendered before the error never committed")
		assert.truthy(r:getByText("fb"))
		r:unmount()
	end)
end)

describe("lui test helper", function()
	it("queries by text, role, name and class, and errors on none or many", function()
		local r = T.render(ui.VBox{
			ui.Text{ "one", role = "r1", name = "n1" },
			ui.Text{ "two", role = "r2" },
			ui.Text{ "two" },
		})
		assert.equal(r:getByRole("r1"), r:getByText("one"))
		assert.equal(r:getByName("n1"), r:getByText("one"))
		assert.equal(2, #r:queryAllByText("two"))
		assert.equal(3, #r:queryAllByClass("flatlabel"))
		assert.equal(1, #r:queryAllByText({ pattern = "^on" }))
		assert.has_error(function() r:getByText("two") end)
		assert.has_error(function() r:getByText("none") end)
		r:unmount()
	end)

	it("clicks through real input at the laid-out position", function()
		local hits = {}
		local r = T.render(ui.HBox{
			ui.Button{ "left", size = { 80, 30 }, onClick = function() hits[#hits + 1] = "left" end },
			ui.Button{ "right", size = { 80, 30 }, onClick = function() hits[#hits + 1] = "right" end },
		})
		r:click(r:getByText("right"))
		r:click(r:getByText("left"))
		assert.same({ "right", "left" }, hits)
		local x, _, w = r:rect(r:getByText("right"))
		assert.equal(80, x)
		assert.equal(80, w)
		r:unmount()
	end)

	it("presses keys on the focused widget and shows dialogs", function()
		local keys = {}
		local r = T.render(ui.Dialog{ title = "d", RASTERSIZE = "300x200", onKey = function(c) keys[#keys + 1] = c end,
			ui.VBox{ ui.Input{ name = "in" } } })
		r:click(r:getByName("in"))
		r:key(r.iup.K_ESC)
		assert.same({ r.iup.K_ESC }, keys)
		r:unmount()
	end)
end)

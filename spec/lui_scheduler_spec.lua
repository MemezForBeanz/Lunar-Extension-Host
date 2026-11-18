-- core.lui's commit queue on the ImGui host: one armed timer that stops after it runs,
-- flushes requested during a flush, and updates made inside nested modal loops.
local T = require("core.lui.test")
local ui = require("core.lui")
local S = require("core.lui.scheduler")
local R = require("core.lui.reconciler")

local iup, Runtime, B
before_each(function() iup, Runtime, B = T.boot({}) end)

local function title(root) return iup.GetAttribute(root:widget(), "TITLE") end

-- Count how deeply _flushNow nests, per root.
local function watch_nesting()
	local raw = R.Root._flushNow
	local depth, max = {}, {}
	R.Root._flushNow = function(self, ...)
		depth[self] = (depth[self] or 0) + 1
		max[self] = math.max(max[self] or 0, depth[self])
		local r = raw(self, ...)
		depth[self] = depth[self] - 1
		return r
	end
	return max, function() R.Root._flushNow = raw end
end

describe("lui commit queue", function()
	it("arms one timer for many updates, and the timer stops after it runs", function()
		local renders, set = 0, nil
		local function C() renders = renders + 1; local v, s = ui.useState(0); set = s; return ui.Text{ tostring(v) } end
		local root = ui.mount(C, { iup = iup })
		local d = iup.dialog({ iup.vbox({}) })
		iup.Show(d)
		local starts = 0
		local state
		set(1)
		state = S.timerState(R.driverFor(iup))
		local raw = iup.SetAttribute
		iup.SetAttribute = function(h, k, v)
			if h == state.handle and k == "RUN" and v == "YES" then starts = starts + 1 end
			return raw(h, k, v)
		end
		set(2)
		set(3)
		assert.is_true(state.armed)
		assert.equal(0, starts, "later updates join the queue without re-arming")
		B.advance(0.01)
		Runtime.step(false)
		iup.SetAttribute = raw
		assert.equal("3", title(root))
		assert.equal(2, renders)
		assert.is_false(S.timerState(R.driverFor(iup)).armed)
		assert.is_false(Runtime.timerRunning(state.handle), "stopped: it does not repeat")
		B.advance(0.01)
		Runtime.step(false)
		assert.equal(2, renders)
		iup.Destroy(d)
	end)

	it("takes a flush requested during a flush in its next round, without recursing", function()
		local max, restore = watch_nesting()
		local set_b
		local function B_() local v, s = ui.useState("b0"); set_b = s; return ui.Text{ v } end
		local rb = ui.mount(B_, { iup = iup })
		local set_a
		local function A()
			local v, s = ui.useState(0)
			set_a = s
			ui.useEffect(function()
				if v == 1 then
					set_b("b1")    -- another root
					set_a(2)       -- this root, while it is still committing
				end
			end, ui.deps(v))
			return ui.Text{ tostring(v) }
		end
		local ra = ui.mount(A, { iup = iup })
		ui.flushSync(function() set_a(1) end)
		restore()
		assert.equal("2", title(ra))
		assert.equal("b1", title(rb))
		assert.equal(1, max[ra], "root A never rendered inside its own flush")
		assert.equal(1, max[rb])
	end)

	it("flushes the updates of a modal loop opened inside a click handler, while it is up", function()
		local seen_inside
		local set_dialog_text
		local function Modal() local v, s = ui.useState("typed: "); set_dialog_text = s; return ui.Text{ v, name = "modal" } end
		local modal_root
		local function App()
			return ui.Button{ "open", onClick = function()
				modal_root = ui.mount(Modal, { iup = iup })
				-- a nested main loop, as iup.Popup runs; the "user" types in it
				local step = 0
				Runtime.runUntil(function()
					step = step + 1
					if step == 1 then
						-- an event handler inside the modal, at the deeper loop level
						S.batch(function() set_dialog_text("typed: x") end)
						seen_inside = iup.GetAttribute(modal_root:widget(), "TITLE")
					end
					return step >= 2
				end)
			end }
		end
		local r = T.render(App)
		r.Element.call(r:getByText("open"), "FLAT_ACTION")
		assert.equal("typed: x", seen_inside, "rendered while the modal loop was running")
		r:unmount()
	end)

	it("does not lose an update made from a modal loop opened during a flush", function()
		local max, restore = watch_nesting()
		local set_a
		local opened = false
		local function A()
			local v, s = ui.useState("first")
			set_a = s
			ui.useLayoutEffect(function()
				if opened then return end
				opened = true
				local step = 0
				Runtime.runUntil(function()
					step = step + 1
					if step == 1 then S.batch(function() set_a("from the modal") end) end
					-- let the timer and frames run once more
					if step == 2 then B.advance(0.01) end
					return step >= 3
				end)
			end, {})
			return ui.Text{ v }
		end
		local root = ui.mount(A, { iup = iup })
		restore()
		assert.equal("from the modal", title(root))
		assert.equal(1, max[root], "never re-entered its own flush")
	end)

	it("lets ui.flushSync inside a handler flush before the handler returns", function()
		local seen
		local function App()
			local v, s = ui.useState("a")
			local ref = ui.useRef()
			return ui.VBox{ ui.Text{ v, ref = ref }, ui.Button{ "go", onClick = function()
				ui.flushSync(function() s("b") end)
				seen = iup.GetAttribute(ref.current, "TITLE")
			end } }
		end
		local r = T.render(App)
		r.Element.call(r:getByText("go"), "FLAT_ACTION")
		assert.equal("b", seen)
		r:unmount()
	end)
end)

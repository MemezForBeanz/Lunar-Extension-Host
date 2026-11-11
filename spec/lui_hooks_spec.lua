-- core.lui hooks: state, reducers, effects (deps and cleanup order), memo, refs, context,
-- stores, batching, flushSync and the errors hook misuse raises.
local T = require("core.lui.test")
local ui = require("core.lui")

local iup, Runtime, B
before_each(function() iup, Runtime, B = T.boot({}) end)

local function mount(el, opts)
	opts = opts or {}
	opts.iup = iup
	return ui.mount(el, opts)
end

local function title(root) return iup.GetAttribute(root:widget(), "TITLE") end

describe("lui useState", function()
	it("batches several updates into one render", function()
		local renders, set = 0, nil
		local function C()
			renders = renders + 1
			local v, s = ui.useState(0)
			set = s
			return ui.Text{ tostring(v) }
		end
		local root = mount(C)
		ui.flushSync(function()
			set(function(v) return v + 1 end)
			set(function(v) return v + 1 end)
			set(function(v) return v + 1 end)
		end)
		assert.equal("3", title(root))
		assert.equal(2, renders)
	end)

	it("does not render again when set to the value it has", function()
		local renders, set = 0, nil
		local function C()
			renders = renders + 1
			local v, s = ui.useState("same")
			set = s
			return ui.Text{ v }
		end
		mount(C)
		ui.flushSync(function() set("same") end)
		assert.equal(1, renders)
	end)

	it("calls a lazy initialiser once", function()
		local calls, set = 0, nil
		local function C()
			local v, s = ui.useState(function() calls = calls + 1; return 5 end)
			set = s
			return ui.Text{ tostring(v) }
		end
		local root = mount(C)
		ui.flushSync(function() set(6) end)
		assert.equal(1, calls)
		assert.equal("6", title(root))
	end)

	it("flushes on the driver's timer when not in a batch", function()
		local set
		local function C() local v, s = ui.useState("a"); set = s; return ui.Text{ v } end
		local root = mount(C)
		local d = iup.dialog({ iup.vbox({}) })
		iup.Show(d)
		set("b")
		assert.equal("a", title(root), "nothing happens synchronously")
		B.advance(0.01)
		Runtime.step(false)
		assert.equal("b", title(root))
		iup.Destroy(d)
	end)

	it("applies an update made during its own render before committing", function()
		local renders = 0
		local function C(p)
			renders = renders + 1
			local v, set = ui.useState(0)
			if v < p.target then set(v + 1) end
			return ui.Text{ tostring(v) }
		end
		local root = mount(ui.h(C, { target = 3 }))
		assert.equal("3", title(root))
		assert.equal(4, renders)
	end)
end)

describe("lui useReducer", function()
	it("folds dispatched actions through the reducer", function()
		local dispatch
		local function reducer(s, a)
			if a.type == "add" then return s + a.n end
			if a.type == "reset" then return 0 end
			return s
		end
		local function C()
			local s, d = ui.useReducer(reducer, 10)
			dispatch = d
			return ui.Text{ tostring(s) }
		end
		local root = mount(C)
		ui.flushSync(function() dispatch({ type = "add", n = 5 }); dispatch({ type = "add", n = 1 }) end)
		assert.equal("16", title(root))
		ui.flushSync(function() dispatch({ type = "reset" }) end)
		assert.equal("0", title(root))
	end)

	it("keeps dispatch the same function across renders", function()
		local seen = {}
		local function C()
			local s, d = ui.useReducer(function(x) return x + 1 end, 0)
			seen[#seen + 1] = d
			return ui.Text{ tostring(s) }
		end
		mount(C)
		ui.flushSync(function() seen[1](1) end)
		assert.equal(2, #seen)
		assert.equal(seen[1], seen[2])
	end)
end)

describe("lui effects", function()
	it("runs after commit, re-runs when deps change, and cleans up first", function()
		local log, set = {}, nil
		local function C()
			local v, s = ui.useState(1)
			set = s
			ui.useEffect(function()
				log[#log + 1] = "run " .. v .. " " .. tostring(iup.GetAttribute(nil, "x"))
				return function() log[#log + 1] = "cleanup " .. v end
			end, { v })
			return ui.Text{ tostring(v) }
		end
		local root = mount(C)
		assert.same({ "run 1 nil" }, log)
		ui.flushSync(function() set(1) end) -- same value: no render, no effect
		assert.same({ "run 1 nil" }, log)
		ui.flushSync(function() set(2) end)
		assert.same({ "run 1 nil", "cleanup 1", "run 2 nil" }, log)
		root:unmount()
		assert.same({ "run 1 nil", "cleanup 1", "run 2 nil", "cleanup 2" }, log)
	end)

	it("sees the committed widget in a layout effect", function()
		local seen
		local function C()
			local ref = ui.useRef()
			ui.useLayoutEffect(function() seen = iup.GetAttribute(ref.current, "TITLE") end, {})
			return ui.Text{ "ready", ref = ref }
		end
		mount(C)
		assert.equal("ready", seen)
	end)

	it("runs with nil deps after every commit and with {} only once", function()
		local every, once, set = 0, 0, nil
		local function C()
			local v, s = ui.useState(0)
			set = s
			ui.useEffect(function() every = every + 1 end)
			ui.useEffect(function() once = once + 1 end, {})
			return ui.Text{ tostring(v) }
		end
		mount(C)
		ui.flushSync(function() set(1) end)
		ui.flushSync(function() set(2) end)
		assert.equal(3, every)
		assert.equal(1, once)
	end)

	it("orders layout effects before effects, children before parents, cleanups before setups", function()
		local log, set = {}, nil
		local function Child(p)
			ui.useEffect(function() log[#log + 1] = "child effect " .. p.v; return function() log[#log + 1] = "child cleanup " .. p.v end end, { p.v })
			ui.useLayoutEffect(function() log[#log + 1] = "child layout " .. p.v end, { p.v })
			return ui.Text{ "c" }
		end
		local function Parent()
			local v, s = ui.useState(1)
			set = s
			ui.useEffect(function() log[#log + 1] = "parent effect " .. v; return function() log[#log + 1] = "parent cleanup " .. v end end, { v })
			ui.useLayoutEffect(function() log[#log + 1] = "parent layout " .. v end, { v })
			return ui.VBox{ ui.h(Child, { v = v }) }
		end
		mount(Parent)
		assert.same({ "child layout 1", "parent layout 1", "child effect 1", "parent effect 1" }, log)
		log = {}
		ui.flushSync(function() set(2) end)
		assert.same({ "child layout 2", "parent layout 2",
			"child cleanup 1", "parent cleanup 1", "child effect 2", "parent effect 2" }, log)
	end)

	it("lets an effect set state, rendering again in the same flush", function()
		local function C()
			local v, set = ui.useState("loading")
			ui.useEffect(function() set("loaded") end, {})
			return ui.Text{ v }
		end
		local root
		ui.flushSync(function() root = mount(C) end)
		assert.equal("loaded", title(root))
	end)

	it("reports an effect that throws and keeps going", function()
		local msgs, ran = {}, false
		local function C()
			ui.useEffect(function() error("effect boom") end, {})
			ui.useEffect(function() ran = true end, {})
			return ui.Text{ "x" }
		end
		mount(C, { onError = function(m) msgs[#msgs + 1] = m end })
		assert.is_true(ran)
		assert.equal(1, #msgs)
		assert.truthy(msgs[1]:find("effect boom"))
	end)

	it("stops an update loop with an error", function()
		local msgs = {}
		local function C()
			local v, set = ui.useState(0)
			ui.useEffect(function() set(v + 1) end)
			return ui.Text{ tostring(v) }
		end
		local ok, err = pcall(ui.flushSync, function() mount(C, { onError = function(m) msgs[#msgs + 1] = m end }) end)
		assert.is_false(ok)
		assert.truthy(tostring(err):find("maximum update depth"))
	end)
end)

describe("lui effect scopes and unmounted instances", function()
	it("tells an effect it was cleaned up, so resumed async work can stop", function()
		local set_url
		local resumes, applied = {}, {}
		local function Loader()
			local url, s = ui.useState("a")
			set_url = s
			local data, set_data = ui.useState("none")
			ui.useEffect(function(scope)
				-- a coroutine that "waits for the network" until the spec resumes it
				local co = coroutine.create(function()
					coroutine.yield()
					if not scope.alive() then return end
					applied[#applied + 1] = url
					set_data("loaded " .. url)
				end)
				coroutine.resume(co)
				resumes[url] = co
			end, ui.deps(url))
			return ui.Text{ data }
		end
		local root = mount(Loader)
		ui.flushSync(function() set_url("b") end) -- the "a" effect is cleaned up
		ui.flushSync(function() coroutine.resume(resumes.a) end)
		assert.same({}, applied, "the stale request saw alive() == false")
		ui.flushSync(function() coroutine.resume(resumes.b) end)
		assert.same({ "b" }, applied)
		assert.equal("loaded b", title(root))
	end)

	it("runs onCleanup callbacks with the effect's cleanup", function()
		local log = {}
		local function C()
			ui.useEffect(function(scope)
				scope.onCleanup(function() log[#log + 1] = "onCleanup" end)
				return function() log[#log + 1] = "returned" end
			end, {})
			return ui.Text{ "x" }
		end
		mount(C):unmount()
		assert.same({ "onCleanup", "returned" }, log)
	end)

	it("ignores a setter called after unmount", function()
		local set
		local renders = 0
		local function C() renders = renders + 1; local v, s = ui.useState(1); set = s; return ui.Text{ tostring(v) } end
		local root = mount(C)
		root:unmount()
		assert.has_no.errors(function() ui.flushSync(function() set(2) end) end)
		assert.equal(1, renders)
	end)

	it("ignores a store change that arrives after unmount, even mid-notification", function()
		local store = ui.createStore({ n = 0 })
		local renders = 0
		local root
		-- a listener subscribed first unmounts the component while the store notifies
		store:subscribe(function() if root then root:unmount() end end)
		local function C() renders = renders + 1; return ui.Text{ tostring(ui.useStore(store, function(s) return s.n end)) } end
		root = mount(C)
		assert.has_no.errors(function() ui.flushSync(function() store:set({ n = 1 }) end) end)
		assert.equal(1, renders)
	end)
end)

describe("lui dependency lists with nil", function()
	it("compares lists holding nil by their recorded count", function()
		local H = require("core.lui.hooks")
		assert.is_false(H.depsChanged(ui.deps(nil, 1), ui.deps(nil, 1)))
		assert.is_true(H.depsChanged(ui.deps(nil, 1), ui.deps(nil, 2)))
		assert.is_true(H.depsChanged(ui.deps(nil), ui.deps()), "{ nil } and {} differ")
		assert.is_true(H.depsChanged(ui.deps(1, nil), ui.deps(1, 2)))
		assert.is_false(H.depsChanged({ 1, nil, 3 }, { 1, nil, 3 }), "plain lists compare to their largest index")
		assert.is_true(H.depsChanged({ 1, nil, 3 }, { 1, 2, 3 }))
	end)

	it("re-runs an effect when a dep goes from a value to nil", function()
		local runs, set = 0, nil
		local function C()
			local v, s = ui.useState("x")
			set = s
			ui.useEffect(function() runs = runs + 1 end, ui.deps(v, "fixed"))
			return ui.Text{ "t" }
		end
		mount(C)
		ui.flushSync(function() set(false) end)
		ui.flushSync(function() set(nil) end)
		assert.equal(3, runs)
	end)
end)

describe("lui component models", function()
	it("renders a component with another state model through the same reconciler", function()
		-- A toy setup-once model: `setup(props, signal)` runs once and returns a render
		-- function; `signal(v)` makes a value whose `set` asks for another render.
		local Setup = {}
		function Setup.render(inst, fn, props, env)
			if not inst.state then
				inst.state = {}
				local function signal(v)
					local s = { v = v }
					function s.get() return s.v end
					function s.set(n) s.v = n; env.schedule() end
					return s
				end
				inst.state.view = fn(props, signal)
			end
			return inst.state.view(props), { effects = {}, commit = function() end, abort = function() end }
		end
		function Setup.unmount() end
		local count
		local Counter = ui.component(function(_, signal)
			count = signal(0)
			return function(p) return ui.Text{ p.label .. count.get() } end
		end, { name = "Counter", model = Setup })
		local root = mount(Counter{ label = "n=" })
		assert.equal("n=0", title(root))
		ui.flushSync(function() count.set(5) end)
		assert.equal("n=5", title(root))
		root:update(Counter{ label = "count=" })
		assert.equal("count=5", title(root))
	end)
end)

describe("lui memo hooks and refs", function()
	it("recomputes useMemo only when deps change, and keeps useCallback stable", function()
		local computed, set, cbs = 0, nil, {}
		local function C()
			local v, s = ui.useState({ a = 1, b = 1 })
			set = s
			local double = ui.useMemo(function() computed = computed + 1; return v.a * 2 end, { v.a })
			cbs[#cbs + 1] = ui.useCallback(function() return v.a end, { v.a })
			return ui.Text{ tostring(double) }
		end
		local root = mount(C)
		ui.flushSync(function() set({ a = 1, b = 2 }) end)
		assert.equal(1, computed)
		assert.equal(cbs[1], cbs[2])
		ui.flushSync(function() set({ a = 3, b = 2 }) end)
		assert.equal(2, computed)
		assert.equal("6", title(root))
		assert.are_not.equal(cbs[2], cbs[3])
	end)

	it("keeps a useRef table across renders without re-rendering on change", function()
		local refs, renders, set = {}, 0, nil
		local function C()
			renders = renders + 1
			local r = ui.useRef(0)
			refs[#refs + 1] = r
			local _, s = ui.useState(0)
			set = s
			r.current = r.current + 1
			return ui.Text{ "x" }
		end
		mount(C)
		ui.flushSync(function() set(1) end)
		assert.equal(refs[1], refs[2])
		assert.equal(2, refs[1].current)
		assert.equal(2, renders)
	end)
end)

describe("lui context", function()
	it("gives consumers the nearest provider's value and the default without one", function()
		local Theme = ui.createContext("light")
		local function Show() return ui.Text{ ui.useContext(Theme) } end
		local root = mount(ui.VBox{
			ui.h(Show, {}),
			Theme.Provider{ value = "dark", ui.h(Show, {}), Theme.Provider{ value = "blue", ui.h(Show, {}) } },
		})
		local box = root:widget()
		assert.equal("light", iup.GetAttribute(iup.GetChild(box, 0), "TITLE"))
		assert.equal("dark", iup.GetAttribute(iup.GetChild(box, 1), "TITLE"))
		assert.equal("blue", iup.GetAttribute(iup.GetChild(box, 2), "TITLE"))
	end)

	it("re-renders consumers below a memoised parent when the provider value changes", function()
		local Ctx = ui.createContext(0)
		local consumer_renders, middle_renders, set = 0, 0, nil
		local function Consumer() consumer_renders = consumer_renders + 1; return ui.Text{ tostring(ui.useContext(Ctx)) } end
		local Middle = ui.memo(function() middle_renders = middle_renders + 1; return ui.VBox{ ui.h(Consumer, {}) } end)
		local function App()
			local v, s = ui.useState(1)
			set = s
			return Ctx.Provider{ value = v, Middle{} }
		end
		local root = mount(App)
		ui.flushSync(function() set(2) end)
		local label = iup.GetChild(root:widget(), 0)
		assert.equal("2", iup.GetAttribute(label, "TITLE"))
		assert.equal(1, middle_renders, "the memoised middle did not render")
		assert.equal(2, consumer_renders)
	end)
end)

describe("lui stores", function()
	it("re-renders a component only when its selected slice changes", function()
		local store = ui.createStore({ status = "idle", count = 0 })
		local renders = 0
		local function Status()
			renders = renders + 1
			return ui.Text{ ui.useStore(store, function(s) return s.status end) }
		end
		local root = mount(Status)
		ui.flushSync(function() store:set({ count = 1 }) end)
		assert.equal(1, renders)
		ui.flushSync(function() store:set({ status = "busy" }) end)
		assert.equal(2, renders)
		assert.equal("busy", title(root))
	end)

	it("unsubscribes on unmount", function()
		local store = ui.createStore({ n = 0 })
		local function C() return ui.Text{ tostring(ui.useStore(store, function(s) return s.n end)) } end
		local root = mount(C)
		assert.equal(1, #store._listeners)
		root:unmount()
		assert.equal(0, #store._listeners)
	end)

	it("merges table state and notifies listeners only on change", function()
		local store = ui.createStore({ a = 1, b = 2 })
		local calls = 0
		store:subscribe(function() calls = calls + 1 end)
		assert.is_false(store:set({ a = 1 }))
		assert.is_true(store:set({ a = 3 }))
		assert.same({ a = 3, b = 2 }, store:get())
		store:update(function(s) return { b = s.b + 1 } end)
		assert.equal(3, store:get().b)
		assert.equal(2, calls)
	end)
end)

describe("lui memo", function()
	it("skips a render while props are shallow-equal", function()
		local renders, set = 0, nil
		local Row = ui.memo(function(p) renders = renders + 1; return ui.Text{ p.label } end)
		local function App()
			local v, s = ui.useState({ label = "a", other = 0 })
			set = s
			return ui.VBox{ Row{ label = v.label } }
		end
		local root = mount(App)
		ui.flushSync(function() set({ label = "a", other = 1 }) end)
		assert.equal(1, renders)
		ui.flushSync(function() set({ label = "b", other = 1 }) end)
		assert.equal(2, renders)
		assert.equal("b", iup.GetAttribute(iup.GetChild(root:widget(), 0), "TITLE"))
	end)
end)

describe("lui hook misuse", function()
	it("explains a hook called outside a render", function()
		local ok, err = pcall(ui.useState, 1)
		assert.is_false(ok)
		assert.truthy(tostring(err):find("outside a component render"))
	end)

	it("explains a hook count that changed between renders", function()
		local msgs, set = {}, nil
		local function Bad()
			local v, s = ui.useState(false)
			set = s
			if v then ui.useRef(1) end
			return ui.Text{ "x" }
		end
		local root = mount(Bad, { onError = function(m) msgs[#msgs + 1] = m end })
		ui.flushSync(function() set(true) end)
		assert.equal(1, #msgs)
		assert.truthy(msgs[1]:find("more hooks than during the previous render"))
		assert.equal("x", title(root), "the previous output stays")
	end)

	it("explains a hook whose kind changed at the same index", function()
		local msgs, set = {}, nil
		local function Bad()
			local v, s = ui.useState(false)
			set = s
			if v then ui.useRef(1) else ui.useMemo(function() return 1 end, {}) end
			return ui.Text{ "x" }
		end
		mount(Bad, { onError = function(m) msgs[#msgs + 1] = m end })
		ui.flushSync(function() set(true) end)
		assert.truthy(msgs[1] and msgs[1]:find("was memo and is now ref"))
	end)
end)

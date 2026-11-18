--- Hooks: the state model of function components, as a self-contained component model.
--
-- A component is a function `props -> element`. Called by the reconciler, it may call
-- these, always in the same order (never inside an `if` or a loop that changes length):
--
--     local n, setN = ui.useState(0)            -- setN(5) or setN(function(n) return n + 1 end)
--     local s, dispatch = ui.useReducer(reducer, initial[, init])
--     ui.useEffect(function(scope) ...; return cleanup end, ui.deps(a, b))   -- after commit
--     ui.useLayoutEffect(fn, deps)               -- after commit, before useEffect's
--     local v = ui.useMemo(function() return expensive(a) end, ui.deps(a))
--     local cb = ui.useCallback(function() ... end, ui.deps(a))
--     local ref = ui.useRef(initial)              -- ref.current, stable across renders
--     local value = ui.useContext(Ctx)
--     local sel = ui.useStore(store, function(s) return s.field end)
--
-- Deps: `nil` runs the effect after every commit, `{}` once after mount, otherwise when
-- an entry differs (`~=`) from the previous render's. A list may contain nil: build it
-- with `ui.deps(a, b, c)`, which records the count (a plain `{ a, nil }` is compared up
-- to its largest index, which is also correct, but cannot tell `{ nil }` from `{}`).
--
-- ### The component model interface
--
-- The reconciler knows nothing of hooks. It asks a component's *model* (this module,
-- unless the component type names another in `type.model`) to:
--
--     model.render(inst, fn, props, env) -> output, work
--         env.readContext(ctx) -> value     env.schedule()  (render this instance again)
--         work.effects = { { phase = "layout"|"effect", setup = fn, cleanup = fn }, ... }
--         work.commit()   the render was committed: make its state current
--         work.abort()    the render was thrown away
--     model.unmount(inst, report)            run every cleanup; report(err) for errors
--
-- A render is atomic: until `work.commit()`, no hook state changes. A setup-once
-- (signal) model would implement the same four calls.
--
-- @module core.lui.hooks
local M = {}

local current -- the render in progress: { inst, env, index, old, new, effects, consumed, rerender, name }

function M.current() return current end

local function need(name)
	if not current then
		error("lui: " .. name .. " called outside a component render "
			.. "(hooks only work while a function component is being rendered)", 3)
	end
	return current
end

-- The hook at the next index: the previous render's, checked for the same kind, or nil
-- on the first render.
local function slot(name, kind)
	local c = need(name)
	c.index = c.index + 1
	local i = c.index
	local old = c.old and c.old[i]
	if c.old and not old then
		error(string.format("lui: %s rendered more hooks than during the previous render "
			.. "(hook #%d, %s, is new); hooks must not be called conditionally", c.name, i, name), 3)
	end
	if old and old.kind ~= kind then
		error(string.format("lui: hook #%d of %s was %s and is now %s; hooks must be called "
			.. "in the same order every render", i, c.name, old.kind, kind), 3)
	end
	return c, i, old
end

--- A dependency list that may contain nil: `ui.deps(a, b, c)`.
function M.deps(...) return { n = select("#", ...), ... } end

local function count(d) return d.n or table.maxn(d) end

local function deps_changed(a, b)
	if a == nil or b == nil then return true end
	local na, nb = count(a), count(b)
	if a.n and b.n and na ~= nb then return true end
	for i = 1, math.max(na, nb) do if a[i] ~= b[i] then return true end end
	return false
end
M.depsChanged = deps_changed

-- State --------------------------------------------------------------------------------

local function basic(state, action)
	if type(action) == "function" then return action(state) end
	return action
end

-- Queue an update for the instance owning `cell`. A no-op once it has unmounted.
local function dispatch(cell, action)
	local inst = cell.inst
	if inst.unmounted then return end
	local cur = current
	if cur and cur.inst == inst then
		-- set state during its own render: rendered again before this render returns
		cell.queue[#cell.queue + 1] = { action }
		cur.rerender = true
		return
	end
	-- setting state to what it already is does nothing (checked only on an empty queue)
	if cell.basic and #cell.queue == 0 and cell.committed_set then
		local nextv = action
		if type(action) == "function" then nextv = action(cell.committed) end
		if nextv == cell.committed then return end
	end
	cell.queue[#cell.queue + 1] = { action }
	cell.env.schedule()
end

--- `useReducer(reducer, initialArg[, init])` -> state, dispatch
function M.useReducer(reducer, initial, init)
	local c, i, old = slot("useReducer", "reducer")
	local hook
	if not old then
		local cell = { queue = {}, inst = c.inst, env = c.env }
		local first = initial
		if init then first = init(initial) end
		cell.dispatch = function(action) dispatch(cell, action) end
		hook = { kind = "reducer", cell = cell, state = first }
	else
		hook = { kind = "reducer", cell = old.cell, state = old.state }
	end
	local cell = hook.cell
	local state = hook.state
	hook.base = state
	local n = #cell.queue
	for q = 1, n do state = reducer(state, cell.queue[q][1]) end
	hook.state = state
	if n > 0 then c.consumed[#c.consumed + 1] = { cell, n } end
	c.new[i] = hook
	return state, cell.dispatch
end

--- `useState(initial)` -> value, set. `initial` may be a function (called once).
-- `set(v)` or `set(function(prev) return next end)`; setting the value it already has
-- does not re-render; calling `set` after the component unmounted does nothing.
function M.useState(initial)
	local c = need("useState")
	local is_first = not (c.old and c.old[c.index + 1])
	local init
	if is_first and type(initial) == "function" then init = initial; initial = nil end
	local s, d = M.useReducer(basic, initial, init)
	c.new[c.index].cell.basic = true
	return s, d
end

-- Effects ------------------------------------------------------------------------------

--- The scope an effect receives: `scope.alive()` is true until the effect is cleaned
-- up (deps changed, or unmount); `scope.onCleanup(fn)` adds a cleanup. Coroutine-based
-- async code checks `alive()` after each resume and stops when it is false.
local function new_scope()
	local alive, extra = true, {}
	local scope = {}
	function scope.alive() return alive end
	function scope.onCleanup(fn) extra[#extra + 1] = fn end
	return scope, function()
		alive = false
		for i = #extra, 1, -1 do extra[i]() end
	end
end

local function effect(name, phase, fn, deps)
	local c, i, old = slot(name, phase)
	local hook = { kind = phase, deps = deps, cleanup = old and old.cleanup }
	if not old or old.fresh or deps == nil or deps_changed(deps, old.deps) then
		c.effects[#c.effects + 1] = {
			phase = phase,
			cleanup = function()
				local cl = hook.cleanup
				hook.cleanup = nil
				if cl then cl() end
			end,
			setup = function()
				local scope, close = new_scope()
				local ok, r = pcall(fn, scope)
				local user = ok and type(r) == "function" and r or nil
				hook.cleanup = function()
					close()
					if user then user() end
				end
				if not ok then error(r, 0) end
			end,
		}
	else
		hook.deps = old.deps
	end
	c.new[i] = hook
end

--- Run `fn(scope)` after the commit; when deps change (or on unmount) its returned
-- cleanup runs first and `scope.alive()` turns false.
function M.useEffect(fn, deps) effect("useEffect", "effect", fn, deps) end

--- Like `useEffect`, but run before any `useEffect` of the same commit, right after the
-- widgets were written: the place to measure or to touch a host widget.
function M.useLayoutEffect(fn, deps) effect("useLayoutEffect", "layout", fn, deps) end

-- Memoisation and refs (optimisations: reach for them after measuring) ------------------

function M.useMemo(fn, deps)
	local c, i, old = slot("useMemo", "memo")
	if old and deps ~= nil and not deps_changed(deps, old.deps) then
		c.new[i] = old
		return old.value
	end
	local hook = { kind = "memo", deps = deps, value = fn() }
	c.new[i] = hook
	return hook.value
end

function M.useCallback(fn, deps)
	return M.useMemo(function() return fn end, deps)
end

function M.useRef(initial)
	local c, i, old = slot("useRef", "ref")
	local hook = old or { kind = "ref", ref = { current = initial } }
	c.new[i] = hook
	return hook.ref
end

-- Context -------------------------------------------------------------------------------

function M.useContext(ctx)
	local c = need("useContext")
	if type(ctx) ~= "table" or not ctx.Provider then error("lui: useContext needs a context from ui.createContext", 2) end
	return c.env.readContext(ctx)
end

-- External stores ------------------------------------------------------------------------

local function identity(s) return s end

--- `useStore(store, selector)`: the selected slice of a `ui.createStore` store; the
-- component re-renders when the selected value changes (`~=`). A change after unmount
-- does nothing (the subscription ends with the component).
function M.useStore(store, selector)
	selector = selector or identity
	local value = selector(store:get())
	local ref = M.useRef(nil)
	ref.current = { selector = selector, value = value }
	-- a counter whose only job is to make this component render again
	local _, force = M.useReducer(function(n) return n + 1 end, 0)
	M.useLayoutEffect(function(scope)
		local function check()
			if not scope.alive() then return end
			local cur = ref.current
			local ok, v = pcall(cur.selector, store:get())
			if not ok or v ~= cur.value then force(1) end
		end
		local off = store:subscribe(check)
		check() -- the store may have changed between render and subscribe
		return off
	end, { store })
	return value
end

-- The model ------------------------------------------------------------------------------

local MAX_RERENDERS = 25

--- Render `fn(props)` for `inst` with hooks. See the module header.
function M.render(inst, fn, props, env)
	local ctx = { inst = inst, env = env, name = inst.name }
	local old = inst.hooks
	for _ = 1, MAX_RERENDERS do
		ctx.index, ctx.new, ctx.effects, ctx.consumed, ctx.rerender = 0, {}, {}, {}, false
		ctx.old = old
		local prev = current
		current = ctx
		local ok, out = xpcall(fn, debug.traceback, props)
		current = prev
		if not ok then
			error(setmetatable({ component = inst.name, message = out },
				{ __tostring = function(e) return "lui: error rendering " .. e.component .. ": " .. tostring(e.message) end }), 0)
		end
		if old and ctx.index ~= #old then
			error(string.format("lui: %s rendered %d hooks, %d during the previous render; "
				.. "hooks must not be called conditionally", inst.name, ctx.index, #old), 0)
		end
		if not ctx.rerender then
			local new, consumed = ctx.new, ctx.consumed
			local function drop_consumed()
				for _, c in ipairs(consumed) do
					for _ = 1, c[2] do table.remove(c[1].queue, 1) end
				end
				consumed = {}
			end
			return out, {
				effects = ctx.effects,
				commit = function()
					inst.hooks = new
					for _, hk in ipairs(new) do
						if hk.kind == "reducer" then hk.cell.committed, hk.cell.committed_set = hk.state, true end
					end
					drop_consumed()
				end,
				-- thrown away: drop the updates it consumed, so the next render does not
				-- fail on them again
				abort = drop_consumed,
			}
		end
		-- On a first render the cells live in this pass's hooks: keep them, from the start.
		if not inst.hooks then
			old = {}
			for i, hk in ipairs(ctx.new) do
				if hk.kind == "reducer" then old[i] = { kind = "reducer", cell = hk.cell, state = hk.base }
				elseif hk.kind == "effect" or hk.kind == "layout" then old[i] = { kind = hk.kind, fresh = true }
				else old[i] = hk end
			end
		end
	end
	error("lui: " .. inst.name .. " re-rendered " .. MAX_RERENDERS
		.. " times in one render (it sets state unconditionally)", 0)
end

--- Run every cleanup of an unmounting instance: layout cleanups before effect ones.
function M.unmount(inst, report)
	for _, phase in ipairs({ "layout", "effect" }) do
		for _, hk in ipairs(inst.hooks or {}) do
			if hk.kind == phase and hk.cleanup then
				local cl = hk.cleanup
				hk.cleanup = nil
				local ok, err = xpcall(cl, debug.traceback)
				if not ok then report(err) end
			end
		end
	end
end

M.model = { render = M.render, unmount = M.unmount, name = "hooks" }

return M

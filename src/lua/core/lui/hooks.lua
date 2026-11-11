--- Hooks: state and effects that belong to one rendering of one component instance.
--
-- A component is a function `props -> element`. Called by the reconciler, it may call
-- these, always in the same order (never inside an `if` or a loop that changes length):
--
--     local n, setN = ui.useState(0)            -- setN(5) or setN(function(n) return n + 1 end)
--     local s, dispatch = ui.useReducer(reducer, initial[, init])
--     ui.useEffect(function() ...; return cleanup end, { dep1, dep2 })   -- after commit
--     ui.useLayoutEffect(fn, deps)               -- after commit, before useEffect's
--     local v = ui.useMemo(function() return expensive(a) end, { a })
--     local cb = ui.useCallback(function() ... end, { a })
--     local ref = ui.useRef(initial)              -- ref.current, stable across renders
--     local value = ui.useContext(Ctx)
--     local sel = ui.useStore(store, function(s) return s.field end)
--
-- Deps: `nil` runs the effect after every commit, `{}` once after mount, otherwise when
-- an entry differs (`~=`) from the previous render's. Updates are queued and batched; the
-- render that consumes them is atomic: if it throws, no hook state changes.
--
-- @module core.lui.hooks
local M = {}

local current -- the render in progress: { inst, index, old, new, effects, rerender }

function M.current() return current end

--- Start rendering `inst`. The reconciler calls this; components never do.
function M.begin(ctx) local prev = current; current = ctx; return prev end
function M.finish(prev) current = prev end

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

local function deps_changed(a, b)
	if a == nil or b == nil then return true end
	if #a ~= #b then return true end
	for i = 1, #a do if a[i] ~= b[i] then return true end end
	return false
end
M.depsChanged = deps_changed

-- State --------------------------------------------------------------------------------

local function basic(state, action)
	if type(action) == "function" then return action(state) end
	return action
end

--- `useReducer(reducer, initialArg[, init])` -> state, dispatch
function M.useReducer(reducer, initial, init)
	local c, i, old = slot("useReducer", "reducer")
	local hook
	if not old then
		local cell = { queue = {}, inst = c.inst }
		local first = initial
		if init then first = init(initial) end
		cell.reducer = reducer
		cell.dispatch = function(action) c.schedule(cell, action) end
		hook = { kind = "reducer", cell = cell, state = first }
	else
		hook = { kind = "reducer", cell = old.cell, state = old.state }
	end
	local cell = hook.cell
	cell.reducer = reducer
	local state = hook.state
	hook.base = state
	local n = #cell.queue
	for q = 1, n do state = reducer(state, cell.queue[q]) end
	hook.state = state
	if n > 0 then c.consumed[#c.consumed + 1] = { cell, n } end
	c.new[i] = hook
	return state, cell.dispatch
end

--- `useState(initial)` -> value, set. `initial` may be a function (called once).
-- `set(v)` or `set(function(prev) return next end)`; setting the value it already has
-- does not re-render.
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

local function effect(name, phase, fn, deps)
	local c, i, old = slot(name, phase)
	local hook = { kind = phase, deps = deps, cleanup = old and old.cleanup }
	if not old or old.fresh or deps == nil or deps_changed(deps, old.deps) then
		c.effects[#c.effects + 1] = { phase = phase, hook = hook, fn = fn, inst = c.inst }
	else
		hook.deps = old.deps
	end
	c.new[i] = hook
end

--- Run `fn` after the commit; when deps change (or on unmount) its returned cleanup
-- runs first.
function M.useEffect(fn, deps) effect("useEffect", "effect", fn, deps) end

--- Like `useEffect`, but run before any `useEffect` of the same commit, right after the
-- widgets were written: the place to measure or to touch a host widget.
function M.useLayoutEffect(fn, deps) effect("useLayoutEffect", "layout", fn, deps) end

-- Memoisation and refs --------------------------------------------------------------

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
	c.inst.contexts = c.inst.contexts or {}
	c.inst.contexts[ctx] = true
	return c.readContext(ctx)
end

-- External stores ------------------------------------------------------------------------

local function identity(s) return s end

--- `useStore(store, selector)`: the selected slice of a `ui.createStore` store; the
-- component re-renders when the selected value changes (`~=`).
function M.useStore(store, selector)
	selector = selector or identity
	local c = need("useStore")
	local value = selector(store:get())
	local ref = M.useRef(nil)
	ref.current = { selector = selector, value = value }
	-- a counter whose only job is to make this component render again
	local _, force = M.useReducer(function(n) return n + 1 end, 0)
	M.useLayoutEffect(function()
		local function check()
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

return M

--- A tiny observable store, for state shared between components and plain Lua code.
--
-- ```lua
-- local store = ui.createStore({ status = "", busy = false })
-- store:set({ status = "Building" })            -- shallow merge into a table state
-- store:update(function(s) return { n = s.n + 1 } end)
-- local off = store:subscribe(function(state, prev) ... end)
-- -- in a component: local status = ui.useStore(store, function(s) return s.status end)
-- ```
--
-- A table state is replaced, never mutated: `set` builds a new table, so a selector
-- that returns the whole state still sees a change. Listeners run synchronously, in
-- subscription order; a listener that unsubscribes others during the call is safe.
--
-- @module core.lui.store
local M = {}

local Store = {}
Store.__index = Store

--- Create a store.
-- @param initial any value; a table is treated as a record that `set` merges into
-- @treturn Store
function M.createStore(initial)
	return setmetatable({ _state = initial, _listeners = {}, _seq = 0 }, Store)
end

function M.isStore(v) return getmetatable(v) == Store end

--- The current state.
function Store:get() return self._state end

local function notify(self, prev)
	-- a snapshot: listeners may subscribe or unsubscribe while we call them
	local list = {}
	for i, l in ipairs(self._listeners) do list[i] = l end
	for _, l in ipairs(list) do
		if not l.dead then l.fn(self._state, prev) end
	end
end

--- Replace the state, or merge a table into a table state. Listeners are told only
-- when something changed (for a merge: when some field's value differs).
-- @param next_state a table to merge (when the state is a table), or the new value
-- @tparam[opt] boolean replace replace a table state instead of merging
function Store:set(next_state, replace)
	local prev = self._state
	local new
	if not replace and type(prev) == "table" and type(next_state) == "table" then
		local changed = false
		for k, v in pairs(next_state) do
			if prev[k] ~= v then changed = true; break end
		end
		if not changed then return false end
		new = {}
		for k, v in pairs(prev) do new[k] = v end
		for k, v in pairs(next_state) do new[k] = v end
	else
		if prev == next_state then return false end
		new = next_state
	end
	self._state = new
	notify(self, prev)
	return true
end

--- `set(fn(state))`: compute the change from the current state.
function Store:update(fn, replace)
	return self:set(fn(self._state), replace)
end

--- Listen for changes. Returns a function that unsubscribes.
-- @tparam function fn `fn(state, prev)`
function Store:subscribe(fn)
	local entry = { fn = fn }
	self._listeners[#self._listeners + 1] = entry
	return function()
		if entry.dead then return end
		entry.dead = true
		for i, l in ipairs(self._listeners) do
			if l == entry then table.remove(self._listeners, i); break end
		end
	end
end

return M

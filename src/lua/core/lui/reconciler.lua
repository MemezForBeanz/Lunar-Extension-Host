--- The reconciler: turns elements into host widgets and keeps them in step.
--
-- A flush has two phases.
--
-- **Render** walks from the root and builds a new fiber for every element whose output
-- may have changed: a component that has queued updates, whose props changed, or whose
-- context changed; a host element whose element table is new. A subtree whose element
-- table is the same one as last time and has no pending work is reused untouched (the
-- bail-out), so an update deep in the tree re-renders only the path to it. Render never
-- touches a widget and never changes committed state: if a component throws, the new
-- fibers are dropped and the screen and every hook keep their previous values (unless
-- an `ErrorBoundary` above it catches the error and renders its fallback instead).
--
-- **Commit** applies the result: deletions (effect cleanups, then the widgets are
-- destroyed; embedded `Native` handles are only detached), then for each new or changed
-- host fiber the attribute writes that differ from the last ones written, then children
-- placement (insert, move, detach) for the host parents whose list of children changed,
-- then one `iup.Refresh` on the lowest common container of everything whose layout
-- changed, then layout effects, then effects.
--
-- @module core.lui.reconciler
local vnode = require("core.lui.vnode")
local hooks = require("core.lui.hooks")
local P = require("core.lui.props")
local prim = require("core.lui.primitives")
local S = require("core.lui.scheduler")
local Driver = require("core.lui.driver")

local M = {}

local h = vnode.h
local EMPTY = {}
local traceback = debug.traceback

-- Special types -----------------------------------------------------------------------

--- `ui.Native{ handle = some_iup_handle }`: an existing widget placed in the tree. The
-- reconciler moves it into place and detaches it on unmount; it never destroys it and
-- never writes its attributes or children.
M.Native = vnode.callable({ kind = "native", name = "Native" })

--- `ui.ErrorBoundary{ fallback = el | function(err, reset) -> el, onError = fn, ... }`
M.ErrorBoundary = vnode.callable({ kind = "boundary", name = "ErrorBoundary" })

--- `ui.createContext(default)` -> `{ Provider, default }`;
-- `ctx.Provider{ value = v, ...children }`, read with `ui.useContext(ctx)`.
function M.createContext(default)
	local ctx = { default = default }
	ctx.Provider = vnode.callable({ kind = "provider", name = "Provider", context = ctx })
	return ctx
end

local function shallow_equal(a, b)
	if a == b then return true end
	for k, v in pairs(a) do if b[k] ~= v then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end
M.shallowEqual = shallow_equal

--- `ui.component(fn[, name | { name, model }])`: a callable component, `Card{ title = "x" }`.
-- `model` is the state model rendering it (default `core.lui.hooks`; see its header).
function M.component(fn, opts)
	assert(type(fn) == "function", "ui.component needs a function")
	if type(opts) ~= "table" then opts = { name = opts } end
	return vnode.callable({ kind = "component", render = fn, name = opts.name, model = opts.model })
end

--- `ui.memo(component[, areEqual])`: skip re-rendering while props are shallow-equal.
function M.memo(comp, are_equal)
	local fn = type(comp) == "function" and comp or comp.render
	local name = type(comp) == "table" and comp.name or nil
	return vnode.callable({ kind = "component", render = fn, name = name, memo = are_equal or shallow_equal })
end

local function kind_of(t)
	local ty = type(t)
	if ty == "function" then return "component" end
	if ty == "table" and t.kind then return t.kind end
	error("lui: not an element type: " .. tostring(t), 0)
end

local function name_of(t)
	if type(t) == "table" then
		if t.name then return t.name end
		t = t.render
	end
	local info = debug.getinfo(t, "S")
	return string.format("component(%s:%d)", info.short_src or "?", info.linedefined or 0)
end
M.nameOf = name_of

local function set_ref(ref, value)
	if type(ref) == "function" then ref(value)
	elseif type(ref) == "table" then ref.current = value end
end

-- Children normalisation ---------------------------------------------------------------

-- What a component returned, as a list of elements.
local function normalize(tx, out)
	if out == nil or out == false then return EMPTY end
	local t = type(out)
	if t == "string" or t == "number" then return { h(prim.Text, { tostring(out) }) } end
	if vnode.isElement(out) then return { out } end
	if t == "table" and getmetatable(out) == nil then return vnode.collect({}, out, table.maxn(out)) end
	if tx.D.isHandle(out) then return { h(M.Native, { handle = out }) } end
	error("lui: a component returned " .. t .. ", expected an element, a list, a string or nil", 0)
end

-- A container's children: strings become Text, iup handles become Native.
local function container_kids(tx, list)
	local out
	for i, c in ipairs(list) do
		local t = type(c)
		local v = c
		if t == "string" or t == "number" then v = h(prim.Text, { tostring(c) })
		elseif not vnode.isElement(c) then
			if tx.D.isHandle(c) then v = h(M.Native, { handle = c })
			else error("lui: a child of type " .. t .. " is not an element", 0) end
		end
		if v ~= c and not out then out = {}; for j = 1, i - 1 do out[j] = list[j] end end
		if out then out[i] = v end
	end
	return out or list
end

-- Fibers ---------------------------------------------------------------------------------

local function new_fiber(v)
	return { kind = kind_of(v.type), type = v.type, key = v.key, vnode = v, props = v.props, wip = true, new = true }
end

local function clone(old, v)
	return {
		kind = old.kind, type = old.type, key = old.key, vnode = v, props = v.props,
		host = old.host, inst = old.inst, attrs = old.attrs, hrec = old.hrec, instance = old.instance,
		placed = old.placed, ref = old.ref, rendered = old.rendered, alternate = old, wip = true,
	}
end

local work -- forward

local function slot_key(v, i)
	if v.key ~= nil then return "k" .. tostring(v.key) end
	return "i" .. i
end

--- Match new elements against the previous children by key (or position).
local function reconcile(tx, parent, old_list, vnodes)
	local by_key
	if #old_list > 0 then
		by_key = {}
		for _, f in ipairs(old_list) do by_key[f.slot] = f end
	end
	local out, used, seen = {}, {}, {}
	for i, v in ipairs(vnodes) do
		local k = slot_key(v, i)
		if seen[k] then
			tx.root:_warn("lui: duplicate key '" .. tostring(v.key) .. "' among the children of "
				.. tostring(parent.type and name_of(parent.type) or "the root") .. "; using its position")
			k = "i" .. i .. "#dup"
		end
		seen[k] = true
		local old = by_key and by_key[k]
		local f
		if old and old.type == v.type and not used[old] then
			used[old] = true
			if v == old.vnode and not old.pending and tx.ctx_changed == 0 then
				f = old -- bail out: nothing in here can have changed
			else
				f = clone(old, v)
				tx.cloned[#tx.cloned + 1] = old
				work(tx, f, old)
			end
		else
			f = new_fiber(v)
			work(tx, f, nil)
		end
		f.slot = k
		out[i] = f
	end
	for _, old in ipairs(old_list) do
		if not used[old] then tx.deletions[#tx.deletions + 1] = old end
	end
	return out
end

-- Components -------------------------------------------------------------------------------

local function read_context(tx, inst, ctx)
	inst.contexts = inst.contexts or {}
	inst.contexts[ctx] = true
	local stack = tx.ctx[ctx]
	if stack and #stack > 0 then return stack[#stack] end
	return ctx.default
end

local function context_changed(tx, inst)
	if not inst.contexts or tx.ctx_changed == 0 then return false end
	for ctx in pairs(inst.contexts) do
		if (tx.changed[ctx] or 0) > 0 then return true end
	end
	return false
end

local request_render -- forward

-- What a component instance gives its model: context reads for the render in progress,
-- and a way to ask for another render. The model (core.lui.hooks unless the component
-- type names another) holds all of the instance's state.
local function new_instance(tx, t)
	local inst = { name = name_of(t), root = tx.root, type = t,
		model = (type(t) == "table" and t.model) or hooks.model }
	inst.env = {
		readContext = function(ctx) return read_context(inst.tx, inst, ctx) end,
		schedule = function() request_render(inst) end,
	}
	return inst
end

local function render_component(tx, f, old)
	local t = f.type
	local inst = f.inst
	local fresh = inst == nil
	if fresh then
		inst = new_instance(tx, t)
		f.inst = inst
	end
	local must = fresh or inst.dirty or context_changed(tx, inst)
	if not must and old and old.vnode ~= f.vnode then
		if type(t) == "table" and t.memo then must = not t.memo(old.props, f.props) else must = true end
	end
	if must then
		local fn = type(t) == "function" and t or t.render
		inst.tx = tx
		local out, w = inst.model.render(inst, fn, f.props, inst.env)
		inst.tx = nil
		f.work = w
		tx.works[#tx.works + 1] = w
		f.rendered = normalize(tx, out)
	else
		f.rendered = old.rendered
	end
	f.children = reconcile(tx, f, old and old.children or EMPTY, f.rendered)
	-- post-order: a child's effects run before its parent's
	if f.work then
		for _, e in ipairs(f.work.effects or EMPTY) do
			e.inst = inst
			tx.effects[#tx.effects + 1] = e
		end
	end
end

-- Error boundaries -----------------------------------------------------------------------

local function mark(tx)
	return { #tx.effects, #tx.deletions, #tx.works, #tx.cloned }
end

-- The renders of a subtree that threw are dropped: neither committed nor aborted, so the
-- updates they consumed stay queued for whoever renders those instances next (nobody,
-- when the boundary's fallback replaces them).
local function rollback(tx, m)
	for i = #tx.effects, m[1] + 1, -1 do tx.effects[i] = nil end
	for i = #tx.deletions, m[2] + 1, -1 do tx.deletions[i] = nil end
	for i = #tx.works, m[3] + 1, -1 do tx.works[i] = nil end
end

local function render_boundary(tx, f, old)
	local inst = f.inst
	if not inst then inst = { name = "ErrorBoundary", root = tx.root, boundary = true }; f.inst = inst end
	local old_kids = old and old.children or EMPTY
	local err = inst.error
	if err == nil then
		local m = mark(tx)
		local depth = tx.ctx_depth
		local ok, e = pcall(function()
			f.children = reconcile(tx, f, old_kids, container_kids(tx, f.props.children))
		end)
		if ok then f.next_error = nil; return end
		rollback(tx, m)
		-- unwind the providers the failed subtree pushed
		for i = #tx.ctx_log, depth + 1, -1 do
			local entry = tx.ctx_log[i]
			table.remove(tx.ctx[entry[1]])
			if entry[2] then
				tx.changed[entry[1]] = tx.changed[entry[1]] - 1
				tx.ctx_changed = tx.ctx_changed - 1
			end
			tx.ctx_log[i] = nil
		end
		tx.ctx_depth = depth
		err = e
		f.caught = e
	end
	f.next_error = err
	local fb = f.props.fallback
	local out = fb
	if type(fb) == "function" then
		out = fb(type(err) == "table" and err.message or err, function() tx.root:_resetBoundary(inst) end)
	end
	f.children = reconcile(tx, f, old_kids, container_kids(tx, normalize(tx, out)))
end

-- The render-phase work for one fiber ---------------------------------------------

function work(tx, f, old)
	local k = f.kind
	if k == "host" then
		local def = f.type
		local kids = f.props.children
		local text
		if def.leaf or def.content then
			local parts
			for _, c in ipairs(kids) do
				local t = type(c)
				if t == "string" or t == "number" then parts = parts or {}; parts[#parts + 1] = tostring(c)
				elseif def.leaf then
					error("lui: " .. def.name .. " takes text, not child elements", 0)
				end
			end
			text = parts and table.concat(parts) or nil
		end
		if def.leaf then
			f.children = EMPTY
		else
			local elems = kids
			if def.content then
				elems = {}
				for _, c in ipairs(kids) do if type(c) ~= "string" and type(c) ~= "number" then elems[#elems + 1] = c end end
			end
			f.children = reconcile(tx, f, old and old.children or EMPTY, container_kids(tx, elems))
		end
		if def.attributes then f.next, f.next_tokens = def.attributes(f.props), nil
		else f.next, f.next_tokens = P.attributes(def, f.props, text) end
	elseif k == "component" then
		render_component(tx, f, old)
	elseif k == "fragment" then
		f.children = reconcile(tx, f, old and old.children or EMPTY, container_kids(tx, f.props.children))
	elseif k == "native" then
		local handle = f.props.handle
		if not tx.D.isHandle(handle) then error("lui: Native needs `handle`, an iup handle", 0) end
		f.host = handle
		f.children = EMPTY
		tx.live_natives[handle] = true
	elseif k == "provider" then
		local ctx = f.type.context
		local value = f.props.value
		local changed = old ~= nil and old.props.value ~= value
		tx.ctx[ctx] = tx.ctx[ctx] or {}
		table.insert(tx.ctx[ctx], value)
		tx.ctx_log[#tx.ctx_log + 1] = { ctx, changed }
		tx.ctx_depth = #tx.ctx_log
		if changed then
			tx.changed[ctx] = (tx.changed[ctx] or 0) + 1
			tx.ctx_changed = tx.ctx_changed + 1
		end
		f.children = reconcile(tx, f, old and old.children or EMPTY, container_kids(tx, f.props.children))
		if changed then
			tx.changed[ctx] = tx.changed[ctx] - 1
			tx.ctx_changed = tx.ctx_changed - 1
		end
		table.remove(tx.ctx[ctx])
		tx.ctx_log[#tx.ctx_log] = nil
		tx.ctx_depth = #tx.ctx_log
	elseif k == "boundary" then
		render_boundary(tx, f, old)
	else
		error("lui: unknown element kind " .. tostring(k), 0)
	end
end

-- Updates ----------------------------------------------------------------------------------

local function mark_pending(f)
	while f and not f.pending do
		f.pending = true
		f = f.parent
	end
end

--- Ask for `inst` to render again (its model calls this through `env.schedule`). A
-- no-op once the instance has unmounted.
function request_render(inst)
	if inst.unmounted then return end
	inst.dirty = true
	local root = inst.root
	if root._rendering or not inst.fiber then root._late[inst] = true
	else mark_pending(inst.fiber) end
	S.schedule(root)
end

-- Commit -------------------------------------------------------------------------------

local function collect_hosts(list, out)
	for _, f in ipairs(list) do
		if f.kind == "host" or f.kind == "native" then
			if f.host then out[#out + 1] = f.host end
		else
			collect_hosts(f.children or EMPTY, out)
		end
	end
	return out
end
M.collectHosts = collect_hosts

local function same_list(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end

local function remove_order(a, b)
	local na, nb = tonumber(a), tonumber(b)
	if na and nb then return na > nb end
	if na then return true end
	if nb then return false end
	return a < b
end

local function write_attrs(tx, f)
	local D, hnd, def = tx.D, f.host, f.type
	local old, new = f.attrs or EMPTY, f.next
	local removed
	-- two passes: a `late` attribute (a selection) goes after the items it selects
	for pass = 1, 2 do
		for name, v in pairs(new) do
			if (def.late[name] and 2 or 1) == pass then
				local differs
				if def.live[name] then differs = tostring(D.get(hnd, name)) ~= v else differs = old[name] ~= v end
				if differs then
					D.set(hnd, name, v)
					if P.LAYOUT[name] or name:match("^%d+$") then tx.layout[hnd] = true end
				end
			end
		end
	end
	for name in pairs(old) do
		if new[name] == nil then removed = removed or {}; removed[#removed + 1] = name end
	end
	if removed then
		table.sort(removed, remove_order)
		for _, name in ipairs(removed) do
			D.set(hnd, name, nil)
			if P.LAYOUT[name] or name:match("^%d+$") then tx.layout[hnd] = true end
		end
	end
	f.attrs = new
end

-- Re-assert a controlled widget's value after an event (the handler may have refused it).
local function reassert(D, f)
	for name in pairs(f.type.live) do
		local v = f.attrs and f.attrs[name]
		if v ~= nil and tostring(D.get(f.host, name)) ~= v then D.set(f.host, name, v) end
	end
end

local function fire(root, hrec, cbname, self, ...)
	local D = root._driver
	local f = hrec.fiber
	if not f then return D.DEFAULT end
	local n = select("#", ...)
	local args = { ... }
	local result
	local ok, err = pcall(S.batch, function()
		local cur = hrec.fiber
		if not cur then return end
		local props = cur.props
		local okh, r = xpcall(function()
			local raw = props[cbname]
			if type(raw) == "function" then return raw(self, unpack(args, 1, n)) end
			local evs = cur.type.cbEvents[cbname]
			if evs then
				for _, e in ipairs(evs) do
					local fn = props[e[1]]
					if fn then return e[2](fn, self, unpack(args, 1, n)) end
				end
			end
		end, traceback)
		if okh then result = r else root:_report(r) end
	end)
	if not ok then root:_report(err) end
	local cur = hrec.fiber
	if cur and cur.host and next(cur.type.live) then pcall(reassert, D, cur) end
	if result == nil then return D.DEFAULT end
	return result
end

local function install_events(tx, f)
	local D, def, props, rec = tx.D, f.type, f.props, f.hrec
	rec.installed = rec.installed or {}
	local function install(cbname)
		if rec.installed[cbname] then return end
		rec.installed[cbname] = true
		local root = tx.root
		D.setCallback(f.host, cbname, function(self, ...) return fire(root, rec, cbname, self, ...) end)
	end
	for ev, spec in pairs(def.events) do
		if props[ev] ~= nil then install(spec[1]) end
	end
	for k, v in pairs(props) do
		if type(v) == "function" and type(k) == "string"
			and (k:match("^[%l%d_]+_cb$") or k == "flat_action" or k == "action") then
			install(k)
		end
	end
end

local function commit_host(tx, f)
	local D, def = tx.D, f.type
	if not f.hrec then f.hrec = {} end
	f.hrec.fiber = f
	if not f.host then
		if def.mount then
			f.host, f.instance = def.mount(D, f.props, f.hrec)
			for name, v in pairs(f.next) do D.set(f.host, name, v) end
		else
			local early, late = f.next, nil
			if next(def.late) then
				early = {}
				for name, v in pairs(f.next) do
					if def.late[name] then late = late or {}; late[name] = v else early[name] = v end
				end
			end
			f.host = D.create(def.class, early)
			-- written once the children (or items) exist; see commit_fiber
			f.late_attrs = late
		end
		f.attrs = f.next
		tx.created[f.host] = true
		tx.created_list[#tx.created_list + 1] = f.host
	else
		write_attrs(tx, f)
		if def.update and f.alternate then def.update(D, f, f.props, f.alternate.props) end
	end
	f.next = nil
	install_events(tx, f)
	local tok = tx.root._tokens
	if f.next_tokens then tok[f.host] = f else tok[f.host] = nil end
	f.tokens, f.next_tokens = f.next_tokens, nil
end

local function child_after(D, parent, child, managed)
	local kids = D.children(parent)
	local found = false
	for _, c in ipairs(kids) do
		if found and managed[c] then return c, true end
		if c == child then found = true end
	end
	return nil, found
end

--- Put a host parent's managed children in order. Children the parent holds that lui
-- did not place (an extension's status element) are never moved or removed.
local function place(tx, parent_handle, f)
	local D = tx.D
	local desired = collect_hosts(f.children, {})
	local placed = f.placed or EMPTY
	if same_list(desired, placed) then f.placed = placed; return end
	-- first placement (none of them in the parent yet): append in order, exactly what an
	-- iup constructor does with its children
	if #placed == 0 then
		local fresh = true
		for _, c in ipairs(desired) do if D.parent(c) == parent_handle then fresh = false; break end end
		if fresh then
			for _, c in ipairs(desired) do
				if D.parent(c) then D.move(parent_handle, c, nil) else D.append(parent_handle, c) end
			end
			if #desired > 0 then tx.layout[parent_handle] = true end
			f.placed = desired
			return
		end
	end
	local managed, want = {}, {}
	for _, c in ipairs(desired) do managed[c] = true; want[c] = true end
	for _, c in ipairs(placed) do
		-- a Native placed elsewhere in this commit is moved there, not detached here
		if not want[c] and not tx.live_natives[c] and D.isHandle(c) and D.parent(c) == parent_handle then
			D.detach(c)
			tx.layout[parent_handle] = true
		end
	end
	for i = #desired, 1, -1 do
		local c, ref = desired[i], desired[i + 1]
		local in_place = false
		if D.parent(c) == parent_handle then
			local after, found = child_after(D, parent_handle, c, managed)
			in_place = found and after == ref
		end
		if not in_place then
			D.move(parent_handle, c, ref)
			tx.layout[parent_handle] = true
		end
	end
	f.placed = desired
end

local function commit_fiber(tx, f, parent)
	f.parent = parent
	if not f.wip then return end
	f.wip, f.pending = nil, nil
	local k = f.kind
	if k == "host" then commit_host(tx, f) end
	if k == "component" then
		local inst = f.inst
		inst.fiber = f
		inst.dirty = false
		if f.work then f.work.commit() end
		f.work = nil
	elseif k == "boundary" then
		local inst = f.inst
		inst.fiber, inst.dirty = f, false
		inst.error = f.next_error
		if f.caught then
			tx.caught[#tx.caught + 1] = { f.props.onError, f.caught }
			f.caught = nil
		end
	end
	for _, c in ipairs(f.children) do commit_fiber(tx, c, f) end
	if k == "host" and not f.type.leaf then place(tx, f.host, f) end
	if f.late_attrs then
		for name, v in pairs(f.late_attrs) do tx.D.set(f.host, name, v) end
		f.late_attrs = nil
	end
	if (k == "host" or k == "native") then
		local ref = f.vnode.ref
		if f.alternate and f.alternate.host ~= f.host and f.ref then set_ref(f.ref, nil) end
		if ref ~= f.ref or (f.alternate and f.alternate.host ~= f.host) then
			if f.ref and f.ref ~= ref then set_ref(f.ref, nil) end
			if ref then set_ref(ref, f.host) end
			f.ref = ref
		end
	end
	f.alternate, f.new = nil, nil
end

-- Unmount ---------------------------------------------------------------------------------

local function unmount_fiber(tx, f, natives)
	for _, c in ipairs(f.children or EMPTY) do unmount_fiber(tx, c, natives) end
	local inst = f.inst
	if inst and not inst.unmounted then
		-- from here on its setters and store subscriptions are no-ops
		inst.unmounted = true
		inst.fiber = nil
		if inst.model then
			local root = tx.root
			inst.model.unmount(inst, function(err) root:_report(err) end)
		end
	end
	if f.ref then set_ref(f.ref, nil); f.ref = nil end
	if f.kind == "native" then natives[#natives + 1] = f.host end
	if f.kind == "host" and f.host then
		tx.root._tokens[f.host] = nil
		if f.hrec then f.hrec.fiber = nil end
	end
end

--- Unmount a deleted subtree now (cleanups, refs) and queue its widgets for removal after
-- placement, so that a `Native` the new tree places elsewhere is moved there with
-- Reparent (keeping its native windows) before its old container is destroyed.
local function delete(tx, f)
	local natives = {}
	unmount_fiber(tx, f, natives)
	tx.dead[#tx.dead + 1] = { f, natives }
end

local function remove_dead(tx, f, natives)
	local D = tx.D
	-- embedded handles belong to someone else: take them out before their container
	-- dies, unless the new tree placed them somewhere (then they have moved already)
	for _, n in ipairs(natives) do
		if not tx.live_natives[n] and D.isHandle(n) and D.parent(n) then
			tx.layout[D.parent(n)] = true
			D.detach(n)
		end
	end
	for _, hnd in ipairs(collect_hosts({ f }, {})) do
		if D.isHandle(hnd) then
			local p = D.parent(hnd)
			local is_native = false
			for _, n in ipairs(natives) do if n == hnd then is_native = true end end
			if not is_native then
				if p then tx.layout[p] = true end
				D.destroy(hnd)
			end
		end
	end
end

-- Layout --------------------------------------------------------------------------------

--- The lowest common ancestors of a set of handles: one per connected tree.
local function common_ancestors(D, set)
	local trees = {}
	for hnd in pairs(set) do
		if D.isHandle(hnd) then
			local merged = false
			for _, t in ipairs(trees) do
				local e = hnd
				while e do
					local i = t.index[e]
					if i then
						if i > t.best then t.best = i end
						merged = true
						break
					end
					e = D.parent(e)
				end
				if merged then break end
			end
			if not merged then
				local path, index = {}, {}
				local e = hnd
				while e do path[#path + 1] = e; index[e] = #path; e = D.parent(e) end
				trees[#trees + 1] = { path = path, index = index, best = 1 }
			end
		end
	end
	local out = {}
	for _, t in ipairs(trees) do out[#out + 1] = t.path[t.best] end
	return out
end
M.commonAncestors = common_ancestors

-- Effects --------------------------------------------------------------------------------

local function run_effects(root, list, phase)
	for _, e in ipairs(list) do
		if e.phase == phase then
			local ok, err = xpcall(e.cleanup, traceback)
			if not ok then root:_report(err) end
		end
	end
	for _, e in ipairs(list) do
		if e.phase == phase and not e.inst.unmounted then
			local ok, err = xpcall(e.setup, traceback)
			if not ok then root:_report(err) end
		end
	end
end

-- Roots ----------------------------------------------------------------------------------

local Root = {}
Root.__index = Root
M.Root = Root

local drivers = setmetatable({}, { __mode = "k" })
local function driver_for(iup)
	local d = drivers[iup]
	if not d then d = Driver.iup(iup); drivers[iup] = d end
	return d
end
M.driverFor = driver_for

local log
function Root:_report(err)
	local msg = tostring(type(err) == "table" and (err.message and tostring(err) or err) or err)
	local on = self._opts.onError
	if on then
		local ok = pcall(on, msg, err)
		if ok then return end
	end
	if not log then
		local ok, l = pcall(require, "core.lib.log")
		log = ok and l.get("lui") or false
	end
	if log then pcall(log.error, log, msg) else io.stderr:write(msg, "\n") end
end

function Root:_warn(msg)
	if self._opts.onWarn then self._opts.onWarn(msg); return end
	if not log then
		local ok, l = pcall(require, "core.lib.log")
		log = ok and l.get("lui") or false
	end
	if log then pcall(log.warn, log, msg) end
end

function Root:_resetBoundary(inst)
	if inst.unmounted then return end
	inst.error = nil
	inst.dirty = true
	if inst.fiber then mark_pending(inst.fiber) end
	S.schedule(self)
end

local function new_tx(root)
	return {
		root = root, D = root._driver, effects = {}, deletions = {}, works = {}, cloned = {},
		ctx = {}, ctx_log = {}, ctx_depth = 0, changed = {}, ctx_changed = 0,
		layout = {}, created = {}, created_list = {}, caught = {}, dead = {}, live_natives = {},
	}
end

local function theme_new(root, tx)
	if not root._committed then return end
	local hook = root._opts.theme
	if hook == false then return end
	local D = tx.D
	for _, hnd in ipairs(tx.created_list) do
		local p = D.isHandle(hnd) and D.parent(hnd)
		if p and not tx.created[p] then
			if hook then pcall(hook, hnd)
			else
				local ok, TR = pcall(require, "core.ui.ThemeReactor")
				local tm = ok and TR.themeManager()
				if tm and tm.themeWidget then pcall(tm.themeWidget, tm, hnd) end
			end
		end
	end
end

function Root:_commit(tx, wip)
	local D = tx.D
	local rf = self._fiber
	for _, f in ipairs(tx.deletions) do delete(tx, f) end
	rf.children = wip.children
	for _, c in ipairs(rf.children) do commit_fiber(tx, c, rf) end
	if rf.host then place(tx, rf.host, rf) else rf.placed = collect_hosts(rf.children, {}) end
	for _, d in ipairs(tx.dead) do remove_dead(tx, d[1], d[2]) end
	rf.pending = nil
	-- one Refresh per tree whose layout changed
	local targets = common_ancestors(D, tx.layout)
	self._lastLayout = targets
	-- the first commit of a detached tree needs none: its owner places and lays it out
	if self._opts.layout ~= "manual" and (self._committed or rf.host) then
		for _, t in ipairs(targets) do if D.isMapped(t) then D.refresh(t) end end
	end
	theme_new(self, tx)
	self._committed = true
	for _, c in ipairs(tx.caught) do
		if c[1] then
			local ok, err = pcall(c[1], type(c[2]) == "table" and c[2].message or c[2])
			if not ok then self:_report(err) end
		else
			self:_report(c[2])
		end
	end
	run_effects(self, tx.effects, "layout")
	run_effects(self, tx.effects, "effect")
end

function Root:_flushNow()
	if self._unmounted or self._in_flush then return false end
	local rf = self._fiber
	if not rf.pending and self._committed and not self._element_changed then return true end
	self._in_flush = true
	self._element_changed = false
	local tx = new_tx(self)
	self._rendering = true
	local wip = { kind = "root" }
	local ok, err = xpcall(function()
		wip.children = reconcile(tx, rf, rf.children, { self._element })
	end, traceback)
	self._rendering = false
	if not ok then
		-- keep what is on screen; drop the updates that led here so the next flush
		-- does not throw the same error again
		for _, w in ipairs(tx.works) do w.abort() end
		for _, old in ipairs(tx.cloned) do
			old.pending = nil
			if old.inst then old.inst.dirty = false end
		end
		rf.pending = nil
		self._in_flush = false
		self:_report(err)
		self:_late_updates()
		return false
	end
	local cok, cerr = xpcall(function() self:_commit(tx, wip) end, traceback)
	self._in_flush = false
	if not cok then self:_report(cerr) end
	self:_late_updates()
	return cok
end

function Root:_late_updates()
	local late = self._late
	if not next(late) then return end
	self._late = {}
	for inst in pairs(late) do
		if not inst.unmounted and inst.dirty and inst.fiber then
			mark_pending(inst.fiber)
			S.schedule(self)
		end
	end
end

--- The root's top host widget (the first, when the tree has several at the top).
function Root:widget()
	local p = self._fiber.placed
	return p and p[1] or nil
end

--- All top host widgets.
function Root:widgets() return self._fiber.placed or {} end

--- Render a new element, or new props for the root component. Synchronous.
function Root:update(x)
	if vnode.isElement(x) then self._element = x
	else self._element = h(self._element.type, x or {}) end
	self._element_changed = true
	self._fiber.pending = true
	S.cancel(self)
	self:_flushNow()
end

--- Flush this root's pending updates now.
function Root:flush()
	S.cancel(self)
	return self:_flushNow()
end

--- What the last flush changed the layout of (the containers it refreshed, or would
-- have with `layout = "manual"`).
function Root:layoutChanged() return self._lastLayout or {} end

--- Unmount: effect cleanups run and the widgets are destroyed (Native ones detached).
function Root:unmount()
	if self._unmounted then return end
	S.cancel(self)
	local tx = new_tx(self)
	local rf = self._fiber
	for _, f in ipairs(rf.children) do delete(tx, f) end
	for _, d in ipairs(tx.dead) do remove_dead(tx, d[1], d[2]) end
	rf.children, rf.placed = {}, {}
	if self._opts.layout ~= "manual" then
		for _, t in ipairs(common_ancestors(tx.D, tx.layout)) do if tx.D.isMapped(t) then tx.D.refresh(t) end end
	end
	self._unmounted = true
end

-- Theme: palette tokens re-resolve on every theme switch.
function Root:_retheme(force)
	if self._unmounted then return end
	local D = self._driver
	for hnd, f in pairs(self._tokens) do
		if D.isHandle(hnd) and f.host == hnd and f.tokens then
			local attrs = f.type.attributes and f.type.attributes(f.props) or P.attributes(f.type, f.props, f.attrs and f.type.content and f.attrs[f.type.content])
			for name in pairs(f.tokens) do
				local v = attrs[name]
				if force or v ~= f.attrs[name] then D.set(hnd, name, v) end
				f.attrs[name] = v
			end
		end
	end
end
function Root:_onThemeApply() self:_retheme(false) end
-- a theme pass may have written over a token colour through an inherited role
function Root:_afterThemePass() self:_retheme(true) end

--- Mount an element (or a component, with `opts.props`).
-- @param el an element, or a component (function, `ui.component`, `ui.memo`)
-- @tparam[opt] table opts
-- @param opts.iup the iup table (default: the global `iup`)
-- @param opts.driver a driver instead of the iup one
-- @param opts.parent an iup container to render the children into
-- @param opts.props props for a component given as `el`
-- @param opts.onError `fn(message, err)` for render/effect/handler errors (default: log)
-- @param opts.layout `"auto"` (default): one `iup.Refresh` per flush where the layout
--   changed; `"manual"`: never refresh, the owner does (`root:layoutChanged()`)
-- @param opts.theme `fn(handle)` for subtrees created after the first commit (default:
--   the bound ThemeManager's `themeWidget`); `false` for none
-- @param opts.schedule `fn(flush)` instead of the driver's timer
-- @treturn Root
function M.mount(el, opts)
	opts = opts or {}
	local D = opts.driver
	if not D then
		local iup = opts.iup or rawget(_G, "iup")
		if not iup then error("lui.mount: no iup (pass opts.iup)", 2) end
		D = driver_for(iup)
	end
	if not vnode.isElement(el) then
		kind_of(el)
		el = h(el, opts.props or {})
	end
	local root = setmetatable({
		_driver = D, _opts = opts, _element = el, _late = {},
		_tokens = setmetatable({}, { __mode = "k" }),
		_fiber = { kind = "root", children = {}, host = opts.parent, placed = {} },
	}, Root)
	local ok, TR = pcall(require, "core.ui.ThemeReactor")
	if ok and TR then TR.register(root) end
	root:_flushNow()
	return root
end

return M

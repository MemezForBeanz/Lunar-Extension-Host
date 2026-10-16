--- Reading IUP's `_IUP`-prefixed (internal) attributes from Lua.
--
-- ### The trap
--
-- IUP treats any attribute whose name begins with `_IUP` as *internal*. The host
-- uses that prefix deliberately, because internal attributes are **local to the
-- widget**: ordinary unregistered attributes are inherited by every descendant, and
-- a tab's layout key or a group's name showing up on every widget inside the page
-- makes the tree impossible to read back (see `core.classes.TabGroups`).
--
-- Writing them works exactly as expected. **Reading them from Lua does not.** The
-- `iuplua` binding filters them out on the way back:
--
--     /* srclua5/iuplua_api.c, iuplua_pushvalue */
--     if (!value || iupATTRIB_ISINTERNAL(name))
--       lua_pushnil(L);
--
-- So `iup.GetAttribute(w, "_IUPLUNAR_TABKEY")` returns `nil` **always**, no matter
-- what was stored. There is no error and no warning; the value is simply invisible.
--
-- ### What that cost
--
-- Every consumer of these attributes silently behaved as if the value had never
-- been set:
--
--   * `core.lib.handle` handed out a fresh id on every call, so `handle.same()`
--     answered "different widget" for two handles to the *same* widget -- defeating
--     the very identity checks that module exists to provide.
--   * `core.classes.TabGroups` read no layout key for any tab, so `serialize()`
--     dropped every tab from the saved arrangement. Groups persisted; their
--     contents did not. On the next launch every plugin tab was "unplaced" and got
--     appended at the root -- tabs falling out of their groups on restart.
--
-- ### The fix
--
-- Read through the C entry point directly (`core.classes.IupFFI`, which calls
-- `IupGetAttribute` via the FFI), bypassing the binding's filter. The value comes
-- back exactly as stored.
--
-- The plain `iup.GetAttribute` path is kept as a fallback for hosts without the
-- FFI -- and for the busted suite, whose fake `iup` table has no such filter, so
-- the tests exercise the same code without needing the real toolkit.
--
-- @module core.lib.attr

local M = {}

local ok_ffi, IupFFI = pcall(require, "core.classes.IupFFI")
if not ok_ffi then IupFFI = nil end

--- Is the direct C read path available?
-- When false, `get` falls back to `iup.GetAttribute`, which cannot see `_IUP`
-- attributes on a real IUP build.
-- @treturn boolean
function M.available()
	return (IupFFI ~= nil and IupFFI.available) and true or false
end

--- Read an attribute, including `_IUP`-prefixed internal ones.
-- @tparam table iup the IUP binding
-- @tparam userdata widget the widget to read from
-- @tparam string name attribute name
-- @treturn string|nil the stored value, or `nil` when unset
-- @usage local key = attr.get(iup, page, "_IUPLUNAR_TABKEY")
function M.get(iup, widget, name)
	if widget == nil or type(name) ~= "string" then return nil end

	if IupFFI and IupFFI.available then
		local ok, value = pcall(function()
			local p = IupFFI.ptr(widget)
			if p == nil then return nil end
			return IupFFI.get(p, name)
		end)
		if ok and value ~= nil then return value end
		-- A nil here is ambiguous: either genuinely unset, or the handle could not
		-- be resolved. Fall through to the binding, which settles both cases the
		-- same way and keeps behaviour identical under the test doubles.
	end

	local ok, value = pcall(iup.GetAttribute, widget, name)
	if not ok then return nil end
	return value
end

--- Write an attribute.
--
-- A thin pass-through: `iup.SetAttribute` maps to `IupStoreAttribute`, which
-- copies the string even for internal names, so writing never needed a workaround.
-- It exists so call sites read symmetrically with `get` and nobody has to remember
-- which half of the pair was the broken one.
--
-- @tparam table iup the IUP binding
-- @tparam userdata widget the widget to write to
-- @tparam string name attribute name
-- @tparam string|nil value the value to store
-- @usage attr.set(iup, page, "_IUPLUNAR_TABKEY", "ext.demo/1")
function M.set(iup, widget, name, value)
	if widget == nil or type(name) ~= "string" then return end
	pcall(iup.SetAttribute, widget, name, value)
end

return M

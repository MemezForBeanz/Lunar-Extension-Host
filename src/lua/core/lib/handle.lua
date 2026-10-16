--- Stable identity for IUP handles.
--
-- ### Never compare two IUP handles with `==`
--
-- `iuplua_pushihandle_raw` (`srclua5/iuplua.c`) calls `lua_newuserdata` on every
-- push, so the binding hands out a **brand new Lua object each time** the same
-- widget crosses the C boundary:
--
--     local a = iup.GetChild(tabs, 0)
--     local b = iup.GetChild(tabs, 0)
--     a == b   --> false, for the same widget
--
-- Attribute and callback access still work through either object — those resolve
-- to the underlying `Ihandle*`, and a shared widget table carries the callbacks —
-- so the breakage is invisible until code tries to answer "is this the same
-- widget?". Then every such test silently answers "no", and guard clauses written
-- to prevent something instead permit it.
--
-- That is not hypothetical. In the tab strip it meant a plain click resolved as a
-- drop of a tab onto *itself*, which the self-drop guard failed to catch, so
-- clicking a tab wrapped it in a brand new group; and the "don't move a group
-- inside itself" check failed the same way. It also silently disabled position
-- lookup (`_posOf`), ancestor walks, and the same-strip index correction, because
-- all of them scan children looking for `child == widget`.
--
-- This module gives each handle a durable id, stored on the widget itself under an
-- `_IUP`-prefixed (and therefore local, non-inherited — see
-- `core.classes.TabGroups`) attribute. Two handles are the same widget when their
-- ids match.
--
-- @module core.lib.handle

local M = {}

local attr = require("core.lib.attr")

local ATTR = "_IUPLUNAR_HANDLEID"

-- Process-local and monotonic. Never persisted and never reset: these ids mean
-- "the same widget in this session", nothing more. The durable, cross-session
-- identity of a tab is its layout key (see `core.classes.TabGroups`).
local counter = 0

--- The stable id of a handle, assigning one on first use.
--
-- Read through `core.lib.attr`, NOT `iup.GetAttribute`. The id is stored under an
-- `_IUP`-prefixed name so IUP keeps it local to the widget, and the Lua binding
-- returns `nil` for every such attribute regardless of what is stored (see
-- `core.lib.attr`). Reading it directly therefore always missed, so every call
-- minted a fresh id and `same()` never recognised a widget it had already seen --
-- silently disabling every identity check built on top of it.
--
-- @tparam table iup the IUP binding
-- @tparam userdata widget any IUP handle
-- @treturn string|nil the id, or `nil` when `widget` is nil
function M.id(iup, widget)
	if widget == nil then return nil end
	local value = attr.get(iup, widget, ATTR)
	if value then return value end
	counter = counter + 1
	local id = "h" .. tostring(counter)
	attr.set(iup, widget, ATTR, id)
	return id
end

--- Do two handles refer to the same widget?
-- @tparam table iup the IUP binding
-- @tparam userdata a first handle (may be nil)
-- @tparam userdata b second handle (may be nil)
-- @treturn boolean
function M.same(iup, a, b)
	if a == nil or b == nil then return false end
	if rawequal(a, b) then return true end
	return M.id(iup, a) == M.id(iup, b)
end

return M

--- The host driver: everything the reconciler does to widgets, behind one small table.
--
-- The first driver speaks the `iup` API (`iup[class](attrs)`, `iup.SetAttribute`,
-- `iup.Append`/`Insert`/`Detach`/`Destroy`, `iup.Map`, `iup.Refresh`), so components
-- run on the native IUP build and on the ImGui emulator alike, and their widgets are
-- ordinary iup handles any existing code can hold. A driver that builds emulator
-- elements directly can replace it later without touching components: the reconciler
-- uses only the functions below.
--
--     create(class, attrs) -> handle           attrs: { NAME = "string" }
--     set(h, name, value)                      value: string, handle, or nil (reset)
--     get(h, name) -> string|nil
--     setCallback(h, name, fn)                 name: the lower-case iuplua callback name
--     children(h) -> { handle, ... }           in order, internal children included
--     parent(h) -> handle|nil
--     append(parent, child)  insert(parent, ref, child)   (before ref)
--     move(parent, child, ref|nil)             reparent a placed child (nil ref: append)
--     detach(child)  destroy(h)  map(child)    (map only when the parent is mapped)
--     refresh(h)  isHandle(v)  handle(name)    (iup.GetHandle)
--     timer(ms, fn) -> { start = fn, stop = fn }
--
-- @module core.lui.driver
local M = {}

--- A driver over an `iup` table.
-- @param iup the iup binding (`core.imgui.iup` or iuplua)
function M.iup(iup)
	assert(type(iup) == "table", "lui driver: an iup table is required")
	local D = { iup = iup, name = "iup" }

	local function is_handle(v)
		if v == nil then return false end
		if iup.ihandle then return iup.ihandle(v) and true or false end
		return type(v) == "userdata"
	end
	D.isHandle = is_handle

	function D.create(class, attrs)
		local ctor = iup[class]
		if type(ctor) ~= "function" then error("lui: iup has no class '" .. tostring(class) .. "'", 0) end
		local init = {}
		local handles
		for k, v in pairs(attrs) do
			if is_handle(v) then handles = handles or {}; handles[k] = v else init[k] = v end
		end
		local h = ctor(init)
		if handles then for k, v in pairs(handles) do iup.SetAttributeHandle(h, k, v) end end
		return h
	end

	function D.set(h, name, value)
		if is_handle(value) then iup.SetAttributeHandle(h, name, value)
		else iup.SetAttribute(h, name, value) end
	end

	function D.get(h, name) return iup.GetAttribute(h, name) end

	-- iuplua binds a function stored under a lower-case key as the callback.
	function D.setCallback(h, name, fn) h[name] = fn end

	function D.children(h)
		local out = {}
		local n = iup.GetChildCount(h) or 0
		for i = 0, n - 1 do out[#out + 1] = iup.GetChild(h, i) end
		return out
	end

	function D.parent(h) return iup.GetParent(h) end

	--- The children other code may have put there: not the ones a class keeps for itself
	-- (a split's sash, a scroll box's scrollbars). The emulator marks those; on the native
	-- build the classes that have them are skipped.
	local INTERNAL = { split = true, flatscrollbox = true, scrollbox = true }
	function D.userChildren(h)
		local E = iup._Element
		if E and E.userChildren then return E.userChildren(h) end
		if iup.GetClassName and INTERNAL[iup.GetClassName(h)] then return {} end
		return D.children(h)
	end

	local function mapped(h)
		local ok, wid = pcall(iup.GetAttribute, h, "WID")
		return ok and wid ~= nil
	end
	D.isMapped = mapped

	-- A child added to a mapped parent must be mapped by hand, as with IupAppend.
	function D.map(child)
		local p = iup.GetParent(child)
		if p and mapped(p) and not mapped(child) then pcall(iup.Map, child) end
	end

	function D.append(parent, child)
		iup.Append(parent, child)
		D.map(child)
	end

	function D.insert(parent, ref, child)
		iup.Insert(parent, ref, child)
		D.map(child)
	end

	--- Move a child that may already be placed (and mapped) somewhere: IupReparent keeps
	-- a mapped child's native window, Detach + Insert would unmap it.
	function D.move(parent, child, ref)
		if iup.GetParent(child) and iup.Reparent then
			iup.Reparent(child, parent, ref)
			return
		end
		if iup.GetParent(child) then iup.Detach(child) end
		if ref then D.insert(parent, ref, child) else D.append(parent, child) end
	end

	function D.detach(child) if iup.GetParent(child) then iup.Detach(child) end end
	function D.destroy(h) iup.Destroy(h) end
	function D.refresh(h) iup.Refresh(h) end
	function D.handle(name) return iup.GetHandle(name) end

	--- A one-shot timer the scheduler restarts. Zero delay is not allowed by IUP; 1 ms
	-- fires on the next pass of the loop.
	function D.timer(ms, fn)
		local t = iup.timer({ TIME = tostring(math.max(1, ms or 1)), RUN = "NO" })
		t.action_cb = function()
			iup.SetAttribute(t, "RUN", "NO")
			fn()
			return iup.DEFAULT
		end
		return {
			start = function() iup.SetAttribute(t, "RUN", "NO"); iup.SetAttribute(t, "RUN", "YES") end,
			stop = function() iup.SetAttribute(t, "RUN", "NO") end,
			handle = t,
		}
	end

	D.DEFAULT = iup.DEFAULT or -2

	--- What a handler returned, as IUP wants it: nil is the default; `ui.CLOSE`,
	-- `ui.IGNORE`, `ui.CONTINUE` ("close", "ignore", "continue") map to IUP's codes; a
	-- number (an iup constant from the compatibility namespace) passes through.
	local RESULTS = { close = iup.CLOSE or -3, ignore = iup.IGNORE or -1, continue = iup.CONTINUE or -4,
		default = D.DEFAULT }
	function D.result(r)
		if r == nil then return D.DEFAULT end
		if type(r) == "number" then return r end
		local code = RESULTS[r]
		if code == nil then error("lui: a handler returned " .. tostring(r) .. "; return ui.CLOSE, ui.IGNORE, ui.CONTINUE or nothing", 0) end
		return code
	end
	--- The main-loop nesting level (a modal iup.Popup runs one level deeper).
	function D.loopLevel() return iup.MainLoopLevel and iup.MainLoopLevel() or 0 end
	return D
end

return M

-- Fullscreen state for a page that owns the application's main dialog.
--
-- IUP changes the dialog, not the page, so the native video host remains mapped
-- to the same HWND while the dialog enters and leaves fullscreen.
-- @module core.ui.Fullscreen

local M = {}

local function get(iup, widget, name)
	local ok, value = pcall(iup.GetAttribute, widget, name)
	return ok and value or nil
end

local function set(iup, widget, name, value)
	local ok, err = pcall(iup.SetAttribute, widget, name, value)
	if not ok then return nil, err end
	return true
end

function M.new(opts)
	opts = opts or {}
	local iup, dialog, tabs, ctx = opts.iup, opts.dialog, opts.tabs, opts.context
	local state
	local escape

	local api = {}

	function api.active()
		return state ~= nil
	end

	function api.enter()
		if state or not dialog then return state ~= nil end
		state = {
			fullscreen = get(iup, dialog, "FULLSCREEN"),
			maximized = get(iup, dialog, "MAXIMIZED"),
			placement = get(iup, dialog, "PLACEMENT"),
			tab = tabs and get(iup, tabs, "VALUEPOS") or nil,
		}
		local ok, err = set(iup, dialog, "FULLSCREEN", "YES")
		if not ok then
			state = nil
			return nil, err
		end
		-- Register this only while fullscreen is active, so Escape keeps its
		-- normal meaning everywhere else in the media extension.
		if ctx and ctx.registerShortcut and iup.K_ESC then
			escape = ctx:registerShortcut(iup.K_ESC, function()
				if api.active() then api.exit() end
			end)
		end
		return true
	end

	function api.exit()
		if not state then return false end
		local prior = state
		state = nil
		if escape and ctx and ctx.unregisterShortcut then
			ctx:unregisterShortcut(escape)
			escape = nil
		end
		-- FULLSCREEN is a real dialog mode in IUP. Leaving it restores the
		-- previous native placement; restore the tab defensively in case a
		-- platform callback changed it during the transition.
		local ok, err = set(iup, dialog, "FULLSCREEN", prior.fullscreen == "YES" and "YES" or "NO")
		if not ok then return nil, err end
		if prior.fullscreen ~= "YES" and prior.maximized and get(iup, dialog, "MAXIMIZED") ~= prior.maximized then
			-- IUP applies PLACEMENT on Show for an already mapped dialog. This
			-- keeps a previously maximized or normal window from being changed
			-- as a side effect of leaving fullscreen.
			set(iup, dialog, "PLACEMENT", prior.maximized == "YES" and "MAXIMIZED" or "NORMAL")
			if iup.Show then pcall(iup.Show, dialog) end
		end
		if tabs and prior.tab ~= nil and get(iup, tabs, "VALUEPOS") ~= prior.tab then
			set(iup, tabs, "VALUEPOS", prior.tab)
		end
		return true
	end

	function api.toggle()
		if api.active() then return api.exit() end
		return api.enter()
	end

	function api.close()
		if api.active() then return api.exit() end
		return true
	end

	return api
end

return M

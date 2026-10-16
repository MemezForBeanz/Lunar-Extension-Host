--- Theme-aware status indicator widget backed by `core.ui.VectorIcon`.
-- Maps nine semantic state names (e.g. `"db_ok"`, `"build_error"`, `"upd_get"`) to
-- source SVG files and semantic color roles so icons recolor live on every theme
-- switch.  Public API is identical to the retired PNG-based version — all existing
-- call sites work unchanged.
--
-- When LuaJIT FFI or the `svgicon` C bridge is unavailable (`VectorIcon.available`
-- is `false`) a transparent no-op stub is returned so callers never error.
--
-- **State names** (pass to `set` / `startSpinState`):
-- `db_ok`, `db_alert`, `db_error`, `upd_complete`, `upd_get`, `upd_check`,
-- `upd_now`, `build_ok`, `build_warn`, `build_skip`, `build_error`.
--
-- @usage
--   local StatusIcon = require("core.ui.StatusIcon")
--   -- Database indicator
--   local db = StatusIcon.new(iup, { dir = ICON_DIR, size = 20 })
--   hbox:append(db:widget())
--   db:set("db_ok", "Database connected")
--
--   -- Animated spinner
--   local spin = StatusIcon.new(iup, { dir = ICON_DIR, size = 16 })
--   spin:startSpin("Build in progress...")
--   -- later:
--   spin:stopSpin("build_ok", "Build succeeded")
-- @module core.ui.StatusIcon
local VectorIcon = require("core.ui.VectorIcon")
local SEP = require("core.platform").sep

local StatusIcon = {}
StatusIcon.__index = StatusIcon

-- state name -> { file = "<source .svg in `dir`>", role = "<VectorIcon semantic role>" }
-- Role names are resolved to theme colors by VectorIcon.roleColor (see its
-- "Theme-aware semantic colors" section) -- the exact same success/warning/
-- error/info mapping the old render_icons.py used as FIXED colors, except this
-- now tracks the active theme.
local STATES = {
	db_ok        = { file = "data--base.svg",          role = "success" },
	db_alert     = { file = "data--alert.svg",         role = "warning" },
	db_error     = { file = "data--error.svg",         role = "error" },
	upd_complete = { file = "update-complete.svg",     role = "success" },
	upd_get      = { file = "update--get.svg",         role = "info" },
	upd_check    = { file = "update--get.svg",         role = "warning" },
	upd_now      = { file = "update-now.svg",          role = "info" },
	build_ok     = { file = "checkmark--outline.svg",  role = "success" },
	build_warn   = { file = "in-progress--warning.svg", role = "warning" },
	build_skip   = { file = "in-progress--warning.svg", role = "warning" },
	build_error  = { file = "in-progress--error.svg",  role = "error" },
}
local SPINNER_FILE = "in-progress.svg"
local SPINNER_ROLE = "info"

local function state_path(dir, basename)
	local s = STATES[basename]
	if not s or not dir then
		return nil
	end
	return dir .. SEP .. s.file, s.role
end

-- Minimal no-op stand-in used only if VectorIcon itself is unavailable (FFI /
-- svgicon / struct-layout mismatch -- mirrors core.classes.IupFFI.available).
-- Keeps every StatusIcon call site working (just displaying no icon) instead
-- of erroring, matching the rest of the app's FFI-unavailable degradation.
local function fallback_icon(iup, tip)
	local label = iup.label({ title = "", TIP = tip or "", ALIGNMENT = "ACENTER:ACENTER" })
	local stub = { _spinning = false }
	function stub:widget() return label end
	function stub:setIconRole() return self end
	function stub:setTooltip(text)
		pcall(iup.SetAttribute, label, "TIP", tostring(text or ""))
		return self
	end
	function stub:spin(_dir) self._spinning = true return self end
	function stub:stopSpin() self._spinning = false return self end
	function stub:isSpinning() return self._spinning end
	return stub
end

--- Create a new StatusIcon.
-- **opts fields:**
--
-- * `dir` `string` — absolute path to the source SVG folder (`assets/Icons`).
-- * `size` `number` (default `20`) — icon square size in pixels.
-- * `tip` `string` *(optional)* — initial tooltip text.
-- * `state` `string` *(optional)* — initial state name (one of the state names listed in the module description).
--
-- @tparam userdata iup The IUP library reference.
-- @tparam[opt] table opts Construction options (see above).
-- @treturn StatusIcon New instance (or a no-op stub when `VectorIcon.available` is `false`).
function StatusIcon.new(iup, opts)
	opts = opts or {}
	local self = setmetatable({}, StatusIcon)
	self.iup = iup
	self.dir = opts.dir
	self.size = opts.size or 20
	self._vi = VectorIcon.available and VectorIcon.new(iup, { size = self.size, tip = opts.tip })
		or fallback_icon(iup, opts.tip)
	if opts.state then
		self:set(opts.state, opts.tip)
	end
	return self
end

--- Return the IUP label widget to add to a layout.
-- @treturn userdata IUP label handle.
function StatusIcon:widget()
	return self._vi:widget()
end

--- Register a static icon image handle for use outside a widget (e.g. a list's per-row `IMAGEid`).
-- Colors are resolved from the **current** theme at call time; request a fresh handle after a
-- theme switch if live recoloring is needed.  Returns `nil` when VectorIcon is unavailable or
-- `basename` is not a known state name.
-- @tparam userdata iup The IUP library reference.
-- @tparam string dir Absolute path to the source SVG folder.
-- @tparam string basename State name (e.g. `"build_ok"`).
-- @tparam[opt=20] number size Square render size in pixels.
-- @treturn string|nil IUP image handle name, or `nil` on failure.
function StatusIcon.imageHandle(iup, dir, basename, size)
	if not VectorIcon.available then
		return nil
	end
	local path, role = state_path(dir, basename)
	if not path then
		return nil
	end
	return VectorIcon.imageHandle(iup, { path = path, size = size or 20, color = VectorIcon.roleColor(role) })
end

--- Switch the displayed icon to a named state and optionally update the tooltip.
-- Missing states or missing SVG files are ignored gracefully.
-- The icon remains theme-aware and recolors on future theme switches.
-- @tparam string basename State name (e.g. `"db_ok"`, `"build_error"`).
-- @tparam[opt] string tooltip New tooltip text; `nil` leaves the current tooltip unchanged.
-- @treturn StatusIcon `self` for chaining.
function StatusIcon:set(basename, tooltip)
	local path, role = state_path(self.dir, basename)
	if path then
		self._vi:setIconRole(path, role)
	end
	if tooltip ~= nil then
		self._vi:setTooltip(tooltip)
	end
	return self
end

--- Update the hover tooltip text.
-- @tparam string text New tooltip string.
-- @treturn StatusIcon `self` for chaining.
function StatusIcon:setTooltip(text)
	self._vi:setTooltip(text)
	return self
end

--- Begin a continuous rotation animation using the generic `in-progress.svg` spinner glyph.
-- Switches to the spinner icon and starts rotating it at 12 fps clockwise.
-- Call `stopSpin` to stop and settle on a final state.
-- @tparam[opt] string tooltip Tooltip shown while spinning.
-- @treturn StatusIcon `self` for chaining.
function StatusIcon:startSpin(tooltip)
	if self.dir then
		self._vi:setIconRole(self.dir .. SEP .. SPINNER_FILE, SPINNER_ROLE)
	end
	self._vi:spin(12, tooltip)
	return self
end

--- Spin a specific named state icon in place (without switching to the generic spinner glyph).
-- Useful for animating a semantic icon — e.g. the update icon while a check is in flight.
-- @tparam string basename State name whose SVG file is used as the spinning glyph.
-- @tparam[opt] string direction `"ccw"` for counter-clockwise; default is clockwise.
-- @tparam[opt] string tooltip Tooltip shown while spinning.
-- @treturn StatusIcon `self` for chaining.
function StatusIcon:startSpinState(basename, direction, tooltip)
	local path, role = state_path(self.dir, basename)
	if path then
		self._vi:setIconRole(path, role)
	end
	self._vi:spin(12, tooltip, direction)
	return self
end

--- Stop spinning and optionally settle on a final state.
-- @tparam[opt] string finalState State name to switch to after stopping (e.g. `"build_ok"`).
-- @tparam[opt] string tooltip Tooltip text after stopping.
-- @treturn StatusIcon `self` for chaining.
function StatusIcon:stopSpin(finalState, tooltip)
	self._vi:stopSpin()
	if finalState then
		self:set(finalState, tooltip)
	elseif tooltip ~= nil then
		self:setTooltip(tooltip)
	end
	return self
end

--- Return whether the spinner is currently running.
-- @treturn boolean `true` while a spin animation is active.
function StatusIcon:isSpinning()
	return self._vi:isSpinning()
end

return StatusIcon

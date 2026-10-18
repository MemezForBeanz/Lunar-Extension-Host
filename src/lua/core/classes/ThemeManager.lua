--- Applies the active theme to the live IUP widget tree and switches themes at runtime.
--
-- Records each widget's original attributes the first time it is themed, so a
-- later switch can restore them before applying the next theme's rules.

local class = require("middleclass")
local ThemeBase     = require("core.classes.Themes.Theme")  -- base class for all theme objects
local ThemePalette  = require("core.classes.Theme")         -- active-palette registry (Theme.set/get/color)

local ThemeManager = class("ThemeManager")

-- Sentinel stored in the originals table to mark "this attribute was unset when we
-- first themed it" (distinct from "not tracked", which is a plain nil/absent key).
-- It is intentionally the boolean `false` rather than a string sentinel: the native
-- themeapply.restore helper restores any string value with IupSetStrAttribute and
-- treats every non-string entry (i.e. false) as a clear -- so the store can be
-- handed straight to C without translation.
local UNSET = false
-- Void layout containers: IupVbox/Hbox/Zbox/Cbox/Gridbox create no native window
-- and draw no background of their own. Their bg/fg/font rules exist only to seed
-- inheritance -- but the dialog already sets identical bg/fg/font, and IUP attribute
-- inheritance walks the parent chain up to the dialog regardless of intermediate
-- boxes, so theming each of these is redundant. Worse, each NTHEME/SetAttribute on
-- a container forces a synchronous layout re-measure of its (visible) subtree, which
-- profiling showed to be the dominant cost of a theme switch (vbox alone ~880ms of a
-- ~2700ms classic->dark walk). We skip theming them entirely; leaves still inherit
-- the right colors/font from the dialog. NOTE: drawing containers (split, frame,
-- flatframe, tabs, flattabs, scrollbox, flatscrollbox) are intentionally NOT here --
-- they render their own surface/border and must still be themed.
local VOID_CONTAINERS = {
	vbox = true,
	hbox = true,
	zbox = true,
	cbox = true,
	gridbox = true,
}

local CLASS_RULES = {
	dialog = true,
	canvas = true,
	vbox = true,
	hbox = true,
	zbox = true,
	cbox = true,
	gridbox = true,
	split = true,
	frame = true,
	flatframe = true,
	tabs = true,
	flattabs = true,
	scrollbox = true,
	flatscrollbox = true,
	label = true,
	button = true,
	flatbutton = true,
	toggle = true,
	flattoggle = true,
	text = true,
	multiline = true,
	list = true,
	flatlist = true,
	progressbar = true,
	gauge = true,
	dropbutton = true,
	flatseparator = true,
	separator = true,
}

-- middleclass v4 exposes :isSubclassOf() on every class object.
local function isThemeSubclass(cls)
	return type(cls) == "table"
		and type(cls.isSubclassOf) == "function"
		and cls ~= ThemeBase
		and cls:isSubclassOf(ThemeBase)
end

function ThemeManager:initialize(opts)
	self._iup = opts.iup
	self._settings = opts.settings
	self._root = nil
	local ok_df, default_font = pcall(self._iup.GetGlobal, "DEFAULTFONT")
	self._orig_default_font = (ok_df and default_font ~= "" and default_font) or nil
	local ok_dlg, dlg_font = pcall(self._iup.GetGlobal, "DLGFONT")
	self._orig_dlg_font = (ok_dlg and dlg_font ~= "" and dlg_font) or nil
	local ok_tip_bg, tip_bg = pcall(self._iup.GetGlobal, "TIPBGCOLOR")
	self._orig_tip_bg = (ok_tip_bg and tip_bg ~= "" and tip_bg) or nil
	local ok_tip_fg, tip_fg = pcall(self._iup.GetGlobal, "TIPFGCOLOR")
	self._orig_tip_fg = (ok_tip_fg and tip_fg ~= "" and tip_fg) or nil
	local ok_tip_font, tip_font = pcall(self._iup.GetGlobal, "TIPFONT")
	self._orig_tip_font = (ok_tip_font and tip_font ~= "" and tip_font) or nil
	local ok_tip_border, tip_border = pcall(self._iup.GetGlobal, "TIPBORDERCOLOR")
	self._orig_tip_border = (ok_tip_border and tip_border ~= "" and tip_border) or nil

	-- Auto-discover all Theme subclasses embedded under core.classes.Themes.*.
	-- embed_lua registers every .lua file found in src/lua/core/classes/Themes/ into
	-- package.preload at build time, so dropping a new theme file there is sufficient
	-- -- no change to ThemeManager required.
	local themeInstances = {}
	for modname in pairs(package.preload) do
		if modname:match("^core%.classes%.Themes%.") then
			local ok, mod = pcall(require, modname)
			if ok and isThemeSubclass(mod) then
				themeInstances[#themeInstances + 1] = mod:new()
			end
		end
	end
	table.sort(themeInstances, function(a, b) return a:id() < b:id() end)
	self._themes = themeInstances
	self._theme_by_id = {}
	for _, t in ipairs(self._themes) do
		self._theme_by_id[t:id()] = t
	end

	self._current = "classic"
	self._active = self._theme_by_id.classic
	self._menu_items = {}
	self._dropdown = nil
	self._applying = false

	-- Tracks which theme id has actually been painted onto the live root. Distinct
	-- from _current/_active (which are seeded to classic before the first real
	-- apply), so the startup apply is never skipped by the no-op guard.
	self._applied = nil

	-- Coalesced/deferred theming. Tab/settings additions schedule a subtree (or a
	-- full) re-theme on a one-shot timer so a burst of additions collapses into a
	-- single batched repaint instead of one full-dialog walk per addition.
	self._apply_timer = nil
	self._pending_full = false
	self._pending_subtrees = {}

	-- Native paint-batching module (optional). Suspends window painting around the
	-- theme walk so the dialog repaints once instead of rippling widget-by-widget.
	local ok_wr, wr = pcall(require, "winredraw")
	self._winredraw = (ok_wr and wr) or nil

	self._native_supported = self:_detectNativeThemeSupport()
	self._native_handles = {}
	self._native_role_handles = {}

	-- Cache of per-element IupUser "bundle" handles keyed by theme id -> "cls|role".
	-- When native theming is active each widget is themed by pointing its NTHEME at
	-- one of these prebuilt handles (a single native write that applies the whole
	-- attribute set in C) instead of issuing ~10-25 individual SetAttribute writes
	-- per node from Lua. See _ensureElementHandle / _applyElementNative.
	self._element_handles = {}

	-- Per-widget save/restore store for the attributes this manager themes.
	-- Keyed by a stable per-widget string id (see _widgetKey) -> { ATTR =
	-- original_value_or_UNSET }. Held Lua-side rather than as native attributes:
	-- one native read captures the original, where native storage would cost
	-- ~5-6 extra round-trips per themed attribute on every theme switch.
	self._orig = {}
	self._key_seq = 0

	-- LuaJIT FFI + native batch theme fast paths (ON by default). These avoid the
	-- iuplua wrapper on per-attribute reads/writes:
	--   * themeapply (C): captures originals + applies a whole attribute table for
	--     one widget in a single Lua->C crossing, and restores them the same way.
	--   * IupFFI: direct ffi.C.Iup* calls (via a raw Ihandle*) for the scattered
	--     per-node metadata reads/writes (THEMEROLE, the widget-id stamp, NTHEME).
	-- _probeNative validates the native path against a throwaway widget so a binding
	-- mismatch degrades to the pure-Lua iup.* path instead of crashing the walk.
	-- NOTE: benchmarking showed a theme switch is largely bottlenecked on IUP's
	-- internal relayout/repaint per attribute write on heavyweight container widgets
	-- (flattabs/split/dialog/scrollboxes), so the crossing-cost savings have limited
	-- effect on the dark switch; the high-count cheap widgets (labels/buttons) still
	-- benefit. Set env LUNAR_THEME_NO_FFI=1 to force the pure-Lua path (A/B / kill-switch).
	if os.getenv("LUNAR_THEME_NO_FFI") == "1" then
		self._themeapply = nil
		self._ffi = nil
		self._native_error = "turned off by LUNAR_THEME_NO_FFI"
	else
		local ok_ta, themeapply = pcall(require, "themeapply")
		self._themeapply = (ok_ta and themeapply) or nil
		local ok_ff, iupffi = pcall(require, "core.classes.IupFFI")
		self._ffi = (ok_ff and iupffi and iupffi.available and iupffi) or nil
		self:_probeNative()
	end
end

-- Validate the native fast paths against a disposable widget. If iuplua_checkihandle
-- (themeapply) or the FFI pointer/get/set round-trip fails -- e.g. the prebuilt IUP
-- Lua 5.1 binding does not interoperate with our handles, or the IUP symbols are not
-- FFI-resolvable -- disable that path so theming falls back to iup.*. The reason
-- is kept for `fastPaths` (the startup log and Window Diagnostics report it).
function ThemeManager:_probeNative()
	local iup = self._iup
	local ok, err = pcall(function()
		local u = iup.user({})
		if self._themeapply then
			local orig = self._themeapply.apply_save(u, { BGCOLOR = "1 2 3" })
			assert(type(orig) == "table", "apply_save did not return a table")
			self._themeapply.restore(u, orig)
		end
		if self._ffi then
			local p = self._ffi.ptr(u)
			assert(p ~= nil, "iupraw.ptr returned nil")
			self._ffi.setstr(p, "THEMEMGR_PROBE", "ok")
			assert(self._ffi.get(p, "THEMEMGR_PROBE") == "ok", "FFI get/set mismatch")
		end
		iup.Destroy(u)
	end)
	if not ok then
		self._themeapply = nil
		self._ffi = nil
		self._native_error = "probe failed: " .. tostring(err):match("^[^\n]*")
	end
	return ok
end

--- Which theme fast paths are in use (see `_probeNative`).
-- @treturn table `{ themeapply = bool, ffi = bool, error = string|nil }`
function ThemeManager:fastPaths()
	return { themeapply = self._themeapply ~= nil, ffi = self._ffi ~= nil, error = self._native_error }
end

--- Add a theme supplied at runtime (an extension, via `ctx:registerTheme`).
-- Appended to the Theme menu and the Settings dropdown. Themes are applied after
-- extensions load, so a saved choice of an extension's theme still resolves.
-- @param theme_class A subclass of `core.classes.Themes.Theme`.
-- @treturn[1] string The theme id.
-- @treturn[2] nil
-- @treturn[2] string Why it was refused.
function ThemeManager:registerTheme(theme_class)
	if not isThemeSubclass(theme_class) then return nil, "not a Theme subclass" end
	local ok, t = pcall(theme_class.new, theme_class)
	if not ok then return nil, "theme failed to construct: " .. tostring(t) end
	local id = t:id()
	if type(id) ~= "string" or id == "" then return nil, "theme has no id" end
	if self._theme_by_id[id] then return nil, "a theme with id '" .. id .. "' already exists" end
	self._themes[#self._themes + 1] = t
	self._theme_by_id[id] = t

	local iup = self._iup
	if self._menu then
		local item = self:_menuItem(t)
		iup.Append(self._menu, item)
		pcall(iup.Map, item)
	end
	self:_fillDropdown()
	self:_syncControls()

	-- Extension reload: startup already applied a theme, and this is the one the
	-- user saved (it was removed when the extension unloaded). Bring it back.
	local saved = self._settings and self._settings:get("theme")
	if self._applied ~= nil and saved == id and self._current ~= id then
		self:apply(id, { skip_save = true })
	end
	return id
end

--- Remove a runtime theme (its extension unloaded). If it is the active theme the
-- app falls back to the default for this session; the user's saved choice is
-- kept, so it returns when the extension does.
-- @tparam string id
function ThemeManager:unregisterTheme(id)
	local idx
	for i, t in ipairs(self._themes) do
		if t:id() == id then idx = i break end
	end
	if not idx then return end
	table.remove(self._themes, idx)
	self._theme_by_id[id] = nil
	-- Native attribute bundles are cached per theme id; a reloaded extension may
	-- bring back a changed theme under the same id.
	if self._native_handles then self._native_handles[id] = nil end
	if self._native_role_handles then self._native_role_handles[id] = nil end
	if self._element_handles then self._element_handles[id] = nil end
	local item = self._menu_items[id]
	if item then
		pcall(self._iup.Detach, item)
		pcall(self._iup.Destroy, item)
		self._menu_items[id] = nil
	end
	self:_fillDropdown()
	if self._current == id then
		self:apply("classic_dark", { skip_save = true })
	end
	self:_syncControls()
end

--- The registered theme with this id, or nil.
-- @tparam string id
-- @treturn table|nil
function ThemeManager:themeById(id)
	return self._theme_by_id[id]
end

--- Route the user's theme picks (the Settings selector and the Theme menu)
-- through `fn(id)` instead of applying them directly. "Match system theme"
-- (`core.lib.SystemTheme`) uses this to remember a pick per light/dark mode.
-- @tparam function|nil fn
function ThemeManager:setChooser(fn)
	self._chooser = fn
end

-- A theme the user picked.
function ThemeManager:_choose(id)
	if self._chooser then return self._chooser(id) end
	return self:apply(id)
end

function ThemeManager:themes()
	local out = {}
	for _, t in ipairs(self._themes) do
		out[#out + 1] = { id = t:id(), label = t:label() }
	end
	return out
end

function ThemeManager:current()
	return self._current
end

-- Return the active Theme object (not just its id), so callers can read its palette --
-- e.g. the gradient overlay reads the paint-time gradient tokens. Never nil after the
-- first apply(); seeded to the classic theme at construction.
function ThemeManager:activeTheme()
	return self._active
end

-- Register a callback invoked once at the END of every apply(), after the widget walk
-- and global-font update. Intended for paint-time visuals (e.g. the gradient overlay)
-- that must react to theme changes WITHOUT participating in the per-widget attribute
-- walk. The callback receives the active Theme object.
function ThemeManager:onApply(fn)
	if type(fn) ~= "function" then return end
	self._on_apply = self._on_apply or {}
	self._on_apply[#self._on_apply + 1] = fn
	-- If a theme is already applied, fire immediately so late subscribers sync up.
	if self._applied then
		pcall(fn, self._active)
	end
end

function ThemeManager:_fireOnApply()
	if not self._on_apply then return end
	for _, fn in ipairs(self._on_apply) do
		pcall(fn, self._active)
	end
end

function ThemeManager:setRoot(dlg)
	self._root = dlg
end
--- Bind the shared `core.classes.MotionDirector`, so motion follows the theme.
--
-- A theme is a design language, and movement is half of one. Binding the director
-- here means a theme's `motion()` overrides are installed by the same call that
-- paints its colors -- there is no window in which the app looks like one theme
-- and moves like another, and no wiring in `main.lua` to keep in step.
--
-- Optional: without a director, `motion()` is simply never consulted.
--
-- @tparam MotionDirector director the shared director
-- @usage theme_mgr:setMotionDirector(motion_director)
function ThemeManager:setMotionDirector(director)
	self._motion = director
	if self._active then self:_applyMotion(self._active) end
end

-- Push a theme's per-role motion overrides at the director. Wrapped in pcall for
-- the same reason `rules()` consumers are: `motion()` is theme-supplied code, and
-- a theme with a broken override should lose its custom motion, not prevent the
-- user from switching to it.
function ThemeManager:_applyMotion(theme)
	local director = self._motion
	if not director then return end
	local ok, roles = pcall(function() return theme:motion() end)
	director:setRoles(ok and roles or nil)
end

function ThemeManager:setDropdown(list)
	self._dropdown = list
end

function ThemeManager:_detectNativeThemeSupport()
	local iup = self._iup
	local ok = pcall(function()
		local u = iup.user({})
		if u then
			iup.Destroy(u)
		end
	end)
	return ok
end

function ThemeManager:_attrsFromRule(cls, r)
	local attrs = {}
	if not r then
		return attrs
	end
	local has_scroll = (
		cls == "flatlist"
		or cls == "flatscrollbox"
		or cls == "scrollbox"
		or cls == "list"
		or cls == "text"
		or cls == "multiline"
	)

	if r.bg then
		attrs.BGCOLOR = r.bg
	end
	if r.fg then
		attrs.FGCOLOR = r.fg
	end
	if r.font then
		attrs.FONT = r.font
	end
	if cls == "gauge" and r.bg then
		attrs.BACKCOLOR = r.bg
	end
	if cls == "gauge" and r.border then
		attrs.FLAT = "YES"
		attrs.FLATCOLOR = r.border
	end

	if r.fg and cls == "flatframe" then
		attrs.TITLECOLOR = r.fg
	end

	if r.border then
		attrs.BORDERCOLOR = r.border
		if r.borderwidth then
			attrs.BORDERWIDTH = tostring(r.borderwidth)
		end

		if cls == "flatframe" or cls == "flatlist" or cls == "flattabs" or cls == "flatscrollbox" then
			attrs.FRAMECOLOR = r.border
		end

		if cls == "flatframe" then
			attrs.TITLELINECOLOR = r.border
		end

		if cls == "tabs" or cls == "flattabs" then
			attrs.TABBORDERCOLOR = r.border
			if r.fg then
				attrs.TABFGCOLOR = r.fg
			end
			if r.bg then
				attrs.TABBGCOLOR = r.bg
			end
		end

		if cls == "flattabs" then
			attrs.TABSLINECOLOR = r.border
			if r.fg then
				attrs.FORECOLOR = r.fg
				-- Unselected tab labels. Falls back to the selected colour, so a
				-- rule that does not care reads exactly as it did before.
				attrs.TABSFORECOLOR = r.tabsfg or r.fg
			end
			-- BGCOLOR (set from r.bg above) is the SELECTED tab and the page
			-- behind it; TABSBACKCOLOR is the strip the unselected tabs sit on.
			-- Driving both from r.bg made them the same colour, which is why a
			-- selected tab was indistinguishable from its neighbours.
			--
			-- Carbon's contained tabs put the selected tab on $layer-01 and the
			-- strip on $background, so the selected one reads as the surface the
			-- content below belongs to. `tabsbg` is optional and falls back to
			-- r.bg, so a rule that does not opt in is unchanged.
			if r.tabsbg or r.bg then
				attrs.TABSBACKCOLOR = r.tabsbg or r.bg
			end

			-- Trailing "extra" buttons (the host's "+ new tab group"; see
			-- core.classes.TabGroups). These are owner-drawn by IupFlatTabs, not
			-- native -- but when the per-button colors are unset it falls back to
			-- IUP_FLAT_HIGHCOLOR / IUP_FLAT_PRESSCOLOR, which are its own blue
			-- defaults and ignore the theme entirely. That is the blue flash on
			-- hover. Supplying them here themes every strip, including group
			-- sub-strips created later (TabGroups notifies the theme manager for
			-- each new one).
			--
			-- Written for all three ids IupFlatTabs supports rather than just the
			-- one the host uses, so an extension that adds its own extra buttons
			-- is themed too. Unused ids cost nothing.
			--
			-- Guarded by spec/theme_flattabs_spec.lua, which is what caught this
			-- block going missing once already.
			local hi    = r.hover or r.selbg or r.bg
			local press = r.selbg or r.hover or r.border
			for i = 1, 3 do
				if r.fg then attrs["EXTRAFORECOLOR" .. i] = r.fg end
				if hi then attrs["EXTRAHIGHCOLOR" .. i] = hi end
				if press then attrs["EXTRAPRESSCOLOR" .. i] = press end
				if r.border then attrs["EXTRABORDERCOLOR" .. i] = r.border end
			end
		end
	end

	if has_scroll then
		local sb_bg = r.scrollbg or r.bg
		local sb_fg = r.scrollfg or r.border
		if sb_bg then
			attrs.SB_BGCOLOR = sb_bg
			attrs.SB_BACKCOLOR = sb_bg
		end
		if sb_fg then
			attrs.SB_FORECOLOR = sb_fg
			-- Hover/pressed thumb colors: use the gradient-family tones when the rule
			-- provides them (Fluent/One Dark Pro), else fall back to the flat thumb color.
			attrs.SB_HIGHCOLOR = r.scrollhi or sb_fg
			attrs.SB_PRESSCOLOR = r.scrollpress or sb_fg
		end
		if r.fg then
			attrs.ARROWCOLOR = r.fg
		end
	end

	if cls == "flatlist" then
		local sel_bg = r.selbg or r.hover or r.bg
		local sel_text = r.seltext or r.hovertext or r.fg
		if sel_bg then
			attrs.HLCOLOR = sel_bg
			attrs.PSCOLOR = sel_bg
		end
		if sel_text then
			attrs.TEXTHLCOLOR = sel_text
			attrs.TEXTPSCOLOR = sel_text
		end
		attrs.HLCOLORALPHA = r.selalpha or ((r.selbg or r.hover) and "255" or "0")
	end

	if r.border and (cls == "flatseparator" or cls == "separator") then
		attrs.COLOR = r.border
	end

	if r.border and (cls == "flatbutton" or cls == "flattoggle" or cls == "dropbutton") then
		attrs.BORDERHLCOLOR = r.border
		attrs.BORDERPSCOLOR = r.border
	end

	if r.showborder then
		attrs.SHOWBORDER = "YES"
	end

	if r.hover then
		attrs.HLCOLOR = r.hover
		attrs.PSCOLOR = r.hover
	end

	if r.hovertext then
		attrs.TEXTHLCOLOR = r.hovertext
		attrs.TEXTPSCOLOR = r.hovertext
	end

	if r.forceflat then
		attrs.FLAT = "YES"
	end

	-- Carbon sizes its controls rather than letting them shrink-wrap their text:
	-- a button is a 40 or 48px target, not "however tall this label happens to
	-- be". IUP has no height attribute that survives a theme switch cleanly, but
	-- PADDING gets there -- a flat control's height is its text plus twice the
	-- vertical padding -- and unlike RASTERSIZE it does not pin the width, so a
	-- long label still grows the button instead of being clipped.
	if r.padding then
		attrs.PADDING = r.padding
	end

	-- Native gradient fill and rounded corners (IUP fork additions). These three
	-- attributes are registered ONLY on the five fork-patched flat controls:
	-- flatbutton, flatframe, flatlabel, flattoggle, dropbutton.  Any other class
	-- would silently ignore them; the guard avoids the SetAttribute round-trip on
	-- controls that will never honour them, and keeps Carbon themes unaffected --
	-- carbon_rules never sets r.gradcolor or r.radius, so the block is entered
	-- but emits nothing for those themes.
	if cls == "flatbutton" or cls == "flatframe" or cls == "flatlabel"
			or cls == "flattoggle" or cls == "dropbutton" then
		if r.gradcolor then
			attrs.GRADIENTCOLOR     = r.gradcolor
			-- r.graddir defaults to VERTICAL when unset (the IUP fork's own
			-- default), but we write it explicitly so the attribute table is
			-- self-contained and a future NTHEME snapshot captures the intent.
			attrs.GRADIENTDIRECTION = r.graddir or "VERTICAL"
		end
		if r.radius then
			attrs.CORNERRADIUS = tostring(r.radius)
		end
	end
	return attrs
end

function ThemeManager:_newNativeUser(attrs)
	local iup = self._iup
	local user = iup.user({})
	for k, v in pairs(attrs or {}) do
		if v ~= nil then
			iup.SetAttribute(user, k, tostring(v))
		end
	end
	return user
end

function ThemeManager:_themeHandleName(theme)
	return ("LUNAR_THEME_%s"):format((theme:id() or "default"):upper():gsub("[^%w]", "_"))
end

function ThemeManager:_ensureNativeThemeHandle(theme)
	local id = theme:id()
	local cached = self._native_handles[id]
	if cached then
		return cached
	end

	local iup = self._iup
	local rules = theme:rules() or {}
	local root_name = self:_themeHandleName(theme)
	local root_user = self:_newNativeUser({})
	iup.SetHandle(root_name, root_user)

	for cls, r in pairs(rules) do
		if CLASS_RULES[cls] then
			local attrs = self:_attrsFromRule(cls, r)
			if next(attrs) then
				local sub_name = ("%s_%s"):format(root_name, cls:upper())
				local sub_user = self:_newNativeUser(attrs)
				iup.SetHandle(sub_name, sub_user)
				iup.SetAttribute(root_user, "IUP" .. cls:upper(), sub_name)
			end
		end
	end

	self._native_handles[id] = root_name
	return root_name
end

function ThemeManager:_ensureNativeRoleHandle(theme, role, cls)
	local rules = theme:rules() or {}
	local role_rule = rules[role]
	if not role_rule then
		return nil
	end

	local t_id = theme:id()
	self._native_role_handles[t_id] = self._native_role_handles[t_id] or {}
	self._native_role_handles[t_id][role] = self._native_role_handles[t_id][role] or {}

	local cached = self._native_role_handles[t_id][role][cls]
	if cached then
		return cached
	end

	local attrs = self:_attrsFromRule(cls, role_rule)
	if not next(attrs) then
		return nil
	end

	local iup = self._iup
	local role_key = role:upper():gsub("[^%w]", "_")
	local cls_key = cls:upper():gsub("[^%w]", "_")
	local name = ("%s_ROLE_%s_%s"):format(self:_themeHandleName(theme), role_key, cls_key)
	local user = self:_newNativeUser(attrs)
	iup.SetHandle(name, user)
	self._native_role_handles[t_id][role][cls] = name
	return name
end

function ThemeManager:_clearManagedRoleTheme(ih, p)
	local ffi = p and self._ffi
	if ffi then
		if ffi.get(p, "THEMEMGR_NTHEME") ~= "1" then
			return
		end
		ffi.clear(p, "NTHEME")
		ffi.clear(p, "THEMEMGR_NTHEME")
		return
	end
	local iup = self._iup
	if iup.GetAttribute(ih, "THEMEMGR_NTHEME") ~= "1" then
		return
	end
	iup.SetAttribute(ih, "NTHEME", nil)
	iup.SetAttribute(ih, "THEMEMGR_NTHEME", nil)
end

function ThemeManager:_applyNativeRoleTheme(ih, theme, cls, role)
	local iup = self._iup
	if not role or role == "" then
		self:_clearManagedRoleTheme(ih)
		return
	end

	if not cls or cls == "" then
		self:_clearManagedRoleTheme(ih)
		return
	end
	local lcls = cls:lower()

	local role_handle = self:_ensureNativeRoleHandle(theme, role, lcls)
	if not role_handle then
		self:_clearManagedRoleTheme(ih)
		return
	end

	iup.SetAttribute(ih, "NTHEME", role_handle)
	iup.SetAttribute(ih, "THEMEMGR_NTHEME", "1")
end

-- Returns (handle_name, attrs) for the bundle of attributes that should be applied
-- to a widget of class `cls` (optionally specialized by THEMEROLE `role`) under
-- `theme`. The IupUser handle is built once per (theme, cls, role) and cached, so a
-- whole theme switch reuses a handful of handles. `attrs` is returned so the caller
-- can capture each original via _save before NTHEME overwrites it (needed so a later
-- switch back to Classic can restore the true pre-theme values).
function ThemeManager:_ensureElementHandle(theme, cls, role)
	if not cls then
		return nil
	end
	local rules = theme:rules() or {}
	local r = (role and role ~= "" and rules[role]) or rules[cls]
	if not r then
		return nil
	end

	local t_id = theme:id()
	local cache = self._element_handles[t_id]
	if not cache then
		cache = {}
		self._element_handles[t_id] = cache
	end

	local key = cls .. "|" .. (role or "")
	local entry = cache[key]
	if entry then
		return entry.name, entry.attrs
	end

	local attrs = self:_attrsFromRule(cls, r)
	if not next(attrs) then
		cache[key] = { name = false, attrs = attrs }
		return nil, attrs
	end

	local iup = self._iup
	local cls_key = cls:upper():gsub("[^%w]", "_")
	local role_key = (role or ""):upper():gsub("[^%w]", "_")
	local name = ("%s_EL_%s_%s"):format(self:_themeHandleName(theme), cls_key, role_key)
	local user = self:_newNativeUser(attrs)
	iup.SetHandle(name, user)
	cache[key] = { name = name, attrs = attrs }
	return name, attrs
end

-- Native fast-path applier: theme a single widget with ONE NTHEME write instead of
-- the ~10-25 individual SetAttribute writes _applyElement issues. Originals are
-- still captured (cheap reads) so dark->classic restore stays correct.
function ThemeManager:_applyElementNative(ih, theme, cls, role)
	local handle, attrs = self:_ensureElementHandle(theme, cls, role)
	if not handle then
		self:_clearManagedRoleTheme(ih)
		return
	end
	for attr in pairs(attrs) do
		self:_save(ih, attr)
	end
	local iup = self._iup
	iup.SetAttribute(ih, "NTHEME", handle)
	iup.SetAttribute(ih, "THEMEMGR_NTHEME", "1")
end

function ThemeManager:_beginPaintBatch(root)
	local wr = self._winredraw
	if wr and root then
		pcall(wr.lock, root)
	end
end

function ThemeManager:_endPaintBatch(root)
	local wr = self._winredraw
	if wr and root then
		pcall(wr.unlock, root)
	end
end

-- Stable per-widget key for the Lua-side originals store. IUP's Lua binding can
-- return a *different* Lua wrapper object for the same native widget across tree
-- walks, so the Lua handle itself is not a reliable table key (using it caused
-- restore to miss on theme switch-back). Stamp each widget once with a small
-- string id held as a native attribute and key the store by that id instead.
function ThemeManager:_widgetKey(ih, p)
	local ffi = p and self._ffi
	local id
	if ffi then
		id = ffi.get(p, "THEMEMGR_ID")
	else
		id = self._iup.GetAttribute(ih, "THEMEMGR_ID")
	end
	if id and id ~= "" then
		return id
	end
	self._key_seq = (self._key_seq or 0) + 1
	id = tostring(self._key_seq)
	if ffi then
		ffi.setstr(p, "THEMEMGR_ID", id)
	else
		self._iup.SetAttribute(ih, "THEMEMGR_ID", id)
	end
	return id
end

function ThemeManager:_store(ih, p)
	local key = self:_widgetKey(ih, p)
	local store = self._orig[key]
	if not store then
		store = {}
		self._orig[key] = store
	end
	return store
end

function ThemeManager:_save(ih, attr, p)
	local store = self:_store(ih, p)
	-- Capture the pre-theme original exactly once; later re-applies of other
	-- themes must not overwrite the true original with an intermediate themed value.
	if store[attr] ~= nil then
		return
	end
	local cur
	if p and self._ffi then
		cur = self._ffi.get(p, attr)
	else
		cur = self._iup.GetAttribute(ih, attr)
	end
	store[attr] = (cur == nil) and UNSET or cur
end

-- Merge originals captured natively by themeapply.apply_save into the per-widget
-- store. apply_save returns { ATTR = original_string_or_false } where false means
-- the attribute was unset; that matches the store's UNSET sentinel exactly. The
-- capture-once guard mirrors _save so a switch-back restores the true pre-theme
-- value rather than an intermediate themed one.
function ThemeManager:_mergeOriginals(ih, originals, p)
	local store = self:_store(ih, p)
	for attr, v in pairs(originals) do
		if store[attr] == nil then
			store[attr] = v
		end
	end
end

function ThemeManager:_restore(ih, attr)
	local store = self._orig[self:_widgetKey(ih)]
	if not store then
		return
	end
	local v = store[attr]
	if v == nil then
		return
	end
	if v == UNSET then
		v = nil
	end
	self._iup.SetAttribute(ih, attr, v)
end

-- Theme a single widget. The attribute bundle for (cls, role) is identical to the
-- one _attrsFromRule builds, so we reuse it and apply the whole table in one shot:
--   * fast path: themeapply.apply_save captures every original and applies the new
--     values in a single Lua->C crossing (vs. the ~10-25 paired GetAttribute/
--     SetAttribute round-trips this used to issue per node).
--   * fallback: the original per-attribute save+set, used when the native batch
--     helper is unavailable.
-- Per-widget FONT writes are the largest single cost of a dark switch: every
-- IupSetStrAttribute("FONT", ...) triggers IUP's synchronous natural-size
-- re-measure of the widget. Widgets with no locally-set FONT already inherit
-- DEFAULTFONT, which _applyGlobalFont sets to the theme font after the walk.
-- For those widgets we can skip the explicit per-widget FONT write entirely --
-- the final IupRefresh re-measures everything in one pass once DEFAULTFONT is
-- updated, exactly like CSS `font` inheritance from the root element.
-- Widgets created with an explicit FONT (Bold headers, sized text) do need the
-- override, so they fall through to normal theming. LUNAR_THEME_NO_FONT_INHERIT=1
-- disables this path for A/B diagnosis. Defined here (before _applyElement, its
-- first user) so the closure actually captures it as an upvalue.
local FONT_INHERIT = (os.getenv("LUNAR_THEME_NO_FONT_INHERIT") ~= "1")

function ThemeManager:_applyElement(ih, rules, cls, role, p)
	if not cls then
		return
	end

	-- A THEMEROLE attribute lets a specific widget opt into a dedicated palette
	-- entry (e.g. "actionbutton") instead of the generic per-class rule. This
	-- keeps action buttons themable (green outline, green-fill hover) without
	-- affecting other widgets of the same IUP class such as CheckList rows.
	-- cls and role are resolved once by _walk and passed in to avoid re-fetching.
	local r = (role and rules[role]) or rules[cls]
	if not r then
		return
	end
	local attrs = self:_attrsFromRule(cls, r)
	if not next(attrs) then
		return
	end

	-- FONT-inherit optimisation: widgets with no locally-set FONT inherit DEFAULTFONT,
	-- which _applyGlobalFont already sets to the theme font. Removing FONT from the
	-- attrs batch avoids a per-widget IupSetStrAttribute that IUP would turn into a
	-- synchronous natural-size re-measure -- the dominant cost of a dark switch.
	-- Widgets with an explicit local FONT (bold headers etc.) keep FONT in the batch
	-- so the theme can override their value. _hasLocalFont is cached on first visit.
	-- The LABEL_INHERIT path already handles plain labels (entire node skipped); this
	-- path handles every other widget class that inherits its font from DEFAULTFONT.
	if FONT_INHERIT and attrs.FONT then
		-- Skipping is only sound when the rule's font is the one DEFAULTFONT is
		-- about to be set to. A rule naming a DIFFERENT font -- every entry in
		-- the Carbon type scale, where a heading is deliberately larger or
		-- heavier than the body font -- cannot be delivered by inheritance, so
		-- it must be written even though the widget has no local FONT.
		--
		-- Without this test the optimisation silently swallowed the whole type
		-- scale: `pagetitle`, `sectiontitle` and friends are applied to
		-- flatlabels created with a THEMEROLE and no FONT (see
		-- core.lib.CarbonLayout.pageTitle), so every heading in the app rendered
		-- at body size and weight and the scale existed only on paper.
		if attrs.FONT == self._theme_font and not self:_hasLocalFont(ih, p) then
			attrs.FONT = nil
		end
	end

	if self._themeapply then
		local originals = self._themeapply.apply_save(ih, attrs)
		self:_mergeOriginals(ih, originals, p)
	else
		local iup = self._iup
		for attr, val in pairs(attrs) do
			self:_save(ih, attr, p)
			iup.SetAttribute(ih, attr, val)
		end
	end
end

function ThemeManager:_restoreElement(ih, p)
	-- Restore exactly the attributes this manager previously themed on this widget
	-- (recorded by _save / _mergeOriginals). Avoids probing a large fixed attribute
	-- list per node and is complete because every themed SetAttribute is paired with
	-- a captured original. themeapply.restore re-applies the whole store in one
	-- Lua->C crossing (string -> set, UNSET/false -> clear).
	local store = self._orig[self:_widgetKey(ih, p)]
	if store and next(store) then
		if self._themeapply then
			self._themeapply.restore(ih, store)
		else
			local iup = self._iup
			for attr, v in pairs(store) do
				if v == UNSET then
					v = nil
				end
				iup.SetAttribute(ih, attr, v)
			end
		end
	end
	-- Drop any NTHEME bundle this manager applied so the restored originals are the
	-- element's effective values again (a stale NTHEME name left on the widget is
	-- inert, but clearing keeps switch-back state clean and symmetric).
	self:_clearManagedRoleTheme(ih, p)
end

-- Classify a label (once) as "generic" -- one with no locally-set FONT, i.e. it
-- purely inherits its font from the dialog -- vs "explicit" (created with its own
-- FONT). Only generic labels are eligible for inherit-theming. The signal is
-- IupGetAllAttributes, which lists exactly the attributes set ON the element (not
-- inherited ones), so it is robust regardless of which theme/global font was active
-- when the label was created -- unlike comparing font strings, which fails for
-- labels created lazily after the global font already changed. Cached on the widget
-- so it costs one attribute scan per label for the lifetime of the process.
function ThemeManager:_isGenericLabel(ih)
	local iup = self._iup
	local cached = iup.GetAttribute(ih, "THEMEMGR_LBLKIND")
	if cached == "gen" then
		return true
	elseif cached == "exp" then
		return false
	end
	local generic = true
	local ok, names = pcall(iup.GetAllAttributes, ih)
	if ok and type(names) == "table" then
		for _, nm in ipairs(names) do
			-- A local FONT or FGCOLOR means the widget styles itself and must be
			-- themed explicitly (e.g. a Bold/sized header) rather than inheriting.
			if nm == "FONT" or nm == "FGCOLOR" then
				generic = false
				break
			end
		end
	else
		generic = false
	end
	iup.SetAttribute(ih, "THEMEMGR_LBLKIND", generic and "gen" or "exp")
	return generic
end

-- Returns false if this widget has a locally-set FONT (set at creation time or by
-- a previous apply), meaning the theme must override it explicitly. Returns true if
-- FONT is absent from the widget's locally-set attribute list, meaning it inherits
-- DEFAULTFONT from the parent chain and does not need a per-widget FONT write to
-- render the theme font -- _applyGlobalFont + a final Refresh handles that for free.
--
-- The result is cached on the widget (THEMEMGR_HASFONT) after the first call,
-- because a widget's "was created with an explicit FONT" state persists across
-- theme cycles: apply_save only writes FONT on explicit-font widgets (handled via
-- the normal path), and restore clears it back to UNSET on inheritance widgets, so
-- the widget returns to its creation state after each restore. The cache therefore
-- stays valid for the lifetime of the process.
function ThemeManager:_hasLocalFont(ih, p)
	local cached
	if p and self._ffi then
		cached = self._ffi.get(p, "THEMEMGR_HASFONT")
	else
		cached = self._iup.GetAttribute(ih, "THEMEMGR_HASFONT")
	end
	if cached then
		return cached == "1"
	end
	-- IupGetAllAttributes returns the set of attributes that are set DIRECTLY on
	-- this element (not attributes propagated via inheritance from ancestors). FONT
	-- appearing here means the widget was created with an explicit font; absent
	-- means it relies on DEFAULTFONT and is eligible for the FONT-skip path.
	local has = false
	local ok, names = pcall(self._iup.GetAllAttributes, ih)
	if ok and type(names) == "table" then
		for _, nm in ipairs(names) do
			if nm == "FONT" then
				has = true
				break
			end
		end
	else
		has = true  -- fail-safe: treat as explicit so the FONT write always fires
	end
	local v = has and "1" or "0"
	if p and self._ffi then
		self._ffi.setstr(p, "THEMEMGR_HASFONT", v)
	else
		self._iup.SetAttribute(ih, "THEMEMGR_HASFONT", v)
	end
	return has
end

function ThemeManager:_walk(ih, fn)
	local iup = self._iup
	-- Resolve the class name once here and hand it to the visitor; both the color
	-- pass and the native-role pass need it, so this avoids 2-3 GetClassName calls
	-- per node across a ~500-node tree.
	local ok_cls, cls = pcall(iup.GetClassName, ih)
	cls = (ok_cls and cls) or nil
	fn(ih, cls)
	local i = 0
	while true do
		local ok, child = pcall(iup.GetChild, ih, i)
		if not ok or not child then
			break
		end
		self:_walk(child, fn)
		i = i + 1
	end
	-- IupDropButton hosts its drop child inside a separate, decoration-less dialog
	-- that GetChild cannot reach. Follow it so the dropdown popup is themed too.
	if cls == "dropbutton" then
		local okc, dropchild = pcall(iup.GetAttributeHandle, ih, "DROPCHILD_HANDLE")
		-- Some Lua bindings expose only DROPCHILD (handle name) when a drop child is
		-- attached via SetHandle + SetAttribute("DROPCHILD", ...). Resolve that form
		-- too so popup lists and their scrollbars get themed consistently.
		if (not okc or not dropchild) and iup.GetHandle then
			local okn, dropname = pcall(iup.GetAttribute, ih, "DROPCHILD")
			if okn and dropname and dropname ~= "" then
				local okh, named = pcall(iup.GetHandle, dropname)
				if okh and named then
					dropchild = named
				end
			end
		end
		if dropchild then
			-- Theme the drop child (the flatlist) directly rather than its enclosing
			-- popup dialog. The popup dialog is decoration-less and draws nothing --
			-- the visible content is the flatlist, whose own FLATSCROLLBAR draws its
			-- scrollbar in the list's colors. Crucially, resolving the popup *dialog*
			-- (IupGetDialog) on a not-yet-shown dropdown forces that hidden dialog to
			-- map/lay out, which profiling showed dominated dropbutton cost (~20ms
			-- each). Walking just the list themes the same visible widgets without
			-- forcing the invisible popup to lay out during the switch.
			self:_walk(dropchild, fn)
		end
	end
end

-- Optional phase timing. Set env LUNAR_THEME_PROFILE=1 to append per-phase millis
-- of each apply() to %TEMP%\lunar_theme_profile.log. Used to find the dominant cost
-- of a theme switch; a no-op (zero overhead beyond an env check) when unset.
local PROFILE = (os.getenv("LUNAR_THEME_PROFILE") == "1")

-- JS/CSS-parity label theming. Generic labels (no THEMEROLE and no explicit
-- per-widget font) only need an inheritable fg + font, which the themed dialog
-- already provides. Instead of issuing a per-label NTHEME write -- whose FONT
-- application forces a synchronous natural-size re-measure of the label (the
-- dominant residual cost of a switch: ~109ms across ~54 labels) -- we clear the
-- label's local FONT/FGCOLOR so it simply inherits from the dialog, exactly like
-- a CSS leaf inheriting `color`/`font` from an ancestor. The dialog recolors once
-- and every generic label follows for free, with zero per-label relayout.
--
-- This is intentionally limited to labels whose own font equals the app default:
-- labels created with an explicit font (e.g. "Segoe UI, Bold 10" section headers)
-- still need the theme to override them to its own font, so they keep the normal
-- per-widget themed path. Set env LUNAR_THEME_NO_INHERIT=1 to disable this and fall
-- back to per-widget label theming (A/B verification / safety kill-switch).
local LABEL_INHERIT = (os.getenv("LUNAR_THEME_NO_INHERIT") ~= "1")

-- JS/CSS-parity FONT inheritance: FONT_INHERIT is defined above (before
-- _applyElement, its first user) so its closure captures it correctly.

local function proflog(line)
	if not PROFILE then
		return
	end
	local platform = require("core.platform")
	local f = io.open(platform.path:join(platform.temp_dir(), "lunar_theme_profile.log"), "a")
	if f then
		f:write(line .. "\n")
		f:close()
	end
end

function ThemeManager:_applyGlobalFont(theme)
	local iup = self._iup
	local default_font = self._orig_default_font
	local dlg_font = self._orig_dlg_font
	if theme and not theme:isClassic() then
		local palette = theme:palette()
		if palette and palette.font and palette.font ~= "" then
			default_font = palette.font
			dlg_font = palette.font
		end
	end
	pcall(iup.SetGlobal, "DEFAULTFONT", default_font or "")
	pcall(iup.SetGlobal, "DLGFONT", dlg_font or "")
end

function ThemeManager:_applyGlobalTooltip(theme)
	local iup = self._iup
	local tip_bg = self._orig_tip_bg
	local tip_fg = self._orig_tip_fg
	local tip_font = self._orig_tip_font
	local tip_border = self._orig_tip_border
	if theme then
		local palette = theme:palette()
		if palette then
			tip_bg = palette.surface or palette.bg or tip_bg
			tip_fg = palette.text or tip_fg
			tip_font = palette.font or tip_font
			tip_border = palette.borderStrong or palette.border or tip_border
		end
	end
	pcall(iup.SetGlobal, "TIPBGCOLOR", tip_bg or "")
	pcall(iup.SetGlobal, "TIPFGCOLOR", tip_fg or "")
	pcall(iup.SetGlobal, "TIPFONT", tip_font or "")
	-- Not all IUP builds expose TIPBORDERCOLOR; set best-effort.
	pcall(iup.SetGlobal, "TIPBORDERCOLOR", tip_border or "")

	-- Some controls keep using their previously-resolved local TIP* values even after
	-- globals change; stamp tooltip attrs per-widget as well so theme switches update
	-- visible tooltip colors/font immediately.
	if self._root then
		self:_walk(self._root, function(ih)
			pcall(iup.SetAttribute, ih, "TIPBGCOLOR", tip_bg or "")
			pcall(iup.SetAttribute, ih, "TIPFGCOLOR", tip_fg or "")
			pcall(iup.SetAttribute, ih, "TIPFONT", tip_font or "")
			pcall(iup.SetAttribute, ih, "TIPBORDERCOLOR", tip_border or "")
		end)
	end
end

-- Single batched re-theme of an entire subtree under `root`. Merges what used to
-- be two full-tree walks (color attributes + native role themes) into ONE walk so
-- a theme switch touches each node once, and wraps the whole thing in a single
-- paint batch so the dialog repaints once instead of rippling widget-by-widget.
function ThemeManager:_repaintSubtree(root, theme)
	if not root then
		return
	end
	local iup = self._iup
	local rules = theme:rules() or {}

	-- The font DEFAULTFONT is about to carry, so `_applyElement` can tell a rule
	-- that merely restates the body font (skippable -- it will be inherited) from
	-- one that names a different size or weight (which must be written).
	local palette = theme.palette and theme:palette() or nil
	self._theme_font = (palette and palette.font ~= "" and palette.font) or nil

	-- Per-class timing/counters (only populated when profiling) so we can see which
	-- widget class dominates a switch. Dumped by _repaintRoot.
	local prof = PROFILE and {} or nil
	self._last_prof = prof
	self._last_node_count = 0

	self:_walk(root, function(ih, cls)
		self._last_node_count = self._last_node_count + 1
		local ts = prof and os.clock() or nil
		-- Resolve the raw Ihandle* once per node so the scattered metadata
		-- reads/writes below (THEMEROLE, widget-id stamp, NTHEME clears) go through
		-- the FFI instead of the iuplua wrapper. nil when FFI is unavailable, in
		-- which case every helper falls back to iup.*.
		local p = self._ffi and self._ffi.ptr(ih) or nil
		local role
		if p then
			role = self._ffi.get(p, "THEMEROLE")
		else
			local okr, rv = pcall(iup.GetAttribute, ih, "THEMEROLE")
			if okr then
				role = rv
			end
		end
		-- Skip void layout containers (vbox/hbox/zbox/cbox/gridbox) unless they were
		-- given an explicit THEMEROLE. They draw nothing and only pass inheritance
		-- through to the dialog, so theming them is redundant and was the dominant
		-- cost of a switch (each container write forces a subtree layout re-measure).
		if VOID_CONTAINERS[cls] and (not role or role == "") then
			if prof then
				local e = prof[cls]
				if not e then
					e = { n = 0, ms = 0 }
					prof[cls] = e
				end
				e.n = e.n + 1
				e.ms = e.ms + (os.clock() - ts) * 1000
			end
			return
		end
		-- JS/CSS-parity fast path for generic labels (no locally-set FONT/FGCOLOR):
		-- do NOTHING. With no local style they resolve font + fg by inheritance at
		-- draw time, so when the dialog's NTHEME changes FGCOLOR and the global
		-- DEFAULTFONT changes, the single final Refresh repaints every generic label
		-- in the new theme for free -- no per-label SetAttribute and, crucially, no
		-- per-label natural-size re-measure (which even clearing FONT would trigger).
		-- Explicit-font labels (Bold/sized headers) are NOT eligible and fall through
		-- to normal per-widget theming. See LABEL_INHERIT / _isGenericLabel.
		if LABEL_INHERIT and cls == "label" and (not role or role == "")
			and self:_isGenericLabel(ih) then
			if prof then
				local e = prof["label(inherit)"]
				if not e then
					e = { n = 0, ms = 0 }
					prof["label(inherit)"] = e
				end
				e.n = e.n + 1
				e.ms = e.ms + (os.clock() - ts) * 1000
			end
			return
		end
		-- Restore the captured originals first, then apply this theme's rules.
		-- Restore-then-apply keeps switching symmetric: every per-class/per-role
		-- rule is re-applied cleanly instead of leaking the previous theme.
		self:_restoreElement(ih, p)
		-- Always use direct per-attribute SetAttribute (_applyElement) rather than
		-- NTHEME alone. NTHEME is a *fallback* for attrs not in the widget's own
		-- table -- it does NOT override attrs set explicitly at widget creation (e.g.
		-- BORDERCOLOR="160 160 160" on action buttons, FONT on the output text box).
		-- For native IUP controls (iup.text, iup.button, etc.) NTHEME may also be
		-- silently ignored entirely. _applyElement's direct SetAttribute is reliable
		-- for all widget types. _clearManagedRoleTheme removes any stale NTHEME
		-- written by a previous apply cycle so the restore stays clean.
		self:_applyElement(ih, rules, cls, role, p)
		self:_clearManagedRoleTheme(ih, p)
		if prof then
			local key = cls or "?"
			local e = prof[key]
			if not e then
				e = { n = 0, ms = 0 }
				prof[key] = e
			end
			e.n = e.n + 1
			e.ms = e.ms + (os.clock() - ts) * 1000
		end
	end)
end

-- Full-root re-theme used by apply()/refresh(): batched single walk + native
-- global theme + one Refresh, all under one paint lock.
function ThemeManager:_repaintRoot(theme)
	if not self._root then
		return
	end
	local iup = self._iup

	self:_beginPaintBatch(self._root)

	local t0 = os.clock()
	proflog(string.format(
		"%s repaintRoot: fastpath themeapply=%s ffi=%s",
		theme:id(),
		tostring(self._themeapply ~= nil),
		tostring(self._ffi ~= nil)
	))
	self:_repaintSubtree(self._root, theme)
	local t_walk = os.clock()

	-- Configure the native GLOBAL theme AFTER the per-widget save/restore walk.
	-- DEFAULTTHEME themes widgets at *creation* time (e.g. tabs/panels added later,
	-- before the coalesced re-theme runs); it does not walk the existing tree, so
	-- it's cheap. We deliberately do NOT set the inheritable THEME on the root:
	-- our per-widget NTHEME walk above already applied each widget's full attribute
	-- bundle, and setting THEME would make IUP re-apply the same attributes across
	-- the whole tree again in C -- a redundant second themed walk that was a major
	-- part of the classic->dark cost.
	if self._native_supported then
		if theme:isClassic() then
			pcall(iup.SetGlobal, "DEFAULTTHEME", nil)
			iup.SetAttribute(self._root, "THEME", nil)
		else
			local handle = self:_ensureNativeThemeHandle(theme)
			if handle then
				pcall(iup.SetGlobal, "DEFAULTTHEME", handle)
			end
		end
	end
	local t_theme = os.clock()

	pcall(iup.Refresh, self._root)
	local t_refresh = os.clock()
	self:_endPaintBatch(self._root)
	local t_end = os.clock()

	proflog(string.format(
		"%s repaintRoot: nodes=%d walk=%.1fms rootTHEME=%.1fms refresh=%.1fms unlock=%.1fms total=%.1fms",
		theme:id(),
		self._last_node_count or -1,
		(t_walk - t0) * 1000,
		(t_theme - t_walk) * 1000,
		(t_refresh - t_theme) * 1000,
		(t_end - t_refresh) * 1000,
		(t_end - t0) * 1000
	))

	if self._last_prof then
		-- Sort classes by total time descending so the dominant cost is first.
		local rows = {}
		for cls, e in pairs(self._last_prof) do
			rows[#rows + 1] = { cls = cls, n = e.n, ms = e.ms }
		end
		table.sort(rows, function(a, b) return a.ms > b.ms end)
		for i = 1, math.min(8, #rows) do
			local r = rows[i]
			proflog(string.format(
				"    %-16s n=%-4d total=%.1fms avg=%.2fms",
				r.cls, r.n, r.ms, r.ms / math.max(1, r.n)
			))
		end
	end
end

function ThemeManager:apply(name, opts)
	opts = opts or {}

	-- A theme locked by the org profile can't be switched by the user: refuse
	-- before repainting, rather than repaint and then fail to save.
	local settings = self._settings
	if settings and not opts.skip_save and settings.isLocked and settings:isLocked("theme")
		and name ~= settings:get("theme") then
		return false
	end

	local theme = self._theme_by_id[name] or self._theme_by_id.classic
	local theme_id = theme:id()

	-- No-op guard: skip the (expensive) re-theme only if THIS theme has actually
	-- been painted onto the live root already. Uses _applied (not _current/_active,
	-- which are seeded to classic at construction) so the very first apply always
	-- runs — otherwise a saved classic theme would never get painted at startup.
	if not opts.force and self._root and self._applied == theme_id then
		self:_syncControls()
		return
	end

	-- A pending coalesced re-theme would otherwise run after this and clobber/redo
	-- the work; cancel it since we're doing a full apply now.
	self:_cancelPending()

	self._active = theme
	self._current = theme_id

	ThemePalette.set(theme:isClassic() and nil or theme:palette())
	self:_applyMotion(theme)

	self:_repaintRoot(theme)

	-- Set the global font AFTER the per-widget walk. FONT is inheritable, so doing
	-- this first would let _save capture the new global as a widget's "original".
	local tf0 = os.clock()
	self:_applyGlobalFont(theme)
	self:_applyGlobalTooltip(theme)
	proflog(string.format("%s globalFont=%.1fms", theme_id, (os.clock() - tf0) * 1000))

	if self._root then
		self._applied = theme_id
	end

	self:_syncControls()

	if self._settings and not opts.skip_save then
		self._settings:set("theme", self._current)
		pcall(function()
			self._settings:save()
		end)
	end

	-- Notify paint-time observers (e.g. the gradient overlay) last, outside the
	-- per-widget attribute walk, so gradients never add to theme-switch cost.
	self:_fireOnApply()
end

function ThemeManager:refresh()
	if not self._root or not self._active then
		return
	end
	self:_repaintRoot(self._active)
	self:_applyGlobalFont(self._active)
	self:_applyGlobalTooltip(self._active)
end

-- Coalesced theming entry point wired to the host's _on_tree_change. A nil widget
-- requests a full re-theme; a specific widget requests just that subtree. Either
-- way the work is deferred to a one-shot timer so a burst of tab/settings
-- additions collapses into a single batched repaint.
function ThemeManager:themeWidget(widget)
	if not self._active then
		return
	end
	if not widget then
		self._pending_full = true
	else
		self._pending_subtrees[#self._pending_subtrees + 1] = widget
	end
	self:_ensureApplyTimer()
end

function ThemeManager:_ensureApplyTimer()
	local iup = self._iup
	if self._apply_timer then
		iup.SetAttribute(self._apply_timer, "RUN", "YES")
		return
	end
	local mgr = self
	local t = iup.timer{ TIME = "16", RUN = "NO" }
	function t:action_cb()
		iup.SetAttribute(t, "RUN", "NO")
		mgr:_flushPending()
		return iup.DEFAULT
	end
	self._apply_timer = t
	iup.SetAttribute(t, "RUN", "YES")
end

function ThemeManager:_cancelPending()
	self._pending_full = false
	self._pending_subtrees = {}
	if self._apply_timer then
		self._iup.SetAttribute(self._apply_timer, "RUN", "NO")
	end
end

function ThemeManager:_flushPending()
	if not self._active or not self._root then
		self._pending_full = false
		self._pending_subtrees = {}
		return
	end

	if self._pending_full then
		self._pending_full = false
		self._pending_subtrees = {}
		self:_repaintRoot(self._active)
		self:_applyGlobalFont(self._active)
		self:_applyGlobalTooltip(self._active)
		return
	end

	local subs = self._pending_subtrees
	self._pending_subtrees = {}
	if #subs == 0 then
		return
	end

	-- Theme every queued subtree under a single paint lock + one Refresh. A widget
	-- queued and then destroyed before this timer fired (TabGroups drops a group
	-- strip it created moments earlier when it ends up empty) is skipped: iuplua
	-- raises on any use of a destroyed handle.
	self:_beginPaintBatch(self._root)
	for _, w in ipairs(subs) do
		local alive, cls = pcall(self._iup.GetClassName, w)
		if alive and cls then
			self:_repaintSubtree(w, self._active)
		end
	end
	pcall(self._iup.Refresh, self._root)
	self:_endPaintBatch(self._root)
end

function ThemeManager:_syncControls()
	local iup = self._iup

	for id, item in pairs(self._menu_items) do
		if item then
			iup.SetAttribute(item, "VALUE", id == self._current and "ON" or "OFF")
		end
	end

	if self._dd then
		for i, t in ipairs(self._themes) do
			if t:id() == self._current then self._dd:setValue(i) end
		end
	end
end

function ThemeManager:buildMenu()
	local iup = self._iup
	local items = {}

	self._menu_items = {}
	for _, t in ipairs(self._themes) do
		items[#items + 1] = self:_menuItem(t)
	end
	self._menu = iup.menu(items)
	return iup.submenu({ self._menu, TITLE = "Theme" })
end

-- One radio-style Theme menu item.
function ThemeManager:_menuItem(t)
	local iup, mgr, id = self._iup, self, t:id()
	local item = iup.item({
		TITLE = t:label(),
		VALUE = (id == self._current) and "ON" or "OFF",
	})
	function item:action()
		mgr:_choose(id)
		return iup.DEFAULT
	end
	self._menu_items[id] = item
	return item
end

-- (Re)write the Settings dropdown's entries from the theme list.
function ThemeManager:_fillDropdown()
	if not self._dd then return end
	local labels, current = {}, nil
	for i, t in ipairs(self._themes) do
		labels[i] = t:label()
		if t:id() == self._current then current = i end
	end
	self._dd:setItems(labels, current)
end

-- Theme selector for the Settings tab: a core.ui.FlatDropdown (an owner-drawn
-- IupDropButton with an IupFlatList drop child) rather than a native dropdown
-- list, so its border, background and popup follow the active theme.
function ThemeManager:buildDropdown()
	local FlatDropdown = require("core.ui.FlatDropdown")
	local mgr = self
	local labels, current = {}, nil
	for i, t in ipairs(self._themes) do
		labels[i] = t:label()
		if t:id() == self._current then current = i end
	end
	local dd = FlatDropdown.new(self._iup, {
		items = labels,
		value = current,
		width = 180,
		font = "Segoe UI, 10",
		name = "themebar_theme_dropchild",
		on_change = function(index)
			if mgr._applying then return end
			local t = mgr._themes[index]
			if t then mgr:_choose(t:id()) end
		end,
	})
	self._dd = dd
	self._dropdown = dd.list
	self._dropdown_btn = dd.widget
	return dd.widget
end

return ThemeManager

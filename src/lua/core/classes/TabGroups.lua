--- Extension tab groups: a tree of `iup.flattabs` strips.
--
-- A **group** is a tab whose page is itself an `iup.flattabs`. Activating the
-- group tab therefore reveals a second tab bar directly beneath the first, which
-- holds that group's member tabs. Because a group's page is just another strip,
-- groups nest to any depth with no extra machinery — a group inside a group is a
-- strip inside a strip.
--
-- ### All state lives on the widgets
--
-- This class keeps **no Lua-side model at all** — not of the order, not of the
-- membership, and (since the duplication bug described below) not of the group
-- metadata either. Everything is read back out of IUP, and every attribute it
-- writes lives on the widget it describes:
--
--   * `_IUPLUNAR_TABKEY` — stable key for a leaf tab (`"<manifest id>/<n>"`, or
--     `"host/<id>"` for host-owned tabs). Set by `core.classes.HostAPI:addTab`.
--   * `_IUPLUNAR_GROUPNAME` — display name of a group. Its **presence marks the
--     widget as a group strip**; there is no separate registry to consult.
--   * `_IUPLUNAR_GROUPSOURCE` — `"user"` or `"manifest"` (see the pruning rule).
--   * `_IUPLUNAR_GROUPACTIVE` — the member this group was last left on.
--   * `_IUPLUNAR_GROUPHINT` — optional manifest-supplied default group path,
--     applied only the first time a tab is seen.
--
-- **The `_IUP` prefix on those names is required for correctness, not style** —
-- see the comment on the constants below before touching them.
--
-- ### Tab titles belong to the PARENT, by position
--
-- `TABTITLE` looks like a property of the page but is not. `IupFlatTabs` stores
-- it as a position-indexed attribute on the **strip** — `TABTITLE0`, `TABTITLE1`
-- — and `iFlatTabsChildAddedMethod` copies it off the child exactly once, when
-- the child is attached, and *only if the strip has no title at that position
-- already*. So setting `TABTITLE` on a page that is already attached does
-- nothing (this is why renaming a group appeared to do nothing), and a page
-- inserted into a slot a different page used to occupy can inherit the previous
-- occupant's title.
--
-- `_syncTitles` is therefore called after every structural change: it rewrites
-- every `TABTITLE<pos>` on the strip from its children. Nothing in this class
-- relies on IUP's one-shot copy.
--
-- ### Persistence
--
-- The whole tree is serialized to the `tab_groups` setting:
--
--     { version = 1, children = {
--         { t = "tab",   key = "hello/1" },
--         { t = "group", name = "Diagnostics", source = "user",
--           active = "logparser/1", children = { { t = "tab", key = "logparser/1" } } },
--     } }
--
-- @classmod core.classes.TabGroups

local class  = require("middleclass")
local handle = require("core.lib.handle")
local attr   = require("core.lib.attr")
local tree   = require("core.lib.tree")

-- Native paint batching (see `core.classes.ThemeManager`, which uses it for the
-- same reason). Optional: absent under the test doubles and on any non-Windows
-- build, where every operation below still produces the right tree and only the
-- number of intermediate repaints differs.
local ok_winredraw, winredraw = pcall(require, "winredraw")
if not ok_winredraw then winredraw = nil end

local TabGroups = class("TabGroups")

-- THE `_IUP` PREFIX IS LOad-BEARING. DO NOT RENAME THESE.
--
-- IUP inherits custom attributes. For any name the control's class does not
-- register, `iupClassObjectGetAttribute` returns `inherit = 1` ("default is
-- inheritable", iup_classattrib.c) and `IupGetAttribute` then walks up the
-- parent chain until it finds a value. So an attribute set on a group strip is
-- visible on EVERY widget inside it, all the way down.
--
-- That is not a subtle problem here, it is a catastrophic one: the marker that
-- says "this page is a group" was being read back as true for the extension
-- pages inside the group, and then for the widgets inside those. Grouping an
-- extension turned the extension into a group; ungrouping it walked into the
-- extension's own layout and lifted its panels out as if they were tabs.
--
-- Names starting with `_IUP` are "internal" (`iupATTRIB_ISINTERNAL`,
-- iup_attrib.h). `IupGetAttribute` short-circuits for those and returns the
-- LOCAL value only, with no inheritance walk -- which is exactly why IUP's own
-- private per-widget state is named this way (`_IUPFTABS_SCROLLPOS` and
-- friends). Every attribute this host invents must follow the same rule.
--
-- THE OTHER HALF OF THAT RULE: read them through `core.lib.attr`, never through
-- `iup.GetAttribute`. The Lua binding refuses to hand an internal attribute back
-- to Lua at all -- `iuplua_pushvalue` pushes nil for any name starting with `_IUP`,
-- whatever is stored -- so a direct read always answers "unset", with no error to
-- notice. That is not hypothetical either: it meant `keyOf` never found a layout
-- key, `serialize()` silently dropped every tab from the saved arrangement, and
-- each launch re-appended the user's grouped tabs at the root. `core.lib.attr`
-- reads through the C entry point, which returns the value that is actually there.
local TAB_ATTR    = "_IUPLUNAR_TABKEY"
local NAME_ATTR   = "_IUPLUNAR_GROUPNAME"
local SOURCE_ATTR = "_IUPLUNAR_GROUPSOURCE"
local ACTIVE_ATTR = "_IUPLUNAR_GROUPACTIVE"
local HINT_ATTR   = "_IUPLUNAR_GROUPHINT"

-- Versions 1 and 2 were both written by builds that read the group marker through
-- an INHERITED attribute (see the constants below), so both could persist a tree
-- of duplicated, self-nested groups. A layout at either version may already be
-- corrupt, and restoring it faithfully would just preserve the mess -- so older
-- layouts are DISCARDED rather than migrated. Tabs fall back to load order plus
-- their manifest hints: a clean strip the user rearranges once.
local SCHEMA_VERSION = 3

-- Vertical room one nested tab strip costs its page. Used only to tighten the
-- MAXSIZE height cap that HostAPI:addTab puts on every page (see the long comment
-- there): a page two levels deep has two tab bars above it, so its ceiling has to
-- come down by the same amount or the deficit reappears at the bottom of the
-- window as a clipped status bar.
local STRIP_HEIGHT = 28

-- Guard against a malformed saved tree (or a bug here) sending a descent
-- infinite. Groups may nest arbitrarily deep by design, so this is a sanity
-- ceiling and not a product limit.
local MAX_DEPTH = 64

--- Create the group manager for a root tab strip.
--
-- `opts` fields:
--
--   * `iup` — the IUP binding
--   * `root_strip` — the host's main `iup.flattabs`
--   * `settings` — a `core.classes.SettingsManager` for persistence
--   * `on_change` — invoked after any structural change (the host re-scopes menus)
--   * `on_strip_created` — invoked with each new strip so the caller can install
--     drag handlers on it (`core.classes.TabOrder:install`)
--   * `on_new_group` — invoked as `fn(parent_strip)` when a strip's "+" button is
--     pressed; omit to fall back to creating an auto-named group
--   * `notify_tree_change` — theme hook for freshly created widgets
--   * `height_cap` — base MAXSIZE height for a top-level page
--
-- @tparam table opts construction options (see above)
function TabGroups:initialize(opts)
	self._iup        = opts.iup
	self._root       = opts.root_strip
	self._settings   = opts.settings
	self._on_change  = opts.on_change
	self._on_strip   = opts.on_strip_created
	self._on_new     = opts.on_new_group
	self._notify     = opts.notify_tree_change
	self._height_cap = tonumber(opts.height_cap)

	self._shown    = false
	self._restored = false

	self._depth           = 0       -- open `_batch` nesting level
	self._refresh_wanted  = false   -- a layout pass is owed at depth 0
	self._changed_wanted  = false   -- a save + re-scope is owed at depth 0

	if self._root then
		self:_prepareStrip(self._root)
	end
end

-- =======================================================================
-- BATCHING
-- =======================================================================
--
-- Every structural edit below owes the world three things when it finishes: a
-- layout pass, a repaint, and a save + host re-scope. Each is expensive, each is
-- idempotent, and each used to be issued by the *innermost* thing that dirtied
-- something -- so a single drag produced four or five of all three.
--
-- That is what the flicker was. `IupRefresh` recomputes the layout of the whole
-- DIALOG regardless of the widget it is handed (`iup_layout.c`: it resolves to
-- `IupGetDialog` and lays out from there), and repositions every native window in
-- it. Doing that once is invisible; doing it four times interleaved with widget
-- surgery is the app visibly rebuilding itself.
--
-- So the public operations wrap themselves in `_batch`, which collapses all three
-- into one round at the end of the OUTERMOST operation -- `groupTogether` is a
-- group creation plus two moves, and now costs one layout pass rather than four.

-- Suspend painting for the whole dialog while the tree is in pieces. Only ever
-- held across the synchronous surgery below, which opens no dialogs -- the lock is
-- process-global (`LockWindowUpdate`), so anything that could block while holding
-- it would freeze the window it is protecting.
function TabGroups:_lockPaint()
	if winredraw and self._root and self._shown then
		pcall(winredraw.lock, self._root)
	end
end

function TabGroups:_unlockPaint()
	if winredraw and self._root and self._shown then
		pcall(winredraw.unlock, self._root)
	end
end

--- Run `fn` as one operation: one layout pass, one repaint, one save.
--
-- Re-entrant. Nested calls (a merge creates a group and then performs two moves)
-- join the outermost batch rather than starting their own, which is also what
-- keeps the paint lock balanced -- `LockWindowUpdate` holds one window
-- process-wide, so an inner unlock would release the outer lock mid-surgery.
--
-- @tparam function fn the work to perform
-- @return whatever `fn` returned
-- @local
function TabGroups:_batch(fn)
	self._depth = (self._depth or 0) + 1
	if self._depth == 1 then self:_lockPaint() end

	local ok, a, b = pcall(fn)

	self._depth = self._depth - 1
	if self._depth == 0 then
		-- Layout first, then reveal it: the repaint on unlock should show the
		-- finished arrangement rather than the tree halfway to it.
		self:_flushRefresh()
		self:_unlockPaint()
		-- Persisting and re-scoping happen OUTSIDE the lock. `save()` writes to
		-- disk and `on_change` may rearrange the status bar; neither is layout the
		-- repaint above is waiting on, and neither belongs inside a global lock.
		self:_flushChanged()
	end

	if not ok then error(a, 0) end
	return a, b
end

-- Record that the dialog's layout is stale. Collapsed to a single `IupRefresh` at
-- the end of the outermost batch; issued immediately when there is no batch, so
-- callers outside one behave exactly as they did before.
function TabGroups:_requestRefresh()
	self._refresh_wanted = true
	if (self._depth or 0) == 0 then self:_flushRefresh() end
end

function TabGroups:_flushRefresh()
	if not self._refresh_wanted then return end
	self._refresh_wanted = false
	-- The root, not the strip that changed: IupRefresh lays out the containing
	-- dialog either way, so every target is the same call.
	pcall(self._iup.Refresh, self._root)
end

function TabGroups:_flushChanged()
	if not self._changed_wanted then return end
	self._changed_wanted = false
	self:save()
	if self._on_change then pcall(self._on_change) end
end

-- =======================================================================
-- WIDGET TREE HELPERS
-- =======================================================================

-- Do two handles refer to the same widget?
--
-- NEVER use `==` for this. The Lua binding allocates a fresh userdata on every
-- push, so two handles for the same widget compare unequal — see core.lib.handle
-- for the mechanism and for the damage it did here.
function TabGroups:_same(a, b)
	return handle.same(self._iup, a, b)
end

-- Session-stable identity string, for use as a table key.
function TabGroups:_uid(widget)
	return handle.id(self._iup, widget)
end

--- Ordered array (1-based) of a strip's page handles.
-- @local
function TabGroups:_children(strip)
	local iup, out, i = self._iup, {}, 0
	if not strip then return out end
	while true do
		local ok, child = pcall(iup.GetChild, strip, i)
		if not ok or not child then break end
		out[#out + 1] = child
		i = i + 1
	end
	return out
end

--- Describe a group strip, or return `nil` for a leaf tab.
--
-- The returned table is a read-only snapshot built from the widget's own
-- attributes — there is no registry behind it, so it cannot go stale and mutating
-- it does nothing. Use `renameGroup` to change the name.
--
-- @tparam userdata widget a page handle
-- @treturn table|nil `{ name, source, strip, active }`
function TabGroups:groupOf(widget)
	if not self:isGroupStrip(widget) then return nil end
	local name   = attr.get(self._iup, widget, NAME_ATTR)
	local source = attr.get(self._iup, widget, SOURCE_ATTR)
	local active = attr.get(self._iup, widget, ACTIVE_ATTR)
	return {
		name   = name or self:_titleOf(widget) or "Group",
		source = source or "user",
		active = active,
		strip  = widget,
	}
end

--- True when `widget` is a group strip.
--
-- Decided STRUCTURALLY, from the widget's class, not from an attribute this class
-- wrote. A group page is by construction an `iup.flattabs`; an extension page
-- never is (`HostAPI:addTab` hands over a box or a scroll host). Asking IUP what
-- the widget *is* cannot be thrown off by an attribute that was inherited, lost,
-- or never applied — three failure modes that have each produced a release-blocking
-- bug in this feature. The attributes now only carry a group's *data* (its name,
-- origin, last-active member), never its identity.
--
-- The root strip is excluded: it is a flattabs, but it is the container for
-- groups rather than one of them.
--
-- @tparam userdata widget a page handle
-- @treturn boolean
function TabGroups:isGroupStrip(widget)
	if not widget then return false end
	if self._root and self:_same(widget, self._root) then return false end

	local ok, cls = pcall(self._iup.GetClassName, widget)
	if ok and cls ~= nil then return cls == "flattabs" end

	-- GetClassName unavailable (a cut-down binding, or a test double). Fall back
	-- to the marker attribute rather than answering "nothing is a group": that
	-- answer makes restore() treat every group strip as a leaf, re-attach it at
	-- the root, and drop it from the saved layout — silently deleting the user's
	-- groups. A wrong answer here is destructive, so it degrades instead.
	local name = attr.get(self._iup, widget, NAME_ATTR)
	return name ~= nil
end

-- The title a page should be showing: a group's name, or a leaf's own TABTITLE.
function TabGroups:_titleOf(widget)
	local name = attr.get(self._iup, widget, NAME_ATTR)
	if name then return name end
	local ok2, title = pcall(self._iup.GetAttribute, widget, "TABTITLE")
	if ok2 and title then return title end
	return ""
end

-- Rewrite every TABTITLE<pos> on a strip from its current children.
--
-- REQUIRED after any append, insert, detach or rename. IupFlatTabs keeps titles
-- as position-indexed attributes on the strip and only copies one off a child at
-- attach time, and only into an empty slot (iFlatTabsChildAddedMethod), so
-- without this a reordered strip shows the previous occupants' titles and a
-- rename never appears at all.
function TabGroups:_syncTitles(strip)
	if not strip then return end
	local iup = self._iup
	for i, child in ipairs(self:_children(strip)) do
		pcall(iup.SetAttributeId, strip, "TABTITLE", i - 1, self:_titleOf(child))
	end
	self:_requestRefresh()
end

--- The stable key of a leaf tab, or `nil` for group strips and untagged widgets.
-- @tparam userdata widget a page handle
-- @treturn string|nil
function TabGroups:keyOf(widget)
	if not widget then return nil end
	return attr.get(self._iup, widget, TAB_ATTR)
end

--- The strip a page currently lives in (`nil` when detached).
-- @tparam userdata widget a page handle
-- @treturn userdata|nil
function TabGroups:stripOf(widget)
	if not widget then return nil end
	local ok, parent = pcall(self._iup.GetParent, widget)
	if not ok then return nil end
	return parent
end

--- Position (0-based, matching `VALUEPOS`) of a page within its strip.
-- @local
function TabGroups:_posOf(widget)
	local strip = self:stripOf(widget)
	if not strip then return nil end
	for i, child in ipairs(self:_children(strip)) do
		if self:_same(child, widget) then return i - 1 end
	end
	return nil
end

--- How many strips deep a strip sits (root is 0).
-- @tparam userdata strip a strip handle
-- @treturn number
function TabGroups:depthOf(strip)
	local depth, cur = 0, strip
	while cur and not self:_same(cur, self._root) and depth < MAX_DEPTH do
		cur = self:stripOf(cur)
		depth = depth + 1
	end
	return depth
end

--- Every strip in the tree, ordered deepest first.
--
-- Drop targeting hit-tests in this order because a nested strip is physically
-- inside its parent's rectangle: testing the parent first would always win and
-- sub-tab bars would be unreachable.
--
-- @treturn {userdata,...} strip handles, deepest first
function TabGroups:stripsDeepestFirst()
	local out = {}
	local function walk(strip, depth)
		if depth > MAX_DEPTH then return end
		out[#out + 1] = { strip = strip, depth = depth }
		for _, child in ipairs(self:_children(strip)) do
			if self:isGroupStrip(child) then walk(child, depth + 1) end
		end
	end
	if self._root then walk(self._root, 0) end
	table.sort(out, function(a, b) return a.depth > b.depth end)
	local strips = {}
	for _, e in ipairs(out) do strips[#strips + 1] = e.strip end
	return strips
end

--- The root (main) tab strip.
-- @treturn userdata the root `iup.flattabs`
function TabGroups:rootStrip()
	return self._root
end

--- Every group in the tree as `{ strip = <handle>, path = "Parent / Child" }`.
--
-- Used to offer a flat "move to group" list in the tab context menu:
-- `core.ui.ContextMenu` has no submenus, so the full path stands in for the
-- nesting. The root is included first as the top-level destination.
--
-- @treturn {table,...} entries in depth-first display order
function TabGroups:groupPaths()
	local out = { { strip = self._root, path = "Top Level" } }
	local function walk(strip, prefix, depth)
		if depth > MAX_DEPTH then return end
		for _, child in ipairs(self:_children(strip)) do
			local record = self:groupOf(child)
			if record then
				local path = prefix and (prefix .. " / " .. record.name) or record.name
				out[#out + 1] = { strip = child, path = path }
				walk(child, path, depth + 1)
			end
		end
	end
	if self._root then walk(self._root, nil, 0) end
	return out
end

--- Is `maybe_ancestor` at or above `widget` in the strip tree?
-- Used to refuse dropping a group into itself or into one of its own descendants,
-- which would detach a subtree from the tree and lose it.
-- @local
function TabGroups:_isAncestor(maybe_ancestor, widget)
	local cur, guard = widget, 0
	while cur and guard < MAX_DEPTH do
		if self:_same(cur, maybe_ancestor) then return true end
		cur = self:stripOf(cur)
		guard = guard + 1
	end
	return false
end

-- =======================================================================
-- STRIP CONSTRUCTION
-- =======================================================================

-- Attach the host's per-strip behaviour: the "+" new-group button and whatever
-- drag handling the caller installs. Applied to the root strip as well as to
-- every group strip, so a group's own bar behaves exactly like the main one.
function TabGroups:_prepareStrip(strip)
	local iup = self._iup
	local self_ = self

	-- EXTRABUTTONS is IupFlatTabs' own trailing-button facility: it draws the
	-- button inside the strip after the last tab and reports presses through
	-- EXTRABUTTON_CB. Using it rather than a sibling widget keeps the button
	-- inside the themed strip and correctly positioned when tabs overflow.
	--
	-- NOTE: this only works because core.classes.TabOrder now hooks
	-- FLAT_BUTTON_CB instead of overwriting the control's internal BUTTON_CB.
	pcall(iup.SetAttribute, strip, "EXTRABUTTONS", "1")
	pcall(iup.SetAttributeId, strip, "EXTRATITLE", 1, "+")
	pcall(iup.SetAttributeId, strip, "EXTRATIP", 1, "New tab group")

	pcall(function()
		function strip:extrabutton_cb(id, pressed)
			-- Act on release, mirroring a normal button click.
			if id == 1 and pressed == 0 then
				if self_._on_new then
					self_._on_new(strip)
				else
					self_:createGroup(strip)
				end
			end
			return iup.DEFAULT
		end
	end)

	if self._on_strip then self._on_strip(strip) end
end

--- Create a group and append (or insert) it into `parent_strip`.
--
-- @tparam[opt] userdata parent_strip strip to create the group in; defaults to the root
-- @tparam[opt] string name display name; auto-numbered when omitted
-- @tparam[opt="user"] string source `"user"` or `"manifest"` — empty manifest groups
--   are pruned on restore, user-created ones are kept
-- @tparam[opt] number index 1-based insertion position; appends when omitted
-- @treturn userdata the new group's strip handle
function TabGroups:createGroup(parent_strip, name, source, index)
	return self:_batch(function()
		return self:_createGroup(parent_strip, name, source, index)
	end)
end

function TabGroups:_createGroup(parent_strip, name, source, index)
	local iup = self._iup
	parent_strip = parent_strip or self._root
	if not parent_strip then return nil end

	local strip = iup.flattabs({})
	pcall(iup.SetAttribute, strip, "TABTYPE", "TOP")
	pcall(iup.SetAttribute, strip, "EXPAND", "YES")

	name = name or ("Group " .. tostring(self:_countGroups(self._root) + 1))
	-- Identity, name and origin all live on the widget. Nothing is registered
	-- anywhere else, so there is no id to collide and no record to go stale.
	pcall(iup.SetAttribute, strip, NAME_ATTR, name)
	pcall(iup.SetAttribute, strip, SOURCE_ATTR, source or "user")
	pcall(iup.SetAttribute, strip, "TABTITLE", name)

	self:_prepareStrip(strip)
	self:_insertAt(parent_strip, strip, index)
	self:_applyHeightCap(strip)
	self:_syncTitles(parent_strip)

	if self._notify then pcall(self._notify, strip) end
	self:_changed()
	return strip
end

-- Total number of groups anywhere in the tree; used only for auto-numbering.
function TabGroups:_countGroups(strip, depth)
	depth = depth or 0
	if depth > MAX_DEPTH then return 0 end
	local n = 0
	for _, child in ipairs(self:_children(strip)) do
		if self:isGroupStrip(child) then
			n = n + 1 + self:_countGroups(child, depth + 1)
		end
	end
	return n
end

--- Rename a group.
--
-- Writes the name to the widget AND re-syncs the parent strip's position-indexed
-- titles. Setting `TABTITLE` on an attached page is a no-op in IUP — the strip
-- owns the title, so without the re-sync the old label stays on screen.
--
-- @tparam userdata strip the group strip
-- @tparam string name new display name
-- @treturn boolean true when the group existed and was renamed
function TabGroups:renameGroup(strip, name)
	if not self:isGroupStrip(strip) then return false end
	name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then return false end
	pcall(self._iup.SetAttribute, strip, NAME_ATTR, name)
	pcall(self._iup.SetAttribute, strip, "TABTITLE", name)
	self:_syncTitles(self:stripOf(strip))
	self:_changed()
	return true
end

--- Dissolve a group, lifting its members into the parent strip in its place.
-- The group strip itself is destroyed. Members keep their relative order.
-- @tparam userdata strip the group strip
-- @treturn boolean true when the group existed and was dissolved
function TabGroups:dissolveGroup(strip)
	if not self:isGroupStrip(strip) then return false end
	local parent = self:stripOf(strip)
	if not parent then return false end

	return self:_batch(function()
		local iup = self._iup
		local at = (self:_posOf(strip) or 0) + 1
		for _, child in ipairs(self:_children(strip)) do
			-- No Detach first: `_insertAt` reparents, which moves the page out of
			-- the dying strip without destroying its windows on the way (see
			-- core.lib.tree). Detaching here would unmap every page in the group and
			-- hand the reparent nothing left to preserve.
			self:_insertAt(parent, child, at)
			self:_applyHeightCap(child)
			at = at + 1
		end

		pcall(iup.Detach, strip)
		pcall(iup.Destroy, strip)
		self:_syncTitles(parent)
		self:_changed()
		return true
	end)
end

-- Insert `widget` into `strip` at a 1-based index (appending when out of range),
-- mapping it if the window is already up and it had to be built from scratch.
--
-- A widget that was already attached somewhere is REPARENTED rather than detached
-- and re-appended, so it keeps its native windows across the move -- see
-- core.lib.tree for why that distinction is the whole difference between a tab
-- move and an apparent full-app refresh. A brand new strip has no parent yet and
-- takes the append path, which is what still needs the map.
function TabGroups:_insertAt(strip, widget, index)
	local iup = self._iup
	local kids = self:_children(strip)
	local ref = nil
	if index and index >= 1 and index <= #kids then
		ref = kids[index]
	end
	local kept = tree.place(iup, strip, widget, ref)
	if self._shown and not kept then
		pcall(iup.Map, widget)
	end
end

-- Tighten a page's MAXSIZE height for the depth it now sits at. See STRIP_HEIGHT.
function TabGroups:_applyHeightCap(widget)
	if not self._height_cap then return end
	local strip = self:stripOf(widget)
	if not strip then return end
	local cap = self._height_cap - (self:depthOf(strip) * STRIP_HEIGHT)
	if cap < 320 then cap = 320 end
	pcall(self._iup.SetAttribute, widget, "MAXSIZE", "65535x" .. tostring(cap))
end

-- Note that the layout changed. Suppressed until restore() has finished: during
-- startup the tree is still being assembled, so notifying on every intermediate
-- append would re-scope menus dozens of times and could write a half-built layout
-- over the user's saved one.
--
-- Inside a batch this only records the debt; `_flushChanged` settles it once at
-- the end: a merge is three structural edits, and must not serialize the tree
-- and write settings.json three times for one drag.
function TabGroups:_changed()
	if not self._restored then return end
	self._changed_wanted = true
	if (self._depth or 0) == 0 then self:_flushChanged() end
end

-- =======================================================================
-- MOVING TABS
-- =======================================================================

--- Move a page into a strip at a position, physically and in the saved layout.
--
-- Refuses moves that would detach a subtree from the tree (a group into itself or
-- into one of its own descendants), which is the one way arbitrary nesting can go
-- wrong.
--
-- @tparam userdata widget the page to move (a leaf tab or a whole group)
-- @tparam userdata target_strip destination strip
-- @tparam[opt] number index 1-based destination position; appends when omitted
-- @treturn boolean true when the move happened
function TabGroups:moveInto(widget, target_strip, index)
	if not widget or not target_strip then return false end
	if self:_same(widget, target_strip) then return false end
	if self:_isAncestor(widget, target_strip) then return false end
	if not self:stripOf(widget) then return false end

	return self:_batch(function()
		return self:_moveInto(widget, target_strip, index)
	end)
end

function TabGroups:_moveInto(widget, target_strip, index)
	local iup = self._iup
	local source = self:stripOf(widget)
	if not source then return false end

	local kids = self:_children(target_strip)
	if self:_same(source, target_strip) then
		-- Removing the widget first shifts every later position down by one, so
		-- the caller's index (measured against the strip as the user sees it)
		-- has to be corrected or a rightward move lands one slot short.
		local from
		for i, c in ipairs(kids) do
			if self:_same(c, widget) then from = i; break end
		end
		if from then
			table.remove(kids, from)
			if index and index > from then index = index - 1 end
		end
		if from and index == from then return false end   -- no-op
	end

	local ref = nil
	if index and index >= 1 and index <= #kids then ref = kids[index] end

	-- REPARENT, do not detach and re-append.
	--
	-- `IupDetach` unmaps, which destroys every native window under the page; the
	-- re-append then rebuilds the extension's entire control tree from scratch.
	-- That is what made dragging a tab look like the app reloading itself -- the
	-- content was identical afterwards, but all of it had been thrown away and
	-- redrawn. `core.lib.tree` moves the page with a single SetParent instead, so
	-- the windows the user is looking at simply change position in the tree.
	local kept = tree.place(iup, target_strip, widget, ref)
	-- Only map once the dialog owns a native window, and only when the fallback
	-- path actually unmapped something. Mapping a page before IupShow corrupts
	-- dynamically-populated children -- the same lifecycle trap HostAPI:addTab
	-- documents -- and restore() runs this path pre-show.
	if self._shown and not kept then pcall(iup.Map, widget) end
	self:_applyHeightCap(widget)
	-- Both strips: the source lost a tab and the destination gained one, so both
	-- have position-indexed titles that no longer line up with their children.
	self:_syncTitles(source)
	if not self:_same(target_strip, source) then self:_syncTitles(target_strip) end

	-- Follow the tab the user just dragged: make it current in its new strip and
	-- make every ancestor group current too, so the move is visible rather than
	-- silently filed away behind a collapsed group.
	self:reveal(widget)

	self:_requestRefresh()
	self:_changed()
	return true
end

--- Create a new group holding `first` and `second`, in place of `first`.
--
-- This is the drag-two-tabs-together gesture: the new group takes the position
-- `first` occupied, and both tabs become its members.
--
-- @tparam userdata first the page that was dropped on (defines the group's slot)
-- @tparam userdata second the page that was dragged
-- @tparam[opt] string name group display name; auto-numbered when omitted
-- @treturn userdata|nil the new group's strip
function TabGroups:groupTogether(first, second, name)
	if not first or not second or self:_same(first, second) then return nil end
	local parent = self:stripOf(first)
	if not parent then return nil end
	-- Dropping a group onto one of its own members would nest it inside itself.
	if self:_isAncestor(second, first) then return nil end

	-- One batch around all three edits. Left unbatched this is a group creation
	-- plus two moves, each laying out the dialog, saving settings.json and
	-- re-scoping the host -- so the single gesture that forms a group was by far
	-- the most expensive thing the tab strip could do.
	return self:_batch(function()
		local at = (self:_posOf(first) or 0) + 1
		local strip = self:createGroup(parent, name, "user", at)
		if not strip then return nil end

		self:moveInto(first, strip)
		self:moveInto(second, strip)
		return strip
	end)
end

-- =======================================================================
-- ACTIVATION
-- =======================================================================

--- The active leaf page, descending through nested group strips.
--
-- The host resolves "which extension owns the current view" from this, so it must
-- return the innermost real tab and never a group strip.
--
-- @treturn userdata|nil the active leaf page
function TabGroups:activeLeaf()
	local iup = self._iup
	if not self._root then return nil end
	local ok, active = pcall(iup.GetAttributeHandle, self._root, "VALUE")
	if not ok or not active then return nil end
	local guard = 0
	while self:isGroupStrip(active) and guard < MAX_DEPTH do
		local ok2, inner = pcall(iup.GetAttributeHandle, active, "VALUE")
		if not ok2 or not inner then break end
		active = inner
		guard = guard + 1
	end
	if self:isGroupStrip(active) then return nil end   -- empty group
	return active
end

--- Make `widget` the visible page, activating every group above it.
--
-- Ancestors are activated outermost-first so each strip is already on screen when
-- the next one down is switched. This is what makes `lunar://` routing work for a
-- tab that lives several groups deep.
--
-- @tparam userdata widget the page to reveal
-- @treturn boolean true when the page was reachable from the root
function TabGroups:reveal(widget)
	local iup = self._iup
	if not widget then return false end

	-- Walk up to the root collecting (strip, position) pairs.
	local chain, cur, guard = {}, widget, 0
	while cur and guard < MAX_DEPTH do
		local strip = self:stripOf(cur)
		if not strip then break end
		local pos = self:_posOf(cur)
		if pos == nil then return false end
		chain[#chain + 1] = { strip = strip, pos = pos }
		if self:_same(strip, self._root) then
			for i = #chain, 1, -1 do
				local step = chain[i]
				pcall(iup.SetAttribute, step.strip, "VALUEPOS", tostring(step.pos))
				if self:isGroupStrip(step.strip) then
					local member = self:_children(step.strip)[step.pos + 1]
					pcall(iup.SetAttribute, step.strip, ACTIVE_ATTR, self:_memberKey(member))
				end
			end
			return true
		end
		cur = strip
		guard = guard + 1
	end
	return false
end

-- How a group refers to its last-active member when saving: a leaf's key, or a
-- nested group's name (unique enough within one strip to re-find on restore).
function TabGroups:_memberKey(widget)
	if not widget then return nil end
	local key = self:keyOf(widget)
	if key then return key end
	local record = self:groupOf(widget)
	return record and ("group:" .. record.name) or nil
end

--- Remember which member of each group is current, so a group reopens where the
-- user left it rather than snapping back to its first tab.
--
-- Walks the live tree rather than a registry — a destroyed strip simply is not
-- in the tree, so there is no stale handle to read attributes off.
-- @local
function TabGroups:_captureActive(strip, depth)
	strip = strip or self._root
	depth = depth or 0
	if not strip or depth > MAX_DEPTH then return end
	for _, child in ipairs(self:_children(strip)) do
		if self:isGroupStrip(child) then
			local ok, active = pcall(self._iup.GetAttributeHandle, child, "VALUE")
			if ok and active then
				pcall(self._iup.SetAttribute, child, ACTIVE_ATTR, self:_memberKey(active))
			end
			self:_captureActive(child, depth + 1)
		end
	end
end

-- =======================================================================
-- EXTENSION UNLOAD
-- =======================================================================

--- Forget a page that is about to be destroyed (extension unload or reload).
--
-- The page is left attached — `HostAPI:removeOwned` still detaches and destroys
-- it — but any group it emptied is cleaned up here. Groups the user made by hand
-- survive going empty; groups auto-created from a manifest hint do not, because
-- nothing would ever put a tab back into them.
--
-- @tparam userdata widget the page being removed
function TabGroups:forget(widget)
	if not widget then return end
	local strip = self:stripOf(widget)

	if strip and not self:_same(strip, self._root) then
		-- Deferred: the caller detaches after this returns, so the page we are
		-- being told about still counts as a child right now.
		local remaining = 0
		for _, child in ipairs(self:_children(strip)) do
			if not self:_same(child, widget) then remaining = remaining + 1 end
		end
		local parent_record = self:groupOf(strip)
		if remaining == 0 and parent_record and parent_record.source == "manifest" then
			local grandparent = self:stripOf(strip)
			pcall(self._iup.Detach, widget)
			pcall(self._iup.Detach, strip)
			pcall(self._iup.Destroy, strip)
			self:_syncTitles(grandparent)
		else
			-- The caller's detach is still to come, so re-sync afterwards rather
			-- than now; queue it by syncing the strip once the child is gone.
			pcall(self._iup.Detach, widget)
			self:_syncTitles(strip)
		end
	end

	-- Deliberately re-scopes but does NOT save.
	--
	-- "Reload Extensions" tears every extension tab down and then adds them all
	-- back. Persisting here would write out that momentarily empty layout and
	-- destroy the group membership the reload is about to restore from it. An
	-- extension that is genuinely gone needs no bookkeeping either: restore()
	-- drops saved entries whose tab is missing.
	if self._restored and self._on_change then pcall(self._on_change) end
end

-- =======================================================================
-- PERSISTENCE
-- =======================================================================

-- Can an `_IUP` attribute actually be written and read back?
--
-- Probed rather than inferred. The obvious test -- "is the direct C read path
-- available?" -- checks the MECHANISM, and the mechanism is not the thing that
-- matters: under the test doubles the plain binding round-trips these names
-- perfectly well, while on a real IUP build it silently cannot (core.lib.attr).
-- Asking the question directly is correct under both, and stays correct if the
-- read path is ever reimplemented.
--
-- Memoized: the answer cannot change within a session, and save() is called on
-- every structural edit.
function TabGroups:_attrsReadable()
	if self._attrs_readable == nil then
		local probe = "_IUPLUNAR_PROBE"
		attr.set(self._iup, self._root, probe, "1")
		self._attrs_readable = (attr.get(self._iup, self._root, probe) == "1")
		attr.set(self._iup, self._root, probe, nil)
	end
	return self._attrs_readable
end

--- Serialize the current layout to a plain table.
-- @treturn table the layout tree (see the class description for the shape)
function TabGroups:serialize()
	self:_captureActive()
	local children = self:_serializeStrip(self._root, 0)
	self:_mergeAbsent(children)
	return {
		version  = SCHEMA_VERSION,
		children = children,
	}
end

-- Put back the saved tabs whose extension did not load this session (an org pack
-- not installed yet, a plugin that failed), at the place they had. Without this,
-- one launch without the pack would save a layout that has forgotten them, and
-- the user's arrangement would be gone for good when the pack returns.
function TabGroups:_mergeAbsent(children)
	if not self._absent or #self._absent == 0 then return end
	local live = {}
	local function collect(nodes)
		for _, n in ipairs(nodes) do
			if n.t == "tab" then live[n.key] = true
			elseif n.t == "group" then collect(n.children) end
		end
	end
	collect(children)

	for _, entry in ipairs(self._absent) do
		if not live[entry.key] then
			local list = children
			for _, g in ipairs(entry.path) do
				local found
				for _, n in ipairs(list) do
					if n.t == "group" and n.name == g.name then found = n break end
				end
				if not found then
					found = { t = "group", name = g.name, source = g.source, active = g.active, children = {} }
					table.insert(list, math.min(g.index or #list + 1, #list + 1), found)
				end
				list = found.children
			end
			table.insert(list, math.min(entry.index, #list + 1), { t = "tab", key = entry.key })
			live[entry.key] = true
		end
	end
end

function TabGroups:_serializeStrip(strip, depth)
	local out = {}
	if depth > MAX_DEPTH then return out end
	for _, child in ipairs(self:_children(strip)) do
		local record = self:groupOf(child)
		if record then
			out[#out + 1] = {
				t        = "group",
				name     = record.name,
				source   = record.source,
				active   = record.active,
				children = self:_serializeStrip(child, depth + 1),
			}
		else
			local key = self:keyOf(child)
			if key then out[#out + 1] = { t = "tab", key = key } end
		end
	end
	return out
end

--- Persist the current layout to settings.
-- No-op before `restore` has run, so a partially built tree (extensions still
-- loading) can never overwrite the user's saved arrangement.
function TabGroups:save()
	if not self._settings or not self._restored then return end

	-- REFUSE to persist when internal attributes cannot be read back.
	--
	-- Every tab's layout key lives in an `_IUP`-prefixed attribute, and the iuplua
	-- binding filters those out on read (see core.lib.attr). Without the direct C
	-- read path, keyOf() returns nil for every page, serialize() emits a tree with
	-- the groups but none of their contents, and that gets written over a perfectly
	-- good saved arrangement -- so the user's tabs scatter to the root on the next
	-- launch and the arrangement they had is gone for good.
	--
	-- Losing the layout for one session is recoverable; overwriting the stored one
	-- with an empty shell is not. When the read path is unavailable this keeps the
	-- last known-good layout on disk and simply stops recording changes.
	if not self:_attrsReadable() then
		if not self._warned_no_attr then
			self._warned_no_attr = true
			local log = require("core.lib.log").get("tabgroups")
			log:warn("tab layout not saved: internal attributes do not survive a "
				.. "write/read round trip, so tab keys would be lost; the stored "
				.. "arrangement is left intact")
		end
		return
	end

	self._settings:set("tab_groups", self:serialize())
	pcall(function() self._settings:save() end)
end

--- Rebuild the saved layout, then file any unplaced tabs.
--
-- Called at startup after every extension has added its tabs and the host has
-- appended its own, ideally **before** `iup.Show` (pages are still unmapped then,
-- so the detach/reattach is cheap). It is also called again after
-- "Reload Extensions", which appends every reloaded tab back at the root — so
-- this is written to be safely repeatable: it first flattens the tree back to a
-- plain list of leaf pages and destroys the existing groups, then rebuilds.
--
-- Tabs the saved layout does not mention (a newly installed extension) are placed
-- from their manifest group hint when they have one, and otherwise appended at
-- the root in their existing order. Saved entries whose tab is no longer present
-- (an uninstalled extension) are dropped silently.
function TabGroups:restore()
	if not self._root then
		self._restored = true
		return
	end
	return self:_batch(function() self:_restore() end)
end

function TabGroups:_restore()
	local iup = self._iup

	-- Suppress persistence while the tree is in pieces; re-enabled at the end.
	self._restored = false

	local live = self:_flatten()
	local by_title = {}
	for _, widget in ipairs(live) do
		local ok, title = pcall(iup.GetAttribute, widget, "TABTITLE")
		if ok and title and title ~= "" and not by_title[title] then
			by_title[title] = widget
		end
	end

	local saved = self._settings and self._settings:get("tab_groups")
	if type(saved) == "table" and (tonumber(saved.version) or 1) < SCHEMA_VERSION then
		saved = nil   -- see SCHEMA_VERSION: pre-fix layouts are discarded, not migrated
	end
	if type(saved) ~= "table" or type(saved.children) ~= "table" or #saved.children == 0 then
		saved = self:_migrateLegacyOrder(by_title)
	end

	local placed = {}
	self._absent = {}
	self._holds_absent = {}   -- uid -> true for group strips with unloaded tabs
	if saved then
		self._live_index = live
		self:_restoreInto(self._root, saved.children, placed, 0, {})
		self._live_index = nil
	end

	-- Anything the saved tree did not claim, in one pass so relative order is kept:
	-- into its manifest-declared group when it has one, otherwise the root. Doing
	-- hints as a separate earlier pass would float every hinted extension's group
	-- ahead of the ungrouped tabs that loaded before it.
	for _, widget in ipairs(live) do
		if not placed[self:_uid(widget)] then
			self:_place(self:_hintTarget(widget) or self._root, widget)
			placed[self:_uid(widget)] = true
		end
	end

	self:_pruneEmptyGroups(self._root)
	self:_restoreActive(self._root, 0)
	self:_syncTitlesDeep(self._root, 0)
	self:_requestRefresh()

	self._restored = true
	self:save()
end

-- Re-apply position-indexed titles across the whole tree. restore() detaches and
-- re-attaches everything, so every strip's TABTITLE<pos> slots are stale.
function TabGroups:_syncTitlesDeep(strip, depth)
	if depth > MAX_DEPTH then return end
	self:_syncTitles(strip)
	for _, child in ipairs(self:_children(strip)) do
		if self:isGroupStrip(child) then self:_syncTitlesDeep(child, depth + 1) end
	end
end

-- Reduce the tree to a detached, ordered list of leaf pages and destroy every
-- group strip. Leaves are detached BEFORE the groups are destroyed, otherwise
-- destroying a group would take its members down with it.
function TabGroups:_flatten()
	local iup = self._iup
	local leaves = {}
	local function walk(strip, depth)
		if depth > MAX_DEPTH then return end
		for _, child in ipairs(self:_children(strip)) do
			if self:isGroupStrip(child) then
				walk(child, depth + 1)
			else
				leaves[#leaves + 1] = child
			end
		end
	end
	walk(self._root, 0)

	for _, widget in ipairs(leaves) do pcall(iup.Detach, widget) end
	-- Whatever is left at the root is a group strip (its members were just taken
	-- out), so destroy the lot. Destroying a strip takes its nested groups with
	-- it. Nothing else references them: group state lives on the widget, so there
	-- is no registry entry to leak or, worse, to be reused by a later group and
	-- silently shared -- which is exactly how the duplication bug worked.
	for _, child in ipairs(self:_children(self._root)) do
		pcall(iup.Detach, child)
		pcall(iup.Destroy, child)
	end
	return leaves
end

-- Append a page to a strip, remapping it when the window is already up (the
-- reload path runs post-show).
function TabGroups:_place(strip, widget)
	pcall(self._iup.Append, strip, widget)
	if self._shown then pcall(self._iup.Map, widget) end
	self:_applyHeightCap(widget)
end

function TabGroups:_restoreInto(strip, nodes, placed, depth, path)
	if depth > MAX_DEPTH then return end
	for index, node in ipairs(nodes or {}) do
		if type(node) == "table" then
			if node.t == "group" then
				local group_strip = self:createGroup(
					strip,
					node.name,
					node.source == "manifest" and "manifest" or "user"
				)
				if group_strip and type(node.active) == "string" then
					pcall(self._iup.SetAttribute, group_strip, ACTIVE_ATTR, node.active)
				end
				local sub = {}
				for i, g in ipairs(path) do sub[i] = g end
				-- Its position and selection too: a manifest group left empty is pruned
				-- from the live tree, and must come back where it was, not at the end.
				sub[#sub + 1] = {
					name = node.name, index = index, active = node.active,
					source = node.source == "manifest" and "manifest" or "user",
				}
				self:_restoreInto(group_strip, node.children, placed, depth + 1, sub)
			elseif node.t == "tab" and type(node.key) == "string" then
				local widget = self:_takeLive(node.key, placed)
				if widget then
					self:_place(strip, widget)
					placed[self:_uid(widget)] = true
				else
					-- Its extension isn't loaded this session: remember where it was.
					self._absent[#self._absent + 1] = { key = node.key, path = path, index = index }
					if not self:_same(strip, self._root) then self._holds_absent[self:_uid(strip)] = true end
				end
			end
		end
	end
end

-- `placed` is keyed by stable id, not by the handle: two handles for the same
-- widget are different Lua objects (core.lib.handle), so a handle-keyed set
-- would never register a hit and every tab would be placed twice.
function TabGroups:_takeLive(key, placed)
	for _, widget in ipairs(self._live_index or {}) do
		if not placed[self:_uid(widget)] and self:keyOf(widget) == key then
			return widget
		end
	end
	return nil
end

-- Turn the pre-groups `tab_order` setting (a comma-separated list of TABTITLEs)
-- into a flat layout tree, so an existing arrangement survives the upgrade.
-- Titles are matched rather than keys because keys did not exist before now.
function TabGroups:_migrateLegacyOrder(by_title)
	local legacy = self._settings and self._settings:get("tab_order")
	if type(legacy) ~= "string" or legacy == "" then return nil end
	local children = {}
	for title in legacy:gmatch("[^,]+") do
		local widget = by_title[title]
		local key = widget and self:keyOf(widget)
		if key then children[#children + 1] = { t = "tab", key = key } end
	end
	if #children == 0 then return nil end
	return { version = SCHEMA_VERSION, children = children }
end

-- Resolve a tab's manifest group hint to a strip, creating the group (and any
-- parent groups along a "Parent/Child" path) on demand. Returns nil when the tab
-- declares no group, so the caller can fall back to the root.
function TabGroups:_hintTarget(widget)
	local hint = attr.get(self._iup, widget, HINT_ATTR)
	if type(hint) ~= "string" or hint == "" then return nil end

	local strip = self._root
	for segment in hint:gmatch("[^/]+") do
		segment = segment:gsub("^%s+", ""):gsub("%s+$", "")
		if segment ~= "" then
			strip = self:_findOrCreateGroup(strip, segment)
		end
	end
	if self:_same(strip, self._root) then return nil end
	return strip
end

function TabGroups:_findOrCreateGroup(strip, name)
	for _, child in ipairs(self:_children(strip)) do
		local record = self:groupOf(child)
		if record and record.name == name then return child end
	end
	return self:createGroup(strip, name, "manifest")
end

function TabGroups:_pruneEmptyManifestGroups(strip, depth)
	depth = depth or 0
	if depth > MAX_DEPTH then return end
	local iup = self._iup
	local changed = false
	for _, child in ipairs(self:_children(strip)) do
		local record = self:groupOf(child)
		if record then
			self:_pruneEmptyManifestGroups(child, depth + 1)
			if #self:_children(child) == 0 and record.source == "manifest" then
				pcall(iup.Detach, child)
				pcall(iup.Destroy, child)
				changed = true
			end
		end
	end
	if changed then self:_syncTitles(strip) end
end

-- Re-select the member each group was left on. Runs after the tree is fully
-- rebuilt, because VALUEPOS on a strip that is still being populated does not
-- survive the appends that follow it.
-- After a restore: drop empty manifest groups, and user groups that are empty only
-- because their tabs didn't load this session (an org pack missing). The saved
-- layout keeps those (see _mergeAbsent), so they come back with their tabs. A
-- user group that was empty on purpose stays. Returns whether anything pruned
-- below held unloaded tabs, so a parent emptied by that goes too.
function TabGroups:_pruneEmptyGroups(strip, depth)
	depth = depth or 0
	if depth > MAX_DEPTH then return false end
	local iup = self._iup
	local held_any, changed = false, false
	for _, child in ipairs(self:_children(strip)) do
		local record = self:groupOf(child)
		if record then
			local held = self:_pruneEmptyGroups(child, depth + 1)
				or (self._holds_absent and self._holds_absent[self:_uid(child)]) or false
			if #self:_children(child) == 0 and (record.source == "manifest" or held) then
				pcall(iup.Detach, child)
				pcall(iup.Destroy, child)
				changed = true
				held_any = held_any or held
			end
		end
	end
	if changed then self:_syncTitles(strip) end
	return held_any
end

--- Move tabs into the group their hint names, whatever the saved layout says.
--
-- For an org pack's tool group the first time it applies on a machine (a layout
-- saved before tool groups existed keeps the org's tabs wherever they were).
-- Groups the moves leave empty are removed.
-- @tparam function filter `filter(widget, hint)`: true for tabs to move
-- @treturn number how many tabs matched (moved or already in place)
function TabGroups:applyHints(filter)
	if not self._root then return 0 end
	return self:_batch(function()
		local iup = self._iup
		local leaves = {}
		local function walk(strip, depth)
			if depth > MAX_DEPTH then return end
			for _, child in ipairs(self:_children(strip)) do
				if self:isGroupStrip(child) then walk(child, depth + 1) else leaves[#leaves + 1] = child end
			end
		end
		walk(self._root, 0)

		local matched, sources, seen = 0, {}, {}
		for _, widget in ipairs(leaves) do
			local hint = attr.get(iup, widget, HINT_ATTR)
			if type(hint) == "string" and hint ~= "" and filter(widget, hint) then
				matched = matched + 1
				local from, target = self:stripOf(widget), self:_hintTarget(widget)
				if from and target and not self:_same(from, target) and self:_moveInto(widget, target) then
					if self:isGroupStrip(from) and not seen[self:_uid(from)] then
						seen[self:_uid(from)] = true
						sources[#sources + 1] = from
					end
				end
			end
		end

		-- Deepest first, so a nested group goes before the parent it may empty.
		-- Uids are taken while each strip is alive; a destroyed one is never read.
		local depth_of, uid_of = {}, {}
		for _, s in ipairs(sources) do depth_of[s], uid_of[s] = self:depthOf(s), self:_uid(s) end
		table.sort(sources, function(a, b) return depth_of[a] > depth_of[b] end)
		local destroyed = {}
		for _, strip in ipairs(sources) do
			local s, uid = strip, uid_of[strip]
			while s and not destroyed[uid] and self:isGroupStrip(s) and #self:_children(s) == 0 do
				local parent = self:stripOf(s)
				local parent_uid = parent and self:_uid(parent)
				destroyed[uid] = true
				pcall(iup.Detach, s)
				pcall(iup.Destroy, s)
				if parent then self:_syncTitles(parent) end
				s, uid = parent, parent_uid
			end
		end
		self:_requestRefresh()
		self:_changed()
		return matched
	end)
end

function TabGroups:_restoreActive(strip, depth)
	depth = depth or 0
	if depth > MAX_DEPTH then return end
	for _, child in ipairs(self:_children(strip)) do
		local record = self:groupOf(child)
		if record then
			self:_restoreActive(child, depth + 1)
			if record.active then
				for i, member in ipairs(self:_children(child)) do
					if self:_memberKey(member) == record.active then
						pcall(self._iup.SetAttribute, child, "VALUEPOS", tostring(i - 1))
						break
					end
				end
			end
		end
	end
end

--- Tell the manager the window is up, so later structural changes remap widgets.
function TabGroups:markShown()
	self._shown = true
end

--- A human-readable dump of the live tab tree.
--
-- Exists because three separate bugs in this feature were invisible from the
-- outside: the strip looked wrong but nothing said *why*. This reports, per page,
-- what the host believes it is (class, group-or-tab, key, name) next to the label
-- the user can actually see — so a single screenshot distinguishes "the tree is
-- wrong" from "the tree is right and the labels are wrong".
--
-- @treturn string one line per page, indented by depth
function TabGroups:describe()
	local iup = self._iup
	local readable = self:_attrsReadable()

	-- Reported first, and loudly, because it is the single fact that determines
	-- whether anything below is trustworthy. Without the direct C read path the
	-- binding hides every `_IUP` attribute (core.lib.attr), so keys and group
	-- names come back nil, the tree reads as a pile of anonymous tabs, and saving
	-- is suppressed to avoid overwriting the stored layout with that.
	local lines = {
		"internal attributes readable : " .. tostring(readable)
			.. (readable and "" or "   <-- layout will NOT be saved this session"),
		"saved layout schema          : v" .. tostring(SCHEMA_VERSION),
		"window shown                 : " .. tostring(self._shown),
		"layout restored              : " .. tostring(self._restored),
		"",
		"root strip: " .. tostring(self:_uid(self._root)),
	}

	local function walk(strip, depth)
		if depth > MAX_DEPTH then return end
		local pad = string.rep("  ", depth + 1)
		for i, child in ipairs(self:_children(strip)) do
			local _, cls = pcall(iup.GetClassName, child)
			local _, shown_title = pcall(iup.GetAttributeId, strip, "TABTITLE", i - 1)
			local record = self:groupOf(child)
			lines[#lines + 1] = string.format(
				"%s[%d] %-10s %-6s label=%-24s %s",
				pad, i - 1,
				tostring(cls),
				record and "GROUP" or "tab",
				tostring(shown_title),
				record
					and string.format("name=%s source=%s active=%s",
						tostring(record.name), tostring(record.source), tostring(record.active))
					or ("key=" .. tostring(self:keyOf(child)))
			)
			if record then walk(child, depth + 1) end
		end
	end

	walk(self._root, 0)
	return table.concat(lines, "\n")
end

return TabGroups

-- spec/tab_groups_spec.lua — core.classes.TabGroups.
--
-- TabGroups keeps no Lua-side copy of the layout: membership, order, and group
-- metadata are all read back out of the IUP widget tree. These tests therefore
-- run against a mock that models IUP's tree semantics, because that tree IS the
-- thing under test.
--
-- The mock deliberately reproduces two IupFlatTabs behaviours that an obvious
-- mock gets wrong, and that shipped as bugs precisely because the first version
-- of this mock did get them wrong:
--
--   1. `TABTITLE` is NOT a property of the page. It is a position-indexed
--      attribute on the STRIP (`TABTITLE0`, `TABTITLE1`, ...).
--      `iFlatTabsChildAddedMethod` copies it off the child once, at attach time,
--      and only into a slot that has no title yet; `ChildRemovedMethod` shuffles
--      the remaining ones down. So setting TABTITLE on an attached page does
--      nothing, and a page can inherit the title of whatever used to sit in its
--      slot. Assertions here read the STRIP's indexed titles — what the user
--      actually sees — never the page's own attribute.
--   2. `IupGetAttribute` INHERITS. Any attribute the control's class does not
--      register is reported as inheritable (`*inherit = 1`, "default is
--      inheritable", iup_classattrib.c) and the lookup walks up the parent
--      chain. So a marker set on a group strip reads back as set on every page
--      inside it, and on every widget inside those. That is what turned a
--      grouped extension into a group, and what made ungrouping lift the
--      extension's own panels out as top-level tabs. Names beginning with `_IUP`
--      are internal and read local-only, which is the fix and is why every
--      attribute this host invents carries that prefix.
--
--      A mock without this is worse than no mock: the first version of these
--      tests asserted confidently against a widget tree that could not exhibit
--      the bug, and the suite stayed green through two shipped regressions.
--
-- The rest of the cases: unbounded nesting has to serialize/restore/resolve like
-- depth 1; moving a group into its own descendant would detach a subtree and lose
-- every tab in it; and "Reload Extensions" re-appends every tab at the root, so
-- restore() must be safely repeatable rather than a startup-only path.

local TabGroups = require("core.classes.TabGroups")

-- Layout schema the current code writes. Versions 1 and 2 were written by builds
-- that could persist a corrupt tree, so they are discarded rather than migrated.
local SCHEMA_VERSION_EXPECTED = 3

-- ---------------------------------------------------------------- mock IUP ---

-- Attributes IupFlatTabs stores per POSITION on the strip and shuffles on
-- add/remove (flattabs_attrib_id in iup_flattabs.c).
local ID_ATTRS = { "TABTITLE", "TABIMAGE", "TABVISIBLE", "TABACTIVE" }

local function make_iup()
	local iup = { DEFAULT = 0, BUTTON1 = 1 }

	local function widget(cls)
		return { cls = cls, attrs = {}, children = {} }
	end

	-- Every handle that crosses the C boundary comes back as a FRESH Lua object:
	-- `iuplua_pushihandle_raw` calls `lua_newuserdata` on every push, so
	-- `iup.GetChild(t, 0) == iup.GetChild(t, 0)` is FALSE for one and the same
	-- widget — while attributes and callbacks still resolve to that one widget
	-- underneath.
	--
	-- These proxies reproduce it. Without them every identity comparison in the
	-- code under test passes trivially in the suite and fails in the product,
	-- which is exactly what shipped: the "did this land on the tab being dragged"
	-- guard never fired, so a plain click on a tab wrapped it in a new group, and
	-- "don't move a group into itself" never fired either.
	--
	-- Only the accessors that return a handle hand out proxies; every function
	-- that touches state unwraps first, mirroring the C side operating on the one
	-- real `Ihandle*`.
	local backing = setmetatable({}, { __mode = "k" })

	local function real(w)
		if w == nil then return nil end
		return backing[w] or w
	end

	local function proxy(w)
		if w == nil then return nil end
		local p = setmetatable({}, { __index = w })
		backing[p] = w
		return p
	end

	function iup.SetAttribute(w, name, value)
		real(w).attrs[name] = value ~= nil and tostring(value) or nil
	end

	function iup.SetAttributeId(w, name, id, value)
		real(w).attrs[name .. tostring(id)] = value ~= nil and tostring(value) or nil
	end

	-- IupGetAttribute INHERITS. For any attribute the control's class does not
	-- register, iupClassObjectGetAttribute reports `inherit = 1` ("default is
	-- inheritable") and the lookup walks up the parent chain. Names starting with
	-- `_IUP` are internal and short-circuit to the local value only.
	--
	-- Modelling this is the whole point: without it, a mock happily reports that
	-- a marker set on a group strip is absent from the pages inside it, and the
	-- bug where grouping an extension turned the extension itself into a group --
	-- and ungrouping it lifted the extension's own panels out as tabs -- sails
	-- straight through the suite.
	local function is_internal(name)
		return name:sub(1, 4) == "_IUP"
	end

	function iup.GetAttribute(w, name)
		local cur = real(w)
		if is_internal(name) then return cur.attrs[name] end
		while cur do
			local v = cur.attrs[name]
			if v ~= nil then return v end
			cur = cur.parent
		end
		return nil
	end

	-- iFlatTabsChildAddedMethod: shift the indexed attributes up from the
	-- insertion point, then adopt the child's own value ONLY into an empty slot.
	local function child_added(strip, child, pos)
		strip, child = real(strip), real(child)
		if strip.cls ~= "flattabs" then return end
		for p = #strip.children - 1, pos + 1, -1 do
			for _, a in ipairs(ID_ATTRS) do
				strip.attrs[a .. p] = strip.attrs[a .. (p - 1)]
				strip.attrs[a .. (p - 1)] = nil
			end
		end
		for _, a in ipairs(ID_ATTRS) do
			if strip.attrs[a .. pos] == nil and child.attrs[a] then
				strip.attrs[a .. pos] = child.attrs[a]
			end
		end
	end

	-- iFlatTabsChildRemovedMethod: shift the indexed attributes back down.
	local function child_removed(strip, pos)
		strip = real(strip)
		if strip.cls ~= "flattabs" then return end
		local count = #strip.children
		for p = pos, count - 1 do
			for _, a in ipairs(ID_ATTRS) do
				strip.attrs[a .. p] = strip.attrs[a .. (p + 1)]
				strip.attrs[a .. (p + 1)] = nil
			end
		end
		if pos == count then
			for _, a in ipairs(ID_ATTRS) do strip.attrs[a .. pos] = nil end
		end
	end

	-- IupDetach opens with IupUnmap, which DESTROYS the native window of the
	-- widget and of everything under it (iup_childtree.c). That is the single most
	-- expensive thing this class can do to a page -- an extension's whole control
	-- tree is thrown away and rebuilt -- so the mock models it: `mapped` goes
	-- false all the way down, and `builds` counts how many times a widget has had
	-- to be constructed. A move that leaves either untouched kept its windows.
	local function unmap(w)
		w.mapped = false
		for _, c in ipairs(w.children) do unmap(c) end
	end

	function iup.Detach(child)
		child = real(child)
		unmap(child)
		local parent = child.parent
		if not parent then return end
		for i = #parent.children, 1, -1 do
			if parent.children[i] == child then
				table.remove(parent.children, i)
				child.parent = nil
				child_removed(parent, i - 1)
				return
			end
		end
	end

	-- IupReparent: the same tree surgery and the same ChildRemoved/ChildAdded
	-- class methods as detach + insert, but no unmap -- the native side is told
	-- with a SetParent instead. Returns IUP_NOERROR (0) or IUP_ERROR (1).
	function iup.Reparent(child, parent, ref)
		child, parent, ref = real(child), real(parent), real(ref)
		if not child.parent then return 1 end
		-- "can not be at the same place" (iup_childtree.c)
		if child.parent == parent
			and (ref == child or (ref == nil and parent.children[#parent.children] == child)) then
			return 1
		end
		-- both must be mapped or both unmapped
		if (child.mapped and not parent.mapped) or (parent.mapped and not child.mapped) then
			return 1
		end

		local old = child.parent
		for i = #old.children, 1, -1 do
			if old.children[i] == child then
				table.remove(old.children, i)
				child.parent = nil
				child_removed(old, i - 1)
				break
			end
		end

		if ref then
			for i, c in ipairs(parent.children) do
				if c == ref then
					table.insert(parent.children, i, child)
					child.parent = parent
					child_added(parent, child, i - 1)
					return 0
				end
			end
		end
		parent.children[#parent.children + 1] = child
		child.parent = parent
		child_added(parent, child, #parent.children - 1)
		return 0
	end

	function iup.Append(parent, child)
		parent, child = real(parent), real(child)
		if child.parent then iup.Detach(child) end
		parent.children[#parent.children + 1] = child
		child.parent = parent
		child_added(parent, child, #parent.children - 1)
	end

	function iup.Insert(parent, ref, child)
		parent, ref, child = real(parent), real(ref), real(child)
		if child.parent then iup.Detach(child) end
		for i, c in ipairs(parent.children) do
			if c == ref then
				table.insert(parent.children, i, child)
				child.parent = parent
				child_added(parent, child, i - 1)
				return
			end
		end
		iup.Append(parent, child)
	end

	function iup.Destroy(w)
		w = real(w)
		w.destroyed = true
		for _, c in ipairs(w.children) do iup.Destroy(c) end
		w.children = {}
	end

	function iup.GetChild(parent, index)
		return proxy(real(parent).children[index + 1])
	end

	function iup.GetParent(w)
		return proxy(real(w).parent)
	end

	function iup.GetAttributeHandle(w, name)
		w = real(w)
		if name ~= "VALUE" then return nil end
		return proxy(w.children[(tonumber(w.attrs.VALUEPOS) or 0) + 1])
	end

	function iup.flattabs(def)
		local w = widget("flattabs")
		for _, child in ipairs(def or {}) do iup.Append(w, child) end
		for k, v in pairs(def or {}) do
			if type(k) == "string" then w.attrs[k] = tostring(v) end
		end
		return w
	end

	function iup.GetClassName(w)
		return real(w).cls
	end

	function iup.Map(w)
		w = real(w)
		if w.mapped then return end   -- IupMap returns immediately when mapped
		w.builds = (w.builds or 0) + 1
		w.mapped = true
		for _, c in ipairs(w.children) do iup.Map(c) end
	end

	-- Counted, because collapsing the four full-dialog layout passes a single drag
	-- used to trigger into one is half of what makes the move seamless. IupRefresh
	-- lays out the whole DIALOG whatever widget it is handed, so every call here is
	-- the same work no matter the argument.
	iup.refreshes = 0
	function iup.Refresh() iup.refreshes = iup.refreshes + 1 end

	function iup.timer(def) return widget("timer", def) end

	iup._widget = widget
	-- Tests must unwrap before comparing handles, for the same reason the code
	-- under test must: two handles for one widget are different Lua objects.
	iup._real = real
	return iup
end

local function make_settings(seed)
	local data = seed or {}
	return {
		get = function(_, key) return data[key] end,
		set = function(_, key, value) data[key] = value end,
		save = function() end,
		_data = data,
	}
end

-- A page as HostAPI:addTab would leave it: tagged with a stable layout key and,
-- optionally, a manifest-declared default group.
local function make_tab(iup, key, title, hint)
	local w = iup._widget("vbox")
	iup.SetAttribute(w, "_IUPLUNAR_TABKEY", key)
	iup.SetAttribute(w, "TABTITLE", title or key)
	if hint then iup.SetAttribute(w, "_IUPLUNAR_GROUPHINT", hint) end
	return w
end

local function make_groups(iup, root, settings)
	return TabGroups:new({
		iup = iup,
		root_strip = root,
		settings = settings,
	})
end

-- The titles the user actually sees: the STRIP's position-indexed attributes,
-- not the pages' own. Reading the pages instead is what let the rename bug and
-- the title-inheritance bug through.
local function titles(strip)
	local out = {}
	for i = 1, #strip.children do
		out[i] = strip.attrs["TABTITLE" .. (i - 1)]
	end
	return out
end

-- Compact, comparable shape of a strip: nested arrays of keys and group names.
local function shape(groups, strip)
	local out = {}
	local i = 0
	while true do
		local child = strip.children[i + 1]
		if not child then break end
		local record = groups:groupOf(child)
		if record then
			out[#out + 1] = { group = record.name, children = shape(groups, child) }
		else
			out[#out + 1] = groups:keyOf(child)
		end
		i = i + 1
	end
	return out
end

-- --------------------------------------------------------------- the tests ---

describe("TabGroups", function()
	local iup, root, settings, groups

	before_each(function()
		iup = make_iup()
		root = iup.flattabs({})
		settings = make_settings()
		groups = make_groups(iup, root, settings)
		groups:restore()   -- establishes the "loaded, nothing saved" baseline
	end)

	local function add(key, title, hint)
		local w = make_tab(iup, key, title, hint)
		iup.Append(root, w)
		return w
	end

	-- ---------------------------------------------------------- seamlessness ---
	--
	-- Every case below is about the COST of a move, not its result, and each one
	-- was a visible defect: dragging a tab blanked and rebuilt the window for the
	-- best part of a second, as if the app had reloaded, even though nothing but a
	-- position had changed.
	--
	-- Two things caused it, and both are asserted here rather than left to
	-- inspection, because both are invisible from the outside once fixed and
	-- trivially reintroduced by a well-meaning `iup.Detach` on the move path:
	--
	--   1. IupDetach unmaps, and unmapping DESTROYS every native window under the
	--      page. Re-attaching rebuilds an extension's entire control tree.
	--   2. IupRefresh lays out the whole dialog. A single drag issued four of
	--      them, interleaved with the surgery, so the user watched the app
	--      reassemble itself in stages.
	describe("moving without rebuilding", function()
		-- The state after startup: window shown, every page mapped.
		local function shown(...)
			local pages = { ... }
			groups:markShown()
			iup.Map(root)
			for _, p in ipairs(pages) do iup.Map(p) end
			iup.refreshes = 0
			return pages
		end

		local function page_with_content(key, title)
			local page = make_tab(iup, key, title)
			local body = iup._widget("vbox")
			iup.Append(page, body)
			iup.Append(body, iup._widget("flatlist"))
			iup.Append(root, page)
			return page, body
		end

		it("reorders a tab without rebuilding it", function()
			local a = add("a/1", "Alpha")
			local b = add("b/1", "Bravo")
			add("c/1", "Charlie")
			shown(a, b)
			local built = iup._real(a).builds

			-- Alpha dropped past the last tab: the append path, where IupReparent's
			-- "already in that place" refusal is the one that has to be read as
			-- success rather than as a reason to fall back to detach.
			assert.is_true(groups:moveInto(a, root, 4))

			assert.are.same({ "b/1", "c/1", "a/1" }, shape(groups, root))
			assert.is_true(iup._real(a).mapped)
			assert.are.equal(built, iup._real(a).builds)
		end)

		it("keeps an extension page's whole widget tree alive across a move", function()
			local page, body = page_with_content("bq/1", "Build Queue")
			local g = groups:createGroup(root, "Diagnostics")
			shown(page)
			local built = iup._real(body).builds

			assert.is_true(groups:moveInto(page, g))

			-- The page's contents were never torn down, so nothing had to be
			-- reconstructed and there is nothing for the user to watch redraw.
			assert.is_true(iup._real(body).mapped)
			assert.is_true(iup._real(body).children[1].mapped)
			assert.are.equal(built, iup._real(body).builds)
		end)

		it("lays the dialog out once per move, not once per internal edit", function()
			local a, b = add("a/1", "Alpha"), add("b/1", "Bravo")
			local g = groups:createGroup(root, "Diagnostics")
			shown(a, b)

			groups:moveInto(b, g)

			-- Two strips re-titled plus the move itself; one layout pass covers all
			-- three, because they all compute the same answer.
			assert.are.equal(1, iup.refreshes)
		end)

		it("lays the dialog out once for a merge, which is three edits", function()
			local a, b = add("a/1", "Alpha"), add("b/1", "Bravo")
			shown(a, b)

			groups:groupTogether(a, b, "Pair")

			assert.are.same({ { group = "Pair", children = { "a/1", "b/1" } } },
				shape(groups, root))
			assert.are.equal(1, iup.refreshes)
		end)

		it("saves and re-scopes once for a merge, not once per edit", function()
			local a, b = add("a/1", "Alpha"), add("b/1", "Bravo")
			local scopes = 0
			groups._on_change = function() scopes = scopes + 1 end
			shown(a, b)

			groups:groupTogether(a, b, "Pair")

			assert.are.equal(1, scopes)
		end)

		it("keeps a dissolved group's members mapped as they are lifted out", function()
			local a = add("a/1", "Alpha")
			local g = groups:createGroup(root, "Diagnostics")
			groups:moveInto(a, g)
			shown(a)
			local built = iup._real(a).builds

			assert.is_true(groups:dissolveGroup(g))

			assert.are.same({ "a/1" }, shape(groups, root))
			assert.is_true(iup._real(a).mapped)
			assert.are.equal(built, iup._real(a).builds)
		end)
	end)

	it("moves a tab into a group and reports it in the layout", function()
		local a, b = add("a/1", "Alpha"), add("b/1", "Bravo")
		local g = groups:createGroup(root, "Diagnostics")

		assert.is_true(groups:moveInto(b, g))

		assert.are.same({ "a/1", { group = "Diagnostics", children = { "b/1" } } },
			shape(groups, root))
		assert.equals(root, iup._real(groups:stripOf(a)))
		assert.equals(g, iup._real(groups:stripOf(b)))
	end)

	it("groups two tabs together in place of the first", function()
		add("a/1", "Alpha")
		local b, c = add("b/1", "Bravo"), add("c/1", "Charlie")

		groups:groupTogether(b, c, "Pair")

		-- The new group takes Bravo's slot, and Charlie follows it in.
		assert.are.same({ "a/1", { group = "Pair", children = { "b/1", "c/1" } } },
			shape(groups, root))
	end)

	it("nests groups arbitrarily deep", function()
		local t = add("deep/1", "Deep")
		local one = groups:createGroup(root, "One")
		local two = groups:createGroup(one, "Two")
		local three = groups:createGroup(two, "Three")
		groups:moveInto(t, three)

		assert.equals(3, groups:depthOf(three))
		assert.are.same({
			{ group = "One", children = {
				{ group = "Two", children = {
					{ group = "Three", children = { "deep/1" } },
				} },
			} },
		}, shape(groups, root))
	end)

	it("resolves the active leaf through nested strips", function()
		local t = add("deep/1", "Deep")
		local one = groups:createGroup(root, "One")
		local two = groups:createGroup(one, "Two")
		groups:moveInto(t, two)

		assert.is_true(groups:reveal(t))
		assert.equals(t, iup._real(groups:activeLeaf()))
	end)

	it("returns no active leaf for an empty group", function()
		groups:createGroup(root, "Empty")
		iup.SetAttribute(root, "VALUEPOS", "0")
		assert.is_nil(groups:activeLeaf())
	end)

	it("refuses to move a group into its own descendant", function()
		local outer = groups:createGroup(root, "Outer")
		local inner = groups:createGroup(outer, "Inner")

		-- Allowing this would detach Outer (and Inner, and everything in them)
		-- from the tree entirely.
		assert.is_false(groups:moveInto(outer, inner))
		assert.is_false(groups:moveInto(outer, outer))
		assert.equals(root, iup._real(groups:stripOf(outer)))
		assert.equals(outer, iup._real(groups:stripOf(inner)))
	end)

	it("corrects the index when reordering rightwards within a strip", function()
		local a = add("a/1", "Alpha")
		add("b/1", "Bravo")
		add("c/1", "Charlie")

		-- "Insert before Charlie" measured against the strip as the user sees it;
		-- removing Alpha first shifts Charlie down one, so a naive index lands short.
		groups:moveInto(a, root, 3)

		assert.are.same({ "b/1", "a/1", "c/1" }, shape(groups, root))
	end)

	it("dissolves a group back into its parent, in place", function()
		add("a/1", "Alpha")
		local b, c = add("b/1", "Bravo"), add("c/1", "Charlie")
		local g = groups:groupTogether(b, c, "Pair")

		assert.is_true(groups:dissolveGroup(g))
		assert.are.same({ "a/1", "b/1", "c/1" }, shape(groups, root))
	end)

	describe("attribute inheritance", function()
		-- The shipped bug, and the worst of them. IUP inherits unregistered
		-- attributes down the widget tree, so the "this page is a group" marker
		-- set on a group strip was read back as TRUE for the extension pages
		-- inside it, and for the widgets inside those. Grouping an extension made
		-- the extension itself look like a group; ungrouping then walked into the
		-- extension's own layout and lifted its panels out as top-level tabs.
		--
		-- These pages carry realistic inner content so the walk has something to
		-- wrongly harvest.
		local function add_rich(key, title)
			local page = make_tab(iup, key, title)
			local toolbar = iup._widget("hbox")
			local body = iup._widget("vbox")
			iup.Append(page, toolbar)
			iup.Append(page, body)
			iup.Append(body, iup._widget("flatlist"))
			iup.Append(root, page)
			return page, toolbar, body
		end

		it("does not turn a grouped extension page into a group", function()
			local page = add_rich("bq/1", "Build Queue")
			local g = groups:createGroup(root, "ROM QA Validation")

			groups:moveInto(page, g)

			assert.is_false(groups:isGroupStrip(page))
			assert.is_nil(groups:groupOf(page))
			assert.are.same({ { group = "ROM QA Validation", children = { "bq/1" } } },
				shape(groups, root))
		end)

		it("does not treat an extension's inner widgets as tabs", function()
			local page, toolbar = add_rich("bq/1", "Build Queue")
			local g = groups:createGroup(root, "ROM QA Validation")
			groups:moveInto(page, g)

			assert.is_false(groups:isGroupStrip(toolbar))
			-- restore() walks the tree to flatten it; if the page reads as a group
			-- it recurses inside and harvests the toolbar and body as "leaves".
			groups:restore()

			assert.are.same({ { group = "ROM QA Validation", children = { "bq/1" } } },
				shape(groups, root))
			assert.are.equal(page, toolbar.parent)
		end)

		it("keeps the extension intact when its group is dissolved", function()
			local page, toolbar, body = add_rich("bq/1", "Build Queue")
			local g = groups:createGroup(root, "ROM QA Validation")
			groups:moveInto(page, g)

			groups:dissolveGroup(g)

			assert.are.same({ "bq/1" }, shape(groups, root))
			assert.are.equal(root, page.parent)
			assert.are.equal(page, toolbar.parent)
			assert.are.equal(page, body.parent)
		end)

		it("does not leak a group's key or hint onto the pages inside it", function()
			local page = add_rich("bq/1", "Build Queue")
			local nested = groups:createGroup(root, "Outer")
			groups:moveInto(page, nested)

			-- A nested group must not inherit its parent's identity either.
			local inner = groups:createGroup(nested, "Inner")
			assert.are.equal("Inner", groups:groupOf(inner).name)
			assert.are.equal("Outer", groups:groupOf(nested).name)
			assert.are.equal("bq/1", groups:keyOf(page))
			assert.is_nil(groups:keyOf(inner))
		end)
	end)

	describe("unreadable internal attributes", function()
		-- Every tab's layout key lives in an `_IUP`-prefixed attribute, and the
		-- iuplua binding filters those out on read (core.lib.attr). Without the
		-- direct C read path keyOf() returns nil for every page, so serialize()
		-- produces the groups with none of their contents. Writing THAT over a good
		-- saved arrangement is unrecoverable -- the user's tabs scatter to the root
		-- on the next launch and the layout they had is gone.
		--
		-- Losing the layout for a session is acceptable; destroying the stored one
		-- is not. save() must decline rather than write a shell.
		-- Simulating the real failure: writes still succeed, reads come back nil.
		-- That is precisely what the iuplua binding does with `_IUP` names, and it
		-- is why the guard probes a write/read round trip rather than asking
		-- whether some particular read mechanism is present.
		local attr = require("core.lib.attr")
		local real_get

		before_each(function()
			real_get = attr.get
		end)

		after_each(function()
			attr.get = real_get
		end)

		local function blind()
			attr.get = function() return nil end
		end

		it("does not overwrite the stored layout when keys cannot be read", function()
			local a = add("a/1", "Alpha")
			local g = groups:createGroup(root, "Tools")
			groups:moveInto(a, g)
			local good = settings:get("tab_groups")
			assert.is_truthy(good)
			-- The tab is recorded inside the group, not just the group itself.
			assert.are.same({ { t = "tab", key = "a/1" } }, good.children[1].children)

			groups._attrs_readable = nil   -- re-probe
			blind()
			groups:createGroup(root, "Made While Blind")
			groups:save()

			-- Byte-for-byte the arrangement from before the read path failed.
			assert.are.same(good, settings:get("tab_groups"))
		end)

		it("resumes saving once the read path is available again", function()
			groups._attrs_readable = nil
			blind()
			add("a/1", "Alpha")
			groups:save()

			attr.get = real_get
			groups._attrs_readable = nil
			local a = add("b/1", "Bravo")
			local g = groups:createGroup(root, "Tools")
			groups:moveInto(a, g)

			local saved = settings:get("tab_groups")
			assert.are.same({ { t = "tab", key = "b/1" } },
				saved.children[#saved.children].children)
		end)

		it("reports the read path in the diagnostics dump", function()
			assert.is_truthy(groups:describe():match("internal attributes readable : true"))

			groups._attrs_readable = nil
			blind()
			local text = groups:describe()
			assert.is_truthy(text:match("internal attributes readable : false"))
			-- and says what that costs, so the dump is actionable on its own
			assert.is_truthy(text:match("will NOT be saved"))
		end)
	end)

	describe("tab bar labels", function()
		it("shows a renamed group's new name", function()
			local g = groups:createGroup(root, "Group 1")

			assert.is_true(groups:renameGroup(g, "Diagnostics"))

			-- The strip owns the title. Asserting on the page's own TABTITLE would
			-- have passed even while the bar still read "Group 1".
			assert.are.same({ "Diagnostics" }, titles(root))
		end)

		it("keeps labels aligned with tabs after a reorder", function()
			local a = add("a/1", "Alpha")
			add("b/1", "Bravo")
			add("c/1", "Charlie")

			groups:moveInto(a, root, 3)

			-- Alpha lands in a slot Bravo/Charlie occupied; IUP's one-shot title
			-- copy would leave the old occupant's label there.
			assert.are.same({ "Bravo", "Alpha", "Charlie" }, titles(root))
		end)

		it("keeps labels aligned when a tab leaves for a group", function()
			add("a/1", "Alpha")
			local b = add("b/1", "Bravo")
			local g = groups:createGroup(root, "Tools")

			groups:moveInto(b, g)

			assert.are.same({ "Alpha", "Tools" }, titles(root))
			assert.are.same({ "Bravo" }, titles(g))
		end)

		it("restores labels for the whole tree", function()
			local a = add("a/1", "Alpha")
			add("b/1", "Bravo")
			local g = groups:createGroup(root, "Tools")
			groups:moveInto(a, g)

			groups:restore()

			assert.are.same({ "Bravo", "Tools" }, titles(root))
			local restored_group = root.children[2]
			assert.are.same({ "Alpha" }, titles(restored_group))
		end)
	end)

	describe("persistence", function()
		it("round-trips a nested layout through save and restore", function()
			local a, b = add("a/1", "Alpha"), add("b/1", "Bravo")
			local outer = groups:createGroup(root, "Outer")
			local inner = groups:createGroup(outer, "Inner")
			groups:moveInto(a, inner)
			groups:moveInto(b, outer)
			local expected = shape(groups, root)

			-- Rebuild from scratch against the same settings, as a relaunch would.
			local iup2 = make_iup()
			local root2 = iup2.flattabs({})
			local groups2 = TabGroups:new({ iup = iup2, root_strip = root2, settings = settings })
			-- Tabs arrive at the root in load order, before restore runs.
			for _, key in ipairs({ "a/1", "b/1" }) do
				local w = make_tab(iup2, key, key)
				iup2.Append(root2, w)
			end
			groups2:restore()

			assert.are.same(expected, shape(groups2, root2))
		end)

		it("drops saved entries whose extension is no longer installed", function()
			local a = add("a/1", "Alpha")
			local g = groups:createGroup(root, "Tools")
			groups:moveInto(a, g)

			local iup2 = make_iup()
			local root2 = iup2.flattabs({})
			local groups2 = TabGroups:new({ iup = iup2, root_strip = root2, settings = settings })
			iup2.Append(root2, make_tab(iup2, "other/1", "Other"))
			groups2:restore()

			-- The missing tab is gone from the screen, and so is the group it left
			-- empty; the saved layout keeps both for when it returns (below).
			assert.are.same({ "other/1" }, shape(groups2, root2))
		end)

		it("keeps a missing extension's place so it returns there when reinstalled", function()
			local a, b = add("a/1", "Alpha"), add("b/1", "Bravo")
			local g = groups:createGroup(root, "Tools")
			groups:moveInto(a, g)
			groups:moveInto(b, g)

			-- Launch without extension "a" (e.g. its org pack isn't installed yet).
			local iup2 = make_iup()
			local root2 = iup2.flattabs({})
			local groups2 = TabGroups:new({ iup = iup2, root_strip = root2, settings = settings })
			iup2.Append(root2, make_tab(iup2, "b/1", "Bravo"))
			groups2:restore()
			assert.are.same({ { group = "Tools", children = { "b/1" } } }, shape(groups2, root2))

			-- That launch saved, yet the stored layout still knows where "a" went.
			local stored = settings:get("tab_groups")
			assert.are.same({ { t = "tab", key = "a/1" }, { t = "tab", key = "b/1" } }, stored.children[1].children)

			-- Next launch has "a" back: it lands in its group, in its old position.
			local iup3 = make_iup()
			local root3 = iup3.flattabs({})
			local groups3 = TabGroups:new({ iup = iup3, root_strip = root3, settings = settings })
			iup3.Append(root3, make_tab(iup3, "b/1", "Bravo"))
			iup3.Append(root3, make_tab(iup3, "a/1", "Alpha"))
			groups3:restore()
			assert.are.same({ { group = "Tools", children = { "a/1", "b/1" } } }, shape(groups3, root3))
		end)

		it("hides a group whose tabs are all missing this session, but remembers it", function()
			local a = add("a/1", "Alpha")
			local g = groups:createGroup(root, "Pack")
			groups:moveInto(a, g)

			local iup2 = make_iup()
			local root2 = iup2.flattabs({})
			local groups2 = TabGroups:new({ iup = iup2, root_strip = root2, settings = settings })
			iup2.Append(root2, make_tab(iup2, "other/1", "Other"))
			groups2:restore()
			groups2:save()

			-- No empty "Pack" on screen...
			assert.are.same({ "other/1" }, shape(groups2, root2))
			-- ...but the saved layout still has it, with its tab.
			local found
			for _, n in ipairs(settings:get("tab_groups").children) do
				if n.t == "group" and n.name == "Pack" then found = n end
			end
			assert.is_truthy(found)
			assert.are.equal("user", found.source)
			assert.are.same({ { t = "tab", key = "a/1" } }, found.children)

			-- And it comes back when the tab does.
			local iup3 = make_iup()
			local root3 = iup3.flattabs({})
			local groups3 = TabGroups:new({ iup = iup3, root_strip = root3, settings = settings })
			iup3.Append(root3, make_tab(iup3, "other/1", "Other"))
			iup3.Append(root3, make_tab(iup3, "a/1", "Alpha"))
			groups3:restore()
			assert.are.same({ { group = "Pack", children = { "a/1" } }, "other/1" }, shape(groups3, root3))
		end)

		it("keeps a user group that is empty on purpose", function()
			add("other/1", "Other")
			groups:createGroup(root, "Later")
			groups:save()

			local iup2 = make_iup()
			local root2 = iup2.flattabs({})
			local groups2 = TabGroups:new({ iup = iup2, root_strip = root2, settings = settings })
			iup2.Append(root2, make_tab(iup2, "other/1", "Other"))
			groups2:restore()
			assert.are.same({ "other/1", { group = "Later", children = {} } }, shape(groups2, root2))
		end)

		it("keeps the position of a manifest group whose extension is missing", function()
			local a = add("a/1", "Alpha")
			local g = groups:createGroup(root, "Tools", "manifest")
			groups:moveInto(a, g)
			add("other/1", "Other")
			-- Tools first, then Other.
			groups:save()
			assert.are.equal("group", settings:get("tab_groups").children[1].t)

			-- Without "a" the manifest group is pruned from the live tree, but the saved
			-- layout puts it back where it was, ahead of "other/1".
			local iup2 = make_iup()
			local root2 = iup2.flattabs({})
			local groups2 = TabGroups:new({ iup = iup2, root_strip = root2, settings = settings })
			iup2.Append(root2, make_tab(iup2, "other/1", "Other"))
			groups2:restore()
			local stored = settings:get("tab_groups").children
			assert.are.equal("Tools", stored[1].name)
			assert.are.equal("manifest", stored[1].source)
			assert.are.same({ t = "tab", key = "other/1" }, stored[2])
		end)

		it("is repeatable, as the extension-reload path needs", function()
			local a = add("a/1", "Alpha")
			local g = groups:createGroup(root, "Tools")
			groups:moveInto(a, g)
			local expected = shape(groups, root)

			-- A reload leaves the tab back at the root; restore has to put it back
			-- without duplicating the group it was in.
			iup.Detach(a)
			iup.Append(root, a)
			groups:restore()

			assert.are.same(expected, shape(groups, root))
		end)

		it("does not duplicate or nest groups across repeated launches", function()
			-- The shipped regression. Two groups turned into a growing nest of
			-- identically-named duplicates on every restart, because group state
			-- lived in a registry keyed by an id whose counter was reseeded from
			-- the saved layout: ids repeated, two live strips shared one record,
			-- and tearing one down unregistered the other.
			--
			-- Persistence goes through real JSON here, as SettingsManager does —
			-- a mock that hands the Lua table straight back cannot catch an
			-- encoding-shape problem.
			local cjson = require("cjson")
			local blob

			local function launch(mutate)
				local iup2 = make_iup()
				local root2 = iup2.flattabs({})
				for _, spec in ipairs({
					{ "buildqueue/1", "Build Queue" }, { "inventory/1", "Inventory" },
					{ "logparser/1", "Log Parser" }, { "host/settings", "Settings" },
				}) do
					iup2.Append(root2, make_tab(iup2, spec[1], spec[2]))
				end
				local data = blob and cjson.decode(blob) or {}
				local store = {
					get = function(_, k) return data[k] end,
					set = function(_, k, v) data[k] = v end,
					save = function() blob = cjson.encode(data) end,
				}
				local g2 = TabGroups:new({ iup = iup2, root_strip = root2, settings = store })
				g2:restore()
				if mutate then mutate(g2, root2, iup2) end
				store.save()
				return g2, root2
			end

			launch(function(g2, root2, iup2)
				local function find(key)
					for _, c in ipairs(root2.children) do
						if iup2.GetAttribute(c, "_IUPLUNAR_TABKEY") == key then return c end
					end
				end
				local rom = g2:createGroup(root2, "ROM QA Validation")
				g2:moveInto(find("buildqueue/1"), rom)
				g2:moveInto(find("logparser/1"), rom)
				local dev = g2:createGroup(root2, "Device Tools")
				g2:moveInto(find("inventory/1"), dev)
			end)

			local expected = {
				"host/settings",
				{ group = "ROM QA Validation", children = { "buildqueue/1", "logparser/1" } },
				{ group = "Device Tools", children = { "inventory/1" } },
			}

			for _ = 1, 4 do
				local g2, root2 = launch()
				assert.are.same(expected, shape(g2, root2))
			end
		end)

		it("discards a layout written by a build with the duplication bug", function()
			-- A version-1 or -2 layout may already describe a nest of duplicated
			-- groups, so restoring it faithfully would preserve the corruption.
			-- Users get a clean strip instead of hand-editing settings.json.
			local stale = make_settings({
				tab_groups = {
					version = 2,
					children = {
						{ t = "group", name = "ROM QA Validation", source = "user",
						  children = {
							{ t = "group", name = "ROM QA Validation", source = "user", children = {} },
							{ t = "group", name = "ROM QA Validation", source = "user", children = {} },
						  } },
						{ t = "tab", key = "a/1" },
					},
				},
			})
			local iup2 = make_iup()
			local root2 = iup2.flattabs({})
			iup2.Append(root2, make_tab(iup2, "a/1", "Alpha"))
			local groups2 = TabGroups:new({ iup = iup2, root_strip = root2, settings = stale })

			groups2:restore()

			assert.are.same({ "a/1" }, shape(groups2, root2))
			assert.are.equal(SCHEMA_VERSION_EXPECTED, stale:get("tab_groups").version)
		end)

		it("migrates the pre-groups tab_order setting by title", function()
			local legacy = make_settings({ tab_order = "Charlie,Alpha,Bravo" })
			local iup2 = make_iup()
			local root2 = iup2.flattabs({})
			local groups2 = TabGroups:new({ iup = iup2, root_strip = root2, settings = legacy })
			for _, spec in ipairs({ { "a/1", "Alpha" }, { "b/1", "Bravo" }, { "c/1", "Charlie" } }) do
				iup2.Append(root2, make_tab(iup2, spec[1], spec[2]))
			end
			groups2:restore()

			assert.are.same({ "c/1", "a/1", "b/1" }, shape(groups2, root2))
		end)
	end)

	describe("manifest group hints", function()
		it("files a new tab into the group its manifest declares, nesting on /", function()
			add("a/1", "Alpha")
			add("p/1", "Parser", "Tools/Parsers")
			groups:restore()

			assert.are.same({
				"a/1",
				{ group = "Tools", children = {
					{ group = "Parsers", children = { "p/1" } },
				} },
			}, shape(groups, root))
		end)

		it("does not override an arrangement the user already made", function()
			local p = add("p/1", "Parser", "Tools")
			groups:restore()
			-- User pulls it back out to the top level; that is what gets saved.
			groups:moveInto(p, root)

			local iup2 = make_iup()
			local root2 = iup2.flattabs({})
			local groups2 = TabGroups:new({ iup = iup2, root_strip = root2, settings = settings })
			iup2.Append(root2, make_tab(iup2, "p/1", "Parser", "Tools"))
			groups2:restore()

			assert.are.same({ "p/1" }, shape(groups2, root2))
		end)

		it("applyHints moves hinted tabs out of an older arrangement and drops the emptied group", function()
			-- A layout from before tool groups: the user's own group holds the org's tools.
			local a, b = add("a/1", "Alpha", "Org Tools"), add("b/1", "Bravo", "Org Tools/Sub")
			local c, d = add("c/1", "Charlie"), add("d/1", "Delta", "Org Tools")
			groups:restore()
			local mine = groups:createGroup(root, "ORG TOOLS (mine)")
			groups:moveInto(a, mine)
			groups:moveInto(b, mine)
			groups:moveInto(c, mine)
			local old = groups:createGroup(root, "Only org")
			groups:moveInto(d, old)

			local matched = groups:applyHints(function(_, hint)
				return hint == "Org Tools" or hint:sub(1, 10) == "Org Tools/"
			end)

			assert.are.equal(3, matched)
			-- "Only org" emptied and is gone; the user's group keeps its own tab.
			-- (Org Tools was made by the first restore, so it keeps its earlier place.)
			assert.are.same({
				{ group = "Org Tools", children = { { group = "Sub", children = { "b/1" } }, "a/1", "d/1" } },
				{ group = "ORG TOOLS (mine)", children = { "c/1" } },
			}, shape(groups, root))
		end)

		it("prunes a manifest group left empty but keeps a user group", function()
			local p = add("p/1", "Parser", "Tools")
			groups:restore()
			local mine = groups:createGroup(root, "Mine")

			groups:forget(p)
			iup.Detach(p)

			local names = {}
			for _, entry in ipairs(shape(groups, root)) do
				if type(entry) == "table" then names[#names + 1] = entry.group end
			end
			assert.are.same({ "Mine" }, names)
			assert.equals(root, iup._real(groups:stripOf(mine)))
		end)
	end)
end)

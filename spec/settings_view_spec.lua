-- spec/settings_view_spec.lua — the collapsible Settings surface.
--
-- Settings is the one screen whose length is decided by how many extensions
-- happen to be installed, so the accordion is what keeps it navigable. The
-- behaviours worth pinning are the ones a user would notice being wrong:
--
--   * a collapsed category stays collapsed across restarts — a preference that
--     resets itself is worse than not having one
--   * a collapsed body is FLOATING as well as zero-height, or every closed
--     section leaves a gutter behind it
--   * searching force-expands the sections holding matches — a search that
--     leaves its results collapsed has not found anything as far as the user is
--     concerned — and restores the user's own arrangement when cleared
--   * controls sit in a fixed column rather than stretching, which is the whole
--     point of the row rework
--   * with no director (or with motion off) sections still land open or closed,
--     never stuck mid-height
--
-- IUP is faked. The view only ever pokes at attributes and the widget tree, so
-- the fake records both and the assertions read them straight back.

local SettingsView = require("core.ui.SettingsView")

-- Height the fake reports for any body, so expand/collapse has a real target.
local BODY_H = 60

local function fake_iup()
	local iup = { DEFAULT = 0, BUTTON1 = 1 }

	local function node(kind)
		return function(def)
			local n = { kind = kind, children = {}, attrs = {} }
			for k, v in pairs(def or {}) do
				if type(k) == "number" then
					n.children[#n.children + 1] = v
					v.parent = n
				else
					n.attrs[k] = v
				end
			end
			return n
		end
	end

	for _, kind in ipairs({
		"vbox", "hbox", "label", "flatframe", "flatlabel", "flatbutton",
		"flatseparator", "flatscrollbox", "text", "fill", "timer",
	}) do
		iup[kind] = node(kind)
	end

	function iup.SetAttribute(w, name, value) w.attrs[name] = value end
	function iup.GetAttribute(w, name)
		-- The view measures a body from its NATURALSIZE; report a fixed height so
		-- the animation has somewhere to travel to.
		if name == "NATURALSIZE" then return "200x" .. BODY_H end
		return w.attrs[name]
	end
	function iup.Append(parent, child)
		parent.children[#parent.children + 1] = child
		child.parent = parent
	end
	function iup.Detach(child)
		local p = child.parent
		if not p then return end
		for i = #p.children, 1, -1 do
			if p.children[i] == child then table.remove(p.children, i) end
		end
		child.parent = nil
	end
	function iup.Destroy(w) w.destroyed = true end
	function iup.Map(w) w.mapped = true end

	-- Counted separately, and this distinction is the point.
	--
	-- IupRefresh lays out the ENTIRE DIALOG whatever widget it is handed -- the
	-- argument only selects which dialog. IupRefreshChildren is genuinely scoped
	-- to that container's children. Per-frame code must only ever use the latter,
	-- so the two are never collapsed into one counter.
	iup.refreshes = 0
	iup.child_refreshes = 0
	function iup.Refresh(w)
		w.refreshed = (w.refreshed or 0) + 1
		iup.refreshes = iup.refreshes + 1
	end
	function iup.RefreshChildren(w)
		w.refreshed_children = (w.refreshed_children or 0) + 1
		iup.child_refreshes = iup.child_refreshes + 1
	end

	return iup
end

-- An in-memory stand-in for core.classes.SettingsManager.
local function fake_settings(seed)
	local store = seed or {}
	return {
		saves = 0,
		store = store,
		get = function(_, k) return store[k] end,
		set = function(self, k, v) store[k] = v end,
		save = function(self) self.saves = self.saves + 1 end,
	}
end

local function make(opts)
	opts = opts or {}
	local iup = fake_iup()
	local settings = opts.settings or fake_settings(opts.seed)
	local view = SettingsView:new({
		iup = iup,
		settings = settings,
		motion = opts.motion,
	})
	return view, iup, settings
end

local ENTRIES = {
	entries = {
		{ label = "Parent folder", description = "Where builds land", widget = false },
		{ label = "Verbose", widget = false },
	},
}

-- The entries above carry `widget = false` so the view falls back to iup.fill{};
-- a real widget handle is not needed for any of these assertions.

describe("SettingsView relayout", function()
	-- This surface does no per-frame layout at all, and these specs are what
	-- keep it that way. The history is worth the comment, because the mistake was
	-- made twice.
	--
	-- A layout pass is `IupRefresh`, which does NOT scope to the widget it is
	-- given: it recomputes the natural size of every container and every label in
	-- the whole dialog (`iupBaseComputeNaturalSize` -- "for containers always
	-- compute", no caching, and measuring a label is a GDI text metric call) and
	-- then issues a `SetWindowPos` for every widget in the dialog.
	--
	-- Animating a section's HEIGHT requires one of those per frame. Two attempts
	-- to make that affordable both failed:
	--
	--   * `IupRefreshChildren` is scoped, but "if the container natural size
	--     changed from inside, simply ignore the change" -- it cannot grow a
	--     container, so the reveal became invisible until the final pass.
	--   * Rate-limiting the full pass reduced the stutter without removing it.
	--
	-- So the height is not animated. One pass per toggle, and the only thing that
	-- moves is the chevron -- a cached bitmap on a small button, exactly what
	-- every other animated icon in the app does.

	local function counts(iup)
		return iup.refreshes, iup.child_refreshes
	end

	it("costs exactly one layout pass per toggle", function()
		local view, iup = make({ motion = {
			animate = function() end,
			cancel = function() end,
		} })
		local section = view:addSection("Build Queue", ENTRIES)

		local before = select(1, counts(iup))
		view:toggleSection(section)

		assert.are.equal(1, select(1, counts(iup)) - before)
	end)

	it("does no layout on an animation frame", function()
		-- The regression that made this surface unusable: a full-dialog relayout
		-- per frame saturates the message queue, so the animation's own frames
		-- (delivered on the low-priority WM_TIMER) never get dispatched.
		local scheduled
		local view, iup = make({ motion = {
			animate = function(_, spec) scheduled = spec end,
			cancel = function() end,
		} })
		local section = view:addSection("Build Queue", ENTRIES)

		view:toggleSection(section)
		local before_full, before_scoped = counts(iup)
		for i = 1, 20 do scheduled.on_frame(-90 + i * 4) end
		local after_full, after_scoped = counts(iup)

		assert.are.equal(before_full, after_full, "an animation frame laid out the dialog")
		assert.are.equal(before_scoped, after_scoped, "an animation frame laid out children")
	end)

	it("animates the chevron, and nothing else", function()
		local scheduled
		local view = make({ motion = {
			animate = function(_, spec) scheduled = spec end,
			cancel = function() end,
		} })
		local section = view:addSection("Build Queue", ENTRIES)
		view:toggleSection(section)

		-- Closing: the chevron sweeps from open (0) to closed.
		assert.are.equal(0, scheduled.from)
		assert.are.equal(-90, scheduled.to)
		-- No `distance`, so the role's fixed duration stands: the sweep is always
		-- 90 degrees regardless of how many rows the section holds.
		assert.is_nil(scheduled.distance)
	end)

	it("never pins a height on a section body", function()
		-- RASTERSIZE existed only to drive the old height animation. Left pinned,
		-- a section could never grow when an extension added a row.
		local scheduled
		local view = make({ motion = {
			animate = function(_, spec) scheduled = spec end,
			cancel = function() end,
		} })
		local section = view:addSection("Build Queue", ENTRIES)

		view:toggleSection(section)
		for i = 1, 10 do scheduled.on_frame(-90 + i * 9) end

		assert.is_nil(section.body.attrs.RASTERSIZE)
	end)

	it("moves the chevron across many distinct angles", function()
		-- The chevron is the whole animation now, so it has to actually travel
		-- rather than snap between two states.
		local scheduled
		local view = make({ motion = {
			animate = function(_, spec) scheduled = spec end,
			cancel = function() end,
		} })
		local section = view:addSection("Build Queue", ENTRIES)
		view:toggleSection(section)

		local distinct = {}
		for i = 0, 18 do
			scheduled.on_frame(-90 + i * 5)
			distinct[section.chevron_deg] = true
		end
		local n = 0
		for _ in pairs(distinct) do n = n + 1 end

		assert.is_true(n >= 15,
			string.format("chevron only took %d distinct angles across the sweep", n))
	end)

	it("settles the scrollbox once per keystroke, not once per section", function()
		-- filter() runs on every character typed and touches every section. Each
		-- section that actually changes state settles the scroll range, and a
		-- settle is a full-dialog relayout -- so unbatched this cost one per
		-- changed section plus one for the trailing settle.
		--
		-- The sections carry DISTINCT entries on purpose: a query matching all of
		-- them would leave every section already open, `_setOpen` would no-op,
		-- and the test would pass whether or not the batching existed.
		local view, iup = make()
		for _, name in ipairs({ "Build Queue", "Log Parser", "Inventory", "Scan Chain" }) do
			view:addSection(name, { entries = {
				{ label = name .. " option", widget = false },
			} })
		end

		local before = select(1, counts(iup))
		-- Matches exactly one section, so the other three must close.
		view:filter("inventory")
		local after = select(1, counts(iup))

		assert.are.equal(1, after - before,
			string.format("expected 1 full relayout per keystroke, got %d", after - before))
	end)

	it("closes the non-matching sections it was asked to close", function()
		-- Guards the test above: if filtering stopped changing any section's
		-- state, the batching assertion would pass for the wrong reason.
		local view = make()
		local sections = {}
		for _, name in ipairs({ "Build Queue", "Inventory" }) do
			sections[name] = view:addSection(name, { entries = {
				{ label = name .. " option", widget = false },
			} })
		end

		view:filter("inventory")
		assert.is_true(sections["Inventory"].open)
		assert.is_false(sections["Build Queue"].open)
	end)

	it("settles the scroll range as part of the toggle, not at the end of an animation", function()
		-- The scroll range has to be re-measured when the body appears, or the
		-- page cannot scroll to content a freshly expanded section just added.
		-- It happens in the toggle itself now: there is no per-frame layout and
		-- nothing deferred to on_done, so a cancelled or superseded chevron
		-- animation cannot leave the scroll range stale.
		local scheduled
		local view, iup = make({ motion = {
			animate = function(_, spec) scheduled = spec end,
			cancel = function() end,
		} })
		local section = view:addSection("Build Queue", ENTRIES)

		local before = select(1, counts(iup))
		view:toggleSection(section)
		assert.is_true(select(1, counts(iup)) > before,
			"the toggle itself must settle the scroll range")

		-- And finishing the chevron adds no further layout.
		local after_toggle = select(1, counts(iup))
		scheduled.on_done()
		assert.are.equal(after_toggle, select(1, counts(iup)))
	end)
end)

describe("SettingsView sections", function()
	it("starts expanded when nothing was stored", function()
		local view = make()
		local section = view:addSection("Build Queue", ENTRIES)
		assert.is_true(section.open)
	end)

	it("restores a category the user had collapsed", function()
		local view = make({ seed = { ["settings.collapsed.Build Queue"] = true } })
		local section = view:addSection("Build Queue", ENTRIES)
		assert.is_false(section.open)
		assert.are.equal("YES", section.body.attrs.FLOATING)
	end)

	it("persists a collapse and clears the key again on expand", function()
		local view, _, settings = make()
		local section = view:addSection("Build Queue", ENTRIES)

		view:toggleSection(section)
		assert.is_false(section.open)
		assert.is_true(settings.store["settings.collapsed.Build Queue"])

		view:toggleSection(section)
		assert.is_true(section.open)
		-- Cleared rather than stored as false: the default is "open", and a
		-- settings file full of false flags is noise.
		assert.is_nil(settings.store["settings.collapsed.Build Queue"])
	end)

	it("floats a closed body so it leaves no gutter behind", function()
		-- A zero-height widget still participates in layout and still contributes
		-- its parent's GAP, which is a visible gap under every closed section.
		local view = make()
		local section = view:addSection("Build Queue", ENTRIES)

		view:toggleSection(section)
		assert.are.equal("YES", section.body.attrs.FLOATING)
		assert.are.equal("NO", section.body.attrs.VISIBLE)

		view:toggleSection(section)
		assert.are.equal("NO", section.body.attrs.FLOATING)
		assert.are.equal("YES", section.body.attrs.VISIBLE)
	end)

	it("releases the pinned height once open, so a later row can grow it", function()
		local view = make()
		local section = view:addSection("Build Queue", ENTRIES)
		view:toggleSection(section)   -- closed
		view:toggleSection(section)   -- open again
		assert.is_nil(section.body.attrs.RASTERSIZE)
	end)

	it("works without a settings manager", function()
		local iup = fake_iup()
		local view = SettingsView:new({ iup = iup })
		local section = view:addSection("Build Queue", ENTRIES)
		assert.has_no.errors(function() view:toggleSection(section) end)
		assert.is_false(section.open)
	end)

	it("accepts the bare IUP binding, as the host originally constructed it", function()
		local iup = fake_iup()
		local view = SettingsView:new(iup)
		assert.has_no.errors(function() view:addSection("Build Queue", ENTRIES) end)
	end)
end)

describe("SettingsView rows", function()
	it("puts every control in a fixed-width column instead of stretching it", function()
		-- The rework this pins: a control sized to the window puts a text field
		-- thousands of pixels from its own label on a maximised display.
		local view = make()
		local section = view:addSection("Build Queue", ENTRIES)

		local row = section.rows[1].box
		local top = row.children[1]
		local column = top.children[#top.children]
		assert.matches("^%d+x0$", column.attrs.RASTERSIZE)
	end)

	it("makes only rows with a description clickable", function()
		local view = make()
		local section = view:addSection("Build Queue", ENTRIES)

		-- Row 1 has a description: its label is a button, so it highlights and
		-- invites a click. Row 2 has none and stays an inert label.
		assert.are.equal("flatbutton", section.rows[1].box.children[1].children[1].kind)
		assert.are.equal("flatlabel", section.rows[2].box.children[1].children[1].kind)
	end)

	it("hides a description until its row is opened", function()
		local view = make()
		local section = view:addSection("Build Queue", ENTRIES)
		local entry = section.rows[1].entry

		assert.are.equal("YES", entry._desc.attrs.FLOATING)
		view:_toggleRow(entry)
		assert.are.equal("NO", entry._desc.attrs.FLOATING)
		assert.are.equal("YES", entry._desc.attrs.VISIBLE)
		view:_toggleRow(entry)
		assert.are.equal("YES", entry._desc.attrs.FLOATING)
	end)

	it("reveals a description without any per-frame layout", function()
		-- Carbon's semantic consistency: a row and a section header are the same
		-- gesture with the same meaning, so they must behave the same way. Since a
		-- section no longer animates its height, a row does not either -- both
		-- reveal in a single layout pass.
		local scheduled
		local view, iup = make({ motion = {
			animate = function(_, spec) scheduled = spec end,
			cancel = function() end,
		} })
		local section = view:addSection("Build Queue", ENTRIES)
		local entry = section.rows[1].entry

		local before = iup.refreshes
		view:_toggleRow(entry)

		assert.is_nil(scheduled, "a row reveal must not schedule a layout animation")
		assert.are.equal(1, iup.refreshes - before, "a reveal costs exactly one layout pass")
		assert.are.equal("NO", entry._desc.attrs.FLOATING)
		assert.are.equal("YES", entry._desc.attrs.VISIBLE)
	end)

	it("never pins a height on a description", function()
		-- The pinned RASTERSIZE existed only to drive the height animation. Left
		-- set, a description could not re-measure after a theme switch changed
		-- its font.
		local view = make({ motion = {
			animate = function() end,
			cancel = function() end,
		} })
		local section = view:addSection("Build Queue", ENTRIES)
		local entry = section.rows[1].entry

		view:_toggleRow(entry)
		assert.is_nil(entry._desc.attrs.RASTERSIZE)
		assert.are.equal("NO", entry._desc.attrs.FLOATING)
	end)

	it("indexes label, description and category for search", function()
		local view = make()
		local section = view:addSection("Build Queue", ENTRIES)
		assert.matches("parent folder", section.rows[1].text)
		assert.matches("where builds land", section.rows[1].text)
		assert.matches("build queue", section.rows[1].text)
	end)
end)

describe("SettingsView filtering", function()
	it("hides rows that do not match and their now-empty category", function()
		local view = make()
		local bq = view:addSection("Build Queue", ENTRIES)
		local other = view:addSection("Log Parser", {
			entries = { { label = "Result directory", widget = false } },
		})

		view:filter("verbose")

		assert.are.equal("YES", bq.rows[2].box.attrs.VISIBLE)
		assert.are.equal("NO", bq.rows[1].box.attrs.VISIBLE)
		assert.are.equal("NO", other.header.attrs.VISIBLE)
	end)

	it("force-expands a collapsed section that holds a match", function()
		local view = make({ seed = { ["settings.collapsed.Build Queue"] = true } })
		local section = view:addSection("Build Queue", ENTRIES)
		assert.is_false(section.open)

		view:filter("verbose")
		assert.is_true(section.open)
	end)

	it("restores the user's own arrangement when the query is cleared", function()
		local view = make({ seed = { ["settings.collapsed.Build Queue"] = true } })
		local section = view:addSection("Build Queue", ENTRIES)

		view:filter("verbose")
		assert.is_true(section.open)

		view:filter("")
		-- Back to collapsed: searching borrows the section open, it does not
		-- silently rewrite what the user chose.
		assert.is_false(section.open)
	end)

	it("does not persist the expansion a search caused", function()
		local view, _, settings = make({ seed = { ["settings.collapsed.Build Queue"] = true } })
		view:addSection("Build Queue", ENTRIES)
		view:filter("verbose")
		assert.is_true(settings.store["settings.collapsed.Build Queue"])
	end)
end)

describe("SettingsView removal", function()
	it("destroys a section's widgets and drops it from the list", function()
		local view = make()
		local section = view:addSection("Build Queue", ENTRIES)
		view:removeSection(section)

		assert.are.equal(0, #view._sections)
		assert.is_true(section.header.destroyed)
		assert.is_true(section.body.destroyed)
	end)

	it("cancels an in-flight toggle so no frame fires at a destroyed body", function()
		local cancelled
		local view = make({ motion = {
			animate = function() end,
			cancel = function(_, filter) cancelled = filter end,
		} })
		local section = view:addSection("Build Queue", ENTRIES)
		view:removeSection(section)
		assert.are.equal(section.body, cancelled.target)
	end)

	it("brings the empty-state label back when the last section goes", function()
		local view = make()
		local section = view:addSection("Build Queue", ENTRIES)
		assert.are.equal("NO", view._empty.attrs.VISIBLE)
		view:removeSection(section)
		assert.are.equal("YES", view._empty.attrs.VISIBLE)
	end)
end)

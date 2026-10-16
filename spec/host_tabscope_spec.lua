-- spec/host_tabscope_spec.lua — regression spec for HostAPI tab-scope fan-out.
--
-- Bug guarded: TabOrder replaces the FlatTabs button_cb, so normal tab clicks
-- switch programmatically and never fire TABCHANGE_CB. The host must therefore
-- re-scope on the TabOrder on_switch hook — and it must re-scope BOTH menu items
-- and status-bar widgets. Previously only menu items were re-scoped, so a tab's
-- status indicator (e.g. Build Queue's SQL icon) lingered on every other tab.
-- _applyTabScopes() is the single fan-out both paths now call; this test pins
-- that it drives menu AND status scoping together.

local HostAPI = require("core.classes.HostAPI")

-- Minimal instance: initialize() only assigns opts fields and, when opts.tabs is
-- present, installs a tabchange_cb. We pass no tabs so construction stays inert
-- and needs no real iup tab strip.
local function make_host()
	return HostAPI:new({ iup = {} })
end

describe("HostAPI:_applyTabScopes", function()
	it("re-scopes menu items AND status widgets in one call", function()
		local host = make_host()
		local calls = {}
		host._applyMenuScope = function() calls[#calls + 1] = "menu" end
		host._applyStatusScope = function() calls[#calls + 1] = "status" end

		host:_applyTabScopes()

		assert.are.same({ "menu", "status" }, calls)
	end)

	-- Models the two things that make a status-bar rebuild expensive rather than
	-- free: IupDetach unmaps (destroying the element's native window, so the
	-- re-append has to build a new one), and IupRefresh lays out the whole dialog.
	-- Both are counted so a test can assert that an unchanged bar costs neither.
	local function make_status_iup()
		local iup = {
			BUTTON1 = 1,
			DEFAULT = 0,
			refreshes = 0,
		}

		function iup.hbox(def)
			return { child = def[1], margin = def.MARGIN, children = {} }
		end

		function iup.SetAttribute(widget, name, value)
			widget[name] = value
		end

		function iup.GetAttribute(widget, name)
			return widget[name]
		end

		function iup.GetChild(parent, index)
			return parent.children[index + 1]
		end

		function iup.GetParent(widget)
			return widget.parent
		end

		function iup.Append(parent, child)
			parent.children[#parent.children + 1] = child
			child.parent = parent
		end

		function iup.Insert(parent, ref, child)
			for i, c in ipairs(parent.children) do
				if c == ref then
					table.insert(parent.children, i, child)
					child.parent = parent
					return
				end
			end
			iup.Append(parent, child)
		end

		-- IupReparent: same tree surgery, no unmap.
		function iup.Reparent(child, parent, ref)
			if not child.parent then return 1 end
			if child.parent == parent
				and (ref == child or (ref == nil and parent.children[#parent.children] == child)) then
				return 1
			end
			iup.Detach(child, true)
			if ref then iup.Insert(parent, ref, child) else iup.Append(parent, child) end
			return 0
		end

		function iup.Detach(child, keep_mapped)
			if not keep_mapped then child.mapped = false end
			local parent = child.parent
			if not parent then return end
			for i = #parent.children, 1, -1 do
				if parent.children[i] == child then
					table.remove(parent.children, i)
					break
				end
			end
			child.parent = nil
		end

		function iup.Map(widget)
			if widget.mapped then return end
			widget.builds = (widget.builds or 0) + 1
			widget.mapped = true
		end

		function iup.Refresh() iup.refreshes = iup.refreshes + 1 end
		function iup.Destroy(widget) widget.destroyed = true end

		return iup
	end

	describe("HostAPI status elements", function()
		it("orders visible elements and keeps only persistent elements across tabs", function()
			local iup = make_status_iup()
			local box = { children = {} }
			local host = HostAPI:new({ iup = iup, status_box = box })
			local owner = {}
			local active_owner
			host._activeOwner = function() return active_owner end

			local update = { id = "update" }
			local database = { id = "database" }
			local farther = { id = "farther" }
			host:addStatusElement(update, { persistent = true, position = 1, padding = 2 })
			host:addStatusElement(farther, { persistent = true, position = 3 })
			host:addStatusElement(database, { position = 2 }, owner)

			assert.are.same({ "farther", "update" }, {
				box.children[1].child.id,
				box.children[2].child.id,
			})
			assert.are.equal("2x2", box.children[2].margin)

			active_owner = owner
			host:_applyStatusScope()
			assert.are.same({ "farther", "database", "update" }, {
				box.children[1].child.id,
				box.children[2].child.id,
				box.children[3].child.id,
			})

			active_owner = {}
			host:_applyStatusScope()
			assert.are.same({ "farther", "update" }, {
				box.children[1].child.id,
				box.children[2].child.id,
			})
		end)

		-- The flicker that trailed every tab switch.
		--
		-- _applyStatusScope runs on every tab change, and a tab change usually does
		-- not change what the bar should hold: switching between two tabs of the
		-- same extension never does, and neither do the three re-scopes one drag
		-- fans out (TABCHANGE_CB, TabGroups' on_change, TabOrder's on_switch). The
		-- old version rebuilt regardless -- detach, re-append, re-map, refresh --
		-- so the update indicator and every extension icon were destroyed and
		-- recreated several times per drag and once per switch, each followed by a
		-- full-dialog layout pass.
		it("does nothing when the bar already holds the right elements", function()
			local iup = make_status_iup()
			local box = { children = {}, mapped = true }
			local host = HostAPI:new({ iup = iup, status_box = box })
			local owner = {}
			host._activeOwner = function() return owner end
			host:addStatusElement({ id = "update" }, { persistent = true, position = 1 })
			host:addStatusElement({ id = "database" }, { position = 2 }, owner)
			host._shown = true
			for _, s in ipairs(host._status_scoped) do iup.Map(s.container) end
			local built = {}
			for i, s in ipairs(host._status_scoped) do built[i] = s.container.builds end
			iup.refreshes = 0

			-- A switch between two tabs of the same extension.
			host:_applyStatusScope()
			host:_applyStatusScope()

			assert.are.equal(0, iup.refreshes)
			for i, s in ipairs(host._status_scoped) do
				assert.is_true(s.container.mapped)
				assert.are.equal(built[i], s.container.builds)
			end
		end)

		it("keeps persistent elements mapped when the active owner changes", function()
			local iup = make_status_iup()
			local box = { children = {}, mapped = true }
			local host = HostAPI:new({ iup = iup, status_box = box })
			local owner = {}
			local active_owner = owner
			host._activeOwner = function() return active_owner end
			host:addStatusElement({ id = "update" }, { persistent = true, position = 1 })
			host:addStatusElement({ id = "database" }, { position = 2 }, owner)
			host._shown = true
			for _, s in ipairs(host._status_scoped) do iup.Map(s.container) end
			local persistent = host._status_scoped[1].container
			local built = persistent.builds

			-- Away from the owning extension: its icon goes, the indicator stays --
			-- and staying must mean staying, not being destroyed and rebuilt in the
			-- same position.
			active_owner = {}
			host:_applyStatusScope()

			assert.are.equal(1, #box.children)
			assert.are.equal("update", box.children[1].child.id)
			assert.is_true(persistent.mapped)
			assert.are.equal(built, persistent.builds)
		end)

		it("applies tooltip and dispatches left-click callbacks", function()
			local iup = make_status_iup()
			local host = HostAPI:new({ iup = iup, status_box = { children = {} } })
			local widget = {}
			local calls = {}

			host:addStatusElement(widget, {
				persistent = true,
				tooltip = "Details",
				on_click = function(clicked, button, pressed, x, y)
					calls = { clicked, button, pressed, x, y }
				end,
			})

			assert.are.equal("Details", widget.TIP)
			assert.are.equal("HAND", widget.CURSOR)
			assert.are.equal(iup.DEFAULT, widget:button_cb(iup.BUTTON1, 0, 12, 34))
			assert.are.same({ widget, 1, 0, 12, 34 }, calls)
		end)

		it("removes and destroys an owner's status elements", function()
			local iup = make_status_iup()
			local box = { children = {} }
			local host = HostAPI:new({ iup = iup, status_box = box })
			local owner = {}
			host._activeOwner = function() return owner end
			host:addStatusElement({}, { position = 2 }, owner)
			local container = box.children[1]

			host:removeOwned(owner)

			assert.is_true(container.destroyed)
			assert.are.equal(0, #box.children)
			assert.are.equal(0, #host._status_scoped)
		end)
	end)

	describe("HostAPI:addTab scrolling", function()
		local function make_tab_host()
			local iup = {}

			function iup.flatscrollbox(def)
				return { kind = "flatscrollbox", child = def[1] }
			end

			function iup.SetAttribute(widget, name, value)
				widget[name] = value
			end

			function iup.GetChild()
				return nil
			end

			function iup.Append(parent, child)
				parent.children[#parent.children + 1] = child
			end

			local tabs = { children = {} }
			return HostAPI:new({ iup = iup, tabs = tabs }), tabs
		end

		it("keeps ordinary tabs on the committed paint hierarchy", function()
			local host, tabs = make_tab_host()
			local panel = {}

			host:addTab("Plain", panel)

			assert.are.equal(panel, tabs.children[1])
		end)

		it("wraps tabs only when scrolling is explicitly requested", function()
			local host, tabs = make_tab_host()
			local panel = {}

			host:addTab("Scrollable", panel, nil, { scroll = true })

			assert.are.equal("flatscrollbox", tabs.children[1].kind)
			assert.are.equal(panel, tabs.children[1].child)
		end)

		it("puts an org pack's tabs inside the pack's tool group", function()
			local host, tabs = make_tab_host()
			local org, builtin = {}, {}
			host:registerExtension(org, { id = "bq", group = "Queues" }, { group = "Acme Tools" })
			host:registerExtension(builtin, { id = "hello" }, { source = "built-in" })
			local loose = {}
			host:registerExtension(loose, { id = "logs" }, { group = "Acme Tools" })

			host:addTab("Queue", {}, org)
			host:addTab("Hello", {}, builtin)
			host:addTab("Logs", {}, loose)
			host:addTab("Elsewhere", {}, org, { group = "Diagnostics" })

			assert.are.equal("Acme Tools/Queues", tabs.children[1]._IUPLUNAR_GROUPHINT)
			assert.is_nil(tabs.children[2]._IUPLUNAR_GROUPHINT)
			assert.are.equal("Acme Tools", tabs.children[3]._IUPLUNAR_GROUPHINT)
			assert.are.equal("Acme Tools/Diagnostics", tabs.children[4]._IUPLUNAR_GROUPHINT)
		end)
	end)

	it("still re-scopes status even if menu scoping is a no-op", function()
		local host = make_host()
		local status_calls = 0
		host._applyMenuScope = function() end
		host._applyStatusScope = function() status_calls = status_calls + 1 end

		host:_applyTabScopes()

		assert.are.equal(1, status_calls)
	end)

	describe("group-aware active tab", function()
		-- With tab groups a top-level page can be another tab strip rather than an
		-- extension's content, so the strip's VALUE is a group and not a tab. Menu
		-- scoping, status scoping, shortcut scoping and route serialization all
		-- resolve through _activeTab, so if it stops at the group every one of them
		-- silently reverts to "no active extension" -- the whole point of routing
		-- the descent through a single method.
		it("descends into the group manager's leaf rather than stopping at the group", function()
			local iup = {}
			local tabs = {}
			local group_page = { id = "group" }
			local leaf = { id = "leaf", HOSTTABOWNERID = "hosttab1" }

			function iup.GetAttributeHandle(_, name)
				if name == "VALUE" then return group_page end
				return nil
			end
			function iup.GetAttribute(widget, name) return widget[name] end

			local host = HostAPI:new({ iup = iup, tabs = tabs })
			local owner = {}
			host._owner_by_tab["hosttab1"] = owner
			host:setTabGroups({ activeLeaf = function() return leaf end })

			assert.are.equal(leaf, host:_activeTab())
			assert.are.equal(owner, host:_activeOwner())
		end)

		it("falls back to the strip's own VALUE when no group manager is attached", function()
			local iup = {}
			local page = { id = "page" }
			function iup.GetAttributeHandle(_, name)
				if name == "VALUE" then return page end
				return nil
			end
			function iup.GetAttribute(widget, name) return widget[name] end

			local host = HostAPI:new({ iup = iup, tabs = {} })

			assert.are.equal(page, host:_activeTab())
		end)
	end)
end)

local Kit = require("core.ui.Kit")

describe("Kit.requirements", function()
	local iup, widgets
	before_each(function()
		widgets = {}
		iup = { DEFAULT = 0 }
		for _, kind in ipairs({ "flatlabel", "flatbutton", "vbox", "hbox", "fill" }) do
			iup[kind] = function(attrs)
				attrs.kind = kind
				widgets[#widgets + 1] = attrs
				return attrs
			end
		end
		iup.SetAttribute = function(w, k, v) w[k] = v end
		iup.GetAttribute = function(w, k) return w[k] end
		iup.ResetAttribute = function(w, k) w[k] = nil end
		iup.Append = function() end
		iup.Refresh = function() end
	end)
	local function button(title)
		for _, w in ipairs(widgets) do
			if w.kind == "flatbutton" and w.TITLE == title then return w end
		end
	end
	local function label(title)
		for _, w in ipairs(widgets) do
			if w.kind == "flatlabel" and w.TITLE == title then return w end
		end
	end
	local function shown(w) return w and w.FLOATING ~= "YES" end

	it("says one thing when all is well, with the page's own words if it has them", function()
		local strip = Kit.requirements(iup, { ready = "Ready" })
		strip.set({ { label = "Key", ok = true } })
		assert.truthy(label("Ready"))
		assert.is_nil(strip.blocker)
		strip.set({ { label = "Key", ok = true } }, "Next run Tue 14:00")
		assert.truthy(label("Next run Tue 14:00"))
	end)
	it("leads with the first blocker and its action", function()
		local hit
		local strip = Kit.requirements(iup)
		strip.set({
			{ label = "One", ok = true },
			{ label = "Two", ok = false, problem = "missing", action_title = "Fix...", action = function() hit = true end },
			{ label = "Three", ok = false, problem = "also missing" },
		})
		assert.truthy(label("Two: missing"))
		assert.is_nil(label("Three: also missing"))
		assert.are.equal("Two", strip.blocker.label)
		button("Fix..."):flat_action()
		assert.is_true(hit)
	end)
	it("doesn't let an optional item stand in the way", function()
		local strip = Kit.requirements(iup, { ready = "Ready" })
		strip.set({ { label = "Later", ok = false, optional = true, problem = "not yet" } })
		assert.is_nil(strip.blocker)
		assert.truthy(label("Ready"))
	end)
	it("keeps every action reachable in Details, even for what is already fine", function()
		local changed
		local strip = Kit.requirements(iup)
		strip.set({
			{ label = "Account", ok = true, action_title = "Change...", action = function() changed = true end },
			{ label = "Engine", ok = true },
		})
		assert.is_nil(button("Change..."))
		button("Details"):flat_action()
		assert.are.equal("Hide details", button("Hide details").TITLE)
		assert.truthy(shown(label("Account")))
		assert.truthy(shown(button("Change...")))
		button("Change..."):flat_action()
		assert.is_true(changed)
	end)
	it("offers no Details for a single item", function()
		local strip = Kit.requirements(iup)
		strip.set({ { label = "Only", ok = true } })
		assert.is_false(shown(button("Details")))
	end)
	it("gives pages an anchor that is always on the page", function()
		local strip = Kit.requirements(iup)
		assert.are.equal("flatlabel", strip.anchor.kind)
	end)
end)

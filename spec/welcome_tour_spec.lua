local WelcomeTour = require("core.ui.WelcomeTour")

local function fake_settings()
	local data = { welcome_tour_completed = false, welcome_tour_dismissed = false }
	return {
		saves = 0,
		data = data,
		get = function(self, k) return self.data[k] end,
		set = function(self, k, v) self.data[k] = v end,
		save = function(self) self.saves = self.saves + 1 end,
	}
end

-- Minimal IUP stand-in: widgets are plain tables and Popup drives the dialog by
-- invoking the flat_action callbacks the caller asks for.
local function fake_iup(script)
	local widgets = {}
	local iup
	local function widget(kind)
		return function(t)
			t = t or {}
			t._kind = kind
			widgets[#widgets + 1] = t
			return t
		end
	end
	iup = {
		DEFAULT = "default",
		CLOSE = "close",
		CENTER = 0,
		label = widget("label"),
		text = widget("text"),
		fill = widget("fill"),
		vbox = widget("vbox"),
		hbox = widget("hbox"),
		flatframe = widget("flatframe"),
		flatbutton = widget("flatbutton"),
		dialog = widget("dialog"),
		SetAttribute = function(w, k, v) w[k] = v end,
		Destroy = function() end,
	}
	iup.Popup = function()
		local buttons = {}
		for _, w in ipairs(widgets) do
			if w._kind == "flatbutton" then buttons[w.TITLE] = w end
		end
		for _, title in ipairs(script) do
			-- Button titles change as the wizard advances (Next -> Finish).
			local btn = buttons[title]
			if not btn then
				for _, w in ipairs(widgets) do
					if w._kind == "flatbutton" and w.TITLE == title then btn = w end
				end
			end
			assert(btn, "no button titled " .. title)
			btn:flat_action()
		end
	end
	return iup
end

describe("WelcomeTour persistence", function()
	it("marks the tour completed using the keys main.lua checks", function()
		local settings = fake_settings()
		local result = WelcomeTour.show({
			iup = fake_iup({ "Next", "Next", "Finish" }),
			settings = settings,
		})
		assert.equal("completed", result)
		assert.is_true(settings.data.welcome_tour_completed)
		assert.is_false(settings.data.welcome_tour_dismissed)
		assert.is_true(settings.saves > 0)
		assert.is_nil(settings.data.onboarding_completed)
	end)

	it("marks the tour dismissed when the user picks Not Now", function()
		local settings = fake_settings()
		local result = WelcomeTour.show({
			iup = fake_iup({ "Not Now" }),
			settings = settings,
		})
		assert.equal("dismissed", result)
		assert.is_true(settings.data.welcome_tour_dismissed)
		assert.is_true(settings.saves > 0)
	end)

	it("records a dismissal when the dialog is closed without any button", function()
		local settings = fake_settings()
		WelcomeTour.show({ iup = fake_iup({}), settings = settings })
		assert.is_true(settings.data.welcome_tour_dismissed)
	end)

	it("does not clear the completed flag when reopened and closed again", function()
		local settings = fake_settings()
		settings.data.welcome_tour_completed = true
		WelcomeTour.show({ iup = fake_iup({ "Not Now" }), settings = settings })
		assert.is_true(settings.data.welcome_tour_completed)
		assert.is_false(settings.data.welcome_tour_dismissed)
	end)
end)

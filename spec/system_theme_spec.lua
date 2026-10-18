-- "Match system theme": core.lib.SystemTheme, Theme:isDark, and the Linux
-- light/dark detection.

local SystemTheme = require("core.lib.SystemTheme")
local Theme = require("core.classes.Themes.Theme")
local posix = require("core.platform.posix")

local function theme(id, dark)
	return { id = function() return id end, isDark = function() return dark end }
end

local function fixture(opts)
	opts = opts or {}
	local store = {
		theme_follow_system = opts.follow or false,
		theme_light = opts.light, theme_dark = opts.dark,
	}
	local settings = {
		saved = 0,
		get = function(_, k) return store[k] end,
		set = function(_, k, v)
			if (opts.locked or {})[k] then return false end
			store[k] = v
			return true
		end,
		save = function(self) self.saved = self.saved + 1 end,
		isLocked = function(_, k) return (opts.locked or {})[k] == true end,
	}
	local themes = { applied = {}, current_id = opts.current or "classic" }
	local by_id = {
		classic = theme("classic", false), classic_dark = theme("classic_dark", true),
		one_dark_pro = theme("one_dark_pro", true),
	}
	function themes.apply(self, id) self.applied[#self.applied + 1] = id; self.current_id = id end
	function themes.current(self) return self.current_id end
	function themes.themeById(_, id) return by_id[id] end
	local system = { dark = opts.system, asked = 0 }
	function themes._syncControls(self) self.synced = (self.synced or 0) + 1 end
	local st = SystemTheme.new({
		settings = settings, theme_manager = themes,
		system_dark = function() system.asked = system.asked + 1; return system.dark end,
		system_dark_probe = opts.probe,
		iup = opts.iup,
	})
	return st, store, themes, system, settings
end

describe("SystemTheme", function()
	it("does nothing while matching is off", function()
		local st, _, themes = fixture({ system = true })
		assert.is_false(st:sync(true))
		assert.are.same({}, themes.applied)
	end)

	it("shows the light theme in light mode and the dark theme in dark mode", function()
		local st, _, themes = fixture({ follow = true, system = false })
		assert.is_true(st:sync(true))
		assert.are.same({ "classic" }, themes.applied)
		local st2, _, themes2 = fixture({ follow = true, system = true, dark = "one_dark_pro" })
		st2:sync(true)
		assert.are.same({ "one_dark_pro" }, themes2.applied)
	end)

	it("follows a live change and ignores checks where nothing changed", function()
		local st, _, themes, system = fixture({ follow = true, system = false })
		st:sync(true)
		assert.is_false(st:sync())                      -- still light
		system.dark = true
		assert.is_true(st:sync())
		assert.are.same({ "classic", "classic_dark" }, themes.applied)
	end)

	it("keeps the current theme when the system can't say", function()
		local st, _, themes = fixture({ follow = true, system = nil })
		assert.is_false(st:sync(true))
		assert.are.same({}, themes.applied)
	end)

	it("remembers a pick for the current mode while matching", function()
		local st, store, themes = fixture({ follow = true, system = true })
		st:sync(true)
		st:choose("one_dark_pro")
		assert.are.equal("one_dark_pro", store.theme_dark)
		assert.is_nil(store.theme_light)
		assert.are.equal("one_dark_pro", themes.applied[#themes.applied])
	end)

	it("just applies a pick while matching is off", function()
		local st, store, themes = fixture({ system = true })
		st:choose("one_dark_pro")
		assert.is_nil(store.theme_dark)
		assert.are.same({ "one_dark_pro" }, themes.applied)
	end)

	it("turning it on starts from the theme on screen when it suits the mode", function()
		local st, store, themes = fixture({ system = true, current = "one_dark_pro" })
		assert.is_true(st:setEnabled(true))
		assert.is_true(store.theme_follow_system)
		assert.are.equal("one_dark_pro", store.theme_dark)
		assert.are.same({ "one_dark_pro" }, themes.applied)
		-- A light theme on screen while the system is dark isn't seeded as the dark choice.
		local st2, store2, themes2 = fixture({ system = true, current = "classic" })
		st2:setEnabled(true)
		assert.is_nil(store2.theme_dark)
		assert.are.same({ "classic_dark" }, themes2.applied)
	end)

	it("is unavailable and inert when the org locks the theme", function()
		local st, store, themes = fixture({ follow = true, system = true, locked = { theme = true } })
		assert.is_false(st:available())
		assert.is_false(st:enabled())
		assert.is_false(st:sync(true))
		assert.is_false(st:setEnabled(true))
		assert.are.same({}, themes.applied)
		assert.is_true(store.theme_follow_system)        -- untouched
	end)
end)

describe("SystemTheme review fixes", function()
	it("refuses a pick for a mode whose theme the org locked, and snaps the selector back", function()
		local st, store, themes = fixture({ follow = true, system = true, dark = "classic_dark",
			locked = { theme_dark = true } })
		st:sync(true)
		assert.is_false(st:choose("one_dark_pro"))
		assert.are.equal("classic_dark", store.theme_dark)
		assert.are.equal("classic_dark", themes.current_id)
		assert.are.equal(1, themes.synced)
	end)

	it("remembers a light-mode pick after the system was unknown at startup", function()
		local st, store, themes, system = fixture({ follow = true, system = nil })
		st:sync(true)                                   -- unknown: nothing applied
		system.dark = false
		assert.is_true(st:choose("one_dark_pro"))
		assert.are.equal("one_dark_pro", store.theme_light)
		assert.is_false(st:sync())                      -- light already showing it
		assert.are.equal("one_dark_pro", themes.current_id)
	end)

	it("asks the system once when matching is turned on", function()
		local st, _, _, system = fixture({ system = true })
		st:setEnabled(true)
		assert.are.equal(1, system.asked)
	end)

	it("polls a non-blocking probe on the timer instead of asking synchronously", function()
		local probes = {}
		local function probe()
			local p = { polls = 0, answer = true }
			function p.poll() p.polls = p.polls + 1; if p.polls < 3 then return false end return true, p.answer end
			function p.cancel() p.cancelled = true end
			probes[#probes + 1] = p
			return p
		end
		local st, _, themes, system = fixture({ follow = true, system = false, probe = probe })
		st:sync(true)
		system.asked = 0
		assert.is_false(st:tick())                      -- started, in flight
		assert.is_false(st:tick())
		assert.is_true(st:tick())                       -- answered dark
		assert.are.equal("classic_dark", themes.current_id)
		assert.are.equal(0, system.asked)               -- never blocked
		assert.are.equal(1, #probes)
		st:tick()                                       -- the next check is a fresh probe
		assert.are.equal(2, #probes)
		st:setEnabled(false)
		assert.is_true(probes[2].cancelled)
	end)

	it("turning it on with a probe doesn't block: it finishes when the probe answers", function()
		local p = { polls = 0 }
		function p.poll() p.polls = p.polls + 1; if p.polls < 2 then return false end return true, true end
		function p.cancel() end
		local st, store, themes, system = fixture({ system = true, current = "one_dark_pro",
			probe = function() return p end })
		assert.is_true(st:setEnabled(true))
		assert.are.equal(0, system.asked)                   -- no synchronous question
		assert.is_true(store.theme_follow_system)
		assert.are.same({}, themes.applied)
		st:tick()
		assert.is_true(st:tick())                           -- answered: dark
		assert.are.equal("one_dark_pro", store.theme_dark)  -- seeded from the screen
		assert.are.same({ "one_dark_pro" }, themes.applied)
	end)

	it("stop() destroys its timer", function()
		local destroyed = {}
		local iup = { DEFAULT = -2 }
		function iup.timer(t) return t end
		function iup.Destroy(t) destroyed[#destroyed + 1] = t end
		local st = fixture({ follow = true, system = false, iup = iup })
		st:start()
		local t = st._timer
		st:stop()
		assert.are.same({ t }, destroyed)
		assert.is_nil(st._timer)
	end)
end)

describe("Linux dark-mode probe (posix.system_dark_probe)", function()
	-- A fake `process` module: each spawn takes the next scripted run.
	local function fake_process(runs)
		local spawned = {}
		local mod = {}
		function mod.spawn(opts)
			local run = table.remove(runs, 1)
			spawned[#spawned + 1] = opts.argv
			if run == "missing" then return nil, "not found" end
			local p = { out = run.out, polls = 0, killed = false }
			function p:read(stream)
				if stream ~= "stdout" then return nil end
				local o = self.out; self.out = nil; return o
			end
			function p:poll()
				self.polls = self.polls + 1
				if run.hang then return nil end
				return 0
			end
			function p:kill() self.killed = true; run.killed = true end
			function p:close() end
			return p
		end
		return mod, spawned
	end

	local function finish(probe)
		for _ = 1, 100 do
			local done, v = probe.poll()
			if done then return v end
		end
		error("probe never finished")
	end

	it("asks the portal first, with an argv (no shell)", function()
		local proc, spawned = fake_process({ { out = "(<<uint32 1>>,)" } })
		assert.is_true(finish(posix.system_dark_probe({ process = proc })))
		assert.are.equal("gdbus", spawned[1][1])
		assert.are.equal(1, #spawned)
	end)

	it("falls through missing or silent sources to the GTK theme name", function()
		local proc, spawned = fake_process({ "missing", { out = "" }, { out = "'default'" },
			{ out = "'Mint-Y-Dark'" } })
		assert.is_true(finish(posix.system_dark_probe({ process = proc })))
		assert.are.equal(4, #spawned)
		assert.are.equal("gtk-theme", spawned[4][4])
	end)

	it("is nil when nothing answers", function()
		local proc = fake_process({ { out = "" }, { out = "" }, { out = "" }, { out = "" } })
		assert.is_nil(finish(posix.system_dark_probe({ process = proc })))
	end)

	it("kills a source that hangs once the deadline passes", function()
		local t = 0
		local hung = { hang = true }
		local proc = fake_process({ hung })
		local probe = posix.system_dark_probe({ process = proc, timeout = 2, now = function() return t end })
		assert.is_false((probe.poll()))
		t = 2.5
		local done, v = probe.poll()
		assert.is_true(done)
		assert.is_nil(v)
		assert.is_true(hung.killed)
	end)
end)

describe("Theme:isDark", function()
	it("uses an explicit flag, else the background brightness", function()
		assert.is_true(Theme:new({ id = "a", label = "A", dark = true, palette = { bg = "255 255 255" } }):isDark())
		assert.is_true(Theme:new({ id = "b", label = "B", palette = { bg = "22 22 22" } }):isDark())
		assert.is_false(Theme:new({ id = "c", label = "C", palette = { bg = "244 244 244" } }):isDark())
		assert.is_false(Theme:new({ id = "d", label = "D" }):isDark())
	end)

	it("classifies the shipped themes", function()
		assert.is_false(require("core.classes.Themes.ClassicTheme"):new():isDark())
		assert.is_true(require("core.classes.Themes.ClassicDarkTheme"):new():isDark())
		assert.is_true(require("core.classes.Themes.OneDarkProTheme"):new():isDark())
	end)
end)

describe("Linux light/dark detection (posix.parse_dark)", function()
	it("prefers the XDG portal", function()
		assert.is_true(posix.parse_dark("(<uint32 1>,)", "'prefer-light'", "'Adwaita'"))
		assert.is_false(posix.parse_dark("(<<uint32 2>>,)", "'prefer-dark'", "'Mint-Y-Dark'"))
	end)

	it("falls back to GNOME's color-scheme, then the GTK theme name", function()
		assert.is_true(posix.parse_dark("(<uint32 0>,)", "'prefer-dark'", "'Adwaita'"))
		assert.is_false(posix.parse_dark("", "'prefer-light'", "'Mint-Y-Dark'"))
		assert.is_true(posix.parse_dark("", "'default'", "'Mint-Y-Dark-Red'"))
		assert.is_false(posix.parse_dark("", "'default'", "'Adwaita'"))
		assert.is_nil(posix.parse_dark("", "", ""))
	end)
end)

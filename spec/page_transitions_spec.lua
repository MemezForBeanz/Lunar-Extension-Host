-- spec/page_transitions_spec.lua -- tab page transition kinds (core.lib.PageTransitions),
-- how the director picks one, the extension API, the ImGui tab strip playing them with
-- the live pages, and core.ui.TabTransition standing down for such a strip.

local PT = require("core.lib.PageTransitions")
local MotionDirector = require("core.classes.MotionDirector")
local Tokens = require("core.lib.MotionTokens")

local function ctx(w, forward, spec)
	return PT.context(spec or Tokens.ROLES.tab_transition, w or 1000, 600, forward ~= false)
end

describe("page transition kinds", function()
	it("has the built-in kinds, push first", function()
		local names = {}
		for _, k in ipairs(PT.list()) do names[#names + 1] = k.name end
		assert.equal("push", names[1])
		for _, n in ipairs({ "fade", "rise", "slide", "none" }) do assert.is_not_nil(PT.get(n), n) end
	end)

	it("lands every kind with the incoming page in place and opaque", function()
		for _, k in ipairs(PT.list()) do
			local def = PT.get(k.name)
			if def.frame then
				local _, spec = PT.resolve(nil, k.name)
				local _, inn = def.frame(1, PT.context(spec, 1000, 600, true))
				assert.equal(0, inn.dx or 0, k.name)
				assert.equal(0, inn.dy or 0, k.name)
				assert.equal(1, inn.alpha or 1, k.name)
			end
		end
	end)

	it("keeps push's geometry: capped travel, incoming from the new tab's side, a lead", function()
		local def = PT.get("push")
		local c = ctx(4000)
		assert.equal(360, c.travel) -- the pixel cap
		local out0, in0 = def.frame(0, c)
		assert.equal(0, out0.dx)
		assert.equal(360, in0.dx) -- forward: arrives from the right
		local out1 = def.frame(1, c)
		assert.equal(-180, out1.dx) -- half the travel (OUTGOING_LEAD)
		local _, back = def.frame(0, ctx(4000, false))
		assert.equal(-360, back.dx)
	end)

	it("rises the incoming page 16 px and fades the outgoing one out early", function()
		local _, spec = PT.resolve(nil, "rise")
		local out, inn = PT.get("rise").frame(0.5, PT.context(spec, 1000, 600, true))
		assert.equal(8, inn.dy)
		assert.equal(0, out.alpha)
		assert.equal("entrance", spec.curve)
		assert.equal("expressive", spec.style)
	end)

	it("slides the incoming page over the outgoing one, which dims", function()
		local out, inn = PT.get("slide").frame(0.5, ctx(1000))
		assert.equal(0, out.dx)
		assert.is_true(out.dim > 0)
		assert.equal(500, inn.dx)
	end)

	it("resolves the user's choice over the theme's, and the theme's over push", function()
		local _, _, n = PT.resolve(nil, nil)
		assert.equal("push", n)
		_, _, n = PT.resolve({ kind = "rise" }, nil)
		assert.equal("rise", n)
		_, _, n = PT.resolve({ kind = "rise" }, "theme")
		assert.equal("rise", n)
		_, _, n = PT.resolve({ kind = "rise" }, "fade")
		assert.equal("fade", n)
		_, _, n = PT.resolve({ kind = "nosuch" }, "alsonot")
		assert.equal("push", n)
	end)

	it("gives a kind its own timing, with the theme's fields on top only for its own kind", function()
		local _, spec = PT.resolve(nil, "fade")
		assert.equal(Tokens.DURATION.fast_02, spec.duration)
		_, spec = PT.resolve({ kind = "fade", duration = 200 }, nil)
		assert.equal(200, spec.duration)
		-- a theme tuning push does not retime the user's fade
		_, spec = PT.resolve({ travel = 1, duration = 500 }, "fade")
		assert.equal(Tokens.DURATION.fast_02, spec.duration)
	end)

	it("registers and removes an extension's kind, never a built-in one", function()
		assert.is_nil((PT.register("bad name", { frame = function() end })))
		assert.is_nil((PT.register("nofr", {})))
		assert.is_true(PT.register("zoomtest", { label = "Zoom", frame = function(t) return {}, { alpha = t } end }))
		local found = false
		for _, k in ipairs(PT.list()) do if k.name == "zoomtest" then found = k.label == "Zoom" end end
		assert.is_true(found)
		assert.is_true(PT.unregister("zoomtest"))
		assert.is_nil(PT.get("zoomtest"))
		assert.is_false(PT.unregister("push"))
	end)
end)

describe("MotionDirector:pageTransition", function()
	it("takes the theme's kind, the user's choice over it, and none with motion off", function()
		local d = MotionDirector:new({ widgets = false, clock = function() return 0 end })
		d:setRoles({ tab_transition = { kind = "rise" } })
		local _, _, n = d:pageTransition()
		assert.equal("rise", n)
		d:configure({ page_transition = "slide" })
		_, _, n = d:pageTransition()
		assert.equal("slide", n)
		d:configure({ page_transition = "theme" })
		_, _, n = d:pageTransition()
		assert.equal("rise", n)
		d:configure({ enabled = false })
		_, _, n = d:pageTransition()
		assert.equal("none", n)
	end)
end)

describe("ctx:registerPageTransition", function()
	it("files the kind under the extension and removes it when the extension unloads", function()
		local iup = require("core.imgui.iup")
		local HostAPI = require("core.classes.HostAPI")
		local Extension = require("core.classes.Extension")
		local h = HostAPI:new({
			iup = iup, mode = "gui", app = { title = "t", version = "1", dir = "." },
			settings = { get = function() end, set = function() end, save = function() end },
			tabs = iup.flattabs{}, ext_menu = iup.menu{}, file_menu = iup.menu{}, help_menu = iup.menu{},
			status_box = iup.hbox{}, set_status = function() end, notify = function() end,
			subprocess = { terminate = function() end, destroy = function() end },
		})
		local ext = Extension:new("Drops", "1")
		ext._ctx = h
		assert.is_true(ext:registerPageTransition("droptest", {
			label = "Drop", frame = function(t) return { alpha = 1 - t }, { dy = -24 * (1 - t), alpha = t } end,
		}))
		assert.is_not_nil(PT.get("droptest"))
		assert.is_nil((ext:registerPageTransition("push", { frame = function() end })))
		h:removeOwned(ext)
		assert.is_nil(PT.get("droptest"))
	end)
end)

describe("the ImGui tab strip plays the transition with the live pages", function()
	local Null = require("core.imgui.backend.Null")
	local R = require("core.imgui.Runtime")
	local iup = require("core.imgui.iup")
	local motion = require("core.imgui.motion")
	local B, tabs

	-- a director stand-in choosing the kind
	local function use(kind, enabled)
		motion.attach({
			enabled = function() return enabled ~= false end, scale = function() return 1 end,
			role = function(_, name) return Tokens.role(name) end,
			pageTransition = function() return PT.resolve(nil, enabled == false and "none" or kind) end,
		})
	end

	before_each(function()
		B = Null.new({ w = 600, h = 300 })
		R.init(B)
		use("push")
		tabs = iup.flattabs{
			iup.vbox{ iup.label{ TITLE = "PAGE A" }, MARGIN = "250x10" }, iup.vbox{ iup.label{ TITLE = "PAGE B" }, MARGIN = "250x10" },
			TABTITLE0 = "A", TABTITLE1 = "B", RASTERSIZE = "600x260" }
		iup.Show(iup.dialog{ tabs, RASTERSIZE = "600x300" })
		R.frame(); R.frame()
	end)
	after_each(function() motion.attach(nil) end)

	-- x of each page's label in the last frame
	local function drawn()
		local at = {}
		for _, c in ipairs(B.lastFrame()) do
			if c[1] == "text" and (c[7] == "PAGE A" or c[7] == "PAGE B") then at[c[7]] = c[4] end
		end
		return at
	end

	it("draws both pages mid-way, the incoming one on its way in, then only the new one", function()
		local a0 = drawn()["PAGE A"]
		iup.SetAttribute(tabs, "VALUEPOS", "1")
		assert.equal("1", iup.GetAttribute(tabs, "VALUEPOS")) -- the switch is immediate
		B.advance(0.08); R.frame()
		local mid = drawn()
		assert.is_not_nil(mid["PAGE A"], "the leaving page is still drawn")
		assert.is_not_nil(mid["PAGE B"])
		assert.is_true(mid["PAGE B"] > a0, "B comes in from the right")
		assert.is_true(mid["PAGE A"] < a0, "A drifts left")
		B.advance(0.5); R.frame()
		local done = drawn()
		assert.is_nil(done["PAGE A"])
		assert.equal(a0, done["PAGE B"])
	end)

	it("switches at once with motion off, with kind none and with PAGETRANSITION=NO", function()
		for _, setup in ipairs({
			function() use("push", false) end,
			function() use("none") end,
			function() iup.SetAttribute(tabs, "PAGETRANSITION", "NO") end,
		}) do
			iup.SetAttribute(tabs, "VALUEPOS", "0"); B.advance(1); R.frame()
			iup.SetAttribute(tabs, "PAGETRANSITION", nil); use("push")
			setup()
			iup.SetAttribute(tabs, "VALUEPOS", "1")
			R.frame()
			local at = drawn()
			assert.is_nil(at["PAGE A"])
			assert.is_not_nil(at["PAGE B"])
		end
	end)

	it("tells core.ui.TabTransition it draws its own", function()
		assert.equal("LIVE", iup.GetAttribute(tabs, "PAGETRANSITIONDRAW"))
	end)
end)

describe("core.ui.TabTransition on a strip that draws its own", function()
	it("only switches: no capture, no compositor", function()
		local TabTransition = require("core.ui.TabTransition")
		local switched = 0
		local iup = { DEFAULT = 0, GetAttribute = function(_, n) if n == "PAGETRANSITIONDRAW" then return "LIVE" end end }
		local t = TabTransition:new({
			iup = iup,
			director = { enabled = function() return true end, role = function() return {} end, finish = function() end },
			compositor = function() error("no compositor should be made") end,
		})
		assert.is_true(t:run({}, 1, function() switched = switched + 1 end))
		assert.equal(1, switched)
		t:arm({})
		assert.is_nil(t._armed)
		assert.is_true(t:commit({}))
	end)
end)

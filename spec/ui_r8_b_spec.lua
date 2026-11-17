-- Round 8, package B: Carbon disabled text, table and notice fills, Metadata preview,
-- and the narrow Home hero.
local carbon = require("core.classes.Themes.carbon_rules")

local function rgb(s)
	local r, g, b = s:match("(%d+)%s+(%d+)%s+(%d+)")
	return tonumber(r), tonumber(g), tonumber(b)
end

describe("round 8 Carbon disabled text", function()
	-- The flat controls fade a disabled label halfway to its background (patch 0005).
	local function faded(fg, bg)
		local r, g, b = rgb(fg)
		local br, bg_, bb = rgb(bg)
		return math.floor((r + br) / 2), math.floor((g + bg_) / 2), math.floor((b + bb) / 2)
	end
	for _, name in ipairs({ "CarbonWhite", "CarbonG10", "CarbonG90", "CarbonG100" }) do
		it(name .. " lands disabled ghost labels on text-disabled over the button", function()
			local t = require("core.classes.Themes." .. name .. "Theme"):new()
			local p, r = t:palette(), t:rules()
			local raw = p.carbonTokens.textDisabled
			local tr, tg, tb, a = raw:match("rgba%((%d+),%s*(%d+),%s*(%d+),%s*([%d%.]+)%)")
			local sr, sg, sb = rgb(r.ghost_btn.inactivebg)
			a = tonumber(a)
			local want = {
				math.floor(tr * a + sr * (1 - a) + 0.5),
				math.floor(tg * a + sg * (1 - a) + 0.5),
				math.floor(tb * a + sb * (1 - a) + 0.5),
			}
			for _, role in ipairs({ "ghost_btn", "actionbutton", "flatbutton" }) do
				local fr, fg, fb = faded(r[role].inactivefg, r[role].inactivebg)
				assert.is_true(math.abs(fr - want[1]) <= 1, role .. " red " .. fr .. " vs " .. want[1])
				assert.is_true(math.abs(fg - want[2]) <= 1, role)
				assert.is_true(math.abs(fb - want[3]) <= 1, role)
			end
			-- Visible: the painted label differs from the surface.
			local fr = faded(r.ghost_btn.inactivefg, r.ghost_btn.inactivebg)
			assert.is_true(math.abs(fr - sr) >= 40)
		end)
	end
	it("falls back to the plain token without Carbon tokens", function()
		assert.equal("1 2 3", carbon.disabledText({ textDisabled = "1 2 3" }, "9 9 9"))
	end)
end)

describe("round 8 Carbon table and notice fills", function()
	for _, name in ipairs({ "CarbonWhite", "CarbonG10", "CarbonG90", "CarbonG100" }) do
		it(name .. " uses one table rule: layer-02 body, layer-accent-02 header", function()
			local t = require("core.classes.Themes." .. name .. "Theme"):new()
			local p, r = t:palette(), t:rules()
			assert.equal(p.layer02, r.flatrows_plain.bg)
			assert.equal(p.layer02, r.flatrows_plain.scrollbg)
			assert.equal(p.layerAccent02, r.flatrows_plain.header)
			assert.is_not.equal(r.flatrows_plain.header, r.flatrows_plain.bg)
			assert.equal(p.layer02, carbon.notificationFill(p))
		end)
	end
	it("keeps the Lunar notice fill and uses the Carbon rule in Carbon", function()
		local Kit = require("core.ui.Kit")
		assert.equal("3 3 3", Kit.notificationFill({ layer03 = "3 3 3", layer02 = "2 2 2" }))
		assert.equal("2 2 2", Kit.notificationFill({ carbonTokens = {}, layer03 = "3 3 3", layer02 = "2 2 2" }))
	end)
end)

describe("round 8 media details", function()
	local iup, old_path, old_raw
	before_each(function()
		old_path, old_raw = package.path, package.loaded.iupraw
		package.path = "extensions/media/?.lua;" .. old_path
		package.loaded.iupraw = require("core.imgui.native.iupraw")
		require("core.imgui.Runtime").init(require("core.imgui.backend.Null").new())
		iup = require("core.imgui.iup")
	end)
	after_each(function() package.path, package.loaded.iupraw = old_path, old_raw end)
	local function count(root, pred)
		local n = pred(root) and 1 or 0
		for i = 0, iup.GetChildCount(root) - 1 do n = n + count(iup.GetChild(root, i), pred) end
		return n
	end
	local function titled(text) return function(w) return iup.GetAttribute(w, "TITLE") == text end end
	local function containing(text) return function(w)
		return (iup.GetAttribute(w, "TITLE") or ""):find(text, 1, true) ~= nil
	end end

	it("shows the selected result's overview once, with the type capitalised", function()
		local api = require("ui.metadata").new({iup=iup}, {})
		api.capture("selected")
		assert.equals(1, count(api.widget, titled("The General (1926)")))
		assert.equals(1, count(api.widget, titled("Movie")))
		assert.equals(1, count(api.widget, containing("A railway engineer crosses")))
		assert.equals(0, count(api.widget, containing(" — ")))
		iup.Destroy(api.widget)
	end)

	it("keeps the inline caption where the page has no preview of its own", function()
		local api = require("ui.metadata_match").new({iup=iup}, {})
		api.capture("selected")
		assert.equals(1, count(api.widget, containing("The General — A railway engineer")))
		iup.Destroy(api.widget)
	end)

	it("keeps the hero's words, synopsis included, inside a narrow hero", function()
		local Layout = require("core.imgui.Layout")
		local Element = require("core.imgui.Element")
		local hero = require("ui.spotlight").new({iup=iup}, { art=function() return nil end,
			on_play=function() end, on_info=function() end })
		local long = string.rep("Two rival engineers keep a failing harbour alive ", 4)
		hero.setItems({ { id=1, title="Quarter Island", year=2011, minutes=98, resolution="1080p", overview=long } })
		local box = iup.hbox({ hero.widget, EXPAND="YES" })
		Layout.run(box, 640, 300)
		local frame = Element.state(hero.widget)
		assert.is_true(frame.w <= 640, "hero " .. frame.w)
		local function find(root)
			if iup.GetAttribute(root, "TITLE") == long then return root end
			for i = 0, iup.GetChildCount(root) - 1 do
				local f = find(iup.GetChild(root, i)); if f then return f end
			end
		end
		local overview = assert(find(hero.widget), "overview label")
		local s = Element.state(overview)
		assert.is_true(s.x + s.w <= frame.x + frame.w, "synopsis ends at " .. (s.x + s.w) .. " past " .. (frame.x + frame.w))
		iup.Destroy(box)
	end)

	it("lets the Fits tonight summary shorten instead of widening Home", function()
		local src = assert(io.open("extensions/media/ui/library.lua")):read("*a")
		local block = src:match('local plan_summary = L.sectionTitle%(iup, ""%)(.-)local function refill_plan')
		assert.truthy(block and block:find('"RASTERSIZE", "1x"', 1, true))
		assert.truthy(block:find('"TEXTELLIPSIS", "YES"', 1, true))
	end)
end)

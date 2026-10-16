-- spec/carbon_layout_spec.lua — core.lib.CarbonLayout, the spacing vocabulary.
--
-- The module is data plus arithmetic, so the interesting assertions are about
-- fidelity rather than behaviour:
--
--   * the scale matches IBM's published table exactly — a token that has drifted
--     from Carbon by a pixel is worse than no token, because every call site now
--     believes it is Carbon-correct and is not
--   * `margin`/`gap` emit the shapes IUP actually parses ("HxV" and a bare pixel
--     count); a plausible-looking string IUP silently ignores is the failure mode
--     these helpers exist to eliminate
--   * off-scale values pass through rather than snapping, so the rare deliberate
--     exception is still expressible
--   * the builders tag widgets with a THEMEROLE and never a literal color, which
--     is what stops headings surviving onto a theme they were not written for
--
-- IUP is faked: the builders take it as an argument precisely so this file needs
-- no GUI toolkit.

local L = require("core.lib.CarbonLayout")

-- Records what was asked for, so a builder's output can be inspected as data.
local function fake_iup()
	local iup = {}
	local function node(kind)
		return function(def)
			local n = { kind = kind, children = {} }
			for k, v in pairs(def or {}) do
				if type(k) == "number" then n.children[k] = v else n[k] = v end
			end
			return n
		end
	end
	iup.vbox = node("vbox")
	iup.hbox = node("hbox")
	iup.flatlabel = node("flatlabel")
	iup.fill = node("fill")
	return iup
end

describe("CarbonLayout scale", function()
	it("matches IBM's published spacing table", function()
		-- https://carbondesignsystem.com/elements/spacing/overview/
		assert.are.same(
			{ 2, 4, 8, 12, 16, 24, 32, 40, 48, 64, 80, 96, 160 },
			{
				L.SPACING[1], L.SPACING[2], L.SPACING[3], L.SPACING[4],
				L.SPACING[5], L.SPACING[6], L.SPACING[7], L.SPACING[8],
				L.SPACING[9], L.SPACING[10], L.SPACING[11], L.SPACING[12],
				L.SPACING[13],
			})
	end)

	it("resolves a token number to its pixel value", function()
		assert.are.equal(16, L.px(5))
		assert.are.equal(2, L.px(1))
		assert.are.equal(160, L.px(13))
	end)

	it("treats zero and nil as no space", function()
		assert.are.equal(0, L.px(0))
		assert.are.equal(0, L.px(nil))
		assert.are.equal(0, L.px(-4))
	end)

	it("passes off-scale pixel counts through instead of snapping them", function()
		-- The rare deliberate exception (matching a native control's own metrics)
		-- has to stay expressible, or call sites go back to raw strings.
		assert.are.equal(154, L.px(154))
	end)
end)

describe("CarbonLayout IUP attribute helpers", function()
	it("emits MARGIN as IUP's HORIZONTALxVERTICAL pixel pair", function()
		assert.are.equal("16x16", L.margin(5))
		assert.are.equal("16x8", L.margin(5, 3))
		assert.are.equal("0x0", L.margin(0))
	end)

	it("emits GAP as a bare pixel count string", function()
		assert.are.equal("8", L.gap(3))
		assert.are.equal("0", L.gap(0))
	end)

	it("emits 0 for an omitted RASTERSIZE axis, never an empty one", function()
		-- IUP's parser wants two integers and discards the whole attribute if
		-- either is missing, so "400x" sets NO width rather than a free height.
		-- Getting this wrong is silent: the widget simply keeps stretching.
		assert.are.equal("400x0", L.size(400))
		assert.are.equal("0x120", L.size(nil, 120))
		assert.are.equal("400x120", L.size(400, 120))
	end)

	it("uses IUP's 65535 sentinel for an unbounded MAXSIZE axis", function()
		-- 0 would mean "maximum of zero" here and collapse the widget, which is
		-- why MAXSIZE cannot share `size`.
		assert.are.equal("880x65535", L.maxSize(880))
		assert.are.equal("65535x120", L.maxSize(nil, 120))
		assert.are.equal("880x120", L.maxSize(880, 120))
	end)
end)

describe("CarbonLayout.nearest", function()
	it("snaps a hand-tuned value onto the scale", function()
		local step, px = L.nearest(5)
		assert.are.equal(2, step)
		assert.are.equal(4, px)
	end)

	it("breaks a tie toward the more generous step", function()
		-- 6 is equidistant from 4 and 8. Carbon treats too-tight spacing as the
		-- worse failure, so the larger step wins.
		local _, px = L.nearest(6)
		assert.are.equal(8, px)
	end)

	it("returns an exact match unchanged", function()
		local step, px = L.nearest(24)
		assert.are.equal(6, step)
		assert.are.equal(24, px)
	end)
end)

describe("CarbonLayout builders", function()
	it("tags typography with a theme role and never a literal color", function()
		local iup = fake_iup()
		for _, built in ipairs({
			{ w = L.pageTitle(iup, "T"),    role = "pagetitle" },
			{ w = L.pageSubtitle(iup, "S"), role = "pagesubtitle" },
			{ w = L.sectionTitle(iup, "H"), role = "sectiontitle" },
			{ w = L.hint(iup, "h"),         role = "hint" },
		}) do
			assert.are.equal(built.role, built.w.THEMEROLE)
			-- A literal here is exactly the bug this replaced: a heading colored
			-- for one theme and unreadable on every other.
			assert.is_nil(built.w.FGCOLOR)
			assert.is_nil(built.w.FONT)
		end
	end)

	it("omits the subtitle from a page header when there is none", function()
		local iup = fake_iup()
		assert.are.equal(2, #L.pageHeader(iup, "Title", "Subtitle").children)
		assert.are.equal(1, #L.pageHeader(iup, "Title").children)
		assert.are.equal(1, #L.pageHeader(iup, "Title", "").children)
	end)

	it("applies a tokenized gap to a stack", function()
		local iup = fake_iup()
		local box = L.stack(iup, { 1, 2 }, 5)
		assert.are.equal("vbox", box.kind)
		assert.are.equal("16", box.GAP)
	end)

	it("lets an explicit attribute override the token default", function()
		-- Builders fill in defaults; they must not overwrite a caller who has a
		-- reason to differ, or every exception forces a raw iup.vbox.
		local iup = fake_iup()
		local box = L.stack(iup, { 1, GAP = "3", EXPAND = "YES" })
		assert.are.equal("3", box.GAP)
		assert.are.equal("YES", box.EXPAND)
	end)

	it("centers a row vertically by default", function()
		local iup = fake_iup()
		local row = L.row(iup, { 1, 2 })
		assert.are.equal("hbox", row.kind)
		assert.are.equal("ACENTER", row.ALIGNMENT)
	end)

	it("gives a page the page padding and the section gap", function()
		local iup = fake_iup()
		local page = L.page(iup, { 1 })
		assert.are.equal(L.margin(L.ROLE.page), page.MARGIN)
		assert.are.equal(L.gap(L.ROLE.section_gap), page.GAP)
	end)
end)

describe("CarbonLayout named roles", function()
	it("keeps every layout role on the spacing scale", function()
		for name, step in pairs(L.ROLE) do
			assert(L.SPACING[step] ~= nil,
				"layout role " .. name .. " is not a spacing token")
		end
	end)

	it("separates sections more than the rows inside them", function()
		-- Carbon builds hierarchy out of space: if these ever invert, grouped
		-- content stops reading as grouped.
		assert.is_true(L.px(L.ROLE.section_gap) > L.px(L.ROLE.row_gap))
		assert.is_true(L.px(L.ROLE.row_gap) <= L.px(L.ROLE.inline_gap))
	end)
end)

describe("CarbonLayout.CARBON component metrics", function()
	it("exposes the full set of Carbon component sizes", function()
		-- Each of these drives a real component; a missing key means a caller
		-- falls back to a raw literal and the corresponding widget drifts from
		-- the Carbon spec silently.
		local required = {
			"button_default", "button_sm",
			"input_height",
			"table_row", "table_row_compact",
			"tab_height", "tab_indicator",
			"sidenav_item", "sidenav_accent",
			"tile_padding",
		}
		for _, key in ipairs(required) do
			assert.is_not_nil(L.CARBON[key], "CARBON." .. key .. " is missing")
		end
	end)

	it("matches Carbon's published component heights", function()
		-- https://carbondesignsystem.com/components/ (2026 reference)
		-- If these change, the tokens source must be re-checked before bumping.
		assert.are.equal(48, L.CARBON.button_default)
		assert.are.equal(40, L.CARBON.button_sm)
		assert.are.equal(40, L.CARBON.input_height)
		assert.are.equal(48, L.CARBON.table_row)
		assert.are.equal(40, L.CARBON.table_row_compact)
		assert.are.equal(40, L.CARBON.tab_height)
		assert.are.equal(3,  L.CARBON.tab_indicator)
		assert.are.equal(48, L.CARBON.sidenav_item)
		assert.are.equal(4,  L.CARBON.sidenav_accent)
	end)

	it("expresses tile_padding as a spacing-scale value", function()
		-- tile_padding must stay on the scale so tile content aligns with page
		-- margins set at the same step.
		assert.are.equal(L.SPACING[5], L.CARBON.tile_padding)
	end)

	it("keeps default and compact row heights distinct", function()
		-- They share the same pixel value as button sizes; if they ever
		-- converge, compact rows become invisible to users.
		assert.is_true(L.CARBON.table_row > L.CARBON.table_row_compact)
	end)
end)

describe("CarbonLayout.gutter", function()
	it("defaults to 2px (spacing step 1)", function()
		assert.are.equal(2, L.gutter())
	end)

	it("accepts an explicit step", function()
		assert.are.equal(4, L.gutter(2))
		assert.are.equal(8, L.gutter(3))
	end)

	it("a step-1 seam is the narrowest on the scale", function()
		-- Carbon tile grids use step 1 (2px) as the canonical seam width.
		-- Any narrower would require going off-scale.
		assert.are.equal(L.SPACING[1], L.gutter(1))
	end)
end)

-- Native smoke test: run with Lunar.exe scripts/branding_check.lua.
-- LUNAR_REPO points at this checkout; LUNAR_PROFILE_DIR at the sibling packs.
-- Maps widgets without showing a window; never reads or writes user settings.
local iup = require("iup")
local ffi = require("ffi")
local ptr = require("core.classes.IupFFI").ptr
local png = require("pngimage")
local VectorIcon = require("core.ui.VectorIcon")
local Kit = require("core.ui.Kit")
local OrgProfile = require("core.lib.OrgProfile")
local repo = assert(os.getenv("LUNAR_REPO"))
local packs = assert(os.getenv("LUNAR_PROFILE_DIR"))
local function check()
	assert(VectorIcon.available)
	Kit.setIconDir(repo .. "/assets/Icons")
	ffi.cdef("char *IupGetAttribute(void *ih, const char *name);")
	local function pixels(img)
		return ffi.cast("unsigned char *", ffi.C.IupGetAttribute(ptr(img), "WID"))
	end
	for _, id in ipairs({ "microchip", "hpe" }) do
		local profile = assert(OrgProfile.load(packs .. "/" .. id))
		assert(#profile.warnings == 0)
		local paths = { profile.brand.logo.light, profile.brand.logo.dark }
		for _, path in pairs(profile.brand.logo.themes or {}) do paths[#paths + 1] = path end
		for _, path in ipairs(paths) do
			local img = assert(png.to_image(path, 18))
			assert(tonumber(iup.GetAttribute(img, "HEIGHT")) == 18)
			assert(tonumber(iup.GetAttribute(img, "WIDTH")) > 18)
			iup.Destroy(img)
			local handle = assert(VectorIcon.logoHandle(iup, path, 18))
			assert(handle == VectorIcon.logoHandle(iup, path, 18))
		end
	end
	assert(not png.to_image("missing.png", 18))
	assert(not png.to_image(packs .. "/microchip/assets/Microchip-Logo.svg", 18))
	assert(not png.to_image(packs .. "/hpe/assets/HPE_logo_statusbar.png", 0))
	assert(not png.to_image(packs .. "/hpe/assets/HPE_logo_statusbar.png", 8193))

	-- Synthetic fixtures exercise limits and transparent-edge averaging in the C decoder.
	local fixtures = repo .. "/build/branding-fixtures/"
	local blended = assert(png.to_image(fixtures .. "alpha.png", 1))
	local p = pixels(blended)
	assert(p[0] == 255 and p[1] == 0 and p[2] == 0 and p[3] == 128,
		"transparent blue must not fringe the half-opaque red average")
	iup.Destroy(blended)
	for _, name in ipairs({ "oversized.png", "dimensions.png", "corrupt.png", "truncated.png" }) do
		local img, err = png.to_image(fixtures .. name, 18)
		assert(not img and type(err) == "string", name)
	end

	local profile = assert(OrgProfile.load(packs .. "/microchip"))
	local icon = assert(Kit.icon(iup, profile.brand.icon:sub(1, -5), 16, "brand"))
	local data = pixels(iup.GetHandle(icon))
	local left, top, right, bottom = 16, 16, -1, -1
	for y = 0, 15 do for x = 0, 15 do
		if data[(y * 16 + x) * 4 + 3] > 16 then
			left, right = math.min(left, x), math.max(right, x)
			top, bottom = math.min(top, y), math.max(bottom, y)
		end
	end end
	assert(right - left >= 13 and bottom - top >= 13, "mark should fill the icon slot")
	assert(math.abs((left + right) / 2 - 7.5) <= 1, "mark horizontally centered")
	assert(math.abs((top + bottom) / 2 - 7.5) <= 1.5, "mark vertically centered (Kit optical offset)")

	local root = iup.flattabs({})
	local group = iup.flattabs({ iup.vbox({ iup.label({ TITLE = "child" }) }), TABTITLE = "Microchip Tools" })
	Kit.bindIcon(iup, group, profile.brand.icon:sub(1, -5), { role = "brand", attribute = "TABIMAGE" })
	iup.Append(root, group)
	local attr = require("core.lib.attr")
	assert(attr.get(iup, group, "_IUPLUNAR_KITICON"), "the binding must read back: iup.GetAttribute hides _IUP names")
	assert(not attr.get(iup, iup.GetChild(group, 0), "_IUPLUNAR_KITICON"), "group bindings must not inherit")
	local StatusBar = require("core.ui.StatusBar")
	local bar = StatusBar.new({ iup = iup, icon_dir = repo .. "/assets/Icons", has_logo = true, logo_tip = profile.name })
	assert(iup.GetAttribute(bar._logo, "IMAGE"), "image required before mapping")
	local title = require("core.ui.TitleBar").new({ iup = iup, root = root,
		icon = function(w, name, size, role, attribute)
			Kit.bindIcon(iup, w, name, { size = size, role = role, attribute = attribute })
		end })
	local dlg = iup.dialog({ iup.vbox({ title:widget(), root, bar:widget() }), RASTERSIZE = "1200x600" })
	assert(iup.Map(dlg) == iup.NOERROR)
	bar:fit(1200)
	local callbacks = {}
	local theme
	local manager = { _root = dlg, onApply = function(_, fn) callbacks[#callbacks + 1] = fn end,
		activeTheme = function() return theme end }
	require("core.ui.ThemeReactor").bindThemeManager(manager)
	package.path = packs .. "/microchip/extensions/microchip-theme/?.lua;" .. package.path
	local previous
	for _, mode in ipairs({ "Light", "Dark" }) do
		theme = require("Microchip" .. mode .. "Theme"):new()
		for _, fn in ipairs(callbacks) do fn(theme) end
		local path = OrgProfile.logoFor(profile.brand, theme:id(), theme:isDark())
		local logo = assert(VectorIcon.logoHandle(iup, path, 18))
		assert(logo ~= previous)
		previous = logo
		bar:setLogo(logo)
		assert(iup.GetAttribute(bar._logo, "IMAGE") == logo)
		assert(iup.GetAttribute(bar._logo_box, "FLOATING") == "NO")
		title:sync({ group })
		assert(iup.GetAttribute(title:groupStrip(), "TABSIMAGEPOSITION") == "RIGHT")
		assert(iup.GetAttributeId(title:groupStrip(), "TABIMAGE", 0) == iup.GetAttributeId(root, "TABIMAGE", 0))
		assert(VectorIcon.roleColor("brand"):lower() == "#ed1b2e")
	end
	local branded = iup.GetAttributeId(root, "TABIMAGE", 0)
	theme = require("core.classes.Themes.LunarDarkTheme"):new()
	for _, fn in ipairs(callbacks) do fn(theme) end
	assert(iup.GetAttributeId(root, "TABIMAGE", 0) ~= branded, "a theme switch must repaint bound icons")
	assert(VectorIcon.roleColor("brand") == VectorIcon.roleColor("neutral"))
	bar:fit(999)
	assert(iup.GetAttribute(bar._logo_box, "FLOATING") == "YES")
	bar:fit(1200)
	bar:setLogo(nil)
	assert(iup.GetAttribute(bar._logo_box, "FLOATING") == "YES")
	iup.Destroy(dlg)
end

local ok, err = xpcall(check, debug.traceback)
local report = assert(io.open(repo .. "/build/branding-check.txt", "w"))
report:write(ok and "PASS: PNG bounds/alpha/cache, pack assets, centered SVG, mapped logo swaps, group tint and title image\n" or tostring(err))
report:close()
os.exit(ok and 0 or 1)

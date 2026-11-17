-- Round 8: the Media Server Attention list is a table again (icon column, "Next:" indented
-- under the issue, the repair on the issue line under its "Repair" header).
describe("media server attention table", function()
	local iup, Layout, Element, old_path, old_raw, Kit, old_icon
	before_each(function()
		old_path, old_raw = package.path, package.loaded.iupraw
		package.path = "extensions/media/?.lua;" .. old_path
		package.loaded.iupraw = require("core.imgui.native.iupraw")
		require("core.imgui.Runtime").init(require("core.imgui.backend.Null").new())
		iup = require("core.imgui.iup")
		Layout = require("core.imgui.Layout")
		Element = require("core.imgui.Element")
		-- The Null backend draws no vector icons: name them instead.
		Kit = require("core.ui.Kit")
		old_icon = Kit.icon
		Kit.icon = function(_, name) return name end
	end)
	after_each(function()
		package.path, package.loaded.iupraw = old_path, old_raw
		Kit.icon = old_icon
	end)

	local function find(root, title)
		if iup.GetAttribute(root, "TITLE") == title then return root end
		for n = 0, iup.GetChildCount(root) - 1 do
			local found = find(iup.GetChild(root, n), title)
			if found then return found end
		end
	end
	local function rect(e) local s = Element.state(e); return s.x, s.y, s.w, s.h end

	local function server_page()
		local model = require("libs.repair_sample").apply({ films = {}, shows = {}, server = { name = "Local", analysis = "on" } })
		local repaired
		local api = require("ui.server").new({ iup = iup }, { model = model,
			on_repair = function(action, done) repaired = action; done(true) end })
		local root = iup.vbox{ api.widget, SHRINK = "YES" }
		Layout.run(root, 1800, 1000)
		return api, function() return repaired end
	end

	it("puts each repair on its issue line, right-aligned under the Repair header", function()
		local api = server_page()
		local header = find(api.widget, "Repair")
		local issue = find(api.widget, "Shows: 3 files are offline — The media drive is disconnected.")
		local repair = find(api.widget, "Rescan library")
		assert.equals(iup.GetParent(issue), iup.GetParent(repair))
		local hx, _, hw = rect(header)
		local rx, _, rw = rect(repair)
		-- "Repair" ends where the button's label ends: the header's padding is the cell
		-- inset plus the button's own.
		local function pad(e) return tonumber(tostring(iup.GetAttribute(e, "PADDING") or "0"):match("^(%d+)")) or 0 end
		assert.equals(rx + rw - pad(repair), hx + hw - pad(header))
		local row_right = select(1, rect(iup.GetParent(repair))) + select(3, rect(iup.GetParent(repair)))
		assert.equals(row_right, rx + rw)
		assert.equals("actionbutton", iup.GetAttribute(repair, "THEMEROLE"))
		iup.Destroy(api.widget)
	end)

	it("gives the status icon its own column and indents the next step under the issue", function()
		local api = server_page()
		local issue = find(api.widget, "Marrow: analysis failed — ffprobe could not read the media file.")
		local next_step = find(api.widget, "Next: Check the file, then retry.")
		assert.is_nil(iup.GetAttribute(issue, "IMAGE"))
		local icon = iup.GetChild(iup.GetParent(issue), 0)
		assert.truthy(iup.GetAttribute(icon, "IMAGE"))
		local ix, iy = rect(issue)
		local nx, ny = rect(next_step)
		assert.equals(ix, nx)
		assert.is_true(ny > iy)
		assert.equals("reading_muted", iup.GetAttribute(next_step, "THEMEROLE"))
		local cx = rect(icon)
		assert.is_true(cx < ix)
		iup.Destroy(api.widget)
	end)

	it("keeps one severity per kind and runs the repair", function()
		local api, repaired = server_page()
		local frame = find(api.widget, "The Salt Line: frame failed — ffmpeg could not make a preview frame.")
		local offline = find(api.widget, "Shows: 3 files are offline — The media drive is disconnected.")
		local function icon_of(label) return iup.GetAttribute(iup.GetChild(iup.GetParent(label), 0), "IMAGE") end
		assert.equals("warning--alt--filled", icon_of(frame))
		assert.equals("error--filled", icon_of(offline))
		find(api.widget, "Sync source"):flat_action()
		assert.equals("/v1/sources/1/sync", repaired().path)
		iup.Destroy(api.widget)
	end)

	local function themed(api, palette)
		local reactor = require("core.ui.ThemeReactor")
		local saved = reactor.palette
		reactor.palette = function() return palette end
		api:_afterThemePass()
		reactor.palette = saved
		local header = find(api.widget, "Issue / next step")
		local row = iup.GetParent(iup.GetParent(find(api.widget, "Marrow: analysis failed — ffprobe could not read the media file.")))
		local rows = iup.GetParent(row)
		local divider = iup.GetChild(rows, iup.GetChildPos(rows, row) + 1)
		return iup.GetAttribute(header, "BGCOLOR"), iup.GetAttribute(find(api.widget, "Repair"), "BGCOLOR"),
			iup.GetAttribute(divider, "BGCOLOR")
	end

	it("draws a Carbon table header and row rules from the Carbon table tokens", function()
		local api = server_page()
		local issue, repair, rule = themed(api, { layer01 = "10 10 10", layerAccent01 = "1 2 3", borderSubtle01 = "4 5 6" })
		assert.equals("1 2 3", issue)
		assert.equals("1 2 3", repair)
		assert.equals("4 5 6", rule)
		iup.Destroy(api.widget)
	end)

	it("keeps a Lunar table header and rows on the page surface", function()
		local api = server_page()
		local issue, repair, rule = themed(api, { layer01 = "10 10 10", borderSubtle01 = "4 5 6" })
		assert.equals("10 10 10", issue)
		assert.equals("10 10 10", repair)
		assert.equals("10 10 10", rule)
		iup.Destroy(api.widget)
	end)
end)

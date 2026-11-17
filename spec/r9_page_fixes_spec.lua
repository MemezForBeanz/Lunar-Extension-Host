-- Round 9: pages size to their content and stay reachable in a short window.
describe("round 9 page fixes", function()
	local iup, Layout, Element, old_path, old_raw, Kit, old_icon
	before_each(function()
		old_path, old_raw = package.path, package.loaded.iupraw
		package.path = "extensions/media/?.lua;" .. old_path
		package.loaded.iupraw = require("core.imgui.native.iupraw")
		require("core.imgui.Runtime").init(require("core.imgui.backend.Null").new())
		iup = require("core.imgui.iup")
		Layout = require("core.imgui.Layout")
		Element = require("core.imgui.Element")
		Kit = require("core.ui.Kit")
		old_icon = Kit.icon
		Kit.icon = function(_, name) return name end
	end)
	after_each(function()
		package.path, package.loaded.iupraw = old_path, old_raw
		Kit.icon = old_icon
	end)

	local function find(root, pred)
		if pred(root) then return root end
		for n = 0, iup.GetChildCount(root) - 1 do
			local found = find(iup.GetChild(root, n), pred)
			if found then return found end
		end
	end
	local function titled(text) return function(w) return iup.GetAttribute(w, "TITLE") == text end end
	local function starting(text) return function(w) return (iup.GetAttribute(w, "TITLE") or ""):sub(1, #text) == text end end
	local function scroll_above(w)
		local p = iup.GetParent(w)
		while p do
			local class = iup.GetClassName(p)
			if class == "scrollbox" or class == "flatscrollbox" then return p end
			p = iup.GetParent(p)
		end
	end
	local function lay(widget, w, h)
		local root = iup.vbox{ widget, SHRINK = "YES" }
		Layout.run(root, w, h)
		return root
	end

	it("lays the Metadata overview out as tall as its lines, and scrolls the page in a short window", function()
		local api = require("ui.metadata").new({ iup = iup }, {})
		api.capture("selected")
		lay(api.widget, 1100, 800)
		local overview = find(api.widget, starting("A railway engineer"))
		local _, line = require("core.imgui.Fonts").forElement(overview):charsize()
		assert.equals(line, Element.state(overview).h)
		local scroll = scroll_above(overview)
		assert.truthy(scroll)
		lay(api.widget, 1100, 420)
		assert.is_true(tonumber(iup.GetAttribute(scroll, "YMAX")) > tonumber(iup.GetAttribute(scroll, "DY")))
		iup.Destroy(api.widget)
	end)

	it("puts the Media server's View actions beside their counts, styled as actions", function()
		local model = require("libs.repair_sample").apply({ films = {}, shows = {}, server = { name = "Local", analysis = "on" } })
		local api = require("ui.server").new({ iup = iup }, { model = model, on_repair = function(_, done) done(true) end })
		lay(api.widget, 1800, 1000)
		local views = {}
		local function collect(w)
			if iup.GetClassName(w) == "flatbutton" and iup.GetAttribute(w, "TITLE") == "View"
				and iup.GetAttribute(w, "VISIBLE") ~= "NO" then views[#views + 1] = w end
			for n = 0, iup.GetChildCount(w) - 1 do collect(iup.GetChild(w, n)) end
		end
		collect(api.widget)
		assert.equals(2, #views)
		for _, view in ipairs(views) do
			assert.equals("actionbutton", iup.GetAttribute(view, "THEMEROLE"))
			-- the count it opens is the label right before it on the same row
			local count = iup.GetChild(iup.GetParent(view), 0)
			assert.equals("pagetitle", iup.GetAttribute(count, "THEMEROLE"))
			local cs, vs = Element.state(count), Element.state(view)
			assert.is_true(vs.x >= cs.x + cs.w and vs.x - (cs.x + cs.w) <= 16)
		end
		iup.Destroy(api.widget)
	end)

	it("scrolls the Sources detail column so the whole provider form is reachable", function()
		local providers = { { id = "jf", name = "Jellyfin or Emby server", summary = "Another media server.",
			fields = { { id = "url", label = "Server address" }, { id = "key", label = "API key" } } } }
		local api = require("ui.sources").new({ iup = iup }, { sources = {}, providers = providers,
			on_add = function() end, on_sync = function() end, on_remove = function() end })
		lay(api.widget, 1100, 800)
		local title = find(api.widget, titled("Provider database"))
		assert.truthy(scroll_above(title))
		iup.Destroy(api.widget)
	end)
end)

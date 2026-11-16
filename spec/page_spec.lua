local Kit = require("core.ui.Kit")
describe("declarative tool page", function()
    local iup
    before_each(function()
        iup = { DEFAULT = 0 }
        for _, kind in ipairs({ "text", "flatlabel", "flatbutton", "vbox", "hbox", "fill", "split", "zbox", "flatframe" }) do
            iup[kind] = function(attrs) attrs.kind = kind; return attrs end
        end
        iup.SetAttribute = function(w, k, v) w[k] = v end
        iup.GetAttribute = function(w, k) return w[k] end
        iup.ResetAttribute = function(w, k) w[k] = nil end
        iup.Refresh = function() end
        iup.Detach = function() end
        iup.GetClassName = function(w) return w.kind end
        iup.GetChild = function(w, n) return w[n + 1] end
    end)
    it("keeps callbacks and the primary in the header when the mode changes", function()
        local hit
        local page = Kit.page(iup, { title = "Tests", primary = { title = "Run", action = function() hit = "run" end } })
        page.primary:flat_action()
        assert.equals("run", hit)
        page:setPrimary{ title = "Stop", action = function() hit = "stop" end }
        page.primary:flat_action()
        assert.equals("stop", hit)
        assert.equals(page.primary, page.header[#page.header])
    end)
    it("uses the pane width for config and inspector breakpoints", function()
        local page = Kit.page(iup, { config = { widget = iup.vbox{} }, main = iup.vbox{}, inspector = { widget = iup.vbox{} } })
        page:fit(1200)
        assert.equals("NO", page.config.FLOATING)
        assert.equals("YES", page.configure.FLOATING)
        page:fit(700)
        assert.equals("YES", page.config.FLOATING)
        assert.equals("NO", page.configure.FLOATING)
        page.configure:flat_action()
        assert.equals("NO", page.config.FLOATING)
        page:openInspector(true)
        assert.equals("120", page.inspectorSplit.VALUE)
        page:openInspector(false)
        assert.equals("1000", page.inspectorSplit.VALUE)
    end)
    it("folds secondary actions and retains the full state as a tooltip", function()
        local page = Kit.page(iup, { primary={title="Parse"}, secondary={{title="Browse"},{title="New parse"}} })
        page:fit(700)
        assert.equals("YES", page.secondary[1].FLOATING)
        assert.equals("NO", page.overflow.FLOATING)
        assert.equals("NO", page.primary.FLOATING)
        page:setState("info", "A long state sentence")
        assert.equals("A long state sentence", page.stateLine.TIP)
        page:setRunState("working")
        assert.equals("Stop", page.primary.TITLE)
        page:setRunState("ready")
        assert.equals("Parse", page.primary.TITLE)
    end)
    it("overlays narrow details without hiding the subject on ImGui", function()
        iup._IMGUI = true
        local page = Kit.page(iup, {main=iup.vbox{}, inspector={title="Details",widget=iup.vbox{}}})
        page:fit(700)
        page:openInspector(true)
        assert.equals("1000", page.inspectorSplit.VALUE)
        assert.equals("NO", page.mainHost.FLOATING)
        assert.equals("YES", page.inspector.FLOATING)
        assert.equals("YES", page.inspector.VISIBLE)
        page:openInspector(false)
        assert.equals("NO", page.inspector.VISIBLE)
    end)
    it("keeps the summary visible and opens failures, closes successes", function()
        local page = Kit.page(iup, { dock = { widget = iup.vbox{}, summary = "No output" } })
        assert.is_false(page.dockOpen)
        page:setDockSummary("error", "Build failed", function() end)
        assert.is_true(page.dockOpen)
        assert.equals("Build failed", page.dockSummary.TITLE)
        assert.equals("NO", page.dockAction.FLOATING)
        page:setDockSummary("success", "Build complete")
        assert.is_false(page.dockOpen)
        assert.equals("IGNORE", page.dockContent.FLOATING)
    end)
    it("stages an operation without showing results from the previous run", function()
        iup.Append = function(parent, child) table.insert(parent, child) end
        local page = Kit.page(iup, {title="Scan Chain", main=iup.vbox{ iup.flatlabel{TITLE="Previous successful result"} }, primary={title="Parse"}})
        local fixtures = dofile("scripts/ui_fixtures.lua")
        fixtures.tool_state(page, "working")
        assert.equals("YES", page.main.FLOATING)
        assert.equals("NO", page.capturePlaceholder.FLOATING)
        assert.equals("Stop", page.primary.TITLE)
        fixtures.tool_state(page, "failed")
        assert.is_true(page.dockOpen)
        assert.matches("incomplete device record", page.dockContent.VALUE, 1, true)
        assert.equals("YES", page.main.FLOATING)
        assert.equals("Retry", page.primary.TITLE)
        assert.is_nil(page.stateLine.TITLE:find("fixture", 1, true))
    end)
    it("bounds remembered widths and saves dragged geometry per page", function()
        local values = { ["page.Test.config"] = 999 }
        local settings = { get = function(_, k) return values[k] end, set = function(_, k, v) values[k] = v end, save = function() end }
        local page = Kit.page(iup, { title = "Test", settings = settings, config = { widget = iup.vbox{} } })
        assert.equals(360, page.configSize)
        page:fit(1200)
        page.configSplit.VALUE = "250"
        page.configSplit:valuechanged_cb()
        assert.equals(300, values["page.Test.config"])
    end)
    it("keeps extra secondary actions available in overflow", function()
        local page = Kit.page(iup, { secondary = { { title = "One" }, { title = "Two" }, { title = "Three" } } })
        assert.equals(2, #page.secondary)
        assert.equals("NO", page.overflow.FLOATING)
        assert.equals("Three", page.secondarySpecs[3].title)
    end)
end)

describe("tool page header geometry", function()
    it("pins native and grouped primaries to the page padding at every pane width", function()
        local iup = require("core.lui.test").boot({})
        local Layout = require("core.imgui.Layout")
        local Element = require("core.imgui.Element")
        for _, grouped in ipairs({ false, true }) do
            local primary = grouped and { widget = iup.hbox{ iup.flatbutton{TITLE="Build"} } } or { title="Run" }
            local page = Kit.page(iup, {title="Build Queue", primary=primary, secondary={{title="Browse"}}})
            for _, width in ipairs({ 560, 700, 1036, 1872 }) do
                page:fit(width)
                Layout.run(page.root, width, 800)
                local action = Element.state(page.primary)
                assert.equal(width - require("core.lib.CarbonLayout").PAGE.padding, action.x + action.w)
            end
        end
    end)
end)

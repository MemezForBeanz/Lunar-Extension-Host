describe("round 7 media polish", function()
    local iup, old_path, old_raw
    before_each(function()
        old_path, old_raw = package.path, package.loaded.iupraw
        package.path = "extensions/media/?.lua;" .. old_path
        package.loaded.iupraw = require("core.imgui.native.iupraw")
        require("core.imgui.Runtime").init(require("core.imgui.backend.Null").new())
        iup = require("core.imgui.iup")
    end)
    after_each(function() package.path, package.loaded.iupraw = old_path, old_raw end)
    local function find(root, title)
        if iup.GetAttribute(root, "TITLE") == title then return root end
        for n=0,iup.GetChildCount(root)-1 do
            local found = find(iup.GetChild(root,n),title)
            if found then return found end
        end
    end
    it("replaces generic Preview copy on selection and restores it on reset", function()
        local api = require("ui.metadata").new({iup=iup}, {})
        local generic = "Search movies, TV shows, and anime without connecting a media server."
        assert.truthy(find(api.widget,generic))
        api.capture("selected")
        assert.is_nil(find(api.widget,generic))
        assert.truthy(find(api.widget,"The General (1926)"))
        assert.truthy(find(api.widget,"movie\nA railway engineer crosses enemy lines to recover his locomotive."))
        api.capture("working")
        assert.truthy(find(api.widget,generic))
        iup.Destroy(api.widget)
    end)
    it("updates preview when navigating among loaded results and clears it for a new search", function()
        local selected
        local api = require("ui.metadata_match").new({iup=iup}, {
            on_selection=function(row) selected=row end,
            on_metadata=function(method, _, _, done)
                if method == "search" then done({id="job"}) else
                    done({state="ready",result={{id=1,title="First"},{id=2,title="Second",year=2001,overview="Second story"}}})
                end
            end,
        })
        api.open({title="Film"})
        api.controls.search:flat_action();api.tick()
        assert.equals("First", selected.title)
        local rows = iup.GetChild(api.widget,2)
        rows:row_action_cb(2)
        assert.equals("Second", selected.title)
        api.controls.search:flat_action()
        assert.is_nil(selected)
        iup.Destroy(api.widget)
    end)
    it("uses real repair buttons and a consistent error summary", function()
        local model = require("libs.repair_sample").apply({films={},shows={},server={name="Local",analysis="on"}})
        local repaired
        local api = require("ui.server").new({iup=iup}, {model=model,on_repair=function(action,done) repaired=action;done(true) end})
        local page = require("core.ui.Page").fromWidget(api.widget)
        assert.matches("4 items need attention", iup.GetAttribute(page.stateLine,"TITLE"))
        local repair = find(api.widget,"Sync source")
        assert.equals("flatbutton",iup.GetClassName(repair))
        assert.equals("actionbutton",iup.GetAttribute(repair,"THEMEROLE"))
        repair:flat_action()
        assert.equals("/v1/sources/1/sync", repaired.path)
        iup.Destroy(api.widget)
    end)
end)

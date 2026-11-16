local Kit = require("core.ui.Kit")
describe("media feed notification", function()
    local iup
    before_each(function()
        iup = { DEFAULT = 0 }
        for _, name in ipairs({"flatlabel", "flatbutton", "hbox"}) do iup[name] = function(t) return t end end
        iup.SetAttribute = function(w,k,v) w[k]=v end
        iup.GetAttribute = function(w,k) return w[k] end
        iup.ResetAttribute = function(w,k) w[k]=nil end
        iup.Refresh = function() end
    end)
    it("keeps recovery independent of dismissal and updates the error sentence", function()
        local recovered = 0
        local notice = Kit.notification(iup, {kind="error",title="Feed unavailable",
            action={title="Manage sources",action=function() recovered=recovered+1 end}})
        notice.widget[2]:flat_action()
        assert.equals(1,recovered)
        assert.is_nil(notice.widget.VISIBLE)
        notice:setTitle("Film club feed: HTTP 503")
        assert.equals("Film club feed: HTTP 503",notice.widget[1].TITLE)
        notice.widget[3]:flat_action()
        assert.equals("NO",notice.widget.VISIBLE)
        assert.equals("YES",notice.widget.FLOATING)
    end)
    it("uses the same notification for attention and origin failures and hides on recovery", function()
        local chunk=assert(loadfile("extensions/media/ui/reliability.lua"))
        local api=chunk().new({iup=iup},{attention={{kind="source",title="Feed: source failed",wrong="HTTP 503"}}})
        assert.equals("Feed: HTTP 503",api.widget[1].TITLE)
        api.setModel({origins={{name="Archive",status="failed",error="Offline"}}})
        assert.equals("Archive: Offline",api.widget[1].TITLE)
        api.setModel({})
        assert.equals("NO",api.widget.VISIBLE)
    end)
end)

describe("metadata action availability", function()
    it("rethemes Apply match on selection and disables it again when cleared", function()
        local buttons, painted = {}, {}
        local widget=function(t) return t or {} end
        local iup={hbox=widget,vbox=widget,fill=widget,flatlabel=widget,
            SetAttribute=function(w,k,v) w[k]=v end}
        local modules={
            ["core.lib.CarbonLayout"]={gap=function() return 0 end,hint=function() return {} end},
            ["core.ui.Kit"]={button=function(_,s) local w={TITLE=s.title};buttons[s.title]=w;return w end,
                statusLine=function() return {} end,setStatus=function() end},
            ["core.ui.FlatField"]={new=function() return {widget={},setValue=function() end} end},
            ["core.ui.FlatDropdown"]={new=function() return {widget={}} end},
            ["libs.metadb"]={providers={}},
            ["core.ui.RowList"]={new=function() return {widget={},setProvider=function() end,select=function() end} end},
        }
        local chunk=assert(loadfile("extensions/media/ui/metadata_match.lua"))
        setfenv(chunk,setmetatable({require=function(name) return assert(modules[name],name) end},{__index=_G}))
        local api=chunk().new({iup=iup,notifyTreeChange=function(_,w) painted[#painted+1]=w.ACTIVE end},{})
        api.capture("selected")
        assert.equals("YES",buttons["Apply match"].ACTIVE)
        assert.equals("YES",painted[#painted])
        api.open({title="Another title"})
        assert.equals("NO",buttons["Apply match"].ACTIVE)
        assert.equals("NO",painted[#painted])
        assert.equals("Select a result to apply its metadata",buttons["Apply match"].TIP)
    end)
end)

describe("media detail breadcrumb", function()
    it("returns to the library from a real header link and keeps Play in that header", function()
        local old_path=package.path
        local old_raw=package.loaded.iupraw
        package.loaded.iupraw=require("core.imgui.native.iupraw")
        local R=require("core.imgui.Runtime")
        R.init(require("core.imgui.backend.Null").new())
        package.path="extensions/media/?.lua;"..old_path
        local ok,err=pcall(function()
            local iup=require("core.imgui.iup")
            local sample=require("libs.sample")
            local model=sample.library()
            local returned=0
            local api=require("ui.title").new({iup=iup},{model=model,
                art=function() return nil end,
                on_back=function() returned=returned+1 end,on_play=function() end,on_mark=function() end,
                pool=function() return {} end,load_seasons=function(_,done) done({}) end,
                decide=function(_,_,done) done({mode="direct"}) end})
            api.setWidth(1036)
            api.open(model.films[6])
            local header=iup.GetChild(api.widget,0)
            local breadcrumb=iup.GetChild(header,0)
            local link=iup.GetChild(breadcrumb,0)
            assert.equals("Films",iup.GetAttribute(link,"TITLE"))
            assert.equals(model.films[6].title,iup.GetAttribute(iup.GetChild(breadcrumb,2),"TITLE"))
            link:flat_action()
            assert.equals(1,returned)
            local primary=iup.GetChild(header,iup.GetChildCount(header)-1)
            assert.equals("primary_btn",iup.GetAttribute(primary,"THEMEROLE"))
            api.open(model.shows[1])
            assert.equals("Shows",iup.GetAttribute(link,"TITLE"))
            iup.Destroy(api.widget)
        end)
        package.path=old_path
        package.loaded.iupraw=old_raw
        assert.is_true(ok,tostring(err))
    end)
end)

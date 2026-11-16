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

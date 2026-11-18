local Runtime = require("core.imgui.Runtime")
local Null = require("core.imgui.backend.Null")
local iup = require("core.imgui.iup")
local E = require("core.imgui.Element")

describe("Time Clock dashboard geometry", function()
    it("keeps history below the cards and the dock inside a narrow page", function()
        local root = os.getenv("LUNAR_ORGPACKS_DIR")
        if not root then pending("set LUNAR_ORGPACKS_DIR"); return end
        root = root:gsub("\\","/") .. "/microchip/extensions/timeclock"
        Runtime.init(Null.new{w=1100,h=620})
        local old_scheduler, old_dev = package.loaded["libs.scheduler"], rawget(_G,"LUNAR_DEV_SHELL")
        package.loaded["libs.scheduler"] = assert(loadfile(root .. "/libs/scheduler.lua"))()
        _G.LUNAR_DEV_SHELL = {}
        local extension = assert(loadfile(root .. "/init.lua"))()
        local panel, fit
        local ctx = {iup=iup,ui={FlatDropdown=require("core.ui.FlatDropdown")},
            settings={get=function() end,set=function() end,save=function() return true end},
            addTab=function(_,_,widget) panel=widget end,
            fitPage=function(_,_,callback) fit=callback end,
            addTimer=function() return iup.timer{} end,onReady=function() end,setStatus=function() end}
        local dialog
        local ok, err = pcall(function()
            extension:register(ctx)
            dialog=iup.dialog{panel,RASTERSIZE="1100x620"}
            iup.Show(dialog)
            _G.LUNAR_DEV_SHELL.pages["Time Clock"].show{employee="Alex",response="Clock In confirmed",
                available={"meal_start"},history={"08:00 Clock In confirmed","Yesterday Clock Out confirmed"}}
            fit(1100)
            iup.Refresh(dialog)
            Runtime.frame()
            local found = {}
            local function walk(node)
                local st=E.state(node)
                found[iup.GetAttribute(node,"TITLE") or ""]=st
                for _,child in ipairs(st.children) do walk(child) end
            end
            walk(panel)
            local history, schedules, dock = found.History, found.Schedules, found["Server response"]
            assert.is_true(history.y > schedules.y)
            assert.is_true(history.y + history.h < 800,"history must stay visible")
            assert.is_true(dock.y + dock.h <= 620,"dock must stay inside the page")
        end)
        extension:shutdown()
        if dialog then iup.Destroy(dialog) end
        package.loaded["libs.scheduler"], _G.LUNAR_DEV_SHELL = old_scheduler, old_dev
        assert.is_true(ok,tostring(err))
    end)
end)

local Workbench = require("core.ui.CodeWorkbench")
describe("editor language server notice", function()
    it("keeps unavailable and failed servers in the actionable notice only", function()
        local iup = require("core.lui.test").boot({})
        local w = setmetatable({_iup=iup, _chip=iup.flatlabel{}, _message=iup.flatlabel{},
            _settings_link=iup.flatbutton{}, _anchor=iup.flatlabel{}}, Workbench)
        for _, state in ipairs({"unavailable", "failed"}) do
            local doc = {binder={state=state, _entry={name="Lua"}, message="Server detail"},
                view={caret=function() return 0 end, diagnosticsOnLine=function() return {} end}}
            w:_showServer(doc)
            w:_showMessage(doc)
            assert.equal("NO",iup.GetAttribute(w._chip,"VISIBLE"))
            assert.equal("NO",iup.GetAttribute(w._settings_link,"FLOATING"))
            assert.matches("Language server",iup.GetAttribute(w._message,"TITLE"))
            doc.binder.state = "running"
            w:_showServer(doc)
            assert.equal("NO",iup.GetAttribute(w._chip,"FLOATING"))
        end
    end)
end)

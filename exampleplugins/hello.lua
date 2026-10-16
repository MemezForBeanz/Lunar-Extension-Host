-- hello.lua — Sample Lunar Extension Host extension
-- Demonstrates the Extension base class with convenience methods.
-- Extensions can also use plain tables with register()/shutdown() if preferred.

local Extension = require("core.classes.Extension")

local Hello = Extension:subclass("HelloExtension")

function Hello:initialize()
    Extension.initialize(self, "Hello Extension", "1.0")
end

function Hello:register(ctx)
    local iup = ctx.iup

    -- Add a tab using the base class convenience method
    local panel = iup.vbox{
        iup.fill{},
        iup.hbox{
            iup.fill{},
            iup.label{
                TITLE   = "Hello from the sample extension!",
                FONT    = "Segoe UI, 14",
                FGCOLOR = "0 120 200",
            },
            iup.fill{},
        },
        iup.hbox{
            iup.fill{},
            iup.label{
                TITLE   = "This tab was added by plugins/hello.lua",
                FONT    = "Segoe UI, 10",
                FGCOLOR = "120 120 120",
            },
            iup.fill{},
        },
        iup.fill{},
        BGCOLOR = "255 255 255",
    }
    self:addTab("Hello", panel)

    -- Add a menu item using the base class convenience method
    self:addMenuItem("Hello Extension...", function()
        iup.Message("Hello Extension",
            "Hello from the sample extension!\n"
            .. "Version: " .. self.version .. "\n"
            .. "App: " .. ctx.app.title .. " v" .. ctx.app.version)
    end)

    -- Register a small settings section to demonstrate category dividers in the
    -- host's centralized, searchable Settings tab.
    -- Wrap the native text in a themed flatframe (BORDER=NO on the text,
    -- THEMEROLE="text" on the frame) so its border/background follow the active
    -- theme, matching the flat inputs used everywhere else in the app.
    local greeting = iup.text{ BORDER = "NO", VALUE = "Hello", SIZE = "120x", FONT = "Segoe UI, 10" }
    local greeting_box = iup.flatframe{ greeting, TITLE = "", MARGIN = "2x2", THEMEROLE = "text" }
    local show_tab = iup.flattoggle{ TITLE = "", VALUE = "ON", FONT = "Segoe UI, 10", CHECKSIZE = "14" }
    self:addSettings("Hello Extension", {
        entries = {
            {
                label       = "Greeting text",
                description = "The message shown on the Hello tab.",
                widget      = greeting_box,
            },
            {
                label       = "Show Hello tab",
                description = "Demo toggle (illustrative only).",
                widget      = show_tab,
            },
        },
    })

    self:log("loaded successfully")
end

function Hello:shutdown()
    -- Cleanup if needed
end

return Hello:new()

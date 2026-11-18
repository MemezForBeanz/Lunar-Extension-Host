--- Declarative tool workspace. No extension logic or per-frame work lives here.
local M = {}
local pages = setmetatable({}, { __mode = "kv" })
function M.fromWidget(widget) return pages[widget] end
local L = require("core.lib.CarbonLayout")
local P = L.PAGE
local Kit = require("core.ui.Kit")
local ok, StateIcon = pcall(require, "core.ui.StateIcon")
local function clamp(n, lo, hi) return math.max(lo, math.min(hi, tonumber(n) or lo)) end

function M.new(iup, opts)
    opts = opts or {}
    local self = { iup = iup, opts = opts, width = math.huge, runState = "ready",
        -- what the work above an open dock keeps before the dock gives way
        bodyMin = opts.bodyMin or P.body_min }
    local settings, key = opts.settings, "page." .. (opts.id or opts.title or "tool") .. "."
    local function saved(name, default) return settings and settings:get(key .. name) or default end
    local function save(name, value)
        if settings then settings:set(key .. name, value); settings:save() end
    end
    local function show(w, on) if w then Kit.show(iup, w, on, self.stateLine) end end
    local function row(kids, role, height)
        kids.GAP, kids.ALIGNMENT, kids.EXPAND = L.gap(5), "ACENTER", "HORIZONTAL"
        kids.THEMEROLE = role
        if height then kids.MINSIZE = L.size(nil, height) end
        return iup.hbox(kids)
    end
    local function refresh() if self.root and iup.Refresh then iup.Refresh(self.root) end end
    self.stateLine = Kit.statusLine(iup, "info", "Ready")
    iup.SetAttribute(self.stateLine, "RASTERSIZE", L.size(1))
    iup.SetAttribute(self.stateLine, "TEXTELLIPSIS", "YES")
    local title = L.pageTitle(iup, opts.title or "")
    self.title = title
    iup.SetAttribute(title, "TEXTELLIPSIS", "YES")
    if opts.icon then Kit.bindIcon(iup, title, opts.icon) end
    self.primary = opts.primary and opts.primary.widget or Kit.button(iup, { title = "", role = "primary_btn" })
    self.primaryIconTarget = opts.primary and opts.primary.iconWidget or self.primary
    -- Custom action groups must not compete with the state line for spare width.
    iup.SetAttribute(self.primary, "EXPAND", "NO")
    self.secondary = {}
    for n = 1, 2 do self.secondary[n] = Kit.button(iup, { title = "" }) end
    local overflow = Kit.button(iup, { title = "More", action = function()
        local items = {}
        if self.configureFolded then
            items[#items + 1] = { title = self.configOpen and "Hide configuration" or "Configure", action = function()
                self.configOpen = not self.configOpen; self:fit(self.width)
            end }
        end
        for _, item in ipairs(opts.menu or {}) do items[#items + 1] = item end
        for n = (self.width < P.drawer_break and 1 or 3), #(self.secondarySpecs or {}) do items[#items + 1] = self.secondarySpecs[n] end
        local Menu = require("core.ui.ContextMenu")
        self.menu = self.menu or Menu:new(iup, {})
        self.menu:setItems(items)
        self.menu:popup()
    end })
    self.overflow = overflow
    self.configure = Kit.button(iup, { title = "Configure", action = function()
        self.configOpen = not self.configOpen; self:fit(self.width)
    end })
    self.header = row({ title, self.stateLine, self.configure, self.secondary[1], self.secondary[2], overflow, self.primary }, "page_header", P.header)
    local config = opts.config or opts.nav
    local function column(spec, role, close)
        if not spec then return nil end
        local kids = {}
        if spec.title then
            kids[#kids + 1] = row({ L.sectionTitle(iup, spec.title), iup.fill({}), close or iup.fill({}) }, role)
        end
        kids[#kids + 1] = spec.widget
        kids.GAP, kids.EXPAND, kids.THEMEROLE = L.gap(5), "YES", role
        return iup.vbox(kids)
    end
    self.config = column(config, "page_column")
    local close = Kit.button(iup, { title = "Close", action = function() self:openInspector(false) end })
    self.inspector = column(opts.inspector, "page_inspector", close)
    if self.inspector then self.inspector = iup.flatframe{self.inspector, TITLE="", FRAME="NO", MARGIN=L.margin(3), EXPAND="YES", THEMEROLE="page_inspector"} end
    self.inspectorOpen = opts.inspector and opts.inspector.open == true
    local main = opts.main or iup.vbox({ EXPAND = "YES" })
    self.main = main
    self.mainHost = iup.vbox{main, EXPAND="YES", THEMEROLE="page_column"}
    main = self.mainHost
    local body = main
    local function split(first, second, horizontal, name, default, lo, hi)
        local s = iup.split({ first, second, EXPAND = "YES", SHOWGRIP = "SASH", MINMAX = "0:1000" })
        if horizontal then iup.SetAttribute(s, "ORIENTATION", "HORIZONTAL") end
        s.valuechanged_cb = function()
            if self.fitting then return iup.DEFAULT end
            local size = tonumber(iup.GetAttribute(s, "VALUE")) or 0
            local extent = horizontal and self.height or self.width
            if extent and extent < math.huge then
                local pixels = extent * (name == "config" and size or (1000 - size)) / 1000
                self[name .. "Size"] = clamp(pixels, lo, hi); save(name, self[name .. "Size"])
            end
            return iup.DEFAULT
        end
        self[name .. "Size"] = clamp(saved(name, default), lo, hi)
        self[name .. "Bar"] = iup.GetAttribute(s, "BARSIZE")
        return s
    end
    if self.inspector then
        self.inspectorSplit = split(body, self.inspector, false, "inspector", opts.inspector.width or P.inspector, P.inspector_min, P.inspector_max)
        self.inspectorOverlay = iup.vbox{self.inspectorSplit, EXPAND="YES"}
        self.inspectorFrame = iup.flatframe{self.inspectorOverlay, TITLE="", FRAME="NO", MARGIN=L.margin(0), EXPAND="YES", THEMEROLE="page_column"}
        body = self.inspectorFrame
    end
    if self.config then
        self.configSplit = split(self.config, body, false, "config", config.width or P.config, P.config_min, P.config_max)
        body = self.configSplit
    end
    self.body = body
    local kids = { self.header }
    if opts.toolbar then
        self.toolbar = row({ opts.toolbar }, "page_toolbar", P.toolbar)
        kids[#kids + 1] = self.toolbar
    end
    local function buildDock(spec)
        -- Both declared and late docks may take height from long config forms.
        -- Scrolling the body keeps those inputs reachable without squeezing logs.
        body = iup.scrollbox{body, EXPAND="YES", CANVASBOX="YES", SCROLLBAR="VERTICAL", BORDER="NO", THEMEROLE="page_column"}
        self.body = body
        if iup.GetClassName(spec.widget) == "text" and iup.flatscrollbox then
            spec.widget = iup.flatscrollbox{spec.widget, EXPAND="YES", SCROLLBAR="YES",
                NATIVETEXTSCROLL="YES", THEMEROLE="outputlog_scroll"}
        end
        -- One dock anatomy on every page: the output always sits in the same well.
        -- A page that already hands one over keeps its own handle.
        if not (iup.GetClassName(spec.widget) == "flatframe" and iup.GetAttribute(spec.widget, "THEMEROLE") == "well") then
            spec.widget = iup.flatframe{spec.widget, TITLE="", EXPAND="YES", MARGIN=L.margin(2), THEMEROLE="well"}
        end
        self.renderedDockOpen = nil
        self.dockSummary = Kit.statusLine(iup, "idle", spec.summary or "No output yet")
        -- A short pane ends the summary in an ellipsis (whole sentence in the tooltip),
        -- never a word cut through.
        iup.SetAttribute(self.dockSummary, "RASTERSIZE", L.size(1))
        iup.SetAttribute(self.dockSummary, "TEXTELLIPSIS", "YES")
        self.dockAction = Kit.button(iup, { title = "Open error" })
        -- The toggle acts on what is shown: a dock that gave way to a short pane opens.
        self.dockToggle = Kit.button(iup, { title = "Show output", action = function() self:openDock(not self.renderedDockOpen) end })
        self.dock = iup.vbox({ row({ L.sectionTitle(iup, spec.title or "Output"), self.dockSummary, self.dockAction, self.dockToggle }, "page_dock", P.control),
            spec.widget, GAP = L.gap(3), EXPAND = "YES", THEMEROLE = "page_dock" })
        self.dockContent = spec.widget
        -- Existing viewers keep their callbacks and handles; plain dock text gets
        -- the same flat scrolling container as the org-pack output viewers.
        local function outputStyle(w)
            if iup.GetClassName(w) == "text" then
                iup.SetAttribute(w, "THEMEROLE", "outputlog")
                iup.SetAttribute(w, "FONT", "IBM Plex Mono, 10")
                iup.SetAttribute(w, "SCROLLBAR", "NO")
                iup.SetAttribute(w, "VISIBLELINES", "6")
            end
            local n = 0
            while iup.GetChild(w, n) do outputStyle(iup.GetChild(w, n)); n = n + 1 end
        end
        outputStyle(spec.widget)
        self.dockSplit = split(body, self.dock, true, "dock", P.dock, P.toolbar, P.dock * 2)
        self.dockHost = iup.vbox{self.dockSplit, EXPAND="YES", THEMEROLE="page_column"}
        return self.dockHost
    end
    if opts.dock then
        kids[#kids + 1] = buildDock(opts.dock)
    else kids[#kids + 1] = body end
    kids.MARGIN, kids.GAP, kids.EXPAND = L.margin(P.padding), L.gap(5), "YES"
    kids.THEMEROLE = "page_surface"
    self.root = iup.vbox(kids)
    pages[self.root] = self
    local dev = rawget(_G, "LUNAR_DEV_SHELL")
    if dev then
        dev.toolPages = dev.toolPages or {}
        dev.toolPages[opts.title] = self
    end
    function self:widget() return self.root end
    function self:ensureDock(spec)
        if self.dock then return end
        iup.Detach(self.body)
        -- A late dock must be able to take height from a tall configuration form.
        -- Preserve access to that form instead of letting its natural minimum
        -- squeeze the failure transcript down to zero lines in a short pane.
        iup.Append(self.root, buildDock(spec))
        -- A dock added after the page was themed is themed now, so its title, buttons and
        -- well match a dock declared up front.
        local theme = require("core.ui.ThemeReactor").themeManager()
        if theme then pcall(theme.themeWidget, theme, self.dockHost) end
        self:openDock(false)
    end
    function self:destroy()
        pages[self.root] = nil
        if self.runIcon then self.runIcon:destroy(); self.runIcon = nil end
        if self.menu then self.menu:destroy(); self.menu = nil end
    end
    function self:setState(kind, text)
        self.stateText = text
        Kit.setStatus(iup, self.stateLine, kind == "success" and "ok" or kind, text)
        iup.SetAttribute(self.stateLine, "TIP", text)
    end
    function self:setRunState(state, progress)
        if self.renderedRunState == state and self.runProgress == progress then return end
        self.runState = state
        if not (opts.primary and opts.primary.widget) then
            iup.SetAttribute(self.primary, "TITLE", state == "working" and "Stop" or self.primaryTitle or "")
        end
        self.renderedRunState, self.runProgress = state, progress
        if self.runIcon then
            -- each kind names its own states; one it lacks (a connection has no "ready")
            -- starts from the kind's initial state
            local def = StateIcon.definition(self.runKind)
            if def and not def.states[state] then state = def.initial end
            self.runIcon:set(state, { progress = progress })
        else Kit.bindIcon(iup, self.primaryIconTarget, state == "failed" and "warning--alt" or (state == "working" and "stop" or "play--outline")) end
    end
    function self:setPrimary(spec)
        spec = spec or {}
        if not spec.widget then
            self.primaryTitle = spec.title or ""
            iup.SetAttribute(self.primary, "TITLE", self.runState == "working" and "Stop" or self.primaryTitle)
            self.primary.flat_action = function() if spec.action then spec.action() end; return iup.DEFAULT end
        end
        show(self.primary, spec.widget ~= nil or spec.title ~= nil)
        if self.runKind ~= spec.run then
            if self.runIcon then self.runIcon:destroy(); self.runIcon = nil end
            self.runKind = spec.run
            self.renderedRunState = nil
            if spec.run and ok then
                self.runIcon = StateIcon.new(iup, { kind = spec.run, size = Kit.ICON_BUTTON, role = spec.iconRole or "on-accent" })
                self.runIcon:attach(self.primaryIconTarget, "IMAGE")
            end
        end
        self:setRunState(self.runState)
    end
    function self:setSecondary(specs)
        self.secondarySpecs = specs or {}
        for n, btn in ipairs(self.secondary) do
            local spec = self.secondarySpecs[n]
            iup.SetAttribute(btn, "TITLE", spec and spec.title or "")
            btn.flat_action = function() if spec and spec.action then spec.action() end; return iup.DEFAULT end
            show(btn, spec ~= nil and self.width >= P.drawer_break)
        end
        show(overflow, self.configureFolded or #(opts.menu or {}) > 0 or #self.secondarySpecs > (self.width < P.drawer_break and 0 or 2))
    end
    --- Would the header's buttons leave the state line less than it needs to read? Uses
    -- the natural widths of the last layout (ImGui host); elsewhere the header is kept.
    function self:measure(w)
        if not rawget(iup, "_IMGUI") then return nil end
        local Element = package.loaded["core.imgui.Element"]
        local st = Element and Element.state(w)
        return st and st.nat_w
    end
    function self:_headerShort(width, titleWidth)
        local gap = L.px(5)
        local tw = self:measure(title)
        if not tw or tw <= 0 then return false end
        local need = math.min(tw, titleWidth) + P.state_min + gap
        for _, btn in ipairs({ self.configure, self.secondary[1], self.secondary[2], overflow, self.primary }) do
            if iup.GetAttribute(btn, "FLOATING") ~= "YES" then need = need + (self:measure(btn) or 0) + gap end
        end
        return need > width - P.padding * 2
    end
    function self:openInspector(on) self.inspectorOpen = on == true; self:fit(self.width) end
    -- What is on screen. `openDock` records what is wanted; `fit` decides what the
    -- pane has room for and calls this only when that changes.
    local function placeDock(open)
        if self.renderedDockOpen == open then return end
        self.renderedDockOpen = open
        if self.dockHost and iup.Append and iup.Detach then
            local tree = require("core.lib.tree")
            if open then
                tree.place(iup, self.dockSplit, self.body)
                tree.place(iup, self.dockSplit, self.dock)
            else
                tree.place(iup, self.dockHost, self.body)
                tree.place(iup, self.dockHost, self.dock)
            end
            show(self.dockSplit, open)
            iup.SetAttribute(self.dock, "EXPAND", open and "YES" or "HORIZONTAL")
        end
        if self.dockContent then
            show(self.dockContent, open)
            iup.SetAttribute(self.dockContent, "FLOATING", open and "NO" or "IGNORE")
            iup.SetAttribute(self.dock, "MAXSIZE", open and L.maxSize() or L.maxSize(nil, P.control))
            iup.SetAttribute(self.dockToggle, "TITLE", open and "Hide output" or "Show output")
        end
    end
    --- Open or close the output dock. An open asked for by the user (or by a call
    -- without `how`) holds even in a short pane; `how == "auto"` (a failure arriving)
    -- lets the dock give way to the work when the pane is short.
    function self:openDock(on, how)
        on = on == true
        self.dockForced = on and (how ~= "auto" or (self.dockOpen == true and self.dockForced == true))
        self.dockOpen = on
        self:fit(self.width, self.height)
    end
    function self:setDockSummary(kind, text, action)
        if not self.dockSummary then return end
        Kit.setStatus(iup, self.dockSummary, kind == "success" and "ok" or kind, text)
        if text then iup.SetAttribute(self.dockSummary, "TIP", text) end
        -- "Open error" always shows the output, even where the dock had given way.
        self.dockAction.flat_action = function()
            self:openDock(true)
            if action then action() end
            return iup.DEFAULT
        end
        show(self.dockAction, action ~= nil)
        if kind == "error" then self:openDock(true, "auto") elseif kind == "success" then self:openDock(false) end
    end
    function self:fit(width, height)
        if iup.GetParent then
            local rootX = tonumber((iup.GetAttribute(self.root, "SCREENPOSITION") or ""):match("^(-?%d+),"))
            local ancestor = iup.GetParent(self.root)
            while ancestor do
                local w = tonumber((iup.GetAttribute(ancestor, "RASTERSIZE") or ""):match("^(%d+)x"))
                local x = tonumber((iup.GetAttribute(ancestor, "SCREENPOSITION") or ""):match("^(-?%d+),"))
                if w and w > P.control then width = math.min(width, w - ((rootX and x) and math.max(0, rootX - x) or 0)) end
                ancestor = iup.GetParent(ancestor)
            end
        end
        width = math.max(P.control, width)
        iup.SetAttribute(self.root, "MAXSIZE", L.maxSize(width))
        -- The parent already removes page padding. Let this row fill that client area.
        iup.SetAttribute(self.header, "MAXSIZE", nil)
        self.fitting = true
        self.width, self.height = width, height or self.height or P.dock * 3
        local narrow = width - P.padding * 2 < P.config_break
        self:setSecondary(self.secondarySpecs)
        local titleWidth = math.min(P.card_min, math.floor(width / 4))
        iup.SetAttribute(title, "MAXSIZE", L.maxSize(titleWidth))
        -- One unbounded expanding child consumes all remaining space; a capped label
        -- plus an IUP fill loses space when the label hits its maximum.
        iup.SetAttribute(self.stateLine, "MAXSIZE", nil)
        self.configureFolded = false
        show(self.configure, narrow and self.config ~= nil)
        if narrow and self.config and self:_headerShort(width, titleWidth) then
            -- Wide buttons (Carbon's) would leave the state line only its icon: Configure
            -- goes under More, so the header still says what happened.
            self.configureFolded = true
            show(self.configure, false)
            show(overflow, true)
        end
        if self.configSplit then
            local visible = not narrow or self.configOpen
            show(self.config, visible)
            iup.SetAttribute(self.configSplit, "VALUE", visible and tostring(math.floor(self.configSize / width * 1000)) or "0")
            -- A closed column leaves no bar behind: an idle sash at the edge reads as a scrollbar.
            iup.SetAttribute(self.configSplit, "BARSIZE", visible and self.configBar or "0")
        end
        if self.inspectorSplit then
            show(self.inspector, self.inspectorOpen)
            local drawer = self.inspectorOpen and width < P.drawer_break and rawget(iup, "_IMGUI")
            show(main, true)
            if iup.Append and iup.Detach then
                require("core.lib.tree").place(iup, drawer and self.inspectorOverlay or self.inspectorSplit, self.inspector)
            end
            if drawer then
                iup.SetAttribute(self.inspector, "_IUPLUNAR_OVERLAY", "YES")
                iup.SetAttribute(self.inspector, "FLOATING", "YES")
                iup.SetAttribute(self.inspector, "VISIBLE", "YES")
                local frameHeight = tonumber((iup.GetAttribute(self.inspectorFrame, "RASTERSIZE") or ""):match("x(%d+)$"))
                iup.SetAttribute(self.inspector, "RASTERSIZE", L.size(self.inspectorSize, (frameHeight and frameHeight > P.control) and frameHeight or math.max(P.dock, self.height - P.header - P.padding * 2)))
                iup.SetAttribute(self.inspector, "POSITION", tostring(math.max(0, width - P.padding * 2 - self.inspectorSize)) .. ",0")
            else
                iup.SetAttribute(self.inspector, "_IUPLUNAR_OVERLAY", nil)
                iup.SetAttribute(self.inspector, "RASTERSIZE", L.size(1))
                -- A closed inspector takes no part in layout: its details would otherwise
                -- still size the body, and the page would scroll with nothing to show.
                if not self.inspectorOpen then iup.SetAttribute(self.inspector, "FLOATING", "IGNORE") end
            end
            iup.SetAttribute(self.inspectorSplit, "BARSIZE", (not self.inspectorOpen or drawer) and "0" or self.inspectorBar)
            iup.SetAttribute(self.inspectorSplit, "VALUE", (not self.inspectorOpen or drawer) and "1000" or tostring(math.floor((1 - self.inspectorSize / math.max(P.control, width - P.padding * 2 - ((self.config and (not narrow or self.configOpen)) and self.configSize + P.gutter or 0))) * 1000)))
        end
        if self.dockSplit then
            local function measured(w, fallback)
                local h = w and tonumber((iup.GetAttribute(w, "RASTERSIZE") or ""):match("x(%d+)$"))
                return (h and h > 0) and h or fallback
            end
            local rows = self.toolbar and 2 or 1
            local bodyHeight = measured(self.root, self.height) - P.padding * 2 - math.max(P.header, measured(self.header, 0))
                - (self.toolbar and math.max(P.toolbar, measured(self.toolbar, 0)) or 0) - P.gutter * rows
            local open, takeover = self.dockOpen == true, false
            local h = math.max(P.dock, self.dockSize)
            if open then
                local room = bodyHeight - self.bodyMin
                if self.dockForced and bodyHeight < P.dock + L.px(13) then
                    -- Asked for in a very short pane: the output gets the pane; Hide output
                    -- returns to the work.
                    takeover, h = true, bodyHeight
                elseif room < P.dock_min then
                    -- The work keeps its minimum: when even the dock's smallest readable
                    -- height does not fit, it gives way to its summary line, unless the
                    -- user asked for it.
                    if self.dockForced then h = P.dock_min else open = false end
                else
                    h = math.min(h, room)
                    -- Softer: the dock also shrinks (not below readable) so a config form
                    -- fits whole above it, instead of scrolling beside an empty main.
                    local Lay = rawget(iup, "_IMGUI") and package.loaded["core.imgui.Layout"]
                    if Lay and self.config and (not narrow or self.configOpen) then
                        local form = Lay.minContent(self.config, false)
                        local bar = tonumber(iup.GetAttribute(self.dockSplit, "BARSIZE")) or 0
                        if form > 0 then h = math.max(P.dock_min, math.min(h, bodyHeight - bar - form)) end
                    end
                end
            end
            placeDock(open)
            show(self.body, not takeover)
            iup.SetAttribute(self.body, "FLOATING", takeover and "IGNORE" or "NO")
            if not open then h = P.control end
            iup.SetAttribute(self.dockSplit, "VALUE", open and tostring(math.floor(clamp((1 - h / math.max(P.control, bodyHeight)) * 1000, 0, 1000))) or "1000")
        end
        self.fitting = false
        refresh()
    end
    self:setPrimary(opts.primary)
    self:setSecondary(opts.secondary)
    self:setState((opts.state or {}).kind or "info", (opts.state or {}).text or "Ready")
    self:setDockSummary("idle", opts.dock and opts.dock.summary or "")
    self:openDock(false)
    self:fit(P.drawer_break + P.config)
    return self
end

-- Cards share one grid; fit is called only on resize, never in a paint callback.
function M.cards(iup, opts)
    local cards = opts.cards or opts
    local root = iup.vbox({ GAP = L.gap(5), EXPAND = "YES" })
    local rows = {}
    for n, card in ipairs(cards) do
        rows[n] = iup.hbox({ card.widget or card, GAP = L.gap(5), EXPAND = "HORIZONTAL" })
        iup.Append(root, rows[n])
    end
    iup.Append(root, iup.fill{})
    local grid = { widget = root }
    function grid:fit(width)
        local count = math.max(1, math.min(P.columns, math.floor((width + P.gutter) / (P.card_min + P.gutter))))
        local tree = require("core.lib.tree")
        for n, card in ipairs(cards) do
            local target = math.floor((n - 1) / count) + 1
            tree.place(iup, rows[target], card.widget or card)
            Kit.show(iup, rows[n], n <= math.ceil(#cards / count))
        end
    end
    return grid
end
return M

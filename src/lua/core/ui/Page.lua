--- Declarative tool workspace. No extension logic or per-frame work lives here.
local M = {}
local L = require("core.lib.CarbonLayout")
local P = L.PAGE
local Kit = require("core.ui.Kit")
local ok, StateIcon = pcall(require, "core.ui.StateIcon")
local function clamp(n, lo, hi) return math.max(lo, math.min(hi, tonumber(n) or lo)) end

function M.new(iup, opts)
    opts = opts or {}
    local self = { iup = iup, opts = opts, width = math.huge, runState = "ready" }
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
    if opts.icon then Kit.bindIcon(iup, title, opts.icon) end
    self.primary = opts.primary and opts.primary.widget or Kit.button(iup, { title = "", role = "primary_btn" })
    self.primaryIconTarget = opts.primary and opts.primary.iconWidget or self.primary
    self.secondary = {}
    for n = 1, 2 do self.secondary[n] = Kit.button(iup, { title = "" }) end
    local overflow = Kit.button(iup, { title = "More", action = function()
        local items = {}
        for _, item in ipairs(opts.menu or {}) do items[#items + 1] = item end
        for n = 3, #(self.secondarySpecs or {}) do items[#items + 1] = self.secondarySpecs[n] end
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
    self.inspectorOpen = opts.inspector and opts.inspector.open == true
    local main = opts.main or iup.vbox({ EXPAND = "YES" })
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
        return s
    end
    if self.inspector then
        self.inspectorSplit = split(body, self.inspector, false, "inspector", opts.inspector.width or P.inspector, P.inspector_min, P.inspector_max)
        body = self.inspectorSplit
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
    if opts.dock then
        self.dockSummary = Kit.statusLine(iup, "idle", opts.dock.summary or "No output yet")
        self.dockAction = Kit.button(iup, { title = "Open error" })
        self.dockToggle = Kit.button(iup, { title = "Show output", action = function() self:openDock(not self.dockOpen) end })
        self.dock = iup.vbox({ row({ L.sectionTitle(iup, opts.dock.title or "Output"), self.dockSummary, self.dockAction, self.dockToggle }, "page_dock", P.control),
            opts.dock.widget, GAP = L.gap(3), EXPAND = "YES", THEMEROLE = "page_dock" })
        self.dockContent = opts.dock.widget
        self.dockSplit = split(body, self.dock, true, "dock", P.dock, P.toolbar, P.dock * 2)
        kids[#kids + 1] = self.dockSplit
    else kids[#kids + 1] = body end
    kids.MARGIN, kids.GAP, kids.EXPAND = L.margin(P.padding), L.gap(5), "YES"
    kids.THEMEROLE = "page_surface"
    self.root = iup.vbox(kids)
    local dev = rawget(_G, "LUNAR_DEV_SHELL")
    if dev then
        dev.toolPages = dev.toolPages or {}
        dev.toolPages[opts.title] = self
    end
    function self:widget() return self.root end
    function self:destroy()
        if self.runIcon then self.runIcon:destroy(); self.runIcon = nil end
        if self.menu then self.menu:destroy(); self.menu = nil end
    end
    function self:setState(kind, text)
        Kit.setStatus(iup, self.stateLine, kind == "success" and "ok" or kind, text)
    end
    function self:setRunState(state, progress)
        if self.renderedRunState == state and self.runProgress == progress then return end
        self.runState = state
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
            iup.SetAttribute(self.primary, "TITLE", spec.title or "")
            self.primary.flat_action = function() if spec.action then spec.action() end; return iup.DEFAULT end
        end
        show(self.primary, spec.widget ~= nil or spec.title ~= nil)
        if self.runKind ~= spec.run then
            if self.runIcon then self.runIcon:destroy(); self.runIcon = nil end
            self.runKind = spec.run
            self.renderedRunState = nil
            if spec.run and ok then
                self.runIcon = StateIcon.new(iup, { kind = spec.run, size = Kit.ICON_BUTTON, role = "on-accent" })
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
            show(btn, spec ~= nil)
        end
        show(overflow, #(opts.menu or {}) > 0 or #self.secondarySpecs > 2)
    end
    function self:openInspector(on) self.inspectorOpen = on == true; self:fit(self.width) end
    function self:openDock(on)
        self.dockOpen = on == true
        if self.dockContent then
            show(self.dockContent, self.dockOpen)
            iup.SetAttribute(self.dockContent, "FLOATING", self.dockOpen and "NO" or "IGNORE")
            iup.SetAttribute(self.dock, "MAXSIZE", self.dockOpen and L.maxSize() or L.maxSize(nil, P.control))
            iup.SetAttribute(self.dockToggle, "TITLE", self.dockOpen and "Hide output" or "Show output")
        end
        self:fit(self.width, self.height)
    end
    function self:setDockSummary(kind, text, action)
        if not self.dockSummary then return end
        Kit.setStatus(iup, self.dockSummary, kind == "success" and "ok" or kind, text)
        self.dockAction.flat_action = function() if action then action() end; return iup.DEFAULT end
        show(self.dockAction, action ~= nil)
        if kind == "error" then self:openDock(true) elseif kind == "success" then self:openDock(false) end
    end
    function self:fit(width, height)
        width = math.max(P.control, width)
        self.fitting = true
        self.width, self.height = width, height or self.height or P.dock * 3
        local narrow = width < P.config_break
        show(self.configure, narrow and self.config ~= nil)
        if self.configSplit then
            local visible = not narrow or self.configOpen
            show(self.config, visible)
            iup.SetAttribute(self.configSplit, "VALUE", visible and tostring(math.floor(self.configSize / width * 1000)) or "0")
        end
        if self.inspectorSplit then
            show(self.inspector, self.inspectorOpen)
            -- A narrow pane gives the details the work area until Close is pressed.
            show(main, not self.inspectorOpen or width >= P.drawer_break)
            iup.SetAttribute(self.inspectorSplit, "VALUE", not self.inspectorOpen and "1000" or (width < P.drawer_break and "0" or tostring(math.floor((1 - self.inspectorSize / width) * 1000))))
        end
        if self.dockSplit then
            local h = self.dockOpen and self.dockSize or P.control
            iup.SetAttribute(self.dockSplit, "VALUE", tostring(math.floor(clamp((1 - h / self.height) * 1000, 0, 1000))))
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

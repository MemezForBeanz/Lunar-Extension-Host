--- Internal layout service for core.classes.HostAPI.
-- @module core.classes.host.Layout
-- @local

local M = {}
local L = require("core.lib.CarbonLayout")
-- Handle identity. IUP handles must never be compared with `==` -- the Lua
-- binding allocates a fresh userdata on every push, so two handles for the same
-- widget compare unequal. See core.lib.handle.
local handle = require("core.lib.handle")
local tree = require("core.lib.tree")
local DEFAULT_OWNER = require("core.classes.host.Owners")

local function to_int(value, default)
    local n = tonumber(value)
    if not n then return default end
    return math.floor(n + 0.5)
end

local function status_padding(value)
    if type(value) == "number" then
        local n = math.max(0, math.floor(value + 0.5))
        return tostring(n) .. "x" .. tostring(n)
    end
    if type(value) == "string" and value ~= "" then
        return value
    end
    return "0x0"
end

function M.registerHostTab(self, id, widget)
    if type(id) ~= "string" or id == "" or not widget then
        return
    end
    self._host_tabs[id] = widget
    -- Host tabs are appended directly rather than through addTab, so they get
    -- their layout key here. Without one, core.classes.TabGroups cannot record
    -- where the user filed the Settings tab and it would jump back to the end of
    -- the strip on every launch.
    --
    -- The "_IUP" prefix makes this a LOCAL attribute. Without it IUP treats an
    -- unregistered attribute as inheritable and every widget inside the page
    -- reports the same key -- see the constants block in core.classes.TabGroups.
    pcall(self.iup.SetAttribute, widget, "_IUPLUNAR_TABKEY", "host/" .. id)
end

function M.setTabGroups(self, groups)
    self._tab_groups = groups
end

function M.workArea(self)
    local iup = self.iup
    -- Prefer the shell-accurate figure, which also accounts for an AUTO-HIDE
    -- taskbar (SPI_GETWORKAREA does not -- see core.lib.desktop).
    local ok_desktop, desktop = pcall(require, "core.lib.desktop")
    if ok_desktop and desktop then
        local w, h = desktop.usableArea()
        if w and h and w > 0 and h > 0 then
            return w, h
        end
    end
    for _, name in ipairs({ "SCREENSIZE", "FULLSIZE" }) do
        local ok, value = pcall(iup.GetGlobal, name)
        if ok and type(value) == "string" then
            local w, h = value:match("^(%d+)%s*x%s*(%d+)")
            w, h = tonumber(w), tonumber(h)
            if w and h and w > 0 and h > 0 then
                return w, h
            end
        end
    end
    return 1920, 1080
end

function M._getScreenWidth(self)
    local w = self:workArea()
    return w
end

function M.screenWidth(self)
    return self:_getScreenWidth()
end

function M.scaleUi(self, px, opts)
    local value = tonumber(px)
    if not value then return 0 end
    opts = opts or {}
    local base = tonumber(opts.base_width) or 1920
    if base <= 0 then base = 1920 end
    local min_scale = tonumber(opts.min_scale) or 0.72
    local max_scale = tonumber(opts.max_scale) or 1.25
    local scale = self:_getScreenWidth() / base
    if scale < min_scale then scale = min_scale end
    if scale > max_scale then scale = max_scale end
    return to_int(value * scale, 0)
end

function M._scaleSidePadding(self, side_padding, opts)
    local pad = tonumber(side_padding) or 0
    if pad <= 0 then return 0 end
    if opts and opts.scale_side_padding == false then
        return to_int(pad, 0)
    end
    local base_width = tonumber(opts and opts.base_screen_width) or 1920
    if base_width <= 0 then base_width = 1920 end
    local scale = self:_getScreenWidth() / base_width
    if scale < 0.5 then scale = 0.5 end
    return to_int(pad * scale, 0)
end

function M._wrapTabForPadding(self, widget, opts)
    if type(opts) ~= "table" then return widget end
    local side_padding = self:_scaleSidePadding(opts.side_padding, opts)
    local max_width = to_int(opts.max_content_width, nil)
    if side_padding <= 0 and (not max_width or max_width <= 0) then
        return widget
    end

    local iup = self.iup

    -- Centering is done with MARGIN, NOT with iup.fill{} on either side.
    --
    -- The fill approach does not work here and produced the left-shifted Log Parser
    -- with a wide dead strip down the right. In an IupHbox, free space is split
    -- between ALL expanding children -- and the tab content expands too. Capping it
    -- with MAXSIZE stops it growing, but IUP's single-pass layout does not then
    -- hand the surplus back to the fills, so the leftover simply piles up after the
    -- last child. The content ends up flush left, which is the opposite of centered.
    --
    -- Computing the margin instead makes the result symmetric by construction: the
    -- same number is applied to both edges, so the content cannot drift.
    local vertical = opts.vertical_padding
    vertical = vertical and self:_scaleSidePadding(vertical, opts) or side_padding

    local horizontal = side_padding
    if max_width and max_width > 0 then
        -- Widen the gutter until the content is capped at max_width. Measured
        -- against the screen because the tab has no size yet at build time; the
        -- window opens maximized, so the two agree in the normal case.
        local screen_w = self:_getScreenWidth()
        if screen_w > max_width then
            horizontal = math.max(horizontal, math.floor((screen_w - max_width) / 2))
        end
        -- Never let the gutter eat the content: on a restored (non-maximized)
        -- window a margin sized for the full screen would squeeze the panel.
        local cap = math.floor(screen_w * 0.12)
        if horizontal > cap then horizontal = cap end
    end

    return iup.vbox{
        widget,
        MARGIN = tostring(horizontal) .. "x" .. tostring(vertical),
        GAP = L.gap(0),
        EXPAND = "YES",
    }
end


--- Wrap tab content in a scroll host so nothing can be clipped out of reach.
--
-- On a small screen the bottom of a tall tab would otherwise sit under the
-- taskbar with no way to reach it: the dialog has SHRINK="YES", and IUP simply
-- clips a child that does not fit.
--
-- IupScrollBox is exactly the right container here, and notably does NOT cost the
-- fill-the-tab behaviour every existing tab relies on. Its
-- SetChildrenCurrentSize gives the child `max(child natural size, scrollbox
-- size)`: bigger than the tab -> child keeps its natural size and scrollbars
-- appear; smaller -> the child is stretched to the scrollbox, exactly as before.
-- So EXPAND="YES" panels still fill the tab and only overflow starts scrolling.
--
-- OPT-IN ONLY (`opts.scroll == true`), and it should stay that way.
--
-- DO NOT enable this by default to solve tab-height problems -- that was tried and
-- reverted twice. It does fix the height (a mapped scrollbox reports a natural
-- size of 0, so the page stops inflating the window), but it is a NATIVE container,
-- and every flat control resolves its background by walking to the nearest native
-- parent and reading that parent's STORED BGCOLOR
-- (iupBaseNativeParentGetBgColorAttrib; if it finds none it falls back to
-- IupGetGlobal("DLGBGCOLOR"), i.e. white). Inserting one re-parents the entire tab
-- and paints solid white blocks behind every label. `addTab` caps the page's
-- natural height with MAXSIZE instead, which needs no extra widget.
--
-- A scrollbox is a NATIVE container. Every flat control resolves its own
-- background by walking up to the nearest native parent
-- (`iupBaseNativeParentGetBgColorAttrib` in iup_flatlabel.c / iup_flatbutton.c /
-- iup_flatseparator.c, and `bg_str` in the forked rounded iup_gauge.c). Plain
-- vbox/hbox are VOID containers with no native window, so that walk normally
-- reaches the dialog. Dropping a scrollbox into every tab silently re-parents the
-- whole app: each flat label, button, separator and gauge starts blending against
-- the scrollbox's color instead of the dialog's. Applied globally that produced a
-- visible rectangle behind every piece of flat text and broke the gauge's
-- anti-aliased rounded corners (they are blended against that same background).
--
-- So a tab only gets a scroll host when it actually needs one, and whoever opts in
-- owns checking that its flat controls still sit on the right color.
--
-- The container itself is well-behaved otherwise: IupScrollBox's
-- SetChildrenCurrentSize gives the child `max(child natural size, scrollbox
-- size)`, so EXPAND="YES" panels still fill the tab and only genuine overflow
-- scrolls.
--
-- flatscrollbox (not the native scrollbox) keeps the owner-drawn themed bars used
-- everywhere else; THEMEROLE="tabscroll" paints it in the dialog background with
-- no border so the host itself is invisible.
function M._wrapTabForScroll(self, widget)
    local iup = self.iup
    local ok, box = pcall(iup.flatscrollbox, {
        widget,
        EXPAND = "YES",
        THEMEROLE = "tabscroll",
        BORDER = "NO",
        BORDERWIDTH = "0",
    })
    if not ok or not box then
        -- Never let a missing/renamed control cost the user their tab.
        return widget
    end
    return box
end

function M.addTab(self, title, widget, owner, opts)
    local iup = self.iup
    local tab_widget = self:_wrapTabForPadding(widget, opts)
    -- Scroll host goes OUTSIDE the padding/centering wrapper, so the wrapper's
    -- centering fills still measure against the real tab width rather than the
    -- (unbounded) scrolled virtual area. OPT-IN -- see _wrapTabForScroll for why
    -- this must not be applied to every tab.
    if opts and opts.scroll == true then
        tab_widget = self:_wrapTabForScroll(tab_widget)
    end

    -- CAP THE PAGE'S NATURAL HEIGHT. This is what keeps the status bar on screen.
    --
    -- A dialog is sized from its content (iDialogComputeNaturalSizeMethod), and an
    -- IUP box NEVER shrinks a child below its natural height -- iVboxCalcEmptyHeight
    -- computes the leftover as (currentheight - total_natural_size) and then does
    -- `if (empty_height < 0) empty_height = 0`. So a page taller than the window
    -- does not compress: it keeps its full height and everything after it (the
    -- status bar) is positioned off the bottom of the client area. SHRINK="YES"
    -- only lets the BOX be small; it does not compress children.
    --
    -- MAXSIZE is the lever, because iupBaseComputeNaturalSize finishes with
    -- `iupLayoutApplyMinMaxSize(ih, &naturalwidth, &naturalheight)` -- it crops the
    -- NATURAL size, not just the current one. Capping the page at the height a tab
    -- actually gets means its natural size can never exceed the space available,
    -- so the deficit never appears and the status bar keeps its room.
    --
    -- Deliberately NOT done with a scroll host. A scrollbox achieves the same
    -- decoupling (its natural size is 0) but is a NATIVE container, and inserting
    -- one changes what every flat control inside resolves as its background
    -- (iupBaseNativeParentGetBgColorAttrib walks to the nearest native parent), which
    -- painted white blocks behind the labels. This adds no widgets at all.
    --
    -- Height only: horizontal overflow is not the problem and capping width would
    -- fight max_content_width.
    do
        local _, work_h = self:workArea()
        -- Chrome above/below the tab page: title bar + menu, the tab strip itself,
        -- the accent strip and the status bar. Measured from the running app
        -- (work 1200 -> client 1066 -> tab area ~1022).
        local CHROME_H = 130
        local cap = math.max(320, (tonumber(work_h) or 1080) - CHROME_H)
        pcall(iup.SetAttribute, tab_widget, "MAXSIZE", "65535x" .. cap)
    end

    iup.SetAttribute(tab_widget, "TABTITLE", title)
    -- Tag the tab with a unique id so the active owner can be resolved from the
    -- focused control anywhere inside the tab tree. This is more robust than asking
    -- the tab strip for its active handle, because focus may live on a descendant
    -- widget instead of the page root.
    self._tab_seq = self._tab_seq + 1
    local tab_id = "hosttab" .. self._tab_seq
    self._owner_by_tab[tab_id] = owner or DEFAULT_OWNER
    self:_tagTreeOwner(tab_widget, tab_id)
    self:_installKeyDispatch(tab_widget)

    -- Layout identity for core.classes.TabGroups. This has to be STABLE across
    -- runs -- it is the key the saved group layout refers to -- so it is derived
    -- from the manifest id and the tab's ordinal within its extension, not from
    -- _tab_seq (which depends on plugin load order) or the title (which the
    -- extension may change).
    --
    -- Both attributes are "_IUP"-prefixed so IUP keeps them LOCAL to this page.
    -- Unregistered attributes are inheritable by default, and a key visible on
    -- every widget inside the page makes the tab tree unreadable -- see the
    -- constants block in core.classes.TabGroups.
    local manifest = self._manifest_by_owner[owner]
    local rec = self:_record(owner)
    local base = (manifest and manifest.id) or "host"
    iup.SetAttribute(tab_widget, "_IUPLUNAR_TABKEY", base .. "/" .. tostring(#rec.tabs + 1))

    -- Optional default group, from addTab opts or the manifest. Only consulted
    -- the first time this tab is seen: once the user has arranged it themselves
    -- the saved layout wins. "Parent/Child" nests. An org pack's extensions
    -- always land inside the pack's tool group ("Acme Tools/<hint>").
    local hint = (opts and opts.group) or (manifest and manifest.group)
    if type(hint) ~= "string" or hint == "" then hint = nil end
    local root_group = self._root_group_by_owner[owner]
    if root_group then hint = hint and (root_group .. "/" .. hint) or root_group end
    if hint then
        iup.SetAttribute(tab_widget, "_IUPLUNAR_GROUPHINT", hint)
    end

    iup.Append(self.tabs, tab_widget)
    if self._shown then
        iup.Map(tab_widget)
        iup.Refresh(self.tabs)
    end
    table.insert(self:_record(owner).tabs, tab_widget)
    if self._shown then self:_applyTabScopes() end
    if self._shown and self._on_tree_change then self._on_tree_change(tab_widget) end
    return widget
end

function M.addStatusElement(self, widget, opts, owner)
    if not self._status_box then return end
    if not widget then
        error("addStatusElement requires a widget", 2)
    end
    opts = opts or {}
    if type(opts) ~= "table" then
        error("addStatusElement opts must be a table", 2)
    end

    self._status_seq = self._status_seq + 1
    local position = tonumber(opts.position) or self._status_seq
    local container = self.iup.hbox({
        widget,
        MARGIN = status_padding(opts.padding),
        GAP = L.gap(0),
        ALIGNMENT = "ACENTER",
    })
    local entry = {
        owner = owner or DEFAULT_OWNER,
        widget = widget,
        container = container,
        persistent = opts.persistent == true,
        position = position,
        sequence = self._status_seq,
        present = false,
    }

    if opts.tooltip ~= nil then
        self.iup.SetAttribute(widget, "TIP", tostring(opts.tooltip))
    end
    if opts.on_click ~= nil then
        if type(opts.on_click) ~= "function" then
            error("addStatusElement on_click must be a function", 2)
        end
        local host = self
        self.iup.SetAttribute(widget, "CURSOR", opts.cursor or "HAND")
        function widget:button_cb(button, pressed, x, y)
            if button == host.iup.BUTTON1 and pressed == 0 then
                local ok, err = xpcall(function()
                    opts.on_click(widget, button, pressed, x, y, entry)
                end, debug.traceback)
                if not ok then
                    host:setStatus("Status element callback error: " .. tostring(err))
                end
            end
            return host.iup.DEFAULT
        end
    end

    self._status_scoped[#self._status_scoped + 1] = entry
    table.insert(self:_record(owner).statuswidgets, entry)
    self:_applyStatusScope()
    if self._shown and self._on_tree_change then self._on_tree_change(container) end
    return widget
end

function M.addStatusWidget(self, widget, owner)
    return self:addStatusElement(widget, nil, owner)
end


-- =======================================================================
-- TAB-SCOPED MENU ITEMS
-- Extension-contributed File/Help/Extensions items are shown only while one of
-- the owning extension's tabs is the active tab. Win32 menu items can't be hidden
-- via the VISIBLE attribute, so visibility is implemented by detaching/re-inserting.
-- =======================================================================

-- The owner whose tab is currently active, or nil (e.g. the host Settings tab, which
-- is appended directly and carries no owner tag).
function M._activeOwner(self)
    local iup = self.iup
    if not self.tabs then return nil end
    local active = self:_activeTab()
    if active then
        local tab_id = iup.GetAttribute(active, "HOSTTABOWNERID")
        if tab_id then
            return self._owner_by_tab[tab_id]
        end
    end
    -- Fallback for transient states (e.g. during dialog/show ordering).
    local fok, f = pcall(iup.GetFocus)
    if not fok or not f then return nil end
    local tab_id = iup.GetAttribute(f, "HOSTTABOWNERID")
    if not tab_id then return nil end
    return self._owner_by_tab[tab_id]
end


-- The active LEAF page.
--
-- With tab groups a top-level page may be another tab strip rather than an
-- extension's content (see core.classes.TabGroups), so the strip's VALUE is
-- followed down until it lands on a real page. Menu scoping, status-bar scoping,
-- shortcut scoping and route serialization all resolve through here, so getting
-- the descent right in this one place makes every one of them group-aware.
function M._activeTab(self)
    if not self.tabs then return nil end
    if self._tab_groups then
        local leaf = self._tab_groups:activeLeaf()
        if leaf then return leaf end
    end
    local ok, active = pcall(self.iup.GetAttributeHandle, self.tabs, "VALUE")
    if ok and active then return active end
    return nil
end

function M._tabIndex(self, widget)
    if not (self.tabs and widget) then return nil end
    local i = 0
    while true do
        local ok, child = pcall(self.iup.GetChild, self.tabs, i)
        if not ok or not child then return nil end
        if handle.same(self.iup, child, widget) then return i end
        i = i + 1
    end
end

function M._activateTabWidget(self, widget)
    -- A tab may live several groups deep, in which case activating it means
    -- activating each group above it first. TabGroups:reveal walks that chain;
    -- the flat path below still covers the pre-group case and the group manager
    -- being absent (CLI/dev harness).
    if self._tab_groups and self._tab_groups:reveal(widget) then
        self:_applyTabScopes()
        return true
    end
    local index = self:_tabIndex(widget)
    if index == nil then return nil end
    pcall(self.iup.SetAttribute, self.tabs, "VALUEPOS", tostring(index))
    self:_applyTabScopes()
    return true
end

function M._walkTree(self, ih, fn)
    if not ih then return end
    fn(ih)
    local iup = self.iup
    local i = 0
    while true do
        local ok, child = pcall(iup.GetChild, ih, i)
        if not ok or not child then
            break
        end
        self:_walkTree(child, fn)
        i = i + 1
    end
end

function M._tagTreeOwner(self, ih, tab_id)
    if not ih then return end
    local iup = self.iup
    pcall(iup.SetAttribute, ih, "HOSTTABOWNERID", tab_id)
    local i = 0
    while true do
        local ok, child = pcall(iup.GetChild, ih, i)
        if not ok or not child then
            break
        end
        self:_tagTreeOwner(child, tab_id)
        i = i + 1
    end
end


-- Rebuild the visible status area in deterministic position order. IUP lays hbox
-- children out left-to-right, so descending positions put position 1 at the
-- right edge, next to the org logo.
--
-- ### Why the early return matters
--
-- This runs on EVERY tab change, and a tab change very often does not change what
-- the status bar should hold -- switching between two tabs of the same extension
-- never does, and neither do the three re-scopes a single drag fans out (one from
-- TABCHANGE_CB as the drop reveals the tab, one from TabGroups' on_change, one
-- from TabOrder's on_switch).
--
-- Rebuilding is not a cheap no-op. `IupDetach` unmaps, which DESTROYS the element's
-- native window, and the re-map builds a new one, followed by a full-dialog
-- `IupRefresh`: done on every switch, that flickers the status bar behind every
-- tab transition.
--
-- So the target arrangement is computed first and compared with what is already
-- on screen. Identical is the common case and costs nothing.
function M._applyStatusScope(self)
    if not self._status_box then return end
    local iup = self.iup
    local active_owner = self:_activeOwner()

    local visible = {}
    for _, s in ipairs(self._status_scoped) do
        if s.persistent or s.owner == active_owner then
            visible[#visible + 1] = s
        end
    end
    table.sort(visible, function(a, b)
        if a.position ~= b.position then
            return a.position > b.position
        end
        return a.sequence > b.sequence
    end)

    -- Self-invalidating by construction: a registration added or removed changes
    -- this list, so there is no separate epoch to keep in step with it.
    local shown = self._status_visible
    if shown and #shown == #visible then
        local same = true
        for i = 1, #visible do
            if shown[i] ~= visible[i] then
                same = false
                break
            end
        end
        if same then return end
    end

    local wanted = {}
    for _, s in ipairs(visible) do wanted[s] = true end

    for _, s in ipairs(self._status_scoped) do
        if s.present and not wanted[s] then
            pcall(iup.Detach, s.container)
            s.present = false
        end
    end

    -- Appending each in turn leaves them in exactly this order. Elements already
    -- in the bar are reordered by `core.lib.tree` without being unmapped, so the
    -- ones whose visibility did not change keep the windows they already had --
    -- only the elements genuinely arriving or leaving cost anything.
    for _, s in ipairs(visible) do
        local kept = tree.place(iup, self._status_box, s.container, nil)
        if self._shown and not kept then pcall(iup.Map, s.container) end
        s.present = true
    end

    self._status_visible = visible
    pcall(iup.Refresh, self._status_box)
end


-- Re-scope every tab-owned contribution (menu items AND status-bar widgets) to the
-- currently active tab. This is the single entry point to call on any tab switch:
-- menu and status scoping must always move together, and splitting them is exactly
-- how the status indicator got stranded on other tabs when TabOrder's programmatic
-- switch bypassed TABCHANGE_CB (which fires only on native, non-reordered clicks).
function M._applyTabScopes(self)
    self:_applyMenuScope()
    self:_applyStatusScope()
end

return M

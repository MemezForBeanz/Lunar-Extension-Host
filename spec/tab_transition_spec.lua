-- spec/tab_transition_spec.lua — the geometry of the tab page transition.
--
-- This is the app's most-repeated animation and its travel distance has now been
-- wrong in both directions: first a literal full-width push, which on a maximised
-- 4K page works out around 16,000 px/s and reads as a smear, then a 14% fraction
-- so short the movement was barely visible and the whole thing read as a dissolve.
--
-- What actually governs how it feels is absolute pixels per second, so the
-- assertions here are about distance:
--
--   * the pixel cap holds apparent speed constant across window sizes — the same
--     travel on a laptop and on a 4K display
--   * a small window scales below the cap rather than overshooting its own page
--   * `travel = 1, fade = false` still reproduces the literal Carbon rigid pair,
--     both pages exactly one page width apart at every instant
--   * the composition never leaves a hole: every pixel of the frame is covered by
--     the opaque outgoing page or by the incoming page over it
--
-- IUP, the overlay and the director are all faked, so the composition can be
-- sampled as numbers instead of looked at.

local TabTransition = require("core.ui.TabTransition")
local Tokens = require("core.lib.MotionTokens")

-- Captures what the transition draws, so a frame can be inspected as data.
--
-- The composer clips every draw to the part of the page actually on the canvas,
-- so a recorded blit reports where the VISIBLE part landed -- not the page's
-- logical offset -- and a page entirely off-canvas is not recorded at all. The
-- logical geometry is read from `state.from_x` / `state.to_x` instead; see
-- `frameAt` below.
local function fake_overlay(w, h)
    local o = { blits = {}, fills = {}, w = w, h = h }
    function o:available() return true end
    function o:capture() return { w = w, h = h, release = function() end } end
    function o:show(_page, draw) self._draw = draw; return true end
    function o:hide() end
    function o:redraw() end
    function o:fill(x, _y, fw, _fh)
        self.fills[#self.fills + 1] = { x = x, w = fw }
    end
    function o:blit(snap, x, _y, sw, _sh, sx)
        self.blits[#self.blits + 1] = { snap = snap, x = x, w = sw, sx = sx }
    end
    function o:blendBlit(snap, x, _y, alpha, sw, _sh, sx)
        self.blits[#self.blits + 1] = { snap = snap, x = x, alpha = alpha, w = sw, sx = sx }
    end

    -- Run the composer at eased progress `t`.
    --
    -- Returns the two draws in order plus the geometry table, so a test can
    -- assert either what was painted (clipping) or where the pages logically sat
    -- (the motion contract). Either may be nil when that page is off-canvas.
    function o:frameAt(t, state)
        self.blits = {}
        self.fills = {}
        state.progress = t
        self._draw(self)
        return self.blits[1], self.blits[2], state
    end

    -- Every canvas column painted at least once, by a blit or a backdrop fill.
    -- This is the guarantee clipping must not break: a column nothing writes to
    -- keeps whatever the back buffer held, which is a ghost of the last
    -- transition.
    function o:coverage()
        local cols = {}
        for i = 0, self.w - 1 do cols[i] = 0 end
        local function mark(x, width)
            if not (x and width) then return end
            for i = x, x + width - 1 do
                if cols[i] ~= nil then cols[i] = cols[i] + 1 end
            end
        end
        for _, b in ipairs(self.blits) do mark(b.x, b.w) end
        for _, f in ipairs(self.fills) do mark(f.x, f.w) end
        return cols
    end
    return o
end

local function fake_director(roles)
    local d = { roles = roles or {} }
    function d:enabled() return true end
    function d:role(name) return Tokens.role(name, self.roles) end
    function d:animate(spec) self.spec = spec; return { done = function() return false end } end
    function d:finish() end
    function d:cancel() end
    return d
end

local function fake_iup()
    local iup = { DEFAULT = 0 }
    function iup.timer() return {} end
    function iup.SetAttribute() end
    function iup.GetAttribute(_, name)
        if name == "VALUEPOS" then return "1" end
    end
    function iup.GetChild(_, pos) return { pos = pos } end
    return iup
end

-- Drive a switch from tab 0 to tab 1 (forward) on a page `w` wide, and return
-- the overlay plus the state table the composer reads.
local function play(w, roles)
    local iup = fake_iup()
    local overlay = fake_overlay(w, 500)
    local director = fake_director(roles)
    local t = TabTransition:new({ iup = iup, director = director, overlay = overlay })

    local state = {}
    -- _play is the whole composition; calling it directly skips the arm/commit
    -- plumbing, which is IUP-event-driven and not what this file is about.
    local snap = overlay:capture()
    t:_play({}, snap, {}, 0, 1)
    -- The composer closes over TabTransition's own state table; reach it back
    -- through the active record so frames can be sampled at chosen progress.
    state = t._active
    return overlay, state, director
end

-- Distance the incoming page travels: its offset at t=0 (it settles at 0).
--
-- Read from the geometry rather than from the draw, because at full travel the
-- page is entirely off-canvas at t=0 and is correctly not drawn.
local function incoming_travel(overlay, state)
    overlay:frameAt(0, state)
    return math.abs(state.to_x)
end

describe("TabTransition travel", function()
    it("caps travel in pixels so apparent speed is the same on any display", function()
        -- The point of the cap: a laptop and a 4K display get the SAME slide, so
        -- the transition feels identical rather than four times as fast on the
        -- bigger screen.
        assert.are.equal(360, incoming_travel(play(1366)))
        assert.are.equal(360, incoming_travel(play(3840)))
    end)

    it("scales below the cap on a window too small to reach it", function()
        -- Below ~1125 px the fraction is the binding constraint, so a narrow pane
        -- gets a proportionally shorter slide instead of one that dominates it.
        local w = 800
        assert.are.equal(math.floor(w * 0.32), math.floor(incoming_travel(play(w))))
    end)

    it("never travels further than the page itself", function()
        local w = 60
        assert.is_true(incoming_travel(play(w)) <= w)
    end)

    it("lets a theme widen the slide", function()
        local wide = incoming_travel(play(3840, {
            tab_transition = { travel = 0.5, max_travel = 800 },
        }))
        assert.are.equal(800, wide)
    end)
end)

describe("TabTransition composition", function()
    it("cross-fades the incoming page in", function()
        local overlay, state = play(1600)

        local _, early = overlay:frameAt(0.1, state)
        local _, late  = overlay:frameAt(0.9, state)
        assert.is_true(early.alpha < late.alpha)
        -- Opaque before it settles: still translucent at rest looks like the
        -- transition failed to finish.
        assert.are.equal(255, late.alpha)
    end)

    it("settles the incoming page at zero offset", function()
        local overlay, state = play(1600)
        overlay:frameAt(1, state)
        assert.are.equal(0, state.to_x)
    end)

    it("moves the outgoing page less than the incoming one", function()
        -- Two layers at different rates is the depth cue that makes the arriving
        -- page read as leading rather than as a rigid pair.
        local overlay, state = play(1600)
        overlay:frameAt(0.5, state)
        assert.is_true(math.abs(state.from_x) < math.abs(state.to_x))
    end)

    it("leaves no uncovered strip at any point in the slide", function()
        -- The outgoing page is the opaque base; wherever it has vacated must be
        -- covered by the incoming page, or the backdrop shows through as a band.
        local w = 1600
        local overlay, state = play(w)
        for i = 0, 20 do
            local t = i / 20
            overlay:frameAt(t, state)
            local covered_right = math.max(state.from_x + w, state.to_x + w)
            local covered_left  = math.min(state.from_x, state.to_x)
            assert.is_true(covered_left <= 0,
                string.format("gap on the left at t=%.2f", t))
            assert.is_true(covered_right >= w,
                string.format("gap on the right at t=%.2f", t))
        end
    end)

    it("reproduces the literal Carbon rigid pair at travel = 1 with no fade", function()
        local w = 1200
        local overlay, state = play(w, {
            tab_transition = { travel = 1, fade = false },
        })
        for i = 0, 10 do
            local t = i / 10
            local _, incoming = overlay:frameAt(t, state)
            -- Exactly one page width apart at every instant, and drawn opaque.
            assert.are.equal(w, math.abs(state.from_x - state.to_x))
            -- No alpha on any draw the incoming page did make. At t = 0 it is
            -- exactly one page width off-canvas and correctly not drawn at all,
            -- which is the clipping doing its job.
            if incoming then assert.is_nil(incoming.alpha) end
        end
    end)
end)

describe("TabTransition clipping", function()
    -- Clipping is a pure cost reduction, so the contract is: never paint a pixel
    -- that is off-canvas, and never LEAVE a pixel unpainted. The second half is
    -- the one with teeth -- an unpainted column shows whatever the back buffer
    -- held, i.e. a ghost of the previous transition.

    it("paints every canvas column on every frame", function()
        for _, w in ipairs({ 320, 1600, 3840 }) do
            local overlay, state = play(w)
            for i = 0, 20 do
                local t = i / 20
                overlay:frameAt(t, state)
                for col, n in pairs(overlay:coverage()) do
                    assert.is_true(n > 0, string.format(
                        "column %d unpainted at t=%.2f on a %d px page", col, t, w))
                end
            end
        end
    end)

    it("never draws outside the canvas", function()
        local w = 1600
        local overlay, state = play(w)
        for i = 0, 20 do
            local t = i / 20
            overlay:frameAt(t, state)
            for _, b in ipairs(overlay.blits) do
                assert.is_true(b.x >= 0, "blit starts left of the canvas")
                assert.is_true(b.x + b.w <= w, "blit runs past the right edge")
                assert.is_true(b.w > 0, "zero-width blit should be skipped entirely")
            end
        end
    end)

    it("skips a page that is entirely off-canvas", function()
        -- travel = 1 puts the incoming page exactly one page width away at t = 0,
        -- so there is nothing of it to draw. The whole point of the optimisation
        -- is that this costs nothing rather than a full-page blit.
        local overlay, state = play(1200, {
            tab_transition = { travel = 1, fade = false },
        })
        local _, incoming = overlay:frameAt(0, state)
        assert.is_nil(incoming)
    end)

    it("offsets into the source when a page hangs off the left edge", function()
        -- A page at x = -100 must skip its first 100 source columns, not squash
        -- the full width into the remaining space.
        local w = 1600
        local overlay, state = play(w)
        local outgoing = overlay:frameAt(1, state)
        assert.is_true(state.from_x < 0, "outgoing page should have moved left")
        assert.are.equal(0, outgoing.x)
        assert.are.equal(math.abs(math.floor(state.from_x + 0.5)), outgoing.sx)
        assert.are.equal(w - outgoing.sx, outgoing.w)
    end)

    it("draws no backdrop at all, because the pages already tile the canvas", function()
        -- The composer this replaced filled the whole canvas every frame and then
        -- painted both pages over it. Since travel is clamped to at most the page
        -- width, the two opaque pages always span the canvas between them, so
        -- every one of those pixels was written twice.
        --
        -- Asserting zero fills is what stops that creeping back: the backdrop is
        -- retained only as a guard for geometry that cannot currently occur, and
        -- if it starts painting on the shipped configuration something upstream
        -- has changed the travel clamping.
        for _, w in ipairs({ 320, 1600, 3840 }) do
            local overlay, state = play(w)
            for i = 0, 20 do
                local t = i / 20
                overlay:frameAt(t, state)
                assert.are.equal(0, #overlay.fills, string.format(
                    "backdrop painted at t=%.2f on a %d px page", t, w))
            end
        end
    end)

    it("blits no more pixels than are actually on screen", function()
        -- The guarantee that makes this an optimisation rather than a rewrite.
        local w = 3840
        local overlay, state = play(w)
        for i = 0, 20 do
            local t = i / 20
            overlay:frameAt(t, state)
            local painted = 0
            for _, b in ipairs(overlay.blits) do painted = painted + b.w end
            for _, f in ipairs(overlay.fills) do painted = painted + f.w end
            -- Two full-page layers was the old cost; anything at or above that
            -- means clipping is not actually reducing the work.
            assert.is_true(painted < 2 * w, string.format(
                "painted %d columns at t=%.2f, no better than the unclipped composer", painted, t))
        end
    end)
end)

describe("TabTransition scheduling", function()
    it("animates under the tab_transition role rather than a literal duration", function()
        local _, _, director = play(1600)
        assert.are.equal("tab_transition", director.spec.role)
        -- No explicit duration: a theme retunes this without touching the module.
        assert.is_nil(director.spec.duration)
        -- And no distance either, or the role's fixed duration would be replaced
        -- by one derived from the page width -- the original bug.
        assert.is_nil(director.spec.distance)
    end)
end)

-- A stateful IUP fake that tracks which tab is currently selected, so that
-- arm() captures the outgoing position and _startPending() sees the incoming one.
-- The comment that previously said "commit() drops the transition on the floor"
-- was describing the bug: commit() was checking VALUEPOS synchronously inside
-- TABCHANGE_CB, before iFlatTabsSetCurrentTab had run.
local function fake_iup_switching()
    local iup = { DEFAULT = 0 }
    local current_pos = "0"
    function iup.timer() return {} end
    function iup.SetAttribute() end
    function iup.GetAttribute(_, name)
        if name == "VALUEPOS" then return current_pos end
    end
    function iup.GetChild(_, pos) return { pos = pos } end
    -- Advance the simulated strip to a new tab, as IUP's iFlatTabsSetCurrentTab
    -- does AFTER iFlatTabsCallTabChange (and therefore after TABCHANGE_CB) returns.
    function iup._switchTo(pos) current_pos = tostring(pos) end
    return iup
end

describe("TabTransition arm → commit → play pipeline", function()
    -- This is the end-to-end path for a mouse click: arm() captures the outgoing
    -- page, commit() receives the TABCHANGE_CB and schedules the start timer,
    -- and the timer fires _startPending() → _play().  The existing suite only
    -- tests _play() geometry directly, which left the full click path untested.
    --
    -- ### The IUP call-order bug this pins
    --
    -- In iup_flattabs.c, `iFlatTabsCallTabChange` (which fires TABCHANGE_CB) is
    -- called *before* `iFlatTabsSetCurrentTab` updates VALUE/VALUEPOS (lines
    -- 1394 and 1396 of the vendor source).  When commit() read VALUEPOS
    -- synchronously inside TABCHANGE_CB it always saw the outgoing position,
    -- so `to_pos == armed.pos` was true on every click and every transition was
    -- silently dropped before _startPending ever ran.
    --
    -- The fix defers the position check to _startPending (1 ms later, after the
    -- button handler has returned and iFlatTabsSetCurrentTab has settled).
    -- The tests below reproduce the actual call order: commit() fires BEFORE the
    -- simulated iup._switchTo(), matching the C ordering.

    local function make_pipeline(w)
        local iup     = fake_iup_switching()
        local overlay = fake_overlay(w or 1000, 600)
        local dir     = fake_director()
        local t       = TabTransition:new({ iup = iup, director = dir, overlay = overlay })
        local strip   = {}   -- the strip is the same object in arm() and commit()
        return t, iup, strip
    end

    local function stat(t, key) return (t._stats or {})[key] or 0 end

    it("reaches the played counter after arm + commit + timer (IUP order: VALUEPOS updated after commit)", function()
        -- Reproduce the real IUP sequence:
        --   1. flat_button_cb(pressed=1): arm()
        --   2. iFlatTabsCallTabChange: commit()   ← VALUEPOS still == from_pos here
        --   3. iFlatTabsSetCurrentTab: iup._switchTo(1)
        --   4. 1 ms timer fires: _startPending()
        local t, iup, strip = make_pipeline()

        t:arm(strip)     -- VALUEPOS == "0": outgoing page captured
        assert.are.equal(1, stat(t, "armed"), "arm() should increment armed")

        -- commit() fires BEFORE the switch (matching iFlatTabsCallTabChange order).
        -- Before the fix, commit() read VALUEPOS here (still "0") and silently
        -- dropped the transition because to_pos == armed.pos.
        t:commit(strip)
        assert.are.equal(1, stat(t, "committed"),
            "commit() must schedule the transition regardless of current VALUEPOS")

        iup._switchTo(1)    -- iFlatTabsSetCurrentTab runs after tabchange_cb returns

        -- Fire the 1-ms start timer synchronously.
        local timer = t._start_timer
        assert.is_not_nil(timer, "commit() should have created the start timer")
        timer:action_cb()

        assert.are.equal(1, stat(t, "played"), "play should reach the played counter")
        assert.are.equal(1, stat(t, "shown"),  "play should reach the shown counter")
    end)

    it("_startPending skips the animation when no navigation happened", function()
        -- If commit() is called but the strip's position hasn't changed by the
        -- time _startPending runs (e.g. the user switched back in < 1 ms), the
        -- committed counter still advances but the animation is correctly withheld.
        local t, _iup, strip = make_pipeline()

        t:arm(strip)     -- VALUEPOS stays "0"
        t:commit(strip)  -- schedules _startPending
        assert.are.equal(1, stat(t, "committed"))

        -- Timer fires — iup._switchTo was never called, so VALUEPOS is still "0"
        -- (from_pos). _startPending must release the snap without playing.
        local timer = t._start_timer
        timer:action_cb()

        assert.are.equal(0, stat(t, "played"),
            "_startPending should not play when to_pos == from_pos")
    end)

    it("ignores a commit with no prior arm (e.g. programmatic switch)", function()
        -- TABCHANGE_CB fires for programmatic switches too.  Without a prior
        -- arm() the capture is nil, and commit() must decline without crashing.
        local t, iup, strip = make_pipeline()

        iup._switchTo(1)
        t:commit(strip)

        assert.are.equal(0, stat(t, "committed"),
            "commit without arm must not count a transition")
        assert.are.equal(0, stat(t, "armed"))
    end)
end)

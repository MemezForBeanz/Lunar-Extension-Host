--- Staggered entrance animation for a set of sibling IUP widgets.
--
-- Carbon's choreography guidance is explicit: "When multiple elements need to
-- animate, distribute their entrances over time instead of introducing
-- everything at once." Their canonical example is a data table whose rows
-- cascade in at 20 ms apart. This module is the single implementation of that
-- for every list in the app, so the timing and cut-off are consistent
-- everywhere and live next to the `list_stagger` role that owns them.
--
-- ### What the host's own lists actually get from this
--
-- Worth stating plainly, because the module name oversells it for the two
-- callers that exist today: `core.ui.CheckList` and `core.ui.ReorderableList`
-- are each a **single** `IupFlatList`. Their rows are internal to one native
-- control and are not addressable as separate widgets from Lua, so both pass a
-- one-element array -- and `MotionTokens.stagger(1, 1)` is zero. What those two
-- surfaces get is a single grow-in, not a row-by-row cascade.
--
-- That is a limit of the control, not of this module: the stagger is real for
-- any caller that hands over genuine sibling widgets, which is why `play` takes
-- an array rather than a list handle. Nothing in the host does that yet. Do not
-- "fix" the apparent no-op by reaching into the list control -- the honest fix
-- is a surface built from real per-row widgets.
--
-- ### What animates — and why height, not opacity
--
-- IUP has no per-widget opacity. A true fade would require a GDI snapshot per
-- row, an alpha-blending pass every frame, and a layered-window compositing
-- surface — the same machinery `core.ui.MotionOverlay` uses for page
-- transitions. That overhead is acceptable for one fullscreen transition; it
-- is not acceptable for up to forty rows running concurrently.
--
-- Instead, each row enters by growing from zero to its natural height,
-- following the same `RASTERSIZE` / `FLOATING` / `iup.Refresh` dance that
-- `core.ui.SettingsView._setOpen` uses. A row that grows upward from nothing
-- reads as appearing: it is entering the view, not just getting taller. The
-- entrance easing on `list_stagger` (`{0,0,0.38,0.9}`) starts fast and slows
-- to a stop, which is exactly the "lands softly" feel Carbon shows in its
-- reference video.
--
-- ### One shared refresh per tick, not one per row
--
-- The naive approach calls `iup.Refresh` inside every row's `on_frame`,
-- which is O(rows²) relayouts per second — each refresh measures and relays
-- the entire container. Instead, we pin a shared flag in the closure and let
-- all the `on_frame` callbacks in a single tick mark it dirty; a dedicated
-- finishing callback flushes one `iup.Refresh(container)` at the end of the
-- tick. Because the director's `_runPass` calls every `on_frame` in a single
-- synchronous sweep before returning, the flag is always flushed within the
-- same tick it was set.
--
-- A MotionDirector callback that schedules another animation achieves this
-- naturally: the per-row callbacks only set `RASTERSIZE`, and one extra
-- animation (duration=0, delay=0, same tick) does the single refresh.
-- The simpler approach chosen here — a Lua closure shared across all callbacks
-- — avoids that extra allocation and is safe because all the `on_frame` calls
-- happen synchronously before control leaves `director:tick()`.
--
-- ### The limit
--
-- Past `list_stagger.limit` rows (40 by default) the list is a scrollable
-- catalogue, not a content reveal. Animating four hundred rows at 20 ms apart
-- would take 8 seconds and serve no one. Above the limit every row lands
-- immediately — which the director handles automatically when animations with
-- `duration = 0` are scheduled, but here we just skip `play` entirely and
-- call the settle helper directly.
--
-- ### Motion off is not a special case
--
-- When motion is disabled, the director calls `on_frame(to)` then
-- `on_done(true)` synchronously inside `animate()`, before it returns. Every
-- row therefore settles at its natural height within `play()` itself, with no
-- branching needed anywhere in this module. This is the fundamental contract
-- of the motion system; see `docs/motion.md` §"Motion off is not a special
-- case".
--
-- @module core.ui.ListEntrance

local Tokens = require("core.lib.MotionTokens")

local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Read NATURALSIZE and return the pixel height, or nil when the widget has not
-- been mapped yet (layout pass has not run). We want the row's *natural* height,
-- not whatever RASTERSIZE we may have pinned to it, so we ask for NATURALSIZE
-- rather than RASTERSIZE.
local function naturalHeight(iup, widget)
	local ok, sz = pcall(iup.GetAttribute, widget, "NATURALSIZE")
	if not ok or not sz then return nil end
	-- NATURALSIZE is "WidthxHeight"; grab the part after "x".
	local h = tonumber(sz:match("x(%d+)"))
	return (h and h > 0) and h or nil
end

-- Bring a row to its fully-settled state: RASTERSIZE released, FLOATING=NO,
-- VISIBLE=YES. Mirrors what SettingsView._setOpen's `land()` does, but for
-- entrance (the widget is already nominally visible; we just unlock it).
local function settle(iup, widget)
	local ok = pcall(function()
		iup.SetAttribute(widget, "FLOATING", "NO")
		iup.SetAttribute(widget, "VISIBLE",  "YES")
		iup.SetAttribute(widget, "RASTERSIZE", nil)
	end)
	return ok
end

-- Collapse a row to zero height so it can grow into view. Called just before
-- the animation starts, so the row is invisible at frame 0.
local function collapse(iup, widget)
	pcall(function()
		-- FLOATING=NO so the row still participates in layout and its siblings
		-- reflow as it grows — FLOATING=YES would make it a free-floating
		-- overlay and break the cascade effect entirely.
		iup.SetAttribute(widget, "FLOATING", "NO")
		iup.SetAttribute(widget, "RASTERSIZE", "x0")
	end)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Animate a set of sibling widgets in as a staggered cascade.
--
-- Each widget grows from zero to its natural height, with a delay computed by
-- `MotionTokens.stagger` so the first row starts at 0 ms, the second at 20 ms,
-- etc., automatically compressed if the list is long enough that the raw delay
-- would breach the 500 ms Carbon ceiling.
--
-- When `#items` exceeds `opts.limit` (default: the `list_stagger` role's
-- `limit` extra, currently 40), every widget lands immediately without
-- animation — past that count the list is scrolled rather than read in, and
-- the stagger would run longer than the ceiling it exists to enforce.
--
-- Re-entrancy: each widget is registered as the `target` of its animation, so
-- calling `play` again while a prior entrance is in flight supersedes the old
-- animation on each row rather than stacking on top of it.
--
-- Fail-soft: a widget destroyed between scheduling and playback does not raise;
-- the bad `on_frame` is silently dropped by the director's `pcall` discipline.
--
-- @tparam table director `core.classes.MotionDirector` instance.
-- @tparam table items Array of IUP widget handles, or records with a `widget`
--   field. Mixed formats are supported: if `items[i]` has a `.widget` field
--   that field is used; otherwise `items[i]` is treated as the widget directly.
-- @tparam[opt] table opts Options:
--   * `container` — the parent IUP widget to refresh after each frame. When
--     omitted each widget refreshes itself, so callers that forget the container
--     still land visible rather than collapsed. The refresh is batched to one
--     call per tick to avoid O(rows²) relayout (see module header).
--   * `step` — ms between rows; defaults to `list_stagger.step` (20).
--   * `limit` — max rows to stagger; defaults to `list_stagger.limit` (40).
--   * `sequence` — a `MotionTokens.SEQUENCE` category name (`"shell"`, `"body"`,
--     `"dynamic"`, `"primary"`, `"visual"`). Offsets the whole cascade by that
--     category's delay, so a page composed of several of these lists enters in
--     Carbon's published running order -- static content first, the primary
--     action last -- without each caller working out its own delay. A list is
--     `"dynamic"` unless it is something else, which is why omitting this costs
--     nothing.
-- @usage
--   ListEntrance.play(director, rows, { container = self._panel })
-- @usage
--   ListEntrance.play(director, rows, { sequence = "dynamic" })
function M.play(director, items, opts)
	if not director then return end
	if type(items) ~= "table" then return end
	opts = opts or {}

	local role_spec  = director:role("list_stagger")
	local step       = tonumber(opts.step)  or role_spec.step  or 20
	local limit      = tonumber(opts.limit) or role_spec.limit or 40
	-- Offset shared by every row, so the cascade keeps its own internal 20 ms
	-- rhythm and simply starts later relative to the rest of the page.
	local lead       = opts.sequence and Tokens.sequence(opts.sequence) or 0
	local container  = opts.container
	local iup        = director._iup

	local n = #items
	if n == 0 then return end

	-- Above the limit the list is something the user scrolls, not reads in.
	-- Animate nothing; just ensure every row is settled and do one refresh.
	if n > limit then
		if iup then
			for _, item in ipairs(items) do
				local w = (type(item) == "table" and item.widget) or item
				if w then settle(iup, w) end
			end
			if container then pcall(iup.Refresh, container) end
		end
		return
	end

	-- Shared dirty flag: all per-row on_frame callbacks in one tick mark this
	-- true; the batching flush (below) issues one iup.Refresh per tick rather
	-- than one per row. All on_frame calls within a tick are synchronous
	-- (director._runPass is a single sweep), so the flag is always drained
	-- within the same tick it is set.
	--
	-- When container is nil we fall back to refreshing the widget itself, so
	-- a caller that forgets the container still gets visible rows. Both current
	-- callers (CheckList, ReorderableList) animate a single list widget and
	-- pass no container; the widget IS the thing that needs a layout pass.
	local dirty = { false }

	-- The refresh target: an explicit container when supplied, otherwise the
	-- first animated widget we encounter (set below on the first iteration).
	-- Using the container is correct when items are children of it; using the
	-- widget itself is correct when the widget is a self-contained list that
	-- manages its own layout, which is the single-widget caller pattern.
	local flush_target = container

	for i, item in ipairs(items) do
		local w = (type(item) == "table" and item.widget) or item
		if w and iup then
			-- Measure the natural height before we collapse it. If the widget
			-- has not been mapped yet (NATURALSIZE is nil) we skip the
			-- animation for this row and settle it immediately — it is better
			-- for one unmapped row to appear instantly than for it to sit at
			-- height 0 permanently.
			local target_h = naturalHeight(iup, w)
			if not target_h then
				settle(iup, w)
			else
				-- Capture the fallback refresh target from the first real row.
				-- This makes the no-container path self-contained: whichever
				-- widget collapsed will also drive the layout flush.
				if not flush_target then flush_target = w end

				collapse(iup, w)

				local delay = lead + Tokens.stagger(i, n, step)

				-- Capture per-iteration locals — Lua closures bind the
				-- *variable*, not the *value*, so without a fresh local the
				-- inner functions would all see the same `w` and `target_h`.
				local widget   = w
				local height   = target_h

				director:animate{
					role     = "list_stagger",
					delay    = delay,
					from     = 0,
					to       = height,
					-- Each widget is its own target so a re-play supersedes
					-- rather than stacking.
					target   = widget,
					on_frame = function(v)
						-- Fail-soft: the pcall inside the director already
						-- catches throws from on_frame, but the director
						-- drops the animation on an error. Use an explicit
						-- guard so a destroyed widget does not abort the
						-- whole sequence.
						pcall(function()
							iup.SetAttribute(widget, "RASTERSIZE",
								"x" .. math.floor(v))
						end)
						-- Mark flush_target as needing one refresh this tick.
						-- The flush animation (scheduled after all rows) drains
						-- this flag once per tick, keeping layout passes at
						-- O(1) per tick rather than O(rows).
						dirty[1] = true
					end,
					on_done  = function()
						pcall(settle, iup, widget)
						-- on_done also needs a refresh so the final settled
						-- state is visible. The flush animation drains this
						-- flag on the same tick.
						dirty[1] = true
					end,
				}
			end
		end
	end

	-- Batch the container refresh: schedule a sentinel animation that covers
	-- the full cascade window and fires on_frame after every row's on_frame
	-- in each tick (director processes in insertion order). The sentinel drains
	-- the dirty flag once per tick, so the relayout cost is O(1) per tick
	-- regardless of row count.
	--
	-- Duration must outlive the entire cascade. The last row's stagger delay
	-- is at most 500 ms (Carbon ceiling); adding the row's own animation
	-- duration (fast_02 = 110 ms) gives 610 ms. We use 700 ms — one Carbon
	-- slow_01 token — so the sentinel cleanly outlives even a theme-scaled
	-- or stagger-extended cascade without needing to know the exact per-theme
	-- durations. It stops itself early once all rows have landed (dirty never
	-- set again) but that is a free-ride optimisation, not required.
	--
	-- When motion is disabled, the director delivers every on_frame and on_done
	-- synchronously inside animate(), so dirty[1] is already true by the time
	-- we reach this call. The sentinel therefore also fires synchronously,
	-- flushing the flag and issuing the refresh before play() returns — no
	-- special-casing needed, per the "Motion off is not a special case" contract.
	if flush_target and iup then
		local ft = flush_target
		director:animate{
			duration = 700,
			from     = 0,
			to       = 0,
			on_frame = function()
				if dirty[1] then
					dirty[1] = false
					pcall(iup.Refresh, ft)
				end
			end,
			on_done  = function()
				-- Final flush: the last row's on_done may have set dirty[1]
				-- on the same tick the sentinel completes. Drain it now so
				-- the settled state becomes visible without waiting for a
				-- further tick that will never come.
				if dirty[1] then
					dirty[1] = false
					pcall(iup.Refresh, ft)
				end
			end,
		}
	end
end

return M

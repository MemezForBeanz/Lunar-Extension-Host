--- IBM Carbon Design System motion tokens: durations, easing curves, choreography.
--
-- The single source of truth for every duration and easing curve in the app. This
-- module is **data plus arithmetic only** -- it never touches IUP, FFI or the
-- clock, which is what makes the whole motion vocabulary testable under plain
-- busted.
--
-- ### Productive vs expressive
--
-- Carbon recognises two motion styles, and the choice is a design decision, not a
-- tuning knob:
--
--   * **productive** -- efficient and out of the way. Use for anything the user
--     does repeatedly while concentrating on a task: switching tabs, reordering,
--     hover feedback. If a user notices it twice, it is wrong.
--   * **expressive** -- deliberately visible. Reserve it for occasional, significant
--     moments where the movement itself carries meaning: forming a tab group,
--     a system alert. Overusing it is what makes an interface feel slow.
--
-- ### Easing curves
--
-- Strictly linear movement reads as mechanical, so every curve here accelerates and
-- decelerates. Which of the three to use is decided by whether the element is
-- present at both ends of the motion:
--
--   * **standard** -- visible from start to finish (a tab sliding to a new position).
--   * **entrance** -- appears and slows to a stop (a drop indicator appearing).
--   * **exit**     -- speeds up as it leaves, implying it is gone for good.
--     Exception: something that leaves but stays nearby ready to return (a side
--     panel) uses **standard**, because it should read as coming to rest just
--     offscreen rather than departing.
--
-- @module core.lib.MotionTokens

local M = {}

--- Carbon duration tokens, in milliseconds.
--
-- Keyed by Carbon's own token names. Callers should prefer `M.duration()`, which
-- picks and scales a token by travel distance; reach for a literal token only when
-- the motion has no meaningful distance (a fade, a color change).
--
--   * `fast_01`     70 ms  -- micro-interactions: buttons, toggles
--   * `fast_02`    110 ms  -- micro-interactions: fades
--   * `moderate_01` 150 ms  -- small expansions, short-distance movement
--   * `moderate_02` 240 ms  -- expansion, system communication, toasts
--   * `slow_01`    400 ms  -- large expansion, important notifications
--   * `slow_02`    700 ms  -- background dimming
M.DURATION = {
	fast_01     = 70,
	fast_02     = 110,
	moderate_01 = 150,
	moderate_02 = 240,
	slow_01     = 400,
	slow_02     = 700,
}

--- Cubic-bezier control points for every Carbon easing curve.
--
-- Indexed `M.EASING[curve][style]`, each a four-element array
-- `{x1, y1, x2, y2}` matching the CSS `cubic-bezier()` notation Carbon publishes.
-- Feed these to `core.lib.MotionEasing.curve()`.
--
-- Fields are listed explicitly: left to infer them, LDoc reads the nested
-- control-point arrays as array entries of this table and rejects it.
-- @table EASING
-- @field standard `{productive=, expressive=}` -- elements moving within view
-- @field entrance `{productive=, expressive=}` -- elements entering the view
-- @field exit `{productive=, expressive=}` -- elements leaving the view
M.EASING = {
	standard = {
		productive = { 0.2, 0,    0.38, 0.9 },
		expressive = { 0.4, 0.14, 0.3,  1   },
	},
	entrance = {
		productive = { 0,   0,    0.38, 0.9 },
		expressive = { 0,   0,    0.3,  1   },
	},
	exit = {
		productive = { 0.2, 0,    1,    0.9 },
		expressive = { 0.4, 0.14, 1,    1   },
	},
}

-- Ordered token values, used to clamp dynamic durations to the published scale.
local FAST_02     = M.DURATION.fast_02
local MODERATE_01 = M.DURATION.moderate_01
local SLOW_01     = M.DURATION.slow_01

--- Look up the bezier control points for a curve/style pair.
-- @tparam[opt="standard"] string curve `"standard"`, `"entrance"` or `"exit"`.
-- @tparam[opt="productive"] string style `"productive"` or `"expressive"`.
-- @treturn table Four-element `{x1, y1, x2, y2}` array.
-- @usage local pts = MotionTokens.easing("entrance", "expressive")
function M.easing(curve, style)
	local group = M.EASING[curve or "standard"] or M.EASING.standard
	return group[style or "productive"] or group.productive
end

--- Duration in milliseconds for a motion travelling `distance` pixels.
--
-- Carbon scales duration with the size of the movement -- the further an element
-- travels, the longer it takes -- but **sub-linearly**, on a non-linear scale that
-- keeps long and short movements feeling equally brisk. A linear scale makes large
-- movements feel sluggish long before they look wrong on paper.
--
-- The square-root relationship below is that non-linear scale: doubling the
-- distance multiplies the duration by ~1.4, not 2. Results are clamped to the
-- published token range so no motion can undershoot perceptibility or overstay
-- its welcome.
--
-- Expressive motion is significantly slower than productive, per the spec.
--
-- @tparam[opt=0] number distance Travel distance (or size change) in pixels.
-- @tparam[opt="productive"] string style `"productive"` or `"expressive"`.
-- @treturn number Duration in milliseconds.
-- @usage local ms = MotionTokens.duration(page_width, "productive")
function M.duration(distance, style)
	distance = tonumber(distance) or 0
	if distance < 0 then distance = -distance end

	local expressive = (style == "expressive")
	-- Reference travel at which the base token is reached. Movements shorter than
	-- this get proportionally quicker, longer ones proportionally slower.
	local reference = 400
	local base      = expressive and M.DURATION.moderate_02 or M.DURATION.moderate_01
	local ms        = base * math.sqrt(distance / reference)

	local lo = expressive and MODERATE_01 or FAST_02
	local hi = expressive and M.DURATION.slow_02 or SLOW_01
	if ms < lo then ms = lo end
	if ms > hi then ms = hi end
	return ms
end

--- Default motion for each animated surface in the host, keyed by role name.
--
-- A **role** is a named moment in the UI -- switching a tab, opening a settings
-- section -- rather than a widget. Naming the moment is what lets a theme restyle
-- it: `core.classes.Themes.Theme:motion()` returns a table of the same shape whose
-- entries are merged over these, so a theme can slow one surface down or give it a
-- different curve without knowing which module implements it.
--
-- Every field is optional in an override. Anything a theme leaves out keeps the
-- Carbon-correct default below, so a theme that only cares about one role writes
-- exactly one line.
--
-- Recognised fields:
--
--   * `duration` -- milliseconds, or `nil` to derive from distance
--   * `curve` -- `"standard"`, `"entrance"`, `"exit"`, or raw `{x1,y1,x2,y2}` points
--   * `style` -- `"productive"` or `"expressive"`
--   * `delay` -- milliseconds before the first frame
--   * plus any role-specific extras, which are passed through untouched (see
--     `travel` and `fade` on `tab_transition`)
--
-- Fields are listed explicitly; the rationale for each default lives in the
-- comments beside it in the source, which LDoc would otherwise misparse.
-- @table ROLES
-- @field tab_transition switching tabs
-- @field tab_drag_caret the insertion caret sliding between tabs during a drag
-- @field tab_drag_combine the highlight over a tab that a drop would group with
-- @field tab_group_merge the highlight contracting as a tab group forms
-- @field settings_expand a settings section or row opening
-- @field settings_collapse a settings section or row closing
-- @field scrim_in dimming the page behind a modal
-- @field scrim_out lifting that dim
-- @field modal_enter a modal arriving
-- @field modal_exit a modal dismissed by completing it
-- @field modal_cancel a modal dismissed by backing out
-- @field toast_enter a notification arriving
-- @field toast_exit a notification leaving on its own
-- @field list_stagger one row of a list or table arriving
-- @field progress_advance a progress bar moving between values
-- @field status_change the status line changing text
M.ROLES = {
	-- Switching tabs. The single most repeated navigation in the app, so it is
	-- productive and firmly in the middle of the duration band -- long enough to
	-- read as movement, short enough that a user stepping through five tabs is
	-- never waiting on it.
	--
	-- `travel` is the fraction of the page width the pages slide, and `max_travel`
	-- caps that in absolute pixels. Together they decide whether this reads as a
	-- window sliding or as a whip.
	--
	-- A full-width push (`travel = 1`) has to cover a whole 4K page inside the
	-- productive band, which works out around 16,000 px/s -- fast enough that the
	-- eye gets motion blur and no spatial information, which is the opposite of
	-- the point.
	--
	-- The fix is a pixel cap rather than a smaller fraction. Perceived speed is
	-- about absolute distance over time, not about the proportion of the window
	-- crossed, so a fraction alone either whips on a large display or -- as this
	-- did at 0.14 -- becomes so short on any display that the movement is barely
	-- there and the transition reads as a plain fade. Capping the pixels keeps the
	-- apparent speed constant at every window size: small windows scale, large
	-- ones settle at `max_travel`.
	--
	-- 360 px over 240 ms is 1500 px/s -- unmistakably a slide, and still well
	-- inside what the eye tracks cleanly.
	tab_transition = {
		duration   = M.DURATION.moderate_02,
		curve      = "standard",
		style      = "productive",
		travel     = 0.32,
		max_travel = 360,
		fade       = true,
	},

	-- The thin caret that slides between tabs during a drag: "this lands here".
	-- Feedback on a live gesture, so it is the fastest thing in the app -- any
	-- slower and it lags visibly behind the cursor that is driving it.
	tab_drag_caret = {
		duration = M.DURATION.fast_02,
		curve    = "standard",
		style    = "productive",
	},

	-- The highlight that scales up over a tab during a drag: "these two become
	-- one". Deliberately a different shape of motion from the caret -- expressive
	-- rather than productive -- because the same gesture produces two meaningfully
	-- different outcomes, which is Carbon's intentional inconsistency.
	tab_drag_combine = {
		duration = M.DURATION.fast_02,
		curve    = "entrance",
		style    = "expressive",
	},

	-- Forming a tab group: the highlight contracts from the span of both source
	-- tabs down to the new group tab. The one expressive moment in the host --
	-- occasional, significant, and the movement itself tells the "two became one"
	-- story.
	tab_group_merge = {
		duration = M.DURATION.slow_01,
		curve    = "entrance",
		style    = "expressive",
	},

	-- A settings section or row opening.
	--
	-- This times the header CHEVRON's rotation, not a height reveal. The section
	-- body is shown in a single layout pass rather than animated, because a
	-- layout pass in IUP is a whole-dialog operation -- see the RELAYOUT block in
	-- `core.ui.SettingsView` -- and running one per frame made this the slowest
	-- surface in the application.
	--
	-- The duration is explicit because the sweep is a fixed 90 degrees whatever
	-- the section contains, not derived from the body's height.
	--
	-- Entrance easing: the chevron arrives at its open position and slows to a
	-- stop, matching content appearing in a seam.
	settings_expand = {
		duration = M.DURATION.fast_02,
		curve    = "entrance",
		style    = "productive",
	},

	-- The same seam closing. Not `exit` -- the content is not gone for good, it is
	-- one click away, and Carbon's stated exception for elements that leave but
	-- stay nearby is to use standard easing so they read as coming to rest just
	-- out of view.
	settings_collapse = {
		duration = M.DURATION.fast_02,
		curve    = "standard",
		style    = "productive",
	},

	-- Dimming the page behind a modal. `slow_02` exists in Carbon's scale for
	-- exactly one purpose -- "background dimming" -- and this is the only role
	-- that uses it. The dim is deliberately the slowest thing in the app: it is
	-- context rather than content, and a scrim that snaps reads as a light being
	-- switched off rather than as the page receding.
	--
	-- `alpha` is the resting opacity, 0-255. Carbon's overlay is black at 50%.
	scrim_in = {
		duration = M.DURATION.slow_02,
		curve    = "entrance",
		style    = "productive",
		alpha    = 128,
	},

	-- Lifting the dim. Faster than raising it, and `exit` rather than `standard`:
	-- unlike a side panel the scrim is not waiting nearby to be recalled, it is
	-- simply gone once the modal it belonged to has closed. Holding the page dim
	-- for the full 700 ms on the way out would read as the UI being slow to give
	-- control back, which is the one thing a dismissal must never do.
	scrim_out = {
		duration = M.DURATION.moderate_02,
		curve    = "exit",
		style    = "productive",
	},

	-- A modal arriving. Carbon names "opening a new page" and "clicking the
	-- primary action button" as expressive moments, and a modal is both: it is
	-- occasional, it is significant, and it takes the whole window.
	--
	-- `rise` is how far, in pixels, the dialog travels upward into its resting
	-- position. Small on purpose -- the movement is there to give the fade a
	-- direction, not to be a journey of its own.
	modal_enter = {
		duration = M.DURATION.moderate_02,
		curve    = "entrance",
		style    = "expressive",
		rise     = 16,
	},

	-- A modal dismissed by doing the thing it asked for. Exit easing, expressive
	-- to match the entrance: it speeds up as it goes, because the decision is
	-- made and this surface is not coming back.
	modal_exit = {
		duration = M.DURATION.moderate_02,
		curve    = "exit",
		style    = "expressive",
	},

	-- A modal dismissed by backing out -- Cancel, Escape, the close box.
	--
	-- Carbon's *intentional inconsistency*: the same widget leaving the screen
	-- two different ways should not look identical, because the two outcomes are
	-- not. Confirmation is the completion of an expressive arc and keeps the
	-- expressive exit above; cancellation is a retraction, so it is productive
	-- and roughly half the length -- the dialog is withdrawn rather than sent.
	modal_cancel = {
		duration = M.DURATION.fast_02,
		curve    = "exit",
		style    = "productive",
	},

	-- A notification arriving. Carbon: "System alerts and the appearance of
	-- notification boxes are great cases for expressive motion." The whole point
	-- of a toast is to be noticed without stealing focus, which is precisely what
	-- expressive entrance easing buys.
	--
	-- `travel` is how far it slides in from the right edge, and `hold` is how
	-- long it stays before dismissing itself.
	toast_enter = {
		duration = M.DURATION.moderate_02,
		curve    = "entrance",
		style    = "expressive",
		travel   = 32,
		hold     = 5000,
	},

	-- A notification leaving of its own accord. Exit easing: it has said what it
	-- came to say.
	toast_exit = {
		duration = M.DURATION.moderate_02,
		curve    = "exit",
		style    = "expressive",
	},

	-- One row of a list or table arriving. Carbon's worked example for staggering
	-- is a data table entering at 20 ms per row, which is what `step` is; the
	-- per-row motion itself is a short fade, so it sits at the `fast_02` fade
	-- token rather than being derived from distance.
	--
	-- `limit` caps how many rows are staggered. Past that the list is something
	-- the user scrolls rather than reads in, and animating a thousand rows costs
	-- real frames to make a point nobody is watching for.
	list_stagger = {
		duration = M.DURATION.fast_02,
		curve    = "entrance",
		style    = "productive",
		step     = 20,
		limit    = 40,
	},

	-- A progress bar moving between two values. Standard easing because the bar
	-- is present at both ends of the motion; productive because progress is
	-- something the user glances at while doing something else.
	progress_advance = {
		duration = M.DURATION.moderate_01,
		curve    = "standard",
		style    = "productive",
	},

	-- The status line changing text. A cross-fade at the fade token: the status
	-- bar is peripheral, and a hard swap there catches the eye far more than the
	-- information usually deserves.
	status_change = {
		duration = M.DURATION.fast_02,
		curve    = "standard",
		style    = "productive",
	},
}

-- Two Carbon moments are deliberately absent, and it is worth recording why so
-- they are not "fixed" by adding tokens nothing can consume.
--
-- **Menus and dropdowns.** Carbon's own worked example for semantic consistency is
-- that a dropdown opening should share the accordion's motion. It is missing here
-- because the app does not own those surfaces: `core.ui.ContextMenu` shows a real
-- Win32 popup menu, and `IupDropButton` shows and hides its drop child internally.
-- Animating either means owner-drawing menus, which costs their keyboard handling
-- and screen-reader behaviour to buy 150 ms of movement. Not a trade worth making.
--
-- **Hover.** `fast_01` is Carbon's button/toggle token, but IUP's flat controls
-- apply `HLCOLOR` themselves the instant the pointer enters. Tweening it would mean
-- clearing that and driving `BGCOLOR` from `ENTERWINDOW_CB`, fighting the control's
-- own state on every widget in the app for a 70 ms transition -- which is close to
-- the threshold of perception anyway. Carbon's fourth review question is "is your
-- motion frequently noticed? If so, consider removing it"; this one would be
-- noticed only when it broke.

--- Carbon's recommended order for content entering a view.
--
-- Choreography is not only about how one element moves but about which element
-- moves first. Carbon publishes a fixed running order and a reason for it: begin
-- with what is most stable so the frame of reference is established before
-- anything is poured into it, and end with what matters most, because whatever
-- arrives last is what the eye is left on.
--
-- Sequencing the primary action *last* is the load-bearing part. It is the one
-- thing on the page the user is being asked to do, and arriving last is what
-- directs attention to it without a highlight, a pulse or any other decoration.
--
-- Values are the `index` to hand to `M.stagger`, so a caller groups its widgets
-- by category and lets the same ceiling-aware helper space them out:
--
--     local delay = Tokens.stagger(Tokens.SEQUENCE.dynamic, Tokens.SEQUENCE.total)
--
--   1. `shell`   -- UI shell, top and side navigation
--   2. `body`    -- headers, written content, images
--   3. `dynamic` -- data table contents, query results
--   4. `primary` -- the primary action button
--   5. `visual`  -- data visualisations
M.SEQUENCE = {
	shell   = 1,
	body    = 2,
	dynamic = 3,
	primary = 4,
	visual  = 5,
	total   = 5,
}

--- Delay before a given content category should enter.
--
-- A thin wrapper over `M.stagger` that names the category rather than making
-- every call site remember which number it was. Unknown names sort to the end
-- rather than raising, so a typo delays a widget instead of breaking the page.
--
-- @tparam string category A key of `M.SEQUENCE`.
-- @tparam[opt=90] number step Milliseconds between categories.
-- @treturn number Delay in milliseconds.
-- @usage director:animate{ role = "page_enter", delay = Tokens.sequence("primary") }
function M.sequence(category, step)
	local index = M.SEQUENCE[category] or M.SEQUENCE.total
	return M.stagger(index, M.SEQUENCE.total, tonumber(step) or 90)
end

--- Resolve a role's motion, with optional theme overrides layered on top.
--
-- Merging is a single shallow pass, deliberately: a role spec is flat, and a deep
-- merge would make a theme unable to *remove* an inherited field.
--
-- Unknown role names return the overrides alone rather than raising, so a theme
-- naming a role the host has since renamed degrades to Carbon defaults instead of
-- taking the theme switch down with it.
--
-- @tparam string name Role name (a key of `M.ROLES`).
-- @tparam[opt] table overrides Theme motion table, keyed by role name.
-- @treturn table A fresh spec table; never the stored default, so callers may
--   mutate it freely.
-- @usage
--   local spec = MotionTokens.role("tab_transition", theme:motion())
--   director:animate{ duration = spec.duration, curve = spec.curve, ... }
function M.role(name, overrides)
	local out = {}
	local base = M.ROLES[name]
	if base then
		for k, v in pairs(base) do out[k] = v end
	end
	local over = overrides and overrides[name]
	if type(over) == "table" then
		for k, v in pairs(over) do out[k] = v end
	end
	return out
end

--- Delay before the `index`-th element of a staggered sequence starts.
--
-- Introducing many elements at once costs the user a spike of cognitive load;
-- distributing their entrances over time lets the eye follow the content in. The
-- catch is that a fixed per-item delay turns a long list into an unbearable wait,
-- so Carbon caps the **total** sequence at 500 ms. This compresses the step
-- automatically once `total` would breach that ceiling, which is why `total` must
-- be passed rather than inferred.
--
-- @tparam number index 1-based position in the sequence.
-- @tparam[opt=1] number total Number of elements in the sequence.
-- @tparam[opt=20] number step Preferred delay between elements, in milliseconds.
-- @treturn number Delay in milliseconds before this element should start.
-- @usage
--   for i, row in ipairs(rows) do
--     director:animate{ delay = MotionTokens.stagger(i, #rows), ... }
--   end
function M.stagger(index, total, step)
	index = tonumber(index) or 1
	total = tonumber(total) or 1
	step  = tonumber(step) or 20
	if index <= 1 or total <= 1 then return 0 end

	local CEILING = 500
	local spans = total - 1
	if spans * step > CEILING then
		-- Compute the delay directly as a fraction of the ceiling rather than
		-- deriving a compressed step and multiplying back up. The round trip
		-- through `step` accumulates float error, and for a long sequence that put
		-- the final element a hair PAST the ceiling it exists to enforce.
		return (index - 1) / spans * CEILING
	end
	return (index - 1) * step
end

--- Split a two-axis movement into staggered legs so the path has a rounded corner.
--
-- Elements in Carbon move along the grid and **never diagonally**: a diagonal path
-- breaks the grid and reads as harsh. Offsetting the vertical leg against the
-- horizontal one bends the path into a rounded corner instead of a straight
-- diagonal, which is the difference between a movement that looks organised and
-- one that looks sporadic.
--
-- The returned legs overlap deliberately -- the second starts before the first
-- finishes -- which is what rounds the corner rather than squaring it.
--
-- @tparam number dx Horizontal travel in pixels.
-- @tparam number dy Vertical travel in pixels.
-- @tparam[opt="productive"] string style `"productive"` or `"expressive"`.
-- @treturn table `{ x = {delay, duration}, y = {delay, duration}, total = ms }`
-- @usage
--   local path = MotionTokens.cornerPath(dx, dy)
--   director:animate{ delay = path.x.delay, duration = path.x.duration, ... }
function M.cornerPath(dx, dy, style)
	dx = math.abs(tonumber(dx) or 0)
	dy = math.abs(tonumber(dy) or 0)

	local x_ms = M.duration(dx, style)
	local y_ms = M.duration(dy, style)

	-- The longer leg leads; the shorter one joins at 60% of its progress, so the
	-- two overlap for the final 40% and the corner comes out rounded.
	local OVERLAP = 0.6
	local x_delay, y_delay = 0, 0
	if dx >= dy then
		y_delay = x_ms * OVERLAP
	else
		x_delay = y_ms * OVERLAP
	end

	return {
		x = { delay = x_delay, duration = x_ms },
		y = { delay = y_delay, duration = y_ms },
		total = math.max(x_delay + x_ms, y_delay + y_ms),
	}
end

return M

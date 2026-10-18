--- The animation scheduler: one timer, every animation, one off-switch.
--
-- Every piece of motion in the application -- host chrome and extensions alike --
-- is scheduled here. Nothing else owns an animation timer.
--
-- ### One timer, not one per animation
--
-- The obvious design gives each animation its own `iup.timer`. It does not scale:
-- Windows timers are a limited per-process resource, each one costs a `WM_TIMER`
-- dispatch, and independent timers drift against each other so animations that
-- should move together visibly desynchronise. This class runs a **single** shared
-- timer and ticks every active animation from it, so concurrent motion is frame-
-- locked by construction and the cost of ten animations is barely more than one.
--
-- The timer is stopped whenever the queue empties, so an idle application pays
-- nothing at all -- no wakeups, no scheduler pressure, no battery drain.
--
-- ### Time-based, not frame-based
--
-- Progress is computed from the clock, not from a frame counter. Under load, or
-- when Windows coalesces timer messages, frames are simply dropped: a 240 ms
-- animation still finishes in 240 ms, having rendered fewer intermediate steps.
-- A frame-counting driver would instead stretch that animation to 400 ms, which
-- is precisely when the UI feels sluggish -- the moment it is already busy.
--
-- ### The off-switch is structural
--
-- When motion is disabled, `animate()` invokes `on_frame(to)` and `on_done(true)`
-- **synchronously** and returns an already-completed handle. Because every caller
-- in the codebase goes through `animate()`, and because the final value is still
-- delivered, disabling motion cannot leave a widget stranded mid-animation and no
-- call site needs its own `if enabled` branch. That is what makes the setting
-- trustworthy rather than merely mostly-effective.
--
-- @classmod core.classes.MotionDirector

local class = require("middleclass")

local Tokens = require("core.lib.MotionTokens")
local Easing = require("core.lib.MotionEasing")
local Clock  = require("core.lib.MotionClock")

local MotionDirector = class("MotionDirector")

-- ~60 fps. Windows cannot dispatch WM_TIMER faster than the system timer
-- resolution, which is why the driver holds MotionClock's 1 ms resolution for as
-- long as it is running (see _startTimer).
local FRAME_MS = 16

-- Deliberately no maximum-frame-step clamp.
--
-- The usual defence against a long stall (debugger, modal dialog, minimised
-- window) is to cap the time attributed to one tick so animations pause rather
-- than teleport. That is the right call for long-running motion, but every Carbon
-- duration is at most `slow_02` (700 ms) -- so any cap loose enough to leave
-- ordinary jank alone is also loose enough to complete every animation we have,
-- and a cap tight enough to bite would stretch a heavy relayout into the very
-- frame-based sluggishness this driver exists to avoid.
--
-- Landing instantly is also simply the better behaviour: after a multi-second
-- freeze the user has lost all context, and a 240 ms pane slide starting *then*
-- is more disorienting than arriving already settled. Progress is clamped to 1
-- and `_stop(rec, true)` still delivers the end value, so nothing is stranded.

--- Create a director.
--
-- `opts` fields:
--
--   * `iup` -- the IUP binding (required for real animation; without it the
--     director still works but completes every animation immediately)
--   * `enabled` -- master switch, default `true`
--   * `scale` -- duration multiplier, default `1.0`
--   * `respect_system` -- honour the OS reduce-motion setting, default `true`
--   * `clock` -- injectable time source `fn() -> seconds`, for tests
--
-- @tparam table opts construction options (see above)
function MotionDirector:initialize(opts)
	opts = opts or {}
	self._iup   = opts.iup
	self._clock = opts.clock or Clock.now
	-- Without a precise clock, time only advances in whole seconds: animations
	-- would hold their first frame and then jump. Finish them instead.
	self._clock_ok = opts.clock ~= nil or Clock.available

	self._enabled        = opts.enabled ~= false
	self._scale          = tonumber(opts.scale) or 1.0
	self._respect_system = opts.respect_system ~= false

	self._running  = {}     -- active animation records
	self._timer    = nil
	self._ticking  = false
	self._hires    = false
	self._seq      = 0

	-- Frame-delivery measurement; see the FRAME TIMING block.
	self._last_tick   = nil
	self._frame_stats = nil

	-- Per-role motion supplied by the active theme, merged over the Carbon
	-- defaults in `core.lib.MotionTokens.ROLES`. Empty until a theme is applied.
	self._roles = opts.roles or {}
end

-- =======================================================================
-- CONFIGURATION
-- =======================================================================

--- Update motion settings live.
--
-- Only the keys present in `cfg` are changed. Disabling motion immediately
-- finishes every in-flight animation at its end value rather than freezing it
-- part-way, so the UI lands in the same state it would have reached anyway.
--
-- @tparam table cfg `{ enabled = bool, scale = number, respect_system = bool }`
-- @usage director:configure{ enabled = false }
-- @usage director:configure{ scale = 0.5 }   -- half duration, twice as fast
function MotionDirector:configure(cfg)
	cfg = cfg or {}
	if cfg.enabled ~= nil then self._enabled = cfg.enabled and true or false end
	if cfg.respect_system ~= nil then
		self._respect_system = cfg.respect_system and true or false
	end
	if cfg.scale ~= nil then
		local s = tonumber(cfg.scale)
		if s and s > 0 then self._scale = s end
	end

	if not self:enabled() then
		self:finishAll()
	end
end

--- Is motion currently active?
--
-- False when the user has switched it off, when they have asked the operating
-- system to reduce motion and the app is configured to honour that, or when no
-- precise clock is available to time frames with. Callers do
-- **not** need to check this before calling `animate()` -- it is enforced there.
-- It exists for code that can choose a cheaper representation entirely, such as
-- skipping a snapshot capture it would only throw away.
--
-- @treturn boolean
function MotionDirector:enabled()
	if not self._enabled or not self._clock_ok then return false end
	if self._respect_system and Clock.systemReducedMotion() then return false end
	return true
end

--- The current duration multiplier.
-- @treturn number
function MotionDirector:scale()
	return self._scale
end

--- Install the active theme's per-role motion overrides.
--
-- Called by `core.classes.ThemeManager` on every apply. Overrides are merged over
-- the Carbon defaults per field, so a theme that names one role changes only that
-- role and only the fields it lists.
--
-- In-flight animations are **not** disturbed: they were scheduled against the
-- outgoing theme and are measured in tens of milliseconds, so retiming them
-- mid-flight would produce a visible stutter to no benefit. The next animation
-- picks the new values up.
--
-- @tparam[opt] table roles Role name → motion spec, or `nil` to clear back to
--   the Carbon defaults.
-- @usage director:setRoles(theme:motion())
function MotionDirector:setRoles(roles)
	self._roles = (type(roles) == "table") and roles or {}
end

--- The resolved motion spec for a role, after theme overrides.
--
-- Returns a fresh table each call, so callers may read role-specific extras (a
-- travel fraction, a fade flag) and mutate the result freely.
--
-- @tparam string name Role name, e.g. `"tab_transition"`.
-- @treturn table Resolved spec.
-- @usage local m = director:role("tab_transition"); local px = width * m.travel
function MotionDirector:role(name)
	return Tokens.role(name, self._roles)
end

--- Number of animations currently running. Mainly for tests and diagnostics.
-- @treturn number
function MotionDirector:activeCount()
	local n = 0
	for _ in pairs(self._running) do n = n + 1 end
	return n
end

-- =======================================================================
-- SCHEDULING
-- =======================================================================

-- Resolve the `easing` field of a spec into a function. Accepts a ready-made
-- function, a `{x1,y1,x2,y2}` array, or a "curve/style" token pair.
function MotionDirector:_resolveEasing(spec)
	local e = spec.easing
	if type(e) == "function" then return e end
	if type(e) == "table" then return Easing.fromPoints(e) end
	return Easing.fromPoints(Tokens.easing(e or spec.curve, spec.style))
end

--- Schedule an animation.
--
-- `spec` fields:
--
--   * `role` -- a named motion role (`"tab_transition"`, `"settings_expand"`,
--     ...). Fills in `duration`, `curve`, `style` and `delay` from the Carbon
--     defaults as overridden by the active theme. Anything given explicitly in
--     the spec wins over the role.
--   * `duration` -- milliseconds. Omit and supply `distance` to let
--     `core.lib.MotionTokens` derive a Carbon-correct duration instead.
--   * `distance` -- pixels of travel, used when `duration` is absent
--   * `easing` -- a function, a `{x1,y1,x2,y2}` array, or a curve name
--     (`"standard"`, `"entrance"`, `"exit"`); defaults to `"standard"`
--   * `style` -- `"productive"` (default) or `"expressive"`
--   * `delay` -- milliseconds to wait before the first frame
--   * `from`, `to` -- numeric endpoints, default 0 and 1
--   * `on_frame(value, t)` -- called per frame with the eased value and raw
--     progress. **Required** to be cheap: it runs up to 60 times a second.
--   * `on_done(completed)` -- called once; `completed` is `false` if cancelled
--   * `tag`, `target`, `owner` -- cancellation scopes (see `cancel`)
--
-- Scheduling a new animation with the same `target` cancels the one already
-- running on it. Without that, a user clicking rapidly between tabs stacks
-- animations that fight over the same pixels.
--
-- @tparam table spec animation specification (see above)
-- @treturn table handle with `:cancel()`, `:finish()` and `:done()`
-- @usage
--   director:animate{
--     distance = width, curve = "standard", target = pane,
--     on_frame = function(v) pane:setOffset(v) end,
--     from = width, to = 0,
--   }
function MotionDirector:animate(spec)
	spec = spec or {}

	-- A `role` supplies whatever the caller left out. Merged into a copy rather
	-- than into `spec`, because callers legitimately reuse a spec table across
	-- calls and would otherwise find it silently rewritten by the first theme
	-- that overrode the role. Skipped entirely when no role is named, so the
	-- common path allocates nothing extra.
	if spec.role ~= nil then
		local merged = self:role(spec.role)
		for k, v in pairs(spec) do merged[k] = v end
		-- An explicit `distance` means "derive the duration from this travel",
		-- which the role's own fixed duration would otherwise override. The
		-- caller's intent wins.
		if spec.duration == nil and spec.distance ~= nil then
			merged.duration = nil
		end
		spec = merged
	end

	local from = tonumber(spec.from) or 0
	local to   = tonumber(spec.to)
	if to == nil then to = 1 end

	local on_frame = spec.on_frame
	local on_done  = spec.on_done

	-- Supersede any animation already running on this target.
	if spec.target ~= nil then
		self:cancel({ target = spec.target })
	end

	local handle = {
		_dir      = self,
		_done     = false,
		completed = false,
	}
	function handle:cancel() self._dir:_stop(self, false) end
	function handle:finish() self._dir:_stop(self, true) end
	function handle:done()   return self._done end

	-- Disabled: deliver the end state synchronously and return complete. This is
	-- the choke point that makes the off-switch total -- see the class notes.
	if not self:enabled() then
		handle._done = true
		handle.completed = true
		if on_frame then pcall(on_frame, to, 1) end
		if on_done then pcall(on_done, true) end
		return handle
	end

	local duration = tonumber(spec.duration)
	if not duration then
		duration = Tokens.duration(spec.distance or 0, spec.style)
	end
	duration = duration * self._scale
	if duration <= 0 then duration = 1 end

	self._seq = self._seq + 1
	local rec = {
		handle   = handle,
		seq      = self._seq,
		start    = self:_now() + ((tonumber(spec.delay) or 0) * self._scale) / 1000,
		duration = duration / 1000,
		from     = from,
		to       = to,
		ease     = self:_resolveEasing(spec),
		on_frame = on_frame,
		on_done  = on_done,
		tag      = spec.tag,
		target   = spec.target,
		owner    = spec.owner,
	}
	handle._rec = rec
	self._running[rec] = true

	self:_startTimer()
	return handle
end

--- Cancel matching animations without delivering their end value.
--
-- `filter` may carry any combination of `tag`, `target` and `owner`; an animation
-- must match **all** supplied fields. An empty filter cancels everything.
--
-- Cancelled animations leave their property wherever it had reached. Use
-- `finish` instead when the end state matters -- which is usually the case for
-- anything affecting layout.
--
-- @tparam[opt] table filter `{ tag = ..., target = ..., owner = ... }`
-- @treturn number Count of animations cancelled.
-- @usage director:cancel{ owner = ext }   -- extension unloading
function MotionDirector:cancel(filter)
	return self:_sweep(filter, false)
end

--- Immediately complete matching animations at their end value.
--
-- Each matching animation gets a final `on_frame(to, 1)` and `on_done(true)`, so
-- the UI lands exactly where the animation was heading. This is the safe way to
-- collapse motion when something more important needs the widget now.
--
-- @tparam[opt] table filter `{ tag = ..., target = ..., owner = ... }`
-- @treturn number Count of animations finished.
-- @usage director:finish{ tag = "tab-transition" }
function MotionDirector:finish(filter)
	return self:_sweep(filter, true)
end

--- Complete every running animation at its end value.
-- @treturn number Count of animations finished.
function MotionDirector:finishAll()
	return self:_sweep(nil, true)
end

function MotionDirector:_sweep(filter, complete)
	filter = filter or {}
	local matched = {}
	for rec in pairs(self._running) do
		local hit = true
		if filter.tag ~= nil and rec.tag ~= filter.tag then hit = false end
		if filter.target ~= nil and rec.target ~= filter.target then hit = false end
		if filter.owner ~= nil and rec.owner ~= filter.owner then hit = false end
		if hit then matched[#matched + 1] = rec end
	end
	-- Collected first: _stop mutates _running, and callbacks may schedule more.
	for _, rec in ipairs(matched) do
		self:_stop(rec.handle, complete)
	end
	return #matched
end

function MotionDirector:_stop(handle, complete)
	if not handle or handle._done then return end
	local rec = handle._rec
	handle._done = true
	handle.completed = complete and true or false
	if rec then
		self._running[rec] = nil
		handle._rec = nil
		if complete and rec.on_frame then pcall(rec.on_frame, rec.to, 1) end
		if rec.on_done then pcall(rec.on_done, complete and true or false) end
	end
	self:_stopTimerIfIdle()
end

-- =======================================================================
-- THE DRIVER
-- =======================================================================

function MotionDirector:_now()
	local ok, t = pcall(self._clock)
	if ok and type(t) == "number" then return t end
	return os.clock()
end

--- Advance every running animation to time `now`.
--
-- Normally called by the shared timer, but exposed so tests can drive the
-- director deterministically with an injected clock instead of waiting on real
-- frames.
--
-- @tparam[opt] number now Time in seconds; defaults to the director's clock.
-- @treturn number Count of animations still running afterwards.
-- @usage director:tick(t0 + 0.120)
function MotionDirector:tick(now)
	if self._ticking then return self:activeCount() end
	self._ticking = true

	now = tonumber(now) or self:_now()

	self:_recordFrame(now)

	-- The driver must NEVER exit with _ticking still raised.
	--
	-- If it did, the guard above would reject every future tick, `_stopTimerIfIdle`
	-- would refuse to stop the timer, and the queue would never drain: all motion
	-- in the app dies at once, the shared 16 ms timer spins for the rest of the
	-- process lifetime with nothing driving it, and consumers that release
	-- resources in `on_done` -- notably `core.ui.TabTransition`, which frees its
	-- GDI snapshots there -- leak instead.
	--
	-- Per-animation errors are already handled inside the pass, so this outer
	-- guard is for the cases that escape it. It costs one pcall per frame for
	-- every animation, which is not measurable against the rest of a frame.
	local ok, err = pcall(self._runPass, self, now)
	self._ticking = false
	if not ok then
		self._last_error = err
	end
	self:_flushFrameEnd()

	self:_stopTimerIfIdle()
	return self:activeCount()
end

--- Run `fn` once at the end of the current frame, after every animation's
-- `on_frame` -- or right away when no frame is being ticked. The same function
-- queued several times in one frame runs once. This is how effects that share
-- one compositor (`core.lib.Compositor:schedule`) present a single frame per tick.
-- @tparam function fn
function MotionDirector:atFrameEnd(fn)
	if not self._ticking then
		fn()
		return
	end
	local q = self._frame_end
	if not q then
		q = { seen = {} }
		self._frame_end = q
	end
	if not q.seen[fn] then
		q.seen[fn] = true
		q[#q + 1] = fn
	end
end

function MotionDirector:_flushFrameEnd()
	local q = self._frame_end
	self._frame_end = nil
	if not q then return end
	for _, fn in ipairs(q) do
		local ok, err = pcall(fn)
		if not ok then self._last_error = err end
	end
end

-- =======================================================================
-- FRAME TIMING
-- =======================================================================
--
-- Frames are delivered by an `iup.timer`, which on Windows is `SetTimer` /
-- `WM_TIMER`. `WM_TIMER` is the LOWEST-priority message there is: it is
-- synthesised only when the queue is otherwise empty, and Windows coalesces
-- pending ones. `core.lib.MotionClock` raises the system timer *resolution* to
-- 1 ms while animations run, but resolution is not priority -- if a frame's work
-- keeps the queue busy, the next frame simply arrives late.
--
-- That makes the interval between ticks the number worth having. A 16 ms nominal
-- frame arriving at 40 ms means two thirds of the animation was never drawn, and
-- no amount of retuning durations or easing curves will fix it -- the cost per
-- frame has to come down instead. Recording it turns "the transition feels
-- choppy" into something falsifiable.
--
-- Cost is two subtractions and a comparison per tick, only while animations are
-- actually running.

-- Rolling stats since the last idle period. Reset when the queue drains, so the
-- figures always describe one continuous burst of motion rather than an average
-- over the whole session (which would be dominated by whatever ran longest).
function MotionDirector:_recordFrame(now)
	local prev = self._last_tick
	self._last_tick = now
	if not prev then return end

	local dt = (now - prev) * 1000
	if dt <= 0 then return end

	local s = self._frame_stats
	if not s then
		s = { count = 0, total = 0, worst = 0 }
		self._frame_stats = s
	end
	s.count = s.count + 1
	s.total = s.total + dt
	if dt > s.worst then s.worst = dt end
end

--- Frame-delivery statistics for the most recent burst of motion.
--
-- Returns `nil` when nothing has been animated yet.
--
-- @treturn table|nil `{ frames, mean_ms, worst_ms, fps, target_ms }`
-- @usage
--   local s = director:frameStats()
--   if s then print(("%.0f fps, worst frame %.0f ms"):format(s.fps, s.worst_ms)) end
function MotionDirector:frameStats()
	local s = self._frame_stats
	if not s or s.count == 0 then return nil end
	local mean = s.total / s.count
	return {
		frames    = s.count,
		mean_ms   = mean,
		worst_ms  = s.worst,
		fps       = (mean > 0) and (1000 / mean) or 0,
		target_ms = FRAME_MS,
	}
end

-- Advance every running animation. Called only from `tick`, under its guard.
function MotionDirector:_runPass(now)
	-- Snapshot: callbacks are free to schedule or cancel animations, and mutating
	-- _running while iterating it is undefined behaviour in Lua.
	local batch = {}
	for rec in pairs(self._running) do batch[#batch + 1] = rec end
	table.sort(batch, function(a, b) return a.seq < b.seq end)

	for _, rec in ipairs(batch) do
		-- Skip records a previous callback in this same batch already stopped.
		if self._running[rec] then
			local elapsed = now - rec.start
			if elapsed >= 0 then
				local t = elapsed / rec.duration
				if t >= 1 then
					self:_stop(rec.handle, true)
				else
					-- The easing function is a public spec field, so it can be
					-- supplied by an extension and is no more trustworthy than
					-- on_frame. Evaluated under its own pcall, and its result
					-- type-checked, because a curve that throws or forgets to
					-- return would otherwise take the whole driver down with it.
					local ok_ease, eased = pcall(rec.ease, t)
					if not ok_ease or type(eased) ~= "number" then
						rec.error = ok_ease and "easing returned a non-number" or eased
						self:_stop(rec.handle, false)
					elseif rec.on_frame then
						local ok, err = pcall(rec.on_frame,
							rec.from + (rec.to - rec.from) * eased, t)
						-- A throwing frame callback would otherwise throw every
						-- frame forever. Drop the animation instead.
						if not ok then
							rec.error = err
							self:_stop(rec.handle, false)
						end
					end
				end
			end
		end
	end
end

function MotionDirector:_startTimer()
	local iup = self._iup
	if not iup then return end
	if next(self._running) == nil then return end

	-- A nil baseline means the queue was idle, so this is the first animation of
	-- a new burst. Clear the previous burst's figures now rather than on going
	-- idle, so they remain readable for as long as nothing new is running.
	if self._last_tick == nil then
		self._frame_stats = nil
	end

	if not self._hires then
		self._hires = Clock.acquireHighResolution() and true or false
	end

	if self._timer then
		pcall(iup.SetAttribute, self._timer, "RUN", "YES")
		return
	end

	local dir = self
	local timer = iup.timer({ TIME = tostring(FRAME_MS), RUN = "NO" })
	function timer:action_cb()
		dir:tick()
		return iup.DEFAULT
	end
	self._timer = timer
	pcall(iup.SetAttribute, timer, "RUN", "YES")
end

function MotionDirector:_stopTimerIfIdle()
	if self._ticking then return end
	if next(self._running) ~= nil then return end

	if self._timer and self._iup then
		pcall(self._iup.SetAttribute, self._timer, "RUN", "NO")
	end
	if self._hires then
		Clock.releaseHighResolution()
		self._hires = false
	end

	-- Drop the inter-frame baseline, but KEEP the accumulated stats.
	--
	-- Without this the idle gap between two bursts of motion -- which can be
	-- minutes -- would be recorded as one enormous frame interval and would
	-- dominate both the mean and the worst case, making the figures useless. The
	-- stats themselves survive so they can be read after the animation that
	-- produced them has finished, which is the only time anyone looks.
	self._last_tick = nil
end

--- Release the shared timer and any held system resources.
-- Cancels everything in flight. Called on shutdown; the director is unusable
-- afterwards only in the sense that it has no timer until the next `animate()`.
function MotionDirector:shutdown()
	self:cancel()
	if self._timer and self._iup then
		pcall(self._iup.SetAttribute, self._timer, "RUN", "NO")
	end
	if self._hires then
		Clock.releaseHighResolution()
		self._hires = false
	end
end

return MotionDirector

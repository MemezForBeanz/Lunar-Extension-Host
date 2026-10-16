--- Eased progress: a bar that moves rather than teleports.
--
-- A progress bar driven straight from its data jumps: a queue of eight items moves
-- in eight 12.5% steps, each one instantaneous. That reads as a series of unrelated
-- states rather than as one thing advancing, and it is worse the coarser the data
-- is -- the fewer the steps, the larger and more startling each jump.
--
-- Carbon's standard easing is the right curve here because the bar is present at
-- both ends of the motion: it is not appearing or leaving, it is moving. Productive,
-- because progress is something the user glances at while concentrating on
-- something else, and `moderate_01` because the movement is short.
--
-- ### Why this is not just `animate`
--
-- Two things make a progress bar a special case rather than a call to the director:
--
--   * **It is driven repeatedly.** Progress updates arrive whenever work completes,
--     which can be faster than the animation that shows the last one. Every update
--     therefore has to supersede the one in flight and start from wherever the bar
--     actually is, not from where the previous update was heading -- otherwise the
--     bar visibly snaps backwards before resuming.
--   * **It must never go backwards on its own.** A reset to zero is a real event
--     (a new queue) and should be instant; an *eased* return to zero looks like
--     work being undone.
--
-- @module core.ui.ProgressMotion

local ProgressMotion = {}

-- Where each gauge currently is, so a superseding update can start from the real
-- position instead of the last requested one. Keyed by the widget itself and held
-- weakly, so a destroyed gauge does not keep its entry alive forever.
local current = setmetatable({}, { __mode = "k" })

--- Read a gauge's present value, preferring what we last drove it to.
--
-- `VALUE` is read back from the widget only when this module has not driven it
-- before, because IUP round-trips the attribute through a string and the parse
-- costs more precision than it is worth mid-animation.
--
-- @tparam userdata iup the IUP binding
-- @tparam ihandle gauge the gauge
-- @treturn number 0..1
function ProgressMotion.valueOf(iup, gauge)
	local known = current[gauge]
	if known then return known end
	local ok, raw = pcall(iup.GetAttribute, gauge, "VALUE")
	return (ok and tonumber(raw)) or 0
end

--- Drive a gauge to `to`, easing the movement.
--
-- Falls back to setting the value directly when there is no director, so a caller
-- never needs to branch on whether motion is available. With motion switched off
-- the director delivers the final value synchronously, which lands the bar exactly
-- where this call asked for it before it returns.
--
-- `owner` files the animation under an extension so that unloading or reloading it
-- cancels anything still in flight. That is not optional politeness: `HostAPI`
-- cancels `{ owner = owner }` **before** it destroys an extension's widgets,
-- precisely so no frame writes to a freed handle. An animation with no owner
-- survives that sweep and keeps setting `VALUE` on a gauge whose tab has already
-- been destroyed -- which is exactly what happens if the queue is advancing when
-- the plugin is reloaded.
--
-- @tparam userdata iup the IUP binding
-- @tparam ihandle gauge the gauge to drive
-- @tparam number to target value, 0..1
-- @tparam[opt] table director `core.classes.MotionDirector`
-- @tparam[opt] any owner cancellation scope, normally the calling extension
-- @usage ProgressMotion.set(iup, bar, completed / total, ctx:motion(), self)
function ProgressMotion.set(iup, gauge, to, director, owner)
	if not gauge then return end
	to = tonumber(to) or 0
	if to < 0 then to = 0 elseif to > 1 then to = 1 end

	local from = ProgressMotion.valueOf(iup, gauge)

	-- Backwards is a reset, not progress. Land it immediately: easing a bar down
	-- to zero animates work being undone, which is not what happened.
	if not director or to <= from then
		current[gauge] = to
		pcall(iup.SetAttribute, gauge, "VALUE", tostring(to))
		if director then director:cancel({ target = gauge }) end
		return
	end

	director:animate({
		role     = "progress_advance",
		-- Supersedes the update still in flight. Combined with starting from the
		-- gauge's real position above, this is what stops a burst of completions
		-- turning into a bar that stutters back and forth.
		target   = gauge,
		owner    = owner,
		from     = from,
		to       = to,
		on_frame = function(v)
			current[gauge] = v
			pcall(iup.SetAttribute, gauge, "VALUE", tostring(v))
		end,
	})
end

return ProgressMotion

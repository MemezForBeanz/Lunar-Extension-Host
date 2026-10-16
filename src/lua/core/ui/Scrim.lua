--- Background dimming: the page receding behind a modal surface.
--
-- Carbon's rule for layered content is unambiguous: *"always dim the content below
-- when a new layer is introduced above."* Dimming is what tells the user that the
-- thing which just appeared is on a **higher layer** rather than beside them in the
-- same one -- without it a modal reads as a widget that happened to land on top,
-- and the page behind it still looks live and clickable when it is neither.
--
-- ### Why this is the slowest thing in the app
--
-- `slow_02` (700 ms) exists in Carbon's duration scale for exactly one stated
-- purpose -- background dimming -- and this module is its only consumer. That is
-- deliberate and it is not an oversight that it is four times longer than anything
-- else here.
--
-- A scrim is *context*, not content. It carries no information the user is waiting
-- for, so it is free to take its time, and taking its time is what makes it read as
-- the page receding rather than as a light being switched off. A scrim that snaps
-- to 50% grey is perceived as a flash -- the eye registers the discontinuity, not
-- the depth -- which is the precise opposite of what the dim is for.
--
-- Lifting it uses `scrim_out` instead, at `moderate_02`, and the asymmetry is the
-- point. Raising the dim is scene-setting and can be luxurious; lowering it is the
-- user getting control back, and holding a page dim for 700 ms after they have
-- dismissed something reads as the application being slow to respond. Nothing else
-- in the UI is allowed to be the reason a dismissal feels sluggish.
--
-- ### Depth counting
--
-- `raise`/`lower` are counted, not boolean. A modal that opens another modal is not
-- hypothetical here -- `core.ui.FolderDialog` pops a name prompt while it is itself
-- up -- and with a plain flag the inner dialog closing would lift the dim while the
-- outer one was still on screen, leaving a modal floating over an undimmed page.
--
-- The dim is also **not** re-animated for a nested raise. It is already at rest at
-- the right opacity, and re-running the entrance would pulse the whole page darker
-- and back for no reason the user could name.
--
-- ### Failing closed
--
-- Everything here is decoration layered on top of a modal that works without it.
-- `core.ui.MotionOverlay` latches itself off if the FFI, the window handle or the
-- layered style is unavailable, and this module simply reports false and does
-- nothing when that happens. The modal still opens; it opens over an undimmed page.
--
-- Not reachable from the busted suite -- it needs a live dialog and a real window
-- handle. `scripts/motion_check.lua` exercises it against the running host.
--
-- @classmod core.ui.Scrim

local class = require("middleclass")

local MotionOverlay = require("core.ui.MotionOverlay")

local Scrim = class("Scrim")

-- Carbon's overlay is black. The opacity is a role field rather than a constant
-- here so a theme can lighten or deepen it in the same place it retimes it.
local SCRIM_COLOR = "0 0 0"

--- Create a scrim bound to a host dialog.
--
-- `opts` fields:
--
--   * `iup` -- the IUP binding (required)
--   * `dialog` -- the main application dialog, used for parenting so the scrim
--     minimises, restores and z-orders with the application
--   * `cover` -- the widget whose area is dimmed. Defaults to `dialog`, but a
--     caller that wants the title bar left alone should pass the content
--     container instead -- Carbon dims the page, and the window chrome is not
--     part of the page.
--   * `director` -- `core.classes.MotionDirector`
--   * `log` -- optional `fn(msg)` for diagnostics
--
-- Construction is cheap and creates no window; see `prepare`.
--
-- @tparam table opts construction options (see above)
function Scrim:initialize(opts)
	opts = opts or {}
	self._iup      = opts.iup
	self._dialog   = opts.dialog
	self._cover    = opts.cover or opts.dialog
	self._director = opts.director

	self._overlay = MotionOverlay:new({
		iup    = opts.iup,
		dialog = opts.dialog,
		log    = opts.log,
	})

	self._depth = 0
	self._alpha = 0
end

--- Point the scrim at a different widget to cover.
-- @tparam ihandle widget the widget whose area should be dimmed
function Scrim:setCover(widget)
	self._cover = widget
end

--- Attach the motion director.
-- Separate from construction because the director and the scrim are built at
-- different points in the host's startup, and neither is useful without a dialog.
-- @tparam table director `core.classes.MotionDirector`
function Scrim:setDirector(director)
	self._director = director
end

--- The attached motion director, if any.
-- @treturn table|nil `core.classes.MotionDirector`
function Scrim:director()
	return self._director
end

--- Create the overlay window now, ahead of any modal.
--
-- Worth doing for the same reason `core.ui.MotionOverlay:prepare` is: creating and
-- mapping a native window from inside an event callback is a genuine re-entrancy
-- hazard, and the first modal of a session would otherwise do exactly that from a
-- menu or button handler.
--
-- @treturn boolean true when the window is ready
-- @usage scrim:prepare()   -- once, after the main dialog is shown
function Scrim:prepare()
	return self._overlay:prepare()
end

--- Is the scrim currently dimming anything?
-- @treturn boolean
function Scrim:visible()
	return self._depth > 0
end

--- How many surfaces are currently holding the scrim up. Mainly for diagnostics.
-- @treturn number
function Scrim:depth()
	return self._depth
end

-- The resting opacity, from the role so a theme can restyle it.
function Scrim:_restAlpha()
	local spec = self._director and self._director:role("scrim_in") or nil
	local alpha = spec and tonumber(spec.alpha)
	return alpha or 128
end

--- Dim the page.
--
-- Counted: the first call animates the dim in, later calls only note that another
-- surface now depends on it. Safe to call when the overlay is unavailable, in
-- which case it reports false and the caller carries on undimmed.
--
-- @treturn boolean true when the scrim is up (or already was)
-- @usage scrim:raise()
function Scrim:raise()
	if not self._overlay:available() then return false end

	self._depth = self._depth + 1
	if self._depth > 1 then
		-- Already at rest at the right opacity. Re-running the entrance would
		-- pulse the page for a change the user did not make.
		return true
	end

	-- Alpha is set to zero BEFORE the window is shown. `show()` raises the window
	-- to the top of the z-order and paints it immediately, so a window still
	-- carrying the opacity from its last use would flash a full-strength black
	-- rectangle over the page for one frame before the animation's first tick
	-- brought it back down.
	self._alpha = 0
	self._overlay:setAlpha(0)

	local shown = self._overlay:show(self._cover, function(o)
		o:clear(SCRIM_COLOR)
	end)
	if not shown then
		self._depth = self._depth - 1
		return false
	end

	self:_fade(self:_restAlpha(), "scrim_in")
	return true
end

--- Undim the page.
--
-- The counterpart to `raise`, and likewise counted: the dim only lifts once the
-- last surface holding it has gone. Extra calls are harmless.
--
-- `role` lets the caller time the lift from a role other than `scrim_out`. That is
-- how `core.ui.ModalMotion` carries Carbon's affirm/cancel distinction: the page
-- coming back is the last thing the user sees of a modal, so timing it from
-- `modal_exit` or `modal_cancel` is what makes confirming and cancelling feel
-- different without either of them animating the dialog itself.
--
-- @tparam[opt="scrim_out"] string role motion role to time the fade from
-- @usage scrim:lower()
-- @usage scrim:lower("modal_cancel")
function Scrim:lower(role)
	if self._depth == 0 then return end

	self._depth = self._depth - 1
	if self._depth > 0 then return end

	local overlay = self._overlay
	self:_fade(0, role or "scrim_out", function()
		-- Hidden only once the fade has actually finished. Hiding on the way out
		-- would cut the dim rather than lift it, which is the flash this module
		-- exists to avoid -- just at the other end of the modal's life.
		--
		-- Guarded on the depth still being zero: a modal that closes and
		-- immediately opens another (a confirmation chain) can raise the scrim
		-- again while this fade is in flight, and hiding then would drop the dim
		-- out from under a modal that is still on screen.
		if overlay and self._depth == 0 then
			overlay:hide()
		end
	end)
end

--- Drop the dim immediately, whatever the depth.
--
-- For teardown and for error paths that have lost track of how many surfaces were
-- holding it. Not for ordinary dismissal -- that is `lower`.
function Scrim:reset()
	self._depth = 0
	if self._director then
		self._director:cancel({ target = self })
	end
	self._alpha = 0
	pcall(function() self._overlay:setAlpha(0) end)
	self._overlay:hide()
end

-- Animate the layered window's alpha. The whole scrim is one flat colour, so
-- opacity is the only thing that changes and the layered-window alpha does it
-- without touching a pixel -- there is no per-frame repaint here at all, which is
-- what makes a 700 ms full-window dim free.
function Scrim:_fade(to, role, on_done)
	local from = self._alpha
	local overlay = self._overlay
	local scrim = self

	if not self._director then
		self._alpha = to
		overlay:setAlpha(to)
		if on_done then on_done() end
		return
	end

	self._director:animate({
		role = role,
		-- Supersedes a fade already running on this scrim, so a modal dismissed
		-- and reopened faster than the dim can settle does not end up with two
		-- animations fighting over one window's opacity.
		target   = self,
		from     = from,
		to       = to,
		on_frame = function(v)
			scrim._alpha = v
			overlay:setAlpha(v)
		end,
		on_done  = function()
			if on_done then on_done() end
		end,
	})
end

--- Destroy the overlay window and release every native resource it holds.
function Scrim:destroy()
	self:reset()
	self._overlay:destroy()
end

return Scrim

--- Modal entrance and exit: the scrim, the arrival, and the two ways out.
--
-- One helper that every modal in the host routes through, so "how a dialog appears"
-- is decided once rather than re-decided (and re-decided differently) at each of the
-- seven `iup.Popup` call sites.
--
-- ### Why a modal is expressive
--
-- Carbon names "opening a new page" and "clicking the primary action button" as
-- expressive moments, and a modal is both at once: it is occasional, it is
-- significant, and it takes the whole window. Almost everything else in this app is
-- productive -- tab switches, accordions, hover -- precisely so that the handful of
-- expressive moments still land as expressive. Carbon's own warning is that
-- expressive motion stops being expressive the moment it is everywhere.
--
-- ### Intentional inconsistency: confirm and cancel do not look alike
--
-- The same dialog leaving the screen two different ways should not look identical,
-- because the two outcomes are not the same. Carbon calls this *intentional
-- inconsistency*: "forward motion in the direction of entrance signals affirmation,
-- while reversing entrance motion signals cancellation."
--
-- So a dialog dismissed by doing the thing it asked leaves on `modal_exit` --
-- expressive, completing the arc it entered on. A dialog dismissed by backing out
-- (Cancel, Escape, the close box) leaves on `modal_cancel` -- productive and about
-- half the length, so it reads as withdrawn rather than sent. The user gets
-- confirmation of *which* thing happened from the movement itself, before they have
-- read anything.
--
-- ### Animating a native modal at all
--
-- `iup.Popup` blocks: it runs its own Win32 message loop until the dialog closes.
-- That looks fatal for an entrance animation, but it is not -- IUP timers dispatch
-- inside that nested loop just as they do in the main one, so the shared 16 ms
-- director timer keeps ticking and the animation runs normally. What does *not*
-- work is animating before `Popup`, because nothing is on screen yet. The entrance
-- is therefore kicked off from the dialog's own `SHOW_CB`, which fires once the
-- window exists and before the user can interact with it.
--
-- The exit is the harder half and is deliberately **not** attempted. Once a
-- dismissal is under way IUP is already tearing the dialog down, and animating a
-- window through its own destruction is how this kind of code earns access
-- violations. What is animated on the way out is the part that outlives the dialog:
-- the scrim. `modal_exit` and `modal_cancel` retime *that*, which is what carries
-- the affirm/cancel distinction to the user anyway -- the page coming back quickly
-- or unhurriedly.
--
-- ### Failing closed
--
-- Every piece of this is decoration around an `iup.Popup` that works without it. If
-- the scrim is unavailable, or the platform can't move windows, or `SHOW_CB` never fires, the
-- dialog still opens and still closes; it simply does so instantly. No call site
-- needs to know which of those happened.
--
-- @module core.ui.ModalMotion

local Tokens = require("core.lib.MotionTokens")

local M = {}

local platform = require("core.platform")

-- The host's shared scrim, installed once by main.lua. Module-level rather than
-- threaded through every call site because there is exactly one page to dim and
-- every modal in the process wants the same one -- passing it down through seven
-- unrelated dialog constructors would be ceremony around a singleton.
local scrim = nil

--- Install the host's scrim.
-- @tparam table s `core.ui.Scrim`, or `nil` to disable dimming entirely.
-- @usage ModalMotion.setScrim(scrim)
function M.setScrim(s)
	scrim = s
end

--- The installed scrim, if any.
-- @treturn table|nil
function M.scrim()
	return scrim
end

-- The director reaches us through the scrim rather than being installed twice.
local function director()
	return scrim and scrim:director() or nil
end

-- Screen position of a mapped dialog, as two numbers, or nil.
local function positionOf(iup, dlg)
	local ok, pos = pcall(iup.GetAttribute, dlg, "SCREENPOSITION")
	if not ok or type(pos) ~= "string" then return nil end
	local x, y = pos:match("^(%-?%d+),(%-?%d+)")
	if not x then return nil end
	return tonumber(x), tonumber(y)
end

--- Show a modal dialog with Carbon entrance motion and a dimmed page behind it.
--
-- A drop-in replacement for `iup.Popup(dlg, x, y)`. Blocks exactly as `iup.Popup`
-- does and returns only once the dialog has closed.
--
-- The dialog rises `rise` pixels into its resting position (from the `modal_enter`
-- role, 16 px by default). The travel is small on purpose: it is there to give the
-- arrival a direction, not to be a journey of its own -- a modal that flies in from
-- the edge of the screen is drawing attention to the animation rather than to the
-- decision it is asking for.
--
-- Any `SHOW_CB` already on the dialog is preserved and still called.
--
-- @tparam userdata iup the IUP binding
-- @tparam ihandle dlg the dialog to show
-- @tparam[opt] table opts `{ x = ..., y = ..., dim = false }`; `x`/`y` default to
--   `iup.CENTERPARENT`, and `dim = false` suppresses the scrim for a dialog that
--   is not really a modal over the page.
-- @usage ModalMotion.popup(iup, dlg, { x = iup.CENTERPARENT, y = iup.CENTERPARENT })
function M.popup(iup, dlg, opts)
	opts = opts or {}
	local x = opts.x or iup.CENTERPARENT
	local y = opts.y or iup.CENTERPARENT

	local dimmed = false
	if opts.dim ~= false and scrim then
		dimmed = scrim:raise()
	end

	local dir = director()
	local spec = dir and dir:role("modal_enter") or Tokens.role("modal_enter")
	local rise = tonumber(spec.rise) or 16

	-- Chained rather than replaced: FolderDialog and the tour already use SHOW_CB
	-- for their own setup, and silently dropping it would break them in a way that
	-- looks like a motion bug.
	local prev_show = nil
	pcall(function() prev_show = dlg.show_cb end)

	local animated = false
	function dlg:show_cb(state)
		local ret
		if prev_show then
			local ok, r = pcall(prev_show, self, state)
			if ok then ret = r end
		end

		-- IUP_SHOW is 0 and also fires on restore; only the first one is an
		-- entrance. Without the latch, minimising and restoring a modal would
		-- replay the arrival.
		if not animated and dir and (state == nil or state == 0) then
			animated = true
			local rx, ry = positionOf(iup, dlg)
			-- Offset applied before the animation is scheduled, not left to its
			-- first tick. `animate` does not call `on_frame` until the timer
			-- fires, so without this the dialog paints one frame at its resting
			-- position and then jumps down to start rising -- a visible stutter
			-- on precisely the frame the user first sees it. Where the platform
			-- can't move windows (native Wayland) the first move says so and the
			-- dialog simply appears.
			if rx and platform.move_window(iup, dlg, rx, ry + rise) then
				dir:animate({
					role     = "modal_enter",
					target   = dlg,
					from     = rise,
					to       = 0,
					on_frame = function(v)
						platform.move_window(iup, dlg, rx, ry + v)
					end,
				})
			end
		end

		return ret or iup.DEFAULT
	end

	local ok = pcall(iup.Popup, dlg, x, y)

	-- Cancel the entrance the instant `Popup` returns, and BEFORE this function
	-- hands control back.
	--
	-- Every call site destroys the dialog on the line after `popup` returns. A
	-- user who dismisses inside the entrance window -- Escape or Enter on a
	-- familiar prompt, and twice as likely at `motion_scale = 2.0` where the
	-- entrance runs 480 ms -- leaves frames still queued against a handle that is
	-- about to be freed. The next tick would then call `move()` on it, which goes
	-- through raw FFI to `IupGetAttribute(p, "HWND")`; `iupraw_wrap.c` hands back
	-- the pointer with no liveness check, and the `pcall` inside `move` cannot
	-- catch a fault in C.
	--
	-- Cancel rather than finish: the end state is the dialog sitting at its
	-- resting position, and it is being destroyed, so there is nothing to land.
	--
	-- This is the same invariant `core.classes.HostAPI:removeOwned` documents --
	-- cancel before the handles go, because surviving one more frame means
	-- writing attributes to something that was freed a few lines below.
	if dir then
		dir:cancel({ target = dlg })
	end

	if dimmed then
		-- The scrim's fade-out role carries the affirm/cancel distinction. It is
		-- read from the dialog at dismissal rather than passed in, so a dialog
		-- can set it from inside its own button handlers -- which is the only
		-- place that actually knows which way the user went.
		local how = nil
		pcall(function() how = iup.GetAttribute(dlg, "LUNAR_MODAL_RESULT") end)
		M.dismiss(how)
	end

	return ok
end

--- Note how a modal was dismissed, from inside its own button handler.
--
-- Call with `"confirm"` from the affirmative action and `"cancel"` from Cancel,
-- Escape or the close box. Anything else is treated as a cancel, because backing
-- out is the safe reading of an ambiguous dismissal.
--
-- Recorded on the dialog rather than returned, because the only code that knows
-- which way the user went is the button handler, and the only code that needs to
-- know is `popup` -- which by then is several stack frames away, blocked inside
-- `iup.Popup`.
--
-- @tparam userdata iup the IUP binding
-- @tparam ihandle dlg the dialog being dismissed
-- @tparam string how `"confirm"` or `"cancel"`
-- @usage
--   function ok_btn:flat_action()
--     ModalMotion.result(iup, dlg, "confirm")
--     ...
--   end
function M.result(iup, dlg, how)
	pcall(iup.SetAttribute, dlg, "LUNAR_MODAL_RESULT",
		how == "confirm" and "confirm" or "cancel")
end

--- Lower the scrim, timed by how the modal was dismissed.
--
-- Normally called for you by `popup`. Exposed for surfaces that raise the scrim
-- themselves around something that is not an `iup.Popup`.
--
-- @tparam[opt="cancel"] string how `"confirm"` or `"cancel"`
function M.dismiss(how)
	if not scrim then return end
	scrim:lower((how == "confirm") and "modal_exit" or "modal_cancel")
end

return M

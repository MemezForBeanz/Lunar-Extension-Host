--- Carbon toast notification: the one animated surface the host was missing.
--
-- IBM Carbon names "system alerts and the appearance of notification boxes" as
-- great cases for expressive motion. A toast is deliberately visible — it slides
-- into the top-right corner over the live page and later dismisses itself. That
-- arc (enter → hold → exit) is what the `toast_enter` and `toast_exit` roles in
-- `core.lib.MotionTokens` encode.
--
-- ### The two-layer design
--
-- The pure arithmetic lives in `Toast.layout` — a set of stateless functions over
-- plain tables. They compute where toast N sits and where survivors slide to after
-- a dismissal. No IUP, no director, no global state: the spec covers them directly.
--
-- The GUI layer (`Toast.show`) owns the window, the animations and the lifetime.
-- It is not testable under busted because it needs a live IUP dialog, but it is
-- thin: every interesting decision is delegated down to `layout`.
--
-- ### Stacking and reflow
--
-- Toasts accumulate in a vertical column just inside the top-right corner of the
-- main dialog. When one dismisses, the survivors above it reflow downward. Carbon
-- says elements never travel diagonally, so every reflow leg is split with
-- `MotionTokens.cornerPath` even when the horizontal offset is zero (it still
-- keeps the API contract and makes the reflow composable if a future theme adds
-- horizontal shift).
--
-- ### Failing closed
--
-- Window creation may fail in locked-down environments. `Toast.show` wraps every
-- IUP call in `pcall` and latches `_failed` on the host instance rather than
-- raising into the caller, mirroring `core.ui.MotionOverlay`.
--
-- ### Focus and taskbar
--
-- IUP `TOOLBOX="YES"` removes the toast from the taskbar and alt-tab. It is
-- enough on its own: we do not need the WS_EX_NOACTIVATE FFI dance that
-- `MotionOverlay` uses for its click-through overlay, because a toast accepts
-- exactly one kind of interaction (the close button) and TOOLBOX already prevents
-- it from stealing keyboard focus on show.
--
-- @module core.ui.Toast

local Tokens = require("core.lib.MotionTokens")

-- ==========================================================================
-- CONSTANTS — all Carbon or derived from Carbon
-- ==========================================================================

-- Carbon 16-column grid margin between the toast column and the window edge.
local MARGIN        = 16
-- Gap between stacked toasts (Carbon spacing-03).
local GAP           = 8
-- Toast width in px — Carbon's default notification width.
local TOAST_W       = 352
-- Status bar on the left edge, per Carbon notification spec.
local STATUS_BAR_W  = 3
-- Top offset: just below the Carbon 48 px shell bar.
local TOP_OFFSET    = 48 + MARGIN

-- Carbon type-scale token names used in FONT attribute strings.
-- heading-compact-01: IBMPlexSans 14/18 SemiBold
-- body-compact-01:    IBMPlexSans 14/18 Regular
local FONT_TITLE = "IBM Plex Sans, SemiBold 11"
local FONT_BODY  = "IBM Plex Sans, 11"

-- THEMEROLE constants — resolved to colours by ThemeManager. The left status bar
-- gets a role per kind so each maps to the theme's semantic palette token.
local ROLE_BG = {
	error   = "toast_bg_error",
	success = "toast_bg_success",
	warning = "toast_bg_warning",
	info    = "toast_bg_info",
}
local ROLE_BAR = {
	error   = "toast_bar_error",
	success = "toast_bar_success",
	warning = "toast_bar_warning",
	info    = "toast_bar_info",
}

-- ==========================================================================
-- PURE LAYOUT ARITHMETIC
-- ==========================================================================

--- Pure layout arithmetic for the toast stack (no IUP, no global state).
--
-- These are free functions so `spec/toast_spec.lua` can import and drive them
-- directly — the same separation `MotionTokens` uses for its own arithmetic.
--
-- @section layout
local layout = {}

--- Y coordinate (from the top of the dialog) of the Nth toast in the stack.
--
-- Toasts accumulate top-to-bottom. Toast 1 is closest to the top edge; its
-- successor sits one `height + GAP` further down.
--
-- This form assumes a uniform height for every toast. Use `layout.stackY` when
-- toasts in the stack have different heights.
--
-- @tparam number index 1-based position in the live stack.
-- @tparam number height Height of each toast in pixels.
-- @treturn number Y in pixels from the dialog's top edge.
function layout.toastY(index, height)
	return TOP_OFFSET + (index - 1) * (height + GAP)
end

--- Y coordinate of slot `index` in a mixed-height stack.
--
-- `heights` is a sparse array keyed by slot number; missing slots fall back to
-- the Carbon default (48 px, the no-body height). When all heights are the same
-- this produces the same result as `toastY`, so it is the general form the GUI
-- layer uses instead of `toastY`.
--
-- @tparam number index 1-based slot number.
-- @tparam table  heights Sparse per-slot heights, e.g. `{ [1]=64, [3]=48 }`.
-- @tparam number fallback Height for any slot missing from `heights`.
-- @treturn number Y in pixels from the dialog's top edge.
function layout.stackY(index, heights, fallback)
	fallback = fallback or 48
	local y = TOP_OFFSET
	for i = 1, index - 1 do
		y = y + (heights[i] or fallback) + GAP
	end
	return y
end

--- X coordinate (from the left of the dialog) for a toast, given dialog width.
--
-- Toasts are right-aligned with a Carbon margin. The X is dialog-relative —
-- callers must add the main dialog's screen origin before handing this to
-- `ShowXY` or `SCREENPOSITION`.
--
-- @tparam number dialog_w Width of the main dialog in pixels.
-- @treturn number X in pixels from the dialog's left edge.
function layout.toastX(dialog_w)
	return dialog_w - TOAST_W - MARGIN
end

--- Where each surviving toast should move after one toast is removed.
--
-- When the toast at `removed_index` dismisses, every toast below it moves up.
-- The gap closed is exactly `removed_h + GAP` where `removed_h` is the dismissed
-- toast's height — independent of the survivor's own height or position.
--
-- Survivor descriptors: `{ index = N [, height = H [, removed_h = R]] }`.
--
--   * `index`     Original 1-based slot (before removal).
--   * `height`    This toast's own height in px; falls back to `height` arg.
--   * `removed_h` Height of the dismissed toast in px; falls back to `height` arg.
--
-- The fall-back to the scalar `height` argument keeps every existing uniform-
-- height call site and test working without change.
--
-- The return value is an array parallel to `survivors`, each entry either
-- `nil` (toast does not move) or `{x, y, dx, dy}` where dx and dy are the
-- signed deltas — what `cornerPath` expects.
--
-- @tparam table survivors Array of `{ index = N [, height = H, removed_h = R] }`.
-- @tparam number removed_index Original 1-based slot of the dismissed toast.
-- @tparam number dialog_w Width of the main dialog in pixels.
-- @tparam number height Fallback uniform height in pixels.
-- @treturn table Array of `{x, y, dx, dy}|nil`, parallel to `survivors`.
function layout.reflowTargets(survivors, removed_index, dialog_w, height)
	-- Build a slot-keyed heights table for stackY so mixed-height stacks land
	-- gap-free. Above-gap survivors keep their new slot == old slot; below-gap
	-- survivors move to new slot = old slot - 1.
	local new_heights = {}
	for _, s in ipairs(survivors) do
		local new_slot = (s.index > removed_index) and (s.index - 1) or s.index
		new_heights[new_slot] = s.height or height
	end

	local results = {}
	for i, s in ipairs(survivors) do
		if s.index > removed_index then
			-- This toast was below the one that left. The amount it moves up is
			-- exactly the removed toast's height plus the inter-toast spacing —
			-- independent of the survivor's own height. Using the removed toast's
			-- actual height (not a uniform fallback) is what prevents overlap when
			-- the removed toast was taller than its neighbours.
			local removed_h = s.removed_h or height
			local new_slot  = s.index - 1
			local new_y     = layout.stackY(new_slot, new_heights, height)
			local old_y     = new_y + removed_h + GAP
			local x         = layout.toastX(dialog_w)
			results[i] = { x = x, y = new_y, dx = 0, dy = new_y - old_y }
		else
			results[i] = nil   -- no movement needed
		end
	end
	return results
end

-- Export the layout namespace so specs can reach it without instantiating anything.
local Toast = {}
Toast.layout = layout

-- ==========================================================================
-- TOAST HOST — manages the live stack, wired in by HostAPI
-- ==========================================================================

--- @type ToastHost
local ToastHost = {}
ToastHost.__index = ToastHost

--- Create a ToastHost.
--
-- `opts` fields:
--
--   * `iup`      — the IUP binding (required for real windows)
--   * `director` — the `core.classes.MotionDirector` (optional; nil = instant)
--   * `dialog`   — the main application dialog (for PARENTDIALOG and sizing)
--   * `notify_tree_change` — `fn(widget)` so ThemeManager colours new windows
--
-- @tparam table opts
-- @treturn ToastHost
function ToastHost.new(opts)
	opts = opts or {}
	local h = setmetatable({}, ToastHost)
	h._iup      = opts.iup
	h._director = opts.director
	h._dialog   = opts.dialog
	h._ntc      = opts.notify_tree_change   -- notify_tree_change
	h._stack    = {}   -- ordered array of live toast records
	h._failed   = false
	return h
end

-- Latch the host disabled after an unrecoverable failure. Silent: the user
-- still sees whatever had been posted so far.
function ToastHost:_fail(why)
	if not self._failed then
		self._failed = true
		-- A log handle is not guaranteed; swallow the message gracefully.
		pcall(function()
			if self._iup then
				-- Best-effort: print to stdout where the host can catch it.
				print("[Toast] disabled: " .. tostring(why))
			end
		end)
	end
end

--- Update the director reference (called by HostAPI:setMotionDirector when the
-- director is set after the host is constructed).
-- @tparam MotionDirector|nil director
function ToastHost:setDirector(director)
	self._director = director
end

--- Current dialog width, or a safe fallback.
function ToastHost:_dialogW()
	local iup = self._iup
	if not (iup and self._dialog) then return 1200 end
	local ok, size = pcall(iup.GetAttribute, self._dialog, "RASTERSIZE")
	if ok and type(size) == "string" then
		local w = size:match("^(%d+)")
		if w then return tonumber(w) end
	end
	return 1200
end

--- Screen-coordinate origin of the main dialog, or (0, 0) when unavailable.
--
-- `layout.toastX/Y` return dialog-relative offsets. `ShowXY` and
-- `SCREENPOSITION` are screen coordinates. Adding the dialog's origin converts
-- between the two. Reading it here rather than inside the pure layout functions
-- keeps the arithmetic testable without IUP.
--
-- @treturn number sx, sy — screen X and Y of the dialog's top-left corner.
function ToastHost:_dialogOrigin()
	local iup = self._iup
	if not (iup and self._dialog) then return 0, 0 end
	local ok, pos = pcall(iup.GetAttribute, self._dialog, "SCREENPOSITION")
	if ok and type(pos) == "string" then
		local sx, sy = pos:match("^(%-?%d+),(%-?%d+)")
		if sx then return tonumber(sx), tonumber(sy) end
	end
	return 0, 0
end

--- Height of a toast given whether it has a body line.
function ToastHost:_toastH(has_body)
	-- heading row + optional body + vertical padding. Carbon notification
	-- spec: 64 px with one line of body, 48 px without.
	return has_body and 64 or 48
end

-- Schedule a Carbon animation against the director, falling through to an
-- instant delivery when the director is absent or motion is off.
function ToastHost:_animate(spec)
	local d = self._director
	if d then
		return d:animate(spec)
	end
	-- No director: deliver the end state synchronously, matching the director's
	-- own motion-off path so callers never need to branch.
	local to = tonumber(spec.to)
	if to == nil then to = 1 end
	if spec.on_frame then pcall(spec.on_frame, to, 1) end
	if spec.on_done  then pcall(spec.on_done, true) end
end

-- Position an IUP dialog at (x, y) in screen coordinates, using ShowXY so
-- it is non-blocking (never iup.Popup).
function ToastHost:_place(dlg, x, y)
	local iup = self._iup
	if not (iup and dlg) then return end
	pcall(iup.ShowXY, dlg, x, y)
end

-- Move a toast dialog to a new (x, y) position using IUP's POSITION attribute.
-- ShowXY only works once; after that we must reposition by attribute.
function ToastHost:_moveTo(dlg, x, y)
	local iup = self._iup
	if not (iup and dlg) then return end
	pcall(iup.SetAttribute, dlg, "SCREENPOSITION", tostring(math.floor(x)) .. "," .. tostring(math.floor(y)))
end

--- Post a toast notification.
--
-- `spec` fields:
--
--   * `title`   — required; heading-compact-01 text
--   * `body`    — optional; body-compact-01 text
--   * `kind`    — `"error"` | `"success"` | `"warning"` | `"info"` (default `"info"`)
--   * `timeout` — ms before auto-dismiss; overrides the role's `hold` extra
--   * `owner`   — owning extension (for `removeOwned` cleanup)
--
-- Silent no-op on any construction failure.
--
-- @tparam table spec notification specification
function ToastHost:show(spec)
	if self._failed then return end
	spec = spec or {}

	local iup = self._iup
	if not iup then return end

	local kind = spec.kind
	if kind ~= "error" and kind ~= "success" and kind ~= "warning" then
		kind = "info"
	end

	local title    = tostring(spec.title or "")
	local body_txt = spec.body and tostring(spec.body) or nil
	local has_body = body_txt and body_txt ~= ""

	-- The entrance role, resolved through the director so a theme's overrides are
	-- picked up. The exit role is resolved at dismissal instead of here: a toast
	-- can outlive a theme switch, and reading it now would dismiss it on the
	-- outgoing theme's timing.
	local enter_role
	if self._director then
		enter_role = self._director:role("toast_enter")
	else
		enter_role = Tokens.role("toast_enter")
	end

	local travel  = tonumber(enter_role.travel) or 32
	local hold_ms = tonumber(spec.timeout) or tonumber(enter_role.hold) or 5000
	local toast_h = self:_toastH(has_body)

	-- Determine stack position BEFORE building the window so the initial
	-- placement is correct. Index is 1-based from the top.
	local slot     = #self._stack + 1
	local dialog_w = self:_dialogW()
	-- layout.toastX/Y are dialog-relative; ShowXY and SCREENPOSITION are screen
	-- coordinates. Add the main dialog's screen origin to convert.
	local orig_sx, orig_sy = self:_dialogOrigin()
	local base_x  = layout.toastX(dialog_w) + orig_sx
	local base_y  = layout.toastY(slot, toast_h) + orig_sy

	-- Build the IUP widget tree ------------------------------------------
	local dlg, close_btn
	local ok_build = pcall(function()
		local title_label = iup.flatlabel({
			TITLE    = title,
			FONT     = FONT_TITLE,
			EXPAND   = "HORIZONTAL",
			THEMEROLE = "toast_title",
		})

		close_btn = iup.flatbutton({
			TITLE    = "✕",
			FONT     = "IBM Plex Sans, 9",
			PADDING  = "2x2",
			THEMEROLE = "toast_close",
		})

		-- heading row: title + close affordance
		local head_row = iup.hbox({
			title_label,
			iup.fill{},
			close_btn,
			GAP       = "4",
			ALIGNMENT = "ACENTER",
			EXPAND    = "HORIZONTAL",
		})

		-- optional body
		local content
		if has_body then
			local body_label = iup.flatlabel({
				TITLE    = body_txt,
				FONT     = FONT_BODY,
				EXPAND   = "HORIZONTAL",
				THEMEROLE = "toast_body",
			})
			content = iup.vbox({
				head_row,
				body_label,
				GAP    = "4",
				EXPAND = "HORIZONTAL",
			})
		else
			content = head_row
		end

		-- 3 px status bar on the left edge, coloured by kind
		local status_bar = iup.flatlabel({
			TITLE    = "",
			RASTERSIZE = tostring(STATUS_BAR_W) .. "x" .. tostring(toast_h),
			THEMEROLE = ROLE_BAR[kind] or "toast_bar_info",
		})

		-- main row: status bar + text area
		local body_row = iup.hbox({
			status_bar,
			content,
			GAP    = "8",
			MARGIN = "0x0",
			EXPAND = "YES",
		})

		local panel = iup.vbox({
			body_row,
			MARGIN   = "12x10",
			EXPAND   = "YES",
			THEMEROLE = ROLE_BG[kind] or "toast_bg_info",
		})

		dlg = iup.dialog({
			panel,
			RASTERSIZE   = tostring(TOAST_W) .. "x" .. tostring(toast_h),
			BORDER       = "NO",
			RESIZE       = "NO",
			MAXBOX       = "NO",
			MINBOX       = "NO",
			MENUBOX      = "NO",
			-- TOOLBOX keeps the toast out of the taskbar and alt-tab without
			-- needing the WS_EX_TOOLWINDOW FFI call; it also prevents keyboard
			-- focus from moving here on show. Sufficient because a toast only
			-- accepts the close button — it does not need to be click-through.
			TOOLBOX      = "YES",
			-- Parented so it minimises and z-orders with the app.
			PARENTDIALOG = self._dialog,
		})
	end)

	if not ok_build or not dlg then
		self:_fail("widget construction failed")
		return
	end

	-- Apply theme to the new window before showing it.
	if self._ntc then pcall(self._ntc, dlg) end

	-- Record the toast immediately (before showing) so the slot index is stable
	-- even if motion callbacks fire on the same frame.
	local rec = {
		dlg    = dlg,
		owner  = spec.owner,
		slot   = slot,
		height = toast_h,
		alive  = true,
	}
	self._stack[slot] = rec

	-- Dismiss logic — shared by close button and auto-dismiss timer.
	local self_ref  = self
	local dismissed = false
	local function dismiss()
		if dismissed then return end
		dismissed = true
		self_ref:_exitToast(rec)
	end

	-- Wire the close button.
	function close_btn:flat_action()
		dismiss()
		return iup.DEFAULT
	end

	-- Place the dialog just off the right edge (travel px out) so the enter
	-- animation slides it into position. ShowXY is the only non-blocking show
	-- call in IUP — Popup is modal and must never be used for toasts.
	local start_x = base_x + travel

	-- Show off-screen first so the window exists but is not yet visible at its
	-- resting position. The enter animation slides it left into base_x.
	self:_place(dlg, start_x, base_y)

	-- Enter animation: slide left (x: start_x → base_x) while fading in (alpha: 0→1).
	-- The horizontal movement is the expressive element; the fade rides it.
	local host = self
	self:_animate({
		role     = "toast_enter",
		owner    = spec.owner,
		target   = dlg,
		from     = start_x,
		to       = base_x,
		on_frame = function(v)
			host:_moveTo(dlg, v, base_y)
		end,
		on_done  = function(completed)
			if not completed then return end
			-- The hold is a timeout, not an animation: it must not collapse when
			-- motion is off. The director's own off-switch fires on_done
			-- synchronously, ignoring delay — so a hold_ms delay here would
			-- vanish entirely, creating and destroying the toast inside show()
			-- before it is ever visible. Users with "Reduce Motion" enabled (often
			-- because motion causes physical discomfort) would lose every
			-- notification silently. Use an iup.timer instead, which is immune to
			-- the motion switch.
			local iup_ref = host._iup
			if iup_ref and iup_ref.timer then
				local hold_timer = iup_ref.timer({ TIME = tostring(math.floor(hold_ms)), RUN = "NO" })
				-- Kept on the record so an early dismissal (the close button, or
				-- `dismissOwned` on extension unload) can stop and free it.
				-- Windows timers are a limited per-process resource -- the reason
				-- `core.classes.MotionDirector` runs every animation off ONE
				-- shared timer -- so one leaked per notification is a real cost
				-- over a long session, not a tidiness point.
				rec.hold_timer = hold_timer
				function hold_timer:action_cb()
					iup_ref.SetAttribute(hold_timer, "RUN", "NO")
					dismiss()
					return iup_ref.DEFAULT or 0
				end
				iup_ref.SetAttribute(hold_timer, "RUN", "YES")
			else
				-- No IUP timer support (test environment without timer or no-IUP
				-- path): fall through to immediate dismiss so the no-IUP path
				-- still works correctly.
				dismiss()
			end
		end,
	})
end

--- Run the exit animation for `rec` then destroy it and reflow survivors.
-- @tparam table rec the toast record
function ToastHost:_exitToast(rec)
	if not rec.alive then return end
	rec.alive = false

	local iup = self._iup
	local dlg = rec.dlg
	local host = self

	-- Stop the hold immediately. This toast is already leaving, and letting the
	-- timer fire during the exit animation would call `dismiss()` again -- a
	-- no-op today because of the `dismissed` latch, but only by luck. The handle
	-- itself is freed in the exit animation's on_done rather than here, because
	-- this function is reached FROM that timer's own callback on the ordinary
	-- auto-dismiss path, and destroying a timer from inside its own action_cb is
	-- the kind of re-entrancy that is fine until it is not.
	if rec.hold_timer and iup then
		pcall(iup.SetAttribute, rec.hold_timer, "RUN", "NO")
	end

	-- Snapshot position before removing from stack, because reflow reads indices.
	local removed_slot = rec.slot

	-- Remove from stack immediately so reflow and future toasts see the right count.
	table.remove(self._stack, removed_slot)
	-- Update the slot numbers of survivors.
	for i, s in ipairs(self._stack) do
		s.slot = i
	end

	-- Reflow survivors above the gap.
	local dialog_w  = host:_dialogW()
	local orig_sx, orig_sy = host:_dialogOrigin()
	-- Build a descriptor array for reflowTargets (original indices before removal).
	-- Each descriptor carries the survivor's own height and the removed toast's
	-- height so reflowTargets can compute gap-free y positions for mixed-height
	-- stacks instead of assuming every toast is the same height.
	local descs = {}
	for i, s in ipairs(self._stack) do
		-- `i` is the new slot; the original slot was i if it was above the removed
		-- one, or i+1 if it was below. We only care about "was below" (> removed_slot).
		descs[i] = {
			index    = (i < removed_slot) and i or i + 1,
			height   = s.height,
			removed_h = rec.height,
		}
	end
	local targets = layout.reflowTargets(descs, removed_slot, dialog_w, rec.height)

	for i, s in ipairs(self._stack) do
		local t = targets[i]
		if t then
			-- Carbon choreography: never diagonal. cornerPath splits the movement
			-- into a leading leg and a lagging leg so the path has a rounded corner
			-- rather than a straight diagonal. For a pure vertical reflow dx==0,
			-- skip the x leg entirely — running a zero-distance x animation that
			-- outlives the y leg would pin the toast back at its old y on the x
			-- leg's final frame (it writes both axes). The cornerPath API contract
			-- is still honoured for the case where a theme introduces horizontal
			-- travel: non-zero dx triggers both legs with the correct overlap.
			local path = Tokens.cornerPath(math.abs(t.dx), math.abs(t.dy), "productive")
			local toast_dlg = s.dlg
			local cur_x = t.x - t.dx   -- x before this animation
			local cur_y = t.y - t.dy   -- y before this animation (the old position)
			-- Screen-offset the target positions so they agree with ShowXY coords.
			local scr_x  = t.x + orig_sx
			local scr_y  = t.y + orig_sy
			local scr_cx = cur_x + orig_sx
			local scr_cy = cur_y + orig_sy

			if t.dx ~= 0 then
				-- Horizontal leg — writes only x; y stays at cur while x travels.
				host:_animate({
					duration = path.x.duration,
					delay    = path.x.delay,
					curve    = "standard",
					style    = "productive",
					owner    = s.owner,
					target   = toast_dlg,
					from     = scr_cx,
					to       = scr_x,
					on_frame = function(vx)
						host:_moveTo(toast_dlg, vx, scr_cy)
					end,
				})
			end
			-- Vertical leg — writes only y; x stays at its final value.
			-- `target` is set so a subsequent dismissal of this toast cancels this
			-- leg before it can write to a destroyed window, and so that two rapid
			-- dismissals do not leave competing legs against the same window.
			host:_animate({
				duration = path.y.duration,
				delay    = path.y.delay,
				curve    = "standard",
				style    = "productive",
				owner    = s.owner,
				target   = toast_dlg,
				from     = scr_cy,
				to       = scr_y,
				on_frame = function(vy)
					host:_moveTo(toast_dlg, scr_x, vy)
				end,
			})
		end
	end

	-- Exit animation on the dismissed toast: fade out and slide right.
	local enter_role = self._director and self._director:role("toast_enter")
		or Tokens.role("toast_enter")
	local travel = tonumber(enter_role.travel) or 32

	-- Read the current screen position so the exit slide starts where the window
	-- actually is. The screen-offset fallback is used only when SCREENPOSITION is
	-- unavailable (e.g. the window was never shown, which should not happen but is
	-- handled gracefully here).
	local ok_pos, cur_pos = pcall(iup.GetAttribute, dlg, "SCREENPOSITION")
	local exit_from_x = layout.toastX(dialog_w) + orig_sx
	local exit_y      = orig_sy   -- safe fallback; overwritten below when available
	if ok_pos and type(cur_pos) == "string" then
		local px, py = cur_pos:match("^(%-?%d+),(%-?%d+)")
		if px then exit_from_x = tonumber(px) end
		if py then exit_y = tonumber(py) end
	end
	local exit_to_x = exit_from_x + travel

	host:_animate({
		role     = "toast_exit",
		owner    = rec.owner,
		target   = dlg,
		from     = exit_from_x,
		to       = exit_to_x,
		on_frame = function(v)
			host:_moveTo(dlg, v, exit_y)
		end,
		on_done  = function(_)
			-- Destroy the window after the exit animation completes.
			pcall(iup.Hide, dlg)
			pcall(iup.Destroy, dlg)
			-- And the hold timer with it. Safe here in a way it is not inside
			-- `_exitToast`: this runs from the director's tick, so the timer's
			-- own callback is no longer on the stack.
			if rec.hold_timer then
				pcall(iup.Destroy, rec.hold_timer)
				rec.hold_timer = nil
			end
		end,
	})
end

--- Dismiss and destroy all toasts owned by `owner`.
--
-- Called by `HostAPI:removeOwned` on extension unload, matching how animations
-- are cancelled. Toasts without an owner (`owner == nil`) are never removed here.
--
-- @tparam table owner extension owner
function ToastHost:dismissOwned(owner)
	if not owner then return end
	-- Snapshot: _exitToast mutates _stack.
	local owned = {}
	for _, rec in ipairs(self._stack) do
		if rec.owner == owner then owned[#owned + 1] = rec end
	end
	for _, rec in ipairs(owned) do
		self:_exitToast(rec)
	end
end

--- Number of live toasts in the stack. Mainly for tests and diagnostics.
-- @treturn number
function ToastHost:count()
	return #self._stack
end

Toast.ToastHost = ToastHost

return Toast

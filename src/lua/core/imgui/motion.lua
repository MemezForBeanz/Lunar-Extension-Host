--- Motion inside widgets: values that ease toward their target, frame by frame.
--
-- IUP's flat controls changed state in one repaint, so Lunar's Carbon motion
-- (`core.lib.MotionTokens`, `core.classes.MotionDirector`) could only animate what
-- it could picture from outside: whole pages, overlays, carets. Hover, a selection
-- moving from one tab to the next and colour changes were left instant
-- (docs/motion.md, "two moments deliberately left un-animated"), because tweening
-- them meant fighting each control's own drawing.
--
-- On the ImGui host every widget draws itself every frame, so the widget can ease the
-- value it draws instead: a widget asks for the value it wants this frame and gets
-- the one on the way there. Nothing else changes about the control (its attributes,
-- callbacks and state switch at once, as on IUP); only the picture moves.
--
--     local x = motion.number(st, "indicator_x", target_x, "tab_indicator")
--     local fill = motion.color(st, "fill" .. pos, target_fill, "hover")
--
-- Durations and curves are the Carbon tokens, by role (MotionTokens.ROLES), with the
-- active theme's overrides and the user's motion settings when the host's
-- MotionDirector is attached (it attaches itself on the ImGui host): with motion off or
-- the OS asking for reduced motion, every value lands on its target at once.
--
-- @module core.imgui.motion
local Tokens = require("core.lib.MotionTokens")
local Easing = require("core.lib.MotionEasing")
local Color = require("core.imgui.Color")

local M = {}

local director   -- core.classes.MotionDirector, when the host attached one
local disabled = false -- for code without a director (tests, tools)

--- Take motion settings and theme roles from the host's MotionDirector.
function M.attach(d) director = d end

--- Turn widget motion off or on when no director is attached (a director decides
-- itself, from the user's settings and the OS).
function M.setEnabled(on) disabled = not on end

--- Is widget motion on?
function M.enabled()
	if director then
		local ok, on = pcall(director.enabled, director)
		return ok and on and true or false
	end
	return not disabled
end

local function runtime() return package.loaded["core.imgui.Runtime"] end
local function now()
	local R = runtime()
	return R and R.now and R.now() or os.clock()
end

-- The role's spec, after the theme's overrides.
local function role(name)
	if director then
		local ok, spec = pcall(director.role, director, name)
		if ok and type(spec) == "table" then return spec end
	end
	return Tokens.role(name)
end

local curves = {}
local function ease_fn(spec)
	local pts = spec.easing or Tokens.easing(spec.curve, spec.style)
	local key = table.concat(pts, ",")
	local fn = curves[key]
	if not fn then fn = Easing.curve(pts[1], pts[2], pts[3], pts[4]); curves[key] = fn end
	return fn
end

-- seconds for a change of `distance` under `spec`
local function seconds(spec, distance)
	local ms = spec.duration
	if type(ms) ~= "number" then ms = Tokens.duration(distance or 0, spec.style) end
	if director then
		local ok, scale = pcall(director.scale, director)
		if ok and type(scale) == "number" then ms = ms * scale end
	end
	return ms / 1000
end

local function tweens(st)
	local t = st.data.motion
	if not t then t = {}; st.data.motion = t end
	return t
end

-- Ask for the next frame while something is on the way.
local function keep_going()
	local R = runtime()
	if R and R.animate then R.animate() end
end

--- A number easing toward `target`.
-- The first value a key is asked for is drawn as is: nothing animates into place when
-- a widget first appears. With `opts.ident`, the value eases only when the ident
-- changes (the selected tab became another one); while it stays, the value follows
-- its target at once (the same tab moved because the window was resized).
-- @tparam table st the element's state
-- @tparam string key what is animated, unique within the element
-- @tparam number target where the value is going
-- @tparam string|table spec a MotionTokens role name, or a spec (`duration`, `curve`, `style`)
-- @tparam[opt] table opts `{ ident = any }`
-- @treturn number the value to draw this frame
function M.number(st, key, target, spec, opts)
	local t = tweens(st)
	local a = t[key]
	local ident = opts and opts.ident
	if not a then
		t[key] = { v = target, to = target, ident = ident }
		return target
	end
	if a.to ~= target then
		local moving_on = ident == nil or a.ident ~= ident
		if not moving_on or not M.enabled() then
			a.v, a.to, a.t0, a.ident = target, target, nil, ident
			return target
		end
		local s = type(spec) == "table" and spec or role(spec)
		local from = a.v
		a.from, a.to, a.ident = from, target, ident
		a.t0, a.dur, a.ease = now(), seconds(s, math.abs(target - from)), ease_fn(s)
		if a.dur <= 0 then a.v, a.t0 = target, nil; return target end
	elseif ident ~= nil then
		a.ident = ident
	end
	if a.t0 then
		local p = (now() - a.t0) / a.dur
		if p >= 1 then
			a.v, a.t0 = a.to, nil
		else
			a.v = a.from + (a.to - a.from) * a.ease(p < 0 and 0 or p)
			keep_going()
		end
	end
	return a.v
end

--- Two numbers easing together on one clock (a position and a length: an indicator
-- that slides and stretches between tabs of different widths). The duration follows
-- the distance the first one travels. Same rules as `number`.
-- @treturn number, number
function M.pair(st, key, a_to, b_to, spec, opts)
	local t = tweens(st)
	local a = t[key]
	local ident = opts and opts.ident
	if not a then
		t[key] = { a = a_to, b = b_to, ta = a_to, tb = b_to, ident = ident }
		return a_to, b_to
	end
	if a.ta ~= a_to or a.tb ~= b_to then
		local moving_on = ident == nil or a.ident ~= ident
		if not moving_on or not M.enabled() then
			a.a, a.b, a.ta, a.tb, a.t0, a.ident = a_to, b_to, a_to, b_to, nil, ident
			return a_to, b_to
		end
		local s = type(spec) == "table" and spec or role(spec)
		a.fa, a.fb, a.ta, a.tb, a.ident = a.a, a.b, a_to, b_to, ident
		a.t0, a.dur, a.ease = now(), seconds(s, math.max(math.abs(a_to - a.a), math.abs(b_to - a.b))), ease_fn(s)
		if a.dur <= 0 then a.a, a.b, a.t0 = a_to, b_to, nil; return a_to, b_to end
	elseif ident ~= nil then
		a.ident = ident
	end
	if a.t0 then
		local p = (now() - a.t0) / a.dur
		if p >= 1 then
			a.a, a.b, a.t0 = a.ta, a.tb, nil
		else
			local e = a.ease(p < 0 and 0 or p)
			a.a, a.b = a.fa + (a.ta - a.fa) * e, a.fb + (a.tb - a.fb) * e
			keep_going()
		end
	end
	return a.a, a.b
end

--- A colour easing toward `target` (a colour string, a packed colour or nil for none).
-- To and from nothing, it fades through the other colour made transparent; the result
-- is nil once it has faded out, so the caller draws nothing, as before.
-- @treturn number|nil the packed colour to draw this frame
function M.color(st, key, target, spec)
	local to = target ~= nil and Color.parse(target) or nil
	local t = tweens(st)
	local a = t[key]
	if not a then
		t[key] = { v = to, to = to }
		return to
	end
	if a.to ~= to then
		if not M.enabled() then
			a.v, a.to, a.t0 = to, to, nil
			return to
		end
		local s = type(spec) == "table" and spec or role(spec)
		local from = a.v
		-- nothing <-> a colour: fade the colour's alpha
		local f = from or (to and Color.alpha(to, 0))
		local g = to or (from and Color.alpha(from, 0))
		a.from, a.to, a.fromc, a.toc = from, to, f, g
		a.t0, a.dur, a.ease = now(), seconds(s, 0), ease_fn(s)
		if a.dur <= 0 or not f or not g then a.v, a.t0 = to, nil; return to end
	end
	if a.t0 then
		local p = (now() - a.t0) / a.dur
		if p >= 1 then
			a.v, a.t0 = a.to, nil
		else
			a.v = Color.mix(a.fromc, a.toc, a.ease(p < 0 and 0 or p))
			keep_going()
		end
	end
	return a.v
end

--- The tab page transition to play (core.lib.PageTransitions): kind, spec and name,
-- from the director (the user's choice, then the theme's), or the default kind.
function M.pageTransition()
	local PT = require("core.lib.PageTransitions")
	if director and director.pageTransition then
		local ok, def, spec, name = pcall(director.pageTransition, director)
		if ok and def then return def, spec, name end
	end
	if not M.enabled() then return PT.resolve(nil, "none") end
	return PT.resolve(nil, nil)
end

--- The easing function and the duration in seconds of a spec (or role name), for a
-- widget that runs its own progress (a page transition).
function M.timing(spec, distance)
	local s = type(spec) == "table" and spec or role(spec)
	return ease_fn(s), seconds(s, distance or 0)
end

M.now = now
M.keepGoing = keep_going

--- Is anything of this element still on the way?
function M.busy(st)
	local t = st.data.motion
	if not t then return false end
	for _, a in pairs(t) do if a.t0 then return true end end
	return false
end

--- Forget an element's values (it was rebuilt, or a test starts over).
function M.reset(st) st.data.motion = nil end

return M

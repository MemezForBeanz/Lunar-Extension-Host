--- Tab page transitions: what the outgoing and incoming pages do as one replaces the other.
--
-- A transition **kind** is pure geometry: given the eased progress (0..1) it says where
-- each page sits and how opaque it is. It draws nothing, so the same kinds drive both
-- hosts: the IUP build moves snapshots of the pages (core.ui.TabTransition), the ImGui
-- host moves the live pages themselves (core.imgui.widgets.flattabs). A theme picks one
-- with its `tab_transition` motion role (`{ kind = "rise" }`), the user can override
-- that in Appearance settings, and an extension adds its own with `register` (through
-- `ctx:registerPageTransition`, which removes it again when the extension unloads).
--
-- ### What Carbon says, and how each kind reads it
--
-- Carbon's motion guidance has no tab-specific rule. It asks for **productive** motion
-- (quick, out of the way) for repeated tasks and reserves **expressive** motion for
-- significant moments such as opening a new page; it asks for **continuity** through
-- elements shared across the change (here the tab strip, whose indicator slides to the
-- new tab, core.imgui.motion); it scales duration with distance, sub-linearly; and it
-- keeps exit easing for things that leave for good. The built-in kinds:
--
-- * `push` (default): the pages are peers on one layer, so they move together the way
--   the new tab's position implies, the outgoing a little, the incoming further, with
--   the incoming page fading in over the outgoing. Productive, 240 ms, standard.
-- * `fade`: no movement at all, only the incoming page fading in over the outgoing one
--   at Carbon's fade token (110 ms). The calmest; suits dense, frequently switched views.
-- * `rise`: the incoming page rises 16 px into place and fades in while the outgoing
--   fades away in place. Carbon's expressive "opening a new page": entrance curve,
--   expressive style, 240 ms, nothing moving sideways.
-- * `slide`: the incoming page slides in over the outgoing one, which stays put and
--   dims, as a higher layer arrives over a lower one. Use it where tabs read as a stack
--   rather than a row.
-- * `none`: the switch is instant.
--
-- ### A kind
--
--     PageTransitions.register("zoom", {
--         label = "Zoom",
--         role  = { duration = 150, curve = "entrance", style = "productive" },
--         frame = function(t, ctx)
--             -- ctx: dir (-1 forward, 1 back), w, h, travel (px), lead, fade, fade_span
--             return { dx = 0, dy = 0, alpha = 1 },          -- the outgoing page
--                    { dx = 0, dy = 8 * (1 - t), alpha = t }  -- the incoming page
--         end,
--     })
--
-- A page's table may also carry `dim` (0..1, a darkening laid over that page). The
-- incoming page is drawn over the outgoing one, both clipped to the page's rectangle,
-- over the page background when `backdrop` is true (the default). `role` gives the
-- kind's own duration, curve and style; a theme's `tab_transition` fields win over it.
--
-- @module core.lib.PageTransitions
local Tokens = require("core.lib.MotionTokens")

local M = {}

-- Push geometry (core.ui.TabTransition's numbers, which its spec holds):
M.MIN_TRAVEL = 24      -- px: shorter reads as a glitch
M.OUTGOING_LEAD = 0.5  -- the outgoing page moves half as far as the incoming one
M.FADE_SPAN = 0.85     -- the incoming page is opaque by 85% of the way

local kinds, order = {}, {}

local function clamp01(v) if v < 0 then return 0 elseif v > 1 then return 1 end return v end

--- Add or replace a kind. Returns true, or nil and why.
function M.register(name, def)
	if type(name) ~= "string" or not name:match("^[%w_%-]+$") then return nil, "kind name must be a word" end
	if type(def) ~= "table" or (name ~= "none" and type(def.frame) ~= "function") then
		return nil, "a kind needs frame(t, ctx)"
	end
	if not kinds[name] then order[#order + 1] = name end
	kinds[name] = def
	return true
end

--- Remove a kind (an extension unloading). Built-in kinds stay.
function M.unregister(name)
	local def = kinds[name]
	if not def or def.builtin then return false end
	kinds[name] = nil
	for i = #order, 1, -1 do if order[i] == name then table.remove(order, i) end end
	return true
end

--- The kind called `name`, or nil.
function M.get(name) return kinds[name] end

--- Every kind, in registration order: `{ { name = , label = }, ... }`.
function M.list()
	local out = {}
	for _, name in ipairs(order) do out[#out + 1] = { name = name, label = kinds[name].label or name } end
	return out
end

--- The transition to play: the kind and its spec (duration, curve, style, travel...).
-- `override` is the theme's `tab_transition` role table (fields win over the kind's
-- own role); `choice` is the user's setting ("theme" or nil: the theme's or default).
-- @treturn table def, table spec, string name
function M.resolve(override, choice)
	override = type(override) == "table" and override or {}
	local name = (choice and choice ~= "" and choice ~= "theme" and kinds[choice] and choice)
		or (kinds[override.kind] and override.kind) or "push"
	local def = kinds[name]
	local spec = {}
	for k, v in pairs(Tokens.ROLES.tab_transition or {}) do spec[k] = v end
	for k, v in pairs(def.role or {}) do spec[k] = v end
	-- the theme's fields belong to the kind it names (push when it names none): a user's
	-- other choice takes that kind's own timing, not the theme's push tuning
	if (override.kind or "push") == name then
		for k, v in pairs(override) do spec[k] = v end
	end
	spec.kind = name
	return def, spec, name
end

--- Geometry common to every kind, for a page `w` wide under `spec`: how far a page
-- travels (the role's `travel` fraction, capped at `max_travel` px below full travel,
-- at least MIN_TRAVEL), whether the incoming page fades, and the outgoing lead.
function M.geometry(spec, w)
	local frac = tonumber(spec.travel) or 1
	if frac > 1 then frac = 1 end
	local travel = w * frac
	local cap = tonumber(spec.max_travel)
	if cap and frac < 1 and travel > cap then travel = cap end
	if travel < M.MIN_TRAVEL then travel = math.min(M.MIN_TRAVEL, w) end
	local fade = (spec.fade ~= false) and (frac < 1)
	return { travel = travel, fade = fade, lead = fade and M.OUTGOING_LEAD or 1, fade_span = M.FADE_SPAN }
end

--- The context a kind's frame gets: direction (-1: the new tab is further along the
-- strip, so content moves left/up; 1: back) and the page size, plus the geometry.
function M.context(spec, w, h, forward)
	local ctx = M.geometry(spec, w)
	ctx.dir, ctx.w, ctx.h = forward and -1 or 1, w, h
	-- the spec's own fields too (a kind's tuning, such as rise's `rise`)
	for k, v in pairs(spec) do if ctx[k] == nil then ctx[k] = v end end
	return ctx
end

M.register("push", {
	builtin = true, label = "Push",
	frame = function(t, ctx)
		local alpha = 1
		if ctx.fade then alpha = clamp01(t / ctx.fade_span) end
		return { dx = ctx.dir * ctx.travel * ctx.lead * t, dy = 0, alpha = 1 },
			{ dx = -ctx.dir * ctx.travel * (1 - t), dy = 0, alpha = alpha }
	end,
})

M.register("fade", {
	builtin = true, label = "Fade",
	role = { duration = Tokens.DURATION.fast_02, curve = "standard", style = "productive" },
	frame = function(t)
		return { dx = 0, dy = 0, alpha = 1 }, { dx = 0, dy = 0, alpha = t }
	end,
})

M.register("rise", {
	builtin = true, label = "Rise",
	role = { duration = Tokens.DURATION.moderate_02, curve = "entrance", style = "expressive", rise = 16 },
	frame = function(t, ctx)
		local rise = tonumber(ctx.rise) or 16
		-- the outgoing page is gone by a third of the way, so the two never read as one
		return { dx = 0, dy = 0, alpha = 1 - clamp01(t * 3) },
			{ dx = 0, dy = rise * (1 - t), alpha = clamp01(t / 0.6) }
	end,
})

M.register("slide", {
	builtin = true, label = "Slide over",
	role = { duration = Tokens.DURATION.moderate_02, curve = "standard", style = "productive" },
	frame = function(t, ctx)
		return { dx = 0, dy = 0, alpha = 1, dim = 0.35 * t },
			{ dx = -ctx.dir * ctx.w * (1 - t), dy = 0, alpha = 1 }
	end,
})

M.register("none", { builtin = true, label = "None" })

return M

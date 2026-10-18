--- Pure scene validation, ordering, and input hit testing.
-- Coordinates are device pixels and rectangles use half-open bounds.
-- @module core.lib.Scene

local M = {}
local LIMIT = 2147483647
local MIN = -2147483648

local function integer(v, lo, hi)
	return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

local function rect(r, where)
	if type(r) ~= "table" then return nil, where .. " must be a table" end
	for _, key in ipairs({ "x", "y" }) do
		if not integer(r[key], MIN, LIMIT) then return nil, where .. "." .. key .. " must be a signed 32-bit integer" end
	end
	for _, key in ipairs({ "w", "h" }) do
		if not integer(r[key], 0, LIMIT) then return nil, where .. "." .. key .. " must be a nonnegative integer" end
	end
	return true
end

local function array(t, where)
	if type(t) ~= "table" then return nil, where .. " must be a table" end
	local count, max = 0, 0
	for k in pairs(t) do
		if type(k) == "number" then
			if not integer(k, 1, LIMIT) then return nil, where .. " must use positive integer indices" end
			count = count + 1
			if k > max then max = k end
		end
	end
	if count ~= max then return nil, where .. " must be a dense array" end
	return max
end

local function alpha(v)
	return type(v) == "number" and v >= 0 and v <= 1
end

local function snapshot_size(s)
	if type(s) ~= "table" and type(s) ~= "userdata" then return nil end
	local ok, w, h = pcall(function() return s.w, s.h end)
	if ok and integer(w, 1, LIMIT) and integer(h, 1, LIMIT) then return w, h end
	return nil
end

--- Validate a scene and any attached input regions.
-- `scene` has positive `w`, `h`, and a dense array of sprites. Image snapshots
-- may be native userdata or test doubles exposing integer `w`, `h` fields.
-- @tparam table scene Scene to validate.
-- @treturn boolean|nil True on success, otherwise nil.
-- @treturn string|nil Error on failure.
function M.validate(scene)
	if type(scene) ~= "table" then return nil, "scene must be a table" end
	if not integer(scene.w, 1, LIMIT) or not integer(scene.h, 1, LIMIT) or
		scene.w * scene.h * 4 > 9007199254740991 then
		return nil, "scene w and h must be positive 32-bit integers with a representable buffer"
	end
	local n, why = array(scene, "scene sprites")
	if not n then return nil, why end
	for i = 1, n do
		local s = scene[i]
		if type(s) ~= "table" then return nil, "sprite " .. i .. " must be a table" end
		if s.kind ~= "fill" and s.kind ~= "rrect" and s.kind ~= "stroke" and s.kind ~= "image" then
			return nil, "sprite " .. i .. " has invalid kind"
		end
		if not integer(s.x, MIN, LIMIT) or not integer(s.y, MIN, LIMIT) then
			return nil, "sprite " .. i .. " x and y must be signed 32-bit integers"
		end
		if not alpha(s.alpha) then return nil, "sprite " .. i .. " alpha must be in [0, 1]" end
		if s.clip ~= nil then
			local valid, reason = rect(s.clip, "sprite " .. i .. " clip")
			if not valid then return nil, reason end
		end
		if s.kind == "image" then
			local sw, sh = snapshot_size(s.snap)
			if not sw then return nil, "sprite " .. i .. " snap must expose positive w and h" end
			local sx, sy = s.sx or 0, s.sy or 0
			local width, height = s.sw or (sw - sx), s.sh or (sh - sy)
			if not integer(sx, 0, LIMIT) or not integer(sy, 0, LIMIT) or
				not integer(width, 0, LIMIT) or not integer(height, 0, LIMIT) or
				sx + width > sw or sy + height > sh then
				return nil, "sprite " .. i .. " source rectangle outside snapshot"
			end
		else
			if not integer(s.w, 0, LIMIT) or not integer(s.h, 0, LIMIT) then
				return nil, "sprite " .. i .. " w and h must be nonnegative integers"
			end
			if not integer(s.color, 0, 0xffffff) then return nil, "sprite " .. i .. " color must be 24-bit RGB" end
			if s.kind == "rrect" and not integer(s.radius, 0, LIMIT) then
				return nil, "sprite " .. i .. " radius must be nonnegative integer"
			end
			if s.kind == "stroke" and not integer(s.thickness, 1, LIMIT) then
				return nil, "sprite " .. i .. " thickness must be positive integer"
			end
		end
	end
	if scene.regions ~= nil then
		local rn, reason = array(scene.regions, "regions")
		if not rn then return nil, reason end
		for i = 1, rn do
			local region = scene.regions[i]
			local valid, rect_reason = rect(region, "region " .. i)
			if not valid then return nil, rect_reason end
			if region.mode ~= "pass" and region.mode ~= "block" and region.mode ~= "action" then
				return nil, "region " .. i .. " has invalid mode"
			end
			if region.mode == "action" and type(region.id) ~= "string" and type(region.id) ~= "number" then
				return nil, "region " .. i .. " action requires string or number id"
			end
		end
	end
	return true
end

--- Find the last matching region in draw order.
-- A pass region is returned too, so callers can forward the input.
-- @tparam table regions Ordered region array.
-- @tparam number x Device-pixel x coordinate.
-- @tparam number y Device-pixel y coordinate.
-- @treturn table|nil Matching region or nil for unlisted area.
function M.hit(regions, x, y)
	for i = #regions, 1, -1 do
		local r = regions[i]
		if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then return r end
	end
	return nil
end

--- Flatten groups by increasing z, then insertion order.
-- Groups may be an array or a map. Mapped groups need `_order` assigned by
-- the scene manager; ties use a stable string form of the key.
-- @tparam table groups Groups with `z`, `sprites`, and `regions` fields.
-- @treturn table Ordered sprite array.
-- @treturn table Ordered region array.
function M.flatten(groups)
	local ordered, sprites, regions = {}, {}, {}
	for id, group in pairs(groups) do
		ordered[#ordered + 1] = { id = id, group = group }
	end
	table.sort(ordered, function(a, b)
		if a.group.z ~= b.group.z then return a.group.z < b.group.z end
		if (a.group._order or 0) ~= (b.group._order or 0) then
			return (a.group._order or 0) < (b.group._order or 0)
		end
		return tostring(a.id) < tostring(b.id)
	end)
	for _, entry in ipairs(ordered) do
		for _, sprite in ipairs(entry.group.sprites or {}) do sprites[#sprites + 1] = sprite end
		for _, region in ipairs(entry.group.regions or {}) do regions[#regions + 1] = region end
	end
	return sprites, regions
end

return M

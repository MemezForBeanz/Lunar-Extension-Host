--- Icons that move: a play and pause morph, and now-playing equalizer bars.
--
-- Shapes are point lists, so the morph is plain arithmetic that a spec can check. NanoSVG has
-- no animation, so each frame is an SVG written once to a private folder and rasterised by
-- `core.ui.VectorIcon`, which caches by path. Frames are quantised: a morph redraws at most
-- `FRAMES` images, however fast the display runs.
--
-- Motion runs on the host's director through the `animate` function you pass in, normally
-- `function(spec) return ctx:animate(spec, M) end`. With motion off, the director delivers the
-- end value at once, so the icon lands on its end state. The equalizer holds still.
--
-- Designed by LongCat 2.5 of the Lunar council; the frame cache and two-bar shapes were added
-- in review.
--
-- ```lua
-- local icon = AnimatedIcon.new(iup, { animate = animate, size = 20, role = "neutral" })
-- box:append(icon:widget())
-- icon:setPlaying(true)      -- shows pause, the action the button now offers
-- icon:setEqualizer(true)    -- three moving bars for the row that is playing
-- ```
--
-- @module core.ui.AnimatedIcon

local lfs = require("lfs")
local platform = require("core.platform")

local M = {}
M.__index = M

M.FRAMES = 8
M.EQUALIZER_FRAMES = 12

-- Each glyph is two four-point shapes on a 32 unit square. The play triangle is cut in two at
-- its middle, so each half has a pause bar to become, and no shape crosses another on the way.
M.PLAY = {
	{ { 9, 5 }, { 18, 10.5 }, { 18, 21.5 }, { 9, 27 } },
	{ { 18, 10.5 }, { 27, 16 }, { 27, 16 }, { 18, 21.5 } },
}
M.PAUSE = {
	{ { 8, 4 }, { 14, 4 }, { 14, 28 }, { 8, 28 } },
	{ { 18, 4 }, { 24, 4 }, { 24, 28 }, { 18, 28 } },
}

local BAR_WIDTH, BAR_GAP, BAR_FLOOR = 6, 3, 28
local BAR_MIN, BAR_MAX = 6, 24

local function lerp(a, b, t)
	return a + (b - a) * t
end

--- Resample a closed point loop to `count` points, evenly along its perimeter.
-- @tparam table points list of `{ x, y }`
-- @tparam number count points wanted
-- @treturn table the new list
function M.resample(points, count)
	count = math.floor(count)
	if #points == 0 or count <= 0 then return {} end
	if count == 1 then return { { points[1][1], points[1][2] } } end
	if count == #points then
		local out = {}
		for i = 1, #points do out[i] = { points[i][1], points[i][2] } end
		return out
	end
	local lengths, total = {}, 0
	for i = 1, #points do
		local a, b = points[i], points[(i % #points) + 1]
		lengths[i] = math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
		total = total + lengths[i]
	end
	local out, seg, walked = {}, 1, 0
	for i = 1, count do
		local distance = total * (i - 1) / count
		while seg < #points and walked + lengths[seg] < distance do
			walked = walked + lengths[seg]
			seg = seg + 1
		end
		local a, b = points[seg], points[(seg % #points) + 1]
		local along = lengths[seg] > 0 and (distance - walked) / lengths[seg] or 0
		out[i] = { lerp(a[1], b[1], along), lerp(a[2], b[2], along) }
	end
	return out
end

--- Interpolate two point lists of equal length.
function M.lerpPoints(a, b, t)
	local out = {}
	for i = 1, #a do
		out[i] = { lerp(a[i][1], b[i][1], t), lerp(a[i][2], b[i][2], t) }
	end
	return out
end

--- Interpolate two closed shapes, resampling them to a common point count.
function M.morphPoints(a, b, t)
	local n = math.max(#a, #b)
	return M.lerpPoints(M.resample(a, n), M.resample(b, n), t)
end

--- The play and pause glyph at `t`: 0 is play, 1 is pause.
-- @treturn table a list of shapes
function M.glyphShapes(t)
	local shapes = {}
	for i = 1, #M.PLAY do shapes[i] = M.morphPoints(M.PLAY[i], M.PAUSE[i], t) end
	return shapes
end

--- The three bar heights at `phase`, 0 to 1. Each bar is a third of a cycle behind the last.
function M.barHeights(phase)
	local out = {}
	for i = 1, 3 do
		local wave = 0.5 + 0.5 * math.sin((phase + (i - 1) / 3) * math.pi * 2)
		out[i] = lerp(BAR_MIN, BAR_MAX, wave)
	end
	return out
end

local function path_of(shape)
	local d = {}
	for i, point in ipairs(shape) do
		d[i] = string.format("%s%.2f %.2f", i == 1 and "M" or "L", point[1], point[2])
	end
	d[#d + 1] = "Z"
	return table.concat(d, " ")
end

local function svg_of(shapes)
	local d = {}
	for i, shape in ipairs(shapes) do d[i] = path_of(shape) end
	return '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32"><path d="'
		.. table.concat(d, " ") .. '"/></svg>'
end

--- SVG text for frame `t` of the morph.
function M.glyphSVG(t) return svg_of(M.glyphShapes(t)) end

--- SVG text for the equalizer at `phase`.
function M.barsSVG(phase)
	local shapes = {}
	for i, height in ipairs(M.barHeights(phase)) do
		local x = 2 + (i - 1) * (BAR_WIDTH + BAR_GAP)
		local top = BAR_FLOOR - height
		shapes[i] = { { x, top }, { x + BAR_WIDTH, top }, { x + BAR_WIDTH, BAR_FLOOR }, { x, BAR_FLOOR } }
	end
	return svg_of(shapes)
end

local frame_dir

local function default_frame(name, svg)
	if not frame_dir then
		frame_dir = platform.path:join(platform.temp_dir(), "lunar-animated-icons")
		lfs.mkdir(frame_dir)
	end
	local path = platform.path:join(frame_dir, name .. ".svg")
	if not lfs.attributes(path) then
		local file = io.open(path, "w")
		if not file then return nil end
		file:write(svg)
		file:close()
	end
	return path
end

--- Create an icon.
-- @tparam userdata iup
-- @tparam[opt] table opts `animate` (see the module note), `size` (default 20), `role` (a
--   `VectorIcon` colour role, default "neutral"), `playing`, `paint(path)` to draw somewhere
--   other than a `VectorIcon`, and `frame(name, svg)` to store frames somewhere else
function M.new(iup, opts)
	opts = opts or {}
	local self = setmetatable({
		iup = iup, animate = opts.animate, size = opts.size or 20, role = opts.role or "neutral",
		paint = opts.paint, frame = opts.frame or default_frame,
		playing = opts.playing == true, progress = opts.playing and 1 or 0,
		equalizer = false,
	}, M)
	self:_draw()
	return self
end

--- The widget to put in a layout. Created on first use.
function M:widget()
	if not self.icon then
		self.icon = require("core.ui.VectorIcon").new(self.iup, { size = self.size })
		self:_draw()
	end
	return self.icon:widget()
end

function M:_show(path)
	if not path then return end
	if self.paint then return self.paint(path) end
	if self.icon then self.icon:setIconRole(path, self.role) end
end

function M:_draw()
	local step = math.floor(self.progress * M.FRAMES + 0.5)
	self:_show(self.frame("morph-" .. step, M.glyphSVG(step / M.FRAMES)))
end

function M:_draw_bars(phase)
	local step = math.floor(phase * M.EQUALIZER_FRAMES) % M.EQUALIZER_FRAMES
	self:_show(self.frame("bars-" .. step, M.barsSVG(step / M.EQUALIZER_FRAMES)))
end

--- Show the playing state. Playing shows pause, which is what a press will do.
function M:setPlaying(playing)
	if self.playing == playing then return self end
	self.playing = playing
	if self.morph then self.morph.cancel() end
	local target = playing and 1 or 0
	if self.equalizer or not self.animate then
		self.progress = target
		if not self.equalizer then self:_draw() end
		return self
	end
	self.morph = self.animate({
		role = "status_change", from = self.progress, to = target,
		on_frame = function(value)
			self.progress = value
			self:_draw()
		end,
		on_done = function() self.morph = nil end,
	})
	return self
end

function M:_cycle()
	self.bars = self.animate({
		duration = 1200, from = 0, to = 1, curve = "linear",
		on_frame = function(value) self:_draw_bars(value % 1) end,
		on_done = function(completed)
			self.bars = nil
			if completed and self.equalizer and self.moving then self:_cycle() end
		end,
	})
end

--- Show or hide the moving bars. Without motion they hold one still frame.
function M:setEqualizer(active)
	if self.equalizer == active then return self end
	self.equalizer = active
	if self.bars then self.bars.cancel() end
	if not active then
		self.moving = false
		self:_draw()
		return self
	end
	self:_draw_bars(0.25)
	local motion = self.animate and (not self.motion_enabled or self.motion_enabled())
	self.moving = motion and true or false
	if self.moving then self:_cycle() end
	return self
end

--- Stop any animation; call before the widget goes away.
function M:stop()
	self.equalizer, self.moving = false, false
	if self.morph then self.morph.cancel() end
	if self.bars then self.bars.cancel() end
end

return M

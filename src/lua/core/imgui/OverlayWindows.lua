-- Native surfaces for bounded, interactive overlays and tooltips.
local M = {}
function M.new(B, now, wake)
	local enabled = B.overlay_windows == true and B.surface and os.getenv("LUNAR_OVERLAY_WINDOWS") ~= "0"
	local pool = {}
	local self = { enabled = enabled }
	function self.release(o)
		if not o.win then return end
		B.window("overlay_place", o.win, 0, 0, 1, 1, false, 0)
		pool[#pool + 1] = { id = o.win, owner = o.native_owner, pass = o.passthrough == true, due = now() + 5 }
		o.win = nil
		o.shift_x, o.shift_y = nil, nil
		while #pool > 2 do B.window("overlay_close", table.remove(pool, 1).id) end
		wake(now() + 5)
	end
	function self.sweep(all)
		for i = #pool, 1, -1 do
			if all or now() >= pool[i].due then B.window("overlay_close", pool[i].id); table.remove(pool, i)
			else wake(pool[i].due) end
		end
	end
	function self.prepare(o, owner, bounds, videos)
		if not enabled or o.w <= 0 or o.h <= 0 or (not o.event and not o.passthrough) then return end
		local x, y, w, h = o.x, o.y, o.w, o.h
		local promote = o.win or x < bounds[1] or y < bounds[2] or x+w > bounds[1]+bounds[3] or y+h > bounds[2]+bounds[4]
		for _, r in ipairs(videos) do
			if r.surface == owner and x < r.x+r.w and y < r.y+r.h and x+w > r.x and y+h > r.y then promote = true end
		end
		if not promote then return end
		if o.win and o.native_owner ~= owner then self.release(o) end
		if not o.win then
			for i = #pool, 1, -1 do
				local p = pool[i]
				if p.owner == owner and p.pass == (o.passthrough == true) then o.win = p.id; table.remove(pool, i); break end
			end
			o.win = o.win or B.window("overlay_open", { owner = owner, passthrough = o.passthrough })
			o.native_owner = owner
		end
		if not o.win then return end
		local bx, by, bw, bh = B.window("monitor", x, y)
		if bx then
			if y+h > by+bh then y = y-h end
			x = math.max(bx, math.min(x, bx+bw-w)); y = math.max(by, math.min(y, by+bh-h))
		end
		o.shift_x, o.shift_y = x-o.x, y-o.y
		local margin = 8
		if B.window("overlay_place", o.win, x-margin, y-margin, w+margin*2, h+margin*2, true, margin) == false then
			B.window("overlay_close", o.win); o.win = nil
			o.shift_x, o.shift_y = nil, nil
			return
		end
		return o.win, x-margin, y-margin, w+margin*2, h+margin*2
	end
	return self
end
return M

-- scripts/ui_scroll_audit.lua: the scroll check the UI capture runs on every shot (ImGui
-- host only). For the window as it is shown:
--
--   (a) a scroll container shows no thumb when its content fits: the visible leaves of its
--       content end inside the viewport, so a range past them is empty space (a container
--       laid out taller than what it holds, a min size, an expanding child);
--   (b) scrolled to the end, the last visible leaf of a scroll container is fully inside
--       its viewport (and the container goes back where it was);
--   (c) nothing visible is cut off by a container that cannot scroll to it: every leaf
--       lies inside each clipping ancestor up to its nearest scroll container (whose reach
--       is (b)), so a page laid out taller than its window, or a rail pushed past its
--       bottom, is caught too.
--
-- A leaf is a control, or a nested scroll container, list, grid or text (they show their
-- own content). Hidden subtrees and the pages behind a tab are not walked.
--
-- Use: local Audit = dofile("scripts/ui_scroll_audit.lua"); local a = Audit.new(iup)
--      a:check(dialog, "shot-05-media-home") ... a:finish(out_dir, prefix)
-- Run on its own at wide and narrow size: Lunar scripts/ui_audit.lua <out_dir> [prefix].
local M = {}
M.__index = M

local TOL = 2 -- px: rounding in the layout
local SCROLL = { scrollbox = true, flatscrollbox = true }
-- Shown content is drawn by the control: its rect is all the page can lay out.
local OPAQUE = { flatrows = true, flatlist = true, list = true, text = true, multiline = true,
	scintilla = true, flatgrid = true, canvas = true, videohost = true, flatseek = true,
	dropbutton = true }
local SKIP = { fill = true, timer = true, image = true, menu = true, item = true, separator = true }

function M.new(iup)
	local self = setmetatable({ iup = iup, lines = {}, failures = 0, checked = 0, shots = 0 }, M)
	self.Element = require("core.imgui.Element")
	self.Runtime = require("core.imgui.Runtime")
	self.Layout = require("core.imgui.Layout")
	return self
end

local function name_of(self, el)
	local st = self.Element.state(el)
	local a = st and st.attrs or {}
	local label = a.TITLE or a.TIP or a.NAME or a.THEMEROLE or ""
	label = tostring(label):gsub("[\r\n\t]", " "):sub(1, 40)
	return string.format("%s%s", st and st.classname or "?", label ~= "" and (" '" .. label .. "'") or "")
end

local function rect(st) return string.format("%d,%d %dx%d", st.x or 0, st.y or 0, st.w or 0, st.h or 0) end

local function shown(st)
	if not st or st.internal then return false end
	if st.attrs.VISIBLE == "NO" then return false end
	return true
end

local function children(self, el, st)
	local list = self.Runtime.childrenShown(el, st)
	local out = {}
	for _, c in ipairs(list or {}) do
		local cs = self.Element.state(c)
		if shown(cs) then out[#out + 1] = c end
	end
	return out
end

local function is_leaf(self, el, st)
	if SCROLL[st.classname] or OPAQUE[st.classname] then return true end
	return #children(self, el, st) == 0
end

-- The leaves under el, not descending into nested scroll containers.
local function leaves(self, el, out, skip_self)
	local st = self.Element.state(el)
	if not shown(st) or SKIP[st.classname] then return out end
	if not skip_self and is_leaf(self, el, st) then
		if (st.w or 0) > 1 and (st.h or 0) > 1 then out[#out + 1] = el end
		return out
	end
	for _, c in ipairs(children(self, el, st)) do leaves(self, c, out) end
	return out
end

local function vertical_bar(self, el, st)
	local v = tostring(self.Element.getAttribute(el, st.classname == "scrollbox" and "SCROLLBAR" or "FLATSCROLLBAR") or "")
	v = v:upper()
	return v == "YES" or v == "VERTICAL"
end

local function viewport(st)
	local dy = st.data.dy or 0
	if dy <= 0 then dy = st.h end
	return st.y, st.y + dy
end

local function relayout(self, el)
	self.Runtime.relayout(el)
	self.Runtime.layoutNow(el)
end

local function add(self, shot, kind, text)
	self.failures = self.failures + 1
	self.lines[#self.lines + 1] = string.format("FAIL %s [%s] %s", shot, kind, text)
end

-- Why a container's content is as tall as it is: each shown child with its laid-out
-- height, natural height and minimum, down the tallest branch.
local function explain(self, el, depth, out, indent)
	indent = indent or "    "
	local st = self.Element.state(el)
	if not st or depth <= 0 then return end
	local tallest, th = nil, -1
	for _, c in ipairs(children(self, el, st)) do
		local cs = self.Element.state(c)
		local ex = self.Layout.L.expand and select(2, self.Layout.L.expand(c))
		out[#out + 1] = string.format("%s%s at %s nat_h %d min_h %d%s", indent, name_of(self, c), rect(cs),
			cs.nat_h or 0, self.Layout.minContent(c, false), ex and " EXPAND-V" or "")
		if (cs.h or 0) > th then tallest, th = c, cs.h or 0 end
	end
	if tallest then explain(self, tallest, depth - 1, out, indent .. "  ") end
end

-- (a) and (b) for one scroll container.
local function check_scroll(self, shot, el)
	local E = self.Element
	local st = E.state(el)
	if not vertical_bar(self, el, st) or (st.w or 0) <= 0 or (st.h or 0) <= 0 then return end
	self.checked = self.checked + 1
	local d = st.data
	local ymax, dy, posy = d.ymax or 0, d.dy or 0, d.posy or 0
	local thumb = dy > 0 and ymax > dy
	if not thumb then return end
	local top, bottom = viewport(st)
	local child = nil
	for _, c in ipairs(st.children) do if shown(E.state(c)) then child = c; break end end
	if not child then return end
	local found = leaves(self, child, {})
	-- (a) where the leaves end, unscrolled
	local ink = 0
	-- A NATIVETEXTSCROLL box keeps its text the size of the view and scrolls it by lines,
	-- so the text's rect says nothing: its content is every line plus the EDIT's inset.
	local cs = E.state(child)
	local native = d.native_liney and cs and (cs.classname == "text" or cs.classname == "multiline")
	local lines = native and (tonumber(E.getAttribute(child, "LINECOUNT")) or 1)
	if native then
		local border = tostring(E.getAttribute(child, "BORDER") or ""):upper() == "YES" and 2 or 0
		ink = (cs.y - st.y) + 2 * border + 2 + lines * d.native_liney
	end
	for _, leaf in ipairs(native and {} or found) do
		local ls = E.state(leaf)
		ink = math.max(ink, (ls.y + posy) - st.y + ls.h)
	end
	if ink <= (bottom - top) + TOL then
		local why = {}
		explain(self, child, 4, why)
		add(self, shot, "thumb-fits", string.format("%s at %s: range %d, view %d, but its content ends at %d\n%s",
			name_of(self, el), rect(st), ymax, dy, ink, table.concat(why, "\n")))
	elseif ymax - ink > 24 then
		local why = {}
		explain(self, child, 4, why)
		add(self, shot, "empty-tail", string.format("%s at %s: range %d, but its content ends at %d (%d px of nothing)\n%s",
			name_of(self, el), rect(st), ymax, ink, ymax - ink, table.concat(why, "\n")))
	end
	-- (b) scrolled to the end
	self.iup.SetAttribute(el, "POSY", tostring(math.max(0, ymax - dy)))
	relayout(self, el)
	local last, lb = nil, -math.huge
	for _, leaf in ipairs(leaves(self, child, {})) do
		local ls = E.state(leaf)
		if ls.y + ls.h > lb then last, lb = leaf, ls.y + ls.h end
	end
	top, bottom = viewport(st)
	if native then
		-- the text's last line is on screen
		local first = tonumber(E.getAttribute(child, "FIRSTVISIBLELINE")) or 1
		local shown = require("core.imgui.widgets.text").mlVisibleLines(child, cs)
		if first + math.max(1, shown) - 1 < lines then
			add(self, shot, "end-unreachable", string.format("%s at %s scrolled to %s: its text shows lines %d..%d of %d",
				name_of(self, el), rect(st), tostring(d.posy), first, first + shown - 1, lines))
		end
	elseif last then
		local ls = E.state(last)
		if ls.y + ls.h > bottom + TOL or ls.y < top - TOL then
			add(self, shot, "end-unreachable", string.format("%s at %s scrolled to %s: last child %s at %s, viewport %d..%d",
				name_of(self, el), rect(st), tostring(d.posy), name_of(self, last), rect(ls), top, bottom))
		end
	end
	self.iup.SetAttribute(el, "POSY", tostring(posy))
	relayout(self, el)
end

-- (c) leaves cut off by a clipping ancestor below their nearest scroll container.
local function check_clip(self, shot, root)
	local E = self.Element
	for _, leaf in ipairs(leaves(self, root, {}, true)) do
		local ls = E.state(leaf)
		local y1 = math.huge
		local p = ls.parent
		local by = nil
		while p do
			local ps = E.state(p)
			if not ps then break end
			if SCROLL[ps.classname] then break end
			local cls = ps.class
			if cls.clip or cls.clipRect or ps.classname == "dialog" then
				local cy, ch = ps.y, ps.h
				if ps.classname == "dialog" then cy = 0 end
				if cy + ch < y1 then y1, by = cy + ch, p end
			end
			p = ps.parent
		end
		if by and ls.y + ls.h > y1 + TOL then
			-- the first one under each clipper says why: the boxes between, with what they need
			local why = ""
			self.explained = self.explained or {}
			local key = shot .. tostring(by)
			if not self.explained[key] or SCROLL[ls.classname] then
				self.explained[key] = true
				local chain = { string.format("    nat_h %d min_h %d", ls.nat_h or 0, self.Layout.minContent(leaf, false)) }
				local a = ls.parent
				while a and a ~= by do
					local as = E.state(a)
					local kids = {}
					for _, c in ipairs(as.children) do
						local cs = E.state(c)
						if cs and not cs.internal then
							kids[#kids + 1] = string.format("%s:%d%s%s", cs.classname, cs.nat_h or 0,
								cs.attrs.FLOATING == "YES" and "F" or "", cs.attrs.VISIBLE == "NO" and "H" or "")
						end
					end
					chain[#chain + 1] = string.format("    in %s at %s nat_h %d min_h %d [%s]", name_of(self, a), rect(as),
						as.nat_h or 0, self.Layout.minContent(a, false), table.concat(kids, " "))
					a = as.parent
				end
				why = "\n" .. table.concat(chain, "\n")
			end
			add(self, shot, "cut-off", string.format("%s at %s %s the bottom of %s (%d), which cannot scroll to it%s",
				name_of(self, leaf), rect(ls), ls.y >= y1 and "is entirely below" or "runs past",
				name_of(self, by), y1, why))
		end
	end
end

--- Check every shown scroll container of a dialog, and what its clipping hides.
function M:check(dialog, shot)
	if not rawget(self.iup, "_IMGUI") or not dialog then return end
	self.shots = self.shots + 1
	local E = self.Element
	self.Runtime.layoutNow(dialog)
	local before = self.failures
	local function walk(el)
		local st = E.state(el)
		if not shown(st) then return end
		if SCROLL[st.classname] then check_scroll(self, shot, el) end
		for _, c in ipairs(children(self, el, st)) do walk(c) end
	end
	walk(dialog)
	-- the scroll checks put every container back; lay out again before (c) reads rects
	self.Runtime.relayout(dialog)
	self.Runtime.layoutNow(dialog)
	-- scroll containers are checked by (a)/(b); (c) looks at everything else, and at the
	-- scroll containers themselves inside their parents
	local function clips(el)
		local st = E.state(el)
		if not shown(st) then return end
		if SCROLL[st.classname] then
			for _, c in ipairs(children(self, el, st)) do check_clip(self, shot, c); clips(c) end
		else
			for _, c in ipairs(children(self, el, st)) do clips(c) end
		end
	end
	check_clip(self, shot, dialog)
	clips(dialog)
	if self.failures == before then self.lines[#self.lines + 1] = "ok   " .. shot end
end

--- Write <out>/<prefix>-scroll-audit.txt; on any failure also SCROLL-AUDIT-FAILED.txt there
-- and a log the capture tool prints. Returns the number of failures.
function M:finish(out_dir, prefix)
	if not rawget(self.iup, "_IMGUI") then return 0 end
	local summary = string.format("scroll audit: %d shots, %d scroll containers with a thumb or range checked, %d failures",
		self.shots, self.checked, self.failures)
	local f = io.open(string.format("%s/%s-scroll-audit.txt", out_dir, prefix), "w")
	if f then f:write(summary, "\n", table.concat(self.lines, "\n"), "\n"); f:close() end
	local flag = string.format("%s/SCROLL-AUDIT-FAILED.txt", out_dir)
	if self.failures > 0 then
		local g = io.open(flag, "w")
		if g then g:write(summary, "\n", table.concat(self.lines, "\n"), "\n"); g:close() end
		-- cap-ui.ps1 prints the tail of every .log under APPDATA after a run
		local appdata = os.getenv("APPDATA")
		if appdata then
			local h = io.open(appdata .. "/scroll-audit-FAILED.log", "w")
			if h then h:write(summary, "\n"); h:write("see ", out_dir, "/SCROLL-AUDIT-FAILED.txt\n"); h:close() end
		end
	else
		os.remove(flag)
	end
	io.stderr:write("ui_capture: ", summary, "\n")
	return self.failures
end

return M

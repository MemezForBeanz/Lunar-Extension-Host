local M = {}
local function next_char(s, p)
	local b = s:byte(p + 1) or 0
	return p + (b < 128 and 1 or b < 224 and 2 or b < 240 and 3 or 4)
end
function M.new(doc, width, font, mode, indent, indent_mode, measure)
	local cw, ch = font:charsize()
	return setmetatable({ doc = doc, width = math.max(cw, width), font = font, mode = mode,
		indent = (indent or 0) * cw, indent_mode = indent_mode or 0,
		cw = cw, ch = ch, cache = {}, prefix = { [0] = 0 }, through = 0, measure = measure }, { __index = M })
end
function M:line(line)
	if self.cache[line] then return self.cache[line] end
	local doc, text = self.doc, self.doc.text
	local start, finish = doc:line_start(line), doc:line_end(line)
	local rows, p = {}, start
	local indent = self.indent
	if self.indent_mode > 0 then
		indent = doc:line_indentation(line) * self.cw
		if self.indent_mode >= 2 then indent = indent + (self.indent_mode - 1) * doc.tab_width * self.cw end
	end
	indent = math.min(indent, self.width - self.cw)
	if self.start_flag then indent = math.max(indent, self.cw) end
	repeat
		local a, x, col, boundary = p, 0, 0, nil
		local inset = #rows == 0 and 0 or indent
		local xs = { [p] = 0 }
		while p < finish do
			local q = math.min(finish, next_char(text, p))
			local c = text:sub(p + 1, q)
			local advance = c == "\t" and (doc.tab_width - col % doc.tab_width) * self.cw
				or (self.measure and self.measure(p, c) or self.font:measure(c))
			if self.mode ~= 0 and x + advance > self.width - inset and p > a then break end
			x, col = x + advance, col + (c == "\t" and doc.tab_width - col % doc.tab_width or 1)
			p = q; xs[p] = x
			if c:match("%s") or (self.mode == 1 and c:match("[%p]")) then boundary = p end
		end
		if self.mode ~= 0 and self.mode ~= 2 and p < finish and boundary and boundary > a then p = boundary end
		rows[#rows + 1] = { start = a, finish = p, indent = inset, xs = xs, line = line }
	until p >= finish
	self.cache[line] = rows
	return rows
end
function M:visible(line)
	line = math.max(0, math.min(line, self.doc:lines_total()))
	while self.through < line do
		local n = self.through
		self.prefix[n + 1] = self.prefix[n] + #self:line(n)
		self.through = n + 1
	end
	return self.prefix[line]
end
function M:row(display)
	display = math.max(0, display)
	while self.through < self.doc:lines_total() and self.prefix[self.through] <= display do self:visible(self.through + 1) end
	local lo, hi = 0, self.through - 1
	while lo < hi do local mid = math.floor((lo + hi + 1) / 2); if self.prefix[mid] <= display then lo = mid else hi = mid - 1 end end
	local rows = self:line(lo)
	local sub = math.min(#rows, display - self.prefix[lo] + 1)
	return rows[sub], lo, sub
end
function M:position(pos)
	local line = self.doc:line_from_position(pos)
	local rows = self:line(line)
	for i, row in ipairs(rows) do
		if pos < row.finish or i == #rows then
			return self:visible(line) + i - 1, row.indent + (row.xs[math.min(pos, row.finish)] or 0), row
		end
	end
end
function M:hit(display, x)
	local row = self:row(display)
	x = x - row.indent
	local p = row.start
	while p < row.finish do
		local q = math.min(row.finish, next_char(self.doc.text, p))
		if x < ((row.xs[p] or 0) + (row.xs[q] or 0)) / 2 then return p end
		p = q
	end
	return row.finish
end
return M

-- UTF-8 byte offsets and the UTF-16 code-unit positions used by Win32 EDIT.
local M = {}

local function decode(s, p)
	local b = s:byte(p)
	if not b then return nil, p, 0 end
	if b < 0x80 then return b, p + 1, 1 end
	local n, cp, min
	if b >= 0xC2 and b <= 0xDF then n, cp, min = 2, b - 0xC0, 0x80
	elseif b >= 0xE0 and b <= 0xEF then n, cp, min = 3, b - 0xE0, 0x800
	elseif b >= 0xF0 and b <= 0xF4 then n, cp, min = 4, b - 0xF0, 0x10000
	else return 0xFFFD, p + 1, 1 end
	for i = 2, n do
		local c = s:byte(p + i - 1)
		if not c or c < 0x80 or c > 0xBF then return 0xFFFD, p + 1, 1 end
		cp = cp * 0x40 + c - 0x80
	end
	if cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
		return 0xFFFD, p + 1, 1
	end
	return cp, p + n, cp > 0xFFFF and 2 or 1
end

function M.byte_to_units(s, byte_pos)
	s = tostring(s or "")
	local target = math.max(0, math.min(#s, math.floor(byte_pos or 0)))
	local p, units = 1, 0
	while p <= target do
		local _, next_p, width = decode(s, p)
		if next_p > target + 1 then break end
		units, p = units + width, next_p
	end
	return units
end

function M.units_to_byte(s, unit_pos)
	s = tostring(s or "")
	local remaining = math.max(0, math.floor(unit_pos or 0))
	local p = 1
	while p <= #s do
		local _, next_p, width = decode(s, p)
		if remaining < width then return p - 1 end
		remaining, p = remaining - width, next_p
	end
	return #s
end

function M.length(s)
	return M.byte_to_units(s, #(s or ""))
end

return M

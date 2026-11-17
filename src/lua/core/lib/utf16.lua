-- UTF-8 byte offsets and UTF-16 code-unit positions, for controls that keep UTF-8 text
-- but report positions as the Win32 EDIT control does.
-- A byte offset is 0-based and always a character boundary; a unit position is 0-based too.
-- Invalid UTF-8 never raises: every byte that is not part of a well-formed sequence
-- (overlong forms, surrogates, values above U+10FFFF, stray continuation bytes, truncated
-- sequences) is one character of one unit. A character outside the BMP is two units.
-- @module core.lib.utf16
local byte, find = string.byte, string.find

local M = {}

--- The byte length and UTF-16 unit count of the character that starts at byte index i
-- (1-based, i <= #s).
local function step(s, i)
	local b = byte(s, i)
	if b < 0xC2 or b > 0xF4 then return 1, 1 end -- ASCII, a stray continuation byte, C0/C1, F5..FF
	local b2 = byte(s, i + 1)
	if not b2 or b2 < 0x80 or b2 > 0xBF then return 1, 1 end
	if b < 0xE0 then return 2, 1 end
	if b == 0xE0 and b2 < 0xA0 then return 1, 1 end -- overlong
	if b == 0xED and b2 > 0x9F then return 1, 1 end -- a UTF-16 surrogate
	if b == 0xF0 and b2 < 0x90 then return 1, 1 end -- overlong
	if b == 0xF4 and b2 > 0x8F then return 1, 1 end -- above U+10FFFF
	local b3 = byte(s, i + 2)
	if not b3 or b3 < 0x80 or b3 > 0xBF then return 1, 1 end
	if b < 0xF0 then return 3, 1 end
	local b4 = byte(s, i + 3)
	if not b4 or b4 < 0x80 or b4 > 0xBF then return 1, 1 end
	return 4, 2
end
M.step = step

--- True when the string has no byte >= 0x80 (a position in it is the same in both units).
function M.is_ascii(s) return not find(s, "[\128-\255]") end

--- UTF-16 units in the first b bytes of s. A b inside a character counts only the whole
-- characters before it.
function M.to_units(s, b)
	if b <= 0 then return 0 end
	if b > #s then b = #s end
	local i, u = 1, 0
	while i <= b do
		local j = find(s, "[\128-\255]", i)
		if not j or j > b then return u + (b - i + 1) end
		u = u + (j - i)
		i = j
		local n, k = step(s, i)
		if i + n - 1 > b then return u end
		u = u + k
		i = i + n
	end
	return u
end

--- UTF-16 units in the whole string.
function M.units(s) return M.to_units(s, #s) end

--- The byte offset after the first u units of s, clamped to 0 and #s. A u that falls
-- between the two units of a surrogate pair gives the byte offset of the pair's start
-- (the caret and selection can sit at a pair's edges only).
function M.to_bytes(s, u)
	if u <= 0 then return 0 end
	local len = #s
	local i, c = 1, 0 -- next byte index, units passed
	while i <= len and c < u do
		local j = find(s, "[\128-\255]", i) or len + 1
		local run = j - i
		if c + run >= u then return i - 1 + (u - c) end
		c = c + run
		i = j
		if i > len then break end
		local n, k = step(s, i)
		if c + k > u then return i - 1 end
		c = c + k
		i = i + n
	end
	return i - 1
end

--- The nearest character boundary at or before byte offset b.
function M.snap(s, b)
	if b <= 0 then return 0 end
	if b >= #s then return #s end
	local c = byte(s, b + 1)
	if c >= 0x80 and c < 0xC0 then
		for back = 1, 3 do
			local j = b + 1 - back
			if j < 1 then break end
			c = byte(s, j)
			if c < 0x80 or c >= 0xC0 then
				if c >= 0xC2 and c <= 0xF4 then
					local n = step(s, j)
					if n > 1 and j + n - 1 >= b + 1 then return j - 1 end
				end
				break
			end
		end
	end
	return b
end

--- The character boundary before byte offset b (b is a boundary).
function M.prev(s, b)
	if b <= 0 then return 0 end
	if b > #s then b = #s end
	local c = byte(s, b)
	if c >= 0x80 and c < 0xC0 then
		for back = 1, 3 do
			local j = b - back
			if j < 1 then break end
			c = byte(s, j)
			if c < 0x80 or c >= 0xC0 then
				if c >= 0xC2 and c <= 0xF4 then
					local n = step(s, j)
					if n > 1 and j + n - 1 == b then return j - 1 end
				end
				break
			end
		end
	end
	return b - 1
end

--- The character boundary after byte offset b (b is a boundary).
function M.next(s, b)
	if b < 0 then b = 0 end
	if b >= #s then return #s end
	return b + (step(s, b + 1))
end

-- Names the host UI code (CodeView, CommandPalette) used before the modules merged: they
-- take any value and fractional positions, as the old core.lib.utf16 did.
function M.byte_to_units(s, b) s = tostring(s or ""); return M.to_units(s, math.floor(b or 0)) end
function M.units_to_byte(s, u) s = tostring(s or ""); return M.to_bytes(s, math.floor(u or 0)) end
function M.length(s) return M.units(tostring(s or "")) end

return M

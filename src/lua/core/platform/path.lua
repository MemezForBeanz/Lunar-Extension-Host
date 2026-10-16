--- Path helpers for one operating system's rules.
--
-- `core.platform` exposes the instance for the running OS as `platform.path`.
-- `path.new{ windows = bool }` builds either flavour, so both rule sets can be
-- tested on any machine.
--
-- Windows rules: `\` is the separator but `/` is accepted on input; names
-- compare case-insensitively; `C:\`, `\\server\share` and `\\?\` prefixes are
-- roots. POSIX rules: `/` only; case-sensitive.
--
-- @module core.platform.path

local M = {}

local Path = {}
Path.__index = Path

--- Build a path helper.
-- @tparam table opts `{ windows = boolean }`.
-- @treturn table A helper with `sep`, `join`, `normalize`, `dirname`,
--   `basename`, `is_absolute`, `same` and `split_ext`.
function M.new(opts)
	local windows = opts and opts.windows and true or false
	return setmetatable({
		windows = windows,
		sep = windows and "\\" or "/",
	}, Path)
end

-- Split `p` into its root prefix and the rest, and say what kind of root it is:
--   "abs"       C:\  \\server\share\  /       (a fixed place)
--   "extended"  \\?\C:\  \\?\UNC\server\share\  (Windows passes these through verbatim)
--   "drive"     C:        (relative to that drive's current folder)
--   "rooted"    \         (root of the current drive)
--   ""          relative
function Path:_root(p)
	if not self.windows then
		if p:sub(1, 1) == "/" then return "/", p:sub(2), "abs" end
		return "", p, ""
	end
	local r = p:match("^[\\/][\\/][%?%.][\\/][Uu][Nn][Cc][\\/][^\\/]+[\\/][^\\/]+[\\/]?")
		or p:match("^[\\/][\\/][%?%.][\\/]%a:[\\/]?")
		or p:match("^[\\/][\\/][%?%.][\\/][^\\/]+[\\/]?")
	if r then return r, p:sub(#r + 1), "extended" end
	r = p:match("^[\\/][\\/][^\\/]+[\\/][^\\/]+[\\/]?")
	if r then return r, p:sub(#r + 1), "abs" end
	r = p:match("^%a:[\\/]")
	if r then return r, p:sub(#r + 1), "abs" end
	r = p:match("^%a:")
	if r then return r, p:sub(#r + 1), "drive" end
	r = p:match("^[\\/]")
	if r then return r, p:sub(2), "rooted" end
	return "", p, ""
end

--- Is `p` absolute (names one fixed place)?
-- On Windows, `C:foo` (drive-relative) and `\foo` (current drive's root) are
-- not absolute.
-- @tparam string p
-- @treturn boolean
function Path:is_absolute(p)
	local _, _, kind = self:_root(p)
	return kind == "abs" or kind == "extended"
end

--- Clean a path: native separators, no repeated separators, no `.` segments,
-- `..` resolved where it can be (kept when there is nothing to resolve it
-- against, e.g. `..\x` or `C:..\x`). The root is never touched.
--
-- Extended-length paths (`\\?\...`) are returned unchanged: Windows itself does
-- no `.`/`..` processing on them, so neither do we.
-- @tparam string p
-- @treturn string
function Path:normalize(p)
	if type(p) ~= "string" or p == "" then return p end
	local root, rest, kind = self:_root(p)
	if kind == "extended" then return p end
	local parts = {}
	for seg in rest:gmatch(self.windows and "[^\\/]+" or "[^/]+") do
		if seg == ".." then
			if #parts > 0 and parts[#parts] ~= ".." then
				parts[#parts] = nil
			elseif kind == "" or kind == "drive" then
				parts[#parts + 1] = ".."  -- nothing to resolve it against: keep it
			end                          -- above an absolute root: drop it
		elseif seg ~= "." then
			parts[#parts + 1] = seg
		end
	end
	if self.windows then root = root:gsub("/", "\\") end
	if #parts > 0 and root ~= "" and kind ~= "drive" and root:sub(-1) ~= self.sep then
		root = root .. self.sep
	end
	local out = root .. table.concat(parts, self.sep)
	if out == "" then return "." end
	return out
end

-- Does `p` end in a separator? (Only "/" counts on POSIX, where "\" is a name character.)
function Path:_ends_sep(p)
	if self.windows then return p:match("[\\/]$") ~= nil end
	return p:sub(-1) == "/"
end

-- The drive letter prefix ("C:") of a Windows path, if it has one.
local function drive_of(p)
	return p:match("^(%a:)")
end

--- Join segments, then normalize. An absolute segment restarts the path. On
-- Windows, a drive-relative segment (`D:x`) restarts it unless it names the
-- same drive, and a rooted segment (`\x`) keeps the current drive.
-- @tparam string ... Segments; nil and "" are skipped.
-- @treturn string
function Path:join(...)
	local out = ""
	for i = 1, select("#", ...) do
		local seg = select(i, ...)
		if seg ~= nil and seg ~= "" then
			seg = tostring(seg)
			local _, seg_rest, kind = self:_root(seg)
			if out == "" or kind == "abs" or kind == "extended" then
				out = seg
			elseif kind == "drive" then
				local d = drive_of(out)
				if d and d:lower() == seg:sub(1, 2):lower() then
					out = out .. (self:_ends_sep(out) and "" or self.sep) .. seg_rest
				else
					out = seg
				end
			elseif kind == "rooted" then
				out = (drive_of(out) or "") .. seg
			elseif self:_ends_sep(out) or (self.windows and out:match("^%a:$")) then
				out = out .. seg
			else
				out = out .. self.sep .. seg
			end
		end
	end
	return self:normalize(out)
end
--- The folder part of `p` (`"."` when there is none).
-- @tparam string p
-- @treturn string
function Path:dirname(p)
	p = self:normalize(p)
	local root, rest = self:_root(p)
	local dir = rest:match(self.windows and "^(.*)[\\/][^\\/]*$" or "^(.*)/[^/]*$")
	if dir then return root .. dir end
	if root ~= "" then return root end
	return "."
end

--- The last component of `p`.
-- @tparam string p
-- @treturn string
function Path:basename(p)
	p = self:normalize(p)
	local _, rest = self:_root(p)
	return rest:match(self.windows and "([^\\/]*)$" or "([^/]*)$") or ""
end

--- Split `p` into the part before its extension and the extension (with dot).
-- @tparam string p
-- @treturn string
-- @treturn string Extension such as `".lua"`, or `""`.
function Path:split_ext(p)
	local base = self:basename(p)
	local ext = base:match("^.+(%.[^.]+)$") or ""
	return p:sub(1, #p - #ext), ext
end

--- Do two paths name the same location (after normalizing; case-insensitive
-- on Windows)?
-- @tparam string a
-- @tparam string b
-- @treturn boolean
function Path:same(a, b)
	if type(a) ~= "string" or type(b) ~= "string" then return false end
	a, b = self:normalize(a), self:normalize(b)
	if self.windows then return a:lower() == b:lower() end
	return a == b
end

return M

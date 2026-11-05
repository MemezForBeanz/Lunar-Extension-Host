--- `file:` URIs and file paths, both ways.
--
-- Servers disagree about how a Windows path is spelled (`file:///C:/x`,
-- `file:///c%3A/x`), so anything that compares two URIs goes through `key`.
--
-- @module core.lsp.Uri
local M = {}

local WINDOWS = package.config:sub(1, 1) == "\\"

local function encode(text)
	return (text:gsub("([^A-Za-z0-9%-%._~/])", function(ch)
		return string.format("%%%02X", string.byte(ch))
	end))
end

local function decode(text)
	return (text:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

--- A `file:` URI for an absolute path.
-- @tparam string path
-- @tparam[opt] boolean windows treat `path` as a Windows path (default: this platform)
-- @treturn string
function M.fromPath(path, windows)
	if windows == nil then windows = WINDOWS end
	if not windows then return "file://" .. encode(path) end
	path = path:gsub("\\", "/")
	local server, share_path = path:match("^//([^/]+)(/.*)$")
	if server then return "file://" .. encode(server) .. encode(share_path) end
	local drive, rest = path:match("^(%a):(.*)$")
	if drive then
		if rest:sub(1, 1) ~= "/" then rest = "/" .. rest end
		return "file:///" .. drive:upper() .. ":" .. encode(rest)
	end
	if path:sub(1, 1) ~= "/" then path = "/" .. path end
	return "file://" .. encode(path)
end

--- The path a `file:` URI names, or nil when it is not a file URI.
-- @tparam string uri
-- @tparam[opt] boolean windows produce a Windows path (default: this platform)
-- @treturn string|nil
function M.toPath(uri, windows)
	if type(uri) ~= "string" then return nil end
	if windows == nil then windows = WINDOWS end
	local authority, path = uri:match("^[Ff][Ii][Ll][Ee]://([^/]*)(/.*)$")
	if not authority then return nil end
	path = decode(path:gsub("[?#].*$", ""))
	authority = decode(authority)
	if not windows then return path end
	if authority ~= "" and authority:lower() ~= "localhost" then
		return "\\\\" .. authority .. path:gsub("/", "\\")
	end
	local drive, rest = path:match("^/(%a):(.*)$")
	if drive then return drive:upper() .. ":" .. (rest == "" and "\\" or rest:gsub("/", "\\")) end
	return (path:gsub("/", "\\"))
end

--- A value equal for every spelling of the same file.
-- @tparam string uri
-- @treturn string
function M.key(uri, windows)
	if windows == nil then windows = WINDOWS end
	local path = M.toPath(uri, windows)
	if not path then return tostring(uri) end
	if windows then return path:lower() end
	return path
end

--- The last path segment, for display.
function M.basename(uri)
	local path = M.toPath(uri) or tostring(uri)
	return path:match("([^/\\]+)[/\\]*$") or path
end

return M

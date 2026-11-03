--- Read an administrator-provisioned token file; never include tokens in errors.
-- @module core.lib.HttpTokens
local ffi = require("ffi")
local M = {}

function M.validateAttributes(attr, uid)
	if not attr or attr.mode ~= "file" then return nil, "tokens file must be a regular file" end
	if attr.uid ~= 0 and attr.uid ~= uid then return nil, "tokens file must be owned by root or the running user" end
	if attr.permissions ~= "rw-------" and attr.permissions ~= "rw-r-----" then
		return nil, "tokens file permissions must be 0600 or 0640"
	end
	return true
end

function M.parse(text)
	local tokens, names, count = {}, {}, 0
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if line:match("%S") then
			local name, token = line:match("^%s*([%w_.-]+)%s+(%S+)%s*$")
			if not name or #token > 4096 or token:find("%c") then return nil, "invalid tokens file line" end
			if tokens[token] or names[name] then return nil, "duplicate token or token name" end
			tokens[token], names[name], count = name, true, count + 1
		end
	end
	if count == 0 then return nil, "tokens file is empty" end
	return tokens
end

function M.load(path)
	if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then return nil, "tokens file path required" end
	local text
	if ffi.os == "Windows" then
		local f, err = io.open(path, "rb")
		if not f then return nil, err end
		text = f:read(65537) or ""
		f:close()
	else
		-- One declaration per pcall: core.platform.posix declares open/read/close
		-- too, and LuaJIT refuses to redefine a C symbol.
		for _, decl in ipairs({ "int open(const char *, int, ...);", "int close(int);",
			"long read(int, void *, unsigned long);", "unsigned int getuid(void);" }) do
			pcall(ffi.cdef, decl)
		end
		-- O_NOFOLLOW and O_NONBLOCK: refuse symlinks and never hang on a FIFO.
		local flags = ffi.os == "Linux" and (131072 + 2048 + 524288) or (256 + 4)
		local fd = ffi.C.open(path, flags)
		if fd < 0 then return nil, "cannot open tokens file " .. path end
		local attr = require("lfs").attributes((ffi.os == "Linux" and "/proc/self/fd/" or "/dev/fd/") .. fd)
		local ok, err = M.validateAttributes(attr, tonumber(ffi.C.getuid()))
		if not ok then ffi.C.close(fd) return nil, path .. ": " .. tostring(err) end
		local buffer, chunks, size = ffi.new("char[4096]"), {}, 0
		while size <= 65536 do
			local n = tonumber(ffi.C.read(fd, buffer, 4096))
			if n < 0 then ffi.C.close(fd) return nil, "cannot read tokens file " .. path end
			if n == 0 then break end
			size = size + n
			chunks[#chunks + 1] = ffi.string(buffer, n)
		end
		ffi.C.close(fd)
		text = table.concat(chunks)
	end
	if #text > 65536 then return nil, "tokens file exceeds 64 KiB" end
	return M.parse(text)
end

return M

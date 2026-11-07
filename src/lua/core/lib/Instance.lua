--- One running copy per user, and a way for a second launch to talk to it.
--
-- The first process takes a name. A later launch finds the name taken, sends one line
-- to the holder and exits, so the Lunar shortcut brings a hidden window back instead of
-- starting a second app. The desktop app and the background service each hold their own
-- name, so either can run without the other.
--
-- Windows uses a mutex and a named pipe; POSIX uses a socket in the user's runtime
-- folder, whose successful bind is the claim. Both are polled from a timer: nothing
-- here starts a thread, so messages arrive on the UI or event loop like any other work.
--
-- Names include a hash of the settings folder, so a test run or a second profile with
-- its own folder is a separate app.
--
-- @module core.lib.Instance

local ok_ffi, ffi = pcall(require, "ffi")

local M = {}

local MAX_LINE = 4096

--- A stable, filename-safe key for a scope such as a settings folder (FNV-1a).
-- @tparam string text
-- @treturn string eight hex digits
function M.key(text)
	local hash = 2166136261
	for i = 1, #text do
		hash = bit.bxor(hash, text:byte(i))
		hash = (hash * 16777619) % 4294967296
	end
	return string.format("%08x", hash % 4294967296)
end

--- Split what a connection delivered into lines, dropping blanks and overlong ones.
-- @tparam string text
-- @treturn table lines
function M.lines(text)
	local out = {}
	for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		if line ~= "" and #line <= MAX_LINE then out[#out + 1] = line end
	end
	return out
end

-- Windows -----------------------------------------------------------------------

local win = {}

local ERROR_ALREADY_EXISTS = 183
local ERROR_PIPE_CONNECTED = 535
local ERROR_NO_DATA = 232
local GENERIC_WRITE = 0x40000000
local OPEN_EXISTING = 3
local PIPE_ACCESS_INBOUND = 1
local PIPE_NOWAIT = 1
local INVALID_HANDLE = ffi and ffi.cast("void*", -1)
local ASFW_ANY = 0xFFFFFFFF

function win.declare()
	pcall(ffi.cdef, [[
		void* CreateMutexW(void*, int, const unsigned short*);
		void* CreateNamedPipeW(const unsigned short*, unsigned long, unsigned long, unsigned long,
			unsigned long, unsigned long, unsigned long, void*);
		int ConnectNamedPipe(void*, void*);
		int DisconnectNamedPipe(void*);
		int ReadFile(void*, void*, unsigned long, unsigned long*, void*);
		int WriteFile(void*, const void*, unsigned long, unsigned long*, void*);
		void* CreateFileW(const unsigned short*, unsigned long, unsigned long, void*, unsigned long,
			unsigned long, void*);
		int CloseHandle(void*);
		unsigned long GetLastError(void);
		int MultiByteToWideChar(unsigned int, unsigned long, const char*, int, unsigned short*, int);
	]])
	pcall(ffi.cdef, "int AllowSetForegroundWindow(unsigned long);")
end

local function widen(text)
	local size = ffi.C.MultiByteToWideChar(65001, 0, text, -1, nil, 0)
	local out = ffi.new("unsigned short[?]", size)
	ffi.C.MultiByteToWideChar(65001, 0, text, -1, out, size)
	return out
end

function win.pipe_name(name)
	return "\\\\.\\pipe\\lunar-" .. name
end

function win.make_pipe(name)
	local handle = ffi.C.CreateNamedPipeW(widen(win.pipe_name(name)), PIPE_ACCESS_INBOUND, PIPE_NOWAIT, 1,
		MAX_LINE, MAX_LINE, 0, nil)
	if handle == INVALID_HANDLE then return nil end
	return handle
end

function win.acquire(name)
	win.declare()
	local mutex = ffi.C.CreateMutexW(nil, 0, widen("Local\\lunar-" .. name))
	if mutex == nil then return nil, "the instance lock could not be created" end
	if ffi.C.GetLastError() == ERROR_ALREADY_EXISTS then
		ffi.C.CloseHandle(mutex)
		return false
	end
	return { mutex = mutex, pipe = win.make_pipe(name), name = name }
end

function win.poll(state)
	if not state.pipe then
		state.pipe = win.make_pipe(state.name)
		if not state.pipe then return "" end
	end
	-- With PIPE_NOWAIT this returns at once, and success only means "now listening". A client
	-- shows as ERROR_PIPE_CONNECTED, or as ERROR_NO_DATA if it wrote and left between polls,
	-- which is the usual case: its line is still in the pipe.
	if ffi.C.ConnectNamedPipe(state.pipe, nil) ~= 0 then return "" end
	local why = ffi.C.GetLastError()
	if why ~= ERROR_PIPE_CONNECTED and why ~= ERROR_NO_DATA then return "" end
	local buffer, count = ffi.new("char[?]", MAX_LINE), ffi.new("unsigned long[1]")
	local parts = {}
	for _ = 1, 16 do
		if ffi.C.ReadFile(state.pipe, buffer, MAX_LINE, count, nil) == 0 or count[0] == 0 then break end
		parts[#parts + 1] = ffi.string(buffer, count[0])
	end
	ffi.C.DisconnectNamedPipe(state.pipe)
	return table.concat(parts)
end

function win.send(name, line)
	win.declare()
	local pipe = ffi.C.CreateFileW(widen(win.pipe_name(name)), GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, nil)
	if pipe == INVALID_HANDLE then return nil, "no running copy answered" end
	pcall(function()
		-- Windows only lets the foreground process hand the foreground on. This launch has it,
		-- the holder is about to want it.
		ffi.load("user32").AllowSetForegroundWindow(ASFW_ANY)
	end)
	local data, count = line .. "\n", ffi.new("unsigned long[1]")
	local wrote = ffi.C.WriteFile(pipe, data, #data, count, nil)
	ffi.C.CloseHandle(pipe)
	if wrote == 0 then return nil, "the running copy did not take the message" end
	return true
end

function win.release(state)
	if state.pipe then ffi.C.CloseHandle(state.pipe) end
	if state.mutex then ffi.C.CloseHandle(state.mutex) end
	state.pipe, state.mutex = nil, nil
end

-- POSIX -------------------------------------------------------------------------

local posix = {}

local AF_UNIX = 1
local SOCK_STREAM = 1
local F_SETFL = 4
local O_NONBLOCK = ffi and (ffi.os == "Linux" and 2048 or 4)
local SUN_PATH = 104

function posix.declare()
	for _, decl in ipairs({
		"int socket(int, int, int);", "int bind(int, const void *, unsigned int);", "int listen(int, int);",
		"int accept(int, void *, void *);", "int connect(int, const void *, unsigned int);",
		"int fcntl(int, int, ...);", "int close(int);", "long read(int, void *, unsigned long);",
		"long write(int, const void *, unsigned long);", "int unlink(const char *);",
	}) do
		pcall(ffi.cdef, decl)
	end
end

function posix.address(path)
	local size = 2 + #path + 1
	local address = ffi.new("char[?]", SUN_PATH + 2)
	if ffi.os == "Linux" then
		ffi.cast("unsigned short*", address)[0] = AF_UNIX
	else
		address[0], address[1] = size, AF_UNIX
	end
	ffi.copy(address + 2, path)
	return address, size
end

function posix.path(name)
	local dir = os.getenv("XDG_RUNTIME_DIR") or os.getenv("TMPDIR") or "/tmp"
	local uid = 0
	pcall(function()
		pcall(ffi.cdef, "unsigned int getuid(void);")
		uid = tonumber(ffi.C.getuid())
	end)
	return string.format("%s/lunar-%d-%s.sock", dir, uid, name)
end

function posix.dial(path)
	local fd = ffi.C.socket(AF_UNIX, SOCK_STREAM, 0)
	if fd < 0 then return nil end
	local address, size = posix.address(path)
	if ffi.C.connect(fd, address, size) ~= 0 then
		ffi.C.close(fd)
		return nil
	end
	return fd
end

function posix.acquire(name)
	posix.declare()
	local path = posix.path(name)
	if #path >= SUN_PATH then return nil, "the runtime folder path is too long" end
	local held = posix.dial(path)
	if held then
		ffi.C.close(held)
		return false
	end
	ffi.C.unlink(path)   -- nobody answered, so a crash left it behind
	local fd = ffi.C.socket(AF_UNIX, SOCK_STREAM, 0)
	if fd < 0 then return nil, "the instance socket could not be created" end
	local address, size = posix.address(path)
	if ffi.C.bind(fd, address, size) ~= 0 or ffi.C.listen(fd, 4) ~= 0 then
		ffi.C.close(fd)
		return false     -- another launch won the race between the dial and the bind
	end
	ffi.C.fcntl(fd, F_SETFL, ffi.cast("int", O_NONBLOCK))
	return { fd = fd, path = path }
end

function posix.poll(state)
	local client = ffi.C.accept(state.fd, nil, nil)
	if client < 0 then return "" end
	local buffer = ffi.new("char[?]", MAX_LINE)
	local count = tonumber(ffi.C.read(client, buffer, MAX_LINE))
	ffi.C.close(client)
	return count > 0 and ffi.string(buffer, count) or ""
end

function posix.send(name, line)
	posix.declare()
	local fd = posix.dial(posix.path(name))
	if not fd then return nil, "no running copy answered" end
	local data = line .. "\n"
	local wrote = tonumber(ffi.C.write(fd, data, #data))
	ffi.C.close(fd)
	if wrote ~= #data then return nil, "the running copy did not take the message" end
	return true
end

function posix.release(state)
	if state.fd then
		ffi.C.close(state.fd)
		ffi.C.unlink(state.path)
	end
	state.fd = nil
end

local function backend()
	if not ok_ffi then return nil end
	return ffi.os == "Windows" and win or posix
end

-- Public ------------------------------------------------------------------------

local Instance = {}
Instance.__index = Instance

--- Try to become the running copy.
-- @tparam string name letters, digits and dashes: `"app-" .. M.key(folder)`
-- @treturn[1] table an instance with `poll()` and `release()`
-- @treturn[2] boolean false when another copy holds the name
-- @treturn[3] nil
-- @treturn[3] string why it could not tell; the caller should carry on alone
function M.acquire(name)
	local impl = backend()
	if not impl then return nil, "this build has no FFI" end
	local state, err = impl.acquire(name)
	if not state then return state, err end
	return setmetatable({ impl = impl, state = state }, Instance)
end

--- Send one line to the running copy.
-- @tparam string name
-- @tparam string line
-- @treturn[1] boolean true
-- @treturn[2] nil
-- @treturn[2] string why
function M.send(name, line)
	local impl = backend()
	if not impl then return nil, "this build has no FFI" end
	return impl.send(name, line)
end

--- Lines that arrived since the last call. Never blocks.
-- @treturn table lines
function Instance:poll()
	return M.lines(self.impl.poll(self.state))
end

--- Give the name up.
function Instance:release()
	self.impl.release(self.state)
end

return M

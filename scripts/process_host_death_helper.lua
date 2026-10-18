-- Spawn a hanging engine and expose its grandchild pid to process_check.lua.
local socket = require("socket")
local process = require("process")
io.stdout:setvbuf("no")
if arg[3] == "sigchld" then
	local ffi = require("ffi")
	ffi.cdef([[ void *signal(int sig, void *handler); ]])
	ffi.C.signal(17, ffi.cast("void *", 1))  -- Linux SIGCHLD, SIG_IGN
	local child = assert(process.spawn{ argv = { arg[1], "-c", "import sys; sys.exit(23)" } })
	local deadline = socket.gettime() + 5
	local code
	repeat
		code = child:poll()
		if code == nil then socket.sleep(0.01) end
	until code ~= nil or socket.gettime() > deadline
	print("EXIT_CODE=" .. tostring(code))
	child:close()
	return
end
if arg[3] == "sigusr1" then
	local ffi = require("ffi")
	ffi.cdef([[ void *signal(int sig, void *handler); ]])
	local handler = ffi.cast("void (*)(int)", function() end)
	ffi.C.signal(10, ffi.cast("void *", handler))  -- Linux SIGUSR1, caught
	local child = assert(process.spawn{ argv = { arg[1], "-c",
		"import signal; print(int(signal.getsignal(signal.SIGUSR1) == signal.SIG_DFL))" } })
	local buffer = ""
	local deadline = socket.gettime() + 5
	while socket.gettime() < deadline do
		local chunk = child:read("stdout")
		if chunk and chunk ~= "" then buffer = buffer .. chunk end
		if child:poll() ~= nil then break end
		socket.sleep(0.01)
	end
	print("CHILD_SIGUSR1_DEFAULT=" .. (buffer:match("(%d)") or "unknown"))
	child:close()
	return
end
local child = assert(process.spawn{ argv = { arg[1], "-u", arg[2], "hang" } })
local buffer = ""
local deadline = socket.gettime() + 5
while socket.gettime() < deadline do
	local chunk = child:read("stdout")
	if chunk and chunk ~= "" then
		buffer = buffer .. chunk
		local pid = buffer:match('"pid"%s*:%s*(%d+)')
		if pid then
			if arg[3] == "stop_supervisor" then
				local ffi = require("ffi")
				ffi.cdef([[ int kill(int pid, int sig); ]])
				local status = assert(io.open("/proc/" .. child:pid() .. "/status"))
				local parent = tonumber(assert(status:read("*a")):match("PPid:%s*(%d+)"))
				status:close()
				assert(parent and ffi.C.kill(parent, 19) == 0)  -- Linux SIGSTOP
			end
			print("GRANDCHILD_PID=" .. pid)
			while true do socket.sleep(1) end
		end
	end
	socket.sleep(0.01)
end
error("engine did not report grandchild pid")

-- scripts/process_check.lua -- end-to-end check of the native `process` module
-- and core.lib.ProcessJob against a real child (spec/fixtures/fake_engine.py).
--
-- busted can't reach the native module (it lives in the exe), so this runs in
-- the CLI host, which preloads the same native modules the app has:
--
--   LUA_PATH="src/lua/?.lua;;" build/linux/bin/lunar-cli
--     scripts/process_check.lua /usr/bin/python3
--
-- Exits non-zero if any case fails.

local ffi = require("ffi")
local bit = require("bit")
local socket = require("socket")
local platform = require("core.platform")
local lfs = require("lfs")
local process = require("process")
local ProcessJob = require("core.lib.ProcessJob")

local python = arg[1] or "python"
local repo = os.getenv("LUNAR_REPO") or lfs.currentdir()
if not platform.path:is_absolute(repo) then repo = platform.path:join(lfs.currentdir(), repo) end
local engine = platform.path:join(repo, "spec", "fixtures", "fake_engine.py")
local helper = platform.path:join(repo, "scripts", "process_host_death_helper.lua")
local cli = arg[-1]
if not platform.path:is_absolute(cli) then cli = platform.path:join(lfs.currentdir(), cli) end

if platform.is_windows then
	ffi.cdef([[
		void* OpenProcess(unsigned long access, int inherit, unsigned long pid);
		unsigned long WaitForSingleObject(void* h, unsigned long ms);
		int CloseHandle(void* h);
	]])
else
	ffi.cdef([[
		int kill(int pid, int sig);
		int getpid(void);
		int symlink(const char *target, const char *linkpath);
		int unlink(const char *path);
	]])
end

local function proc_info(pid)
	local f = io.open("/proc/" .. tostring(pid) .. "/status")
	if not f then return nil end
	local status = f:read("*a")
	f:close()
	return status and {
		state = status:match("State:%s*(%a)"),
		parent = tonumber(status:match("PPid:%s*(%d+)")),
		ignored = status:match("SigIgn:%s*([%da-fA-F]+)"),
	}
end

local function read_until(p, pattern, seconds)
	local output, found = "", nil
	local deadline = socket.gettime() + seconds
	while socket.gettime() < deadline and not found do
		local chunk = p:read("stdout")
		if chunk and chunk ~= "" then
			output = output .. chunk
			found = output:match(pattern)
		end
		if not found then socket.sleep(0.01) end
	end
	return found, output
end

local function wait_gone(pids, seconds)
	local deadline = socket.gettime() + seconds
	while socket.gettime() < deadline do
		local remaining = {}
		for _, pid in ipairs(pids) do
			local info = proc_info(pid)
			if info then remaining[#remaining + 1] = pid .. ":" .. tostring(info.state) end
		end
		if #remaining == 0 then return true, "" end
		socket.sleep(0.02)
	end
	local remaining = {}
	for _, pid in ipairs(pids) do
		local info = proc_info(pid)
		if info then remaining[#remaining + 1] = pid .. ":" .. tostring(info.state) end
	end
	return #remaining == 0, table.concat(remaining, ",")
end

-- Is `pid` still running? (A process we can't open has gone.)
local function alive(pid)
	if not platform.is_windows then
		if ffi.C.kill(pid, 0) ~= 0 then return false end
		-- A reparented zombie is dead even if this container's init has not reaped it.
		local f = io.open("/proc/" .. pid .. "/stat")
		if f then
			local stat = f:read("*a")
			f:close()
			if stat and stat:match("%)%s+Z%s") then return false end
		end
		return true
	end
	local h = ffi.C.OpenProcess(0x00100000, 0, pid)  -- SYNCHRONIZE
	if h == nil or h == ffi.NULL then return false end
	local running = ffi.C.WaitForSingleObject(h, 0) == 0x102  -- WAIT_TIMEOUT
	ffi.C.CloseHandle(h)
	return running
end

local failures = 0
local function check(name, cond, detail)
	print(string.format("[%s] %s%s", cond and "PASS" or "FAIL", name, cond and "" or ("  -- " .. tostring(detail))))
	if not cond then failures = failures + 1 end
end

-- Run one job to completion with a 50 ms pump, as the UI timer would.
local function run(mode, extra, during)
	local events, stderr = {}, 0
	local opts = {
		argv = { python, "-u", engine, mode },
		on_event = function(e) events[#events + 1] = e end,
		on_stderr = function() stderr = stderr + 1 end,
	}
	for k, v in pairs(extra or {}) do opts[k] = v end
	local job = assert(ProcessJob.start(opts))
	local t0 = socket.gettime()
	while job:pump() do
		if during then during(job, events) end
		if socket.gettime() - t0 > 30 then job:cancel() end
		socket.sleep(0.05)
	end
	return job:result(), events, stderr, socket.gettime() - t0
end

-- 1. Streaming progress with stderr flooding alongside.
do
	local res, events, stderr = run("ok")
	check("ok: status", res.status == "ok", res.summary)
	check("ok: 50 progress events + result", #events == 51, #events)
	check("ok: stderr lines kept out of the protocol", stderr == 50 and res.protocol_errors == 0,
		stderr .. " stderr, " .. res.protocol_errors .. " protocol errors")
end

-- 2. Quoting: spaces, embedded quotes, trailing backslashes, empty arg; cwd for the child only.
do
	local tricky = { "plain", "with space", 'say "hi"', "C:\\dir with space\\", "", "back\\\\slash", "%PATH%" }
	local argv = { python, "-u", engine, "args" }
	for _, a in ipairs(tricky) do argv[#argv + 1] = a end
	local host_cwd = lfs.currentdir()
	local tmp = platform.temp_dir()
	local res = run("args", { argv = argv, cwd = tmp })
	local got = res.result and res.result.data and res.result.data.argv or {}
	local same = #got == #tricky
	for i = 1, #tricky do same = same and got[i] == tricky[i] end
	check("args: round-trip exactly", same, table.concat(got, " | "))
	local got_cwd = res.result and res.result.data.cwd
	local same_cwd = got_cwd and (platform.is_windows and got_cwd:lower() == tmp:lower() or got_cwd == tmp)
	check("args: child ran in cwd", same_cwd, got_cwd)
	check("args: host cwd unchanged", lfs.currentdir() == host_cwd)
end

-- 3. Secrets through stdin and env (and env removal).
do
	local res = run("secrets", {
		stdin = "hunter2\n",
		env = { FAKE_TOKEN = "tok-123", FAKE_REMOVED = false },
	})
	local d = res.result and res.result.data or {}
	check("secrets: stdin delivered", d.stdin == "hunter2", d.stdin)
	check("secrets: env set", d.env == "tok-123", d.env)
	-- JSON null decodes to cjson.null, not nil.
	check("secrets: env removal", d.removed == nil or d.removed == require("cjson").null, d.removed)
end

-- 3b. Large stdin to a child that never reads it must not block the host.
do
	local res, _, _, secs = run("ignore_stdin", { stdin = string.rep("x", 8 * 1024 * 1024) })
	check("stdin: unread input doesn't block", res.status == "ok" and secs < 10, res.status .. " in " .. secs .. "s")
end

-- 4. Crash: non-zero exit, traceback kept from stderr.
do
	local res = run("crash")
	check("crash: failed", res.status == "failed" and res.exit_code ~= 0, res.status .. " " .. tostring(res.exit_code))
	check("crash: traceback in stderr tail", res.stderr_tail:find("boom in the engine", 1, true) ~= nil)
end

-- 5. Exit 0 without a result is not success.
do
	local res = run("noresult")
	check("noresult: failed", res.status == "failed" and res.exit_code == 0, res.summary)
end

-- 6. Oversized line skipped, the rest still parsed.
do
	local res, events = run("big")
	check("big: ok", res.status == "ok", res.summary)
	check("big: oversized line rejected once", res.protocol_errors == 1, res.protocol_errors)
	check("big: 2000 logs + result", #events == 2001, #events)
end

-- 7. A line arriving in pieces.
do
	local res = run("slow")
	check("slow: reassembled", res.status == "ok" and res.summary == "slow done", res.summary)
end

-- 8. Cancel kills the whole tree, grandchild included.
do
	local grandchild
	local res, _, _, secs = run("hang", nil, function(job, events)
		for _, e in ipairs(events) do
			if e.pid and not grandchild then
				grandchild = e.pid
				job:cancel()
			end
		end
	end)
	socket.sleep(0.5)
	check("hang: cancelled", res.status == "cancelled", res.status)
	check("hang: finished promptly", secs < 10, secs)
	check("hang: grandchild killed", grandchild and not alive(grandchild), grandchild)
end

-- 9. Spawn failure is an error, not a crash.
do
	local missing = platform.path:join(platform.temp_dir(), "lunar-definitely-not-here-executable")
	local job, err = ProcessJob.start({ argv = { missing } })
	local reported = platform.is_windows and err and err:find("CreateProcess", 1, true)
		or err and (err:find("executable:", 1, true) or err:find("execve:", 1, true))
	check("spawn failure reported", job == nil and reported, err)
end

-- 10. A bad working directory fails during spawn, not during poll.
if not platform.is_windows then
	local bad_cwd = platform.path:join(platform.temp_dir(), "lunar-definitely-not-here-directory")
	local p, err = process.spawn{ argv = { python, "-c", "pass" }, cwd = bad_cwd }
	check("bad cwd reported synchronously", p == nil and err and err:find("chdir:", 1, true), err)
end

-- 11. A normally exited process can be killed and closed safely.
do
	local p = assert(process.spawn{ argv = { python, "-c", "print('done')" } })
	local code
	local deadline = socket.gettime() + 5
	repeat code = p:poll(); if code == nil then socket.sleep(0.01) end until code ~= nil or socket.gettime() > deadline
	local killed = p:kill(47)
	local after = p:poll()
	p:close()
	p:close()
	check("terminate after exit: original status", code == 0 and after == 0 and killed, tostring(code) .. "/" .. tostring(after))
	check("close twice: host survives", true)
end

if not platform.is_windows then
	-- 12. Only standard fds survive exec.
	local res = run("fds")
	local fds = res.result and res.result.data.fds or {}
	check("fds: only 0,1,2", #fds == 3 and fds[1] == 0 and fds[2] == 1 and fds[3] == 2,
		table.concat(fds, ","))

	-- 13. An unrequested signal is reported as 128 + signal number.
	local signal_res = run("signal")
	check("signal exit: SIGTERM is 143", signal_res.exit_code == 143, signal_res.exit_code)

	-- 14. SIGKILL of the host helper closes its lifeline and kills its tree.
	local host = assert(process.spawn{ argv = { cli, helper, python, engine } })
	local output, grandchild = "", nil
	local deadline = socket.gettime() + 5
	while socket.gettime() < deadline and not grandchild do
		local chunk = host:read("stdout")
		if chunk and chunk ~= "" then output = output .. chunk; grandchild = tonumber(output:match("GRANDCHILD_PID=(%d+)")) end
		socket.sleep(0.01)
	end
	local helper_pid = host:pid()
	if grandchild then ffi.C.kill(helper_pid, 9) end
	deadline = socket.gettime() + 2
	while grandchild and alive(grandchild) and socket.gettime() < deadline do socket.sleep(0.02) end
	check("host death: grandchild pid reported", grandchild ~= nil, output)
	check("host death: grandchild killed within 2 s", grandchild and not alive(grandchild), grandchild)
	host:close()

	-- 15. An unexpectedly killed supervisor cannot leave its child group running.
	local abandoned = assert(process.spawn{ argv = { python, "-u", engine, "hang" } })
	local abandoned_child = abandoned:pid()
	local abandoned_supervisor = proc_info(abandoned_child)
	abandoned_supervisor = abandoned_supervisor and abandoned_supervisor.parent
	local abandoned_grandchild_text = read_until(abandoned, '"pid"%s*:%s*(%d+)', 5)
	local abandoned_grandchild = tonumber(abandoned_grandchild_text)
	if abandoned_supervisor then ffi.C.kill(abandoned_supervisor, 9) end
	abandoned:close()
	local abandoned_deadline = socket.gettime() + 2
	while abandoned_grandchild and (alive(abandoned_child) or alive(abandoned_grandchild))
		and socket.gettime() < abandoned_deadline do socket.sleep(0.02) end
	local abandoned_gone = abandoned_grandchild and not alive(abandoned_child) and not alive(abandoned_grandchild)
	check("supervisor death: child and grandchild ended by close", abandoned_gone,
		tostring(abandoned_child) .. "/" .. tostring(abandoned_grandchild))
	local abandoned_kill = assert(process.spawn{ argv = { "/usr/bin/sleep", "5" } })
	local kill_child = abandoned_kill:pid()
	local kill_info = proc_info(kill_child)
	if kill_info and kill_info.parent then ffi.C.kill(kill_info.parent, 9) end
	socket.sleep(0.05)
	local killed = abandoned_kill:kill(47)
	local kill_deadline = socket.gettime() + 2
	while alive(kill_child) and socket.gettime() < kill_deadline do socket.sleep(0.02) end
	check("supervisor death: kill ends child group", killed and not alive(kill_child), kill_child)
	abandoned_kill:close()

	-- 16. Each supervisor must reap its entire tree before close returns.
	local jobs, descendants = {}, {}
	local complete = true
	for _ = 1, 16 do
		local p = assert(process.spawn{ argv = { python, "-u", engine, "hang" } })
		jobs[#jobs + 1] = p
		local pid = p:pid()
		local info = proc_info(pid)
		local job_grandchild_text = read_until(p, '"pid"%s*:%s*(%d+)', 5)
		local job_grandchild = tonumber(job_grandchild_text)
		if not info or not info.parent or not job_grandchild then complete = false end
		descendants[#descendants + 1] = pid
		if info and info.parent then descendants[#descendants + 1] = info.parent end
		if job_grandchild then descendants[#descendants + 1] = job_grandchild end
	end
	for _, p in ipairs(jobs) do p:close() end
	local gone, remaining = wait_gone(descendants, 5)
	check("close 16 jobs: all recorded descendants reaped", complete and gone,
		remaining ~= "" and remaining or "missing descendant pid")

	-- 17. A host that ignores SIGCHLD still receives the child's exit code.
	local ignored_host = assert(process.spawn{ argv = { cli, helper, python, engine, "sigchld" } })
	local ignored_code, ignored_output = read_until(ignored_host, "EXIT_CODE=([%w]+)", 5)
	check("SIGCHLD ignored by host: real exit code", ignored_code == "23", ignored_output)
	ignored_host:close()
	local already_exited = assert(process.spawn{ argv = { python, "-c", "import sys; sys.exit(23)" } })
	socket.sleep(0.2)  -- Let the supervisor record the exit without a host poll.
	local late_kill = already_exited:kill(47)
	local late_code = already_exited:poll()
	check("kill after supervisor recorded exit: real status", late_kill and late_code == 23, late_code)
	already_exited:close()

	-- 18. A non-Python executable must start with SIGPIPE at its default disposition.
	local sleeper = assert(process.spawn{ argv = { "/usr/bin/sleep", "5" } })
	local sleeper_info = proc_info(sleeper:pid())
	local ignored_mask = sleeper_info and sleeper_info.ignored
	local sigpipe_ignored = ignored_mask and bit.band(tonumber(ignored_mask:sub(-8), 16), 0x1000) ~= 0
	check("child SIGPIPE disposition is default", ignored_mask and not sigpipe_ignored, ignored_mask)
	sleeper:close()

	-- 19. Slash-containing relative argv[0] resolves before the child changes cwd.
	local original_cwd = lfs.currentdir()
	local temp = platform.path:join(platform.temp_dir(), "lunar-relative-" .. tostring(ffi.C.getpid()))
	local made = lfs.mkdir(temp)
	local relative_path = platform.path:join(temp, "relative")
	local target = platform.path:is_absolute(python) and python or "/usr/bin/python3"
	local linked = made and ffi.C.symlink(target, relative_path) == 0
	local relative, relative_err, relative_output, relative_code
	if linked and lfs.chdir(temp) then
		relative, relative_err = process.spawn{ argv = { "./relative", "-c", "print('relative-ok')" }, cwd = repo }
		lfs.chdir(original_cwd)
		if relative then
			local relative_deadline = socket.gettime() + 5
			repeat
				relative_code = relative:poll()
				local chunk = relative:read("stdout")
				if chunk then relative_output = (relative_output or "") .. chunk end
				if relative_code == nil then socket.sleep(0.01) end
			until relative_code ~= nil or socket.gettime() > relative_deadline
			relative:close()
		end
	else
		lfs.chdir(original_cwd)
	end
	check("relative executable resolves from host cwd", relative_code == 0 and
		relative_output and relative_output:find("relative-ok", 1, true), relative_err or relative_output)
	if linked then ffi.C.unlink(relative_path) end
	if made then lfs.rmdir(temp) end

	-- 20. A stopped supervisor must wake on host death and close must be bounded.
	local stopped = assert(process.spawn{ argv = { python, "-u", engine, "hang" } })
	local stopped_child = stopped:pid()
	local stopped_info = proc_info(stopped_child)
	local stopped_grandchild = tonumber((read_until(stopped, '"pid"%s*:%s*(%d+)', 5)))
	local stopped_supervisor = stopped_info and stopped_info.parent
	local stopped_ok = stopped_supervisor and ffi.C.kill(stopped_supervisor, 19) == 0
	local close_start = socket.gettime()
	stopped:close()
	local close_elapsed = socket.gettime() - close_start
	local stopped_gone = wait_gone({ stopped_child, stopped_grandchild or 0 }, 2)
	check("stopped supervisor: close bounded and child gone",
		stopped_ok and stopped_grandchild and close_elapsed < 5 and stopped_gone,
		tostring(close_elapsed) .. "s child=" .. tostring(stopped_child) .. " grandchild=" .. tostring(stopped_grandchild))

	-- 21. The nested helper stops its supervisor before the helper host is killed.
	local stopped_host = assert(process.spawn{ argv = { cli, helper, python, engine, "stop_supervisor" } })
	local stopped_host_grandchild = tonumber((read_until(stopped_host, "GRANDCHILD_PID=(%d+)", 5)))
	if stopped_host_grandchild then ffi.C.kill(stopped_host:pid(), 9) end
	local stop_death_deadline = socket.gettime() + 3
	while stopped_host_grandchild and alive(stopped_host_grandchild) and
		socket.gettime() < stop_death_deadline do socket.sleep(0.02) end
	check("stopped supervisor: host death kills child within 3 s",
		stopped_host_grandchild and not alive(stopped_host_grandchild), stopped_host_grandchild)
	stopped_host:close()

	-- 22. A setsid grandchild leaves the process group but remains a descendant.
	local escaped = assert(process.spawn{ argv = { python, "-u", "-c",
		"import os,time; p=os.fork(); os.setsid() if p == 0 else None; print(p if p else os.getpid(),flush=True) if p else None; time.sleep(30)" } })
	local escaped_pid = tonumber((read_until(escaped, "(%d+)", 5)))
	local escaped_start = socket.gettime()
	escaped:close()
	local escaped_elapsed = socket.gettime() - escaped_start
	local escaped_gone = wait_gone({ escaped_pid or 0 }, 2)
	check("setsid grandchild: close kills escapee within 5 s",
		escaped_pid and escaped_elapsed < 5 and escaped_gone,
		tostring(escaped_elapsed) .. "s pid=" .. tostring(escaped_pid))

	-- 23. Cancellation requests are coalesced and never fill a blocking pipe.
	local repeated = assert(process.spawn{ argv = { "/usr/bin/sleep", "30" } })
	local kill_start = socket.gettime()
	local all_kills = true
	for _ = 1, 100 do all_kills = repeated:kill(47) and all_kills end
	local kill_elapsed = socket.gettime() - kill_start
	repeated:close()
	check("kill 100 times: no blocking", all_kills and kill_elapsed < 1, kill_elapsed)

	-- 24. A caught host handler must not survive into exec.
	local signal_host = assert(process.spawn{ argv = { cli, helper, python, engine, "sigusr1" } })
	local sigusr1_default, signal_output = read_until(signal_host, "CHILD_SIGUSR1_DEFAULT=(%w+)", 5)
	check("caught host SIGUSR1: child disposition is default", sigusr1_default == "1", signal_output)
	signal_host:close()
end

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)

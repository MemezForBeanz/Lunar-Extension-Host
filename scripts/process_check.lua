-- scripts/process_check.lua -- end-to-end check of the native `process` module
-- and core.lib.ProcessJob against a real child (spec/fixtures/fake_engine.py).
--
-- busted can't reach the native module (it lives in the exe), so this runs in
-- the CLI host, which preloads the same native modules the app has:
--
--   $env:LUA_PATH = "src\lua\?.lua;;"
--   build\win\bin\LunarExtensionHostCLI.exe scripts\process_check.lua <python.exe>
--
-- Exits non-zero if any case fails.

local ffi = require("ffi")
local socket = require("socket")
local ProcessJob = require("core.lib.ProcessJob")

local python = arg[1] or "python"
local repo = os.getenv("LUNAR_REPO") or "."
local engine = repo .. "\\spec\\fixtures\\fake_engine.py"

ffi.cdef([[
	void* OpenProcess(unsigned long access, int inherit, unsigned long pid);
	unsigned long WaitForSingleObject(void* h, unsigned long ms);
	int CloseHandle(void* h);
]])

-- Is `pid` still running? (A process we can't open has gone.)
local function alive(pid)
	local h = ffi.C.OpenProcess(0x00100000, 0, pid)  -- SYNCHRONIZE
	if h == nil then return false end
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
	local host_cwd = require("lfs").currentdir()
	local tmp = os.getenv("TEMP")
	local res = run("args", { argv = argv, cwd = tmp })
	local got = res.result and res.result.data and res.result.data.argv or {}
	local same = #got == #tricky
	for i = 1, #tricky do same = same and got[i] == tricky[i] end
	check("args: round-trip exactly", same, table.concat(got, " | "))
	check("args: child ran in cwd", res.result and res.result.data.cwd:lower() == tmp:lower(), res.result and res.result.data.cwd)
	check("args: host cwd unchanged", require("lfs").currentdir() == host_cwd)
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
	local job, err = ProcessJob.start({ argv = { "C:\\definitely\\not\\here.exe" } })
	check("spawn failure reported", job == nil and err and err:find("CreateProcess", 1, true), err)
end

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)

-- spec/support/runtime_host.lua — busted helper: assert the test VM is the ship VM.
--
-- Loaded via the `helper` key in .busted, before any spec runs.
--
-- Lunar ships on LuaJIT 2.1 (Lua 5.1 ABI). The suite used to run on PUC-Lua 5.4
-- while the product ran on LuaJIT, which meant specs could pass against
-- semantics the application never sees: integer vs float division and `//`,
-- `math.type`, `string.format("%d", ...)` on non-integral numbers, error-message
-- wording, and `table.unpack` vs `unpack`. Worse, `ffi` does not exist on PUC-Lua
-- at all, so every FFI-backed module silently took its fallback path under test
-- and its real path was never exercised.
--
-- This check makes that class of drift impossible to reintroduce by accident:
-- if the runner is not LuaJIT, the suite refuses to run rather than reporting a
-- green result that means nothing.

local function fail(reason)
	io.stderr:write("\n[spec] Refusing to run: " .. reason .. "\n")
	io.stderr:write("[spec] Lunar tests must run on the same VM the app ships on (LuaJIT 2.1).\n")
	io.stderr:write("[spec] Restore the toolchain with scripts\\fetch-deps.ps1 -Dev and run scripts\\test.ps1.\n\n")
	os.exit(1)
end

if _VERSION ~= "Lua 5.1" then
	fail("interpreter reports " .. tostring(_VERSION) .. ", expected 'Lua 5.1'")
end

if type(jit) ~= "table" or type(jit.version) ~= "string" then
	fail("no LuaJIT `jit` table present (this looks like PUC-Lua 5.1, not LuaJIT)")
end

if not jit.version:match("^LuaJIT 2%.1") then
	fail("found " .. jit.version .. ", expected LuaJIT 2.1")
end

-- `ffi` is load-bearing in production (core.classes.IupFFI, logparser ffigrep).
-- If it is missing the host is not a usable stand-in for the shipped runtime.
local ok_ffi = pcall(require, "ffi")
if not ok_ffi then
	fail("LuaJIT is present but the `ffi` library failed to load")
end

-- .luacheckrc — static analysis config for the Lunar Lua codebase.
-- Runtime is LuaJIT 2.1 (Lua 5.1 ABI). Run via scripts\lint.ps1.

std = "luajit"

-- Directories that are not our source (vendored rocks, build artifacts, the
-- LuaJIT/Lua trees, packaged output). Nothing here should be linted.
exclude_files = {
	"vendor/",
	"build/",
	"dist/",
	"include/",
}

-- Globals injected by the C host at runtime (read-only from Lua's side):
--   iup            — IUP GUI toolkit table
--   subprocess     — process-spawn module bound in C
--   LUNAR_EXE_DIR  — absolute dir of the running executable, set by the host
read_globals = {
	"iup",
	"subprocess",
	"LUNAR_EXE_DIR",
	"LUNAR_EXE_PATH",
	"LUNAR_PID",
	"LUNAR_DEV_BUILD",  -- true in a local (CMake LUNAR_DEV_BUILD=ON) build
	"LUNAR_SOURCE_DIR", -- the repo folder, dev builds only
}

-- Quiet a few low-signal diagnostics so the baseline highlights real problems:
--   212 unused argument       — callbacks often ignore args
--   213 unused loop variable  — `for _, v in` idioms
--   631 line too long         — many report scripts format wide tables
--   431/432/421 for `self`    — IUPLua callbacks are defined as `function
--     control:cb()`, which idiomatically rebinds `self` to the control (the
--     outer object is captured separately, e.g. `local host = self`). The
--     name-scoped filters silence ONLY `self` shadowing, so genuine shadowing
--     of other upvalues/locals is still reported.
ignore = {
	"212",
	"213",
	"631",
	"431/self",
	"432/self",
	"421/self",
}

-- Per-area tuning.
files["scripts/"] = {
	-- CLI scripts legitimately read the global `arg` table (populated by the
	-- host / argparse) and print a lot; keep them lenient on unused locals.
	globals = { "arg" },
}

files["scripts/luarocks-config.lua"] = {
	-- Declarative LuaRocks config file: assigning config globals is its purpose.
	globals = { "external_deps_dirs" },
}

files["spec/"] = {
	-- busted defines these test DSL globals.
	std = "+busted",
}

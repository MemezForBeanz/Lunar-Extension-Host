package = "lunarextensionhost"
version = "dev-1"

-- `test_dependencies` (below) is a rockspec 3.0 field. Without this declaration
-- LuaRocks parses the file as format 1.0 and aborts with "Unknown field
-- test_dependencies", which made `luarocks install --only-deps` on this file
-- fail outright.
rockspec_format = "3.0"

source = {
   -- No public remote yet; update this URL when the repository is published.
   -- Only the `dependencies` table is needed to restore the local rock tree via
   -- `luarocks install --only-deps`, so `source` is a placeholder for now.
   url = "git+https://example.invalid/lunarextensionhost.git",
}

description = {
   summary  = "Lunar Extension Host: a lightweight, extension-based build/test queue tool.",
   detailed = [[
Development rockspec that pins the Lua dependencies used by the Lunar Extension Host
host and its plugins. It is not meant to be published; it exists so a fresh
checkout can rebuild the project-local rock tree (vendor/luarocks-tree/)
deterministically.

Restore the dependencies with:
  . .\scripts\lua-env.ps1
  scripts\fetch-deps.ps1

The LuaJIT interpreter, the IUP toolkit, and the MinGW toolchain are provided
outside of LuaRocks (see README.md, "Building from Source").
]],
   license  = "MIT",
}

-- Lunar runs LuaJIT 2.1 (Lua 5.1 ABI) for the shipped GUI *and* for lint/test, so
-- every rock here must resolve for 5.1. Do not relax this to a newer PUC-Lua:
-- a test tree on a different VM than the product ships on hides real behavioral
-- differences (integer division, %d formatting, error wording, no `ffi`).
dependencies = {
   "lua ~> 5.1",
   "luafilesystem >= 1.8.0",
   "luasocket 3.1.0-1",
   "middleclass 4.1.1-0",
   -- Pure-Lua libraries embedded into the exe and used by the dev/CLI scripts:
   "argparse 0.7.2-1",     -- declarative CLI parsing (scripts/cli_args.lua)
   "tableshape 2.7.0-1",   -- schema validation at JSON trust boundaries
   "date 2.2.1-2",         -- ISO-8601 timestamps for the logger/capsules
   "lualogging 1.8.2-1",   -- structured logging (core.lib.log)
   -- NOTE: `lua-cjson` is NOT listed here. luarocks.org has no 2.1devel rock for
   -- 5.1, and the rock must match the 2.1devel source CMake links into the exe,
   -- so scripts/fetch-deps.ps1 builds it from vendor/lua-cjson instead.
   -- NOTE: `serpent` (debug table dumps) is also required at runtime but cannot
   -- be installed from luarocks.org in this environment (git+SSL fetch fails).
   -- scripts/fetch-deps.ps1 curls serpent.lua into the tree instead.
}

-- Developer tooling: linter, test framework, and API documentation generator.
-- These are NOT needed to build or run the app, only to lint/test/document it,
-- so they live outside `dependencies` (a plain `--only-deps` restore skips
-- them). scripts/fetch-deps.ps1 -Dev installs them.
test_dependencies = {
   "luacheck 1.2.0-1",
   "busted 2.3.0-0",
   "ldoc 1.5.0-1",      -- API reference generator (scripts/docs.ps1, config.ld)
   "markdown 0.32-2",   -- ldoc's Markdown backend for doc comments and topics
}

-- Dependency-only rockspec: there is nothing to compile here. The C modules are
-- built by CMake (see CMakeLists.txt), not by LuaRocks.
build = {
   type = "none",
}

-- scripts/luarocks-config.lua - LuaRocks configuration for the Lunar dev toolchain.
--
-- Activated by scripts\lua-env.ps1, which points $env:LUAROCKS_CONFIG here.
--
-- The only thing this file exists to do is override `external_deps_dirs`.
-- LuaRocks' Windows default includes "c:\\windows\\system32", and when a rock
-- declares an external dependency that LuaRocks resolves there, it appends
-- `-Lc:\windows\system32` to the link line. MinGW's linker then resolves the C
-- runtime against the system32 msvcrt.dll instead of the mingw-w64 import libs,
-- and every C rock fails to link with:
--
--   undefined reference to `_execute_onexit_table'
--   undefined reference to `__acrt_iob_func'
--
-- luasocket is the rock that trips this in practice (mime.core / socket.core).
-- Restricting the search to the mingw64 prefix keeps the toolchain self-consistent.
--
-- Keep the mingw64 root in sync with $mingwBin in scripts\lua-env.ps1.
external_deps_dirs = {
	"C:\\msys64\\mingw64",
}

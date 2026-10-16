# vendor/

Third-party code Lunar builds against. There are two kinds.

## Tracked in Git

CMake compiles these into the executable. They are kept exactly as Lunar builds
them, so any local fix travels with the source.

| Folder | What | License |
|---|---|---|
| `luafilesystem/` | LuaFileSystem 1.8.0 | MIT |
| `lua-cjson/` | lua-cjson 2.1devel (the same source is built into the test tree by `scripts\fetch-deps.ps1`) | MIT |
| `luasocket/` | LuaSocket 3.0.0 | MIT |
| `luasec/` | LuaSec 1.3.2 (upstream commit 989ee5f; see `VENDOR-NOTES.txt`) | MIT |
| `copas/` | Copas 3.0.0 plus binaryheap, coxpcall and timerwheel (Lua only) | MIT |
| `nanosvg/` | NanoSVG parser and rasterizer headers | zlib |
| `certs/cacert.pem` | Mozilla's CA bundle (curl's extract, May 2026) | MPL 2.0 |
| `subprocess.h` | sheredom/subprocess.h with a local Windows argv-quoting fix (see the file) | public domain |

## Restored by `scripts\bootstrap.ps1`

Ignored by Git. Each comes from a pinned source and is checked against a SHA-256.

| Folder | What |
|---|---|
| `luajit/` | LuaJIT 2.1 at one pinned commit, built with MinGW: the static library the exe links, and the interpreter the tests and LuaRocks use |
| `iup/` | the official IUP 3.32 MinGW static libraries and headers the exe links (`libiup.a` itself is built from `iup-fork/` into `iup-src/`) |
| `openssl/` | OpenSSL, a trimmed static build (`scripts\build-openssl.ps1`) |
| `luarocks-*/`, `luarocks-tree/` | LuaRocks and the Lua rock tree (`scripts\fetch-deps.ps1`) |
| `iup-src/` | pristine IUP 3.32 source with `iup-fork/` patches applied (`scripts\build-iup-fork.ps1`, run by CMake) |
| `.downloads/` | the download cache |

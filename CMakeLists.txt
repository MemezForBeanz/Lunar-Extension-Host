cmake_minimum_required(VERSION 3.20)
project(Lunar C)
set(CMAKE_C_STANDARD 11)

# Export compile_commands.json for VS Code IntelliSense
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# The app version comes from APP_VERSION in main.lua (the one place it lives), for
# the Windows version resource and the Linux packages.
file(STRINGS ${CMAKE_SOURCE_DIR}/src/lua/core/main.lua LUNAR_VERSION_LINE
     REGEX "^local APP_VERSION = \"[0-9]+\\.[0-9]+\\.[0-9]+")
string(REGEX MATCH "([0-9]+)\\.([0-9]+)\\.([0-9]+)" LUNAR_VERSION "${LUNAR_VERSION_LINE}")
if(NOT LUNAR_VERSION)
    message(FATAL_ERROR "APP_VERSION not found in src/lua/core/main.lua")
endif()
set(LUNAR_VERSION_MAJOR ${CMAKE_MATCH_1})
set(LUNAR_VERSION_MINOR ${CMAKE_MATCH_2})
set(LUNAR_VERSION_PATCH ${CMAKE_MATCH_3})

# Place all executables in build/bin/
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
set(VENDOR   ${CMAKE_SOURCE_DIR}/vendor)
# LuaJIT 2.1 (Lua 5.1 ABI). LUA_SRC points at the LuaJIT headers so every target
# that includes ${LUA_SRC} compiles against the LuaJIT API. LUAJIT_LIB is the
# prebuilt static archive (libluajit-5.1.a) vendored under vendor/luajit/lib.
if(WIN32)
    set(LUA_SRC     ${VENDOR}/luajit/src)
    set(LUAJIT_LIB  ${VENDOR}/luajit/lib/libluajit-5.1.a)
else()
    set(LUNAR_LUAJIT_PREFIX /usr/local CACHE PATH "Prefix of the system LuaJIT 2.1 installation")
    set(LUA_SRC     ${LUNAR_LUAJIT_PREFIX}/include/luajit-2.1)
    set(LUAJIT_LIB  ${LUNAR_LUAJIT_PREFIX}/lib/libluajit-5.1.a)
endif()
set(IUP_DIR  ${VENDOR}/iup)
set(IM_DIR   ${VENDOR}/im)
set(NANOSVG_DIR ${VENDOR}/nanosvg)
set(LFS_SRC  ${VENDOR}/luafilesystem/src)
set(CJSON_SRC ${VENDOR}/lua-cjson)
set(LSOCK_SRC ${VENDOR}/luasocket/src)

# ---------------------------------------------------------------------------
# 1. LuaJIT 2.1 runtime (imported prebuilt static archive, Lua 5.1 ABI)
#    This is the project's *only* Lua: the GUI, the busted suite, luacheck and
#    ldoc all run on it. We import the prebuilt libluajit-5.1.a and expose the
#    LuaJIT headers via INTERFACE so consumers that link `lua_static` compile
#    against the same API the exe embeds.
# ---------------------------------------------------------------------------
add_library(lua_static STATIC IMPORTED GLOBAL)
set_target_properties(lua_static PROPERTIES
    IMPORTED_LOCATION             ${LUAJIT_LIB}
    INTERFACE_INCLUDE_DIRECTORIES ${LUA_SRC}
)

# ---------------------------------------------------------------------------
# 2. LuaFileSystem
# ---------------------------------------------------------------------------
add_library(lfs_static STATIC "${LFS_SRC}/lfs.c")
target_include_directories(lfs_static PRIVATE ${LUA_SRC})

# ---------------------------------------------------------------------------
# 3. lua-cjson
# ---------------------------------------------------------------------------
add_library(cjson_static STATIC
    "${CJSON_SRC}/lua_cjson.c"
    "${CJSON_SRC}/strbuf.c"
    "${CJSON_SRC}/fpconv.c"
    "${CJSON_SRC}/dtoa.c"
    "${CJSON_SRC}/g_fmt.c"
)
target_include_directories(cjson_static PRIVATE ${LUA_SRC} ${CJSON_SRC})
# LuaJIT provides luaL_setfuncs despite reporting LUA_VERSION_NUM 501; tell
# lua-cjson to skip its own 5.1 compat shim so it doesn't redefine it.
target_compile_definitions(cjson_static PRIVATE USE_LUAJIT)

# ---------------------------------------------------------------------------
# 4. LuaSocket core (platform socket transport; no unix/serial modules)
# ---------------------------------------------------------------------------
if(WIN32)
    set(LSOCK_PLATFORM_SOURCE "${LSOCK_SRC}/wsocket.c")
else()
    set(LSOCK_PLATFORM_SOURCE "${LSOCK_SRC}/usocket.c")
endif()
add_library(luasocket_static STATIC
    "${LSOCK_SRC}/luasocket.c"
    "${LSOCK_SRC}/timeout.c"
    "${LSOCK_SRC}/buffer.c"
    "${LSOCK_SRC}/io.c"
    "${LSOCK_SRC}/auxiliar.c"
    "${LSOCK_SRC}/options.c"
    "${LSOCK_SRC}/inet.c"
    "${LSOCK_SRC}/except.c"
    "${LSOCK_SRC}/select.c"
    "${LSOCK_SRC}/tcp.c"
    "${LSOCK_SRC}/udp.c"
    "${LSOCK_SRC}/mime.c"
    "${LSOCK_SRC}/compat.c"
    ${LSOCK_PLATFORM_SOURCE}
)
target_include_directories(luasocket_static PRIVATE ${LUA_SRC} ${LSOCK_SRC})
target_compile_definitions(luasocket_static PRIVATE LUASOCKET_API= NDEBUG)
if(WIN32)
    target_link_libraries(luasocket_static PRIVATE ws2_32)
endif()

# ---------------------------------------------------------------------------
# 4b. OpenSSL 3.6.1 (imported prebuilt static archives) + LuaSec 1.3.2
#     Static TLS transport for the backend client. OpenSSL is vendored under
#     vendor/openssl (libssl.a + libcrypto.a + headers, copied from the MSYS2
#     mingw64 toolchain). LuaSec's C core is compiled here and linked against
#     OpenSSL and our luasocket_static (LuaSec's bundled luasocket headers are
#     ABI-identical to vendor/luasocket, so struct layouts match at link time).
#     Private OpenSSL link deps on Windows: crypt32, gdi32, ws2_32.
# ---------------------------------------------------------------------------
set(LUASEC_SRC  ${VENDOR}/luasec/src)

if(WIN32)
set(OPENSSL_DIR ${VENDOR}/openssl)
add_library(openssl_crypto STATIC IMPORTED GLOBAL)
set_target_properties(openssl_crypto PROPERTIES
    IMPORTED_LOCATION             ${OPENSSL_DIR}/lib/libcrypto.a
    INTERFACE_INCLUDE_DIRECTORIES ${OPENSSL_DIR}/include
)
add_library(openssl_ssl STATIC IMPORTED GLOBAL)
set_target_properties(openssl_ssl PROPERTIES
    IMPORTED_LOCATION             ${OPENSSL_DIR}/lib/libssl.a
    INTERFACE_INCLUDE_DIRECTORIES ${OPENSSL_DIR}/include
)
else()
find_package(OpenSSL REQUIRED)
endif()
if(WIN32)
    set(LUASEC_OPENSSL_INCLUDE ${OPENSSL_DIR}/include)
else()
    set(LUASEC_OPENSSL_INCLUDE ${OPENSSL_INCLUDE_DIR})
endif()

# LuaSec C core (registers ssl.core/context/x509/config). Compiled against its
# bundled luasocket headers (LUASEC_SRC exposes the <luasocket/*.h> subdir the
# sources include) plus the OpenSSL headers. LSEC_API defaults to dllexport on
# Windows which is harmless for a static archive folded into the exe.
add_library(luasec_static STATIC
    "${LUASEC_SRC}/options.c"
    "${LUASEC_SRC}/x509.c"
    "${LUASEC_SRC}/context.c"
    "${LUASEC_SRC}/ssl.c"
    "${LUASEC_SRC}/config.c"
    "${LUASEC_SRC}/ec.c"
)
target_include_directories(luasec_static PRIVATE
    ${LUA_SRC}
    ${LUASEC_SRC}
    ${LUASEC_OPENSSL_INCLUDE}
)

# ---------------------------------------------------------------------------
# 5. CLI backend test harness (no IUP — pure console app)
# ---------------------------------------------------------------------------
if(WIN32)
    set(CLI_PLATFORM_SOURCES src/c/libs/subprocess_wrap.c src/c/platform/win32/process.c)
else()
    set(CLI_PLATFORM_SOURCES src/c/platform/posix/process.c)
endif()
add_executable(LunarCLI
    src/c/core/main_cli.c
    ${CLI_PLATFORM_SOURCES}
    src/c/libs/logscan.c
    src/c/libs/compositor/blend.c
    src/c/libs/compositor/compositor_lua.c
    src/c/libs/compositor/backend_none.c
)

if(NOT WIN32)
    set_target_properties(LunarCLI PROPERTIES OUTPUT_NAME lunar-cli)
endif()
target_include_directories(LunarCLI PRIVATE
    ${LUA_SRC}
    ${VENDOR}
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}/src
)

if(WIN32)
    set(CLI_OPENSSL_LIBS openssl_ssl openssl_crypto -lcrypt32 -lgdi32 -lws2_32)
else()
    set(CLI_OPENSSL_LIBS OpenSSL::SSL OpenSSL::Crypto -lm -ldl -pthread)
endif()
target_link_libraries(LunarCLI PRIVATE
    lua_static
    lfs_static
    cjson_static
    luasec_static
    luasocket_static
    ${CLI_OPENSSL_LIBS}
)

# -s drops the COFF symbol table and DWARF sections from the shipped binary.
# Release only, so debug builds stay debuggable.
if(WIN32)
    target_link_options(LunarCLI PRIVATE
        -static -static-libgcc
        $<$<CONFIG:Release>:-s>
    )
endif()


# ---------------------------------------------------------------------------
# 6. GUI executable (built separately — requires IUP)
# ---------------------------------------------------------------------------
find_package(Python3 REQUIRED COMPONENTS Interpreter)

# Collect all Lua module files for embedding and dependency tracking.
#
# CONFIGURE_DEPENDS so a NEW core module actually re-triggers the bundle, and a
# DELETED one does not leave a dangling dependency that stops the build. The
# bundle's own contents are always correct either way -- embed_lua.py rescans the
# directories -- but without this the rebuild is not triggered, so the embedded
# copy silently lags the source.
file(GLOB_RECURSE LUA_MODULE_FILES CONFIGURE_DEPENDS
    "${CMAKE_SOURCE_DIR}/src/lua/core/*.lua"
    "${CMAKE_SOURCE_DIR}/src/lua/installer/*.lua")
set(LUA_MAIN        "${CMAKE_SOURCE_DIR}/src/lua/core/main.lua")
set(LUA_MIDDLECLASS "${VENDOR}/luarocks-tree/share/lua/5.1/middleclass.lua")

# LuaSocket's C cores (socket.core/mime.core) are statically linked and preloaded
# in main.c, but its pure-Lua glue must also be embedded so require("socket.http")
# resolves at runtime (the vendor/ tree is not shipped next to the exe). Only the
# modules on the plain-HTTP path are needed; ssl.https is loaded lazily and unused.
set(LSOCK_LUA "${VENDOR}/luasocket/src")

# LuaSec's pure-Lua glue: ssl.lua registers the "ssl" module (over the ssl.core/
# context/x509/config C modules, which are statically linked + preloaded in
# main.c), and https.lua is the "ssl.https" transport BackendClient selects for
# https:// backends. Both are embedded so require() resolves them at runtime.
set(LUASEC_LUA "${VENDOR}/luasec/src")

# Pure-Lua LuaRocks dependencies embedded so require() resolves them at runtime
# without the vendor/ tree being shipped next to the exe. The tree is built for
# the Lua 5.1 (LuaJIT) ABI — the same runtime the exe embeds — so these are the
# exact files the app loads. Restore them into the local tree with:
#   scripts\fetch-deps.ps1
# (which also curls serpent.lua and builds cjson from vendor/lua-cjson).
# lualogging ships a base module plus per-appender submodules; only the
# file/console appenders are embedded (the socket/email/sql appenders pull
# optional deps we do not use).
set(LUAROCKS_SHARE "${VENDOR}/luarocks-tree/share/lua/5.1")

# copas (lunarmodules) + its pure-Lua deps (coxpcall, binaryheap, timerwheel).
# These provide the cooperative async transport extensions use (core.lib.async) so
# HTTP(S) I/O yields to the IUP main loop instead of blocking it. All are
# Lua 5.1-ABI compatible (LuaJIT-safe); copas 3.x avoids the luasystem C dep.
set(COPAS_LUA "${VENDOR}/copas")

add_custom_command(
    OUTPUT  ${CMAKE_SOURCE_DIR}/src/lua_bundle.h
    COMMAND ${Python3_EXECUTABLE}
            ${CMAKE_SOURCE_DIR}/scripts/embed_lua.py
            ${LUA_MAIN}
            ${CMAKE_SOURCE_DIR}/src/lua_bundle.h
            --scan  ${CMAKE_SOURCE_DIR}/src/lua  ${CMAKE_SOURCE_DIR}/src/lua/core/classes
            --scan  ${CMAKE_SOURCE_DIR}/src/lua  ${CMAKE_SOURCE_DIR}/src/lua/core/classes/host
            --scan  ${CMAKE_SOURCE_DIR}/src/lua  ${CMAKE_SOURCE_DIR}/src/lua/core/ui
            --scan  ${CMAKE_SOURCE_DIR}/src/lua  ${CMAKE_SOURCE_DIR}/src/lua/core/lib
            --scan  ${CMAKE_SOURCE_DIR}/src/lua  ${CMAKE_SOURCE_DIR}/src/lua/core/platform.lua
            --scan  ${CMAKE_SOURCE_DIR}/src/lua  ${CMAKE_SOURCE_DIR}/src/lua/core/platform
            --scan  ${CMAKE_SOURCE_DIR}/src/lua  ${CMAKE_SOURCE_DIR}/src/lua/installer
            --preload middleclass ${LUA_MIDDLECLASS}
            --preload socket ${LSOCK_LUA}/socket.lua
            --preload socket.url ${LSOCK_LUA}/url.lua
            --preload socket.headers ${LSOCK_LUA}/headers.lua
            --preload ltn12 ${LSOCK_LUA}/ltn12.lua
            --preload mime ${LSOCK_LUA}/mime.lua
            --preload socket.http ${LSOCK_LUA}/http.lua
            --preload ssl ${LUASEC_LUA}/ssl.lua
            --preload ssl.https ${LUASEC_LUA}/https.lua
            --preload coxpcall ${COPAS_LUA}/coxpcall.lua
            --preload binaryheap ${COPAS_LUA}/binaryheap.lua
            --preload timerwheel ${COPAS_LUA}/timerwheel.lua
            --preload copas ${COPAS_LUA}/copas.lua
            --preload copas.http ${COPAS_LUA}/copas/http.lua
            --preload argparse ${LUAROCKS_SHARE}/argparse.lua
            --preload tableshape ${LUAROCKS_SHARE}/tableshape/init.lua
            --preload serpent ${LUAROCKS_SHARE}/serpent.lua
            --preload date ${LUAROCKS_SHARE}/date.lua
            --preload logging ${LUAROCKS_SHARE}/logging.lua
            --preload logging.console ${LUAROCKS_SHARE}/logging/console.lua
            --preload logging.file ${LUAROCKS_SHARE}/logging/file.lua
            --preload logging.rolling_file ${LUAROCKS_SHARE}/logging/rolling_file.lua
    DEPENDS ${LUA_MAIN}
            ${CMAKE_SOURCE_DIR}/scripts/embed_lua.py
            ${LUA_MIDDLECLASS}
            ${LSOCK_LUA}/socket.lua
            ${LSOCK_LUA}/url.lua
            ${LSOCK_LUA}/headers.lua
            ${LSOCK_LUA}/ltn12.lua
            ${LSOCK_LUA}/mime.lua
            ${LSOCK_LUA}/http.lua
            ${LUASEC_LUA}/ssl.lua
            ${LUASEC_LUA}/https.lua
            ${COPAS_LUA}/coxpcall.lua
            ${COPAS_LUA}/binaryheap.lua
            ${COPAS_LUA}/timerwheel.lua
            ${COPAS_LUA}/copas.lua
            ${COPAS_LUA}/copas/http.lua
            ${LUAROCKS_SHARE}/argparse.lua
            ${LUAROCKS_SHARE}/tableshape/init.lua
            ${LUAROCKS_SHARE}/serpent.lua
            ${LUAROCKS_SHARE}/date.lua
            ${LUAROCKS_SHARE}/logging.lua
            ${LUAROCKS_SHARE}/logging/console.lua
            ${LUAROCKS_SHARE}/logging/file.lua
            ${LUAROCKS_SHARE}/logging/rolling_file.lua
            ${LUA_MODULE_FILES}
    COMMENT "Embedding main.lua + Lua modules into lua_bundle.h"
)
add_custom_target(embed_lua DEPENDS ${CMAKE_SOURCE_DIR}/src/lua_bundle.h)

# ---------------------------------------------------------------------------
# 6b. Embedded bitmaps
#     The window icon is decoded from PNG to raw RGBA at
#     build time and compiled in (see src/c/libs/appimages_wrap.c). Doing this
#     is what lets the exe drop the IM imaging library entirely -- iup.LoadImage
#     on startup bitmaps was IM's only caller, and IM costs ~1 MB of TIFF/EXIF/
#     JPEG/colour-space code plus a static libstdc++.
#     embed_images.py uses only the Python standard library (no Pillow).
# ---------------------------------------------------------------------------
set(EMBEDDED_IMAGES_H ${CMAKE_SOURCE_DIR}/src/embedded_images.h)
set(APP_IMAGE_ICON ${CMAKE_SOURCE_DIR}/assets/lunar-icon-32.png)

add_custom_command(
    OUTPUT  ${EMBEDDED_IMAGES_H}
    COMMAND ${Python3_EXECUTABLE}
            ${CMAKE_SOURCE_DIR}/scripts/embed_images.py
            ${EMBEDDED_IMAGES_H}
            lunar_icon_32=${APP_IMAGE_ICON}
    DEPENDS ${CMAKE_SOURCE_DIR}/scripts/embed_images.py
            ${APP_IMAGE_ICON}
    COMMENT "Embedding startup bitmaps into embedded_images.h"
)
add_custom_target(embed_images DEPENDS ${EMBEDDED_IMAGES_H})

# ---------------------------------------------------------------------------
# IUP fork: build the core libiup.a from vendored + patched source under
# vendor/iup-src (IUP 3.32 + Lunar gradient/rounded-corner/flat-scrollbar
# patches). Only the core archive is rebuilt from source; the satellite
# archives (controls/im/lua) remain the prebuilt 3.32 binaries and stay
# ABI-compatible because our patches are purely additive (new symbols, no
# signature changes). scripts/build-iup-fork.ps1 is incremental and only
# rewrites the archive when a source actually changed.
# ---------------------------------------------------------------------------
if(WIN32)
set(IUP_FORK_LIB ${CMAKE_SOURCE_DIR}/vendor/iup-src/build/libiup.a)
add_custom_target(iup_fork ALL
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass -File ${CMAKE_SOURCE_DIR}/scripts/build-iup-fork.ps1
    BYPRODUCTS ${IUP_FORK_LIB}
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Building IUP fork libiup.a from patched source (vendor/iup-src)"
    VERBATIM
    USES_TERMINAL
)

add_executable(Lunar WIN32
    src/c/core/main.c
    src/c/platform/win32/host.c
    src/c/libs/subprocess_wrap.c
    src/c/platform/win32/process.c
    src/c/libs/logscan.c
    src/c/libs/compositor/blend.c
    src/c/libs/compositor/compositor_lua.c
    src/c/libs/compositor/win32.c
    src/c/libs/winredraw_wrap.c
    src/c/libs/iupraw_wrap.c
    src/c/libs/themeapply_wrap.c
    src/c/libs/nanosvg_impl.c
    src/c/libs/svgicon_wrap.c
    src/c/libs/appimages_wrap.c
    assets/Lunar.rc
)
# The version resource reads its numbers from a generated header (a quoted string
# define doesn't survive the trip through CMake to windres intact).
configure_file(${CMAKE_SOURCE_DIR}/assets/lunar_version.h.in ${CMAKE_BINARY_DIR}/generated/lunar_version.h @ONLY)
set_source_files_properties(assets/Lunar.rc PROPERTIES
    INCLUDE_DIRECTORIES ${CMAKE_BINARY_DIR}/generated
    OBJECT_DEPENDS ${CMAKE_BINARY_DIR}/generated/lunar_version.h)
add_dependencies(Lunar embed_lua)
add_dependencies(Lunar embed_images)
add_dependencies(Lunar iup_fork)

# Export the host's symbols (including the statically-linked Lua API) so that
# loadable extension C modules (an extension's native/<name>.dll) can
# resolve lua_*/luaL_* from the executable at load time.
set_target_properties(Lunar PROPERTIES ENABLE_EXPORTS TRUE)

target_include_directories(Lunar PRIVATE
    ${LUA_SRC}
    ${IUP_DIR}/include
    ${NANOSVG_DIR}
    ${VENDOR}
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}/src
)

# IM (libim/libiupim/libimlua) is deliberately absent: its only caller was
# iup.LoadImage() for two small PNGs, which are now compiled in as raw RGBA by
# scripts/embed_images.py. Dropping it also removes the static libstdc++ and zlib
# it required (IM is C++), so those are gone from the link line too.
target_link_libraries(Lunar PRIVATE
    lua_static
    lfs_static
    cjson_static
    luasec_static
    luasocket_static
    openssl_ssl
    openssl_crypto
    ${IUP_DIR}/libiuplua51.a
    ${IUP_DIR}/libiupluacontrols51.a
    ${IUP_DIR}/libiupcontrols.a
    ${IUP_FORK_LIB}
    -luser32 -lgdi32 -lgdiplus -lcomdlg32 -lcomctl32
    -lole32 -loleaut32 -luuid
    -lws2_32 -lcrypt32
)

target_link_options(Lunar PRIVATE
    -static -static-libgcc
    $<$<CONFIG:Release>:-s>
    $<$<CONFIG:Release>:-Wl,--gc-sections>
)

# Emit one section per function/object so --gc-sections above can drop the ones
# nothing reaches. Only effective now that exports are limited to the .def list;
# --export-all-symbols made every symbol a GC root.
target_compile_options(Lunar PRIVATE
    $<$<CONFIG:Release>:-ffunction-sections>
    $<$<CONFIG:Release>:-fdata-sections>
)

# Export the host's Lua C API into the import library so plugin C modules
# (an extension's native .dll) can bind it at load time, and so LuaJIT FFI code in the app can
# resolve nsvg*/Iup* out of the running exe. src/Lunar.def names exactly
# those symbols; --export-all-symbols would instead export all ~13,600 globals in
# the binary (OpenSSL/IUP/LuaJIT internals) for 448 KB of .edata, and would also
# defeat --gc-sections by making every symbol a GC root.
#
# LUNAR_EXPORT_ALL_SYMBOLS=ON switches back to exporting everything. That mode
# exists for scripts/gen-exports.ps1, which has to link a binary in order to
# enumerate the symbols that belong in the .def -- it cannot use the .def itself
# without a chicken-and-egg problem. Do not ship a build made with it.
option(LUNAR_DEV_BUILD
    "Development build: prefer the repo's plugins/ folder and keep the default Lua module paths. Packaging (scripts/build.ps1) turns this OFF, which makes the host load code only from its own folder and trusted org packs."
    ON)
if(LUNAR_DEV_BUILD)
    # LUNAR_SOURCE_DIR: where the repo is, so a dev build loads plugins/ straight
    # from it whatever the build tree's depth (build/bin, build/win/bin, ...).
    target_compile_definitions(Lunar PRIVATE
        LUNAR_DEV_BUILD=1
        LUNAR_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
endif()

option(LUNAR_EXPORT_ALL_SYMBOLS
       "Export every global symbol instead of src/Lunar.def (harvest builds only)"
       OFF)

if(LUNAR_EXPORT_ALL_SYMBOLS)
    target_link_options(Lunar PRIVATE -Wl,--export-all-symbols)
else()
    target_link_options(Lunar PRIVATE
        "${CMAKE_SOURCE_DIR}/src/Lunar.def"
    )
    set_property(TARGET Lunar APPEND PROPERTY
        LINK_DEPENDS "${CMAKE_SOURCE_DIR}/src/Lunar.def"
    )
endif()

else()
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK3 REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(FONTCONFIG REQUIRED IMPORTED_TARGET fontconfig)

set(IUP_LINUX_BUILD ${CMAKE_SOURCE_DIR}/vendor/iup-src-linux/build)
set(IUP_LINUX_LIB ${IUP_LINUX_BUILD}/libiup.a)
set(IUP_LINUX_LUA_LIB ${IUP_LINUX_BUILD}/libiuplua51.a)
add_custom_target(iup_fork ALL
    COMMAND ${Python3_EXECUTABLE} -I ${CMAKE_SOURCE_DIR}/scripts/build_iup.py
            --luajit-prefix ${LUNAR_LUAJIT_PREFIX}
    BYPRODUCTS ${IUP_LINUX_LIB} ${IUP_LINUX_LUA_LIB}
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Building patched IUP and IupLua for GTK3"
    VERBATIM
    USES_TERMINAL
)

set(LUNAR_DYNAMIC_LIST ${CMAKE_BINARY_DIR}/lunar-dynamic.list)
set(LUNAR_UNDEFINED_RSP ${CMAKE_BINARY_DIR}/lunar-undefined.rsp)
add_custom_command(
    OUTPUT ${LUNAR_DYNAMIC_LIST} ${LUNAR_UNDEFINED_RSP}
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/scripts/gen_dynamic_list.py
        ${CMAKE_SOURCE_DIR}/src/Lunar.def
        ${LUNAR_DYNAMIC_LIST} ${LUNAR_UNDEFINED_RSP}
    DEPENDS ${CMAKE_SOURCE_DIR}/scripts/gen_dynamic_list.py
        ${CMAKE_SOURCE_DIR}/src/Lunar.def
    VERBATIM
)
add_custom_target(lunar_exports DEPENDS ${LUNAR_DYNAMIC_LIST} ${LUNAR_UNDEFINED_RSP})

add_executable(Lunar
    src/c/core/main.c
    src/c/platform/posix/host.c
    src/c/platform/posix/process.c
    src/c/libs/logscan.c
    src/c/libs/compositor/blend.c
    src/c/libs/compositor/compositor_lua.c
    src/c/libs/compositor/gtk.c
    src/c/libs/iupraw_wrap.c
    src/c/libs/themeapply_wrap.c
    src/c/libs/nanosvg_impl.c
    src/c/libs/svgicon_wrap.c
    src/c/libs/appimages_wrap.c
)
add_dependencies(Lunar embed_lua embed_images iup_fork lunar_exports)
# Linux convention: lowercase commands. The process still shows as "Lunar"
# (posix/host.c sets the process and window-class names at startup).
set_target_properties(Lunar PROPERTIES OUTPUT_NAME lunar)
target_include_directories(Lunar PRIVATE
    ${LUA_SRC}
    ${CMAKE_SOURCE_DIR}/vendor/iup-src-linux/iup/include
    ${NANOSVG_DIR}
    ${VENDOR}
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/src/c
)
target_link_libraries(Lunar PRIVATE
    lua_static lfs_static cjson_static luasec_static luasocket_static
    OpenSSL::SSL OpenSSL::Crypto
    ${IUP_LINUX_LUA_LIB} ${IUP_LINUX_LIB}
    PkgConfig::GTK3 X11 Xext PkgConfig::FONTCONFIG m dl pthread
)
target_link_options(Lunar PRIVATE
    "-Wl,--dynamic-list=${LUNAR_DYNAMIC_LIST}"
    "@${LUNAR_UNDEFINED_RSP}"
)
set_property(TARGET Lunar APPEND PROPERTY
    LINK_DEPENDS ${LUNAR_DYNAMIC_LIST} ${LUNAR_UNDEFINED_RSP})

option(LUNAR_DEV_BUILD
    "Development build: load the repo's plugins/ and keep default Lua module paths"
    ON)
if(LUNAR_DEV_BUILD)
    target_compile_definitions(Lunar PRIVATE
        LUNAR_DEV_BUILD=1
        LUNAR_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
endif()
endif()

# Mirror plugins/, lua/ tree, and assets/ into build/bin/ for development
# convenience (all Lua modules are also embedded — lua/ is for fallback/dev use).
#
# Each destination is removed first. `cmake -E copy_directory` only ever adds or
# overwrites, so without this a file deleted from source lingers in build\bin
# forever and gets picked up by the packager: that is how 51 obsolete raster
# icons under assets\Icons\generated\ and a removed `hello` example plugin were
# still shipping long after being deleted from the repo.
#
# This lives only in sync_runtime, not also in a POST_BUILD hook on the exe: a
# custom target's commands run on every build anyway, and having two writers
# racing to delete the same directories breaks parallel builds
# ("Error removing directory .../build/bin/lua" under -j 4).
#
# CONFIGURE_DEPENDS: re-run this glob at BUILD time and reconfigure when the file
# set changes. Without it the dependency list is frozen at configure time, so
# DELETING any file under plugins/, src/lua/ or assets/ breaks the build outright
# with "No rule to make target ...", and ADDING one silently fails to trigger the
# mirror until someone reconfigures by hand. Both have happened here (a stray
# native .dll, then a stray plugins/hello.lua).
file(GLOB_RECURSE RUNTIME_SYNC_FILES CONFIGURE_DEPENDS
    "${CMAKE_SOURCE_DIR}/plugins/*"
    "${CMAKE_SOURCE_DIR}/src/lua/*"
    "${CMAKE_SOURCE_DIR}/assets/*"
)
list(FILTER RUNTIME_SYNC_FILES EXCLUDE REGEX "\\.(dll|exe|o|obj|a|lib|pdb)$")
add_custom_target(sync_runtime ALL
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${CMAKE_BINARY_DIR}/bin/plugins
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${CMAKE_SOURCE_DIR}/plugins
        ${CMAKE_BINARY_DIR}/bin/plugins
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${CMAKE_BINARY_DIR}/bin/lua
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${CMAKE_SOURCE_DIR}/src/lua
        ${CMAKE_BINARY_DIR}/bin/lua
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${CMAKE_BINARY_DIR}/bin/assets
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${CMAKE_SOURCE_DIR}/assets
        ${CMAKE_BINARY_DIR}/bin/assets
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${CMAKE_BINARY_DIR}/bin/certs
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_SOURCE_DIR}/vendor/certs/cacert.pem
        ${CMAKE_BINARY_DIR}/bin/certs/cacert.pem
    DEPENDS ${RUNTIME_SYNC_FILES}
    COMMENT "Mirroring plugins/, lua/, and assets/ to build/bin/ (always current)"
)

# sync_runtime wipes and re-mirrors build/bin/{plugins,lua,assets,certs}. Every
# other target that reads or writes inside those directories must be ordered
# after it, or a parallel build can race the wipe:
#   * LunarCLI's harness scripts resolve lua/ and certs/ next to the exe.
add_dependencies(LunarCLI sync_runtime)

# A Linux release build ends with the install packages (scripts/package_linux.sh):
# dist/linux/Lunar-Setup-<version>-x86_64.run, lunar-extension-host_<version>_<arch>.deb and Lunar-<version>-x86_64.AppImage,
# each with the menu entry and icons. Dev builds skip it (the script refuses them).
if(NOT WIN32 AND NOT LUNAR_DEV_BUILD)
    add_custom_target(linux_packages ALL
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/package_linux.sh
                --build-dir ${CMAKE_BINARY_DIR} --out ${CMAKE_SOURCE_DIR}/dist/linux
        DEPENDS Lunar LunarCLI sync_runtime
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        COMMENT "Packaging the Linux setup (.run), .deb and AppImage into dist/linux"
        USES_TERMINAL
        VERBATIM)
endif()



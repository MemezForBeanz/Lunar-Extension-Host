/* nanosvg_impl.c
 *
 * Single translation unit that compiles the header-only NanoSVG parser and
 * rasterizer (vendor/nanosvg/{nanosvg,nanosvgrast}.h) into the host exe.
 *
 * NanoSVG ships as a "STB-style" single-header library: the declarations are
 * always visible, but the implementations only get compiled where the
 * NANOSVG_IMPLEMENTATION / NANOSVGRAST_IMPLEMENTATION macros are defined
 * before inclusion. This is that one place. Everywhere else in the codebase
 * that needs the declarations just includes the headers normally.
 *
 * Because LunarExtensionHost links with -Wl,--export-all-symbols, the resulting
 * nsvgParse/nsvgRasterize/etc. entry points are reachable from LuaJIT's FFI
 * (see src/lua/core/ui/VectorIcon.lua) without any additional Lua<->C glue
 * beyond the tiny image-handoff bridge in svgicon_wrap.c.
 */
#define NANOSVG_IMPLEMENTATION
#define NANOSVGRAST_IMPLEMENTATION

#include "nanosvg.h"
#include "nanosvgrast.h"

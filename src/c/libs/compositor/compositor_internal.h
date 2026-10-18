#ifndef LUNAR_COMPOSITOR_INTERNAL_H
#define LUNAR_COMPOSITOR_INTERNAL_H

/* Shared between the portable binding (compositor_lua.c) and the platform
 * backends (win32.c, backend_none.c, later gtk.c). Not a public header. */

#include <lua.h>
#include <stddef.h>
#include <stdint.h>
#include "blend.h"

/* Parse and validate the scene table at `idx` (absolute index). Pushes one
 * userdata holding the sprite array (keep it on the stack while rendering:
 * sprites point into snapshots the scene references) and returns the array.
 * Raises a Lua error on invalid input. */
BlendSprite *compositor_parse_scene(lua_State *L, int idx, int32_t *w, int32_t *h, size_t *count);

/* Push a new snapshot userdata of w x h and return its pixel buffer (premultiplied
 * BGRA8, stride w*4) for the caller to fill. Raises on bad sizes or no memory. */
uint8_t *compositor_new_snapshot(lua_State *L, int32_t w, int32_t h);

/* Called by luaopen_compositor with the module table on top of the stack: a
 * backend adds `supported()` and, when it has one, `overlay()`. */
void compositor_backend_register(lua_State *L);

#endif

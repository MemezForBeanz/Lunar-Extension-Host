/* Compositor backend for hosts without an overlay: the CLI, and Linux until the
 * GTK backend (proven by scripts/gtk_overlay_probe.lua) moves into C. Rendering
 * and snapshots-from-pixels still work; only on-screen overlays are missing. */

#include <lua.h>
#include "compositor_internal.h"

static int supported(lua_State *L)
{
    lua_pushboolean(L, 0);
    lua_pushliteral(L, "no compositor backend in this host");
    return 2;
}

void compositor_backend_register(lua_State *L)
{
    lua_pushcfunction(L, supported);
    lua_setfield(L, -2, "supported");
}

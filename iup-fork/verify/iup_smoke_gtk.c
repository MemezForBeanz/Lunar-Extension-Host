/* Linux IUP smoke test: GTK3 driver + LuaJIT IupLua + the Lunar fork attributes.
 *
 * Built by `python3 -I scripts/build_iup.py --smoke` into vendor/iup-src-linux/build/iup_smoke.
 * Opens a dialog with a rounded gradient flat button, a text field and tabs, prints the
 * IUP/GTK/LuaJIT versions, and closes itself after LUNAR_SMOKE_MS (default 3000) ms.
 */
#include <stdio.h>
#include <stdlib.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include "iup.h"
#include "iuplua.h"

static const char smoke_lua[] =
  "local iup = iup\n"
  "local ms = tonumber(os.getenv('LUNAR_SMOKE_MS')) or 3000\n"
  "if ms < 1 then ms = 3000 end\n"
  "local dlg = iup.dialog{\n"
  "  iup.vbox{\n"
  "    iup.flatbutton{title='Rounded', CORNERRADIUS='8',\n"
  "      GRADIENTCOLOR='0 120 255', BGCOLOR='40 40 40'},\n"
  "    iup.text{},\n"
  "    iup.tabs{\n"
  "      iup.vbox{iup.label{title='First tab'}, tabtitle='One'},\n"
  "      iup.vbox{iup.label{title='Second tab'}, tabtitle='Two'}\n"
  "    }\n"
  "  }, title='Lunar IUP smoke'\n"
  "}\n"
  "dlg:show()\n"
  "local timer = iup.timer{time=ms, action_cb=function(self)\n"
  "  self.run='NO'\n"
  "  return iup.CLOSE\n"
  "end}\n"
  "timer.run='YES'\n"
  "iup.MainLoop()\n";

int main(void)
{
  lua_State *L = luaL_newstate();
  const char *driver;
  const char *gtk_version;
  const char *jit_version;
  int status;

  if (!L) {
    fputs("Failed to create Lua state\n", stderr);
    return 1;
  }
  luaL_openlibs(L);
  status = iuplua_open(L);
  if (status != 0) {
    fprintf(stderr, "iuplua_open failed: %d\n", status);
    lua_close(L);
    return 1;
  }

  driver = IupGetGlobal("DRIVER");
  gtk_version = IupGetGlobal("GTKVERSION");
  lua_getglobal(L, "jit");
  lua_getfield(L, -1, "version");
  jit_version = lua_tostring(L, -1);
  printf("IUP version: %s\n", IupVersion());
  printf("DRIVER: %s\n", driver ? driver : "(null)");
  printf("GTKVERSION: %s\n", gtk_version ? gtk_version : "(null)");
  printf("jit.version: %s\n", jit_version ? jit_version : "(null)");
  fflush(stdout);
  lua_pop(L, 2);

  if (luaL_dostring(L, smoke_lua) != 0) {
    fprintf(stderr, "Smoke Lua error: %s\n", lua_tostring(L, -1));
    lua_close(L);
    return 1;
  }
  lua_close(L);
  return 0;
}

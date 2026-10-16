#ifndef SUBPROCESS_WRAP_H
#define SUBPROCESS_WRAP_H

#include <lua.h>

/* subprocess.start(cmdline, cwd)  -> handle | nil, errmsg
 * subprocess.poll(handle)         -> nil (running) | integer (exit_code)
 * subprocess.terminate(handle)    -> true | nil, errmsg
 * subprocess.destroy(handle)      -> (frees memory)
 */
int luaopen_subprocess(lua_State *L);

#endif /* SUBPROCESS_WRAP_H */

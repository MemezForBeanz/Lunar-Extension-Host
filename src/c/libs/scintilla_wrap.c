/*** IupScintilla for the host: opens the control and reaches the Scintilla
 * messages IUP has no attribute for.
 *
 * `require("sci")` registers the Scintilla control class and its Lua binding
 * (`iup.scintilla`) the first time it runs, so a session that never shows code
 * never creates the window class. The module it returns sends raw Scintilla
 * messages, which core.ui.CodeView needs for the handful of things IUP's
 * attributes do not cover: the drawing technology, the scrollbars, point and
 * position conversions, and indicator hover.
 *
 * Built only with LUNAR_SCINTILLA (see cmake/IupScintilla.cmake).
 *
 * @module sci
 */
#include <stdint.h>
#include <lua.h>
#include <lauxlib.h>
#include <iup.h>
#include <iuplua.h>

void IupScintillaOpen(void);
int iup_scintillalua_open(lua_State *L);
/* iup_scintilla.h declares this only after Scintilla.h; the types are these. */
intptr_t IupScintillaSendMessage(Ihandle *ih, unsigned int message, uintptr_t wparam, intptr_t lparam);

static Ihandle *check_mapped(lua_State *L)
{
    Ihandle *ih = iuplua_checkihandle(L, 1);
    /* An unmapped control has no window to send to. */
    if (!IupGetAttribute(ih, "WID")) luaL_error(L, "the code view is not mapped yet");
    return ih;
}

/*** Send a message whose arguments are numbers.
 * @function send
 * @param ih the `iup.scintilla` handle (it must be mapped)
 * @tparam integer message a `SCI_*` message number
 * @tparam[opt=0] integer wparam
 * @tparam[opt=0] integer lparam
 * @treturn integer the message's result
 */
static int l_send(lua_State *L)
{
    Ihandle *ih = check_mapped(L);
    unsigned int message = (unsigned int)luaL_checkinteger(L, 2);
    uintptr_t wparam = (uintptr_t)(intptr_t)luaL_optnumber(L, 3, 0);
    intptr_t lparam = (intptr_t)luaL_optnumber(L, 4, 0);
    lua_pushnumber(L, (lua_Number)IupScintillaSendMessage(ih, message, wparam, lparam));
    return 1;
}

/*** Send a message whose lparam is a string (a font name, a word list).
 * @function sends
 * @param ih
 * @tparam integer message
 * @tparam integer wparam
 * @tparam string text
 * @treturn integer
 */
static int l_sends(lua_State *L)
{
    Ihandle *ih = check_mapped(L);
    unsigned int message = (unsigned int)luaL_checkinteger(L, 2);
    uintptr_t wparam = (uintptr_t)(intptr_t)luaL_optnumber(L, 3, 0);
    const char *text = luaL_checkstring(L, 4);
    lua_pushnumber(L, (lua_Number)IupScintillaSendMessage(ih, message, wparam, (intptr_t)text));
    return 1;
}

static const luaL_Reg functions[] = {
    { "send",  l_send },
    { "sends", l_sends },
    { NULL, NULL }
};

int luaopen_sci(lua_State *L)
{
    /* The host opened IUP itself, so the binding will not open the control for
     * us (it only does that when it called IupOpen): do both here. */
    IupScintillaOpen();
    iup_scintillalua_open(L);
    lua_newtable(L);
    luaL_register(L, NULL, functions);
    return 1;
}

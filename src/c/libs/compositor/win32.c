/* Win32 compositor backend: one layered child window per dialog.
 *
 * The overlay is a WS_CHILD | WS_EX_LAYERED window over the dialog's client area
 * (layered child windows need Windows 8+ and the Windows 8 entry in the exe
 * manifest's compatibility section). Being a child, it moves, clips and
 * minimises with the dialog for free; this file follows size and DPI changes and
 * the dialog's destruction through a window subclass.
 *
 * Frames are rendered by the portable blend core straight into a top-down 32-bpp
 * DIB section (premultiplied BGRA, the memory layout UpdateLayeredWindow wants)
 * and shown with UpdateLayeredWindow(ULW_ALPHA). `fade` re-issues the last frame
 * with a different constant alpha and no re-render, so a full-window fade costs
 * one UpdateLayeredWindow call per frame.
 *
 * Input is decided by regions, not pixels: WM_NCHITTEST returns HTTRANSPARENT
 * (the click goes to the window beneath; it is in the same thread) outside
 * `block`/`action` regions. A click on an `action` region is queued with a copy
 * of its id and read by `events()`; no Lua runs inside the window procedure.
 * Fully transparent pixels are click-through regardless (layered-window rule),
 * so block/action regions lift zero-alpha pixels to premultiplied black at A=1.
 *
 * Lua (methods on the object `compositor.overlay(dialog)` returns):
 *   ov:present(scene, regions[, opacity])
 *                               render and show; regions = { {x,y,w,h,mode,id}, ... };
 *                               opacity 0..1 (default 1) is the whole layer's alpha
 *   ov:fade(alpha)              re-show the last frame at constant alpha 0..1
 *   ov:rect(widget)             a widget's rectangle in overlay pixels (x, y, w, h)
 *   ov:raise()                  restore the overlay's place above its siblings
 *   ov:hide()  ov:visible()  ov:geometry() -> {w,h,scale}  ov:events() -> {...}
 *   ov:snapshot([widget])       the dialog's client area (or a widget's part of
 *                               it) without the overlay, as a compositor snapshot
 *   ov:screen_pixel(x, y)       composed desktop colour at overlay point (r,g,b),
 *                               for probes and tests
 *   ov:close()                  idempotent; also __gc and the dialog's destruction
 */

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <commctrl.h>
#include <float.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <iup.h>
#include <iuplua.h>
#include "compositor_internal.h"

#define OVERLAY_MT "lunar.overlay"
#define MAX_EVENTS 64

#ifndef PW_RENDERFULLCONTENT
#define PW_RENDERFULLCONTENT 0x00000002
#endif

enum { MODE_PASS, MODE_BLOCK, MODE_ACTION };
enum { EV_ACTION, EV_RESIZE, EV_DPI };

typedef struct {
    int is_number;
    lua_Number number;
    char *string;               /* malloc'd copy when not a number */
    size_t length;
} RegionId;

typedef struct {
    int32_t x, y, w, h;
    int mode;
    RegionId id;
} Region;

typedef struct {
    int type;
    RegionId id;                /* EV_ACTION only; owned by the event */
    lua_Number generation;
} Event;

typedef struct {
    Region *regions;
    size_t count;
} StagedRegions;

typedef struct {
    HWND hwnd;                  /* the overlay */
    HWND parent;                /* the dialog */
    HDC memdc;
    HBITMAP dib, old_bitmap;
    void *bits;
    int32_t dib_w, dib_h;
    Region *regions;
    size_t nregions;
    Event events[MAX_EVENTS];
    int nevents;
    int event_oom;
    lua_Number generation;
    int shown;                  /* has a frame on screen */
    int has_frame;
    int stale;
    unsigned visibility_epoch;
    int subclassed;
    int closed;
} Overlay;

/* ---- ids ---------------------------------------------------------------- */

static void id_free(RegionId *id)
{
    free(id->string);
    id->string = NULL;
}

static int id_copy(RegionId *dst, const RegionId *src)
{
    *dst = *src;
    dst->string = NULL;
    if (!src->is_number && src->string) {
        dst->string = (char *)malloc(src->length ? src->length : 1u);
        if (!dst->string) return 0;
        memcpy(dst->string, src->string, src->length);
    }
    return 1;
}

static void id_push(lua_State *L, const RegionId *id)
{
    if (id->is_number) lua_pushnumber(L, id->number);
    else if (id->string) lua_pushlstring(L, id->string, id->length);
    else lua_pushnil(L);
}

/* ---- events ------------------------------------------------------------- */

static void push_event(Overlay *ov, int type, const RegionId *id)
{
    Event *e;
    if (ov->nevents >= MAX_EVENTS) return;     /* Lua isn't draining; drop the newest */
    e = &ov->events[ov->nevents];
    memset(e, 0, sizeof(*e));
    e->type = type;
    e->generation = ov->generation;
    if (id && !id_copy(&e->id, id)) { ov->event_oom = 1; return; }
    ov->nevents++;
}

static void clear_events(Overlay *ov)
{
    int i;
    for (i = 0; i < ov->nevents; ++i) id_free(&ov->events[i].id);
    ov->nevents = 0;
}

static void clear_regions(Overlay *ov)
{
    size_t i;
    for (i = 0; i < ov->nregions; ++i) id_free(&ov->regions[i].id);
    free(ov->regions);
    ov->regions = NULL;
    ov->nregions = 0;
}

static int staged_regions_gc(lua_State *L)
{
    StagedRegions *stage = (StagedRegions *)lua_touserdata(L, 1);
    size_t i;
    for (i = 0; i < stage->count; ++i) id_free(&stage->regions[i].id);
    free(stage->regions);
    stage->regions = NULL;
    stage->count = 0;
    return 0;
}

/* The topmost region under an overlay-client point (later regions are on top). */
static const Region *region_at(const Overlay *ov, int x, int y)
{
    size_t i = ov->nregions;
    while (i-- > 0) {
        const Region *r = &ov->regions[i];
        if (x >= r->x && y >= r->y && (int64_t)x < (int64_t)r->x + r->w &&
            (int64_t)y < (int64_t)r->y + r->h) return r;
    }
    return NULL;
}

/* ---- DPI ---------------------------------------------------------------- */

static double window_scale(HWND hwnd)
{
    typedef UINT (WINAPI *GetDpiForWindowFn)(HWND);
    static GetDpiForWindowFn get_dpi;
    static int looked;
    if (!looked) {
        HMODULE user32 = GetModuleHandleW(L"user32.dll");
        if (user32) get_dpi = (GetDpiForWindowFn)(void (*)(void))GetProcAddress(user32, "GetDpiForWindow");
        looked = 1;
    }
    if (get_dpi) {
        UINT dpi = get_dpi(hwnd);
        if (dpi) return dpi / 96.0;
    }
    {
        HDC dc = GetDC(hwnd);
        int dpi = dc ? GetDeviceCaps(dc, LOGPIXELSX) : 96;
        if (dc) ReleaseDC(hwnd, dc);
        return (dpi > 0 ? dpi : 96) / 96.0;
    }
}

/* ---- windows ------------------------------------------------------------ */

static const wchar_t OVERLAY_CLASS[] = L"LunarCompositorOverlay";
static void overlay_close(Overlay *ov);
static int live(Overlay *ov);

static LRESULT CALLBACK overlay_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    Overlay *ov = (Overlay *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    switch (msg) {
    case WM_NCCREATE: {
        CREATESTRUCTW *cs = (CREATESTRUCTW *)lp;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
        break;
    }
    case WM_NCHITTEST: {
        POINT pt;
        const Region *r;
        if (!ov) return HTTRANSPARENT;
        pt.x = (short)LOWORD(lp); pt.y = (short)HIWORD(lp);
        ScreenToClient(hwnd, &pt);
        r = region_at(ov, pt.x, pt.y);
        return (r && r->mode != MODE_PASS) ? HTCLIENT : HTTRANSPARENT;
    }
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;           /* never take focus from the dialog */
    case WM_LBUTTONDOWN: {
        const Region *r = ov ? region_at(ov, (short)LOWORD(lp), (short)HIWORD(lp)) : NULL;
        if (r && r->mode == MODE_ACTION) push_event(ov, EV_ACTION, &r->id);
        return 0;
    }
    case WM_NCDESTROY:
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        if (ov) {
            ov->hwnd = NULL;
            overlay_close(ov);
        }
        break;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static int register_class(void)
{
    static int registered;
    WNDCLASSEXW wc;
    if (registered) return 1;
    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = overlay_proc;            /* no CS_OWNDC/CS_CLASSDC: ULW owns the DC */
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    wc.lpszClassName = OVERLAY_CLASS;
    if (!RegisterClassExW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return 0;
    registered = 1;
    return 1;
}

/* The dialog's own messages: follow its size and DPI, and close with it. */
static LRESULT CALLBACK parent_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp,
                                    UINT_PTR id, DWORD_PTR ref)
{
    Overlay *ov = (Overlay *)ref;
    (void)id;
    switch (msg) {
    case WM_SIZE:
        if (wp != SIZE_MINIMIZED && ov->hwnd) {
            SetWindowPos(ov->hwnd, HWND_TOP, 0, 0, LOWORD(lp), HIWORD(lp),
                         SWP_NOACTIVATE | SWP_NOMOVE);
            ov->stale = 1;
            push_event(ov, EV_RESIZE, NULL);
        }
        break;
    case WM_DPICHANGED: {
        RECT rc;
        if (ov->hwnd && GetClientRect(hwnd, &rc)) {
            SetWindowPos(ov->hwnd, HWND_TOP, 0, 0, rc.right - rc.left, rc.bottom - rc.top,
                         SWP_NOACTIVATE | SWP_NOMOVE);
        }
        ov->stale = 1;
        push_event(ov, EV_DPI, NULL);
        break;
    }
    case WM_NCDESTROY: {
        LRESULT result = DefSubclassProc(hwnd, msg, wp, lp);
        overlay_close(ov);              /* removes this subclass; no Lua involved */
        return result;
    }
    }
    return DefSubclassProc(hwnd, msg, wp, lp);
}

static void release_dib(Overlay *ov)
{
    if (ov->memdc) {
        if (ov->old_bitmap) SelectObject(ov->memdc, ov->old_bitmap);
        DeleteDC(ov->memdc);
    }
    if (ov->dib) DeleteObject(ov->dib);
    ov->memdc = NULL; ov->dib = NULL; ov->old_bitmap = NULL; ov->bits = NULL;
    ov->dib_w = ov->dib_h = 0;
}

static int ensure_dib(Overlay *ov, int32_t w, int32_t h)
{
    BITMAPINFO bmi;
    HDC screen;
    if (ov->dib && ov->dib_w == w && ov->dib_h == h) return 1;
    ov->has_frame = 0;
    release_dib(ov);
    memset(&bmi, 0, sizeof(bmi));
    bmi.bmiHeader.biSize = sizeof(bmi.bmiHeader);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;              /* top-down: row 0 first, stride w*4 */
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    screen = GetDC(NULL);
    ov->memdc = CreateCompatibleDC(screen);
    ReleaseDC(NULL, screen);
    if (!ov->memdc) return 0;
    ov->dib = CreateDIBSection(ov->memdc, &bmi, DIB_RGB_COLORS, &ov->bits, NULL, 0);
    if (!ov->dib || !ov->bits) { release_dib(ov); return 0; }
    ov->old_bitmap = (HBITMAP)SelectObject(ov->memdc, ov->dib);
    ov->dib_w = w; ov->dib_h = h;
    return 1;
}

static int show_frame(Overlay *ov, BYTE constant_alpha)
{
    BLENDFUNCTION blend;
    SIZE size;
    POINT src = { 0, 0 };
    blend.BlendOp = AC_SRC_OVER;
    blend.BlendFlags = 0;
    blend.SourceConstantAlpha = constant_alpha;
    blend.AlphaFormat = AC_SRC_ALPHA;
    size.cx = ov->dib_w; size.cy = ov->dib_h;
    GdiFlush();
    /* pptDst NULL: keep the child's position (set with SetWindowPos). */
    if (!UpdateLayeredWindow(ov->hwnd, NULL, NULL, &size, ov->memdc, &src, 0, &blend, ULW_ALPHA))
        return 0;
    /* IUP can raise sibling canvases after the overlay is already visible. */
    if (!live(ov)) return 0;
    if (!SetWindowPos(ov->hwnd, HWND_TOP, 0, 0, 0, 0,
                      SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOOWNERZORDER |
                      SWP_SHOWWINDOW)) return 0;
    ov->shown = 1;
    ++ov->visibility_epoch;
    return 1;
}

static void overlay_close(Overlay *ov)
{
    if (ov->closed) return;
    ov->closed = 1;
    if (ov->subclassed && ov->parent) {
        RemoveWindowSubclass(ov->parent, parent_proc, (UINT_PTR)ov);
        ov->subclassed = 0;
    }
    if (ov->hwnd) {
        HWND hwnd = ov->hwnd;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        ov->hwnd = NULL;
        if (IsWindow(hwnd)) DestroyWindow(hwnd);
    }
    release_dib(ov);
    clear_regions(ov);
    clear_events(ov);
    ov->parent = NULL;
    ov->shown = 0;
    ov->has_frame = 0;
    ++ov->visibility_epoch;
}

/* ---- Lua ---------------------------------------------------------------- */

static Overlay *check_overlay(lua_State *L)
{
    return (Overlay *)luaL_checkudata(L, 1, OVERLAY_MT);
}

static int live(Overlay *ov)
{
    return !ov->closed && ov->hwnd && IsWindow(ov->hwnd);
}

static int parse_int(lua_State *L, int idx, const char *name, int32_t *out)
{
    lua_Number v;
    lua_pushstring(L, name);
    lua_rawget(L, idx);
    if (lua_type(L, -1) != LUA_TNUMBER) { lua_pop(L, 1); return 0; }
    v = lua_tonumber(L, -1);
    lua_pop(L, 1);
    if (!(v >= INT32_MIN && v <= INT32_MAX) || v != (lua_Number)(int32_t)v) return 0;
    *out = (int32_t)v;
    return 1;
}

/* The userdata owns every allocation until a successful frame takes the list. */
static StagedRegions *parse_regions(lua_State *L, int idx)
{
    size_t n, i;
    StagedRegions *stage;
    if (!lua_isnil(L, idx)) luaL_checktype(L, idx, LUA_TTABLE);
    n = lua_isnil(L, idx) ? 0 : lua_objlen(L, idx);
    if (n > INT_MAX || n > SIZE_MAX / sizeof(Region))
        luaL_error(L, "too many input regions");
    stage = (StagedRegions *)lua_newuserdata(L, sizeof(*stage));
    memset(stage, 0, sizeof(*stage));
    luaL_getmetatable(L, "lunar.staged_regions");
    lua_setmetatable(L, -2);
    stage->regions = n ? (Region *)calloc(n, sizeof(Region)) : NULL;
    if (n && !stage->regions) luaL_error(L, "out of memory for input regions");
    stage->count = n;
    if (n) {
        lua_pushnil(L);
        while (lua_next(L, idx)) {
            if (lua_type(L, -2) == LUA_TNUMBER) {
                lua_Number k = lua_tonumber(L, -2);
                if (!(k >= 1 && k <= (lua_Number)n) ||
                    k != (lua_Number)(size_t)k)
                    luaL_error(L, "region indices must be dense and 1-based");
            }
            lua_pop(L, 1);
        }
    } else if (!lua_isnil(L, idx)) {
        lua_pushnil(L);
        while (lua_next(L, idx)) {
            if (lua_type(L, -2) == LUA_TNUMBER)
                luaL_error(L, "region indices must be dense and 1-based");
            lua_pop(L, 1);
        }
    }
    for (i = 0; i < n; ++i) {
        Region *r = &stage->regions[i];
        const char *mode;
        size_t mode_len;
        lua_rawgeti(L, idx, (int)i + 1);
        if (!lua_istable(L, -1) || !parse_int(L, lua_gettop(L), "x", &r->x) ||
            !parse_int(L, lua_gettop(L), "y", &r->y) || !parse_int(L, lua_gettop(L), "w", &r->w) ||
            !parse_int(L, lua_gettop(L), "h", &r->h) || r->w < 0 || r->h < 0) {
            luaL_error(L, "region %d needs integer x, y, w, h", (int)i + 1);
        }
        lua_pushliteral(L, "mode");
        lua_rawget(L, -2);
        mode = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &mode_len) : NULL;
        if (mode && mode_len == 4 && memcmp(mode, "pass", 4) == 0) r->mode = MODE_PASS;
        else if (mode && mode_len == 5 && memcmp(mode, "block", 5) == 0) r->mode = MODE_BLOCK;
        else if (mode && mode_len == 6 && memcmp(mode, "action", 6) == 0) r->mode = MODE_ACTION;
        else luaL_error(L, "region %d has invalid mode", (int)i + 1);
        lua_pop(L, 1);
        if (r->mode == MODE_ACTION) {
            lua_pushliteral(L, "id");
            lua_rawget(L, -2);
            if (lua_type(L, -1) == LUA_TNUMBER) {
                lua_Number value = lua_tonumber(L, -1);
                if (!(value >= -DBL_MAX && value <= DBL_MAX))
                    luaL_error(L, "region %d action id must be finite", (int)i + 1);
                r->id.is_number = 1;
                r->id.number = value;
            } else if (lua_type(L, -1) == LUA_TSTRING) {
                const char *s = lua_tolstring(L, -1, &r->id.length);
                r->id.string = (char *)malloc(r->id.length ? r->id.length : 1u);
                if (!r->id.string) luaL_error(L, "out of memory for action id");
                memcpy(r->id.string, s, r->id.length);
            } else {
                luaL_error(L, "region %d action id must be a string or finite number", (int)i + 1);
            }
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
    }
    return stage;
}

static lua_Number scene_generation(lua_State *L)
{
    lua_Number value;
    lua_pushliteral(L, "generation");
    lua_rawget(L, 2);
    if (lua_isnil(L, -1)) { lua_pop(L, 1); return 0; }
    if (lua_type(L, -1) != LUA_TNUMBER) luaL_error(L, "scene generation must be an integer");
    value = lua_tonumber(L, -1);
    lua_pop(L, 1);
    if (!(value >= -9007199254740992.0 && value <= 9007199254740992.0) ||
        value != (lua_Number)(int64_t)value)
        luaL_error(L, "scene generation must be an integer");
    return value;
}

/* Windows ignores WM_NCHITTEST on fully transparent layered-window pixels. */
static void make_regions_hittable(Overlay *ov, const StagedRegions *stage)
{
    size_t i;
    for (i = 0; i < stage->count; ++i) {
        const Region *r = &stage->regions[i];
        int64_t x0 = r->x, y0 = r->y;
        int64_t x1 = x0 + r->w, y1 = y0 + r->h, x, y;
        if (r->mode == MODE_PASS) continue;
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        if (x1 > ov->dib_w) x1 = ov->dib_w;
        if (y1 > ov->dib_h) y1 = ov->dib_h;
        for (y = y0; y < y1; ++y) for (x = x0; x < x1; ++x) {
            uint8_t *pixel = (uint8_t *)ov->bits + ((size_t)y * (size_t)ov->dib_w + (size_t)x) * 4u;
            if (pixel[3] == 0) pixel[3] = 1;
        }
    }
}

static BYTE layer_alpha(lua_State *L, int idx)
{
    lua_Number a = luaL_optnumber(L, idx, 1);
    if (!(a > 0)) return 0;     /* also NaN */
    if (a > 1) a = 1;
    return (BYTE)(a * 255.0 + 0.5);
}

static int l_present(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    int32_t w, h;
    size_t count;
    BlendSprite *sprites;
    StagedRegions *stage;
    lua_Number generation;
    const char *why = NULL;
    BYTE opacity;
    /* Keep optional argument slots stable when scene parsing pushes userdata. */
    lua_settop(L, 4);
    opacity = layer_alpha(L, 4);
    if (!live(ov)) { lua_pushboolean(L, 0); lua_pushliteral(L, "overlay is closed"); return 2; }
    sprites = compositor_parse_scene(L, 2, &w, &h, &count);
    generation = scene_generation(L);
    stage = parse_regions(L, 3);
    if (!ensure_dib(ov, w, h)) { lua_pushboolean(L, 0); lua_pushliteral(L, "cannot allocate the frame"); return 2; }
    if (!blend_render((uint8_t *)ov->bits, (size_t)w * (size_t)h * 4u, w, h, sprites, count, &why))
        return luaL_error(L, "compositor render: %s", why ? why : "invalid scene");
    make_regions_hittable(ov, stage);
    if (!show_frame(ov, opacity)) {
        ov->has_frame = 0;
        lua_pushboolean(L, 0);
        lua_pushfstring(L, "cannot show compositor frame (error %d)", (int)GetLastError());
        return 2;
    }
    if (!live(ov)) { lua_pushboolean(L, 0); lua_pushliteral(L, "overlay closed while showing frame"); return 2; }
    clear_regions(ov);
    ov->regions = stage->regions;
    ov->nregions = stage->count;
    ov->generation = generation;
    stage->regions = NULL;
    stage->count = 0;
    ov->has_frame = 1;
    ov->stale = 0;
    lua_pushboolean(L, 1);
    return 1;
}

static int l_fade(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    RECT rc;
    BYTE a;
    luaL_checknumber(L, 2);
    a = layer_alpha(L, 2);
    if (!live(ov) || !ov->dib || !ov->has_frame || ov->stale) {
        lua_pushboolean(L, 0); return 1;
    }
    if (!GetClientRect(ov->hwnd, &rc) ||
        rc.right - rc.left != ov->dib_w || rc.bottom - rc.top != ov->dib_h) {
        ov->stale = 1;
        lua_pushboolean(L, 0); return 1;
    }
    lua_pushboolean(L, show_frame(ov, a));
    return 1;
}

static int l_hide(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    if (live(ov)) ShowWindow(ov->hwnd, SW_HIDE);
    ov->shown = 0;
    ++ov->visibility_epoch;
    return 0;
}

static int l_visible(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    lua_pushboolean(L, live(ov) && ov->shown && IsWindowVisible(ov->hwnd));
    return 1;
}

static int l_geometry(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    RECT rc;
    if (ov->closed || !ov->parent || !GetClientRect(ov->parent, &rc)) { lua_pushnil(L); return 1; }
    lua_createtable(L, 0, 3);
    lua_pushinteger(L, rc.right - rc.left); lua_setfield(L, -2, "w");
    lua_pushinteger(L, rc.bottom - rc.top); lua_setfield(L, -2, "h");
    lua_pushnumber(L, window_scale(ov->parent)); lua_setfield(L, -2, "scale");
    return 1;
}

static int l_events(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    int i;
    if (ov->event_oom) {
        ov->event_oom = 0;
        return luaL_error(L, "out of memory for action event id");
    }
    lua_createtable(L, ov->nevents, 0);
    for (i = 0; i < ov->nevents; ++i) {
        const Event *e = &ov->events[i];
        lua_createtable(L, 0, e->type == EV_ACTION ? 3 : 1);
        lua_pushstring(L, e->type == EV_ACTION ? "action" : e->type == EV_RESIZE ? "resize" : "dpi");
        lua_setfield(L, -2, "type");
        if (e->type == EV_ACTION) {
            id_push(L, &e->id); lua_setfield(L, -2, "id");
            lua_pushnumber(L, e->generation); lua_setfield(L, -2, "generation");
        }
        lua_rawseti(L, -2, i + 1);
    }
    clear_events(ov);
    return 1;
}

/* A widget's rectangle in the dialog's client coordinates, from IUP. */
static int widget_rect(Overlay *ov, Ihandle *ih, RECT *out)
{
    const char *pos, *size = IupGetAttribute(ih, "RASTERSIZE");
    POINT pt;
    int x, y, w, h;
    if (!size || sscanf(size, "%dx%d", &w, &h) != 2) return 0;
    if ((HWND)IupGetAttribute(ih, "HWND") == ov->parent) {
        /* The dialog itself: its whole client area (SCREENPOSITION would be the
           outer window's corner). */
        RECT rc;
        if (!GetClientRect(ov->parent, &rc)) return 0;
        *out = rc;
        return 1;
    }
    pos = IupGetAttribute(ih, "SCREENPOSITION");
    if (pos && sscanf(pos, "%d,%d", &x, &y) == 2) {
        pt.x = x; pt.y = y;
        ScreenToClient(ov->parent, &pt);
    } else {
        /* A box without a native window (vbox, hbox, ...): POSITION is relative
           to the nearest ancestor that has one; map from that window. */
        Ihandle *p = IupGetParent(ih);
        HWND native = NULL;
        pos = IupGetAttribute(ih, "POSITION");
        if (!pos || sscanf(pos, "%d,%d", &x, &y) != 2) return 0;
        for (; p && !native; p = IupGetParent(p)) native = (HWND)IupGetAttribute(p, "HWND");
        if (!native) return 0;
        pt.x = x; pt.y = y;
        if (native != ov->parent) MapWindowPoints(native, ov->parent, &pt, 1);
    }
    out->left = pt.x; out->top = pt.y; out->right = pt.x + w; out->bottom = pt.y + h;
    return 1;
}

/* Back on top of the dialog's other children, if IUP raised or created one
 * above a visible overlay (the manager's pump calls this while idle). */
static int l_raise(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    if (live(ov) && ov->shown && GetWindow(ov->hwnd, GW_HWNDPREV) != NULL)
        SetWindowPos(ov->hwnd, HWND_TOP, 0, 0, 0, 0,
                     SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOOWNERZORDER);
    return 0;
}

static int l_rect(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    Ihandle *ih = iuplua_checkihandle(L, 2);
    RECT rc;
    if (!live(ov) || !widget_rect(ov, ih, &rc)) { lua_pushnil(L); return 1; }
    lua_pushinteger(L, rc.left);
    lua_pushinteger(L, rc.top);
    lua_pushinteger(L, rc.right - rc.left);
    lua_pushinteger(L, rc.bottom - rc.top);
    return 4;
}

static int l_snapshot(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    RECT client, crop;
    HDC screen, dc;
    HBITMAP bmp, old;
    BITMAPINFO bmi;
    void *bits = NULL;
    int cw, ch, ok, was_visible;
    unsigned visibility_epoch;
    int32_t w, h, row;
    uint8_t *dst;
    if (ov->closed || !ov->parent || !GetClientRect(ov->parent, &client)) {
        lua_pushnil(L); lua_pushliteral(L, "overlay is closed"); return 2;
    }
    cw = client.right; ch = client.bottom;
    crop = client;
    if (!lua_isnoneornil(L, 2)) {
        Ihandle *ih = iuplua_checkihandle(L, 2);
        if (!widget_rect(ov, ih, &crop)) { lua_pushnil(L); lua_pushliteral(L, "widget has no position yet"); return 2; }
        if (crop.left < 0) crop.left = 0;
        if (crop.top < 0) crop.top = 0;
        if (crop.right > cw) crop.right = cw;
        if (crop.bottom > ch) crop.bottom = ch;
    }
    w = crop.right - crop.left; h = crop.bottom - crop.top;
    if (cw <= 0 || ch <= 0 || w <= 0 || h <= 0) { lua_pushnil(L); lua_pushliteral(L, "nothing to capture"); return 2; }

    /* Allocate Lua memory before GDI handles: allocation errors long-jump. */
    dst = compositor_new_snapshot(L, w, h);

    memset(&bmi, 0, sizeof(bmi));
    bmi.bmiHeader.biSize = sizeof(bmi.bmiHeader);
    bmi.bmiHeader.biWidth = cw;
    bmi.bmiHeader.biHeight = -ch;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    screen = GetDC(NULL);
    dc = CreateCompatibleDC(screen);
    ReleaseDC(NULL, screen);
    bmp = dc ? CreateDIBSection(dc, &bmi, DIB_RGB_COLORS, &bits, NULL, 0) : NULL;
    if (!bmp || !bits) {
        if (bmp) DeleteObject(bmp);
        if (dc) DeleteDC(dc);
        lua_pushnil(L); lua_pushliteral(L, "cannot allocate the capture"); return 2;
    }
    old = (HBITMAP)SelectObject(dc, bmp);

    /* Keep the overlay out of its own capture. */
    was_visible = live(ov) && IsWindowVisible(ov->hwnd);
    visibility_epoch = ov->visibility_epoch;
    if (was_visible) ShowWindow(ov->hwnd, SW_HIDE);
    ok = PrintWindow(ov->parent, dc, PW_CLIENTONLY | PW_RENDERFULLCONTENT);
    if (!ok && live(ov)) {
        HDC wdc = GetDC(ov->parent);
        ok = wdc && BitBlt(dc, 0, 0, cw, ch, wdc, 0, 0, SRCCOPY);
        if (wdc) ReleaseDC(ov->parent, wdc);
    }
    if (was_visible && live(ov) && ov->shown && ov->visibility_epoch == visibility_epoch)
        ShowWindow(ov->hwnd, SW_SHOWNA);
    GdiFlush();

    if (!ok) {
        SelectObject(dc, old); DeleteObject(bmp); DeleteDC(dc);
        lua_pushnil(L); lua_pushliteral(L, "PrintWindow and BitBlt both failed"); return 2;
    }
    for (row = 0; row < h; ++row) {
        const uint8_t *src = (const uint8_t *)bits + ((size_t)(crop.top + row) * (size_t)cw + (size_t)crop.left) * 4u;
        uint8_t *out = dst + (size_t)row * (size_t)w * 4u;
        int32_t x;
        memcpy(out, src, (size_t)w * 4u);
        for (x = 0; x < w; ++x) out[x * 4 + 3] = 255;   /* GDI leaves alpha undefined: captures are opaque */
    }
    SelectObject(dc, old); DeleteObject(bmp); DeleteDC(dc);
    return 1;
}

/* Wait for DWM's next composition, so a desktop sample sees the frame just
 * presented (composition is asynchronous). Loaded at runtime: no link dependency. */
static void dwm_flush(void)
{
    typedef HRESULT (WINAPI *DwmFlushFn)(void);
    static DwmFlushFn flush;
    static int looked;
    if (!looked) {
        HMODULE dwm = LoadLibraryW(L"dwmapi.dll");
        if (dwm) flush = (DwmFlushFn)(void (*)(void))GetProcAddress(dwm, "DwmFlush");
        looked = 1;
    }
    if (flush) flush();
}

static int l_screen_pixel(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    POINT pt;
    HDC screen, mem;
    HBITMAP bmp, old;
    BITMAPINFO bmi;
    void *bits = NULL;
    pt.x = (LONG)luaL_checkinteger(L, 2);
    pt.y = (LONG)luaL_checkinteger(L, 3);
    if (ov->closed || !ov->parent) return 0;
    ClientToScreen(ov->parent, &pt);
    memset(&bmi, 0, sizeof(bmi));
    bmi.bmiHeader.biSize = sizeof(bmi.bmiHeader);
    bmi.bmiHeader.biWidth = 1; bmi.bmiHeader.biHeight = -1;
    bmi.bmiHeader.biPlanes = 1; bmi.bmiHeader.biBitCount = 32; bmi.bmiHeader.biCompression = BI_RGB;
    dwm_flush();
    screen = GetDC(NULL);
    mem = CreateCompatibleDC(screen);
    bmp = mem ? CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &bits, NULL, 0) : NULL;
    if (!bmp || !bits) {
        if (bmp) DeleteObject(bmp);
        if (mem) DeleteDC(mem);
        ReleaseDC(NULL, screen);
        return 0;
    }
    old = (HBITMAP)SelectObject(mem, bmp);
    /* CAPTUREBLT: include layered windows, i.e. what the user actually sees. */
    BitBlt(mem, 0, 0, 1, 1, screen, pt.x, pt.y, SRCCOPY | CAPTUREBLT);
    GdiFlush();
    lua_pushinteger(L, ((uint8_t *)bits)[2]);
    lua_pushinteger(L, ((uint8_t *)bits)[1]);
    lua_pushinteger(L, ((uint8_t *)bits)[0]);
    SelectObject(mem, old); DeleteObject(bmp); DeleteDC(mem);
    ReleaseDC(NULL, screen);
    return 3;
}

static int l_close(lua_State *L)
{
    overlay_close(check_overlay(L));
    return 0;
}

static int l_overlay(lua_State *L)
{
    Ihandle *dlg = iuplua_checkihandle(L, 1);
    HWND parent = (HWND)IupGetAttribute(dlg, "HWND");
    Overlay *ov;
    RECT rc;
    if (!parent || !IsWindow(parent)) { lua_pushnil(L); lua_pushliteral(L, "dialog has no window yet (show it first)"); return 2; }
    if (!register_class()) { lua_pushnil(L); lua_pushliteral(L, "cannot register the overlay window class"); return 2; }
    ov = (Overlay *)lua_newuserdata(L, sizeof(*ov));
    memset(ov, 0, sizeof(*ov));
    luaL_getmetatable(L, OVERLAY_MT);
    lua_setmetatable(L, -2);
    ov->parent = parent;
    GetClientRect(parent, &rc);
    ov->hwnd = CreateWindowExW(WS_EX_LAYERED, OVERLAY_CLASS, L"", WS_CHILD | WS_CLIPSIBLINGS,
                               0, 0, rc.right > 0 ? rc.right : 1, rc.bottom > 0 ? rc.bottom : 1,
                               parent, NULL, GetModuleHandleW(NULL), ov);
    if (!ov->hwnd) {
        DWORD err = GetLastError();
        ov->closed = 1;
        lua_pushnil(L);
        lua_pushfstring(L, "cannot create a layered child window (error %d; needs Windows 8+ and the manifest's Windows 8 entry)", (int)err);
        return 2;
    }
    if (GetWindowThreadProcessId(parent, NULL) != GetCurrentThreadId()) {
        overlay_close(ov);
        lua_pushnil(L);
        lua_pushliteral(L, "dialog window belongs to another thread");
        return 2;
    }
    if (!SetWindowSubclass(parent, parent_proc, (UINT_PTR)ov, (DWORD_PTR)ov)) {
        DWORD err = GetLastError();
        overlay_close(ov);
        lua_pushnil(L);
        lua_pushfstring(L, "cannot track dialog window (error %d)", (int)err);
        return 2;
    }
    ov->subclassed = 1;
    return 1;
}

static int l_supported(lua_State *L)
{
    lua_pushboolean(L, 1);
    return 1;
}

void compositor_backend_register(lua_State *L)
{
    static const luaL_Reg methods[] = {
        { "present", l_present }, { "fade", l_fade }, { "hide", l_hide },
        { "visible", l_visible }, { "geometry", l_geometry }, { "events", l_events },
        { "snapshot", l_snapshot }, { "screen_pixel", l_screen_pixel }, { "close", l_close },
        { "rect", l_rect }, { "raise", l_raise },
        { NULL, NULL }
    };
    luaL_newmetatable(L, "lunar.staged_regions");
    lua_pushcfunction(L, staged_regions_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);
    luaL_newmetatable(L, OVERLAY_MT);
    lua_newtable(L);
    luaL_register(L, NULL, methods);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, l_close);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);
    lua_pushcfunction(L, l_supported); lua_setfield(L, -2, "supported");
    lua_pushcfunction(L, l_overlay);   lua_setfield(L, -2, "overlay");
}

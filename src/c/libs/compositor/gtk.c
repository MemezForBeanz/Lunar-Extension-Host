/* GTK compositor backend (Linux, GTK3 on X11/XWayland): one native child
 * window per dialog.
 *
 * X child windows cannot alpha-blend with their siblings, so the overlay does
 * the blending itself ("backdrop" mode, proven by scripts/gtk_overlay_probe.lua):
 *
 *   - the overlay is a GtkDrawingArea put last in IUP's inner GtkFixed, made a
 *     native window (gdk_window_ensure_native) and raised;
 *   - when a frame is presented after the layer was hidden (or the size changed,
 *     or the frame covers more than the last one did) the dialog's content is
 *     captured ONCE into a cairo image surface (gtk_widget_draw with the overlay
 *     painting nothing). The backdrop is kept while the layer stays up, because a
 *     scrim's backdrop does not change;
 *   - the portable blend core renders the scene into a premultiplied BGRA buffer
 *     (the memory layout of cairo ARGB32), and the draw handler paints
 *     backdrop (SOURCE) then scene * layer opacity (OVER);
 *   - `fade` only changes the opacity and repaints: no scene render;
 *   - the window's bounding shape is the union of sprite and input regions, so a
 *     toast leaves the rest of the page live; a full-cover scrim has no shape;
 *   - input is an X input shape of the block/action regions (empty = every click
 *     passes through). A press on an action region is queued with a copy of its
 *     id; no Lua runs inside GTK callbacks.
 *
 * Overlay pixels are device pixels: GTK logical size * the window's scale factor.
 * The Lua API is the one documented in win32.c.
 */

#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <gtk/gtk.h>
#include <gdk/gdkx.h>
#include <lua.h>
#include <lauxlib.h>
#include <iup.h>
#include <iuplua.h>
#include "compositor_internal.h"

/* gdk_window_process_updates / process_all_updates are the only way to paint a
 * native child synchronously (the scrim fade drives its own frames); GTK3
 * marks them deprecated but they work for every GTK 3 release. */
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

#define OVERLAY_MT "lunar.overlay"
#define MAX_EVENTS 64

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
} InRegion;

typedef struct {
    int type;
    RegionId id;                /* EV_ACTION only; owned by the event */
    lua_Number generation;
} Event;

typedef struct {
    InRegion *regions;
    size_t count;
} StagedRegions;

typedef struct {
    GtkWidget *window;          /* the dialog (GtkWindow) */
    GtkWidget *fixed;           /* IUP's inner container: the overlay's cover */
    GtkWidget *da;              /* the overlay */
    gulong alloc_id, destroy_id, scale_id, press_id, draw_id;
    int scale;                  /* device pixels per logical pixel */
    int32_t cover_w, cover_h;   /* cover size in device pixels */

    uint8_t *scene;             /* premultiplied BGRA, frame_w x frame_h */
    cairo_surface_t *scene_surface;
    int32_t frame_w, frame_h;
    cairo_surface_t *backdrop;  /* opaque capture of the page beneath */
    int32_t backdrop_w, backdrop_h;
    cairo_region_t *shape;      /* last bounding shape in logical px; NULL = whole cover */
    double opacity;
    int capturing;              /* draw handler paints nothing while capturing */

    InRegion *regions;
    size_t nregions;
    Event events[MAX_EVENTS];
    int nevents;
    int event_oom;
    lua_Number generation;
    int shown;                  /* the layer is up */
    int has_frame;
    int stale;
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
static const InRegion *region_at(const Overlay *ov, int x, int y)
{
    size_t i = ov->nregions;
    while (i-- > 0) {
        const InRegion *r = &ov->regions[i];
        if (x >= r->x && y >= r->y && (int64_t)x < (int64_t)r->x + r->w &&
            (int64_t)y < (int64_t)r->y + r->h) return r;
    }
    return NULL;
}

/* ---- geometry ----------------------------------------------------------- */

static int live(const Overlay *ov)
{
    return !ov->closed && ov->da && ov->fixed && ov->window;
}

static void refresh_cover(Overlay *ov)
{
    GtkAllocation a;
    int s = gtk_widget_get_scale_factor(ov->window);
    ov->scale = s > 0 ? s : 1;
    gtk_widget_get_allocation(ov->fixed, &a);
    ov->cover_w = a.width > 0 ? a.width * ov->scale : 0;
    ov->cover_h = a.height > 0 ? a.height * ov->scale : 0;
}

static void release_surfaces(Overlay *ov)
{
    if (ov->scene_surface) cairo_surface_destroy(ov->scene_surface);
    if (ov->backdrop) cairo_surface_destroy(ov->backdrop);
    if (ov->shape) cairo_region_destroy(ov->shape);
    free(ov->scene);
    ov->scene_surface = ov->backdrop = NULL;
    ov->shape = NULL;
    ov->scene = NULL;
    ov->frame_w = ov->frame_h = ov->backdrop_w = ov->backdrop_h = 0;
}

/* The overlay window fills the cover. GtkFixed does not stretch children. */
static void fit_overlay(Overlay *ov)
{
    GtkAllocation a, want;
    gtk_widget_get_allocation(ov->fixed, &a);
    want.x = 0; want.y = 0;
    want.width = a.width > 0 ? a.width : 1;
    want.height = a.height > 0 ? a.height : 1;
    gtk_widget_set_size_request(ov->da, want.width, want.height);
    gtk_widget_size_allocate(ov->da, &want);
}

/* ---- callbacks (no Lua in here) ----------------------------------------- */

static void overlay_close(Overlay *ov);

/* After GtkFixed has allocated its children: follow the cover immediately. */
static void on_fixed_allocate(GtkWidget *w, GdkRectangle *a, gpointer data)
{
    Overlay *ov = (Overlay *)data;
    (void)w; (void)a;
    if (!live(ov)) return;
    fit_overlay(ov);
    {
        int32_t ow = ov->cover_w, oh = ov->cover_h;
        refresh_cover(ov);
        if (ov->cover_w != ow || ov->cover_h != oh) {
            ov->stale = 1;
            push_event(ov, EV_RESIZE, NULL);
        }
    }
}

static void on_scale_changed(GObject *o, GParamSpec *p, gpointer data)
{
    Overlay *ov = (Overlay *)data;
    (void)o; (void)p;
    if (!live(ov)) return;
    refresh_cover(ov);
    ov->stale = 1;
    push_event(ov, EV_DPI, NULL);
}

/* The dialog is going away: drop every pointer, GTK destroys the widgets. */
static void on_window_destroy(GtkWidget *w, gpointer data)
{
    Overlay *ov = (Overlay *)data;
    (void)w;
    ov->window = ov->fixed = ov->da = NULL;     /* handlers die with the widgets */
    ov->alloc_id = ov->destroy_id = ov->scale_id = ov->press_id = ov->draw_id = 0;
    overlay_close(ov);
}

static gboolean on_draw(GtkWidget *w, cairo_t *cr, gpointer data)
{
    Overlay *ov = (Overlay *)data;
    (void)w;
    if (ov->capturing || ov->closed || !ov->shown) return FALSE;
    if (ov->backdrop) {
        cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
        cairo_set_source_surface(cr, ov->backdrop, 0, 0);
        cairo_paint(cr);
    }
    if (ov->scene_surface && ov->opacity > 0) {
        cairo_set_operator(cr, ov->backdrop ? CAIRO_OPERATOR_OVER : CAIRO_OPERATOR_SOURCE);
        cairo_set_source_surface(cr, ov->scene_surface, 0, 0);
        cairo_paint_with_alpha(cr, ov->opacity);
    }
    return FALSE;
}

static gboolean on_press(GtkWidget *w, GdkEventButton *e, gpointer data)
{
    Overlay *ov = (Overlay *)data;
    const InRegion *r;
    (void)w;
    if (e->button == 1) {
        r = region_at(ov, (int)(e->x * ov->scale), (int)(e->y * ov->scale));
        if (r && r->mode == MODE_ACTION) push_event(ov, EV_ACTION, &r->id);
    }
    return TRUE;                        /* block and action regions swallow the click */
}

/* ---- capture ------------------------------------------------------------ */

/* The dialog's cover content without the overlay, as an opaque cairo surface of
 * device size, or NULL. The overlay's draw handler paints nothing meanwhile, so
 * the native window is not unmapped (no flicker). */
static cairo_surface_t *capture_cover(Overlay *ov)
{
    cairo_surface_t *surface;
    cairo_t *cr;
    int ox = 0, oy = 0;
    if (!live(ov)) return NULL;
    gtk_container_check_resize(GTK_CONTAINER(ov->window));   /* settle pending layout */
    if (!live(ov)) return NULL;
    refresh_cover(ov);
    if (ov->cover_w <= 0 || ov->cover_h <= 0) return NULL;
    surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, ov->cover_w, ov->cover_h);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return NULL;
    }
    cairo_surface_set_device_scale(surface, ov->scale, ov->scale);
    cr = cairo_create(surface);
    if (!gtk_widget_translate_coordinates(ov->fixed, ov->window, 0, 0, &ox, &oy)) ox = oy = 0;
    cairo_translate(cr, -ox, -oy);
    ov->capturing = 1;
    gtk_widget_draw(ov->window, cr);
    ov->capturing = 0;
    cairo_destroy(cr);
    cairo_surface_flush(surface);
    return surface;
}

/* ---- Lua ---------------------------------------------------------------- */

static Overlay *check_overlay(lua_State *L)
{
    return (Overlay *)luaL_checkudata(L, 1, OVERLAY_MT);
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
    if (n > INT_MAX || n > SIZE_MAX / sizeof(InRegion))
        luaL_error(L, "too many input regions");
    stage = (StagedRegions *)lua_newuserdata(L, sizeof(*stage));
    memset(stage, 0, sizeof(*stage));
    luaL_getmetatable(L, "lunar.staged_regions");
    lua_setmetatable(L, -2);
    stage->regions = n ? (InRegion *)calloc(n, sizeof(InRegion)) : NULL;
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
        InRegion *r = &stage->regions[i];
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

static double layer_alpha(lua_State *L, int idx)
{
    lua_Number a = luaL_optnumber(L, idx, 1);
    if (!(a > 0)) return 0;     /* also NaN */
    if (a > 1) a = 1;
    return (double)((int)(a * 255.0 + 0.5)) / 255.0;
}

/* Logical-pixel rectangle covering the device rectangle, clipped to the cover. */
static void add_device_rect(cairo_region_t *region, const Overlay *ov, int64_t x, int64_t y,
                            int64_t w, int64_t h, int subtract)
{
    int64_t s = ov->scale, x1 = x + w, y1 = y + h, cw = ov->cover_w / s + 1, ch = ov->cover_h / s + 1;
    cairo_rectangle_int_t r;
    if (w <= 0 || h <= 0) return;
    x = x >= 0 ? x / s : -((-x + s - 1) / s);
    y = y >= 0 ? y / s : -((-y + s - 1) / s);
    x1 = x1 >= 0 ? (x1 + s - 1) / s : -((-x1) / s);
    y1 = y1 >= 0 ? (y1 + s - 1) / s : -((-y1) / s);
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x1 > cw) x1 = cw;
    if (y1 > ch) y1 = ch;
    if (x1 <= x || y1 <= y) return;
    r.x = (int)x; r.y = (int)y; r.width = (int)(x1 - x); r.height = (int)(y1 - y);
    if (subtract) cairo_region_subtract_rectangle(region, &r);
    else cairo_region_union_rectangle(region, &r);
}

static int region_is_cover(const cairo_region_t *region, const Overlay *ov)
{
    cairo_rectangle_int_t e;
    GtkAllocation a;
    gtk_widget_get_allocation(ov->fixed, &a);
    if (cairo_region_num_rectangles(region) != 1) return 0;
    cairo_region_get_extents(region, &e);
    return e.x <= 0 && e.y <= 0 && e.width >= a.width && e.height >= a.height;
}

static void set_input_shape(Overlay *ov)
{
    cairo_region_t *input = cairo_region_create();
    size_t i;
    for (i = 0; i < ov->nregions; ++i) {
        const InRegion *r = &ov->regions[i];
        add_device_rect(input, ov, r->x, r->y, r->w, r->h, r->mode == MODE_PASS);
    }
    gtk_widget_input_shape_combine_region(ov->da, input);
    cairo_region_destroy(input);
}

/* Paint the current backdrop + scene synchronously. */
static void repaint(Overlay *ov)
{
    GdkWindow *win = gtk_widget_get_window(ov->da);
    if (!win) return;
    gdk_window_invalidate_rect(win, NULL, FALSE);
    gdk_window_process_updates(win, FALSE);
}

static void set_layer_visible(Overlay *ov, int visible)
{
    gtk_widget_set_child_visible(ov->da, visible ? TRUE : FALSE);
    ov->shown = visible;
}

static void overlay_close(Overlay *ov)
{
    if (ov->closed) return;
    ov->closed = 1;
    if (ov->window) g_signal_handlers_disconnect_by_data(ov->window, ov);
    if (ov->fixed) g_signal_handlers_disconnect_by_data(ov->fixed, ov);
    if (ov->da) {
        GtkWidget *da = ov->da;
        g_signal_handlers_disconnect_by_data(da, ov);
        ov->da = NULL;
        gtk_widget_destroy(da);
    }
    ov->window = ov->fixed = NULL;
    release_surfaces(ov);
    clear_regions(ov);
    clear_events(ov);
    ov->shown = 0;
    ov->has_frame = 0;
}

static int l_present(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    int32_t w, h;
    size_t count, i;
    BlendSprite *sprites;
    StagedRegions *stage;
    lua_Number generation;
    const char *why = NULL;
    double opacity;
    cairo_region_t *bounds;
    int need_capture, full;
    lua_settop(L, 4);
    opacity = layer_alpha(L, 4);
    if (!live(ov)) { lua_pushboolean(L, 0); lua_pushliteral(L, "overlay is closed"); return 2; }
    sprites = compositor_parse_scene(L, 2, &w, &h, &count);
    generation = scene_generation(L);
    stage = parse_regions(L, 3);
    refresh_cover(ov);
    if (ov->cover_w <= 0 || ov->cover_h <= 0) {
        lua_pushboolean(L, 0); lua_pushliteral(L, "the dialog has no size yet"); return 2;
    }

    if (!ov->scene || ov->frame_w != w || ov->frame_h != h) {
        cairo_surface_t *surface;
        uint8_t *buffer = (uint8_t *)malloc((size_t)w * (size_t)h * 4u + 4u);
        if (!buffer) { lua_pushboolean(L, 0); lua_pushliteral(L, "cannot allocate the frame"); return 2; }
        surface = cairo_image_surface_create_for_data(buffer, CAIRO_FORMAT_ARGB32, w, h, w * 4);
        if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
            cairo_surface_destroy(surface);
            free(buffer);
            lua_pushboolean(L, 0); lua_pushliteral(L, "cannot allocate the frame"); return 2;
        }
        cairo_surface_set_device_scale(surface, ov->scale, ov->scale);
        if (ov->scene_surface) cairo_surface_destroy(ov->scene_surface);
        free(ov->scene);
        ov->scene = buffer;
        ov->scene_surface = surface;
        ov->frame_w = w; ov->frame_h = h;
    }
    ov->has_frame = 0;
    if (!blend_render(ov->scene, (size_t)w * (size_t)h * 4u, w, h, sprites, count, &why))
        return luaL_error(L, "compositor render: %s", why ? why : "invalid scene");
    cairo_surface_mark_dirty(ov->scene_surface);

    /* Where the window exists: sprites and input regions. */
    bounds = cairo_region_create();
    for (i = 0; i < count; ++i) {
        BlendRect r = sprites[i].rect;
        if (sprites[i].has_clip) {
            BlendRect c = sprites[i].clip;
            int32_t x0 = r.x > c.x ? r.x : c.x, y0 = r.y > c.y ? r.y : c.y;
            int64_t x1 = (int64_t)r.x + r.w, y1 = (int64_t)r.y + r.h;
            if ((int64_t)c.x + c.w < x1) x1 = (int64_t)c.x + c.w;
            if ((int64_t)c.y + c.h < y1) y1 = (int64_t)c.y + c.h;
            r.x = x0; r.y = y0;
            r.w = x1 > x0 ? (int32_t)(x1 - x0) : 0;
            r.h = y1 > y0 ? (int32_t)(y1 - y0) : 0;
        }
        add_device_rect(bounds, ov, r.x, r.y, r.w, r.h, 0);
    }
    for (i = 0; i < stage->count; ++i) {
        const InRegion *r = &stage->regions[i];
        if (r->mode != MODE_PASS) add_device_rect(bounds, ov, r->x, r->y, r->w, r->h, 0);
    }
    full = region_is_cover(bounds, ov);

    /* One capture per time the layer is up; again when the page area it must
       reproduce grows or changes size. */
    need_capture = !ov->backdrop || !ov->shown || ov->stale ||
                   ov->backdrop_w != ov->cover_w || ov->backdrop_h != ov->cover_h;
    if (!need_capture && ov->shape) {                /* previously partial: new area? */
        cairo_region_t *extra = cairo_region_copy(bounds);
        cairo_region_subtract(extra, ov->shape);
        need_capture = !cairo_region_is_empty(extra);
        cairo_region_destroy(extra);
    }
    if (need_capture) {
        cairo_surface_t *backdrop = capture_cover(ov);
        if (!backdrop) {
            cairo_region_destroy(bounds);
            lua_pushboolean(L, 0); lua_pushliteral(L, "cannot capture the page beneath the overlay"); return 2;
        }
        if (ov->backdrop) cairo_surface_destroy(ov->backdrop);
        ov->backdrop = backdrop;
        ov->backdrop_w = ov->cover_w; ov->backdrop_h = ov->cover_h;
    }

    if (ov->shape) cairo_region_destroy(ov->shape);
    ov->shape = full ? NULL : bounds;
    if (full) cairo_region_destroy(bounds);
    gtk_widget_shape_combine_region(ov->da, ov->shape);

    ov->opacity = opacity;
    fit_overlay(ov);
    ov->shown = 1;
    gtk_widget_set_child_visible(ov->da, TRUE);
    {
        GdkWindow *win = gtk_widget_get_window(ov->da);
        if (win) gdk_window_raise(win);
    }
    repaint(ov);
    if (!live(ov)) { lua_pushboolean(L, 0); lua_pushliteral(L, "overlay closed while showing frame"); return 2; }

    clear_regions(ov);
    ov->regions = stage->regions;
    ov->nregions = stage->count;
    ov->generation = generation;
    stage->regions = NULL;
    stage->count = 0;
    set_input_shape(ov);
    ov->has_frame = 1;
    ov->stale = 0;
    lua_pushboolean(L, 1);
    return 1;
}

static int l_fade(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    double a;
    luaL_checknumber(L, 2);
    a = layer_alpha(L, 2);
    if (!live(ov) || !ov->scene || !ov->has_frame || ov->stale) {
        lua_pushboolean(L, 0); return 1;
    }
    refresh_cover(ov);
    if (ov->cover_w != ov->backdrop_w || ov->cover_h != ov->backdrop_h ||
        ov->cover_w != ov->frame_w || ov->cover_h != ov->frame_h) {
        ov->stale = 1;
        lua_pushboolean(L, 0); return 1;
    }
    ov->opacity = a;
    if (!ov->shown) { ov->shown = 1; gtk_widget_set_child_visible(ov->da, TRUE); }
    repaint(ov);
    lua_pushboolean(L, live(ov));
    return 1;
}

static int l_hide(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    if (live(ov)) set_layer_visible(ov, 0);
    else ov->shown = 0;
    return 0;
}

static int l_visible(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    lua_pushboolean(L, live(ov) && ov->shown && gtk_widget_get_mapped(ov->da));
    return 1;
}

static int l_geometry(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    if (!live(ov)) { lua_pushnil(L); return 1; }
    refresh_cover(ov);
    lua_createtable(L, 0, 3);
    lua_pushinteger(L, ov->cover_w); lua_setfield(L, -2, "w");
    lua_pushinteger(L, ov->cover_h); lua_setfield(L, -2, "h");
    lua_pushnumber(L, ov->scale); lua_setfield(L, -2, "scale");
    /* Device pixels per IUP pixel: GTK lays IUP out in logical pixels, so
       effects positioning IUP coordinates multiply by this (Windows: 1). */
    lua_pushnumber(L, ov->scale); lua_setfield(L, -2, "unit");
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

/* The GtkWidget behind an IUP element, or NULL for boxes (IUP gives them a fake
 * handle) and unmapped elements. */
static GtkWidget *native_widget(Ihandle *ih)
{
    uintptr_t p = (uintptr_t)IupGetAttribute(ih, "WID");
    if (p < 0x10000u || p == (uintptr_t)-1) return NULL;
    return GTK_IS_WIDGET((GtkWidget *)p) ? (GtkWidget *)p : NULL;
}

/* A widget's rectangle in overlay (device) pixels, from IUP. */
static int widget_rect(Overlay *ov, Ihandle *ih, int *out)
{
    const char *size = IupGetAttribute(ih, "RASTERSIZE");
    GtkWidget *native = native_widget(ih);
    int x = 0, y = 0, w, h, ok = 0;
    if (native == ov->window) {          /* the dialog: its whole cover */
        out[0] = 0; out[1] = 0; out[2] = ov->cover_w; out[3] = ov->cover_h;
        return 1;
    }
    if (!size || sscanf(size, "%dx%d", &w, &h) != 2) return 0;
    if (native && gtk_widget_get_realized(native))
        ok = gtk_widget_translate_coordinates(native, ov->fixed, 0, 0, &x, &y);
    if (!ok) {
        /* A box without a native window (vbox, hbox, ...): POSITION is relative to
           the nearest ancestor that has one; map from that widget. */
        Ihandle *p = IupGetParent(ih);
        GtkWidget *anc = NULL;
        int px, py;
        const char *pos = IupGetAttribute(ih, "POSITION");
        if (!pos || sscanf(pos, "%d,%d", &px, &py) != 2) return 0;
        for (; p && !anc; p = IupGetParent(p)) anc = native_widget(p);
        if (!anc) return 0;
        x = px; y = py;
        if (anc == ov->window) anc = ov->fixed;
        else if (!gtk_widget_translate_coordinates(anc, ov->fixed, px, py, &x, &y)) return 0;
    }
    out[0] = x * ov->scale; out[1] = y * ov->scale;
    out[2] = w * ov->scale; out[3] = h * ov->scale;
    return 1;
}

/* Back on top of the dialog's other children, if IUP raised or created one
 * above a visible overlay (the manager's pump calls this while idle). */
static int l_raise(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    if (live(ov) && ov->shown) {
        GdkWindow *win = gtk_widget_get_window(ov->da);
        GdkWindow *parent = win ? gdk_window_get_parent(win) : NULL;
        if (parent) {
            GList *kids = gdk_window_get_children(parent);   /* topmost first */
            int on_top = kids && kids->data == win;
            g_list_free(kids);
            if (!on_top) gdk_window_raise(win);
        }
    }
    return 0;
}

static int l_rect(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    Ihandle *ih = iuplua_checkihandle(L, 2);
    int r[4];
    if (!live(ov)) { lua_pushnil(L); return 1; }
    refresh_cover(ov);
    if (!widget_rect(ov, ih, r)) { lua_pushnil(L); return 1; }
    lua_pushinteger(L, r[0]); lua_pushinteger(L, r[1]);
    lua_pushinteger(L, r[2]); lua_pushinteger(L, r[3]);
    return 4;
}

static int l_snapshot(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    cairo_surface_t *surface;
    int crop[4], cw, ch, row;
    int32_t w, h;
    uint8_t *dst;
    const uint8_t *src;
    int stride;
    if (!live(ov)) { lua_pushnil(L); lua_pushliteral(L, "overlay is closed"); return 2; }
    gtk_container_check_resize(GTK_CONTAINER(ov->window));
    if (!live(ov)) { lua_pushnil(L); lua_pushliteral(L, "overlay is closed"); return 2; }
    refresh_cover(ov);
    cw = ov->cover_w; ch = ov->cover_h;
    crop[0] = 0; crop[1] = 0; crop[2] = cw; crop[3] = ch;
    if (!lua_isnoneornil(L, 2)) {
        Ihandle *ih = iuplua_checkihandle(L, 2);
        int x1, y1;
        if (!widget_rect(ov, ih, crop)) { lua_pushnil(L); lua_pushliteral(L, "widget has no position yet"); return 2; }
        x1 = crop[0] + crop[2]; y1 = crop[1] + crop[3];
        if (crop[0] < 0) crop[0] = 0;
        if (crop[1] < 0) crop[1] = 0;
        if (x1 > cw) x1 = cw;
        if (y1 > ch) y1 = ch;
        crop[2] = x1 - crop[0]; crop[3] = y1 - crop[1];
    }
    w = crop[2]; h = crop[3];
    if (cw <= 0 || ch <= 0 || w <= 0 || h <= 0) { lua_pushnil(L); lua_pushliteral(L, "nothing to capture"); return 2; }
    /* Allocate Lua memory before cairo's: allocation errors long-jump. */
    dst = compositor_new_snapshot(L, w, h);
    surface = capture_cover(ov);
    if (!surface) { lua_pushnil(L); lua_pushliteral(L, "cannot capture the dialog"); return 2; }
    if ((int64_t)cairo_image_surface_get_width(surface) < (int64_t)crop[0] + w ||
        (int64_t)cairo_image_surface_get_height(surface) < (int64_t)crop[1] + h ||
        crop[0] < 0 || crop[1] < 0) {
        cairo_surface_destroy(surface);
        lua_pushnil(L); lua_pushliteral(L, "capture changed size"); return 2;
    }
    src = cairo_image_surface_get_data(surface);
    stride = cairo_image_surface_get_stride(surface);
    for (row = 0; row < h; ++row) {
        const uint8_t *s = src + (size_t)(crop[1] + row) * (size_t)stride + (size_t)crop[0] * 4u;
        uint8_t *out = dst + (size_t)row * (size_t)w * 4u;
        int32_t x;
        memcpy(out, s, (size_t)w * 4u);
        for (x = 0; x < w; ++x) out[x * 4 + 3] = 255;   /* captures are opaque */
    }
    cairo_surface_destroy(surface);
    return 1;
}

static int l_screen_pixel(lua_State *L)
{
    Overlay *ov = check_overlay(L);
    int x = (int)luaL_checkinteger(L, 2), y = (int)luaL_checkinteger(L, 3);
    int ox = 0, oy = 0;
    GdkWindow *win, *root;
    GdkPixbuf *pix;
    if (!live(ov) || !(win = gtk_widget_get_window(ov->da))) return 0;
    gdk_window_process_all_updates();
    gdk_display_sync(gdk_window_get_display(win));
    g_usleep(60000);                    /* let a compositing window manager recompose (tests only) */
    gdk_window_get_origin(win, &ox, &oy);
    root = gdk_get_default_root_window();
    pix = gdk_pixbuf_get_from_window(root, ox + x / ov->scale, oy + y / ov->scale, 1, 1);
    if (!pix) return 0;
    {
        const guchar *p = gdk_pixbuf_get_pixels(pix);
        lua_pushinteger(L, p[0]); lua_pushinteger(L, p[1]); lua_pushinteger(L, p[2]);
    }
    g_object_unref(pix);
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
    GtkWidget *window = native_widget(dlg);
    GtkWidget *fixed;
    Overlay *ov;
    GdkWindow *gw;
    if (!window || !GTK_IS_WINDOW(window) || !gtk_widget_get_realized(window)) {
        lua_pushnil(L); lua_pushliteral(L, "dialog has no window yet (show it first)"); return 2;
    }
    fixed = gtk_bin_get_child(GTK_BIN(window));
    if (!fixed || !GTK_IS_FIXED(fixed)) {
        lua_pushnil(L); lua_pushliteral(L, "dialog has no inner container"); return 2;
    }
    ov = (Overlay *)lua_newuserdata(L, sizeof(*ov));
    memset(ov, 0, sizeof(*ov));
    luaL_getmetatable(L, OVERLAY_MT);
    lua_setmetatable(L, -2);
    ov->window = window;
    ov->fixed = fixed;
    ov->opacity = 1;
    refresh_cover(ov);

    ov->da = gtk_drawing_area_new();
    gtk_widget_add_events(ov->da, GDK_BUTTON_PRESS_MASK);
    ov->draw_id = g_signal_connect(ov->da, "draw", G_CALLBACK(on_draw), ov);
    ov->press_id = g_signal_connect(ov->da, "button-press-event", G_CALLBACK(on_press), ov);
    ov->alloc_id = g_signal_connect_after(fixed, "size-allocate", G_CALLBACK(on_fixed_allocate), ov);
    ov->destroy_id = g_signal_connect(window, "destroy", G_CALLBACK(on_window_destroy), ov);
    ov->scale_id = g_signal_connect(window, "notify::scale-factor", G_CALLBACK(on_scale_changed), ov);

    gtk_widget_set_child_visible(ov->da, FALSE);       /* hidden until a frame is shown */
    gtk_widget_set_size_request(ov->da, ov->cover_w / ov->scale > 0 ? ov->cover_w / ov->scale : 1,
                                ov->cover_h / ov->scale > 0 ? ov->cover_h / ov->scale : 1);
    gtk_fixed_put(GTK_FIXED(fixed), ov->da, 0, 0);
    gtk_widget_show(ov->da);
    gtk_widget_realize(ov->da);
    gw = gtk_widget_get_window(ov->da);
    if (!gw || !gdk_window_ensure_native(gw)) {
        overlay_close(ov);
        lua_pushnil(L);
        lua_pushliteral(L, "cannot create a native overlay window");
        return 2;
    }
    {
        cairo_region_t *none = cairo_region_create();
        gtk_widget_input_shape_combine_region(ov->da, none);   /* click-through until regions */
        cairo_region_destroy(none);
    }
    gdk_window_raise(gw);
    fit_overlay(ov);
    return 1;
}

static int l_supported(lua_State *L)
{
    GdkDisplay *display = gdk_display_get_default();
    if (!display) {
        lua_pushboolean(L, 0); lua_pushliteral(L, "no GTK display"); return 2;
    }
    if (!GDK_IS_X11_DISPLAY(display)) {
        lua_pushboolean(L, 0); lua_pushliteral(L, "the GTK compositor needs an X11 display"); return 2;
    }
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

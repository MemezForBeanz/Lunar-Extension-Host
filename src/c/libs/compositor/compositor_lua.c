#include "blend.h"
#include "compositor_internal.h"
#include <lua.h>
#include <lauxlib.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    BlendImage image;
    int released;
} Snapshot;

typedef struct {
    int32_t w, h;
    size_t length;
    uint8_t bytes[];
} Buffer;

static void field(lua_State *L, int idx, const char *name)
{
    lua_pushstring(L, name);
    lua_rawget(L, idx);
}

static int32_t integer_at(lua_State *L, int idx, const char *name, int32_t min)
{
    lua_Number value = lua_tonumber(L, idx);
    if (!lua_isnumber(L, idx) || lua_type(L, idx) != LUA_TNUMBER ||
        !(value >= (lua_Number)min && value <= (lua_Number)INT32_MAX) ||
        value != (lua_Number)(int32_t)value)
        luaL_error(L, "%s must be an integer in [%ld, %ld]", name,
                   (long)min, (long)INT32_MAX);
    return (int32_t)value;
}

static int32_t required_int(lua_State *L, int idx, const char *name, int32_t min)
{
    int32_t result;
    field(L, idx, name);
    result = integer_at(L, -1, name, min);
    lua_pop(L, 1);
    return result;
}

static int32_t optional_int(lua_State *L, int idx, const char *name,
                            int32_t fallback, int32_t min)
{
    int32_t result;
    field(L, idx, name);
    result = lua_isnil(L, -1) ? fallback : integer_at(L, -1, name, min);
    lua_pop(L, 1);
    return result;
}

static uint8_t alpha_at(lua_State *L, int idx)
{
    lua_Number a;
    field(L, idx, "alpha");
    a = lua_tonumber(L, -1);
    if (lua_type(L, -1) != LUA_TNUMBER || !(a >= 0 && a <= 1))
        luaL_error(L, "alpha must be a number in [0, 1]");
    lua_pop(L, 1);
    return (uint8_t)(a * 255 + 0.5);
}

static BlendRect rect_at(lua_State *L, int idx)
{
    BlendRect r;
    r.x = required_int(L, idx, "x", INT32_MIN);
    r.y = required_int(L, idx, "y", INT32_MIN);
    r.w = required_int(L, idx, "w", 0);
    r.h = required_int(L, idx, "h", 0);
    return r;
}

static int snapshot_gc(lua_State *L)
{
    Snapshot *s = (Snapshot *)luaL_checkudata(L, 1, "lunar.snapshot");
    free((void *)s->image.bytes);
    s->image.bytes = NULL;
    s->image.length = 0;
    s->released = 1;
    return 0;
}

static int snapshot_index(lua_State *L)
{
    Snapshot *s = (Snapshot *)luaL_checkudata(L, 1, "lunar.snapshot");
    const char *key = luaL_checkstring(L, 2);
    if (strcmp(key, "w") == 0) lua_pushinteger(L, s->image.w);
    else if (strcmp(key, "h") == 0) lua_pushinteger(L, s->image.h);
    else if (strcmp(key, "release") == 0) lua_pushcfunction(L, snapshot_gc);
    else lua_pushnil(L);
    return 1;
}

static int buffer_bytes(lua_State *L)
{
    Buffer *b = (Buffer *)luaL_checkudata(L, 1, "lunar.buffer");
    lua_pushlstring(L, (const char *)b->bytes, b->length);
    return 1;
}

static int buffer_pixel(lua_State *L)
{
    Buffer *b = (Buffer *)luaL_checkudata(L, 1, "lunar.buffer");
    int32_t x = integer_at(L, 2, "x", 0);
    int32_t y = integer_at(L, 3, "y", 0);
    const uint8_t *p;
    if (x >= b->w || y >= b->h) return luaL_error(L, "pixel coordinates outside buffer");
    p = b->bytes + ((size_t)y * (size_t)b->w + (size_t)x) * 4u;
    lua_pushinteger(L, p[0]); lua_pushinteger(L, p[1]);
    lua_pushinteger(L, p[2]); lua_pushinteger(L, p[3]);
    return 4;
}

static int buffer_index(lua_State *L)
{
    Buffer *b = (Buffer *)luaL_checkudata(L, 1, "lunar.buffer");
    const char *key = luaL_checkstring(L, 2);
    if (strcmp(key, "w") == 0) lua_pushinteger(L, b->w);
    else if (strcmp(key, "h") == 0) lua_pushinteger(L, b->h);
    else if (strcmp(key, "bytes") == 0) lua_pushcfunction(L, buffer_bytes);
    else if (strcmp(key, "pixel") == 0) lua_pushcfunction(L, buffer_pixel);
    else lua_pushnil(L);
    return 1;
}

uint8_t *compositor_new_snapshot(lua_State *L, int32_t w, int32_t h)
{
    size_t length;
    Snapshot *s;
    if (w <= 0 || h <= 0 || (size_t)w > SIZE_MAX / 4u || (size_t)h > SIZE_MAX / ((size_t)w * 4u))
        luaL_error(L, "snapshot dimensions out of range");
    length = (size_t)w * (size_t)h * 4u;
    s = (Snapshot *)lua_newuserdata(L, sizeof(*s));
    memset(s, 0, sizeof(*s));
    luaL_getmetatable(L, "lunar.snapshot");
    lua_setmetatable(L, -2);
    s->image.bytes = (uint8_t *)malloc(length);
    if (!s->image.bytes) luaL_error(L, "out of memory for snapshot");
    s->image.w = w; s->image.h = h; s->image.length = length;
    return (uint8_t *)s->image.bytes;
}

static int lua_image(lua_State *L)
{
    int32_t w = integer_at(L, 1, "image width", 1);
    int32_t h = integer_at(L, 2, "image height", 1);
    size_t length, got, i;
    const char *bytes = luaL_checklstring(L, 3, &got);
    if ((size_t)w > SIZE_MAX / 4u || (size_t)h > SIZE_MAX / ((size_t)w * 4u))
        return luaL_error(L, "image dimensions overflow byte size");
    length = (size_t)w * (size_t)h * 4u;
    if (got != length) return luaL_error(L, "image bytes length must be w*h*4");
    for (i = 0; i < length; i += 4u) {
        uint8_t a = (uint8_t)bytes[i + 3u];
        if ((uint8_t)bytes[i] > a || (uint8_t)bytes[i + 1u] > a ||
            (uint8_t)bytes[i + 2u] > a)
            return luaL_error(L, "image bytes must be premultiplied BGRA8");
    }
    memcpy(compositor_new_snapshot(L, w, h), bytes, length);
    return 1;
}

static void parse_sprite(lua_State *L, int idx, BlendSprite *s)
{
    const char *kind;
    memset(s, 0, sizeof(*s));
    if (!lua_istable(L, idx)) luaL_error(L, "sprite must be a table");
    field(L, idx, "kind");
    if (lua_type(L, -1) != LUA_TSTRING) luaL_error(L, "sprite kind must be a string");
    kind = lua_tostring(L, -1);
    if (strcmp(kind, "fill") == 0) s->kind = BLEND_FILL;
    else if (strcmp(kind, "rrect") == 0) s->kind = BLEND_RRECT;
    else if (strcmp(kind, "stroke") == 0) s->kind = BLEND_STROKE;
    else if (strcmp(kind, "image") == 0) s->kind = BLEND_IMAGE;
    else luaL_error(L, "unknown sprite kind '%s'", kind);
    lua_pop(L, 1);
    s->opacity = alpha_at(L, idx);
    if (s->kind == BLEND_IMAGE) {
        Snapshot *snap;
        field(L, idx, "snap");
        snap = (Snapshot *)luaL_checkudata(L, -1, "lunar.snapshot");
        if (snap->released) luaL_error(L, "image snapshot has been released");
        s->image = &snap->image;
        lua_pop(L, 1);
        s->source.x = optional_int(L, idx, "sx", 0, 0);
        s->source.y = optional_int(L, idx, "sy", 0, 0);
        if (s->source.x > snap->image.w || s->source.y > snap->image.h)
            luaL_error(L, "image source origin outside snapshot");
        s->source.w = optional_int(L, idx, "sw", snap->image.w - s->source.x, 0);
        s->source.h = optional_int(L, idx, "sh", snap->image.h - s->source.y, 0);
        if ((int64_t)s->source.x + s->source.w > snap->image.w ||
            (int64_t)s->source.y + s->source.h > snap->image.h)
            luaL_error(L, "image source rectangle outside snapshot");
        s->rect.x = required_int(L, idx, "x", INT32_MIN);
        s->rect.y = required_int(L, idx, "y", INT32_MIN);
        s->rect.w = s->source.w; s->rect.h = s->source.h;
    } else {
        s->rect = rect_at(L, idx);
        s->color = (uint32_t)required_int(L, idx, "color", 0);
        if (s->color > 0xffffffu) luaL_error(L, "color must be 0x000000..0xffffff");
        if (s->kind == BLEND_RRECT) s->radius = required_int(L, idx, "radius", 0);
        if (s->kind == BLEND_STROKE) s->thickness = required_int(L, idx, "thickness", 1);
    }
    field(L, idx, "clip");
    if (!lua_isnil(L, -1)) {
        if (!lua_istable(L, -1)) luaL_error(L, "clip must be a rectangle table");
        s->clip = rect_at(L, lua_gettop(L));
        s->has_clip = 1;
    }
    lua_pop(L, 1);
}

BlendSprite *compositor_parse_scene(lua_State *L, int idx, int32_t *w, int32_t *h, size_t *count)
{
    size_t n, i;
    BlendSprite *sprites;
    if (!lua_istable(L, idx)) luaL_error(L, "scene must be a table");
    *w = required_int(L, idx, "w", 1); *h = required_int(L, idx, "h", 1);
    if ((size_t)*w > SIZE_MAX / 4u || (size_t)*h > SIZE_MAX / ((size_t)*w * 4u))
        luaL_error(L, "scene dimensions overflow byte size");
    n = lua_objlen(L, idx);
    if (n > SIZE_MAX / sizeof(BlendSprite)) luaL_error(L, "too many sprites");
    sprites = (BlendSprite *)lua_newuserdata(L, n ? n * sizeof(*sprites) : 1u);
    /* Numeric keys must be a dense 1-based array; lua_objlen alone can hide holes. */
    lua_pushnil(L);
    while (lua_next(L, idx)) {
        if (lua_type(L, -2) == LUA_TNUMBER) {
            lua_Number k = lua_tonumber(L, -2);
            if (k < 1 || k > (lua_Number)n || k != (lua_Number)(size_t)k)
                luaL_error(L, "scene sprite indices must be dense and 1-based");
        }
        lua_pop(L, 1);
    }
    for (i = 0; i < n; ++i) {
        lua_rawgeti(L, idx, (int)i + 1);
        if (lua_isnil(L, -1)) luaL_error(L, "scene sprite array has a hole");
        parse_sprite(L, lua_gettop(L), &sprites[i]);
        lua_pop(L, 1);
    }
    *count = n;
    return sprites;
}

static int lua_render(lua_State *L)
{
    int32_t w, h;
    size_t n, count;
    BlendSprite *sprites = compositor_parse_scene(L, 1, &w, &h, &count);
    Buffer *b;
    const char *why = NULL;
    n = (size_t)w * (size_t)h * 4u;
    if (n > SIZE_MAX - sizeof(*b)) return luaL_error(L, "scene buffer too large");
    b = (Buffer *)lua_newuserdata(L, sizeof(*b) + n);
    b->w = w; b->h = h; b->length = n;
    luaL_getmetatable(L, "lunar.buffer"); lua_setmetatable(L, -2);
    if (!blend_render(b->bytes, n, w, h, sprites, count, &why))
        return luaL_error(L, "compositor render: %s", why ? why : "invalid scene");
    return 1;
}

int luaopen_compositor(lua_State *L)
{
    luaL_newmetatable(L, "lunar.snapshot");
    lua_pushcfunction(L, snapshot_gc); lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, snapshot_index); lua_setfield(L, -2, "__index");
    lua_pop(L, 1);
    luaL_newmetatable(L, "lunar.buffer");
    lua_pushcfunction(L, buffer_index); lua_setfield(L, -2, "__index");
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushcfunction(L, lua_image); lua_setfield(L, -2, "image");
    lua_pushcfunction(L, lua_render); lua_setfield(L, -2, "render");
    compositor_backend_register(L);
    return 1;
}

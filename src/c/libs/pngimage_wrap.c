/* Runtime pack logos. Keep IM out of the host; decode PNG only. */
#include <lua.h>
#include <lauxlib.h>
#include <iup.h>
#include <iuplua.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_MAX_DIMENSIONS 8192
#define STB_IMAGE_IMPLEMENTATION
#include "stb/stb_image.h"

static int failure(lua_State *L, const char *reason)
{
    lua_pushnil(L);
    lua_pushstring(L, reason);
    return 2;
}

/* Area average of premultiplied RGB and alpha; unpremultiply only at output.
 * Fractional pixel coverage matters when shrinking large wordmarks to 18px. */
static void resize_rgba(const unsigned char *src, int sw, int sh,
                        unsigned char *dst, int dw, int dh)
{
    int x, y;
    for (y = 0; y < dh; ++y) {
        double y0 = (double)y * sh / dh, y1 = (double)(y + 1) * sh / dh;
        for (x = 0; x < dw; ++x) {
            double x0 = (double)x * sw / dw, x1 = (double)(x + 1) * sw / dw;
            double sum[4] = {0, 0, 0, 0};
            double area = (x1 - x0) * (y1 - y0);
            int sx, sy, c;
            unsigned char *out = dst + ((size_t)y * dw + x) * 4;
            for (sy = (int)floor(y0); sy < (int)ceil(y1) && sy < sh; ++sy) {
                double wy = fmin(y1, sy + 1.0) - fmax(y0, sy);
                for (sx = (int)floor(x0); sx < (int)ceil(x1) && sx < sw; ++sx) {
                    double weight = wy * (fmin(x1, sx + 1.0) - fmax(x0, sx));
                    const unsigned char *p = src + ((size_t)sy * sw + sx) * 4;
                    double alpha = p[3] * weight;
                    for (c = 0; c < 3; ++c) sum[c] += p[c] * alpha;
                    sum[3] += alpha;
                }
            }
            for (c = 0; c < 3; ++c)
                out[c] = sum[3] > 0 ? (unsigned char)fmin(255, floor(sum[c] / sum[3] + 0.5)) : 0;
            out[3] = (unsigned char)fmin(255, floor(sum[3] / area + 0.5));
        }
    }
}

/* pngimage.to_image(path, height) -> IUP image | nil, error.
 * Both input and output dimensions are bounded before allocating pixels. */
static int l_to_image(lua_State *L)
{
    const char *path = lua_tostring(L, 1);
    lua_Number requested = lua_tonumber(L, 2);
    FILE *file;
    long length;
    unsigned char *encoded, *pixels, *scaled;
    int sw, sh, channels, dw, dh;
    Ihandle *image;
    if (!path || !isfinite(requested) || requested < 1 || requested > 8192)
        return failure(L, "invalid path or height");
    dh = (int)requested;
    file = fopen(path, "rb");
    if (!file) return failure(L, "cannot open PNG");
    if (fseek(file, 0, SEEK_END) != 0 || (length = ftell(file)) <= 0 || length > 8 * 1024 * 1024
        || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return failure(L, "PNG is empty, unreadable or exceeds 8 MiB");
    }
    encoded = (unsigned char *)malloc((size_t)length);
    if (!encoded) { fclose(file); return failure(L, "out of memory"); }
    if (fread(encoded, 1, (size_t)length, file) != (size_t)length) {
        free(encoded); fclose(file); return failure(L, "cannot read PNG");
    }
    fclose(file);
    if (!stbi_info_from_memory(encoded, (int)length, &sw, &sh, &channels)
        || sw <= 0 || sh <= 0 || sw > 8192 || sh > 8192) {
        free(encoded); return failure(L, "invalid PNG or dimensions exceed 8192");
    }
    dw = (int)ceil((double)sw * dh / sh);
    if (dw < 1 || dw > 8192) {
        free(encoded); return failure(L, "output width exceeds 8192");
    }
    pixels = stbi_load_from_memory(encoded, (int)length, &sw, &sh, &channels, 4);
    free(encoded);
    if (!pixels) return failure(L, "PNG decode failed");
    scaled = (unsigned char *)malloc((size_t)dw * dh * 4);
    if (!scaled) { stbi_image_free(pixels); return failure(L, "out of memory"); }
    resize_rgba(pixels, sw, sh, scaled, dw, dh);
    stbi_image_free(pixels);
    image = IupImageRGBA(dw, dh, scaled); /* IUP copies the pixel buffer. */
    free(scaled);
    if (!image) return failure(L, "IupImageRGBA failed");
    iuplua_pushihandle(L, image);
    return 1;
}

int luaopen_pngimage(lua_State *L)
{
    static const luaL_Reg lib[] = { {"to_image", l_to_image}, {NULL, NULL} };
    luaL_newlib(L, lib);
    return 1;
}

#include "blend.h"
#include <limits.h>
#include <string.h>

uint8_t blend_mul(uint8_t a, uint8_t b)
{
    unsigned t = (unsigned)a * b + 128u;
    return (uint8_t)((t + (t >> 8)) >> 8);
}

static int buffer_size(int32_t w, int32_t h, size_t *n)
{
    if (w <= 0 || h <= 0 || (size_t)w > SIZE_MAX / 4u ||
        (size_t)h > SIZE_MAX / ((size_t)w * 4u)) return 0;
    *n = (size_t)w * (size_t)h * 4u;
    return 1;
}

static int valid_rect(BlendRect r)
{
    return r.w >= 0 && r.h >= 0;
}

static int valid_sprite(const BlendSprite *s)
{
    size_t n;
    if (s->kind < BLEND_FILL || s->kind > BLEND_IMAGE ||
        !valid_rect(s->rect) || (s->has_clip && !valid_rect(s->clip))) return 0;
    if (s->kind == BLEND_IMAGE) {
        if (!s->image || !s->image->bytes ||
            !buffer_size(s->image->w, s->image->h, &n) ||
            s->image->length < n || !valid_rect(s->source) ||
            s->source.x < 0 || s->source.y < 0 ||
            (int64_t)s->source.x + s->source.w > s->image->w ||
            (int64_t)s->source.y + s->source.h > s->image->h ||
            s->rect.w != s->source.w || s->rect.h != s->source.h) return 0;
    } else if (s->color > 0xffffffu ||
               (s->kind == BLEND_RRECT && s->radius < 0) ||
               (s->kind == BLEND_STROKE && s->thickness <= 0)) return 0;
    return 1;
}

/* blend_mul for every pair, built once: the inner loops are table lookups.
 * Rendering happens on the UI thread only, so the lazy init needs no lock. */
static uint8_t g_mul[256][256];
static int g_mul_ready;

static void init_mul(void)
{
    unsigned a, b;
    if (g_mul_ready) return;
    for (a = 0; a < 256; ++a)
        for (b = 0; b < 256; ++b) g_mul[a][b] = blend_mul((uint8_t)a, (uint8_t)b);
    g_mul_ready = 1;
}

/* Source-over of one premultiplied pixel. */
static void over(uint8_t *dst, const uint8_t src[4])
{
    const uint8_t *inv = g_mul[255u - src[3]];
    unsigned k;
    for (k = 0; k < 4; ++k) {
        unsigned value = src[k] + inv[dst[k]];
        dst[k] = (uint8_t)(value > 255u ? 255u : value);
    }
}

/* Source-over of the same premultiplied pixel across `n` pixels. An opaque
 * source replaces the destination exactly (mul(dst, 0) = 0), so it is a copy. */
static void span_uniform(uint8_t *dst, int64_t n, const uint8_t src[4])
{
    int64_t i;
    if (n <= 0) return;
    if (src[3] == 255) {
        for (i = 0; i < n; ++i, dst += 4) memcpy(dst, src, 4);
        return;
    }
    if (!src[0] && !src[1] && !src[2] && !src[3]) return;   /* transparent: no-op */
    {
        const uint8_t *inv = g_mul[255u - src[3]];
        for (i = 0; i < n; ++i, dst += 4) {
            unsigned k;
            for (k = 0; k < 4; ++k) {
                unsigned value = src[k] + inv[dst[k]];
                dst[k] = (uint8_t)(value > 255u ? 255u : value);
            }
        }
    }
}

/* Source-over of `n` image pixels at sprite opacity `o`. */
static void span_image(uint8_t *dst, const uint8_t *pixel, int64_t n, uint8_t o)
{
    int64_t i;
    if (o == 255) {
        for (i = 0; i < n; ++i, dst += 4, pixel += 4) {
            if (pixel[3] == 255) memcpy(dst, pixel, 4);
            else over(dst, pixel);
        }
        return;
    }
    {
        const uint8_t *mo = g_mul[o];
        for (i = 0; i < n; ++i, dst += 4, pixel += 4) {
            uint8_t src[4];
            src[0] = mo[pixel[0]]; src[1] = mo[pixel[1]];
            src[2] = mo[pixel[2]]; src[3] = mo[pixel[3]];
            over(dst, src);
        }
    }
}

/* Coordinates scaled by 8 keep the fixed sample rule exact and avoid floats.
 * Called only for pixels inside a corner square; everywhere else coverage is
 * full (see the band classification in render_rrect). */
static uint8_t corner_coverage(const BlendSprite *s, int32_t radius, int64_t px, int64_t py)
{
    int count = 0, i, j;
    int64_t left = (int64_t)s->rect.x * 8, top = (int64_t)s->rect.y * 8;
    int64_t right = ((int64_t)s->rect.x + s->rect.w) * 8;
    int64_t bottom = ((int64_t)s->rect.y + s->rect.h) * 8;
    int64_t rr = (int64_t)radius * 8;
    for (j = 0; j < 4; ++j) for (i = 0; i < 4; ++i) {
        int64_t sx = px * 8 + 2 * i + 1;
        int64_t sy = py * 8 + 2 * j + 1;
        int64_t dx = sx < left + rr ? sx - (left + rr) :
                     sx > right - rr ? sx - (right - rr) : 0;
        int64_t dy = sy < top + rr ? sy - (top + rr) :
                     sy > bottom - rr ? sy - (bottom - rr) : 0;
        if (dx * dx + dy * dy <= rr * rr) ++count;
    }
    return (uint8_t)((count * 255 + 8) / 16);
}

#define PIXEL(out, w, x, y) ((out) + ((size_t)(y) * (size_t)(w) + (size_t)(x)) * 4u)

static void render_rrect(uint8_t *out, int32_t w, const BlendSprite *s, const uint8_t base[4],
                         int64_t x0, int64_t y0, int64_t x1, int64_t y1)
{
    int32_t radius = s->radius;
    int32_t half = s->rect.w < s->rect.h ? s->rect.w / 2 : s->rect.h / 2;
    int64_t left, right, top, bottom, y;
    if (radius > half) radius = half;
    if (radius > BLEND_MAX_RADIUS) radius = BLEND_MAX_RADIUS;
    left = s->rect.x; right = left + s->rect.w;
    top = s->rect.y; bottom = top + s->rect.h;
    for (y = y0; y < y1; ++y) {
        /* Rows outside the top and bottom corner bands are full coverage. A
         * pixel's samples all fall on one side of an integer band edge, so this
         * classification is exact. */
        if (!radius || (y >= top + radius && y < bottom - radius)) {
            span_uniform(PIXEL(out, w, x0, y), x1 - x0, base);
            continue;
        }
        {
            int64_t mid0 = left + radius, mid1 = right - radius, x;
            int64_t a = x0 > mid0 ? x0 : mid0, b = x1 < mid1 ? x1 : mid1;
            for (x = x0; x < x1 && x < mid0; ++x) {
                uint8_t c = corner_coverage(s, radius, x, y), src[4];
                src[0] = g_mul[base[0]][c]; src[1] = g_mul[base[1]][c];
                src[2] = g_mul[base[2]][c]; src[3] = g_mul[base[3]][c];
                over(PIXEL(out, w, x, y), src);
            }
            if (a < b) span_uniform(PIXEL(out, w, a, y), b - a, base);
            for (x = (x0 > mid1 ? x0 : (mid1 > mid0 ? mid1 : mid0)); x < x1; ++x) {
                uint8_t c = corner_coverage(s, radius, x, y), src[4];
                src[0] = g_mul[base[0]][c]; src[1] = g_mul[base[1]][c];
                src[2] = g_mul[base[2]][c]; src[3] = g_mul[base[3]][c];
                over(PIXEL(out, w, x, y), src);
            }
        }
    }
}

static void render_stroke(uint8_t *out, int32_t w, const BlendSprite *s, const uint8_t base[4],
                          int64_t x0, int64_t y0, int64_t x1, int64_t y1)
{
    int64_t left = s->rect.x, top = s->rect.y;
    int64_t right = left + s->rect.w, bottom = top + s->rect.h;
    int64_t t = s->thickness, y;
    for (y = y0; y < y1; ++y) {
        int64_t l_end = left + t, r_start = right - t;
        if (y < top + t || y >= bottom - t || l_end >= r_start) {
            span_uniform(PIXEL(out, w, x0, y), x1 - x0, base);   /* full row of the stroke */
            continue;
        }
        {
            int64_t a0 = x0, a1 = x1 < l_end ? x1 : l_end;      /* left strip */
            int64_t b0 = x0 > r_start ? x0 : r_start, b1 = x1;  /* right strip */
            if (a0 < a1) span_uniform(PIXEL(out, w, a0, y), a1 - a0, base);
            if (b0 < b1) span_uniform(PIXEL(out, w, b0, y), b1 - b0, base);
        }
    }
}

int blend_render(uint8_t *out, size_t out_length, int32_t w, int32_t h,
                 const BlendSprite *sprites, size_t count, const char **why)
{
    size_t n, i;
    if (!buffer_size(w, h, &n) || !out || out_length < n) {
        if (why) *why = "invalid output buffer or surface dimensions";
        return 0;
    }
    if (count && !sprites) {
        if (why) *why = "missing sprite list";
        return 0;
    }
    for (i = 0; i < count; ++i) if (!valid_sprite(&sprites[i])) {
        if (why) *why = "invalid sprite bounds or fields";
        return 0;
    }
    init_mul();
    memset(out, 0, n);
    for (i = 0; i < count; ++i) {
        const BlendSprite *s = &sprites[i];
        int64_t x0 = s->rect.x, y0 = s->rect.y;
        int64_t x1 = x0 + s->rect.w, y1 = y0 + s->rect.h;
        int64_t y;
        uint8_t base[4];
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        if (x1 > w) x1 = w;
        if (y1 > h) y1 = h;
        if (s->has_clip) {
            if (x0 < s->clip.x) x0 = s->clip.x;
            if (y0 < s->clip.y) y0 = s->clip.y;
            if (x1 > (int64_t)s->clip.x + s->clip.w) x1 = (int64_t)s->clip.x + s->clip.w;
            if (y1 > (int64_t)s->clip.y + s->clip.h) y1 = (int64_t)s->clip.y + s->clip.h;
        }
        if (x0 >= x1 || y0 >= y1 || !s->opacity) continue;
        base[0] = blend_mul((uint8_t)s->color, s->opacity);
        base[1] = blend_mul((uint8_t)(s->color >> 8), s->opacity);
        base[2] = blend_mul((uint8_t)(s->color >> 16), s->opacity);
        base[3] = s->opacity;
        switch (s->kind) {
        case BLEND_FILL:
            for (y = y0; y < y1; ++y) span_uniform(PIXEL(out, w, x0, y), x1 - x0, base);
            break;
        case BLEND_RRECT:
            render_rrect(out, w, s, base, x0, y0, x1, y1);
            break;
        case BLEND_STROKE:
            render_stroke(out, w, s, base, x0, y0, x1, y1);
            break;
        case BLEND_IMAGE:
            for (y = y0; y < y1; ++y) {
                size_t sx = (size_t)(x0 - s->rect.x + s->source.x);
                size_t sy = (size_t)(y - s->rect.y + s->source.y);
                span_image(PIXEL(out, w, x0, y),
                           s->image->bytes + (sy * (size_t)s->image->w + sx) * 4u,
                           x1 - x0, s->opacity);
            }
            break;
        }
    }
    return 1;
}

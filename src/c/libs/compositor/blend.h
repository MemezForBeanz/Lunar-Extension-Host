#ifndef LUNAR_COMPOSITOR_BLEND_H
#define LUNAR_COMPOSITOR_BLEND_H

#include <stddef.h>
#include <stdint.h>

/* Portable top-down BGRA8 premultiplied renderer. All rectangles use half-open
 * pixel bounds. Coordinates are signed; dimensions are nonnegative. The caller
 * owns the output and every image byte array for the duration of blend_render.
 * A frame begins with transparent black, including an empty sprite list.
 *
 * Rounded corners: clamp integer radius to floor(min(w,h)/2), then to
 * BLEND_MAX_RADIUS. For each pixel
 * inside the rectangle, test the centers of a fixed 4x4 grid at offsets
 * (2*i+1)/8, (2*j+1)/8 for i,j=0..3. A sample is inside if it lies in the
 * central horizontal/vertical bars, or its squared distance to its corner's
 * circle center is <= radius^2. Convert the count of inside samples to byte
 * coverage as floor((count*255+8)/16), then multiply every premultiplied BGRA
 * channel by coverage using blend_mul. Radius zero gives full coverage.
 * Stroke uses nonoverlapping top, bottom, left, right strips so each pixel is
 * blended once even when thickness exceeds half the rectangle's dimensions. */

/* Bounds 8x-scaled corner distance squares safely within signed int64. */
#define BLEND_MAX_RADIUS (1 << 20)

typedef struct {
    int32_t x, y, w, h;
} BlendRect;

typedef struct {
    int32_t w, h;
    const uint8_t *bytes;
    size_t length;
} BlendImage;

typedef enum {
    BLEND_FILL, BLEND_RRECT, BLEND_STROKE, BLEND_IMAGE
} BlendKind;

typedef struct {
    BlendKind kind;
    BlendRect rect;
    BlendRect clip;
    int has_clip;
    uint32_t color;             /* straight 0xRRGGBB */
    uint8_t opacity;            /* round(alpha * 255) */
    int32_t radius, thickness;
    const BlendImage *image;
    BlendRect source;
} BlendSprite;

uint8_t blend_mul(uint8_t a, uint8_t b);
/* Returns 1 on success; on failure returns 0 and sets *why to a static string. */
int blend_render(uint8_t *out, size_t out_length, int32_t w, int32_t h,
                 const BlendSprite *sprites, size_t count, const char **why);

#endif

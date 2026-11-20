/* Glass primitives shared by the D3D11 (lunarimgui.cpp) and SDL (lunarimgui_sdl.cpp) hosts.
 *
 * Each surface of the Lunar glass is drawn in a handful of calls, whatever its size or
 * radius: one rounded image (the softened backdrop, sampled through a UV sub-rectangle),
 * one nine-slice image (the floating shadow, from a small pre-baked texture) and one rim
 * stroke whose colour runs from the lit upper-left shoulder to the far edge. */
#pragma once
#include "imgui.h"
#include "imgui_internal.h"
#include <algorithm>
#include <cmath>

namespace lunar_glass {

inline ImU32 lerp_color(ImU32 a, ImU32 b, float t) {
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    int out = 0;
    for (int s = 0; s < 32; s += 8) {
        float ca = (float)((a >> s) & 0xFF), cb = (float)((b >> s) & 0xFF);
        out |= ((int)(ca + (cb - ca) * t + 0.5f) & 0xFF) << s;
    }
    return (ImU32)out;
}

/* Recolour vertices [v0, v1): `col` decides RGB and alpha, the vertex's own alpha (0 on
   anti-aliasing fringes, 255 on the line) scales it. */
template <class F> inline void shade(ImDrawList *dl, int v0, int v1, F col) {
    for (int i = v0; i < v1; i++) {
        ImDrawVert &v = dl->VtxBuffer[i];
        ImU32 c = col(v.pos);
        unsigned own = (v.col >> IM_COL32_A_SHIFT) & 0xFF;
        unsigned a = (((c >> IM_COL32_A_SHIFT) & 0xFF) * own + 127) / 255;
        v.col = (c & ~IM_COL32_A_MASK) | (a << IM_COL32_A_SHIFT);
    }
}

/* A rounded image whose texture is sampled from (u1,v1)-(u2,v2), not the whole image. */
inline void image_rounded_uv(ImDrawList *dl, ImTextureRef tex, float x1, float y1, float x2, float y2,
                             float u1, float v1, float u2, float v2, ImU32 col, float rounding, int flags) {
    dl->AddImageRounded(tex, ImVec2(x1, y1), ImVec2(x2, y2), ImVec2(u1, v1), ImVec2(u2, v2), col, rounding,
                        (ImDrawFlags)flags);
}

/* Nine-slice: the corners keep their size (bx, by window pixels; ub, vb of the texture),
   the edges stretch along one axis and the centre along both. Nine quads, one call. */
inline void image_nine(ImDrawList *dl, ImTextureRef tex, float x1, float y1, float x2, float y2,
                       float bx, float by, float ub, float vb, ImU32 col) {
    if (x2 <= x1 || y2 <= y1) return;
    bx = std::min(bx, (x2 - x1) * 0.5f); by = std::min(by, (y2 - y1) * 0.5f);
    const float xs[4] = { x1, x1 + bx, x2 - bx, x2 }, ys[4] = { y1, y1 + by, y2 - by, y2 };
    const float us[4] = { 0, ub, 1 - ub, 1 }, vs[4] = { 0, vb, 1 - vb, 1 };
    const bool push = tex != dl->_CmdHeader.TexRef;
    if (push) dl->PushTexture(tex);
    dl->PrimReserve(9 * 6, 9 * 4);
    for (int j = 0; j < 3; j++)
        for (int i = 0; i < 3; i++)
            dl->PrimRectUV(ImVec2(xs[i], ys[j]), ImVec2(xs[i + 1], ys[j + 1]), ImVec2(us[i], vs[j]),
                           ImVec2(us[i + 1], vs[j + 1]), col);
    if (push) dl->PopTexture();
}

/* The curved edge (a bevel `thick` px wide): a rim on the outer contour, `hi` at the
   upper-left shoulder easing to `lo` at the far corner, and an inner lower edge in `inner`
   that fades out up the sides. Either part may be fully transparent to skip it. */
inline void rim(ImDrawList *dl, float x1, float y1, float x2, float y2, float rounding,
                ImU32 hi, ImU32 lo, ImU32 inner, int flags, float thick = 1.0f) {
    thick = std::max(1.0f, thick);
    const float half = thick * 0.5f;
    float w = x2 - x1, h = y2 - y1;
    if (w <= 2 || h <= 2) return;
    rounding = std::min(rounding, std::min(w, h) * 0.5f);
    if ((hi | lo) & IM_COL32_A_MASK) {
        int v0 = dl->VtxBuffer.Size;
        dl->AddRect(ImVec2(x1 + half, y1 + half), ImVec2(x2 - half, y2 - half), IM_COL32_WHITE,
                    std::max(0.0f, rounding - half), thick, (ImDrawFlags)flags);
        /* Project onto the diagonal: wide strips run left to right, tall rails top to bottom. */
        ImVec2 d(w, h);
        float dd = d.x * d.x + d.y * d.y;
        shade(dl, v0, dl->VtxBuffer.Size, [&](ImVec2 p) {
            float t = ((p.x - x1) * d.x + (p.y - y1) * d.y) / dd;
            t = t < 0 ? 0 : (t > 1 ? 1 : t);
            return lerp_color(hi, lo, 1 - (1 - t) * (1 - t));
        });
    }
    if (inner & IM_COL32_A_MASK) {
        float in = thick + half;
        float r = std::max(1.0f, rounding - thick);
        float top = y2 - in - r;
        int v0 = dl->VtxBuffer.Size;
        dl->PathArcTo(ImVec2(x2 - in - r, top), r, 0.0f, IM_PI * 0.5f);
        dl->PathArcTo(ImVec2(x1 + in + r, top), r, IM_PI * 0.5f, IM_PI);
        dl->PathStroke(IM_COL32_WHITE, thick, 0);
        shade(dl, v0, dl->VtxBuffer.Size, [&](ImVec2 p) {
            float t = (p.y - top) / r;
            t = t < 0 ? 0 : (t > 1 ? 1 : t);
            unsigned a = (unsigned)(((inner >> IM_COL32_A_SHIFT) & 0xFF) * t + 0.5f);
            return (inner & ~IM_COL32_A_MASK) | (a << IM_COL32_A_SHIFT);
        });
    }
}

} // namespace lunar_glass

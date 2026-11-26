/* Liquid Glass on the GPU (core.ui.Glass), Direct3D 11, hardware devices only.
 *
 * Included by lunarimgui.cpp inside its namespace, after State `g`. On WARP none of this
 * is made: core.ui.Glass asks lunar_ui_glass_ready() each frame and keeps its baked path.
 *
 * Surfaces (lunar_ui_glass `kind`):
 *   0 floating  menus, dropdowns, palette, toasts, Activity: a lip of glass round an opaque
 *               text well (drawn by Lua), over a copy of what is under it, light blur
 *               (1/4 resolution), easing into the well's colour over its last px.
 *   1 chrome    title strip, rail caps, status bar: lies on the floor, the baked backdrop
 *               whose sharp and softened images are already on the GPU, so it samples those
 *               (no copy, no blur).
 *   2 live      the Media transport: what is under it (the nearest artwork, extended under
 *               it by Lua), strong blur (1/8 resolution and back), its luminance bounded
 *               for its labels.
 *   3 frost     a tooltip: no well; the whole body is strongly blurred glass, its luminance
 *               bounded so its text keeps its contrast whatever lies under it.
 *
 * Cost model (lg-shader-1.md, Efficiency):
 *   - No glass on screen: nothing at all (no copy, no blur, no query, no textures made).
 *     Chrome alone: one draw per surface, no copy, no textures made.
 *   - What a surface copies is what was drawn before it. Glass in a later list than the
 *     main window's background layer (its foreground layer, a dialog or overlay window's
 *     own) shares one copy of the regions under it (the glass rects widened by the
 *     refraction/blur margin, merged where that saves work) taken after that layer with
 *     CopySubresourceRegion. Glass inside the background layer (the transport, a dialog
 *     drawn in the window) copies its region at its own callback, before it draws: a copy
 *     taken after it would hold the glass itself, and it would refract its own rim. All
 *     copies land in the same textures at their own place.
 *   - One blur chain for both: full -> 1/4 (16 texels in 4 bilinear taps) is the light
 *     blur; dual-Kawase 1/4 -> 1/8 and back up to 1/4 the strong one, run only when a
 *     surface samples it. Each pass is one draw covering every region.
 *   - Copy and blur are skipped when nothing under the glass changed: the background
 *     layer's commands reaching the regions (vertices, indices, textures, clips and the
 *     callbacks' data) hash as last frame, with the same regions and no texture made or
 *     updated since (g.texture_revision), hashed in one pass over the layer (each copy's hash
 *     a running prefix up to its callback). The textures count as valid only after every
 *     step of the copy and blur that filled them succeeded; where two copies meet, those two
 *     are not kept for the next frame (the others are).
 *   - Stacked floating glass (a submenu over its menu, a dropdown over a dialog) samples the
 *     background layer, not the glass beneath it: the shared copy is taken once, after that
 *     layer, so the upper surface refracts the window under both, not the lower surface.
 *     Cheaper, and the opaque wells keep both readable; it is deliberate, not a bug.
 *   - Blur levels write their regions rounded outward (floor(min / s), ceil(max / s)), and
 *     every read, the surface's included, stops at the centre of the last texel written,
 *     ceil(extent / s) - 0.5: glass at the window's right or bottom edge never reads a
 *     texel no pass wrote.
 *   - A surface whose copy failed, whose texture is missing or whose constants would not
 *     map draws its rounded tint (never stale pixels, never nothing).
 *   - Each surface: one callback (shader, constants, two textures), one quad (floating:
 *     only the ring round its well), one state reset; a single pixel-shader pass.
 *   - Textures are made at the monitor's size (rounded to 256 px) the first time floating
 *     or live glass is on screen, and re-made only if the window outgrows them; shaders
 *     and state objects once per device; nothing uploaded; per-frame vectors keep their
 *     capacity.
 * LUNAR_GPU_TIMING=1 adds D3D11 timestamp queries round the glass work (read back up to
 * three frames later, never stalling) for renderer().glass_gpu_*. */

const char *GLASS_HLSL = R"(
cbuffer D : register(b0) {
    float4 src_info;      /* 1/src size, last valid src px */
    float4 dst_info;      /* dest level size w h, dest->src scale, level shift factor (1 << shift) */
    float4 regions[16];   /* level-0 px x0 y0 x1 y1 */
};
struct VO { float4 pos : SV_POSITION; };
/* six vertices per region: one draw covers them all. Bounds round outward in the
   destination level (floor(min / s), ceil(max / s)): a region ending mid-texel (the window's
   right or bottom edge) still writes its last texel, which the reads below clamp to. */
VO vs_regions(uint id : SV_VertexID) {
    float4 r = regions[id / 6] / dst_info.w;
    r.xy = floor(r.xy); r.zw = ceil(r.zw);
    uint k = id % 6;
    float2 c = float2((k == 1 || k == 2 || k == 4) ? r.z : r.x, (k == 2 || k == 4 || k == 5) ? r.w : r.y);
    VO o; o.pos = float4(c / dst_info.xy * float2(2, -2) + float2(-1, 1), 0, 1); return o;
}
Texture2D src : register(t0);
SamplerState smp : register(s1);
float4 tap(float2 p) { return src.SampleLevel(smp, clamp(p, 0.5, src_info.zw) * src_info.xy, 0); }
/* full -> 1/4: the 4x4 block, four bilinear taps */
float4 ps_down4(VO i) : SV_Target {
    float2 p = i.pos.xy * 4;
    return (tap(p + float2(-1, -1)) + tap(p + float2(1, -1)) + tap(p + float2(-1, 1)) + tap(p + float2(1, 1))) * 0.25;
}
float4 ps_down(VO i) : SV_Target {
    float2 p = i.pos.xy * 2;
    return (tap(p) * 4 + tap(p + float2(-1, -1)) + tap(p + float2(1, -1)) + tap(p + float2(-1, 1)) + tap(p + float2(1, 1))) / 8;
}
float4 ps_up(VO i) : SV_Target {
    float2 p = i.pos.xy * 0.5;
    float4 s = tap(p + float2(-1, 0)) + tap(p + float2(1, 0)) + tap(p + float2(0, -1)) + tap(p + float2(0, 1));
    s += 2 * (tap(p + float2(-0.5, -0.5)) + tap(p + float2(0.5, -0.5)) + tap(p + float2(-0.5, 0.5)) + tap(p + float2(0.5, 0.5)));
    return s / 12;
}

cbuffer G : register(b0) {
    float4 rect;    /* x1 y1 x2 y2, main-client px */
    float4 frame;   /* origin x y; px -> uv scale x y */
    float4 shape;   /* valid w h of the sample (px), corner radius, lens falloff (px in from the rim) */
    float4 optic;   /* displacement at the rim px, hover lift, opacity, hollow depth (0: none) */
    float4 tint;    /* rgb; a: the tint's share over what is under it */
    float4 rim;     /* rgb; a: the specular lobe's peak alpha */
    float4 inner;   /* rgb; a: the inner shade's alpha */
    float4 well;    /* the opaque well's rgb; a: px over which the glass eases into it (0: none) */
    float4 extra;   /* chromatic split px per channel, lobe floor alpha, blur share at the rim (<0: sharp rim), 0 */
    float4 light;   /* toward the light xy; luminance at most z, at least w (1, 0: unbounded) */
    float4 more;    /* px in from the rim where it is all blur; 1: no valid copy this frame (the tint alone);
                       the last written blur texel's centre x y (px) */
};
Texture2D sharp : register(t1); Texture2D blurred : register(t2);
struct PI { float4 pos : SV_POSITION; float4 col : COLOR0; float2 uv : TEXCOORD0; };
float3 at(Texture2D t, float2 p) { return t.SampleLevel(smp, clamp(p, 0.5, shape.xy - 0.5) * frame.zw, 0).rgb; }
/* the blur is at 1/4: its reads stop at the centre of the last texel the chain wrote */
float3 at_blur(float2 p) { return blurred.SampleLevel(smp, clamp(p, 0.5, more.zw) * frame.zw, 0).rgb; }
float3 to_lin(float3 c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
float3 to_srgb(float3 c) { return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055; }
/* the lit result's luminance at most light.z, at least light.w (labels keep their contrast) */
float3 bound_lum(float3 col) {
    float3 lin = to_lin(saturate(col));
    float y = dot(lin, float3(0.2126, 0.7152, 0.0722));
    if (y > light.z) lin *= light.z / y;
    y = dot(lin, float3(0.2126, 0.7152, 0.0722));
    /* raised to the floor keeping its hue: scaled toward the gamut's edge first, and
       only the rest of the way by mixing in white */
    if (y < light.w) {
        lin *= min(light.w / max(y, 1e-4), 1 / max(max(lin.r, max(lin.g, lin.b)), 1e-4));
        y = dot(lin, float3(0.2126, 0.7152, 0.0722));
        if (y < light.w) lin += (1 - lin) * ((light.w - y) / max(1e-4, 1 - y));
    }
    return to_srgb(lin);
}
float4 ps_glass(PI i) : SV_Target {
    float2 p = i.pos.xy + frame.xy;
    float2 c = (rect.xy + rect.zw) * 0.5, hs = (rect.zw - rect.xy) * 0.5;
    float r = min(shape.z, min(hs.x, hs.y));
    float2 d = p - c;
    float2 q = abs(d) - (hs - r);
    float sd = length(max(q, 0)) + min(max(q.x, q.y), 0) - r;
    /* coverage over a 1.25 px band centred on the edge (a 1 px step read as stairs on
       the larger radii); the quad reaches 1 px past the rect, so the band fits */
    float cov = saturate(0.5 - sd * 0.8) * optic.z;         /* the quad's own colour is transparent */
    if (cov <= 0) discard;
    float depth = max(0, -sd);
    /* the body of a surface with no well (the veil, chrome, the transport): past the lens band it is
       the scene as it is, tinted and bounded; no lens, normal, lobe or shade work there */
    [branch] if (optic.w <= 0 && well.a <= 0 && more.y < 0.5 && depth > shape.w + 2) {
        float3 b = lerp(at_blur(p), tint.rgb, tint.a);
        float b_hi = max(b.r, max(b.g, b.b)), b_lo = saturate(min(b.r, min(b.g, b.b)));
        [branch] if ((light.z < 1 && b_hi * b_hi > light.z) || (light.w > 0 && b_lo * b_lo * sqrt(b_lo) < light.w))
            b = bound_lum(b);
        return float4(b, cov);
    }
    /* under the opaque well nothing shows; the well's own anti-aliased edge (ImGui's 1 px
       fringe, half of it outside) lies over glass that already has the well's colour */
    if (optic.w > 0 && depth > optic.w + 1.5) discard;
    float2 sg = float2(d.x < 0 ? -1 : 1, d.y < 0 ? -1 : 1);
    float2 m = max(q, 0);
    float2 gr = (m.x + m.y > 0) ? normalize(m) : (q.x > q.y ? float2(1, 0) : float2(0, 1));
    float2 n = sg * gr;                                     /* outward normal */
    float u = 1 - saturate(depth / max(1, shape.w));        /* 1 at the rim, 0 past the falloff */
    float lens = optic.x * (1 - sqrt(saturate(1 - u * u))); /* ~0 inside, rising to the rim */
    float2 sp = p - n * lens;                               /* refracted inward */
    /* text-heavy edges: mostly blurred even at the rim, fully 3 px in (no legible glyph
       fragments); chrome over the floor: sharper toward the rim. Where it is all blur
       (the body), the sharp and split samples are skipped. */
    float k = extra.z >= 0 ? lerp(extra.z, 1, saturate(depth / more.x)) : smoothstep(0, 1, 1 - u);
    float3 col = tint.rgb;                                  /* no valid copy this frame: the tint */
    [branch] if (more.y < 0.5) {
        col = at_blur(sp);
        [branch] if (k < 0.999) {
            float3 s = at(sharp, sp);
            [branch] if (extra.x > 0) { float ca = extra.x * u; s.r = at(sharp, sp - n * ca).r; s.b = at(sharp, sp + n * ca).b; }
            col = lerp(s, col, k);
        }
        col = lerp(col, tint.rgb, tint.a);
        float inside = (p.x >= 0 && p.y >= 0 && p.x < shape.x && p.y < shape.y) ? 1 : 0;
        col = lerp(tint.rgb, col, inside);                  /* past the window: the tint */
    }
    /* one specular lobe on a 1.2 px rim, brightest facing the light, the floor elsewhere,
       and a faint shade inside the far side */
    float f = dot(n, light.xy);
    /* inside the coverage band only (no notches where an arc's edge is part-covered) */
    float line_ = saturate(1.7 - depth) * smoothstep(0, 1.25, depth + 0.5);
    float a = lerp(extra.y, saturate(rim.a + 0.10 * optic.y), pow(saturate(f), 2));
    col = lerp(col, rim.rgb, line_ * a);
    col = lerp(col, inner.rgb, saturate(inner.a * saturate(-f) * exp(-depth / 2.5)));
    /* labels on it keep their contrast: the lit result is bounded, lobe and shade included */
    /* skipped where the pixel is provably inside the bounds (the veil's body over a night
       sky): lum <= to_lin(max) <= max^2, lum >= to_lin(min) >= min^2.5 */
    float c_hi = max(col.r, max(col.g, col.b)), c_lo = saturate(min(col.r, min(col.g, col.b)));
    bool bounded = (light.z >= 1 || c_hi * c_hi <= light.z) && (light.w <= 0 || c_lo * c_lo * sqrt(c_lo) >= light.w);
    [branch] if (!bounded) col = bound_lum(col);
    /* one continuous ease into the opaque well, which Lua draws from the hollow depth in */
    [branch] if (well.a > 0) col = lerp(col, well.rgb, smoothstep(optic.w - well.a, optic.w, depth));
    return float4(col, cov);
}

/* A rounded image (posters, artwork) through ImGui's own texture and sampler: a square
   quad 1 px past the rect, its alpha the rounded rect's analytic coverage over the same
   1.25 px band as the glass (ImGui's polygon arcs stepped on small radii). */
cbuffer M : register(b0) {
    float4 mrect;   /* x1 y1 x2 y2 (ImGui px) */
    float4 mshape;  /* origin x y, corner radius, 0 */
};
Texture2D img : register(t0); SamplerState img_smp : register(s0);
float4 ps_mask(PI i) : SV_Target {
    float2 p = i.pos.xy + mshape.xy;
    float2 c = (mrect.xy + mrect.zw) * 0.5, hs = (mrect.zw - mrect.xy) * 0.5;
    float r = min(mshape.z, min(hs.x, hs.y));
    float2 q = abs(p - c) - (hs - r);
    float sd = length(max(q, 0)) + min(max(q.x, q.y), 0) - r;
    float cov = saturate(0.5 - sd * 0.8);
    if (cov <= 0) discard;
    float4 t = img.Sample(img_smp, saturate(i.uv)) * i.col;
    return float4(t.rgb, t.a * cov);
}
)";

void monitor_rects(RECT &work, RECT &full);

struct GlassLevel { ID3D11Texture2D *tex = nullptr; ID3D11ShaderResourceView *srv = nullptr; ID3D11RenderTargetView *rtv = nullptr; int shift = 0; };
struct GlassRect { int x0, y0, x1, y1; };
const int GLASS_MARGIN = 24;      /* refraction + the widest blur reach, px */
const int GLASS_REGIONS = 16;     /* regions per blur draw (more are folded into their box) */
const int GLASS_TS = 96;          /* timestamps per frame at most */
const int GLASS_TIMING_FRAMES = 4;
const int GLASS_SAMPLES = 1024;
enum { GLASS_FLOATING = 0, GLASS_CHROME = 1, GLASS_LIVE = 2, GLASS_FROST = 3 };
struct GlassTiming {
    ID3D11Query *disjoint = nullptr; ID3D11Query *ts[GLASS_TS] = {};
    int n = 0; bool pending = false;
    unsigned char opens[GLASS_TS] = {};   /* 0 closes a span; opens 1 a surface, 2 a copy, 3 a blur, 4 the probe load,
                                             5 the scene target (lunar_scene_d3d11.inc) */
};
struct GlassGpu {
    bool tried = false, ready = false;
    std::string error;
    ID3D11VertexShader *vs = nullptr; ID3D11PixelShader *down4 = nullptr, *down = nullptr, *up = nullptr, *glass = nullptr, *mask = nullptr;
    ID3D11Buffer *mask_cb = nullptr;   /* ps_mask's constants, one Map per rounded image */
    ID3D11Buffer *mask_fallback = nullptr;   /* the same 32 bytes, DEFAULT usage (UpdateSubresource) */
    ID3D11Buffer *cb = nullptr, *blur_cb = nullptr;
    ID3D11Buffer *cb_fallback = nullptr;   /* DEFAULT usage: written by UpdateSubresource, which cannot fail */
    ID3D11RasterizerState *rs = nullptr; ID3D11SamplerState *smp = nullptr;
    /* 0: the copy; 1: 1/4 down (light blur); 2: 1/8; 3: 1/4 up (strong blur) */
    GlassLevel lv[4];
    int tw = 0, th = 0;    /* level 0's size (a multiple of 256) */
    int vw = 0, vh = 0;    /* the part of it the back buffer fills */
    bool used = false;     /* this frame drew glass */
    ImVec2 origin;         /* the display origin of what is being rendered now */
    /* The shared copy after the background layer: this frame's glass rects (main-client)
       in later lists, their copy regions, whether one samples the strong blur, may it be
       skipped, and do the textures hold last frame's result there */
    std::vector<GlassRect> fl, merged;
    bool fl_strong = false, skip = false, valid = false;
    bool fl_ok = false;    /* this frame: the shared copy is there (taken now, or kept and valid) */
    /* Copies at a callback inside the background layer, one per surface there, in list
       order; their last hashes and validity by index */
    /* `rects`: what the surface samples (a floating one: the four strips round its well);
       `ok`: its copy is there this frame */
    /* `overlap`: another copy this frame meets its regions (it copies, and is not kept) */
    struct Point { std::vector<GlassRect> rects; bool strong; std::vector<GlassRect> merged; bool skip, done, ok, overlap; };
    std::vector<Point> pts; size_t npts = 0;   /* pts keeps its capacity: npts are this frame's */
    /* lunar_ui_glass_copy's point, taken by the next glass call on the same list */
    const ImDrawList *pending_dl = nullptr; int pending_pt = -1;
    std::vector<uint64_t> pt_hash; std::vector<char> pt_valid;
    bool fl_overlap = false;   /* a point's copy meets the shared copy's regions: both copy, neither is kept */
    /* glass_plan's running hashes, one per copy (the points', then the shared one) */
    struct HashSet { const std::vector<GlassRect> *regions; GlassRect box; int end; uint64_t h; };
    std::vector<HashSet> hsets; std::vector<int> hash_owner; std::vector<char> hash_took;
    bool rendering_main = false;
    bool force = false;    /* window("glass_force_copy"): never skip (worst-case timing) */
    bool off = false;      /* window("glass_shader", false): the baked path, for comparison */
    bool flush_probe = false;   /* window("glass_flush_probe"): Flush after the floating blur */
    /* window("glass_fail", what), LUNAR_GPU_TIMING only: the failure paths on demand.
       1: every surface's textures are missing at bind; 2: every constant Map fails */
    int fail = 0;
    /* window("glass_probe_load", n), LUNAR_GPU_TIMING only: n blur passes over two private
       1024 px targets after the timed spans each frame, so the GPU holds its clocks under a
       light vsync-paced load and the spans compare between phases */
    int probe_load = 0;
    GlassLevel load[2];
    uint64_t last_hash = 0;
    long long surfaces = 0, copies = 0, skips = 0, passes = 0, creations = 0, live_copies = 0, live_skips = 0;
    bool timing = false, timing_open = false;
    GlassTiming tq[GLASS_TIMING_FRAMES]; int tcur = 0;
    double gpu_glass_us_sum = 0, gpu_glass_us_max = 0, gpu_frame_us_sum = 0, gpu_copy_us_sum = 0;
    double gpu_glass_us_last = 0, hash_us_sum = 0, gpu_blur_us_sum = 0; long long gpu_frames = 0;
    /* per-frame samples for window("glass_timing_take"): glass, copy + blur, whole frame,
       copy alone, blur alone (us), and the CPU's time in l_frame_end before Present (us) */
    float sample_glass[GLASS_SAMPLES] = {}, sample_copy[GLASS_SAMPLES] = {}, sample_frame[GLASS_SAMPLES] = {};
    float sample_copy_only[GLASS_SAMPLES] = {}, sample_blur[GLASS_SAMPLES] = {};
    float sample_load[GLASS_SAMPLES] = {};   /* the probe load: fixed work, so a clock gauge */
    float sample_scene[GLASS_SAMPLES] = {};  /* the scene target's render and blur (core.ui.Background) */
    double gpu_scene_us_sum = 0; long long gpu_scene_frames = 0;
    int samples = 0;
    /* What the scene's renders (lunar_scene_d3d11.inc) changed since the last plan: the
       boxes of the sprites that moved or changed (widened by the scene blur's reach), or
       everything; a copy whose regions meet them hashes the scene's revision */
    std::vector<GlassRect> scene_dirty; bool scene_all = false; uint64_t scene_rev = 0;
    /* the scene revision that last changed each copy's regions (the shared copy's, the
       points' by index): hashed every frame, so a copy is redone once per change */
    uint64_t fl_scene_rev = 0; std::vector<uint64_t> pt_scene_rev;
} gg;

struct GlassCmd {
    float rect[4]; float radius, band, thickness, lift, alpha, hollow, chroma, rim_floor, rim_blur, lum_max, lum_min;
    float light[2];
    float tint[4], rim[4], inner[4], well[4];
    float ku, kv;   /* chrome: px -> uv of the floor images */
    float blur_depth;   /* px in from the rim where it is all blur */
    int kind;
    int point;      /* its copy: a point in the background layer, or -1 the shared copy */
    int soft;       /* floating: samples the strong blur (its edges lie over text) */
    int floor_sharp, floor_blur;   /* chrome: the floor images' texture ids */
};

/* -- timing ----------------------------------------------------------------------------- */
/* The slot this frame opened, or none (timing off, or every slot still waiting). */
GlassTiming *glass_tq() { return gg.timing && gg.timing_open ? &gg.tq[gg.tcur] : nullptr; }
void glass_stamp(int kind) {
    GlassTiming *t = glass_tq();
    if (!t || t->n >= GLASS_TS) return;
    t->opens[t->n] = (unsigned char)kind;
    g.ctx->End(t->ts[t->n++]);
}
void glass_cb_stamp(const ImDrawList *, const ImDrawCmd *) { glass_stamp(0); }
void glass_timing_collect() {
    for (int k = 0; k < GLASS_TIMING_FRAMES; k++) {
        GlassTiming &t = gg.tq[k];
        if (!t.pending) continue;
        D3D11_QUERY_DATA_TIMESTAMP_DISJOINT dj;
        if (g.ctx->GetData(t.disjoint, &dj, sizeof(dj), D3D11_ASYNC_GETDATA_DONOTFLUSH) != S_OK) continue;
        UINT64 v[GLASS_TS];
        bool ok = true;
        for (int i = 0; i < t.n && ok; i++)
            ok = g.ctx->GetData(t.ts[i], &v[i], sizeof(UINT64), D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK;
        if (!ok) continue;   /* the disjoint query can land before its timestamps: next frame */
        t.pending = false;
        if (dj.Disjoint || dj.Frequency == 0 || t.n < 2) continue;
        double us = 1e6 / (double)dj.Frequency, glass = 0, copy = 0, blur = 0, load = 0, scene = 0;
        for (int i = 0; i + 1 < t.n; i++) {
            double span = (double)(v[i + 1] - v[i]) * us;
            if (t.opens[i] == 4) { load += span; continue; }
            if (t.opens[i] == 5) { scene += span; continue; }
            if (t.opens[i]) glass += span;
            if (t.opens[i] == 2) copy += span;
            if (t.opens[i] == 3) blur += span;
        }
        double frame = (double)(v[t.n - 1] - v[0]) * us - load;
        gg.gpu_copy_us_sum += copy; gg.gpu_blur_us_sum += blur;
        if (scene > 0) { gg.gpu_scene_us_sum += scene; gg.gpu_scene_frames++; }
        if (gg.samples < GLASS_SAMPLES) gg.sample_scene[gg.samples] = (float)scene;
        gg.gpu_glass_us_last = glass;
        if (gg.samples < GLASS_SAMPLES) {
            gg.sample_glass[gg.samples] = (float)glass; gg.sample_copy[gg.samples] = (float)(copy + blur);
            gg.sample_frame[gg.samples] = (float)frame;
            gg.sample_copy_only[gg.samples] = (float)copy; gg.sample_blur[gg.samples] = (float)blur;
            gg.sample_load[gg.samples] = (float)load;
            gg.samples++;
        }
        gg.gpu_glass_us_sum += glass; gg.gpu_glass_us_max = std::max(gg.gpu_glass_us_max, glass);
        gg.gpu_frame_us_sum += frame;
        gg.gpu_frames++;
    }
}
void glass_timing_begin() {
    gg.timing_open = false;
    if (!gg.timing) return;
    glass_timing_collect();
    GlassTiming &t = gg.tq[gg.tcur];
    if (t.pending || !t.disjoint) return;   /* not read back yet: this frame goes untimed */
    t.n = 0; t.pending = true; gg.timing_open = true;
    g.ctx->Begin(t.disjoint);
    glass_stamp(0);
}
void glass_timing_end() {
    if (!glass_tq()) return;
    glass_stamp(0);
    g.ctx->End(gg.tq[gg.tcur].disjoint);
    gg.timing_open = false;
    gg.tcur = (gg.tcur + 1) % GLASS_TIMING_FRAMES;
}

/* -- objects ---------------------------------------------------------------------------- */
void glass_invalidate() { gg.valid = false; std::fill(gg.pt_valid.begin(), gg.pt_valid.end(), 0); }
void glass_release_levels() {
    for (GlassLevel &l : gg.lv) {
        if (l.rtv) { l.rtv->Release(); l.rtv = nullptr; }
        if (l.srv) { if (g.frame_open) g.retired_textures.push_back(l.srv); else l.srv->Release(); l.srv = nullptr; }
        if (l.tex) { l.tex->Release(); l.tex = nullptr; }
    }
    gg.tw = gg.th = 0; glass_invalidate();
}

void glass_release_load() {
    for (GlassLevel &l : gg.load) {
        if (l.rtv) { l.rtv->Release(); l.rtv = nullptr; }
        if (l.srv) { l.srv->Release(); l.srv = nullptr; }
        if (l.tex) { l.tex->Release(); l.tex = nullptr; }
    }
}

void glass_release() {
    glass_release_levels();
    glass_release_load();
    auto rel = [](auto *&p) { if (p) { p->Release(); p = nullptr; } };
    rel(gg.mask); rel(gg.mask_cb); rel(gg.mask_fallback); rel(gg.vs); rel(gg.down4); rel(gg.down); rel(gg.up); rel(gg.glass); rel(gg.cb); rel(gg.cb_fallback); rel(gg.blur_cb); rel(gg.rs); rel(gg.smp);
    for (GlassTiming &t : gg.tq) { rel(t.disjoint); for (auto *&q : t.ts) rel(q); t.pending = false; t.n = 0; }
    gg.tried = gg.ready = false; gg.used = gg.skip = false; gg.timing_open = false;
    gg.fl.clear(); gg.npts = 0;
}

ID3DBlob *glass_compile(const char *entry, const char *target) {
    ID3DBlob *code = nullptr, *errors = nullptr;
    HRESULT hr = D3DCompile(GLASS_HLSL, strlen(GLASS_HLSL), "lunar_glass", nullptr, nullptr, entry, target,
        D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errors);
    if (FAILED(hr)) {
        gg.error = std::string(entry) + ": " + (errors ? (const char*)errors->GetBufferPointer() : "compile failed");
        if (code) { code->Release(); code = nullptr; }
    }
    if (errors) errors->Release();
    return code;
}

/* Made once per device, the first time a frame asks, on a hardware device only. */
bool glass_ensure() {
    if (gg.tried) return gg.ready;
    gg.tried = true;
    if (!g.device || g.warp) return false;
    ID3DBlob *vs = glass_compile("vs_regions", "vs_4_0"), *down4 = glass_compile("ps_down4", "ps_4_0"),
        *down = glass_compile("ps_down", "ps_4_0"), *up = glass_compile("ps_up", "ps_4_0"),
        *glass = glass_compile("ps_glass", "ps_4_0"), *mask = glass_compile("ps_mask", "ps_4_0");
    auto ps = [](ID3DBlob *b, ID3D11PixelShader **out) {
        return SUCCEEDED(g.device->CreatePixelShader(b->GetBufferPointer(), b->GetBufferSize(), nullptr, out));
    };
    bool ok = vs && down4 && down && up && glass && mask
        && SUCCEEDED(g.device->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr, &gg.vs))
        && ps(down4, &gg.down4) && ps(down, &gg.down) && ps(up, &gg.up) && ps(glass, &gg.glass) && ps(mask, &gg.mask);
    for (ID3DBlob *b : {vs, down4, down, up, glass, mask}) if (b) b->Release();
    if (ok) {
        D3D11_BUFFER_DESC b = {};
        b.Usage = D3D11_USAGE_DYNAMIC; b.BindFlags = D3D11_BIND_CONSTANT_BUFFER; b.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        b.ByteWidth = 11 * 16;
        ok = SUCCEEDED(g.device->CreateBuffer(&b, nullptr, &gg.cb));
        D3D11_BUFFER_DESC f = b; f.Usage = D3D11_USAGE_DEFAULT; f.CPUAccessFlags = 0;
        ok = ok && SUCCEEDED(g.device->CreateBuffer(&f, nullptr, &gg.cb_fallback));
        b.ByteWidth = (2 + GLASS_REGIONS) * 16;
        ok = ok && SUCCEEDED(g.device->CreateBuffer(&b, nullptr, &gg.blur_cb));
        b.ByteWidth = 2 * 16;
        ok = ok && SUCCEEDED(g.device->CreateBuffer(&b, nullptr, &gg.mask_cb));
        D3D11_BUFFER_DESC mf = b; mf.Usage = D3D11_USAGE_DEFAULT; mf.CPUAccessFlags = 0;
        ok = ok && SUCCEEDED(g.device->CreateBuffer(&mf, nullptr, &gg.mask_fallback));
        D3D11_RASTERIZER_DESC r = {};
        r.FillMode = D3D11_FILL_SOLID; r.CullMode = D3D11_CULL_NONE; r.DepthClipEnable = TRUE;
        ok = ok && SUCCEEDED(g.device->CreateRasterizerState(&r, &gg.rs));
        D3D11_SAMPLER_DESC s = {};
        s.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        s.AddressU = s.AddressV = s.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        s.ComparisonFunc = D3D11_COMPARISON_ALWAYS; s.MaxLOD = D3D11_FLOAT32_MAX;
        ok = ok && SUCCEEDED(g.device->CreateSamplerState(&s, &gg.smp));
    }
    if (ok) {
        char v[8] = ""; GetEnvironmentVariableA("LUNAR_GPU_TIMING", v, sizeof(v));
        gg.timing = v[0] == '1';
        if (gg.timing) {
            D3D11_QUERY_DESC dq = {D3D11_QUERY_TIMESTAMP_DISJOINT, 0}, tq = {D3D11_QUERY_TIMESTAMP, 0};
            for (GlassTiming &t : gg.tq) {
                if (FAILED(g.device->CreateQuery(&dq, &t.disjoint))) { gg.timing = false; break; }
                for (auto *&q : t.ts) if (FAILED(g.device->CreateQuery(&tq, &q))) { gg.timing = false; break; }
            }
        }
    }
    if (!ok) { if (gg.error.empty()) gg.error = "glass_objects_failed"; glass_release(); gg.tried = true; return false; }
    gg.ready = true;
    return true;
}

/* Levels at least the back buffer's size: made the first time at the monitor's size
   (rounded up to 256 px), re-made only when the window outgrows them. */
bool glass_levels(int w, int h) {
    if (w <= 0 || h <= 0) return false;
    if (w != gg.vw || h != gg.vh) glass_invalidate();
    gg.vw = w; gg.vh = h;
    if (gg.lv[0].tex && w <= gg.tw && h <= gg.th) return true;
    RECT work, full; monitor_rects(work, full);
    int mw = gg.tw ? 0 : (int)(full.right - full.left), mh = gg.th ? 0 : (int)(full.bottom - full.top);
    int tw = std::max({gg.tw, mw, w}), th = std::max({gg.th, mh, h});
    tw = (tw + 255) & ~255; th = (th + 255) & ~255;
    glass_release_levels();
    const int shifts[4] = {0, 2, 3, 2};
    for (int k = 0; k < 4; k++) {
        D3D11_TEXTURE2D_DESC d = {};
        d.Width = (UINT)(tw >> shifts[k]); d.Height = (UINT)(th >> shifts[k]); d.MipLevels = 1; d.ArraySize = 1;
        d.Format = DXGI_FORMAT_R8G8B8A8_UNORM; d.SampleDesc.Count = 1; d.Usage = D3D11_USAGE_DEFAULT;
        d.BindFlags = D3D11_BIND_SHADER_RESOURCE | (k ? D3D11_BIND_RENDER_TARGET : 0);
        GlassLevel &l = gg.lv[k];
        l.shift = shifts[k];
        if (FAILED(g.device->CreateTexture2D(&d, nullptr, &l.tex)) || !l.tex
            || FAILED(g.device->CreateShaderResourceView(l.tex, nullptr, &l.srv))
            || (k && FAILED(g.device->CreateRenderTargetView(l.tex, nullptr, &l.rtv)))) {
            glass_release_levels(); return false;
        }
    }
    gg.tw = tw; gg.th = th; gg.vw = w; gg.vh = h;
    gg.creations++;
    return true;
}

/* -- regions ---------------------------------------------------------------------------- */
inline long long glass_area(const GlassRect &r) { return (long long)(r.x1 - r.x0) * (r.y1 - r.y0); }
inline bool glass_meets(const GlassRect &a, const GlassRect &b) { return a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1; }
/* What a surface samples: its rect, or for a floating surface round an opaque well the
   four strips of its lip (`e` px deep, past the well's ease, the lens's 5 px pull and the corner
   radius); the opaque centre is never sampled. Appended to `out`. */
void glass_regions(const GlassRect &r, float hollow, float radius, std::vector<GlassRect> &out) {
    int e = (int)std::ceil(std::max(hollow + 5.0f, radius)) + 1;
    if (hollow <= 0 || 2 * e >= r.x1 - r.x0 || 2 * e >= r.y1 - r.y0) { out.push_back(r); return; }
    out.push_back({r.x0, r.y0, r.x1, r.y0 + e});
    out.push_back({r.x0, r.y1 - e, r.x1, r.y1});
    out.push_back({r.x0, r.y0 + e, r.x0 + e, r.y1 - e});
    out.push_back({r.x1 - e, r.y0 + e, r.x1, r.y1 - e});
}

/* `in` widened by the margin, clipped to the back buffer (and aligned to 8 px, two 1/4
   texels), merged where the box round two is no bigger than the two apart; past
   GLASS_REGIONS, the pair whose box grows the area least is merged, until they fit. */
void glass_merge(const std::vector<GlassRect> &in, std::vector<GlassRect> &out) {
    out.clear();
    for (const GlassRect &r : in) {
        GlassRect m = {std::max(0, (r.x0 - GLASS_MARGIN) & ~7), std::max(0, (r.y0 - GLASS_MARGIN) & ~7),
                       std::min(gg.vw, (r.x1 + GLASS_MARGIN + 7) & ~7), std::min(gg.vh, (r.y1 + GLASS_MARGIN + 7) & ~7)};
        if (m.x1 <= m.x0 || m.y1 <= m.y0) continue;
        out.push_back(m);
    }
    auto box = [](const GlassRect &a, const GlassRect &b) {
        return GlassRect{std::min(a.x0, b.x0), std::min(a.y0, b.y0), std::max(a.x1, b.x1), std::max(a.y1, b.y1)};
    };
    for (;;) {
        for (bool merged = true; merged;) {   /* the free merges */
            merged = false;
            for (size_t i = 0; i < out.size() && !merged; i++)
                for (size_t j = i + 1; j < out.size() && !merged; j++) {
                    GlassRect u = box(out[i], out[j]);
                    if (glass_area(u) <= glass_area(out[i]) + glass_area(out[j])) {
                        out[i] = u; out.erase(out.begin() + (long)j); merged = true;
                    }
                }
        }
        if (out.size() <= (size_t)GLASS_REGIONS) return;
        size_t bi = 0, bj = 1; long long best = LLONG_MAX;
        for (size_t i = 0; i < out.size(); i++)
            for (size_t j = i + 1; j < out.size(); j++) {
                long long grow = glass_area(box(out[i], out[j])) - glass_area(out[i]) - glass_area(out[j]);
                if (grow < best) { best = grow; bi = i; bj = j; }
            }
        out[bi] = box(out[bi], out[bj]); out.erase(out.begin() + (long)bj);
    }
}

/* One blur pass of `src` into `dst` over every region, in one draw. */
bool glass_pass(ID3D11PixelShader *ps, const GlassLevel &src, const GlassLevel &dst, const std::vector<GlassRect> &regions) {
    ID3D11DeviceContext *c = g.ctx;
    int sw = gg.tw >> src.shift, sh = gg.th >> src.shift, sv = (1 << src.shift) - 1;
    int dw = gg.tw >> dst.shift, dh = gg.th >> dst.shift;
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(c->Map(gg.blur_cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) return false;
    float *v = (float*)m.pData;
    /* reads stop at the centre of the last texel the level above wrote: ceil(extent / s) - 0.5 */
    v[0] = 1.0f / sw; v[1] = 1.0f / sh;
    v[2] = ((gg.vw + sv) >> src.shift) - 0.5f; v[3] = ((gg.vh + sv) >> src.shift) - 0.5f;
    v[4] = (float)dw; v[5] = (float)dh; v[6] = 0; v[7] = (float)(1 << dst.shift);
    size_t n = std::min(regions.size(), (size_t)GLASS_REGIONS);
    for (size_t i = 0; i < n; i++) {
        float *r = v + 8 + 4 * i;
        r[0] = (float)regions[i].x0; r[1] = (float)regions[i].y0; r[2] = (float)regions[i].x1; r[3] = (float)regions[i].y1;
    }
    c->Unmap(gg.blur_cb, 0);
    D3D11_VIEWPORT vp = {0, 0, (float)dw, (float)dh, 0, 1};
    c->RSSetViewports(1, &vp);
    c->PSSetShader(ps, nullptr, 0);
    c->OMSetRenderTargets(1, &dst.rtv, nullptr);
    c->PSSetShaderResources(0, 1, &src.srv);
    c->Draw((UINT)(6 * n), 0);
    ID3D11ShaderResourceView *none = nullptr;
    c->PSSetShaderResources(0, 1, &none);
    gg.passes++;
    return true;
}

/* FNV-1a over 64-bit words */
inline uint64_t glass_mix(uint64_t h, const void *p, size_t n) {
    const unsigned char *b = (const unsigned char*)p;
    size_t i = 0;
    for (; i + 8 <= n; i += 8) { uint64_t w; memcpy(&w, b + i, 8); h = (h ^ w) * 0x100000001B3ull; }
    for (; i < n; i++) h = (h ^ b[i]) * 0x100000001B3ull;
    return h;
}
const uint64_t GLASS_SEED = 1469598103934665603ull;

void glass_cb_copy(const ImDrawList *, const ImDrawCmd *);
void glass_cb_bind(const ImDrawList *, const ImDrawCmd *);
void glass_cb_stamp(const ImDrawList *, const ImDrawCmd *);
const GlassCmd *glass_cmd(const ImDrawList *dl, const ImDrawCmd *cmd);

/* One pass over the background layer `bg` in order; each copy's hash is a running prefix
   (commands [0, end): a point's copy ends at its callback, the shared copy takes the whole
   list). A copy takes only what is drawn inside its regions: a triangle (its three
   vertices: position, uv, colour) counts only if its box meets a region, a command's
   texture and clip only if one of its triangles does, a glass surface's constants only if
   its rect meets one, and never its light or hover (the pointer moving must not copy). The
   copy, timing and state-reset callbacks draw nothing; any other callback counts. Each
   triangle is hashed once, however many copies take it. */
void glass_hash_sets(const ImDrawList *bg, std::vector<GlassGpu::HashSet> &sets) {
    if (!bg || sets.empty()) return;
    int last = 0;
    for (GlassGpu::HashSet &s : sets) {
        s.box = (*s.regions)[0];
        for (const GlassRect &r : *s.regions) {
            s.box.x0 = std::min(s.box.x0, r.x0); s.box.y0 = std::min(s.box.y0, r.y0);
            s.box.x1 = std::max(s.box.x1, r.x1); s.box.y1 = std::max(s.box.y1, r.y1);
        }
        last = std::max(last, s.end);
    }
    auto meets = [](const GlassGpu::HashSet &s, float x0, float y0, float x1, float y1) {
        if (x0 >= s.box.x1 || x1 <= s.box.x0 || y0 >= s.box.y1 || y1 <= s.box.y0) return false;
        for (const GlassRect &r : *s.regions) if (x0 < r.x1 && x1 > r.x0 && y0 < r.y1 && y1 > r.y0) return true;
        return false;
    };
    const ImDrawVert *vtx = bg->VtxBuffer.Data;
    const unsigned nv = (unsigned)bg->VtxBuffer.Size;
    const size_t ns = sets.size();
    std::vector<char> &state = gg.hash_took;   /* per copy, this command: 0 not yet taken, 1 taken, 2 out of reach */
    state.resize(ns);
    for (int ci = 0; ci < last && ci < bg->CmdBuffer.Size; ci++) {
        const ImDrawCmd &cmd = bg->CmdBuffer[ci];
        if (cmd.UserCallback) {
            if (cmd.UserCallback == glass_cb_copy || cmd.UserCallback == glass_cb_stamp
                || cmd.UserCallback == ImGui::GetPlatformIO().DrawCallback_ResetRenderState) continue;
            if (cmd.UserCallback == glass_cb_bind) {
                const GlassCmd *d = glass_cmd(bg, &cmd);
                if (!d) continue;
                GlassCmd c = *d;
                c.light[0] = c.light[1] = 0; c.lift = 0;
                uint64_t ch = glass_mix(GLASS_SEED, &c, sizeof(c));
                for (GlassGpu::HashSet &s : sets)
                    if (ci < s.end && meets(s, d->rect[0], d->rect[1], d->rect[2], d->rect[3])) s.h = glass_mix(s.h, &ch, sizeof(ch));
                continue;
            }
            uint64_t ch = GLASS_SEED;
            const void *fn = (const void*)cmd.UserCallback; ch = glass_mix(ch, &fn, sizeof(fn));
            const void *data = cmd.UserCallbackData;
            if (!data && cmd.UserCallbackDataOffset >= 0 && cmd.UserCallbackDataSize > 0)
                data = bg->_CallbacksDataBuf.Data + cmd.UserCallbackDataOffset;
            if (data && cmd.UserCallbackDataSize > 0) ch = glass_mix(ch, data, (size_t)cmd.UserCallbackDataSize);
            else ch = glass_mix(ch, &data, sizeof(data));
            for (GlassGpu::HashSet &s : sets) if (ci < s.end) s.h = glass_mix(s.h, &ch, sizeof(ch));
            continue;
        }
        if (cmd.ElemCount == 0) continue;
        /* the copies this command can reach: before their end, its clip meeting their regions */
        bool live = false;
        for (size_t k = 0; k < ns; k++) {
            bool in = ci < sets[k].end && meets(sets[k], cmd.ClipRect.x, cmd.ClipRect.y, cmd.ClipRect.z, cmd.ClipRect.w);
            state[k] = in ? 0 : 2;
            live = live || in;
        }
        if (!live) continue;
        const ImDrawIdx *idx = bg->IdxBuffer.Data + cmd.IdxOffset;
        ImTextureID tid = cmd.GetTexID();
        for (unsigned i = 0; i + 2 < cmd.ElemCount; i += 3) {
            unsigned a = cmd.VtxOffset + idx[i], b = cmd.VtxOffset + idx[i + 1], c = cmd.VtxOffset + idx[i + 2];
            if (a >= nv || b >= nv || c >= nv) continue;
            const ImDrawVert &va = vtx[a], &vb = vtx[b], &vc = vtx[c];
            float x0 = std::min({va.pos.x, vb.pos.x, vc.pos.x}), x1 = std::max({va.pos.x, vb.pos.x, vc.pos.x});
            float y0 = std::min({va.pos.y, vb.pos.y, vc.pos.y}), y1 = std::max({va.pos.y, vb.pos.y, vc.pos.y});
            /* inside the clip and a region (a sliver of a box still draws a pixel's edge) */
            x0 = std::max(x0, cmd.ClipRect.x); y0 = std::max(y0, cmd.ClipRect.y);
            x1 = std::min(x1, cmd.ClipRect.z); y1 = std::min(y1, cmd.ClipRect.w);
            if (x1 < x0 || y1 < y0) continue;
            float fx0 = std::floor(x0), fy0 = std::floor(y0), fx1 = std::ceil(x1) + 1, fy1 = std::ceil(y1) + 1;
            uint64_t th = 0; bool hashed = false;
            for (size_t k = 0; k < ns; k++) {
                if (state[k] == 2) continue;
                GlassGpu::HashSet &s = sets[k];
                if (!meets(s, fx0, fy0, fx1, fy1)) continue;
                if (!state[k]) {
                    state[k] = 1;
                    float clip[4] = {std::max(cmd.ClipRect.x, (float)s.box.x0), std::max(cmd.ClipRect.y, (float)s.box.y0),
                                     std::min(cmd.ClipRect.z, (float)s.box.x1), std::min(cmd.ClipRect.w, (float)s.box.y1)};
                    s.h = glass_mix(s.h, clip, sizeof(clip));
                    s.h = glass_mix(s.h, &tid, sizeof(tid));
                }
                if (!hashed) {
                    hashed = true;
                    th = glass_mix(GLASS_SEED, &va, sizeof(ImDrawVert));
                    th = glass_mix(th, &vb, sizeof(ImDrawVert)); th = glass_mix(th, &vc, sizeof(ImDrawVert));
                }
                s.h = glass_mix(s.h, &th, sizeof(th));
            }
        }
    }
}

/* Before the main window renders: the copy regions, and may each copy and its blur be
   skipped? One may when everything drawn before it that reaches its regions hashes as
   last frame, last frame's copy there succeeded and no other copy meets its regions (two
   copies that meet write the same texels: those two copy every frame and are not kept;
   the others are unaffected). The scene target changes only where its renders say
   (gg.scene_dirty): a copy over an unchanged part of the scene keeps its copy. */
bool glass_scene_meets(const std::vector<GlassRect> &regions) {
    if (gg.scene_all) return true;
    for (const GlassRect &r : regions) for (const GlassRect &d : gg.scene_dirty) if (glass_meets(r, d)) return true;
    return false;
}
void glass_plan(ImDrawList *bg) {
    gg.skip = gg.fl_overlap = false;
    if (gg.fl.empty()) gg.valid = false;
    size_t np = gg.npts;
    gg.pt_valid.resize(np, 0); gg.pt_hash.resize(np, 0);
    if (gg.fl.empty() && np == 0) return;
    auto t0 = std::chrono::steady_clock::now();
    glass_merge(gg.fl, gg.merged);
    for (size_t i = 0; i < np; i++) { glass_merge(gg.pts[i].rects, gg.pts[i].merged); gg.pts[i].overlap = false; }
    auto meets = [](const std::vector<GlassRect> &a, const std::vector<GlassRect> &b) {
        for (const GlassRect &x : a) for (const GlassRect &y : b) if (glass_meets(x, y)) return true;
        return false;
    };
    for (size_t i = 0; i < np; i++) {
        if (!gg.fl.empty() && meets(gg.pts[i].merged, gg.merged)) gg.pts[i].overlap = gg.fl_overlap = true;
        for (size_t j = i + 1; j < np; j++)
            if (meets(gg.pts[i].merged, gg.pts[j].merged)) gg.pts[i].overlap = gg.pts[j].overlap = true;
    }
    uint64_t base = GLASS_SEED;
    base = glass_mix(base, &g.texture_revision, sizeof(g.texture_revision));   /* freed or updated in place */
    base = glass_mix(base, &g.next_texture, sizeof(g.next_texture));          /* made */
    int size[2] = {gg.vw, gg.vh}; base = glass_mix(base, size, sizeof(size));
    /* the copies: each point's (ending at its callback), then the shared one (the whole list) */
    std::vector<GlassGpu::HashSet> &sets = gg.hsets; sets.clear();
    std::vector<int> &owner = gg.hash_owner; owner.clear();
    if (np && bg) {
        for (int ci = 0; ci < bg->CmdBuffer.Size; ci++) {
            const ImDrawCmd &cmd = bg->CmdBuffer[ci];
            if (cmd.UserCallback != glass_cb_copy) continue;
            size_t i = (size_t)(intptr_t)cmd.UserCallbackData;
            if (i >= np || gg.pts[i].merged.empty()) continue;
            GlassGpu::Point &pt = gg.pts[i];
            uint64_t h = glass_mix(base, pt.merged.data(), pt.merged.size() * sizeof(GlassRect));
            h = glass_mix(h, &pt.strong, sizeof(pt.strong));
            if (gg.pt_scene_rev.size() < np) gg.pt_scene_rev.resize(np, 0);
            if (glass_scene_meets(pt.merged)) gg.pt_scene_rev[i] = gg.scene_rev;
            h = glass_mix(h, &gg.pt_scene_rev[i], sizeof(uint64_t));
            sets.push_back({&pt.merged, {}, ci, h}); owner.push_back((int)i);
        }
    }
    if (!gg.fl.empty() && !gg.merged.empty()) {
        uint64_t h = glass_mix(base, gg.merged.data(), gg.merged.size() * sizeof(GlassRect));
        h = glass_mix(h, &gg.fl_strong, sizeof(gg.fl_strong));
        if (glass_scene_meets(gg.merged)) gg.fl_scene_rev = gg.scene_rev;
        h = glass_mix(h, &gg.fl_scene_rev, sizeof(gg.fl_scene_rev));
        sets.push_back({&gg.merged, {}, bg ? bg->CmdBuffer.Size : 0, h}); owner.push_back(-1);
    }
    glass_hash_sets(bg, sets);
    gg.scene_dirty.clear(); gg.scene_all = false;
    for (size_t k = 0; k < sets.size(); k++) {
        uint64_t h = sets[k].h;
        if (owner[k] < 0) {
            gg.skip = gg.valid && !gg.force && !gg.fl_overlap && h == gg.last_hash;
            gg.fl_ok = gg.skip;
            gg.last_hash = h;
            if (gg.skip) gg.skips++;
        } else {
            size_t i = (size_t)owner[k];
            GlassGpu::Point &pt = gg.pts[i];
            pt.skip = gg.pt_valid[i] && !gg.force && !pt.overlap && h == gg.pt_hash[i];
            gg.pt_hash[i] = h;
            if (pt.skip) gg.live_skips++;
        }
    }
    gg.hash_us_sum += std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count();
}

/* After the frame: what the textures hold that a later frame may reuse. A copy counts only
   after every step that filled it succeeded; copies that met another are not kept. */
void glass_frame_done(bool glass, bool floating_ok) {
    if (!glass) { glass_invalidate(); return; }
    if (!gg.fl.empty() && !gg.skip) gg.valid = floating_ok;
    if (gg.fl_overlap) gg.valid = false;
    for (size_t i = 0; i < gg.npts && i < gg.pt_valid.size(); i++)
        if ((!gg.pts[i].skip && !gg.pts[i].done) || gg.pts[i].overlap) gg.pt_valid[i] = 0;
}

/* Copy `regions` of `back` into level 0 and blur them (the strong chain too if asked).
   Leaves no render target bound. False if any step failed. */
bool glass_copy_blur(ID3D11Resource *back, const std::vector<GlassRect> &regions, bool strong, long long &count) {
    ID3D11DeviceContext *c = g.ctx;
    glass_stamp(2);
    c->OMSetRenderTargets(0, nullptr, nullptr);
    ID3D11ShaderResourceView *none[4] = {};
    c->PSSetShaderResources(0, 4, none);
    for (const GlassRect &r : regions) {
        D3D11_BOX box = {(UINT)r.x0, (UINT)r.y0, 0, (UINT)r.x1, (UINT)r.y1, 1};
        c->CopySubresourceRegion(gg.lv[0].tex, 0, (UINT)r.x0, (UINT)r.y0, 0, back, 0, &box);
        count++;
    }
    glass_stamp(3);
    c->IASetInputLayout(nullptr);
    c->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    c->VSSetShader(gg.vs, nullptr, 0);
    c->VSSetConstantBuffers(0, 1, &gg.blur_cb);
    c->PSSetConstantBuffers(0, 1, &gg.blur_cb);
    c->PSSetSamplers(1, 1, &gg.smp);
    c->GSSetShader(nullptr, nullptr, 0);
    c->OMSetBlendState(nullptr, nullptr, 0xffffffff);
    c->OMSetDepthStencilState(nullptr, 0);
    c->RSSetState(gg.rs);
    bool ok = glass_pass(gg.down4, gg.lv[0], gg.lv[1], regions);
    if (ok && strong) ok = glass_pass(gg.down, gg.lv[1], gg.lv[2], regions) && glass_pass(gg.up, gg.lv[2], gg.lv[3], regions);
    c->OMSetRenderTargets(0, nullptr, nullptr);
    glass_stamp(0);
    return ok;
}

/* After the main window's background layer: the floating regions. */
bool glass_floating_copy(ID3D11Resource *back) {
    if (!gg.ready || !gg.lv[0].tex || gg.fl.empty() || gg.skip || gg.merged.empty()) return false;
    bool ok = glass_copy_blur(back, gg.merged, gg.fl_strong, gg.copies);
    if (gg.flush_probe) g.ctx->Flush();
    gg.fl_ok = ok;
    return ok;
}

/* At a glass surface inside the main window's background layer, before it draws: what
   was drawn under it so far. Rendering a dialog window that shows the main lists under its
   own, it reuses the main render's copy. The state reset after it puts ImGui's state back. */
void glass_cb_copy(const ImDrawList *, const ImDrawCmd *cmd) {
    size_t i = (size_t)(intptr_t)cmd->UserCallbackData;
    if (!gg.ready || !gg.rendering_main || i >= gg.npts || !gg.lv[0].tex) return;
    GlassGpu::Point &pt = gg.pts[i];
    if (pt.done) return;
    pt.done = true;
    if (pt.skip || pt.merged.empty()) { pt.ok = pt.skip; return; }
    ID3D11Resource *back = nullptr;
    g.rtv->GetResource(&back);
    bool ok = back && glass_copy_blur(back, pt.merged, pt.strong, gg.live_copies);
    if (back) back->Release();
    pt.ok = ok;
    if (i < gg.pt_valid.size()) gg.pt_valid[i] = ok;
    g.ctx->OMSetRenderTargets(1, &g.rtv, nullptr);
}

/* The probe load (see GlassGpu::probe_load): untimed, after the frame's last timestamp. */
void glass_probe_frame() {
    if (!gg.timing || gg.probe_load <= 0 || !gg.ready) return;
    const int N = 1024;
    if (!gg.load[0].tex) {
        for (GlassLevel &l : gg.load) {
            D3D11_TEXTURE2D_DESC d = {};
            d.Width = d.Height = N; d.MipLevels = 1; d.ArraySize = 1; d.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            d.SampleDesc.Count = 1; d.Usage = D3D11_USAGE_DEFAULT; d.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
            if (FAILED(g.device->CreateTexture2D(&d, nullptr, &l.tex)) || FAILED(g.device->CreateShaderResourceView(l.tex, nullptr, &l.srv))
                || FAILED(g.device->CreateRenderTargetView(l.tex, nullptr, &l.rtv))) { glass_release_load(); gg.probe_load = 0; return; }
        }
    }
    ID3D11DeviceContext *c = g.ctx;
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(c->Map(gg.blur_cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) return;
    float *v = (float*)m.pData;
    v[0] = v[1] = 1.0f / N; v[2] = v[3] = N - 0.5f; v[4] = v[5] = (float)N; v[6] = 0; v[7] = 1;
    v[8] = v[9] = 0; v[10] = v[11] = (float)N;
    c->Unmap(gg.blur_cb, 0);
    c->IASetInputLayout(nullptr); c->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    c->VSSetShader(gg.vs, nullptr, 0); c->VSSetConstantBuffers(0, 1, &gg.blur_cb);
    c->PSSetConstantBuffers(0, 1, &gg.blur_cb); c->PSSetSamplers(1, 1, &gg.smp); c->PSSetShader(gg.up, nullptr, 0);
    c->GSSetShader(nullptr, nullptr, 0); c->OMSetBlendState(nullptr, nullptr, 0xffffffff);
    c->OMSetDepthStencilState(nullptr, 0); c->RSSetState(gg.rs);
    D3D11_VIEWPORT vp = {0, 0, (float)N, (float)N, 0, 1}; c->RSSetViewports(1, &vp);
    ID3D11ShaderResourceView *none = nullptr;
    glass_stamp(4);
    for (int k = 0; k < gg.probe_load; k++) {
        GlassLevel &src = gg.load[k & 1], &dst = gg.load[(k + 1) & 1];
        c->OMSetRenderTargets(1, &dst.rtv, nullptr);
        c->PSSetShaderResources(0, 1, &src.srv);
        c->Draw(6, 0);
        c->PSSetShaderResources(0, 1, &none);
    }
    glass_stamp(0);
    c->OMSetRenderTargets(0, nullptr, nullptr);
}

/* -- the surface ------------------------------------------------------------------------ */
ID3D11ShaderResourceView *scene_srv(int tex);
ID3D11ShaderResourceView *texture_srv(int id) {
    if (id < 0) return scene_srv(id);   /* the scene target (lunar_scene_d3d11.inc) */
    auto it = g.textures.find(id);
    return it == g.textures.end() ? nullptr : it->second.srv;
}

/* The glass shader, this surface's constants and its two textures. */
/* ImGui resolves the data pointer in Render(); dialog and overlay windows' own lists do
   not go through it, so it is resolved here from the list's buffer */
const GlassCmd *glass_cmd(const ImDrawList *dl, const ImDrawCmd *cmd) {
    const GlassCmd *d = (const GlassCmd*)cmd->UserCallbackData;
    if (!d && cmd->UserCallbackDataOffset >= 0 && cmd->UserCallbackDataSize >= (int)sizeof(GlassCmd))
        d = (const GlassCmd*)(dl->_CallbacksDataBuf.Data + cmd->UserCallbackDataOffset);
    return d;
}
void glass_cb_bind(const ImDrawList *dl, const ImDrawCmd *cmd) {
    const GlassCmd *d = glass_cmd(dl, cmd);
    if (!d || !gg.ready) return;
    ID3D11ShaderResourceView *srv[2];
    float ku, kv, vw, vh;
    /* a copy that failed (or never ran) this frame holds another frame's pixels, or none:
       this draw shows the tint instead */
    bool stale = false;
    if (d->kind != GLASS_CHROME)
        stale = d->point >= 0 ? !((size_t)d->point < gg.npts && gg.pts[(size_t)d->point].done && gg.pts[(size_t)d->point].ok)
                              : !gg.fl_ok;
    if (d->kind == GLASS_CHROME) {   /* the floor images, mapped as core.ui.Glass maps them */
        srv[0] = texture_srv(d->floor_sharp); srv[1] = texture_srv(d->floor_blur);
        ku = d->ku; kv = d->kv; vw = vh = 1e7f;
    } else {                         /* this frame's copy and the one blur it samples */
        srv[0] = gg.lv[0].srv; srv[1] = d->kind == GLASS_FLOATING && !d->soft ? gg.lv[1].srv : gg.lv[3].srv;
        ku = 1.0f / gg.tw; kv = 1.0f / gg.th; vw = (float)gg.vw; vh = (float)gg.vh;
    }
    /* a texture gone (a floor image freed mid-frame, a level not made): the rounded tint,
       never the transparent quad */
    if (!srv[0] || !srv[1] || gg.fail == 1) { stale = true; srv[0] = srv[1] = nullptr; }
    /* the blur's last written texel centre, in px: ceil(extent / 4) - 0.5 texels */
    float bx = d->kind == GLASS_CHROME ? 1e7f : (((gg.vw + 3) >> 2) - 0.5f) * 4.0f;
    float by = d->kind == GLASS_CHROME ? 1e7f : (((gg.vh + 3) >> 2) - 0.5f) * 4.0f;
    glass_stamp(1);
    float cb[44] = {
        d->rect[0], d->rect[1], d->rect[2], d->rect[3],
        gg.origin.x, gg.origin.y, ku, kv,
        vw, vh, d->radius, d->band,
        d->thickness, d->lift, d->alpha, d->hollow,
        d->tint[0], d->tint[1], d->tint[2], d->tint[3],
        d->rim[0], d->rim[1], d->rim[2], d->rim[3],
        d->inner[0], d->inner[1], d->inner[2], d->inner[3],
        d->well[0], d->well[1], d->well[2], d->well[3],
        d->chroma, d->rim_floor, d->rim_blur, 0,
        d->light[0], d->light[1], d->lum_max, d->lum_min,
        std::max(0.5f, d->blur_depth), stale ? 1.0f : 0.0f, bx, by,
    };
    ID3D11Buffer *buf = gg.cb;
    D3D11_MAPPED_SUBRESOURCE m;
    if (gg.fail != 2 && SUCCEEDED(g.ctx->Map(gg.cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) {
        memcpy(m.pData, cb, sizeof(cb)); g.ctx->Unmap(gg.cb, 0);
    } else {
        /* the dynamic buffer would not map: the same constants, the tint alone, through the
           default-usage buffer (UpdateSubresource has no failure to report) */
        cb[41] = 1.0f; srv[0] = srv[1] = nullptr;
        g.ctx->UpdateSubresource(gg.cb_fallback, 0, nullptr, cb, 0, 0);
        buf = gg.cb_fallback;
    }
    g.ctx->PSSetShader(gg.glass, nullptr, 0);
    g.ctx->PSSetConstantBuffers(0, 1, &buf);
    g.ctx->PSSetShaderResources(1, 2, srv);
    g.ctx->PSSetSamplers(1, 1, &gg.smp);
}

/* A rounded image's mask (ps_mask): its constants and shader; ImGui binds its texture and
   sampler for the quad that follows, and the state reset after it puts ImGui's shader
   back. If the constants will not map they go through the default-usage buffer, so the
   image keeps its silhouette (never the square quad, 1 px too large, that a glass copy
   later in the frame or the next one could take up). */
struct MaskCmd { float rect[4]; float radius; };
void glass_cb_mask(const ImDrawList *dl, const ImDrawCmd *cmd) {
    const MaskCmd *d = (const MaskCmd*)cmd->UserCallbackData;
    if (!d && cmd->UserCallbackDataOffset >= 0 && cmd->UserCallbackDataSize >= (int)sizeof(MaskCmd))
        d = (const MaskCmd*)(dl->_CallbacksDataBuf.Data + cmd->UserCallbackDataOffset);
    if (!d || !gg.ready || !gg.mask) return;
    float cb[8] = {d->rect[0], d->rect[1], d->rect[2], d->rect[3], gg.origin.x, gg.origin.y, d->radius, 0};
    ID3D11Buffer *buf = gg.mask_cb;
    D3D11_MAPPED_SUBRESOURCE m;
    if (gg.fail != 2 && SUCCEEDED(g.ctx->Map(gg.mask_cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) {
        memcpy(m.pData, cb, sizeof(cb)); g.ctx->Unmap(gg.mask_cb, 0);
    } else {
        g.ctx->UpdateSubresource(gg.mask_fallback, 0, nullptr, cb, 0, 0);
        buf = gg.mask_fallback;
    }
    g.ctx->PSSetShader(gg.mask, nullptr, 0);
    g.ctx->PSSetConstantBuffers(0, 1, &buf);
}

void glass_unpack(uint32_t c, float out[4]) {
    out[0] = ((c >> IM_COL32_R_SHIFT) & 0xFF) / 255.0f; out[1] = ((c >> IM_COL32_G_SHIFT) & 0xFF) / 255.0f;
    out[2] = ((c >> IM_COL32_B_SHIFT) & 0xFF) / 255.0f; out[3] = ((c >> IM_COL32_A_SHIFT) & 0xFF) / 255.0f;
}

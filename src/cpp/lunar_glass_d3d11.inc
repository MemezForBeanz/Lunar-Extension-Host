/* Liquid Glass on the GPU (core.ui.Glass), Direct3D 11, hardware devices only.
 *
 * Included by lunarimgui.cpp inside its namespace, after State `g`. On WARP none of this
 * is made: core.ui.Glass asks lunar_ui_glass_ready() each frame and keeps its baked path.
 *
 * Cost model (lg-shader-1.md, Efficiency):
 *   - No glass on screen: nothing at all (no copy, no blur, no query).
 *   - Chrome (title strip, rail caps, status bar, Media transport) lies on the floor, the
 *     baked backdrop whose sharp and softened images are already on the GPU: it samples
 *     those directly, so it needs no copy and no blur.
 *   - Floating glass (menus, dropdowns, tooltips, palette, toasts, Activity) samples the
 *     main window's background layer, copied once per frame after that layer, and only
 *     where it lies under floating glass: the glass rects widened by the refraction/blur
 *     margin, merged where that saves work, each copied with CopySubresourceRegion.
 *   - One blur for all of it, at quarter resolution: full -> 1/4 (16 texels in 4 bilinear
 *     taps), dual-Kawase 1/4 -> 1/8 and back up to 1/4. Three passes, each one draw that
 *     covers every region. The glass samples the full-res copy (rim) and the two 1/4
 *     results (light and strong blur).
 *   - Nothing under the glass changed (the background layer's draw data reaching the
 *     regions hashes as last frame, same regions, no texture made): copy and blur skipped.
 *   - Each surface: one callback (shader, constants, its three textures), one quad, one
 *     state reset; a single pixel-shader pass. Floating glass discards under its opaque
 *     text well before sampling.
 *   - Textures are made at the monitor's size (rounded to 256 px) and re-made only if the
 *     window outgrows them; shaders and state objects once per device; nothing uploaded;
 *     per-frame vectors keep their capacity.
 * LUNAR_GPU_TIMING=1 adds D3D11 timestamp queries round the glass work (read back up to
 * three frames later, never stalling) for renderer().glass_gpu_*. */

const char *GLASS_HLSL = R"(
cbuffer D : register(b0) {
    float4 src_info;      /* 1/src size, last valid src px */
    float4 dst_info;      /* dest level size w h, dest->src scale, level shift factor (1 << shift) */
    float4 regions[16];   /* level-0 px x0 y0 x1 y1 */
};
struct VO { float4 pos : SV_POSITION; };
/* six vertices per region: one draw covers them all */
VO vs_regions(uint id : SV_VertexID) {
    float4 r = regions[id / 6] / dst_info.w;
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
    float4 shape;   /* valid w h of the sample (px), corner radius, lens band px */
    float4 optic;   /* lens thickness px, light->strong blur mix, hover lift, opacity */
    float4 tint; float4 rim; float4 inner;
    float4 extra;   /* chromatic split px, body blur, 0, hollow depth (0: none) */
};
Texture2D sharp : register(t1); Texture2D light_blur : register(t2); Texture2D strong_blur : register(t3);
struct PI { float4 pos : SV_POSITION; float4 col : COLOR0; float2 uv : TEXCOORD0; };
float3 at(Texture2D t, float2 p) { return t.SampleLevel(smp, clamp(p, 0.5, shape.xy - 0.5) * frame.zw, 0).rgb; }
float4 ps_glass(PI i) : SV_Target {
    float2 p = i.pos.xy + frame.xy;
    float2 c = (rect.xy + rect.zw) * 0.5, hs = (rect.zw - rect.xy) * 0.5;
    float r = min(shape.z, min(hs.x, hs.y));
    float2 d = p - c;
    float2 q = abs(d) - (hs - r);
    float sd = length(max(q, 0)) + min(max(q.x, q.y), 0) - r;
    float cov = saturate(0.5 - sd) * optic.w;   /* the quad's own colour is transparent */
    if (cov <= 0) discard;
    float depth = max(0, -sd);
    if (extra.w > 0 && depth > extra.w) discard;            /* under the opaque well: nothing to show */
    float2 sg = float2(d.x < 0 ? -1 : 1, d.y < 0 ? -1 : 1);
    float2 m = max(q, 0);
    float2 gr = (m.x + m.y > 0) ? normalize(m) : (q.x > q.y ? float2(1, 0) : float2(0, 1));
    float2 n = sg * gr;                                     /* outward normal */
    float u = 1 - saturate(depth / max(1, shape.w));        /* 1 at the rim, 0 past the band */
    float lens = optic.x * (1 - sqrt(saturate(1 - u * u))); /* ~0 inside, rising to the rim */
    float2 sp = p - n * lens;                               /* refracted inward */
    float ca = extra.x * u;
    float3 s = at(sharp, sp);
    [branch] if (ca > 0.05) { s.r = at(sharp, sp - n * ca).r; s.b = at(sharp, sp + n * ca).b; }
    float3 b = lerp(at(light_blur, sp), at(strong_blur, sp), optic.y);
    float3 col = lerp(s, b, extra.y * smoothstep(0, 1, 1 - u));   /* sharper toward the rim */
    col = lerp(col, tint.rgb, tint.a);
    float inside = (p.x >= 0 && p.y >= 0 && p.x < shape.x && p.y < shape.y) ? 1 : 0;
    col = lerp(tint.rgb, col, inside);                      /* past the window: the tint */
    float f = dot(n, float2(-0.7071, -0.7071));             /* light from the upper left */
    /* the rim: a thin ring all round (the glass's edge catching light), brightest at the
       upper-left shoulder, a weaker back-light on the far side, and a soft sheen inside it */
    float line_ = saturate(1.25 - depth / 1.8);
    float sheen = exp(-depth / 3.5);
    float hi = saturate(rim.a + 0.10 * optic.z);
    float spec = hi * (line_ * (0.40 + 0.60 * pow(saturate(f), 1.2) + 0.35 * pow(saturate(-f), 2))
        + 0.30 * sheen * pow(saturate(f), 2));
    col = lerp(col, rim.rgb, saturate(spec));
    col = lerp(col, inner.rgb, saturate(inner.a * saturate(-f) * exp(-depth / 2.5)));
    return float4(col, cov);
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
struct GlassTiming {
    ID3D11Query *disjoint = nullptr; ID3D11Query *ts[GLASS_TS] = {};
    int n = 0; bool pending = false;
    unsigned char opens[GLASS_TS] = {};   /* 0 closes a span; opens 1 a surface, 2 the copy, 3 the blur */
};
struct GlassGpu {
    bool tried = false, ready = false;
    std::string error;
    ID3D11VertexShader *vs = nullptr; ID3D11PixelShader *down4 = nullptr, *down = nullptr, *up = nullptr, *glass = nullptr;
    ID3D11Buffer *cb = nullptr, *blur_cb = nullptr;
    ID3D11RasterizerState *rs = nullptr; ID3D11SamplerState *smp = nullptr;
    /* 0: the copy; 1: 1/4 down (light blur); 2: 1/8; 3: 1/4 up (strong blur) */
    GlassLevel lv[4];
    int tw = 0, th = 0;    /* level 0's size (a multiple of 256) */
    int vw = 0, vh = 0;    /* the part of it the back buffer fills */
    bool used = false;     /* this frame drew glass */
    ImVec2 origin;         /* the display origin of what is being rendered now */
    std::vector<GlassRect> fl, merged;   /* this frame's floating glass rects (main-client) */
    bool skip = false;     /* nothing under the glass changed: reuse last frame's textures */
    bool valid = false;    /* the textures hold last frame's result */
    bool force = false;    /* window("glass_force_copy"): never skip (worst-case timing) */
    bool off = false;      /* window("glass_shader", false): the baked path, for comparison */
    uint64_t last_hash = 0;
    long long surfaces = 0, copies = 0, skips = 0, passes = 0, creations = 0;
    bool timing = false;
    GlassTiming tq[GLASS_TIMING_FRAMES]; int tcur = 0;
    double gpu_glass_us_sum = 0, gpu_glass_us_max = 0, gpu_frame_us_sum = 0, gpu_copy_us_sum = 0;
    double gpu_glass_us_last = 0, hash_us_sum = 0, gpu_blur_us_sum = 0; long long gpu_frames = 0;
    /* per-frame samples for window("glass_timing_take"): glass, copy + blur, whole frame (us) */
    float sample_glass[1024] = {}, sample_copy[1024] = {}, sample_frame[1024] = {}; int samples = 0;
} gg;

struct GlassCmd {
    float rect[4]; float radius, band, thickness, blur_mix, lift, alpha, chroma, body;
    float tint[4], rim[4], inner[4];
    float hollow;   /* depth past which an opaque well covers it (floating), 0 none */
    float ku, kv;   /* chrome: px -> uv of the floor images */
    int floor_sharp, floor_blur;   /* chrome: the floor images' texture ids, 0 for floating */
};

/* -- timing ----------------------------------------------------------------------------- */
GlassTiming *glass_tq() { return gg.timing && gg.tq[gg.tcur].disjoint ? &gg.tq[gg.tcur] : nullptr; }
void glass_stamp(int kind) {
    GlassTiming *t = glass_tq();
    if (!t || !t->pending || t->n >= GLASS_TS) return;
    t->opens[t->n] = (unsigned char)kind;
    g.ctx->End(t->ts[t->n++]);
}
void glass_cb_stamp(const ImDrawList *, const ImDrawCmd *) { glass_stamp(0); }
void glass_timing_collect() {
    for (int k = 0; k < GLASS_TIMING_FRAMES; k++) {
        GlassTiming &t = gg.tq[k];
        if (!t.pending || &t == &gg.tq[gg.tcur]) continue;
        D3D11_QUERY_DATA_TIMESTAMP_DISJOINT dj;
        if (g.ctx->GetData(t.disjoint, &dj, sizeof(dj), D3D11_ASYNC_GETDATA_DONOTFLUSH) != S_OK) continue;
        t.pending = false;
        if (dj.Disjoint || dj.Frequency == 0 || t.n < 2) continue;
        UINT64 v[GLASS_TS];
        bool ok = true;
        for (int i = 0; i < t.n && ok; i++)
            ok = g.ctx->GetData(t.ts[i], &v[i], sizeof(UINT64), D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK;
        if (!ok) continue;
        double us = 1e6 / (double)dj.Frequency, glass = 0, copy = 0, blur = 0;
        for (int i = 0; i + 1 < t.n; i++) {
            double span = (double)(v[i + 1] - v[i]) * us;
            if (t.opens[i]) glass += span;
            if (t.opens[i] == 2) copy += span;
            if (t.opens[i] == 3) blur += span;
        }
        gg.gpu_copy_us_sum += copy; gg.gpu_blur_us_sum += blur;
        gg.gpu_glass_us_last = glass;
        if (gg.samples < GLASS_SAMPLES) {
            gg.sample_glass[gg.samples] = (float)glass; gg.sample_copy[gg.samples] = (float)(copy + blur);
            gg.sample_frame[gg.samples] = (float)((double)(v[t.n - 1] - v[0]) * us); gg.samples++;
        }
        gg.gpu_glass_us_sum += glass; gg.gpu_glass_us_max = std::max(gg.gpu_glass_us_max, glass);
        gg.gpu_frame_us_sum += (double)(v[t.n - 1] - v[0]) * us;
        gg.gpu_frames++;
    }
}
void glass_timing_begin() {
    if (!gg.timing) return;
    glass_timing_collect();
    GlassTiming &t = gg.tq[gg.tcur];
    if (t.pending || !t.disjoint) return;   /* not read back yet: this frame goes untimed */
    t.n = 0; t.pending = true;
    g.ctx->Begin(t.disjoint);
    glass_stamp(0);
}
void glass_timing_end() {
    GlassTiming *t = glass_tq();
    if (!t || !t->pending) return;
    glass_stamp(0);
    g.ctx->End(t->disjoint);
    gg.tcur = (gg.tcur + 1) % GLASS_TIMING_FRAMES;
}

/* -- objects ---------------------------------------------------------------------------- */
void glass_release_levels() {
    for (GlassLevel &l : gg.lv) {
        if (l.rtv) { l.rtv->Release(); l.rtv = nullptr; }
        if (l.srv) { if (g.frame_open) g.retired_textures.push_back(l.srv); else l.srv->Release(); l.srv = nullptr; }
        if (l.tex) { l.tex->Release(); l.tex = nullptr; }
    }
    gg.tw = gg.th = 0; gg.valid = false;
}

void glass_release() {
    glass_release_levels();
    auto rel = [](auto *&p) { if (p) { p->Release(); p = nullptr; } };
    rel(gg.vs); rel(gg.down4); rel(gg.down); rel(gg.up); rel(gg.glass); rel(gg.cb); rel(gg.blur_cb); rel(gg.rs); rel(gg.smp);
    for (GlassTiming &t : gg.tq) { rel(t.disjoint); for (auto *&q : t.ts) rel(q); t.pending = false; t.n = 0; }
    gg.tried = gg.ready = false; gg.used = gg.skip = false;
    gg.fl.clear();
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
        *glass = glass_compile("ps_glass", "ps_4_0");
    auto ps = [](ID3DBlob *b, ID3D11PixelShader **out) {
        return SUCCEEDED(g.device->CreatePixelShader(b->GetBufferPointer(), b->GetBufferSize(), nullptr, out));
    };
    bool ok = vs && down4 && down && up && glass
        && SUCCEEDED(g.device->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr, &gg.vs))
        && ps(down4, &gg.down4) && ps(down, &gg.down) && ps(up, &gg.up) && ps(glass, &gg.glass);
    for (ID3DBlob *b : {vs, down4, down, up, glass}) if (b) b->Release();
    if (ok) {
        D3D11_BUFFER_DESC b = {};
        b.Usage = D3D11_USAGE_DYNAMIC; b.BindFlags = D3D11_BIND_CONSTANT_BUFFER; b.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        b.ByteWidth = 8 * 16;
        ok = SUCCEEDED(g.device->CreateBuffer(&b, nullptr, &gg.cb));
        b.ByteWidth = (2 + GLASS_REGIONS) * 16;
        ok = ok && SUCCEEDED(g.device->CreateBuffer(&b, nullptr, &gg.blur_cb));
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
    if (w != gg.vw || h != gg.vh) gg.valid = false;
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
/* `in` widened by the margin, clipped to the back buffer (and aligned to 4 px, the 1/4
   texel), merged where the box round two is no bigger than the two apart. */
void glass_merge(const std::vector<GlassRect> &in, std::vector<GlassRect> &out) {
    out.clear();
    for (const GlassRect &r : in) {
        GlassRect m = {std::max(0, (r.x0 - GLASS_MARGIN) & ~7), std::max(0, (r.y0 - GLASS_MARGIN) & ~7),
                       std::min(gg.vw, (r.x1 + GLASS_MARGIN + 7) & ~7), std::min(gg.vh, (r.y1 + GLASS_MARGIN + 7) & ~7)};
        if (m.x1 <= m.x0 || m.y1 <= m.y0) continue;
        out.push_back(m);
    }
    for (bool merged = true; merged;) {
        merged = false;
        for (size_t i = 0; i < out.size() && !merged; i++)
            for (size_t j = i + 1; j < out.size() && !merged; j++) {
                GlassRect &a = out[i], &b = out[j];
                GlassRect u = {std::min(a.x0, b.x0), std::min(a.y0, b.y0), std::max(a.x1, b.x1), std::max(a.y1, b.y1)};
                if (glass_area(u) <= glass_area(a) + glass_area(b) || out.size() > (size_t)GLASS_REGIONS) {
                    a = u; out.erase(out.begin() + (long)j); merged = true;
                }
            }
    }
}

/* One blur pass of `src` into `dst` over every region, in one draw. */
void glass_pass(ID3D11PixelShader *ps, const GlassLevel &src, const GlassLevel &dst, const std::vector<GlassRect> &regions) {
    ID3D11DeviceContext *c = g.ctx;
    int sw = gg.tw >> src.shift, sh = gg.th >> src.shift, sv = (1 << src.shift) - 1;
    int dw = gg.tw >> dst.shift, dh = gg.th >> dst.shift;
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(c->Map(gg.blur_cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) return;
    float *v = (float*)m.pData;
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
}

/* FNV-1a over 64-bit words */
inline uint64_t glass_mix(uint64_t h, const void *p, size_t n) {
    const unsigned char *b = (const unsigned char*)p;
    size_t i = 0;
    for (; i + 8 <= n; i += 8) { uint64_t w; memcpy(&w, b + i, 8); h = (h ^ w) * 0x100000001B3ull; }
    for (; i < n; i++) h = (h ^ b[i]) * 0x100000001B3ull;
    return h;
}

/* Before the main window renders: the floating regions, and may their copy and blur be
   skipped? They may when the background layer's draw commands that reach the regions
   (vertices, textures, clips), the regions and the textures made are all as last frame. */
void glass_plan(ImDrawList *bg) {
    gg.skip = false;
    if (gg.fl.empty()) return;
    auto t0 = std::chrono::steady_clock::now();
    glass_merge(gg.fl, gg.merged);
    uint64_t h = 1469598103934665603ull;
    h = glass_mix(h, gg.merged.data(), gg.merged.size() * sizeof(GlassRect));
    h = glass_mix(h, &g.next_texture, sizeof(g.next_texture));
    int size[2] = {gg.vw, gg.vh}; h = glass_mix(h, size, sizeof(size));
    if (bg) {
        for (const ImDrawCmd &cmd : bg->CmdBuffer) {
            if (cmd.UserCallback || cmd.ElemCount == 0) continue;
            bool hit = false;
            for (const GlassRect &r : gg.merged)
                if (cmd.ClipRect.x < r.x1 && cmd.ClipRect.z > r.x0 && cmd.ClipRect.y < r.y1 && cmd.ClipRect.w > r.y0) { hit = true; break; }
            if (!hit) continue;
            h = glass_mix(h, &cmd.ClipRect, sizeof(cmd.ClipRect));
            ImTextureID tid = cmd.GetTexID(); h = glass_mix(h, &tid, sizeof(tid));
            /* the vertices this command draws: ImGui appends them in order, so they span
               its smallest to its largest index */
            const ImDrawIdx *idx = bg->IdxBuffer.Data + cmd.IdxOffset;
            unsigned lo = UINT_MAX, hi = 0;
            for (unsigned i = 0; i < cmd.ElemCount; i++) { lo = std::min(lo, (unsigned)idx[i]); hi = std::max(hi, (unsigned)idx[i]); }
            unsigned first = cmd.VtxOffset + lo, last = cmd.VtxOffset + hi;
            if (last < (unsigned)bg->VtxBuffer.Size)
                h = glass_mix(h, bg->VtxBuffer.Data + first, (size_t)(last - first + 1) * sizeof(ImDrawVert));
        }
    }
    gg.skip = gg.valid && !gg.force && h == gg.last_hash;
    gg.last_hash = h;
    if (gg.skip) gg.skips++;
    gg.hash_us_sum += std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count();
}

/* After the main window's background layer: copy the floating regions of `back` and blur
   them. Leaves no render target bound. */
void glass_floating_copy(ID3D11Resource *back) {
    if (!gg.ready || !gg.lv[0].tex || gg.fl.empty() || gg.skip || gg.merged.empty()) return;
    ID3D11DeviceContext *c = g.ctx;
    glass_stamp(2);
    c->OMSetRenderTargets(0, nullptr, nullptr);
    ID3D11ShaderResourceView *none[4] = {};
    c->PSSetShaderResources(0, 4, none);
    for (const GlassRect &r : gg.merged) {
        D3D11_BOX box = {(UINT)r.x0, (UINT)r.y0, 0, (UINT)r.x1, (UINT)r.y1, 1};
        c->CopySubresourceRegion(gg.lv[0].tex, 0, (UINT)r.x0, (UINT)r.y0, 0, back, 0, &box);
        gg.copies++;
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
    glass_pass(gg.down4, gg.lv[0], gg.lv[1], gg.merged);
    glass_pass(gg.down, gg.lv[1], gg.lv[2], gg.merged);
    glass_pass(gg.up, gg.lv[2], gg.lv[3], gg.merged);
    c->OMSetRenderTargets(0, nullptr, nullptr);
    glass_stamp(0);
}

/* -- the surface ------------------------------------------------------------------------ */
ID3D11ShaderResourceView *texture_srv(int id) {
    auto it = g.textures.find(id);
    return it == g.textures.end() ? nullptr : it->second.srv;
}

/* The glass shader, this surface's constants and its three textures. */
void glass_cb_bind(const ImDrawList *dl, const ImDrawCmd *cmd) {
    /* ImGui resolves the data pointer in Render(); dialog and overlay windows' own lists
       do not go through it, so it is resolved here from the list's buffer */
    const GlassCmd *d = (const GlassCmd*)cmd->UserCallbackData;
    if (!d && cmd->UserCallbackDataOffset >= 0 && cmd->UserCallbackDataSize >= (int)sizeof(GlassCmd))
        d = (const GlassCmd*)(dl->_CallbacksDataBuf.Data + cmd->UserCallbackDataOffset);
    if (!d || !gg.ready) return;
    ID3D11ShaderResourceView *srv[3];
    float ku, kv, vw, vh;
    if (d->floor_sharp) {   /* chrome: the floor images, mapped as core.ui.Glass maps them */
        srv[0] = texture_srv(d->floor_sharp); srv[1] = srv[2] = texture_srv(d->floor_blur);
        ku = d->ku; kv = d->kv; vw = vh = 1e7f;
    } else {                /* floating: this frame's copy and its blurs */
        srv[0] = gg.lv[0].srv; srv[1] = gg.lv[1].srv; srv[2] = gg.lv[3].srv;
        ku = 1.0f / gg.tw; kv = 1.0f / gg.th; vw = (float)gg.vw; vh = (float)gg.vh;
    }
    if (!srv[0] || !srv[1]) return;
    glass_stamp(1);
    float cb[32] = {
        d->rect[0], d->rect[1], d->rect[2], d->rect[3],
        gg.origin.x, gg.origin.y, ku, kv,
        vw, vh, d->radius, d->band,
        d->thickness, d->blur_mix, d->lift, d->alpha,
        d->tint[0], d->tint[1], d->tint[2], d->tint[3],
        d->rim[0], d->rim[1], d->rim[2], d->rim[3],
        d->inner[0], d->inner[1], d->inner[2], d->inner[3],
        d->chroma, d->body, 0, d->hollow,
    };
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(g.ctx->Map(gg.cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) return;
    memcpy(m.pData, cb, sizeof(cb)); g.ctx->Unmap(gg.cb, 0);
    g.ctx->PSSetShader(gg.glass, nullptr, 0);
    g.ctx->PSSetConstantBuffers(0, 1, &gg.cb);
    g.ctx->PSSetShaderResources(1, 3, srv);
    g.ctx->PSSetSamplers(1, 1, &gg.smp);
}

void glass_unpack(uint32_t c, float out[4]) {
    out[0] = ((c >> IM_COL32_R_SHIFT) & 0xFF) / 255.0f; out[1] = ((c >> IM_COL32_G_SHIFT) & 0xFF) / 255.0f;
    out[2] = ((c >> IM_COL32_B_SHIFT) & 0xFF) / 255.0f; out[3] = ((c >> IM_COL32_A_SHIFT) & 0xFF) / 255.0f;
}

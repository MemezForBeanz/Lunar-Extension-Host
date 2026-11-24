/* Liquid Glass on the GPU (core.ui.Glass), Direct3D 11, hardware devices only.
 *
 * Included by lunarimgui.cpp inside its namespace, after State `g`. On WARP none of this
 * is made: core.ui.Glass asks lunar_ui_glass_ready() each frame and keeps its baked path.
 *
 * Cost model (lg-shader-1.md, Efficiency):
 *   - No glass on screen: nothing at all (no copy, no blur, no query).
 *   - Only the regions under glass are copied and blurred: the glass rects of the frame,
 *     widened by the refraction/blur margin and merged where they touch, each copied with
 *     CopySubresourceRegion and blurred with scissored passes.
 *   - Two copy points share one set of textures: background-layer glass (title strip, rail
 *     caps, status bar, Media transport) is copied once, when the first such surface is
 *     drawn, over all of their regions (what lies under them is the floor drawn before);
 *     floating glass (menus, dropdowns, tooltips, palette, toasts, Activity) once after
 *     the background layer.
 *   - Blur: dual-Kawase at reduced resolution, down to 1/2, 1/4 and 1/8 and one up pass
 *     back to 1/4. The glass samples the full-res copy (rim) and the 1/4 results (body).
 *   - Nothing under the glass changed (the background layer's draw data inside the glass
 *     regions hashes the same as last frame, same regions, no texture made): the copy and
 *     the blur are skipped; the surfaces draw from last frame's textures.
 *   - Each surface: one callback (shader + constants), one quad, one state reset.
 *   - Textures are made once at the monitor's size (rounded to 256 px) and only re-made if
 *     the window outgrows them; state objects and shaders are made once per device; nothing
 *     is uploaded; per-frame vectors keep their capacity.
 * LUNAR_GPU_TIMING=1 adds D3D11 timestamp queries round the glass work (read back three
 * frames later, never stalling) for renderer().glass_gpu_*. */

const char *GLASS_HLSL = R"(
struct VO { float4 pos : SV_POSITION; };
VO vs_full(uint id : SV_VertexID) {
    VO o; float2 t = float2((id << 1) & 2, id & 2);
    o.pos = float4(t * float2(2, -2) + float2(-1, 1), 0, 1); return o;
}
cbuffer D : register(b0) { float4 src_info; float4 src_scale; };  /* 1/src size, last valid src px; dest->src scale */
Texture2D src : register(t0);
SamplerState smp : register(s1);
float4 tap(float2 p) { return src.SampleLevel(smp, clamp(p, 0.5, src_info.zw) * src_info.xy, 0); }
float4 ps_down(VO i) : SV_Target {
    float2 p = i.pos.xy * src_scale.x;
    return (tap(p) * 4 + tap(p + float2(-1, -1)) + tap(p + float2(1, -1)) + tap(p + float2(-1, 1)) + tap(p + float2(1, 1))) / 8;
}
float4 ps_up(VO i) : SV_Target {
    float2 p = i.pos.xy * src_scale.x;
    float4 s = tap(p + float2(-1, 0)) + tap(p + float2(1, 0)) + tap(p + float2(0, -1)) + tap(p + float2(0, 1));
    s += 2 * (tap(p + float2(-0.5, -0.5)) + tap(p + float2(0.5, -0.5)) + tap(p + float2(-0.5, 0.5)) + tap(p + float2(0.5, 0.5)));
    return s / 12;
}

cbuffer G : register(b0) {
    float4 rect;    /* x1 y1 x2 y2, main-client px */
    float4 frame;   /* origin x y, 1 / level-0 size */
    float4 shape;   /* valid w h of the copy, corner radius, lens band px */
    float4 optic;   /* lens thickness px, light->strong blur mix, hover lift, opacity */
    float4 tint; float4 rim; float4 inner;
    float4 extra;   /* chromatic split px, body blur, passthrough, 0 */
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
    if (extra.z > 0.5) return float4(at(sharp, p), cov);    /* already composited (a dialog's underlay) */
    float2 sg = float2(d.x < 0 ? -1 : 1, d.y < 0 ? -1 : 1);
    float2 m = max(q, 0);
    float2 gr = (m.x + m.y > 0) ? normalize(m) : (q.x > q.y ? float2(1, 0) : float2(0, 1));
    float2 n = sg * gr;                                     /* outward normal */
    float depth = max(0, -sd);
    float u = 1 - saturate(depth / max(1, shape.w));        /* 1 at the rim, 0 past the band */
    float lens = optic.x * (1 - sqrt(saturate(1 - u * u))); /* ~0 inside, rising to the rim */
    float2 sp = p - n * lens;                               /* refracted inward */
    float ca = extra.x * u;
    float3 s = float3(at(sharp, sp - n * ca).r, at(sharp, sp).g, at(sharp, sp + n * ca).b);
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
const int GLASS_TS = 96;          /* timestamps per frame at most */
const int GLASS_TIMING_FRAMES = 4;
struct GlassTiming {
    ID3D11Query *disjoint = nullptr; ID3D11Query *ts[GLASS_TS] = {};
    int n = 0; bool pending = false;
    /* which timestamps open a glass span (pairs i, i+1); the frame span is 0 .. last */
    unsigned char opens[GLASS_TS] = {};
};
struct GlassGpu {
    bool tried = false, ready = false;
    std::string error;
    ID3D11VertexShader *vs = nullptr; ID3D11PixelShader *down = nullptr, *up = nullptr, *glass = nullptr;
    ID3D11Buffer *cb = nullptr, *down_cb = nullptr;
    ID3D11RasterizerState *rs = nullptr; ID3D11SamplerState *smp = nullptr;
    /* 0: the copy; 1..3: 1/2, 1/4, 1/8 down; 4: 1/4 up (the strong blur) */
    GlassLevel lv[5];
    int tw = 0, th = 0;    /* level 0's size (a multiple of 256) */
    int vw = 0, vh = 0;    /* the part of it the back buffer fills */
    bool used = false;     /* this frame drew glass */
    bool main_target = false; ImVec2 origin;  /* what is being rendered now */
    std::vector<GlassRect> bg, fl, merged;    /* this frame's glass rects (main-client) */
    bool bg_done = false;  /* the background snapshot was taken this frame */
    bool skip = false;     /* nothing under the glass changed: reuse last frame's textures */
    bool valid = false;    /* the textures hold last frame's result */
    uint64_t last_hash = 0;
    long long surfaces = 0, copies = 0, skips = 0, passes = 0, creations = 0;
    /* timing */
    bool timing = false;
    GlassTiming tq[GLASS_TIMING_FRAMES]; int tcur = 0;
    double gpu_glass_us_sum = 0, gpu_glass_us_max = 0, gpu_frame_us_sum = 0; long long gpu_frames = 0;
    double gpu_glass_us_last = 0, hash_us_sum = 0;
} gg;

struct GlassCmd {
    float rect[4]; float radius, band, thickness, blur_mix, lift, alpha, chroma, body;
    float tint[4], rim[4], inner[4];
    int snap;
};

/* -- timing ----------------------------------------------------------------------------- */
GlassTiming *glass_tq() { return gg.timing && gg.tq[gg.tcur].disjoint ? &gg.tq[gg.tcur] : nullptr; }
void glass_stamp(bool opens_glass) {
    GlassTiming *t = glass_tq();
    if (!t || !t->pending || t->n >= GLASS_TS) return;
    t->opens[t->n] = opens_glass ? 1 : 0;
    g.ctx->End(t->ts[t->n++]);
}
void glass_cb_stamp(const ImDrawList *, const ImDrawCmd *cmd) { glass_stamp(cmd->UserCallbackData != nullptr); }
void glass_timing_collect() {
    /* the oldest slot, issued GLASS_TIMING_FRAMES - 1 frames ago */
    for (int k = 0; k < GLASS_TIMING_FRAMES; k++) {
        GlassTiming &t = gg.tq[k];
        if (!t.pending || &t == &gg.tq[gg.tcur]) continue;
        D3D11_QUERY_DATA_TIMESTAMP_DISJOINT dj;
        if (g.ctx->GetData(t.disjoint, &dj, sizeof(dj), D3D11_ASYNC_GETDATA_DONOTFLUSH) != S_OK) continue;
        t.pending = false;
        if (dj.Disjoint || dj.Frequency == 0 || t.n < 2) continue;
        std::vector<UINT64> v((size_t)t.n);
        bool ok = true;
        for (int i = 0; i < t.n && ok; i++)
            ok = g.ctx->GetData(t.ts[i], &v[(size_t)i], sizeof(UINT64), D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK;
        if (!ok) continue;
        double us = 1e6 / (double)dj.Frequency, glass = 0;
        for (int i = 0; i + 1 < t.n; i++) if (t.opens[i]) glass += (double)(v[(size_t)i + 1] - v[(size_t)i]) * us;
        gg.gpu_glass_us_last = glass;
        gg.gpu_glass_us_sum += glass; gg.gpu_glass_us_max = std::max(gg.gpu_glass_us_max, glass);
        gg.gpu_frame_us_sum += (double)(v[(size_t)t.n - 1] - v[0]) * us;
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
    glass_stamp(false);
}
void glass_timing_end() {
    GlassTiming *t = glass_tq();
    if (!t || !t->pending) return;
    glass_stamp(false);
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
    rel(gg.vs); rel(gg.down); rel(gg.up); rel(gg.glass); rel(gg.cb); rel(gg.down_cb); rel(gg.rs); rel(gg.smp);
    for (GlassTiming &t : gg.tq) { rel(t.disjoint); for (auto *&q : t.ts) rel(q); t.pending = false; t.n = 0; }
    gg.tried = gg.ready = false; gg.used = gg.bg_done = gg.skip = false;
    gg.bg.clear(); gg.fl.clear();
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
    ID3DBlob *vs = glass_compile("vs_full", "vs_4_0"), *down = glass_compile("ps_down", "ps_4_0"),
        *up = glass_compile("ps_up", "ps_4_0"), *glass = glass_compile("ps_glass", "ps_4_0");
    bool ok = vs && down && up && glass
        && SUCCEEDED(g.device->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr, &gg.vs))
        && SUCCEEDED(g.device->CreatePixelShader(down->GetBufferPointer(), down->GetBufferSize(), nullptr, &gg.down))
        && SUCCEEDED(g.device->CreatePixelShader(up->GetBufferPointer(), up->GetBufferSize(), nullptr, &gg.up))
        && SUCCEEDED(g.device->CreatePixelShader(glass->GetBufferPointer(), glass->GetBufferSize(), nullptr, &gg.glass));
    for (ID3DBlob *b : {vs, down, up, glass}) if (b) b->Release();
    if (ok) {
        D3D11_BUFFER_DESC b = {};
        b.Usage = D3D11_USAGE_DYNAMIC; b.BindFlags = D3D11_BIND_CONSTANT_BUFFER; b.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        b.ByteWidth = 8 * 16;
        ok = SUCCEEDED(g.device->CreateBuffer(&b, nullptr, &gg.cb));
        b.ByteWidth = 2 * 16;
        ok = ok && SUCCEEDED(g.device->CreateBuffer(&b, nullptr, &gg.down_cb));
        D3D11_RASTERIZER_DESC r = {};
        r.FillMode = D3D11_FILL_SOLID; r.CullMode = D3D11_CULL_NONE; r.ScissorEnable = TRUE; r.DepthClipEnable = TRUE;
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
    const int shifts[5] = {0, 1, 2, 3, 2};
    for (int k = 0; k < 5; k++) {
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
/* `in` widened by the margin, clipped to the back buffer, merged where they meet. */
void glass_merge(const std::vector<GlassRect> &in, std::vector<GlassRect> &out) {
    out.clear();
    for (const GlassRect &r : in) {
        GlassRect m = {std::max(0, r.x0 - GLASS_MARGIN), std::max(0, r.y0 - GLASS_MARGIN),
                       std::min(gg.vw, r.x1 + GLASS_MARGIN), std::min(gg.vh, r.y1 + GLASS_MARGIN)};
        if (m.x1 <= m.x0 || m.y1 <= m.y0) continue;
        out.push_back(m);
    }
    for (bool merged = true; merged;) {
        merged = false;
        for (size_t i = 0; i < out.size() && !merged; i++)
            for (size_t j = i + 1; j < out.size() && !merged; j++) {
                GlassRect &a = out[i], &b = out[j];
                if (a.x0 <= b.x1 && b.x0 <= a.x1 && a.y0 <= b.y1 && b.y0 <= a.y1) {
                    a = {std::min(a.x0, b.x0), std::min(a.y0, b.y0), std::max(a.x1, b.x1), std::max(a.y1, b.y1)};
                    out.erase(out.begin() + (long)j); merged = true;
                }
            }
    }
}

/* One dual-Kawase pass of `src` into `dst` over region r (level-0 px). */
void glass_pass(ID3D11PixelShader *ps, const GlassLevel &src, const GlassLevel &dst, const GlassRect &r) {
    ID3D11DeviceContext *c = g.ctx;
    int sw = gg.tw >> src.shift, sh = gg.th >> src.shift;
    int sv = (1 << src.shift) - 1;
    D3D11_MAPPED_SUBRESOURCE m;
    if (SUCCEEDED(c->Map(gg.down_cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) {
        float v[8] = {1.0f / sw, 1.0f / sh, ((gg.vw + sv) >> src.shift) - 0.5f, ((gg.vh + sv) >> src.shift) - 0.5f,
                      (float)(1 << dst.shift) / (float)(1 << src.shift), 0, 0, 0};
        memcpy(m.pData, v, sizeof(v)); c->Unmap(gg.down_cb, 0);
    }
    D3D11_VIEWPORT vp = {0, 0, (float)(gg.tw >> dst.shift), (float)(gg.th >> dst.shift), 0, 1};
    c->RSSetViewports(1, &vp);
    D3D11_RECT sc = {(LONG)std::max(0, (r.x0 >> dst.shift) - 1), (LONG)std::max(0, (r.y0 >> dst.shift) - 1),
                     (LONG)((r.x1 >> dst.shift) + 1), (LONG)((r.y1 >> dst.shift) + 1)};
    c->RSSetScissorRects(1, &sc);
    c->PSSetShader(ps, nullptr, 0);
    c->OMSetRenderTargets(1, &dst.rtv, nullptr);
    c->PSSetShaderResources(0, 1, &src.srv);
    c->Draw(3, 0);
    ID3D11ShaderResourceView *none = nullptr;
    c->OMSetRenderTargets(0, nullptr, nullptr);
    c->PSSetShaderResources(0, 1, &none);
    gg.passes++;
}

/* Copy each region of `from` into level 0 and blur it down the chain (and one step up).
   Leaves no render target bound. */
void glass_copy(ID3D11Resource *from, const std::vector<GlassRect> &regions) {
    if (regions.empty()) return;
    ID3D11DeviceContext *c = g.ctx;
    glass_stamp(true);
    c->OMSetRenderTargets(0, nullptr, nullptr);
    ID3D11ShaderResourceView *none[4] = {};
    c->PSSetShaderResources(0, 4, none);
    for (const GlassRect &r : regions) {
        D3D11_BOX box = {(UINT)r.x0, (UINT)r.y0, 0, (UINT)r.x1, (UINT)r.y1, 1};
        c->CopySubresourceRegion(gg.lv[0].tex, 0, (UINT)r.x0, (UINT)r.y0, 0, from, 0, &box);
        gg.copies++;
    }
    c->IASetInputLayout(nullptr);
    c->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    c->VSSetShader(gg.vs, nullptr, 0);
    c->PSSetSamplers(1, 1, &gg.smp);
    c->PSSetConstantBuffers(0, 1, &gg.down_cb);
    c->GSSetShader(nullptr, nullptr, 0);
    c->OMSetBlendState(nullptr, nullptr, 0xffffffff);
    c->OMSetDepthStencilState(nullptr, 0);
    c->RSSetState(gg.rs);
    for (const GlassRect &r : regions) {
        glass_pass(gg.down, gg.lv[0], gg.lv[1], r);
        glass_pass(gg.down, gg.lv[1], gg.lv[2], r);
        glass_pass(gg.down, gg.lv[2], gg.lv[3], r);
        glass_pass(gg.up, gg.lv[3], gg.lv[4], r);
    }
    glass_stamp(false);
}

/* FNV-1a over 64-bit words */
inline uint64_t glass_mix(uint64_t h, const void *p, size_t n) {
    const unsigned char *b = (const unsigned char*)p;
    size_t i = 0;
    for (; i + 8 <= n; i += 8) { uint64_t w; memcpy(&w, b + i, 8); h = (h ^ w) * 0x100000001B3ull; }
    for (; i < n; i++) h = (h ^ b[i]) * 0x100000001B3ull;
    return h;
}

/* Before the main window renders: may the copies be skipped this frame? They may when
   the background layer's draw commands that reach the glass regions (their vertices,
   textures and clips), the regions themselves and the textures made are all as last frame,
   and no floating region overlaps a background one (whose copy it would overwrite). */
void glass_plan(ImDrawList *bg) {
    auto t0 = std::chrono::steady_clock::now();
    std::vector<GlassRect> &all = gg.merged;
    all.clear();
    for (const GlassRect &r : gg.bg) all.push_back(r);
    for (const GlassRect &r : gg.fl) all.push_back(r);
    uint64_t h = 1469598103934665603ull;
    h = glass_mix(h, all.data(), all.size() * sizeof(GlassRect));
    int counts[2] = {(int)gg.bg.size(), (int)gg.fl.size()};
    h = glass_mix(h, counts, sizeof(counts));
    h = glass_mix(h, &g.next_texture, sizeof(g.next_texture));
    int size[2] = {gg.vw, gg.vh}; h = glass_mix(h, size, sizeof(size));
    if (bg) {
        for (const ImDrawCmd &cmd : bg->CmdBuffer) {
            if (cmd.UserCallback || cmd.ElemCount == 0) continue;
            bool hit = false;
            for (const GlassRect &r : all)
                if (cmd.ClipRect.x < r.x1 + GLASS_MARGIN && cmd.ClipRect.z > r.x0 - GLASS_MARGIN &&
                    cmd.ClipRect.y < r.y1 + GLASS_MARGIN && cmd.ClipRect.w > r.y0 - GLASS_MARGIN) { hit = true; break; }
            if (!hit) continue;
            h = glass_mix(h, &cmd.ClipRect, sizeof(cmd.ClipRect));
            ImTextureID tid = cmd.GetTexID(); h = glass_mix(h, &tid, sizeof(tid));
            /* the vertices this command draws: ImGui appends them in order, so its index range
               spans its first to its largest index */
            const ImDrawIdx *idx = bg->IdxBuffer.Data + cmd.IdxOffset;
            unsigned lo = UINT_MAX, hi = 0;
            for (unsigned i = 0; i < cmd.ElemCount; i++) { lo = std::min(lo, (unsigned)idx[i]); hi = std::max(hi, (unsigned)idx[i]); }
            unsigned first = cmd.VtxOffset + lo, last = cmd.VtxOffset + hi;
            if (last < (unsigned)bg->VtxBuffer.Size)
                h = glass_mix(h, bg->VtxBuffer.Data + first, (size_t)(last - first + 1) * sizeof(ImDrawVert));
        }
    }
    bool overlap = false;
    for (const GlassRect &a : gg.bg) for (const GlassRect &b : gg.fl)
        if (a.x0 - GLASS_MARGIN < b.x1 + GLASS_MARGIN && b.x0 - GLASS_MARGIN < a.x1 + GLASS_MARGIN &&
            a.y0 - GLASS_MARGIN < b.y1 + GLASS_MARGIN && b.y0 - GLASS_MARGIN < a.y1 + GLASS_MARGIN) overlap = true;
    gg.skip = gg.valid && !overlap && h == gg.last_hash;
    gg.last_hash = h;
    if (gg.skip) gg.skips++;
    gg.hash_us_sum += std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count();
}

/* -- callbacks -------------------------------------------------------------------------- */
/* Before the first background-layer surface: snapshot all of their regions once, then put
   the target back (ImGui's state reset follows). Off the main window it does nothing. */
void glass_cb_snap(const ImDrawList *, const ImDrawCmd *) {
    if (!gg.main_target || !gg.lv[0].tex || gg.bg_done) return;
    gg.bg_done = true;
    if (gg.skip) return;
    ID3D11RenderTargetView *rtv = nullptr; ID3D11DepthStencilView *dsv = nullptr;
    g.ctx->OMGetRenderTargets(1, &rtv, &dsv);
    if (rtv) {
        ID3D11Resource *res = nullptr; rtv->GetResource(&res);
        if (res) {
            glass_merge(gg.bg, gg.merged);
            glass_copy(res, gg.merged);
            res->Release();
        }
        g.ctx->OMSetRenderTargets(1, &rtv, dsv);
        rtv->Release();
    }
    if (dsv) dsv->Release();
}

/* The glass shader and this surface's constants (the one state change a surface makes). */
void glass_cb_bind(const ImDrawList *, const ImDrawCmd *cmd) {
    const GlassCmd *d = (const GlassCmd*)cmd->UserCallbackData;
    if (!gg.ready || !gg.lv[0].srv) return;
    glass_stamp(true);
    float cb[32] = {
        d->rect[0], d->rect[1], d->rect[2], d->rect[3],
        gg.origin.x, gg.origin.y, 1.0f / gg.tw, 1.0f / gg.th,
        (float)gg.vw, (float)gg.vh, d->radius, d->band,
        d->thickness, d->blur_mix, d->lift, d->alpha,
        d->tint[0], d->tint[1], d->tint[2], d->tint[3],
        d->rim[0], d->rim[1], d->rim[2], d->rim[3],
        d->inner[0], d->inner[1], d->inner[2], d->inner[3],
        d->chroma, d->body, (d->snap && !gg.main_target) ? 1.0f : 0.0f, 0,
    };
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(g.ctx->Map(gg.cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) return;
    memcpy(m.pData, cb, sizeof(cb)); g.ctx->Unmap(gg.cb, 0);
    g.ctx->PSSetShader(gg.glass, nullptr, 0);
    g.ctx->PSSetConstantBuffers(0, 1, &gg.cb);
    /* the full-res copy (rim), the 1/4 down (light blur) and the 1/4 up (strong blur) */
    ID3D11ShaderResourceView *srv[3] = {gg.lv[0].srv, gg.lv[2].srv, gg.lv[4].srv};
    g.ctx->PSSetShaderResources(1, 3, srv);
    g.ctx->PSSetSamplers(1, 1, &gg.smp);
}

/* After the main window's background layer: the regions floating glass samples. */
void glass_floating_copy(ID3D11Resource *back) {
    if (!gg.ready || !gg.lv[0].tex || gg.fl.empty() || gg.skip) return;
    glass_merge(gg.fl, gg.merged);
    glass_copy(back, gg.merged);
}

void glass_unpack(uint32_t c, float out[4]) {
    out[0] = ((c >> IM_COL32_R_SHIFT) & 0xFF) / 255.0f; out[1] = ((c >> IM_COL32_G_SHIFT) & 0xFF) / 255.0f;
    out[2] = ((c >> IM_COL32_B_SHIFT) & 0xFF) / 255.0f; out[3] = ((c >> IM_COL32_A_SHIFT) & 0xFF) / 255.0f;
}

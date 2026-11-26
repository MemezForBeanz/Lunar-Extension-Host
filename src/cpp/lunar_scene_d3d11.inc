/* Reactive backgrounds (core.ui.Background) on Direct3D 11.
 *
 * Included by lunarimgui.cpp after lunar_glass_d3d11.inc, inside its namespace.
 *
 * A theme's background layers are drawn by Lua into a private ImDrawList (the scene list),
 * which is rendered into the scene target: one texture the size of the window (made at
 * the monitor's size rounded to 256 px, re-made only if the window outgrows it). On a
 * hardware device its strong blur is made next to it with the glass shaders (1/4, 1/8 and
 * back to 1/4, one draw each). The main window then draws the target as its floor, and
 * chrome glass samples the target and its blur as it sampled the baked backdrop, so the
 * glass refracts the live background with no copy of the frame.
 *
 * Cost model:
 *   - The target is re-rendered only in frames whose scene Lua re-emitted (a bound signal
 *     changed); other frames draw the texture they already have.
 *   - lunar_ui_scene_present: a frame whose only change is the scene (a twinkle tick, a
 *     parallax step) renders the scene list into the target and re-renders the main
 *     window's last draw data (valid until the next NewFrame) and presents, without a Lua
 *     frame of the UI. Refused (0) when that frame drew glass in a later list (floating
 *     glass), the frame copy, overlay or dialog windows, or a shot: those take a full
 *     frame. Glass inside the main list (the transport) is planned again and copies at
 *     its own callback, as in a full frame.
 *   - Nothing is uploaded: the sprites' textures are made once by Lua; the target and its
 *     levels once per size class.
 * Texture ids SCENE_SHARP and SCENE_BLUR (never real ids) name the target and its blur in
 * lunar_ui_image / lunar_ui_image_rounded_uv / lunar_ui_glass. Without the glass shaders
 * (WARP) SCENE_BLUR is the sharp target. */

const int SCENE_SHARP = -8, SCENE_BLUR = -9;

struct SceneGpu {
    GlassLevel lv[4];      /* 0: the target; 1: 1/4; 2: 1/8; 3: 1/4 up (the blur) */
    int tw = 0, th = 0;    /* level 0's size */
    int vw = 0, vh = 0;    /* the part this frame fills */
    ImDrawList *list = nullptr;
    bool open = false;     /* between scene_begin and scene_end */
    bool emitted = false;  /* the list holds a scene not yet rendered into the target */
    bool valid = false;    /* the target holds a finished scene */
    bool blurred = false;  /* its blur too */
    bool reusable = false; /* the last full frame may be presented again (see above) */
    size_t points = 0;     /* its in-window glass copy points (gg.pts keeps them) */
    long long renders = 0, presents = 0, refusals = 0, creations = 0, sprites = 0;
    double cpu_us_sum = 0;   /* render + present of scene-only frames, CPU side */
} sg;

void scene_release_levels() {
    for (GlassLevel &l : sg.lv) {
        if (l.rtv) { l.rtv->Release(); l.rtv = nullptr; }
        if (l.srv) { if (g.frame_open) g.retired_textures.push_back(l.srv); else l.srv->Release(); l.srv = nullptr; }
        if (l.tex) { l.tex->Release(); l.tex = nullptr; }
    }
    sg.tw = sg.th = 0; sg.valid = sg.blurred = false;
}

void scene_release() {
    scene_release_levels();
    if (sg.list) { IM_DELETE(sg.list); sg.list = nullptr; }
    sg.open = sg.emitted = sg.reusable = false;
}

ID3D11ShaderResourceView *scene_srv(int tex) {
    if (tex == SCENE_SHARP) return sg.valid ? sg.lv[0].srv : nullptr;
    if (tex == SCENE_BLUR) return !sg.valid ? nullptr : (sg.blurred ? sg.lv[3].srv : sg.lv[0].srv);
    return nullptr;
}

/* The target and its levels at least w x h. */
bool scene_levels(int w, int h) {
    if (!g.device || w <= 0 || h <= 0) return false;
    if (sg.lv[0].tex && w <= sg.tw && h <= sg.th) return true;
    RECT work, full; monitor_rects(work, full);
    int tw = std::max({sg.tw, (int)(full.right - full.left), w}), th = std::max({sg.th, (int)(full.bottom - full.top), h});
    tw = (tw + 255) & ~255; th = (th + 255) & ~255;
    scene_release_levels();
    const int shifts[4] = {0, 2, 3, 2};
    for (int k = 0; k < 4; k++) {
        D3D11_TEXTURE2D_DESC d = {};
        d.Width = (UINT)(tw >> shifts[k]); d.Height = (UINT)(th >> shifts[k]); d.MipLevels = 1; d.ArraySize = 1;
        d.Format = DXGI_FORMAT_R8G8B8A8_UNORM; d.SampleDesc.Count = 1; d.Usage = D3D11_USAGE_DEFAULT;
        d.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
        GlassLevel &l = sg.lv[k];
        l.shift = shifts[k];
        if (FAILED(g.device->CreateTexture2D(&d, nullptr, &l.tex)) || !l.tex
            || FAILED(g.device->CreateShaderResourceView(l.tex, nullptr, &l.srv))
            || FAILED(g.device->CreateRenderTargetView(l.tex, nullptr, &l.rtv))) {
            scene_release_levels(); return false;
        }
        if (!gg.ready) break;   /* WARP: the target alone */
    }
    sg.tw = tw; sg.th = th;
    sg.creations++;
    return true;
}

/* One blur pass over the whole valid area, the glass shaders' constant layout. */
bool scene_pass(ID3D11PixelShader *ps, const GlassLevel &src, const GlassLevel &dst) {
    ID3D11DeviceContext *c = g.ctx;
    int sw = sg.tw >> src.shift, sh = sg.th >> src.shift, sv = (1 << src.shift) - 1;
    int dw = sg.tw >> dst.shift, dh = sg.th >> dst.shift;
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(c->Map(gg.blur_cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) return false;
    float *v = (float*)m.pData;
    v[0] = 1.0f / sw; v[1] = 1.0f / sh;
    v[2] = ((sg.vw + sv) >> src.shift) - 0.5f; v[3] = ((sg.vh + sv) >> src.shift) - 0.5f;
    v[4] = (float)dw; v[5] = (float)dh; v[6] = 0; v[7] = (float)(1 << dst.shift);
    v[8] = 0; v[9] = 0; v[10] = (float)sg.vw; v[11] = (float)sg.vh;
    c->Unmap(gg.blur_cb, 0);
    D3D11_VIEWPORT vp = {0, 0, (float)dw, (float)dh, 0, 1};
    c->RSSetViewports(1, &vp);
    c->PSSetShader(ps, nullptr, 0);
    c->OMSetRenderTargets(1, &dst.rtv, nullptr);
    c->PSSetShaderResources(0, 1, &src.srv);
    c->Draw(6, 0);
    ID3D11ShaderResourceView *none = nullptr;
    c->PSSetShaderResources(0, 1, &none);
    return true;
}

/* The scene list into the target, then its blur. `textures`: ImGui's texture updates of
   this frame (the font atlas the list's fills use), done before the list draws. */
bool scene_render(ImVector<ImTextureData*> *textures) {
    if (!sg.emitted || !sg.list || !sg.lv[0].rtv) return false;
    sg.emitted = false;
    glass_stamp(5);
    ImDrawData dd;
    dd.Valid = true;
    sg.list->_PopUnusedDrawCmd();
    if (sg.list->CmdBuffer.Size > 0) {
        dd.CmdLists.push_back(sg.list);
        dd.TotalVtxCount = sg.list->VtxBuffer.Size; dd.TotalIdxCount = sg.list->IdxBuffer.Size;
    }
    dd.DisplayPos = ImVec2(0, 0);
    dd.DisplaySize = ImVec2((float)sg.vw, (float)sg.vh);
    dd.FramebufferScale = ImVec2(1, 1);
    dd.Textures = textures;
    const float clear[4] = {0, 0, 0, 1};
    g.ctx->OMSetRenderTargets(1, &sg.lv[0].rtv, nullptr);
    g.ctx->ClearRenderTargetView(sg.lv[0].rtv, clear);
    ImVec2 origin = gg.origin; gg.origin = ImVec2(0, 0);
    ImGui_ImplDX11_RenderDrawData(&dd);
    gg.origin = origin;
    sg.valid = true; sg.blurred = false;
    sg.renders++;
    if (gg.ready && sg.lv[3].rtv) {
        ID3D11DeviceContext *c = g.ctx;
        c->OMSetRenderTargets(0, nullptr, nullptr);
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
        sg.blurred = scene_pass(gg.down4, sg.lv[0], sg.lv[1]) && scene_pass(gg.down, sg.lv[1], sg.lv[2])
            && scene_pass(gg.up, sg.lv[2], sg.lv[3]);
        c->OMSetRenderTargets(0, nullptr, nullptr);
    }
    glass_stamp(0);
    g.texture_revision++;   /* what lies under every copy changed */
    return true;
}

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <string>
#include <unordered_map>
#include <vector>

#include "imgui.h"
#include "imgui_internal.h"
#include "lunarimgui_gdifont.h"

namespace {

struct FontSource {
    std::wstring family;
    WORD weight = FW_NORMAL;
    bool italic = false;
    float upm = 2048.0f;
    float hhea_span = 2048.0f;
};

struct FontDataRef { std::string path; };
std::unordered_map<void *, FontDataRef> g_data;
HDC g_dc = nullptr;

uint16_t be16(const unsigned char *p) { return (uint16_t)((p[0] << 8) | p[1]); }
int16_t be16s(const unsigned char *p) { return (int16_t)be16(p); }
uint32_t be32(const unsigned char *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

bool table(const unsigned char *data, size_t size, uint32_t wanted, const unsigned char **out, size_t *out_size) {
    if (size < 12) return false;
    size_t base = 0;
    if (be32(data) == 0x74746366) {
        if (size < 16) return false;
        base = be32(data + 12);
    }
    if (base + 12 > size) return false;
    uint16_t count = be16(data + base + 4);
    for (uint16_t i = 0; i < count; ++i) {
        size_t rec = base + 12 + (size_t)i * 16;
        if (rec + 16 > size) return false;
        if (be32(data + rec) != wanted) continue;
        size_t off = be32(data + rec + 8), len = be32(data + rec + 12);
        if (off + len > size) return false;
        *out = data + off; *out_size = len; return true;
    }
    return false;
}

std::wstring font_name(const unsigned char *data, size_t size) {
    const unsigned char *name = nullptr; size_t name_size = 0;
    if (!table(data, size, 0x6E616D65, &name, &name_size) || name_size < 6) return L"Segoe UI";
    uint16_t count = be16(name + 2), string_offset = be16(name + 4);
    std::wstring result;
    int best = -1;
    for (uint16_t i = 0; i < count; ++i) {
        size_t off = 6 + (size_t)i * 12;
        if (off + 12 > name_size) break;
        uint16_t platform = be16(name + off), encoding = be16(name + off + 2), lang = be16(name + off + 4);
        uint16_t id = be16(name + off + 6), len = be16(name + off + 8), str = be16(name + off + 10);
        if ((id != 16 && id != 1) || (platform != 3 && platform != 0) || string_offset + str + len > name_size) continue;
        std::wstring candidate;
        const unsigned char *p = name + string_offset + str;
        /* Windows (3) and Unicode (0) records are UTF-16BE */
        for (uint16_t j = 0; j + 1 < len; j += 2) candidate.push_back((wchar_t)((p[j] << 8) | p[j + 1]));
        (void)encoding;
        if (candidate.empty() || candidate[0] == 0) continue;
        /* CreateFont matches the legacy family (name 1) in US English first */
        int score = (id == 1 ? 4 : 0) + (platform == 3 ? 2 : 0) + (lang == 0x409 || platform == 0 ? 1 : 0);
        if (score > best) { best = score; result = candidate; }
    }
    return result.empty() ? L"Segoe UI" : result;
}

FontSource *source_from(ImFontConfig *src) {
    if (src->FontLoaderData) return (FontSource *)src->FontLoaderData;
    auto it = g_data.find(src->FontData);
    if (it == g_data.end()) return nullptr;
    // The host already keeps one immutable source per file for all merged
    // faces. Parse it directly instead of rereading/copying every fallback.
    const auto *bytes = static_cast<const unsigned char *>(src->FontData);
    const size_t size = (size_t)src->FontDataSize;
    FontSource *out = new FontSource;
    out->family = font_name(bytes, size);
    const unsigned char *head = nullptr, *hhea = nullptr, *os2 = nullptr; size_t hs = 0, hhs = 0, os = 0;
    if (table(bytes, size, 0x68656164, &head, &hs) && hs >= 20) out->upm = be16(head + 18);
    float asc = out->upm, desc = 0;
    if (table(bytes, size, 0x68686561, &hhea, &hhs) && hhs >= 8) { asc = be16s(hhea + 4); desc = be16s(hhea + 6); }
    out->hhea_span = asc - desc;
    if (table(bytes, size, 0x4F532F32, &os2, &os) && os >= 64) {
        uint16_t selection = be16(os2 + 62);
        out->weight = (selection & 32) ? FW_BOLD : FW_NORMAL;
        out->italic = (selection & 1) != 0;
    }
    src->FontLoaderData = out;
    return out;
}

HFONT make_font(const FontSource *src, float size) {
    int height = std::max(1, (int)std::lround(size * src->upm / std::max(1.0f, src->hhea_span)));
    if (!g_dc) g_dc = CreateCompatibleDC(nullptr);
    return CreateFontW(-height, 0, 0, 0, src->weight, src->italic, FALSE, FALSE, DEFAULT_CHARSET,
        OUT_TT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, FF_DONTCARE | DEFAULT_PITCH, src->family.c_str());
}

void debug_log(const char *what, const ImFontConfig *src, const FontSource *font) {
    static int on = -1;
    if (on < 0) { char v[4] = ""; on = GetEnvironmentVariableA("LUNAR_GLYPHS_DEBUG", v, sizeof v) > 0; }
    if (!on) return;
    char path[MAX_PATH]; GetTempPathA(MAX_PATH, path); strcat_s(path, "lunar_glyphs.log");
    FILE *f = nullptr; fopen_s(&f, path, "a");
    if (!f) return;
    auto it = g_data.find(src->FontData);
    fprintf(f, "%s data=%p known=%d path=%s family=%ls\n", what, src->FontData, it != g_data.end(),
        it != g_data.end() ? it->second.path.c_str() : "-", font ? font->family.c_str() : L"-");
    fclose(f);
}
bool loader_src_init(ImFontAtlas *, ImFontConfig *src) {
    FontSource *font = source_from(src);
    debug_log("src_init", src, font);
    return font != nullptr;
}
void loader_src_destroy(ImFontAtlas *, ImFontConfig *src) {
    delete (FontSource *)src->FontLoaderData;
    src->FontLoaderData = nullptr;
}

bool loader_contains(ImFontAtlas *, ImFontConfig *src, ImWchar codepoint) {
    FontSource *font = source_from(src); if (!font) return false;
    HFONT hf = make_font(font, src->SizePixels); if (!hf) return false;
    HGDIOBJ old = SelectObject(g_dc, hf); WCHAR c = (WCHAR)codepoint; WORD glyph = 0;
    DWORD n = GetGlyphIndicesW(g_dc, &c, 1, &glyph, GGI_MARK_NONEXISTING_GLYPHS);
    SelectObject(g_dc, old); DeleteObject(hf);
    return n == 1 && glyph != 0xFFFF;
}

bool loader_baked_init(ImFontAtlas *, ImFontConfig *src, ImFontBaked *baked, void *) {
    FontSource *font = source_from(src); if (!font) return false;
    HFONT hf = make_font(font, baked->Size); if (!hf) return false;
    HGDIOBJ old = SelectObject(g_dc, hf); TEXTMETRICW tm = {}; GetTextMetricsW(g_dc, &tm);
    baked->Ascent = (float)tm.tmAscent; baked->Descent = -(float)tm.tmDescent;
    SelectObject(g_dc, old); DeleteObject(hf); return true;
}

bool loader_glyph(ImFontAtlas *atlas, ImFontConfig *src, ImFontBaked *baked, void *, ImWchar codepoint,
                  ImFontGlyph *out, float *out_advance) {
    FontSource *font = source_from(src); if (!font) return false;
    HFONT hf = make_font(font, baked->Size); if (!hf) return false;
    HGDIOBJ old = SelectObject(g_dc, hf);
    WCHAR c = (WCHAR)codepoint; WORD glyph = 0;
    if (GetGlyphIndicesW(g_dc, &c, 1, &glyph, GGI_MARK_NONEXISTING_GLYPHS) != 1 || glyph == 0xFFFF) {
        SelectObject(g_dc, old); DeleteObject(hf); return false;
    }
    ABC abc = {}; if (!GetCharABCWidthsW(g_dc, c, c, &abc)) {
        SelectObject(g_dc, old); DeleteObject(hf); return false;
    }
    float advance = (float)(abc.abcA + abc.abcB + abc.abcC);
    if (out_advance) { *out_advance = advance; SelectObject(g_dc, old); DeleteObject(hf); return true; }
    /* IUP's Windows driver draws text with GDI's default quality, ClearType on a normal
     * desktop. Draw the glyph the same way, light on black in a DIB, and keep the mean of
     * its three subpixel coverages: the weight and hinting of IUP's text, as grayscale. */
    MAT2 mat = {}; mat.eM11.value = 1; mat.eM22.value = 1;
    GLYPHMETRICS gm = {};
    if (GetGlyphOutlineW(g_dc, c, GGO_METRICS, &gm, 0, nullptr, &mat) == GDI_ERROR || gm.gmBlackBoxX == 0 || gm.gmBlackBoxY == 0
        || c == L' ' || c == 0xA0) {
        out->Codepoint = codepoint; out->AdvanceX = advance; out->Visible = false;
        SelectObject(g_dc, old); DeleteObject(hf); return true;
    }
    const int pad = 2;
    int w = (int)gm.gmBlackBoxX + 2 * pad, h = (int)gm.gmBlackBoxY + 2 * pad;
    BITMAPINFO bi = {}; bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = w; bi.bmiHeader.biHeight = -h; bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32; bi.bmiHeader.biCompression = BI_RGB;
    void *bits = nullptr;
    HBITMAP dib = CreateDIBSection(g_dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!dib || !bits) { if (dib) DeleteObject(dib); SelectObject(g_dc, old); DeleteObject(hf); return false; }
    HGDIOBJ old_bmp = SelectObject(g_dc, dib);
    memset(bits, 0, (size_t)w * h * 4);
    SetBkMode(g_dc, TRANSPARENT); SetTextColor(g_dc, RGB(255, 255, 255));
    SetTextAlign(g_dc, TA_BASELINE | TA_LEFT);
    /* the pixel (pad, pad) is the top left of the glyph's black box */
    TextOutW(g_dc, pad - gm.gmptGlyphOrigin.x, pad + gm.gmptGlyphOrigin.y, &c, 1);
    GdiFlush();
    std::vector<unsigned char> pixels((size_t)w * h);
    const unsigned char *src_px = (const unsigned char *)bits;
    for (int i = 0; i < w * h; ++i)
        pixels[(size_t)i] = (unsigned char)((src_px[i * 4] + src_px[i * 4 + 1] + src_px[i * 4 + 2] + 1) / 3);
    SelectObject(g_dc, old_bmp); DeleteObject(dib);
    ImFontAtlasRectId id = ImFontAtlasPackAddRect(atlas, w, h);
    if (id == ImFontAtlasRectId_Invalid) { SelectObject(g_dc, old); DeleteObject(hf); return false; }
    ImTextureRect *rect = ImFontAtlasPackGetRect(atlas, id);
    out->Codepoint = codepoint; out->AdvanceX = advance;
    out->X0 = (float)(gm.gmptGlyphOrigin.x - pad); out->Y0 = baked->Ascent - (float)(gm.gmptGlyphOrigin.y + pad);
    out->X1 = out->X0 + w; out->Y1 = out->Y0 + h; out->Visible = true; out->PackId = id;
    ImFontAtlasBakedSetFontGlyphBitmap(atlas, baked, src, out, rect, pixels.data(), ImTextureFormat_Alpha8, w);
    SelectObject(g_dc, old); DeleteObject(hf); return true;
}

}

void lunarimgui_gdi_register_font_data(void *data, const char *path) {
    g_data[data] = {path ? path : ""};
}

const ImFontLoader *lunarimgui_gdi_font_loader() {
    static ImFontLoader loader;
    loader.Name = "gdi_gray8";
    loader.FontSrcInit = loader_src_init;
    loader.FontSrcDestroy = loader_src_destroy;
    loader.FontSrcContainsGlyph = loader_contains;
    loader.FontBakedInit = loader_baked_init;
    loader.FontBakedLoadGlyph = loader_glyph;
    return &loader;
}

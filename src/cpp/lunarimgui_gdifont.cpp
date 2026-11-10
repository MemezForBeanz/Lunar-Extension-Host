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
    for (uint16_t i = 0; i < count; ++i) {
        size_t off = 6 + (size_t)i * 12;
        if (off + 12 > name_size) break;
        uint16_t platform = be16(name + off), encoding = be16(name + off + 2);
        uint16_t id = be16(name + off + 6), len = be16(name + off + 8), str = be16(name + off + 10);
        if ((id != 16 && id != 1) || (platform != 3 && platform != 0) || string_offset + str + len > name_size) continue;
        std::wstring candidate;
        const unsigned char *p = name + string_offset + str;
        if (platform == 3 || encoding == 1) {
            for (uint16_t j = 0; j + 1 < len; j += 2) candidate.push_back((wchar_t)((p[j] << 8) | p[j + 1]));
        } else {
            for (uint16_t j = 0; j < len; ++j) candidate.push_back((wchar_t)p[j]);
        }
        if (!candidate.empty()) {
            if (id == 16) return candidate;
            if (result.empty()) result = candidate;
        }
    }
    return result.empty() ? L"Segoe UI" : result;
}

FontSource *source_from(ImFontConfig *src) {
    if (src->FontLoaderData) return (FontSource *)src->FontLoaderData;
    auto it = g_data.find(src->FontData);
    if (it == g_data.end()) return nullptr;
    HANDLE file = CreateFileA(it->second.path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (file == INVALID_HANDLE_VALUE) return nullptr;
    LARGE_INTEGER n = {}; GetFileSizeEx(file, &n);
    std::vector<unsigned char> bytes((size_t)n.QuadPart);
    DWORD got = 0; BOOL ok = ReadFile(file, bytes.data(), (DWORD)bytes.size(), &got, nullptr); CloseHandle(file);
    if (!ok || got != bytes.size()) return nullptr;
    FontSource *out = new FontSource;
    out->family = font_name(bytes.data(), bytes.size());
    const unsigned char *head = nullptr, *hhea = nullptr, *os2 = nullptr; size_t hs = 0, hhs = 0, os = 0;
    if (table(bytes.data(), bytes.size(), 0x68656164, &head, &hs) && hs >= 20) out->upm = be16(head + 18);
    float asc = out->upm, desc = 0;
    if (table(bytes.data(), bytes.size(), 0x68686561, &hhea, &hhs) && hhs >= 8) { asc = be16s(hhea + 4); desc = be16s(hhea + 6); }
    out->hhea_span = asc - desc;
    if (table(bytes.data(), bytes.size(), 0x4F532F32, &os2, &os) && os >= 64) {
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
        OUT_TT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, FF_DONTCARE | DEFAULT_PITCH, src->family.c_str());
}

bool loader_src_init(ImFontAtlas *, ImFontConfig *src) { return source_from(src) != nullptr; }
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
    /* GGO_GRAY8_BITMAP is hinted by the selected HFONT and matches IUP's
     * grayscale coverage more closely than stb's outline rasterizer. */
    MAT2 mat = {}; mat.eM11.value = 1; mat.eM22.value = 1;
    GLYPHMETRICS gm = {}; DWORD bytes = GetGlyphOutlineW(g_dc, c, GGO_GRAY8_BITMAP, &gm, 0, nullptr, &mat);
    if (bytes == GDI_ERROR) {
        out->Codepoint = codepoint; out->AdvanceX = advance; out->Visible = false;
        SelectObject(g_dc, old); DeleteObject(hf); return true;
    }
    int w = (int)gm.gmBlackBoxX, h = (int)gm.gmBlackBoxY;
    if (bytes == 0 || w <= 0 || h <= 0) {
        out->Codepoint = codepoint; out->AdvanceX = advance; out->Visible = false;
        SelectObject(g_dc, old); DeleteObject(hf); return true;
    }
    std::vector<unsigned char> raw(bytes);
    if (GetGlyphOutlineW(g_dc, c, GGO_GRAY8_BITMAP, &gm, bytes, raw.data(), &mat) == GDI_ERROR) {
        SelectObject(g_dc, old); DeleteObject(hf); return false;
    }
    ImFontAtlasRectId id = ImFontAtlasPackAddRect(atlas, w, h);
    if (id == ImFontAtlasRectId_Invalid) { SelectObject(g_dc, old); DeleteObject(hf); return false; }
    ImTextureRect *rect = ImFontAtlasPackGetRect(atlas, id);
    int pitch = (w + 3) & ~3;
    if ((size_t)pitch * h > raw.size()) {
        SelectObject(g_dc, old); DeleteObject(hf); return false;
    }
    std::vector<unsigned char> pixels((size_t)w * h);
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x)
        pixels[(size_t)y * w + x] = (unsigned char)std::min(255, raw[(size_t)y * pitch + x] * 4);
    out->Codepoint = codepoint; out->AdvanceX = advance;
    out->X0 = (float)gm.gmptGlyphOrigin.x; out->Y0 = baked->Ascent - (float)gm.gmptGlyphOrigin.y;
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

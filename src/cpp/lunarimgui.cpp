/*** The native backend of the ImGui host: one Win32 window, OpenGL 3, Dear ImGui's
 * draw lists, fonts and textures, exposed to Lua as `lunarimgui`.
 *
 * Lunar paints everything itself (core.imgui.Runtime walks the widget tree and calls
 * these primitives), so ImGui is used for what it is good at underneath: input
 * plumbing, a dynamic font atlas, texture upload and batched anti-aliased drawing.
 * No ImGui window or widget is ever created.
 *
 * Text is sized the way GDI sized it under IUP: Lua passes the em size in pixels
 * (pt * dpi / 72, what GDI's lfHeight = -px means), and this file converts that to
 * ImGui's size (which is ascender-descender height from `hhea`) per face, reports
 * tmAscent/tmDescent/tmHeight/tmAveCharWidth from the `OS/2` table, and moves the
 * baseline to where GDI puts it. That is what keeps every IUP SIZE unit, natural
 * size and text baseline where it was.
 *
 * The window frame: with `custom_frame` on, WM_NCCALCSIZE gives the caption to the
 * client area and keeps the side and bottom frames, so DWM keeps the shadow, rounded
 * corners and Snap; WM_NCHITTEST reports the bar as HTCAPTION and the three buttons
 * as HTMINBUTTON/HTMAXBUTTON/HTCLOSE (HTMAXBUTTON is what opens Snap Layouts). Mouse
 * input over the buttons arrives as non-client messages and is fed to Lua like
 * client input, so core.imgui.native.winframe draws and handles them.
 *
 * @module lunarimgui
 */
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <windowsx.h>
#include <commdlg.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <dwmapi.h>
#include <GL/gl.h>
#include <string>
#include <vector>
#include <unordered_map>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cfloat>
#include <cstdio>
#include <cstring>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}
#include "imgui.h"
#include "imgui_internal.h"
#include "backends/imgui_impl_win32.h"
#include "backends/imgui_impl_opengl3.h"
extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);

#ifndef WM_DPICHANGED
#define WM_DPICHANGED 0x02E0
#endif

namespace {

struct KeyEvent { int code; bool down, shift, ctrl, alt, sys; };

struct Face {
    ImFont *font = nullptr;
    float upm = 2048, hhea_asc = 0, hhea_desc = 0, win_asc = 0, win_desc = 0, avg = 0;
    bool metrics = false;
};

struct Rect { int x = 0, y = 0, w = 0, h = 0; bool contains(int px, int py) const { return w > 0 && px >= x && py >= y && px < x + w && py < y + h; } };

struct Shot { bool pending = false; std::string path; int x = 0, y = 0, w = 0, h = 0; bool ok = false; };

struct State {
    HWND hwnd = nullptr; HDC dc = nullptr; HGLRC gl = nullptr;
    bool alive = false, close = false, resized = false;
    bool custom_frame = false, fullscreen = false, tracking = false, nc_tracking = false;
    bool inside = false, in_sizemove = false, in_callback = false, frame_open = false, ready = false;
    WINDOWPLACEMENT saved_placement = { sizeof(WINDOWPLACEMENT) };
    LONG saved_style = 0;
    Rect caption, btn_min, btn_max, btn_close;
    std::vector<Rect> nodrag;
    std::vector<KeyEvent> keys; std::vector<std::string> chars; std::vector<std::string> files;
    int pressed[3] = {}, released[3] = {}, dbl[3] = {}; bool down[3] = {};
    float wheel_x = 0, wheel_y = 0; int mx = -1, my = -1;
    std::unordered_map<int, GLuint> textures; int next_texture = 1;
    std::vector<Face> faces;
    std::unordered_map<std::string, int> face_by_path;
    std::chrono::steady_clock::time_point started = std::chrono::steady_clock::now();
    HCURSOR cursor = nullptr;
    wchar_t high_surrogate = 0;
    lua_State *L = nullptr; int paint_ref = LUA_NOREF;
    int last_w = 0, last_h = 0;
    Shot shot;
    std::vector<ImDrawList*> lists; int layer = 0;
} g;

ImU32 color(lua_Number n) { return (ImU32)(unsigned long long)n; }
bool key_held(int vk) { return (GetKeyState(vk) & 0x8000) != 0; }

std::wstring wide(const char *s) {
    if (!s) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    std::wstring r(n ? n - 1 : 0, L'\0');
    if (n) MultiByteToWideChar(CP_UTF8, 0, s, -1, &r[0], n);
    return r;
}
std::string utf8(const wchar_t *s, int len = -1) {
    int n = WideCharToMultiByte(CP_UTF8, 0, s, len, nullptr, 0, nullptr, nullptr);
    std::string r(n > 0 ? n : 0, '\0');
    if (n > 0) WideCharToMultiByte(CP_UTF8, 0, s, len, &r[0], n, nullptr, nullptr);
    if (len < 0 && !r.empty() && r.back() == '\0') r.pop_back();
    return r;
}

UINT window_dpi(HWND hwnd) {
    typedef UINT (WINAPI *Fn)(HWND);
    static Fn fn = (Fn)(void*)GetProcAddress(GetModuleHandleA("user32.dll"), "GetDpiForWindow");
    if (fn && hwnd) return fn(hwnd);
    HDC dc = GetDC(nullptr); UINT d = (UINT)GetDeviceCaps(dc, LOGPIXELSX); ReleaseDC(nullptr, dc); return d ? d : 96;
}

void enable_dpi() {
    typedef BOOL (WINAPI *Fn)(DPI_AWARENESS_CONTEXT);
    static Fn fn = (Fn)(void*)GetProcAddress(GetModuleHandleA("user32.dll"), "SetProcessDpiAwarenessContext");
    if (fn) fn(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
}

int frame_thickness(HWND h) {
    UINT dpi = window_dpi(h);
    typedef int (WINAPI *Fn)(int, UINT);
    static Fn fn = (Fn)(void*)GetProcAddress(GetModuleHandleA("user32.dll"), "GetSystemMetricsForDpi");
    if (fn) return fn(SM_CXSIZEFRAME, dpi) + fn(SM_CXPADDEDBORDER, dpi);
    return GetSystemMetrics(SM_CXSIZEFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER);
}

/* IUP's key codes for a virtual key, before modifiers (core.imgui.Runtime adds them). */
int key_code(WPARAM vk) {
    if ((vk >= 'A' && vk <= 'Z') || (vk >= '0' && vk <= '9')) return (int)vk;
    if (vk >= VK_F1 && vk <= VK_F24) return 0xFFBE + (int)(vk - VK_F1);
    if (vk >= VK_NUMPAD0 && vk <= VK_NUMPAD9) return '0' + (int)(vk - VK_NUMPAD0);
    switch (vk) {
    case VK_ESCAPE: return 0xFF1B; case VK_LEFT: return 0xFF51; case VK_UP: return 0xFF52;
    case VK_RIGHT: return 0xFF53; case VK_DOWN: return 0xFF54; case VK_HOME: return 0xFF50;
    case VK_PRIOR: return 0xFF55; case VK_NEXT: return 0xFF56; case VK_END: return 0xFF57;
    case VK_INSERT: return 0xFF63; case VK_DELETE: return 0xFFFF; case VK_BACK: return 8;
    case VK_TAB: return 9; case VK_RETURN: return 13; case VK_SPACE: return 32;
    case VK_PAUSE: return 0xFF13; case VK_SNAPSHOT: return 0xFF61; case VK_APPS: return 0xFF67;
    case VK_CLEAR: return 0xFFD2; case VK_HELP: return 0xFFD3;
    case VK_OEM_COMMA: return ','; case VK_OEM_MINUS: return '-'; case VK_OEM_PERIOD: return '.';
    case VK_OEM_PLUS: return '='; case VK_OEM_1: return ';'; case VK_OEM_2: return '/';
    case VK_OEM_3: return '`'; case VK_OEM_4: return '['; case VK_OEM_5: return '\\';
    case VK_OEM_6: return ']'; case VK_OEM_7: return '\'';
    case VK_ADD: return '+'; case VK_SUBTRACT: return '-'; case VK_MULTIPLY: return '*';
    case VK_DIVIDE: return '/'; case VK_DECIMAL: return '.';
    default: return 0;
    }
}

bool is_modifier(WPARAM vk) {
    return vk == VK_SHIFT || vk == VK_CONTROL || vk == VK_MENU || vk == VK_LWIN || vk == VK_RWIN
        || vk == VK_LSHIFT || vk == VK_RSHIFT || vk == VK_LCONTROL || vk == VK_RCONTROL
        || vk == VK_LMENU || vk == VK_RMENU || vk == VK_CAPITAL || vk == VK_NUMLOCK || vk == VK_SCROLL;
}

void add_key(WPARAM vk, bool down) {
    if (is_modifier(vk)) return;
    int code = key_code(vk);
    if (!code) return;
    g.keys.push_back({code, down, key_held(VK_SHIFT), key_held(VK_CONTROL), key_held(VK_MENU),
        key_held(VK_LWIN) || key_held(VK_RWIN)});
}

void call_paint() {
    if (!g.ready || !g.L || g.paint_ref == LUA_NOREF || g.in_callback || g.frame_open) return;
    g.in_callback = true;
    lua_rawgeti(g.L, LUA_REGISTRYINDEX, g.paint_ref);
    if (lua_pcall(g.L, 0, 0, 0) != 0) lua_pop(g.L, 1);
    g.in_callback = false;
}

void mouse_to_client(HWND h, LPARAM l, bool screen) {
    POINT p = {GET_X_LPARAM(l), GET_Y_LPARAM(l)};
    if (screen) ScreenToClient(h, &p);
    g.mx = p.x; g.my = p.y; g.inside = true;
}

int button_index(UINT m) {
    switch (m) {
    case WM_LBUTTONDOWN: case WM_LBUTTONUP: case WM_LBUTTONDBLCLK: return 0;
    case WM_MBUTTONDOWN: case WM_MBUTTONUP: case WM_MBUTTONDBLCLK: return 1;   /* IUP button 2 */
    case WM_RBUTTONDOWN: case WM_RBUTTONUP: case WM_RBUTTONDBLCLK: return 2;   /* IUP button 3 */
    }
    return -1;
}

LRESULT hit_test(HWND h, LPARAM l) {
    POINT p = {GET_X_LPARAM(l), GET_Y_LPARAM(l)};
    ScreenToClient(h, &p);
    RECT r; GetClientRect(h, &r);
    if (!IsZoomed(h) && !g.fullscreen) {
        int e = MulDiv(5, (int)window_dpi(h), 96);
        if (p.y < e) {
            if (p.x < e * 2) return HTTOPLEFT;
            if (p.x >= r.right - e * 2) return HTTOPRIGHT;
            return HTTOP;
        }
    }
    if (g.btn_close.contains(p.x, p.y)) return HTCLOSE;
    if (g.btn_max.contains(p.x, p.y)) return HTMAXBUTTON;
    if (g.btn_min.contains(p.x, p.y)) return HTMINBUTTON;
    if (g.caption.contains(p.x, p.y)) {
        for (const Rect &n : g.nodrag) if (n.contains(p.x, p.y)) return HTCLIENT;
        return HTCAPTION;
    }
    return HTCLIENT;
}

bool is_button_hit(WPARAM ht) { return ht == HTCLOSE || ht == HTMAXBUTTON || ht == HTMINBUTTON; }

LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (g.gl && ImGui::GetCurrentContext() && ImGui::GetIO().BackendPlatformUserData) ImGui_ImplWin32_WndProcHandler(h, m, w, l);
    switch (m) {
    case WM_NCCALCSIZE:
        if (w && g.custom_frame && !g.fullscreen) {
            NCCALCSIZE_PARAMS *p = (NCCALCSIZE_PARAMS*)l;
            LONG top = p->rgrc[0].top;
            LRESULT r = DefWindowProcW(h, m, w, l);
            p->rgrc[0].top = top;                          /* the caption becomes client area */
            if (IsZoomed(h)) p->rgrc[0].top += frame_thickness(h);   /* keep it on screen */
            return r;
        }
        break;
    case WM_NCHITTEST:
        if (g.custom_frame && !g.fullscreen) {
            LRESULT r = DefWindowProcW(h, m, w, l);
            if (r != HTCLIENT) return r;
            return hit_test(h, l);
        }
        break;
    case WM_NCMOUSEMOVE:
        if (g.custom_frame && is_button_hit(w)) {
            mouse_to_client(h, l, true);
            if (!g.nc_tracking) {
                TRACKMOUSEEVENT t = {sizeof(t), TME_LEAVE | TME_NONCLIENT, h, 0};
                TrackMouseEvent(&t); g.nc_tracking = true;
            }
            return 0;
        }
        if (g.custom_frame && !g.tracking) { g.inside = false; g.mx = g.my = -1; }
        break;
    case WM_NCMOUSELEAVE:
        g.nc_tracking = false;
        if (!g.tracking) { g.inside = false; g.mx = g.my = -1; }
        break;
    case WM_NCLBUTTONDOWN: case WM_NCLBUTTONDBLCLK:
        if (g.custom_frame && is_button_hit(w)) {
            mouse_to_client(h, l, true); g.pressed[0]++; g.down[0] = true; return 0;
        }
        break;
    case WM_NCLBUTTONUP:
        if (g.custom_frame && is_button_hit(w)) {
            mouse_to_client(h, l, true); g.released[0]++; g.down[0] = false; return 0;
        }
        break;
    case WM_ERASEBKGND: return 1;
    case WM_CLOSE: g.close = true; return 0;
    case WM_DESTROY: g.alive = false; return 0;
    case WM_ENTERSIZEMOVE: g.in_sizemove = true; SetTimer(h, 1, 16, nullptr); return 0;
    case WM_EXITSIZEMOVE: g.in_sizemove = false; KillTimer(h, 1); return 0;
    case WM_TIMER: if (w == 1) { call_paint(); return 0; } break;
    case WM_SIZE:
        g.resized = true;
        if (w != SIZE_MINIMIZED) call_paint();
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps; BeginPaint(h, &ps); EndPaint(h, &ps);
        if (g.in_sizemove) call_paint();
        return 0;
    }
    case WM_DPICHANGED: {
        RECT *r = (RECT*)l;
        SetWindowPos(h, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        g.resized = true;
        return 0;
    }
    case WM_SETCURSOR:
        if (LOWORD(l) == HTCLIENT && g.cursor) { SetCursor(g.cursor); return TRUE; }
        break;
    case WM_KEYDOWN: case WM_SYSKEYDOWN:
        add_key(w, true);
        if (m == WM_SYSKEYDOWN && w == VK_F4) break;   /* Alt+F4 still closes */
        return 0;
    case WM_KEYUP: case WM_SYSKEYUP: add_key(w, false); return 0;
    case WM_SYSCHAR: return 0;                       /* no menu-bar beep on Alt+letter */
    case WM_CHAR: {
        wchar_t c = (wchar_t)w;
        if (c >= 0xD800 && c <= 0xDBFF) { g.high_surrogate = c; return 0; }
        if (c < 32 || c == 127) return 0;
        if (c >= 0xDC00 && c <= 0xDFFF && g.high_surrogate) {
            wchar_t pair[2] = {g.high_surrogate, c}; g.chars.push_back(utf8(pair, 2)); g.high_surrogate = 0;
        } else {
            wchar_t one[1] = {c}; g.chars.push_back(utf8(one, 1));
        }
        return 0;
    }
    case WM_LBUTTONDOWN: case WM_MBUTTONDOWN: case WM_RBUTTONDOWN:
    case WM_LBUTTONDBLCLK: case WM_MBUTTONDBLCLK: case WM_RBUTTONDBLCLK: {
        int b = button_index(m);
        mouse_to_client(h, l, false);
        g.pressed[b]++; g.down[b] = true;
        if (m == WM_LBUTTONDBLCLK || m == WM_MBUTTONDBLCLK || m == WM_RBUTTONDBLCLK) g.dbl[b]++;
        SetCapture(h);
        return 0;
    }
    case WM_LBUTTONUP: case WM_MBUTTONUP: case WM_RBUTTONUP: {
        int b = button_index(m);
        mouse_to_client(h, l, false);
        g.released[b]++; g.down[b] = false;
        if (!g.down[0] && !g.down[1] && !g.down[2]) ReleaseCapture();
        return 0;
    }
    case WM_CAPTURECHANGED:
        for (int i = 0; i < 3; i++) if (g.down[i]) { g.down[i] = false; g.released[i]++; }
        break;
    case WM_MOUSEWHEEL: g.wheel_y += (float)GET_WHEEL_DELTA_WPARAM(w) / WHEEL_DELTA; return 0;
    case WM_MOUSEHWHEEL: g.wheel_x += (float)GET_WHEEL_DELTA_WPARAM(w) / WHEEL_DELTA; return 0;
    case WM_MOUSEMOVE:
        mouse_to_client(h, l, false);
        if (!g.tracking) { TRACKMOUSEEVENT t = {sizeof(t), TME_LEAVE, h, 0}; TrackMouseEvent(&t); g.tracking = true; }
        return 0;
    case WM_MOUSELEAVE:
        g.tracking = false;
        if (!g.down[0] && !g.down[1] && !g.down[2]) { g.inside = false; g.mx = g.my = -1; }
        return 0;
    case WM_DROPFILES: {
        HDROP drop = (HDROP)w;
        UINT n = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
        for (UINT i = 0; i < n; i++) {
            wchar_t path[MAX_PATH * 4]; DragQueryFileW(drop, i, path, MAX_PATH * 4);
            g.files.push_back(utf8(path));
        }
        DragFinish(drop);
        return 0;
    }
    }
    return DefWindowProcW(h, m, w, l);
}

/* -- Fonts ------------------------------------------------------------------- */

uint16_t be16(const unsigned char *p) { return (uint16_t)((p[0] << 8) | p[1]); }
uint32_t be32(const unsigned char *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

bool read_file(const std::wstring &path, std::vector<unsigned char> &out) {
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size; GetFileSizeEx(f, &size);
    out.resize((size_t)size.QuadPart);
    DWORD got = 0; BOOL ok = ReadFile(f, out.data(), (DWORD)out.size(), &got, nullptr);
    CloseHandle(f);
    return ok && got == out.size();
}

/* The metrics GDI would report, from the face's own tables. */
void read_metrics(const std::vector<unsigned char> &d, Face &face) {
    if (d.size() < 12) return;
    size_t base = 0;
    if (be32(&d[0]) == 0x74746366 /* ttcf */ && d.size() >= 16) base = be32(&d[12]);
    if (base + 12 > d.size()) return;
    uint16_t n = be16(&d[base + 4]);
    const unsigned char *head = nullptr, *hhea = nullptr, *os2 = nullptr;
    for (uint16_t i = 0; i < n; i++) {
        size_t rec = base + 12 + (size_t)i * 16;
        if (rec + 16 > d.size()) return;
        uint32_t tag = be32(&d[rec]), off = be32(&d[rec + 8]), len = be32(&d[rec + 12]);
        if ((size_t)off + len > d.size()) continue;
        if (tag == 0x68656164) head = &d[off];
        else if (tag == 0x68686561) hhea = &d[off];
        else if (tag == 0x4F532F32 && len >= 78) os2 = &d[off];
    }
    if (!head || !hhea) return;
    face.upm = (float)be16(head + 18);
    face.hhea_asc = (float)(int16_t)be16(hhea + 4);
    face.hhea_desc = (float)(int16_t)be16(hhea + 6);
    if (os2) {
        face.avg = (float)(int16_t)be16(os2 + 2);
        face.win_asc = (float)be16(os2 + 74);
        face.win_desc = (float)be16(os2 + 76);
    } else {
        face.win_asc = face.hhea_asc; face.win_desc = -face.hhea_desc; face.avg = face.upm / 2;
    }
    face.metrics = face.upm > 0 && face.hhea_asc - face.hhea_desc > 0;
}

Face &face_of(int id) {
    if (id < 0 || id >= (int)g.faces.size()) id = 0;
    return g.faces[(size_t)id];
}

/* ImGui's size for an em size in pixels. */
float imgui_size(const Face &f, float px) {
    if (!f.metrics) return px * 1.33f;
    return px * (f.hhea_asc - f.hhea_desc) / f.upm;
}

/* GDI places the baseline at tmAscent (usWinAscent); ImGui at the hhea ascender. */
float baseline_shift(const Face &f, float px) {
    if (!f.metrics) return 0;
    return std::round(px * f.win_asc / f.upm) - px * f.hhea_asc / f.upm;
}

void merge_fallbacks(float size) {
    wchar_t windir[MAX_PATH]; GetWindowsDirectoryW(windir, MAX_PATH);
    const wchar_t *names[] = {L"\\Fonts\\seguisym.ttf", L"\\Fonts\\segoeui.ttf"};
    for (const wchar_t *name : names) {
        std::wstring p = std::wstring(windir) + name;
        if (GetFileAttributesW(p.c_str()) == INVALID_FILE_ATTRIBUTES) continue;
        ImFontConfig cfg; cfg.MergeMode = true; cfg.PixelSnapH = true;
        ImGui::GetIO().Fonts->AddFontFromFileTTF(utf8(p.c_str()).c_str(), size, &cfg);
    }
}

int load_face(const std::string &path) {
    auto hit = g.face_by_path.find(path);
    if (hit != g.face_by_path.end()) return hit->second;
    std::vector<unsigned char> bytes;
    if (!read_file(wide(path.c_str()), bytes)) return -1;
    Face face;
    read_metrics(bytes, face);
    ImFontConfig cfg; cfg.PixelSnapH = true; cfg.OversampleH = 1; cfg.OversampleV = 1;
    ImFont *font = ImGui::GetIO().Fonts->AddFontFromFileTTF(path.c_str(), 16.0f, &cfg);
    if (!font) return -1;
    merge_fallbacks(16.0f);
    face.font = font;
    g.faces.push_back(face);
    int id = (int)g.faces.size() - 1;
    g.face_by_path[path] = id;
    return id;
}

std::string lower(std::string s) { for (char &c : s) c = (char)tolower((unsigned char)c); return s; }
std::string squash(const std::string &s) {
    std::string r; for (char c : s) if (c != ' ' && c != '-' && c != '_') r += (char)tolower((unsigned char)c); return r;
}

std::string exe_dir() {
    wchar_t path[MAX_PATH * 4]; DWORD n = GetModuleFileNameW(nullptr, path, MAX_PATH * 4);
    std::wstring p(path, n); size_t cut = p.find_last_of(L"\\/");
    return utf8(p.substr(0, cut).c_str());
}

void find_bundled(const std::wstring &dir, const std::string &want, std::string &found) {
    WIN32_FIND_DATAW fd; HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        std::wstring name = fd.cFileName;
        if (name == L"." || name == L"..") continue;
        std::wstring full = dir + L"\\" + name;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) { find_bundled(full, want, found); }
        else {
            std::string n = utf8(name.c_str());
            size_t dot = n.find_last_of('.');
            std::string ext = dot == std::string::npos ? "" : lower(n.substr(dot));
            if ((ext == ".ttf" || ext == ".otf") && squash(n.substr(0, dot)) == want) found = utf8(full.c_str());
        }
    } while (found.empty() && FindNextFileW(h, &fd));
    FindClose(h);
}

std::string find_font(const std::string &face, bool bold, bool italic) {
    std::string style = bold && italic ? " bold italic" : bold ? " bold" : italic ? " italic" : "";
    std::string want = lower(face) + style;
    /* fonts the themes bundle, e.g. assets/Themes/Carbon/IBMPlexSans-Bold.otf */
    std::string bundled;
    std::string key = squash(face) + squash(style.empty() ? "regular" : style);
    find_bundled(wide((exe_dir() + "\\assets\\Themes").c_str()), key, bundled);
    if (bundled.empty() && style.empty()) find_bundled(wide((exe_dir() + "\\assets\\Themes").c_str()), squash(face), bundled);
    if (!bundled.empty()) return bundled;
    wchar_t windir[MAX_PATH]; GetWindowsDirectoryW(windir, MAX_PATH);
    HKEY roots[2] = {HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE};
    const wchar_t *sub = L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts";
    for (HKEY root : roots) {
        HKEY h;
        if (RegOpenKeyExW(root, sub, 0, KEY_READ, &h) != ERROR_SUCCESS) continue;
        for (DWORD i = 0;; i++) {
            wchar_t name[512], val[1024]; DWORD ns = 512, vs = sizeof(val), type;
            if (RegEnumValueW(h, i, name, &ns, nullptr, &type, (LPBYTE)val, &vs) != ERROR_SUCCESS) break;
            std::string n = lower(utf8(name));
            size_t paren = n.find(" (");
            if (paren != std::string::npos) n = n.substr(0, paren);
            /* "Cambria & Cambria Math": any member of a collection name */
            bool match = false;
            size_t start = 0;
            while (start <= n.size()) {
                size_t amp = n.find(" & ", start);
                std::string part = n.substr(start, amp == std::string::npos ? std::string::npos : amp - start);
                if (part == want || (style.empty() && part == want + " regular")) match = true;
                if (amp == std::string::npos) break;
                start = amp + 3;
            }
            if (match) {
                RegCloseKey(h);
                std::wstring v = val;
                if (v.find(L'\\') == std::wstring::npos) v = std::wstring(windir) + L"\\Fonts\\" + v;
                return utf8(v.c_str());
            }
        }
        RegCloseKey(h);
    }
    return "";
}

/* -- Window ------------------------------------------------------------------ */

/* The ImGui context and fonts exist from the moment the module loads: the host measures
 * text (natural sizes, theme probes) long before the first window opens. */
void ensure_imgui() {
    if (ImGui::GetCurrentContext()) return;
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr; io.LogFilename = nullptr;
    io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;
    io.DisplaySize = ImVec2(1280, 800);
    /* font 0: Segoe UI when present, else ImGui's own */
    wchar_t windir[MAX_PATH]; GetWindowsDirectoryW(windir, MAX_PATH);
    std::string segoe = utf8((std::wstring(windir) + L"\\Fonts\\segoeui.ttf").c_str());
    if (load_face(segoe) != 0) {
        Face f; f.font = io.Fonts->AddFontDefault(); f.metrics = false;
        g.faces.insert(g.faces.begin(), f);
    }
}

void ensure_context() {
    if (g.gl) return;
    PIXELFORMATDESCRIPTOR pfd = {};
    pfd.nSize = sizeof(pfd); pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA; pfd.cColorBits = 32; pfd.cAlphaBits = 8; pfd.iLayerType = PFD_MAIN_PLANE;
    int pf = ChoosePixelFormat(g.dc, &pfd); SetPixelFormat(g.dc, pf, &pfd);
    g.gl = wglCreateContext(g.dc); wglMakeCurrent(g.dc, g.gl);
    typedef BOOL (WINAPI *SwapFn)(int);
    SwapFn swap = (SwapFn)(void*)wglGetProcAddress("wglSwapIntervalEXT");
    if (swap) swap(1);
    ensure_imgui();
    ImGui_ImplWin32_Init(g.hwnd);
    ImGui_ImplOpenGL3_Init("#version 130");
}

void client_to_window(int &w, int &h, DWORD style, DWORD ex) {
    if (g.custom_frame) return;   /* the client is the whole window but the side frames */
    RECT r = {0, 0, w, h};
    typedef BOOL (WINAPI *Fn)(LPRECT, DWORD, BOOL, DWORD, UINT);
    static Fn fn = (Fn)(void*)GetProcAddress(GetModuleHandleA("user32.dll"), "AdjustWindowRectExForDpi");
    if (fn) fn(&r, style, FALSE, ex, window_dpi(g.hwnd)); else AdjustWindowRectEx(&r, style, FALSE, ex);
    w = r.right - r.left; h = r.bottom - r.top;
}

void monitor_rects(RECT &work, RECT &full) {
    HMONITOR mon = g.hwnd ? MonitorFromWindow(g.hwnd, MONITOR_DEFAULTTONEAREST)
                          : MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO mi = {sizeof(mi)}; GetMonitorInfoW(mon, &mi);
    work = mi.rcWork; full = mi.rcMonitor;
}

void set_fullscreen(bool on) {
    if (on == g.fullscreen) return;
    if (on) {
        GetWindowPlacement(g.hwnd, &g.saved_placement);
        g.saved_style = GetWindowLongW(g.hwnd, GWL_STYLE);
        RECT work, full; monitor_rects(work, full);
        g.fullscreen = true;
        SetWindowLongW(g.hwnd, GWL_STYLE, (g.saved_style & ~WS_OVERLAPPEDWINDOW) | WS_POPUP);
        SetWindowPos(g.hwnd, HWND_TOP, full.left, full.top, full.right - full.left, full.bottom - full.top,
            SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
    } else {
        g.fullscreen = false;
        SetWindowLongW(g.hwnd, GWL_STYLE, g.saved_style);
        SetWindowPlacement(g.hwnd, &g.saved_placement);
        SetWindowPos(g.hwnd, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    }
    g.resized = true;
}

Rect rect_field(lua_State *L, int idx, const char *name) {
    Rect r;
    if (name) { lua_getfield(L, idx, name); idx = lua_gettop(L); }
    if (lua_istable(L, idx)) {
        lua_getfield(L, idx, "x"); r.x = (int)lua_tonumber(L, -1); lua_pop(L, 1);
        lua_getfield(L, idx, "y"); r.y = (int)lua_tonumber(L, -1); lua_pop(L, 1);
        lua_getfield(L, idx, "w"); r.w = (int)lua_tonumber(L, -1); lua_pop(L, 1);
        lua_getfield(L, idx, "h"); r.h = (int)lua_tonumber(L, -1); lua_pop(L, 1);
    }
    if (name) lua_pop(L, 1);
    return r;
}

void write_shot() {
    Shot &s = g.shot;
    s.pending = false; s.ok = false;
    RECT rc; GetClientRect(g.hwnd, &rc);
    int W = rc.right, H = rc.bottom;
    int x = s.w > 0 ? std::max(0, s.x) : 0, y = s.w > 0 ? std::max(0, s.y) : 0;
    int w = s.w > 0 ? std::min(s.w, W - x) : W, h = s.h > 0 ? std::min(s.h, H - y) : H;
    if (w <= 0 || h <= 0) return;
    std::vector<unsigned char> px((size_t)w * h * 4);
    glReadBuffer(GL_BACK);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(x, H - y - h, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px.data());
    FILE *f = _wfopen(wide(s.path.c_str()).c_str(), L"wb");
    if (!f) return;
    uint32_t data = (uint32_t)px.size(), file = 54 + data;
    unsigned char hdr[54] = {'B', 'M'};
    memcpy(hdr + 2, &file, 4); uint32_t off = 54; memcpy(hdr + 10, &off, 4);
    uint32_t bih = 40; memcpy(hdr + 14, &bih, 4);
    int32_t bw = w, bh = h; memcpy(hdr + 18, &bw, 4); memcpy(hdr + 22, &bh, 4); /* bottom-up, like GL */
    uint16_t planes = 1, bpp = 32; memcpy(hdr + 26, &planes, 2); memcpy(hdr + 28, &bpp, 2);
    memcpy(hdr + 34, &data, 4);
    fwrite(hdr, 1, 54, f);
    for (size_t i = 0; i < px.size(); i += 4) { std::swap(px[i], px[i + 2]); }
    fwrite(px.data(), 1, px.size(), f);
    fclose(f);
    s.ok = true;
}

ImDrawList *scratch_list() {
    static ImDrawList *list = nullptr;
    if (!list) list = IM_NEW(ImDrawList)(ImGui::GetDrawListSharedData());
    list->_ResetForNewFrame();
    list->PushClipRectFullScreen();
    return list;
}
/* Calls between frames land on a scratch list that is never rendered. */
ImDrawList *draw() { return g.frame_open && !g.lists.empty() ? g.lists[(size_t)g.layer] : scratch_list(); }

/* -- Lua --------------------------------------------------------------------- */

int l_open(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    std::string title;
    lua_getfield(L, 1, "title"); if (lua_isstring(L, -1)) title = lua_tostring(L, -1); lua_pop(L, 1);
    int w = 1280, h = 800, x = CW_USEDEFAULT, y = CW_USEDEFAULT;
    lua_getfield(L, 1, "w"); if (lua_isnumber(L, -1)) w = (int)lua_tointeger(L, -1); lua_pop(L, 1);
    lua_getfield(L, 1, "h"); if (lua_isnumber(L, -1)) h = (int)lua_tointeger(L, -1); lua_pop(L, 1);
    bool has_x = false, has_y = false;
    lua_getfield(L, 1, "x"); if (lua_isnumber(L, -1)) { x = (int)lua_tointeger(L, -1); has_x = true; } lua_pop(L, 1);
    lua_getfield(L, 1, "y"); if (lua_isnumber(L, -1)) { y = (int)lua_tointeger(L, -1); has_y = true; } lua_pop(L, 1);
    lua_getfield(L, 1, "maximized"); bool maximized = lua_toboolean(L, -1) != 0; lua_pop(L, 1);
    lua_getfield(L, 1, "borderless"); g.custom_frame = lua_toboolean(L, -1) != 0; lua_pop(L, 1);
    lua_getfield(L, 1, "hidden"); bool hidden = lua_toboolean(L, -1) != 0; lua_pop(L, 1);
    enable_dpi();
    WNDCLASSEXW wc = {sizeof(wc)};
    wc.style = CS_DBLCLKS | CS_OWNDC;
    wc.hInstance = GetModuleHandleW(nullptr); wc.lpfnWndProc = wndproc; wc.lpszClassName = L"LunarImGuiHost";
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hIcon = LoadIconW(wc.hInstance, MAKEINTRESOURCEW(1));
    RegisterClassExW(&wc);
    DWORD style = WS_OVERLAPPEDWINDOW, ex = WS_EX_APPWINDOW;
    int ww = w, wh = h;
    client_to_window(ww, wh, style, ex);
    RECT work, full; monitor_rects(work, full);
    if (!has_x) x = work.left + std::max(0, (int)(work.right - work.left - ww) / 2);
    if (!has_y) y = work.top + std::max(0, (int)(work.bottom - work.top - wh) / 2);
    g.hwnd = CreateWindowExW(ex, wc.lpszClassName, wide(title.c_str()).c_str(), style, x, y, ww, wh,
        nullptr, nullptr, wc.hInstance, nullptr);
    if (!g.hwnd) { lua_pushboolean(L, 0); lua_pushstring(L, "CreateWindowExW failed"); return 2; }
    DragAcceptFiles(g.hwnd, TRUE);
    BOOL dark = TRUE; DwmSetWindowAttribute(g.hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof(dark));
    if (g.custom_frame) SetWindowPos(g.hwnd, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    g.dc = GetDC(g.hwnd);
    g.alive = true;
    ensure_context();
    if (!hidden) ShowWindow(g.hwnd, maximized ? SW_SHOWMAXIMIZED : SW_SHOW);
    g.ready = true;
    lua_pushboolean(L, 1);
    return 1;
}

int l_close(lua_State *L) {
    if (g.paint_ref != LUA_NOREF) { luaL_unref(L, LUA_REGISTRYINDEX, g.paint_ref); g.paint_ref = LUA_NOREF; }
    for (auto &t : g.textures) glDeleteTextures(1, &t.second);
    g.textures.clear();
    if (g.gl && ImGui::GetCurrentContext()) { ImGui_ImplOpenGL3_Shutdown(); ImGui_ImplWin32_Shutdown(); }
    if (g.gl) { wglMakeCurrent(nullptr, nullptr); wglDeleteContext(g.gl); g.gl = nullptr; }
    if (g.hwnd) { ReleaseDC(g.hwnd, g.dc); DestroyWindow(g.hwnd); g.hwnd = nullptr; }
    g.alive = false; g.ready = false;
    return 0;
}

int l_alive(lua_State *L) { lua_pushboolean(L, g.alive); return 1; }

int l_now(lua_State *L) {
    lua_pushnumber(L, std::chrono::duration<double>(std::chrono::steady_clock::now() - g.started).count());
    return 1;
}

int l_wait(lua_State *L) {
    double t = luaL_optnumber(L, 1, 0.016);
    DWORD ms = t < 0 ? INFINITE : (DWORD)std::max(0.0, t * 1000.0);
    MsgWaitForMultipleObjectsEx(0, nullptr, ms, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    return 0;
}

int l_set_paint_callback(lua_State *L) {
    if (g.paint_ref != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, g.paint_ref);
    g.paint_ref = LUA_NOREF;
    if (lua_isfunction(L, 1)) { lua_pushvalue(L, 1); g.paint_ref = luaL_ref(L, LUA_REGISTRYINDEX); }
    g.L = L;
    return 0;
}

void set_bool(lua_State *L, int t, const char *k, bool v) { lua_pushboolean(L, v); lua_setfield(L, t, k); }
void set_num(lua_State *L, int t, const char *k, double v) { lua_pushnumber(L, v); lua_setfield(L, t, k); }

void push_counts(lua_State *L, int t, const char *k, const int *v) {
    lua_createtable(L, 3, 0);
    for (int i = 0; i < 3; i++) { lua_pushinteger(L, v[i]); lua_rawseti(L, -2, i + 1); }
    lua_setfield(L, t, k);
}

int l_frame_begin(lua_State *L) {
    if (!g.hwnd || !g.gl) return luaL_error(L, "frame_begin before open");
    if (!g.in_callback) {
        MSG m;
        while (PeekMessageW(&m, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&m); DispatchMessageW(&m); }
    }
    RECT r; GetClientRect(g.hwnd, &r);
    int w = r.right, h = r.bottom;
    bool minimized = IsIconic(g.hwnd) || w <= 0 || h <= 0;
    if (minimized) { w = g.last_w; h = g.last_h; } else { g.last_w = w; g.last_h = h; }
    ImGuiIO &io = ImGui::GetIO();
    ImGui_ImplOpenGL3_NewFrame(); ImGui_ImplWin32_NewFrame();
    io.DisplaySize = ImVec2((float)std::max(w, 1), (float)std::max(h, 1));
    ImGui::NewFrame();
    g.lists.clear();
    g.lists.push_back(ImGui::GetBackgroundDrawList());
    g.lists.push_back(ImGui::GetForegroundDrawList());
    g.layer = 0;
    g.frame_open = true;

    lua_createtable(L, 0, 24);
    int t = lua_gettop(L);
    set_num(L, t, "w", w); set_num(L, t, "h", h);
    set_num(L, t, "scale", (double)window_dpi(g.hwnd) / 96.0);
    set_num(L, t, "mx", g.mx); set_num(L, t, "my", g.my);
    set_bool(L, t, "inside", g.inside && g.mx >= 0);
    lua_createtable(L, 3, 0);
    for (int i = 0; i < 3; i++) { lua_pushboolean(L, g.down[i]); lua_rawseti(L, -2, i + 1); }
    lua_setfield(L, t, "down");
    push_counts(L, t, "pressed", g.pressed);
    push_counts(L, t, "released", g.released);
    push_counts(L, t, "double", g.dbl);
    set_num(L, t, "wheel_x", g.wheel_x); set_num(L, t, "wheel_y", g.wheel_y);
    lua_createtable(L, (int)g.keys.size(), 0);
    for (size_t i = 0; i < g.keys.size(); i++) {
        const KeyEvent &k = g.keys[i];
        lua_createtable(L, 0, 6); int kt = lua_gettop(L);
        lua_pushinteger(L, k.code); lua_setfield(L, kt, "code");
        set_bool(L, kt, "down", k.down); set_bool(L, kt, "shift", k.shift); set_bool(L, kt, "ctrl", k.ctrl);
        set_bool(L, kt, "alt", k.alt); set_bool(L, kt, "sys", k.sys);
        lua_rawseti(L, -2, (int)i + 1);
    }
    lua_setfield(L, t, "keys");
    lua_createtable(L, (int)g.chars.size(), 0);
    for (size_t i = 0; i < g.chars.size(); i++) { lua_pushlstring(L, g.chars[i].data(), g.chars[i].size()); lua_rawseti(L, -2, (int)i + 1); }
    lua_setfield(L, t, "chars");
    lua_createtable(L, (int)g.files.size(), 0);
    for (size_t i = 0; i < g.files.size(); i++) { lua_pushstring(L, g.files[i].c_str()); lua_rawseti(L, -2, (int)i + 1); }
    lua_setfield(L, t, "files");
    lua_createtable(L, 0, 4); int mt = lua_gettop(L);
    set_bool(L, mt, "shift", key_held(VK_SHIFT)); set_bool(L, mt, "ctrl", key_held(VK_CONTROL));
    set_bool(L, mt, "alt", key_held(VK_MENU)); set_bool(L, mt, "sys", key_held(VK_LWIN) || key_held(VK_RWIN));
    lua_setfield(L, t, "mods");
    set_bool(L, t, "focused", GetForegroundWindow() == g.hwnd);
    set_bool(L, t, "resized", g.resized);
    set_bool(L, t, "minimized", minimized);
    set_bool(L, t, "close_requested", g.close);

    g.keys.clear(); g.chars.clear(); g.files.clear();
    g.wheel_x = g.wheel_y = 0; g.resized = false; g.close = false;
    for (int i = 0; i < 3; i++) g.pressed[i] = g.released[i] = g.dbl[i] = 0;
    return 1;
}

int l_frame_end(lua_State *) {
    if (!g.frame_open) return 0;
    g.frame_open = false;
    ImGui::Render();
    RECT r; GetClientRect(g.hwnd, &r);
    glViewport(0, 0, r.right, r.bottom);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
    if (g.shot.pending) write_shot();
    SwapBuffers(g.dc);
    return 0;
}

int l_rect(lua_State *L) {
    draw()->AddRect(ImVec2((float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2)),
        ImVec2((float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4)), color(luaL_checknumber(L, 5)),
        (float)luaL_optnumber(L, 6, 0), (ImDrawFlags)luaL_optinteger(L, 8, 0), (float)luaL_optnumber(L, 7, 1));
    return 0;
}
int l_rect_filled(lua_State *L) {
    draw()->AddRectFilled(ImVec2((float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2)),
        ImVec2((float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4)), color(luaL_checknumber(L, 5)),
        (float)luaL_optnumber(L, 6, 0), (ImDrawFlags)luaL_optinteger(L, 7, 0));
    return 0;
}
int l_rect_gradient(lua_State *L) {
    draw()->AddRectFilledMultiColor(ImVec2((float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2)),
        ImVec2((float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4)),
        color(luaL_checknumber(L, 5)), color(luaL_checknumber(L, 6)), color(luaL_checknumber(L, 7)), color(luaL_checknumber(L, 8)));
    return 0;
}
int l_line(lua_State *L) {
    draw()->AddLine(ImVec2((float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2)),
        ImVec2((float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4)), color(luaL_checknumber(L, 5)),
        (float)luaL_optnumber(L, 6, 1));
    return 0;
}
int l_circle(lua_State *L) {
    ImVec2 c((float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2));
    float r = (float)luaL_checknumber(L, 3); ImU32 col = color(luaL_checknumber(L, 4));
    float thick = (float)luaL_optnumber(L, 5, 1); int seg = (int)luaL_optinteger(L, 6, 0);
    if (thick <= 0) draw()->AddCircleFilled(c, r, col, seg); else draw()->AddCircle(c, r, col, seg, thick);
    return 0;
}
int l_poly(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    std::vector<ImVec2> p;
    size_t n = lua_objlen(L, 1);
    for (size_t i = 1; i + 1 <= n; i += 2) {
        lua_rawgeti(L, 1, (int)i); float x = (float)lua_tonumber(L, -1); lua_pop(L, 1);
        lua_rawgeti(L, 1, (int)i + 1); float y = (float)lua_tonumber(L, -1); lua_pop(L, 1);
        p.push_back(ImVec2(x, y));
    }
    if (p.size() < 2) return 0;
    ImU32 c = color(luaL_checknumber(L, 2));
    if (lua_toboolean(L, 3)) draw()->AddConvexPolyFilled(p.data(), (int)p.size(), c);
    else draw()->AddPolyline(p.data(), (int)p.size(), c, ImDrawFlags_Closed, (float)luaL_optnumber(L, 4, 1));
    return 0;
}

int l_text(lua_State *L) {
    Face &f = face_of((int)luaL_checkinteger(L, 1));
    float px = (float)luaL_checknumber(L, 2);
    size_t len; const char *s = luaL_checklstring(L, 6, &len);
    ImVec4 clip((float)luaL_optnumber(L, 8, -FLT_MAX), (float)luaL_optnumber(L, 9, -FLT_MAX),
        (float)luaL_optnumber(L, 10, FLT_MAX), (float)luaL_optnumber(L, 11, FLT_MAX));
    float x = (float)luaL_checknumber(L, 3), y = (float)luaL_checknumber(L, 4) + baseline_shift(f, px);
    draw()->AddText(f.font, imgui_size(f, px), ImVec2(std::round(x), std::round(y)), color(luaL_checknumber(L, 5)),
        s, s + len, (float)luaL_optnumber(L, 7, 0), &clip);
    return 0;
}

int l_text_size(lua_State *L) {
    Face &f = face_of((int)luaL_checkinteger(L, 1));
    float px = (float)luaL_checknumber(L, 2);
    size_t len; const char *s = luaL_checklstring(L, 3, &len);
    ImVec2 v = f.font->CalcTextSizeA(imgui_size(f, px), FLT_MAX, (float)luaL_optnumber(L, 4, 0), s, s + len);
    /* lines are tmHeight apart, as GDI lays them out */
    int lines = 1; for (size_t i = 0; i < len; i++) if (s[i] == '\n') lines++;
    float line = f.metrics ? std::round(px * f.win_asc / f.upm) + std::round(px * f.win_desc / f.upm) : v.y / lines;
    lua_pushnumber(L, v.x);
    lua_pushnumber(L, line * (v.y / std::max(1.0f, imgui_size(f, px))));
    return 2;
}

int l_font_metrics(lua_State *L) {
    Face &f = face_of((int)luaL_checkinteger(L, 1));
    float px = (float)luaL_checknumber(L, 2);
    if (!f.metrics) { lua_pushnumber(L, px); lua_pushnumber(L, px * 0.25); lua_pushnumber(L, std::ceil(px * 1.25)); lua_pushnumber(L, px / 2); return 4; }
    float asc = std::round(px * f.win_asc / f.upm), desc = std::round(px * f.win_desc / f.upm);
    lua_pushnumber(L, asc); lua_pushnumber(L, desc); lua_pushnumber(L, asc + desc);
    lua_pushnumber(L, std::round(px * f.avg / f.upm));
    return 4;
}

int l_font_load(lua_State *L) {
    int id = load_face(luaL_checkstring(L, 1));
    if (id < 0) { lua_pushnil(L); return 1; }
    lua_pushinteger(L, id);
    return 1;
}

int l_font_find(lua_State *L) {
    std::string p = find_font(luaL_checkstring(L, 1), lua_toboolean(L, 2) != 0, lua_toboolean(L, 3) != 0);
    if (p.empty()) lua_pushnil(L); else lua_pushstring(L, p.c_str());
    return 1;
}

int l_texture(lua_State *L) {
    size_t n; const unsigned char *p = (const unsigned char*)luaL_checklstring(L, 1, &n);
    int w = (int)luaL_checkinteger(L, 2), h = (int)luaL_checkinteger(L, 3);
    if (w <= 0 || h <= 0 || n < (size_t)w * h * 4) { lua_pushnil(L); return 1; }
    GLuint tex; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, 0x812F /* CLAMP_TO_EDGE */);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, 0x812F);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, p);
    int id = g.next_texture++;
    g.textures[id] = tex;
    lua_pushinteger(L, id);
    return 1;
}

int l_texture_free(lua_State *L) {
    auto it = g.textures.find((int)luaL_checkinteger(L, 1));
    if (it != g.textures.end()) { glDeleteTextures(1, &it->second); g.textures.erase(it); }
    return 0;
}

int l_image(lua_State *L) {
    auto it = g.textures.find((int)luaL_checkinteger(L, 1));
    if (it == g.textures.end()) return 0;
    draw()->AddImage(ImTextureRef((ImTextureID)(intptr_t)it->second),
        ImVec2((float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3)),
        ImVec2((float)luaL_checknumber(L, 4), (float)luaL_checknumber(L, 5)),
        ImVec2((float)luaL_optnumber(L, 6, 0), (float)luaL_optnumber(L, 7, 0)),
        ImVec2((float)luaL_optnumber(L, 8, 1), (float)luaL_optnumber(L, 9, 1)),
        color(luaL_optnumber(L, 10, 0xFFFFFFFF)));
    return 0;
}

int l_clip_push(lua_State *L) {
    draw()->PushClipRect(ImVec2((float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2)),
        ImVec2((float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4)), true);
    return 0;
}
int l_clip_pop(lua_State *) { if (draw()->_ClipRectStack.Size > 1) draw()->PopClipRect(); return 0; }
int l_layer(lua_State *L) { int n = (int)luaL_optinteger(L, 1, 0); g.layer = (n == 1 && g.lists.size() > 1) ? 1 : 0; return 0; }

int l_cursor(lua_State *L) {
    const char *n = luaL_checkstring(L, 1);
    LPCSTR id = IDC_ARROW;
    if (!_stricmp(n, "HAND")) id = IDC_HAND;
    else if (!_stricmp(n, "IBEAM")) id = IDC_IBEAM;
    else if (!_stricmp(n, "WAIT")) id = IDC_WAIT;
    else if (!_stricmp(n, "SIZEWE")) id = IDC_SIZEWE;
    else if (!_stricmp(n, "SIZENS")) id = IDC_SIZENS;
    else if (!_stricmp(n, "SIZEALL")) id = IDC_SIZEALL;
    else if (!_stricmp(n, "SIZENWSE")) id = IDC_SIZENWSE;
    else if (!_stricmp(n, "SIZENESW")) id = IDC_SIZENESW;
    else if (!_stricmp(n, "NO")) id = IDC_NO;
    else if (!_stricmp(n, "CROSS")) id = IDC_CROSS;
    else if (!_stricmp(n, "UPARROW")) id = IDC_UPARROW;
    HCURSOR c = !_stricmp(n, "NONE") ? nullptr : LoadCursorA(nullptr, id);
    if (c != g.cursor) {
        g.cursor = c;
        POINT p; GetCursorPos(&p);
        if (g.hwnd && WindowFromPoint(p) == g.hwnd && g.inside) SetCursor(c);
    }
    return 0;
}

int l_clipboard_get(lua_State *L) {
    std::string s;
    if (OpenClipboard(g.hwnd)) {
        HANDLE h = GetClipboardData(CF_UNICODETEXT);
        if (h) { const wchar_t *p = (const wchar_t*)GlobalLock(h); if (p) s = utf8(p); GlobalUnlock(h); }
        CloseClipboard();
    }
    /* CRLF -> LF, as IUP hands text to Lua */
    std::string out; out.reserve(s.size());
    for (size_t i = 0; i < s.size(); i++) if (!(s[i] == '\r' && i + 1 < s.size() && s[i + 1] == '\n')) out += s[i];
    lua_pushlstring(L, out.data(), out.size());
    return 1;
}

int l_clipboard_set(lua_State *L) {
    std::string in = luaL_checkstring(L, 1), crlf;
    for (char c : in) { if (c == '\n') crlf += '\r'; crlf += c; }
    std::wstring s = wide(crlf.c_str());
    if (!OpenClipboard(g.hwnd)) return 0;
    EmptyClipboard();
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, (s.size() + 1) * sizeof(wchar_t));
    if (h) { memcpy(GlobalLock(h), s.c_str(), (s.size() + 1) * sizeof(wchar_t)); GlobalUnlock(h); SetClipboardData(CF_UNICODETEXT, h); }
    CloseClipboard();
    return 0;
}

int l_cursor_pos(lua_State *L) {
    POINT p; GetCursorPos(&p);
    lua_pushinteger(L, p.x); lua_pushinteger(L, p.y);
    return 2;
}

int l_screenshot(lua_State *L) {
    g.shot.pending = true;
    g.shot.path = luaL_checkstring(L, 1);
    g.shot.x = (int)luaL_optinteger(L, 2, 0); g.shot.y = (int)luaL_optinteger(L, 3, 0);
    g.shot.w = (int)luaL_optinteger(L, 4, 0); g.shot.h = (int)luaL_optinteger(L, 5, 0);
    lua_pushboolean(L, 1);
    return 1;
}

int l_window(lua_State *L) {
    const char *op = luaL_checkstring(L, 1);
    HWND h = g.hwnd;
    auto is = [&](const char *name) { return _stricmp(op, name) == 0; };
    if (is("screen") || is("full")) {
        RECT work, full; monitor_rects(work, full);
        RECT &r = is("screen") ? work : full;
        lua_pushinteger(L, r.right - r.left); lua_pushinteger(L, r.bottom - r.top);
        return 2;
    }
    if (is("dpi")) { lua_pushnumber(L, (double)window_dpi(h) / 96.0); return 1; }
    if (!h) return 0;
    if (is("title")) {
        if (lua_isstring(L, 2)) SetWindowTextW(h, wide(lua_tostring(L, 2)).c_str());
        wchar_t buf[1024]; GetWindowTextW(h, buf, 1024); lua_pushstring(L, utf8(buf).c_str()); return 1;
    }
    if (is("show")) { if (!IsWindowVisible(h)) ShowWindow(h, SW_SHOW); return 0; }
    if (is("hide")) { ShowWindow(h, SW_HIDE); return 0; }
    if (is("focus")) { if (IsIconic(h)) ShowWindow(h, SW_RESTORE); SetForegroundWindow(h); lua_pushboolean(L, 1); return 1; }
    if (is("maximize")) { ShowWindow(h, SW_MAXIMIZE); return 0; }
    if (is("minimize")) { ShowWindow(h, SW_MINIMIZE); return 0; }
    if (is("restore")) { if (g.fullscreen) set_fullscreen(false); ShowWindow(h, SW_RESTORE); return 0; }
    if (is("is_maximized")) { lua_pushboolean(L, IsZoomed(h)); return 1; }
    if (is("is_minimized")) { lua_pushboolean(L, IsIconic(h)); return 1; }
    if (is("fullscreen")) { set_fullscreen(lua_toboolean(L, 2) != 0); return 0; }
    if (is("hwnd")) { lua_pushnumber(L, (lua_Number)(uintptr_t)h); return 1; }
    if (is("size")) {
        if (lua_isnumber(L, 2)) {
            int w = (int)lua_tointeger(L, 2), hh = (int)luaL_checkinteger(L, 3);
            client_to_window(w, hh, (DWORD)GetWindowLongW(h, GWL_STYLE), (DWORD)GetWindowLongW(h, GWL_EXSTYLE));
            SetWindowPos(h, nullptr, 0, 0, w, hh, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        }
        RECT r; GetClientRect(h, &r); lua_pushinteger(L, r.right); lua_pushinteger(L, r.bottom); return 2;
    }
    if (is("pos")) {
        if (lua_isnumber(L, 2)) SetWindowPos(h, nullptr, (int)lua_tointeger(L, 2), (int)luaL_checkinteger(L, 3), 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        RECT r; GetWindowRect(h, &r); lua_pushinteger(L, r.left); lua_pushinteger(L, r.top); return 2;
    }
    if (is("client_origin")) { POINT p = {0, 0}; ClientToScreen(h, &p); lua_pushinteger(L, p.x); lua_pushinteger(L, p.y); return 2; }
    if (is("custom_frame")) {
        g.custom_frame = lua_toboolean(L, 2) != 0;
        SetWindowPos(h, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
        return 0;
    }
    if (is("caption")) {
        g.caption = rect_field(L, 2, nullptr);
        g.btn_min = Rect(); g.btn_max = Rect(); g.btn_close = Rect(); g.nodrag.clear();
        if (lua_istable(L, 3)) {
            g.btn_min = rect_field(L, 3, "min"); g.btn_max = rect_field(L, 3, "max"); g.btn_close = rect_field(L, 3, "close");
            lua_getfield(L, 3, "nodrag");
            if (lua_istable(L, -1)) {
                int nt = lua_gettop(L);
                for (size_t i = 1; i <= lua_objlen(L, nt); i++) { lua_rawgeti(L, nt, (int)i); g.nodrag.push_back(rect_field(L, lua_gettop(L), nullptr)); lua_pop(L, 1); }
            }
            lua_pop(L, 1);
        }
        return 0;
    }
    if (is("icon")) {
        size_t n; const unsigned char *px = (const unsigned char*)luaL_checklstring(L, 2, &n);
        int w = (int)luaL_checkinteger(L, 3), hh = (int)luaL_checkinteger(L, 4);
        if (n < (size_t)w * hh * 4) return 0;
        BITMAPV5HEADER bi = {}; bi.bV5Size = sizeof(bi); bi.bV5Width = w; bi.bV5Height = -hh; bi.bV5Planes = 1;
        bi.bV5BitCount = 32; bi.bV5Compression = BI_BITFIELDS;
        bi.bV5RedMask = 0x00FF0000; bi.bV5GreenMask = 0x0000FF00; bi.bV5BlueMask = 0x000000FF; bi.bV5AlphaMask = 0xFF000000;
        void *bits = nullptr; HDC dc = GetDC(nullptr);
        HBITMAP color_bm = CreateDIBSection(dc, (BITMAPINFO*)&bi, DIB_RGB_COLORS, &bits, nullptr, 0);
        ReleaseDC(nullptr, dc);
        if (!color_bm) return 0;
        unsigned char *dst = (unsigned char*)bits;
        for (int i = 0; i < w * hh; i++) { dst[i*4] = px[i*4+2]; dst[i*4+1] = px[i*4+1]; dst[i*4+2] = px[i*4]; dst[i*4+3] = px[i*4+3]; }
        HBITMAP mask = CreateBitmap(w, hh, 1, 1, nullptr);
        ICONINFO ii = {TRUE, 0, 0, mask, color_bm};
        HICON icon = CreateIconIndirect(&ii);
        DeleteObject(mask); DeleteObject(color_bm);
        if (icon) { SendMessageW(h, WM_SETICON, ICON_SMALL, (LPARAM)icon); SendMessageW(h, WM_SETICON, ICON_BIG, (LPARAM)icon); }
        return 0;
    }
    return 0;
}

/* "Text|*.txt|All|*.*|" (IUP EXTFILTER) -> "Text\0*.txt\0All\0*.*\0\0" */
std::wstring win_filter(const char *f) {
    std::wstring w = wide(f ? f : "All files|*.*|");
    if (w.empty()) w = L"All files|*.*|";
    if (w.back() != L'|') w += L'|';
    for (wchar_t &c : w) if (c == L'|') c = L'\0';
    w += L'\0';
    return w;
}

int pick_folder(lua_State *L, const std::wstring &title, const std::wstring &start) {
    HRESULT co = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    IFileOpenDialog *dlg = nullptr; std::string result;
    if (SUCCEEDED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_ALL, IID_IFileOpenDialog, (void**)&dlg))) {
        DWORD opts; dlg->GetOptions(&opts); dlg->SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
        if (!title.empty()) dlg->SetTitle(title.c_str());
        if (!start.empty()) {
            IShellItem *item = nullptr;
            if (SUCCEEDED(SHCreateItemFromParsingName(start.c_str(), nullptr, IID_IShellItem, (void**)&item))) { dlg->SetFolder(item); item->Release(); }
        }
        if (SUCCEEDED(dlg->Show(g.hwnd))) {
            IShellItem *item = nullptr;
            if (SUCCEEDED(dlg->GetResult(&item))) {
                PWSTR path = nullptr;
                if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) { result = utf8(path); CoTaskMemFree(path); }
                item->Release();
            }
        }
        dlg->Release();
    }
    if (SUCCEEDED(co)) CoUninitialize();
    if (result.empty()) lua_pushnil(L); else lua_pushstring(L, result.c_str());
    return 1;
}

int l_file_dialog(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    auto str = [&](const char *k) { std::string s; lua_getfield(L, 1, k); if (lua_isstring(L, -1)) s = lua_tostring(L, -1); lua_pop(L, 1); return s; };
    auto flag = [&](const char *k) { lua_getfield(L, 1, k); bool b = lua_toboolean(L, -1) != 0; lua_pop(L, 1); return b; };
    std::string type = lower(str("type"));
    std::wstring title = wide(str("title").c_str()), dir = wide(str("directory").c_str());
    for (wchar_t &c : dir) if (c == L'/') c = L'\\';
    if (type == "dir") return pick_folder(L, title, dir);
    std::vector<wchar_t> file(65536, L'\0');
    std::wstring initial = wide(str("file").c_str());
    for (wchar_t &c : initial) if (c == L'/') c = L'\\';
    wcsncpy(file.data(), initial.c_str(), file.size() - 1);
    std::wstring filter = win_filter(str("filter").empty() ? nullptr : str("filter").c_str());
    OPENFILENAMEW ofn = {}; ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = g.hwnd; ofn.lpstrFile = file.data(); ofn.nMaxFile = (DWORD)file.size();
    ofn.lpstrFilter = filter.c_str(); ofn.nFilterIndex = 1;
    ofn.lpstrTitle = title.empty() ? nullptr : title.c_str();
    ofn.lpstrInitialDir = dir.empty() ? nullptr : dir.c_str();
    ofn.Flags = OFN_EXPLORER | OFN_NOCHANGEDIR | OFN_HIDEREADONLY;
    bool save = type == "save";
    if (save) { if (flag("overwrite_prompt")) ofn.Flags |= OFN_OVERWRITEPROMPT; }
    else { if (!flag("allownew")) ofn.Flags |= OFN_FILEMUSTEXIST; if (flag("multiple")) ofn.Flags |= OFN_ALLOWMULTISELECT; }
    BOOL ok = save ? GetSaveFileNameW(&ofn) : GetOpenFileNameW(&ofn);
    if (!ok) { lua_pushnil(L); return 1; }
    if (!save && (ofn.Flags & OFN_ALLOWMULTISELECT) && file[wcslen(file.data()) + 1] != L'\0') {
        std::wstring folder = file.data();
        lua_newtable(L); int i = 1;
        for (const wchar_t *p = file.data() + folder.size() + 1; *p; p += wcslen(p) + 1) {
            lua_pushstring(L, utf8((folder + L"\\" + p).c_str()).c_str()); lua_rawseti(L, -2, i++);
        }
        return 1;
    }
    lua_pushstring(L, utf8(file.data()).c_str());
    return 1;
}

int l_message_box(lua_State *L) {
    const char *kind = luaL_optstring(L, 3, "");
    UINT type = MB_OK;
    if (!_stricmp(kind, "ERROR")) type |= MB_ICONERROR;
    else if (!_stricmp(kind, "WARNING")) type |= MB_ICONWARNING;
    else if (!_stricmp(kind, "QUESTION")) type = MB_YESNO | MB_ICONQUESTION;
    else if (!_stricmp(kind, "INFORMATION")) type |= MB_ICONINFORMATION;
    int r = MessageBoxW(g.hwnd, wide(luaL_checkstring(L, 2)).c_str(), wide(luaL_checkstring(L, 1)).c_str(), type);
    lua_pushinteger(L, r == IDYES || r == IDOK ? 1 : 2);
    return 1;
}

const luaL_Reg api[] = {
    {"open", l_open}, {"close", l_close}, {"alive", l_alive}, {"now", l_now}, {"wait", l_wait},
    {"set_paint_callback", l_set_paint_callback},
    {"frame_begin", l_frame_begin}, {"frame_end", l_frame_end},
    {"rect", l_rect}, {"rect_filled", l_rect_filled}, {"rect_gradient", l_rect_gradient},
    {"line", l_line}, {"circle", l_circle}, {"poly", l_poly},
    {"text", l_text}, {"text_size", l_text_size}, {"font_metrics", l_font_metrics},
    {"font_load", l_font_load}, {"font_find", l_font_find},
    {"texture", l_texture}, {"texture_free", l_texture_free}, {"image", l_image},
    {"clip_push", l_clip_push}, {"clip_pop", l_clip_pop}, {"layer", l_layer},
    {"cursor", l_cursor}, {"clipboard_get", l_clipboard_get}, {"clipboard_set", l_clipboard_set},
    {"cursor_pos", l_cursor_pos}, {"window", l_window}, {"screenshot", l_screenshot},
    {"file_dialog", l_file_dialog}, {"message_box", l_message_box},
    {nullptr, nullptr}};

} // namespace

extern "C" int luaopen_lunarimgui(lua_State *L) {
    ensure_imgui();
    lua_newtable(L);
    luaL_register(L, nullptr, api);
    return 1;
}

/*** The native backend of the ImGui host: one Win32 window, Direct3D 11 (WARP by default), Dear ImGui's
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
#include <d3d11.h>
#include <dxgi.h>
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
#include "backends/imgui_impl_dx11.h"
extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);

#ifndef WM_DPICHANGED
#define WM_DPICHANGED 0x02E0
#endif

/* The frame and its input, read by Lua through LuaJIT's FFI (core.imgui.backend.Native
 * declares the same layout). Input arrives as an ordered list of events, each with the
 * pointer position and modifiers it happened with, so a press and release that land in
 * one frame (a touchpad tap, a quick click) are routed exactly as they happened. */
extern "C" {
typedef struct LunarUiEvent {
    int32_t type;     /* 1 move, 2 press, 3 release, 4 wheel, 5 key down, 6 key up, 7 char, 8 leave, 9 file */
    int32_t button;   /* 1 left, 2 middle, 3 right; a double click is a press with button + 8 */
    int32_t mods;     /* 1 shift, 2 ctrl, 4 alt, 8 sys, 16/32/64 buttons 1/2/3 held */
    int32_t code;     /* key: the backend key code; char/file: index into chars/files */
    float x, y;       /* client px */
    float dx, dy;     /* wheel notches */
} LunarUiEvent;

typedef struct LunarUiFrame {
    int32_t w, h;
    float scale;
    int32_t focused, resized, minimized, close_requested, inside;
    float mx, my;
    int32_t nevents;
    const LunarUiEvent *events;
    int32_t nchars;
    const char *const *chars;
    int32_t nfiles;
    const char *const *files;
} LunarUiFrame;
}

namespace {

struct KeyEvent { int code; bool down, shift, ctrl, alt, sys; };

struct Face {
    ImFont *font = nullptr;
    float upm = 2048, hhea_asc = 0, hhea_desc = 0, win_asc = 0, win_desc = 0, avg = 0;
    bool metrics = false;
};

struct Rect { int x = 0, y = 0, w = 0, h = 0; bool contains(int px, int py) const { return w > 0 && px >= x && py >= y && px < x + w && py < y + h; } };

struct Shot { bool pending = false; std::string path; int x = 0, y = 0, w = 0, h = 0; bool ok = false; };
struct VideoChild { HWND hwnd = nullptr; HBRUSH brush = nullptr; };

struct State {
    HWND hwnd = nullptr;
    /* Direct3D 11. WARP (Windows' software rasterizer) by default: the GPU driver a
     * hardware device loads costs tens of MB of working set, which a desktop tool's
     * flat 2D UI does not need. LUNAR_RENDERER=hardware picks the GPU. */
    ID3D11Device *device = nullptr; ID3D11DeviceContext *ctx = nullptr;
    IDXGISwapChain *swap = nullptr; ID3D11RenderTargetView *rtv = nullptr;
    int sc_w = 0, sc_h = 0; bool warp = true;
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
    std::unordered_map<int, ID3D11ShaderResourceView*> textures; int next_texture = 1;
    std::vector<Face> faces;
    std::unordered_map<std::string, int> face_by_path;
    std::chrono::steady_clock::time_point started = std::chrono::steady_clock::now();
    HCURSOR cursor = nullptr;
    wchar_t high_surrogate = 0;
    lua_State *L = nullptr; int paint_ref = LUA_NOREF;
    int last_w = 0, last_h = 0;
    Shot shot;
    std::vector<ImDrawList*> lists; int layer = 0;
    std::vector<VideoChild> video_children;
    bool tray = false; std::string tray_tip, tray_title; int tray_balloon = 0; std::string tray_icon;
    std::vector<LunarUiEvent> events, frame_events;
    std::vector<std::string> frame_chars, frame_files;
    std::vector<const char*> frame_char_ptrs, frame_file_ptrs;
    LunarUiFrame frame = {};
} g;

const UINT LUNAR_TRAY_MESSAGE = WM_APP + 42;
const UINT LUNAR_TRAY_ID = 1;
const wchar_t *VIDEO_CLASS = L"LunarImGuiVideoHost";
std::wstring wide(const char *s);

COLORREF rgb(const char *s) {
    int r = 0, g = 0, b = 0;
    if (s) sscanf_s(s, "%d %d %d", &r, &g, &b);
    return RGB(std::max(0, std::min(255, r)), std::max(0, std::min(255, g)), std::max(0, std::min(255, b)));
}

LRESULT CALLBACK video_wndproc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_ERASEBKGND) return 1;
    if (m == WM_PAINT) {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        HBRUSH brush = (HBRUSH)GetWindowLongPtrW(h, GWLP_USERDATA);
        FillRect(dc, &ps.rcPaint, brush ? brush : (HBRUSH)(COLOR_WINDOW + 1)); EndPaint(h, &ps);
        return 0;
    }

    return DefWindowProcW(h, m, w, l);
}

void tray_apply(bool add) {
    if (!g.hwnd) return;
    NOTIFYICONDATAW n = {}; n.cbSize = sizeof(n); n.hWnd = g.hwnd; n.uID = LUNAR_TRAY_ID;
    n.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP; n.uCallbackMessage = LUNAR_TRAY_MESSAGE;
    n.hIcon = (HICON)SendMessageW(g.hwnd, WM_GETICON, ICON_SMALL, 0);
    if (!n.hIcon) n.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1));
    std::wstring tip = wide(g.tray_tip.c_str());
    wcsncpy_s(n.szTip, tip.c_str(), _TRUNCATE);
    Shell_NotifyIconW(add ? (g.tray ? NIM_MODIFY : NIM_ADD) : NIM_DELETE, &n);
    if (add) g.tray = true;
}

void tray_balloon() {
    if (!g.tray || g.tray_balloon <= 0) return;
    NOTIFYICONDATAW n = {}; n.cbSize = sizeof(n); n.hWnd = g.hwnd; n.uID = LUNAR_TRAY_ID;
    n.uFlags = NIF_INFO; n.dwInfoFlags = NIIF_INFO;
    std::wstring tip = wide(g.tray_tip.c_str()), title = wide(g.tray_title.c_str());
    wcsncpy_s(n.szInfo, tip.c_str(), _TRUNCATE); wcsncpy_s(n.szInfoTitle, title.c_str(), _TRUNCATE);
    Shell_NotifyIconW(NIM_MODIFY, &n);
}

void video_frame_reset() {
    for (auto &v : g.video_children) if (v.hwnd) ShowWindow(v.hwnd, SW_HIDE);
}

ImU32 color(lua_Number n) { return (ImU32)(unsigned long long)n; }
bool key_held(int vk) { return (GetKeyState(vk) & 0x8000) != 0; }

int event_mods() {
    int m = 0;
    if (key_held(VK_SHIFT)) m |= 1;
    if (key_held(VK_CONTROL)) m |= 2;
    if (key_held(VK_MENU)) m |= 4;
    if (key_held(VK_LWIN) || key_held(VK_RWIN)) m |= 8;
    if (g.down[0]) m |= 16;
    if (g.down[1]) m |= 32;
    if (g.down[2]) m |= 64;
    return m;
}

void push_event(int type, int button = 0, int code = 0, float dx = 0, float dy = 0) {
    LunarUiEvent e = {};
    e.type = type; e.button = button; e.code = code; e.mods = event_mods();
    e.x = (float)g.mx; e.y = (float)g.my; e.dx = dx; e.dy = dy;
    /* consecutive moves collapse into one: only the last position matters */
    if (type == 1 && !g.events.empty() && g.events.back().type == 1) { g.events.back() = e; return; }
    g.events.push_back(e);
}

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
    push_event(down ? 5 : 6, 0, code);
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
    if (g.device && ImGui::GetCurrentContext() && ImGui::GetIO().BackendPlatformUserData) ImGui_ImplWin32_WndProcHandler(h, m, w, l);
    switch (m) {
    case LUNAR_TRAY_MESSAGE:
        if (w == LUNAR_TRAY_ID) {
            int button = 0, pressed = 0, dbl = 0;
            switch ((UINT)l) {
            case WM_LBUTTONDOWN: button = 1; pressed = 1; break;
            case WM_LBUTTONUP: button = 1; break;
            case WM_LBUTTONDBLCLK: button = 1; pressed = 1; dbl = 1; break;
            case WM_MBUTTONDOWN: button = 2; pressed = 1; break;
            case WM_MBUTTONUP: button = 2; break;
            case WM_MBUTTONDBLCLK: button = 2; pressed = 1; dbl = 1; break;
            case WM_RBUTTONDOWN: button = 3; pressed = 1; break;
            case WM_RBUTTONUP: button = 3; break;
            case WM_RBUTTONDBLCLK: button = 3; pressed = 1; dbl = 1; break;
            }
            if (button) {
                LunarUiEvent e = {}; e.type = 10; e.button = button + (dbl ? 8 : 0);
                e.dx = (float)pressed; e.dy = (float)dbl; g.events.push_back(e);
            }
        }
        return 0;
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
            push_event(1);
            if (!g.nc_tracking) {
                TRACKMOUSEEVENT t = {sizeof(t), TME_LEAVE | TME_NONCLIENT, h, 0};
                TrackMouseEvent(&t); g.nc_tracking = true;
            }
            return 0;
        }
        if (g.custom_frame && !g.tracking && g.inside) { g.inside = false; g.mx = g.my = -1; push_event(8); }
        break;
    case WM_NCMOUSELEAVE:
        g.nc_tracking = false;
        if (!g.tracking && g.inside) { g.inside = false; g.mx = g.my = -1; push_event(8); }
        break;
    case WM_NCLBUTTONDOWN: case WM_NCLBUTTONDBLCLK:
        if (g.custom_frame && is_button_hit(w)) {
            mouse_to_client(h, l, true); g.pressed[0]++; g.down[0] = true; push_event(2, 1); return 0;
        }
        break;
    case WM_NCLBUTTONUP:
        if (g.custom_frame && is_button_hit(w)) {
            mouse_to_client(h, l, true); g.released[0]++; g.down[0] = false; push_event(3, 1); return 0;
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
        push_event(7, 0, (int)g.chars.size() - 1);
        return 0;
    }
    case WM_LBUTTONDOWN: case WM_MBUTTONDOWN: case WM_RBUTTONDOWN:
    case WM_LBUTTONDBLCLK: case WM_MBUTTONDBLCLK: case WM_RBUTTONDBLCLK: {
        int b = button_index(m);
        mouse_to_client(h, l, false);
        g.pressed[b]++; g.down[b] = true;
        bool dbl = m == WM_LBUTTONDBLCLK || m == WM_MBUTTONDBLCLK || m == WM_RBUTTONDBLCLK;
        if (dbl) g.dbl[b]++;
        push_event(2, b + 1 + (dbl ? 8 : 0));
        SetCapture(h);
        return 0;
    }
    case WM_LBUTTONUP: case WM_MBUTTONUP: case WM_RBUTTONUP: {
        int b = button_index(m);
        mouse_to_client(h, l, false);
        g.released[b]++; g.down[b] = false;
        push_event(3, b + 1);
        if (!g.down[0] && !g.down[1] && !g.down[2]) ReleaseCapture();
        return 0;
    }
    case WM_CAPTURECHANGED:
        for (int i = 0; i < 3; i++) if (g.down[i]) { g.down[i] = false; g.released[i]++; push_event(3, i + 1); }
        break;
    case WM_MOUSEWHEEL: {
        float d = (float)GET_WHEEL_DELTA_WPARAM(w) / WHEEL_DELTA;
        g.wheel_y += d;
        push_event(4, 0, 0, 0, d);
        return 0;
    }
    case WM_MOUSEHWHEEL: {
        float d = (float)GET_WHEEL_DELTA_WPARAM(w) / WHEEL_DELTA;
        g.wheel_x += d;
        push_event(4, 0, 0, d, 0);
        return 0;
    }
    case WM_MOUSEMOVE:
        mouse_to_client(h, l, false);
        push_event(1);
        if (!g.tracking) { TRACKMOUSEEVENT t = {sizeof(t), TME_LEAVE, h, 0}; TrackMouseEvent(&t); g.tracking = true; }
        return 0;
    case WM_MOUSELEAVE:
        g.tracking = false;
        if (!g.down[0] && !g.down[1] && !g.down[2]) { g.inside = false; g.mx = g.my = -1; push_event(8); }
        return 0;
    case WM_DROPFILES: {
        HDROP drop = (HDROP)w;
        UINT n = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
        for (UINT i = 0; i < n; i++) {
            wchar_t path[MAX_PATH * 4]; DragQueryFileW(drop, i, path, MAX_PATH * 4);
            g.files.push_back(utf8(path));
            push_event(9, 0, (int)g.files.size() - 1);
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
    cfg.RasterizerMultiply = 1.4f;   /* closer to the weight GDI ClearType gave IUP text */
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

void release_target() { if (g.rtv) { g.rtv->Release(); g.rtv = nullptr; } }

bool create_target() {
    ID3D11Texture2D *back = nullptr;
    if (FAILED(g.swap->GetBuffer(0, __uuidof(ID3D11Texture2D), (void**)&back)) || !back) return false;
    HRESULT hr = g.device->CreateRenderTargetView(back, nullptr, &g.rtv);
    D3D11_TEXTURE2D_DESC d; back->GetDesc(&d); g.sc_w = (int)d.Width; g.sc_h = (int)d.Height;
    back->Release();
    return SUCCEEDED(hr);
}

bool create_device(D3D_DRIVER_TYPE driver) {
    DXGI_SWAP_CHAIN_DESC sd = {};
    sd.BufferCount = 2;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = g.hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    const D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0 };
    D3D_FEATURE_LEVEL got;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(nullptr, driver, nullptr, 0, levels, 3, D3D11_SDK_VERSION,
        &sd, &g.swap, &g.device, &got, &g.ctx);
    if (FAILED(hr)) {   /* before Windows 10: the blit model */
        sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD; sd.BufferCount = 1;
        hr = D3D11CreateDeviceAndSwapChain(nullptr, driver, nullptr, 0, levels, 3, D3D11_SDK_VERSION,
            &sd, &g.swap, &g.device, &got, &g.ctx);
    }
    if (FAILED(hr)) return false;
    /* Alt+Enter is the app's to handle, not DXGI's */
    IDXGIFactory *factory = nullptr;
    if (SUCCEEDED(g.swap->GetParent(__uuidof(IDXGIFactory), (void**)&factory)) && factory) {
        factory->MakeWindowAssociation(g.hwnd, DXGI_MWA_NO_ALT_ENTER); factory->Release();
    }
    g.warp = driver == D3D_DRIVER_TYPE_WARP;
    return create_target();
}

void ensure_context() {
    if (g.device) return;
    char want[32] = "";
    GetEnvironmentVariableA("LUNAR_RENDERER", want, sizeof(want));
    bool hardware = !_stricmp(want, "hardware") || !_stricmp(want, "gpu");
    if (!create_device(hardware ? D3D_DRIVER_TYPE_HARDWARE : D3D_DRIVER_TYPE_WARP))
        create_device(hardware ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_HARDWARE);
    ensure_imgui();
    ImGui_ImplWin32_Init(g.hwnd);
    if (g.device) ImGui_ImplDX11_Init(g.device, g.ctx);
}

/* The swap chain follows the client size before each present. */
void fit_target() {
    RECT r; GetClientRect(g.hwnd, &r);
    int w = std::max(1, (int)r.right), h = std::max(1, (int)r.bottom);
    if (w == g.sc_w && h == g.sc_h && g.rtv) return;
    release_target();
    g.ctx->OMSetRenderTargets(0, nullptr, nullptr);
    g.swap->ResizeBuffers(0, (UINT)w, (UINT)h, DXGI_FORMAT_UNKNOWN, 0);
    create_target();
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
    /* the back buffer through a CPU-readable copy, rows bottom-up as the BMP wants them */
    ID3D11Texture2D *back = nullptr;
    if (FAILED(g.swap->GetBuffer(0, __uuidof(ID3D11Texture2D), (void**)&back)) || !back) return;
    D3D11_TEXTURE2D_DESC d; back->GetDesc(&d);
    d.Usage = D3D11_USAGE_STAGING; d.BindFlags = 0; d.CPUAccessFlags = D3D11_CPU_ACCESS_READ; d.MiscFlags = 0;
    ID3D11Texture2D *copy = nullptr;
    if (FAILED(g.device->CreateTexture2D(&d, nullptr, &copy)) || !copy) { back->Release(); return; }
    g.ctx->CopyResource(copy, back);
    D3D11_MAPPED_SUBRESOURCE map;
    if (FAILED(g.ctx->Map(copy, 0, D3D11_MAP_READ, 0, &map))) { copy->Release(); back->Release(); return; }
    for (int row = 0; row < h; row++) {
        const unsigned char *src = (const unsigned char*)map.pData + (size_t)(y + row) * map.RowPitch + (size_t)x * 4;
        memcpy(&px[(size_t)(h - 1 - row) * w * 4], src, (size_t)w * 4);
    }
    g.ctx->Unmap(copy, 0);
    copy->Release(); back->Release();
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

/* -- Measuring with GDI ------------------------------------------------------------
 * IUP's Windows driver sizes every piece of text with GDI (iupwin_font.c): the font is
 * CreateFont(-MulDiv(pt, dpi, 72), 0, 0, 0, bold ? FW_BOLD : FW_NORMAL, italic, ...,
 * face), a line is GetTextExtentPoint32 wide, lines are tmHeight apart, and a SIZE unit
 * comes from tmAveCharWidth and tmHeight. Natural sizes, wrap points and ellipses are
 * worked out from those numbers, so this host measures with GDI too and lays out to the
 * pixel the way IUP did; ImGui only draws. */
struct GdiSize { HFONT font = nullptr; TEXTMETRICW tm = {}; };
struct GdiFont { std::wstring face; bool bold = false, italic = false; std::unordered_map<int, GdiSize> sizes; };
std::vector<GdiFont> gdi_fonts;
HDC gdi_dc = nullptr;

GdiSize *gdi_size(int id, float px) {
    if (id < 0 || id >= (int)gdi_fonts.size()) return nullptr;
    int height = (int)std::lround(px);
    if (height <= 0) return nullptr;
    GdiFont &f = gdi_fonts[(size_t)id];
    auto it = f.sizes.find(height);
    if (it != f.sizes.end()) return &it->second;
    if (!gdi_dc) gdi_dc = CreateCompatibleDC(nullptr);
    GdiSize gs;
    gs.font = CreateFontW(-height, 0, 0, 0, f.bold ? FW_BOLD : FW_NORMAL, f.italic, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_TT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY, FF_DONTCARE | DEFAULT_PITCH, f.face.c_str());
    if (!gs.font) return nullptr;
    HGDIOBJ old = SelectObject(gdi_dc, gs.font);
    GetTextMetricsW(gdi_dc, &gs.tm);
    SelectObject(gdi_dc, old);
    return &(f.sizes[height] = gs);
}

/* winFontGetTextSize: the widest line, and tmHeight per line (a last empty line after a
 * final newline does not count). With wrap > 0, DrawText's word breaking at that width. */
bool gdi_text_size(int id, float px, const char *s, size_t len, float wrap, float *out) {
    GdiSize *gs = gdi_size(id, px);
    if (!gs) return false;
    HGDIOBJ old = SelectObject(gdi_dc, gs->font);
    std::wstring w;
    if (len) {
        int n = MultiByteToWideChar(CP_UTF8, 0, s, (int)len, nullptr, 0);
        w.resize((size_t)n);
        MultiByteToWideChar(CP_UTF8, 0, s, (int)len, &w[0], n);
    }
    if (wrap > 0 && !w.empty()) {
        RECT rc = {0, 0, (LONG)wrap, 0};
        DrawTextW(gdi_dc, w.c_str(), (int)w.size(), &rc, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX | DT_EXPANDTABS);
        out[0] = (float)(rc.right - rc.left); out[1] = (float)(rc.bottom - rc.top);
        SelectObject(gdi_dc, old);
        return true;
    }
    LONG max_w = 0; int lines = 1;
    size_t start = 0;
    for (size_t i = 0; i <= w.size(); i++) {
        if (i == w.size() || w[i] == L'\n') {
            size_t end = i;
            if (end > start && w[end - 1] == L'\r') end--;
            if (end > start) {
                SIZE sz = {0, 0};
                GetTextExtentPoint32W(gdi_dc, w.c_str() + start, (int)(end - start), &sz);
                if (sz.cx > max_w) max_w = sz.cx;
            }
            if (i < w.size() && i + 1 < w.size()) lines++;
            start = i + 1;
        }
    }
    SelectObject(gdi_dc, old);
    out[0] = (float)max_w;
    out[1] = (float)(gs->tm.tmHeight * lines);
    return true;
}

/* Where GDI puts each character of a line (GetTextExtentExPoint's cumulative extents),
 * so glyphs are drawn exactly where the measurements say they are: a run of text that
 * Lua placed by measuring continues without a gap, and an ellipsis lands where IUP's
 * did. Cached per font, size and string. */
struct GdiLine { std::vector<uint32_t> cps; std::vector<float> xs; };
std::unordered_map<std::string, GdiLine> gdi_lines;

const GdiLine *gdi_line(int id, float px, const char *s, size_t len) {
    GdiSize *gs = gdi_size(id, px);
    if (!gs) return nullptr;
    std::string key;
    key.reserve(len + 16);
    key.append((const char*)&id, sizeof(id));
    int height = (int)std::lround(px);
    key.append((const char*)&height, sizeof(height));
    key.append(s, len);
    auto hit = gdi_lines.find(key);
    if (hit != gdi_lines.end()) return &hit->second;
    if (gdi_lines.size() > 16384) gdi_lines.clear();
    GdiLine line;
    std::wstring w;
    std::vector<int> start16;
    const char *p = s, *end = s + len;
    while (p < end) {
        unsigned int c = 0;
        int n = ImTextCharFromUtf8(&c, p, end);
        if (n <= 0) { n = 1; c = 0xFFFD; }
        p += n;
        line.cps.push_back(c);
        start16.push_back((int)w.size());
        if (c >= 0x10000) { c -= 0x10000; w += (wchar_t)(0xD800 + (c >> 10)); w += (wchar_t)(0xDC00 + (c & 0x3FF)); }
        else w += (wchar_t)c;
    }
    std::vector<int> dx(w.size() + 1, 0);
    if (!w.empty()) {
        HGDIOBJ old = SelectObject(gdi_dc, gs->font);
        SIZE sz;
        GetTextExtentExPointW(gdi_dc, w.c_str(), (int)w.size(), 0, nullptr, dx.data(), &sz);
        SelectObject(gdi_dc, old);
    }
    for (size_t k = 0; k < line.cps.size(); k++) line.xs.push_back(start16[k] == 0 ? 0.0f : (float)dx[(size_t)start16[k] - 1]);
    return &(gdi_lines[key] = line);
}

/* One line of text with ImGui's glyphs at GDI's positions (ImFont::RenderText's quad and
 * fine-clip code, with the pen moved by GDI instead of by the glyph's own advance). */
bool draw_text_gdi(ImDrawList *dl, int face, int gid, float px, float x, float y, ImU32 col,
                   const char *s, size_t len, const ImVec4 &fine) {
    if ((col & IM_COL32_A_MASK) == 0 || !len) return true;
    const GdiLine *line = gdi_line(gid, px, s, len);
    if (!line) return false;
    Face &f = face_of(face);
    float size = imgui_size(f, px);
    ImFontBaked *baked = f.font->GetFontBaked(size);
    if (!baked) return false;
    float scale = size / baked->Size;
    x = std::round(x); y = std::round(y + baseline_shift(f, px));
    ImVec4 clip = dl->_CmdHeader.ClipRect;
    clip.x = std::max(clip.x, fine.x); clip.y = std::max(clip.y, fine.y);
    clip.z = std::min(clip.z, fine.z); clip.w = std::min(clip.w, fine.w);
    if (clip.x >= clip.z || clip.y >= clip.w) return true;
    const ImU32 col_untinted = col | ~IM_COL32_A_MASK;
    for (size_t k = 0; k < line->cps.size(); k++) {
        unsigned int c = line->cps[k];
        if (c == '\n' || c == '\r' || c == '\t') continue;
        const ImFontGlyph *glyph = baked->FindGlyph((ImWchar)c);
        if (!glyph || !glyph->Visible) continue;
        float pen = x + line->xs[k];
        float x1 = pen + glyph->X0 * scale, x2 = pen + glyph->X1 * scale;
        float y1 = y + glyph->Y0 * scale, y2 = y + glyph->Y1 * scale;
        if (x1 > clip.z || x2 < clip.x || y1 > clip.w || y2 < clip.y) continue;
        float u1 = glyph->U0, v1 = glyph->V0, u2 = glyph->U1, v2 = glyph->V1;
        if (x1 < clip.x) { u1 = u1 + (1.0f - (x2 - clip.x) / (x2 - x1)) * (u2 - u1); x1 = clip.x; }
        if (y1 < clip.y) { v1 = v1 + (1.0f - (y2 - clip.y) / (y2 - y1)) * (v2 - v1); y1 = clip.y; }
        if (x2 > clip.z) { u2 = u1 + ((clip.z - x1) / (x2 - x1)) * (u2 - u1); x2 = clip.z; }
        if (y2 > clip.w) { v2 = v1 + ((clip.w - y1) / (y2 - y1)) * (v2 - v1); y2 = clip.w; }
        if (y1 >= y2 || x1 >= x2) continue;
        dl->PrimReserve(6, 4);
        dl->PrimRectUV(ImVec2(x1, y1), ImVec2(x2, y2), ImVec2(u1, v1), ImVec2(u2, v2), glyph->Colored ? col_untinted : col);
    }
    return true;
}

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
    DWORD style = WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, ex = WS_EX_APPWINDOW;
    int ww = w, wh = h;
    client_to_window(ww, wh, style, ex);
    RECT work, full; monitor_rects(work, full);
    if (!has_x) x = work.left + std::max(0, (int)(work.right - work.left - ww) / 2);
    if (!has_y) y = work.top + std::max(0, (int)(work.bottom - work.top - wh) / 2);
    g.hwnd = CreateWindowExW(ex, wc.lpszClassName, wide(title.c_str()).c_str(), style, x, y, ww, wh,
        nullptr, nullptr, wc.hInstance, nullptr);
    if (!g.hwnd) { lua_pushboolean(L, 0); lua_pushstring(L, "CreateWindowExW failed"); return 2; }
    WNDCLASSEXW vc = {sizeof(vc)}; vc.lpfnWndProc = video_wndproc; vc.hInstance = wc.hInstance;
    vc.hCursor = LoadCursor(nullptr, IDC_ARROW); vc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    vc.lpszClassName = VIDEO_CLASS; RegisterClassExW(&vc);
    DragAcceptFiles(g.hwnd, TRUE);
    BOOL dark = TRUE; DwmSetWindowAttribute(g.hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof(dark));
    if (g.custom_frame) SetWindowPos(g.hwnd, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    g.alive = true;
    ensure_context();
    if (!hidden) ShowWindow(g.hwnd, maximized ? SW_SHOWMAXIMIZED : SW_SHOW);
    g.ready = true;
    lua_pushboolean(L, 1);
    return 1;
}

int l_close(lua_State *L) {
    if (g.tray) { tray_apply(false); g.tray = false; }
    for (auto &v : g.video_children) {
        if (v.hwnd) DestroyWindow(v.hwnd);
        if (v.brush) DeleteObject(v.brush);
    }
    g.video_children.clear();
    if (g.paint_ref != LUA_NOREF) { luaL_unref(L, LUA_REGISTRYINDEX, g.paint_ref); g.paint_ref = LUA_NOREF; }
    for (auto &t : g.textures) if (t.second) t.second->Release();
    g.textures.clear();
    if (g.device && ImGui::GetCurrentContext()) { ImGui_ImplDX11_Shutdown(); ImGui_ImplWin32_Shutdown(); }
    release_target();
    if (g.swap) { g.swap->Release(); g.swap = nullptr; }
    if (g.ctx) { g.ctx->Release(); g.ctx = nullptr; }
    if (g.device) { g.device->Release(); g.device = nullptr; }
    if (g.hwnd) { DestroyWindow(g.hwnd); g.hwnd = nullptr; }
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
    /* true when a message woke the wait, false when it timed out */
    DWORD r = MsgWaitForMultipleObjectsEx(0, nullptr, ms, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    lua_pushboolean(L, r == WAIT_OBJECT_0);
    return 1;
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
    if (!g.hwnd || !g.device) return luaL_error(L, "frame_begin before open");
    if (!g.in_callback) {
        MSG m;
        while (PeekMessageW(&m, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&m); DispatchMessageW(&m); }
    }
    RECT r; GetClientRect(g.hwnd, &r);
    int w = r.right, h = r.bottom;
    bool minimized = IsIconic(g.hwnd) || w <= 0 || h <= 0;
    if (minimized) { w = g.last_w; h = g.last_h; } else { g.last_w = w; g.last_h = h; }
    ImGuiIO &io = ImGui::GetIO();
    ImGui_ImplDX11_NewFrame(); ImGui_ImplWin32_NewFrame();
    io.DisplaySize = ImVec2((float)std::max(w, 1), (float)std::max(h, 1));
    ImGui::NewFrame();
    g.lists.clear();
    g.lists.push_back(ImGui::GetBackgroundDrawList());
    g.lists.push_back(ImGui::GetForegroundDrawList());
    g.layer = 0;
    g.frame_open = true;

    /* This frame's input moves to the frame_* buffers, which stay valid until the next
     * frame_begin while Lua reads them through the FFI. */
    g.frame_events.swap(g.events); g.events.clear();
    g.frame_chars.swap(g.chars); g.chars.clear();
    g.frame_files.swap(g.files); g.files.clear();
    g.frame_char_ptrs.clear(); for (auto &c : g.frame_chars) g.frame_char_ptrs.push_back(c.c_str());
    g.frame_file_ptrs.clear(); for (auto &f : g.frame_files) g.frame_file_ptrs.push_back(f.c_str());
    LunarUiFrame &f = g.frame;
    f.w = w; f.h = h;
    f.scale = (float)window_dpi(g.hwnd) / 96.0f;
    f.focused = GetForegroundWindow() == g.hwnd;
    f.resized = g.resized; f.minimized = minimized; f.close_requested = g.close;
    f.inside = g.inside && g.mx >= 0;
    f.mx = (float)g.mx; f.my = (float)g.my;
    f.nevents = (int32_t)g.frame_events.size(); f.events = g.frame_events.data();
    f.nchars = (int32_t)g.frame_char_ptrs.size(); f.chars = g.frame_char_ptrs.data();
    f.nfiles = (int32_t)g.frame_file_ptrs.size(); f.files = g.frame_file_ptrs.data();

    g.keys.clear();
    g.wheel_x = g.wheel_y = 0; g.resized = false; g.close = false;
    for (int i = 0; i < 3; i++) g.pressed[i] = g.released[i] = g.dbl[i] = 0;
    lua_pushlightuserdata(L, &g.frame);
    return 1;
}

int l_frame_end(lua_State *) {
    if (!g.frame_open) return 0;
    g.frame_open = false;
    ImGui::Render();
    fit_target();
    const float black[4] = {0, 0, 0, 1};
    g.ctx->OMSetRenderTargets(1, &g.rtv, nullptr);
    g.ctx->ClearRenderTargetView(g.rtv, black);
    ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
    if (g.shot.pending) write_shot();
    /* LUNAR_VSYNC=0 presents at once (frame timing in scripts/imgui_perf.lua) */
    static int vsync = -1;
    if (vsync < 0) { char v[8] = ""; GetEnvironmentVariableA("LUNAR_VSYNC", v, sizeof(v)); vsync = v[0] == '0' ? 0 : 1; }
    g.swap->Present((UINT)vsync, 0);
    return 0;
}

int l_rect(lua_State *L) {
    draw()->AddRect(ImVec2((float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2)),
        ImVec2((float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4)), color(luaL_checknumber(L, 5)),
        (float)luaL_optnumber(L, 6, 0), (float)luaL_optnumber(L, 7, 1), (ImDrawFlags)luaL_optinteger(L, 8, 0));
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
    else draw()->AddPolyline(p.data(), (int)p.size(), c, (float)luaL_optnumber(L, 4, 1), ImDrawFlags_Closed);
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


/* The names a font file calls itself (OpenType `name` table): family (1), subfamily (2),
 * full name (4), typographic family (16) and subfamily (17). Lua maps a font a process
 * registers (ctx:registerFont) to the face names IUP font strings use. */
int l_font_names(lua_State *L) {
    std::vector<unsigned char> d;
    if (!read_file(wide(luaL_checkstring(L, 1)), d) || d.size() < 12) { lua_pushnil(L); return 1; }
    size_t base = 0;
    if (be32(&d[0]) == 0x74746366 && d.size() >= 16) base = be32(&d[12]);
    if (base + 12 > d.size()) { lua_pushnil(L); return 1; }
    uint16_t n = be16(&d[base + 4]);
    const unsigned char *name = nullptr; size_t name_len = 0;
    for (uint16_t i = 0; i < n; i++) {
        size_t rec = base + 12 + (size_t)i * 16;
        if (rec + 16 > d.size()) break;
        if (be32(&d[rec]) == 0x6E616D65) {
            uint32_t off = be32(&d[rec + 8]), len = be32(&d[rec + 12]);
            if ((size_t)off + len <= d.size()) { name = &d[off]; name_len = len; }
        }
    }
    if (!name || name_len < 6) { lua_pushnil(L); return 1; }
    uint16_t count = be16(name + 2), storage = be16(name + 4);
    lua_newtable(L);
    for (uint16_t i = 0; i < count; i++) {
        size_t r = 6 + (size_t)i * 12;
        if (r + 12 > name_len) break;
        uint16_t platform = be16(name + r), id = be16(name + r + 6), len = be16(name + r + 8), off = be16(name + r + 10);
        if (!(id == 1 || id == 2 || id == 4 || id == 16 || id == 17)) continue;
        size_t at = (size_t)storage + off;
        if (at + len > name_len) continue;
        std::string value;
        if (platform == 3 || platform == 0) {
            std::wstring w;
            for (size_t k = 0; k + 1 < len; k += 2) w += (wchar_t)((name[at + k] << 8) | name[at + k + 1]);
            value = utf8(w.c_str());
        } else if (platform == 1) {
            value.assign((const char*)name + at, len);
        } else continue;
        lua_rawgeti(L, -1, id);
        bool have = !lua_isnil(L, -1);
        lua_pop(L, 1);
        if (!have || platform == 3) { lua_pushstring(L, value.c_str()); lua_rawseti(L, -2, id); }
    }
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
    D3D11_TEXTURE2D_DESC d = {};
    d.Width = (UINT)w; d.Height = (UINT)h; d.MipLevels = 1; d.ArraySize = 1;
    d.Format = DXGI_FORMAT_R8G8B8A8_UNORM; d.SampleDesc.Count = 1;
    d.Usage = D3D11_USAGE_DEFAULT; d.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA init = {}; init.pSysMem = p; init.SysMemPitch = (UINT)w * 4;
    ID3D11Texture2D *texture = nullptr;
    ID3D11ShaderResourceView *tex = nullptr;
    if (!g.device || FAILED(g.device->CreateTexture2D(&d, &init, &texture)) || !texture) { lua_pushnil(L); return 1; }
    HRESULT hr = g.device->CreateShaderResourceView(texture, nullptr, &tex);
    texture->Release();
    if (FAILED(hr) || !tex) { lua_pushnil(L); return 1; }
    int id = g.next_texture++;
    g.textures[id] = tex;
    lua_pushinteger(L, id);
    return 1;
}

int l_texture_free(lua_State *L) {
    auto it = g.textures.find((int)luaL_checkinteger(L, 1));
    if (it != g.textures.end()) { if (it->second) it->second->Release(); g.textures.erase(it); }
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
    if (is("tray")) {
        bool on = lua_toboolean(L, 2) != 0;
        if (on && !g.tray) tray_apply(true);
        else if (!on && g.tray) { tray_apply(false); g.tray = false; }
        return 0;
    }
    if (is("traytip")) {
        g.tray_tip = luaL_optstring(L, 2, "");
        if (g.tray) tray_apply(true);
        return 0;
    }
    if (is("tray_image")) { g.tray_icon = luaL_optstring(L, 2, ""); return 0; }
    if (is("tray_balloon_title")) { g.tray_title = luaL_optstring(L, 2, ""); return 0; }
    if (is("tray_balloon_icon")) return 0;
    if (is("tray_balloon")) {
        g.tray_balloon = (int)luaL_optinteger(L, 2, 0);
        if (g.tray_balloon > 0) tray_balloon();
        return 0;
    }
    if (is("videohost_frame")) { video_frame_reset(); return 0; }
    if (is("videohost_create")) {
        VideoChild child;
        child.hwnd = CreateWindowExW(0, VIDEO_CLASS, L"", WS_CHILD | WS_CLIPSIBLINGS,
            0, 0, 0, 0, h, nullptr, GetModuleHandleW(nullptr), nullptr);
        if (!child.hwnd) { lua_pushinteger(L, 0); return 1; }
        child.brush = CreateSolidBrush(rgb(luaL_optstring(L, 2, "0 0 0")));
        SetWindowLongPtrW(child.hwnd, GWLP_USERDATA, (LONG_PTR)child.brush);
        EnableWindow(child.hwnd, FALSE);
        g.video_children.push_back(child);
        lua_pushnumber(L, (lua_Number)(uintptr_t)child.hwnd); return 1;
    }
    if (is("videohost_destroy")) {
        HWND child = (HWND)(uintptr_t)luaL_checknumber(L, 2);
        for (auto it = g.video_children.begin(); it != g.video_children.end(); ++it) {
            if (it->hwnd == child) {
                DestroyWindow(it->hwnd); if (it->brush) DeleteObject(it->brush);
                g.video_children.erase(it); break;
            }
        }
        return 0;
    }
    if (is("videohost")) {
        HWND child = (HWND)(uintptr_t)luaL_checknumber(L, 2);
        Rect r = rect_field(L, 3, nullptr); bool visible = lua_toboolean(L, 4) != 0;
        for (auto &v : g.video_children) if (v.hwnd == child) {
            SetWindowPos(child, HWND_TOP, r.x, r.y, std::max(0, r.w), std::max(0, r.h),
                SWP_NOACTIVATE | SWP_NOOWNERZORDER);
            ShowWindow(child, visible ? SW_SHOW : SW_HIDE);
            break;
        }
        return 0;
    }
    if (is("show")) { if (!IsWindowVisible(h)) ShowWindow(h, SW_SHOW); return 0; }
    if (is("hide")) { video_frame_reset(); ShowWindow(h, SW_HIDE); return 0; }
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

} // namespace

/* -- FFI --------------------------------------------------------------------------
 * The per-primitive calls, for LuaJIT's FFI (core.imgui.backend.Native declares them).
 * Scalars only: LuaJIT compiles calls with scalar arguments into its traces, and would
 * fall back to the interpreter for ImVec2 passed by value, which is why the hot path
 * does not call cimgui's ImDrawList_* directly. None of these pumps messages, so none
 * can re-enter Lua (which a function called through the FFI must never do). */
#define LUNAR_FFI extern "C" __declspec(dllexport)

LUNAR_FFI ImDrawList *lunar_ui_draw_list(int layer) {
    if (!g.frame_open || g.lists.empty()) return scratch_list();
    return g.lists[(size_t)((layer == 1 && g.lists.size() > 1) ? 1 : 0)];
}
LUNAR_FFI void lunar_ui_rect(ImDrawList *dl, float x1, float y1, float x2, float y2, uint32_t col, float rounding, float thick, int flags) {
    dl->AddRect(ImVec2(x1, y1), ImVec2(x2, y2), col, rounding, thick, (ImDrawFlags)flags);
}
LUNAR_FFI void lunar_ui_rect_filled(ImDrawList *dl, float x1, float y1, float x2, float y2, uint32_t col, float rounding, int flags) {
    dl->AddRectFilled(ImVec2(x1, y1), ImVec2(x2, y2), col, rounding, (ImDrawFlags)flags);
}
LUNAR_FFI void lunar_ui_rect_gradient(ImDrawList *dl, float x1, float y1, float x2, float y2, uint32_t a, uint32_t b, uint32_t c, uint32_t d) {
    dl->AddRectFilledMultiColor(ImVec2(x1, y1), ImVec2(x2, y2), a, b, c, d);
}
LUNAR_FFI void lunar_ui_line(ImDrawList *dl, float x1, float y1, float x2, float y2, uint32_t col, float thick) {
    dl->AddLine(ImVec2(x1, y1), ImVec2(x2, y2), col, thick);
}
LUNAR_FFI void lunar_ui_circle(ImDrawList *dl, float cx, float cy, float r, uint32_t col, float thick, int segments) {
    if (thick <= 0) dl->AddCircleFilled(ImVec2(cx, cy), r, col, segments);
    else dl->AddCircle(ImVec2(cx, cy), r, col, segments, thick);
}
LUNAR_FFI void lunar_ui_poly(ImDrawList *dl, const float *xy, int n, uint32_t col, int filled, float thick) {
    if (n < 2) return;
    const ImVec2 *p = (const ImVec2*)xy;   /* ImVec2 is two packed floats */
    if (filled) dl->AddConvexPolyFilled(p, n, col);
    else dl->AddPolyline(p, n, col, thick, ImDrawFlags_Closed);
}
LUNAR_FFI void lunar_ui_text(ImDrawList *dl, int face, float px, float x, float y, uint32_t col, const char *s, size_t len,
                             float wrap, float cx1, float cy1, float cx2, float cy2, int gid) {
    Face &f = face_of(face);
    ImVec4 clip(cx1, cy1, cx2, cy2);
    /* one line at GDI's character positions when the font has a GDI twin */
    if (gid >= 0 && wrap <= 0 && draw_text_gdi(dl, face, gid, px, x, y, col, s, len, clip)) return;
    y += baseline_shift(f, px);
    dl->AddText(f.font, imgui_size(f, px), ImVec2(std::round(x), std::round(y)), col, s, s + len, wrap, &clip);
}
/* out[0] width, out[1] height with lines tmHeight apart, as GDI lays them out */
LUNAR_FFI void lunar_ui_text_size(int face, float px, const char *s, size_t len, float wrap, float *out) {
    Face &f = face_of(face);
    ImVec2 v = f.font->CalcTextSizeA(imgui_size(f, px), FLT_MAX, wrap, s, s + len);
    int lines = 1; for (size_t i = 0; i < len; i++) if (s[i] == '\n') lines++;
    float line = f.metrics ? std::round(px * f.win_asc / f.upm) + std::round(px * f.win_desc / f.upm) : v.y / lines;
    out[0] = v.x;
    out[1] = line * (v.y / std::max(1.0f, imgui_size(f, px)));
}
LUNAR_FFI int lunar_ui_image(ImDrawList *dl, int tex, float x1, float y1, float x2, float y2,
                             float u1, float v1, float u2, float v2, uint32_t col) {
    auto it = g.textures.find(tex);
    if (it == g.textures.end()) return 0;
    dl->AddImage(ImTextureRef((ImTextureID)(intptr_t)it->second), ImVec2(x1, y1), ImVec2(x2, y2), ImVec2(u1, v1), ImVec2(u2, v2), col);
    return 1;
}
LUNAR_FFI void lunar_ui_clip_push(ImDrawList *dl, float x1, float y1, float x2, float y2) {
    dl->PushClipRect(ImVec2(x1, y1), ImVec2(x2, y2), true);
}
LUNAR_FFI void lunar_ui_clip_pop(ImDrawList *dl) { if (dl->_ClipRectStack.Size > 1) dl->PopClipRect(); }
/* GDI's size of a string (see gdi_text_size); returns 0 when the font cannot be made. */
LUNAR_FFI int lunar_ui_gdi_text_size(int id, float px, const char *s, size_t len, float wrap, float *out) {
    return gdi_text_size(id, px, s, len, wrap, out) ? 1 : 0;
}
/* The ImFont behind a face, for extensions that draw with cimgui directly. */
LUNAR_FFI ImFont *lunar_ui_face_font(int face) { return face_of(face).font; }
/* Struct sizes, so the Lua side can refuse a cdef that does not match this build. */
LUNAR_FFI int lunar_ui_sizeof(int which) {
    switch (which) {
    case 0: return (int)sizeof(LunarUiEvent);
    case 1: return (int)sizeof(LunarUiFrame);
    case 2: return (int)sizeof(ImGuiIO);
    case 3: return (int)sizeof(ImDrawList);
    case 4: return (int)sizeof(ImFont);
    case 5: return (int)sizeof(ImGuiStyle);
    }
    return -1;
}

namespace {

int l_gdi_font(lua_State *L) {
    std::wstring face = wide(luaL_checkstring(L, 1));
    bool bold = lua_toboolean(L, 2) != 0, italic = lua_toboolean(L, 3) != 0;
    for (size_t i = 0; i < gdi_fonts.size(); i++)
        if (gdi_fonts[i].face == face && gdi_fonts[i].bold == bold && gdi_fonts[i].italic == italic) {
            lua_pushinteger(L, (lua_Integer)i); return 1;
        }
    GdiFont f; f.face = face; f.bold = bold; f.italic = italic;
    gdi_fonts.push_back(f);
    lua_pushinteger(L, (lua_Integer)gdi_fonts.size() - 1);
    return 1;
}

/* tmAscent, tmDescent, tmHeight, tmAveCharWidth: what IUP's charsize and baselines use */
int l_gdi_metrics(lua_State *L) {
    GdiSize *gs = gdi_size((int)luaL_checkinteger(L, 1), (float)luaL_checknumber(L, 2));
    if (!gs) return 0;
    lua_pushnumber(L, gs->tm.tmAscent); lua_pushnumber(L, gs->tm.tmDescent);
    lua_pushnumber(L, gs->tm.tmHeight); lua_pushnumber(L, gs->tm.tmAveCharWidth);
    return 4;
}

int l_gdi_text_size(lua_State *L) {
    size_t len; const char *s = luaL_checklstring(L, 3, &len);
    float out[2];
    if (!gdi_text_size((int)luaL_checkinteger(L, 1), (float)luaL_checknumber(L, 2), s, len, (float)luaL_optnumber(L, 4, 0), out)) return 0;
    lua_pushnumber(L, out[0]); lua_pushnumber(L, out[1]);
    return 2;
}

/* A font file this process uses (ctx:registerFont): GDI must know it to measure it. */
int l_font_private(lua_State *L) {
    lua_pushboolean(L, AddFontResourceExW(wide(luaL_checkstring(L, 1)).c_str(), FR_PRIVATE, nullptr) > 0);
    return 1;
}

const luaL_Reg api[] = {
    {"open", l_open}, {"close", l_close}, {"alive", l_alive}, {"now", l_now}, {"wait", l_wait},
    {"set_paint_callback", l_set_paint_callback},
    {"frame_begin", l_frame_begin}, {"frame_end", l_frame_end},
    {"rect", l_rect}, {"rect_filled", l_rect_filled}, {"rect_gradient", l_rect_gradient},
    {"line", l_line}, {"circle", l_circle}, {"poly", l_poly},
    {"text", l_text}, {"text_size", l_text_size}, {"font_metrics", l_font_metrics},
    {"font_load", l_font_load}, {"font_find", l_font_find}, {"font_names", l_font_names},
    {"texture", l_texture}, {"texture_free", l_texture_free}, {"image", l_image},
    {"clip_push", l_clip_push}, {"clip_pop", l_clip_pop}, {"layer", l_layer},
    {"cursor", l_cursor}, {"clipboard_get", l_clipboard_get}, {"clipboard_set", l_clipboard_set},
    {"cursor_pos", l_cursor_pos}, {"window", l_window}, {"screenshot", l_screenshot},
    {"file_dialog", l_file_dialog}, {"message_box", l_message_box},
    {"gdi_font", l_gdi_font}, {"gdi_metrics", l_gdi_metrics}, {"gdi_text_size", l_gdi_text_size},
    {"font_private", l_font_private},
    {nullptr, nullptr}};

} // namespace

extern "C" int luaopen_lunarimgui(lua_State *L) {
    ensure_imgui();
    lua_newtable(L);
    luaL_register(L, nullptr, api);
    return 1;
}

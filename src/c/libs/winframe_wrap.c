/* Window frame for the main dialog on Windows 11: our bar in place of the caption.
 *
 * A window subclass, so IUP needs no patch and detaching gives the system frame back.
 * WM_NCCALCSIZE gives the caption's height to the client area and leaves the side and
 * bottom frames alone, so DWM keeps the shadow, the rounded corners and Snap. IUP reads
 * the real client rect when it lays out, so it needs telling nothing.
 *
 * WM_NCHITTEST says what the top of the client area is: the top edge resizes, the three
 * buttons are the system's own hit codes (HTMAXBUTTON is what opens Snap Layouts), and
 * anything the mouse reaches that no child window took is caption. Static labels return
 * HTTRANSPARENT, so text in the bar drags the window; flat controls keep their clicks.
 *
 * The buttons are painted here, on the dialog's own surface, because a child window over
 * them would take the hit test Windows needs to see. The bar leaves room for them
 * (winframe.reserved) and Lua supplies the theme's colours.
 *
 * Lua: winframe.supported()              true on Windows 11 and later, outside high contrast
 *      winframe.attach(dialog)           true once the frame is ours
 *      winframe.caption(dialog, height)  the bar's height, in pixels
 *      winframe.colors(dialog, bg, fg, muted, hover, press)  COLORREFs
 *      winframe.reserved(dialog)         the width the buttons take, in pixels
 */
#include <lua.h>
#include <lauxlib.h>
#include <iup.h>
#include <iuplua.h>
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <stdlib.h>

#define BUTTON_W 46
#define RESIZE_EDGE 5
#define NONE (-1)
#define FRAME_PROP L"LunarWinFrame"
#define CLOSE_BUTTON 2
#define CLOSE_RED RGB(196, 43, 28)
#define CLOSE_RED_PRESS RGB(180, 39, 26)

typedef struct {
    int caption;                     /* bar height in client pixels; 0 until Lua says */
    int hover, press;
    int active;
    int tracking;
    int released;                    /* high contrast came on: the system's frame again */
    COLORREF bg, fg, muted, hover_bg, press_bg;
    HFONT font;
    UINT font_dpi;
} Frame;

/* The Windows 8.1 and 10 entry points, looked up: mingw headers vary by target version. */
static UINT frame_dpi(HWND hwnd)
{
    typedef UINT (WINAPI *GetDpiForWindow_t)(HWND);
    static GetDpiForWindow_t get_dpi = NULL;
    static int looked = 0;
    if (!looked) {
        looked = 1;
        get_dpi = (GetDpiForWindow_t)GetProcAddress(GetModuleHandleA("user32.dll"), "GetDpiForWindow");
    }
    UINT dpi = get_dpi ? get_dpi(hwnd) : 96;
    return dpi ? dpi : 96;
}

static int scaled(HWND hwnd, int px) { return MulDiv(px, (int)frame_dpi(hwnd), 96); }

static int frame_thickness(HWND hwnd)
{
    typedef int (WINAPI *GetSystemMetricsForDpi_t)(int, UINT);
    GetSystemMetricsForDpi_t metric = (GetSystemMetricsForDpi_t)GetProcAddress(
        GetModuleHandleA("user32.dll"), "GetSystemMetricsForDpi");
    UINT dpi = frame_dpi(hwnd);
    if (!metric) return GetSystemMetrics(SM_CYFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER);
    return metric(SM_CYFRAME, dpi) + metric(SM_CXPADDEDBORDER, dpi);
}

static RECT button_rect(HWND hwnd, const Frame *fr, int index)
{
    RECT client, rc;
    int width = scaled(hwnd, BUTTON_W);
    GetClientRect(hwnd, &client);
    rc.top = 0;
    rc.bottom = fr->caption;
    rc.right = client.right - (CLOSE_BUTTON - index) * width;
    rc.left = rc.right - width;
    return rc;
}

static int button_at(HWND hwnd, const Frame *fr, POINT pt)
{
    int i;
    for (i = 0; i <= CLOSE_BUTTON; i++) {
        RECT rc = button_rect(hwnd, fr, i);
        if (PtInRect(&rc, pt)) return i;
    }
    return NONE;
}

static HFONT glyph_font(HWND hwnd, Frame *fr)
{
    UINT dpi = frame_dpi(hwnd);
    if (fr->font && fr->font_dpi == dpi) return fr->font;
    if (fr->font) DeleteObject(fr->font);
    fr->font_dpi = dpi;
    fr->font = CreateFontW(-MulDiv(10, (int)dpi, 96), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH,
        L"Segoe Fluent Icons");
    return fr->font;
}

static void draw_one(HWND hwnd, Frame *fr, HDC dc, int index, RECT rc)
{
    static const wchar_t MAXIMIZE = 0xE922, RESTORE = 0xE923, CLOSE = 0xE8BB;
    wchar_t glyph = index == CLOSE_BUTTON ? CLOSE : (IsZoomed(hwnd) ? RESTORE : MAXIMIZE);
    int hot = fr->hover == index, down = hot && fr->press == index;
    COLORREF bg = fr->bg, fg = fr->active ? fr->fg : fr->muted;
    if (hot && index == CLOSE_BUTTON) {
        bg = down ? CLOSE_RED_PRESS : CLOSE_RED;
        fg = RGB(255, 255, 255);
    } else if (hot) {
        bg = down ? fr->press_bg : fr->hover_bg;
    }
    HBRUSH brush = CreateSolidBrush(bg);
    FillRect(dc, &rc, brush);
    DeleteObject(brush);
    if (index == 0) {
        /* One pixel high, which antialiasing the font's own dash loses altogether. */
        int width = scaled(hwnd, 10), thick = scaled(hwnd, 1);
        RECT bar;
        bar.left = rc.left + (rc.right - rc.left - width) / 2;
        bar.right = bar.left + width;
        bar.top = rc.top + (rc.bottom - rc.top - thick) / 2;
        bar.bottom = bar.top + thick;
        brush = CreateSolidBrush(fg);
        FillRect(dc, &bar, brush);
        DeleteObject(brush);
        return;
    }
    HGDIOBJ old = SelectObject(dc, glyph_font(hwnd, fr));
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, fg);
    DrawTextW(dc, &glyph, 1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    SelectObject(dc, old);
}

/* Through a memory DC: hover changes draw straight to the window with no erase between. */
static void draw_buttons(HWND hwnd, Frame *fr, HDC target)
{
    if (fr->caption <= 0) return;
    RECT first = button_rect(hwnd, fr, 0), last = button_rect(hwnd, fr, CLOSE_BUTTON);
    int w = last.right - first.left, h = fr->caption, i;
    HDC mem = CreateCompatibleDC(target);
    HBITMAP bmp = CreateCompatibleBitmap(target, w, h);
    HGDIOBJ old = SelectObject(mem, bmp);
    for (i = 0; i <= CLOSE_BUTTON; i++) {
        RECT rc = button_rect(hwnd, fr, i);
        OffsetRect(&rc, -first.left, 0);
        draw_one(hwnd, fr, mem, i, rc);
    }
    BitBlt(target, first.left, 0, w, h, mem, 0, 0, SRCCOPY);
    SelectObject(mem, old);
    DeleteObject(bmp);
    DeleteDC(mem);
}

static void repaint_buttons(HWND hwnd, Frame *fr)
{
    HDC dc = GetDC(hwnd);
    if (!dc) return;
    draw_buttons(hwnd, fr, dc);
    ReleaseDC(hwnd, dc);
}

static void set_hover(HWND hwnd, Frame *fr, int hover)
{
    if (fr->hover == hover) return;
    fr->hover = hover;
    repaint_buttons(hwnd, fr);
}

static LRESULT hit_test(HWND hwnd, Frame *fr, LPARAM lp, WPARAM wp)
{
    LRESULT def = DefSubclassProc(hwnd, WM_NCHITTEST, wp, lp);
    POINT pt;
    if (def != HTCLIENT) return def;
    pt.x = GET_X_LPARAM(lp);
    pt.y = GET_Y_LPARAM(lp);
    ScreenToClient(hwnd, &pt);
    if (!IsZoomed(hwnd) && pt.y < scaled(hwnd, RESIZE_EDGE)) return HTTOP;
    if (pt.y >= fr->caption) return def;
    switch (button_at(hwnd, fr, pt)) {
    case 0: return HTMINBUTTON;
    case 1: return HTMAXBUTTON;
    case CLOSE_BUTTON: return HTCLOSE;
    default: return HTCAPTION;
    }
}

static int code_button(WPARAM code)
{
    return code == HTMINBUTTON ? 0 : code == HTMAXBUTTON ? 1 : code == HTCLOSE ? CLOSE_BUTTON : NONE;
}

static int high_contrast_on(void)
{
    HIGHCONTRASTW contrast;
    contrast.cbSize = sizeof(contrast);
    contrast.dwFlags = 0;
    SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0);
    return (contrast.dwFlags & HCF_HIGHCONTRASTON) != 0;
}

static LRESULT CALLBACK frame_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR id, DWORD_PTR data)
{
    Frame *fr = (Frame *)data;
    if (msg == WM_SETTINGCHANGE && wp == SPI_SETHIGHCONTRAST) {
        int released = high_contrast_on();
        if (released != fr->released) {
            fr->released = released;
            SetWindowPos(hwnd, NULL, 0, 0, 0, 0,
                SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
            RedrawWindow(hwnd, NULL, NULL, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN);
        }
    }
    if (fr->released && msg != WM_NCDESTROY) return DefSubclassProc(hwnd, msg, wp, lp);
    switch (msg) {
    case WM_NCCALCSIZE:
        if (wp) {
            NCCALCSIZE_PARAMS *params = (NCCALCSIZE_PARAMS *)lp;
            LONG top = params->rgrc[0].top;
            LRESULT result = DefSubclassProc(hwnd, msg, wp, lp);
            /* A maximized window hangs past the monitor by its frame. */
            params->rgrc[0].top = top + (IsZoomed(hwnd) ? frame_thickness(hwnd) : 0);
            return result;
        }
        break;
    case WM_NCHITTEST:
        return fr->caption > 0 ? hit_test(hwnd, fr, lp, wp) : DefSubclassProc(hwnd, msg, wp, lp);
    case WM_NCMOUSEMOVE: {
        int hover = code_button(wp);
        if (!fr->tracking) {
            TRACKMOUSEEVENT track = { sizeof(track), TME_LEAVE | TME_NONCLIENT, hwnd, 0 };
            TrackMouseEvent(&track);
            fr->tracking = 1;
        }
        if (hover != fr->hover && fr->press != NONE && hover != fr->press) hover = NONE;
        set_hover(hwnd, fr, hover);
        break;                       /* still DefWindowProc's: Snap Layouts hangs off it */
    }
    case WM_NCMOUSELEAVE:
        fr->tracking = 0;
        fr->press = NONE;
        set_hover(hwnd, fr, NONE);
        break;
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONDBLCLK: {
        int index = code_button(wp);
        if (index != NONE) {
            fr->press = index;
            fr->hover = index;
            repaint_buttons(hwnd, fr);
            return 0;
        }
        break;
    }
    case WM_NCLBUTTONUP: {
        int index = code_button(wp), pressed = fr->press;
        if (pressed != NONE) {
            fr->press = NONE;
            repaint_buttons(hwnd, fr);
            if (index == pressed) {
                WPARAM command = index == 0 ? SC_MINIMIZE : index == CLOSE_BUTTON ? SC_CLOSE
                    : (IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE);
                PostMessageW(hwnd, WM_SYSCOMMAND, command, lp);
            }
            return 0;
        }
        break;
    }
    case WM_ACTIVATE: {
        /* The palette and other owned popups take activation, but the user is still here. */
        HWND other = (HWND)lp;
        int active = LOWORD(wp) != WA_INACTIVE || (other && GetAncestor(other, GA_ROOTOWNER) == hwnd);
        if (active != fr->active) {
            fr->active = active;
            repaint_buttons(hwnd, fr);
        }
        break;
    }
    case WM_ERASEBKGND: {
        LRESULT result = DefSubclassProc(hwnd, msg, wp, lp);
        draw_buttons(hwnd, fr, (HDC)wp);
        return result;
    }
    case WM_SIZE: {
        LRESULT result = DefSubclassProc(hwnd, msg, wp, lp);
        /* The buttons sit against the right edge, so a resize moves them. */
        RedrawWindow(hwnd, NULL, NULL, RDW_INVALIDATE | RDW_ERASE);
        return result;
    }
    case WM_NCDESTROY:
        RemoveWindowSubclass(hwnd, frame_proc, id);
        RemovePropW(hwnd, FRAME_PROP);
        if (fr->font) DeleteObject(fr->font);
        free(fr);
        break;
    }
    return DefSubclassProc(hwnd, msg, wp, lp);
}

static HWND dialog_hwnd(lua_State *L, int pos)
{
    Ihandle *ih = iuplua_checkihandle(L, pos);
    Ihandle *dlg = ih ? IupGetDialog(ih) : NULL;
    return dlg ? (HWND)IupGetAttribute(dlg, "HWND") : NULL;
}

static Frame *frame_of(HWND hwnd)
{
    return hwnd ? (Frame *)GetPropW(hwnd, FRAME_PROP) : NULL;
}

static int l_supported(lua_State *L)
{
    typedef LONG (WINAPI *RtlGetVersion_t)(OSVERSIONINFOW *);
    RtlGetVersion_t get = (RtlGetVersion_t)GetProcAddress(GetModuleHandleA("ntdll.dll"), "RtlGetVersion");
    OSVERSIONINFOW info;
    info.dwOSVersionInfoSize = sizeof(info);
    /* High contrast is the system's frame or nothing: ours wouldn't follow the user's colours. */
    lua_pushboolean(L, get && get(&info) == 0 && info.dwBuildNumber >= 22000 && !high_contrast_on());
    return 1;
}

static int l_attach(lua_State *L)
{
    HWND hwnd = dialog_hwnd(L, 1);
    if (!hwnd) { lua_pushboolean(L, 0); return 1; }
    if (!frame_of(hwnd)) {
        Frame *fr = calloc(1, sizeof(Frame));
        if (!fr) { lua_pushboolean(L, 0); return 1; }
        fr->hover = fr->press = NONE;
        fr->active = 1;
        fr->bg = RGB(0, 0, 0);
        fr->fg = fr->muted = RGB(255, 255, 255);
        fr->hover_bg = fr->press_bg = RGB(64, 64, 64);
        if (!SetWindowSubclass(hwnd, frame_proc, 1, (DWORD_PTR)fr)) {
            free(fr);
            lua_pushboolean(L, 0);
            return 1;
        }
        SetPropW(hwnd, FRAME_PROP, fr);
        SetWindowPos(hwnd, NULL, 0, 0, 0, 0,
            SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_caption(lua_State *L)
{
    HWND hwnd = dialog_hwnd(L, 1);
    Frame *fr = frame_of(hwnd);
    if (fr) {
        fr->caption = (int)luaL_checkinteger(L, 2);
        repaint_buttons(hwnd, fr);
    }
    return 0;
}

static int l_colors(lua_State *L)
{
    HWND hwnd = dialog_hwnd(L, 1);
    Frame *fr = frame_of(hwnd);
    if (fr) {
        fr->bg = (COLORREF)luaL_checkinteger(L, 2);
        fr->fg = (COLORREF)luaL_checkinteger(L, 3);
        fr->muted = (COLORREF)luaL_checkinteger(L, 4);
        fr->hover_bg = (COLORREF)luaL_checkinteger(L, 5);
        fr->press_bg = (COLORREF)luaL_checkinteger(L, 6);
        repaint_buttons(hwnd, fr);
    }
    return 0;
}

static int l_reserved(lua_State *L)
{
    HWND hwnd = dialog_hwnd(L, 1);
    Frame *fr = frame_of(hwnd);
    lua_pushinteger(L, fr && !fr->released ? scaled(hwnd, BUTTON_W) * 3 : 0);
    return 1;
}

static const luaL_Reg winframe_lib[] = {
    { "supported", l_supported },
    { "attach",    l_attach    },
    { "caption",   l_caption   },
    { "colors",    l_colors    },
    { "reserved",  l_reserved  },
    { NULL,        NULL        }
};

int luaopen_winframe(lua_State *L)
{
    luaL_newlib(L, winframe_lib);
    return 1;
}

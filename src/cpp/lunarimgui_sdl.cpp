// Linux native backend. The Lua/FFI ABI is shared with the Windows backend;
// SDL supplies input and windows, OpenGL3 renders the same owned draw lists.
#include <SDL3/SDL.h>
#include <SDL3/SDL_opengl.h>
#include <fontconfig/fontconfig.h>
#include "imgui.h"
#include "imgui_internal.h"
#include "backends/imgui_impl_sdl3.h"
#include "backends/imgui_impl_opengl3.h"
#include "lunarimgui_abi.h"
extern "C" {
#include <lua.h>
#include <lauxlib.h>
}
#include <algorithm>
#include <cmath>
#include <cfloat>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cctype>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace {
struct Window {
    int id = 0, x = 0, y = 0, w = 1, h = 1;
    SDL_Window *native = nullptr;
    SDL_GLContext context = nullptr;
    ImDrawList *lists[2] = {};
    bool visible = false, close = false, drawn = false, positioned = false;
};
struct Texture { GLuint gl; int refs = 1; };
struct State {
    Window main;
    std::vector<std::unique_ptr<Window>> windows;
    std::vector<ImFont*> fonts;
    std::unordered_map<std::string, int> font_ids;
    std::unordered_map<int, Texture> textures;
    std::vector<GLuint> retired_textures;
    std::vector<LunarUiEvent> pending, events;
    std::vector<std::string> chars, files, frame_chars, frame_files;
    std::vector<const char*> char_ptrs, file_ptrs;
    LunarUiFrame frame = {};
    float mx = -1, my = -1;
    bool down[3] = {}, inside = false, open = false, frame_open = false, wayland = false;
    int next_window = 1, next_texture = 1, layer = 0, surface = 0, pointer_window = 0;
    int caption = 0;
    std::vector<SDL_Rect> nodrag;
    SDL_Cursor *cursor = nullptr;
    ImDrawList *scratch = nullptr;
    std::string shot;
    int shot_window = 0;
} g;

Window *window(int id) {
    if (id == 0) return &g.main;
    for (auto &w : g.windows) if (w->id == id) return w.get();
    return nullptr;
}
Window *from_sdl(SDL_WindowID id) {
    if (g.main.native && SDL_GetWindowID(g.main.native) == id) return &g.main;
    for (auto &w : g.windows) if (SDL_GetWindowID(w->native) == id) return w.get();
    return nullptr;
}
float density(Window *w) { float s = SDL_GetWindowPixelDensity(w->native); return s > 0 ? s : 1; }
float ui_scale(Window *w) { float s=w->native?SDL_GetWindowDisplayScale(w->native):SDL_GetDisplayContentScale(SDL_GetPrimaryDisplay());return s>0?s:1; }
void size(Window *w) { SDL_GetWindowSizeInPixels(w->native, &w->w, &w->h); }
void ensure_gui() {
    if (ImGui::GetCurrentContext()) return;
    IMGUI_CHECKVERSION(); ImGui::CreateContext();
    auto &io = ImGui::GetIO(); io.IniFilename = nullptr; io.LogFilename = nullptr;
    io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;
    io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures;
    g.fonts.push_back(io.Fonts->AddFontDefault());
}
ImFont *font(int id) { ensure_gui(); return id >= 0 && id < (int)g.fonts.size() ? g.fonts[id] : g.fonts[0]; }
ImDrawList *list(int id, int layer) {
    Window *w = window(id); if (!w) w = &g.main;
    int n = layer == 1 ? 1 : 0;
    if (!w->lists[n]) {
        w->lists[n] = IM_NEW(ImDrawList)(ImGui::GetDrawListSharedData());
        w->lists[n]->_ResetForNewFrame();
        w->lists[n]->PushTexture(ImGui::GetIO().Fonts->TexRef);
        w->lists[n]->PushClipRect(ImVec2(-32768,-32768),ImVec2(32768,32768));
    }
    return w->lists[n];
}
ImDrawList *scratch_list(){
    if(!g.scratch)g.scratch=IM_NEW(ImDrawList)(ImGui::GetDrawListSharedData());
    g.scratch->_ResetForNewFrame();g.scratch->PushClipRectFullScreen();return g.scratch;
}
void reset_list(Window *w) {
    for (int n = 0; n < 2; ++n) {
        auto dl = list(w->id, n); dl->_ResetForNewFrame();
        dl->PushTexture(ImGui::GetIO().Fonts->TexRef);
        dl->PushClipRect(ImVec2(-32768, -32768), ImVec2(32768, 32768));
    }
    w->drawn = false;
}
void destroy(Window *w) {
    for (auto &dl : w->lists) { if (dl) IM_DELETE(dl); dl = nullptr; }
    if (w->context) SDL_GL_DestroyContext(w->context);
    if (w->native) SDL_DestroyWindow(w->native);
    w->context = nullptr; w->native = nullptr;
}
int modifiers() {
    auto m = SDL_GetModState();
    return ((m & SDL_KMOD_SHIFT) ? 1 : 0) | ((m & SDL_KMOD_CTRL) ? 2 : 0)
        | ((m & SDL_KMOD_ALT) ? 4 : 0) | ((m & SDL_KMOD_GUI) ? 8 : 0)
        | (g.down[0] ? 16 : 0) | (g.down[1] ? 32 : 0) | (g.down[2] ? 64 : 0);
}
int key(SDL_Keycode k) {
    if (k >= SDLK_F1 && k <= SDLK_F12) return 0xffbe + (int)(k - SDLK_F1);
    switch (k) {
    case SDLK_ESCAPE: return 0xff1b; case SDLK_DELETE: return 0xffff;
    case SDLK_LEFT: return 0xff51; case SDLK_UP: return 0xff52;
    case SDLK_RIGHT: return 0xff53; case SDLK_DOWN: return 0xff54;
    case SDLK_HOME: return 0xff50; case SDLK_END: return 0xff57;
    case SDLK_PAGEUP: return 0xff55; case SDLK_PAGEDOWN: return 0xff56;
    case SDLK_INSERT: return 0xff63; case SDLK_TAB: return 9;
    case SDLK_RETURN: case SDLK_KP_ENTER: return 13; case SDLK_BACKSPACE: return 8;
    default: return k < 128 ? (int)k : 0;
    }
}
void emit(Window *w, int type, int button = 0, int code = 0, float dx = 0, float dy = 0) {
    g.pending.push_back({type, button, modifiers() | ((w ? w->id : 0) << 8), code, g.mx, g.my, dx, dy});
}
void process(const SDL_Event &e) {
    ImGui_ImplSDL3_ProcessEvent(&e);
    Window *w = nullptr;
    // The shared windowID is at the same offset in SDL's window/input events.
    if (e.type >= SDL_EVENT_WINDOW_FIRST && e.type <= SDL_EVENT_WINDOW_LAST) w = from_sdl(e.window.windowID);
    if (e.type == SDL_EVENT_QUIT) { g.main.close = true; return; }
    if (e.type == SDL_EVENT_WINDOW_CLOSE_REQUESTED && w) { w->close = true; return; }
    if (e.type == SDL_EVENT_WINDOW_MOUSE_LEAVE) {
        if (!g.down[0] && !g.down[1] && !g.down[2]) { g.inside = false; g.mx = g.my = -1; emit(w, 8); }
    } else if (e.type == SDL_EVENT_MOUSE_MOTION || e.type == SDL_EVENT_MOUSE_BUTTON_DOWN || e.type == SDL_EVENT_MOUSE_BUTTON_UP) {
        SDL_WindowID id = e.type == SDL_EVENT_MOUSE_MOTION ? e.motion.windowID : e.button.windowID;
        w = from_sdl(id); if (!w) return;
        float s = density(w);
        g.mx = w->x + (e.type == SDL_EVENT_MOUSE_MOTION ? e.motion.x : e.button.x) * s;
        g.my = w->y + (e.type == SDL_EVENT_MOUSE_MOTION ? e.motion.y : e.button.y) * s;
        g.inside = true; g.pointer_window = w->id;
        if (e.type == SDL_EVENT_MOUSE_MOTION) emit(w, 1);
        else {
            int b = e.button.button == SDL_BUTTON_LEFT ? 1 : e.button.button == SDL_BUTTON_MIDDLE ? 2 : e.button.button == SDL_BUTTON_RIGHT ? 3 : 0;
            if (!b) return;
            bool down = e.type == SDL_EVENT_MOUSE_BUTTON_DOWN; g.down[b-1] = down;
            emit(w, down ? 2 : 3, b + ((down && e.button.clicks == 2) ? 8 : 0));
            SDL_CaptureMouse(down);
        }
    } else if (e.type == SDL_EVENT_MOUSE_WHEEL) {
        w = from_sdl(e.wheel.windowID); float direction = e.wheel.direction == SDL_MOUSEWHEEL_FLIPPED ? -1 : 1;
        emit(w, 4, 0, 0, e.wheel.x * direction, e.wheel.y * direction);
    } else if (e.type == SDL_EVENT_KEY_DOWN || e.type == SDL_EVENT_KEY_UP) {
        w = from_sdl(e.key.windowID); int code = key(e.key.key);
        if (code) emit(w, e.type == SDL_EVENT_KEY_DOWN ? 5 : 6, 0, code);
    } else if (e.type == SDL_EVENT_TEXT_INPUT) {
        w = from_sdl(e.text.windowID);
        g.chars.emplace_back(e.text.text); emit(w, 7, 0, (int)g.chars.size()-1);
    } else if (e.type == SDL_EVENT_DROP_FILE) {
        w = from_sdl(e.drop.windowID);
        g.files.emplace_back(e.drop.data); emit(w, 9, 0, (int)g.files.size()-1);
    }
}
int field(lua_State *L, int table, const char *name, int fallback) {
    lua_getfield(L, table, name); int n = (int)luaL_optinteger(L, -1, fallback); lua_pop(L, 1); return n;
}
bool flag(lua_State *L, int table, const char *name, bool fallback = false) {
    lua_getfield(L, table, name); bool b = lua_isnil(L, -1) ? fallback : lua_toboolean(L, -1); lua_pop(L, 1); return b;
}
std::string strfield(lua_State *L, int table, const char *name, const char *fallback = "") {
    lua_getfield(L, table, name); std::string s = luaL_optstring(L, -1, fallback); lua_pop(L, 1); return s;
}
SDL_HitTestResult hit(SDL_Window *, const SDL_Point *point, void *) {
    int x = (int)(point->x * density(&g.main)), y = (int)(point->y * density(&g.main));
    int edge = 6;
    if (x < edge && y < edge) return SDL_HITTEST_RESIZE_TOPLEFT;
    if (x >= g.main.w-edge && y < edge) return SDL_HITTEST_RESIZE_TOPRIGHT;
    if (x < edge && y >= g.main.h-edge) return SDL_HITTEST_RESIZE_BOTTOMLEFT;
    if (x >= g.main.w-edge && y >= g.main.h-edge) return SDL_HITTEST_RESIZE_BOTTOMRIGHT;
    if (y < edge) return SDL_HITTEST_RESIZE_TOP;
    if (y >= g.main.h-edge) return SDL_HITTEST_RESIZE_BOTTOM;
    if (x < edge) return SDL_HITTEST_RESIZE_LEFT;
    if (x >= g.main.w-edge) return SDL_HITTEST_RESIZE_RIGHT;
    if (y < g.caption) {
        for (auto r : g.nodrag) if (x >= r.x && y >= r.y && x < r.x+r.w && y < r.y+r.h) return SDL_HITTEST_NORMAL;
        return SDL_HITTEST_DRAGGABLE;
    }
    return SDL_HITTEST_NORMAL;
}
int l_open(lua_State *L) {
    ensure_gui();
    if (g.open) { lua_pushboolean(L, true); return 1; }
    if (!SDL_Init(SDL_INIT_VIDEO)) { lua_pushnil(L); lua_pushstring(L, SDL_GetError()); return 2; }
    g.wayland = std::strcmp(SDL_GetCurrentVideoDriver(), "wayland") == 0;
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3); SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    auto title = strfield(L, 1, "title", "Lunar");
    SDL_WindowFlags flags = SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY;
    if (flag(L, 1, "hidden")) flags |= SDL_WINDOW_HIDDEN;
    if (flag(L, 1, "maximized")) flags |= SDL_WINDOW_MAXIMIZED;
    if (flag(L, 1, "borderless")) flags |= SDL_WINDOW_BORDERLESS;
    g.main.native = SDL_CreateWindow(title.c_str(), field(L,1,"w",1280), field(L,1,"h",800), flags);
    if (g.main.native) g.main.context = SDL_GL_CreateContext(g.main.native);
    if (!g.main.native || !g.main.context) { destroy(&g.main); lua_pushnil(L); lua_pushstring(L,SDL_GetError()); return 2; }
    if (!ImGui_ImplSDL3_InitForOpenGL(g.main.native, g.main.context) || !ImGui_ImplOpenGL3_Init("#version 330")) {
        destroy(&g.main); lua_pushnil(L); lua_pushliteral(L,"cannot initialise ImGui SDL/OpenGL backends"); return 2;
    }
    ImGui_ImplSDL3_SetMouseCaptureMode(ImGui_ImplSDL3_MouseCaptureMode_Disabled);
    SDL_GL_SetSwapInterval(std::getenv("LUNAR_VSYNC") && std::strcmp(std::getenv("LUNAR_VSYNC"),"0")==0 ? 0 : 1);
    SDL_StartTextInput(g.main.native);
    g.open = true; g.main.visible = true; size(&g.main);
    lua_pushboolean(L,true); return 1;
}
int l_close(lua_State *) {
    if (g.open) {
        SDL_GL_MakeCurrent(g.main.native,g.main.context);
        for (auto &t : g.textures) glDeleteTextures(1,&t.second.gl);
        for (auto t : g.retired_textures) glDeleteTextures(1,&t);
        g.retired_textures.clear();
        g.textures.clear();
        ImGui_ImplOpenGL3_Shutdown(); ImGui_ImplSDL3_Shutdown();
        for (auto &w : g.windows) destroy(w.get());
        g.windows.clear(); destroy(&g.main); g.open=false;
    }
    if (g.cursor) { SDL_DestroyCursor(g.cursor); g.cursor=nullptr; }
    if(g.scratch){IM_DELETE(g.scratch);g.scratch=nullptr;}
    if (ImGui::GetCurrentContext()) ImGui::DestroyContext();
    g.fonts.clear(); g.font_ids.clear(); g.pending.clear(); g.events.clear();
    g.chars.clear(); g.files.clear(); g.down[0]=g.down[1]=g.down[2]=false;
    g.frame_open=false; g.main.close=false; SDL_Quit(); return 0;
}
int l_alive(lua_State *L) { lua_pushboolean(L,g.open); return 1; }
int l_now(lua_State *L) { lua_pushnumber(L,SDL_GetTicksNS()/1e9); return 1; }
int l_wait(lua_State *L) {
    SDL_Event e; bool got = SDL_WaitEventTimeout(&e,(Sint32)std::min(60000.0,std::max(0.0,luaL_optnumber(L,1,0.016)*1000)));
    if (got) process(e); lua_pushboolean(L,got); return 1;
}
int l_frame_begin(lua_State *L) {
    SDL_GL_MakeCurrent(g.main.native,g.main.context);
    SDL_Event e; while (SDL_PollEvent(&e)) process(e);
    int oldw=g.main.w, oldh=g.main.h; size(&g.main);
    ImGui_ImplOpenGL3_NewFrame(); ImGui_ImplSDL3_NewFrame();
    auto &io=ImGui::GetIO(); io.DisplaySize=ImVec2((float)g.main.w,(float)g.main.h); io.DisplayFramebufferScale=ImVec2(1,1);
    ImGui::NewFrame(); reset_list(&g.main);
    for (auto &w:g.windows) reset_list(w.get());
    g.events.swap(g.pending); g.pending.clear();
    g.frame_chars.swap(g.chars);g.chars.clear();g.frame_files.swap(g.files);g.files.clear();
    g.char_ptrs.clear();for(auto &s:g.frame_chars)g.char_ptrs.push_back(s.c_str());
    g.file_ptrs.clear();for(auto &s:g.frame_files)g.file_ptrs.push_back(s.c_str());
    auto &f=g.frame;f.w=g.main.w;f.h=g.main.h;f.scale=ui_scale(&g.main);
    f.focused=SDL_GetKeyboardFocus()!=nullptr; f.resized=oldw!=f.w||oldh!=f.h;
    f.minimized=(SDL_GetWindowFlags(g.main.native)&SDL_WINDOW_MINIMIZED)!=0;f.close_requested=g.main.close;
    g.main.close=false;f.inside=g.inside;f.mx=g.mx;f.my=g.my;
    f.nevents=(int)g.events.size();f.events=g.events.data();f.nchars=(int)g.char_ptrs.size();f.chars=g.char_ptrs.data();
    f.nfiles=(int)g.file_ptrs.size();f.files=g.file_ptrs.data();
    g.frame_open=true;g.layer=g.surface=0;
    lua_pushlightuserdata(L,&f);return 1;
}
void screenshot(Window *w) {
    if(g.shot.empty()||g.shot_window!=w->id)return;
    SDL_Surface *s=SDL_CreateSurface(w->w,w->h,SDL_PIXELFORMAT_RGBA32);
    if(s){glPixelStorei(GL_PACK_ALIGNMENT,1);glReadPixels(0,0,w->w,w->h,GL_RGBA,GL_UNSIGNED_BYTE,s->pixels);
        std::vector<unsigned char> row((size_t)s->pitch);
        for(int y=0;y<s->h/2;++y){auto a=(unsigned char*)s->pixels+y*s->pitch;auto b=(unsigned char*)s->pixels+(s->h-y-1)*s->pitch;
            std::memcpy(row.data(),a,s->pitch);std::memcpy(a,b,s->pitch);std::memcpy(b,row.data(),s->pitch);}
        SDL_SaveBMP(s,g.shot.c_str());SDL_DestroySurface(s);}
    g.shot.clear();
}
void render(Window *w) {
    if(!w->visible||(SDL_GetWindowFlags(w->native)&SDL_WINDOW_MINIMIZED))return;
    SDL_GL_MakeCurrent(w->native,w->context);size(w);
    ImDrawData dd;dd.Valid=true;dd.DisplayPos=ImVec2((float)w->x,(float)w->y);
    dd.DisplaySize=ImVec2((float)w->w,(float)w->h);dd.FramebufferScale=ImVec2(1,1);
    dd.Textures=&ImGui::GetPlatformIO().Textures;
    auto append=[&](ImDrawList *dl){if(!dl)return;dl->_PopUnusedDrawCmd();for(auto &cmd:dl->CmdBuffer){cmd.ClipRect.x=std::max(cmd.ClipRect.x,(float)w->x);cmd.ClipRect.y=std::max(cmd.ClipRect.y,(float)w->y);cmd.ClipRect.z=std::min(cmd.ClipRect.z,(float)(w->x+w->w));cmd.ClipRect.w=std::min(cmd.ClipRect.w,(float)(w->y+w->h));}if(dl->CmdBuffer.Size){dd.CmdLists.push_back(dl);dd.TotalVtxCount+=dl->VtxBuffer.Size;dd.TotalIdxCount+=dl->IdxBuffer.Size;}};
    append(w->lists[0]);
    if(w->id==0)for(auto dl:ImGui::GetDrawData()->CmdLists)append(dl);
    append(w->lists[1]);
    glViewport(0,0,w->w,w->h);glClearColor(0,0,0,1);glClear(GL_COLOR_BUFFER_BIT);
    ImGui_ImplOpenGL3_RenderDrawData(&dd);screenshot(w);SDL_GL_SwapWindow(w->native);
}
int l_frame_end(lua_State *) {
    if(!g.frame_open)return 0;
    ImGui::Render();render(&g.main);for(auto &w:g.windows)if(w->drawn)render(w.get());
    SDL_GL_MakeCurrent(g.main.native,g.main.context);
    for(auto t:g.retired_textures)glDeleteTextures(1,&t);
    g.retired_textures.clear();g.frame_open=false;return 0;
}
int l_font_find(lua_State *L) {
    FcPattern *p=FcPatternCreate();
    FcPatternAddString(p,FC_FAMILY,(FcChar8*)luaL_checkstring(L,1));
    FcPatternAddInteger(p,FC_WEIGHT,lua_toboolean(L,2)?FC_WEIGHT_BOLD:FC_WEIGHT_REGULAR);
    FcPatternAddInteger(p,FC_SLANT,lua_toboolean(L,3)?FC_SLANT_ITALIC:FC_SLANT_ROMAN);
    FcConfigSubstitute(nullptr,p,FcMatchPattern);FcDefaultSubstitute(p);FcResult result;
    FcPattern *match=FcFontMatch(nullptr,p,&result);FcChar8 *path=nullptr;
    if(match&&FcPatternGetString(match,FC_FILE,0,&path)==FcResultMatch)lua_pushstring(L,(char*)path);else lua_pushnil(L);
    if(match)FcPatternDestroy(match);FcPatternDestroy(p);return 1;
}
int l_font_load(lua_State *L) {
    std::string path=luaL_checkstring(L,1);auto found=g.font_ids.find(path);
    if(found!=g.font_ids.end()){lua_pushinteger(L,found->second);return 1;}
    ensure_gui();FILE *f=std::fopen(path.c_str(),"rb");if(!f){lua_pushnil(L);return 1;}std::fclose(f);
    ImFont *face=ImGui::GetIO().Fonts->AddFontFromFileTTF(path.c_str(),13.0f);
    if(!face){lua_pushnil(L);return 1;}int id=(int)g.fonts.size();g.fonts.push_back(face);g.font_ids[path]=id;lua_pushinteger(L,id);return 1;
}
int l_font_metrics(lua_State *L) {
    auto f=font((int)luaL_checkinteger(L,1));float px=(float)luaL_checknumber(L,2);auto b=f->GetFontBaked(px);
    lua_pushnumber(L,b->Ascent);lua_pushnumber(L,-b->Descent);lua_pushnumber(L,b->Ascent-b->Descent);
    lua_pushnumber(L,f->CalcTextSizeA(px,FLT_MAX,0,"x").x);return 4;
}
int l_font_private(lua_State *L){lua_pushboolean(L,FcConfigAppFontAddFile(nullptr,(const FcChar8*)luaL_checkstring(L,1)));return 1;}
int l_font_names(lua_State *L){
    int count=0;FcPattern *p=FcFreeTypeQuery((const FcChar8*)luaL_checkstring(L,1),0,nullptr,&count);
    if(!p){lua_pushnil(L);return 1;}lua_newtable(L);
    const char *keys[]={FC_FAMILY,FC_STYLE,FC_FULLNAME};int ids[]={1,2,4};
    for(int n=0;n<3;n++){FcChar8 *s;if(FcPatternGetString(p,keys[n],0,&s)==FcResultMatch){lua_pushstring(L,(char*)s);lua_rawseti(L,-2,ids[n]);}}
    FcPatternDestroy(p);return 1;
}
int upload(const unsigned char *data,int w,int h) {
    if(!g.open||w<=0||h<=0)return 0;
    SDL_GL_MakeCurrent(g.main.native,g.main.context);
    GLuint gl;glGenTextures(1,&gl);glBindTexture(GL_TEXTURE_2D,gl);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT,1);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,w,h,0,GL_RGBA,GL_UNSIGNED_BYTE,data);
    int id=g.next_texture++;g.textures.emplace(id,Texture{gl,1});return id;
}
int l_texture(lua_State *L){size_t n;auto p=(const unsigned char*)luaL_checklstring(L,1,&n);int w=(int)luaL_checkinteger(L,2),h=(int)luaL_checkinteger(L,3);
    if(w<=0||h<=0||w>32768||h>32768||n<(size_t)w*h*4){lua_pushnil(L);return 1;}int id=upload(p,w,h);if(id)lua_pushinteger(L,id);else lua_pushnil(L);return 1;}
void free_texture(int id){auto t=g.textures.find(id);if(t!=g.textures.end()&&--t->second.refs==0){
    if(g.frame_open)g.retired_textures.push_back(t->second.gl);
    else{SDL_GL_MakeCurrent(g.main.native,g.main.context);glDeleteTextures(1,&t->second.gl);}
    g.textures.erase(t);}}
int l_texture_free(lua_State *L){free_texture((int)luaL_checkinteger(L,1));return 0;}
int l_texture_retain(lua_State *L){auto t=g.textures.find((int)luaL_checkinteger(L,1));if(t!=g.textures.end())++t->second.refs;return 0;}
int l_clipboard_get(lua_State *L){char *s=SDL_GetClipboardText();lua_pushstring(L,s?s:"");SDL_free(s);return 1;}
int l_clipboard_set(lua_State *L){SDL_SetClipboardText(luaL_checkstring(L,1));return 0;}
int l_cursor_pos(lua_State *L){
    float x=0,y=0;
    if(g.wayland){x=g.mx;y=g.my;}else SDL_GetGlobalMouseState(&x,&y);
    lua_pushnumber(L,x);lua_pushnumber(L,y);return 2;
}
int l_cursor(lua_State *L){std::string name=luaL_checkstring(L,1);for(auto &ch:name)ch=(char)std::tolower((unsigned char)ch);const char *s=name.c_str();SDL_SystemCursor c=SDL_SYSTEM_CURSOR_DEFAULT;
    if(name=="none"){SDL_HideCursor();return 0;}SDL_ShowCursor();
    if(!std::strcmp(s,"text")||name=="ibeam")c=SDL_SYSTEM_CURSOR_TEXT;
    else if(name=="hand")c=SDL_SYSTEM_CURSOR_POINTER;
    else if(name=="resize_ew"||name=="sizewe")c=SDL_SYSTEM_CURSOR_EW_RESIZE;
    else if(name=="resize_ns"||name=="sizens")c=SDL_SYSTEM_CURSOR_NS_RESIZE;
    else if(name=="resize_all"||name=="sizeall"||name=="move")c=SDL_SYSTEM_CURSOR_MOVE;
    else if(name=="sizenwse")c=SDL_SYSTEM_CURSOR_NWSE_RESIZE;
    else if(name=="sizenesw")c=SDL_SYSTEM_CURSOR_NESW_RESIZE;
    else if(name=="wait")c=SDL_SYSTEM_CURSOR_WAIT;
    else if(name=="no")c=SDL_SYSTEM_CURSOR_NOT_ALLOWED;
    else if(name=="cross")c=SDL_SYSTEM_CURSOR_CROSSHAIR;
    static SDL_SystemCursor previous=SDL_SYSTEM_CURSOR_COUNT;
    if(c!=previous){auto next=SDL_CreateSystemCursor(c);if(next){SDL_SetCursor(next);if(g.cursor)SDL_DestroyCursor(g.cursor);g.cursor=next;previous=c;}}return 0;
}
int l_renderer(lua_State *L){lua_newtable(L);lua_pushliteral(L,"opengl3");lua_setfield(L,-2,"backend");lua_pushstring(L,SDL_GetCurrentVideoDriver());lua_setfield(L,-2,"video_driver");
    if(g.open){lua_pushstring(L,(const char*)glGetString(GL_RENDERER));lua_setfield(L,-2,"adapter");}return 1;}
int l_screenshot(lua_State *L){g.shot=luaL_checkstring(L,1);g.shot_window=(int)luaL_optinteger(L,6,0);lua_pushboolean(L,true);return 1;}

int l_window(lua_State *L) {
    std::string op=luaL_checkstring(L,1);Window *w=&g.main;
    if((op=="screen"||op=="full"||op=="dpi"||op=="capabilities")&&!SDL_WasInit(SDL_INIT_VIDEO)){
        if(SDL_Init(SDL_INIT_VIDEO)){const char *driver=SDL_GetCurrentVideoDriver();g.wayland=driver&&std::strcmp(driver,"wayland")==0;}
    }
    if(op=="popup_open"){
        SDL_GL_MakeCurrent(g.main.native,g.main.context);SDL_GL_SetAttribute(SDL_GL_SHARE_WITH_CURRENT_CONTEXT,1);
        auto p=std::make_unique<Window>();p->id=g.next_window++;
        SDL_WindowFlags flags=SDL_WINDOW_OPENGL|SDL_WINDOW_HIGH_PIXEL_DENSITY|SDL_WINDOW_HIDDEN;
        if(flag(L,2,"resize",true))flags|=SDL_WINDOW_RESIZABLE;
        if(!flag(L,2,"caption",true))flags|=SDL_WINDOW_BORDERLESS;
        p->native=SDL_CreateWindow(strfield(L,2,"title","Lunar").c_str(),640,480,flags);
        if(p->native)p->context=SDL_GL_CreateContext(p->native);
        if(!p->native||!p->context){destroy(p.get());lua_pushnil(L);return 1;}
        int parent=field(L,2,"parent",0);auto owner=window(parent);
        if(flag(L,2,"owned")&&owner)SDL_SetWindowParent(p->native,owner->native);
        SDL_StartTextInput(p->native);int id=p->id;g.windows.push_back(std::move(p));
        SDL_GL_MakeCurrent(g.main.native,g.main.context);lua_pushinteger(L,id);return 1;
    }
    if(op.rfind("popup_",0)==0){w=window((int)luaL_checkinteger(L,2));if(!w)return 0;}
    if(op=="popup_close"){
        int id=w->id;destroy(w);g.windows.erase(std::remove_if(g.windows.begin(),g.windows.end(),[&](auto &p){return p->id==id;}),g.windows.end());
        SDL_GL_MakeCurrent(g.main.native,g.main.context);return 0;
    }
    if(op=="popup_ready"){lua_pushboolean(L,w->context!=nullptr);return 1;}
    if(op=="popup_place"){
        int x=(int)luaL_checkinteger(L,3),y=(int)luaL_checkinteger(L,4),width=(int)luaL_checkinteger(L,5),height=(int)luaL_checkinteger(L,6);
        bool visible=lua_toboolean(L,7);float s=density(w);
        int desiredw=std::max(1,(int)std::lround(width/s)),desiredh=std::max(1,(int)std::lround(height/s));
        int ow,oh;SDL_GetWindowSize(w->native,&ow,&oh);
        if(ow!=desiredw||oh!=desiredh)SDL_SetWindowSize(w->native,desiredw,desiredh);
        if(!g.wayland&&(!w->positioned||x!=w->x||y!=w->y)){
            int mx,my;SDL_GetWindowPosition(g.main.native,&mx,&my);SDL_SetWindowPosition(w->native,mx+(int)(x/s),my+(int)(y/s));w->positioned=true;
        }
        w->x=x;w->y=y;
        if(visible&&!w->visible){SDL_ShowWindow(w->native);SDL_RaiseWindow(w->native);}else if(!visible&&w->visible)SDL_HideWindow(w->native);
        w->visible=visible;
        if(!lua_isnoneornil(L,9))SDL_SetWindowTitle(w->native,lua_tostring(L,9));
        SDL_SetWindowModal(w->native,lua_toboolean(L,8));return 0;
    }
    if(op=="popup_state"){
        size(w);if(!g.wayland){int mx,my,x,y;SDL_GetWindowPosition(g.main.native,&mx,&my);SDL_GetWindowPosition(w->native,&x,&y);w->x=(int)((x-mx)*density(w));w->y=(int)((y-my)*density(w));}
        lua_pushinteger(L,w->x);lua_pushinteger(L,w->y);lua_pushinteger(L,w->w);lua_pushinteger(L,w->h);lua_pushboolean(L,w->close);w->close=false;
        lua_pushboolean(L,(SDL_GetWindowFlags(w->native)&SDL_WINDOW_MINIMIZED)!=0);lua_pushboolean(L,SDL_GetKeyboardFocus()==w->native);return 7;
    }
    if(op=="limits"){
        w=window((int)luaL_optinteger(L,3,0));if(!w)return 0;
        float s=density(w);int minw=field(L,2,"min_w",0),minh=field(L,2,"min_h",0),maxw=field(L,2,"max_w",65535),maxh=field(L,2,"max_h",65535);
        SDL_SetWindowMinimumSize(w->native,(int)std::ceil(minw/s),(int)std::ceil(minh/s));SDL_SetWindowMaximumSize(w->native,(int)(maxw/s),(int)(maxh/s));return 0;
    }
    if(op=="capabilities"){lua_newtable(L);lua_pushboolean(L,!g.wayland);lua_setfield(L,-2,"global_coordinates");lua_pushboolean(L,true);lua_setfield(L,-2,"custom_frame");return 1;}
    if(op=="caption"){g.caption=field(L,2,"h",0);g.nodrag.clear();
        if(lua_istable(L,3)){
            for(const char *name:{"min","max","close"}){lua_getfield(L,3,name);if(lua_istable(L,-1))g.nodrag.push_back({field(L,-1,"x",0),field(L,-1,"y",0),field(L,-1,"w",0),field(L,-1,"h",0)});lua_pop(L,1);}
            lua_getfield(L,3,"nodrag");int rects=lua_gettop(L);
            if(lua_istable(L,rects))for(size_t n=1;n<=lua_objlen(L,rects);n++){lua_rawgeti(L,rects,(int)n);g.nodrag.push_back({field(L,-1,"x",0),field(L,-1,"y",0),field(L,-1,"w",0),field(L,-1,"h",0)});lua_pop(L,1);}lua_pop(L,1);
        }
        SDL_SetWindowHitTest(g.main.native,hit,nullptr);return 0;}
    if(op=="custom_frame"){SDL_SetWindowBordered(w->native,false);lua_pushboolean(L,true);return 1;}
    if(op=="title"){if(lua_gettop(L)>1)SDL_SetWindowTitle(w->native,luaL_checkstring(L,2));lua_pushstring(L,SDL_GetWindowTitle(w->native));return 1;}
    if(op=="size"){if(lua_gettop(L)>2)SDL_SetWindowSize(w->native,(int)luaL_checkinteger(L,2),(int)luaL_checkinteger(L,3));size(w);lua_pushinteger(L,w->w);lua_pushinteger(L,w->h);return 2;}
    if(op=="dpi"){lua_pushnumber(L,ui_scale(w));return 1;}
    if(op=="pos"||op=="client_origin"){
        int x=0,y=0;if(!g.wayland){if(lua_gettop(L)>2)SDL_SetWindowPosition(w->native,(int)luaL_checkinteger(L,2),(int)luaL_checkinteger(L,3));SDL_GetWindowPosition(w->native,&x,&y);}
        lua_pushinteger(L,x);lua_pushinteger(L,y);return 2;
    }
    if(op=="screen"||op=="full"){
        SDL_Rect r={0,0,1280,800};auto display=w->native?SDL_GetDisplayForWindow(w->native):SDL_GetPrimaryDisplay();
        if(op=="screen")SDL_GetDisplayUsableBounds(display,&r);else SDL_GetDisplayBounds(display,&r);
        lua_pushinteger(L,r.w);lua_pushinteger(L,r.h);return 2;
    }
    if(op=="window_size"){int width,height;SDL_GetWindowSize(w->native,&width,&height);lua_pushinteger(L,width);lua_pushinteger(L,height);return 2;}
    if(op=="show")SDL_ShowWindow(w->native);
    else if(op=="hide")SDL_HideWindow(w->native);
    else if(op=="focus"||op=="popup_focus")SDL_RaiseWindow(w->native);
    else if(op=="maximize")SDL_MaximizeWindow(w->native);
    else if(op=="minimize")SDL_MinimizeWindow(w->native);
    else if(op=="restore")SDL_RestoreWindow(w->native);
    else if(op=="fullscreen")SDL_SetWindowFullscreen(w->native,lua_toboolean(L,2));
    else if(op=="is_active"){lua_pushboolean(L,SDL_GetKeyboardFocus()==w->native);return 1;}
    else if(op=="is_maximized"||op=="is_minimized"){lua_pushboolean(L,(SDL_GetWindowFlags(w->native)&(op=="is_maximized"?SDL_WINDOW_MAXIMIZED:SDL_WINDOW_MINIMIZED))!=0);return 1;}
    else if(op=="hwnd"||op=="popup_hwnd"){lua_pushnil(L);return 1;}
    return 0;
}
} // namespace

#define LUNAR_FFI extern "C" __attribute__((visibility("default")))
LUNAR_FFI ImDrawList *lunar_ui_draw_list(int layer){return g.frame_open?list(0,layer):scratch_list();}
LUNAR_FFI ImDrawList *lunar_ui_popup_list(int id,int layer){auto w=window(id);if(!g.frame_open||!w)return scratch_list();w->drawn=true;return list(id,layer);}
LUNAR_FFI void lunar_ui_rect(ImDrawList *d,float a,float b,float c,float e,uint32_t color,float radius,float thick,int flags){d->AddRect({a,b},{c,e},color,radius,thick,(ImDrawFlags)flags);}
LUNAR_FFI void lunar_ui_rect_filled(ImDrawList *d,float a,float b,float c,float e,uint32_t color,float radius,int flags){d->AddRectFilled({a,b},{c,e},color,radius,(ImDrawFlags)flags);}
LUNAR_FFI void lunar_ui_rect_gradient(ImDrawList *d,float a,float b,float c,float e,uint32_t c1,uint32_t c2,uint32_t c3,uint32_t c4){d->AddRectFilledMultiColor({a,b},{c,e},c1,c2,c3,c4);}
LUNAR_FFI void lunar_ui_line(ImDrawList *d,float a,float b,float c,float e,uint32_t color,float thick){d->AddLine({a,b},{c,e},color,thick);}
LUNAR_FFI void lunar_ui_circle(ImDrawList *d,float x,float y,float r,uint32_t color,float thick,int seg){if(thick<=0)d->AddCircleFilled({x,y},r,color,seg);else d->AddCircle({x,y},r,color,seg,thick);}
LUNAR_FFI void lunar_ui_poly(ImDrawList *d,const float *xy,int n,uint32_t color,int fill,float thick){std::vector<ImVec2> p;for(int k=0;k<n;k++)p.emplace_back(xy[2*k],xy[2*k+1]);if(fill)d->AddConvexPolyFilled(p.data(),n,color);else d->AddPolyline(p.data(),n,color,thick,ImDrawFlags_Closed);}
LUNAR_FFI void lunar_ui_text(ImDrawList *d,int face,float px,float x,float y,uint32_t color,const char *s,size_t n,float wrap,float x1,float y1,float x2,float y2,int){ImVec4 clip(x1,y1,x2,y2);d->AddText(font(face),px,{x,y},color,s,s+n,wrap,&clip);}
LUNAR_FFI void lunar_ui_text_size(int face,float px,const char *s,size_t n,float wrap,float *out){auto sz=font(face)->CalcTextSizeA(px,FLT_MAX,wrap,s,s+n);out[0]=sz.x;out[1]=sz.y;}
LUNAR_FFI int lunar_ui_image(ImDrawList *d,int id,float x1,float y1,float x2,float y2,float u1,float v1,float u2,float v2,uint32_t color){auto t=g.textures.find(id);if(t==g.textures.end())return 0;d->AddImage((ImTextureID)t->second.gl,{x1,y1},{x2,y2},{u1,v1},{u2,v2},color);return 1;}
LUNAR_FFI int lunar_ui_texture_bits(const unsigned char *p,int w,int h,int stride,int premultiplied){
    if(!p||w<=0||h<=0||w>32768||h>32768||stride<w*4)return 0;
    std::vector<unsigned char> rgba((size_t)w*h*4);
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){const auto s=p+(size_t)y*stride+x*4;auto d=rgba.data()+((size_t)y*w+x)*4;unsigned a=s[3];for(int c=0;c<3;c++){unsigned v=s[2-c];d[c]=(unsigned char)(premultiplied&&a?std::min(255u,v*255/a):v);}d[3]=(unsigned char)a;}
    return upload(rgba.data(),w,h);
}
LUNAR_FFI void lunar_ui_texture_free(int id){free_texture(id);}
LUNAR_FFI int lunar_ui_image_rounded(ImDrawList *d,int id,float x1,float y1,float x2,float y2,uint32_t color,float radius){auto t=g.textures.find(id);if(t==g.textures.end())return 0;d->AddImageRounded((ImTextureID)t->second.gl,{x1,y1},{x2,y2},{0,0},{1,1},color,radius);return 1;}
LUNAR_FFI void lunar_ui_clip_push(ImDrawList *d,float x1,float y1,float x2,float y2){d->PushClipRect({x1,y1},{x2,y2},true);}
LUNAR_FFI void lunar_ui_clip_pop(ImDrawList *d){if(d->_ClipRectStack.Size>1)d->PopClipRect();}
LUNAR_FFI ImFont *lunar_ui_face_font(int id){return font(id);}
LUNAR_FFI int lunar_ui_gdi_text_size(int,float,const char*,size_t,float,float*){return 0;}
LUNAR_FFI int lunar_ui_sizeof(int which){switch(which){case 0:return sizeof(LunarUiEvent);case 1:return sizeof(LunarUiFrame);case 2:return sizeof(ImGuiIO);case 3:return sizeof(ImDrawList);case 4:return sizeof(ImFont);case 5:return sizeof(ImGuiStyle);}return -1;}

extern "C" int luaopen_lunarimgui(lua_State *L){
    ensure_gui();
    const luaL_Reg api[]={
        {"open",l_open},{"close",l_close},{"alive",l_alive},{"now",l_now},{"wait",l_wait},
        {"frame_begin",l_frame_begin},{"frame_end",l_frame_end},{"window",l_window},
        {"font_find",l_font_find},{"font_load",l_font_load},{"font_metrics",l_font_metrics},{"font_names",l_font_names},{"font_private",l_font_private},
        {"texture",l_texture},{"texture_free",l_texture_free},{"texture_retain",l_texture_retain},
        {"clipboard_get",l_clipboard_get},{"clipboard_set",l_clipboard_set},{"cursor",l_cursor},{"cursor_pos",l_cursor_pos},
        {"renderer",l_renderer},{"screenshot",l_screenshot},{nullptr,nullptr}};
    luaL_newlib(L,api);return 1;
}

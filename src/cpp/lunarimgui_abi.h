#pragma once
#include <stdint.h>
// Keep this layout identical to core.imgui.backend.Native's LuaJIT declarations.
struct LunarUiEvent {
    int32_t type, button, mods, code;
    float x, y, dx, dy;
};
struct LunarUiFrame {
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
};

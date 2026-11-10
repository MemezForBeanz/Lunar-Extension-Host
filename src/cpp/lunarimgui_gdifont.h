#ifndef LUNARIMGUI_GDIFONT_H
#define LUNARIMGUI_GDIFONT_H

#include "imgui.h"

const ImFontLoader *lunarimgui_gdi_font_loader();
void lunarimgui_gdi_register_font_data(void *data, const char *path);

#endif

/* Non-interactive geometry regression for patch 0004. Maps windows but never
 * shows them. Link against the fork's libiup.a and the Windows system libraries
 * used by scripts/verify-iup-fork.ps1. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "iup.h"

static int changes;
static int checks;
static int button_calls, motion_calls, extra_calls;
typedef int (*ButtonCB)(Ihandle*, int, int, int, int, char*);
typedef int (*MotionCB)(Ihandle*, int, int, char*);

static int button(Ihandle* ih, int b, int pressed, int x, int y, char* status)
{
  (void)ih; (void)b; (void)pressed; (void)x; (void)y; (void)status;
  button_calls++;
  return IUP_DEFAULT;
}

static int motion(Ihandle* ih, int x, int y, char* status)
{
  (void)ih; (void)x; (void)y; (void)status;
  motion_calls++;
  return IUP_DEFAULT;
}

static int extra(Ihandle* ih, int id, int pressed)
{
  (void)ih; (void)id; (void)pressed;
  extra_calls++;
  return IUP_DEFAULT;
}

static void check(int ok, const char* message)
{
  checks++;
  if (!ok)
  {
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
  }
}

static int changed(Ihandle* ih, int new_pos, int old_pos)
{
  (void)ih; (void)new_pos; (void)old_pos;
  changes++;
  return IUP_DEFAULT;
}

static void verify(const char* type, int lines)
{
  int w, h, cw, ch, hidden_w, hidden_h, restored_w, restored_h, band;
  int horizontal = strcmp(type, "TOP") == 0 || strcmp(type, "BOTTOM") == 0;
  Ihandle* page = IupVbox(IupLabel("First page"), NULL);
  Ihandle* nested = IupFlatTabs(IupVbox(IupLabel("Nested page"), NULL), NULL);
  Ihandle* tabs = IupFlatTabs(page, nested, NULL);
  Ihandle* dlg = IupDialog(tabs);
  IupSetAttribute(IupGetChild(page, 0), "EXPAND", "YES");
  IupSetAttribute(IupGetChild(IupGetChild(nested, 0), 0), "EXPAND", "YES");
  IupSetAttribute(page, "TABTITLE", "First");
  IupSetAttribute(tabs, "TABTYPE", type);
  IupSetAttribute(tabs, "SHOWLINES", lines ? "YES" : "NO");
  IupSetAttribute(tabs, "EXTRABUTTONS", "1");
  IupSetAttributeId(tabs, "EXTRATITLE", 1, "+");
  IupSetAttribute(tabs, "VALUEPOS", "1");
  IupSetCallback(tabs, "TABCHANGEPOS_CB", (Icallback)changed);
  IupSetCallback(tabs, "FLAT_BUTTON_CB", (Icallback)button);
  IupSetCallback(tabs, "FLAT_MOTION_CB", (Icallback)motion);
  IupSetCallback(tabs, "EXTRABUTTON_CB", (Icallback)extra);
  IupSetAttribute(dlg, "RASTERSIZE", "640x480");
  IupSetAttribute(dlg, "SHRINK", "YES");
  check(IupMap(dlg) == IUP_NOERROR, "map dialog");
  IupRefresh(dlg);
  IupGetIntInt(tabs, "RASTERSIZE", &w, &h);
  IupGetIntInt(tabs, "CLIENTSIZE", &cw, &ch);
  band = horizontal ? h - ch - lines : w - cw - lines;
  check(band > 0, "visible strip has a positive title band");
  check(IupGetInt(tabs, "SHOWTABS") == 1, "default SHOWTABS is YES");
  changes = 0;

  IupSetAttribute(tabs, "SHOWTABS", "NO");
  /* No explicit IupRefresh: the attribute setter must update child layout. */
  IupGetIntInt(tabs, "CLIENTSIZE", &hidden_w, &hidden_h);
  printf("%s lines=%d: raster=%dx%d client=%dx%d hidden=%dx%d band=%d\n",
         type, lines, w, h, cw, ch, hidden_w, hidden_h, band);
  check(horizontal ? hidden_h == ch + band : hidden_w == cw + band,
        "content grows by exactly the title band");
  check(horizontal ? hidden_w == cw : hidden_h == ch, "other axis is unchanged");
  IupGetIntInt(nested, "RASTERSIZE", &restored_w, &restored_h);
  check(restored_w == hidden_w && restored_h == hidden_h, "selected child receives reclaimed space");
  check(IupGetInt(tabs, "VALUEPOS") == 1, "selection survives hiding");
  check(IupGetInt(nested, "SHOWTABS") == 1, "SHOWTABS is not inherited");
  check(IupGetAttributeId(tabs, "EXTRABOX", 1) == NULL, "hidden extra button has no hit box");
  check(IupConvertXYToPos(tabs, 5, 5) == -1, "hidden strip cannot be hit");
  check(IupConvertXYToPos(tabs, w - 5, h - 5) == -1, "opposite hidden edge cannot be hit");
  button_calls = motion_calls = extra_calls = 0;
  ((ButtonCB)IupGetCallback(tabs, "BUTTON_CB"))(tabs, IUP_BUTTON1, 1, 5, 5, "          ");
  ((ButtonCB)IupGetCallback(tabs, "BUTTON_CB"))(tabs, IUP_BUTTON1, 0, 5, 5, "          ");
  ((MotionCB)IupGetCallback(tabs, "MOTION_CB"))(tabs, 5, 5, "          ");
  check(button_calls == 2 && motion_calls == 1, "application callbacks still run while hidden");
  check(extra_calls == 0, "hidden extra buttons never fire");
  check(changes == 0, "hiding emits no selection callbacks");

  IupSetAttribute(tabs, "SHOWTABS", NULL);
  IupGetIntInt(tabs, "CLIENTSIZE", &restored_w, &restored_h);
  check(restored_w == cw && restored_h == ch, "clearing SHOWTABS restores original geometry");
  check(IupGetInt(tabs, "VALUEPOS") == 1 && changes == 0, "restoring preserves selection and callbacks");
  IupDestroy(dlg);
}

/* SHOWTABS=NO set BEFORE map must survive mapping. The mapping process
   re-applies every stored attribute through the class setter
   (iupAttribUpdate) and REMOVES it from the hash when the setter answers
   "do not store" -- the original setter did exactly that for an unchanged
   value, so a strip hidden before map came back visible. */
static void verify_premap(void)
{
  int w, h, cw, ch, band;
  Ihandle* page = IupVbox(IupLabel("First page"), NULL);
  Ihandle* other = IupVbox(IupLabel("Second page"), NULL);
  Ihandle* tabs = IupFlatTabs(page, other, NULL);
  Ihandle* dlg = IupDialog(tabs);
  IupSetAttribute(page, "TABTITLE", "First");
  IupSetAttribute(other, "TABTITLE", "Second");
  IupSetAttribute(dlg, "RASTERSIZE", "640x480");
  IupSetAttribute(tabs, "SHOWTABS", "NO");
  check(IupGetInt(tabs, "SHOWTABS") == 0, "pre-map: stored before map");
  check(IupMap(dlg) == IUP_NOERROR, "pre-map: map dialog");
  IupRefresh(dlg);
  check(IupGetInt(tabs, "SHOWTABS") == 0, "pre-map: survives mapping");
  IupGetIntInt(tabs, "RASTERSIZE", &w, &h);
  IupGetIntInt(tabs, "CLIENTSIZE", &cw, &ch);
  band = h - ch;
  check(band <= 1, "pre-map: no title band is reserved");
  IupSetAttribute(tabs, "SHOWTABS", "YES");
  IupGetIntInt(tabs, "RASTERSIZE", &w, &h);
  IupGetIntInt(tabs, "CLIENTSIZE", &cw, &ch);
  check(h - ch > 1, "pre-map: restoring shows the title band");
  IupDestroy(dlg);
}

int main(int argc, char** argv)
{
  const char* types[] = { "TOP", "BOTTOM", "LEFT", "RIGHT" };
  int t, lines;
  check(IupOpen(&argc, &argv) == IUP_NOERROR, "open IUP");
  for (t = 0; t < 4; t++)
    for (lines = 0; lines <= 1; lines++)
      verify(types[t], lines);
  verify_premap();
  IupClose();
  printf("SHOWTABS: %d checks passed (four orientations, with/without lines).\n", checks);
  return 0;
}

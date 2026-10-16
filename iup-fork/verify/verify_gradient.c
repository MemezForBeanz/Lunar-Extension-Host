/* Visual verification harness for the Lunar IUP fork: exercises the new
 * CORNERRADIUS / GRADIENTCOLOR / GRADIENTDIRECTION attributes on flat controls.
 * Built and run by scripts/verify-iup-fork.ps1, which screenshots the window. */
#include <stdlib.h>
#include "iup.h"

static Ihandle* mkbtn(const char* title, const char* bg, const char* grad, const char* radius, const char* dir)
{
  Ihandle* b = IupFlatButton(title);
  IupSetAttribute(b, "BGCOLOR", bg);
  if (grad) IupSetAttribute(b, "GRADIENTCOLOR", grad);
  if (radius) IupSetAttribute(b, "CORNERRADIUS", radius);
  if (dir) IupSetAttribute(b, "GRADIENTDIRECTION", dir);
  IupSetAttribute(b, "FGCOLOR", "255 255 255");
  IupSetAttribute(b, "SHOWBORDER", "YES");
  IupSetAttribute(b, "BORDERWIDTH", "2");
  IupSetAttribute(b, "BORDERCOLOR", "40 60 120");
  IupSetAttribute(b, "SIZE", "120x40");
  return b;
}

int main(int argc, char** argv)
{
  Ihandle *dlg, *box;

  IupOpen(&argc, &argv);

  box = IupVbox(
    mkbtn("Plain flat",       "80 120 200", NULL,          NULL, NULL),
    mkbtn("Rounded r=14",     "80 120 200", NULL,          "14", NULL),
    mkbtn("Gradient V",       "97 175 239", "198 120 221", NULL, "VERTICAL"),
    mkbtn("Grad+Round r=14",  "97 175 239", "198 120 221", "14", "VERTICAL"),
    mkbtn("Grad H r=20",      "97 175 239", "198 120 221", "20", "HORIZONTAL"),
    NULL);
  IupSetAttribute(box, "GAP", "12");
  IupSetAttribute(box, "MARGIN", "18x18");
  IupSetAttribute(box, "BGCOLOR", "30 30 34");

  dlg = IupDialog(box);
  IupSetAttribute(dlg, "TITLE", "Lunar IUP Fork - Gradient/Corner Verify");
  IupSetAttribute(dlg, "BGCOLOR", "30 30 34");
  IupSetHandle("verify_dlg", dlg);

  IupShowXY(dlg, IUP_CENTER, IUP_CENTER);

  IupMainLoop();
  IupClose();
  return 0;
}

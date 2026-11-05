/* Shows both fork controls on one dialog for native drawing review. */
#include "iup.h"
#include <stddef.h>

int main(int argc, char **argv)
{
  Ihandle *rows, *segments, *box, *dlg;
  IupOpen(&argc, &argv);
  rows = IupCreate("flatrows");
  segments = IupCreate("flatsegmented");
  IupSetAttribute(rows, "RASTERSIZE", "500x220");
  IupSetAttribute(rows, "COUNT", "4");
  IupSetAttribute(rows, "ROWHEIGHT", "44");
  IupSetAttribute(rows, "VALUE", "2");
  IupSetAttribute(rows, "BGCOLOR", "28 31 37");
  IupSetAttribute(rows, "FGCOLOR", "238 240 244");
  IupSetAttribute(rows, "SECONDARYCOLOR", "156 163 173");
  IupSetAttribute(rows, "PSCOLOR", "53 62 75");
  IupSetAttribute(rows, "HLCOLOR", "43 48 57");
  IupSetAttribute(rows, "ITEMMARKERCOLOR", "75 171 255");
  IupSetAttribute(rows, "ITEMRADIUS", "7");
  IupSetAttribute(rows, "COLUMN1WIDTH", "76");
  IupSetAttribute(rows, "COLUMN2WIDTH", "82");
  IupSetAttributeId(rows, "TITLE", 1, "server-log.txt");
  IupSetAttributeId(rows, "SECONDARY", 1, "Modified today 10:42");
  IupSetAttributeId(rows, "COLUMN1", 1, "2.4 MB");
  IupSetAttributeId(rows, "COLUMN2", 1, "Ready");
  IupSetAttributeId(rows, "TITLE", 2, "Security scan");
  IupSetAttributeId(rows, "SECONDARY", 2, "Run 42  /  completed");
  IupSetAttributeId(rows, "COLUMN1", 2, "12 files");
  IupSetAttributeId(rows, "COLUMN2", 2, "3 findings");
  IupSetAttributeId(rows, "TITLE", 3, "Dependencies");
  IupSetAttributeId(rows, "SECONDARY", 3, "Updated yesterday");
  IupSetAttributeId(rows, "COLUMN1", 3, "90 files");
  IupSetAttributeId(rows, "COLUMN2", 3, "No findings");
  IupSetAttributeId(rows, "TITLE", 4, "Build artifacts");
  IupSetAttributeId(rows, "SECONDARY", 4, "From main branch");
  IupSetAttribute(segments, "COUNT", "3");
  IupSetAttribute(segments, "VALUEPOS", "1");
  IupSetAttributeId(segments, "TITLE", 0, "Files");
  IupSetAttributeId(segments, "TITLE", 1, "Runs");
  IupSetAttributeId(segments, "TITLE", 2, "Findings");
  IupSetAttribute(segments, "RASTERSIZE", "280x32");
  IupSetAttribute(segments, "BGCOLOR", "39 43 51");
  IupSetAttribute(segments, "FGCOLOR", "200 207 218");
  IupSetAttribute(segments, "PSCOLOR", "71 85 105");
  IupSetAttribute(segments, "TEXTPSCOLOR", "255 255 255");
  IupSetAttribute(segments, "BORDERCOLOR", "83 92 105");
  box = IupVbox(segments, rows, NULL);
  IupSetAttribute(box, "GAP", "14");
  IupSetAttribute(box, "MARGIN", "18x18");
  dlg = IupDialog(box);
  IupSetAttribute(dlg, "TITLE", "Lunar flat widgets verify");
  IupSetAttribute(dlg, "BGCOLOR", "28 31 37");
  IupShowXY(dlg, IUP_CENTER, IUP_CENTER);
  IupMainLoop();
  IupClose();
  return 0;
}

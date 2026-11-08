-- Windows regression for the transient orphaned page inside IupReparent. Run in a
-- private desktop. The old focus handler crashes on the first simulated native event.
local iup = require("iup")
local ffi = require("ffi")
local platform = require("core.platform")
if not platform.is_windows then print("SKIP: Windows focus regression"); return end
local IupFFI = require("core.classes.IupFFI")
ffi.cdef("void iupwinWmSetFocus(Ihandle* ih);")
local events = 0
local page = iup.canvas({ canfocus = "NO", getfocus_cb = function() events = events + 1 end })
assert(not iup.GetDialog(page))
ffi.C.iupwinWmSetFocus(IupFFI.ptr(page))
assert(events == 0, "An orphaned page must not dispatch application focus callbacks")
local dialog = iup.dialog({ page, rastersize = "320x180", title = "Reparent focus regression" })
dialog:showxy(iup.CENTER, iup.CENTER)
local before = events
ffi.C.iupwinWmSetFocus(IupFFI.ptr(page))
assert(events == before + 1, "Attached controls must still dispatch focus callbacks")
iup.Destroy(dialog)
print("PASS: transient orphan focus ignored; attached control focus delivered")

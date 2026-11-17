-- scripts/ui_audit.lua: the UI capture walk (scripts/ui_capture.lua) at two window sizes in one
-- run, wide (LUNAR_CAPTURE_SIZE, else maximized) and then narrow (LUNAR_AUDIT_NARROW, default
-- 1100x800), with the scroll audit (scripts/ui_scroll_audit.lua) on every shot.
--
--   powershell -File D:\lunar-council\tools\cap-ui.ps1 -Script scripts\ui_audit.lua -Timeout 900 ...
--
-- The report is <out_dir>/<prefix>-scroll-audit.txt; any failure also writes
-- <out_dir>/SCROLL-AUDIT-FAILED.txt and a scroll-audit-FAILED.log the capture tool prints.
-- Narrow shots are named 1100-<prefix>-NN-<tab>.
LUNAR_AUDIT_SIZES = { os.getenv("LUNAR_AUDIT_NARROW") or "1100x800" }
local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local dir = here:match("^(.*)/[^/]+$") or "."
dofile(dir .. "/ui_capture.lua")

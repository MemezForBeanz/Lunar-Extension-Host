--- `winredraw` held WM_SETREDRAW across a batch of IUP changes. The ImGui host paints
-- once per frame after all callbacks have run, so a batch never shows half done and
-- lock/unlock have nothing to do.
-- @module core.imgui.native.winredraw
local M = {}
function M.lock() return true end
function M.unlock() return true end
return M

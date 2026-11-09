--- `themeapply` has no ImGui counterpart: its fast path wrote attributes straight into
-- IUP's C tables. Failing to load sends core.classes.ThemeManager down its Lua path,
-- which sets the same attributes through `iup.SetAttribute`.
-- @module core.imgui.native.themeapply
error("themeapply is not available on the ImGui host", 0)

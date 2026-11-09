-- scripts/imgui_smoke.lua — the native ImGui backend on its own: open a window, draw
-- shapes, text and a texture for a few frames, optionally save a shot, and exit 0.
--
--   Lunar scripts/imgui_smoke.lua [out.bmp]
local B = require("lunarimgui")
local out = arg and arg[1]
local step = function(s) io.stderr:write("smoke: ", s, "\n") end
local logf = out and io.open(out .. ".log", "w")
local function say(s) step(s); if logf then logf:write(s, "\n"); logf:flush() end end

say("open")
assert(B.open({ title = "Lunar ImGui smoke", w = 640, h = 400 }))
say("font")
local path = B.font_find("Segoe UI", false, false)
say("segoe: " .. tostring(path))
local font = path and B.font_load(path) or 0
local bold = B.font_find("Segoe UI", true, false)
say("bold: " .. tostring(bold))
local asc, desc, line, avg = B.font_metrics(font, 12)
say(string.format("metrics 12px: %s %s %s %s", asc, desc, line, avg))
local tw, th = B.text_size(font, 12, "Hello, Lunar")
say(string.format("text size: %s %s", tw, th))
local pixels = string.rep("\255\128\0\255", 32 * 32)
local tex = B.texture(pixels, 32, 32)
say("texture " .. tostring(tex))
for i = 1, 30 do
	local input = B.frame_begin()
	if i == 1 then say(string.format("input %dx%d scale %s", input.w, input.h, tostring(input.scale))) end
	B.rect_filled(0, 0, input.w, input.h, 0xFF202020, 0, 256)
	B.rect_filled(20, 20, 220, 80, 0xFF3A3A3A, 8, 0)
	B.rect(20, 20, 220, 80, 0xFF808080, 8, 1, 16 + 32)
	B.rect_gradient(240, 20, 440, 80, 0xFF0000FF, 0xFF00FF00, 0xFFFF0000, 0xFFFFFFFF)
	B.line(20, 100, 440, 100, 0xFFFFFFFF, 1)
	B.circle(500, 50, 20, 0xFF00FFFF, 0, 0)
	B.poly({ 20, 120, 60, 160, 20, 160 }, 0xFFFF00FF, true, 1)
	B.text(font, 12, 30, 40, 0xFFFFFFFF, "Hello, Lunar", 0, 0, 0, 640, 400)
	B.image(tex, 100, 120, 132, 152, 0, 0, 1, 1, 0xFFFFFFFF)
	B.clip_push(300, 120, 340, 160)
	B.rect_filled(280, 110, 360, 170, 0xFF00FF00, 0, 256)
	B.clip_pop()
	if i == 25 and out then B.screenshot(out) end
	B.frame_end()
	B.wait(0.01)
end
say("close")
B.close()
say("done")
if logf then logf:close() end
os.exit(0)

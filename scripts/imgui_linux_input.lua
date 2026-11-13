-- Native X11 input probe; requires xdotool and an isolated display.
-- lunar scripts/imgui_linux_input.lua
local B = require("core.imgui.backend.Native")
local ok, err = xpcall(function()
	assert(B.open{ title = "Lunar SDL input probe", w = 400, h = 240 })
	for _ = 1, 5 do B.frame_begin(); B.frame_end(); B.wait(0.02) end
	local pipe = assert(io.popen("xdotool search --name '^Lunar SDL input probe$'"))
	local id = assert(tonumber(pipe:read("*l")), "native X11 window missing")
	pipe:close()
	os.execute("xdotool windowfocus " .. id .. " mousemove --window " .. id .. " 40 50 click 1 key Left type abc")
	local seen, text = {}, ""
	for _ = 1, 20 do
		local frame = B.frame_begin()
		for _, event in ipairs(frame.events) do
			seen[event.type] = true
			if event.type == "keydown" and event.code == 0xff51 then seen.left = true end
			if event.type == "char" then text = text .. event.char end
		end
		B.frame_end(); B.wait(0.01)
	end
	assert(seen.press and seen.release and seen.move and seen.left and text == "abc",
		require("cjson").encode{ seen = seen, text = text })
end, debug.traceback)
B.close()
assert(ok, err)
print("PASS: native X11 pointer, button, arrow and text events")

-- scripts/video_host_check.lua: IupVideoHost and libmpv, through core.ui.VideoHost.
--
-- Plays a clip this script writes itself, then moves the host through a tab change, a resize
-- while hidden, a split change, a resize burst and fullscreen, and reads back where mpv's
-- child window and mpv's own idea of the size ended up. Then does it all once more with a
-- second player, because a page can be closed and opened in one session.
--
-- Run on a private desktop: its windows must not reach anyone's screen.
--   set LUNAR_LIBMPV=D:\path\to\libmpv-2.dll
--   Lunar scripts/video_host_check.lua
-- Without libmpv it reports SKIP.

local iup = require("iup")
local ffi = require("ffi")
local VideoHost = require("core.ui.VideoHost")
local Fullscreen = require("core.ui.Fullscreen")
local PaneGrid = require("core.classes.PaneGrid")
local TabGroups = require("core.classes.TabGroups")

local failures = 0
local function line(text) io.stdout:write(text, "\n"); io.stdout:flush() end
local function report(name, pass, detail)
	if not pass then failures = failures + 1 end
	line(string.format("[%s] %s%s", pass and "PASS" or "FAIL", name, detail and (" -- " .. tostring(detail)) or ""))
end

local lib, why = VideoHost.library()
if not lib then
	line("[SKIP] no libmpv: " .. tostring(why))
	os.exit(0)
end

local function write_clip(path)
	local w, h, frames = 320, 180, 90
	local base = {}
	for x = 1, w do base[x] = string.char(40 + (math.floor(x / 20) % 8) * 28) end
	base = table.concat(base)
	local file = assert(io.open(path, "wb"))
	file:write(string.format("YUV4MPEG2 W%d H%d F30:1 Ip A1:1 C420\n", w, h))
	for i = 0, frames - 1 do
		local shift = (i * 5) % w
		file:write("FRAME\n", (base:sub(shift + 1) .. base:sub(1, shift)):rep(h))
		file:write(string.char(128 + i % 60):rep(w * h / 4), string.char(128):rep(w * h / 4))
	end
	file:close()
end

ffi.cdef[[
typedef struct { long left, top, right, bottom; } VHC_RECT;
int GetWindowRect(void*, VHC_RECT*);
void* GetWindow(void*, unsigned);
int IsWindowVisible(void*);
long GetWindowLongA(void*, int);
]]
local user32 = ffi.load("user32")

local clip = (os.getenv("TEMP") or ".") .. "/lunar_video_host_check.y4m"
write_clip(clip)

local host = assert(VideoHost.new(iup, { bgcolor = "16 16 20" }))
local side = iup.label({ title = "side", expand = "YES" })
local split = iup.split({ host.widget, side, orientation = "VERTICAL", value = "700" })
local tabs = iup.flattabs({ split, iup.label({ title = "other", expand = "YES" }), tabtitle0 = "Video", tabtitle1 = "Other" })
local panes = PaneGrid({ iup = iup, main = tabs })
local groups = TabGroups({ iup = iup, root_strip = tabs })
groups:setPanes(panes:extraStrips())
panes:setGroups(groups)
local dlg = iup.dialog({ panes:widget(), rastersize = "1000x640", title = "video host check" })
dlg:showxy(iup.CENTER, iup.CENTER)
iup.Flush()
groups:markShown()
local original_window = host.windowId()
local fullscreen = Fullscreen.new({ iup = iup, dialog = dlg, tabs = tabs })

local function hwnd() return ffi.cast("void*", tonumber(host.windowId())) end
local function size(window)
	local rect = ffi.new("VHC_RECT")
	user32.GetWindowRect(window, rect)
	return rect.right - rect.left, rect.bottom - rect.top
end

local player, events, timer
local function start()
	events = {}
	player = assert(VideoHost.player(host, {
		options = { { "loop-file", "inf" }, { "hwdec", "no" }, { "ao", "null" } },
		on_event = function(name, info)
			events[name] = (events[name] or 0) + 1
			if name == "property-change" and info.name == "pause" then events.observed_pause = info.value end
		end,
	}))
	assert(player:observe("pause", "flag") == nil)
	assert(player:load(clip) == nil)
end
local function matches(tag)
	local child = user32.GetWindow(hwnd(), 5)
	if child == nil then return report(tag, false, "mpv has no child window") end
	local hw, hh = size(hwnd())
	local cw, ch = size(child)
	local osd = (player:get("osd-width") or "?") .. "x" .. (player:get("osd-height") or "?")
	report(tag, hw == cw and hh == ch and osd == hw .. "x" .. hh,
		string.format("host %dx%d child %dx%d osd %s", hw, hh, cw, ch, osd))
end

local steps, index = {}, 0
local function step(ms, fn) steps[#steps + 1] = { ms, fn } end
local function run()
	index = index + 1
	local item = steps[index]
	if not item then
		timer.run = "NO"
		line(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
		os.remove(clip)
		os.exit(failures == 0 and 0 or 1)
	end
	local t = iup.timer({ time = item[1] })
	function t.action_cb()
		t.run = "NO"
		local ok, err = pcall(item[2])
		if not ok then report("step " .. index, false, err) end
		run()
		return iup.DEFAULT
	end
	t.run = "YES"
end

timer = iup.timer({ time = 15 })
function timer.action_cb()
	if player then player:poll() end
	return iup.DEFAULT
end
timer.run = "YES"

local function round(label)
	step(50, start)
	step(2000, function()
		report(label .. " playback started", (events["playback-restart"] or 0) > 0 and player:get("vo-configured") == "yes")
		matches(label .. " first frame")
		local style = tonumber(user32.GetWindowLongA(user32.GetWindow(hwnd(), 5), -16))
		report(label .. " mouse reaches the host", bit.band(style, 0x08000000) ~= 0, "mpv child is disabled")
		report(label .. " host clips its child", bit.band(tonumber(user32.GetWindowLongA(hwnd(), -16)), 0x02000000) ~= 0)
		report(label .. " bounded read-ahead", tonumber(player:get("options/demuxer-max-bytes")) == 64 * 1024 * 1024)
	end)
	for _, zone in ipairs({ "right", "bottom", "corner", "main" }) do
		step(50, function()
			iup.SetFocus(host.widget)
			assert(panes:move(split, zone))
			if zone == "main" then groups:moveInto(split, tabs, 1); panes:sync() end
			iup.Flush()
		end)
		step(500, function()
			report(label .. " playing tab moved " .. zone,
				host.windowId() == original_window and player:get("vo-configured") == "yes")
			matches(label .. " reparented " .. zone)
		end)
	end
	step(50, function() tabs.valuepos = "1"; iup.Flush() end)
	step(500, function()
		report(label .. " hidden with its tab", user32.IsWindowVisible(user32.GetWindow(hwnd(), 5)) == 0)
		dlg.rastersize = "860x600"; iup.Refresh(dlg); iup.Flush()
	end)
	step(300, function() tabs.valuepos = "0"; iup.Flush() end)
	step(600, function()
		report(label .. " back with its tab", user32.IsWindowVisible(user32.GetWindow(hwnd(), 5)) == 1)
		matches(label .. " resized while hidden")
	end)
	step(50, function() split.value = "400"; iup.Flush() end)
	step(600, function() matches(label .. " split moved") end)
	step(50, function()
		for w = 860, 1160, 15 do
			dlg.rastersize = w .. "x" .. math.floor(600 + (w - 860) / 3)
			iup.Refresh(dlg); iup.Flush()
		end
	end)
	step(600, function() matches(label .. " resize burst") end)
	step(50, function() assert(fullscreen.enter()); iup.Flush() end)
	step(900, function()
		report(label .. " fullscreen controller keeps video window", host.windowId() == original_window
			and iup.GetAttribute(dlg, "FULLSCREEN") == "YES")
		matches(label .. " fullscreen")
	end)
	step(50, function() assert(fullscreen.exit()); iup.Flush() end)
	step(900, function()
		matches(label .. " windowed again")
		report(label .. " no frames dropped", (tonumber(player:get("frame-drop-count")) or 0) == 0, player:get("frame-drop-count"))
		player:set("pause", "yes")
	end)
	step(300, function()
		report(label .. " property event", events.observed_pause == true)
		dlg.rastersize = "1000x640"; iup.Refresh(dlg); split.value = "700"; iup.Flush()
		player:destroy()
		player:destroy()
		report(label .. " calls after destroy are harmless", player:get("pause") == nil and player:load("x") ~= nil)
		player = nil
	end)
end

round("first")
round("second")
run()
iup.MainLoop()

-- Interactive counterpart to ui_capture.lua: populate the same registered pages,
-- then leave the normal application event loop and dialogs under user control.
-- Run: Lunar scripts/ui_demo.lua (development builds only).
assert(LUNAR_DEV_BUILD and LUNAR_SOURCE_DIR, "UI demo requires a development build")
local iup = require("iup")
local fixtures = dofile(LUNAR_SOURCE_DIR .. "/scripts/ui_fixtures.lua")
local real_mainloop = iup.MainLoop

iup.MainLoop = function()
	-- Restore immediately so nested event loops don't initialize another demo.
	iup.MainLoop = real_mainloop
	local shell = assert(rawget(_G, "LUNAR_DEV_SHELL"), "Development shell is unavailable")
	local timer = iup.timer({ time = 900 })
	local pass = 0
	local function populate()
		local titles = {}
		for title in pairs(shell.pages or {}) do titles[#titles + 1] = title end
		table.sort(titles)
		local count = 0
		for _, title in ipairs(titles) do
			local fixture = fixtures.for_tab(shell, title)
			if fixture then
				local ok, err = pcall(fixture)
				if ok then count = count + 1
				else io.stderr:write("ui_demo: ", title, ": ", tostring(err), "\n") end
			end
		end
		print(string.format("ui_demo: populated %d fixture pages (pass %d)", count, pass))
	end
	function timer:action_cb()
		pass = pass + 1
		populate()
		-- Some fixtures initiate asynchronous loading on pass one, then replace
		-- its result on pass two. Stop afterwards so user edits are not reset.
		if pass == 2 then self.run = "NO" end
		return iup.DEFAULT
	end
	shell.host:addMenuItem("Reload demo data", function()
		pass = 0
		timer.run = "YES"
	end, "help")
	timer.run = "YES"
	local result = real_mainloop()
	timer.run = "NO"
	iup.Destroy(timer)
	return result
end

dofile(LUNAR_SOURCE_DIR .. "/src/lua/core/main.lua")

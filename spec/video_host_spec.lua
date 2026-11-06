local VideoHost = require("core.ui.VideoHost")

describe("VideoHost", function()
	it("refuses another product's private libmpv, however the path is written", function()
		assert.is_true(VideoHost.refused("E:\\Program Files\\Plex\\Plex\\libmpv-2.dll"))
		assert.is_true(VideoHost.refused("e:/program files/PLEX/plex/libmpv-2.dll"))
		assert.is_false(VideoHost.refused("D:\\tools\\mpv\\libmpv-2.dll"))
		assert.is_false(VideoHost.refused("D:\\tools\\plexamp-notes\\libmpv-2.dll"))
	end)

	it("tries the configured path, then the environment, then the usual names", function()
		local list = VideoHost.candidates({
			library = "C:/mine/libmpv-2.dll", windows = true,
			getenv = function(name) return name == "LUNAR_LIBMPV" and "D:/env/libmpv-2.dll" or nil end,
		})
		assert.same({ "C:/mine/libmpv-2.dll", "D:/env/libmpv-2.dll", "libmpv-2", "mpv-2" }, list)
		list = VideoHost.candidates({ windows = false, getenv = function() end })
		assert.same({ "mpv", "libmpv.so.2" }, list)
	end)

	it("skips a refused path instead of loading it", function()
		local ffi = require("ffi")
		local real, tried = ffi.load, {}
		ffi.load = function(name) tried[#tried + 1] = name; error("no such library") end
		local lib, why = VideoHost.library({
			library = "E:/Program Files/Plex/Plex/libmpv-2.dll", getenv = function() end,
		})
		ffi.load = real
		assert.is_nil(lib)
		assert.truthy(why)
		for _, name in ipairs(tried) do assert.is_false(VideoHost.refused(name)) end
	end)

	it("reports a missing library as an optional requirement", function()
		local ffi = require("ffi")
		local real = ffi.load
		ffi.load = function() error("no such library") end
		local item = VideoHost.requirement({ getenv = function() end, action_title = "Choose" })
		ffi.load = real
		assert.is_false(item.ok)
		assert.is_true(item.optional)
		assert.equals("Choose", item.action_title)
		assert.truthy(item.problem:find("libmpv", 1, true))
	end)

	it("returns nil rather than failing on a build without the host class", function()
		local iup = { SetAttribute = function() end }
		local host, why = VideoHost.new(iup, { raw = {} })
		assert.is_nil(host)
		assert.truthy(why)
	end)

	it("asks the widget for its window id, and reports an unmapped host", function()
		local attrs, widget = {}, {}
		local iup = {
			SetAttribute = function(_, k, v) attrs[k] = v end,
			GetAttribute = function(_, k) return attrs[k] end,
		}
		local host = VideoHost.new(iup, { raw = { videohost = function() return widget end }, bgcolor = "1 2 3" })
		assert.equals(widget, host.widget)
		assert.equals("1 2 3", attrs.BGCOLOR)
		assert.is_nil(host.windowId())
		attrs.WINDOWID = "1234"
		assert.equals("1234", host.windowId())
	end)
end)

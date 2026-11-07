local Runtime = dofile("extensions/media-server/libs/runtime.lua")
local cjson = require("cjson")
local lock = { id = "test-1", tools = { ffprobe = "bin/ffprobe.exe", extractor = "bin/yt-dlp.exe" } }

local function fixture(options)
	options = options or {}
	local files, texts, calls = {}, {}, {}
	texts["/extension/runtime/windows-x86_64.json"] = cjson.encode(options.lock or lock)
	files["/extension/runtime/bootstrap.ps1"] = true
	local now = 10
	local process = { queues = { stdout = {}, stderr = {} } }
	function process:read(channel) return table.remove(self.queues[channel], 1) end
	function process:poll() return self.code end
	function process:kill() self.killed = true end
	function process:close() self.closed = true end
	local runtime = Runtime.new({}, { name = "media-server" }, {
		root = "/extension", cache = "/cache", windows = options.windows ~= false, arch = options.arch or "x64",
		exists = function(path) return files[path] == true end,
		read = function(path) return texts[path] end,
		now = function() return now end,
		spawn = function(argv)
			calls[#calls + 1] = argv
			if options.spawn_error then return nil, options.spawn_error end
			return process
		end,
	})
	local function ready(dir)
		texts[dir .. "/receipt.json"] = cjson.encode({ id = lock.id })
		for _, relative in pairs(lock.tools) do files[dir .. "/" .. relative] = true end
	end
	return runtime, files, texts, calls, process, ready, function(time) now = time end
end

describe("contained media runtime", function()
	it("prefers a complete bundled payload to a cached payload without spawning", function()
		local runtime, _, _, calls, _, ready = fixture()
		ready(runtime.bundled); ready(runtime.cached)
		runtime:start()
		assert.equal("ready", runtime:status().state)
		assert.equal("/extension/runtime/windows-x86_64/bin/ffprobe.exe", runtime:tool("ffprobe"))
		assert.equal(0, #calls)
	end)
	it("ignores incomplete bundled tools and uses the versioned extension cache", function()
		local runtime, files, _, calls, _, ready = fixture()
		files[runtime.bundled .. "/bin/ffprobe.exe"] = true
		ready(runtime.cached); runtime:start()
		assert.equal("/cache/test-1/windows-x86_64/bin/ffprobe.exe", runtime:tool("ffprobe"))
		assert.equal(0, #calls)
	end)
	it("provisions missing tools once and only reports ready after a complete receipt exists", function()
		local runtime, _, _, calls, process, ready = fixture()
		runtime:start(); runtime:start()
		assert.equal(1, #calls)
		assert.equal("preparing", runtime:status().state)
		assert.equal("powershell.exe", calls[1][1])
		assert.equal(runtime.cached, calls[1][#calls[1]])
		assert.is_nil(runtime:tool("ffprobe"))
		ready(runtime.cached); process.code = 0; runtime:tick()
		assert.equal("ready", runtime:status().state)
		assert.is_true(process.closed)
	end)
	it("does not accept a stale runtime receipt", function()
		local runtime, _, texts, _, _, ready = fixture()
		ready(runtime.cached)
		texts[runtime.cached .. "/receipt.json"] = cjson.encode({ id = "old-version" })
		assert.is_nil(runtime:tool("ffprobe"))
	end)
	it("surfaces preparation failure and never exposes partial executables", function()
		local runtime, files, _, _, process = fixture()
		runtime:start()
		files[runtime.cached .. "/bin/ffprobe.exe"] = true
		process.queues.stderr = { "checksum mismatch" }; process.code = 1
		runtime:tick()
		assert.equal("failed", runtime:status().state)
		assert.matches("checksum mismatch", runtime:status().message)
		assert.is_nil(runtime:tool("ffprobe"))
	end)
	it("bounds preparation time and stops the owned helper on shutdown", function()
		local runtime, _, _, _, process, _, clock = fixture()
		runtime:start(); clock(700); runtime:tick()
		assert.is_true(process.killed)
		assert.is_true(process.closed)
		assert.equal("failed", runtime:status().state)
		local other, _, _, _, helper = fixture()
		other:start(); other:close()
		assert.is_true(helper.killed)
		assert.is_true(helper.closed)
	end)
	it("does not download Windows executables on unsupported platforms", function()
		local runtime, _, _, calls = fixture({ windows = false })
		runtime:start()
		assert.equal("unsupported", runtime:status().state)
		assert.equal(0, #calls)
	end)
	it("reports a missing bootstrap rather than trying an unrelated installer", function()
		local runtime, files, _, calls = fixture()
		files["/extension/runtime/bootstrap.ps1"] = nil
		runtime:start()
		assert.equal("failed", runtime:status().state)
		assert.equal(0, #calls)
	end)
	it("reports subprocess launch failures", function()
		local runtime = fixture({ spawn_error = "process unavailable" })
		runtime:start()
		assert.equal("failed", runtime:status().state)
		assert.equal("process unavailable", runtime:status().message)
	end)
	it("rejects a malformed or escaping runtime manifest before launching a helper", function()
		local runtime, _, _, calls = fixture({ lock = { id = "../bad", tools = { ffprobe = "bin/ffprobe.exe" } } })
		runtime:start()
		assert.equal("failed", runtime:status().state)
		assert.equal(0, #calls)
		local other, _, _, launches = fixture({ lock = { id = "ok", tools = { ffprobe = "../ffprobe.exe" } } })
		other:start()
		assert.equal("failed", other:status().state)
		assert.equal(0, #launches)
	end)
end)

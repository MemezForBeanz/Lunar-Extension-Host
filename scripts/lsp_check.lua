-- scripts/lsp_check.lua -- end-to-end check of the language-server client over a
-- real process: the native `process` stdin stream, Content-Length framing, and
-- core.lsp.Registry / Client, against spec/fixtures/fake_lsp_server.py and,
-- when their paths are given, real servers started through the shipped
-- extensions (plugins/lsp-lua, plugins/lsp-c, extensions/lsp-python,
-- extensions/lsp-csharp).
--
-- busted can't reach the native module (it lives in the exe), so this runs in
-- the CLI host:
--
--   LUA_PATH="src/lua/?.lua;vendor/luasocket/src/?.lua;;" build/win/bin/LunarCLI.exe
--     scripts/lsp_check.lua --python C:\Python\python.exe
--     [--lua <lua-language-server>] [--clangd <clangd>]
--     [--pyserver <pyright-langserver|pylsp>] [--csharp <csharp-ls|OmniSharp>]
--     [--work <an empty scratch folder>]
--
-- Every server is optional; a server that is not given is skipped and said so.
-- Exits non-zero if any case that ran failed.

local socket = require("socket")
local lfs = require("lfs")
local platform = require("core.platform")
local process = require("process")
local Registry = require("core.lsp.Registry")
local Diagnostics = require("core.lsp.Diagnostics")
local Discover = require("core.lsp.Discover")
local Client = require("core.lsp.Client")
local Uri = require("core.lsp.Uri")

local options = {}
do
	local i = 1
	while arg[i] do
		local name = arg[i]:match("^%-%-(%w+)$")
		if name and arg[i + 1] then
			options[name] = arg[i + 1]
			i = i + 2
		else
			i = i + 1
		end
	end
end

local repo = os.getenv("LUNAR_REPO") or lfs.currentdir()
local work = options.work or platform.path:join(platform.temp_dir(), "lunar-lsp-check")
lfs.mkdir(work)

local failures, ran = 0, 0
local function check(name, cond, detail)
	ran = ran + 1
	print(string.format("[%s] %s%s", cond and "PASS" or "FAIL", name,
		(cond or detail == nil) and "" or ("  -- " .. tostring(detail))))
	if not cond then failures = failures + 1 end
end

local function write_file(path, text)
	local file = assert(io.open(path, "wb"))
	file:write(text)
	file:close()
end

-- A registry on the real process module, pumped by hand.
local function new_registry()
	local diagnostics = Diagnostics.new()
	local log = {}
	local registry = Registry.new({
		diagnostics = diagnostics,
		spawn = function(opts) return process.spawn(opts) end,
		log = function(level, message) log[#log + 1] = level .. ": " .. message end,
	})
	return registry, diagnostics, log
end

local function pump_until(registry, seconds, done)
	local deadline = socket.gettime() + seconds
	while socket.gettime() < deadline do
		registry:pump()
		if done() then return true end
		socket.sleep(0.02)
	end
	registry:pump()
	return done()
end

-- The byte column just after (or at the start of) the n-th `needle` on a line.
local function column(text, line, needle, at_end)
	local i = 0
	for row in (text .. "\n"):gmatch("(.-)\r?\n") do
		if i == line then
			local from, to = row:find(needle, 1, true)
			assert(from, "no '" .. needle .. "' on line " .. line)
			return at_end and to or (from - 1)
		end
		i = i + 1
	end
	error("no line " .. line)
end

local function contains(list, predicate)
	for _, item in ipairs(list or {}) do
		if predicate(item) then return true end
	end
	return false
end

local function hover_text(hover)
	if type(hover) ~= "table" then return "" end
	local contents = hover.contents
	if type(contents) == "string" then return contents end
	if type(contents) ~= "table" then return "" end
	if type(contents.value) == "string" then return contents.value end
	local parts = {}
	for _, part in ipairs(contents) do
		parts[#parts + 1] = type(part) == "string" and part or tostring(part.value or "")
	end
	return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- 1. The fake server, over real stdio
-- ---------------------------------------------------------------------------

if options.python then
	local fake = platform.path:join(repo, "spec", "fixtures", "fake_lsp_server.py")
	local function fake_spec(mode)
		return {
			id = "fake", name = "Fake", languages = { "fake" }, extensions = { ".fake" },
			command = { argv = { options.python, "-u", fake, mode } },
		}
	end
	local path = platform.path:join(work, "notes.fake")
	local uri = Uri.fromPath(path)
	-- A non-ASCII character before the mark proves the UTF-16 mapping end to end.
	local text = "alpha beta\n\195\169t\195\169 TODO fix\nlast line\n"

	do
		local registry, diagnostics = new_registry()
		registry:register(fake_spec("ok"), {})
		local client = registry:clientFor(path)
		client:open(uri, "fake", text)
		check("fake: reaches running over real pipes",
			pump_until(registry, 20, function() return client.state == "running" end), client.detail)
		check("fake: diagnostics arrive",
			pump_until(registry, 10, function() return diagnostics:counts().warning == 1 end))
		local entry = diagnostics:forUri(uri)[1] or {}
		check("fake: diagnostic position is in UTF-16 units", entry.line == 1 and entry.character == 4,
			tostring(entry.line) .. ":" .. tostring(entry.character))
		local line, byte = client.documents:fromPosition(uri, { line = entry.line, character = entry.character })
		check("fake: and maps back to the editor's byte column", line == 1 and byte == 6, byte)

		local hover, hover_err
		client:hover(uri, 0, 7, function(result, err) hover, hover_err = result or false, err end)
		pump_until(registry, 10, function() return hover ~= nil end)
		check("fake: hover", hover_text(hover):find("beta", 1, true) ~= nil, hover_err and hover_err.message or hover_text(hover))

		local items
		client:completion(uri, 0, 3, nil, function(list) items = list or {} end)
		pump_until(registry, 10, function() return items ~= nil end)
		check("fake: completion", contains(items, function(item) return item.label == "alpha" end))

		local locations
		client:definition(uri, 2, 1, function(list) locations = list or {} end)
		pump_until(registry, 10, function() return locations ~= nil end)
		check("fake: definition", locations and locations[1] and Uri.key(locations[1].uri) == Uri.key(uri))

		client:change(uri, "all clean now\n")
		check("fake: a debounced edit clears the diagnostic",
			pump_until(registry, 10, function() return diagnostics:counts().total == 0 end))

		client:stop()
		check("fake: stop ends the process within the grace period",
			pump_until(registry, Client.SHUTDOWN_GRACE + 3, function() return not registry:isActive() end))
	end

	do
		local registry, _, log = new_registry()
		registry:register(fake_spec("crash"), {})
		local client = registry:clientFor(path)
		client:open(uri, "fake", text)
		local restarted = pump_until(registry, 20, function() return client.state == "restarting" end)
		check("fake: a crash is noticed, with its exit code and last words",
			restarted and tostring(client.detail):find("exit code 7", 1, true) ~= nil
				and tostring(client.detail):find("crashing on purpose", 1, true) ~= nil, client.detail)
		check("fake: the crash is logged", #log > 0)
		registry:stopAll()
	end

	do
		-- A server that stops reading: big edits pile up behind it. The UI thread
		-- must never wait, and the client must give up on it.
		local saved = Client.STALL_AFTER
		Client.STALL_AFTER = 2
		local registry = new_registry()
		registry:register(fake_spec("deaf"), {})
		local client = registry:clientFor(path)
		client:open(uri, "fake", text)
		pump_until(registry, 20, function() return client.state == "running" end)
		local big = string.rep("x", 1024 * 1024)
		local slowest = 0
		for i = 1, 8 do
			local t0 = socket.gettime()
			client:change(uri, big .. i)
			client.documents:flush(uri)
			registry:pump()
			slowest = math.max(slowest, socket.gettime() - t0)
		end
		check("deaf: 8 MB of edits to a stalled server never block", slowest < 0.5, slowest)
		check("deaf: the stalled server is ended and restarted",
			pump_until(registry, 15, function() return client.state == "restarting" end), client.state)
		check("deaf: and the reason is stated", tostring(client.detail):find("stopped reading", 1, true) ~= nil, client.detail)
		registry:stopAll()
		Client.STALL_AFTER = saved
	end
else
	print("[SKIP] fake server: pass --python <python executable>")
end

-- ---------------------------------------------------------------------------
-- 2. Real servers, through the shipped extensions
-- ---------------------------------------------------------------------------

-- Load an extension's init.lua and let it register against a minimal host.
local function register_extension(registry, dir, server_id, executable)
	local module = assert(loadfile(platform.path:join(repo, dir, "init.lua")))()
	local ctx = {}
	function ctx:addLanguageServer(spec, owner) return registry:register(spec, owner) end
	function ctx:findLanguageServer(spec)
		return Discover.find({
			label = spec.label, names = spec.names, install = spec.install,
			configured = spec.id == server_id and executable or nil,
		})
	end
	module.register(ctx)
end

local function real_server(case)
	if not case.executable then
		print("[SKIP] " .. case.name .. ": pass --" .. case.option .. " <server executable>")
		return
	end
	local dir = platform.path:join(work, case.id)
	lfs.mkdir(dir)
	for name, text in pairs(case.extra_files or {}) do write_file(platform.path:join(dir, name), text) end
	local path = platform.path:join(dir, case.file)
	write_file(path, case.text)
	local uri = Uri.fromPath(path)

	local registry, diagnostics, log = new_registry()
	register_extension(registry, case.extension, case.id, case.executable)
	local client, _, language = registry:clientFor(path)
	check(case.name .. ": the extension serves " .. case.file, client ~= nil and language == case.language, language)
	if not client then return end

	client:open(uri, language, case.text)
	local running = pump_until(registry, 90, function() return client.state == "running" or client.state == "failed" end)
	check(case.name .. ": starts and initializes", running and client.state == "running",
		tostring(client.state) .. " " .. tostring(client.detail))
	if client.state ~= "running" then
		for _, line in ipairs(log) do print("    " .. line) end
		registry:stopAll()
		return
	end
	print(string.format("    %s %s, position encoding %s", tostring(client.server_info and client.server_info.name),
		tostring(client.server_info and client.server_info.version), client.documents:encoding()))

	local found = pump_until(registry, case.wait or 90, function()
		return contains(diagnostics:forUri(uri), function(d) return d.message:lower():find(case.diagnostic, 1, true) ~= nil end)
	end)
	local shown = {}
	for _, d in ipairs(diagnostics:forUri(uri)) do
		shown[#shown + 1] = string.format("%d:%d %s %s", d.line + 1, d.character + 1, d.kind, d.message)
	end
	check(case.name .. ": diagnostics name the mistake", found, table.concat(shown, " | "))
	for _, line in ipairs(shown) do print("    " .. line) end

	-- Servers answer "nothing yet" while still loading a project, so ask until
	-- there is an answer or the time is up.
	local function ask(seconds, send, good)
		local deadline = socket.gettime() + seconds
		local last
		while socket.gettime() < deadline do
			local answered, value, err = false, nil, nil
			send(function(result, e) answered, value, err = true, result, e end)
			pump_until(registry, 20, function() return answered end)
			last = value
			if answered and not err and good(value) then return true, value end
			if err then last = err.message end
			pump_until(registry, 1, function() return false end)
		end
		return false, last
	end

	local h = case.hover
	local ok, value = ask(60, function(cb) client:hover(uri, h.line, column(case.text, h.line, h.at), cb) end,
		function(result) return hover_text(result):find(h.expect, 1, true) ~= nil end)
	check(case.name .. ": hover on " .. h.at, ok, type(value) == "table" and hover_text(value) or value)
	if ok then print("    " .. hover_text(value):gsub("%s+", " "):sub(1, 110)) end

	local c = case.completion
	ok, value = ask(60, function(cb)
		client:completion(uri, c.line, column(case.text, c.line, c.after, true), c.trigger, function(items, err) cb(items, err) end)
	end, function(items)
		-- clangd pads its labels with a leading space; the text to insert is exact.
		return contains(items, function(item)
			local label = tostring(item.filterText or item.label):gsub("^%s+", "")
			return label:find(c.expect, 1, true) == 1
		end)
	end)
	check(case.name .. ": completion after " .. c.after .. " offers " .. c.expect, ok,
		type(value) == "table" and (#value .. " items") or value)

	local d = case.definition
	ok, value = ask(60, function(cb) client:definition(uri, d.line, column(case.text, d.line, d.at), cb) end,
		function(locations)
			return contains(locations, function(location)
				return Uri.key(location.uri) == Uri.key(uri) and location.range and location.range.start.line == d.target
			end)
		end)
	check(case.name .. ": definition of " .. d.at .. " is line " .. (d.target + 1), ok,
		type(value) == "table" and value[1] and value[1].range and ("line " .. (value[1].range.start.line + 1)) or value)

	client:change(uri, case.fixed)
	check(case.name .. ": fixing the mistake clears its diagnostic", pump_until(registry, 60, function()
		return not contains(diagnostics:forUri(uri), function(item) return item.message:lower():find(case.diagnostic, 1, true) ~= nil end)
	end))

	client:stop()
	check(case.name .. ": stops", pump_until(registry, Client.SHUTDOWN_GRACE + 5, function() return not registry:isActive() end))
	registry:stopAll()
end

local LUA_TEXT = table.concat({
	"local function greet(name)",
	'\treturn "Hello, " .. name',
	"end",
	"",
	'local message = greet("Lunar")',
	"print(mesage)",
	"local shout = string.upp",
	"return shout, message",
	"",
}, "\n")

real_server({
	id = "lua", name = "lua-language-server", option = "lua", executable = options.lua,
	extension = "plugins/lsp-lua", file = "main.lua", language = "lua",
	text = LUA_TEXT, fixed = (LUA_TEXT:gsub("print%(mesage%)", "print(message)")),
	diagnostic = "mesage",
	hover = { line = 4, at = "greet", expect = "greet" },
	completion = { line = 6, after = "string.upp", expect = "upper" },
	definition = { line = 4, at = "greet", target = 0 },
})

local C_TEXT = table.concat({
	"static int add(int a, int b)",
	"{",
	"    return a + b;",
	"}",
	"",
	"int main(void)",
	"{",
	"    int total = add(2, 3);",
	"    return totl;",
	"}",
	"",
}, "\n")

real_server({
	id = "c", name = "clangd", option = "clangd", executable = options.clangd,
	extension = "plugins/lsp-c", file = "main.c", language = "c",
	text = C_TEXT, fixed = (C_TEXT:gsub("return totl;", "return total;")),
	diagnostic = "totl",
	hover = { line = 7, at = "add", expect = "add" },
	completion = { line = 8, after = "tot", expect = "total" },
	definition = { line = 7, at = "add", target = 0 },
})

local PY_TEXT = table.concat({
	"import os",
	"",
	"",
	"def greet(name: str) -> str:",
	'    return "Hello, " + name',
	"",
	"",
	'message = greet("Lunar")',
	"print(mesage)",
	"print(os.pat)",
	"",
}, "\n")

real_server({
	id = "python", name = "Python server", option = "pyserver", executable = options.pyserver,
	extension = "extensions/lsp-python", file = "main.py", language = "python",
	text = PY_TEXT, fixed = (PY_TEXT:gsub("print%(mesage%)", "print(message)")),
	diagnostic = "mesage",
	hover = { line = 7, at = "greet", expect = "greet" },
	completion = { line = 9, after = "os.pat", expect = "path" },
	definition = { line = 7, at = "greet", target = 3 },
})

local CS_TEXT = table.concat({
	"using System;",
	"",
	"public static class Program",
	"{",
	"    static string Greet(string name)",
	"    {",
	'        return "Hello, " + name;',
	"    }",
	"",
	"    public static void Main()",
	"    {",
	'        var message = Greet("Lunar");',
	"        Console.WriteLine(mesage);",
	"        Console.WriteLi",
	"    }",
	"}",
	"",
}, "\n")

real_server({
	id = "csharp", name = "C# server", option = "csharp", executable = options.csharp,
	extension = "extensions/lsp-csharp", file = "Program.cs", language = "csharp",
	extra_files = {
		["app.csproj"] = table.concat({
			'<Project Sdk="Microsoft.NET.Sdk">',
			"  <PropertyGroup>",
			"    <OutputType>Exe</OutputType>",
			"    <TargetFramework>net8.0</TargetFramework>",
			"  </PropertyGroup>",
			"</Project>",
			"",
		}, "\n"),
	},
	text = CS_TEXT, fixed = (CS_TEXT:gsub("WriteLine%(mesage%)", "WriteLine(message)")),
	diagnostic = "mesage", wait = 180,
	hover = { line = 11, at = "Greet", expect = "Greet" },
	completion = { line = 13, after = "Console.WriteLi", expect = "WriteLine" },
	definition = { line = 11, at = "Greet", target = 4 },
})

print(failures == 0 and ("\nALL PASSED (" .. ran .. " checks)") or ("\n" .. failures .. " FAILED of " .. ran))
os.exit(failures == 0 and 0 or 1)

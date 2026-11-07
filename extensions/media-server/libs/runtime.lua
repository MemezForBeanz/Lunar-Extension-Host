--- Extension-owned native tools. Packaged tools win; missing tools are provisioned once in
-- this extension's user cache, without modifying PATH or installing machine-wide software.
local platform = require("core.platform")
local lfs = require("lfs")
local cjson = require("cjson")
local Runtime = {}
Runtime.__index = Runtime
local M = {}
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local ROOT = source:match("^(.*)/libs/runtime%.lua$")
local function read(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local value = f:read("*a"); f:close(); return value
end
local function decode(text)
	local ok, value = pcall(cjson.decode, text or "")
	return ok and type(value) == "table" and value or nil
end
local function manifest_of(text)
	local value = decode(text)
	if not value or type(value.id) ~= "string" or not value.id:match("^[%w._-]+$")
		or type(value.tools) ~= "table" or next(value.tools) == nil then return nil end
	for name, relative in pairs(value.tools) do
		if type(name) ~= "string" or type(relative) ~= "string" or relative:find("..", 1, true)
			or relative:match("^[/\\]") or relative:find(":", 1, true) then return nil end
	end
	return value
end
function M.new(ctx, owner, opts)
	opts = opts or {}
	local root = opts.root or ROOT
	assert(root, "could not locate this extension's runtime")
	local id = opts.id or owner.name
	assert(type(id) == "string" and id:match("^[%w_-]+$"), "runtime needs an extension id")
	local windows = opts.windows
	if windows == nil then windows = platform.is_windows end
	local arch = opts.arch or require("ffi").arch
	local target = windows and arch == "x64" and "windows-x86_64" or nil
	local self = setmetatable({ root = root, id = id, owner = owner, ctx = ctx,
		read = opts.read or read, exists = opts.exists or function(p) return lfs.attributes(p, "mode") == "file" end,
		now = opts.now or os.time, state = "idle", target = target,
		spawn = opts.spawn or function(argv) return ctx:spawn({ argv = argv }, owner) end,
		cache_root = opts.cache or (platform.cache_dir() .. "/extensions/" .. id .. "/runtime"),
	}, Runtime)
	if target then
		self.manifest_path = root .. "/runtime/" .. target .. ".json"
		self.manifest = manifest_of(self.read(self.manifest_path))
		if self.manifest then
			self.bundled = root .. "/runtime/" .. target
			self.cached = self.cache_root .. "/" .. self.manifest.id .. "/" .. target
		end
	end
	return self
end
function Runtime:_valid(dir)
	if not self.manifest then return false end
	local receipt = decode(self.read(dir .. "/receipt.json"))
	if not receipt or receipt.id ~= self.manifest.id then return false end
	for _, relative in pairs(self.manifest.tools) do
		if not self.exists(dir .. "/" .. relative) then return false end
	end
	return true
end
function Runtime:_resolve()
	if self:_valid(self.bundled) then return self.bundled end
	if self:_valid(self.cached) then return self.cached end
end
function Runtime:tool(name)
	if not self.manifest or not self.manifest.tools[name] then return nil end
	local dir = self:_resolve()
	return dir and (dir .. "/" .. self.manifest.tools[name]) or nil
end
function Runtime:status()
	local tools = {}
	for name in pairs(self.manifest and self.manifest.tools or {}) do tools[name] = self:tool(name) ~= nil end
	return { state = self.state, message = self.message, tools = tools }
end
function Runtime:start()
	if self.process or self.state == "ready" then return end
	if not self.target then
		self.state, self.message = "unsupported", "No contained runtime is packaged for this platform."
		return
	end
	if not self.manifest then self.state, self.message = "failed", "Runtime manifest is missing or unreadable."; return end
	if self:_resolve() then self.state, self.message = "ready", nil; return end
	local bootstrap = self.root .. "/runtime/bootstrap.ps1"
	if not self.exists(bootstrap) then self.state, self.message = "failed", "Runtime bootstrap is missing."; return end
	local process, why = self.spawn({ "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", bootstrap, "-Manifest", self.manifest_path, "-Destination", self.cached })
	if not process then self.state, self.message = "failed", tostring(why); return end
	self.process, self.started, self.output = process, self.now(), ""
	self.state, self.message = "preparing", "Preparing this extension's media tools…"
end
function Runtime:_drain()
	for _, channel in ipairs({ "stdout", "stderr" }) do
		local chunk = self.process:read(channel)
		while chunk and chunk ~= "" do
			self.output = (self.output .. chunk):sub(-65536)
			chunk = self.process:read(channel)
		end
	end
end
function Runtime:tick()
	if not self.process then return end
	self:_drain()
	local code = self.process:poll()
	if code == nil and self.now() - self.started <= 600 then return end
	if code == nil then self.process:kill() end
	self:_drain(); self.process:close(); self.process = nil
	if code == 0 and self:_resolve() then self.state, self.message = "ready", nil
	else self.state, self.message = "failed", code == nil and "Media tools preparation timed out."
		or ((self.output ~= "" and self.output:sub(-3000)) or "Media tools preparation failed.") end
end
function Runtime:close()
	if self.process then self.process:kill(); self.process:close(); self.process = nil end
end
return M

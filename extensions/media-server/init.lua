-- Lunar Media Server: catalogs local folders and streams them over an authenticated API.
--
-- Run it with the headless host, for example:
--   lunar-cli --headless --dev --extensions extensions --require media-server \
--     --listen 127.0.0.1:8421 --tokens-file tokens --state-dir state
--
-- Windows packages contain FFmpeg/ffprobe and the extractor. Lightweight packages prepare
-- the pinned tools in an extension-owned cache and expose progress through /v1/status.

local Catalog = require("libs.catalog")
local Scanner = require("libs.scanner")
local Probe = require("libs.probe")
local api = require("libs.api")
local schema = require("libs.schema")
local art = require("libs.art")
local Sources = require("libs.sources")

local lfs = require("lfs")

local M = { name = "media-server" }

local TICK_MS = 50
local SCAN_BUDGET_MS = 8
local MAX_PROBES = 2
local SOURCE_TICKS = 20     -- a second of 50 ms ticks

local MIME = { mp4 = "video/mp4", m4v = "video/mp4", mkv = "video/x-matroska", webm = "video/webm",
	mov = "video/quicktime", avi = "video/x-msvideo", ts = "video/mp2t" }

local function mime_of(path)
	return MIME[(path:match("%.([%w]+)$") or ""):lower()] or "application/octet-stream"
end

function M:_finish_probe(run)
	local info, why = Probe.parse(table.concat(run.output))
	if run.code == 0 and info then
		self.catalog:saveProbe(run.job, info)
	else
		self.catalog:failProbe(run.job, run.code == nil and "ffprobe timed out"
			or (run.code ~= 0 and ("ffprobe exited with " .. tostring(run.code)) or why), os.time())
	end
end

function M:_tick_probes()
	for i = #self.probes, 1, -1 do
		local run = self.probes[i]
		if Probe.advance(run, os.time()) then
			run.process:close()
			table.remove(self.probes, i)
			self:_finish_probe(run)
		end
	end
	while self.ffprobe and #self.probes < MAX_PROBES and not self.ctx:isStopping() do
		local job = self.catalog:claimProbe(os.time())
		if not job then break end
		local path = job.root .. "/" .. job.rel_path
		local process, err = self.ctx:spawn({ argv = Probe.argv(self.ffprobe, path) }, self)
		if process then
			self.probes[#self.probes + 1] = Probe.run(job, process, os.time())
		else
			self.catalog:failProbe(job, tostring(err), os.time())
		end
	end
end

-- One frame at a time: a frame is a nicety, and streams come first.
function M:_tick_frames()
	local run = self.frame_run
	if run then
		local code = run.process:poll()
		if code == nil and os.time() - run.started <= art.TIMEOUT_S then return end
		if code == nil then run.process:kill() end
		run.process:close()
		self.frame_run = nil
		if code == 0 then
			self.catalog:finishFrame(run.job.work_id, run.name)
		else
			self.catalog:failFrame(run.job.work_id, code == nil and "ffmpeg timed out" or ("ffmpeg exited with " .. tostring(code)))
		end
		return
	end
	if not self.ffmpeg or not self.art_dir or self.ctx:isStopping() then return end
	local job = self.catalog:claimFrame()
	if not job then return end
	local name = job.work_id .. ".jpg"
	local process, err = self.ctx:spawn({ argv = art.frameArgv(self.ffmpeg, job.root .. "/" .. job.rel_path,
		self.art_dir .. "/" .. name, art.frameAt(job.duration_ms)) }, self)
	if process then
		self.frame_run = { job = job, process = process, name = name, started = os.time() }
	else
		self.catalog:failFrame(job.work_id, tostring(err))
	end
end

function M:_tick_scans()
	if not self.scan_run then
		local library = table.remove(self.scan_queue, 1)
		if not library then return end
		self.scan_run = Scanner.new(self.catalog, library)
	end
	if self.scan_run:step(SCAN_BUDGET_MS) then
		self.log:info(string.format("scan finished: %s, %d files, %d to analyse",
			self.scan_run.library.name, self.scan_run.seen, self.scan_run.added))
		self.scan_run = nil
	end
end

function M:_queue_scan(library)
	for _, queued in ipairs(self.scan_queue) do
		if queued.id == library.id then return end
	end
	if self.scan_run and self.scan_run.library.id == library.id then return end
	self.scan_queue[#self.scan_queue + 1] = library
end

function M:_status()
	local counts = self.catalog:counts()
	counts.scanning = self.scan_run and self.scan_run.library.name or nil
	counts.analysis = self.ffprobe and "on" or "off"
	counts.runtime = self.runtime and self.runtime:status()
	counts.metadata = self.metadata and self.metadata:status()
	return { status = 200, json = counts }
end

function M:register(ctx)
	self.ctx = ctx
	self.log = ctx:getLogger("media-server")
	self.scan_queue, self.probes = {}, {}
	self.runtime = require("libs.runtime").new(ctx, self)
	self.runtime:start()
	self.ffprobe, self.ffmpeg = self.runtime:tool("ffprobe"), self.runtime:tool("ffmpeg")
	local data_dir = ctx:dataDir(self)
	if data_dir then
		self.art_dir = data_dir .. "/art"
		lfs.mkdir(self.art_dir)
	end
	local db, err = ctx:openDatabase("catalog", self)
	if not db then error("media-server database: " .. tostring(err), 0) end
	local migrated, why = schema.migrate(db)
	if not migrated then error("media-server schema: " .. tostring(why), 0) end
	self.catalog = Catalog.new(db)
	self.catalog:recoverJobs()
	self.metadata = require("libs.metadata").new({ catalog = self.catalog, now = os.time,
		http = function(request, done) return ctx:http(request, done, self) end,
		get_secret = function(name) return ctx:getSecret(self, name) end,
		set_secret = function(name, value) return ctx:setSecret(self, name, value) end,
	})
	local extension = self
	local mounted = true
	self.sources = Sources.new({ catalog = self.catalog, now = os.time, log = self.log,
		torrent_engine = os.getenv("LUNAR_TORRENT_ENGINE"),
		extractor = function() return self.runtime:tool("extractor") end,
		http = function(request, done) return ctx:http(request, done, extension) end,
		spawn = function(argv) return ctx:spawn({ argv = argv }, extension) end,
		get_secret = function(name) return ctx:getSecret(extension, name) end,
		set_secret = function(name, value) return ctx:setSecret(extension, name, value) end,
		delete_secret = function(name) return ctx:deleteSecret(extension, name) end,
	})
	api.mount({
		catalog = self.catalog,
		frames_enabled = function() return extension.ffmpeg ~= nil and extension.art_dir ~= nil end,
		sources = self.sources,
		metadata = self.metadata,
		now = os.time,
		status = function() return extension:_status() end,
		scan = function(library) extension:_queue_scan(library) end,
		art_response = function(target)
			local root = target.origin == "frame" and extension.art_dir or target.root
			local response, problem = ctx:fileResponse(root, target.path, { mime = art.mime(target.path) }, extension)
			if not response then return { status = 503, json = { error = tostring(problem) } } end
			return response
		end,
		file_response = function(target)
			local response, problem = ctx:fileResponse(target.root, target.rel_path,
				{ mime = mime_of(target.rel_path) }, extension)
			if not response then return { status = 503, json = { error = tostring(problem) } } end
			return response
		end,
		route = function(method, path, handler)
			local handle, problem = ctx:addRoute(method, path, handler, nil, extension)
			if not handle then mounted = false; extension.log:warn("no HTTP API: " .. tostring(problem)) end
		end,
	})
	if not self.ffprobe then
		self.log:info("media tools are not ready yet; preparation progress is available in runtime status")
	end
	ctx:onReady(function()
		self.timer = ctx:addTimer({ time = TICK_MS, run = true, action = function()
			if ctx:isStopping() then return end
			self.runtime:tick()
			if self.runtime.state == "ready" and not self.contained_tools then
				self.ffprobe, self.ffmpeg = self.runtime:tool("ffprobe"), self.runtime:tool("ffmpeg")
				self.contained_tools = true
			end
			self.sources.discovery:tick()
			self.metadata:tick()
			self:_tick_scans()
			self:_tick_probes()
			self:_tick_frames()
			self.sources_wait = (self.sources_wait or 0) + 1
			if self.sources_wait >= SOURCE_TICKS then
				self.sources_wait = 0
				self.sources:tick()
			end
		end }, self)
		for _, library in ipairs(self.catalog:libraries()) do
			if not library.source_id then self:_queue_scan(library) end
		end
	end, self)
	return mounted
end

function M:shutdown()
	if self.metadata then self.metadata:close() end
	if self.runtime then self.runtime:close() end
	for _, run in ipairs(self.probes or {}) do
		run.process:kill()
		run.process:close()
	end
	if self.sources then self.sources:close() end
	if self.frame_run then
		self.frame_run.process:kill()
		self.frame_run.process:close()
	end
	if self.catalog then self.catalog:close() end
end

return M

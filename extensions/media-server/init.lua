-- Lunar Media Server: catalogs local folders and streams them over an authenticated API.
--
-- Run it with the headless host, for example:
--   lunar-cli --headless --dev --extensions extensions --require media-server \
--     --listen 127.0.0.1:8421 --tokens-file tokens --state-dir state
--
-- Set LUNAR_FFPROBE to an ffprobe executable to analyse files. Without one the catalog
-- still fills and streams, and /v1/status reports that analysis is off.

local Catalog = require("libs.catalog")
local Scanner = require("libs.scanner")
local Probe = require("libs.probe")
local api = require("libs.api")
local schema = require("libs.schema")

local M = { name = "media-server" }

local TICK_MS = 50
local SCAN_BUDGET_MS = 8
local MAX_PROBES = 2

local MIME = { mp4 = "video/mp4", m4v = "video/mp4", mkv = "video/x-matroska", webm = "video/webm",
	mov = "video/quicktime", avi = "video/x-msvideo", ts = "video/mp2t" }

local function mime_of(path)
	return MIME[(path:match("%.([%w]+)$") or ""):lower()] or "application/octet-stream"
end

function M:_finish_probe(run)
	local job = run.job
	local text = table.concat(run.output)
	local info, why = Probe.parse(text)
	if run.code == 0 and info then
		self.catalog:saveProbe(job, info)
	else
		self.catalog:failProbe(job, why or ("ffprobe exited with " .. tostring(run.code)), os.time())
	end
end

function M:_drain_probe(run)
	local chunk = run.process:read("stdout")
	while chunk and chunk ~= "" do
		run.size = run.size + #chunk
		if run.size <= Probe.MAX_OUTPUT then run.output[#run.output + 1] = chunk end
		chunk = run.process:read("stdout")
	end
end

function M:_tick_probes()
	for i = #self.probes, 1, -1 do
		local run = self.probes[i]
		self:_drain_probe(run)
		local finished, code = run.process:poll()
		local overdue = os.time() - run.started > Probe.TIMEOUT_S
		if finished or overdue then
			if overdue and not finished then
				run.process:kill()
				code = "a timeout"
			else
				self:_drain_probe(run)
			end
			run.code = code
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
			self.probes[#self.probes + 1] = { job = job, process = process, output = {}, size = 0, started = os.time() }
		else
			self.catalog:failProbe(job, tostring(err), os.time())
		end
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
	return { status = 200, json = counts }
end

function M:register(ctx)
	self.ctx = ctx
	self.log = ctx:getLogger("media-server")
	self.scan_queue, self.probes = {}, {}
	self.ffprobe = os.getenv("LUNAR_FFPROBE")
	if self.ffprobe == "" then self.ffprobe = nil end
	local db, err = ctx:openDatabase("catalog", self)
	if not db then error("media-server database: " .. tostring(err), 0) end
	local migrated, why = schema.migrate(db)
	if not migrated then error("media-server schema: " .. tostring(why), 0) end
	self.catalog = Catalog.new(db)
	self.catalog:recoverJobs()
	local extension = self
	local mounted = true
	api.mount({
		catalog = self.catalog,
		now = os.time,
		status = function() return extension:_status() end,
		scan = function(library) extension:_queue_scan(library) end,
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
		self.log:warn("LUNAR_FFPROBE is not set, so files will be cataloged without analysis")
	end
	ctx:onReady(function()
		self.timer = ctx:addTimer({ time = TICK_MS, run = true, action = function()
			if ctx:isStopping() then return end
			self:_tick_scans()
			self:_tick_probes()
		end }, self)
		for _, library in ipairs(self.catalog:libraries()) do self:_queue_scan(library) end
	end, self)
	return mounted
end

function M:shutdown()
	for _, run in ipairs(self.probes or {}) do
		run.process:kill()
		run.process:close()
	end
	if self.catalog then self.catalog:close() end
end

return M

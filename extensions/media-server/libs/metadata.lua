--- A bounded, restartable server-side metadata worker. No media files are changed.
local tmdb = require("libs.tmdb")
local metadb = require('libs.metadb')
local MetaClient = require('libs.metaclient')
local M = {}
local Service = {}; Service.__index = Service
M.MATCH_TTL = 30 * 24 * 3600
M.NO_MATCH_TTL = 7 * 24 * 3600
M.MAX_BYTES = 2 * 1024 * 1024

function M.new(opts)
	assert(opts.catalog and opts.http, "catalog and http are required")
	local self = setmetatable({ catalog = opts.catalog, http = opts.http, get_secret = opts.get_secret,
		set_secret = opts.set_secret, now = opts.now or os.time, getenv = opts.getenv or os.getenv,
		next_start = 0, next_seed = 0, provider = opts.provider, manual_versions={} }, Service)
	self.client = MetaClient.new({http=opts.http,now=self.now,get_secret=function(name)
		if name=='tmdb_token' then return self:_token() end
		return self.get_secret and self.get_secret(name)
	end})
	self.catalog:recoverMetadata()
	return self
end
function Service:_token()
	local token = self.getenv("LUNAR_TMDB_TOKEN")
	if (not token or token == "") and self.get_secret then token = self.get_secret("tmdb_token") end
	return type(token) == "string" and token ~= "" and token or nil
end
function Service:configure(token)
	if type(token) ~= "string" or token == "" or #token > 4096 or token:find("%s") then return nil, "a TMDB API read access token is required" end
	local managed = self.getenv("LUNAR_TMDB_TOKEN")
	if type(managed) == "string" and managed ~= "" then return nil, "TMDB credentials are managed by the server environment; update LUNAR_TMDB_TOKEN there." end
	if not self.set_secret then return nil, "this service uses read-only secrets; configure tmdb_token in its secrets store" end
	local ok, why = self.set_secret("tmdb_token", token)
	if not ok then return nil, why or "could not save the TMDB token" end
	self.blocked_token, self.last_error = nil, nil
	return true
end
function Service:status()
	local result = self.catalog:metadataStatus()
	result.provider = self.provider or 'keyless'
	result.configured = true
	result.state = self.busy and 'working' or 'ready'
	result.providers = self.client:providers()
	result.error = self.last_error
	result.attribution = tmdb.ATTRIBUTION
	result.source_url = "https://www.themoviedb.org"
	return result
end
function Service:_provider(work, chosen)
	if chosen then return chosen end
	if work.provider and metadb.provider(work.provider) then return work.provider end
	return self.provider or (work.kind=='show' and 'tvmaze' or 'cinemeta')
end
function Service:refresh(work_id)
	return self.catalog:queueMetadata(work_id, self.now())
end
function Service:_details(work, external_id, done, provider)
	return self.client:details(self:_provider(work,provider),work,external_id,done)
end
function Service:search(work_id, query, done, provider)
	local work = self.catalog:metadataWork(work_id)
	if not work then return done(nil, "no movie or show with that id") end
	if self.busy then return done(nil, "metadata worker is busy; try again shortly") end
	if query ~= nil and (type(query) ~= "string" or #query > 200) then return done(nil, "search must be at most 200 characters") end
	self.busy = true
	local search_work = { kind = work.kind, title = work.title, year = (query == nil or query == work.title) and work.year or nil }
	self.client:search(self:_provider(work,provider),search_work,query,function(results,why)
		self.busy = false
		self.next_start = self.now() + 1
		done(results, why)
	end)
end
function Service:match(work_id, external_id, done, provider)
	local work = self.catalog:metadataWork(work_id)
	if not work then return done(nil, "no movie or show with that id") end
	if self.busy then return done(nil, "metadata worker is busy; try again shortly") end
	provider=self:_provider(work,provider)
	if not metadb.validId(provider,external_id) then return done(nil, 'A valid provider id is required.') end
	self.busy = true
	self:_details(work, external_id, function(facts, why)
		self.busy = false
		self.next_start = self.now() + 1
		if not facts then return done(nil, why) end
		local ok, problem = self.catalog:saveMetadata(work.id, facts, self.now(), self.now() + M.MATCH_TTL)
		done(ok and facts or nil, problem)
	end,provider)
end
function Service:tick()
	self.client:tick()
	local now = self.now()
	if self.closed or self.busy or now < self.next_start then return end
	if now >= self.next_seed then
		self.catalog:queueMissingMetadata(now, 100)
		self.next_seed = now + 30
	end
	local job = self.catalog:claimMetadata(now)
	if not job then return end
	self.busy = true
	local manual_version=self.manual_versions[job.work_id]
	local function finish(facts, why, retry, unmatched)
		self.busy = false
		if self.manual_versions[job.work_id]~=manual_version then return end
		self.last_error = why
		self.next_start = self.now() + (retry or 1)
		if facts then
			self.catalog:saveMetadata(job.work_id, facts, self.now(), self.now() + M.MATCH_TTL)
		elseif unmatched then
			self.catalog:unmatchedMetadata(job, why, self.now(), self.now() + M.NO_MATCH_TTL)
		else
			self.catalog:failMetadata(job, why, self.now(), self.now() + (retry or (30 * ((job.attempts or 0) + 1) ^ 2)))
		end
	end
	if job.external_id then return self:_details(job, job.external_id, finish) end
	self.client:search(self:_provider(job),job,nil,function(results,why,retry)
		if not results then return finish(nil, why, retry) end
		local picked, reason = metadb.pick(job, results)
		if not picked then return finish(nil, reason, nil, true) end
		self:_details(job, picked.id, finish)
	end)
end
function Service:apply(work_id, facts)
	local work=self.catalog:metadataWork(work_id)
	if not work then return nil,'No movie or show with that id.' end
	local safe,why=metadb.validateFacts(facts,work.kind)
	if not safe then return nil,why end
	local ok,problem=self.catalog:saveMetadata(work.id,safe,self.now(),self.now()+M.MATCH_TTL)
	if ok then self.manual_versions[work.id]=(self.manual_versions[work.id] or 0)+1 end
	return ok,problem
end
function Service:close() self.closed = true;self.client:close() end
return M

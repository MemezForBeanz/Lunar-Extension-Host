-- Discovery is exercised through its public jobs, deferred HTTP callbacks and subprocess
-- contract. No real website is contacted and no user's installed catalog is changed.
package.path = "./extensions/media-server/?.lua;" .. package.path
local cjson = require("cjson")
local Discovery = require("libs.discovery")
local Sources = require("libs.sources")
local API = require("libs.api")
local Catalog = require("libs.catalog")
local Schema = require("libs.schema")
local sqlite = require("core.lib.sqlite")
local platform = require("core.platform")
local Web = require("libs.websources")

local function process()
	local p = { chunks = { stdout = {}, stderr = {} }, closed = 0 }
	function p:read(channel) return table.remove(self.chunks[channel], 1) end
	function p:poll() return self.code end
	function p:kill() self.killed = true end
	function p:close() self.closed = self.closed + 1 end
	return p
end
local function fixture(options)
	options = options or {}
	local f = { time = 1000, pending = {}, spawned = {}, processes = {} }
	f.d = Discovery.new({
		now = function() return f.time end,
		providers = function() return Web.SITES end,
		http = function(request, done) f.pending[#f.pending + 1] = { request = request, done = done } end,
		extractor = function() return options.no_extractor and nil or "C:/extension/bin/yt-dlp.exe" end,
		spawn = function(argv)
			f.spawned[#f.spawned + 1] = argv
			if options.spawn_error then return nil, options.spawn_error end
			local p = process(); f.processes[#f.processes + 1] = p; return p
		end,
	})
	function f:begin(address)
		return assert(self.d:begin({ provider = "video-page", url = address or "https://video.example/title" }))
	end
	function f:reply(index, body, status)
		local call = assert(self.pending[index]); assert(not call.replied, "response already delivered")
		call.replied = true
		call.done({ ok = not status or status < 400, status = status or 200, body = body or "" })
	end
	function f:extract(address)
		local answer = {}
		local id = self.d:resolve(address or "https://video.example/watch", function(result, why)
			answer.result, answer.error, answer.finished = result, why, true
		end)
		self.d:tick(); self:reply(#self.pending, "<html>No direct stream</html>")
		self.d:tick()
		return answer, self.processes[#self.processes], id
	end
	return f
end

describe("bounded server discovery", function()
	it("queues requests, runs at most two HTTP fetches, and passes response/time bounds to HTTP", function()
		local f = fixture()
		for i = 1, 4 do f:begin("https://video.example/" .. i) end
		assert.equal(0, #f.pending)
		f.d:tick(); f.d:tick(); f.d:tick()
		assert.equal(2, #f.pending)
		assert.equal(Discovery.MAX_BYTES, f.pending[1].request.max_bytes)
		assert.is_true(f.pending[1].request.timeout <= 20)
		f:reply(1, "<title>One</title>"); f.d:tick()
		assert.equal(3, #f.pending)
	end)
	it("reuses a cached page within TTL and fetches it again after expiry", function()
		local f = fixture()
		local first = f:begin(); f.d:tick(); f:reply(1, "<title>Original</title>")
		assert.equal("ready", f.d:poll(first.id).state)
		local cached = f:begin()
		assert.equal("ready", f.d:poll(cached.id).state)
		assert.equal("Original", f.d:poll(cached.id).result.items[1].title)
		assert.equal(1, #f.pending)
		f.time = f.time + Discovery.TTL + 1
		local refreshed = f:begin(); f.d:tick()
		assert.equal("running", f.d:poll(refreshed.id).state)
		assert.equal(2, #f.pending)
	end)
	it("caps outstanding jobs before allocating another HTTP request", function()
		local f = fixture()
		for i = 1, Discovery.MAX_JOBS do f:begin("https://video.example/" .. i) end
		local job, why = f.d:begin({ provider = "video-page", url = "https://video.example/overflow" })
		assert.is_nil(job); assert.matches("Too many", why)
		assert.equal(0, #f.pending)
	end)
	it("expires polling and result selection even when no newer request is made", function()
		local f = fixture(); local job = f:begin()
		f.d:tick(); f:reply(1, "<title>Expired</title>")
		f.time = f.time + Discovery.TTL + 1; f.d:tick()
		assert.is_nil(f.d:poll(job.id))
		assert.is_nil(f.d:entry(job.id, "https://video.example/title"))
	end)
	it("discards expired queued work instead of accumulating a hidden crawl", function()
		local f = fixture()
		for generation = 1, 3 do
			for i = 1, Discovery.MAX_JOBS do f:begin("https://video.example/g" .. generation .. "/" .. i) end
			if generation < 3 then f.time = f.time + Discovery.TTL + 1 end
		end
		f.d:tick()
		assert.matches("/g3/", f.pending[1].request.url)
	end)
	it("reports blocked 403 pages as failures and does not start the extractor", function()
		local f = fixture(); local job = f:begin()
		f.d:tick(); f:reply(1, "Access denied", 403)
		local result = f.d:poll(job.id)
		assert.equal("failed", result.state); assert.matches("403", result.error)
		assert.equal(0, #f.spawned)
	end)
	it("reports a refused video page without attempting access-check workarounds", function()
		local f = fixture(); local answer = {}
		f.d:resolve("https://video.example/watch", function(result, why) answer.result, answer.error = result, why end)
		f.d:tick(); f:reply(1, "Blocked", 403); f.d:tick()
		assert.is_nil(answer.result); assert.matches("403", answer.error)
		assert.equal(0, #f.spawned)
	end)
	it("rejects malformed providers, search bounds, non-web addresses and cross-source detail URLs", function()
		local f = fixture()
		for _, body in ipairs({ {}, { provider = "missing" }, { provider = "video-page", url = "file:///private" },
			{ provider = "9anime", query = string.rep("x", 201) }, { provider = "9anime", page = 0 },
			{ provider = "9anime", page = 1.5 }, { provider = "9anime", url = "https://other.example/anime/title" } }) do
			assert.is_nil(f.d:begin(body))
		end
		assert.equal(0, #f.pending)
	end)
	it("resolves direct embedded media without starting a subprocess", function()
		local f = fixture(); local answer = {}
		f.d:resolve("https://video.example/watch", function(result, why) answer.result, answer.error = result, why end)
		f.d:tick(); f:reply(1, '<video controls src="/media/title.mp4?signature=abc"></video>')
		assert.equal("https://video.example/media/title.mp4?signature=abc", answer.result.url)
		assert.same({ "Referer: https://video.example/watch" }, answer.result.headers)
		assert.equal(f.time + 120, answer.result.expires_at)
		assert.is_nil(answer.error); assert.equal(0, #f.spawned)
	end)
	it("ignores late callbacks after the extension closes", function()
		local f = fixture(); local job = f:begin(); f.d:tick(); f.d:close()
		f:reply(1, "<title>Late</title>")
		assert.is_nil(f.d:poll(job.id)); f.d:tick()
		assert.equal(1, #f.pending)
	end)
end)

describe("contained video extraction", function()
	it("runs at most one extractor and passes URLs as data after --", function()
		local f = fixture()
		f.d:resolve("https://video.example/first", function() end)
		f.d:resolve("https://video.example/second", function() end)
		f.d:tick(); f.d:tick(); f:reply(1, ""); f:reply(2, "")
		f.d:tick(); f.d:tick()
		assert.equal(1, #f.spawned)
		local argv = f.spawned[1]
		assert.equal("--", argv[#argv - 1]); assert.equal("https://video.example/first", argv[#argv])
		assert.is_true(table.concat(argv, " "):find("--ignore-config", 1, true) ~= nil)
		f.processes[1].chunks.stdout = { cjson.encode({ url = "https://cdn.example/one.mp4" }) }
		f.processes[1].code = 0; f.d:tick()
		assert.equal(2, #f.spawned)
		assert.equal(1, f.processes[1].closed)
	end)
	it("returns a short-lived stream and only allowed single-line playback headers", function()
		local f = fixture(); local answer, p = f:extract()
		p.chunks.stdout = { cjson.encode({ url = "https://cdn.example/stream.m3u8?expires=123", http_headers = {
			Referer = "https://video.example/", ["User-Agent"] = "Player", Origin = "https://video.example",
			Cookie = "private=value", Authorization = "secret", Invalid = "a\r\nb", } }) }
		p.code = 0; f.d:tick()
		assert.is_true(answer.finished); assert.is_nil(answer.error)
		assert.equal(f.time + 120, answer.result.expires_at)
		assert.equal(3, #answer.result.headers)
		for _, header in ipairs(answer.result.headers) do assert.is_nil(header:find("private", 1, true)); assert.is_nil(header:find("secret", 1, true)) end
	end)
	it("handles malformed extractor header objects without crashing the server timer", function()
		local f = fixture(); local answer, p = f:extract()
		p.chunks.stdout = { '{"url":"https://cdn.example/a.mp4","http_headers":["bad-header"]}' }
		p.code = 0
		assert.has_no.errors(function() f.d:tick() end)
		assert.is_true(answer.finished)
		assert.same({}, answer.result.headers)
	end)
	it("surfaces extractor stderr, closes handles and does not accept failed stdout", function()
		local f = fixture(); local answer, p = f:extract()
		p.chunks.stdout = { '{"url":"https://cdn.example/a.mp4"}' }
		p.chunks.stderr = { "ERROR: Unsupported host" }; p.code = 1; f.d:tick()
		assert.is_nil(answer.result); assert.matches("Unsupported host", answer.error)
		assert.equal(1, p.closed)
	end)
	it("does not accept non-web URLs or malformed extractor JSON", function()
		for _, stdout in ipairs({ '{"url":"file:///private"}', "not JSON", '{"requested_formats":[]}' }) do
			local f = fixture(); local answer, p = f:extract()
			p.chunks.stdout = { stdout }; p.code = 0; f.d:tick()
			assert.is_nil(answer.result); assert.is_truthy(answer.error)
		end
	end)
	it("kills over-budget output without accepting a stream", function()
		local f = fixture(); local answer, p = f:extract()
		p.chunks.stdout = { string.rep("x", Discovery.MAX_BYTES + 1) }; f.d:tick()
		assert.is_nil(answer.result); assert.is_truthy(answer.error)
		assert.is_true(p.killed); assert.equal(1, p.closed)
	end)
	it("times out a stuck extractor and kills it on extension shutdown", function()
		local f = fixture(); local answer, p = f:extract()
		f.time = f.time + Discovery.TIMEOUT + 1; f.d:tick()
		assert.is_nil(answer.result); assert.matches("timed out", answer.error)
		assert.is_true(p.killed); assert.equal(1, p.closed)
		local other = fixture(); local _, child = other:extract(); other.d:close()
		assert.is_true(child.killed); assert.equal(1, child.closed)
	end)
	it("reports launch failure without leaving the resolve callback pending", function()
		local f = fixture({ spawn_error = "spawn refused" }); local answer = f:extract()
		assert.is_true(answer.finished); assert.matches("spawn refused", answer.error)
	end)
end)

describe("saved discovery results and expiring stream cache", function()
	local db, catalog, path, manager, time, resolutions, clock
	before_each(function()
		time, resolutions = 1000, {}
		path = platform.path:join(platform.temp_dir(), "lunar_discovery_" .. os.time() .. "_" .. math.random(1e9) .. ".sqlite3")
		db = assert(sqlite.open(path)); assert(Schema.migrate(db)); catalog = Catalog.new(db, function() return time end)
		manager = Sources.new({ catalog = catalog, now = function() return time end,
			http = function() error("saved results must not resync whole remote catalogs") end,
			spawn = function() error("unexpected subprocess") end,
			get_secret = function() end, set_secret = function() return true end, delete_secret = function() end })
	end)
	after_each(function()
		if manager then manager:close() end
		if catalog then catalog:close() end
		if db then assert(db:close()) end
		if path then os.remove(path) end
	end)
	it("imports only selected results, keeps previous titles/progress and is idempotent", function()
		local entries = {
			one = { key = "https://video.example/one", title = "First Title", url = "https://video.example/one", resolve = "webpage" },
			two = { key = "https://video.example/two", title = "Second Title", url = "https://video.example/two", resolve = "webpage" },
		}
		local provider = { id = "video-page", name = "Video webpage" }
		manager.discovery.entry = function(_, _, key) return entries[key], provider end
		local first = assert(manager:importDiscovery("job", "one"))
		local page = catalog:browse(first.library_id, { user = "owner", limit = 20 })
		local work_id = page.items[1].id
		catalog:saveProgress("owner", work_id, 12345, 60000, time)
		local second = assert(manager:importDiscovery("job", "two"))
		assert.equal(first.source_id, second.source_id)
		assert.equal(first.library_id, second.library_id)
		assert(manager:importDiscovery("job", "one"))
		local imported = catalog:browse(first.library_id, { user = "owner", limit = 20 }).items
		assert.equal(2, #imported)
		local previous = assert(catalog:item(work_id, "owner"))
		assert.equal(12345, previous.progress.position_ms)
		assert.is_nil(previous.files[1].missing_at)
		time = time + Sources.RESYNC_S + 1; manager:tick()
		assert.equal(2, #catalog:browse(first.library_id, { limit = 20 }).items)
	end)
	it("preserves website provenance and ordered stream alternatives in the catalog", function()
		local provider = { id = "video-page", name = "Video webpage" }
		manager.discovery.entry = function()
			return { key = "https://video.example/title", title = "Native title", url = "https://cdn.example/main.mp4",
				resolve = "direct", source_id = "video-page", source_url = "https://video.example/title",
				attribution = "Example site", overview = "Native description", poster_url = "https://video.example/poster.jpg",
				headers = { Authorization = "private-token" }, auth = "private-key",
				stream_urls = { "https://cdn.example/main.mp4", "https://cdn.example/backup.m3u8" } }, provider
		end
		local saved = assert(manager:importDiscovery("job", "native"))
		local item = assert(catalog:item(catalog:browse(saved.library_id, { limit = 20 }).items[1].id, "owner"))
		assert.equal("Native description", item.overview)
		assert.equal("https://video.example/poster.jpg", item.poster_url)
		assert.equal("video-page", item.files[1].source_id)
		assert.equal("Example site", item.files[1].attribution)
		assert.is_nil(item.files[1].remote.headers)
		assert.is_nil(item.files[1].remote.auth)
		assert.equal("Native description", item.files[1].remote.site_metadata.overview)
		local browsed = catalog:browse(saved.library_id, { limit = 20 }).items[1]
		assert.is_nil(browsed.remote.headers)
		assert.is_nil(browsed.remote.auth)
		assert.same({ "https://cdn.example/main.mp4", "https://cdn.example/backup.m3u8" }, item.files[1].stream_urls)
	end)
	it("deduplicates pending resolves and refreshes expired signed URLs", function()
		manager.discovery.resolve = function(_, url, done) resolutions[#resolutions + 1] = { url = url, done = done } end
		local target = { id = 9, remote = cjson.encode({ url = "https://video.example/page", resolve = "webpage" }) }
		assert.is_nil(manager:open(target)); assert.is_nil(manager:open(target))
		assert.equal(1, #resolutions)
		resolutions[1].done({ url = "https://cdn.example/a.mp4?sig=one", expires_at = time + 120 })
		assert.equal("https://cdn.example/a.mp4?sig=one", manager:open(target).url)
		time = time + 120
		assert.is_nil(manager:open(target)); assert.equal(2, #resolutions)
		resolutions[2].done({ url = "https://cdn.example/a.mp4?sig=two", expires_at = time + 120 })
		assert.equal("https://cdn.example/a.mp4?sig=two", manager:open(target).url)
	end)
	 it("carries an episode's site provenance onto the show's browse and detail responses", function()
		local source = catalog:addSource("video-page", "Site", "{}", time)
		local library = catalog:sourceLibrary(source)
		catalog:saveRemote(library.id, { key = "episode", title = "Pilot", kind = "episode", show = "Example Show",
			season = 1, episode = 1, url = "https://cdn.example/pilot.mp4", source_id = "video-page",
			source_url = "https://video.example/show", overview = "Website description", attribution = "Example site" }, 0)
		local show = catalog:browse(library.id, { limit = 20 }).items[1]
		assert.equals("show", show.kind)
		assert.equals("Example site", show.remote.attribution)
		assert.equals("https://video.example/show", catalog:item(show.id, "owner").remote.source_url)
	end)
	it("subscribes to a series, groups its episodes, and keeps progress across resyncs", function()
		local provider = { id = "9anime", name = "9anime", kind = "website" }
		manager.discovery.entry = function() return {key="series",title="Space",url="https://9anime.or.at/anime/space/",is_series=true},provider end
		local started = 0
		manager.discovery.begin = function() started=started+1; return {id=tostring(started)} end
		manager.discovery.poll = function() return {state="ready",result={items={
			{key="ep2",title="Episode 2",url="https://video.example/2",resolve="webpage",kind="episode",show="Space",season=1,episode=2},
			{key="ep1",title="Episode 1",url="https://video.example/1",resolve="webpage",kind="episode",show="Space",season=1,episode=1},
		}}} end
		local saved=assert(manager:importDiscovery("job","series"))
		assert.is_true(saved.syncing)
		assert.equal(0,#catalog:browse(saved.library_id,{limit=20}).items)
		manager:tick()
		local titles=catalog:browse(saved.library_id,{limit=20}).items
		assert.equal(1,#titles);assert.equal("show",titles[1].kind)
		local seasons=catalog:episodes(titles[1].id,"owner")
		assert.equal(2,#seasons[1].episodes);assert.equal(1,seasons[1].episodes[1].episode)
		catalog:saveProgress("owner",seasons[1].episodes[1].id,5000,60000,time)
		time=time+Sources.RESYNC_S+1;manager:tick();manager:tick()
		assert.equal(2,started)
		assert.equal(5000,catalog:episodes(titles[1].id,"owner")[1].episodes[1].position_ms)
	end)
	it("briefly caches failed resolution, then allows a retry", function()
		manager.discovery.resolve = function(_, url, done) resolutions[#resolutions + 1] = { done = done } end
		local target = { id = 9, remote = cjson.encode({ url = "https://video.example/page", resolve = "webpage" }) }
		manager:open(target); resolutions[1].done(nil, "HTTP 403")
		assert.matches("403", manager:open(target).error); assert.equal(1, #resolutions)
		time = time + 30; assert.is_nil(manager:open(target)); assert.equal(2, #resolutions)
	end)
end)

local function api_fixture()
	local f = { routes = {}, pending = {}, now = 1000 }
	local discovery = { begin = function(_, body) return body and { id = "d1", state = "queued" } or nil, "Choose a provider." end,
		poll = function(_, id) return f.discovery_job and id == "d1" and f.discovery_job or nil end }
	local metadata = { status = function() return { configured = true } end,
		apply=function(_,id,body) f.applied={id=id,body=body};return true end,
		configure = function(_, token) if type(token) ~= "string" then return nil, "Token required" end; f.token = token; return true end,
		refresh = function(_, id) f.refresh_id = id; return true end,
		search = function(_, id, query, done) f.pending[#f.pending + 1] = { id = id, query = query, done = done } end,
		match = function(_, id, external_id, done) f.pending[#f.pending + 1] = { id = id, external_id = external_id, done = done } end }
	API.mount({ catalog = {}, metadata = metadata, now = function() return f.now end,
		status = function() return { status = 200, json = {} } end,
		sources = { discovery = discovery, importDiscovery = function(_, id, key)
			f.imported = { id = id, key = key }; return { library_id = 3, source_id = 4 }
		end },
		route = function(method, path, fn) f.routes[method .. " " .. path] = fn end })
	function f:call(method, path, body, params)
		return assert(self.routes[method .. " " .. path])({ body = body and cjson.encode(body) or "", params = params or {} })
	end
	return f
end

describe("asynchronous discovery and metadata HTTP API", function()
	it('accepts public metadata facts without a provider credential field',function()
		local f=api_fixture();local facts={provider='cinemeta',external_id='tt0120338',title='Titanic'}
		assert.equal(200,f:call('POST','/v1/items/:id/metadata/apply',facts,{id='7'}).status)
		assert.same({id=7,body=facts},f.applied)
	end)
	it("returns an accepted discovery job, pending polls, completed results and missing-job errors", function()
		local f = api_fixture()
		assert.equal(202, f:call("POST", "/v1/discover", { provider = "video-page" }).status)
		f.discovery_job = { id = "d1", state = "running" }
		assert.equal(202, f:call("GET", "/v1/discover/:id", nil, { id = "d1" }).status)
		f.discovery_job = { id = "d1", state = "ready", result = { items = {} } }
		assert.equal(200, f:call("GET", "/v1/discover/:id", nil, { id = "d1" }).status)
		assert.equal(404, f:call("GET", "/v1/discover/:id", nil, { id = "gone" }).status)
	end)
	it("imports a selected opaque result key and validates the import body", function()
		local f = api_fixture()
		local response = f:call("POST", "/v1/discover/:id/import", { key = "selected" }, { id = "d1" })
		assert.equal(201, response.status); assert.same({ id = "d1", key = "selected" }, f.imported)
		assert.equal(400, f:call("POST", "/v1/discover/:id/import", { key = 12 }, { id = "d1" }).status)
		assert.equal(400, f:call("POST", "/v1/discover/:id/import", { key = string.rep("x", 2049) }, { id = "d1" }).status)
	end)
	it("keeps metadata search/match deferred and returns their result through a separate job", function()
		local f = api_fixture()
		local search = f:call("POST", "/v1/items/:id/metadata/search", { query = "Film" }, { id = "7" })
		assert.equal(202, search.status); assert.equal(7, f.pending[1].id)
		assert.equal(202, f:call("GET", "/v1/metadata/jobs/:id", nil, { id = search.json.id }).status)
		f.pending[1].done({ candidates = { { id = 99, title = "Film" } } })
		local finished = f:call("GET", "/v1/metadata/jobs/:id", nil, { id = search.json.id })
		assert.equal(200, finished.status); assert.equal("ready", finished.json.state)
		assert.equal(99, finished.json.result.candidates[1].id)
		local match = f:call("POST", "/v1/items/:id/metadata/match", { external_id = 99 }, { id = "7" })
		assert.equal(202, match.status); assert.equal(99, f.pending[2].external_id)
		f.pending[2].done(nil, "Provider unavailable")
		local failed = f:call("GET", "/v1/metadata/jobs/:id", nil, { id = match.json.id })
		assert.equal("failed", failed.json.state); assert.equal("Provider unavailable", failed.json.error)
	end)
	it('bounds metadata jobs and exposes no remote credential configuration route', function()
		local f = api_fixture()
		assert.is_nil(f.routes['POST /v1/metadata/configure'])
		for _ = 1, 24 do assert.equal(202, f:call("POST", "/v1/items/:id/metadata/search", {}, { id = "1" }).status) end
		assert.equal(429, f:call("POST", "/v1/items/:id/metadata/search", {}, { id = "1" }).status)
		assert.equal(24, #f.pending)
		assert.equal(400, f:call("POST", "/v1/metadata/refresh", { work_id = -1 }).status)
	end)
	it("expires metadata polling after TTL without requiring another search", function()
		local saved_time = os.time
		local fake_time = 1000
		local ok, why = pcall(function()
			os.time = function() return fake_time end
			local f = api_fixture()
			local job = f:call("POST", "/v1/items/:id/metadata/search", {}, { id = "1" })
			f.pending[1].done({ candidates = {} }); fake_time = 1301
			assert.equal(404, f:call("GET", "/v1/metadata/jobs/:id", nil, { id = job.json.id }).status)
		end)
		os.time = saved_time
		assert(ok, why)
	end)
end)

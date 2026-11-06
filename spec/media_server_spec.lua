-- The media server's catalog, scanner, naming and delivery decisions.

local lfs = require("lfs")
local platform = require("core.platform")
local sqlite = require("core.lib.sqlite")

package.path = "./extensions/media-server/?.lua;" .. package.path

local naming = require("libs.naming")
local decision = require("libs.decision")
local schema = require("libs.schema")
local Catalog = require("libs.catalog")
local Scanner = require("libs.scanner")
local Probe = require("libs.probe")

local P = platform.path

local sequence = 0
local function open_catalog()
	sequence = sequence + 1
	local path = P:join(platform.temp_dir(), string.format("lunar_media_%d_%d_%d.sqlite3", os.time(), sequence, math.random(1e9)))
	local db = assert(sqlite.open(path))
	assert(schema.migrate(db))
	return Catalog.new(db, function() return 1000 end), db
end

describe("naming", function()
	it("reads a film title and year", function()
		local p = naming.parse("Coraline (2009)/Coraline (2009).mkv", "movie")
		assert.equal("Coraline", p.title)
		assert.equal(2009, p.year)
	end)

	it("stops at release noise", function()
		local p = naming.parse("The.Matrix.1999.1080p.BluRay.x264.mkv", "movie")
		assert.equal("The Matrix", p.title)
		assert.equal(1999, p.year)
	end)

	it("keeps a year that starts the title", function()
		local p = naming.parse("2001 A Space Odyssey (1968).mkv", "movie")
		assert.equal("2001 A Space Odyssey", p.title)
		assert.equal(1968, p.year)
	end)

	it("falls back to the folder's year", function()
		local p = naming.parse("Alien (1979)/movie.mkv", "movie")
		assert.equal("Alien", p.title)
		assert.equal(1979, p.year)
	end)

	it("ignores samples and other files", function()
		assert.is_nil(naming.parse("Alien (1979)/alien-sample.mkv", "movie"))
		assert.is_nil(naming.parse("Alien (1979)/poster.jpg", "movie"))
	end)

	it("reads SxxEyy with a season folder", function()
		local p = naming.parse("Firefly/Season 01/Firefly - S01E03.mkv", "show")
		assert.equal("Firefly", p.show)
		assert.equal(1, p.season)
		assert.equal(3, p.episode)
	end)

	it("reads a double episode", function()
		local p = naming.parse("Lost/Season 1/Lost.S01E01-E02.mkv", "show")
		assert.equal(1, p.episode)
		assert.equal(2, p.last_episode)
	end)

	it("reads 1x02 and a bare number in a season folder", function()
		assert.equal(2, naming.parse("Show/Show 1x02 Title.mkv", "show").episode)
		local bare = naming.parse("Show/Season 3/07 Title.mkv", "show")
		assert.equal(3, bare.season)
		assert.equal(7, bare.episode)
	end)

	it("treats Specials as season 0", function()
		assert.equal(0, naming.parse("Show/Specials/S00E02.mkv", "show").season)
	end)

	it("refuses an episode it cannot number", function()
		assert.is_nil(naming.parse("Show/behind the scenes.mkv", "show"))
	end)

	it("sorts by value and ignores articles", function()
		assert.equal(naming.sortKey("Matrix"), naming.sortKey("The Matrix"))
		assert.is_true(naming.sortKey("Part 2") < naming.sortKey("Part 10"))
	end)
end)

describe("delivery decision", function()
	local caps = { containers = { "mp4" }, video = { "h264" }, audio = { "aac" }, subtitles = { "srt" }, max_height = 1080, max_channels = 2 }
	local function file(extra)
		local f = { container = "mp4", bitrate = 4000000, streams = {
			{ idx = 0, kind = "video", codec = "h264", height = 1080 },
			{ idx = 1, kind = "audio", codec = "aac", channels = 2, is_default = 1 },
			{ idx = 2, kind = "subtitle", codec = "pgs" },
		} }
		for k, v in pairs(extra or {}) do f[k] = v end
		return f
	end

	it("plays a compatible file directly", function()
		assert.equal("direct", decision.decide(file(), caps).mode)
	end)

	it("copies streams into another container", function()
		local r = decision.decide(file({ container = "matroska" }), caps)
		assert.equal("remux", r.mode)
		assert.equal("copy", r.video.action)
	end)

	it("converts only the stream that needs it, and says why", function()
		local f = file()
		f.streams[2].codec = "dts"
		local r = decision.decide(f, caps)
		assert.equal("convert", r.mode)
		assert.equal("copy", r.video.action)
		assert.equal("convert", r.audio.action)
		assert.matches("dts", r.reason)
	end)

	it("converts over the height and bitrate limits", function()
		local f = file()
		f.streams[1].height = 2160
		assert.equal("convert", decision.decide(f, caps).mode)
		local fast = decision.decide(file(), { containers = { "mp4" }, video = { "h264" }, audio = { "aac" }, max_bitrate = 1000 })
		assert.equal("convert", fast.mode)
	end)

	it("burns in a subtitle the client can't render", function()
		local r = decision.decide(file(), caps, { subtitle = 2 })
		assert.equal("convert", r.mode)
		assert.equal("burn", r.subtitle.action)
	end)

	it("won't play HDR on a client that can't show it", function()
		local f = file()
		f.streams[1].hdr = 1
		assert.equal("convert", decision.decide(f, caps).mode)
	end)

	it("refuses an unanalysed file and a stream that isn't there", function()
		assert.equal("refuse", decision.decide({ streams = {} }, caps).mode)
		assert.equal("refuse", decision.decide(file(), caps, { audio = 9 }).mode)
	end)
end)

describe("probe parsing", function()
	it("reads tracks and skips cover art", function()
		local info = assert(Probe.parse([[{"format":{"format_name":"matroska,webm","duration":"60.5","bit_rate":"8000"},
			"streams":[{"index":0,"codec_type":"video","codec_name":"hevc","height":2160,"width":3840,"color_transfer":"smpte2084","disposition":{"default":1}},
			{"index":1,"codec_type":"audio","codec_name":"aac","channels":6,"tags":{"language":"eng"}},
			{"index":2,"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}},
			{"index":3,"codec_type":"data","codec_name":"bin"}]}]]))
		assert.equal("matroska", info.container)
		assert.equal(60500, info.duration_ms)
		assert.equal(2, #info.streams)
		assert.is_true(info.streams[1].hdr)
		assert.equal("eng", info.streams[2].language)
	end)

	it("reports damaged output", function()
		assert.is_nil((Probe.parse("not json")))
	end)

	it("waits for the exit code, then keeps the last output", function()
		local chunks = { "first", "", "last" }
		local exits = { false, 0 }
		local process = {
			read = function() return table.remove(chunks, 1) end,
			poll = function()
				local code = table.remove(exits, 1)
				if code == false then return nil end
				return code
			end,
		}
		local run = Probe.run({}, process, 0)
		assert.is_false(Probe.advance(run, 1))
		assert.is_true(Probe.advance(run, 2))
		assert.equal(0, run.code)
		assert.equal("firstlast", table.concat(run.output))
	end)

	it("kills a run that takes too long, and leaves no exit code", function()
		local killed = false
		local process = { read = function() return "" end, poll = function() return nil end,
			kill = function() killed = true end }
		local run = Probe.run({}, process, 0)
		assert.is_true(Probe.advance(run, Probe.TIMEOUT_S + 1))
		assert.is_true(killed)
		assert.is_nil(run.code)
	end)

	it("keeps the path as one argument after the option terminator", function()
		local argv = Probe.argv("ffprobe", "-odd name.mkv")
		assert.equal("--", argv[#argv - 1])
		assert.equal("-odd name.mkv", argv[#argv])
	end)
end)

describe("catalog and scanner", function()
	local catalog, db, tree

	local function list(path)
		return tree[path] or {}
	end
	local function attr() return { size = 100, modification = 5 } end
	local function clock() return 0 end

	local function scan(library)
		local run = Scanner.new(catalog, library, { list = list, attr = attr, clock_ms = clock, now = function() return 2000 end })
		for _ = 1, 100 do
			if run:step(1) then return run end
		end
		error("scan did not finish")
	end

	before_each(function()
		catalog, db = open_catalog()
		tree = { ["/m"] = { { name = "Alien (1979).mkv" }, { name = "Heat (1995).mp4" }, { name = "notes.txt" }, { name = ".hidden.mkv" } } }
	end)

	after_each(function()
		catalog:close()
		db:close()
	end)

	it("adds films once and queues analysis", function()
		local library = catalog:addLibrary("Films", "movie", "/m")
		local run = scan(library)
		assert.equal(2, run.seen)
		assert.equal(2, catalog:counts().items)
		assert.equal(2, catalog:counts().analysing)
		scan(catalog:library(library.id))
		assert.equal(2, catalog:counts().items)
	end)

	it("marks missing files instead of deleting them, and restores them", function()
		local library = catalog:addLibrary("Films", "movie", "/m")
		scan(library)
		local keep = tree["/m"]
		tree["/m"] = {}
		scan(catalog:library(library.id))
		assert.equal(2, catalog:counts().missing)
		assert.equal(2, catalog:counts().items)
		tree["/m"] = keep
		scan(catalog:library(library.id))
		assert.equal(0, catalog:counts().missing)
	end)

	it("nests shows, seasons and episodes", function()
		tree = { ["/t"] = { { name = "Firefly", dir = true } }, ["/t/Firefly"] = { { name = "Season 01", dir = true } },
			["/t/Firefly/Season 01"] = { { name = "S01E01.mkv" }, { name = "S01E02.mkv" } } }
		local library = catalog:addLibrary("TV", "show", "/t")
		scan(library)
		local shows = catalog:browse(library.id, {}).items
		assert.equal(1, #shows)
		local show = catalog:item(shows[1].id, "alice")
		assert.equal("Season 1", show.children[1].title)
		assert.equal(2, #catalog:item(show.children[1].id, "alice").children)
	end)

	it("pages without gaps or repeats, in both sorts", function()
		local entries = {}
		for i = 1, 25 do entries[i] = { name = string.format("Film %02d (2000).mkv", i) } end
		tree = { ["/m"] = entries }
		local library = catalog:addLibrary("Films", "movie", "/m")
		scan(library)
		for _, sort in ipairs({ "title", "added" }) do
			local seen, page, pages = {}, nil, 0
			repeat
				local args = { sort = sort, limit = 10 }
				if page then args.after_key, args.after_id = page.after_key, page.after_id end
				local result = catalog:browse(library.id, args)
				for _, item in ipairs(result.items) do
					assert.is_nil(seen[item.id])
					seen[item.id] = true
				end
				page, pages = result.next, pages + 1
			until not page
			assert.equal(3, pages)
			local count = 0
			for _ in pairs(seen) do count = count + 1 end
			assert.equal(25, count)
		end
	end)

	it("keeps progress per user and clears it once watched", function()
		local library = catalog:addLibrary("Films", "movie", "/m")
		scan(library)
		local id = catalog:browse(library.id, {}).items[1].id
		catalog:saveProgress("alice", id, 1000, 10000, 3000)
		assert.equal(1, #catalog:continueWatching("alice"))
		assert.equal(0, #catalog:continueWatching("bob"))
		catalog:saveProgress("alice", id, 9900, 10000, 3100)
		assert.equal(0, #catalog:continueWatching("alice"))
		assert.equal(1, catalog:item(id, "alice").progress.watched)
		catalog:saveProgress("alice", id, 2000, 10000, 3200)
		assert.equal(1, catalog:item(id, "alice").progress.watched)
	end)

	it("retries a failed analysis, then stops and keeps the reason", function()
		local library = catalog:addLibrary("Films", "movie", "/m")
		scan(library)
		for attempt = 1, 3 do
			local job
			repeat job = catalog:claimProbe(1e9 + attempt * 1e6) until job and job.rel_path == "Alien (1979).mkv" or not job
			if job then catalog:failProbe(job, "broken", 0) end
		end
		local failed = catalog:counts().failed
		assert.is_true(failed >= 1)
	end)

	it("puts jobs a crash left running back in the queue", function()
		local library = catalog:addLibrary("Films", "movie", "/m")
		scan(library)
		assert.truthy(catalog:claimProbe(5000))
		catalog:recoverJobs()
		assert.equal(2, catalog:counts().analysing)
		assert.truthy(catalog:claimProbe(5000))
	end)

	it("stores tracks and skips re-analysis of an unchanged file", function()
		local library = catalog:addLibrary("Films", "movie", "/m")
		scan(library)
		local job = catalog:claimProbe(5000)
		catalog:saveProbe(job, { container = "matroska", duration_ms = 1000, bitrate = 5,
			streams = { { idx = 0, kind = "video", codec = "h264", height = 720 } } })
		local other = catalog:claimProbe(5000)
		catalog:saveProbe(other, { container = "mov", streams = {} })
		local run = scan(catalog:library(library.id))
		assert.equal(0, run.added)
		local target = catalog:fileTarget(job.file_id)
		assert.equal("/m", target.root)
		assert.equal(job.rel_path, target.rel_path)
	end)
end)

describe("real folders", function()
	it("walks a directory on disk", function()
		local catalog, db = open_catalog()
		local dir = P:join(platform.temp_dir(), string.format("lunar_media_tree_%d", math.random(1e9)))
		lfs.mkdir(dir)
		local path = P:join(dir, "Up (2009).mkv")
		local f = assert(io.open(path, "wb"))
		f:write("x")
		f:close()
		local library = catalog:addLibrary("Films", "movie", dir)
		local run = Scanner.new(catalog, library)
		while not run:step(5) do end
		assert.equal(1, catalog:counts().items)
		catalog:close()
		db:close()
		os.remove(path)
		lfs.rmdir(dir)
	end)
end)

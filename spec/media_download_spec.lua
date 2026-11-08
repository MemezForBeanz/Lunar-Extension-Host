local lfs = require("lfs")
local socket = require("socket")
local async = require("core.lib.async")
local copas = async.copas
local http = require("core.lib.http")
local sqlite = require("core.lib.sqlite")
local cjson = require("cjson")

package.path = "./extensions/media-server/?.lua;" .. package.path

local schema = require("libs.schema")
local Catalog = require("libs.catalog")
local Sources = require("libs.sources")
local platform = require("core.platform")

describe("media downloads", function()
	if not async.available then
		pending("copas is not on the test path")
		return
	end

	local server, base, catalog, db, root, sources
	local routes = {
		["/media"] = { 200, "owned-media-fixture", "Content-Type: video/mp4\r\n" },
		["/redirect"] = { 302, "<html>redirect</html>", "Location: /media\r\n" },
		["/html"] = { 200, "<html>not media</html>", "Content-Type: text/html\r\n" },
		["/empty"] = { 200, "", "Content-Type: video/mp4\r\n" },
		["/mismatch"] = { 200, "short", "Content-Type: video/mp4\r\nContent-Length: 99\r\n" },
	}

	local function pump_until(predicate)
		local deadline = socket.gettime() + 5
		while not predicate() and socket.gettime() < deadline do copas.step(0.01) end
		assert.is_true(predicate(), "download fixture did not finish")
	end

	local function add_job(path, name)
		local row = catalog:addDownload({
			library_id = catalog:library(1).id, source_id = nil, provider_id = "fixture",
			source_url = base .. path, rel_path = name, temp_path = root .. "/" .. name .. ".lunar-part",
			title = name, now = os.time(),
		})
		sources:_start_download(row)
		pump_until(function()
			local current = catalog:download(row.id)
			return current.state ~= "running" and current.state ~= "queued"
		end)
		return catalog:download(row.id)
	end

	before_each(function()
		server = assert(socket.bind("127.0.0.1", 0))
		local _, port = server:getsockname()
		base = "http://127.0.0.1:" .. port
		copas.addserver(server, function(c)
			c = copas.wrap(c)
			local line = c:receive("*l")
			local path = line and line:match("^%u+ (%S+)") or "/"
			repeat
				local header = c:receive("*l")
			until not header or header == ""
			local response = routes[path] or { 404, "missing" }
			local headers = response[3] or ""
			local length = headers:lower():find("content-length:", 1, true) and "" or ("Content-Length: " .. #response[2] .. "\r\n")
			c:send(string.format("HTTP/1.1 %d Fixture\r\n%s%sConnection: close\r\n\r\n%s",
				response[1], length, headers, response[2]))
			c:close()
		end)
		local path = platform.path:join(platform.temp_dir(), "lunar_download_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000000)))
		assert(lfs.mkdir(path))
		root = path
		db = assert(sqlite.open(root .. "/catalog.sqlite3"))
		assert(schema.migrate(db))
		catalog = Catalog.new(db)
		assert(lfs.mkdir(root .. "/library"))
		catalog:addLibrary("Fixture", "movie", root .. "/library")
		sources = Sources.new({
			catalog = catalog, http = function(request, done)
				local handle = { cancelled = false }
				async.run(function() return http.request(request) end, function(ok, response, why)
					if not handle.cancelled then done(ok and response or nil, ok and why or response) end
				end)
				function handle.cancel() handle.cancelled = true end
				return handle
			end, now = os.time, log = {},
		})
	end)

	after_each(function()
		sources:close()
		catalog:close()
		db:close()
		server:close()
		for _, name in ipairs({ "media.mp4", "redirect.mp4", "html.mp4", "empty.mp4", "mismatch.mp4", "archive.mp4", "mockArchive.mp4" }) do
			os.remove(root .. "/library/" .. name)
			os.remove(root .. "/" .. name .. ".lunar-part")
		end
		os.remove(root .. "/catalog.sqlite3")
		lfs.rmdir(root .. "/library")
		lfs.rmdir(root)
	end)

	it("streams a redirected media response and records provenance after scanning", function()
		local row = add_job("/redirect", "redirect.mp4")
		assert.equal("complete", row.state)
		local file = assert(io.open(root .. "/library/redirect.mp4", "rb"))
		assert.equal("owned-media-fixture", file:read("*a"))
		file:close()
		assert.is_nil(catalog:_one("SELECT origin_url FROM files WHERE rel_path = ?", "redirect.mp4"))
		catalog:noteFile(1, "redirect.mp4", 18, 1, 1, { kind = "movie", title = "Redirect" })
		catalog:applyDownloadOrigins(1)
		assert.equal(base .. "/redirect", catalog:_one("SELECT origin_url FROM files WHERE rel_path = ?", "redirect.mp4").origin_url)
	end)

	it("rejects HTML, empty, and mismatched direct responses", function()
		for _, item in ipairs({ { "/html", "html.mp4" }, { "/empty", "empty.mp4" }, { "/mismatch", "mismatch.mp4" } }) do
			local row = add_job(item[1], item[2])
			assert.equal("failed", row.state, item[1] .. ": " .. tostring(row.error))
			assert.is_nil(lfs.attributes(root .. "/library/" .. item[2]))
		end
	end)

	it("ignores late sink and callback activity after cancellation", function()
		local pending_sink, pending_done, cancelled = nil, nil, false
		sources.http = function(request, done)
			pending_sink, pending_done = request.sink, done
			return { cancel = function() cancelled = true end }
		end
		local row = catalog:addDownload({ library_id = 1, provider_id = "fixture", source_url = base .. "/media",
			rel_path = "media.mp4", temp_path = root .. "/media.mp4.lunar-part", title = "media", now = os.time() })
		sources:_start_download(row)
		assert.is_true(sources:cancelDownload(row.id))
		assert.is_true(cancelled)
		assert.is_nil(pending_sink("late bytes"))
		pending_done({ ok = true, status = 200, headers = { ["content-length"] = "10" } })
		assert.equal("cancelled", catalog:download(row.id).state)
	end)

	it("resolves an Archive result lazily while keeping canonical provenance", function()
		local metadata_requests, transfer_requests = 0, 0
		sources.discovery.entry = function()
			return { key = "mockArchive", title = "Owned Fixture Episode", resolve = "archive" },
				{ id = "archive-classic-tv", kind = "archive" }
		end
		sources.http = function(request, done)
			local handle = { cancelled = false }
			if request.url == "https://archive.org/metadata/mockArchive" then
				metadata_requests = metadata_requests + 1
				assert.equal(16 * 1024 * 1024, request.max_bytes)
				done({ ok = true, status = 200, body = cjson.encode({
					files = { { name = "owned-episode.mp4" } },
				}), headers = {} })
			else
				transfer_requests = transfer_requests + 1
				assert.equal("https://archive.org/download/mockArchive/owned-episode.mp4", request.url)
				assert.is_true(request.sink("owned-archive-bytes"))
				done({ ok = true, status = 200, headers = { ["content-length"] = "19" } })
			end
			function handle.cancel() handle.cancelled = true end
			return handle
		end
		local saved = assert(sources:downloadDiscovery("owned-discovery", "mockArchive", 1))
		assert.equal("complete", saved.state)
		assert.equal(1, metadata_requests)
		assert.equal(1, transfer_requests)
		local row = catalog:download(saved.id)
		assert.equal("https://archive.org/details/mockArchive", row.source_url)
		assert.equal("https://archive.org/download/mockArchive/owned-episode.mp4", row.transfer_url)
		local file = assert(io.open(root .. "/library/mockArchive.mp4", "rb"))
		assert.equal("owned-archive-bytes", file:read("*a"))
		file:close()
	end)

	it("recovers persisted running jobs and does not expose transport fields", function()
		local row = catalog:addDownload({ library_id = 1, provider_id = "fixture", source_url = base .. "/media",
			rel_path = "media.mp4", temp_path = root .. "/media.mp4.lunar-part", title = "media",
			request_headers = '{"Authorization":"secret"}', now = os.time() })
		catalog:updateDownload(row.id, { state = "running", updated_at = os.time() })
		catalog:recoverJobs()
		assert.equal("queued", catalog:download(row.id).state)
		assert.is_nil(catalog:publicDownload(catalog:download(row.id)).request_headers)
		sources:resumeDownloads()
		pump_until(function() return catalog:download(row.id).state == "complete" end)
	end)

	it("resolves a website episode to a file and keeps the episode page as provenance", function()
		sources.discovery.entry = function()
			return { key = "episode", title = "Episode", resolve = "webpage", url = base .. "/watch",
				source_url = base .. "/watch" }, { id = "video-page", kind = "website" }
		end
		sources.discovery.resolve = function(_, address, done)
			assert.equals(base .. "/watch", address)
			done({ url = base .. "/media", headers = { "Referer: " .. address } })
		end
		local saved = assert(sources:downloadDiscovery("owned", "episode", 1))
		pump_until(function() return catalog:download(saved.id).state == "complete" end)
		local row = catalog:download(saved.id)
		assert.equals(base .. "/watch", row.source_url)
		assert.equals(base .. "/media", row.transfer_url)
		local file = assert(io.open(root .. "/library/episode.mp4", "rb"))
		assert.equals("owned-media-fixture", file:read("*a")); file:close()
		os.remove(root .. "/library/episode.mp4")
	end)

	it("rejects a resolved HLS manifest instead of saving it as a media file", function()
		sources.discovery.entry = function()
			return { key = "hls", title = "HLS", resolve = "webpage", url = base .. "/watch" },
				{ id = "video-page", kind = "website" }
		end
		sources.discovery.resolve = function(_, _, done) done({ url = base .. "/stream.m3u8?token=fixture" }) end
		local saved = assert(sources:downloadDiscovery("owned", "hls", 1))
		assert.equals("failed", saved.state)
		assert.matches("HLS", saved.error)
		assert.is_nil(lfs.attributes(root .. "/library/hls.mp4"))
	end)

	it("reserves different paths for simultaneous downloads of the same result", function()
		sources.discovery.entry = function()
			return { key = "collision.mp4", title = "Same episode", resolve = "direct", url = base .. "/media" },
				{ id = "video-page", kind = "website" }
		end
		sources.http = function() return { cancel = function() end } end
		local first = assert(sources:downloadDiscovery("owned", "same", 1))
		local second = assert(sources:downloadDiscovery("owned", "same", 1))
		assert.not_equals(first.rel_path, second.rel_path)
		assert.not_equals(catalog:download(first.id).temp_path, catalog:download(second.id).temp_path)
		assert(sources:cancelDownload(first.id)); assert(sources:cancelDownload(second.id))
	end)
end)

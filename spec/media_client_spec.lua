-- The desktop client's mapping from server answers to the pages' model.

package.path = "./extensions/media/?.lua;" .. package.path

local Client = require("libs.client")

local function fake_http(answers)
	local seen = {}
	return function(request, done)
		seen[#seen + 1] = request
		local answer = answers[request.url:match("/ext/media%-server(.*)$")]
		if not answer then return done({ ok = false, status = 404 }) end
		done({ ok = true, status = answer.status or 200, body = answer.body })
	end, seen
end

describe("media client", function()
	it("splits films and shows and fills the sources", function()
		local model = Client.modelFrom({
			{ items = { { id = 1, kind = "movie", title = "Alien", year = 1979, added_at = 0 } } },
			{ items = { { id = 2, kind = "show", title = "Lost", year = 2004 } } },
		}, { files = 2, missing = 1, analysing = 0, failed = 0, analysis = "off" })
		assert.equal(1, #model.films)
		assert.equal(1, #model.shows)
		assert.equal(1, model.sources[2].count)
		assert.equal("1970-01-01", model.films[1].added)
		assert.equal(1, model.server.missing)
		assert.is_false(model.sample)
	end)

	it("links continue watching to the same items", function()
		local model = Client.modelFrom({ { items = { { id = 7, kind = "movie", title = "Heat" } } } }, {},
			{ { id = 7, position_ms = 5000 }, { id = 99, position_ms = 1 } })
		assert.equal(1, #model.continuing)
		assert.is_true(model.continuing[1] == model.films[1])
		assert.equal(5000, model.films[1].position_ms)
	end)

	it("reads facts from the first file", function()
		local item = Client.applyDetail({}, {
			files = { { id = 3, size = 2147483648, bitrate = 8000000, duration_ms = 600000, rel_path = "a.mkv",
				streams = { { kind = "video", codec = "hevc", height = 2160, hdr = 1 },
					{ kind = "audio", codec = "eac3", channels = 6 } } } },
			progress = { position_ms = 60000, watched = 0 },
		})
		assert.equal(3, item.file_id)
		assert.equal("2160p", item.resolution)
		assert.equal("HEVC", item.codec)
		assert.equal("HDR", item.dynamic)
		assert.equal("EAC3 6 ch", item.audio)
		assert.equal(2, item.size_gb)
		assert.equal(10, item.minutes)
		assert.equal(0.1, item.progress)
	end)

	it("tells an offline file and a finished one apart", function()
		local item = Client.applyDetail({}, { files = { { id = 1, missing_at = 5, duration_ms = 1000 } },
			progress = { position_ms = 0, watched = 1 } })
		assert.is_true(item.offline)
		assert.equal(1, item.progress)
	end)

	it("sends the token and never a path", function()
		local http, seen = fake_http({ ["/v1/items/4"] = { body = '{"id":4}' } })
		local client = Client.new(http, "http://host:1/", "secret")
		local got
		client:detail(4, function(detail) got = detail end)
		assert.equal(4, got.id)
		assert.equal("http://host:1/ext/media-server/v1/items/4", seen[1].url)
		assert.equal("Bearer secret", seen[1].headers.Authorization)
		assert.equal("http://host:1/ext/media-server/v1/files/9/stream", client:streamUrl(9))
	end)

	it("reports a refusal and an unreachable server", function()
		local client = Client.new(fake_http({}), "http://host:1", "t")
		local _, why
		client:detail(1, function(_, err) why = err end)
		assert.matches("404", why)
		local down = Client.new(function(_, done) done(nil, "refused") end, "http://host:1", "t")
		down:detail(1, function(_, err) why = err end)
		assert.equal("refused", why)
	end)

	it("follows pages to the end of a library", function()
		local http = fake_http({
			["/v1/status"] = { body = '{"files":3}' },
			["/v1/libraries"] = { body = '{"libraries":[{"id":1}]}' },
			["/v1/libraries/1/items?limit=200"] = { body = '{"items":[{"id":1,"kind":"movie","title":"A"}],"next":{"after_key":"a b","after_id":1}}' },
			["/v1/libraries/1/items?limit=200&after_key=a%20b&after_id=1"] = { body = '{"items":[{"id":2,"kind":"movie","title":"B"}]}' },
			["/v1/continue"] = { body = '{"items":[]}' },
		})
		local model, why
		Client.new(http, "http://host:1", "t"):load(function(m, err) model, why = m, err end)
		assert.is_nil(why)
		assert.equal(2, #model.films)
	end)
end)

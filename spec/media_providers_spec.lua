package.path = "./extensions/media-server/?.lua;" .. package.path
local providers = require("libs.providers")

describe("the provider database", function()
	it("ships no provider that needs code", function()
		for _, provider in ipairs(providers.BUILTIN) do
			assert.is_true(providers.KINDS[provider.kind])
			assert.is_truthy(providers.validate(provider))
		end
	end)

	it("keeps torrents off until someone turns them on", function()
		for _, provider in ipairs(providers.BUILTIN) do
			if provider.kind == "torrent" then
				assert.is_true(provider.off_by_default)
				assert.is_truthy(provider.summary:find("uploads", 1, true))
			end
		end
	end)

	it("takes a new provider that is only data", function()
		local clean = assert(providers.validate({ id = "club", name = "Film club", kind = "feed",
			fields = { { id = "url", label = "Address" } }, script = "os.execute('x')" }))
		assert.is_nil(clean.script)
	end)

	it("refuses a kind it doesn't know, and a bad id", function()
		assert.is_nil(providers.validate({ id = "x", name = "X", kind = "lua" }))
		assert.is_nil(providers.validate({ id = "../x", name = "X", kind = "feed" }))
		assert.is_nil(providers.validate("nope"))
	end)

	it("only fetches web addresses", function()
		assert.is_true(providers.isWebAddress("https://example.org/a"))
		assert.is_false(providers.isWebAddress("file:///etc/passwd"))
		assert.is_false(providers.isWebAddress("javascript:alert(1)"))
		assert.is_false(providers.isWebAddress("https://a b"))
		assert.is_nil(providers.request({ kind = "m3u" }, { url = "file:///etc/passwd" }))
	end)
end)

describe("reading sources", function()
	it("reads an M3U playlist", function()
		local entries = providers.parseM3u("#EXTM3U\n#EXTINF:-1,Night Mail (1936)\nhttps://a.example/n.mp4\nfile:///x\n#EXTINF:0,Second\nhttps://a.example/b.mkv\n")
		assert.equal(2, #entries)
		assert.equal("Night Mail", entries[1].title)
		assert.equal(1936, entries[1].year)
		assert.equal("https://a.example/n.mp4", entries[1].url)
	end)

	it("reads a feed's video enclosures and skips audio", function()
		local entries = providers.parseFeed([[<rss><channel>
			<item><title>Episode &amp; One</title><description>&lt;p&gt;Hi&lt;/p&gt;</description>
			<enclosure url="https://a.example/1.mp4" type="video/mp4"/></item>
			<item><title>Audio</title><enclosure url="https://a.example/2.mp3" type="audio/mpeg"/></item>
		</channel></rss>]])
		assert.equal(1, #entries)
		assert.equal("Episode & One", entries[1].title)
		assert.equal("Hi", entries[1].overview)
	end)

	it("reads a folder listing and stays inside it", function()
		local entries = providers.parseIndex([[<a href="Night%20Mail%20(1936).mp4">x</a><a href="../up.mp4">y</a>
			<a href="readme.txt">z</a><a href="./b.mkv">w</a>]], "https://a.example/films")
		assert.equal(2, #entries)
		assert.equal("Night Mail", entries[1].title)
		assert.equal(1936, entries[1].year)
		assert.equal("https://a.example/films/Night%20Mail%20(1936).mp4", entries[1].url)
		assert.equal("https://a.example/films/b.mkv", entries[2].url)
	end)

	it("reads an archive search", function()
		local entries = providers.parseArchive('{"response":{"docs":[{"identifier":"night_mail","title":"Night Mail","date":"1936-01-01T00:00:00Z","description":"<p>A train.</p>"},{"identifier":"../bad","title":"No"}]}}')
		assert.equal(1, #entries)
		assert.equal(1936, entries[1].year)
		assert.equal("A train.", entries[1].overview)
		assert.equal("archive", entries[1].resolve)
	end)

	it("picks the best playable archive file", function()
		local url = providers.archiveFile('{"files":[{"name":"a.ogv"},{"name":"a_512kb.mp4"},{"name":"My Film.mp4"},{"name":"a.txt"}]}', "item")
		assert.equal("https://archive.org/download/item/My%20Film.mp4", url)
		assert.is_nil(providers.archiveFile('{"files":[{"name":"a.txt"}]}', "item"))
		assert.is_nil(providers.archiveFile("not json", "item"))
	end)

	it("reads a Jellyfin library", function()
		local entries = providers.parseJellyfin('{"Items":[{"Id":"abc123","Name":"Marrow","ProductionYear":2020,"RunTimeTicks":54000000000,"Overview":"Bones."}]}', "https://nas.example/")
		assert.equal("Marrow", entries[1].title)
		assert.equal(5400000, entries[1].duration_ms)
		assert.equal("https://nas.example/Videos/abc123/stream?static=true", entries[1].url)
		assert.equal("key", entries[1].auth)
	end)

	it("reads magnet links someone added", function()
		local entries = providers.parseLinks("magnet:?xt=urn:btih:ABCDEF0123&dn=Night+Mail+(1936)\nnot a link\n")
		assert.equal(1, #entries)
		assert.equal("Night Mail", entries[1].title)
		assert.equal("abcdef0123", entries[1].key)
		assert.equal("torrent", entries[1].resolve)
	end)

	it("copes with nonsense", function()
		assert.same({}, providers.parseArchive("<html>"))
		assert.same({}, providers.parseJellyfin("<html>", "https://a.example"))
		assert.same({}, providers.parseFeed("nothing"))
		assert.same({}, providers.parseM3u(""))
	end)

	it("builds the request each kind needs", function()
		local archive = assert(providers.request({ kind = "archive", config = { collection = "feature_films" } }, {}))
		assert.is_truthy(archive.url:find("feature_films", 1, true))
		local jellyfin = assert(providers.request({ kind = "jellyfin" }, { url = "https://n.example/", key = "k" }))
		assert.equal("k", jellyfin.headers["X-Emby-Token"])
		assert.equal("links", providers.request({ kind = "torrent" }, { links = "links" }).local_text)
	end)
end)

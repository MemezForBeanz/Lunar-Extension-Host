-- Artwork found beside files, frames taken from them, and the desktop's picture cache.

package.path = "./extensions/media-server/?.lua;./extensions/media/?.lua;" .. package.path

local art = require("libs.art")
local artcache = require("libs.artcache")

local function folders(map)
	local out = {}
	for folder, names in pairs(map) do
		out[folder] = {}
		for _, name in ipairs(names) do out[folder][name:lower()] = name end
	end
	return out
end

describe("finding art beside files", function()
	it("prefers a picture named after the film", function()
		local found = art.find("Marrow (2020)/Marrow (2020).mkv",
			folders({ ["Marrow (2020)"] = { "poster.jpg", "Marrow (2020)-poster.png", "fanart.jpg" } }), "movie")
		assert.equal("Marrow (2020)/Marrow (2020)-poster.png", found.poster)
		assert.equal("Marrow (2020)/fanart.jpg", found.backdrop)
	end)

	it("accepts the common names, whatever their case", function()
		local found = art.find("Film/Film.mkv", folders({ Film = { "Folder.JPG", "Background.jpeg" } }), "movie")
		assert.equal("Film/Folder.JPG", found.poster)
		assert.equal("Film/Background.jpeg", found.backdrop)
	end)

	it("uses the show's folder for every episode", function()
		local found = art.find("Ledger/Season 1/Ledger S01E02.mkv",
			folders({ Ledger = { "poster.jpg" }, ["Ledger/Season 1"] = { "poster.jpg" } }), "show")
		assert.equal("Ledger/poster.jpg", found.poster)
	end)

	it("finds nothing in a bare folder", function()
		assert.same({}, art.find("Film/Film.mkv", folders({ Film = {} }), "movie"))
	end)

	it("handles a file at the library root", function()
		local found = art.find("Film.mkv", folders({ [""] = { "Film-fanart.png" } }), "movie")
		assert.equal("Film-fanart.png", found.backdrop)
	end)

	it("knows a picture when it sees one", function()
		assert.is_true(art.isImage("a.JPG"))
		assert.is_false(art.isImage("a.mkv"))
		assert.equal("image/png", art.mime("x/a.PNG"))
		assert.equal("image/jpeg", art.mime("x/a.jpg"))
	end)
end)

describe("taking a frame", function()
	it("looks a fifth of the way in", function()
		assert.equal(600, art.frameAt(3000000))
		assert.equal(0, art.frameAt(nil))
	end)

	it("passes paths as single arguments", function()
		local argv = art.frameArgv("ffmpeg", "a b.mkv", "o.jpg", 10)
		assert.equal("ffmpeg", argv[1])
		assert.equal("o.jpg", argv[#argv])
		local found = false
		for _, value in ipairs(argv) do found = found or value == "a b.mkv" end
		assert.is_true(found)
	end)
end)

describe("the desktop's picture cache", function()
	local function make(present)
		local fetched, written, arrivals = {}, {}, 0
		local cache = artcache.new({ dir = "d",
			fetch = function(id, kind, done) fetched[#fetched + 1] = { id, kind, done } end,
			exists = function(path) return present and present[path] == true end,
			write = function(path, bytes) written[path] = bytes; return true end,
			on_arrival = function() arrivals = arrivals + 1 end })
		return cache, fetched, written, function() return arrivals end
	end

	it("paints from disk without fetching", function()
		local cache, fetched = make({ ["d/1-poster.img"] = true })
		assert.equal("d/1-poster.img", cache:get(1, "poster"))
		assert.equal(0, #fetched)
	end)

	it("fetches once, then has the picture", function()
		local cache, fetched, written, arrivals = make()
		assert.is_nil(cache:get(1, "poster"))
		assert.is_nil(cache:get(1, "poster"))
		assert.equal(1, #fetched)
		fetched[1][3]("bytes")
		assert.equal("bytes", written["d/1-poster.img"])
		assert.equal(1, arrivals())
		assert.equal("d/1-poster.img", cache:get(1, "poster"))
	end)

	it("doesn't keep asking for a picture that failed", function()
		local cache, fetched = make()
		cache:get(2, "backdrop")
		fetched[1][3](nil)
		assert.is_nil(cache:get(2, "backdrop"))
		assert.equal(1, #fetched)
	end)

	it("limits how many fetches run at once", function()
		local cache, fetched = make()
		for id = 1, artcache.MAX_FETCHES + 3 do cache:get(id, "poster") end
		assert.equal(artcache.MAX_FETCHES, #fetched)
		fetched[1][3]("x")
		assert.equal(artcache.MAX_FETCHES + 1, #fetched)
	end)

	it("uses the other shape when one is missing, and nothing when there is no art", function()
		local cache = make({ ["d/3-backdrop.img"] = true })
		assert.equal("d/3-backdrop.img", cache:best({ id = 3, art = { backdrop = true } }, "poster"))
		assert.is_nil(cache:best({ id = 4, art = {} }, "poster"))
	end)

	it("reads the server's list of kinds", function()
		assert.same({ poster = true, backdrop = true }, artcache.kinds("poster,backdrop"))
		assert.same({}, artcache.kinds(nil))
	end)
end)

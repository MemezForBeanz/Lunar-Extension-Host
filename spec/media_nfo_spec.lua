package.path = "./extensions/media-server/?.lua;" .. package.path
local nfo = require("libs.nfo")

local SAMPLE = [==[<?xml version="1.0" encoding="UTF-8"?>
<movie>
  <title>The Salt Line</title>
  <plot><![CDATA[A surveyor returns & finds the map changed.]]></plot>
  <year>2021</year>
  <rating>7.4</rating>
  <mpaa>PG-13</mpaa>
  <studio>Tidewater</studio>
  <runtime>128</runtime>
  <genre>Drama</genre>
  <genre>Mystery</genre>
  <actor><name>Ana Reyes</name><role>Surveyor</role></actor>
  <actor><name>Tom &amp; Jo</name></actor>
</movie>]==]

describe(".nfo files", function()
	it("reads the facts people keep beside a film", function()
		local facts = nfo.parse(SAMPLE)
		assert.equal("The Salt Line", facts.title)
		assert.equal("A surveyor returns & finds the map changed.", facts.overview)
		assert.equal(2021, facts.year)
		assert.equal(7.4, facts.rating)
		assert.equal("PG-13", facts.content_rating)
		assert.equal(128, facts.minutes)
		assert.same({ "Drama", "Mystery" }, facts.genres)
		assert.same({ "Ana Reyes", "Tom & Jo" }, facts.people)
	end)

	it("takes a year from a premiere date", function()
		assert.equal(2019, nfo.parse("<movie><premiered>2019-03-01</premiered></movie>").year)
	end)

	it("ignores text that isn't an .nfo, and an impossible rating", function()
		assert.is_nil(nfo.parse("https://example.org/title/tt0000000"))
		assert.is_nil(nfo.parse(nil))
		assert.is_nil(nfo.parse("<movie><rating>87</rating></movie>").rating)
	end)

	it("refuses an oversized file", function()
		assert.is_nil(nfo.parse("<movie>" .. string.rep("x", nfo.MAX_BYTES) .. "</movie>"))
	end)

	it("limits how much one file can add", function()
		local parts = { "<movie>" }
		for i = 1, 100 do parts[#parts + 1] = "<genre>g" .. i .. "</genre>" end
		parts[#parts + 1] = "</movie>"
		assert.equal(nfo.MAX_LIST, #nfo.parse(table.concat(parts)).genres)
	end)

	it("finds a film's file, by name first", function()
		local folders = { Film = { ["film.nfo"] = "Film.nfo", ["movie.nfo"] = "movie.nfo" } }
		assert.equal("Film/Film.nfo", nfo.find("Film/Film.mkv", folders, "movie"))
		assert.equal("Other/movie.nfo", nfo.find("Other/x.mkv", { Other = { ["movie.nfo"] = "movie.nfo" } }, "movie"))
		assert.is_nil(nfo.find("None/x.mkv", {}, "movie"))
	end)

	it("finds a show's file above its seasons", function()
		local folders = { Ledger = { ["tvshow.nfo"] = "tvshow.nfo" } }
		assert.equal("Ledger/tvshow.nfo", nfo.find("Ledger/Season 1/e.mkv", folders, "show"))
	end)
end)

describe("embedded tags", function()
	it("reads them in any case", function()
		local facts = nfo.fromTags({ DESCRIPTION = "A film.", Genre = "Drama; Mystery" })
		assert.equal("A film.", facts.overview)
		assert.same({ "Drama", "Mystery" }, facts.genres)
	end)

	it("copes with no tags", function()
		assert.same({ genres = {} }, nfo.fromTags(nil))
	end)
end)

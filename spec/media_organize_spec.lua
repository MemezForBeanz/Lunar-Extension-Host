package.path = "./extensions/media/?.lua;" .. package.path
local organize = require("libs.organize")

local films = {
	{ title = "The Salt Line", year = 2021, resolution = "2160p", progress = 0.4, minutes = 128, genres = { "Drama" } },
	{ title = "Glass Harbour", year = 2019, resolution = "1080p", progress = 0, minutes = 104, genres = { "Drama", "Mystery" } },
	{ title = "Northern Static", year = 1998, resolution = "2160p", progress = 1, minutes = 141, genres = { "Thriller" } },
}

local function titles(list)
	local out = {}
	for i, item in ipairs(list) do out[i] = item.title end
	return out
end

describe("rules", function()
	it("keeps everything with no rules", function()
		assert.equal(3, #organize.apply(films, { rules = {} }))
		assert.equal(3, #organize.apply(films, nil))
	end)

	it("needs every rule with match all", function()
		local set = { match = "all", rules = { { field = "resolution", value = "2160p" }, { field = "watch", value = "watched" } } }
		assert.same({ "Northern Static" }, titles(organize.apply(films, set)))
	end)

	it("needs one rule with match any", function()
		local set = { match = "any", rules = { { field = "decade", value = 1990 }, { field = "genre", value = "Mystery" } } }
		assert.same({ "Glass Harbour", "Northern Static" }, titles(organize.apply(films, set)))
	end)

	it("compares numbers", function()
		local set = { rules = { { field = "minutes", test = "at_most", value = 110 } } }
		assert.same({ "Glass Harbour" }, titles(organize.apply(films, set)))
	end)

	it("excludes a genre", function()
		local set = { rules = { { field = "genre", test = "is_not", value = "Drama" } } }
		assert.same({ "Northern Static" }, titles(organize.apply(films, set)))
	end)

	it("finds nothing with a field it doesn't know", function()
		assert.equal(0, #organize.apply(films, { rules = { { field = "nonsense", value = 1 } } }))
	end)

	it("turns filter choices into the rules a collection saves", function()
		local set = organize.rulesFor({ watch = "unwatched", decade = 2010 })
		assert.equal("all", set.match)
		assert.equal(2, #set.rules)
		assert.same({ "Glass Harbour" }, titles(organize.apply(films, set)))
	end)
end)

describe("searching and similar titles", function()
	it("finds a title by part of its name, in any case", function()
		local set = organize.rulesFor({ title = "HARB" })
		assert.same({ "Glass Harbour" }, titles(organize.apply(films, set)))
	end)

	it("puts shared genres before a shared decade", function()
		local item = { title = "X", year = 1999, genres = { "Drama" } }
		assert.same({ "The Salt Line", "Glass Harbour", "Northern Static" }, titles(organize.similar(item, films, 5)))
	end)

	it("never suggests the title itself", function()
		assert.same({ "Glass Harbour" }, titles(organize.similar(films[1], films, 1)))
	end)

	it("suggests nothing with nothing in common", function()
		assert.same({}, organize.similar({ title = "Y", year = 1900 }, films, 5))
	end)
end)

describe("episodes", function()
	local a, b, c = { title = "A", progress = 1 }, { title = "B", progress = 0.5 }, { title = "C", progress = 0 }
	local seasons = { { number = 1, episodes = { a, b } }, { number = 2, episodes = { c } } }

	it("starts at the first episode not finished", function()
		local episode, season = organize.nextEpisode(seasons)
		assert.equal(b, episode)
		assert.equal(1, season.number)
	end)

	it("starts again when everything is watched", function()
		assert.equal(a, organize.nextEpisode({ { number = 1, episodes = { a } } }))
	end)

	it("copes with a show that has nothing yet", function()
		assert.is_nil(organize.nextEpisode({}))
	end)

	it("queues what follows, across seasons", function()
		assert.same({ "B", "C" }, titles(organize.after(seasons, a)))
		assert.same({}, organize.after(seasons, c))
	end)
end)

describe("facets", function()
	it("offers only what the list has", function()
		local facets = organize.facets(films)
		assert.same({ "Drama", "Mystery", "Thriller" }, facets.genres)
		assert.same({ 2020, 2010, 1990 }, facets.decades)
		assert.same({ "2160p", "1080p" }, facets.resolutions)
	end)
end)

describe("the jump bar", function()
	it("files titles past their article", function()
		assert.equal("S", organize.letter("The Salt Line"))
		assert.equal("Q", organize.letter("A Quiet Meridian"))
		assert.equal("O", organize.letter("An Orchard"))
		assert.equal("#", organize.letter("1917"))
		assert.equal("T", organize.letter("Theremin"))
	end)

	it("records where each letter starts", function()
		local letters = organize.letters({ { title = "Apple" }, { title = "Avocado" }, { title = "The Berry" } })
		assert.same({ { letter = "A", index = 1 }, { letter = "B", index = 3 } }, letters)
	end)

	it("shows from 75 items and 5 letters", function()
		local five = { {}, {}, {}, {}, {} }
		assert.is_true(organize.jumpShows(five, 75))
		assert.is_false(organize.jumpShows(five, 74))
		assert.is_false(organize.jumpShows({ {}, {}, {}, {} }, 500))
	end)

	it("keeps the ends when it has to drop letters", function()
		local letters = {}
		for i = 1, 26 do letters[i] = { letter = string.char(64 + i) } end
		local fitted = organize.fit(letters, 10)
		assert.equal(10, #fitted)
		assert.equal("A", fitted[1].letter)
		assert.equal("Z", fitted[10].letter)
	end)

	it("sorts past articles", function()
		local list = { { title = "The Zebra" }, { title = "Apple" }, { title = "A Mango" } }
		table.sort(list, organize.byTitle)
		assert.same({ "Apple", "A Mango", "The Zebra" }, titles(list))
	end)
end)

describe("describing a collection", function()
	it("says its rules in a few words", function()
		assert.equal("2160p · HDR", organize.describe({ match = "all", rules = {
			{ field = "resolution", value = "2160p" }, { field = "dynamic", test = "is_not", value = "SDR" } } }))
		assert.equal("Up to 120 min · Unwatched", organize.describe({ rules = {
			{ field = "minutes", test = "at_most", value = 120 }, { field = "watch", value = "unwatched" } } }))
		assert.equal("1990s or Drama", organize.describe({ match = "any", rules = {
			{ field = "decade", value = 1990 }, { field = "genre", value = "Drama" } } }))
	end)

	it("says nothing about a hand-made one", function()
		assert.equal("", organize.describe(nil))
	end)
end)

describe("poster badges", function()
	it("ticks a watched film and keeps its format", function()
		assert.equal("\226\156\147 HDR", organize.badge({ progress = 1, dynamic = "HDR10" }))
		assert.equal("\226\156\147", organize.badge({ progress = 1, dynamic = "SDR", resolution = "1080p" }))
	end)

	it("shows format otherwise", function()
		assert.equal("DV", organize.badge({ dynamic = "Dolby Vision" }))
		assert.equal("HDR", organize.badge({ dynamic = "HDR10" }))
		assert.equal("4K", organize.badge({ resolution = "2160p", dynamic = "SDR" }))
		assert.is_nil(organize.badge({ resolution = "1080p", dynamic = "SDR" }))
	end)

	it("counts what's left of a show", function()
		assert.equal("12", organize.badge({ kind = "show", unwatched = 12 }))
		assert.is_nil(organize.badge({ kind = "show", unwatched = 0 }))
	end)
end)

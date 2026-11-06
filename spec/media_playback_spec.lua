package.path = "./extensions/media/?.lua;" .. package.path
local playback = require("libs.playback")

describe("media playback words", function()
	it("shows hours only when there are any", function()
		assert.equal("53:12", playback.clock(3192))
		assert.equal("1:53:12", playback.clock(6792))
		assert.equal("0:00", playback.clock(nil))
	end)

	it("rounds time left up, so a film never claims to be over early", function()
		assert.equal("1 min left", playback.remaining(1))
		assert.equal("59 min left", playback.remaining(3540))
		assert.equal("1 h 15 min left", playback.remaining(4495))
	end)

	it("says paused and how long is left", function()
		assert.equal("Paused · 2021", playback.status({ paused = true, detail = "2021" }))
		assert.equal("Playing", playback.status({ paused = false }))
		assert.equal("2 min left", playback.left({ position = 60, length = 180 }))
		assert.equal("", playback.left({ position = 0, length = 0 }))
	end)

	it("says how long a film runs", function()
		assert.equal("52 min", playback.runtime(52))
		assert.equal("1 h 44 min", playback.runtime(104))
		assert.equal("", playback.runtime(nil))
		assert.equal("", playback.runtime(0))
	end)

	it("marks only the first row of Up next", function()
		local rows = playback.queueRows({ { title = "One", minutes = 104, art = 1 }, { title = "Two" } },
			function(item) return item.art and "poster.png" end)
		assert.same({ title = "One", secondary = "1 h 44 min", column1 = "Next", art = "poster.png" }, rows[1])
		assert.same({ title = "Two", secondary = "", column1 = "" }, rows[2])
	end)

	it("copes with an empty queue and with no art lookup", function()
		assert.same({}, playback.queueRows(nil))
		assert.is_nil(playback.queueRows({ { title = "One" } })[1].art)
	end)
end)

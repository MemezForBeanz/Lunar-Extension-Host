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
end)

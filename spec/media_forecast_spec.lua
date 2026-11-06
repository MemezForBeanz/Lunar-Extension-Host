package.path = "./extensions/media/?.lua;" .. package.path
local forecast = require("libs.forecast")

local function profile(id)
	for _, entry in ipairs(forecast.PROFILES) do
		if entry.id == id then return entry end
	end
end

describe("playback forecast", function()
	it("says a direct file plays as it is", function()
		local verdict = forecast.verdict({ mode = "direct" })
		assert.equal("ok", verdict.tone)
		assert.equal("Plays as it is", verdict.headline)
		assert.is_nil(verdict.fix)
	end)

	it("explains a remux and how to avoid it", function()
		local verdict = forecast.verdict({ mode = "remux", reason = "client cannot open matroska but can play its streams" })
		assert.equal("warning", verdict.tone)
		assert.is_truthy(verdict.why:find("MKV", 1, true))
		assert.is_truthy(verdict.fix:find("MP4", 1, true))
	end)

	it("separates picture from sound", function()
		local sound = forecast.verdict({ mode = "convert", reason = "client cannot decode truehd",
			video = { action = "copy" }, audio = { action = "convert" } })
		assert.equal("Sound has to be converted", sound.headline)
		assert.is_truthy(sound.why:find("TrueHD", 1, true))
		assert.is_truthy(sound.fix:find("AAC", 1, true))
		local picture = forecast.verdict({ mode = "convert", reason = "client cannot show HDR",
			video = { action = "convert", reason = "client cannot show HDR" } })
		assert.equal("Picture has to be converted", picture.headline)
		assert.is_truthy(picture.fix:find("SDR", 1, true))
	end)

	it("says when a file can't play", function()
		local verdict = forecast.verdict({ mode = "refuse", reason = "this file has not been analysed yet" })
		assert.equal("error", verdict.tone)
		assert.equal("Can't play", verdict.headline)
	end)

	it("keeps a line short for the inspector", function()
		assert.equal("Phone: plays as it is", forecast.line({ headline = "Plays as it is" }, "Phone"))
	end)

	it("gives the sample library honest-looking answers", function()
		local film = { codec = "HEVC", audio = "TrueHD 7.1", resolution = "2160p", dynamic = "HDR10" }
		assert.equal("direct", forecast.sampleDecision(film, profile("desktop")).mode)
		assert.equal("convert", forecast.sampleDecision(film, profile("tv")).mode)
		assert.equal("convert", forecast.sampleDecision(film, profile("phone")).mode)
		local small = { codec = "H.264", audio = "AAC 2.0", resolution = "1080p", dynamic = "SDR" }
		assert.equal("remux", forecast.sampleDecision(small, profile("phone")).mode)
	end)
end)

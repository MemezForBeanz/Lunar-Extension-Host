--- Playback Forecast: before anyone presses Play, how a file will reach each of their devices,
-- why, and what would change the answer. The server decides; this turns its decision into
-- words a person can act on. Pure, so specs cover every sentence.
-- @module libs.forecast

local M = {}

--- What each kind of device can play. `this computer` is libmpv, which plays nearly anything.
M.PROFILES = {
	{ id = "desktop", name = "This computer", caps = {
		containers = { "matroska", "mov", "mp4", "avi", "mpegts", "webm" },
		video = { "h264", "hevc", "av1", "vp9", "vp8", "mpeg2video", "mpeg4" },
		audio = { "aac", "ac3", "eac3", "dts", "truehd", "flac", "opus", "mp3", "vorbis" },
		subtitles = { "subrip", "ass", "webvtt", "hdmv_pgs_subtitle", "dvd_subtitle" }, hdr = true,
	} },
	{ id = "tv", name = "A typical TV", assumed = true, caps = {
		containers = { "matroska", "mov", "mp4", "mpegts" }, video = { "h264", "hevc", "vp9" },
		audio = { "aac", "ac3", "eac3", "mp3" }, subtitles = { "subrip", "webvtt" }, max_height = 2160, hdr = true,
	} },
	{ id = "phone", name = "A typical phone", assumed = true, caps = {
		containers = { "mov", "mp4" }, video = { "h264", "hevc" }, audio = { "aac", "mp3" },
		subtitles = { "webvtt" }, max_height = 1080, max_channels = 2,
	} },
}

local NAMES = {
	h264 = "H.264", hevc = "HEVC", av1 = "AV1", eac3 = "E-AC3", ac3 = "AC3", truehd = "TrueHD",
	dts = "DTS", aac = "AAC", opus = "Opus", matroska = "MKV", mov = "MP4",
}

-- The server's reasons are written for logs. These read as a person would say them.
local function named(reason)
	local text = reason:gsub("%f[%w][%w_]+%f[%W]", function(word) return NAMES[word] or word end)
	text = text:gsub("^client cannot open (%S+) but can play its streams", "It can't open %1 files")
	text = text:gsub("^client cannot decode (%S+)", "It can't decode %1")
	text = text:gsub("^client cannot show HDR", "It can't show HDR")
	text = text:gsub("^height (%d+) is above the client limit of (%d+)", "It stops at %2 lines, and this is %1")
	text = text:gsub("^(%d+) channels are above the client limit of (%d+)", "It plays %2 channels, and this has %1")
	return (text:gsub("^%l", string.upper))
end

--- One device's verdict in plain words.
-- @tparam table decision the server's answer
-- @treturn table `tone` (`ok`, `warning`, `error`), `headline`, `why`, `fix`
function M.verdict(decision)
	local mode = decision.mode
	local video, audio = decision.video or {}, decision.audio or {}
	if mode == "direct" then
		return { tone = "ok", headline = "Plays as it is", why = "The original file, nothing changed." }
	end
	if mode == "remux" then
		return { tone = "warning", headline = "Needs a new container",
			why = named(decision.reason or "") .. ", but the picture and sound are fine.",
			fix = "Rewrap it as MP4 once." }
	end
	if mode == "convert" then
		local fix = "Keep a second copy made for this device."
		if audio.action == "convert" and video.action ~= "convert" then
			fix = "Add a stereo AAC track to the file, and the picture never has to change."
		elseif video.action == "convert" and (video.reason or ""):find("HDR", 1, true) then
			fix = "Keep an SDR copy alongside it."
		end
		return { tone = "warning", headline = video.action == "convert" and "Picture has to be converted" or "Sound has to be converted",
			why = named(decision.reason or "") .. ".", fix = fix }
	end
	return { tone = "error", headline = "Can't play", why = named(decision.reason or "No reason was given") .. "." }
end

--- The one line that matters most, for a compact place like the inspector.
-- @tparam table verdict
-- @tparam string device
-- @treturn string
function M.line(verdict, device)
	return device .. ": " .. verdict.headline:sub(1, 1):lower() .. verdict.headline:sub(2)
end

--- A made-up decision for the sample library, from what its items claim to be.
-- @tparam table item
-- @tparam table profile from `M.PROFILES`
-- @treturn table a decision in the server's shape
function M.sampleDecision(item, profile)
	local caps = profile.caps
	local function can(list, value)
		for _, entry in ipairs(list or {}) do
			if entry == value then return true end
		end
		return false
	end
	local video = (item.codec or "h264"):lower():gsub("%.", "")
	local audio = (item.audio or "aac"):match("^%S+"):lower():gsub("%-", "")
	local height = tonumber((item.resolution or "1080p"):match("%d+"))
	if not can(caps.video, video) then
		return { mode = "convert", reason = "client cannot decode " .. video, video = { action = "convert" } }
	end
	if caps.max_height and height > caps.max_height then
		return { mode = "convert", reason = "height " .. height .. " is above the client limit of " .. caps.max_height,
			video = { action = "convert" } }
	end
	if item.dynamic and item.dynamic ~= "SDR" and not caps.hdr then
		return { mode = "convert", reason = "client cannot show HDR", video = { action = "convert", reason = "HDR" } }
	end
	if not can(caps.audio, audio) then
		return { mode = "convert", reason = "client cannot decode " .. audio, audio = { action = "convert" }, video = { action = "copy" } }
	end
	if not can(caps.containers, "matroska") then
		return { mode = "remux", reason = "client cannot open matroska but can play its streams" }
	end
	return { mode = "direct", reason = "client plays this file as it is" }
end

return M

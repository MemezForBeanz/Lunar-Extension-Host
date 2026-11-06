--- Decides how one file reaches one client, and says why, per stream.
-- Pure. A client states what it can play; nothing is inferred from its name.
-- Original bytes are preferred, then a copy into another container, then conversion.
-- @module libs.decision

local M = {}

local function set(list)
	local out = {}
	for _, value in ipairs(list or {}) do out[tostring(value):lower()] = true end
	return out
end

local function first_of(streams, kind)
	for _, stream in ipairs(streams) do
		if stream.kind == kind then return stream end
	end
end

local function chosen(streams, kind, index)
	if index then
		for _, stream in ipairs(streams) do
			if stream.kind == kind and stream.idx == index then return stream end
		end
		return nil, "the selected " .. kind .. " stream is not in this file"
	end
	for _, stream in ipairs(streams) do
		if stream.kind == kind and stream.is_default == 1 then return stream end
	end
	return first_of(streams, kind)
end

local function video_verdict(stream, caps)
	if not stream then return { action = "none", reason = "no video stream" } end
	if not caps.video[(stream.codec or ""):lower()] then
		return { action = "convert", reason = "client cannot decode " .. tostring(stream.codec) }
	end
	if caps.max_height and stream.height and stream.height > caps.max_height then
		return { action = "convert", reason = "height " .. stream.height .. " is above the client limit of " .. caps.max_height }
	end
	if stream.hdr == 1 and not caps.hdr then
		return { action = "convert", reason = "client cannot show HDR" }
	end
	return { action = "copy", reason = "client decodes " .. stream.codec }
end

local function audio_verdict(stream, caps)
	if not stream then return { action = "none", reason = "no audio stream" } end
	if not caps.audio[(stream.codec or ""):lower()] then
		return { action = "convert", reason = "client cannot decode " .. tostring(stream.codec) }
	end
	if caps.max_channels and stream.channels and stream.channels > caps.max_channels then
		return { action = "convert", reason = stream.channels .. " channels are above the client limit of " .. caps.max_channels }
	end
	return { action = "copy", reason = "client decodes " .. stream.codec }
end

local function subtitle_verdict(stream, caps)
	if not stream then return { action = "none", reason = "subtitles off" } end
	if caps.subtitles[(stream.codec or ""):lower()] then
		return { action = "copy", reason = "client renders " .. stream.codec }
	end
	return { action = "burn", reason = "client cannot render " .. tostring(stream.codec) .. ", so it must be drawn into the picture" }
end

--- Normalise a client's capability table.
function M.capabilities(raw)
	raw = raw or {}
	return {
		containers = set(raw.containers),
		video = set(raw.video),
		audio = set(raw.audio),
		subtitles = set(raw.subtitles),
		max_height = tonumber(raw.max_height),
		max_channels = tonumber(raw.max_channels),
		max_bitrate = tonumber(raw.max_bitrate),
		hdr = raw.hdr == true,
	}
end

--- Decide delivery for a file.
-- @tparam table file `{ container, bitrate, streams }`
-- @tparam table raw_caps client capabilities
-- @tparam[opt] table selected `{ audio = idx, subtitle = idx }`
-- @treturn table `{ mode, reason, video, audio, subtitle }`; mode is `direct`, `remux`, `convert` or `refuse`
function M.decide(file, raw_caps, selected)
	local caps = M.capabilities(raw_caps)
	selected = selected or {}
	local streams = file.streams or {}
	if #streams == 0 then
		return { mode = "refuse", reason = "this file has not been analysed yet" }
	end
	local audio, audio_problem = chosen(streams, "audio", selected.audio)
	if audio_problem then return { mode = "refuse", reason = audio_problem } end
	local subtitle
	if selected.subtitle then
		local problem
		subtitle, problem = chosen(streams, "subtitle", selected.subtitle)
		if problem then return { mode = "refuse", reason = problem } end
	end
	local video = video_verdict(first_of(streams, "video"), caps)
	local sound = audio_verdict(audio, caps)
	local text = subtitle_verdict(subtitle, caps)
	local result = { video = video, audio = sound, subtitle = text }
	if video.action == "none" and sound.action == "none" then
		result.mode, result.reason = "refuse", "no playable streams"
		return result
	end
	local needs_conversion = video.action == "convert" or sound.action == "convert" or text.action == "burn"
	local over_budget = caps.max_bitrate and file.bitrate and file.bitrate > caps.max_bitrate
	if needs_conversion then
		result.mode = "convert"
		result.reason = (video.action == "convert" and video.reason)
			or (sound.action == "convert" and sound.reason) or text.reason
	elseif over_budget then
		result.mode = "convert"
		result.reason = "bitrate " .. file.bitrate .. " is above the client limit of " .. caps.max_bitrate
		video.action = "convert"
	elseif not caps.containers[(file.container or ""):lower()] then
		result.mode = "remux"
		result.reason = "client cannot open " .. tostring(file.container) .. " but can play its streams"
	else
		result.mode = "direct"
		result.reason = "client plays this file as it is"
	end
	return result
end

return M

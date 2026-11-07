--- Reads a file's tracks with ffprobe, a separate process, so a damaged file can't
-- take the server down. The extension's contained runtime supplies FFmpeg; while tools
-- are being prepared the catalog remains usable and reports that analysis is off.
-- @module libs.probe

local cjson = require("cjson")
local nfo = require("libs.nfo")

local M = {}

M.MAX_OUTPUT = 4 * 1024 * 1024
M.TIMEOUT_S = 60

local HDR_TRANSFER = { smpte2084 = true, ["arib-std-b67"] = true }

local function truthy(flag)
	return flag == 1 or flag == "1" or flag == true
end

local function integer(text)
	local n = tonumber(text)
	return n and math.floor(n) or nil
end

--- The command line for one file. The path is a single argument, never a shell string.
function M.argv(ffprobe, path)
	return { ffprobe, "-v", "error", "-print_format", "json", "-show_format", "-show_streams", "--", path }
end

local function drain(run)
	local chunk = run.process:read("stdout")
	while chunk and chunk ~= "" do
		run.size = run.size + #chunk
		if run.size <= M.MAX_OUTPUT then run.output[#run.output + 1] = chunk end
		chunk = run.process:read("stdout")
	end
end

--- Start tracking a process. `process` has `read`, `poll` (the exit code, nil while running) and `kill`.
function M.run(job, process, now)
	return { job = job, process = process, output = {}, size = 0, started = now }
end

--- Take what a run has written and see whether it has ended.
-- @treturn boolean true once it ended; `run.code` is then its exit code, or nil if it was killed
function M.advance(run, now)
	drain(run)
	local code = run.process:poll()
	if code ~= nil then
		drain(run)
		run.code = code
		return true
	end
	if now - run.started > M.TIMEOUT_S then
		run.process:kill()
		return true
	end
	return false
end

--- Turn ffprobe's JSON into what the catalog stores.
-- @treturn table|nil `{ container, duration_ms, bitrate, streams }`
-- @treturn[2] string why it could not be read
function M.parse(text)
	local ok, data = pcall(cjson.decode, text)
	if not ok or type(data) ~= "table" or type(data.format) ~= "table" then
		return nil, "ffprobe output was not readable"
	end
	local streams = {}
	for _, raw in ipairs(data.streams or {}) do
		local kind = raw.codec_type
		if kind == "video" or kind == "audio" or kind == "subtitle" then
			local tags = type(raw.tags) == "table" and raw.tags or {}
			local disposition = type(raw.disposition) == "table" and raw.disposition or {}
			if not (kind == "video" and truthy(disposition.attached_pic)) then
				streams[#streams + 1] = {
					idx = raw.index, kind = kind, codec = raw.codec_name,
					language = tags.language, title = tags.title, channels = raw.channels,
					width = raw.width, height = raw.height,
					hdr = HDR_TRANSFER[raw.color_transfer or ""] == true,
					is_default = truthy(disposition.default), is_forced = truthy(disposition.forced),
				}
			end
		end
	end
	local duration = tonumber(data.format.duration)
	local names = tostring(data.format.format_name or "")
	return {
		container = names:match("^[^,]+"),
		duration_ms = duration and math.floor(duration * 1000) or nil,
		bitrate = integer(data.format.bit_rate),
		streams = streams,
		facts = nfo.fromTags(data.format.tags),
	}
end

return M

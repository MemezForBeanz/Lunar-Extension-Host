--- Reads a file's tracks with ffprobe, a separate process, so a damaged file can't
-- take the server down. Lunar doesn't ship FFmpeg: the server finds one, or runs
-- without analysis and says so.
-- @module libs.probe

local cjson = require("cjson")

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
	}
end

return M

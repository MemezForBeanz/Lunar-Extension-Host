--- Talks to a Lunar Media Server and turns its answers into the model the pages show.
-- The mapping is pure, so it is covered by specs without a server. Only ids travel: a file
-- is played through a stream address, and this client never sees a path on the server.
-- @module libs.client

local cjson = require("cjson")
local artcache = require("libs.artcache")

local M = {}
local Client = {}
Client.__index = Client

M.PAGE = 200

local RESOLUTIONS = { { 2000, "2160p" }, { 1000, "1080p" }, { 700, "720p" } }

local function resolution_of(height)
	if not height then return nil end
	for _, step in ipairs(RESOLUTIONS) do
		if height >= step[1] then return step[2] end
	end
	return height .. "p"
end

local CODECS = { h264 = "H.264", hevc = "HEVC", av1 = "AV1", vp9 = "VP9", vp8 = "VP8", mpeg2video = "MPEG-2",
	mpeg4 = "MPEG-4", aac = "AAC", ac3 = "AC3", eac3 = "E-AC3", dts = "DTS", truehd = "TrueHD", flac = "FLAC",
	opus = "Opus", mp3 = "MP3", vorbis = "Vorbis" }
local LAYOUTS = { [1] = "1.0", [2] = "2.0", [6] = "5.1", [8] = "7.1" }

--- A codec the way people write it.
-- @tparam string|nil codec ffprobe's name
-- @treturn string|nil
function M.codecName(codec)
	return codec and (CODECS[codec] or codec:upper()) or nil
end

--- An audio track the way people write it.
-- @tparam string|nil codec
-- @tparam number|nil channels
-- @treturn string|nil
function M.audioName(codec, channels)
	local name = M.codecName(codec)
	if not name then return nil end
	if not channels then return name end
	return name .. " " .. (LAYOUTS[channels] or (channels .. " ch"))
end

local function stream_of(file, kind)
	for _, stream in ipairs(file.streams or {}) do
		if stream.kind == kind then return stream end
	end
end

--- Fill an item with what its first file says.
-- @tparam table item a library item
-- @tparam table detail the server's item answer
-- @treturn table the same item
function M.applyDetail(item, detail)
	local file = (detail.files or {})[1]
	item.file_id = file and file.id or nil
	item.offline = file ~= nil and file.missing_at ~= nil
	local position = detail.progress and detail.progress.position_ms or 0
	if file then
		local video, audio = stream_of(file, "video"), stream_of(file, "audio")
		item.resolution = video and resolution_of(video.height) or nil
		item.codec = video and M.codecName(video.codec) or nil
		item.dynamic = video and (video.hdr == 1 and "HDR" or "SDR") or nil
		item.audio = audio and M.audioName(audio.codec, audio.channels) or nil
		item.bitrate = file.bitrate and file.bitrate / 1000000 or nil
		item.size_gb = file.size and file.size / 1073741824 or nil
		item.minutes = file.duration_ms and math.floor(file.duration_ms / 60000) or nil
		item.path = file.rel_path
		item.problem = file.probe_error
		if file.duration_ms and file.duration_ms > 0 then item.progress = position / file.duration_ms end
	end
	item.position_ms = position
	if detail.progress and detail.progress.watched == 1 then item.progress = 1 end
	if detail.people then item.people = detail.people end
	if detail.rating then item.rating = detail.rating end
	return item
end

local function text_or_nil(value)
	return type(value) == "string" and value or nil
end

local function number_or_nil(value)
	return type(value) == "number" and value or nil
end

-- SQLite joins a list with commas.
local function list_of(text)
	local out = {}
	for entry in tostring(type(text) == "string" and text or ""):gmatch("[^,]+") do out[#out + 1] = entry end
	return out
end

local function added_text(seconds)
	return seconds and os.date("!%Y-%m-%d", seconds) or ""
end

--- Build the page model from a server's libraries.
-- @tparam table libraries the libraries, each with `items` from its pages
-- @tparam table status the server's status answer
-- @tparam[opt] table continuing the server's continue-watching items
-- @tparam[opt] table collections the server's collections
-- @treturn table a model with `sources`, `films`, `shows`, `continuing` and `server`
function M.modelFrom(libraries, status, continuing, collections)
	local by_id = {}
	local model = { films = {}, shows = {}, continuing = {}, sample = false,
		sources = { { id = "home", title = "Home", icon = "home" } } }
	local film_count, show_count = 0, 0
	for _, library in ipairs(libraries) do
		for _, raw in ipairs(library.items or {}) do
			local item = { id = raw.id, kind = raw.kind, title = raw.title, year = raw.year or 0,
				added = added_text(raw.added_at), progress = 0,
				seasons = number_or_nil(raw.seasons) or 0, episodes = number_or_nil(raw.episodes) or 0,
				unwatched = number_or_nil(raw.unwatched) or 0,
				art = artcache.kinds(raw.art), overview = text_or_nil(raw.overview), genres = list_of(raw.genres),
				codec = M.codecName(text_or_nil(raw.vcodec)), resolution = resolution_of(number_or_nil(raw.height)),
				dynamic = raw.hdr == 1 and "HDR" or (type(raw.height) == "number" and "SDR" or nil) }
			if raw.watched == 1 then item.progress = 1 end
			if type(raw.duration_ms) == "number" then item.minutes = math.floor(raw.duration_ms / 60000) end
			by_id[item.id] = item
			if raw.kind == "show" then
				show_count = show_count + 1
				model.shows[show_count] = item
			else
				film_count = film_count + 1
				model.films[film_count] = item
			end
		end
	end
	for _, raw in ipairs(continuing or {}) do
		local item = by_id[raw.id]
		if item then
			item.position_ms = raw.position_ms
			if type(raw.duration_ms) == "number" and raw.duration_ms > 0 then
				item.progress = raw.position_ms / raw.duration_ms
			end
			model.continuing[#model.continuing + 1] = item
		end
	end
	model.sources[2] = { id = "films", title = "Films", icon = "video", count = film_count }
	model.sources[3] = { id = "shows", title = "Shows", icon = "screen", count = show_count }
	model.collections = collections or {}
	model.scanning = status.scanning
	model.server = {
		name = "Connected", version = "0.1.0", analysis = status.analysis or "off", files = status.files or 0,
		missing = status.missing or 0, analysing = status.analysing or 0, failed = status.failed or 0, sessions = {},
	}
	return model
end

--- What a desktop player using libmpv can decode without help.
M.CAPABILITIES = {
	containers = { "matroska", "mov", "mp4", "avi", "mpegts", "webm" },
	video = { "h264", "hevc", "av1", "vp9", "vp8", "mpeg2video", "mpeg4" },
	audio = { "aac", "ac3", "eac3", "dts", "truehd", "flac", "opus", "mp3", "vorbis" },
	subtitles = { "subrip", "ass", "webvtt", "hdmv_pgs_subtitle", "dvd_subtitle" },
	hdr = true,
}

--- Create a client.
-- @tparam function http `http(request, callback)`, normally `ctx:http` bound to its owner
-- @tparam string base server address, such as `https://host:8421`
-- @tparam string token bearer token
function M.new(http, base, token)
	return setmetatable({ http = http, base = base:gsub("/+$", ""), token = token }, Client)
end

function Client:_url(path)
	return self.base .. "/ext/media-server" .. path
end

function Client:_request(method, path, body, done)
	self.http({
		url = self:_url(path), method = method, json = body, timeout = 15,
		headers = { Authorization = "Bearer " .. self.token },
	}, function(response, err)
		if not response then return done(nil, err or "no answer from the server") end
		if not response.ok then return done(nil, "the server answered " .. tostring(response.status)) end
		if response.status == 204 then return done({}) end
		local ok, data = pcall(cjson.decode, response.body or "")
		if not ok then return done(nil, "the server's answer could not be read") end
		done(data)
	end)
end

--- The address of a file's bytes.
function Client:streamUrl(file_id)
	return self:_url("/v1/files/" .. file_id .. "/stream")
end

--- The header a player must send with `streamUrl`.
function Client:authHeader()
	return "Authorization: Bearer " .. self.token
end

function Client:_all_items(library, after, done)
	local path = "/v1/libraries/" .. library.id .. "/items?limit=" .. M.PAGE
	if after then
		path = path .. "&after_key=" .. tostring(after.after_key):gsub("[^%w%-_.~]", function(c)
			return string.format("%%%02X", c:byte())
		end) .. "&after_id=" .. after.after_id
	end
	self:_request("GET", path, nil, function(page, err)
		if not page then return done(err) end
		for _, item in ipairs(page.items or {}) do library.items[#library.items + 1] = item end
		if page.next and page.next ~= cjson.null then return self:_all_items(library, page.next, done) end
		done()
	end)
end

--- Fetch everything the pages need.
-- @tparam function done `done(model)` or `done(nil, why)`
function Client:load(done)
	self:_request("GET", "/v1/status", nil, function(status, err)
		if not status then return done(nil, err) end
		self:_request("GET", "/v1/libraries", nil, function(answer, why)
			if not answer then return done(nil, why) end
			local libraries, index = answer.libraries or {}, 0
			local function next_library()
				index = index + 1
				local library = libraries[index]
				if not library then
					return self:_request("GET", "/v1/continue", nil, function(resume)
						self:_request("GET", "/v1/collections", nil, function(saved)
							done(M.modelFrom(libraries, status, resume and resume.items, M.collectionsFrom(saved)))
						end)
					end)
				end
				library.items = {}
				self:_all_items(library, nil, function(problem)
					if problem then return done(nil, problem) end
					next_library()
				end)
			end
			next_library()
		end)
	end)
end

--- Turn the server's episodes into seasons.
-- @tparam table answer
-- @treturn table
function M.seasonsFrom(answer)
	local seasons = {}
	for _, raw in ipairs(answer.seasons or {}) do
		local season = { number = raw.season, title = raw.title, episodes = {} }
		for i, entry in ipairs(raw.episodes or {}) do
			local minutes = number_or_nil(entry.duration_ms)
			local position = number_or_nil(entry.position_ms) or 0
			season.episodes[i] = { id = entry.id, kind = "episode", title = entry.title, season = raw.season,
				episode = entry.episode, minutes = minutes and math.floor(minutes / 60000) or nil,
				progress = entry.watched == 1 and 1 or (minutes and minutes > 0 and position / minutes or 0),
				position_ms = position }
		end
		seasons[#seasons + 1] = season
	end
	return seasons
end

--- Turn the server's collections into what the rail shows.
-- @tparam table|nil answer the server's reply
-- @treturn table
function M.collectionsFrom(answer)
	local out = {}
	for _, raw in ipairs(answer and answer.collections or {}) do
		local rules
		if type(raw.rules) == "string" then
			local ok, decoded = pcall(cjson.decode, raw.rules)
			if ok and type(decoded) == "table" then rules = decoded end
		end
		out[#out + 1] = { id = raw.id, name = raw.name, icon = text_or_nil(raw.icon) or (rules and "filter" or "bookmark"),
			rules = rules, items = raw.items }
	end
	return out
end

--- Save a collection.
function Client:saveCollection(entry, done)
	self:_request("POST", "/v1/collections", { name = entry.name, icon = entry.icon, rules = entry.rules,
		items = entry.items }, done)
end

--- Fetch one picture's bytes.
-- @tparam number id
-- @tparam string kind `poster` or `backdrop`
-- @tparam function done `done(bytes)`, nil on failure
function Client:art(id, kind, done)
	self.http({
		url = self:_url("/v1/items/" .. id .. "/art/" .. kind), method = "GET", timeout = 30,
		headers = { Authorization = "Bearer " .. self.token },
	}, function(response)
		done(response and response.ok and response.body or nil)
	end)
end

--- Fetch a show's seasons and episodes.
-- @tparam number id
-- @tparam function done `done(seasons)` or `done(nil, why)`
function Client:episodes(id, done)
	self:_request("GET", "/v1/items/" .. id .. "/episodes", nil, function(answer, why)
		if not answer then return done(nil, why) end
		done(M.seasonsFrom(answer))
	end)
end

--- Say whether something has been watched.
function Client:mark(id, watched)
	self:_request("POST", "/v1/items/" .. id .. "/watched", { watched = watched }, function() end)
end

--- Fetch one item's detail.
function Client:detail(id, done)
	self:_request("GET", "/v1/items/" .. id, nil, done)
end

--- Ask how a file reaches this client.
function Client:decision(file_id, done)
	self:_request("POST", "/v1/files/" .. file_id .. "/decision", { capabilities = M.CAPABILITIES }, done)
end

--- Save a resume point. Failures are ignored: the next save carries a newer position.
function Client:saveProgress(id, position_ms, duration_ms)
	self:_request("POST", "/v1/items/" .. id .. "/progress",
		{ position_ms = position_ms, duration_ms = duration_ms }, function() end)
end

return M

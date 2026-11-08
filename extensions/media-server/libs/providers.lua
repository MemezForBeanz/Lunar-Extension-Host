--- The library provider database, and what each kind of provider knows how to read.
--
-- A provider is data: a name, a kind, and the fields a person fills in. The kinds are the only
-- code, and they ship with Lunar, so adding a provider from a file or a friend can never run
-- anything. Each kind turns a source's answer into plain entries, and everything after that is
-- the same catalog that local folders use.
--
-- Nothing here ships a source of other people's films. The defaults are public-domain archives
-- and the owner's own servers and links.
--
-- @module libs.providers

local cjson = require("cjson")

local M = {}

M.MAX_ENTRIES = 5000
M.MAX_NAME = 120

local VIDEO = { mp4 = true, m4v = true, mkv = true, webm = true, mov = true, avi = true, ts = true, m3u8 = true }

--- The providers Lunar ships with.
M.BUILTIN = {
	{ id = "jellyfin", name = "Jellyfin or Emby server", kind = "jellyfin",
		summary = "Another media server you run, on this network or elsewhere.",
		fields = { { id = "url", label = "Server address", cue = "https://media.example.org" },
			{ id = "key", label = "API key", secret = true } } },
	{ id = "archive-feature-films", name = "Internet Archive: Feature Films", kind = "archive",
		summary = "Public-domain and openly licensed feature films.",
		config = { collection = "feature_films" }, fields = {} },
	{ id = "archive-prelinger", name = "Internet Archive: Prelinger Archives", kind = "archive",
		summary = "Advertising, educational and home films from the Prelinger collection.",
		config = { collection = "prelinger" }, fields = {} },
	{ id = "archive-classic-tv", name = "Internet Archive: Classic TV", kind = "archive",
		summary = "Classic television episodes labelled public domain by their Archive item metadata; verify each item.",
		config = { collection = "classic_tv" }, fields = {} },
	{ id = "m3u", name = "M3U playlist", kind = "m3u", summary = "A playlist of streams at an address you give it.",
		fields = { { id = "url", label = "Playlist address", cue = "https://example.org/list.m3u" } } },
	{ id = "feed", name = "Video feed", kind = "feed", summary = "A podcast or RSS feed with video enclosures.",
		fields = { { id = "url", label = "Feed address", cue = "https://example.org/feed.xml" } } },
	{ id = "web-folder", name = "Web folder", kind = "index", summary = "A folder of video files shared over the web.",
		fields = { { id = "url", label = "Folder address", cue = "https://nas.example.org/films/" } } },
	{ id = "torrent", name = "Torrent links", kind = "torrent",
		summary = "Links you add yourself. Playing one uploads to other people and shows them your address, "
			.. "so add only what you have the right to share.",
		off_by_default = true,
		fields = { { id = "links", label = "Magnet links, one per line", multiline = true } } },
}

M.KINDS = { jellyfin = true, archive = true, m3u = true, feed = true, index = true, torrent = true, website = true }

--- Check a provider someone wants to add to the database. It stays data: only known kinds, and
-- fields that say what to ask for.
-- @tparam table def
-- @treturn[1] table a clean copy
-- @treturn[2] nil
-- @treturn[2] string why
function M.validate(def)
	if type(def) ~= "table" then return nil, "a provider must be an object" end
	if type(def.id) ~= "string" or not def.id:match("^[%w][%w_-]*$") or #def.id > 64 then
		return nil, "id must be letters, digits, dashes or underscores"
	end
	if type(def.name) ~= "string" or def.name == "" or #def.name > M.MAX_NAME then return nil, "a name is required" end
	if not M.KINDS[def.kind] then return nil, "unknown kind: " .. tostring(def.kind) end
	local fields = {}
	for i, field in ipairs(type(def.fields) == "table" and def.fields or {}) do
		if type(field) ~= "table" or type(field.id) ~= "string" or type(field.label) ~= "string" then
			return nil, "each field needs an id and a label"
		end
		fields[i] = { id = field.id, label = field.label, cue = type(field.cue) == "string" and field.cue or nil,
			secret = field.secret == true, multiline = field.multiline == true }
	end
	return { id = def.id, name = def.name, kind = def.kind, fields = fields,
		summary = type(def.summary) == "string" and def.summary or "",
		config = type(def.config) == "table" and def.config or nil }
end

local function extension_of(url)
	return (url:match("%.(%w+)[^/]*$") or url:match("%.(%w+)$") or ""):lower()
end

--- Is this address a kind Lunar will fetch? Files and odd schemes are refused.
function M.isWebAddress(url)
	return type(url) == "string" and (url:match("^https?://[%w%[]") ~= nil) and not url:find("%s")
end

local function title_year(text)
	local title, year = text:match("^(.-)%s*[%(%[](%d%d%d%d)[%)%]]")
	if title and title ~= "" then return title, tonumber(year) end
	return text, nil
end

local function entry(key, name, url, extra)
	local title, year = title_year(name)
	local out = { key = key, title = title, year = year, url = url }
	for k, v in pairs(extra or {}) do out[k] = v end
	return out
end

--- Read an M3U playlist.
-- @tparam string text
-- @treturn table entries
function M.parseM3u(text)
	local out, name = {}, nil
	for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		local info = line:match("^#EXTINF:[^,]*,(.*)$")
		if info then
			name = info:gsub("^%s+", ""):gsub("%s+$", "")
		elseif line ~= "" and line:sub(1, 1) ~= "#" then
			if M.isWebAddress(line) and #out < M.MAX_ENTRIES then
				out[#out + 1] = entry(line, name or line:match("([^/]+)$") or line, line)
			end
			name = nil
		end
	end
	return out
end

local function decode_xml(text)
	text = text:gsub("^%s*<!%[CDATA%[(.-)%]%]>%s*$", "%1")
	return (text:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"))
end

--- Read a feed's video enclosures.
-- @tparam string text RSS
-- @treturn table entries
function M.parseFeed(text)
	local out = {}
	for block in text:gmatch("<item[ >](.-)</item>") do
		local url = block:match('<enclosure[^>]-url="([^"]+)"')
		local kind = block:match('<enclosure[^>]-type="([^"]+)"') or ""
		local title = block:match("<title[^>]*>(.-)</title>")
		if url and title and #out < M.MAX_ENTRIES then
			url = decode_xml(url)
			if M.isWebAddress(url) and (kind:match("^video/") or VIDEO[extension_of(url)]) then
				local description = block:match("<description[^>]*>(.-)</description>")
				out[#out + 1] = entry(url, decode_xml(title), url, {
					overview = description and decode_xml(description):gsub("<[^>]+>", "") or nil })
			end
		end
	end
	return out
end

local function unescape(text)
	return (text:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

--- Read a web server's folder listing.
-- @tparam string text HTML
-- @tparam string base the folder's address
-- @treturn table entries
function M.parseIndex(text, base)
	local out, seen = {}, {}
	base = base:gsub("/*$", "/")
	for href in text:gmatch('[hH][rR][eE][fF]%s*=%s*"([^"#?]+)"') do
		if VIDEO[extension_of(href)] and not seen[href] and #out < M.MAX_ENTRIES then
			seen[href] = true
			local url = href:match("^https?://") and href or (base .. href:gsub("^%./", ""))
			if not href:find("..", 1, true) and M.isWebAddress(url) then
				local name = unescape(href:match("([^/]+)$")):gsub("%.[^.]+$", ""):gsub("[._]", " ")
				out[#out + 1] = entry(url, name, url)
			end
		end
	end
	return out
end

--- Read an Internet Archive search answer.
-- @tparam string text JSON
-- @treturn table entries; `url` is filled when one is played
function M.parseArchive(text)
	local ok, data = pcall(cjson.decode, text)
	local docs = ok and type(data) == "table" and type(data.response) == "table" and data.response.docs
	local out = {}
	for _, doc in ipairs(type(docs) == "table" and docs or {}) do
		if type(doc.identifier) == "string" and doc.identifier:match("^[%w%._-]+$") and type(doc.title) == "string" then
			out[#out + 1] = { key = doc.identifier, title = doc.title, resolve = "archive",
				year = tonumber(doc.year) or tonumber(tostring(doc.date or ""):match("^(%d%d%d%d)")),
				overview = type(doc.description) == "string" and doc.description:gsub("<[^>]+>", "") or nil,
				poster_url = "https://archive.org/services/img/" .. doc.identifier }
		end
	end
	return out
end

--- Pick the file to play from an Internet Archive item's metadata.
-- @tparam string text JSON
-- @tparam string identifier
-- @treturn string|nil an address
function M.archiveFile(text, identifier)
	local ok, data = pcall(cjson.decode, text)
	if not ok or type(data) ~= "table" or type(data.files) ~= "table" then return nil end
	local best, best_score
	for _, file in ipairs(data.files) do
		local name = type(file.name) == "string" and file.name or ""
		local extension = extension_of(name)
		local score = (extension == "mp4" and 3) or (extension == "webm" and 2) or (extension == "ogv" and 1) or 0
		if name:lower():find("512kb", 1, true) then score = score - 0.5 end
		if score > 0 and not name:find("..", 1, true) and (not best or score > best_score) then
			best, best_score = name, score
		end
	end
	if not best then return nil end
	return "https://archive.org/download/" .. identifier .. "/" .. best:gsub("[^%w%-_.~/]", function(c)
		return string.format("%%%02X", c:byte())
	end)
end

--- Read a Jellyfin or Emby library.
-- @tparam string text JSON
-- @tparam string base the server's address
-- @treturn table entries
function M.parseJellyfin(text, base)
	local ok, data = pcall(cjson.decode, text)
	local items = ok and type(data) == "table" and data.Items
	local out = {}
	base = base:gsub("/+$", "")
	for _, item in ipairs(type(items) == "table" and items or {}) do
		if type(item.Id) == "string" and item.Id:match("^%w+$") and type(item.Name) == "string" then
			out[#out + 1] = { key = item.Id, title = item.Name, year = tonumber(item.ProductionYear),
				overview = type(item.Overview) == "string" and item.Overview or nil,
				duration_ms = tonumber(item.RunTimeTicks) and math.floor(item.RunTimeTicks / 10000) or nil,
				url = base .. "/Videos/" .. item.Id .. "/stream?static=true", auth = "key",
				poster_url = base .. "/Items/" .. item.Id .. "/Images/Primary",
				backdrop_url = base .. "/Items/" .. item.Id .. "/Images/Backdrop" }
		end
	end
	return out
end

--- Read a list of magnet links.
-- @tparam string text one per line
-- @treturn table entries
function M.parseLinks(text)
	local out = {}
	for line in (tostring(text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		local hash = line:match("^magnet:%?xt=urn:btih:(%w+)")
		if hash and #out < M.MAX_ENTRIES then
			local name = line:match("[?&]dn=([^&]+)")
			out[#out + 1] = entry(hash:lower(), name and unescape(name:gsub("%+", " ")) or ("Torrent " .. hash:sub(1, 8)), line,
				{ resolve = "torrent" })
		end
	end
	return out
end

--- What to fetch for a source.
-- @tparam table provider
-- @tparam table config
-- @treturn[1] table an HTTP request, or `{ local_text = ... }` when there's nothing to fetch
-- @treturn[2] nil
-- @treturn[2] string why
function M.request(provider, config)
	local kind = provider.kind
	if kind == "website" then return require("libs.websources").request(provider, "", 1, config.url) end
	if kind == "torrent" then return { local_text = config.links or "" } end
	if kind == "archive" then
		local collection = tostring((provider.config or {}).collection or config.collection or "")
		if not collection:match("^[%w_-]+$") then return nil, "this provider has no collection" end
		local rights = collection == "classic_tv"
			and "+AND+licenseurl%3A%22http%3A%2F%2Fcreativecommons.org%2Flicenses%2Fpublicdomain%2F%22" or ""
		return { url = "https://archive.org/advancedsearch.php?q=collection%3A" .. collection
			.. "+AND+mediatype%3Amovies" .. rights
			.. "+AND+NOT+collection%3Amoviesandfilms_adult+AND+NOT+subject%3A%28adult+OR+porn+OR+erotic%29"
			.. "&fl%5B%5D=identifier&fl%5B%5D=title&fl%5B%5D=year&fl%5B%5D=date"
			.. "&fl%5B%5D=description&sort%5B%5D=downloads+desc&rows=200&output=json" }
	end
	if not M.isWebAddress(config.url) then return nil, "that isn't a web address" end
	if kind == "jellyfin" then
		return { url = config.url:gsub("/+$", "") .. "/Items?Recursive=true&IncludeItemTypes=Movie&Fields=Overview&Limit=2000",
			headers = { ["X-Emby-Token"] = config.key } }
	end
	return { url = config.url }
end

--- Turn a source's answer into entries.
-- @tparam table provider
-- @tparam table config
-- @tparam string text
-- @treturn table entries
function M.parse(provider, config, text)
	local kind = provider.kind
	if kind == "website" then
		local web = require("libs.websources")
		local base = config.url or (provider.config or {}).base
		local result = web.parse(text, base, provider)
		if #result.items == 0 then
			result.items[1] = { key = base, title = result.title ~= "" and result.title or base,
				url = base, resolve = "webpage", overview = result.overview, poster_url = result.poster_url,
				source_id = result.source_id or provider.id, source_url = result.source_url, attribution = result.attribution }
		end
		return result.items
	end
	if kind == "m3u" then return M.parseM3u(text) end
	if kind == "feed" then return M.parseFeed(text) end
	if kind == "index" then return M.parseIndex(text, config.url) end
	if kind == "archive" then return M.parseArchive(text) end
	if kind == "jellyfin" then return M.parseJellyfin(text, config.url) end
	if kind == "torrent" then return M.parseLinks(text) end
	return {}
end

return M

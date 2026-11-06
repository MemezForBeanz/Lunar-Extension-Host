-- Lunar Media: browse, inspect and play your own library.
--
-- The desktop half of Lunar Media. The catalog lives in the media-server extension, on this
-- computer or another one. Until one is connected, the pages show a made-up sample library,
-- so they can be read, judged and tried before the first scan.

local sample = require("libs.sample")
local Client = require("libs.client")
local library = require("ui.library")
local player = require("ui.player")
local server = require("ui.server")
local sources_page = require("ui.sources")
local dock = require("ui.dock")
local artcache = require("libs.artcache")
local forecast = require("libs.forecast")
local platform = require("core.platform")
local lfs = require("lfs")

local M = { name = "media" }

local TICK_MS = 30
local NOW_PLAYING_TAB = 2
local OPEN_WAIT_TICKS = 20    -- ticks between asking whether a remote file is ready
local OPEN_MAX_TRIES = 90
local NOW_PLAYING_TITLE = "Now playing"
local URL_SETTING = "media.server_url"
local TOKEN_SECRET = "server_token"

local function poster_cache()
	local ok, PosterCache = pcall(require, "core.ui.PosterCache")
	if not ok then return nil end
	return (PosterCache.new({ max_mb = 128 }))
end

local function queue_rows(queue)
	local rows = {}
	for i, item in ipairs(queue or {}) do
		rows[i] = { title = item.title, column1 = item.minutes and (item.minutes .. " min") or "" }
	end
	return rows
end

function M:_notify(title, body, kind)
	self.ctx:notify({ title = title, body = body, kind = kind or "info" }, self)
end

function M:_server_address()
	return os.getenv("LUNAR_MEDIA_SERVER") or self.ctx.settings:get(URL_SETTING)
end

function M:_server_token()
	return os.getenv("LUNAR_MEDIA_TOKEN") or self.ctx:getSecret(self, TOKEN_SECRET)
end

--- Where to connect: a server the owner named, or else this computer's own service.
function M:_target()
	local address, token = self:_server_address(), self:_server_token()
	if address and address ~= "" and token then return address, token end
	local here = self.ctx.localService and self.ctx:localService(self)
	if here then return here.url, here.token end
end

--- Connect, or fall back to the sample library and say why.
function M:connect()
	local address, token = self:_target()
	if not address then return end
	local ctx = self.ctx
	self.client = Client.new(function(request, done) return ctx:http(request, done, self) end, address, token)
	self.art_cache = self:_art_cache(address)
	self.art_urls = {}
	self.client:load(function(model, why)
		if not model then
			self.client = nil
			return self:_notify("Could not reach the media server", why, "error")
		end
		for _, film in ipairs(model.films) do
			self.art_urls[film.id .. "poster"] = film.art_urls and film.art_urls.poster
			self.art_urls[film.id .. "backdrop"] = film.art_urls and film.art_urls.backdrop
		end
		self.library.setModel(model)
		self.server.setModel(model)
		self.now_playing.endDemo()
		self.sources_page.setData(model.origins)
		self.client:providers(function(list) self.sources_page.setData(nil, list) end)
	end)
end

-- Art from a server is kept per server, so two servers' item ids never collide.
function M:_art_cache(address)
	local dir = platform.path:join(platform.cache_dir(), "media-art")
	lfs.mkdir(platform.cache_dir())
	lfs.mkdir(dir)
	dir = platform.path:join(dir, (address:gsub("%W", "_")))
	lfs.mkdir(dir)
	return artcache.new({ dir = dir,
		fetch = function(id, kind, done)
			local url = self.art_urls and self.art_urls[id .. kind]
			if url then return self.client:artFrom(url, done) end
			self.client:art(id, kind, done)
		end,
		exists = function(path) return lfs.attributes(path, "mode") == "file" end,
		write = function(path, bytes)
			local file = io.open(path, "wb")
			if not file then return false end
			file:write(bytes)
			file:close()
			return true
		end,
		on_arrival = function() self.art_arrived = true end,
	})
end

function M:_add_source(provider, config, name, accepted)
	if provider.off_by_default and not accepted then
		return self:_notify("Tick the notice first", "Torrents stay off until you accept what they do.", "warning")
	end
	if not self.client then return self:_notify("Connect a server first", "Sources live on the server.") end
	self.client:addSource({ provider = provider.id, name = name, config = config, accept_notice = accepted }, function(_, why)
		if why then return self:_notify("Could not add that source", why, "error") end
		self:_notify("Added " .. provider.name, "Its titles join the library once it has synced.")
		self:_reload()
	end)
end

function M:_remove_source(source)
	if not self.client or not source.source_id then return self:_notify("This one can't be removed here") end
	self.client:removeSource(source.source_id, function() self:_reload() end)
end

function M:_reload()
	self.client:load(function(model)
		if not model then return end
		self.library.setModel(model)
		self.server.setModel(model)
		self.sources_page.setData(model.origins)
	end)
end

function M:_save_collection(entry)
	self.library.addCollection(entry)
	if self.client then self.client:saveCollection(entry, function() end) end
end

function M:_enrich(item, done)
	if not self.client or item.detailed then return end
	self.client:detail(item.id, function(detail)
		if not detail then return end
		item.detailed = true
		Client.applyDetail(item, detail)
		done()
	end)
end

function M:_start(item, decision)
	if decision.mode ~= "direct" then
		return self:_notify("Lunar can't play this yet", decision.reason, "warning")
	end
	local client = self.client
	local ok, why = self.now_playing.play({
		url = client:streamUrl(item.file_id), header = client:authHeader(), title = item.title,
		queue = queue_rows(self.queue),
		detail = table.concat({ item.resolution or "", item.codec or "", item.audio or "" }, " · "),
		start = (item.position_ms or 0) / 1000,
		on_position = function(seconds, length)
			client:saveProgress(item.id, math.floor(seconds * 1000), math.floor(length * 1000))
		end,
	})
	if not ok then return self:_notify("Could not start the player", why, "error") end
	self.ctx:focusTab(self, NOW_PLAYING_TAB)
end

function M:_mark(item, watched)
	if self.client then self.client:mark(item.id, watched) end
end

-- A forecast is the server's own decision, asked for each kind of device. The sample has no
-- server, so it works one out from what its made-up films claim to be.
function M:_decide(item, profile, done)
	if not self.client then return done(forecast.sampleDecision(item, profile)) end
	local function ask()
		if not item.file_id then return done({ mode = "refuse", reason = "this title has no file" }) end
		self.client:decision(item.file_id, function(decision, why)
			done(decision or { mode = "refuse", reason = why })
		end, profile.caps)
	end
	if item.file_id then return ask() end
	self.client:detail(item.id, function(detail)
		if detail then Client.applyDetail(item, detail) end
		ask()
	end)
end

function M:_seasons(item, done)
	if not self.client then return done(sample.seasons(item)) end
	self.client:episodes(item.id, function(seasons, why)
		if not seasons then self:_notify("Could not load the episodes", why, "error") end
		done(seasons or {})
	end)
end

-- Open one copy. When it can't play, the next copy takes over, so a dead source costs a moment
-- rather than an evening.
function M:_play_copy()
	local try = self.attempt
	local entry = try and try.copies[try.index]
	if not entry then
		return self:_notify("No copy of this could be played", try and try.why or nil, "error")
	end
	local item = entry.item or entry
	self.client:detail(item.id, function(detail, why)
		if not detail then return self:_copy_failed(why) end
		Client.applyDetail(item, detail)
		if not item.file_id then return self:_copy_failed("this item has no file to play") end
		if item.offline then return self:_copy_failed("this file is offline") end
		if item.is_remote then
			self.opening = { item = item, wait = 0, tries = 0 }
			return self:_ask_open()
		end
		self.client:decision(item.file_id, function(decision, problem)
			if not decision then return self:_copy_failed(problem) end
			self:_start(item, decision)
		end)
	end)
end

function M:_copy_failed(why)
	local try = self.attempt
	if not try then return end
	try.why = why
	try.index = try.index + 1
	local following = try.copies[try.index]
	if following then self:_notify("Trying the copy on " .. tostring(following.source or "another source"), why, "warning") end
	self:_play_copy()
end

function M:_ask_open()
	local opening = self.opening
	if not opening then return end
	self.client:open(opening.item.file_id, function(answer)
		if self.opening ~= opening then return end
		if answer.pending then
			opening.tries = opening.tries + 1
			opening.wait = OPEN_WAIT_TICKS
			if opening.tries > OPEN_MAX_TRIES then
				self.opening = nil
				self:_copy_failed("the source took too long to answer")
			end
			return
		end
		self.opening = nil
		if answer.error then return self:_copy_failed(answer.error) end
		self:_start_remote(opening.item, answer)
	end)
end

function M:_start_remote(item, answer)
	local client = self.client
	local ok, why = self.now_playing.play({ url = answer.url, header = answer.header, title = item.title,
		detail = item.sources and item.sources[1] or "", queue = queue_rows(self.queue),
		start = (item.position_ms or 0) / 1000,
		on_position = function(seconds, length)
			client:saveProgress(item.id, math.floor(seconds * 1000), math.floor(length * 1000))
		end })
	if not ok then return self:_notify("Could not start the player", why, "error") end
	self.ctx:focusTab(self, NOW_PLAYING_TAB)
end

function M:_play(item, queue)
	self.queue = queue or {}
	if not self.client then
		return self:_notify("Connect a server to play media", "Add its address and token in Settings under Lunar Media.")
	end
	self.attempt = { copies = item.copy_list or { { item = item } }, index = 1 }
	self:_play_copy()
end

function M:_settings()
	local ctx, iup = self.ctx, self.ctx.iup
	local address = iup.text({ VALUE = ctx.settings:get(URL_SETTING) or "", RASTERSIZE = "320x", CUEBANNER = "https://host:8421" })
	local token = iup.text({ VALUE = "", RASTERSIZE = "320x", PASSWORD = "YES", CUEBANNER = "Bearer token" })
	local connect = require("core.ui.Kit").button(iup, { title = "Connect", role = "primary_btn", action = function()
		ctx.settings:set(URL_SETTING, address.value)
		ctx.settings:save()
		if token.value ~= "" then
			local saved, why = ctx:setSecret(self, TOKEN_SECRET, token.value)
			if not saved then return self:_notify("Could not save the token", why, "error") end
			token.value = ""
		end
		self:connect()
	end })
	ctx:addSettings("Lunar Media", { icon = "media--library", entries = {
		{ label = "Server address", description = "Where your Lunar Media Server is listening.", widget = address },
		{ label = "Access token", description = "A token from the server's tokens file. It is kept in your system keyring.", widget = token },
		{ label = "Connect", description = "Load your libraries from this server.", widget = connect },
	} }, self)
end

function M:register(ctx)
	self.ctx = ctx
	local model = sample.library()
	local art_dir = os.getenv("LUNAR_MEDIA_ART")
	local extension = self
	local function art_of(item)
		if extension.art_cache and type(item.art) == "table" then return extension.art_cache:best(item, "poster") end
		if not art_dir or not item.art then return nil end
		return string.format("%s/poster-%02d.png", art_dir, item.art)
	end
	self.cache = poster_cache()
	local function animate(spec) return ctx:animate(spec, self) end
	self.now_playing = player.new(ctx, { sample = model.films[1], animate = animate, owner = self, demo = true,
		cache = self.cache, art = art_of(model.films[1]) })
	local function backdrop_of(item)
		if extension.art_cache and type(item.art) == "table" then return extension.art_cache:best(item, "backdrop") end
		if not art_dir or not item.art then return nil end
		return string.format("%s/backdrop-%02d.png", art_dir, item.art)
	end
	self.dock = dock.new(ctx, { player = self.now_playing, owner = self, cache = self.cache,
		open = function() ctx:focusTab(self, NOW_PLAYING_TAB) end,
		art_path = function() return art_of(model.films[1]) end })
	self.now_playing.on_change = function() self.dock.refresh() end
	self.now_playing.on_failed = function() self:_copy_failed("it stopped with an error") end
	self.now_playing.on_finished = function()
		local upcoming = self.queue or {}
		local following = table.remove(upcoming, 1)
		if following then self:_play(following, upcoming) end
	end
	self.dock.refresh()
	self.library = library.new(ctx, {
		model = model, cache = self.cache, art_of = art_of, backdrop_of = backdrop_of, owner = self,
		on_play = function(item, queue) self:_play(item, queue) end,
		enrich = function(item, done) self:_enrich(item, done) end,
		on_save_collection = function(entry) self:_save_collection(entry) end,
		on_mark = function(item, watched) self:_mark(item, watched) end,
		load_seasons = function(item, done) self:_seasons(item, done) end,
		decide = function(item, profile, done) self:_decide(item, profile, done) end,
		on_connect = function() ctx:dispatchAddress("lunar://host/settings") end,
	})
	self.server = server.new(ctx, { model = model })
	self.sources_page = sources_page.new(ctx, { sources = model.origins, providers = sample.PROVIDERS,
		on_add = function(provider, config, name, accepted) self:_add_source(provider, config, name, accepted) end,
		on_sync = function(source)
			if self.client and source.source_id then self.client:syncSource(source.source_id) end
			self:_notify("Syncing " .. source.name)
		end,
		on_remove = function(source) self:_remove_source(source) end })

	ctx:addTab("Media", self.library.widget, self, { icon = "grid" })
	ctx:addTab(NOW_PLAYING_TITLE, self.now_playing.widget, self, { icon = "play--outline" })
	ctx:addTab("Sources", self.sources_page.widget, self, { icon = "globe" })
	ctx:addTab("Media server", self.server.widget, self, { icon = "data--base" })
	ctx:fitPage(self.library.widget, self.library.fit)
	ctx:fitPage(self.now_playing.widget, self.now_playing.fit)
	ctx:onTabChange(function(page)
		self.dock.setAway(page ~= nil and ctx.iup.GetAttribute(page, "TABTITLE") == NOW_PLAYING_TITLE)
	end, self)
	-- A film can't be watched in a hidden window. Sound alone is fine, but nobody asked for it.
	ctx:onWindow(function(state)
		if state == "hidden" then self.now_playing.pause() end
	end, self)
	self:_settings()

	self.timer = ctx:addTimer({ time = TICK_MS, run = true, action = function()
		if self.opening then
			self.opening.wait = self.opening.wait - 1
			if self.opening.wait == 0 then self:_ask_open() end
		end
		if self.art_arrived then
			self.art_arrived = false
			self.library.repaintArt()
		end
		self.library.tick()
		if self.now_playing.tick then self.now_playing.tick() end
		self.dock.tick()
		self.now_playing.pump()
	end }, self)

	ctx:registerRouteHandler("library", function(params)
		self.library.go(params.view or "sheet")
		return true
	end, self)

	ctx:onReady(function() self:connect() end, self)

	local shell = rawget(_G, "LUNAR_DEV_SHELL")
	if shell then
		shell.pages = shell.pages or {}
		shell.pages["Media"] = { states = { "home", "sheet", "filtered", "collection", "ledger", "shows", "title", "show", "source" }, show = self.library.go }
		local states = { "wait", "paused" }
		if os.getenv("LUNAR_MEDIA_SERVER") then states = { "wait", "paused", "play", "playing", "playing2", "playing3" } end
		for i = 1, tonumber(os.getenv("LUNAR_CAPTURE_LINGER") or "0") do states[#states + 1] = "linger" .. i end
		shell.pages["Now playing"] = { states = states, show = function(name)
			if name == "play" then self:_play(self.library.find(os.getenv("LUNAR_CAPTURE_PLAY")) or self.library.first()) end
		end }
	end
end

function M:shutdown()
	if self.now_playing then self.now_playing.close() end
	if self.cache then self.cache:close() end
end

return M

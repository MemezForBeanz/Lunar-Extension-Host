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
local dock = require("ui.dock")
local artcache = require("libs.artcache")
local platform = require("core.platform")
local lfs = require("lfs")

local M = { name = "media" }

local TICK_MS = 30
local NOW_PLAYING_TAB = 2
local NOW_PLAYING_TITLE = "Now playing"
local URL_SETTING = "media.server_url"
local TOKEN_SECRET = "server_token"

local function poster_cache()
	local ok, PosterCache = pcall(require, "core.ui.PosterCache")
	if not ok then return nil end
	return (PosterCache.new({ max_mb = 128 }))
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
	self.client:load(function(model, why)
		if not model then
			self.client = nil
			return self:_notify("Could not reach the media server", why, "error")
		end
		self.library.setModel(model)
		self.server.setModel(model)
		self.now_playing.endDemo()
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
		fetch = function(id, kind, done) self.client:art(id, kind, done) end,
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

function M:_seasons(item, done)
	if not self.client then return done(sample.seasons(item)) end
	self.client:episodes(item.id, function(seasons, why)
		if not seasons then self:_notify("Could not load the episodes", why, "error") end
		done(seasons or {})
	end)
end

local function queue_rows(queue)
	local rows = {}
	for i, item in ipairs(queue or {}) do
		rows[i] = { title = item.title, column1 = item.minutes and (item.minutes .. " min") or "" }
	end
	return rows
end

function M:_play(item, queue)
	self.queue = queue or {}
	if not self.client then
		return self:_notify("Connect a server to play media", "Add its address and token in Settings under Lunar Media.")
	end
	self.client:detail(item.id, function(detail, why)
		if not detail then return self:_notify("Could not open this item", why, "error") end
		Client.applyDetail(item, detail)
		if not item.file_id then return self:_notify("This item has no file to play") end
		if item.offline then return self:_notify("This file is offline", item.path) end
		self.client:decision(item.file_id, function(decision, problem)
			if not decision then return self:_notify("Could not open this item", problem, "error") end
			self:_start(item, decision)
		end)
	end)
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
		on_connect = function() ctx:dispatchAddress("lunar://host/settings") end,
	})
	self.server = server.new(ctx, { model = model })

	ctx:addTab("Media", self.library.widget, self, { icon = "grid" })
	ctx:addTab(NOW_PLAYING_TITLE, self.now_playing.widget, self, { icon = "play--outline" })
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
		shell.pages["Media"] = { states = { "home", "sheet", "filtered", "collection", "ledger", "shows", "title", "show" }, show = self.library.go }
		local states = { "wait", "paused" }
		if os.getenv("LUNAR_MEDIA_SERVER") then states = { "wait", "paused", "play", "playing", "playing2", "playing3" } end
		shell.pages["Now playing"] = { states = states, show = function(name)
			if name == "play" then self:_play(self.library.first()) end
		end }
	end
end

function M:shutdown()
	if self.now_playing then self.now_playing.close() end
	if self.cache then self.cache:close() end
end

return M

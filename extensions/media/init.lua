-- Lunar Media: browse, inspect and play your own library.
--
-- The desktop half of Lunar Media. The catalog lives in the media-server extension, on this
-- computer or another one. Until one is connected, the pages show a made-up sample library,
-- so they can be read, judged and tried before the first scan.

local sample = require("libs.sample")
local library = require("ui.library")
local player = require("ui.player")
local server = require("ui.server")

local M = { name = "media" }

local TICK_MS = 30

local function poster_cache()
	local ok, PosterCache = pcall(require, "core.ui.PosterCache")
	if not ok then return nil end
	return (PosterCache.new({ max_mb = 128 }))
end

function M:register(ctx)
	self.ctx = ctx
	local model = sample.library()
	local art_dir = os.getenv("LUNAR_MEDIA_ART")
	local function art_of(item)
		if not art_dir or not item.art then return nil end
		return string.format("%s/poster-%02d.png", art_dir, item.art)
	end
	self.cache = poster_cache()
	local function animate(spec) return ctx:animate(spec, self) end
	self.now_playing = player.new(ctx, { sample = model.films[1], animate = animate, owner = self,
		cache = self.cache, art = art_of(model.films[1]) })
	self.library = library.new(ctx, {
		model = model, cache = self.cache, art_of = art_of, owner = self,
		on_play = function() ctx:notify({ title = "Connect a server to play media", kind = "info" }, self) end,
	})
	self.server = server.new(ctx, { model = model })

	ctx:addTab("Media", self.library.widget, self, { icon = "media--library" })
	ctx:addTab("Now Playing", self.now_playing.widget, self, { icon = "play--filled--alt" })
	ctx:addTab("Media Server", self.server.widget, self, { icon = "server--dns" })
	ctx:fitPage(self.library.widget, self.library.fit)
	ctx:fitPage(self.now_playing.widget, self.now_playing.fit)

	self.timer = ctx:addTimer({ time = TICK_MS, run = true, action = function()
		self.library.tick()
		if self.now_playing.tick then self.now_playing.tick() end
	end }, self)

	ctx:registerRouteHandler("library", function(params)
		self.library.go(params.view or "sheet")
		return true
	end, self)

	local shell = rawget(_G, "LUNAR_DEV_SHELL")
	if shell then
		shell.pages = shell.pages or {}
		shell.pages["Media"] = { states = { "home", "sheet", "ledger", "shows" }, show = self.library.go }
		shell.pages["Now Playing"] = { states = { "wait", "paused" }, show = function() end }
	end
end

function M:shutdown()
	if self.now_playing then self.now_playing.close() end
	if self.cache then self.cache:close() end
end

return M

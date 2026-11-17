local Element = require("core.imgui.Element")
local Harness = require("spec.support.imgui_extension_harness")
local platform = require("core.platform")

local function all(ctx)
	local result = {}
	ctx.walk(ctx.tabs, result)
	return result
end

local function matching(ctx, predicate, visible)
	local result = {}
	for _, widget in ipairs(all(ctx)) do
		if (not visible or ctx.visible(widget)) and predicate(widget) then result[#result + 1] = widget end
	end
	return result
end

local function one(ctx, predicate, description)
	local found = matching(ctx, predicate, true)
	assert.equals(1, #found, description or "expected one widget")
	return found[1]
end

local function title(ctx, text)
	return one(ctx, function(widget)
		return ctx.iup.GetAttribute(widget, "TITLE") == text
	end, "missing visible TITLE " .. text)
end

local function class(ctx, name, extra)
	return one(ctx, function(widget)
		return ctx.iup.GetClassName(widget) == name and (not extra or extra(widget))
	end, "missing visible " .. name)
end

local function tab(ctx, name)
	local found = matching(ctx, function(widget)
		return ctx.iup.GetAttribute(widget, "TABTITLE") == name
	end, false)
	assert.equals(1, #found, "missing tab " .. name)
	return found[1]
end

describe("media 1.6.2 flows on the ImGui host", function()
	it("shows the demo player and changes play, seek, and volume state", function()
		local old_open = platform.open
		finally(function() platform.open = old_open end)
		platform.open = function() return true end
		local _, _, warnings = Harness.run("extensions/media/init.lua", "extensions/media", {
			skip_default_exercise = true,
			exercise = function(ctx)
				ctx.iup.SetAttribute(ctx.tabs, "VALUEPOS", "2")
				for _ = 1, 3 do ctx.runtime.frame() end
				local page = tab(ctx, "Now playing")
				assert.is_true(ctx.visible(ctx.extension.now_playing.widget))
				assert.is_true(title(ctx, "The Salt Line") ~= nil)
				assert.is_true(title(ctx, "Paused") ~= nil)

				local toggle = one(ctx, function(widget)
					return ctx.iup.GetClassName(widget) == "flatbutton"
						and ctx.iup.GetAttribute(widget, "TIP") == "Play or pause (Space)"
				end)
				ctx.invoke(toggle, "FLAT_ACTION")
				assert.is_false(ctx.extension.now_playing.state().paused)
				assert.is_not_nil(title(ctx, "Playing"))

				local seek = class(ctx, "flatseek", function(widget)
					return tonumber(ctx.iup.GetAttribute(widget, "MAX")) == 7680
				end)
				ctx.invoke(seek, "SEEK_CB", 120)
				ctx.iup.SetAttribute(seek, "VALUE", "120")
				assert.equals("120", ctx.iup.GetAttribute(seek, "VALUE"))

				local volume = class(ctx, "flatseek", function(widget)
					return tonumber(ctx.iup.GetAttribute(widget, "MAX")) == 100
				end)
				ctx.invoke(volume, "SEEK_CB", 55)
				assert.equals(55, ctx.extension.now_playing.state().volume)
			end,
		})
		assert.same({}, warnings)
	end)

	it("groups demo shows and exposes their episodes on the title page", function()
		local _, _, warnings = Harness.run("extensions/media/init.lua", "extensions/media", {
			skip_default_exercise = true,
			exercise = function(ctx)
				ctx.iup.SetAttribute(ctx.tabs, "VALUEPOS", "1")
				for _ = 1, 3 do ctx.runtime.frame() end
				ctx.extension.library.go("shows")
				for _ = 1, 4 do ctx.runtime.frame() end

				local shows = class(ctx, "flatgrid", function(widget)
					return ctx.iup.GetAttribute(widget, "COUNT") == "8"
						and Element.hasCallback(widget, "CELL_ACTION_CB")
				end)
				assert.equals("8", ctx.iup.GetAttribute(shows, "COUNT"))
				ctx.invoke(shows, "CELL_ACTION_CB", 1)
				ctx.invoke(one(ctx, function(widget)
					return ctx.iup.GetAttribute(widget, "TITLE") == "Episodes"
				end), "FLAT_ACTION")
				ctx.extension.library.go("show")
				for _ = 1, 3 do ctx.runtime.frame() end
				assert.is_not_nil(title(ctx, "Harbour Lights"))

				local episodes = class(ctx, "flatrows", function(widget)
					return Element.hasCallback(widget, "ROWVALUE_CB")
						and ctx.iup.GetAttribute(widget, "COUNT") == "8"
				end)
				assert.equals("8", ctx.iup.GetAttribute(episodes, "COUNT"))
				local found_episode = false
				for pos = 1, 8 do
					if Element.call(episodes, "ROWVALUE_CB", pos, "TITLE") == "Dead Reckoning" then
						found_episode = true
						break
					end
				end
				assert.is_true(found_episode)
			end,
		})
		assert.same({}, warnings)
	end)

	it("queues a discovered media download without making network or shell calls", function()
		local old_open = platform.open
		finally(function() platform.open = old_open end)
		platform.open = function() error("unexpected URL open") end
		local _, _, warnings = Harness.run("extensions/media/init.lua", "extensions/media", {
			skip_default_exercise = true,
			exercise = function(ctx)
				local queued = {
					id = 91, title = "Fixture episode", state = "queued", bytes = 0, total_bytes = 12,
				}
				ctx.extension.client = {
					discover = function(_, _, done)
						done({ state = "ready", id = "fixture-job", result = {
							title = "Fixture results", items = {
								{ key = "fixture", title = "Fixture episode", year = 2026, episode = 1 },
							},
						} })
					end,
					downloadDiscovery = function(_, _, _, _, done) done(queued) end,
					downloads = function(_, done) done({ queued }) end,
					detail = function(_, _, done) done({}) end,
					load = function() end,
				}
				ctx.extension.sources_page.setData(nil, {
					{ id = "archive-feature-films", name = "Internet Archive: Feature Films",
						kind = "archive", summary = "Fixture archive" },
				}, {
					{ id = 1, name = "Films" },
				})

				ctx.iup.SetAttribute(ctx.tabs, "VALUEPOS", "3")
				for _ = 1, 3 do ctx.runtime.frame() end
				local provider = class(ctx, "flatrows", function(widget)
					return Element.hasCallback(widget, "ROW_ACTION_CB")
						and ctx.iup.GetAttribute(widget, "COUNT") ~= "0"
						and Element.call(widget, "ROWVALUE_CB", 1, "TITLE") == "Internet Archive: Feature Films"
				end)
				ctx.invoke(provider, "ROW_ACTION_CB", 1)
				ctx.invoke(one(ctx, function(widget)
					return ctx.iup.GetAttribute(widget, "TITLE") == "Search / Browse"
				end), "FLAT_ACTION")
				ctx.invoke(one(ctx, function(widget)
					return ctx.iup.GetAttribute(widget, "TITLE") == "Download to library"
				end), "FLAT_ACTION")
				ctx.extension.sources_page.tick()
				ctx.runtime.frame()

				local downloads = class(ctx, "flatrows", function(widget)
					return ctx.iup.GetAttribute(widget, "COUNT") == "1"
						and ctx.iup.GetAttribute(widget, "ROWHEIGHT") == "52"
						and Element.hasCallback(widget, "ROWVALUE_CB")
						and Element.call(widget, "ROWVALUE_CB", 1, "TITLE") == "Fixture episode"
				end)
				assert.equals("1", ctx.iup.GetAttribute(downloads, "COUNT"))
				assert.is_true(title(ctx, "Downloads: 1 · Active: 1 · Failed: 0") ~= nil)
			end,
		})
		assert.same({}, warnings)
	end)
end)

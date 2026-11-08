describe("source download controls", function()
	local function page(options)
		local buttons, rows, lists = {}, {}, {}
		local function widget(spec) return { attrs = spec or {} } end
		local iup = { flatlabel = widget, hbox = widget, vbox = widget, fill = widget }
		function iup.list(spec) local w = widget(spec); lists[#lists + 1] = w; return w end
		function iup.SetAttribute(w, key, value) w.attrs[key] = value end
		function iup.GetAttribute(w, key) return w.attrs[key] end
		local modules = {
			["core.lib.CarbonLayout"] = { gap = function() return 8 end },
			["core.ui.Kit"] = {
				statusLine = function() return widget() end,
				setStatus = function() end,
				button = function(_, spec) buttons[spec.title] = spec.action; return widget() end,
			},
			["core.ui.FlatField"] = { new = function() return { widget = widget(), value = function() return "" end } end },
			["core.ui.RowList"] = { new = function(_, spec)
				local row = { widget = widget(), spec = spec }
				function row:setProvider(count, value) self.count, self.value = count, value end
				function row:select(pos) self.selected = pos; if spec.on_select then spec.on_select(pos) end end
				rows[spec.empty_title or "providers"] = row
				return row
			end },
		}
		local chunk = assert(loadfile("extensions/media/ui/discover.lua"))
		setfenv(chunk, setmetatable({ require = function(name) return assert(modules[name], name) end }, { __index = _G }))
		return chunk().new({ iup = iup }, options), buttons, rows, lists
	end

	it("cancels the selected persisted job and retains its identity when the list reorders", function()
		local jobs = { { id = 1, title = "First", state = "complete" }, { id = 2, title = "Second", state = "running" } }
		local cancelled
		local api, buttons, rows = page({
			on_downloads = function(done) done(jobs) end,
			on_cancel_download = function(id, done) cancelled = id; done({}) end,
		})
		api.tick()
		rows["No downloads"]:select(2)
		jobs = { jobs[2], jobs[1] }
		for _ = 1, 100 do api.tick() end
		assert.equals(1, rows["No downloads"].selected)
		buttons["Cancel download"]()
		assert.equals(2, cancelled)
	end)

	it("keeps the chosen destination library when the server changes library order", function()
		local api, _, _, lists = page({ libraries = { { id = 5, name = "A" }, { id = 9, name = "B" } } })
		lists[1].attrs.VALUE = "2"
		api.setLibraries({ { id = 9, name = "B" }, { id = 5, name = "A" } })
		assert.equals("1", lists[1].attrs.VALUE)
	end)

	it("allows only one download status request in flight", function()
		local requests = 0
		local api = page({ on_downloads = function() requests = requests + 1 end })
		for _ = 1, 500 do api.tick() end
		assert.equals(1, requests)
	end)

	it("offers only owned local libraries as download destinations", function()
		local _, _, _, lists = page({ libraries = {
			{ id = 1, name = "Remote source", source_id = 8 }, { id = 2, name = "Owned library" },
		} })
		assert.equals("Owned library", lists[1].attrs["1"])
		assert.is_nil(lists[1].attrs["2"])
	end)
end)

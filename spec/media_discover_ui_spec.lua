describe("source download controls", function()
	local function page(options, context)
		local buttons, rows, lists = {}, {}, {}
		local function widget(spec) return { attrs = spec or {} } end
		local iup = { flatlabel = widget, hbox = widget, vbox = widget, fill = widget }
		function iup.list(spec) local w = widget(spec); lists[#lists + 1] = w; return w end
		function iup.SetAttribute(w, key, value) w.attrs[key] = value end
		function iup.GetAttribute(w, key) return w.attrs[key] end
		local modules = {
			["core.lib.CarbonLayout"] = { gap = function() return 8 end, sectionTitle=function(_,t) return widget({TITLE=t}) end, hint=function(_,t) return widget({TITLE=t}) end },
			["core.ui.Kit"] = {
				statusLine = function() return widget() end,
                show = function(_, w, on) w.attrs.VISIBLE=on and 'YES' or 'NO' end,
                disclosure = function(_, spec) buttons[spec.title]=spec.on_change;return widget() end,
                page = function(_, spec)
                    local kit_page={opts=spec,stateLine=widget(),toolbar=widget(),config=widget()}
                    function kit_page:widget() return widget() end
                    function kit_page:openInspector(on) self.inspectorOpen=on end
                    function kit_page:setState() end
                    function kit_page:fit() end
                    function kit_page:setSecondary() end
                    return kit_page
                end,
				setStatus = function() end,
				button = function(_, spec) buttons[spec.title] = spec.action; return widget() end,
			},
			["core.ui.FlatField"] = { new = function() return { widget = widget(), value = function() return "" end } end },
			["core.ui.RowList"] = { new = function(_, spec)
				local row = { widget = widget(), spec = spec }
				function row:setEmpty(title,hint) self.emptyTitle=title;self.emptyHint=hint end
				function row:setProvider(count, value) self.count, self.value = count, value end
				function row:select(pos) self.selected = pos; if spec.on_select then spec.on_select(pos) end end
				rows[spec.empty_title or "providers"] = row
				return row
			end },
		}
		local chunk = assert(loadfile("extensions/media/ui/discover.lua"))
		setfenv(chunk, setmetatable({ require = function(name) return assert(modules[name], name) end }, { __index = _G }))
		local ctx={iup=iup};for k,v in pairs(context or {}) do ctx[k]=v end
		return chunk().new(ctx, options), buttons, rows, lists
	end

    it("rethemes Search when a connected provider enables it", function()
        local painted
        local api = page({is_connected=function() return false end,providers={{id="archive",kind="archive",name="Archive"}}},
            {notifyTreeChange=function(_,w) painted=w end})
        api.capture("connected")
        assert.equals("YES",painted.attrs.ACTIVE)
        assert.equals("Search / Browse",painted.attrs.TITLE)
        api.capture("disconnected")
        assert.equals("NO",painted.attrs.ACTIVE)
        assert.equals("Connect and choose a source first",painted.attrs.TIP)
    end)
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
    it("keeps discovery connection-first and invokes Connect", function()
        local connected=false;local requested=false
        local api,buttons=page({is_connected=function() return connected end,on_connect=function() requested=true end})
        buttons.Connect();assert.is_true(requested)
        assert.is_function(api.refreshConnection)
    end)

    it("publishes persisted download progress and cancellation to host activity", function()
        local recorded,cancelled,progress,finished
        local job={id=42,title='The General',state='running',bytes=25,total_bytes=100}
        local api=page({on_downloads=function(done) done({job}) end,
            on_cancel_download=function(id,done) cancelled=id;done({}) end},
            {activity=function(_,spec)
                recorded=spec
                return {progress=function(_,done,total) progress={done,total} end,
                    finish=function(_,ok) finished=ok end}
            end})
        api.tick();assert.same({25,100},progress)
        recorded.cancel();assert.equals(42,cancelled)
        job.state='complete'
        for _=1,100 do api.tick() end
        assert.is_true(finished)
    end)

end)

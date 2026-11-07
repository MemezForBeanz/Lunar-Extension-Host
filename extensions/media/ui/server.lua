--- The repair workbench. Problem copy and actions come from the catalog, including in samples.
local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")
local RowList = require("core.ui.RowList")
local ThemeReactor = require("core.ui.ThemeReactor")
local M = {}
local function grouped(value)
	local text = tostring(value or 0)
	while true do
		local next_text, changed = text:gsub("^(%d+)(%d%d%d)", "%1,%2")
		text = next_text
		if changed == 0 then return text end
	end
end
function M.new(ctx, opts)
	local iup, model = ctx.iup, opts.model
	local api, targets = {}, {}
	local feedback = Kit.statusLine(iup, "info", "")
	Kit.show(iup, feedback, false)
	local attention = iup.vbox({ GAP = L.gap(2), EXPAND = "HORIZONTAL", MARGIN = "0x0" })
	local function act(action, button)
		iup.SetAttribute(button, "ACTIVE", "NO")
		opts.on_repair(action, function(answer, why)
			iup.SetAttribute(button, "ACTIVE", "YES")
			Kit.show(iup, feedback, true)
			Kit.setStatus(iup, feedback, answer and "ok" or "warning", answer and "Queued. The server will update after the work finishes." or why)
		end)
	end
	local metrics = iup.hbox({ HOMOGENEOUS = "YES", GAP = L.gap(3), EXPAND = "HORIZONTAL", MARGIN = "0x0" })
	local setters, semantic_numbers = {}, {}
	for _, entry in ipairs({ { "failed", "Failed", "analysis" }, { "missing", "Offline", "offline" },
		{ "playing", "Now playing" }, { "analysing", "Being analysed" }, { "files", "Files" } }) do
		local key, caption, kind = entry[1], entry[2], entry[3]
		local number = iup.flatlabel({ TITLE = "0", THEMEROLE = kind and "sectiontitle" or "reading", EXPAND = "HORIZONTAL" })
		if kind then semantic_numbers[key] = number end
		local label = kind and Kit.statusLine(iup, key == "failed" and "error" or "warning", caption)
			or iup.flatlabel({ TITLE = caption, THEMEROLE = "reading_muted", EXPAND = "HORIZONTAL" })
		local jump = Kit.button(iup, { title = "View", role = "link_btn", action = function()
			if targets[kind] then iup.SetFocus(targets[kind]) end
		end })
		Kit.show(iup, jump, kind ~= nil)
		setters[key] = function(value) iup.SetAttribute(number, "TITLE", grouped(value)) end
		iup.Append(metrics, iup.vbox({ number, iup.hbox({ label, jump, ALIGNMENT = "ACENTER" }),
			GAP = L.gap(1), MARGIN = "12x8", EXPAND = "HORIZONTAL" }))
	end
	local function rows_for(libraries)
		local rows = {}
		for _, library in ipairs(libraries or {}) do
			rows[#rows + 1] = { title = library.name, secondary = library.root,
				column1 = tostring(#(library.items or {})), column2 = library.scanned_at and os.date("%b %d %H:%M", library.scanned_at) or "Not scanned" }
		end
		return rows
	end
	local libraries = RowList.new(iup, { rows = {}, row_height = 44, role = "flatrows_plain",
		column_widths = { 55, 125 }, header = { title = "Library", columns = { "Items", "Last scan" } },
		empty_title = "No libraries yet", empty_hint = "Add a folder through the server API." })
	local sessions = RowList.new(iup, { rows = {}, row_height = 44, role = "flatrows_plain",
		column_widths = { 85, 130 }, header = { title = "Now playing", columns = { "Delivery", "Position" } },
		empty_title = "Nothing is playing", empty_hint = "Sessions appear when reported by the server." })
	local status = Kit.statusLine(iup, "ok", "")
	local metadata_status = Kit.statusLine(iup, "info", "")
	local runtime_status = Kit.statusLine(iup, "info", "")
	local service_line = iup.flatlabel({ TITLE = "", THEMEROLE = "reading_muted" })
	local service_button
	local function service_refresh()
		local state = ctx.controlLocalService and ctx:controlLocalService(opts.owner)
		if state then
			iup.SetAttribute(service_line, "TITLE", "This computer's service: " .. (state.running and "running" or "stopped"))
			iup.SetAttribute(service_button, "TITLE", state.running and "Stop" or "Start")
		end
		return state
	end
	service_button = Kit.button(iup, { title = "Start", role = "actionbutton", action = function()
		local state = service_refresh()
		if not state then return end
		local ok, why = ctx:controlLocalService(opts.owner, state.running and "stop" or "start")
		Kit.show(iup, feedback, true)
		Kit.setStatus(iup, feedback, ok and "info" or "error", ok and "Service request sent. Status will refresh shortly." or tostring(why))
		service_refresh()
	end })
	local service_box = iup.hbox({ service_line, service_button, GAP = L.gap(2), ALIGNMENT = "ACENTER" })
	Kit.show(iup, service_box, service_refresh() ~= nil)
	local function section(title, children)
		local box = iup.vbox({ L.sectionTitle(iup, title), children, MARGIN = "12x8", GAP = L.gap(2), EXPAND = "HORIZONTAL" })
		return iup.flatframe({ box, TITLE = "", MARGIN = "0x0", THEMEROLE = "settingspanel", EXPAND = "HORIZONTAL" })
	end
	local health = section("Health", iup.vbox({ metrics, L.sectionTitle(iup, "Attention"), attention, feedback,
		GAP = L.gap(2), EXPAND = "HORIZONTAL" }))
	api.widget = iup.vbox({
		iup.hbox({ iup.vbox({ iup.flatlabel({ TITLE = "Media server", THEMEROLE = "pagetitle" }), status, metadata_status, runtime_status,
			GAP = L.gap(1) }), iup.fill({}), service_box, ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL", MARGIN = "15x0" }),   -- 15: the sections' margin and their frame's inset
		Kit.button(iup, { title = 'Refresh all metadata', role = 'actionbutton', action = function()
			if opts.on_refresh_metadata then opts.on_refresh_metadata() end
		end }),
		require('ui.credits').new(iup),
		health,
		iup.hbox({ section("Activity", sessions.widget), section("Libraries", libraries.widget),
			HOMOGENEOUS = "YES", GAP = L.gap(4), EXPAND = "HORIZONTAL" }),
		iup.fill({}), GAP = L.gap(3), MARGIN = L.margin(4), EXPAND = "YES",
	})
	-- Flat labels need an explicit background on Windows in light themes. Keep it
	-- local to this page, and reapply after each host theme pass.
	function api:_afterThemePass()
		local palette = ThemeReactor.palette()
		local function paint(widget, background)
			if iup.GetAttribute(widget, "THEMEROLE") == "settingspanel" then background = palette.layer01 or palette.surface end
			local class = iup.GetClassName(widget)
			if background and (class == "flatlabel" or class == "flatframe" or class == "scrollbox" or class == "vbox" or class == "hbox") then
				iup.SetAttribute(widget, "BGCOLOR", background)
			end
			local index, child = 0, iup.GetChild(widget, 0)
			while child do paint(child, background); index = index + 1; child = iup.GetChild(widget, index) end
		end
		paint(self.widget, palette.layer01 or palette.surface or palette.bg)
		for key, number in pairs(semantic_numbers) do
			local color = key == "failed" and palette.error or palette.warning
			if color then iup.SetAttribute(number, "FGCOLOR", color) end
		end
	end
	ThemeReactor.register(api)
	function api.setModel(next_model)
		model = next_model
		local server = model.server
		for key, setter in pairs(setters) do setter(key == "playing" and #(server.sessions or {}) or server[key]) end
		Kit.setStatus(iup, status, model.sample and "info" or "ok", server.name .. " · analysis " .. server.analysis ..
			(model.sample and " · all examples below are made up" or ""))
		local meta = server.metadata
		Kit.show(iup, metadata_status, meta ~= nil)
		if meta then Kit.setStatus(iup, metadata_status, meta.configured and "info" or "warning", meta.configured and
			("Metadata: " .. tostring(meta.matched or 0) .. " matched · " .. tostring(meta.queued or 0) .. " queued · " .. tostring(meta.unmatched or 0) .. " need a match")
			or "Keyless metadata providers supply posters and descriptions.") end
		local runtime = server.runtime
		Kit.show(iup, runtime_status, runtime ~= nil and runtime.state ~= "ready")
		if runtime then Kit.setStatus(iup, runtime_status, runtime.state == "failed" and "error" or "info", runtime.message or "Media tools ready") end
		while iup.GetChild(attention, 0) do iup.Destroy(iup.GetChild(attention, 0)) end
		targets = {}
		local problems = {}
		for _, problem in ipairs(model.attention or {}) do problems[#problems + 1] = problem end
		table.sort(problems, function(a, b) return a.severity < b.severity end)
		for _, problem in ipairs(problems) do
			local line = Kit.statusLine(iup, problem.severity <= 2 and "error" or "warning", problem.title .. " — " .. problem.wrong)
			local next_step = iup.flatlabel({ TITLE = "Next: " .. problem.next_step, THEMEROLE = "reading_muted", EXPAND = "HORIZONTAL" })
			local button = Kit.button(iup, { title = problem.action and problem.action.label or "", role = "actionbutton" })
			function button:flat_action() act(problem.action, button) end
			Kit.show(iup, button, problem.action ~= nil)
			if problem.action and not targets[problem.kind] then targets[problem.kind] = button end
			iup.Append(attention, iup.hbox({ iup.vbox({ line, next_step, GAP = L.gap(1), EXPAND = "HORIZONTAL" }), button,
				GAP = L.gap(3), ALIGNMENT = "ACENTER", MARGIN = "0x5", EXPAND = "HORIZONTAL" }))
		end
		if #problems == 0 then iup.Append(attention, Kit.statusLine(iup, model.attention_error and "warning" or "ok",
			model.attention_error and ("Could not load attention: " .. model.attention_error) or "Everything looks healthy.")) end
		libraries:setRows(rows_for(model.libraries))
		iup.SetAttribute(libraries.widget, "RASTERSIZE", "x" .. (40 + 44 * math.max(1, #(model.libraries or {}))))
		local rows = {}
		for _, session in ipairs(server.sessions or {}) do rows[#rows + 1] = { title = session.title,
			secondary = session.user .. " on " .. session.device, column1 = session.mode, column2 = session.position .. " / " .. session.duration } end
		sessions:setRows(rows)
		iup.SetAttribute(sessions.widget, "RASTERSIZE", "x" .. (40 + 44 * math.max(1, #rows)))
		api:_afterThemePass()
		iup.Refresh(api.widget)
	end
	api.setModel(model)
	api.widget = iup.scrollbox({ api.widget, EXPAND = "YES", SCROLLBAR = "VERTICAL" })
	if ctx.addTimer then ctx:addTimer({ time = 2000, run = true, action = function() service_refresh(); api:_afterThemePass() end }, opts.owner) end
	return api
end
return M

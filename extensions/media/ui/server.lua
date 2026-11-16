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
	local problems, repairing = {}, {}
	local feedback = Kit.statusLine(iup, "info", "")
	Kit.show(iup, feedback, false)
    local attention

	local function act(action, button)
		if repairing[action] then return end
		repairing[action] = true
		if button then iup.SetAttribute(button, "ACTIVE", "NO") end
		opts.on_repair(action, function(answer, why)
			repairing[action] = nil
			if button then iup.SetAttribute(button, "ACTIVE", "YES") end
			Kit.show(iup, feedback, true)
			Kit.setStatus(iup, feedback, answer and "ok" or "warning", answer and "Queued. The server will update after the work finishes." or why)
		end)
	end
    -- Real ghost buttons keep repairs discoverable and keyboard accessible.
    local attention_rows = iup.vbox({GAP = L.gap(1), EXPAND = "HORIZONTAL"})
    local repair_header = iup.flatlabel({TITLE = "Repair", THEMEROLE = "hint", RASTERSIZE = L.size(L.PAGE.config_min)})
    attention = {widget = iup.vbox({
        iup.hbox({L.hint(iup, "Issue / next step"), iup.fill({}), repair_header, EXPAND = "HORIZONTAL"}),
        attention_rows, GAP = L.gap(2), EXPAND = "HORIZONTAL"})}
    function attention:setRows(rows)
        while iup.GetChildCount(attention_rows) > 0 do
            iup.Destroy(iup.GetChild(attention_rows, 0))
        end
        for i, row in ipairs(rows) do
            local problem = problems[i]
            local label = iup.flatlabel({TITLE = row.title, IMAGE = row.image, THEMEROLE = "reading", EXPAND = "HORIZONTAL", TEXTELLIPSIS = "YES"})
            local copy = iup.vbox({label, L.hint(iup, row.secondary), EXPAND = "HORIZONTAL", GAP = L.gap(1)})
            local action = Kit.button(iup, {title = row.action or "", role = "ghost_btn", active = row.action and "YES" or "NO",
                action = function() act(problem.action) end})
            iup.SetAttribute(action, "RASTERSIZE", L.size(L.PAGE.config_min, L.PAGE.control))
            iup.Append(attention_rows, iup.hbox({copy, action, GAP = L.gap(3), ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL"}))
        end
    end
    function attention:setEmpty(title, hint)
        if #problems == 0 then
            iup.Append(attention_rows, L.stack(iup, {L.hint(iup, title), L.hint(iup, hint)}, 2))
        end
    end

	local metrics = iup.hbox({ HOMOGENEOUS = "YES", GAP = L.gap(3), EXPAND = "HORIZONTAL", MARGIN = "0x0" })
	local setters, semantic_numbers = {}, {}
	for _, entry in ipairs({ { "failed", "Failed", "analysis" }, { "missing", "Offline", "offline" },
		{ "playing", "Now playing" }, { "analysing", "Being analysed" }, { "files", "Files" } }) do
		local key, caption, kind = entry[1], entry[2], entry[3]
		local number = iup.flatlabel({ TITLE = "0", THEMEROLE = "pagetitle", EXPAND = "HORIZONTAL" })
		if kind then semantic_numbers[key] = number end
		local label = kind and Kit.statusLine(iup, "error", caption)
			or iup.flatlabel({ TITLE = caption, THEMEROLE = "reading_muted", EXPAND = "HORIZONTAL" })
		iup.SetAttribute(label, "RASTERSIZE", L.size(nil, L.PAGE.control))
		iup.SetAttribute(label, "ALIGNMENT", "ALEFT:ACENTER")
		local jump = Kit.button(iup, { title = "View", role = "link_btn", action = function()
			if targets[kind] then iup.SetFocus(targets[kind]) end
		end })
		Kit.show(iup, jump, kind ~= nil)
		setters[key] = function(value) iup.SetAttribute(number, "TITLE", grouped(value)) end
		iup.Append(metrics, iup.vbox({ number, iup.hbox({ label, jump, ALIGNMENT = "ACENTER", RASTERSIZE = L.size(nil, L.PAGE.control) }),
			GAP = L.gap(1), MARGIN = "12x8", EXPAND = "HORIZONTAL" }))
	end
	local function rows_for(libraries)
		local rows = {}
		for _, library in ipairs(libraries or {}) do
			rows[#rows + 1] = { title = library.name, secondary = library.root,
				column1 = tostring(#(library.items or {})), column2 = library.scanned_at and os.date("%b %d %H:%M", library.scanned_at) or (#(library.items or {}) > 0 and "Time unknown" or "Not scanned") }
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
			if model.sample then state = { running = true } end
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
        return iup.vbox({ L.sectionTitle(iup, title), children, GAP = L.gap(3), EXPAND = "HORIZONTAL" })
    end
    local content = iup.vbox({ service_box, metadata_status, runtime_status, metrics,
        section("Attention", attention.widget), feedback,
        iup.hbox({ section("Sessions", sessions.widget), section("Libraries", libraries.widget),
            HOMOGENEOUS = "YES", GAP = L.gap(5), EXPAND = "HORIZONTAL" }),
        iup.fill({}), require('ui.credits').new(iup), GAP = L.gap(5), EXPAND = "YES" })
    local page = Kit.page(iup, { id = "media-server", title = "Media server", icon = "data--base",
        main = iup.scrollbox({content, EXPAND = "YES", SCROLLBAR = "VERTICAL"}),
        secondary = { { title = "Refresh metadata", action = opts.on_refresh_metadata } } })
    api.widget = page:widget()

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
			local color = palette.error
			if color then iup.SetAttribute(number, "FGCOLOR", color) end
		end
	end
	ThemeReactor.register(api)
	function api.setModel(next_model)
		model = next_model
		local server = model.server
		for key, setter in pairs(setters) do setter(key == "playing" and #(server.sessions or {}) or server[key]) end
        page:setState("ok", server.name .. " · analysis " .. server.analysis)

		local meta = server.metadata
		Kit.show(iup, metadata_status, meta ~= nil)
		if meta then Kit.setStatus(iup, metadata_status, meta.configured and "info" or "warning", meta.configured and
			("Metadata: " .. tostring(meta.matched or 0) .. " matched · " .. tostring(meta.queued or 0) .. " queued · " .. tostring(meta.unmatched or 0) .. " need a match")
			or "Keyless metadata providers supply posters and descriptions.") end
		local runtime = server.runtime
		Kit.show(iup, runtime_status, runtime ~= nil and runtime.state ~= "ready")
		if runtime then Kit.setStatus(iup, runtime_status, runtime.state == "failed" and "error" or "info", runtime.message or "Media tools ready") end
        targets = {}
        problems = {}
        for _, problem in ipairs(model.attention or {}) do problems[#problems + 1] = problem end
        table.sort(problems, function(a,b) return a.severity < b.severity end)
        local repair_rows = {}
        for i,problem in ipairs(problems) do
            repair_rows[i] = { title = problem.title .. " — " .. problem.wrong, secondary = "Next: " .. problem.next_step,
                image = Kit.icon(iup, problem.kind ~= "frame" and "error--filled" or "warning--alt--filled", Kit.ICON_STATUS, problem.kind ~= "frame" and "error" or "warning"),
                column1 = problem.action and problem.action.label or "",
                action = problem.action and problem.action.label or nil }
            if problem.action then targets[problem.kind] = attention.widget end
        end
        local failed = false
        for _, problem in ipairs(problems) do if problem.kind ~= "frame" then failed = true end end
        page:setState(failed and "error" or (#problems > 0 and "warning" or "ok"), server.name .. " · " .. (#problems > 0 and (#problems .. " items need attention") or "Healthy") .. " · analysis " .. server.analysis)
        attention:setRows(repair_rows)
        iup.SetAttribute(attention.widget, "EXPAND", "HORIZONTAL")
        attention:setEmpty(model.attention_error and "Could not load attention" or "Everything looks healthy", model.attention_error or "No repairs needed.")


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
	if ctx.fitPage then ctx:fitPage(api.widget, function(w) page:fit(w) end) end
	if ctx.addTimer then ctx:addTimer({ time = 2000, run = true, action = function() service_refresh(); api:_afterThemePass() end }, opts.owner) end
	return api
end
return M

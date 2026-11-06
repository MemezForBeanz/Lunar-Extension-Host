--- The Media Server tab: what the server is doing and why. A session states how each stream
-- reaches its client, because "why is this converting" is the question an owner opens this
-- page to answer. Anything wrong is coloured; everything else stays quiet.
-- @module ui.server

local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")
local RowList = require("core.ui.RowList")

local M = {}

local ROW = 52
local HEADER = 32
local ROW_INSET = 12       -- where rows start their text; everything on the page shares that edge

local function grouped(value)
	local text = tostring(value)
	while true do
		local next_text, changed = text:gsub("^(%d+)(%d%d%d)", "%1,%2")
		text = next_text
		if changed == 0 then return text end
	end
end

local function metric(iup, label)
	local number = iup.flatlabel({ TITLE = "0", THEMEROLE = "pagetitle" })
	local caption = iup.flatlabel({ TITLE = label, THEMEROLE = "reading_muted" })
	local box = iup.vbox({ number, caption, GAP = L.gap(1), MARGIN = "0x0", EXPAND = "HORIZONTAL" })
	return box, function(value) iup.SetAttribute(number, "TITLE", grouped(value)) end
end

local function sized(widget, rows, iup)
	iup.SetAttribute(widget, "RASTERSIZE", "x" .. (HEADER + ROW * rows + 8))
	iup.SetAttribute(widget, "EXPAND", "HORIZONTAL")
end

--- Build the tab.
-- @tparam table ctx host context
-- @tparam table opts `model`
function M.new(ctx, opts)
	local iup = ctx.iup
	local server = opts.model.server
	local api = {}

	local playing_box, set_playing = metric(iup, "Now playing")
	local files_box, set_files = metric(iup, "Files")
	local analysing_box, set_analysing = metric(iup, "Being analysed")
	local missing_box, set_missing = metric(iup, "Offline")
	local failed_box, set_failed = metric(iup, "Failed")
	local metrics = iup.hbox({ failed_box, missing_box, playing_box, analysing_box, files_box,
		GAP = L.gap(7), MARGIN = ROW_INSET .. "x0", HOMOGENEOUS = "YES", EXPAND = "HORIZONTAL" })
	iup.SetAttribute(metrics, "NORMALIZESIZE", "NONE")
	local function show_counts(data)
		set_playing(#data.sessions)
		set_files(data.files)
		set_analysing(data.analysing)
		set_missing(data.missing)
		set_failed(data.failed)
	end
	show_counts(server)

	local session_rows = {}
	for i, session in ipairs(server.sessions) do
		session_rows[i] = {
			title = session.title, secondary = session.user .. " on " .. session.device,
			column1 = session.mode, column2 = session.position .. " / " .. session.duration, column3 = session.bitrate,
		}
	end
	local reach_title = L.sectionTitle(iup, "")
	local reach = {}
	local REACH_LABELS = { "Delivery", "Video", "Audio", "Subtitles" }
	local reach_rows = iup.vbox({ GAP = L.gap(2), MARGIN = ROW_INSET .. "x0", EXPAND = "HORIZONTAL" })
	for _, label in ipairs(REACH_LABELS) do
		local name = iup.flatlabel({ TITLE = label, THEMEROLE = "reading_muted", RASTERSIZE = "96x" })
		reach[label] = iup.flatlabel({ TITLE = "", THEMEROLE = "reading", EXPAND = "HORIZONTAL" })
		iup.Append(reach_rows, iup.hbox({ name, reach[label], GAP = L.gap(3), ALIGNMENT = "ACENTER" }))
	end
	local function explain(pos)
		local session = server.sessions[pos]
		if not session then return end
		iup.SetAttribute(reach_title, "TITLE", "How " .. session.title .. " reaches " .. session.user)
		iup.SetAttribute(reach.Delivery, "TITLE", session.mode)
		iup.SetAttribute(reach.Video, "TITLE", session.video)
		iup.SetAttribute(reach.Audio, "TITLE", session.audio)
		iup.SetAttribute(reach.Subtitles, "TITLE", session.subtitles)
	end
	local sessions = RowList.new(iup, { rows = session_rows, row_height = ROW, column_widths = { 88, 168, 96 },
		role = "flatrows_plain",
		header = { title = "Title", columns = { "Delivery", "Position", "Bitrate" } },
		empty_title = "Nothing is playing", empty_hint = "Sessions appear here while someone is watching.",
		on_select = explain })
	sized(sessions.widget, #session_rows, iup)

	local libraries = RowList.new(iup, {
		rows = {
			{ title = "Films", secondary = "D:/Media/Films", column1 = tostring(#opts.model.films), column2 = "12 min ago" },
			{ title = "Shows", secondary = "D:/Media/Shows", column1 = tostring(#opts.model.shows), column2 = "Now" },
		},
		row_height = ROW, column_widths = { 72, 120 }, role = "flatrows_plain",
		header = { title = "Library", columns = { "Items", "Last scan" } },
		empty_title = "No libraries yet", empty_hint = "Add a folder to start your library.",
	})
	sized(libraries.widget, 2, iup)

	local scan = Kit.button(iup, { title = "Scan all", icon = "renew", role = "actionbutton" })
	iup.SetAttribute(scan, "RASTERSIZE", "x36")
	local add = Kit.button(iup, { title = "Add library", icon = "add", role = "primary_btn" })
	iup.SetAttribute(add, "RASTERSIZE", "x36")

	local status = Kit.statusLine(iup, "ok", server.name .. " · version " .. server.version .. " · analysis " .. server.analysis)

	local header = iup.hbox({
		iup.vbox({ iup.flatlabel({ TITLE = "Media server", THEMEROLE = "pagetitle" }), status, GAP = L.gap(2), MARGIN = "0x0" }),
		iup.fill({}), scan, add, GAP = L.gap(3), ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL",
		MARGIN = ROW_INSET .. "x0",
	})

	local function heading(text)
		return iup.hbox({ L.sectionTitle(iup, text), MARGIN = ROW_INSET .. "x0" })
	end

	local attention = iup.vbox({
		Kit.statusLine(iup, "error", "Marrow (2020).mkv could not be read, so it cannot play"),
		Kit.statusLine(iup, "warning", "3 files are offline in Shows"),
		Kit.statusLine(iup, "info", "Analysing Harbour Lights: 18 files left"),
		GAP = L.gap(3), MARGIN = ROW_INSET .. "x0", EXPAND = "HORIZONTAL",
	})
	local left = L.stack(iup, {
		L.stack(iup, { heading("Now playing"), sessions.widget }, 3),
		L.stack(iup, { iup.hbox({ reach_title, MARGIN = ROW_INSET .. "x0" }), reach_rows }, 3),
	}, 6)
	local right = L.stack(iup, {
		L.stack(iup, { heading("Libraries"), libraries.widget }, 3),
	}, 6)
	iup.SetAttribute(left, "EXPAND", "HORIZONTAL")
	iup.SetAttribute(right, "EXPAND", "HORIZONTAL")

	api.widget = iup.vbox({
		header, metrics,
		L.stack(iup, { heading("Attention"), attention }, 3),
		iup.hbox({ left, right, GAP = L.gap(8), MARGIN = "0x0", EXPAND = "HORIZONTAL", HOMOGENEOUS = "YES" }),
		iup.fill({}),
		GAP = L.gap(7), MARGIN = L.margin(5), EXPAND = "YES",
	})
	sessions:select(1)
	explain(1)

	--- Show a connected server's counts.
	function api.setModel(model)
		server = model.server
		show_counts(server)
		Kit.setStatus(iup, status, "ok", server.name .. " · analysis " .. server.analysis)
		sessions:setRows({})
		iup.SetAttribute(reach_title, "TITLE", "")
		for _, label in pairs(reach) do iup.SetAttribute(label, "TITLE", "") end
	end
	return api
end

return M

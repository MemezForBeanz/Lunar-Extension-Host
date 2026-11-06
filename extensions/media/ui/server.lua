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

-- A count that means trouble wears its colour only while it is above zero.
local function metric(iup, label, kind)
	local number = iup.flatlabel({ TITLE = "0", THEMEROLE = "pagetitle" })
	local quiet = L.hint(iup, label)
	local caption = kind and Kit.statusLine(iup, kind, label) or nil
	local box = iup.vbox({ number, quiet, caption, GAP = L.gap(1), MARGIN = "0x0" })
	if caption then iup.SetAttribute(caption, "EXPAND", "NO") end
	return box, function(value)
		iup.SetAttribute(number, "TITLE", tostring(value))
		if caption then
			Kit.show(iup, caption, value > 0, number)
			Kit.show(iup, quiet, value == 0, number)
		end
	end
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

	local playing_box, set_playing = metric(iup, "Playing now")
	local files_box, set_files = metric(iup, "Files")
	local analysing_box, set_analysing = metric(iup, "Being analysed")
	local missing_box, set_missing = metric(iup, "Offline", "warning")
	local failed_box, set_failed = metric(iup, "Failed", "error")
	local metrics = iup.hbox({ playing_box, files_box, analysing_box, missing_box, failed_box, GAP = L.gap(9), MARGIN = "0x0" })
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
	local reach_rows = iup.vbox({ GAP = L.gap(2), MARGIN = "0x0", EXPAND = "HORIZONTAL" })
	for _, label in ipairs(REACH_LABELS) do
		local name = L.hint(iup, label)
		iup.SetAttribute(name, "RASTERSIZE", "96x")
		reach[label] = iup.flatlabel({ TITLE = "", EXPAND = "HORIZONTAL" })
		iup.Append(reach_rows, iup.hbox({ name, reach[label], GAP = L.gap(3), ALIGNMENT = "ACENTER" }))
	end
	local function explain(pos)
		local session = server.sessions[pos]
		if not session then return end
		iup.SetAttribute(reach_title, "TITLE", "How it reaches " .. session.user)
		iup.SetAttribute(reach.Delivery, "TITLE", session.mode)
		iup.SetAttribute(reach.Video, "TITLE", session.video)
		iup.SetAttribute(reach.Audio, "TITLE", session.audio)
		iup.SetAttribute(reach.Subtitles, "TITLE", session.subtitles)
	end
	local sessions = RowList.new(iup, { rows = session_rows, row_height = ROW, column_widths = { 72, 136, 72 },
		header = { title = "Title", columns = { "Delivery", "Position", "Bitrate" } },
		empty_title = "Nothing is playing", empty_hint = "Sessions appear here while someone is watching.",
		on_select = explain })
	sized(sessions.widget, #session_rows, iup)

	local libraries = RowList.new(iup, {
		rows = {
			{ title = "Films", secondary = "D:/Media/Films", column1 = "24 items", column2 = "Scanned 12 min ago" },
			{ title = "Shows", secondary = "D:/Media/Shows", column1 = "8 items", column2 = "Scanning now" },
		},
		row_height = ROW, column_widths = { 88, 160 },
		header = { title = "Library", columns = { "Items", "Last scan" } },
		empty_title = "No libraries yet", empty_hint = "Add a folder to start your library.",
	})
	sized(libraries.widget, 2, iup)

	local scan = Kit.button(iup, { title = "Scan All", icon = "renew", role = "actionbutton" })
	local add = Kit.button(iup, { title = "Add Library", icon = "add", role = "primary_btn" })

	local status = Kit.statusLine(iup, "ok", server.name .. " · version " .. server.version .. " · analysis " .. server.analysis)

	local header = iup.hbox({
		iup.vbox({ iup.flatlabel({ TITLE = "Media Server", THEMEROLE = "pagetitle" }), status, GAP = L.gap(2), MARGIN = "0x0" }),
		iup.fill({}), scan, add, GAP = L.gap(3), ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL",
	})

	local left = L.stack(iup, {
		L.stack(iup, { L.sectionTitle(iup, "Playing now"), sessions.widget }, 3),
		L.stack(iup, { reach_title, reach_rows }, 3),
	}, 6)
	local right = L.stack(iup, {
		L.stack(iup, { L.sectionTitle(iup, "Libraries"), libraries.widget }, 3),
		L.stack(iup, {
			L.sectionTitle(iup, "Attention"),
			Kit.statusLine(iup, "error", "Could not read Marrow (2020).mkv: ffprobe could not open the file"),
			Kit.statusLine(iup, "warning", "3 files are offline in Shows"),
			Kit.statusLine(iup, "info", "Analysing Harbour Lights: 18 files left"),
		}, 3),
	}, 6)
	iup.SetAttribute(left, "EXPAND", "HORIZONTAL")
	iup.SetAttribute(right, "EXPAND", "HORIZONTAL")

	api.widget = iup.vbox({
		header, metrics,
		iup.hbox({ left, right, GAP = L.gap(7), MARGIN = "0x0", EXPAND = "HORIZONTAL", HOMOGENEOUS = "YES" }),
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

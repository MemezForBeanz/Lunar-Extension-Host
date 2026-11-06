--- The Media Server tab: what the server is doing and why. A session states how each stream
-- reaches its client, because "why is this converting" is the question an owner opens this
-- page to answer.
-- @module ui.server

local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")
local RowList = require("core.ui.RowList")

local M = {}

local function metric(iup, value, label)
	local number = iup.flatlabel({ TITLE = tostring(value), THEMEROLE = "pagetitle" })
	return iup.vbox({ number, L.hint(iup, label), GAP = L.gap(1), MARGIN = "0x0" })
end

--- Build the tab.
-- @tparam table ctx host context
-- @tparam table opts `model`
function M.new(ctx, opts)
	local iup = ctx.iup
	local server = opts.model.server
	local api = {}

	local metrics = iup.hbox({
		metric(iup, #server.sessions, "Playing now"), metric(iup, server.files, "Files"),
		metric(iup, server.analysing, "Being analysed"), metric(iup, server.missing, "Offline"),
		metric(iup, server.failed, "Failed"),
		GAP = L.gap(9), MARGIN = "0x0",
	})

	local session_rows = {}
	for i, session in ipairs(server.sessions) do
		session_rows[i] = {
			title = session.title, secondary = session.user .. " on " .. session.device,
			column1 = session.mode, column2 = session.position .. " / " .. session.duration, column3 = session.bitrate,
		}
	end
	local reach_title = L.sectionTitle(iup, "")
	local reach = {}
	local reach_rows = iup.vbox({ GAP = L.gap(2), MARGIN = "0x0", EXPAND = "HORIZONTAL" })
	for _, label in ipairs({ "Video", "Audio", "Subtitles" }) do
		local name = L.hint(iup, label)
		iup.SetAttribute(name, "RASTERSIZE", "96x")
		reach[label] = iup.flatlabel({ TITLE = "", EXPAND = "HORIZONTAL" })
		iup.Append(reach_rows, iup.hbox({ name, reach[label], GAP = L.gap(3), ALIGNMENT = "ACENTER" }))
	end
	local function explain(pos)
		local session = server.sessions[pos]
		if not session then return end
		iup.SetAttribute(reach_title, "TITLE", "How it reaches " .. session.user .. ": " .. session.mode)
		iup.SetAttribute(reach.Video, "TITLE", session.video)
		iup.SetAttribute(reach.Audio, "TITLE", session.audio)
		iup.SetAttribute(reach.Subtitles, "TITLE", session.subtitles)
	end
	local sessions = RowList.new(iup, { rows = session_rows, row_height = 44, column_widths = { 72, 136, 72 },
		empty_title = "Nothing is playing", empty_hint = "Sessions appear here while someone is watching.",
		on_select = explain })
	iup.SetAttribute(sessions.widget, "RASTERSIZE", "x" .. (44 * 2 + 8))
	iup.SetAttribute(sessions.widget, "EXPAND", "HORIZONTAL")

	local libraries = RowList.new(iup, {
		rows = {
			{ title = "Films", secondary = "D:/Media/Films", column1 = "24 items", column2 = "Scanned 12 min ago" },
			{ title = "Shows", secondary = "D:/Media/Shows", column1 = "8 items", column2 = "Scanning now" },
		},
		row_height = 44, column_widths = { 88, 160 },
		empty_title = "No libraries yet", empty_hint = "Add a folder to start your library.",
	})
	iup.SetAttribute(libraries.widget, "EXPAND", "YES")

	local jobs = RowList.new(iup, {
		rows = {
			{ title = "Analysing Harbour Lights", secondary = "18 files left", column1 = "Running" },
			{ title = "Could not read Marrow (2020).mkv", secondary = "ffprobe could not open the file", column1 = "Failed" },
		},
		row_height = 44, column_widths = { 72 },
	})
	iup.SetAttribute(jobs.widget, "EXPAND", "YES")

	local scan = Kit.button(iup, { title = "Scan All", icon = "renew", role = "actionbutton" })
	local add = Kit.button(iup, { title = "Add Library", icon = "add", role = "primary_btn" })

	local status = Kit.statusLine(iup, "ok", server.name .. " · version " .. server.version .. " · analysis " .. server.analysis)

	local header = iup.hbox({
		iup.vbox({ iup.flatlabel({ TITLE = "Media Server", THEMEROLE = "pagetitle" }), status, GAP = L.gap(2), MARGIN = "0x0" }),
		iup.fill({}), scan, add, GAP = L.gap(3), ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL",
	})

	local left = L.stack(iup, {
		L.sectionTitle(iup, "Playing now"), sessions.widget, reach_title, reach_rows,
		L.sectionTitle(iup, "Work"), jobs.widget,
	}, 3)
	iup.SetAttribute(left, "EXPAND", "YES")
	local right = L.stack(iup, { L.sectionTitle(iup, "Libraries"), libraries.widget }, 3)
	iup.SetAttribute(right, "EXPAND", "YES")

	api.widget = iup.vbox({
		header, metrics,
		iup.hbox({ left, right, GAP = L.gap(7), MARGIN = "0x0", EXPAND = "YES", HOMOGENEOUS = "YES" }),
		GAP = L.gap(6), MARGIN = L.margin(5), EXPAND = "YES",
	})
	sessions:select(1)
	explain(1)
	return api
end

return M

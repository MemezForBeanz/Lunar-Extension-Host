--- All workbench states are invented examples; buttons never claim real work ran.
local M = {}
function M.apply(model)
	model.libraries = {
		{ id = 1, name = "Films", root = "D:/Media/Films (sample)", items = model.films },
		{ id = 2, name = "Shows", root = "D:/Media/Shows (sample)", items = model.shows },
	}
	model.attention = {
		{ kind = "offline", severity = 1, title = "Shows: 3 files are offline", wrong = "The sample drive is disconnected.",
			next_step = "Reconnect the drive, then rescan.", action = { label = "Rescan library", path = "/v1/libraries/2/scan" } },
		{ kind = "analysis", severity = 2, title = "Marrow: analysis failed", wrong = "ffprobe could not read the sample file.",
			next_step = "Check the file, then retry.", action = { label = "Retry analysis", path = "/v1/files/1/analyse" } },
		{ kind = "source", severity = 3, title = "Film club feed: source failed", wrong = "It answered 503 (sample).",
			next_step = "Check the feed, then sync again.", action = { label = "Sync source", path = "/v1/sources/1/sync" } },
		{ kind = "frame", severity = 4, title = "The Salt Line: frame failed", wrong = "ffmpeg could not make a sample frame.",
			next_step = "Check ffmpeg, then retry.", action = { label = "Retry frame", path = "/v1/items/1/frame" } },
		{ kind = "analysis_off", severity = 5, title = "Analysis setup example", wrong = "When LUNAR_FFPROBE is unset, analysis is off.",
			next_step = "Set LUNAR_FFPROBE on the server and restart it." },
	}
	return model
end
return M

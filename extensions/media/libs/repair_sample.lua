--- All workbench states are invented examples; buttons never claim real work ran.
local M = {}
function M.apply(model)
	model.libraries = {
		{ id = 1, name = "Films", root = "D:/Media/Films", items = model.films },
		{ id = 2, name = "Shows", root = "D:/Media/Shows", items = model.shows },
	}
	model.attention = {
		{ kind = "offline", severity = 1, title = "Shows: 3 files are offline", wrong = "The media drive is disconnected.",
			next_step = "Reconnect the drive, then rescan.", action = { label = "Rescan library", path = "/v1/libraries/2/scan" } },
		{ kind = "analysis", severity = 2, title = "Marrow: analysis failed", wrong = "ffprobe could not read the media file.",
			next_step = "Check the file, then retry.", action = { label = "Retry analysis", path = "/v1/files/1/analyse" } },
		{ kind = "source", severity = 3, title = "Film club feed: source failed", wrong = "It answered 503.",
			next_step = "Check the feed, then sync again.", action = { label = "Sync source", path = "/v1/sources/1/sync" } },
		{ kind = "frame", severity = 4, title = "The Salt Line: frame failed", wrong = "ffmpeg could not make a preview frame.",
			next_step = "Check ffmpeg, then retry.", action = { label = "Retry frame", path = "/v1/items/1/frame" } },

	}
	return model
end
return M

--- Artwork for a work, with no outside service: pictures people keep beside their files, and
-- for anything without one, a frame from the file itself.
-- @module libs.art

local M = {}

M.TIMEOUT_S = 60
M.WIDTH = 1280

local EXTENSIONS = { "jpg", "jpeg", "png" }
local BASE_NAMES = {
	poster = { "poster", "folder", "cover" },
	backdrop = { "fanart", "backdrop", "background" },
}
local SUFFIXES = { poster = { "poster" }, backdrop = { "fanart", "backdrop" } }

--- A picture's content type.
-- @tparam string path
-- @treturn string
function M.mime(path)
	return (path:match("%.(%w+)$") or ""):lower() == "png" and "image/png" or "image/jpeg"
end

--- Is this file a picture the scanner should remember?
-- @tparam string name
-- @treturn boolean
function M.isImage(name)
	local extension = (name:match("%.(%w+)$") or ""):lower()
	for _, known in ipairs(EXTENSIONS) do
		if known == extension then return true end
	end
	return false
end

local function find(files, stem)
	for _, extension in ipairs(EXTENSIONS) do
		local hit = files[stem .. "." .. extension]
		if hit then return hit end
	end
end

local function folder_of(relative)
	return relative:match("^(.*)/[^/]+$") or ""
end

local function join(folder, name)
	if folder == "" then return name end
	return folder .. "/" .. name
end

--- Find the pictures for a video in the folders the scanner has seen.
-- `Film-poster.jpg` beside the video wins, then `poster.jpg`. For a show, the show's own folder
-- comes first, so every episode shares one picture.
-- @tparam string relative the video's path inside the library
-- @tparam table folders `folders[folder][lowercase name] = name`
-- @tparam string kind `movie` or `show`
-- @treturn table `{ poster = path, backdrop = path }`, either or both missing
function M.find(relative, folders, kind)
	local found = {}
	local folder = folder_of(relative)
	local stem = (relative:match("([^/]+)%.[^.]*$") or ""):lower()
	local places = { folder }
	if kind == "show" and folder ~= "" then
		table.insert(places, 1, folder_of(folder) ~= "" and folder_of(folder) or folder)
	end
	for art_kind, names in pairs(BASE_NAMES) do
		for _, place in ipairs(places) do
			local files = folders[place]
			if files and not found[art_kind] then
				for _, suffix in ipairs(SUFFIXES[art_kind]) do
					if kind ~= "show" and not found[art_kind] then
						local hit = find(files, stem .. "-" .. suffix)
						if hit then found[art_kind] = join(place, hit) end
					end
				end
				for _, name in ipairs(names) do
					if not found[art_kind] then
						local hit = find(files, name)
						if hit then found[art_kind] = join(place, hit) end
					end
				end
			end
		end
	end
	return found
end

--- Where in a film to take a frame: past titles and logos, well before the end.
-- @tparam number duration_ms
-- @treturn number seconds
function M.frameAt(duration_ms)
	local seconds = (duration_ms or 0) / 1000
	if seconds <= 0 then return 0 end
	return math.floor(seconds * 0.2)
end

--- The command line for one frame. Paths are single arguments, never a shell string.
function M.frameArgv(ffmpeg, input, output, at)
	return { ffmpeg, "-hide_banner", "-loglevel", "error", "-ss", tostring(at), "-i", input,
		"-frames:v", "1", "-vf", "scale=" .. M.WIDTH .. ":-2", "-q:v", "3", "-y", output }
end

return M

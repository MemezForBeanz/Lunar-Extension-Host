--- A native window for video, and a libmpv player that draws into it.
--
-- libmpv is optional and supplied by the user. Nothing here ships it, and a missing library
-- is a normal state: `M.requirement()` gives the item for `Kit.requirements`.
--
-- ```lua
-- local VideoHost = require("core.ui.VideoHost")
-- local host = VideoHost.new(iup, { bgcolor = "0 0 0" })   -- host.widget goes in the layout
-- -- once the widget is mapped:
-- local player, err = VideoHost.player(host, {
--     library = settings.libmpv_path,                      -- optional, see M.candidates
--     on_event = function(name, info) end,
-- })
-- player:observe("time-pos", "double")
-- player:load("D:/films/clip.mkv")
-- local timer = ctx:addTimer({ time = 15, run = true, action = function() player:poll() end }, M)
-- -- when done, before the widget goes away:
-- player:destroy()
-- ```
--
-- Events reach Lua only through `poll`, on the thread that calls it. mpv's wakeup callback is
-- never used, because it would enter LuaJIT from mpv's own thread.
--
-- `on_event(name, info)`: `name` is mpv's own event name. `info` is
-- `{ name, value }` for "property-change", `{ reason, error }` for "end-file", else nil.
--
-- Behaviour measured on Windows with a D3D11 flip-model output: mpv's child window follows
-- this host through tab changes, split moves, resizes and dialog fullscreen on its own, so
-- no resize call exists here. A size change made while a tab is hidden lands when it returns.
-- The child is disabled, so mouse input goes to the host's own callbacks.
--
-- `destroy` blocks until mpv has stopped. Call it before the widget is unmapped: the native
-- window is what mpv draws into, and `IupReparent` keeps it only when the move can be done
-- without an unmap.
--
-- @module core.ui.VideoHost
local M = {}

M.LIBRARY_ENV = "LUNAR_LIBMPV"

-- A player must never pick up its code or behaviour from the user's mpv setup.
M.DEFAULT_OPTIONS = {
	{ "config", "no" },
	{ "load-scripts", "no" },
	{ "ytdl", "no" },
	{ "terminal", "no" },
	{ "osc", "no" },
	{ "input-default-bindings", "no" },
	{ "input-vo-keyboard", "no" },
	{ "input-cursor", "no" },
	{ "cursor-autohide", "no" },
	{ "force-window", "yes" },
	{ "keep-open", "yes" },
	{ "idle", "yes" },
	{ "vo", "gpu" },
	{ "hwdec", "auto-safe" },
	-- Bound compressed read-ahead without changing decoding or video quality.
	{ "demuxer-max-bytes", "64MiB" },
	{ "demuxer-max-back-bytes", "8MiB" },
}

local FORMATS = { string = 1, flag = 3, int64 = 4, double = 5 }
local EVENT_END_FILE, EVENT_PROPERTY_CHANGE = 7, 22

--- True for a path this module will not load. Another product's private copy of libmpv is
-- not a user-supplied library.
-- @tparam string path
-- @treturn boolean
function M.refused(path)
	return tostring(path):lower():gsub("\\", "/"):find("/plex/", 1, true) ~= nil
end

--- Library names to try, first match wins: `opts.library`, then `LUNAR_LIBMPV`, then the
-- platform's usual names through the normal library search.
-- @tparam[opt] table opts `library`, `getenv`, `windows`
-- @treturn table
function M.candidates(opts)
	opts = opts or {}
	local list = {}
	local env = (opts.getenv or os.getenv)(M.LIBRARY_ENV)
	if opts.library and opts.library ~= "" then list[#list + 1] = opts.library end
	if env and env ~= "" then list[#list + 1] = env end
	local windows = opts.windows
	if windows == nil then windows = package.config:sub(1, 1) == "\\" end
	if windows then
		list[#list + 1] = "libmpv-2"
		list[#list + 1] = "mpv-2"
	else
		list[#list + 1] = "mpv"
		list[#list + 1] = "libmpv.so.2"
	end
	return list
end

local loaded = {}

local function define(ffi)
	if pcall(ffi.typeof, "struct lunar_mpv_event") then return end
	ffi.cdef[[
	typedef struct lunar_mpv_handle lunar_mpv_handle;
	struct lunar_mpv_event { int event_id; int error; uint64_t reply_userdata; void* data; };
	struct lunar_mpv_property { const char* name; int format; void* data; };
	struct lunar_mpv_end_file { int reason; int error; };
	unsigned long mpv_client_api_version(void);
	lunar_mpv_handle* mpv_create(void);
	int mpv_initialize(lunar_mpv_handle*);
	void mpv_terminate_destroy(lunar_mpv_handle*);
	int mpv_set_option_string(lunar_mpv_handle*, const char*, const char*);
	int mpv_set_property_string(lunar_mpv_handle*, const char*, const char*);
	char* mpv_get_property_string(lunar_mpv_handle*, const char*);
	int mpv_observe_property(lunar_mpv_handle*, uint64_t, const char*, int);
	int mpv_command(lunar_mpv_handle*, const char**);
	struct lunar_mpv_event* mpv_wait_event(lunar_mpv_handle*, double);
	const char* mpv_event_name(int);
	const char* mpv_error_string(int);
	void mpv_free(void*);
	]]
end

--- Load libmpv.
-- @tparam[opt] table opts see `M.candidates`
-- @return the library namespace, or nil
-- @treturn[opt] string why not
function M.library(opts)
	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi then return nil, "this Lua has no FFI" end
	define(ffi)
	local last
	for _, name in ipairs(M.candidates(opts)) do
		if M.refused(name) then
			last = "that copy of libmpv belongs to another product"
		elseif loaded[name] then
			return loaded[name]
		else
			local ok, lib = pcall(ffi.load, name)
			if ok then
				local usable = pcall(function() return lib.mpv_client_api_version end)
				if usable then
					loaded[name] = lib
					return lib
				end
				last = name .. " is not libmpv"
			else
				last = tostring(lib)
			end
		end
	end
	return nil, last or "libmpv not found"
end

--- An item for `Kit.requirements`.
-- @tparam[opt] table opts see `M.candidates`, plus `action_title` and `action`
-- @treturn table
function M.requirement(opts)
	opts = opts or {}
	local lib = M.library(opts)
	return {
		label = "libmpv",
		ok = lib ~= nil,
		optional = true,
		problem = "playback needs libmpv. Point Lunar at your copy of libmpv-2.dll or libmpv.so",
		action_title = opts.action_title,
		action = opts.action,
	}
end

--- Create the native surface.
-- @tparam userdata iup
-- @tparam[opt] table opts `bgcolor`, shown until the first frame; `raw`, for tests
-- @treturn table `{ widget, windowId = function() }`, or nil when the fork has no video host
function M.new(iup, opts)
	opts = opts or {}
	local raw = opts.raw or require("iupraw")
	local widget = raw.videohost and raw.videohost() or nil
	if not widget then return nil, "this build has no video host" end
	iup.SetAttribute(widget, "BGCOLOR", opts.bgcolor or "0 0 0")
	local host = { widget = widget }
	--- The native window id as a decimal string, nil until the widget is mapped.
	function host.windowId() return iup.GetAttribute(widget, "WINDOWID") end
	return host
end

local Player = {}
Player.__index = Player

local function failure(self, code)
	return code < 0 and self.ffi.string(self.lib.mpv_error_string(code)) or nil
end

--- Run an mpv command.
-- @param ... strings, as mpv's input commands take them
-- @treturn[opt] string the error, nil on success
function Player:command(...)
	if not self.ctx then return "player is destroyed" end
	local n = select("#", ...)
	local args = self.ffi.new("const char*[?]", n + 1)
	local keep = { ... }
	for i = 1, n do
		keep[i] = tostring(keep[i])
		args[i - 1] = keep[i]
	end
	return failure(self, self.lib.mpv_command(self.ctx, args))
end

--- Play a file or URL.
function Player:load(path) return self:command("loadfile", path) end

--- Stop playback and keep the player.
function Player:stop() return self:command("stop") end

--- Seek to a position in seconds.
function Player:seek(seconds) return self:command("seek", seconds, "absolute") end

--- Set a property. @treturn[opt] string the error, nil on success
function Player:set(name, value)
	if not self.ctx then return "player is destroyed" end
	return failure(self, self.lib.mpv_set_property_string(self.ctx, name, tostring(value)))
end

--- Read a property as a string, nil when it has no value.
function Player:get(name)
	if not self.ctx then return nil end
	local value = self.lib.mpv_get_property_string(self.ctx, name)
	if value == nil then return nil end
	local text = self.ffi.string(value)
	self.lib.mpv_free(value)
	return text
end

--- Ask for "property-change" events.
-- @tparam string name
-- @tparam[opt] string format `string` (default), `double`, `flag` or `int64`
function Player:observe(name, format)
	if not self.ctx then return "player is destroyed" end
	return failure(self, self.lib.mpv_observe_property(self.ctx, 0, name, FORMATS[format or "string"] or 1))
end

local function property_value(ffi, property)
	if property.data == nil then return nil end
	if property.format == FORMATS.double then return ffi.cast("double*", property.data)[0] end
	if property.format == FORMATS.flag then return ffi.cast("int*", property.data)[0] ~= 0 end
	if property.format == FORMATS.int64 then return tonumber(ffi.cast("int64_t*", property.data)[0]) end
	if property.format == FORMATS.string then
		local text = ffi.cast("char**", property.data)[0]
		return text ~= nil and ffi.string(text) or nil
	end
end

--- Deliver waiting events. Call it from a host timer; it never blocks.
-- @treturn number how many events were delivered
function Player:poll()
	local ffi, count = self.ffi, 0
	while self.ctx do
		local event = self.lib.mpv_wait_event(self.ctx, 0)
		local id = event.event_id
		if id == 0 then break end
		count = count + 1
		if self.on_event then
			local info
			if id == EVENT_PROPERTY_CHANGE then
				local property = ffi.cast("struct lunar_mpv_property*", event.data)
				info = { name = ffi.string(property.name), value = property_value(ffi, property) }
			elseif id == EVENT_END_FILE then
				local ended = ffi.cast("struct lunar_mpv_end_file*", event.data)
				info = { reason = ended.reason, error = ended.error }
			end
			self.on_event(ffi.string(self.lib.mpv_event_name(id)), info)
		end
	end
	return count
end

--- Stop mpv and release it. Blocks until mpv has stopped. Safe to call twice.
function Player:destroy()
	if self.ctx then
		local ctx = self.ctx
		self.ctx = nil
		self.lib.mpv_terminate_destroy(ctx)
	end
end

--- Create a player that draws into a mapped host.
-- @tparam table host from `M.new`
-- @tparam[opt] table opts `library`, `on_event`, and `options`, a list of `{ name, value }`
-- applied after the defaults
-- @return the player, or nil
-- @treturn[opt] string why not
function M.player(host, opts)
	opts = opts or {}
	local lib, why = M.library(opts)
	if not lib then return nil, why end
	local wid = host.windowId()
	if not wid then return nil, "the video host is not mapped yet" end
	local ctx = lib.mpv_create()
	if ctx == nil then return nil, "mpv_create failed" end
	local self = setmetatable({ ctx = ctx, lib = lib, ffi = require("ffi"), on_event = opts.on_event }, Player)
	lib.mpv_set_option_string(ctx, "wid", wid)
	for _, option in ipairs(M.DEFAULT_OPTIONS) do lib.mpv_set_option_string(ctx, option[1], option[2]) end
	for _, option in ipairs(opts.options or {}) do lib.mpv_set_option_string(ctx, option[1], tostring(option[2])) end
	local code = lib.mpv_initialize(ctx)
	if code < 0 then
		local err = failure(self, code)
		self:destroy()
		return nil, err
	end
	return self
end

return M

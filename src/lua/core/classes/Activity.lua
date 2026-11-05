--- Everything Lunar is doing in the background, for this session only.
--
-- Tools come and go from view as the user changes tab, and the work they started
-- carries on. This is the one record of that work. It holds the data and the wording;
-- `core.ui.StatusBar` and `core.ui.ActivityPanel` draw it, and it touches no widgets,
-- so all of it runs under the busted suite.
--
-- An entry starts with `Activity:start` (extensions use `HostAPI:activity`) and is
-- driven through the handle that returns:
--
--     local work = ctx:activity({ title = "Build Queue", cancel = stop }, M)
--     work:progress(3, 12, "Building RomBuilder")
--     work:finish(false, "2 of 12 failed")
--
-- `cancel` is what makes an entry cancellable. Leave it out for work that can't be
-- stopped safely part way, such as a firmware flash, and no Cancel is offered.
--
-- Nothing here is saved. History across restarts is deliberately out of scope.
--
-- @classmod core.classes.Activity

local class = require("middleclass")

local Activity = class("Activity")

--- How many entries a session keeps. Running entries are never dropped.
Activity.static.LIMIT = 50
--- How long a result stays in the status bar, in seconds.
Activity.static.RESULT_SECONDS = 8

local function default_now()
	local ok, socket = pcall(require, "socket")
	if ok and socket.gettime then return socket.gettime() end
	return os.time()
end

--- What an extension holds. Every method is safe to call after the work has ended.
local Handle = {}
Handle.__index = Handle

--- Report how far along the work is. Anything left out keeps its last value.
-- @tparam[opt] number done
-- @tparam[opt] number total a total of 100 reads as a percentage
-- @tparam[opt] string message
function Handle:progress(done, total, message)
	self._store:_progress(self._item, done, total, message)
	return self
end

--- End the work. Later calls do nothing.
-- @param ok `true`, `false`, or `"cancelled"` for work the user stopped
-- @tparam[opt] string summary one line on how it ended
function Handle:finish(ok, summary)
	self._store:_finish(self._item, ok, summary)
	return self
end

--- Ask for the work to stop, as the panel's Cancel does.
-- @treturn boolean asked
function Handle:cancel()
	return self._store:cancel(self._item.id)
end

--- The entry's id.
function Handle:id()
	return self._item.id
end

--- `true` while the work is running.
function Handle:isRunning()
	return self._item.state == "running"
end

--- @tparam[opt] table opts
-- @tparam[opt] function opts.now `fn() -> seconds`
-- @tparam[opt] number opts.limit
function Activity:initialize(opts)
	opts = opts or {}
	self._now = opts.now or default_now
	self._limit = opts.limit or Activity.LIMIT
	self._items = {}       -- oldest first
	self._listeners = {}
	self._seq = 0
end

--- Hear about changes.
-- @tparam function fn `fn(event, item)`, where `event` is `"ended"` just after work
--   ends and `"changed"` for anything that changes what is shown
function Activity:subscribe(fn)
	self._listeners[#self._listeners + 1] = fn
end

-- A listener that throws must never reach the tool reporting its progress.
function Activity:_emit(event, item)
	for _, fn in ipairs(self._listeners) do pcall(fn, event, item) end
end

-- Finished entries go first, oldest first. Work still running is never forgotten.
function Activity:_trim()
	local i = 1
	while #self._items > self._limit and i <= #self._items do
		if self._items[i].state == "running" then
			i = i + 1
		else
			table.remove(self._items, i)
		end
	end
end

--- Record new work.
-- @tparam table spec `title`; optional `tool` (the extension's name), `owner`, `tab`
--   (the id of the tab that shows it), `cancel` (`fn()`) and `manual`, which marks an
--   entry the caller opened itself, so a job it starts joins it (see `openManual`)
-- @treturn table a handle
function Activity:start(spec)
	spec = spec or {}
	self._seq = self._seq + 1
	local title = spec.title
	if type(title) ~= "string" or title == "" then title = spec.tool or "Background work" end
	local item = {
		id = self._seq,
		title = title,
		tool = spec.tool,
		owner = spec.owner,
		tab = spec.tab,
		cancel = type(spec.cancel) == "function" and spec.cancel or nil,
		manual = spec.manual and true or false,
		state = "running",
		started = self._now(),
	}
	self._items[#self._items + 1] = item
	self:_trim()
	self:_emit("changed", item)
	return setmetatable({ _store = self, _item = item }, Handle)
end

function Activity:_progress(item, done, total, message)
	if item.state ~= "running" then return end
	done, total = tonumber(done), tonumber(total)
	-- Tools report far more often than the numbers change, and a scan's tick runs
	-- every 15ms. Only a real change is worth a repaint.
	local changed = false
	if done and done ~= item.done then item.done = done; changed = true end
	if total and total ~= item.total then item.total = total; changed = true end
	if message ~= nil and tostring(message) ~= item.message then
		item.message = tostring(message)
		changed = true
	end
	if changed then self:_emit("changed", item) end
end

function Activity:_finish(item, ok, summary, quiet)
	if item.state ~= "running" then return end
	local state = "failed"
	if ok == true then
		state = "ok"
	elseif ok == "cancelled" or item.cancelling then
		-- A tool that was told to stop usually just reports failing. That isn't one.
		state = "cancelled"
	end
	item.state = state
	item.ended = self._now()
	if summary ~= nil then item.summary = tostring(summary) end
	item.cancelling = nil
	item.cancel = nil      -- a closure over the tool, which may unload
	-- Failing in front of the user counts as seen: HostAPI clears this on "ended".
	item.viewed = state ~= "failed" or quiet == true
	item.quiet = quiet == true
	if not item.quiet then self._last_ended = item end
	self:_emit("ended", item)
	self:_emit("changed", item)
end

--- Ask an entry's work to stop.
--
-- The entry stays running until the tool reports that it has ended. If asking throws,
-- the entry goes back to being cancellable and says why.
-- @tparam number id
-- @treturn boolean asked
-- @treturn[opt] string why not
function Activity:cancel(id)
	local item = self:get(id)
	if not item or item.state ~= "running" or not item.cancel or item.cancelling then
		return false
	end
	item.cancelling = true
	self:_emit("changed", item)
	local ok, err = pcall(item.cancel)
	-- A cancel that stopped the work at once has already finished the entry.
	if not ok and item.state == "running" then
		item.cancelling = nil
		item.message = "Could not cancel: " .. tostring(err)
		self:_emit("changed", item)
		return false, tostring(err)
	end
	return ok
end

--- An entry by id.
function Activity:get(id)
	for _, item in ipairs(self._items) do
		if item.id == id then return item end
	end
	return nil
end

--- Every entry, newest first.
-- @treturn {table,...}
function Activity:list()
	local out = {}
	for i = #self._items, 1, -1 do out[#out + 1] = self._items[i] end
	return out
end

--- Running entries, oldest first, so the one in the status bar holds its place.
-- @treturn {table,...}
function Activity:running()
	local out = {}
	for _, item in ipairs(self._items) do
		if item.state == "running" then out[#out + 1] = item end
	end
	return out
end

--- The owner's running entry that it opened itself, if any. A job started during one
-- reports into it instead of adding a second entry for the same work.
-- @param owner
-- @treturn[opt] table the entry's handle
function Activity:openManual(owner)
	if owner == nil then return nil end
	for i = #self._items, 1, -1 do
		local item = self._items[i]
		if item.state == "running" and item.manual and item.owner == owner then
			return setmetatable({ _store = self, _item = item }, Handle)
		end
	end
	return nil
end

--- How many failures the user hasn't seen.
function Activity:unviewed()
	local count = 0
	for _, item in ipairs(self._items) do
		if not item.viewed and item.state == "failed" then count = count + 1 end
	end
	return count
end

--- Mark failures as seen.
-- @tparam[opt] number|function which an entry's id, or `fn(item) -> boolean`; all
--   of them when left out
function Activity:markViewed(which)
	local changed
	for _, item in ipairs(self._items) do
		local wanted = which == nil
			or (type(which) == "function" and which(item))
			or item.id == which
		if wanted and item.state ~= "running" and not item.viewed then
			item.viewed = true
			changed = item
		end
	end
	if changed then self:_emit("changed", changed) end
end

--- End and disown an unloading owner's entries. Nothing is toasted for these, and
-- their closures are dropped so a finished entry doesn't pin the extension.
-- @param owner
function Activity:removeOwned(owner)
	if owner == nil then return end
	for _, item in ipairs(self._items) do
		if item.owner == owner then
			self:_finish(item, "cancelled", "Stopped when the extension unloaded", true)
			item.owner = nil
		end
	end
end

--- The time since `seconds` ago, as a row shows it: `12s`, `3m 05s`, `1h 02m`.
-- @tparam number seconds
-- @treturn string
function Activity.static.elapsed(seconds)
	local s = math.max(0, math.floor(tonumber(seconds) or 0))
	if s < 60 then return s .. "s" end
	if s < 3600 then return string.format("%dm %02ds", math.floor(s / 60), s % 60) end
	return string.format("%dh %02dm", math.floor(s / 3600), math.floor(s % 3600 / 60))
end

--- An entry's title with its progress: `Build Queue 3 of 12`, `Flash 40%`.
-- @tparam table item
-- @treturn string
function Activity.static.label(item)
	local total, done = item.total, item.done
	if item.state ~= "running" or not (total and total > 0 and done) then return item.title end
	if total == 100 then return string.format("%s %d%%", item.title, math.floor(done)) end
	return string.format("%s %d of %d", item.title, done, total)
end

--- How far along an entry is, 0 to 1, or nil when it hasn't said.
-- @tparam table item
-- @treturn number|nil
function Activity.static.fraction(item)
	local total, done = item.total, item.done
	if not (total and total > 0 and done) then return nil end
	return math.max(0, math.min(1, done / total))
end

local RESULT_WORDS = { ok = "finished", failed = "failed", cancelled = "cancelled" }

--- What the status bar should show now.
-- @tparam[opt] number now
-- @treturn table|nil `{ state, text, tip }`, where `state` is `running`, `ok`, `failed`,
--   `cancelled` or `attention`; nil when there is nothing to say
function Activity:status(now)
	now = now or self._now()
	local failed = self:unviewed()
	local running = self:running()
	if running[1] then
		local text = Activity.label(running[1])
		if running[2] then text = text .. "  +" .. (#running - 1) end
		if failed > 0 then text = text .. "  " .. failed .. " failed" end
		return { state = "running", text = text, tip = running[1].message or running[1].title }
	end
	local last = self._last_ended
	if last and now - last.ended < Activity.RESULT_SECONDS then
		return {
			state = last.state,
			text = last.title .. " " .. RESULT_WORDS[last.state],
			tip = last.summary or last.title,
		}
	end
	if failed > 0 then
		return { state = "attention", text = failed .. " failed", tip = "Open Activity to see what failed" }
	end
	return nil
end

--- `true` while the status will change on its own, so something has to look again.
-- @tparam[opt] number now
-- @treturn boolean
function Activity:needsTick(now)
	now = now or self._now()
	local last = self._last_ended
	return last ~= nil and now - last.ended < Activity.RESULT_SECONDS
end

return Activity

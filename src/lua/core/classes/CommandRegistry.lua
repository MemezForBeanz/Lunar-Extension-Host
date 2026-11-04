--- What the command bar can do: every command, from the host and from extensions.
--
-- This class holds the data and the matching; `core.ui.CommandPalette` draws it.
-- It touches no widgets, so all of it runs under the busted suite.
--
-- ### Three ways to fill the list
--
--   * **Commands** (`register`): a title and a function. `HostAPI:addCommand` is the
--     extension route, and everything an extension adds is removed with it.
--   * **Menu items**: `HostAPI:addMenuItem` registers each one here too, so an
--     extension that has never heard of the command bar is already in it.
--   * **Providers** (`addProvider`): a function that answers a query with items, for
--     lists that change (open tabs, themes) or that are too long to register one by
--     one. A provider with a `prefix` owns that prefix: `task build` goes only to the
--     tasks provider, which is how Tasks plugs in.
--
-- ### What an item is
--
--     { id = "host.settings", title = "Open Settings", category = "Host",
--       keywords = "preferences options", detail = "Ctrl+,",
--       when = function() return true end, run = function() ... end }
--
-- `title` and `run` are required. `category` shows in front of the title, `keywords`
-- are searched but not shown, and `when` hides the item while it returns false.
--
-- @classmod core.classes.CommandRegistry

local class = require("middleclass")

local CommandRegistry = class("CommandRegistry")

-- Everything the bar treats as a lunar address rather than as a search.
local ADDRESS_PATTERN = "^%s*lunar:"

-- How many recently run commands stay at the top of the empty list.
local RECENT_LIMIT = 5

--- Score `query` against `text`: nil when it does not match, higher when it is better.
--
-- A match is the query's characters appearing in order, ignoring case. Runs of
-- consecutive characters and matches at the start of a word score more, so "cfu"
-- finds "Check for Updates" and an exact prefix beats a scattered hit.
--
-- @tparam string query
-- @tparam string text
-- @treturn number|nil
function CommandRegistry.score(query, text)
	query, text = query:lower(), text:lower()
	if query == "" then return 0 end

	local score, from, previous = 0, 1, nil
	for i = 1, #query do
		local c = query:sub(i, i)
		local at = text:find(c, from, true)
		if not at then return nil end
		local at_word = at == 1 or text:sub(at - 1, at - 1):match("[%s%p]") ~= nil
		score = score + 1
		if previous and at == previous + 1 then score = score + 4 end
		if at_word then score = score + 6 end
		previous, from = at, at + 1
	end
	-- A shorter text with the same hits is the closer match.
	return score - (#text / 1000)
end

--- Is `text` a lunar address rather than a search?
-- @tparam string text
-- @treturn boolean
function CommandRegistry.isAddress(text)
	return tostring(text or ""):match(ADDRESS_PATTERN) ~= nil
end

--- Create an empty registry.
-- @tparam[opt] table opts
-- @tparam[opt] function opts.open_address `fn(uri)`: opens a lunar address; returns
--   `true`, or `nil, message`
-- @tparam[opt] function opts.settings `core.classes.SettingsManager`, for the recent list
function CommandRegistry:initialize(opts)
	opts = opts or {}
	self._open_address = opts.open_address
	self._settings = opts.settings
	self._commands = {}    -- in registration order
	self._providers = {}   -- in registration order
end

--- Add a command, replacing any with the same `id`.
-- @tparam table spec see the class description; `id` defaults to `category.title`
-- @param[opt] owner who to remove it with (see `removeOwned`)
-- @treturn table|nil the stored item, or nil when `title` or `run` is missing
function CommandRegistry:register(spec, owner)
	if type(spec) ~= "table" or type(spec.title) ~= "string" or spec.title == ""
		or type(spec.run) ~= "function" then
		return nil
	end
	local item = {}
	for k, v in pairs(spec) do item[k] = v end
	item.id = item.id or ((item.category or "Command") .. "." .. item.title)
	item.owner = owner
	for i, existing in ipairs(self._commands) do
		if existing.id == item.id then
			self._commands[i] = item
			return item
		end
	end
	self._commands[#self._commands + 1] = item
	return item
end

--- Add a provider.
-- @tparam table spec
-- @tparam string spec.id
-- @tparam function spec.items `fn(query) -> { item, ... }`
-- @tparam[opt] string spec.prefix when set, typing this prefix sends the rest of the
--   text to this provider alone (`"task "`), and nothing else answers
-- @tparam[opt] string spec.title what the bar shows while the prefix is active
-- @param[opt] owner who to remove it with
-- @treturn table|nil the stored provider
function CommandRegistry:addProvider(spec, owner)
	if type(spec) ~= "table" or type(spec.id) ~= "string" or type(spec.items) ~= "function" then
		return nil
	end
	local provider = {}
	for k, v in pairs(spec) do provider[k] = v end
	provider.owner = owner
	for i, existing in ipairs(self._providers) do
		if existing.id == provider.id then
			self._providers[i] = provider
			return provider
		end
	end
	self._providers[#self._providers + 1] = provider
	return provider
end

--- Remove everything `owner` added (an extension unloading).
function CommandRegistry:removeOwned(owner)
	if owner == nil then return end
	for _, list in ipairs({ self._commands, self._providers }) do
		for i = #list, 1, -1 do
			if list[i].owner == owner then table.remove(list, i) end
		end
	end
end

--- The registered commands, in order.
function CommandRegistry:commands()
	return self._commands
end

local function visible(item)
	if type(item.when) ~= "function" then return true end
	local ok, shown = pcall(item.when)
	return ok and shown ~= false and shown ~= nil
end

local function label(item)
	if item.category and item.category ~= "" then
		return item.category .. ": " .. item.title
	end
	return item.title
end
CommandRegistry.label = label

local function provider_items(provider, query)
	local ok, items = pcall(provider.items, query)
	if not ok or type(items) ~= "table" then return {} end
	return items
end

function CommandRegistry:_recentIds()
	local recent = self._settings and self._settings:get("command_recent")
	return type(recent) == "table" and recent or {}
end

-- The provider that owns this text's prefix, and the rest of the text.
function CommandRegistry:_prefixed(text)
	for _, provider in ipairs(self._providers) do
		local prefix = provider.prefix
		if prefix and text:sub(1, #prefix):lower() == prefix:lower() then
			return provider, text:sub(#prefix + 1)
		end
	end
end

--- Answer what is in the bar.
--
-- Empty text lists the recent commands, then everything else in registration order.
-- A lunar address offers to open that address. A provider's prefix hands the rest of
-- the text to that provider. Anything else is a fuzzy search of every command and
-- every provider without a prefix.
--
-- @tparam string text
-- @treturn {table,...} items, best first
-- @treturn[opt] table the prefix provider answering, when there is one
function CommandRegistry:query(text)
	text = tostring(text or "")
	local trimmed = text:match("^%s*(.-)%s*$")

	if CommandRegistry.isAddress(trimmed) then
		local open = self._open_address
		return { {
			id = "address:" .. trimmed, title = trimmed, category = "Open Address",
			run = function()
				if open then return open(trimmed) end
				return nil, "Addresses are not available"
			end,
		} }
	end

	local prefixed, rest = self:_prefixed(text)
	if prefixed then
		local out = {}
		for _, item in ipairs(provider_items(prefixed, rest)) do
			if visible(item) then out[#out + 1] = item end
		end
		return out, prefixed
	end

	local pool = {}
	for _, item in ipairs(self._commands) do
		if visible(item) then pool[#pool + 1] = item end
	end
	for _, provider in ipairs(self._providers) do
		if not provider.prefix then
			for _, item in ipairs(provider_items(provider, trimmed)) do
				if type(item.title) == "string" and type(item.run) == "function" and visible(item) then
					pool[#pool + 1] = item
				end
			end
		end
	end

	if trimmed == "" then
		local by_id, out, used = {}, {}, {}
		for _, item in ipairs(pool) do
			if item.id then by_id[item.id] = item end
		end
		for _, id in ipairs(self:_recentIds()) do
			if by_id[id] and not used[id] then
				out[#out + 1] = by_id[id]
				used[id] = true
			end
		end
		for _, item in ipairs(pool) do
			if not (item.id and used[item.id]) then out[#out + 1] = item end
		end
		return out
	end

	local scored = {}
	for order, item in ipairs(pool) do
		local best = CommandRegistry.score(trimmed, label(item))
		if item.keywords then
			local by_keyword = CommandRegistry.score(trimmed, item.keywords)
			if by_keyword and (not best or by_keyword > best) then best = by_keyword end
		end
		if best then scored[#scored + 1] = { item = item, score = best, order = order } end
	end
	table.sort(scored, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		return a.order < b.order
	end)
	local out = {}
	for i, entry in ipairs(scored) do out[i] = entry.item end
	return out
end

--- Run an item and remember it for the top of the empty list.
-- @tparam table item
-- @treturn boolean ok
-- @treturn[opt] string message from a failing command
function CommandRegistry:run(item)
	if self._settings and item.id and not tostring(item.id):match("^address:") then
		local recent = { item.id }
		for _, id in ipairs(self:_recentIds()) do
			if id ~= item.id and #recent < RECENT_LIMIT then recent[#recent + 1] = id end
		end
		pcall(function()
			self._settings:set("command_recent", recent)
			self._settings:save()
		end)
	end
	local ok, result, message = pcall(item.run)
	if not ok then return false, tostring(result) end
	if result == nil and message ~= nil then return false, tostring(message) end
	return true
end

return CommandRegistry

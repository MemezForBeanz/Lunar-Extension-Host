--- Lunar's prompt commands. No widgets, shell expansion, or process creation here.
local Shell = {}
Shell.__index = Shell

--- Quotes group arguments; backslashes in Windows paths stay literal.
function Shell.parse(text, partial)
	local argv, tokens, word, quote, start = {}, {}, {}, nil, nil
	local i = 1
	local function finish(last)
		if not start then return end
		local value = table.concat(word)
		argv[#argv + 1] = value
		tokens[#tokens + 1] = { value = value, start = start - 1, length = last - start + 1,
			quoted = text:sub(start, start):match("[\"']") ~= nil }
		word, start = {}, nil
	end
	while i <= #text do
		local ch = text:sub(i, i)
		if not quote and ch:match("%s") then
			finish(i - 1)
		else
			start = start or i
			if ch == quote then quote = nil
			elseif not quote and (ch == '"' or ch == "'") then quote = ch
			elseif ch == "\\" and quote and text:sub(i + 1, i + 1) == quote
				and i + 1 < #text and not text:sub(i + 2, i + 2):match("%s") then
				i = i + 1; word[#word + 1] = quote
			else word[#word + 1] = ch end
		end
		i = i + 1
	end
	if quote and not partial then return nil, "Unclosed " .. quote .. " quote" end
	finish(#text)
	return argv, tokens
end

Shell.COMMANDS = {
	help = { usage = "help [command]", description = "List commands or explain one.", run = function(s, a)
		if a[2] then
			local c = s.commands[a[2]]
			return c and (c.usage .. "\n" .. c.description) or ("Unknown command: " .. a[2])
		end
		local out = { "Lunar terminal - runs Lunar CLI scripts, with no system shell.", "" }
		for _, name in ipairs(s:names()) do out[#out + 1] = string.format("%-22s %s", s.commands[name].usage, s.commands[name].description) end
		out[#out + 1] = "\nscript.lua [args]       Run a script with the bundled Lunar CLI."
		out[#out + 1] = "Up/Down history; Tab complete; Ctrl+L clear; Ctrl+C cancel (copy with a selection)."
		return table.concat(out, "\n")
	end },
	clear = { usage = "clear", description = "Clear scrollback.", action = "clear" },
	version = { usage = "version", description = "Show the Lunar version.", action = "version" },
	extensions = { usage = "extensions", description = "List extensions and their loaded state.", action = "extensions" },
	themes = { usage = "themes", description = "List installed themes.", action = "themes" },
	problems = { usage = "problems", description = "List language server diagnostics.", action = "problems" },
	lsp = { usage = "lsp", description = "List language server status.", action = "lsp" },
	show = { usage = "show <file>", description = "Print a file with language colours.", action = "show", argument = true },
	open = { usage = "open <file[:line]>", description = "Open a file in the code workspace.", action = "open", argument = true },
	settings = { usage = "settings", description = "Open Lunar settings.", action = "settings" },
	about = { usage = "about", description = "About Lunar.", action = "about" },
	exit = { usage = "exit", description = "Close the terminal panel.", action = "exit" },
	pwd = { usage = "pwd", description = "Print the script working directory.", action = "pwd" },
	headless = { usage = "headless [options]", description = "Run the headless extension host; --help lists options.", cli = "--headless" },
}

function Shell.new(opts)
	opts = opts or {}
	local self = setmetatable({ commands = {}, history = {}, limit = opts.history_limit or 200 }, Shell)
	for name, command in pairs(Shell.COMMANDS) do self:register(name, command) end
	return self
end

function Shell:register(name, command)
	assert(type(name) == "string" and name:match("^[%w_.-]+$"), "Invalid command name")
	assert(type(command) == "table" and type(command.description) == "string", "Command needs a description")
	self.commands[name] = command
end

function Shell:names()
	local out = {}
	for name in pairs(self.commands) do out[#out + 1] = name end
	table.sort(out)
	return out
end

function Shell:remember(text)
	if not text:match("%S") then return end
	if self.history[#self.history] ~= text then self.history[#self.history + 1] = text end
	while #self.history > self.limit do table.remove(self.history, 1) end
	self.index, self.draft = #self.history + 1, ""
end

function Shell:previous(draft)
	self.index = self.index or (#self.history + 1)
	if self.index > #self.history then self.draft = draft or "" end
	self.index = math.max(1, self.index - 1)
	return self.history[self.index] or self.draft or ""
end

function Shell:next()
	self.index = math.min(#self.history + 1, (self.index or #self.history + 1) + 1)
	return self.history[self.index] or self.draft or ""
end

--- Return an action or an argv tail. The executable is never supplied by input.
function Shell:execute(text)
	local argv, err = Shell.parse(text)
	if not argv then return nil, err end
	if not argv[1] then return { action = "noop" } end
	self:remember(text)
	local command = self.commands[argv[1]]
	if command then
		if command.argument and not argv[2] then return nil, "Usage: " .. command.usage end
		if command.run then return { action = "print", text = command.run(self, argv) } end
		if command.action then return { action = command.action, args = argv } end
		if command.cli then argv[1] = command.cli end
	end
	if argv[1] == "lunar-cli" or argv[1] == "LunarCLI.exe" then table.remove(argv, 1) end
	return { action = "cli", argv = argv }
end

local FLAGS = { "--dev", "--extensions", "--for", "--help", "--log-level", "--pack", "--require", "--stop-grace", "--until-idle" }

--- Complete at the caret; `paths(prefix)` supplies file candidates without I/O here.
function Shell:complete(text, caret, paths)
	caret = caret or #text
	local before = text:sub(1, caret)
	local argv, tokens = Shell.parse(before, true)
	local last = tokens[#tokens]
	if last and last.start + last.length ~= caret then last = nil end
	local prefix = last and last.value or ""
	local start = last and last.start or caret
	local pool = {}
	if #argv == 0 or (#argv == 1 and last) then
		pool = self:names()
		pool[#pool + 1] = "lunar-cli"
		if paths then for _, path in ipairs(paths(prefix) or {}) do pool[#pool + 1] = path end end
	elseif prefix:sub(1, 1) == "-" then pool = FLAGS
	elseif argv[1] == "help" then pool = self:names()
	elseif paths then pool = paths(prefix) or {} end
	local matches = {}
	for _, name in ipairs(pool) do
		if name:sub(1, #prefix):lower() == prefix:lower() then matches[#matches + 1] = name end
	end
	table.sort(matches)
	if #matches == 0 then return text, matches, caret end
	local common = matches[1]
	for i = 2, #matches do
		while matches[i]:sub(1, #common):lower() ~= common:lower() do common = common:sub(1, -2) end
	end
	local replacement = common
	if replacement:find("%s") or (last and last.quoted) then replacement = '"' .. replacement .. '"' end
	if #matches == 1 then replacement = replacement .. " " end
	return text:sub(1, start) .. replacement .. text:sub(caret + 1), matches, start + #replacement
end

function Shell:styles(text)
	local _, tokens = Shell.parse(text, true)
	for i, token in ipairs(tokens) do
		local value = token.value
		token.role = i == 1 and ((self.commands[value] or value == "lunar-cli" or value == "LunarCLI.exe") and "keyword"
			or value:match("%.lua$") and "type" or "error")
			or token.quoted and "string" or value:sub(1, 1) == "-" and "preprocessor"
			or value:find("[/\\.]") and "type" or "text"
	end
	return tokens
end

--- File references use one-based display positions, including Windows drive paths.
function Shell.reference(text)
	local path, line, column = text:match("^%s*(.-):(%d+):(%d+)")
	if not path then path, line = text:match("^%s*(.-):(%d+)") end
	if not path or path == "" then return nil end
	return path:gsub('^"(.*)"$', "%1"), tonumber(line), tonumber(column) or 1
end

return Shell

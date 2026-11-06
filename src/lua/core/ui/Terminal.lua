--- A Lunar CLI prompt in the workspace. Never invokes a system shell.
local Shell = require("core.lib.LunarShell")
local Buffer = require("core.lib.TerminalBuffer")
local CodeView = require("core.ui.CodeView")
local CodeBinder = require("core.ui.CodeBinder")
local Kit = require("core.ui.Kit")
local Reactor = require("core.ui.ThemeReactor")
local platform = require("core.platform")
local Uri = require("core.lsp.Uri")
local lfs = require("lfs")
local Terminal = {}
Terminal.__index = Terminal

function Terminal.new(opts)
	local iup = opts.iup
	local self = setmetatable({ _iup = iup, _opts = opts, _shell = Shell.new(), _buffer = Buffer.new(),
		_cwd = lfs.currentdir(), _requests = {}, _generation = 0 }, Terminal)
	self._output = CodeView.new(iup, { line_numbers = false, framed = false, wrap = false })
	self._input = CodeView.new(iup, { line_numbers = false, framed = false, read_only = false, single_line = true })
	iup.SetAttribute(self._input:widget(), "EXPAND", "HORIZONTAL")
	iup.SetAttribute(self._input:widget(), "RASTERSIZE", "x28")
	iup.SetAttribute(self._input:widget(), "MAXSIZE", "65535x28")
	local function button(icon, tip, fn)
		local b = Kit.button(iup, { icon = icon, tip = tip, role = "icon_btn", action = fn })
		iup.SetAttribute(b, "RASTERSIZE", "28x28")
		iup.SetAttribute(b, "PADDING", "0x0")
		return b
	end
	self._maximize = button("chevron--up", "Maximize panel / restore height", function() self:maximize() end)
	local header = iup.hbox({ iup.flatlabel({ TITLE = "TERMINAL", THEMEROLE = "hint", PADDING = "12x0" }),
		iup.fill({}), button("add", "New Lunar session", function() self:reset() end),
		button("reset", "Clear (Ctrl+L)", function() self:clear() end),
		button("trash-can", "Cancel Lunar CLI (Ctrl+C)", function() self:cancel() end), self._maximize,
		button("close", "Close terminal (Ctrl+`)", function() self._layout:toggleTerminal() end),
		MARGIN = "0x0", GAP = "2", ALIGNMENT = "ACENTER", RASTERSIZE = "x32", THEMEROLE = "well" })
	local prompt = iup.flatlabel({ TITLE = "lunar >", PADDING = "12x0", THEMEROLE = "mono" })
	local drag = iup.canvas({ RASTERSIZE = "x5", EXPAND = "HORIZONTAL", CANFOCUS = "NO", BORDER = "NO", CURSOR = "RESIZE_NS" })
	self._drag = drag
	function drag:action()
		iup.DrawBegin(drag)
		local w, h = iup.DrawGetSize(drag)
		local p = Reactor.palette()
		iup.SetAttribute(drag, "DRAWSTYLE", "FILL")
		iup.SetAttribute(drag, "DRAWCOLOR", p.borderSubtle01 or p.border or p.textMuted)
		iup.DrawRectangle(drag, 0, 0, w - 1, h - 1)
		iup.DrawEnd(drag)
		return iup.DEFAULT
	end
	local function mouse_y()
		return tonumber(tostring(iup.GetGlobal("CURSORPOS") or ""):match("[ ,](-?%d+)$"))
	end
	local terminal = self
	function drag:button_cb(button_id, pressed)
		if button_id == iup.BUTTON1 and terminal._layout then
			if pressed == 1 then terminal:_beginDrag(mouse_y()) else terminal:_endDrag() end
		end
		return iup.DEFAULT
	end
	function drag:motion_cb()
		local y = mouse_y()
		if terminal._drag_y and y then
			terminal._layout:setTerminalHeight(terminal._drag_height + terminal._drag_y - y)
		end
		return iup.DEFAULT
	end
	self._body = iup.vbox({ drag, header, self._output:widget(),
		iup.hbox({ prompt, self._input:widget(), MARGIN = "0x0", GAP = "0", ALIGNMENT = "ACENTER" }),
		MARGIN = "0x0", GAP = "0", EXPAND = "YES", THEMEROLE = "well" })
	-- A native clipping parent lets the body fill its fixed height independently
	-- of how the workspace distributes spare height between expandable children.
	self._widget = iup.flatframe({ self._body, TITLE = "", MARGIN = "0x0", BORDERWIDTH = "0",
		EXPAND = "HORIZONTAL", THEMEROLE = "well" })
	self._input:onKey(function(key) return self:_key(key) end)
	self._input:onChange(function(text)
		if text:find("[\r\n]") then
			self:_inputText((text:gsub("[\r\n]+", " ")))
		else self._input:styleRanges(self._shell:styles(text)) end
	end)
	self._output:onKey(function(key)
		if key == iup.K_cC and self._output:hasSelection() then return false end
		if key == iup.K_cC then self:cancel(); return true end
		if key == iup.K_cL then self:clear(); return true end
		return false
	end)
	self._output:onClick(function(line)
		local path, row, column = Shell.reference(self._output:lineText(line))
		if path then self:_open(path, row, column) end
		return false -- retain native text selection and copy
	end)
	self._timer = iup.timer({ TIME = "40" })
	function self._timer:action_cb() terminal:_pump(); return iup.DEFAULT end
	function self._widget:destroy_cb() terminal:destroy() end
	Reactor.register(self)
	self:write("Lunar terminal\nType help for commands; script.lua [args] runs the bundled Lunar CLI.\n\n", "comment")
	return self
end

function Terminal:widget() return self._widget end
function Terminal:setLayout(layout) self._layout = layout end
function Terminal:focus() self._input:focus() end
function Terminal:setHeight(height)
	height = math.max(0, math.floor(height + 0.5))
	local iup, widget = self._iup, self._widget
	iup.SetAttribute(widget, "FLOATING", height == 0 and "YES" or "NO")
	iup.SetAttribute(widget, "VISIBLE", height == 0 and "NO" or "YES")
	iup.SetAttribute(widget, "RASTERSIZE", "x" .. height)
	iup.SetAttribute(widget, "MINSIZE", "1x" .. height)
	iup.SetAttribute(widget, "MAXSIZE", "65535x" .. height)
end
function Terminal:_beginDrag(y)
	self._drag_y, self._drag_height = y, self._layout:terminalHeight()
end
function Terminal:_endDrag()
	self._drag_y = nil
	self._layout:saveTerminalHeight()
end
function Terminal:maximize()
	if self._restore_height then
		self._layout:setTerminalHeight(self._restore_height); self._restore_height = nil
	else
		self._restore_height = self._layout:terminalHeight()
		local dialog = self._iup.GetDialog(self._widget)
		local height = tonumber(tostring(self._iup.GetAttribute(dialog, "CLIENTSIZE")):match("x(%d+)$")) or 700
		self._layout:setTerminalHeight(height - 140)
	end
	Kit.bindIcon(self._iup, self._maximize, self._restore_height and "chevron--down" or "chevron--up")
end
function Terminal:_onThemeApply() self._iup.Update(self._drag) end
function Terminal:_inputText(text, column)
	self._input:setText(text)
	self._input:styleRanges(self._shell:styles(text))
	self._input:goTo(0, column or #text)
end
function Terminal:_key(key)
	local iup = self._iup
	if key == iup.K_CR then self:execute(self._input:text()); return true end
	if key == iup.K_UP then self:_inputText(self._shell:previous(self._input:text())); return true end
	if key == iup.K_DOWN then self:_inputText(self._shell:next()); return true end
	if key == iup.K_cL then self:clear(); return true end
	if key == iup.K_cC then
		if self._input:hasSelection() then return false end
		self:cancel(); self:_inputText(""); return true
	end
	if key == iup.K_TAB then
		local _, column = self._input:caret()
		if not self._input.rich then column = #self._input:text() end
		local text, matches, caret = self._shell:complete(self._input:text(), column, function(prefix) return self:_paths(prefix) end)
		self:_inputText(text, caret)
		if #matches > 1 then self:write(table.concat(matches, "  ") .. "\n", "comment") end
		return true
	end
	return false
end
function Terminal:_path(path)
	if platform.path:is_absolute(path) then return path end
	return platform.path:join(self._cwd, path)
end
function Terminal:_paths(prefix)
	local dir, leaf = prefix:match("^(.*[/\\])([^/\\]*)$")
	dir, leaf = dir or "", leaf or prefix
	local out = {}
	pcall(function()
		for name in lfs.dir(self:_path(dir == "" and "." or dir)) do
			if name ~= "." and name ~= ".." and name:sub(1, #leaf):lower() == leaf:lower() then
				local tail = lfs.attributes(self:_path(dir .. name), "mode") == "directory" and platform.sep or ""
				out[#out + 1] = dir .. name .. tail
			end
		end
	end)
	return out
end
function Terminal:write(text, role, language)
	local block = self._buffer:append(text, { role = role, language = language })
	self:_render()
	self._output:scrollToEnd()
	return block
end
function Terminal:_render()
	local text, fragments = self._buffer:snapshot()
	self._output:setTranscript(text, fragments)
end
function Terminal:clear()
	self._generation = self._generation + 1
	for _, request in pairs(self._requests) do request.cancel() end
	self._requests = {}
	self._buffer:clear()
	self:_render()
end
function Terminal:reset()
	self:cancel(); self:clear(); self._shell = Shell.new(); self:_inputText(""); self:focus()
end
function Terminal:cancel()
	if self._process then
		self._process:kill(); self._process:close(); self._process = nil
		self._iup.SetAttribute(self._timer, "RUN", "NO")
		self:write("^C\n", "comment")
	end
end
function Terminal:_open(path, line, column)
	local ok, why = self._opts.host:openCode(self:_path(path), line or 1, column or 1)
	if not ok then self:write(tostring(why) .. "\n", "error") end
end
function Terminal:_show(path)
	path = self:_path(path)
	local file, why = io.open(path, "rb")
	if not file then return self:write(tostring(why) .. "\n", "error") end
	local text = file:read(256 * 1024 + 1); file:close()
	if #text > 128 * 1024 then return self:write("show accepts files up to 128 KiB. Use open for larger files.\n", "error") end
	if text:find("%z") then return self:write("This file contains binary data.\n", "error") end
	local block = self:write(text .. (text:sub(-1) == "\n" and "" or "\n"), nil, CodeView.languageOf(path))
	local generation = self._generation
	local ticket, completed = {}, false
	local request = CodeBinder.semanticSnapshot({ registry = self._opts.host:languageServers(), path = path, text = text,
		on_done = function() completed = true; self._requests[ticket] = nil end,
		on_tokens = function(tokens)
			if self._generation ~= generation then return end
			block.tokens = tokens; self:_render()
		end })
	if request and not completed then self._requests[ticket] = request end
end
function Terminal:execute(text)
	self:_inputText("")
	if not text:match("%S") then return end
	if self._process then self:write("Lunar CLI is running. Ctrl+C cancels it.\n", "error"); return end
	self:write("lunar > " .. text .. "\n", "keyword")
	local result, why = self._shell:execute(text)
	if not result then return self:write(why .. "\n", "error") end
	local action, host = result.action, self._opts.host
	if action == "print" then self:write(result.text .. "\n")
	elseif action == "clear" then self:clear()
	elseif action == "exit" then if self._layout:terminalVisible() then self._layout:toggleTerminal() end
	elseif action == "version" then self:write(self._opts.version .. "\n")
	elseif action == "pwd" then self:write(self._cwd .. "\n")
	elseif action == "about" then self:write("Lunar Extension Host " .. self._opts.version .. "\nLuaJIT + IUP; Lunar CLI script terminal.\n")
	elseif action == "settings" then host:dispatchRoute("lunar://host/settings")
	elseif action == "show" then self:_show(result.args[2])
	elseif action == "open" then
		local path, line = result.args[2]:match("^(.-):(%d+)$")
		self:_open(path or result.args[2], tonumber(line))
	elseif action == "extensions" then
		local manager = self._opts.extensions
		for _, ext in ipairs(manager.extensions or {}) do self:write((ext.name or ext.id or "Extension") .. "  loaded\n") end
		for _, ext in ipairs(manager.skipped or {}) do self:write((ext.name or ext.id or ext.source or "Extension")
			.. "  skipped: " .. tostring(ext.reason) .. "\n", "comment") end
		if #(manager.extensions or {}) == 0 and #(manager.skipped or {}) == 0 then self:write("No extensions loaded.\n") end
	elseif action == "themes" then
		for _, theme in ipairs(self._opts.themes:themes()) do self:write(theme.id .. "  " .. theme.label .. "\n") end
	elseif action == "problems" then
		local diagnostics = host:languageDiagnostics()
		local list = diagnostics and diagnostics:list() or {}
		for _, d in ipairs(list) do self:write(string.format("%s:%d:%d: %s: %s\n", Uri.toPath(d.uri) or d.uri, d.line + 1,
			d.character + 1, d.kind, d.message), d.severity == 1 and "error" or d.severity == 2 and "number" or "comment") end
		if #list == 0 then self:write("No problems.\n") end
	elseif action == "lsp" then
		local registry = host:languageServers()
		local entries = registry and registry:servers() or {}
		for _, entry in ipairs(entries) do self:write(entry.name .. "  " .. registry:status(entry.id) .. "\n") end
		if #entries == 0 then self:write("No language servers registered.\n") end
	elseif action == "cli" then self:_spawn(result.argv) end
end
function Terminal:_spawn(args)
	local argv = { platform.path:join(platform.exe_dir(), platform.is_windows and "LunarCLI.exe" or "lunar-cli") }
	for _, value in ipairs(args) do argv[#argv + 1] = value end
	local ok, process = pcall(require, "process")
	if not ok then return self:write("Process support is unavailable in this build.\n", "error") end
	local child, why = process.spawn({ argv = argv, cwd = self._cwd })
	if not child then return self:write("Could not start Lunar CLI: " .. tostring(why) .. "\n", "error") end
	self._process = child
	self._iup.SetAttribute(self._timer, "RUN", "YES")
end
function Terminal:_pump()
	local child = self._process
	if not child then return end
	local changed = false
	for _, stream in ipairs({ "stdout", "stderr" }) do
		local text = child:read(stream, 32768)
		if text and text ~= "" then
			local role = stream == "stderr" and "error" or nil
			for line in text:gmatch("[^\n]*\n?") do
				if line ~= "" then
					local lower = line:lower()
					self._buffer:append(line, { role = lower:find("error", 1, true) and "error"
						or lower:find("warn", 1, true) and "number" or role })
				end
			end
			changed = true
		end
	end
	local code = child:poll()
	if code ~= nil then
		-- Drain again on the next tick until both pipes have reached EOF.
		if changed then self:_render(); return end
		child:close(); self._process = nil
		self._iup.SetAttribute(self._timer, "RUN", "NO")
		self:write("[Lunar CLI exited " .. code .. "]\n", code ~= 0 and "error" or "comment")
	elseif changed then self:_render() end
end
function Terminal:destroy()
	if self._destroyed then return end
	self._destroyed = true
	self._generation = self._generation + 1
	if self._process then self._process:close(); self._process = nil end
	for _, request in pairs(self._requests) do request.cancel() end
	self._requests = {}
	self._iup.SetAttribute(self._timer, "RUN", "NO")
	self._iup.Destroy(self._timer)
end
return Terminal

--- Connects one `core.ui.CodeView` to the language server for its file.
--
-- The view knows nothing about servers and the client knows nothing about
-- widgets; this is the thin piece between them. It opens the document with the
-- right client, forwards edits, draws the server's diagnostics on the view, and
-- turns three gestures into requests:
--
--   * resting the pointer on text asks for hover and shows the card;
--   * typing (in an editable view) asks for completion and shows the list;
--   * F12 or Ctrl+click asks for the definition and hands the answer to `navigate`.
--
-- Each feature is offered only when the server says it has it. With no server
-- for the file, or none found on the computer, the binder says so through
-- `on_status` and the view stays a plain code view.
--
-- @classmod core.ui.CodeBinder
local Uri = require("core.lsp.Uri")
local Documents = require("core.lsp.Documents")
local CodePopup = require("core.ui.CodePopup")

local CodeBinder = {}
CodeBinder.__index = CodeBinder

--- Files larger than this are shown without language features: the whole text
-- goes to the server on every edit.
CodeBinder.MAX_BYTES = 4 * 1024 * 1024

local SEVERITY = { "error", "warning", "info", "hint" }

--- Attach a view to its file's server.
--
-- @tparam table opts
-- @tparam userdata opts.iup
-- @tparam core.ui.CodeView opts.view
-- @tparam string opts.path the file's absolute path
-- @tparam core.lsp.Registry opts.registry
-- @tparam core.lsp.Diagnostics opts.diagnostics
-- @tparam core.ui.CodePopup opts.popup shared by every view in the window
-- @tparam[opt] function opts.navigate `fn(locations)`: go to a definition. Each
--   location is `{ uri, path, line, character, end_line, end_character, encoding }`
-- @tparam[opt] function opts.on_status `fn(state, message)`: the server's state
--   in words, for the page to show
-- @tparam[opt] function opts.on_key `fn(key) -> handled`: keys the binder did not use
function CodeBinder.attach(opts)
	local self = setmetatable({
		_iup = opts.iup,
		_view = opts.view,
		_path = opts.path,
		_uri = Uri.fromPath(opts.path),
		_registry = opts.registry,
		_diagnostics = opts.diagnostics,
		_popup = opts.popup,
		_navigate = opts.navigate,
		_on_status = opts.on_status,
		_on_key = opts.on_key,
	}, CodeBinder)
	self:_connect()
	self:_hook()
	return self
end

function CodeBinder:_status(state, message)
	self.state, self.message = state, message
	if self._on_status then pcall(self._on_status, state, message) end
end

-- Say what the server is doing, in a sentence.
function CodeBinder:refreshStatus()
	local client, entry = self._client, self._entry
	if not entry then
		return self:_status("none", self._reason or "No language server is installed for this kind of file.")
	end
	local state, detail = client.state, client.detail
	if state == "running" then
		self:_status("running", entry.name .. " language server is running.")
	elseif state == "starting" then
		self:_status("starting", "Starting the " .. entry.name .. " language server...")
	elseif state == "restarting" then
		self:_status("restarting", entry.name .. " language server stopped and is restarting. " .. tostring(detail or ""))
	elseif state == "unavailable" then
		self:_status("unavailable", tostring(detail or (entry.name .. " language server was not found.")))
	elseif state == "failed" then
		self:_status("failed", entry.name .. " language server stopped: " .. tostring(detail or "it could not be started."))
	else
		self:_status("stopped", entry.name .. " language server is not running.")
	end
end

function CodeBinder:_connect()
	local view = self._view
	if not (self._registry and view.rich) then
		self._reason = view.rich and "Language servers are unavailable in this build."
			or "Language features need the code view, which this build does not include."
		return self:refreshStatus()
	end
	local text = view:text()
	if #text > CodeBinder.MAX_BYTES then
		self._reason = "Language features are off for files over 4 MB."
		return self:refreshStatus()
	end
	local client, entry, language = self._registry:clientFor(self._path)
	if not client then return self:refreshStatus() end
	self._client, self._entry = client, entry
	client:open(self._uri, language, text)
	self._stop_listening = self._diagnostics:onChange(function(uri)
		if Uri.key(uri) == Uri.key(self._uri) then self:_drawDiagnostics() end
	end)
	self:_drawDiagnostics()
	self:refreshStatus()
end

-- The store holds protocol positions; the view wants byte columns.
function CodeBinder:_drawDiagnostics()
	local client = self._client
	if not client then return end
	local list = {}
	for _, d in ipairs(self._diagnostics:forUri(self._uri)) do
		local line, column = client.documents:fromPosition(self._uri, { line = d.line, character = d.character })
		local end_line, end_column = client.documents:fromPosition(self._uri,
			{ line = d.end_line, character = d.end_character })
		list[#list + 1] = {
			line = line, column = column, end_line = end_line, end_column = end_column,
			severity = d.severity, message = d.message, source = d.source, code = d.code,
		}
	end
	local ok = pcall(self._view.setDiagnostics, self._view, list)
	if not ok then self:detach() end   -- the view is gone
end

local function diagnostic_text(d)
	local tail = d.source and (" (" .. d.source .. (d.code and (" " .. d.code) or "") .. ")") or ""
	return d.message .. tail
end

function CodeBinder:_hover(line, column, point)
	local view, popup, client = self._view, self._popup, self._client
	if self._hover_request then self._hover_request.cancel() end
	self._hover_request = nil
	if not line then
		popup:hide("hover")
		return
	end
	if popup:isOpen("list") then return end

	-- What is wrong here comes first: it is what the squiggle promised.
	local blocks = {}
	for _, d in ipairs(view:diagnosticsAt(line, column)) do
		blocks[#blocks + 1] = { text = diagnostic_text(d), kind = SEVERITY[d.severity] or "error" }
	end
	local function show(more)
		local all = {}
		for _, block in ipairs(blocks) do all[#all + 1] = block end
		for _, block in ipairs(more or {}) do all[#all + 1] = block end
		if #all > 0 then popup:showHover(point, all) else popup:hide("hover") end
	end
	if not (client and client:supports("hover")) then return show() end
	-- Nothing to ask about between words.
	local _, _, word = view:wordAt(line, column)
	if word == "" then return show() end
	local request
	request = client:hover(self._uri, line, column, function(result)
		if self._hover_request ~= request then return end
		self._hover_request = nil
		show(type(result) == "table" and CodePopup.blocks(result.contents) or nil)
	end)
	self._hover_request = request
	if #blocks > 0 then show() end
end

-- The word being typed, and the screen point it starts at.
function CodeBinder:_typed()
	local view = self._view
	local line, column = view:caret()
	local text = view:lineText(line):sub(1, column)
	local word = text:match("[%w_]*$") or ""
	return line, column, word, column - #word
end

function CodeBinder:_closeList()
	if self._list_request then self._list_request.cancel() end
	self._list_request, self._list_items = nil, nil
	self._popup:hide("list")
end

function CodeBinder:_showList()
	local view, popup = self._view, self._popup
	local line, _, word, start = self:_typed()
	if line ~= self._list_line then return self:_closeList() end
	local items = CodePopup.filter(self._list_items or {}, word)
	if #items == 0 then return popup:hide("list") end
	local point = view:pointOf(line, start)
	if not point then return end
	popup:hide("hover")
	popup:showList(point, items, function(item) self:_accept(item) end)
end

--- Ask the server for completions at the caret.
-- @tparam[opt] string trigger the character that prompted it
function CodeBinder:complete(trigger)
	local client, view = self._client, self._view
	if not (client and client:supports("completion")) or view:isReadOnly() then return false end
	local line, column = view:caret()
	if self._list_request then self._list_request.cancel() end
	local request
	request = client:completion(self._uri, line, column, trigger, function(items, err)
		if self._list_request ~= request then return end
		self._list_request = nil
		if err or not items then return self:_closeList() end
		self._list_items, self._list_line = items, line
		self:_showList()
	end)
	self._list_request = request
	return true
end

function CodeBinder:_accept(item)
	local view = self._view
	local line, column, _, start = self:_typed()
	self:_closeList()
	view:replace(line, start, column, CodePopup.insertion(item))
	view:focus()
end

function CodeBinder:_char(ch)
	local client = self._client
	if not client or self._view:isReadOnly() then return end
	local is_word = ch:match("^[%w_]$") ~= nil
	local is_trigger = false
	for _, trigger in ipairs(client:completionTriggers()) do
		if trigger == ch then is_trigger = true end
	end
	if self._popup:isOpen("list") and is_word and self._list_items then
		return self:_showList()   -- narrow what is already there
	end
	if is_word or is_trigger then
		self:complete(is_trigger and ch or nil)
	else
		self:_closeList()
	end
end

--- Go to the definition of what is at a place (default: the caret).
function CodeBinder:definition(line, column)
	local client, view = self._client, self._view
	if not (client and client:supports("definition")) then
		self:_status(self.state, "Go to definition is not available for this file.")
		return false
	end
	if not line then line, column = view:caret() end
	client:definition(self._uri, line, column, function(locations, err)
		if err or not locations or #locations == 0 then
			self:_status(self.state, err and err.message or "No definition found.")
			return
		end
		local out = {}
		for _, location in ipairs(locations) do
			local range = type(location.range) == "table" and location.range or {}
			local from = type(range.start) == "table" and range.start or {}
			local to = type(range["end"]) == "table" and range["end"] or from
			out[#out + 1] = {
				uri = location.uri, path = Uri.toPath(location.uri),
				line = tonumber(from.line) or 0, character = tonumber(from.character) or 0,
				end_line = tonumber(to.line) or tonumber(from.line) or 0,
				end_character = tonumber(to.character) or tonumber(from.character) or 0,
				encoding = client.documents:encoding(),
			}
		end
		if self._navigate then self._navigate(out) end
	end)
	return true
end

function CodeBinder:_key(key)
	local iup, popup = self._iup, self._popup
	if popup:isOpen("list") then
		if key == iup.K_DOWN then popup:move(1); return true end
		if key == iup.K_UP then popup:move(-1); return true end
		if key == iup.K_PGDN then popup:move(CodePopup.ROWS); return true end
		if key == iup.K_PGUP then popup:move(-CodePopup.ROWS); return true end
		if key == iup.K_CR or key == iup.K_TAB then
			local item = popup:selected()
			if item then self:_accept(item) end
			return true
		end
		if key == iup.K_ESC then self:_closeList(); return true end
		if key == iup.K_LEFT or key == iup.K_RIGHT or key == iup.K_HOME or key == iup.K_END then self:_closeList() end
		if key == iup.K_BS then
			-- After the deletion lands, narrow again (or close once the word is gone).
			self._after_key = function()
				local _, _, word = self:_typed()
				if word == "" then self:_closeList() else self:_showList() end
			end
		end
	elseif popup:isOpen("hover") then
		popup:hide("hover")
	end
	if key == iup.K_F12 then
		self:definition()
		return true
	end
	if key == iup.K_cSP then
		self:complete()
		return true
	end
	if self._on_key then return self._on_key(key) == true end
	return false
end

function CodeBinder:_hook()
	local view = self._view
	view:onChange(function(text)
		if self._client then self._client:change(self._uri, text) end
		if self._after_key then
			local fn = self._after_key
			self._after_key = nil
			fn()
		end
		if self._on_change then self._on_change(text) end
	end)
	view:onHover(function(line, column, point) self:_hover(line, column, point) end)
	view:onChar(function(ch) self:_char(ch) end)
	view:onKey(function(key) return self:_key(key) end)
	view:onClick(function(line, column, status)
		self._popup:hide()
		-- Ctrl+click follows a definition, as in an editor.
		if self._iup.iscontrol and self._iup.iscontrol(status) then
			self:definition(line, column)
			return true
		end
		return false
	end)
	view:onScroll(function() self._popup:hide() end)
	view:onBlur(function() self._popup:hide() end)
end

--- `fn(text)` after each edit, once the server has been told.
function CodeBinder:onChange(fn) self._on_change = fn end

--- The server client behind the view, or nil.
function CodeBinder:client() return self._client end

--- The file's URI.
function CodeBinder:uri() return self._uri end

--- Tell the server the file was saved.
function CodeBinder:saved()
	if self._client then self._client:saved(self._uri) end
end

--- Convert a protocol `character` on a line of text to a byte column.
function CodeBinder.byteColumn(line_text, character, encoding)
	return Documents.characterToByte(line_text or "", character or 0, encoding)
end

--- Colour a printed snapshot using an already running server, without starting one.
-- Borrow an editor's document only when its text agrees; never change it for a print.
function CodeBinder.semanticSnapshot(opts)
	if not opts.registry then return nil end
	local client, language = opts.registry:runningClientFor(opts.path)
	if not client or not client:supports("semanticTokens") then return nil end
	local uri = Uri.fromPath(opts.path)
	local release_document = client:retainSnapshot(uri, language, opts.text)
	if not release_document then return nil end
	local closed = false
	local function release()
		if closed then return end
		closed = true
		release_document()
		if opts.on_done then opts.on_done() end
	end
	local request = client:semanticTokens(uri, function(tokens)
		if closed then return end
		release()
		if tokens then opts.on_tokens(tokens) end
	end)
	return { cancel = function()
		if request then request.cancel() end
		release()
	end }
end

--- Close the document with the server and stop listening. The view is left alone.
function CodeBinder:detach()
	if self._detached then return end
	self._detached = true
	if self._stop_listening then self._stop_listening() end
	if self._hover_request then self._hover_request.cancel() end
	if self._list_request then self._list_request.cancel() end
	pcall(function() self._popup:hide() end)
	if self._client then self._client:close(self._uri) end
	self._client = nil
end

return CodeBinder

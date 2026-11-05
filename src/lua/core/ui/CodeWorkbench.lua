--- The host's code surfaces: the Code tab, the Problems tab, the problem count in
-- the status bar, and the `lunar://code/...` addresses that reach them.
--
-- Neither tab exists until it is needed. The first `lunar://code/open?path=...`
-- (a file link in a tool's output, Open File in the command bar, a definition)
-- creates the Code tab; it is an ordinary tab from then on, so it splits, groups
-- and drags like any other. A file always opens **there**, never in place of the
-- page the user was on: following a definition from a tool leaves the tool as it was.
--
-- Files open read-only. Edit turns editing on for a file that can be written,
-- and only then do Save and completion apply.
--
-- @classmod core.ui.CodeWorkbench
local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")
local CodeView = require("core.ui.CodeView")
local CodePopup = require("core.ui.CodePopup")
local CodeBinder = require("core.ui.CodeBinder")
local ProblemsPanel = require("core.ui.ProblemsPanel")
local Diagnostics = require("core.lsp.Diagnostics")
local Uri = require("core.lsp.Uri")
local Languages = require("core.classes.host.Languages")

local Workbench = {}
Workbench.__index = Workbench

--- The largest file the Code tab will load.
Workbench.MAX_FILE = 32 * 1024 * 1024
--- How many places Back remembers.
Workbench.HISTORY = 50

local WINDOWS = package.config:sub(1, 1) == "\\"

-- What the toolbar chip says for each server state, and its status glyph.
local CHIP = {
	running = { kind = "ok", text = "%s" },
	starting = { kind = "info", text = "%s: starting" },
	restarting = { kind = "warning", text = "%s: restarting" },
	unavailable = { kind = "warning", text = "%s: not found" },
	failed = { kind = "error", text = "%s: stopped" },
	stopped = { kind = "idle", text = "%s: not running" },
}

-- ---------------------------------------------------------------------------
-- Paths (pure)
-- ---------------------------------------------------------------------------

--- An absolute path in this platform's spelling, or nil and why not.
function Workbench.normalizePath(path, windows)
	if windows == nil then windows = WINDOWS end
	if type(path) ~= "string" or path == "" then return nil, "No file was named." end
	if path:find("%z") then return nil, "That is not a file name." end
	local from_uri = Uri.toPath(path, windows)
	if from_uri then path = from_uri end
	if windows then
		path = path:gsub("/", "\\")
		if not (path:match("^%a:\\") or path:match("^\\\\[^\\]+\\[^\\]+")) then
			return nil, "The Code tab needs a full path, such as C:\\project\\main.c."
		end
	elseif path:sub(1, 1) ~= "/" then
		return nil, "The Code tab needs a full path, such as /home/me/main.c."
	end
	return path
end

--- A file's name and the folder it is in.
function Workbench.splitPath(path)
	local folder, name = tostring(path):match("^(.*)[/\\]([^/\\]+)$")
	return name or tostring(path), folder or ""
end

--- Read a `line` or `column` route parameter: one-based in an address, zero-based inside.
function Workbench.index(value)
	local n = tonumber(value)
	if not n or n < 1 then return 0 end
	return math.floor(n) - 1
end

--- The address that opens a file at a place.
-- @tparam string path
-- @tparam[opt] number line zero-based
-- @tparam[opt] number column zero-based
function Workbench.address(path, line, column)
	local RouteUri = require("core.lib.RouteUri")
	local params = { path = path }
	if line then params.line = line + 1 end
	if column and column > 0 then params.column = column + 1 end
	return RouteUri.serialize({ kind = "code", target = "open", params = params })
end

local function key_of(path)
	return WINDOWS and path:lower() or path
end

-- ---------------------------------------------------------------------------
-- Installation
-- ---------------------------------------------------------------------------

--- Wire the code surfaces into the host. Called once by `main.lua`.
--
-- @tparam table opts
-- @tparam userdata opts.iup
-- @tparam core.classes.HostAPI opts.host
-- @tparam userdata opts.dialog the main dialog
-- @tparam userdata opts.tabs the main tab strip
-- @tparam function opts.groups `fn() -> core.classes.TabGroups`
-- @tparam[opt] core.classes.PaneGrid opts.panes
-- @tparam[opt] core.classes.CommandRegistry opts.commands
-- @tparam[opt] core.ui.CommandPalette opts.palette
-- @tparam[opt] function opts.theme_widget `fn(widget)`: theme a new widget tree
-- @tparam[opt] table opts.settings `core.classes.SettingsManager`
-- @treturn CodeWorkbench
function Workbench.install(opts)
	local self = setmetatable({
		_iup = opts.iup,
		_host = opts.host,
		_dialog = opts.dialog,
		_tabs = opts.tabs,
		_groups = opts.groups or function() return nil end,
		_panes = opts.panes,
		_commands = opts.commands,
		_palette = opts.palette,
		_theme = opts.theme_widget or function() end,
		_settings = opts.settings,
		_docs = {},          -- array, in strip order
		_history = {},
		_history_at = 0,
	}, Workbench)
	local host = self._host
	self._registry = host:languageServers()
	self._diagnostics = host:languageDiagnostics() or Diagnostics.new()
	self._popup = CodePopup.new({
		iup = self._iup, parent = self._dialog,
		round = function(window) pcall(function() require("core.lib.desktop").roundWindow(opts.iup, window) end) end,
	})

	host:registerRouteService("code", function(route) return self:_route(route) end)
	self._diagnostics:onChange(function() self:_countsChanged() end)
	Languages.onChange(host, function() self:_serversChanged() end)
	self:_registerCommands()
	return self
end

function Workbench:_setStatus(message)
	pcall(function() self._host:setStatus(message) end)
end

-- ---------------------------------------------------------------------------
-- Host tabs, created on first use
-- ---------------------------------------------------------------------------

-- Add a page to the main strip after the window is up, the way an extension's
-- tab arrives, and give it a place in the saved layout.
function Workbench:_addHostTab(id, title, icon, widget)
	local iup, host = self._iup, self._host
	iup.SetAttribute(widget, "TABTITLE", title)
	if icon then Kit.bindIcon(iup, widget, icon, { attribute = "TABIMAGE", size = 16, role = "neutral" }) end
	iup.Append(self._tabs, widget)
	host:registerHostTab(id, widget)
	if host._shown then
		iup.Map(widget)
		iup.Refresh(self._tabs)
	end
	host:installKeyDispatch(widget)
	local groups = self._groups()
	if groups then
		-- Re-filing it in its own strip syncs the strip's titles and saves the layout.
		pcall(groups.moveInto, groups, widget, self._tabs)
	end
	self._theme(widget)
	return widget
end

function Workbench:_reveal(widget)
	pcall(function() self._host:_activateTabWidget(widget) end)
end

-- ---------------------------------------------------------------------------
-- The Code tab
-- ---------------------------------------------------------------------------

function Workbench:_buildCodePage()
	if self._page then return self._page end
	local iup = self._iup
	local bench = self

	local function icon_button(icon, tip, action)
		local button = iup.flatbutton({ TITLE = "", TIP = tip, THEMEROLE = "icon_btn", CANFOCUS = "NO", ACTIVE = "NO" })
		Kit.bindIcon(iup, button, icon, { role = "neutral" })
		function button:flat_action()
			action()
			return iup.DEFAULT
		end
		return button
	end
	self._back = icon_button("arrow--left", "Back (Alt+Left)", function() bench:back() end)
	self._forward = icon_button("arrow--right", "Forward (Alt+Right)", function() bench:forward() end)
	self._name = iup.flatlabel({ TITLE = "", THEMEROLE = "sectiontitle" })
	self._folder = iup.flatlabel({ TITLE = "", THEMEROLE = "settingslabel_muted", EXPAND = "HORIZONTAL", ELLIPSIS = "YES" })
	self._chip = Kit.statusLine(iup, "idle", "")
	iup.SetAttribute(self._chip, "EXPAND", "NO")
	self._edit = Kit.button(iup, { title = "Edit", icon = "edit", role = "actionbutton",
		tip = "Turn on editing for this file", action = function() bench:toggleEdit() end })
	self._save = Kit.button(iup, { title = "Save", icon = "save", role = "primary_btn",
		tip = "Save (Ctrl+S)", action = function() bench:save() end })
	Kit.show(iup, self._save, false)
	local toolbar = L.row(iup, {
		self._back, self._forward, self._name, self._folder, self._chip, self._edit, self._save,
		EXPAND = "HORIZONTAL",
	})
	self._toolbar = toolbar
	Kit.show(iup, toolbar, false)

	local strip = iup.flattabs({ SHOWCLOSE = "YES", EXPAND = "YES", THEMEROLE = "flattabs_sub" })
	self._strip = strip
	-- The stock close image is drawn for a much larger tab than this one.
	local close = Kit.icon(iup, "close", 12, "neutral")
	if close then
		iup.SetAttribute(strip, "CLOSEIMAGE", close)
		iup.SetAttribute(strip, "CLOSEIMAGEPRESS", close)
	end
	function strip:tabchangepos_cb(new_pos)
		bench:_activated(bench._docs[new_pos + 1])
		return iup.DEFAULT
	end
	function strip:tabclose_cb(pos)
		-- CONTINUE lets the strip destroy the page; IGNORE keeps it.
		return bench:_closing(pos + 1) and iup.CONTINUE or iup.IGNORE
	end

	local hint = "Use Open File in the command bar (Ctrl+P), or follow a file link from a tool."
	if not CodeView.available() then
		hint = hint .. " This build has no code view, so files open as plain text."
	end
	local body
	body, self._set_empty = Kit.emptyPane(iup, {
		content = strip, icon = "code", title = "No file open", hint = hint,
	})
	self._set_empty(true)

	-- One line under the text: the problem on the caret's line, or why there is
	-- no language server.
	self._message = Kit.statusLine(iup, nil, "")
	iup.SetAttribute(self._message, "ELLIPSIS", "YES")
	self._settings_link = iup.flatbutton({ TITLE = "Language server settings", THEMEROLE = "link_btn", CANFOCUS = "NO" })
	function self._settings_link:flat_action()
		bench._host:dispatchRoute("lunar://host/settings")
		return iup.DEFAULT
	end
	Kit.show(iup, self._settings_link, false)
	local footer = L.row(iup, { self._message, self._settings_link, EXPAND = "HORIZONTAL" })

	self._page = L.page(iup, {
		toolbar, body, footer,
		MARGIN = L.margin(L.ROLE.page, 3), GAP = L.gap(3), EXPAND = "YES",
	})
	self._anchor = body
	self:_addHostTab("code", "Code", "code", self._page)
	self._host:setHostTabRoute("code", function()
		local doc = bench:_current()
		if not doc then return nil end
		local line = doc.view:caret()
		return { kind = "code", target = "open", params = { path = doc.path, line = line + 1 } }
	end)
	return self._page
end

function Workbench:_current()
	if not self._strip then return nil end
	local pos = tonumber(self._iup.GetAttribute(self._strip, "VALUEPOS")) or 0
	return self._docs[pos + 1]
end

function Workbench:_find(path)
	local key = key_of(path)
	for index, doc in ipairs(self._docs) do
		if doc.key == key then return doc, index end
	end
	return nil
end

function Workbench:_title(doc)
	local name = Workbench.splitPath(doc.path)
	return doc.view:isModified() and (name .. " *") or name
end

function Workbench:_syncTitles()
	local iup = self._iup
	for index, doc in ipairs(self._docs) do
		iup.SetAttributeId(self._strip, "TABTITLE", index - 1, self:_title(doc))
		iup.SetAttributeId(self._strip, "TABTIP", index - 1, doc.path)
	end
	pcall(iup.Update, self._strip)
end

-- Put the toolbar and the message line in step with a document.
function Workbench:_activated(doc)
	local iup = self._iup
	Kit.show(iup, self._toolbar, doc ~= nil, self._anchor)
	if not doc then
		iup.SetAttribute(self._message, "TITLE", "")
		Kit.show(iup, self._settings_link, false)
		return
	end
	local name, folder = Workbench.splitPath(doc.path)
	iup.SetAttribute(self._name, "TITLE", name)
	iup.SetAttribute(self._folder, "TITLE", folder)
	iup.SetAttribute(self._edit, "TITLE", doc.view:isReadOnly() and "Edit" or "Editing")
	iup.SetAttribute(self._edit, "ACTIVE", doc.writable and "YES" or "NO")
	iup.SetAttribute(self._edit, "TIP", doc.writable and "Turn editing on or off for this file"
		or "This file can't be changed: it is read-only on disk")
	Kit.show(iup, self._save, not doc.view:isReadOnly(), self._edit)
	iup.SetAttribute(self._save, "ACTIVE", doc.view:isModified() and "YES" or "NO")
	iup.SetAttribute(self._back, "ACTIVE", self._history_at > 1 and "YES" or "NO")
	iup.SetAttribute(self._forward, "ACTIVE", self._history_at < #self._history and "YES" or "NO")
	self:_showServer(doc)
	self:_showMessage(doc)
	pcall(iup.Refresh, self._toolbar)
end

function Workbench:_showServer(doc)
	local iup = self._iup
	local binder = doc.binder
	local state, name = binder and binder.state or "none", binder and binder._entry and binder._entry.name
	local chip = CHIP[state]
	if chip and name then
		Kit.setStatus(iup, self._chip, chip.kind, chip.text:format(name))
	else
		Kit.setStatus(iup, self._chip, "idle", "No language server")
	end
	iup.SetAttribute(self._chip, "TIP", binder and binder.message or "")
end

-- The line under the text.
function Workbench:_showMessage(doc)
	local iup = self._iup
	local binder = doc.binder
	local state = binder and binder.state
	local line = doc.view:caret()
	local here = doc.view:diagnosticsOnLine(line)[1]
	local link = false
	if here then
		local kinds = { "error", "warning", "info", "info" }
		local text = here.message:match("^[^\r\n]*") or ""
		if here.source then text = text .. "  (" .. here.source .. (here.code and (" " .. here.code) or "") .. ")" end
		Kit.setStatus(iup, self._message, kinds[here.severity] or "error", text)
	elseif state == "unavailable" or state == "failed" then
		Kit.setStatus(iup, self._message, state == "failed" and "error" or "warning", binder.message)
		link = true
	elseif state == "none" and binder and binder._reason then
		Kit.setStatus(iup, self._message, "idle", binder._reason)
	elseif doc.note and doc.note ~= "" then
		Kit.setStatus(iup, self._message, "idle", doc.note)
	else
		-- Nothing to say: the line keeps its height, or the text would jump under the
		-- caret each time it reaches a line with a problem.
		iup.SetAttribute(self._message, "IMAGE", "")
		iup.SetAttribute(self._message, "TITLE", "")
	end
	Kit.show(iup, self._settings_link, link, self._anchor)
end

local function read_file(path)
	local file, err = io.open(path, "rb")
	if not file then return nil, "Couldn't open " .. path .. ": " .. tostring(err) end
	local size = file:seek("end")
	if size and size > Workbench.MAX_FILE then
		file:close()
		return nil, string.format("%s is %d MB. The Code tab opens files up to %d MB.",
			path, math.floor(size / 1048576), Workbench.MAX_FILE / 1048576)
	end
	file:seek("set", 0)
	local text = file:read("*a") or ""
	file:close()
	if text:sub(1, 8192):find("%z") then
		return nil, path .. " looks like a binary file, so it was not opened as text."
	end
	return text
end

local function is_writable(path)
	local file = io.open(path, "r+b")
	if file then file:close() end
	return file ~= nil
end

--- Open a file in the Code tab and show it.
--
-- @tparam string path absolute path (or a `file:` URI)
-- @tparam[opt] table at `line`, `column` (zero-based, bytes), `end_line`,
--   `end_column`; or `character` with `encoding` for a protocol position
-- @treturn[1] boolean true
-- @treturn[2] nil
-- @treturn[2] string why not, for the user
function Workbench:open(path, at)
	at = at or {}
	local normal, why = Workbench.normalizePath(path)
	if not normal then return nil, why end
	local iup = self._iup
	local doc, index = self:_find(normal)
	if not doc then
		local text, read_err = read_file(normal)
		if not text then return nil, read_err end
		self:_buildCodePage()
		local view = CodeView.new(iup, { language = CodeView.languageOf(normal), text = text, read_only = true })
		local page = iup.vbox({ view:widget(), MARGIN = "0x0", GAP = "0", EXPAND = "YES" })
		doc = { path = normal, key = key_of(normal), view = view, page = page, writable = is_writable(normal) }
		iup.SetAttribute(page, "TABTITLE", (Workbench.splitPath(normal)))
		iup.Append(self._strip, page)
		iup.Map(page)
		self._theme(page)
		self._docs[#self._docs + 1] = doc
		index = #self._docs
		self._set_empty(false)
		self:_attach(doc)
		self:_syncTitles()
		iup.Refresh(self._strip)
	end
	iup.SetAttribute(self._strip, "VALUEPOS", tostring(index - 1))
	self:_reveal(self._page)

	local line, column = at.line, at.column
	if line and at.character then
		column = CodeBinder.byteColumn(doc.view:lineText(line), at.character, at.encoding)
	end
	local end_column = at.end_column
	if at.end_line and at.end_character then
		end_column = CodeBinder.byteColumn(doc.view:lineText(at.end_line), at.end_character, at.encoding)
	end
	if line then doc.view:goTo(line, column or 0, at.end_line, end_column) end
	if at.history ~= false then self:_remember(doc.path, line or (doc.view:caret())) end
	self:_activated(doc)
	iup.Refresh(self._page)
	doc.view:focus()
	return true
end

function Workbench:_attach(doc)
	local bench = self
	doc.binder = CodeBinder.attach({
		iup = self._iup, view = doc.view, path = doc.path,
		registry = self._registry, diagnostics = self._diagnostics, popup = self._popup,
		navigate = function(locations) bench:_navigate(locations) end,
		on_status = function()
			if bench:_current() == doc then
				bench:_showServer(doc)
				bench:_showMessage(doc)
			end
		end,
		on_key = function(key) return bench:_key(key) end,
	})
	doc.binder:onChange(function()
		bench:_syncTitles()
		if bench:_current() == doc then
			pcall(bench._iup.SetAttribute, bench._save, "ACTIVE", doc.view:isModified() and "YES" or "NO")
		end
	end)
	doc.view:onCaret(function()
		if bench:_current() == doc then bench:_showMessage(doc) end
	end)
	-- Drawn diagnostics change what the caret's line says.
	doc.stop_diagnostics = self._diagnostics:onChange(function(uri)
		if Uri.key(uri) == Uri.key(doc.binder:uri()) and bench:_current() == doc then
			pcall(bench._showMessage, bench, doc)
		end
	end)
end

-- A strip tab's close button was pressed. True: go ahead and destroy the page.
function Workbench:_closing(index)
	local iup = self._iup
	local doc = self._docs[index]
	if not doc then return true end
	if doc.view:isModified() then
		local name = Workbench.splitPath(doc.path)
		local choice = iup.Alarm("Close " .. name, name .. " has changes that were not saved.",
			"Save and close", "Close without saving", "Cancel")
		if choice == 3 or choice == 0 then return false end
		if choice == 1 and not self:save(doc) then return false end
	end
	if doc.stop_diagnostics then doc.stop_diagnostics() end
	doc.binder:detach()
	table.remove(self._docs, index)
	-- After the strip has dropped the page: titles are stored by position.
	local bench = self
	local timer = iup.timer({ TIME = "10" })
	function timer:action_cb()
		self.run = "NO"
		iup.Destroy(self)
		pcall(function()
			bench:_syncTitles()
			if #bench._docs == 0 then bench._set_empty(true) end
			bench:_activated(bench:_current())
		end)
		return iup.DEFAULT
	end
	timer.run = "YES"
	return true
end

--- Turn editing on or off for the file in front.
function Workbench:toggleEdit()
	local doc = self:_current()
	if not (doc and doc.writable) then return end
	doc.view:setReadOnly(not doc.view:isReadOnly())
	self:_activated(doc)
	doc.view:focus()
end

--- Save the file in front (or `doc`).
-- @treturn boolean
function Workbench:save(doc)
	doc = doc or self:_current()
	if not doc or doc.view:isReadOnly() then return false end
	local file, err = io.open(doc.path, "wb")
	if not file then
		self._iup.Message("Couldn't save", "Couldn't save " .. doc.path .. ": " .. tostring(err))
		return false
	end
	file:write(doc.view:text())
	file:close()
	doc.view:markSaved()
	doc.binder:saved()
	self:_syncTitles()
	if self:_current() == doc then self:_activated(doc) end
	self:_setStatus("Saved " .. (Workbench.splitPath(doc.path)))
	return true
end

-- Keys the code view and the binder left alone.
function Workbench:_key(key)
	local iup = self._iup
	if key == iup.K_cS then
		self:save()
		return true
	elseif key == iup.K_mLEFT then
		self:back()
		return true
	elseif key == iup.K_mRIGHT then
		self:forward()
		return true
	end
	return false
end

-- ---------------------------------------------------------------------------
-- History and definitions
-- ---------------------------------------------------------------------------

function Workbench:_remember(path, line)
	-- Leaving a place records where the caret really was, so Back returns there.
	local here = self._history[self._history_at]
	if here and here.path == path and here.line == line then return end
	for i = #self._history, self._history_at + 1, -1 do self._history[i] = nil end
	self._history[#self._history + 1] = { path = path, line = line or 0 }
	if #self._history > Workbench.HISTORY then table.remove(self._history, 1) end
	self._history_at = #self._history
end

function Workbench:_jump(delta)
	local target = self._history[self._history_at + delta]
	if not target then return false end
	self._history_at = self._history_at + delta
	local ok, err = self:open(target.path, { line = target.line, history = false })
	if not ok then self:_setStatus(err) end
	return ok == true
end

--- Go back to where the caret was before the last jump.
function Workbench:back() return self:_jump(-1) end
--- Undo a `back`.
function Workbench:forward() return self:_jump(1) end

-- Follow a definition: one place opens; several are offered in the command bar.
function Workbench:_navigate(locations)
	local usable = {}
	for _, location in ipairs(locations) do
		if location.path then usable[#usable + 1] = location end
	end
	if #usable == 0 then return self:_setStatus("The definition is not in a file Lunar can open.") end
	-- Where the jump started, so Back has somewhere to return to.
	local doc = self:_current()
	if doc then
		local line = doc.view:caret()
		local here = self._history[self._history_at]
		if here and here.path == doc.path then here.line = line else self:_remember(doc.path, line) end
	end
	local function go(location)
		local ok, err = self:open(location.path, {
			line = location.line, character = location.character,
			end_line = location.end_line, end_character = location.end_character, encoding = location.encoding,
		})
		if not ok then self:_setStatus(err) end
	end
	if #usable == 1 or not self._palette then return go(usable[1]) end
	local items = {}
	for i, location in ipairs(usable) do
		local name, folder = Workbench.splitPath(location.path)
		items[i] = {
			id = "definition." .. i, title = string.format("%s:%d", name, location.line + 1), category = folder,
			run = function()
				go(location)
				return true
			end,
		}
	end
	self._palette:open("", { items = items, placeholder = "Choose a definition", hint = "Enter to open   Esc to close" })
end

-- ---------------------------------------------------------------------------
-- Problems
-- ---------------------------------------------------------------------------

--- Show the Problems tab, creating it the first time.
function Workbench:showProblems()
	if not self._problems then
		local bench = self
		self._problems = ProblemsPanel.new({
			iup = self._iup, diagnostics = self._diagnostics,
			on_open = function(entry)
				local path = Uri.toPath(entry.uri)
				if not path then return bench:_setStatus("That problem is not in a file Lunar can open.") end
				local doc = bench:_find(path)
				local encoding = doc and doc.binder:client() and doc.binder:client().documents:encoding()
				local ok, err = bench:open(path, {
					line = entry.line, character = entry.character,
					end_line = entry.end_line, end_character = entry.end_character, encoding = encoding,
				})
				if not ok then bench:_setStatus(err) end
			end,
			idle_hint = function() return bench:_serverSummary() end,
		})
		local page = self:_addHostTab("problems", "Problems", "warning--alt--filled", self._problems:widget())
		-- Its home is under the work, where a problems list sits in an editor.
		-- Only when it has not been placed before, and never at the cost of the page.
		if self._panes then pcall(self._panes.move, self._panes, page, "bottom") end
	end
	self._problems:refresh()
	self:_reveal(self._problems:widget())
end

-- One sentence on what the language servers are doing, for the empty Problems list.
function Workbench:_serverSummary()
	if not self._registry then return "Language servers are unavailable in this build." end
	local servers = self._registry:servers()
	if #servers == 0 then return "No language server extensions are installed." end
	local running, missing = {}, {}
	for _, entry in ipairs(servers) do
		local state = self._registry:status(entry.id)
		if state == "running" or state == "starting" then
			running[#running + 1] = entry.name
		elseif state == "unavailable" or state == "failed" then
			missing[#missing + 1] = entry.name
		end
	end
	if #missing > 0 then
		return "Not running: " .. table.concat(missing, ", ") .. ". See Settings > Language servers."
	end
	if #running > 0 then return "Checking: " .. table.concat(running, ", ") .. "." end
	return "Errors and warnings appear here when a file is open in the Code tab."
end

-- The count in the status bar: errors and warnings, clickable, quiet when clean.
function Workbench:_countsChanged()
	local iup, host = self._iup, self._host
	local counts = self._diagnostics:counts()
	if not self._count then
		if counts.total == 0 then return end   -- nothing to say yet: stay out of the bar
		local bench = self
		self._count = iup.flatlabel({
			TITLE = "", THEMEROLE = "statusbar_text", IMAGEPOSITION = "LEFT", SPACING = "6",
			ALIGNMENT = "ALEFT:ACENTER",
		})
		host:addStatusElement(self._count, {
			persistent = true, padding = "4x0",
			on_click = function() bench:showProblems() end,
		})
	end
	local kind, text = "ok", "No problems"
	if counts.error > 0 then
		kind, text = "error", tostring(counts.error) .. (counts.warning > 0 and ("  +" .. counts.warning) or "")
	elseif counts.warning > 0 then
		kind, text = "warning", tostring(counts.warning)
	elseif counts.total > 0 then
		kind, text = "info", tostring(counts.total)
	end
	pcall(function()
		local status = Kit.STATUS[kind]
		Kit.bindIcon(iup, self._count, status.icon, { size = Kit.ICON_STATUS, role = status.role })
		iup.SetAttribute(self._count, "TITLE", text)
		iup.SetAttribute(self._count, "TIP", Diagnostics.summary(counts) .. "\nClick to show Problems.")
		iup.Refresh(self._count)
	end)
end

function Workbench:_serversChanged()
	for _, doc in ipairs(self._docs) do
		if doc.binder then pcall(doc.binder.refreshStatus, doc.binder) end
	end
	if self._problems then self._problems:schedule() end
	-- The set of servers may have changed (an extension reload): bring Settings
	-- up to date once the registrations have settled.
	local bench, iup = self, self._iup
	if not self._settings_timer then
		self._settings_timer = iup.timer({ TIME = "300", RUN = "NO" })
		function self._settings_timer:action_cb()
			self.run = "NO"
			pcall(bench.refreshSettings, bench)
			return iup.DEFAULT
		end
	end
	self._settings_timer.run = "NO"
	self._settings_timer.run = "YES"
end

-- ---------------------------------------------------------------------------
-- Addresses and commands
-- ---------------------------------------------------------------------------

-- lunar://code/open?path=...&line=...&column=...  and  lunar://code/problems
function Workbench:_route(route)
	if route.target == "open" then
		local params = route.params or {}
		local at = {}
		if params.line then at.line, at.column = Workbench.index(params.line), Workbench.index(params.column) end
		local ok, err = self:open(params.path, at)
		if not ok then return nil, { code = "route_unavailable", message = err } end
		return true, route
	elseif route.target == "problems" then
		self:showProblems()
		return true, route
	end
	return nil, { code = "unknown_route", message = "Unknown code address: " .. tostring(route.target) }
end

--- Ask for a file and open it.
function Workbench:chooseFile()
	local iup = self._iup
	local dialog = iup.filedlg({
		DIALOGTYPE = "OPEN", TITLE = "Open File", PARENTDIALOG = self._dialog,
		EXTFILTER = "Source files|*.lua;*.c;*.h;*.cpp;*.hpp;*.cc;*.py;*.cs;*.json|All files|*.*|",
	})
	iup.Popup(dialog, iup.CENTERPARENT, iup.CENTERPARENT)
	local status, path = iup.GetAttribute(dialog, "STATUS"), iup.GetAttribute(dialog, "VALUE")
	iup.Destroy(dialog)
	if status == "-1" or not path then return end
	local ok, err = self:open(path)
	if not ok then iup.Message("Open File", err) end
end

--- Restart every language server that has a file open.
function Workbench:restartServers()
	if not self._registry then return end
	local count = 0
	for _, client in ipairs(self._registry:clients()) do
		if client.documents:count() > 0 then
			client:stop("restart")
			client:start()
			count = count + 1
		end
	end
	self:_setStatus(count > 0 and "Restarting language servers" or "No language server is in use")
end

function Workbench:_registerCommands()
	local commands = self._commands
	if not commands then return end
	local bench = self
	local function add(id, title, keywords, run, extra)
		local spec = { id = "host.code." .. id, title = title, keywords = keywords, group = "Code",
			run = function()
				run()
				return true
			end }
		for k, v in pairs(extra or {}) do spec[k] = v end
		commands:register(spec)
	end
	add("open", "Open File", "source code editor view", function() bench:chooseFile() end)
	add("problems", "Show Problems", "errors warnings diagnostics", function() bench:showProblems() end)
	add("definition", "Go to Definition", "f12 jump symbol", function()
		local doc = bench:_current()
		if doc then doc.binder:definition() end
	end, { shortcut = "F12", when = function() return bench:_current() ~= nil end })
	add("back", "Go Back", "previous location", function() bench:back() end,
		{ shortcut = "Alt+Left", when = function() return bench._history_at > 1 end })
	add("restart", "Restart Language Servers", "lsp reload", function() bench:restartServers() end,
		{ when = function() return bench._registry ~= nil end })
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

--- Add (or rebuild) the Language servers section in Settings: one row per
-- registered server, saying whether it was found and letting the user point at
-- one. Call after extensions have loaded.
function Workbench:refreshSettings()
	local host, iup, registry = self._host, self._iup, self._registry
	if not (registry and host._settings_view) then return end
	local servers = registry:servers()
	local signature = {}
	for i, entry in ipairs(servers) do signature[i] = entry.id end
	signature = table.concat(signature, ",")
	if signature == self._settings_signature then return end
	if self._settings_section then
		pcall(host._settings_view.removeSection, host._settings_view, self._settings_section)
		self._settings_section = nil
	end
	self._settings_signature = signature
	if #servers == 0 then return end

	local FlatField = require("core.ui.FlatField")
	local settings = self._settings
	local entries = {}
	for _, entry in ipairs(servers) do
		local key = Languages.pathSetting(entry.id)
		local command, why = registry:probe(entry.id)
		local found = command and ("Found: " .. tostring(command.argv[1]))
			or tostring(why or "Not found.")
		local field = FlatField.new(iup, {
			value = settings and settings:get(key) or "",
			cue = "Found automatically",
			on_change = function(text)
				if not settings then return end
				settings:set(key, text ~= "" and text or nil)
				settings:save()
			end,
		})
		entries[#entries + 1] = {
			label = entry.name,
			description = found .. " To use another copy, enter the full path of the server program.",
			widget = field.widget,
		}
	end
	self._settings_section = host._settings_view:addSection("Language servers", { entries = entries, icon = "code" },
		host._shown)
	if host._shown and self._settings_section and self._settings_section.widgets then
		for _, widget in ipairs(self._settings_section.widgets) do self._theme(widget) end
	end
end

return Workbench

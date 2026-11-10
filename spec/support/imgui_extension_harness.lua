local Runtime = require("core.imgui.Runtime")
local Null = require("core.imgui.backend.Null")
local iup = require("core.imgui.iup")
local Element = require("core.imgui.Element")
local HostAPI = require("core.classes.HostAPI")
local ExtensionManager = require("core.classes.ExtensionManager")
local Manifest = require("core.lib.ExtensionManifest")
local SettingsView = require("core.ui.SettingsView")

local M = {}

local function no_op() end

local function fake_settings()
	return {
		get = function() return nil end,
		set = no_op,
		save = no_op,
		getConfigDir = function() return "." end,
	}
end

local function flat_field_fallback()
	return {
		new = function(_, opts)
			opts = opts or {}
			local text = iup.text{ VALUE = opts.value or "", CUEBANNER = opts.cue }
			return {
				text = text,
				widget = iup.flatframe{ text, EXPAND = "HORIZONTAL" },
				value = function(self) return iup.GetAttribute(self.text, "VALUE") or "" end,
				setValue = function(self, value) iup.SetAttribute(self.text, "VALUE", value or "") end,
			}
		end,
	}
end

local function fake_db()
	local db = {}
	local function stmt()
		return {
			reset = no_op, bind = no_op, finalize = no_op,
			step = function() return false end,
		}
	end
	function db:migrate(version, fn) return fn(self, 0), self end
	function db:exec() return true end
	function db:prepare() return stmt() end
	function db:transaction(fn) return fn(self) end
	function db:rows() return function() return nil end end
	function db:query() return function() return nil end end
	function db:close() end
	return db
end

local function append_menu_item(menu, title)
	local item = iup.item{ TITLE = title }
	iup.Append(menu, item)
	return item
end

local function make_host(messages)
	local tabs = iup.flattabs{}
	local ext_menu = iup.menu{}
	local file_menu = iup.menu{}
	local help_menu = iup.menu{}
	local settings = fake_settings()
	local settings_view = SettingsView:new({ iup = iup, settings = settings })
	local status_box = iup.hbox{}
	local exit_item = append_menu_item(file_menu, "Exit")
	local about_item = append_menu_item(help_menu, "About")
	local host = HostAPI:new({
		iup = iup,
		mode = "gui",
		app = { title = "Lunar", version = "test", dir = "." },
		settings = settings,
		tabs = tabs,
		ext_menu = ext_menu,
		file_menu = file_menu,
		file_exit = exit_item,
		help_menu = help_menu,
		help_about = about_item,
		settings_view = settings_view,
		status_box = status_box,
		subprocess = {
			terminate = no_op, destroy = no_op,
			spawn = function() return nil, "test" end,
		},
		set_status = function(message) messages[#messages + 1] = tostring(message) end,
		notify = no_op,
	})
	host._dock_slot = iup.vbox{ EXPAND = "HORIZONTAL" }
	host.ui.FlatField = flat_field_fallback()
	host:addTab("Settings", settings_view:widget(), nil)
	host:registerHostTab("settings", settings_view:widget())
	return host, tabs, { ext_menu, file_menu, help_menu }, settings_view, host._dock_slot
end

local function walk(el, out)
	local st = Element.state(el)
	if not st then return end
	out[#out + 1] = el
	for _, child in ipairs(st.children) do walk(child, out) end
end

local function children(el)
	local st = Element.state(el)
	return st and st.children or {}
end

local function callback_names(el)
	local st = Element.state(el)
	local names = {}
	if not st then return names end
	for name in pairs(st.cbs or {}) do
		names[#names + 1] = name
	end
	table.sort(names)
	return names
end

local function click(el, backend)
	local st = Element.state(el)
	if not st or st.w <= 2 or st.h <= 2 then return false end
	backend.queue{ mx = st.x + st.w / 2, my = st.y + st.h / 2, press = 1 }
	backend.queue{ mx = st.x + st.w / 2, my = st.y + st.h / 2, release = 1 }
	Runtime.frame()
	Runtime.frame()
	return true
end

local function open_pages(root, backend, seen)
	local st = Element.state(root)
	if not st then return 0 end
	local opened = 0
	if st.classname == "flattabs" then
		for i = 1, #st.children do
			iup.SetAttribute(root, "VALUEPOS", tostring(i - 1))
			Runtime.frame()
			opened = opened + 1
		end
	end
	for _, child in ipairs(st.children) do
		opened = opened + open_pages(child, backend, seen)
	end
	return opened
end

local function exercise_callbacks(root, backend, fired)
	local all = {}
	walk(root, all)
	local exercised = 0
	local clickable = {
		flatbutton = true, flattoggle = true, flatlist = true, flattabs = true,
		item = true, button = true, toggle = true, list = true,
	}
	for _, el in ipairs(all) do
		local st = Element.state(el)
		if clickable[st.classname] then
			for _, name in ipairs(callback_names(el)) do
			local key = tostring(st.id) .. ":" .. name
			if not fired[key] then
				fired[key] = true
				if click(el, backend) then exercised = exercised + 1 end
			end
		end
		end
	end
	return exercised
end

local function invoke_menu_callbacks(menus, fired)
	local invoked = 0
	for _, menu in ipairs(menus) do
		local all = {}
		walk(menu, all)
		for _, item in ipairs(all) do
			local st = Element.state(item)
			for _, name in ipairs(callback_names(item)) do
				local key = tostring(st.id) .. ":" .. name
				if not fired[key] then
					fired[key] = true
					local cb = st.cbs[name]
					local ok, err = pcall(cb, item)
					assert(ok, err)
					invoked = invoked + 1
				end
			end
		end
	end
	return invoked
end

local function invoke_routes(host)
	local invoked = 0
	for owner, handlers in pairs(host._route_handlers or {}) do
		local manifest = host._manifest_by_owner[owner]
		for action in pairs(handlers) do
			local ok, result = host:dispatchRoute("lunar://plugin/" .. manifest.id .. "/" .. action)
			local why = type(result) == "table" and result.message or "route failed"
			assert(ok, why)
			invoked = invoked + 1
		end
	end
	return invoked
end

local function assert_pages_are_not_empty(tabs)
	local all = {}
	walk(tabs, all)
	for _, page in ipairs(children(tabs)) do
		local st = Element.state(page)
		local content = 0
		for _, el in ipairs(all) do
			local es = Element.state(el)
			if es and es.parent == page and es.classname ~= "fill" then content = content + 1 end
		end
		assert(st.w > 0 and st.h > 0, "page has no laid-out size")
		assert(content > 0, "page is empty")
	end
end

function M.run(path, module_path, opts)
	opts = opts or {}
	Runtime.init(Null.new({ w = 1280, h = 800 }))
	local warnings = {}
	local old_warn = Runtime.warn
	local old_error = Element.hooks.error
	Runtime.warn = function(message)
		warnings[#warnings + 1] = tostring(message)
	end
	Element.hooks.error = function(el, name, err)
		warnings[#warnings + 1] = string.format("%s: %s", name, tostring(err))
	end

	local old_message, old_alarm, old_gettext, old_popup = iup.Message, iup.Alarm, iup.GetText, iup.Popup
	local messages = {}
	iup.Message = function(_, text) messages[#messages + 1] = tostring(text) end
	iup.Alarm = function() return 2 end
	iup.GetText = function() return nil end
	iup.Popup = function(widget)
		iup.Show(widget)
		iup.Hide(widget)
		return iup.DEFAULT
	end

	local host, tabs, menus, settings_view, dock_slot = make_host(messages)
	local dialog = iup.dialog{ iup.vbox{ tabs, dock_slot, EXPAND = "YES" },
		RASTERSIZE = "1280x800", TITLE = "ImGui extension smoke" }
	host:setDialog(dialog)
	local root = module_path or path:match("^(.*)[\\/][^\\/]+$") or "."
	local parent = root:match("^(.*)[\\/][^\\/]+$") or root
	local stem = path:match("([^\\/]+)%.lua$") or "extension"
	local manifest_path = root .. "/" .. (module_path and "manifest.json" or (stem .. ".manifest.json"))
	local expected = Manifest.load(manifest_path, { id = stem, name = stem })
	assert(expected, "manifest could not be loaded")
	local old_flat_field = package.loaded["core.ui.FlatField"]
	local old_logscan_preload, old_logscan_loaded = package.preload.logscan, package.loaded.logscan
	package.preload.logscan = function()
		return { scan_file = function() return {} end }
	end
	package.loaded.logscan = nil
	package.loaded["core.ui.FlatField"] = flat_field_fallback()
	local manager = ExtensionManager:new({ { dir = parent, source = "test" } })
	manager._discover = function()
		return { {
			path = path, dir = root, manifest_path = manifest_path,
			default_id = stem, default_name = stem,
			source = "test",
		} }
	end
	local loaded = manager:loadAll(host)
	package.loaded["core.ui.FlatField"] = old_flat_field
	package.preload.logscan = old_logscan_preload
	package.loaded.logscan = old_logscan_loaded
	host:_markShown()
	iup.Show(dialog)
	for _ = 1, 4 do Runtime.frame() end

	local has_gui = true
	for _, mode in ipairs(expected.modes or {}) do
		if mode == "gui" then has_gui = true; break end
		has_gui = false
	end
	if not has_gui then
		assert(loaded == 0, "headless-only extension loaded in the GUI host")
	else
		local skipped = {}
		for _, entry in ipairs(manager.skipped or {}) do
			skipped[#skipped + 1] = tostring(entry.id) .. ": " .. tostring(entry.reason)
		end
		assert(loaded == 1, "extension was not loaded by the real host; "
			.. table.concat(skipped, "; ") .. " " .. table.concat(messages, " | "))
	end

	local backend = Runtime.backend()
	local fired = {}
	local pages = open_pages(tabs, backend, fired)
	local clicked = exercise_callbacks(tabs, backend, fired)
	clicked = clicked + invoke_menu_callbacks(menus, fired)
	local routes = invoke_routes(host)
	for _ = 1, 3 do Runtime.frame() end
	assert_pages_are_not_empty(tabs)
	assert(pages >= 1, "host registered no pages")

	manager:shutdownAll()
	iup.Destroy(dialog)
	Runtime.warn = old_warn
	Element.hooks.error = old_error
	iup.Message, iup.Alarm, iup.GetText, iup.Popup = old_message, old_alarm, old_gettext, old_popup
	return loaded, clicked, warnings, routes, settings_view
end

return M

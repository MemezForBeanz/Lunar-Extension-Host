local Runtime = require("core.imgui.Runtime")
local Null = require("core.imgui.backend.Null")
local iup = require("core.imgui.iup")
local Element = require("core.imgui.Element")

local M = {}

local function no_op() end

local function fake_db()
	local db = {}
	local function stmt()
		return {
			reset = no_op, bind = no_op, finalize = no_op,
			step = function() return false end,
		}
	end
	function db:migrate(version, fn)
		return fn(self, 0), self
	end
	function db:exec() return true end
	function db:prepare() return stmt() end
	function db:transaction(fn) return fn(self) end
	function db:rows() return function() return nil end end
	function db:query() return function() return nil end end
	function db:close() end
	return db
end

function M.context()
	local tabs = {}
	local settings = {
		get = function() return nil end,
		set = no_op,
		save = no_op,
		getConfigDir = function() return "." end,
	}
	local ctx = {
		iup = iup,
		mode = "gui",
		app = { title = "Lunar", version = "test", dir = "." },
		settings = settings,
		tabs = tabs,
		ui = {
			FlatField = require("core.ui.FlatField"),
			FlatDropdown = require("core.ui.FlatDropdown"),
			ContextMenu = require("core.ui.ContextMenu"),
		},
		subprocess = {
			terminate = no_op, destroy = no_op, spawn = function() return nil, "test" end,
		},
	}
	function ctx:addTab(_, widget) tabs[#tabs + 1] = widget; return widget end
	function ctx:addStatusElement() end
	function ctx:addDock() return { setVisible = no_op } end
	function ctx:addMenuItem() end
	function ctx:addVersionInfo() end
	function ctx:registerFont() return false, "headless smoke" end
	function ctx:registerTheme() return true end
	function ctx:addSettings() end
	function ctx:addTimer(opts)
		return iup.timer{ TIME = tostring(opts.time or 0), RUN = opts.run and "YES" or "NO",
			action = opts.action }
	end
	function ctx:onReady() end
	function ctx:onTabChange() end
	function ctx:onWindow() end
	function ctx:fitPage() end
	function ctx:notify() end
	function ctx:notifyTreeChange() end
	function ctx:focusTab() end
	function ctx:dispatchAddress() end
	function ctx:registerRouteHandler() end
	function ctx:localService() return nil end
	function ctx:controlLocalService(_, action)
		if action then return true end
		return { running = false }
	end
	function ctx:isStopping() return false end
	function ctx:getSecret() return nil end
	function ctx:setSecret() return true end
	function ctx:deleteSecret() return true end
	function ctx:http(_, done) if done then done({ ok = false, status = 503 }) end end
	function ctx:spawn() return nil, "test" end
	function ctx:dataDir() return "." end
	function ctx:openDatabase() return fake_db() end
	function ctx:addRoute() return {} end
	function ctx:fileResponse() return nil, "test" end
	function ctx:animate(spec)
		if spec.on_frame then spec.on_frame(spec.to or spec.value) end
		if spec.on_done then spec.on_done(true) end
		return { cancel = no_op, finish = no_op }
	end
	function ctx:getLogger()
		return { info = no_op, warn = no_op, error = no_op, debug = no_op }
	end
	return setmetatable(ctx, { __index = function() return no_op end })
end

local function walk(el, out)
	local st = Element.state(el)
	if not st then return end
	out[#out + 1] = el
	for _, child in ipairs(st.children) do walk(child, out) end
end

function M.exercise(ctx)
	local root = iup.vbox(ctx.tabs)
	local dialog = iup.dialog{ root, RASTERSIZE = "960x640", TITLE = "ImGui extension smoke" }
	iup.Show(dialog)
	for _ = 1, 3 do Runtime.frame() end

	local all = {}
	walk(root, all)
	local clicked = 0
	for _, el in ipairs(all) do
		local st = Element.state(el)
		if st and st.classname == "flatbutton" and st.w > 2 and st.h > 2 and clicked < 3 then
			local x, y = st.x + st.w / 2, st.y + st.h / 2
			local b = Runtime.backend()
			b.queue{ mx = x, my = y, press = 1 }
			b.queue{ mx = x, my = y, release = 1 }
			Runtime.frame()
			Runtime.frame()
			clicked = clicked + 1
		end
	end
	iup.Destroy(dialog)
	return #ctx.tabs, clicked
end

function M.load(path, module_path)
	local old_global, old_loaded, old_path = _G.iup, package.loaded.iup, package.path
	_G.iup, package.loaded.iup = iup, iup
	if module_path then package.path = module_path .. "/?.lua;" .. old_path end
	local ok, value = pcall(function() return assert(loadfile(path))() end)
	package.path = old_path
	_G.iup, package.loaded.iup = old_global, old_loaded
	if not ok then error(value, 0) end
	return value
end

function M.run(path, module_path)
	Runtime.init(Null.new())
	local warnings = {}
	local old_warn = Runtime.warn
	Runtime.warn = function(message) warnings[#warnings + 1] = tostring(message) end
	local ctx = M.context()
	local old_path = package.path
	local old_logscan = package.preload.logscan
	package.preload.logscan = package.preload.logscan or function()
		return { scan_file = function() return {} end }
	end
	if module_path then package.path = module_path .. "/?.lua;" .. old_path end
	local extension = M.load(path)
	extension._ctx = ctx
	extension._iup = iup
	extension.dir = module_path or "."
	local ok, err = pcall(extension.register, extension, ctx)
	package.path = old_path
	package.preload.logscan = old_logscan
	assert(ok, err)
	local count, clicked = M.exercise(ctx)
	Runtime.warn = old_warn
	return count, clicked, warnings
end

return M

--- Entry point of the installer, run by the packages' `setup.lua` / `uninstall.lua`
-- through the Lunar executable (`lunar setup/setup.lua`, `Lunar.exe setup.lua`).
-- That is why it is a script for the host rather than a flag on the application: the
-- executable already runs any `.lua` path it is given in place of the app (see
-- `src/c/core/main.c`), with the same IUP, FFI and embedded Lua tree.
--
-- Command line (all optional): see `installer.plan.parse_args`.
--
-- @module installer.main

local lfs = require("lfs")
local plan_mod = require("installer.plan")
local platform = require("core.platform")

local M = {}

local function dirname(p) return p:match("^(.*)[/\\][^/\\]*$") or "." end

local function absolute(path)
	if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then return path end
	return lfs.currentdir() .. "/" .. path
end

local function say(...) io.stdout:write(table.concat({ ... }, " "), "\n") io.stdout:flush() end

local function fail(iup, opts, message)
	io.stderr:write("setup: ", message, "\n")
	if not opts.quiet and iup then pcall(iup.Message, "Lunar Setup", message) end
	return 1
end

-- Finish a quiet run: report the result and map it to an exit code.
local function report(r)
	say(r.status .. ": " .. tostring(r.message))
	if r.detail then say(r.detail) end
	if r.status == "ok" then return 0 end
	if r.status == "reboot" then return 3010 end
	if r.status == "cancelled" then return 1602 end
	return 1
end

--- Run the installer.
-- @tparam table argv command line (`arg[1..]`).
-- @tparam string script path of the running `setup.lua` / `uninstall.lua`.
-- @tparam[opt] table iup the IUP binding (nil for a quiet run in tests).
-- @treturn number exit code
function M.run(argv, script, iup)
	local opts, err = plan_mod.parse_args(argv)
	if not opts then return fail(iup, { quiet = true }, err) end
	local backend_mod = require("installer.backend")
	local ui = (not opts.quiet) and require("installer.ui") or nil
	script = absolute(script)

	local backend
	if platform.is_windows then
		if opts.uninstall then return fail(iup, opts, "Uninstall Lunar from Settings > Apps (or with msiexec /x).") end
		backend, err = backend_mod.windows_install({ dir = platform.exe_dir() })
	else
		local setup_dir = dirname(script)
		local payload = dirname(setup_dir)
		if opts.uninstall then
			local linux = require("installer.linux")
			local rec = plan_mod.read_json(payload .. "/" .. linux.RECORD)
			if type(rec) ~= "table" or type(rec.targets) ~= "table" or rec.targets.app ~= payload then
				return fail(iup, opts, "No Lunar install record found in " .. payload .. ".")
			end
			backend = backend_mod.linux_uninstall({ record = rec, setup_dir = setup_dir, root = opts.root })
		else
			backend, err = backend_mod.linux_install({ payload = payload, root = opts.root, home = opts.home })
		end
	end
	if not backend then return fail(iup, opts, tostring(err)) end

	if opts.quiet then
		local choices = { type = opts.type or backend.default_type, ids = {} }
		local exts = backend.extensions or {}
		local picked, unknown = plan_mod.select(exts, opts.extensions == nil and "all" or opts.extensions)
		if #unknown > 0 then return fail(iup, opts, "no such extension: " .. table.concat(unknown, ", ")) end
		for _, e in ipairs(picked) do choices.ids[#choices.ids + 1] = e.id end
		local job, serr = backend.start(choices)
		if not job then
			if serr == "cancelled" then return report({ status = "cancelled", message = "Administrator permission was not given." }) end
			return fail(iup, opts, tostring(serr))
		end
		return report(backend_mod.run_blocking(job))
	end

	if opts.type then backend.default_type = opts.type end
	ui.run(backend, iup)
	return 0
end

return M

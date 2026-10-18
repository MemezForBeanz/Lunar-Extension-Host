-- spec/support/installer_payload.lua — a fake installer payload on disk, and helpers
-- to look at what an install did.

local lfs = require("lfs")
local sandbox = require("spec.support.config_sandbox")

local M = {}

function M.write(path, text)
	local dir = path:match("^(.*)/[^/]*$")
	assert(require("core.platform").mkdirs(dir))
	local f = assert(io.open(path, "wb"))
	f:write(text or "")
	f:close()
end

function M.read(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local t = f:read("*a")
	f:close()
	return t
end

--- Remove a folder tree (links are removed, never followed).
function M.rmtree(path)
	local mode = lfs.symlinkattributes(path, "mode")
	if mode == "directory" then
		for name in lfs.dir(path) do
			if name ~= "." and name ~= ".." then M.rmtree(path .. "/" .. name) end
		end
		lfs.rmdir(path)
	elseif mode then
		os.remove(path)
	end
end

--- Every path (relative, sorted; folders end in "/") under `root`.
function M.listing(root)
	local out = {}
	local function walk(rel)
		local full = rel == "" and root or (root .. "/" .. rel)
		for name in lfs.dir(full) do
			if name ~= "." and name ~= ".." then
				local r = rel == "" and name or (rel .. "/" .. name)
				local mode = lfs.symlinkattributes(root .. "/" .. r, "mode")
				if mode == "directory" then
					out[#out + 1] = r .. "/"
					walk(r)
				else
					out[#out + 1] = r
				end
			end
		end
	end
	if lfs.attributes(root, "mode") == "directory" then walk("") end
	table.sort(out)
	return out
end

function M.manifest(id, name, extra)
	local t = { '"schema_version": 1', '"id": "' .. id .. '"', '"name": "' .. name .. '"', '"version": "1.2"',
		'"description": "The ' .. name .. ' extension."' }
	for _, e in ipairs(extra or {}) do t[#t + 1] = e end
	return "{" .. table.concat(t, ",") .. "}"
end

--- A payload: the app folder (lunar, assets, certs, plugins) and setup/.
-- Extensions: alpha (folder), beta (single file with manifest), gamma (folder,
-- Windows only), delta (bad manifest), plus a README and a non-extension folder.
-- @treturn string the payload folder
function M.new(opts)
	opts = opts or {}
	local root = sandbox.new_root("installer_payload")
	M.write(root .. "/lunar", "#!/bin/sh\necho lunar\n")
	M.write(root .. "/assets/theme.json", "{}")
	M.write(root .. "/assets/img/logo.png", "png")
	M.write(root .. "/certs/ca.pem", "pem")
	M.write(root .. "/plugins/README.md", "docs")
	M.write(root .. "/plugins/alpha/init.lua", "return {}")
	M.write(root .. "/plugins/alpha/manifest.json", M.manifest("alpha", "Alpha Tools"))
	M.write(root .. "/plugins/alpha/sub/more.lua", "return 1")
	M.write(root .. "/plugins/beta.lua", "return {}")
	M.write(root .. "/plugins/beta.manifest.json", M.manifest("beta", "Beta Viewer"))
	M.write(root .. "/plugins/gamma/init.lua", "return {}")
	M.write(root .. "/plugins/gamma/manifest.json",
		M.manifest("gamma", "Gamma Win", { '"schema_version": 2', '"platforms": ["windows"]' }):gsub('"schema_version": 1,', ""))
	M.write(root .. "/plugins/delta/init.lua", "return {}")
	M.write(root .. "/plugins/delta/manifest.json", "{ not json")
	M.write(root .. "/plugins/shared/util.lua", "return {}")
	M.write(root .. "/setup/lunar-cli", "cli")
	M.write(root .. "/setup/root_helper.lua", "-- helper")
	M.write(root .. "/setup/uninstall.lua", "-- uninstall")
	M.write(root .. "/setup/setup.lua", "-- setup")
	M.write(root .. "/setup/LICENSE", "MIT")
	M.write(root .. "/setup/payload.json", '{"version":"' .. (opts.version or "1.0.0") .. '"}')
	M.write(root .. "/setup/lunar.desktop",
		"[Desktop Entry]\nType=Application\nName=Lunar\nExec=lunar\nIcon=lunar\nTerminal=false\n")
	M.write(root .. "/setup/lua/installer/plan.lua", "return {}")
	for _, s in ipairs({ 16, 24, 32, 48, 64, 128, 256 }) do M.write(root .. "/setup/icons/lunar-" .. s .. ".png", "png" .. s) end
	return root
end

return M

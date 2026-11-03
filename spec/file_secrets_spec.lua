local FileSecrets = require("core.lib.FileSecrets")

-- A fake filesystem: path -> { mode, uid, permissions, data, link }.
local function store(fs)
	return FileSecrets.new("/etc/lunar/secrets", {
		attrs = function(p)
			local e = fs[p]
			if not e or e.link then return e and { mode = "file", uid = 0, permissions = "rw-r-----" } end
			return { mode = e.mode, uid = e.uid or 0, permissions = e.permissions }
		end,
		link_mode = function(p) return fs[p] and fs[p].link and "link" or (fs[p] and fs[p].mode) end,
		read = function(p) return fs[p] and fs[p].data end,
	})
end

local function good()
	return {
		["/etc/lunar/secrets"] = { mode = "directory", permissions = "rwxr-xr-x" },
		["/etc/lunar/secrets/blackduck"] = { mode = "directory", permissions = "rwxr-x---" },
		["/etc/lunar/secrets/blackduck/BDBA_TOKEN"] = { mode = "file", permissions = "rw-r-----", data = "abc123\n" },
	}
end

local T = "Lunar Extension Host/blackduck/BDBA_TOKEN"

describe("core.lib.FileSecrets", function()
	it("reads a provisioned secret and strips one trailing newline", function()
		assert.are.equal("abc123", store(good()).secret_get(T))
	end)

	it("says not found for a missing extension folder, file or empty value", function()
		local fs = good()
		assert.are.same({ nil, "not found" }, { store(fs).secret_get("Lunar Extension Host/other/X") })
		assert.are.same({ nil, "not found" }, { store(fs).secret_get("Lunar Extension Host/blackduck/NOPE") })
		fs["/etc/lunar/secrets/blackduck/BDBA_TOKEN"].data = "\n"
		assert.are.same({ nil, "not found" }, { store(fs).secret_get(T) })
	end)

	it("refuses anything the service account (or anyone but root) could replace", function()
		local cases = {
			{ "/etc/lunar/secrets/blackduck/BDBA_TOKEN", { uid = 984 }, "not root" },
			{ "/etc/lunar/secrets/blackduck/BDBA_TOKEN", { permissions = "rw-rw----" }, "its group can modify it" },
			{ "/etc/lunar/secrets/blackduck/BDBA_TOKEN", { permissions = "rw-r--r--" }, "anyone can read it" },
			{ "/etc/lunar/secrets/blackduck/BDBA_TOKEN", { link = true }, "is a symlink" },
			{ "/etc/lunar/secrets/blackduck", { permissions = "rwxrwx---" }, "its group can modify it" },
			{ "/etc/lunar/secrets/blackduck", { link = true }, "is a symlink" },
			{ "/etc/lunar/secrets", { permissions = "rwxr-xrwx" }, "anyone can modify it" },
			{ "/etc/lunar/secrets", { uid = 1000 }, "not root" },
		}
		for _, c in ipairs(cases) do
			local fs = good()
			for k, v in pairs(c[2]) do fs[c[1]][k] = v end
			local v, err = store(fs).secret_get(T)
			assert.is_nil(v, c[1])
			assert.truthy(err:find(c[3], 1, true), c[1] .. ": " .. tostring(err))
		end
	end)

	it("refuses a missing store folder with the reason", function()
		local fs = good()
		fs["/etc/lunar/secrets"] = nil
		local v, err = store(fs).secret_get(T)
		assert.is_nil(v)
		assert.truthy(err:find("secret store", 1, true))
	end)

	it("rejects malformed targets", function()
		local s = store(good())
		for _, t in ipairs({ "x", "Lunar Extension Host/blackduck", "Lunar Extension Host/../BDBA_TOKEN/x",
			"Lunar Extension Host/a/b/c", "Lunar Extension Host/blackduck/.." }) do
			assert.are.same({ nil, "bad target" }, { s.secret_get(t) }, t)
		end
	end)

	it("is read-only", function()
		local s = store(good())
		local ok, err = s.secret_set(T, "new")
		assert.is_nil(ok)
		assert.truthy(err:find("read-only", 1, true))
		assert.is_nil((s.secret_delete(T)))
	end)

	it("refuses an oversized secret", function()
		local fs = good()
		fs["/etc/lunar/secrets/blackduck/BDBA_TOKEN"].data = string.rep("x", 65537)
		local v, err = store(fs).secret_get(T)
		assert.is_nil(v)
		assert.truthy(err:find("64 KiB", 1, true))
	end)
end)

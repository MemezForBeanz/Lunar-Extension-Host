local cjson = require("cjson")
local OrgProfile = require("core.lib.OrgProfile")

local SEP = package.config:sub(1, 1)
local function P(...) return table.concat({ ... }, SEP) end

-- In-memory filesystem: `files` maps full paths to contents; folders are implied.
local function fake_fs(files)
	return {
		read = function(path) return files[path] end,
		exists = function(path) return files[path] ~= nil end,
		dirs = function(root)
			local seen, out = {}, {}
			for path in pairs(files) do
				local rest = path:sub(#root + 2)
				if path:sub(1, #root + 1) == root .. SEP then
					local name = rest:match("^([^/\\]+)[/\\]")
					if name and not seen[name] then seen[name] = true; out[#out + 1] = name end
				end
			end
			table.sort(out)
			return out
		end,
	}
end

local TRUSTED = P("C:", "ProgramData", "Lunar Extension Host", "profiles")
local DEV = P("D:", "dev-profiles")

local function profile(t)
	local base = { schema = 1, id = "acme", name = "Acme Corp" }
	for k, v in pairs(t or {}) do base[k] = v end
	return cjson.encode(base)
end

local function resolve(files, opts)
	opts = opts or {}
	opts.fs = fake_fs(files)
	opts.roots = opts.roots or { { dir = TRUSTED, trusted = true }, { dir = DEV, trusted = false } }
	opts.env = opts.env or function() return nil end
	-- Never fall through to the real machine's domain.
	if opts.domain == nil then opts.domain = "" end
	return OrgProfile.resolve(opts)
end

describe("OrgProfile.validate", function()
	local fs = fake_fs({ [P("X", "acme", "logo.svg")] = "<svg/>" })

	it("builds a profile from a complete pack", function()
		local p = assert(OrgProfile.validate(cjson.decode(profile({
			match = { domains = { "Acme.example", ".acme.local" } },
			brand = { logo = "logo.svg" },
			tool_group = "Acme Tools",
			settings = { backend_url = "https://lunar.acme.example", update_share = "" },
			locked = { "backend_url" },
		})), P("X", "acme"), { trusted = true, fs = fs, dir_name = "acme" }))

		assert.are.equal("acme", p.id)
		assert.are.same({ "acme.example", "acme.local" }, p.domains)
		assert.are.equal("Acme Tools", p.tool_group)
		assert.are.equal(P("X", "acme", "logo.svg"), p.brand.logo)
		assert.is_true(p.locked.backend_url)
	end)

	it("accepts a plain legacy_config_dir and warns about anything else", function()
		local p = assert(OrgProfile.validate(cjson.decode(profile({ legacy_config_dir = "Old Tool" })), "X", { fs = fs }))
		assert.are.equal("Old Tool", p.legacy_config_dir)
		for _, bad in ipairs({ "..", "a\\b", "../x", "C:x", "", 7 }) do
			local q = assert(OrgProfile.validate(cjson.decode(profile({ legacy_config_dir = bad })), "X", { fs = fs }))
			assert.is_nil(q.legacy_config_dir)
			assert.truthy(q.warnings[1]:find("legacy_config_dir", 1, true))
		end
	end)

	it("ignores locks from an untrusted profile but keeps its defaults", function()
		local p = assert(OrgProfile.validate(cjson.decode(profile({
			settings = { backend_url = "https://x" }, locked = { "backend_url" },
		})), "X", { trusted = false, fs = fs }))
		assert.are.equal("https://x", p.settings.backend_url)
		assert.is_nil(next(p.locked))
	end)

	it("rejects bad packs with a reason", function()
		local cases = {
			{ { schema = 2 }, "schema" },
			{ { id = "Bad Id" }, "id must" },

			{ { locked = { "nope" } }, "has no value" },
		}
		for _, case in ipairs(cases) do
			local p, err = OrgProfile.validate(cjson.decode(profile(case[1])), P("X", "acme"),
				{ trusted = true, fs = fs })
			assert.is_nil(p)
			assert.truthy(err:find(case[2], 1, true), "expected '" .. case[2] .. "' in: " .. tostring(err))
		end
	end)

	it("resolves pack: settings to files inside the pack, and only inside it", function()
		local p = assert(OrgProfile.validate(cjson.decode(profile({
			settings = { backend_ca_file = "pack:certs/backend.crt", plain = "pack" },
		})), P("X", "acme"), { fs = fs }))
		assert.are.equal(P("X", "acme", "certs", "backend.crt"), p.settings.backend_ca_file)
		assert.are.equal("pack", p.settings.plain)

		local bad, err = OrgProfile.validate(cjson.decode(profile({
			settings = { backend_ca_file = "pack:../../etc/evil" },
		})), P("X", "acme"), { fs = fs })
		assert.is_nil(bad)
		assert.truthy(err:find("inside the profile folder", 1, true))
	end)

	it("reads retired_defaults as sets, and only warns about bad entries", function()
		local p = assert(OrgProfile.validate(cjson.decode(profile({
			retired_defaults = { backend_url = { "https://old", "http://old" }, theme = "classic", n = { {} } },
		})), P("X", "acme"), { fs = fs }))
		assert.are.same({ ["https://old"] = true, ["http://old"] = true }, p.retired.backend_url)
		assert.is_nil(p.retired.theme)
		assert.is_nil(p.retired.n)
		assert.are.equal(2, #p.warnings)

		local q = assert(OrgProfile.validate(cjson.decode(profile({ retired_defaults = "nope" })),
			P("X", "acme"), { fs = fs }))
		assert.are.same({}, q.retired)
		assert.are.equal(1, #q.warnings)
	end)

	it("rejects a pack whose id doesn't match its folder", function()
		local p, err = OrgProfile.validate(cjson.decode(profile()), "X", { fs = fs, dir_name = "globex" })
		assert.is_nil(p)
		assert.truthy(err:find("does not match", 1, true))
	end)
end)

describe("OrgProfile.validate branding", function()
	local fs = fake_fs({})

	it("drops bad brand fields with a warning but keeps settings and locks", function()
		local cases = {
			{ { accent = "#EE2223" }, "no longer used" },
			{ { logo = "../outside.svg" }, "inside the profile folder" },
			{ { logo = "C:\\evil.svg" }, "inside the profile folder" },
			{ { logo = "missing.svg" }, "not found" },
			{ { product_name = "Acme Tools" }, "no longer used" },
		}
		for _, case in ipairs(cases) do
			local p = assert(OrgProfile.validate(cjson.decode(profile({
				brand = case[1], settings = { backend_url = "https://x" }, locked = { "backend_url" },
			})), P("X", "acme"), { trusted = true, fs = fs }))
			assert.is_nil(next(p.brand))
			assert.is_true(p.locked.backend_url)
			assert.truthy(p.warnings[1] and p.warnings[1]:find(case[2], 1, true),
				"expected '" .. case[2] .. "' in: " .. tostring(p.warnings[1]))
		end
	end)
end)

describe("OrgProfile.validate tool_group", function()
	local fs = fake_fs({})
	local function v(t) return assert(OrgProfile.validate(cjson.decode(profile(t)), "X", { fs = fs })) end

	it("defaults to the profile name", function()
		assert.are.equal("Acme Corp", v({}).tool_group)
	end)

	it("trims a given name and refuses slashes, control characters and long names", function()
		assert.are.equal("Globex Tools", v({ tool_group = "  Globex Tools " }).tool_group)
		for _, bad in ipairs({ "A/B", "A\\B", "   ", string.rep("x", 65), 3 }) do
			local p = v({ tool_group = bad })
			assert.are.equal("Acme Corp", p.tool_group)
			assert.truthy(p.warnings[1]:find("tool_group", 1, true))
		end
	end)

	it("falls back to the id when the name can't be a group", function()
		assert.are.equal("acme", v({ name = "Acme/Widgets" }).tool_group)
	end)
end)

describe("OrgProfile.resolve", function()
	local ACME = { match = { domains = { "acme.example" } } }

	it("runs neutral when no profile is installed", function()
		local p, info = resolve({})
		assert.is_nil(p)
		assert.are.equal("none", info.reason)
	end)

	it("selects by DNS domain on a label boundary only", function()
		local files = { [P(TRUSTED, "acme", "profile.json")] = profile(ACME) }
		local p, info = resolve(files, { domain = "AMER.ACME.EXAMPLE" })
		assert.are.equal("acme", p.id)
		assert.are.equal("domain", info.reason)

		assert.is_nil((resolve(files, { domain = "notacme.example" })))
	end)

	it("prefers an explicit policy assignment over the domain", function()
		local files = {
			[P(TRUSTED, "acme", "profile.json")] = profile(ACME),
			[P(TRUSTED, "globex", "profile.json")] = profile({ id = "globex", name = "Globex" }),
			[P(TRUSTED:match("^(.*)[/\\]"), "policy.json")] = cjson.encode({ profile = "globex" }),
		}
		local p, info = resolve(files, { domain = "acme.example" })
		assert.are.equal("globex", p.id)
		assert.are.equal("assigned", info.reason)
	end)

	it("runs neutral when the assigned profile is not installed", function()
		local files = { [P(TRUSTED:match("^(.*)[/\\]"), "policy.json")] = cjson.encode({ profile = "globex" }) }
		local p, info = resolve(files)
		assert.is_nil(p)
		assert.are.equal("assigned-missing", info.reason)
	end)

	it("refuses to guess between two profiles claiming the same domain", function()
		local files = {
			[P(TRUSTED, "acme", "profile.json")] = profile(ACME),
			[P(TRUSTED, "other", "profile.json")] = profile({ id = "other", name = "Other", match = ACME.match }),
		}
		local p, info = resolve(files, { domain = "acme.example" })
		assert.is_nil(p)
		assert.are.equal("ambiguous", info.reason)
	end)

	it("lets a trusted profile shadow a dev copy and never reads policy from the dev root", function()
		local files = {
			[P(TRUSTED, "acme", "profile.json")] = profile(ACME),
			[P(DEV, "acme", "profile.json")] = profile({ name = "Dev copy", match = ACME.match }),
			[P("D:", "policy.json")] = cjson.encode({ profile = "acme" }),
		}
		local p, info = resolve(files, { domain = "acme.example" })
		assert.are.equal("Acme Corp", p.name)
		assert.is_true(p.trusted)
		assert.are.equal("domain", info.reason)
	end)

	it("matches trusted profiles first, so a dev profile can't make the org ambiguous", function()
		local files = {
			[P(TRUSTED, "acme", "profile.json")] = profile(ACME),
			[P(DEV, "decoy", "profile.json")] = profile({ id = "decoy", name = "Decoy", match = ACME.match }),
		}
		local p, info = resolve(files, { domain = "acme.example" })
		assert.are.equal("acme", p.id)
		assert.are.equal("domain", info.reason)
	end)

	it("lets a dev build pick any profile by id, ahead of policy and domain", function()
		local files = {
			[P(TRUSTED, "acme", "profile.json")] = profile(ACME),
			[P(DEV, "globex", "profile.json")] = profile({ id = "globex", name = "Globex" }),
			[P(TRUSTED:match("^(.*)[/\\]"), "policy.json")] = cjson.encode({ profile = "acme" }),
		}
		local p, info = resolve(files, { domain = "acme.example", dev_select = "globex" })
		assert.are.equal("globex", p.id)
		assert.are.equal("dev-selected", info.reason)
		assert.is_false(p.trusted)
	end)

	it("only resolves a policy assignment to a trusted profile", function()
		local files = {
			[P(DEV, "globex", "profile.json")] = profile({ id = "globex", name = "Globex dev copy" }),
			[P(TRUSTED:match("^(.*)[/\\]"), "policy.json")] = cjson.encode({ profile = "globex" }),
		}
		local p, info = resolve(files)
		assert.is_nil(p)
		assert.are.equal("assigned-missing", info.reason)
	end)

	it("reports a profiles folder that can't be listed instead of failing", function()
		local fs = fake_fs({ [P(DEV, "acme", "profile.json")] = profile(ACME) })
		local dirs = fs.dirs
		fs.dirs = function(root)
			if root == TRUSTED then return {}, "permission denied" end
			return dirs(root)
		end
		local p, info = OrgProfile.resolve({
			fs = fs, domain = "acme.example", env = function() return nil end,
			roots = { { dir = TRUSTED, trusted = true }, { dir = DEV, trusted = false } },
		})
		assert.are.equal("acme", p.id)
		assert.truthy(info.errors[1]:find("permission denied", 1, true))
	end)

	it("never trusts a ProgramData taken from the environment", function()
		local roots = OrgProfile.roots({
			env = function(k) if k == "ProgramData" then return "C:\\Users\\me\\fake" end end,
			system_dir = "C:\\ProgramData\\Lunar Extension Host",
		})
		for _, root in ipairs(roots) do
			assert.is_nil(root.dir:find("fake", 1, true))
		end
	end)

	it("reports broken packs without failing the others", function()
		local files = {
			[P(TRUSTED, "acme", "profile.json")] = profile(ACME),
			[P(TRUSTED, "broken", "profile.json")] = "{ not json",
		}
		local p, info = resolve(files, { domain = "acme.example" })
		assert.are.equal("acme", p.id)
		assert.are.equal(1, #info.errors)
		assert.truthy(info.errors[1]:find("^broken: "))
	end)
end)

describe("OrgProfile.resolve admin-only check", function()
	local ACME = { match = { domains = { "acme.example" } } }
	local SYS = TRUSTED:match("^(.*)[/\\]")

	-- Every path is admin-only except the ones listed in `open`.
	local function resolve_secure(files, open, opts)
		opts = opts or {}
		local fs = fake_fs(files)
		local checked = {}
		fs.secure = function(path)
			checked[#checked + 1] = path
			if open[path] then return false, "Users can modify it" end
			return true
		end
		fs.is_dir = function(path)
			for f in pairs(files) do
				if f:sub(1, #path + 1) == path .. SEP then return true end
			end
			return false
		end
		-- Every file below `dir` plus the folders they imply, sorted.
		fs.walk = function(dir)
			local seen, out = {}, {}
			for f in pairs(files) do
				if f:sub(1, #dir + 1) == dir .. SEP then
					local p = f
					while #p > #dir and not seen[p] do
						seen[p] = true
						out[#out + 1] = p
						p = p:match("^(.*)[/\\][^/\\]+$")
					end
				end
			end
			table.sort(out)
			return out
		end
		opts.fs = fs
		opts.roots = { { dir = TRUSTED, trusted = true }, { dir = DEV, trusted = false } }
		opts.env = function() return nil end
		if opts.domain == nil then opts.domain = "" end
		local p, info = OrgProfile.resolve(opts)
		return p, info, checked
	end

	local function has_error(info, text)
		for _, e in ipairs(info.errors) do
			if e:find(text, 1, true) then return true end
		end
		return false
	end

	it("trusts a protected install", function()
		local files = {
			[P(TRUSTED, "acme", "profile.json")] = profile(ACME),
			[P(TRUSTED, "acme", "extensions", "x", "init.lua")] = "",
		}
		local p, info, checked = resolve_secure(files, {}, { domain = "acme.example" })
		assert.are.equal("acme", p.id)
		assert.is_true(p.trusted)
		assert.are.same({}, info.errors)
		assert.are.same({ SYS, TRUSTED, P(TRUSTED, "acme"),
			P(TRUSTED, "acme", "extensions"), P(TRUSTED, "acme", "extensions", "x"),
			P(TRUSTED, "acme", "extensions", "x", "init.lua"),
			P(TRUSTED, "acme", "profile.json") }, checked)
	end)

	it("ignores every installed profile when the system folder isn't admin-only", function()
		local files = {
			[P(TRUSTED, "acme", "profile.json")] = profile(ACME),
			[P(SYS, "policy.json")] = cjson.encode({ profile = "acme" }),
		}
		local p, info = resolve_secure(files, { [SYS] = true }, { domain = "acme.example" })
		assert.is_nil(p)
		assert.is_true(has_error(info, "ignoring installed profiles"))
		assert.is_true(has_error(info, "ignoring policy.json"))
	end)

	it("ignores a planted pack but keeps the protected ones", function()
		local files = {
			[P(TRUSTED, "acme", "profile.json")] = profile(ACME),
			[P(TRUSTED, "planted", "profile.json")] = profile({ id = "planted", name = "Planted" }),
			[P(SYS, "policy.json")] = cjson.encode({ profile = "planted" }),
		}
		local p, info = resolve_secure(files, { [P(TRUSTED, "planted")] = true })
		assert.is_nil(p)
		assert.are.equal("assigned-missing", info.reason)
		assert.is_true(has_error(info, "planted is not admin-only"))
	end)

	it("ignores a pack whose profile.json or extensions folder others can change", function()
		local files = {
			[P(TRUSTED, "acme", "profile.json")] = profile(ACME),
			[P(TRUSTED, "globex", "profile.json")] = profile({ id = "globex", name = "Globex", match = { domains = { "globex.example" } } }),
			[P(TRUSTED, "globex", "extensions", "x", "init.lua")] = "",
		}
		local open = {
			[P(TRUSTED, "acme", "profile.json")] = true,
			[P(TRUSTED, "globex", "extensions")] = true,
		}
		assert.is_nil((resolve_secure(files, open, { domain = "acme.example" })))
		assert.is_nil((resolve_secure(files, open, { domain = "globex.example" })))
	end)

	it("ignores a pack with one writable file deep inside an extension", function()
		local files = {
			[P(TRUSTED, "acme", "profile.json")] = profile(ACME),
			[P(TRUSTED, "acme", "extensions", "x", "init.lua")] = "",
			[P(TRUSTED, "acme", "extensions", "x", "libs", "util.lua")] = "",
		}
		local p, info = resolve_secure(files,
			{ [P(TRUSTED, "acme", "extensions", "x", "libs", "util.lua")] = true },
			{ domain = "acme.example" })
		assert.is_nil(p)
		assert.is_true(has_error(info, "util.lua is not admin-only"))
	end)

	it("refuses a pack it can't walk", function()
		local files = { [P(TRUSTED, "acme", "profile.json")] = profile(ACME) }
		local fs = fake_fs(files)
		fs.secure = function() return true end
		fs.walk = function() return nil, "more than 20000 entries" end
		local p, info = OrgProfile.resolve({ fs = fs, domain = "acme.example", env = function() return nil end,
			roots = { { dir = TRUSTED, trusted = true } } })
		assert.is_nil(p)
		assert.is_true(has_error(info, "cannot check"))
	end)

	it("ignores a policy.json others can change, and falls back to the domain", function()
		local files = {
			[P(TRUSTED, "acme", "profile.json")] = profile(ACME),
			[P(TRUSTED, "globex", "profile.json")] = profile({ id = "globex", name = "Globex" }),
			[P(SYS, "policy.json")] = cjson.encode({ profile = "globex" }),
		}
		local p, info = resolve_secure(files, { [P(SYS, "policy.json")] = true }, { domain = "acme.example" })
		assert.are.equal("acme", p.id)
		assert.are.equal("domain", info.reason)
		assert.is_true(has_error(info, "ignoring policy.json"))
	end)

	it("never checks the dev root, and checks nothing when nothing is installed", function()
		local files = { [P(DEV, "acme", "profile.json")] = profile(ACME) }
		local p, _, checked = resolve_secure(files, {}, { domain = "acme.example" })
		assert.is_false(p.trusted)
		assert.are.same({}, checked)
	end)
end)

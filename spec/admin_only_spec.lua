local posix = require("core.platform.posix")
local platform = require("core.platform")

describe("platform.admin_only (POSIX rule)", function()
	local function dir(t)
		t.mode = t.mode or "directory"
		return t
	end

	it("accepts root-owned folders and files nobody else can write", function()
		assert.is_true((posix.admin_only_attrs(dir({ uid = 0, gid = 0, permissions = "rwxr-xr-x" }))))
		assert.is_true((posix.admin_only_attrs({ mode = "file", uid = 0, gid = 0, permissions = "rw-r--r--" })))
	end)

	it("refuses other owners, world-writable, and any group write (it may be an ACL mask)", function()
		assert.is_false((posix.admin_only_attrs(dir({ uid = 0, gid = 0, permissions = "rwxrwxr-x" }))))
		assert.is_false((posix.admin_only_attrs(dir({ uid = 1000, gid = 0, permissions = "rwxr-xr-x" }))))
		assert.is_false((posix.admin_only_attrs(dir({ uid = 0, gid = 0, permissions = "rwxr-xrwx" }))))
		assert.is_false((posix.admin_only_attrs(dir({ uid = 0, gid = 100, permissions = "rwxrwxr-x" }))))
	end)

	it("refuses anything it can't read", function()
		assert.is_false((posix.admin_only_attrs(nil)))
		assert.is_false((posix.admin_only_attrs(dir({ uid = 0, gid = 0 }))))
		assert.is_false((posix.admin_only_attrs({ mode = "link", uid = 0, gid = 0, permissions = "rwxr-xr-x" })))
	end)
end)

describe("platform.admin_only (this machine)", function()
	if not platform.is_windows then return end

	it("accepts the Windows folder", function()
		assert.is_true((platform.admin_only("C:\\Windows")))
	end)

	it("refuses a folder the current user owns, with the reason", function()
		local ok, why = platform.admin_only(os.getenv("TEMP"))
		assert.is_false(ok)
		assert.truthy(why:find("owned by", 1, true))
	end)

	it("refuses a path that doesn't exist", function()
		assert.is_false((platform.admin_only("C:\\lunar-no-such-folder\\x")))
	end)
end)

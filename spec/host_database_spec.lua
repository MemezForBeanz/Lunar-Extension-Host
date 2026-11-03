local HostAPI = require("core.classes.HostAPI")
local lfs = require("lfs")
local P = require("core.platform").path

describe("HostAPI databases", function()
	local host, owner, root, opened
	before_each(function()
		root = P:join(require("core.platform").temp_dir(), "lunar_db_" .. os.time() .. "_" .. math.random(1e9))
		assert(lfs.mkdir(root))
		opened, owner = {}, {}
		host = HostAPI:new({ state_dir = root, sqlite = { open = function(path, opts)
			local db = { path = path, opts = opts, close = function(self) self.closed = true return true end }
			opened[#opened + 1] = db
			return db
		end } })
		host:registerExtension(owner, { id = "scanner", capabilities = { "database" } })
	end)
	after_each(function()
		host:_closeDatabases()
		lfs.rmdir(P:join(root, "scanner")); lfs.rmdir(root)
	end)
	it("requires capability and rejects path components before opening", function()
		local other = {}
		host:registerExtension(other, { id = "other" })
		assert.is_nil((host:openDatabase("history", other)))
		assert.is_nil((host:openDatabase("history", {})))
		for _, name in ipairs({ "", "..", "../history", "a/b", "a\\b", "C:db", "a.sqlite3" }) do
			assert.is_nil((host:openDatabase(name, owner)))
		end
		assert.are.equal(0, #opened)
	end)
	it("caches per owner/name and closes on unload", function()
		local db = assert(host:openDatabase("history", owner))
		assert.are.equal(P:join(root, "scanner", "history.sqlite3"), db.path)
		assert.are.equal(0, db.opts.busy_timeout_ms)
		assert.are.equal(db, host:openDatabase("history", owner))
		assert.are.equal(1, #opened)
		host:removeOwned(owner)
		assert.is_true(db.closed)
	end)
	it("allows cached DB use while draining but refuses new databases", function()
		local db = assert(host:openDatabase("history", owner))
		host._stopping = true
		assert.are.equal(db, host:openDatabase("history", owner))
		assert.is_nil((host:openDatabase("new", owner)))
		assert.is_nil(db.closed)
		assert(host:_closeDatabases())
		assert.is_true(db.closed)
	end)
end)

package.path = "./extensions/media-server/?.lua;" .. package.path
local repair = require("libs.repair")
local Catalog = require("libs.catalog")
local sqlite = require("core.lib.sqlite")
local schema = require("libs.schema")
local api = require("libs.api")
describe("repair workbench", function()
	it("orders every problem by impact and only offers enabled work", function()
		local data = { offline = { { id = 2, name = "Shows", count = 3 } },
			analysis = { { id = 4, title = "Film", error = "Unreadable" } },
			sources = { { id = 7, name = "Club", error = "503" } },
			frames = { { id = 5, title = "Film" } } }
		local rows = repair.list(data)
		assert.equal(5, #rows)
		for i, kind in ipairs({ "offline", "analysis", "source", "frame", "analysis_off" }) do
			assert.equal(kind, rows[i].kind)
			assert.is_string(rows[i].next_step)
		end
		assert.is_nil(rows[2].action)
		assert.is_nil(rows[4].action)
		data.analysis_enabled, data.frames_enabled = true, true
		rows = repair.list(data)
		assert.equal(4, #rows)
		assert.equal("/v1/files/4/analyse", rows[2].action.path)
		assert.equal("/v1/items/5/frame", rows[4].action.path)
	end)
	it("groups offline files and requeues actual failed jobs through routes", function()
		local db = assert(sqlite.open(":memory:"))
		assert(schema.migrate(db))
		local catalog = Catalog.new(db)
		local library = catalog:addLibrary("Films", "movie", "D:/sample")
		for i = 1, 3 do catalog:noteFile(library.id, i .. ".mp4", 1, 1, 1, { kind = "movie", title = "Film " .. i }) end
		catalog:_rows("UPDATE files SET missing_at = 1 WHERE id IN (1, 2)")
		catalog:queueProbe(3)
		catalog:_rows("UPDATE jobs SET state = 'failed', attempts = 3, error = 'broken'")
		catalog:_rows("INSERT INTO art_jobs (work_id, file_id, state, error) VALUES (3, 3, 'failed', 'frame broke')")
		catalog:_rows("INSERT INTO sources (provider_id, name, config, status, error, created_at) VALUES ('feed', 'Club', '{}', 'failed', '503', 1)")
		local routes, enabled = {}, true
		api.mount({ catalog = catalog, frames_enabled = true,
			status = function() return { json = { analysis = enabled and "on" or "off" } } end,
			route = function(method, path, handler) routes[method .. path] = handler end })
		local rows = routes["GET/v1/attention"]().json.problems
		assert.equal(4, #rows)
		assert.matches("2 files", rows[1].wrong)
		assert.equal("source", rows[3].kind)
		assert.equal(202, routes["POST/v1/files/:id/analyse"]({ params = { id = "3" } }).status)
		assert.equal(0, catalog:_one("SELECT attempts FROM jobs").attempts)
		assert.equal("queued", catalog:_one("SELECT state FROM jobs").state)
		assert.equal(409, routes["POST/v1/files/:id/analyse"]({ params = { id = "3" } }).status)
		assert.equal(202, routes["POST/v1/items/:id/frame"]({ params = { id = "3" } }).status)
		enabled = false
		assert.equal(409, routes["POST/v1/files/:id/analyse"]({ params = { id = "3" } }).status)
		assert.is_false(catalog:retryFrame(999))
		catalog:close(); db:close()
	end)
end)

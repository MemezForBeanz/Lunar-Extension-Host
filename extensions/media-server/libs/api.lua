--- The server's HTTP API, under /ext/media-server/v1. Handlers don't touch the
-- network or start work inline; a slow step is queued, and clients read progress back.
-- Files are reached by catalog id only: no request names a path.
-- @module libs.api

local decision = require("libs.decision")
local lfs = require("lfs")

local M = {}

local KINDS = { movie = true, show = true }

local function bad(status, message)
	return { status = status, json = { error = message } }
end

local function id_of(text)
	local n = tonumber(text)
	if n and n >= 1 and n == math.floor(n) then return n end
end

local function json_body(req)
	local cjson = require("cjson")
	local ok, data = pcall(cjson.decode, req.body or "")
	if ok and type(data) == "table" then return data end
end

local function is_absolute(path)
	return path:match("^%a:[/\\]") or path:sub(1, 1) == "/"
end

--- Add every route. `svc` provides `catalog`, `status()`, `scan(library)`,
-- `file_response(target)`, `now()` and `route(method, path, handler)`.
function M.mount(svc)
	local catalog = svc.catalog
	local route = svc.route

	route("GET", "/v1/status", function() return svc.status() end)

	route("GET", "/v1/libraries", function()
		return { status = 200, json = { libraries = catalog:libraries() } }
	end)

	route("POST", "/v1/libraries", function(req)
		local body = json_body(req)
		if not body or type(body.name) ~= "string" or body.name == "" then return bad(400, "a name is required") end
		if not KINDS[body.kind] then return bad(400, "kind must be movie or show") end
		if type(body.root) ~= "string" or not is_absolute(body.root) then return bad(400, "root must be an absolute path") end
		local root = body.root:gsub("[/\\]+$", "")
		if lfs.attributes(root, "mode") ~= "directory" then return bad(400, "root is not a folder on this server") end
		local ok, library = pcall(catalog.addLibrary, catalog, body.name, body.kind, root)
		if not ok then return bad(409, "that folder is already a library") end
		svc.scan(library)
		return { status = 201, json = library }
	end)

	route("POST", "/v1/libraries/:id/scan", function(req)
		local library = catalog:library(id_of(req.params.id) or 0)
		if not library then return bad(404, "no such library") end
		svc.scan(library)
		return { status = 202, json = { queued = true } }
	end)

	route("GET", "/v1/libraries/:id/items", function(req)
		local library = catalog:library(id_of(req.params.id) or 0)
		if not library then return bad(404, "no such library") end
		local q = req.query or {}
		local sort = q.sort == "added" and "added" or "title"
		return { status = 200, json = catalog:browse(library.id, {
			sort = sort, limit = q.limit, user = req.auth,
			after_key = sort == "added" and tonumber(q.after_key) or q.after_key,
			after_id = tonumber(q.after_id),
		}) }
	end)

	route("GET", "/v1/collections", function()
		return { status = 200, json = { collections = catalog:collections() } }
	end)

	route("POST", "/v1/collections", function(req)
		local body = json_body(req)
		if not body or type(body.name) ~= "string" or body.name == "" or #body.name > 200 then
			return bad(400, "a name is required")
		end
		local rules
		if type(body.rules) == "table" then rules = require("cjson").encode(body.rules) end
		if not rules and type(body.items) ~= "table" then return bad(400, "rules or items are required") end
		local id = catalog:addCollection(body.name, type(body.icon) == "string" and body.icon or nil, rules, body.items, svc.now())
		return { status = 201, json = { id = id } }
	end)

	route("DELETE", "/v1/collections/:id", function(req)
		catalog:deleteCollection(id_of(req.params.id) or 0)
		return { status = 204 }
	end)

	route("GET", "/v1/items/:id", function(req)
		local item = catalog:item(id_of(req.params.id) or 0, req.auth)
		if not item then return bad(404, "no such item") end
		return { status = 200, json = item }
	end)

	route("GET", "/v1/search", function(req)
		local q = (req.query or {}).q
		if type(q) ~= "string" or q == "" then return bad(400, "q is required") end
		return { status = 200, json = { items = catalog:search(q, (req.query or {}).limit) } }
	end)

	route("GET", "/v1/continue", function(req)
		return { status = 200, json = { items = catalog:continueWatching(req.auth, (req.query or {}).limit) } }
	end)

	route("POST", "/v1/items/:id/progress", function(req)
		local id, body = id_of(req.params.id), json_body(req)
		if not id or not catalog:item(id, req.auth) then return bad(404, "no such item") end
		local position = body and tonumber(body.position_ms)
		if not position or position < 0 then return bad(400, "position_ms is required") end
		catalog:saveProgress(req.auth, id, position, tonumber(body.duration_ms), svc.now())
		return { status = 204 }
	end)

	route("POST", "/v1/files/:id/decision", function(req)
		local item = catalog:fileTarget(id_of(req.params.id) or 0)
		if not item then return bad(404, "no such file") end
		local body = json_body(req)
		if not body then return bad(400, "capabilities are required") end
		local work = catalog:_one("SELECT work_id FROM files WHERE id = ?", item.id)
		for _, file in ipairs(catalog:item(work.work_id, req.auth).files) do
			if file.id == item.id then
				return { status = 200, json = decision.decide(file, body.capabilities, body.selected) }
			end
		end
		return bad(404, "no such file")
	end)

	route("GET", "/v1/items/:id/art/:kind", function(req)
		local kind = req.params.kind
		if kind ~= "poster" and kind ~= "backdrop" then return bad(404, "no such picture") end
		local target = catalog:artTarget(id_of(req.params.id) or 0, kind)
		if not target then return bad(404, "no such picture") end
		return svc.art_response(target)
	end)

	local function stream(req)
		local target = catalog:fileTarget(id_of(req.params.id) or 0)
		if not target then return bad(404, "no such file") end
		if target.missing_at then return bad(410, "this file is offline") end
		return svc.file_response(target)
	end
	route("GET", "/v1/files/:id/stream", stream)
	route("HEAD", "/v1/files/:id/stream", stream)
end

return M

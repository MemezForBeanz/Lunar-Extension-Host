local M = {}

local function copy_table(value)
	local out = {}
	if type(value) == "table" then
		for k, v in pairs(value) do
			out[k] = v
		end
	end
	return out
end

local function queue_from(items)
	local out = {}
	for i, item in ipairs(items or {}) do
		out[i] = item
	end
	return out
end

function M.transport(script)
	script = script or {}
	local queue = queue_from(script.responses)
	local transport = {
		tls = script.tls == true,
		socket = script.socket or { sleep = function() end },
		requests = {},
	}
	transport.url = {
		escape = function(value)
			value = tostring(value)
			return (value:gsub("([^A-Za-z0-9%-%._~])", function(ch)
				return string.format("%%%02X", string.byte(ch))
			end))
		end,
	}
	transport.ltn12 = {
		sink = {
			table = function(target)
				return function(chunk)
					if chunk ~= nil then
						target[#target + 1] = chunk
					end
					return 1
				end
			end,
		},
		source = {
			string = function(text)
				local done = false
				return function()
					if done then return nil end
					done = true
					return text
				end
			end,
		},
	}
	transport.http = {
		TIMEOUT = nil,
		request = function(req)
			transport.requests[#transport.requests + 1] = req
			local next_response = table.remove(queue, 1) or {}
			if next_response.raise then
				error(next_response.raise)
			end
			if next_response.ok == false then
				return nil, next_response.err or "closed"
			end
			local body = next_response.body
			if body ~= nil and req.sink then
				req.sink(body)
			end
			return 1,
				next_response.code or 200,
				next_response.headers or {},
				next_response.status or "200 OK"
		end,
	}
	return transport
end

function M.client(script)
	script = script or {}
	local queue = queue_from(script.postRun or {})
	local client = {
		calls = {},
	}
	function client:available()
		return script.available ~= false
	end
	function client:postRun(record)
		self.calls[#self.calls + 1] = copy_table(record)
		local next_response = table.remove(queue, 1)
		if next_response == nil then
			next_response = { ok = true, body = { accepted = true } }
		end
		if next_response.raise then
			error(next_response.raise)
		end
		if next_response.ok == false then
			return nil, next_response.err or "backend rejected record"
		end
		return next_response.body or { accepted = true }
	end
	return client
end

function M.store(records)
	local summaries = {}
	local full = {}
	for i, record in ipairs(records or {}) do
		local summary = copy_table(record)
		summaries[i] = summary
		local id = summary.id and tostring(summary.id) or tostring(i)
		full[id] = copy_table(record)
	end
	local store = {}
	function store:queryRuns()
		return summaries
	end
	function store:getRun(id)
		return full[tostring(id)]
	end
	function store:getDir()
		return nil
	end
	return store
end

return M

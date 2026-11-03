local HttpServer = require("core.lib.HttpServer")
local http = require("core.lib.http")
local copas = require("core.lib.async").copas
local socket = require("socket")
local lfs = require("lfs")

describe("HttpServer TLS", function()
	it("serves HTTPS with a verified throwaway certificate", function()
		local sink = package.config:sub(1, 1) == "\\" and "NUL" or "/dev/null"
		local available = os.execute("openssl version >" .. sink .. " 2>&1")
		if available ~= 0 and available ~= true then pending("openssl is not on PATH"); return end
		local has_ssl = pcall(require, "ssl")
		if not has_ssl then pending("LuaSec is unavailable in this test runtime"); return end
		-- Controlled relative paths avoid shell interpolation of environment paths.
		local dir = string.format("tls_test_%d_%d", os.time(), math.random(1e9))
		assert(lfs.mkdir(dir))
		local cert, key = dir .. "/cert.pem", dir .. "/key.pem"
		local server
		local ok, err = pcall(function()
			local generated = os.execute('openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost"'
				.. ' -addext "subjectAltName=DNS:localhost" -keyout ' .. key .. ' -out ' .. cert .. ' >' .. sink .. ' 2>&1')
			assert.is_true(generated == 0 or generated == true)
			server = HttpServer.new({ host = "127.0.0.1", port = 0, allow_anonymous = true,
				tls = { certificate = cert, key = key } })
			server:route("GET", "/health", function() return { json = { ok = true } } end, { public = true })
			assert(server:start())
			local done, response, problem
			copas.addthread(function()
				response, problem = http.request({ url = "https://localhost:" .. server.port .. "/health",
					cafile = cert, verify = "peer", timeout = 3 })
				done = true
			end)
			local deadline = socket.gettime() + 5
			while not done and socket.gettime() < deadline do copas.step(0.01) end
			assert.is_true(done)
			assert.is_nil(problem)
			assert.are.equal(200, response.status)
			assert.is_true(response:json().ok)
		end)
		if server then server:stop() end
		os.remove(key); os.remove(cert); lfs.rmdir(dir)
		assert.is_true(ok, err)
	end)
end)

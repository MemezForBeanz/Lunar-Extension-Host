-- Lua language support: registers lua-language-server with the host.
--
-- Built in, but through the same door as any other language server
-- (`ctx:addLanguageServer`), so unloading this extension stops the server.
--
-- The server itself is not part of this extension. It is found on the computer:
-- the path set in Settings > Language servers, a copy shipped in Lunar's
-- `servers\lua-language-server` folder, or `PATH`.

local M = {}

local INSTALL = "Install lua-language-server (https://luals.github.io) and add it to PATH, "
	.. "or set its path in Settings > Language servers."

function M:register(ctx)
	local windows = package.config:sub(1, 1) == "\\"
	local exe_name = windows and "lua-language-server.exe" or "lua-language-server"

	ctx:addLanguageServer({
		id = "lua",
		name = "Lua",
		languages = { "lua" },
		extensions = { ".lua" },
		root_markers = { ".luarc.json", ".luarc.jsonc", ".luacheckrc", ".git" },
		command = function()
			local exe, why = ctx:findLanguageServer({
				id = "lua",
				label = "lua-language-server",
				names = { "lua-language-server" },
				bundled = {
					"servers/lua-language-server/bin/" .. exe_name,
					"servers/lua-language-server/" .. exe_name,
				},
				install = INSTALL,
			})
			if not exe then return nil, why end
			return { argv = { exe } }
		end,
		settings = {
			Lua = {
				-- Lunar itself and most of what it hosts runs on LuaJIT.
				runtime = { version = "LuaJIT" },
				telemetry = { enable = false },
				workspace = { checkThirdParty = false },
			},
		},
	}, M)
end

return M

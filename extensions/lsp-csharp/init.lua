-- C# language support: registers a C# language server with the host.
--
-- Not installed with Lunar. To install it, copy this folder into the `plugins`
-- folder beside Lunar (or into an org pack's `extensions` folder); see
-- docs/language-servers.md.
--
-- The server is csharp-ls (`dotnet tool install --global csharp-ls`) or
-- OmniSharp, whichever the computer has. Both need the .NET SDK. A path set in
-- Settings > Language servers wins.

local M = {}

local INSTALL = "Install the .NET SDK, then `dotnet tool install --global csharp-ls`, "
	.. "or set a server's path in Settings > Language servers."

local function arguments(exe)
	local name = (exe:match("([^/\\]+)$") or exe):lower()
	if name:find("omnisharp", 1, true) then return { "-lsp" } end
	return {}
end

function M.register(ctx)
	ctx:addLanguageServer({
		id = "csharp",
		name = "C#",
		languages = { "csharp" },
		extensions = { ".cs" },
		-- A solution outranks a project: the server needs the whole solution.
		root_markers = { "*.sln", "*.csproj", ".git" },
		command = function()
			local exe, why = ctx:findLanguageServer({
				id = "csharp",
				label = "A C# language server (csharp-ls or OmniSharp)",
				names = { "csharp-ls", "OmniSharp" },
				install = INSTALL,
			})
			if not exe then return nil, why end
			local argv = { exe }
			for _, arg in ipairs(arguments(exe)) do argv[#argv + 1] = arg end
			return { argv = argv }
		end,
	}, M)
end

return M

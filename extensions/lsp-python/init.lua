-- Python language support: registers a Python language server with the host.
--
-- Not installed with Lunar. To install it, copy this folder into the `plugins`
-- folder beside Lunar (or into an org pack's `extensions` folder); see
-- docs/language-servers.md.
--
-- The server is whichever of these the computer has, in this order: Pyright
-- (`pyright-langserver`, from `npm i -g pyright` or `pip install pyright`),
-- basedpyright, or pylsp (`pip install python-lsp-server`). A path set in
-- Settings > Language servers wins over all of them.

local M = {}

local INSTALL = "Install one with `pip install pyright` or `pip install python-lsp-server`, "
	.. "or set its path in Settings > Language servers."

-- What each server needs on its command line to speak over stdio.
local function arguments(exe)
	local name = (exe:match("([^/\\]+)$") or exe):lower()
	if name:find("pyright", 1, true) then return { "--stdio" } end
	return {}
end

function M.register(ctx)
	ctx:addLanguageServer({
		id = "python",
		name = "Python",
		languages = { "python" },
		extensions = { ".py", ".pyi" },
		root_markers = { "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "pyrightconfig.json", ".git" },
		command = function()
			local exe, why = ctx:findLanguageServer({
				id = "python",
				label = "A Python language server (Pyright or pylsp)",
				names = { "pyright-langserver", "basedpyright-langserver", "pylsp" },
				install = INSTALL,
			})
			if not exe then return nil, why end
			local argv = { exe }
			for _, arg in ipairs(arguments(exe)) do argv[#argv + 1] = arg end
			return { argv = argv }
		end,
		settings = {
			python = { analysis = { autoSearchPaths = true, diagnosticMode = "openFilesOnly" } },
		},
	}, M)
end

return M

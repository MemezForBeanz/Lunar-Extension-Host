-- C and C++ language support: registers clangd with the host.
--
-- Built in, but through the same door as any other language server
-- (`ctx:addLanguageServer`), so unloading this extension stops the server.
--
-- clangd is not part of this extension. It is found on the computer: the path
-- set in Settings > Language servers, a copy shipped in Lunar's `servers\clangd`
-- folder, or `PATH` (an LLVM install puts it there).

local M = {}

local INSTALL = "Install LLVM (https://releases.llvm.org) or clangd and add it to PATH, "
	.. "or set its path in Settings > Language servers."

function M:register(ctx)
	local windows = package.config:sub(1, 1) == "\\"
	local exe_name = windows and "clangd.exe" or "clangd"

	ctx:addLanguageServer({
		id = "c",
		name = "C and C++",
		languages = { "c", "cpp" },
		extensions = { ".c", ".h", ".cc", ".cpp", ".cxx", ".hh", ".hpp", ".hxx" },
		language_ids = {
			[".cc"] = "cpp", [".cpp"] = "cpp", [".cxx"] = "cpp",
			[".hh"] = "cpp", [".hpp"] = "cpp", [".hxx"] = "cpp",
		},
		root_markers = { "compile_commands.json", "compile_flags.txt", ".clangd", ".git" },
		command = function()
			local exe, why = ctx:findLanguageServer({
				id = "c",
				label = "clangd",
				names = { "clangd" },
				bundled = { "servers/clangd/bin/" .. exe_name, "servers/clangd/" .. exe_name },
				install = INSTALL,
			})
			if not exe then return nil, why end
			-- Its log goes to stderr, which the host only keeps a tail of.
			return { argv = { exe, "--log=error" } }
		end,
	}, M)
end

return M

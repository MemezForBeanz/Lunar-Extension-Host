-- config.ld — LDoc configuration for the Lunar Extension Host API reference.
--
-- Build the site with:
--   scripts\docs.ps1              # -> dist\docs
--   scripts\docs.ps1 -Check       # fail on LDoc warnings (CI gate)
--
-- Only the host surface that extensions are allowed to use is documented:
-- src\lua\core (host classes, shared libs, UI toolkit) and the native Lua
-- modules implemented in src\c\libs. Shipped extensions under plugins\ are
-- consumers of this API, not part of it, so they appear only as examples.
--
-- NOTE: LDoc evaluates this file in a sandbox that exposes only the config
-- keys below (no `io`, no `os`), so the documented `version` cannot be read
-- from src\lua\core\main.lua here. scripts\docs.ps1 appends the real
-- APP_VERSION to a generated copy of this file at build time; the value below
-- is only the fallback when ldoc is invoked directly.

project = "Lunar Extension Host"
title = "Lunar Host API reference"
description = "Host and extension API for the Lunar Extension Host Windows host."
full_description = [[
The Lunar Extension Host (Lunar) host owns the window, extension lifecycle,
settings, themes, menus, status bar, routing, and native services. Everything a
Lunar extension needs is reachable from the `HostAPI` context passed to its
`register(ctx)` entry point.
]]

format = "markdown"
dir = "dist/docs"
style = "!fixed"
template = "!"
-- scripts\docs.ps1 copies assets\lunar-icon-32.png into the site as favicon.png.
favicon = "favicon.png"

-- Source roots. LDoc walks these recursively.
file = {
	"src/lua/core",
	"src/c/libs",
	"src/c/platform",
	exclude = {
		-- Host bootstrap/composition rather than API surface.
		"src/lua/core/main.lua",
		-- HostAPI's services are implementation details; the facade owns their LDoc.
		"src/lua/core/classes/host/Owners.lua",
		"src/lua/core/classes/host/Secrets.lua",
		"src/lua/core/classes/host/Network.lua",
		"src/lua/core/classes/host/Layout.lua",
		"src/lua/core/classes/host/Routing.lua",
		"src/lua/core/classes/host/Keys.lua",
		"src/lua/core/classes/host/Menus.lua",
		-- Test-only harnesses.
		"src/lua/core/test/MockBackend.lua",
		-- Generated/derived theme rule tables carry no public API.
		"src/lua/core/classes/Themes/carbon_rules.lua",
		"src/lua/core/classes/Themes/fluent_rules.lua",
		-- Third-party implementation shim with no Lua-visible API.
		"src/c/libs/nanosvg_impl.c",
	},
}

-- Hand-written guides. The first entry becomes the landing page.
topics = {
	"docs/index.md",
	"docs/getting-started.md",
	"docs/extension-lifecycle.md",
	"docs/manifest.md",
	"docs/tab-groups.md",
	"docs/ui-recipes.md",
	"docs/routing.md",
	"docs/theming.md",
	"docs/motion.md",
	"docs/logging.md",
	"docs/native-services.md",
	"docs/packaging.md",
	"docs/trust-model.md",
	"docs/api-stability.md",
}

-- The worked example lives in exampleplugins/, NOT plugins/. plugins/ is the
-- directory the host actually scans at startup, so a sample sitting there is
-- loaded like a real extension -- which is how a zero-byte plugins/hello.lua came
-- to raise a plugin-load error on every launch.
examples = {
	"exampleplugins/hello.lua",
}

-- Only documented items are published; undocumented locals stay private.
all = false
sort = true
sort_modules = true
no_space_before_args = true
backtick_references = true
merge = true
use_markdown_titles = true

-- Custom tag for marking when a host API first appeared, so extension authors
-- can tell which host version they need.
custom_tags = {
	{ "since", title = "Since" },
}

custom_see_handler("^lunar://(.*)$", function(path)
	return "lunar://" .. path, "topics/routing.md.html"
end)
-- `version` is shown in the page footer; scripts\docs.ps1 overrides it with the
-- APP_VERSION of the tree being documented.
version = "dev"

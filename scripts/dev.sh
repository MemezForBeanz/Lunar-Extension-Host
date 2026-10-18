#!/usr/bin/env bash
# scripts/dev.sh — Linux/POSIX dev loop: restore the rock tree, then run the
# specs, lint and the API docs. The Windows equivalents are fetch-deps.ps1,
# rock-tool.ps1, test.ps1, lint.ps1 and docs.ps1.
#
# Usage:
#   scripts/dev.sh bootstrap          # runtime rocks + cjson + serpent + busted/luacheck/ldoc
#   scripts/dev.sh test [busted args] # busted suite (.busted config)
#   scripts/dev.sh lint [paths...]    # luacheck (default: src/lua plugins scripts)
#   scripts/dev.sh docs [--check] [--out DIR]
#   scripts/dev.sh check              # test + lint + docs --check
#   scripts/dev.sh desktop [--remove] # menu entry + icon for the dev build (build/linux)
#
# The interpreter is LuaJIT 2.1 from $LUNAR_LUA_DIR (default /usr/local, i.e.
# /usr/local/bin/luajit and /usr/local/include/luajit-2.1). The rock tree lives
# in vendor/luarocks-tree, as on Windows. Tools run through LuaJIT directly
# rather than the LuaRocks launchers, which bake in absolute paths.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

lua_dir="${LUNAR_LUA_DIR:-/usr/local}"
luajit="$lua_dir/bin/luajit"
tree="$repo/vendor/luarocks-tree"
lua_flags=(--lua-version 5.1 --lua-dir "$lua_dir")

# Keep in sync with scripts/fetch-deps.ps1 and scripts/rock-tool.ps1.
busted_version="2.3.0-1"
luacheck_version="1.2.0-1"
ldoc_version="1.5.0-1"
serpent_commit="ed98a21db64e9e8f44403394400f84f4daecb60d"
serpent_sha256="e90783bf50a5f6ace6691c0607b7c5020c2bffe174d3be63a1bee3dd198b5ccd"

say() { printf '\033[36m[dev] %s\033[0m\n' "$*"; }
die() { printf '\033[31m[dev] %s\033[0m\n' "$*" >&2; exit 1; }

need_luajit() {
	[[ -x "$luajit" ]] || die "LuaJIT not found at $luajit (set LUNAR_LUA_DIR)"
}

bootstrap() {
	need_luajit
	command -v luarocks >/dev/null || die "luarocks not found (apt install luarocks)"

	say "Runtime dependencies (rockspec --only-deps)"
	luarocks "${lua_flags[@]}" install --tree "$tree" --only-deps lunarextensionhost-dev-1.rockspec

	say "lua-cjson from vendor/lua-cjson (the source CMake links)"
	(
		cd vendor/lua-cjson
		trap 'rm -f ./*.o ./*.so' EXIT
		luarocks "${lua_flags[@]}" make --tree "$tree" lua-cjson-2.1devel-1.rockspec \
			CFLAGS="-O2 -fPIC -DUSE_LUAJIT"
	)

	local serpent="$tree/share/lua/5.1/serpent.lua"
	if [[ -f "$serpent" ]]; then
		say "serpent.lua already present"
	else
		say "serpent.lua at $serpent_commit"
		mkdir -p "$(dirname "$serpent")"
		# Download beside the target and rename only once verified, so an
		# interrupted fetch can't leave a partial file that later runs skip.
		local partial="$serpent.partial"
		rm -f "$partial"
		curl -fsSL "https://raw.githubusercontent.com/pkulchenko/serpent/$serpent_commit/src/serpent.lua" -o "$partial" \
			|| { rm -f "$partial"; die "serpent.lua fetch failed"; }
		if ! echo "$serpent_sha256  $partial" | sha256sum -c --quiet -; then
			rm -f "$partial"
			die "serpent.lua does not match the pinned SHA-256"
		fi
		mv -f "$partial" "$serpent"
	fi

	say "Dev tools (luacheck, busted, ldoc)"
	luarocks "${lua_flags[@]}" install --tree "$tree" luacheck "$luacheck_version"
	luarocks "${lua_flags[@]}" install --tree "$tree" busted "$busted_version"
	luarocks "${lua_flags[@]}" install --tree "$tree" ldoc "$ldoc_version"
	say "Done. Tree: $tree"
}

# Run a dev-tool rock's entry script under LuaJIT with the tree on the paths.
rock_tool() {
	need_luajit
	local tool="$1" version
	shift
	case "$tool" in
		busted) version="$busted_version" ;;
		luacheck) version="$luacheck_version" ;;
		ldoc) version="$ldoc_version" ;;
		*) die "unknown rock tool '$tool'" ;;
	esac
	local entry="$tree/lib/luarocks/rocks-5.1/$tool/$version/bin/$tool"
	[[ -f "$entry" ]] || die "$tool $version is not installed in $tree (run: scripts/dev.sh bootstrap)"
	LUA_PATH="$tree/share/lua/5.1/?.lua;$tree/share/lua/5.1/?/init.lua;;" \
	LUA_CPATH="$tree/lib/lua/5.1/?.so;;" \
	LUNAR_REPO="${LUNAR_REPO:-$repo}" \
		"$luajit" "$entry" "$@"
}

docs() {
	local check=0 out="dist/docs"
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--check) check=1 ;;
			--out) out="$2"; shift ;;
			*) die "docs: unknown option $1" ;;
		esac
		shift
	done
	rm -rf "$out"
	mkdir -p "$out"

	# LDoc evaluates config.ld in a sandbox without io/os, so append the
	# version to a generated copy (same as docs.ps1).
	local version generated="$repo/config.generated.ld" output status=0
	version="$(sed -n 's/^local[[:space:]]*APP_VERSION[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' src/lua/core/main.lua | head -n 1)"
	{ cat config.ld; printf '\nversion = "%s"\n' "${version:-dev}"; } > "$generated"
	output="$(rock_tool ldoc --config "$generated" --dir "$out" . 2>&1)" || status=$?
	rm -f "$generated"
	printf '%s\n' "$output"
	[[ $status -eq 0 ]] || die "ldoc failed with exit code $status"
	[[ -f "$out/index.html" ]] || die "ldoc produced no index.html in $out"
	touch "$out/.nojekyll"
	cp -f assets/lunar-icon-32.png "$out/favicon.png" 2>/dev/null || true

	local warnings
	warnings="$(printf '%s\n' "$output" | grep -Eci '^(ldoc: )?[^:]*:[0-9]+:|warning' || true)"
	if [[ "$warnings" -gt 0 ]]; then
		printf '\033[33m[docs] %s LDoc warning(s).\033[0m\n' "$warnings"
		[[ $check -eq 0 ]] || die "Documentation check failed: resolve the LDoc warnings above."
	else
		say "No LDoc warnings."
	fi
	say "Docs: $out/index.html"
}

# A per-user menu entry and hicolor icons for the dev build, so a dev run shows
# the Lunar icon in the panel (the panel matches the window class "Lunar" to a
# .desktop file). Installed packages bring their own entry; this one is "Lunar (dev)".
desktop() {
	local apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
	local icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" s
	if [[ "${1:-}" == "--remove" ]]; then
		rm -f "$apps/lunar-dev.desktop"
		for s in 16 24 32 48 64 128 256; do rm -f "$icons/${s}x${s}/apps/lunar.png"; done
		say "Removed the dev menu entry and icons"
		return
	fi
	for s in 16 24 32 48 64 128 256; do
		install -D -m 0644 "$repo/assets/app-icon/lunar-$s.png" "$icons/${s}x${s}/apps/lunar.png"
	done
	mkdir -p "$apps"
	sed -e "s|^Name=Lunar$|Name=Lunar (dev)|" -e "s|^Exec=lunar$|Exec=$repo/build/linux/bin/lunar|" \
		"$repo/scripts/packaging/linux/lunar.desktop" > "$apps/lunar-dev.desktop"
	command -v update-desktop-database >/dev/null && update-desktop-database "$apps" >/dev/null 2>&1 || true
	command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$icons" 2>/dev/null || true
	say "Installed $apps/lunar-dev.desktop (Exec=$repo/build/linux/bin/lunar)"
}

cmd="${1:-}"
[[ $# -gt 0 ]] && shift
case "$cmd" in
	bootstrap) bootstrap ;;
	test) rock_tool busted "$@" ;;
	lint) if [[ $# -eq 0 ]]; then set -- src/lua plugins scripts; fi; rock_tool luacheck "$@" ;;
	docs) docs "$@" ;;
	check) rock_tool busted && rock_tool luacheck src/lua plugins scripts && docs --check --out dist/docs-ci ;;
	desktop) desktop "$@" ;;
	*) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

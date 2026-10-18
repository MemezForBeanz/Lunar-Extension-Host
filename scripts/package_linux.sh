#!/usr/bin/env bash
# scripts/package_linux.sh — build the Linux install packages from a release build.
#
#   scripts/package_linux.sh [--build-dir build/linux-rel] [--out dist/linux] [--setup] [--deb] [--appimage]
#
# With no format flag it builds all three:
#   Lunar-Setup-<ver>-x86_64.run            the graphical installer (recommended): a self-extracting
#                                           script that runs the same wizard as Windows; installs
#                                           for you (~/.local) or for everyone (/opt/lunar), with
#                                           a choice of extensions, upgrade and uninstall
#   lunar-extension-host_<ver>_<arch>.deb   installs to /opt/lunar, with /usr/bin/lunar,
#                                           a menu entry and hicolor icons (Ubuntu/Mint/Debian)
#   Lunar-<ver>-x86_64.AppImage             one file that runs without installing
#
# All carry the same app folder: the `lunar` executable with assets/, certs/ and
# plugins/ beside it (the Lua tree is embedded in release builds), like the
# Windows portable zip. GTK 3, OpenSSL 3, fontconfig and X11 come from the host
# system. Build first with:
#   cmake --preset linux-release && cmake --build --preset linux-release

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$repo/build/linux-rel"
out_dir="$repo/dist/linux"
want_deb=0
want_appimage=0
want_setup=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--build-dir) build_dir="$(cd "$2" && pwd)"; shift 2 ;;
		--out) mkdir -p "$2"; out_dir="$(cd "$2" && pwd)"; shift 2 ;;
		--deb) want_deb=1; shift ;;
		--appimage) want_appimage=1; shift ;;
		--setup) want_setup=1; shift ;;
		-h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
if [[ $want_deb -eq 0 && $want_appimage -eq 0 && $want_setup -eq 0 ]]; then want_deb=1; want_appimage=1; want_setup=1; fi

die() { echo "package_linux: $*" >&2; exit 1; }
info() { echo "[package] $*"; }

# --- inputs -----------------------------------------------------------------

version="$(sed -n 's/^local APP_VERSION = "\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' "$repo/src/lua/core/main.lua")"
[[ -n "$version" ]] || die "APP_VERSION not found in src/lua/core/main.lua"

bin="$build_dir/bin"
[[ -x "$bin/lunar" ]] || die "$bin/lunar not found: build the linux-release preset first"
grep -q '^LUNAR_DEV_BUILD:BOOL=OFF' "$build_dir/CMakeCache.txt" 2>/dev/null \
	|| die "$build_dir is not a release build (LUNAR_DEV_BUILD must be OFF): use the linux-release preset"
for d in assets certs plugins; do [[ -d "$bin/$d" ]] || die "$bin/$d is missing"; done

pkg_files="$repo/scripts/packaging/linux"
icon_dir="$repo/assets/app-icon"
icon_sizes=(16 24 32 48 64 128 256)
for s in "${icon_sizes[@]}"; do [[ -f "$icon_dir/lunar-$s.png" ]] || die "missing $icon_dir/lunar-$s.png"; done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out_dir"

# The app folder both packages carry. strip --strip-unneeded keeps .dynsym, which
# extensions' FFI and native modules resolve against.
stage_app() {   # stage_app <dir>
	local dir="$1"
	mkdir -p "$dir"
	install -m 0755 "$bin/lunar" "$dir/lunar"
	strip --strip-unneeded "$dir/lunar"
	cp -a "$bin/assets" "$bin/certs" "$bin/plugins" "$dir/"
	# Windows build inputs that ride along in assets/ (the exe resource script,
	# manifest and .ico, and the SVG they come from) aren't used on Linux.
	rm -f "$dir/assets/"*.rc "$dir/assets/"*.manifest "$dir/assets/"*.ico "$dir/assets/lunar-icon.svg"
	find "$dir" -type d -exec chmod 0755 {} +
	find "$dir" -type f ! -name lunar -exec chmod 0644 {} +
}

stage_icons() {   # stage_icons <share dir>
	local s
	for s in "${icon_sizes[@]}"; do
		install -D -m 0644 "$icon_dir/lunar-$s.png" "$1/icons/hicolor/${s}x${s}/apps/lunar.png"
	done
}

# --- .deb ---------------------------------------------------------------------

build_deb() {
	command -v dpkg-deb >/dev/null || die "dpkg-deb not found (install dpkg)"
	local arch root deb depends size
	arch="$(dpkg --print-architecture)"
	root="$work/deb"
	stage_app "$root/opt/lunar"
	mkdir -p "$root/usr/bin"
	ln -s ../../opt/lunar/lunar "$root/usr/bin/lunar"
	install -D -m 0644 "$pkg_files/lunar.desktop" "$root/usr/share/applications/lunar.desktop"
	stage_icons "$root/usr/share"
	install -D -m 0644 "$repo/LICENSE" "$root/usr/share/doc/lunar-extension-host/copyright"

	# Runtime dependencies from the libraries the executable actually links.
	depends=""
	if command -v dpkg-shlibdeps >/dev/null; then
		mkdir -p "$work/shlibs/debian"
		printf 'Source: lunar-extension-host\n\nPackage: lunar-extension-host\nArchitecture: any\n' \
			> "$work/shlibs/debian/control"
		depends="$(cd "$work/shlibs" && dpkg-shlibdeps -O "$root/opt/lunar/lunar" 2>/dev/null \
			| sed -n 's/^shlibs:Depends=//p')"
	fi
	if [[ -z "$depends" ]]; then
		info "dpkg-shlibdeps unavailable or failed; using the Ubuntu 24.04 dependency list"
		depends="libc6 (>= 2.39), libgtk-3-0t64 | libgtk-3-0, libssl3t64 | libssl3, libfontconfig1, libx11-6, libxext6, libglib2.0-0t64 | libglib2.0-0"
	fi

	find "$root" -type d -exec chmod 0755 {} +   # mktemp/umask leave group-writable dirs
	size="$(du -sk --exclude=DEBIAN "$root" | cut -f1)"
	mkdir -p "$root/DEBIAN"
	cat > "$root/DEBIAN/control" <<EOF
Package: lunar-extension-host
Version: $version
Section: utils
Priority: optional
Architecture: $arch
Maintainer: Hayden Phillips <haydenphillips1115@gmail.com>
Installed-Size: $size
Depends: $depends
Conflicts: lunar
Description: Lunar, a desktop host for Lua tool extensions
 Lunar Extension Host runs Lua extensions as tabs in one window: built-in
 settings, theming, motion, process and HTTPS services for tools that would
 otherwise each need their own GUI.
 .
 Installs to /opt/lunar with the "lunar" command. Conflicts with the unrelated
 "lunar" calendar package, which also provides /usr/bin/lunar.
EOF
	deb="$out_dir/lunar-extension-host_${version}_${arch}.deb"
	dpkg-deb --build --root-owner-group -Zxz "$root" "$deb" >/dev/null
	info "deb: $deb ($(du -h "$deb" | cut -f1))"
	if command -v lintian >/dev/null; then
		info "lintian (informational):"
		lintian --no-tag-display-limit "$deb" || true
	fi
}

# --- AppImage -----------------------------------------------------------------

downloads="$repo/vendor/.downloads"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage"
APPIMAGETOOL_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
RUNTIME_URL="https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64"
RUNTIME_SHA256="2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d"

fetch() {   # fetch <url> <sha256> <file name> -> path on stdout
	local url="$1" sum="$2" path="$downloads/$3"
	mkdir -p "$downloads"
	if [[ ! -f "$path" ]] || ! echo "$sum  $path" | sha256sum -c --quiet - 2>/dev/null; then
		echo "[package] downloading $3" >&2
		curl -fsSL --retry 3 -o "$path.partial" "$url"
		echo "$sum  $path.partial" | sha256sum -c --quiet - || { rm -f "$path.partial"; die "checksum mismatch for $3"; }
		mv "$path.partial" "$path"
	fi
	echo "$path"
}

build_appimage() {
	[[ "$(uname -m)" == "x86_64" ]] || die "the AppImage tooling here is pinned for x86_64"
	local appdir tool runtime image
	appdir="$work/Lunar.AppDir"
	stage_app "$appdir/opt/lunar"
	stage_icons "$appdir/usr/share"
	install -m 0755 "$pkg_files/AppRun" "$appdir/AppRun"
	install -m 0644 "$pkg_files/lunar.desktop" "$appdir/lunar.desktop"
	install -D -m 0644 "$pkg_files/lunar.desktop" "$appdir/usr/share/applications/lunar.desktop"
	install -m 0644 "$icon_dir/lunar-256.png" "$appdir/lunar.png"
	find "$appdir" -type d -exec chmod 0755 {} +
	ln -s lunar.png "$appdir/.DirIcon"

	tool="$(fetch "$APPIMAGETOOL_URL" "$APPIMAGETOOL_SHA256" appimagetool-1.9.1-x86_64.AppImage)"
	runtime="$(fetch "$RUNTIME_URL" "$RUNTIME_SHA256" appimage-runtime-20251108-x86_64)"
	chmod +x "$tool"
	image="$out_dir/Lunar-${version}-x86_64.AppImage"
	# Extract-and-run: no FUSE needed (CI runners don't have it).
	APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$tool" --no-appstream --runtime-file "$runtime" \
		"$appdir" "$image" >"$work/appimagetool.log" 2>&1 \
		|| { cat "$work/appimagetool.log" >&2; die "appimagetool failed"; }
	chmod +x "$image"
	info "AppImage: $image ($(du -h "$image" | cut -f1))"
}

# --- Setup (.run) -------------------------------------------------------------
# A shell stub (scripts/packaging/linux/setup-stub.sh) followed by a tar.xz of the
# app folder plus setup/: the installer scripts, the console executable the root
# helper and quiet installs use, the Lua they need, icons, the menu entry and the
# license. The stub unpacks it to a private temp folder and runs the wizard.

build_setup() {
	command -v xz >/dev/null || die "xz not found (install xz-utils)"
	command -v sha256sum >/dev/null || die "sha256sum not found"
	[[ -x "$bin/lunar-cli" ]] || die "$bin/lunar-cli not found: build the linux-release preset first"
	local stage="$work/setup-payload" setup tarxz sum run s
	stage_app "$stage"
	setup="$stage/setup"
	mkdir -p "$setup/icons" "$setup/lua/installer" "$setup/lua/core/platform" "$setup/lua/core/lib"
	install -m 0755 "$bin/lunar-cli" "$setup/lunar-cli"
	strip --strip-unneeded "$setup/lunar-cli"
	install -m 0644 "$repo/scripts/installer/setup.lua" "$repo/scripts/installer/uninstall.lua" \
		"$repo/scripts/installer/root_helper.lua" "$setup/"
	# The Lua the console executable needs (it has no embedded tree): the installer and
	# the platform layer it stands on.
	install -m 0644 "$repo"/src/lua/installer/*.lua "$setup/lua/installer/"
	install -m 0644 "$repo/src/lua/core/platform.lua" "$setup/lua/core/"
	install -m 0644 "$repo"/src/lua/core/platform/*.lua "$setup/lua/core/platform/"
	install -m 0644 "$repo/src/lua/core/lib/ExtensionManifest.lua" "$setup/lua/core/lib/"
	for s in "${icon_sizes[@]}"; do install -m 0644 "$icon_dir/lunar-$s.png" "$setup/icons/"; done
	install -m 0644 "$pkg_files/lunar.desktop" "$setup/lunar.desktop"
	install -m 0644 "$repo/LICENSE" "$setup/LICENSE"
	printf '{"version":"%s","platform":"linux"}\n' "$version" > "$setup/payload.json"
	find "$stage" -type d -exec chmod 0755 {} +

	tarxz="$work/setup-payload.tar.xz"
	tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2026-01-01 00:00Z' -C "$stage" -cf - . \
		| xz -9e -T0 > "$tarxz"
	sum="$(sha256sum "$tarxz" | cut -d' ' -f1)"
	run="$out_dir/Lunar-Setup-${version}-x86_64.run"
	sed -e "s/@VERSION@/$version/g" -e "s/@SHA256@/$sum/" "$pkg_files/setup-stub.sh" > "$run"
	cat "$tarxz" >> "$run"
	chmod +x "$run"
	info "setup: $run ($(du -h "$run" | cut -f1))"
}

info "Lunar $version from $build_dir"
[[ $want_setup -eq 1 ]] && build_setup
[[ $want_deb -eq 1 ]] && build_deb
[[ $want_appimage -eq 1 ]] && build_appimage
info "done: $out_dir"

#!/bin/sh
# Lunar @VERSION@ setup: a self-extracting installer.
#
# This file is a shell script followed by a compressed archive (tar.xz). It unpacks
# the archive to a private temporary folder, runs the Lunar installer from it and
# removes the folder again. Nothing else on the system is touched until you choose
# an install type in the window.
#
#   sh Lunar-Setup-@VERSION@-x86_64.run [options]
#
#   --quiet               no window: install with the options below (needs no display)
#   --type user|system    "Just for me" (default) or "Everyone" (asks for the admin password)
#   --extensions LIST     all (default), none, or comma-separated extension ids
#   --no-launch           don't offer to start Lunar at the end
#   --extract DIR         only unpack the files to DIR
#   --check               verify this file's integrity and exit
#   -h, --help            this text
#
# To remove Lunar later, run "lunar-uninstall" or use the "Uninstall Lunar" menu entry.

PAYLOAD_SHA256='@SHA256@'

die() { echo "Lunar setup: $*" >&2; exit 1; }

self="$0"
case "$self" in /*) ;; *) self="$(pwd)/$self" ;; esac
[ -r "$self" ] || die "cannot read $self"

marker_line="$(awk '/^__LUNAR_PAYLOAD_BELOW__$/ { print NR + 1; exit }' "$self")"
[ -n "$marker_line" ] || die "this file is damaged (no payload)"

payload() { tail -n "+$marker_line" "$self"; }

check() {
	command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum not found; skipping the integrity check" >&2; return 0; }
	sum="$(payload | sha256sum | cut -d' ' -f1)"
	[ "$sum" = "$PAYLOAD_SHA256" ] || die "this file is damaged (checksum mismatch); download it again"
}

quiet=0
extract_to=""
n=$#
while [ "$n" -gt 0 ]; do
	a="$1"
	shift
	n=$((n - 1))
	case "$a" in
		-h|--help) sed -n '2,19p' "$self" | sed 's/^# \{0,1\}//'; exit 0 ;;
		--check) check; echo "OK"; exit 0 ;;
		--extract)
			[ $# -ge 1 ] || die "--extract needs a folder"
			extract_to="$1"; shift; n=$((n - 1))
			continue ;;
		--quiet|-q) quiet=1 ;;
	esac
	set -- "$@" "$a"   # keep it: rotate the argument to the back
done

command -v tar >/dev/null 2>&1 || die "tar is required"
command -v xz >/dev/null 2>&1 || die "xz is required (install the xz or xz-utils package)"
check

if [ -n "$extract_to" ]; then
	mkdir -p "$extract_to" || die "cannot create $extract_to"
	payload | tar -xJ -C "$extract_to" || die "unpacking failed"
	echo "Unpacked to $extract_to"
	exit 0
fi

if [ "$quiet" -eq 0 ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
	die "no graphical display found. Run it from the desktop, or add --quiet to install without a window."
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/lunar-setup.XXXXXX")" || die "cannot create a temporary folder"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

payload | tar -xJ -C "$tmp" || die "unpacking failed"

# The window needs the full program; a quiet install only needs the small console one.
if [ "$quiet" -eq 1 ]; then runner="$tmp/setup/lunar-cli"; else runner="$tmp/lunar"; fi

# Run (not exec) so the temporary folder is removed afterwards.
"$runner" "$tmp/setup/setup.lua" "$@"
exit $?

__LUNAR_PAYLOAD_BELOW__

#!/usr/bin/env bash
# scripts/build_wiki.sh — build the GitHub wiki pages into a folder.
#
#   scripts/build_wiki.sh [out-dir]     (default dist/wiki)
#
# Writes: Home.md (docs/index.md), one page per guide in docs/ (links between
# guides rewritten to wiki links), the API reference from LDoc (API-*.md, via
# scripts/ldoc_wiki.lua) and _Sidebar.md. The docs workflow pushes the folder
# to the repository's wiki. Needs `scripts/dev.sh bootstrap` (for ldoc).

set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$repo/dist/wiki}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
rm -f "$out"/*.md

# Guides: docs/<name>.md -> <name>.md; "[x](other.md#a)" -> "[x](other#a)".
for f in "$repo"/docs/*.md; do
	name="$(basename "$f" .md)"
	[[ "$name" == index ]] && dest="$out/Home.md" || dest="$out/$name.md"
	sed -E 's/\]\(([A-Za-z0-9_-]+)\.md(#[^)]*)?\)/](\1\2)/g; s/\]\(index(#[^)]*)?\)/](Home\1)/g' "$f" > "$dest"
done
printf '\n---\n\n**[API Reference](API-Reference)**: every module, class and function, generated from the source.\n' >> "$out/Home.md"

# API reference.
ldoc="$repo/vendor/luarocks-tree/bin/ldoc"
[[ -x "$ldoc" ]] || { echo "build_wiki: run scripts/dev.sh bootstrap first" >&2; exit 1; }
(cd "$repo" && LUNAR_WIKI_OUT="$out" LUA_PATH="$repo/scripts/?.lua;;" \
	"$ldoc" -c config.ld --filter ldoc_wiki.run . >/dev/null)

# Sidebar: Home, the guides (by their first heading), then the API reference.
{
	echo "**[Home](Home)**"
	echo
	echo "**Guides**"
	echo
	for f in "$repo"/docs/*.md; do
		name="$(basename "$f" .md)"
		[[ "$name" == index ]] && continue
		title="$(sed -n 's/^# //p' "$f" | head -n 1)"
		echo "- [${title:-$name}]($name)"
	done
	echo
	echo "**[API Reference](API-Reference)**"
} > "$out/_Sidebar.md"

echo "wiki: $(ls "$out" | wc -l) pages in $out"

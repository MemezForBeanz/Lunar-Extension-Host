#!/usr/bin/env bash
# Inputs arrive through the environment, never evaluated as shell code.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
selection="${LUNAR_TEST_OVERRIDE:-${LUNAR_TEST_SCRIPTS:-}}"
[[ -n "${selection//[[:space:]]/}" ]] || { echo 'Choose at least one Lua script.' >&2; exit 1; }
selection="${selection//;/,}"
[[ "$selection" != *, ]] || { echo 'Empty script name after separator.' >&2; exit 1; }
IFS=',' read -r -a names <<< "$selection"
scripts=()
for name in "${names[@]}"; do
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    [[ -n "$name" && "$name" != *[/\\:]* ]] || { echo "Invalid script filename: $name" >&2; exit 1; }
    [[ "$name" == *.lua ]] || name+=.lua
    [[ -f "$repo/scripts/$name" ]] || { echo "Script not found: $name" >&2; exit 1; }
    scripts+=("$repo/scripts/$name")
done
export LUNAR_REPO="$repo"
if [[ "${LUNAR_TEST_ALL_PACKS:-no}" == yes ]]; then
    [[ -d "${LUNAR_TEST_PACKS_DIR:-}" ]] || { echo 'Org packs directory does not exist.' >&2; exit 1; }
    export LUNAR_PROFILE_DIR="$(cd "$LUNAR_TEST_PACKS_DIR" && pwd)" LUNAR_PROFILE='*'
else
    unset LUNAR_PROFILE LUNAR_PROFILE_DIR
fi
cd "$repo/build/linux/bin"
failed=0
for script in "${scripts[@]}"; do
    echo "Running $script"
    status=0
    ./lunar "$script" || status=$?
    echo "Exited with code $status"
    if (( status != 0 )); then failed=1; fi
done
exit "$failed"

#!/usr/bin/env bash
# scripts/winvm.sh — drive the Windows 11 test VM from the Linux host.
#
# Setup (once): scripts/winvm/create.sh defines the VM; install Windows and
# virtio-win-guest-tools in it; run `scripts/winvm.sh serve-setup` here and the
# command it prints inside the VM (scripts/winvm/guest-setup.ps1). Then:
#
#   scripts/winvm.sh start | stop | status | ip | ssh [cmd...]
#   scripts/winvm.sh sync               copy the working tree to C:\lunar\src
#   scripts/winvm.sh bootstrap          scripts\bootstrap.ps1 -Dev in the VM (first time, ~15 min)
#   scripts/winvm.sh build | test | lint | docs
#   scripts/winvm.sh harness <script.lua> [args...]   run a CLI harness script
#   scripts/winvm.sh gui <script.lua> [args...]       run a GUI script on the VM's desktop
#                                                      and print its output
#   scripts/winvm.sh check              sync + build + test + lint + docs
#
# The VM's user name is read from $WINVM_USER or ~/.config/lunar-winvm/user.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="${WINVM_NAME:-lunar-win11}"
KEY="$HOME/.ssh/lunar_winvm"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/lunar-winvm"
CONNECT=qemu:///system

say() { printf '\033[36m[winvm] %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31m[winvm] %s\033[0m\n' "$*" >&2; exit 1; }

virsh_() {
	if id -nG | tr ' ' '\n' | grep -qx libvirt; then virsh -c "$CONNECT" "$@"
	else sg libvirt -c "virsh -c $CONNECT $(printf '%q ' "$@")"; fi
}

vm_user() {
	if [[ -n "${WINVM_USER:-}" ]]; then echo "$WINVM_USER"; return; fi
	[[ -f "$CONF/user" ]] || die "set the VM user: mkdir -p $CONF && echo <windows-user> > $CONF/user"
	cat "$CONF/user"
}

vm_ip() {
	local ip
	ip="$(virsh_ domifaddr "$NAME" 2>/dev/null | awk '/ipv4/ { sub(/\/.*/, "", $4); print $4; exit }')"
	[[ -n "$ip" ]] || die "no IP for $NAME yet (is it running and past boot?)"
	echo "$ip"
}

ssh_opts=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$CONF/known_hosts"
	-o ConnectTimeout=10 -o ServerAliveInterval=30 -o BatchMode=yes)

vm_ssh() {
	mkdir -p "$CONF"
	ssh "${ssh_opts[@]}" "$(vm_user)@$(vm_ip)" "$@"
}

vm_scp() {   # vm_scp <local> <remote-path>
	mkdir -p "$CONF"
	scp -q "${ssh_opts[@]}" "$1" "$(vm_user)@$(vm_ip):$2"
}

# Run PowerShell in C:\lunar\src with MSYS2's MinGW tools on PATH.
vm_ps() {
	vm_ssh "\$env:PATH = 'C:\\msys64\\mingw64\\bin;C:\\Program Files\\Git\\cmd;' + \$env:PATH; \$env:LUNAR_REPO = 'C:\\lunar\\src'; Set-Location C:\\lunar\\src; $*; exit \$LASTEXITCODE"
}

wait_ssh() {
	local i
	for i in $(seq 1 90); do
		if vm_ssh "exit 0" 2>/dev/null; then return 0; fi
		sleep 2
	done
	die "the VM didn't answer on SSH"
}

cmd_sync() {
	local tgz
	tgz="$(mktemp --suffix=.tar.gz)"
	# Tracked and untracked-but-not-ignored files: the working tree as it is,
	# without build trees or the Linux-side vendor/ caches.
	# Tracked files deleted in the working tree (renames not yet committed) are
	# still listed by ls-files; tar skips them instead of failing.
	(cd "$repo" && git ls-files -co --exclude-standard -z \
		| tar czf "$tgz" --null --ignore-failed-read --warning=no-failed-read -T -)
	say "sync $(du -h "$tgz" | cut -f1) -> C:\\lunar\\src"
	vm_scp "$tgz" "C:/lunar/src.tar.gz"
	rm -f "$tgz"
	# -m: stamp the files with the time of extraction, not their Linux mtime. A
	# file edited before the VM's last build but synced after it would otherwise
	# look older than the build output, and make/CMake would keep the stale copy
	# (the Lua bundle is regenerated from these files). Costs a full Lunar rebuild
	# after each sync, a few seconds; vendor/ and the IUP fork aren't synced.
	vm_ssh "New-Item -ItemType Directory -Force C:\\lunar\\src | Out-Null; tar -xmzf C:\\lunar\\src.tar.gz -C C:\\lunar\\src; exit \$LASTEXITCODE"
}

# A GUI job: write the command, start the interactive task, wait for it.
cmd_gui() {
	local script="$1"; shift
	local args="" a
	for a in "$@"; do args+=" '$a'"; done
	local job
	job="$(mktemp)"
	cat > "$job" <<EOF
Set-Location C:\\lunar\\src\\build\\win\\bin
\$env:LUNAR_REPO = 'C:\\lunar\\src'
& .\\Lunar.exe "C:\\lunar\\src\\$script"$args
exit \$LASTEXITCODE
EOF
	vm_scp "$job" "C:/lunar/job/command.ps1"
	rm -f "$job"
	vm_ssh "Remove-Item C:\\lunar\\job\\done -ErrorAction SilentlyContinue; Start-ScheduledTask -TaskName LunarRun"
	local i code=""
	for i in $(seq 1 600); do
		code="$(vm_ssh "if (Test-Path C:\\lunar\\job\\done) { Get-Content C:\\lunar\\job\\done }" 2>/dev/null | tr -d '\r')"
		[[ -n "$code" ]] && break
		sleep 1
	done
	vm_ssh "Get-Content C:\\lunar\\job\\output.log -ErrorAction SilentlyContinue"
	[[ -n "$code" ]] || die "the GUI job didn't finish within 10 minutes"
	return "$code"
}

cmd_serve_setup() {
	local dir
	dir="$(mktemp -d)"
	cp "$repo/scripts/winvm/guest-setup.ps1" "$dir/"
	cp "$KEY.pub" "$dir/lunar_winvm.pub"
	# The host's time zone as a Windows id (guest-setup.ps1 applies it); a small map
	# of common zones, falling back to UTC.
	case "$(timedatectl show -p Timezone --value 2>/dev/null)" in
		America/Chicago) echo "Central Standard Time" ;;
		America/New_York) echo "Eastern Standard Time" ;;
		America/Denver) echo "Mountain Standard Time" ;;
		America/Phoenix) echo "US Mountain Standard Time" ;;
		America/Los_Angeles) echo "Pacific Standard Time" ;;
		Europe/London) echo "GMT Standard Time" ;;
		Europe/Berlin|Europe/Paris|Europe/Amsterdam) echo "W. Europe Standard Time" ;;
		*) echo "UTC" ;;
	esac > "$dir/timezone.txt"
	say "serving guest-setup.ps1 on http://192.168.122.1:8765 (Ctrl+C when the VM has fetched it)"
	cat >&2 <<'EOF'
In the VM, in an elevated Windows PowerShell:

  Set-ExecutionPolicy -Scope Process Bypass -Force
  iwr http://192.168.122.1:8765/guest-setup.ps1 -OutFile $env:TEMP\guest-setup.ps1
  & $env:TEMP\guest-setup.ps1

EOF
	cd "$dir" && exec python3 -m http.server 8765 --bind 192.168.122.1
}

cmd="${1:-}"
[[ $# -gt 0 ]] && shift
case "$cmd" in
	start) virsh_ start "$NAME" && say "started; waiting for SSH" && wait_ssh && say "ready at $(vm_ip)" ;;
	stop) virsh_ shutdown "$NAME" ;;
	status) virsh_ domstate "$NAME" ;;
	ip) vm_ip ;;
	ssh) vm_ssh "$@" ;;
	serve-setup) cmd_serve_setup ;;
	sync) cmd_sync ;;
	bootstrap) vm_ps "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\\bootstrap.ps1 -Dev" ;;
	build) vm_ps "cmake --preset dev; if (\$LASTEXITCODE -eq 0) { cmake --build --preset dev }" ;;
	test) vm_ps "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\\test.ps1" ;;
	lint) vm_ps "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\\lint.ps1" ;;
	docs) vm_ps "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\\docs.ps1 -OutDir dist\\docs-ci -Check" ;;
	harness)
		[[ $# -ge 1 ]] || die "usage: winvm.sh harness <script.lua> [args...]"
		s="$1"; shift
		vm_ps "\$env:LUA_PATH='src/lua/?.lua;spec/support/?.lua;vendor/luarocks-tree/share/lua/5.1/?.lua;;'; build\\win\\bin\\LunarCLI.exe $s $*" ;;
	gui) [[ $# -ge 1 ]] || die "usage: winvm.sh gui <script.lua> [args...]"; cmd_gui "$@" ;;
	check) cmd_sync && "$0" build && "$0" test && "$0" lint && "$0" docs ;;
	*) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

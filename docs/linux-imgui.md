# Linux ImGui host

Linux has an SDL3/OpenGL3 backend alongside the existing IUP/GTK host. It uses
the same Lua UI, motion, themes, extension API, and tab/window controllers as
Windows. SDL owns the native windows; Fontconfig resolves system and bundled
fonts. The renderer requires desktop OpenGL 3.3.

## Build

Install a C/C++ toolchain, CMake, Ninja, Python 3, pkg-config, LuaJIT 2.1,
OpenSSL development files, Fontconfig, GLib, GdkPixbuf, and OpenGL development
files. Install SDL3 3.2 or newer if your distribution supplies it; otherwise
CMake downloads and builds the pinned SDL 3.2.20 source archive. Building SDL
also requires the development files for your X11 and/or Wayland desktop.

On Ubuntu 24.04, the dependency list and bootstrap commands are recorded in
`.github/workflows/linux-imgui.yml`. LuaJIT and the Lua modules are bootstrapped
the same way as the existing Linux build (`scripts/dev.sh bootstrap`).

```sh
cmake --preset linux-imgui-dev
cmake --build --preset linux-imgui-dev
build/linux-imgui-dev/bin/lunar
```

The default LuaJIT prefix is `/usr/local`; use
`-DLUNAR_LUAJIT_PREFIX=/usr` when building against distro LuaJIT headers and its
static archive. Release builds use `linux-imgui-release`. The existing
`linux-dev` and `linux-release` presets explicitly select IUP.

## Verification

Run in an isolated desktop/display so probes cannot affect your clipboard or
other application windows:

```sh
SDL_VIDEO_DRIVER=x11 LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a \
  build/linux-imgui-dev/bin/lunar scripts/backend_conformance.lua /tmp/conformance.json

mkdir -p /tmp/lunar-probe
LUNAR_PROFILE_DIR=/path/to/orgpacks LUNAR_PROFILE='*' \
  build/linux-imgui-dev/bin/lunar scripts/imgui_linux_smoke.lua /tmp/lunar-probe
```

The full-shell probe requires the HPE and Microchip packs. It checks group
identity when switching packs, collapse/restore, and extension/group pop-out
and return, and saves BMP captures. It drives Lua control events; it does not
replace physical mouse/keyboard and compositor integration testing.

`scripts/imgui_linux_input.lua` separately checks real X11 pointer, button,
arrow-key and text events using `xdotool`. CI runs this on a private Xvfb
display. The implementation was also built on Alpine Linux 3.22 and exercised
with Mesa under Xvfb and a headless Weston Wayland session, including the
full-shell/org-pack probe on both display systems.

The additional native subprocess harness did not pass completely in the Alpine
VM: three host-death cleanup checks failed (grandchild PID reporting, grandchild
cleanup, and cleanup with a stopped supervisor). Other process checks passed.
This is unresolved and must be investigated before treating Linux as release-ready.

## Desktop integration still to complete

* Native file/message dialogs and tray integration.
* Embedded video surfaces and desktop compositor/media effects.
* IME candidate placement and mixed-monitor fractional-scale coverage.
* Installable ImGui packages and broader distribution/GPU testing.

Wayland lets the compositor place top-level windows. The backend does not
force popup positions there and reports `global_coordinates = false` through
`window("capabilities")`. Its main-relative coordinates are internal layout
coordinates, not global desktop positions. Cross-window tab dragging needs
native drag-and-drop integration before it can be considered supported on
Wayland; within-window reorder/group animations use the existing Lua code.

This is a Linux host implementation, not a claim of complete IUP parity.

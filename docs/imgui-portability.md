# The ImGui host beyond Windows: devices, embedding, other platforms, WebAssembly

Goal: the same Lua application and extensions on each kind of target, with the memory
and responsiveness of the IUP build or better.

**Scope (2026-11-13): no web for now.** The WebAssembly phase is deferred, and with it
the move to standard Lua 5.4 (Phase 1), which only the browser needed: LuaJIT runs
natively on Linux, ARM boards and macOS. Order now: Phase 0, then 3 (devices), 4
(embedding) and 2 (the portable backend). Phase 0 is done: the contract is code,
`core.imgui.backend.contract`, checked on the headless backend by
`spec/imgui_backend_contract_spec.lua` and on the Windows backend by
`scripts/backend_conformance.lua`.

| Target | What it needs |
|---|---|
| Windows desktop (today) | done: Win32 + Direct3D 11, WARP by default, GPU fallback |
| Low-power devices (thin clients, kiosks, small boards) | a renderer that suits weak CPUs and small RAM; redraw only what changed |
| Hosted inside another app | the UI as a library the host drives, or a child window of a host window |
| Other platforms (Linux, embedded Linux, macOS) | a portable window/input/render backend |
| WebAssembly (browser) | standard Lua instead of LuaJIT, WebGL, and a server for processes and sockets |

## Where things stand

The UI core is already portable in design. `core.imgui` (Element, Layout, Runtime,
widgets, Draw) talks to a **backend table** (`B.open`, `B.frame_begin`, the draw
primitives, text measuring, textures, window operations), and two backends exist: the
Windows one (`backend/Native.lua` over `lunarimgui`) and the headless one
(`backend/Null.lua`) that runs the whole test suite. The FFI is optional: without it the
Windows backend falls back to the plain Lua C API.

What ties the host to Windows and LuaJIT today:

- **`lunarimgui.cpp`**: Win32 windows and input, Direct3D 11, GDI text measuring (which is
  what keeps layouts pixel-identical to IUP on Windows), the clipboard, file dialogs, the
  tray icon and the video child window.
- **LuaJIT-only Lua** (counted in `src/lua`): `goto` in 4 files, the `bit` library in 10,
  `setfenv` in 1, `newproxy` in 1, and the FFI in 8 core files (sqlite, Database,
  HttpTokens, svgicon, TitleBar, VideoHost, BackgroundWindow, cimgui). All small.
- **Platform services**: processes (`subprocess.h`, ProcessJob: 10 files) and sockets
  (luasocket/luasec/copas: 9 files). These exist on every native target; a browser has
  neither.

CMake already builds Linux (the IUP/GTK app and the headless `LunarCLI`), so the native
modules (lfs, cjson, luasocket, luasec, subprocess) are already portable.

## Plan

Each phase ends with something runnable and measured against IUP.

### Phase 0: the backend contract (small)

- Write the backend table down as a contract (calls, argument units, the input event
  format, ownership of textures) and a conformance spec that runs against every backend:
  Null, Windows, and each new one.
- Renderer policy per platform, chosen at start and overridable (`LUNAR_RENDERER`, later a
  setting). Done for Windows: WARP by default (49 MiB vs 81 MiB on the GPU, IUP 44), the
  GPU on machines with two logical processors or fewer, where software rendering would
  starve the app.

### Phase 1: Lua portability (the WebAssembly gate)

LuaJIT cannot target WebAssembly, so the core must run on standard Lua 5.4:

- a `core.compat` module: `bit` over 5.4 operators, `unpack`, `setfenv` via `load` with an
  environment, `newproxy` via a table with `__gc`;
- FFI-free paths for the 8 FFI files (each already has, or gets, a C-API or pure-Lua path);
- the full spec suite running under Lua 5.4 as well as LuaJIT, so neither drifts.

LuaJIT stays the desktop runtime (its speed and FFI matter on weak CPUs too).

### Phase 2: a portable backend (Linux, embedded Linux, macOS)

- **SDL3** for windows, input, IME, the clipboard and dialogs, and **OpenGL ES 3** to draw
  the same ImGui draw lists. SDL3 also covers KMS/DRM, which is how kiosks and small boards
  run with no desktop at all.
- **Text without GDI**: stb_truetype is already wired in (`LUNAR_GLYPHS=stb`); the host
  reads the same `hhea`/`OS/2` metrics. Layouts match IUP to the pixel only on Windows, where
  GDI measures; elsewhere they follow the platform's own fonts.
- A **software path** for devices with no usable GPU: the draw lists rasterized into an SDL
  surface.
- Verified the way the Windows host is: the conformance spec, the probe scripts, and
  memory and frame-time numbers against IUP's GTK build on the same machine.

### Phase 3: low-power devices

- **Redraw only what changed** (dirty rectangles): today every frame redraws the whole
  window. This is the largest win for software rendering, WARP and the browser alike.
- Frame pacing tied to input and timers only (mostly in place), and the memory budgets
  added in the last pass (font mapping, bounded caches) carried to every backend.

### Phase 4: hosted inside another app

Two modes, the same core:

- **Library mode**: `lunarui` as a library with a small C API. The host creates a UI,
  feeds it input, calls `frame()`, and draws the returned ImGui draw data with its own
  renderer (the standard way ImGui is embedded), or lets the backend draw into a texture
  the host provides.
- **Child-window mode** (Windows): the UI in a `WS_CHILD` window of a host window, with
  the existing backend.

### Phase 5: WebAssembly

- Emscripten build: Lua 5.4, the core and extensions bundled into the module, SDL3's
  Emscripten port with **WebGL 2**, and an IndexedDB-backed file system for settings and data.
- **Capabilities**: a browser has no processes or raw sockets, so the host reports
  `process` and `network.raw` as unavailable. Extensions that need them (build queue, LSP,
  iLO Redfish, scan chain) either say so, or run against a **Lunar server** over a
  WebSocket: the headless `LunarCLI` already serves extensions (the media server does this
  today), so the browser UI becomes a remote front end for tools that must run on a machine.
- HTTP from extensions goes through `fetch` (subject to CORS) or through that server.

## Order and dependencies

Phase 1 comes first: it is the hard gate for WebAssembly and costs little. Phase 2 then
gives Linux and devices, Phase 3 the efficiency every small target needs, Phase 4 the
embedding API, and Phase 5 builds on all of them. New dependencies: SDL3 (zlib licence)
and the Emscripten SDK as a build tool; FreeType is optional.

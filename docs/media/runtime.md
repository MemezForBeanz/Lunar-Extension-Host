# Contained media tools

On Windows x86-64, the media extensions own their native dependencies. The host does not need
FFmpeg, Python, yt-dlp, or libmpv installed globally, and installing a source does not change PATH.

| Extension | Bundled tools | Purpose |
|---|---|---|
| `media-server` | FFmpeg/ffprobe 9.0.2; yt-dlp 2026.10.26 | File analysis, backdrop frames and supported-host extraction |
| `media` | libmpv build 20261107 | Native video/audio playback |

`runtime/windows-x86_64.json` is the versioned lock file for each extension. Every package has
a pinned HTTPS URL and SHA-256. Updating a runtime means reviewing and updating this lock,
then rebuilding the extension. The runtime does not silently follow upstream `latest` releases
or run an executable before its download has been verified.

## Packaging and first run

The normal Windows MSI and portable packager calls `scripts/package-media-runtime.ps1` for each
media extension in the staged payload. Its binaries, receipt, provenance and available upstream
license files then travel inside that extension's `runtime/windows-x86_64/` folder, allowing an
ordinary installation to work offline. Only installed media extensions are expanded.

For a separate extension package or a development plugin tree, run:

```powershell
./scripts/package-media-runtime.ps1 -PluginsRoot ./build/win/bin/plugins
```

If a development or lightweight extension package omits binaries, the extension starts its own
`runtime/bootstrap.ps1` in a managed background process. The bootstrap downloads only its locked
packages into a versioned per-extension cache under:

```text
%LOCALAPPDATA%/Lunar Extension Host/extensions/<extension-id>/runtime/<lock-id>/windows-x86_64/
```

It verifies the archives before extraction, validates archive paths, stages all files, creates a
receipt containing per-file hashes and package provenance, and promotes the complete directory.
A failed download or unpack leaves the active runtime intact. Concurrent processes share a
destination lock. No administrator prompt is needed for this fallback. Bootstrap errors and
timeouts become an explicit runtime status; the extension can continue serving unrelated work.

This initial runtime catalog supports Windows x86-64. Other targets report `unsupported` and
must be supplied with a platform-specific runtime package; Windows executables are never
downloaded on Linux/macOS. The media extensions resolve their contained tools directly, without
requiring environment variables or machine-wide copies.

## Lua integration

Each extension has a private copy of `libs.runtime`:

```lua
local runtime = require("libs.runtime").new(ctx, self)
runtime:start()                 -- returns immediately; ready or provisioning
runtime:tick()                  -- call from the extension's timer
local ffprobe = runtime:tool("ffprobe") -- absolute path, or nil until ready
local status = runtime:status() -- {state, message, tools = {name = boolean}}
runtime:close()                 -- kills/closes a pending preparation on unload
```

`tool()` checks a complete bundled receipt first, then a complete versioned cached receipt.
Partial and stale installations do not expose executables. States are `idle`, `preparing`,
`ready`, `failed`, and `unsupported`; `start()` can retry a failed preparation. The complete
payload is required before tools become visible. The host owns the bootstrap process through
`ctx:spawn`, and `close()` handles explicit extension shutdown.

Extractors support only the hosts and formats their pinned release knows. A bundled extractor
does not guarantee that a website's access checks, scripts, login requirements or DRM can be
handled, and it does not make unsupported separate video/audio formats playable automatically.
The source workflow must report those cases rather than pretending a stream is ready.

## Validation

```powershell
./scripts/test.ps1 spec/media_runtime_spec.lua
./scripts/check-media-runtime.ps1
```

The Lua specs cover bundled/cache precedence, stale receipts, one preparation per instance,
incomplete results, bounded timeouts, shutdown and unsupported platforms. The offline PowerShell
check verifies extraction and receipts using a tiny inert ZIP, failed-upgrade preservation and
the HTTPS requirement. It never downloads or executes its fixture executable.

Upstream provenance: [FFmpeg Windows builds](https://www.gyan.dev/ffmpeg/builds/),
[yt-dlp](https://github.com/yt-dlp/yt-dlp), and
[mpv Windows builds](https://github.com/shinchiro/mpv-winbuild-cmake/releases).
Runtime redistribution includes upstream licenses where supplied by the archive; distributors
must retain the corresponding upstream source and license obligations for their chosen builds.

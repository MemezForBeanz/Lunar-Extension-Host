# Lunar Media architecture

Lunar Media is two extensions. `media` is the desktop app. `media-server` runs under
`lunar-cli --headless` and owns the catalog. They talk over an authenticated HTTP API, so a
desktop can use a server on another machine, and a server carries no UI code.

The target metric is performance: the cost of serving a stream, and how well the server
stays responsive while it does other work.

## What runs where

| Work | Where | Why |
|---|---|---|
| Routes, validation, permissions, migrations, decisions, job policy | Lua | Changes often, and none of it is hot. |
| File and range delivery | C (`file_stream`) | No media byte enters Lua. A Lua string per chunk would cost a copy and collector pressure on the busiest path. |
| Directory walk | C (`logscan.list_dir`) | One native enumeration per directory instead of a stat for each entry. |
| SQLite | LuaJIT FFI, prepared statements | Calls are cheap and copy only the columns asked for. |
| Probing and conversion | `ffprobe` and `ffmpeg` as separate processes | A damaged file can crash a process, not the server. Decoding is already native, so FFI would add risk and no speed. |
| Poster decode and scaling | C worker thread (`media_native`) | Decoding on the UI thread would drop frames while scrolling. |

C runs where bytes move. Lua runs where decisions are made. A worker thread never calls Lua:
it posts to a queue that the event loop drains.

## The catalog

A **work** is what a person watches, a **file** is one copy of it, and a **stream** is one
track in a file. A second encode of a film adds a file, never a second film.

- Paths are stored relative to the library root, so a moved disk does not invalidate a library.
- A scan marks unseen files missing and never deletes them. An offline disk keeps its catalog
  and everyone's progress.
- `size:mtime` decides whether a file needs analysis again, so a rescan of an unchanged
  library starts no processes.
- Pages are keyset, ordered by a stable tie-breaker, so page 10,000 costs the same as page 1.
- Scans run in slices of 8 ms, each one transaction, so a large library can't stall a stream.

## Delivery

Requests name catalog ids, never paths. The server looks the file up, then passes the library
root and relative path to the native layer, which opens it inside the root and refuses
anything that escapes through a symlink or reparse point. It keeps the open handle until the
response finishes or is cancelled.

The decision is made per stream and says why:

| Mode | Meaning |
|---|---|
| `direct` | The client plays the original bytes. |
| `remux` | Streams are copied into a container the client can open. |
| `convert` | At least one stream has to change. Each stream reports whether it copies, converts or burns in, and the reason. |
| `refuse` | The file can't be played, with the reason. |

A client states its capabilities. Nothing is inferred from a device name. Remux and convert
are decided in this release and carried out in the next one.

## Artwork and descriptive metadata

The scanner reads what people keep beside their files: `poster.jpg`, `folder.jpg`, `fanart.jpg`,
`Film-poster.jpg`, and `.nfo` files for plots, genres, cast and ratings. Embedded tags fill any gap,
and a person's `.nfo` always wins over a tag. A film with no wide picture gets a frame taken a fifth
of the way in, one at a time, so a frame never competes with a stream.

The independent [metadata worker](metadata.md) fills movies and shows from keyless providers:
real posters and backdrops, canonical titles, descriptions, genres, cast/roles, studio and ratings.
It records provider identity, queues and retries separately from file analysis, and preserves
local choices. Both extensions include the same direct provider client. Standalone desktop lookup
needs no server; optional TMDB/TVDB credentials stay local and only public facts go to a connected
server. A title's Fix match panel lets the owner search and choose explicitly. A poster
URL change changes its cache key, so a corrected match replaces stale artwork. The client polls
progress and refreshes facts while preserving the current library/title view.

## Sources

A library can live elsewhere. See [Sources](sources.md).

Website sources follow a stable source-owned contract: the provider id identifies the source,
the canonical page URL identifies the site-owned record, and each result keeps its own artwork,
description, attribution and ordered playable stream alternatives. An embed page remains distinct
from a resolved stream, so a source can expose episodes and page provenance without pretending
that an iframe is a playable file. This is adapted conceptually (no Mihon code copied) from
Mihon's source API at commit `0c55527206d5b253c58a2428cfebeed10b249571`: `Source.kt` (stable
source identity and update/page boundaries), `HttpSource.kt` (base/home URL, versioned identity,
request headers and URL normalization), `ParsedHttpSource.kt` (separate catalogue, detail,
chapter and page parsing), and `source/model/{SManga,SChapter,Page}.kt` (source-owned metadata,
episode records and ordered playable alternatives). See
https://github.com/mihonapp/mihon/tree/0c55527206d5b253c58a2428cfebeed10b249571/source-api.
Lunar's download-to-owned-library lifecycle is separate from this parser contract.

## The desktop

`media` connects to an address and token set in Settings under Lunar Media, or else to this
computer's own background service, with nothing to set up. It starts with an empty library;
`LUNAR_MEDIA_DEMO=1` explicitly enables the preview fixtures. It asks the server how a file will reach
it, and plays direct files through libmpv with the same token. Resume points go back to the server
every ten seconds, so a film can continue on another machine.

Filters, smart collections, the jump bar and Fits Tonight run on the desktop, over the whole
library, which it holds in memory. A smart collection is stored as a rule set the client evaluates.

On Windows x86-64, libmpv ships inside the media extension. Missing payloads are prepared in
its private cache. See [Contained media tools](runtime.md).

## Limits of the first release

- Direct play only. A file that needs a remux or a conversion is refused with the reason.
- No server-generated HLS/transcoding, Live TV, DVR, DLNA, sharing or downloads.
  Resolved remote streams are passed to libmpv; the server does not convert them.
- Windows x86-64 packages include FFmpeg/ffprobe and the website extractor inside media-server.
  Other platforms require their own runtime packages.
- Art in screenshots of the sample library is generated by `scripts/make_media_fixture_art.py`.
- Playback Forecast states what the server would do. Only this computer's desktop app exists today,
  so TV and phone are typical profiles, and remuxing and converting are decided but not carried out.
- Nothing here has been compiled or run on Linux.
- Overlays and dialogs above live video are unverified on a composited desktop.

## Repair workbench

`GET /v1/attention` describes offline files grouped by library, failed analysis, failing sources,
failed frames and missing ffprobe setup, in that order of impact. `libs/repair.lua` is a pure
mapping of catalog facts to plain copy and supported actions. Existing library scan and source
sync routes do the work; `POST /v1/files/:id/analyse` and `POST /v1/items/:id/frame` reset failed
online jobs for the normal workers. Disabled workers refuse retries with 409. No migration is needed.

The desktop loads attention with its library model, reports action errors and refreshes after
queuing a repair. A thin `ui/reliability.lua` strip links failing sources to Sources on Home and
library views. Sample repair rows are explicitly invented. `HostAPI:controlLocalService` exposes
status/start/stop only to desktop owners declaring `local_service`; these controls concern this
computer, even when browsing a remote server. Settings > Background still controls sign-in startup.

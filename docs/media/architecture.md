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

## Limits of the first release

Direct play only. No HLS, hardware acceleration, tone mapping, Live TV, DVR, DLNA, sharing or
downloads. FFmpeg is not shipped; set `LUNAR_FFPROBE` to enable analysis. Without it the
catalog still fills and streams, and the status page says analysis is off.

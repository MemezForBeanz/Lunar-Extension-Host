# Discovered media downloads

The Sources tab distinguishes a catalogue result from a playable stream and a direct
download. Saving a result keeps it remote and does not copy bytes. **Download to library**
is offered for an HTTPS/HTTP direct file URL and for Internet Archive results that can be
lazily resolved to one. Website episodes use the existing server-side stream resolver
before copying a supported direct file; resolution is repeated after restart/retry so
temporary stream URLs can be refreshed. HLS manifests are explicitly rejected for
downloads; supported streams can still be played. Archive jobs retain the canonical item page separately from their
selected transfer URL. Downloads write to an existing local server library selected by the
user. Pages and embeds that cannot be resolved to a supported file, torrents,
authentication challenges, CAPTCHAs and DRM-protected media remain unsupported
for this copy operation.

Downloads are persisted as jobs. Bytes are bounded by the server's 8 GiB request limit,
written under a `.lunar-part` name, and renamed atomically only after the HTTP request
completes. The scanner is queued after that rename; a partial or failed job is therefore
never catalogued. Jobs expose queued/running/complete/failed/cancelled state and can be
cancelled or retried. The final catalog file records its original source URL where the
scanner can preserve the entry's episode filename/grouping.

## Source research (2026-11-07)

* [THE-OMEGATHREAD](https://github.com/dwongdev/THE-OMEGATHREAD) describes itself as a
  piracy aggregator index and links to streaming, download and torrent sites. It is not a
  verified content licence or a stable downloadable API, so it is not a default provider.
* [FMHY video](https://fmhy.net/video) labels its entries as streaming sites, stream
  aggregators, downloads and torrents. The page is a catalogue of third-party links,
  not a direct media endpoint; entries commonly require a site player and may change,
  redirect or require user interaction. It is not a default provider.
* [Internet Archive](https://archive.org/) identifies itself as a digital library with
  movies and other media. Lunar's existing archive provider uses its metadata and file
  APIs; individual item rights and file availability still need to be checked by the
  owner. It is the only researched general-purpose default with an explicit public-domain
  / openly licensed use case, but it does not prove that every item is downloadable.

No copyrighted episode was downloaded for validation. Tests should use an owned local HTTP
fixture or a freely licensed sample and verify the `.lunar-part`/rename/scan boundary.

## Mihon architectural reference

The source/download boundary was compared with Mihon commit
[`0c55527206d5b253c58a2428cfebeed10b249571`](https://github.com/mihonapp/mihon/tree/0c55527206d5b253c58a2428cfebeed10b249571):

* [`Source.kt`](https://github.com/mihonapp/mihon/blob/0c55527206d5b253c58a2428cfebeed10b249571/source-api/src/main/kotlin/eu/kanade/tachiyomi/source/Source.kt)
  separates stable source identity, catalogue lookup, detail/episode updates, and page
  retrieval.
* [`HttpSource.kt`](https://github.com/mihonapp/mihon/blob/0c55527206d5b253c58a2428cfebeed10b249571/source-api/src/main/kotlin/eu/kanade/tachiyomi/source/online/HttpSource.kt)
  keeps base URLs and default request headers source-owned, while
  [`ParsedHttpSource.kt`](https://github.com/mihonapp/mihon/blob/0c55527206d5b253c58a2428cfebeed10b249571/source-api/src/main/kotlin/eu/kanade/tachiyomi/source/online/ParsedHttpSource.kt)
  keeps site parsing separate from the host lifecycle.
* [`Download.kt`](https://github.com/mihonapp/mihon/blob/0c55527206d5b253c58a2428cfebeed10b249571/app/src/main/java/eu/kanade/tachiyomi/data/download/model/Download.kt)
  and [`DownloadStore.kt`](https://github.com/mihonapp/mihon/blob/0c55527206d5b253c58a2428cfebeed10b249571/app/src/main/java/eu/kanade/tachiyomi/data/download/DownloadStore.kt)
  informed Lunar's persisted states, byte progress, retry/cancel operations, and
  restart-safe job records.

No Mihon source code was copied. This is an architectural reference only; Mihon is
licensed under Apache-2.0, whose attribution remains applicable to any future copied code.

## Native integration check

Run `python scripts/check-media-downloads.py <LunarCLI.exe> <staged-plugins>`
with contained FFmpeg present in the staged server runtime. This generates its
own video, serves an owned page/iframe/redirect chain over loopback, discovers
the episode through the real authenticated API, downloads it to an isolated
library, verifies exact bytes and required Referer, and checks provenance after
the normal scanner finishes. It writes logs under `build/` and never modifies
the user's catalog. `scripts/check-media-ui.lua` separately maps populated
download controls and verifies fullscreen/Escape in the native GUI host.

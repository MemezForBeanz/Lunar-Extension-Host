# Source adapters: Mihon reference

Design reference: [Mihon](https://github.com/mihonapp/mihon), inspected at commit
`0c55527206d5b253c58a2428cfebeed10b249571`. This describes the intended Lunar
contract and review criteria, not a claim that every capability is implemented.
No Mihon implementation code was copied for this design note.

The inspected `source-api/src/main/kotlin/eu/kanade/tachiyomi/source/Source.kt`
separates source identity, paginated browsing/search, detail/chapter updates and
chapter page retrieval. `model/SManga.kt` carries a source URL, title, thumbnail,
description, genres and source-specific metadata. `online/HttpSource.kt` separates
requests and parsing and supplies source request headers. The current
`ParsedHttpSource` is deprecated in favor of adapters implementing the methods
they actually need; its generic selector helpers are not a universal scraping
solution.

For Lunar, each adapter should expose the following independent operations:

1. Browse/search returns bounded, paginated series cards with stable source IDs
   and canonical detail URLs.
2. Details returns the site's own description, artwork and attribution, then
   seasons/episodes with stable IDs and ordering. Missing card metadata can be
   filled by the detail request rather than assumed to be unavailable.
3. Episode resolution returns actual stream alternatives with quality/type and
   request requirements. A webpage or iframe is an unresolved page, not a
   playable media file. Short-lived stream URLs are resolved when needed.
4. Artwork requests retain their site URL and required referer/header context.
   Metadata enrichment remains distinguishable from website-supplied values.
5. Downloading is an explicit destination operation: a remote series in the
   catalog is distinct from a completed local media file in an owned library.

The source adapter owns site-specific interpretation. The host owns HTTP
execution, job limits, credentials, caching, cancellation and progress. The UI
should show accurate browsing/streaming/download capability and failure states.
Provider identity and original page URLs must survive discovery, catalog import,
metadata enrichment and copying into a local library.

Mihon's `app/src/main/java/eu/kanade/tachiyomi/data/download/DownloadStore.kt`
persists downloads across restarts; `Downloader.kt` separates the queue and worker
lifecycle. The corresponding Lunar workflow needs a persisted job associated
with the selected destination library, bounded transfers, retry/cancel state,
partial output separated from completed media, and a catalog scan only after
successful completion. Request URLs and authentication context are handled by
the source/host boundary rather than embedded in user-visible filenames.

Release validation should follow one item end to end: discover a series, fetch
its actual site details/art, list and order episodes, resolve a playable source,
stream it, copy it to an existing test library, and discover the completed local
file with its provenance and show/season grouping retained. Use owned fixtures
for transfer tests and report live site limitations separately.

## Current metadata verification

On 2026-11-07, read-only native-host HTTP checks fetched current public browse
and detail pages from the configured WCO, 9anime and KissAnime hosts. Each tested
detail page supplied its own description and artwork URL; each selected artwork
request returned HTTP 200 with its page Referer. These checks fetch page metadata
and artwork, not episode media, and do not establish that every embedded video
host is resolvable. Investigation logs are in `build/memory-investigation/`.

Browse cards use their own images, including matching titled sibling images and
later duplicate poster links, instead of inheriting the homepage logo. Homepage
promotional descriptions are not assigned to individual series. The canonical
source page, attribution and ordered alternatives survive catalog responses,
including show responses inherited from an episode. Original site descriptions
and artwork are kept under `site_metadata`, independently of enriched work fields.
Public catalog responses exclude the private request headers and authentication
configuration used by the server.

# Mihon source architecture and Lunar's adaptation

Inspected the public `mihonapp/mihon` repository referenced by the user, specifically
[`HttpSource`](https://github.com/mihonapp/mihon/blob/main/source-api/src/main/kotlin/eu/kanade/tachiyomi/source/online/HttpSource.kt),
[`ParsedHttpSource`](https://github.com/mihonapp/mihon/blob/main/source-api/src/main/kotlin/eu/kanade/tachiyomi/source/online/ParsedHttpSource.kt),
and the extension manager. No Kotlin or Plex implementation was copied into Lunar.

Mihon's reusable part is a staged source contract: popular/latest/search pages, title details,
chapter lists, then pages resolved when needed. Its HTML source layer supplies parser hooks
over shared HTTP and document handling. The application separately manages source identities,
installed extensions, signatures/trust and updates. It is not a universal scraper that discovers
every site's structure without an adapter. WebView and JavaScript infrastructure exists for
sites that need it; that does not imply that every request launches a browser.

Lunar uses the corresponding video stages: catalog/search, series details, episode list,
and lazy playable-stream resolution. Thin adapters handle the supplied site structures and
ordinary public JSON endpoints. Generic embedded video can be resolved without maintaining a
site-specific executable. An extension-contained yt-dlp process is a fallback for its supported
hosts; it is not a guarantee of support for arbitrary players.

The server owns fetching, caches, subscriptions and extraction. The desktop owns provider
selection, browse/search results, saved titles and playback. Parsed pages are cheap enough to
avoid a browser, but site extraction can involve several requests and a subprocess. Keeping
that work on the server also centralizes caches and prevents each desktop repeating it.
This is an architectural choice, not a production CPU/RAM benchmark.

Bounds are explicit: two discovery HTTP requests, one extractor process, a 2 MiB body/output
budget, 24 retained discovery jobs, five-minute page/job TTLs and a 45-second extractor timeout.
Metadata has a separate single-worker queue, so matching and media-file analysis are not the
same operation. None of this performs a global web crawl. Runtime archives are versioned and
hash pinned; importing a provider definition cannot install executable source code.

Lunar does not load Mihon APKs or implement an external executable-source marketplace. The
initial site adapters ship as reviewed Lua code inside the media-server extension. Compatibility
and observed website failures are documented separately in `source-compatibility.md`.

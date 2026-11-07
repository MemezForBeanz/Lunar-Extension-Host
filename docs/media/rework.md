# Lunar Media 0.2 — Windows review packages

This revision moves media tools inside the owning extensions and adds a server-owned source
browser and independent keyless metadata worker. The current source also adds standalone metadata
lookup and optional local credentials. Update/rebuild the host for credential redirect protection.

## Included

- `media-server`: bundled FFmpeg/ffprobe and yt-dlp; bounded website discovery, episode grouping,
  saved-series refresh, lazy stream extraction, metadata jobs and authenticated APIs.
- `media`: bundled libmpv; Sources split into Discover and Manage; movie/TV metadata settings,
  title Fix match/Refresh actions, proper poster refresh, cast roles and provider attribution.
- Lightweight packages without binary payloads automatically provision the same hash-pinned
  tools into private extension caches. Normal Windows packages contain them already.

The player starts empty. Preview data requires `LUNAR_MEDIA_DEMO=1`. No test catalog or test
credentials are included in the packages. Existing videos are never renamed or moved.

## Metadata setup

Automatic matching uses keyless Cinemeta for movies and TVmaze for shows. Jikan, Kitsu and
experimental IMDbOT lookup are additional choices. The standalone Metadata tab needs no server.
TMDB and TVDB remain optional: enter personal credentials in Settings > Lunar Media. They stay
in this installation's system secret store; only selected public facts go to a connected server.
There is no Lunar cloud relay or bundled provider key. Local NFO/artwork still take precedence
and ambiguous titles require manual selection. See [metadata notes](metadata.md).

## Sources

Open Sources > Discover, select a provider and search/browse. Open a series to inspect episodes,
or save the whole series to fetch its episode list on the server. Individual entries can also
be saved. The generic webpage provider accepts a page URL. Site catalog support does not imply
every video host works; [compatibility notes](source-compatibility.md) record the live checks.

## Validation and platform boundary

The Windows x86-64 runtime archives were downloaded and verified against pinned SHA-256 values.
The native GUI smoke test constructs and maps the library, title/match, discovery, server and
player views in an isolated profile. The native backend integration generates its own one-second
fixture, scans/probes it with contained FFmpeg and verifies authenticated byte-range streaming.
Unit/integration specs cover schema upgrades, matching/precedence, jobs, resource bounds, source
imports/progress, expiring URLs and cache invalidation. The public 9anime check resolves a live
stream and performs HEAD without downloading a video.

These review packages support Windows x86-64. Other platforms require a separately packaged
runtime. They are not automatically deployed over the running server or existing desktop.
Back up the catalog before installing a schema-changing server update; replace both extension
folders as one version and restart the respective hosts.

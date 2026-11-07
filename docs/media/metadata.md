# Movie, TV and anime metadata

Both extensions include the same direct adapters (`libs/metadb.lua`) and bounded client
(`libs/metaclient.lua`). There is no Lunar cloud relay or bundled/shared provider credential.
The desktop **Metadata** tab works without a media server.

## Providers

| Provider | Authentication | Role |
| --- | --- | --- |
| Cinemeta | None | Default movies: titles, IMDb IDs, descriptions, posters, backdrops, cast, genres and available ratings. |
| TVmaze | None | Default shows: descriptions, posters, cast/roles, network, genres and available ratings. |
| Jikan / MyAnimeList | None | Anime titles, descriptions, posters, genres, studios and available ratings. Unofficial MAL service. |
| Kitsu | None | Additional anime search/details, descriptions, posters, cover images, genres and available ratings. |
| IMDbOT | None | Experimental unofficial lookup. Selected IMDb IDs load details through Cinemeta. |
| TMDB | Personal API read access token | Optional movie/TV metadata and artwork, sent directly with Bearer authentication. |
| TheTVDB | Personal API key and optional subscriber PIN | Optional movie/TV metadata, direct v4 login and in-memory session token. |

These are online metadata services, not bundled copies of entire databases. Cinemeta is Stremio's
public metadata provider; Jikan is an unofficial MAL API. Neither requires a Lunar-operated relay.
Public access does not imply unlimited requests or a service-level agreement.

## Local credentials and standalone lookup

In Settings > Lunar Media, choose **Optional metadata provider**, enter your own credential in the
password field and choose **Save local credential**. TVDB's PIN is needed only for applicable keys.
**Remove local credential** deletes the selected provider credential from this installation.

Credentials use `ctx:setSecret` and this computer's system secret store. They never go to another
media server, catalog, relay or artwork CDN. TMDB uses its read access token, not the short v3 key.
TVDB credentials go in the direct provider login body; its session token stays in memory. Password
fields clear after saving and are never prefilled. The updated host HTTP client refuses cross-origin
redirects for credential-bearing requests. Update/rebuild the host for this redirect protection;
older host versions do not enforce the new policy.

Open **Metadata** to search movies, shows or anime and load details without a server. On a library
title, **Fix match** uses the same local client. Selecting a result sends only bounded, typed public
facts to the authenticated server. The desktop's provider credential stays on the desktop.

Headless automatic matching uses Cinemeta for movies and TVmaze for shows, without credentials.
Provider identity is retained for later refreshes. A title manually matched to an optional provider
needs a desktop refresh with that credential or a separately provisioned server credential. Desktop
secrets are never copied automatically. A personal headless TMDB token can still be supplied via
`LUNAR_TMDB_TOKEN` or that server's own secret store; this does not change keyless defaults.

## Matching and persistence

Automatic matching requires exactly one normalized title/original-title match and, when known,
the same release year. Anime providers are explicit choices; ordinary titles are not guessed to be
anime. Provider IDs remain scoped to their provider. Ambiguity requires a manual selection.

Field precedence: local NFO/artwork, then chosen provider facts/artwork, then embedded tags/filename
parsing/generated frame backgrounds. Metadata never renames files. Provider identity, external ID,
source URL, cast/roles and fetch time remain in SQLite. A manual selection wins over an older
automatic request finishing later. Existing metadata survives provider/network failures.

Image URLs must use known provider CDN hosts. Arbitrary URLs, untyped values and credential fields
are discarded before persistence. Descriptive HTML is converted to plain text.

## Resource limits

One HTTP request runs per extension client. The queue is capped at 24, timeout at 15 seconds and
response size at 2 MiB. Calls to a provider are spaced by at least one second, or two for Jikan.
Numeric Retry-After values set a cooldown up to one hour. Rejected optional credentials pause that
provider until changed; other providers remain usable.

The in-memory response cache is bounded to 128 entries / 8 MiB, retaining searches for one hour
and details for one day. TVDB login responses never enter this cache. Catalog metadata and artwork
persist separately. No periodic cloud polling or shared/public key pool is used.

Catalog refresh jobs persist in SQLite: successful matches are reused for 30 days, unmatched
titles for seven days. Failed automatic jobs back off and stop after three attempts until refreshed.

## Live checks and further research

Run `scripts/check-media-metadata.lua` with the native CLI for an opt-in keyless integration check.
On 2026-11-07, Cinemeta, TVmaze and Kitsu returned real descriptions and posters. Kitsu requires
the JSON:API Accept header. Jikan connectivity was unavailable from this environment; IMDbOT returned
HTTP 400 / server failure. Both adapters remain selectable with ordinary errors and are not default
dependencies. Availability can change; rerun the check before deployment.

Wikidata was researched for open IDs and factual cross-references. It is not an equivalent source
of plots and movie posters, so it remains a future enrichment option. AniList's documentation was
blocked from this environment; its integration/conditions are not verified or implemented.

## Sources and attribution

- [Cinemeta manifest](https://v3-cinemeta.strem.io/manifest.json) and [Stremio official add-ons](https://github.com/Stremio/stremio-official-addons).
- [TVmaze API, rate limits and CC BY-SA](https://www.tvmaze.com/api).
- [Jikan API documentation](https://github.com/jikan-me/jikan-rest/blob/master/storage/api-docs/api-docs.json).
- [Kitsu JSON:API documentation](https://kitsu.docs.apiary.io/).
- [IMDbOT project](https://github.com/TelegramPlayground/Free-Movie-Series-DB-API).
- [TMDB authentication](https://developer.themoviedb.org/docs/authentication-application).
- [TVDB v4](https://github.com/thetvdb/v4-api) and [API licensing](https://www.thetvdb.com/api-information).
- [Wikidata data access / CC0](https://www.wikidata.org/wiki/Wikidata:Data_access).

The player's credits retain TMDB's approved logo and required notice, plus provider links and
TVmaze CC BY-SA attribution. Source links accompany selected metadata. Provider content and
artwork remain subject to the relevant source's terms.


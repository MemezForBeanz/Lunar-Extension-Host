# Sources

A library doesn't have to live on one disk. A source is somewhere else a library lives, and every
source joins one view, with one card for each title and a list of its copies.

## The provider database

A provider describes a kind of source: a name, what it is, and the fields a person fills in. It is
data, not code. Each provider picks one of a fixed set of kinds that ship with Lunar, so adding one
from a file or a friend can't run anything.

| Kind | Reads |
|---|---|
| `jellyfin` | A Jellyfin or Emby server you run, with an API key. |
| `archive` | An Internet Archive collection of public-domain and openly licensed films. |
| `m3u` | A playlist of streams. |
| `feed` | An RSS feed with video enclosures. |
| `index` | A web server's folder listing. |
| `torrent` | Magnet links you add yourself. See [Torrents](#torrents). |
| `website` | Bounded title/episode browsing and lazy video-host extraction. |

## Website discovery

The desktop's Sources tab opens **Discover**, with **Manage sources** available alongside it.
Built-in adapters cover WCO, 9anime.or.at, kissanime.tv.in and a generic video webpage. Search or
browse a source, open a series page to inspect episodes, then save a series or an individual
entry. A saved series fetches its episodes in the background and refreshes every six hours,
preserving progress and marking disappeared episodes missing. KissAnime search filters the current catalog page. Next page and Back preserve the
browsing path. Catalog entries are not imported automatically.

Discovery runs on media-server: at most two HTTP fetches, bounded page sizes, five-minute job
and cache lifetimes, and one contained extractor process at a time. Playable URLs are resolved
when needed rather than continuously crawling websites. The player owns only the controls and
results. Adapters are Lua modules shipped with the extension; downloaded provider definitions
remain data and cannot install executable adapter code.

Website catalog support does not guarantee playback of every embedded host. Access refusals,
unsupported hosts, extractor preparation and timeouts appear as errors. There is no browser or
site-script execution fallback. No accounts, cookies, login sessions or DRM handling are bundled.

Native HTTP integration validation on 2026-11-07 returned 100 WCO catalog entries, 76 KissAnime
catalog entries and 22 episode entries for the tested 9anime series. Its latest episode resolved
through the public server-selection API to a direct media URL that passed a HEAD request.
The sampled KissAnime video host reported that its video was unavailable; another older 9anime
host reported a removed file. Those failures are surfaced rather than treated as playable URLs.
PowerShell received WCO HTTP 403 while Lunar's native client succeeded, so access is client-dependent.
These checks do not establish that every episode or video host works. See [compatibility](source-compatibility.md).

Add one with `POST /v1/providers`:

```json
{
  "id": "film-club",
  "name": "Film club",
  "kind": "feed",
  "summary": "This month's picks.",
  "fields": [{ "id": "url", "label": "Feed address" }]
}
```

Anything else in the definition is dropped. An unknown kind, or an id that isn't letters, digits,
dashes or underscores, is refused. Only `http` and `https` addresses are fetched. A field marked
`secret` goes to the keyring and never comes back from the API.

Lunar ships no index of other people's films, and none should be added to the defaults.

## One card, several copies

When a source syncs, its items become ordinary catalog rows in a library of their own, so Home,
filters and collections need no special cases. Removing a source removes that library.

The desktop folds items with the same title and year into one card, with local libraries first.
A title page lists every copy, with its source and whether that source is reachable. Pressing Play
uses the first copy. If it can't be played, Lunar says so and tries the next one, so a dead source
costs a moment rather than an evening. Progress on any copy shows on the one card.

## Limits

- Titles match on their name and year only, so a remake with a missing year can fold into the
  wrong card, and differently spelled titles stay apart.
- Files from a source are not analysed, so the Forecast can't judge them, and they have no frames.
- A source that doesn't support byte ranges may never start playing.
- Website adapters group numbered episodes under series; feeds without episode identity remain separate items.
- `archive` providers ask the Internet Archive to leave out adult material, but its tags are
  written by uploaders, so some can get through.
- Anyone with a token can add a source, and the server will fetch whatever address it names.

## Torrents

Off by default, and nothing is preloaded. Adding this provider requires accepting a notice,
because playing a torrent uploads to other people and shows them your address. Add only what you
have the right to share.

Lunar doesn't include a torrent client. Set `LUNAR_TORRENT_ENGINE` to one that can stream over
local HTTP. It is started as:

```text
<engine> download <magnet> --port 18721
```

and Lunar plays `http://127.0.0.1:18721/0`, which suits `webtorrent-cli`. One torrent runs at a time.
That address is on the server, so this works only when the desktop and the server are the same
computer. It has been tested with a stand-in engine, not on a real swarm.

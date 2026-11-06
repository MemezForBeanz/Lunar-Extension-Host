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
- Shows from sources arrive as separate items. Seasons are only read from local folders.
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

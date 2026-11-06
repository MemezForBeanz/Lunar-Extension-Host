# Media parity matrix

What Lunar Media needs to cover relative to the Plex desktop app, and when. The matrix describes
features in our own words. It came from static analysis of the installed apps and from screenshots
of the desktop app in normal use. No Plex code or assets are used in Lunar, and the analysis itself
sent no requests to any Plex service or server.

- **P0**: the skeleton. The page exists, its routes work, every state is drawn, and it reads real
  data where a server exists.
- **P1**: next.
- **P2**: later.
- **Skip**: not a personal-server need.

| Feature | Plex location | Pri | Notes |
|---|---|---|---|
| Source rail | Sidebar | P0 | Libraries, health dot. Pin and reorder P1 |
| Home shelves | Home | P0 | Continue, On Deck, Recently Added per library |
| Library grid | Library | P0 | Needs `IupFlatGrid` |
| Library table | Library | P0 | Extend `IupFlatRows` |
| Sort, simple filters | Toolbar | P0 | `FlatDropdown` plus direction; unwatched, genre, year |
| Jump bar, multi-select | Library | P1 | Needs selection in grid and rows |
| Rule builder, smart lists | Advanced filters | P1 | One builder, saved as collection or playlist |
| Collections, playlists, reorder | Pivot | P1 | Needs row drag |
| Detail: movie, show, season, episode | Pre-play | P0 | In inspector, promoted to page |
| Detail: artist, album, track | Pre-play | P1 | |
| Person page | Pre-play | P2 | |
| Stream pickers on detail | Pre-play | P0 | |
| Get Info facts | Modal | P0 | Shown inline; Lunar's edge |
| Edit metadata, lock fields | Modal | P1 | |
| Fix match, unmatch, split, merge | Menu | P1 | |
| Mark played, rating | Menu, `w` | P0 | |
| Player: video via libmpv | Player | P0 | `wid` on a native child |
| Transport, seek, volume | Player | P0 | |
| Audio and subtitle switching | Player | P0 | |
| Resume position, watched at threshold | Player | P0 | |
| Subtitle style and offset | Player settings | P1 | |
| Quality ladder, transcode choice | Player settings | P1 | Needs server |
| Video profiles | Client settings | P1 | Name them honestly; use upstream shaders |
| Exclusive audio, passthrough, refresh switching | Client settings | P1 | |
| HDR passthrough, display switching | Host only | P1 | Beat Plex by giving it a setting |
| Skip intro and credits | Player | P1 | Needs server markers |
| Auto play, up next, chapters, thumbnail seek | Player | P1 | Thumbnails need a server index |
| Play queue, playback speed | Player | P1 | Queue is a pane with drag reorder |
| Mini player | Player | P1 | Split pane first, then OS always-on-top window |
| Real PiP window | None | P2 | Plex has none; easy win |
| Keyboard map and help | Global | P0 | Via `registerShortcut`, plus rebind P1 |
| Media keys, SMTC | Shell | P1 | Native bridge; show metadata |
| Screensaver inhibit | Shell | P0 | `SetThreadExecutionState` |
| `mpv.conf`, `input.conf`, scripts | Files | P1 | Same idea, own docs |
| Debug overlay | Player | P1 | Compositor text panel |
| Music player, queue | Player | P1 | Audio path has no video host |
| Lyrics, mix, radio | Player | P2 | Mix needs server analysis |
| Photo viewer, timeline, map | Photo player | P2 | Strip, EXIF |
| Search | Popover, `/search` | P0 | Command bar `media ` prefix first; full page P1; local sources only |
| Watchlist | Discover | P2 | Local list; no cloud |
| Downloads, offline | Downloads | P2 | Depends on sync design |
| Dashboard: now playing | Server status | P0 | Session tile with decision |
| Dashboard charts, alerts, conversions | Server status | P1 | Chart widget; conversions feed Activity |
| Play history | Server | P1 | Table |
| Server settings (schema) | Settings | P0 | Rendered from server list |
| Libraries manage, scan | Manage | P0 | Scan shows in Activity |
| Add Library wizard | Manage | P0 | |
| Optimized versions | Manage | P2 | |
| Scheduled tasks, logs | Settings, Manage | P1 | Reuse log view |
| Users, sharing, restrictions, PIN, webhooks | Account | P2 | Server track decides the model |
| Client settings | Settings | P0 | `ctx:addSettings`, searchable |
| Audio and subtitle language prefs | Account | P1 | Client side setting |
| Live TV guide, DVR schedule, setup | Live, Manage | P2 | Needs guide widget, tuner support |
| DLNA | Server | P2 | Server track |
| Remote control, cast | Nav bar | P2 | Own protocol if at all |
| Watch Together | Player | P2 | Needs relay; only over Lunar server |
| Update flow | Server | P1 | Host updater |
| First run | Client setup | P0 | Connect to server; empty states |
| Announcements, activity feed, profiles, reviews, friends | Social | Skip | Not a personal-server need |

## Left out on purpose

Commercial ad-supported streaming: free films and channels, ads, rentals and purchases, third-party
music and streaming availability, and subscription upsell surfaces. Cloud account features carry
over only where they make sense on a server you own.

## Where Lunar should beat it

- One settings surface, searchable, instead of four places.
- An inspector beside the collection, so triage does not mean back and forth through pages.
- Technical facts visible by default in the ledger.
- A real always-on-top picture-in-picture window.
- Plain settings for HDR, refresh rate matching, passthrough and video profiles.
- A complete keyboard map with rebinding.
- One rule builder for filters, smart collections and smart playlists.

# Source compatibility — verified 2026-11-07

These are bounded observations of the supplied domains, not a promise about every title.

| Source | Verified | Remaining limits |
|---|---|---|
| `9anime.or.at` | Native HTTP catalog/detail parsing; public series-episode API (22 episodes in test); public server-selection API and ordinary base64 embed address; latest tested episode resolved to direct MP4 and passed HEAD. | Another tested older host returned a removed-file error. Individual host support varies. |
| `kissanime.tv.in` | Catalog (76 entries), series episode links and ordinary iframe discovery. | The sampled iframe host reported video unavailable and yt-dlp did not support that host. Playback of that episode is not verified. Search filters the current catalog page. |
| `www.wco.tv` | Native HTTP homepage catalog (100 entries). | PowerShell got HTTP 403 while Lua's native client succeeded. Individual episode playback is not verified. |
| Generic webpage | HTML video/source elements, OpenGraph video URLs, simple VideoObject JSON-LD, bounded iframe traversal, then the contained extractor. | Site scripts are not executed; there is no universal browser/DRM/paywall fallback. |

Each catalog page is limited to 100 entries and 2 MiB. Browsing is on demand, with two HTTP
requests and one extractor process at most. A series subscription refreshes its returned
episode list every six hours; source failures retain the existing catalog and progress.
An episode list that reaches the adapter's page limit is not used to mark old episodes missing;
the subscription reports the limit and retains its catalog instead.
Expired media URLs are resolved again at playback time, rather than permanently stored.

The generic extractor is yt-dlp; supported hosts depend on the pinned release in the runtime
lock file. Authentication cookies, a browser, external JavaScript runtime, and downloads are
not silently installed. The current implementation does not bypass login, premium access,
challenges or DRM. Site availability errors remain visible in the UI.

Run the opt-in public-network check with `LUNAR_REPO` set to this checkout:

```powershell
./build/win/bin/LunarCLI.exe scripts/check-media-discovery.lua
```

It creates no saved user library, does not download a video, and does not update a live server.

# plugins/

Extensions bundled with Lunar go here, one folder per extension (`<name>/init.lua`
and a `manifest.json`), or a single `<name>.lua`. See `docs/getting-started.md` and
`exampleplugins/hello.lua`.

Lunar ships with none. Organisation-specific extensions live in org packs and
are installed under `%ProgramData%\Lunar Extension Host\profiles\<org>\extensions`
(Windows) or `/etc/lunar/profiles/<org>/extensions` (Linux).
# Plex reference inspection

Read-only inspection, 2026-11-06, of the user-selected installation at
`E:\Program Files\Plex\Plex`. This is a desktop installation with a Qt/native
launcher and an extracted `web-client`, rather than an Electron ASAR. The
bundled web client identifies itself as **4.160.0**, revision
`75ddd7bbf2f972ef690e88d351d83c05b787db2f`.

The relevant interface behavior was available in shipped JavaScript, so no
native decompilation or execution was needed. No Plex files, private player
libraries, artwork, credentials, or user catalog records were copied into Lunar.

## Observed static behavior

| Area | Observation in the shipped client | Implication for Lunar's design |
|---|---|---|
| Scanning versus metadata | Analyze and Refresh are separate item actions. The refresh action builds `PUT /library/metadata/{ratingKey}/refresh`. | File probing and online metadata enrichment need separate jobs, status, and retry controls. Finishing analysis must not imply that metadata is complete. |
| Identity correction | The client has Match, Fix Match, Unmatch, Merge, and Split Apart item actions. A match collection builds `/library/metadata/{id}/matches`. | Keep provider identity and match confidence; let the owner correct a wrong match. Do not silently choose an ambiguous title. |
| Descriptive metadata | The item model declares title, original title, sorting title, year, summary, tagline, studio, content rating, release date, and GUIDs. It also has distinct Genre, Role, Director, Writer, Producer, and collection data. | Separate display identity, sort order, synopsis, and people/tags. Preserve stable IDs instead of joining titles only by spelling. |
| Artwork presentation | The preplay code has poster-card and artwork components, separate poster URL and thumbnail fields, poster dimensions, and a `showPrePlayArtwork` preference. | Treat posters and backgrounds as different assets. A generated video frame is a background fallback, not a replacement for a portrait poster. |
| Organization | The client recognizes grid/summary/table presentation variants and separate item children, versions, collections, queue, and watched actions. | Separate browse organization from physical file layout, and preserve the relationship between a title and its available copies. |
| Provenance | The item model has source/source URI and attribution/attribution-logo fields. | Keep the source identity and metadata attribution visible alongside the title instead of losing them when catalogs merge. |

These are observations of declarations and function bodies in the shipped
client. They do not demonstrate that every action is enabled for every user,
server, library type, or account tier.

## Evidence ledger

REA root artifact identity for `web-client`:
`4d3f90653af52ff8bcc12663ef6b75263334766e0b14fc5b7abbda6036b607d4`.

1. `ev_7b3dde9f7ef0d59ba8e4bf72e1f07ae1fd08807b3e25e4bda457915ca5d8250d`
   — selected-source application analysis of
   `js/chunk-8369-fde1af51640439de4265-plex-4.160.0-75ddd7b.js`.
   One JavaScript source parsed, no parse failures. Source SHA-256:
   `3a16c63f63c7f3eba48ad2bf5777687a1c471cf5947678ebe4664be53b492336`.
   Summary view: `ev_be5541cfd249676264965dfc939d41e22635c296131f152d8da984e69328ec5c`.
2. `ev_197a90d8172fd9bc87ec62eab5a586dd8b14ba13422132939813655308ee772a`
   — selected-source application analysis of
   `js/main-8792-e90a21a5fe7ae941e8eb-plex-4.160.0-75ddd7b.js`.
   Source SHA-256:
   `e59d55e322abe4dcddf487fbffddc2e541330f5aa1339a158636f58a883edc01`.
   Main-file static facts were retained, but expanded relationships exceeded
   REA's parent result budget and semantic retention reached its 20,000-node
   and 20,000-unknown per-file ceilings. Summary view:
   `ev_5e68166345afc5729e8c29af1ac8782e6797f64740c2f1ed74f3e20d6ec52a79`.
3. `ev_894169e4c6d2439014ee9b1bd313e1b1def044f3f86fe156f64c57f9269b61a7`
   — exhausted module identity view for the second analysis. Main source node:
   `jag_node_8ad54b8f6113b30b77136036759d6c1964b12ea4eb6f57271a49487ebc4c8c53`.

The selected-source runs each leave 245 inventoried files outside their analysis
scope. REA reconstructed inert Webpack syntax without running bundle bootstrap
code. Some cross-chunk references remain unresolved. Supplementary read-only
text inspection of those two SHA-256-identified files established the model
field and route literals described above; literal occurrence alone is not proof
of runtime availability.

## Boundaries and open questions

- This path contains the desktop application, not a verified snapshot of the
  user's running Plex server database. No claim about the user's matched titles
  or current poster coverage follows from this inspection.
- No live Plex session, remote service, account API, or media stream was used.
- The reviewed files do not establish Plex's server-side matching algorithm,
  provider contracts, licensing, caching policies, or complete metadata agent
  implementation. Public provider APIs remain the appropriate integration
  point for Lunar.
- This inspection does not establish generic arbitrary-website scraping support
  in Plex. Lunar's requested website source adapters are a separate design.
- The recommendations above are Lunar design choices informed by observed
  interface structure; they are not copied Plex implementations.


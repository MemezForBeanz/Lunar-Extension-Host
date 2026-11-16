# Carbon themes

Carbon replaces the offered Classic and Classic Dark themes. The picker offers
Carbon / White, Gray 10, Gray 90 and Gray 100. White pairs with Gray 100; Gray 10
pairs with Gray 90. Existing `classic` and `classic_dark` settings migrate to
`carbon_white` and `carbon_g100` on load, including both stored mode preferences.
Legacy IDs passed to ThemeManager:apply are accepted as migration aliases.

Token provenance: https://unpkg.com/@carbon/themes@11.66.0/src/white.js and the
g10.js, g90.js, g100.js peers, plus that package's component token exports. Each
palette retains every original value in `carbonTokens` (including alpha and type
sets). Opaque IUP colors are decimal RGB. CSS alpha values are composited once
against the theme floor for IUP. There is no glass or animated backdrop.

Component sources: https://carbondesignsystem.com/components/ (Usage and Style
pages), https://carbondesignsystem.com/elements/color/tokens/,
https://carbondesignsystem.com/elements/typography/type-sets/,
https://carbondesignsystem.com/elements/spacing/overview/,
https://carbondesignsystem.com/elements/2x-grid/overview/ and
https://carbondesignsystem.com/elements/themes/overview/.

IBM Plex Sans was bundled already. IBM Plex Mono Regular is now bundled with the
same OFL license. The host recursively discovers these fonts under assets/Themes.
Body 14px rounds to 11pt (15px at 96 DPI); labels are 9pt (12px), page headings
15pt (20px), code 10pt. The negative pixel font path in the supplied binary rendered
poorly in capture, so this pass uses the established positive IUP point path.

ImGui-only additions are BORDERSTYLE=BOTTOM, CONTROLHEIGHT, FOCUSCOLOR /
FOCUSINSETCOLOR and optional switch geometry. They are emitted only on the ImGui
host. Native IUP keeps plain full-border fields and existing switch drawing.

The old Classic modules are deleted. ThemeManager also excludes their stale
embedded names until the lead next rebuilds the built-in module list.

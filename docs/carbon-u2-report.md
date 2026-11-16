# U2 implementation report

Branch in both repositories: `t3/redesign-carbon-ui`. No pushes.
Host implementation: `3290c40` (Carbon v11 modes and widget rules).
Org packs: `8204798` (Microchip Classic references), followed by the HPE retirement
compatibility commit on the same branch. The final host commit contains this report
and documentation reference cleanup.

## Files

* `CarbonWhiteTheme.lua`: White v11 core/component tokens, original CSS/type values,
  IUP RGB aliases, Carbon family and White label.
* `CarbonG10Theme.lua`: equivalent Gray 10 implementation.
* `CarbonG90Theme.lua`: equivalent Gray 90 implementation.
* `CarbonG100Theme.lua`: equivalent Gray 100 implementation.
* `ClassicTheme.lua`, `ClassicDarkTheme.lua`: deleted; stale embedded names are
  excluded from discovery until the next build refreshes its module list.
* `carbon_rules.lua`: solid primary/secondary and outlined tertiary buttons, distinct
  hover/active/disabled states, 40px actions, label-left/icon-right layout, Carbon
  trailing text allowance, field fill/underline, monochrome selection labels,
  square geometry with the content-switcher exception, productive type roles,
  IBM Plex Mono output, toggle geometry and selected-row header/marker tokens.
* `ThemeManager.lua`: all four picker entries, reversible White/100 and 10/90 pairs,
  legacy apply-ID aliases, tooltip inverse colors, small attribute mappings.
* `SettingsManager.lua`: saved Classic IDs migrate in theme/light/dark preferences
  and persist; defaults use Carbon equivalents.
* `MotionTokens.lua`: disclosure expansion corrected to standard easing, moon/sun
  corrected away from the background-dimming token; focus, toggle, disclosure,
  menu, dropdown, tooltip and notification roles added.
* `docs/motion.md`: element/role/token/curve/source audit and integration limits.
* `docs/carbon.md`: token provenance, migration, font and renderer notes.
* `assets/Themes/Carbon/IBMPlexMono-Regular.otf`: added missing Mono face; the existing
  OFL applies. The existing renderer recursively discovers the font directory.
* `spec/carbon_v11_spec.lua`, `spec/imgui_flatbutton_spec.lua`: token, migration,
  pairing, motion, underline and size/trailing-space regressions. Existing theme,
  settings and system-mode specs updated for the replacement IDs and geometry.
* `installer/ui.lua`: Carbon light/dark IDs.
* `Themes/Theme.lua`, `core/main.lua`, `SettingsView.lua`, `StatusBar.lua`,
  `VectorIcon.lua`, `docs/lunar-ui.md`: comment/example reference cleanup only.
* Org packs `microchip/profile.json`, `microchip/spec/profile_theme_spec.lua`:
  Carbon logo IDs and module references. `hpe/profile.json`: legacy retirement also
  recognizes the migrated White ID.

Theme-neutral draw additions (coordinate with the glass builder):

* `widgets/flatbutton.lua`: CONTROLHEIGHT, TEXTRIGHTPADDING, solid focus/inset ring.
* `widgets/text.lua`: CONTROLHEIGHT and bottom-border single-line field drawing.
* `widgets/dropbutton.lua`: CONTROLHEIGHT and bottom-border opt-in.
* `widgets/flatdraw.lua`: bottom-only border drawing, with the existing path unchanged
  unless BORDERSTYLE=BOTTOM is supplied.
* `widgets/list.lua`: optional flat bottom-border dropdown drawing and height.
* `widgets/flattoggle.lua`: optional switch track/knob dimensions.

No org extension logic, Kit, Lunar palette/rules, or shell structure was changed.
Native IUP retains plain full-border fields and its existing switch rendering.

## Captures and inspection

Final normal captures: `D:/lunar-council/rounds/ui1/work/u2/` theme folders (also
retained under `u2-final/`). 40 PNGs each: carbon_white, carbon_g10, carbon_g90,
carbon_g100, lunar_dark, lunar_light, hpe_dark. Contact sheets are in `u2/qa/`.
The run used only cap-ui.ps1 on private desktops. No app or GUI was launched directly.
Early development attempts stopped after Scan Chain with the pixel-font path; those
attempts were superseded by the complete runs using positive IUP point sizes.

What to inspect on each page (shared rules apply across pages):

| Page / capture | Look at |
| --- | --- |
| Build Queue, shot-01 | 40px primary/secondary buttons, right-side run icon, neutral selected labels, blue marker, toolbar underlines |
| iLO Redfish, shot-02 | filled Send/Connect, dropdown field treatment, readable response |
| Log Parser, shot-03 | Run/secondary hierarchy, selected failure, Mono output |
| Scan Chain, shot-04 | Parse/Copy actions, report font, field boundaries |
| Media browser, shot-05 collection/filtered/sheet | distinct layer surfaces, selections, content switcher, grid/list controls |
| Media Home, shot-05 home | primary vs secondary actions on cards |
| Media ledger, shot-05 ledger | text contrast, selection and table/header surfaces |
| Media show/title, shot-05 show/title | Play action, dropdowns, metadata legibility |
| Now Playing, shot-06 | transport buttons and queue selection |
| Sources, shot-07 | server actions, dropdowns and empty-state controls |
| Media Server, shot-08 | support colors and row actions |
| Metadata, shot-09 | provider/type fields and search action |
| Black Duck, shot-10/11/12 | shared button/field appearance across the existing three pages |
| Time Clock, shot-13 | account/punch buttons and switches |
| Settings, shot-14 | Carbon picker label, switches, field geometry |
| Palette/split/activity, shot-90..96 | opaque floating surfaces and selection contrast; split-pane layout limits remain |

Component comparison sheets in `u2/comparison/` place actual app crops beside Carbon's
own structure images for buttons, fields/dropdowns and tabs. Original source diagrams
have editorial scaling; the app crops remain 1:1. `measurements.json` records action
heights: Browse, Save, Add to queue and Build are all 40px. Dropdowns are 42px (2px
above Carbon md, due to inherited content/border metrics). Search text is 40px.
Page tabs remain about 29px rather than Carbon's 40px; shell header remains 40px
rather than 48px. Their dimensions are still set by existing shell/page construction.
Sampled primary #0f62fe, field #f4f4f4 and secondary #393939 fills match exactly.

`contrast.json`: 36 main text/surface, selected/hovered-row, button and tooltip pairs
across four modes pass 4.5:1; minimum 5.002:1. This is a targeted check, not an audit
of every semantic/disabled pair and every page-owned custom surface.

## Tests

* Host: **2231 successes, 0 failures, 0 errors, 2 pending**.
* HPE: **113 successes, 0 failures, 0 errors, 0 pending**.
* Microchip: **87 successes, 0 failures, 0 errors, 0 pending**.
* Pending: TLS fixture needs openssl on PATH; symbolic-link refusal test needs
  symlink privileges. The runtime callback-error test intentionally logs its failure
  fixture while passing. No build was performed.

## Deviations and unfinished coverage

This is a substantial Carbon replacement, **not full section-3 conformance**.
The component-state audit is not fully implemented for every emulated component.
Menu/dropdown/tooltip/focus/toggle/inline-notification motion roles are defined but
their visibility/state lifecycles are not all wired to those roles. Their current
instant transitions remain. Existing director-driven transitions retain reduced
motion support. No new idle loops were introduced.

Remaining work: fixed shell/tab heights and fully distinct contained-tab anatomy;
every widget's invalid/disabled/focus-inset state; Carbon-specific modal/menu/tooltip
metrics and shadows; full structured-list/tile/tag/notification anatomy; full
per-pair contrast validation; dedicated focus/dropdown/toast state captures. The
stock menu capture did not visibly show an open menu, so it is not evidence of menu
conformance. Font body size rounds 14px to 15px through IUP points; exact line-height,
letter spacing and semibold weight are not independently supported in these rules.
The bundled regular/bold faces remain the available Sans weights.

Source pages were fetched directly for most components. The old overflow-menu URLs
returned 404, and modal-style/progress-usage requests were reset; token data came
from pinned official @carbon/themes exports. No claim of pixel-perfect matching or
9/10 council readiness is made.

# Theming

Themes are host-owned. Extensions do not paint their own chrome; they build plain
IUP widgets, optionally tag them with a theme role, and let
`core.classes.ThemeManager` style the tree.

## How it works

- `ThemeManager` discovers the themes under `core.classes.Themes` and applies the
  active one to the whole dialog.
- Widgets are walked, their original attributes saved, and theme rules applied by
  class and by `THEMEROLE`. Saving the originals is what makes switching themes
  at runtime reversible.
- On platforms where native theming is available, the manager creates and reuses
  native theme handles rather than setting attributes per widget.

## Roles

Tag a widget so it is themed like the host's own controls:

```lua
local text = iup.text{ BORDER = "NO", VALUE = "" }
local boxed = iup.flatframe{ text, TITLE = "", MARGIN = "2x2", THEMEROLE = "text" }
```

The pattern above (a borderless native control inside a themed `flatframe`) is
how the shipped extensions get flat inputs that match the rest of the app.

## Reacting to theme changes

- `ThemeManager:onApply(fn)` registers a callback fired after each apply.
- `core.ui.ThemeReactor` binds the manager for widgets that need to recolor
  themselves (icons in particular).
- `core.ui.VectorIcon` resolves its color from a theme role, so SVG icons follow
  the theme automatically.

## Newly created widgets

Anything built after startup — asynchronously populated panels, dialogs opened
later — must be announced:

```lua
ctx:notifyTreeChange(widget)
```

Otherwise the new subtree keeps default IUP colors while the rest of the app is
themed.

## Type roles

Headings and helper text come from the theme too, not from literal fonts and
colours at the call site. Use `core.lib.CarbonLayout`'s builders rather than
building labels by hand:

```lua
local L = require("core.lib.CarbonLayout")

L.pageTitle(iup, "Log File Parser")
L.pageSubtitle(iup, "Find FAILED test cases across a run's log files.")
L.sectionTitle(iup, "Quick Select Network Path")
L.hint(iup, "Select a path, then Map Drive to create the mapping.")
```

Each is a `flatlabel` tagged with a theme role (`pagetitle`, `pagesubtitle`,
`sectiontitle`, `hint`), and the rule builders derive each size from the theme's
own font family — so a theme's headings come out in its own typeface without the
palette carrying an entry per heading level. A label with a hardcoded `FGCOLOR`
looks right in exactly the theme it was written against, which is how the shipped
extensions ended up with dark-blue page titles on a dark background.

## Native gradients and rounded corners (IUP fork)

The vendored IUP fork adds three attributes to the five *flat* controls
(`flatbutton`, `flatframe`, `flatlabel`, `flattoggle`, `dropbutton`):

| Attribute | Values | Effect |
|---|---|---|
| `GRADIENTCOLOR` | `"R G B"` | Second stop of a gradient fill; `BGCOLOR` is the first. |
| `GRADIENTDIRECTION` | `"VERTICAL"` / `"HORIZONTAL"` | Defaults to `VERTICAL` when omitted. |
| `CORNERRADIUS` | integer (px) | Rounded border/background corners. |

`ThemeManager:_attrsFromRule` wires rule fields `gradcolor`, `graddir`, and
`radius` to these attributes automatically — only for the five supported classes.
Setting them on a native control (e.g. `button`, `list`) is a no-op that is
avoided entirely by the class guard in `_attrsFromRule`.

A rule-builder opts a theme into gradients by setting `gradcolor` (the
"to" color; the rule's `bg` is the "from") and optionally `graddir`. The One Dark
Pro theme opts in via `gradEnabled = true` / `gradTop` / `gradBottom` in its
palette, which `fluent_rules` uses to populate `gradcolor` on every button-like
rule; `radius = 6` is also in the palette and is copied to every applicable rule.

Carbon-based themes do not set either field, so they stay intentionally flat and
square even though the same `_attrsFromRule` path handles them.

## Adding a theme

Themes live in `src\lua\core\classes\Themes\`. A theme supplies a name and a rule
table mapping widget classes and roles to attribute sets; `carbon_rules.lua` and
`fluent_rules.lua` are shared rule builders used by the bundled Carbon and
Fluent-style themes. `ThemeManager:themes` lists what was discovered, and
`ThemeManager:buildMenu` / `buildDropdown` produce the selection UI.

A theme may also override `motion()` to change how specific surfaces move — see
[Motion](motion.md#motion-roles). Anything it leaves out keeps the Carbon default,
so a theme only has to say what makes it different.

## Motion

Colour is only half of the Carbon language the app follows; the other half is
movement. Animation durations, easing and choreography are documented separately
in **Motion**, and are configured alongside the theme selector in
Settings → Appearance.

## Light and dark

Settings > Appearance > **Match system theme** shows the user's light theme while
the operating system is in light mode and their dark theme while it is in dark
mode (Windows' app mode; on Linux the desktop's light/dark style), switching live.
Lunar decides whether a theme is dark from its palette's `bg` brightness. A theme
whose background doesn't say it clearly can declare it in its spec:

```lua
Theme.initialize(self, { id = "my_theme", label = "My Theme", dark = true, palette = p })
```


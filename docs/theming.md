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

The Theme selector lists palettes, not themes: a light and a dark theme that give the
same `family` are one entry, and the mode is a separate choice. The moon button in the
title bar, **Dark mode** in Settings > Appearance, and the Theme menu's Toggle Light/Dark
all swap to the other half. With motion on, the window fades and the moon turns into the
sun; with motion off the swap is instant.

```lua
Theme.initialize(self, { id = "acme_light", family = "acme", family_label = "Acme",
    label = "Acme Light", palette = p })
```

A theme with no `family` is a palette of its own, and the toggle can't switch it. Saved
settings still hold a theme id (`theme`, `theme_light`, `theme_dark`), so org locks and
logo maps name real themes.

**Match system theme** follows the operating system's mode (Windows' app mode; on Linux
the desktop's light/dark style), switching live. Flipping the mode by hand turns it off.
Lunar decides whether a theme is dark from its palette's `bg` brightness. A theme
whose background doesn't say it clearly can declare it in its spec:

```lua
Theme.initialize(self, { id = "my_theme", label = "My Theme", dark = true, palette = p })
```


## Reactive backgrounds

A glass theme may put a live scene behind the whole window (`core.ui.Background`): the
frame round the work sheet shows it under a light tint, and the sheet's glass and every
floating surface refract it. Declare it in the palette as `background`; give the light and
dark palettes of a family the same table (or the same `id`) and switching mode animates
the scene instead of swapping it. Lunar's space scene is `Themes/lunar_space.lua`.

```lua
local p = {
    glass = true, glassDark = true,
    background = {
        id = "acme-sky",   -- one scene for both modes: `mode` eases across a switch
        fps = 24,          -- the cap for time-driven redraws (default 24)
        layers = {
            { kind = "fill", top = { signal = "mode", from = "#05070D", to = "#A6C2E4" },
                bottom = "#0A1122" },
            { kind = "stars", count = 200, seed = 3, size = { 0.6, 1.6 },
                twinkle = { amount = 0.4, share = 0.4, period = { 3, 8 } },
                opacity = { signal = "mode", from = 0.4, to = 0, range = { 0, 0.6 } }, parallax = 4 },
            { svg = "<svg ...>...</svg>", size = 300, x = 0.83, y = 0.17,
                rotation = { signal = "time", rate = 2.5, wrap = 360 } },
        },
    },
    glassFrameTint = "7 10 18", glassFrameAlpha = 0.40,   -- the frame: the scene under this
    glassVeilTint = "23 27 33", glassVeilAlpha = 0.74,    -- the sheet: its glass's tint
}
```

**Layers**, drawn in order:

| `kind` | What | Its own keys |
|---|---|---|
| `fill` | the whole window, a vertical gradient | `top`, `bottom` |
| `svg` (or a layer with `svg` / `file`) | one SVG element (NanoSVG: paths, shapes, linear and radial gradients, opacity; no filters) | `svg` (inline) or `file` (under `assets/scene`), `size` or `width`/`height` (px), `raster` (rasterize at this multiple: above 1 for a layer scaled up, below 1 for soft glows), `unit = "px"` for `x`/`y` in pixels (negative: from the right or bottom) |
| `stars` | a seeded star field | `count`, `seed`, `size = { min, max }`, `colors`, `twinkle = { amount, share, period = { min, max } }`, `region = { x0, y0, x1, y1 }` (fractions) |
| `video` | the API is in place; with no in-process decoder it shows its `poster` (an `svg` layer table) | `file`, `poster` |

Every layer takes `opacity`, `tint` (a colour multiplied in), `x`, `y` (fractions of the
window by default), `dx`, `dy` (px), `scale`, `rotation` (degrees) and `parallax` (px the
pointer moves it at the window's edge; a star moves by its depth). Each of those is a
constant or a **binding**:

| Binding | Value |
|---|---|
| `{ signal = s, from = a, to = b, range = { lo, hi }, ease = "smooth" }` | `a`..`b` as `s` goes `lo`..`hi` (numbers or colours) |
| `{ signal = s, stops = { { at, v }, ... } }` | piecewise between stops |
| `{ signal = s, wave = "sine" \| "triangle", period, phase, min, max }` | an oscillation |
| `{ signal = s, rate = r, offset, wrap }` | `offset + s * r`, wrapped (a turn in degrees per second) |
| `{ signal = s, scale = k, offset }` | `offset + s * k` |
| `{ add = { ... } }`, `{ mul = { ... } }` | the sum or product of bindings |
| `function(s) ... end` | anything; list what it reads in the layer's `deps` |

**Signals**: `time` (s), `clock` (time of day 0..1), `mode` (0 dark .. 1 light, eased while
the theme switches), `mouse_x`, `mouse_y` (-1..1 across the window), `width`, `height`,
`rail` (the sidebar, 0 collapsed .. 1 extended, following its motion), `rail_room` (px free
below the rail's entries) and `fullscreen`. A new one is one call,
`Background.signal(name, { read = function(ctx) return value end })`, or a pushed value,
`Background.set(name, value)`.

**Cost.** Each layer knows the signals it reads, and the scene is drawn again only when one
of them changed: an idle window with a static scene draws nothing; a time-bound layer
redraws at the scene's `fps` and no faster; a pointer-bound one only when the pointer
moved. On Direct3D 11 the layers render into one texture the floor and the glass sample,
and a frame whose only change is the scene is presented without rebuilding the UI. SVGs are
rasterized and uploaded once, when the scene first shows; nothing uploads afterwards. With
reduced motion, hardware acceleration off or on WARP, time and the pointer read 0: the scene
is drawn once per window size, mode or rail change, then costs nothing.

**Contrast.** Labels on the frame must keep 4.5:1 over the brightest (dark) or darkest
(light) pixel the scene can put under them at any time; give that pixel as
`glassSampleWorst` and `scripts/theme_contrast.lua` checks every label and state over it
under `glassFrameTint`. Keep bright bodies away from where labels sit, or fade them out
there with a signal (Lunar's crescent fades when the rail's entries would reach it).

## Panels over a reactive background

The rule Lunar follows, and a theme with a background should too:

* **Large structural panels let the scene through.** The work sheet and the page surfaces
  are a veil of glass (`glass = "veil"`): the scene blurred, refracted at the edge, under the
  panel's tint (`glassVeilAlpha`), the result's luminance bounded (dark at most 0.0622,
  light at least 0.62) so text on it keeps its contrast whatever the scene shows. Children
  painting the panel's own colour draw nothing, so tab strips, settings panels and page
  bodies show the veil.
* **Dense, important content stays opaque.** Lists, tables, grids, row lists, editors,
  the terminal, cards holding a form, and every dialog and floating surface's text well
  sit on an opaque fill (`glassContentWell`, default `layer01`).
* Off the GPU path (WARP, hardware acceleration off) the veil is the opaque card.

## One language for interactive states

In Lunar every interactive state is the same frosted chip: hover and pressed/selected
(`glassStateHover`, `glassStateSelected`; slate by night, cool pearl by day) on buttons,
icon and toolbar buttons, tabs, the rail, list rows and settings navigation, with the same
corner radius (`radius`) and the same 110 ms ease in and out. The chip is translucent
enough to take the colour of what it lies on and opaque enough that labels keep 4.5:1 over
the brightest star the frame can show. The primary action keeps its own opaque gradient.

Button sizes come from content: a text button is its label plus the theme's padding; an
icon-only button in a role with `iconsquare` is a square at its `controlheight`; a side
strip's image-only buttons (the rail's "+" and chevron) draw a square pill however wide the
strip. Nothing stretches unless its layout asks it to.

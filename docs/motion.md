# Motion

Lunar's themes and layout follow the IBM Carbon Design System, and so does its
motion. Durations, easing curves and choreography come from
[Carbon's motion guidance](https://carbondesignsystem.com/elements/motion/overview/)
rather than being tuned by hand, so animation reads as part of the same design
language as the rest of the interface.

Motion is host-owned in the same way theming is. Extensions do not run their own
animation timers; they schedule work on the shared director and inherit the user's
motion settings for free.

## The two styles

Carbon recognises two kinds of moment, and picking between them is a design
decision rather than a tuning knob.

**Productive** motion is efficient and stays out of the way. Use it for anything
the user does repeatedly while concentrating on something else: switching tabs,
reordering, hover feedback, revealing a panel. The best productive motion is never
consciously noticed.

**Expressive** motion is deliberately visible. Reserve it for occasional,
significant moments where the movement itself carries meaning — creating a tab
group, a system alert. It is slower and more pronounced, and overusing it is the
fastest way to make an interface feel sluggish.

In the shipped host, everything is productive except one thing: combining two tabs
into a group.

## Duration tokens

| Token | Milliseconds | Use |
| --- | --- | --- |
| `fast_01` | 70 | Buttons, toggles |
| `fast_02` | 110 | Fades |
| `moderate_01` | 150 | Small expansions, short movements |
| `moderate_02` | 240 | Expansion, system communication |
| `slow_01` | 400 | Large expansion, important notifications |
| `slow_02` | 700 | Background dimming |

Rather than picking a token by hand, prefer passing `distance` and letting
`core.lib.MotionTokens` derive the duration. Carbon scales duration with the size
of the movement, but **sub-linearly** — doubling the distance costs about 1.4× the
time, not 2× — which is what keeps long and short movements feeling equally brisk.

```lua
local Tokens = require("core.lib.MotionTokens")

Tokens.DURATION.moderate_01        --> 150
Tokens.duration(400)               --> productive duration for 400px of travel
Tokens.duration(400, "expressive") --> the slower, expressive equivalent
```

## Easing curves

Strictly linear movement reads as mechanical, so every curve accelerates and
decelerates. Which of the three to use depends on whether the element is present at
both ends of the motion:

| Curve | Use when |
| --- | --- |
| `standard` | The element is visible from start to finish — it moves, resizes or sorts |
| `entrance` | The element is appearing — a dialog, a drop indicator, a toast |
| `exit` | The element is leaving for good — it speeds up as it goes |

One exception worth knowing: something that leaves the view but stays nearby, ready
to be recalled (a side panel), uses `standard` rather than `exit`. It should read as
coming to rest just offscreen, not as departing.

```lua
Tokens.easing("entrance", "expressive")  --> { 0, 0, 0.3, 1 }
```

## Motion roles

A **role** is a named moment in the UI — `tab_transition`, `settings_expand`,
`tab_group_merge` — rather than a widget. Naming the moment is what lets a theme
restyle it without knowing which module implements it, and what lets a call site
ask for "however this app switches tabs" instead of restating a duration.

```lua
director:animate{ role = "tab_transition", target = strip, on_frame = ... }
```

Anything the spec states explicitly beats the role, so a call site with a real
reason to differ still can. The defaults live in `MotionTokens.ROLES`.

| Role | Default | Where |
| --- | --- | --- |
| `tab_transition` | 240 ms, standard, productive | Switching tabs |
| `tab_drag_caret` | 110 ms, standard, productive | Drop caret during a drag |
| `tab_drag_combine` | 110 ms, entrance, expressive | Combine highlight |
| `tab_group_merge` | 400 ms, entrance, expressive | Forming a group |
| `settings_expand` | dynamic, entrance, productive | Settings section opening |
| `settings_collapse` | dynamic, standard, productive | Settings section closing |
| `list_stagger` | 110 ms, entrance, productive | Widget entrance; step=20 ms, limit=40 |
| `scrim_in` | 700 ms, entrance, productive | Dimming the page behind a modal; `alpha`=128 |
| `scrim_out` | 240 ms, exit, productive | Lifting the dim |
| `modal_enter` | 240 ms, entrance, expressive | A modal arriving; `rise`=16 px |
| `modal_exit` | 240 ms, exit, expressive | A modal dismissed affirmatively |
| `modal_cancel` | 110 ms, exit, productive | A modal backed out of |
| `toast_enter` | 240 ms, entrance, expressive | Notification arriving; `travel`=32 px, `hold`=5000 ms |
| `toast_exit` | 240 ms, exit, expressive | Notification leaving |
| `progress_advance` | 150 ms, standard, productive | A progress bar moving between values |
| `status_change` | 110 ms, standard, productive | Status-line text cross-fade |
| `tab_indicator` | dynamic, standard, productive | The selected tab's line sliding to the new tab (ImGui host) |
| `tab_select` | 110 ms, standard, productive | A tab's text and fill cross-fading as it is selected or left (ImGui host) |
| `hover` | 70 ms, standard, productive | Hover fill and text easing in and out (ImGui host) |

### Motion inside widgets (the ImGui host)

On the IUP build every effect above is a picture laid over the real widgets, because
IUP's controls draw themselves in one repaint and offer no way to draw a state on its
way to another. The ImGui host draws every control itself, every frame, so a control
can ease the values it draws: `core.imgui.motion` hands a widget the value on the way
to its target (`number`, `pair` for two values on one clock, `color`, which also fades
to and from nothing). The control's state, attributes and callbacks change at once, as
on IUP; only the picture moves.

It uses the same roles, durations and curves, and the host's `MotionDirector`
attaches itself, so the user's motion setting, the OS's reduced-motion request, the
duration scale and the theme's role overrides apply to widgets too: with motion off a
widget draws its target at once. A value seen for the first time is drawn as is, so
nothing animates into place when a control appears.

The tab strip (`core.imgui.widgets.flattabs`) is the first user: the selected tab's
line is one indicator that slides and stretches to the new tab (`tab_indicator`; a
tab that merely moved, as on a resize, takes it along at once), the old and new tabs'
text and fill cross-fade (`tab_select`), and hover eases in and out (`hover`). All of
it plays alongside the page push (`tab_transition`). `spec/imgui_motion_spec.lua`
covers the module and the strip; `scripts/ui_tabmotion.lua` clicks through the real
app's tabs and, with `LUNAR_TABMOTION_SHOTS=1`, saves every frame of a switch.

### Tab transitions: kinds, themes, settings and extensions

Carbon has no rule for tabs. What it does say decides the design: productive motion
for a repeated task, expressive motion for "opening a new page", **continuity** through
what stays put across the change (here the tab strip, whose indicator slides to the
new tab), duration that grows sub-linearly with distance, and exit easing only for what
leaves for good. A tab switch is a repeated task, so the default stays productive.

What the two pages do is a **kind** in `core.lib.PageTransitions`: pure geometry that
turns eased progress into each page's offset, opacity and dimming, plus the kind's own
duration, curve and style. The same kinds drive both hosts: the IUP build moves
snapshots of the pages (`core.ui.TabTransition`); the ImGui host's tab strip draws the
**live** pages (`core.imgui.widgets.flattabs`), so a spinner or a log keeps updating
through the transition and nothing is captured.

| Kind | What it does | Timing |
| --- | --- | --- |
| `push` (default) | Both pages move the way the new tab's position implies, the old one half as far; the new one fades in over it | 240 ms, standard, productive |
| `fade` | No movement: the new page fades in over the old one | 110 ms, standard, productive |
| `rise` | The new page rises 16 px into place and fades in; the old one fades away in place | 240 ms, entrance, expressive |
| `slide` | The new page slides in over the old one, which stays and dims | 240 ms, standard, productive |
| `none` | Instant | |

Who chooses, highest first: the user (Appearance > Tab transition, saved as
`motion_tab_transition`; "Theme default" defers), then the theme
(`tab_transition = { kind = "rise" }` in `Theme:motion()`; the theme's other
`tab_transition` fields tune that kind), then `push`. With motion off, or the OS asking
for reduced motion, the switch is instant. A strip opts out with `PAGETRANSITION=NO`.

An extension adds a kind (host API 5). It is listed in Appearance settings, a theme can
name it, and it is removed when the extension unloads:

```lua
self:registerPageTransition("drop", {
    label = "Drop in",
    role  = { duration = 240, curve = "entrance", style = "expressive" },
    -- t: eased progress 0..1; ctx: dir (-1 forward, 1 back), w, h, travel, fade...
    frame = function(t, ctx)
        return { alpha = 1 - t },                    -- the outgoing page
               { dy = -24 * (1 - t), alpha = t }     -- the incoming page
    end,
})
```

Each page is drawn as an opaque sheet (the incoming one over the outgoing one), both
clipped to the page rectangle; `dim` darkens a page. `spec/page_transitions_spec.lua`
covers the kinds, the choice order, the extension API, the live strip and the snapshot
path standing down for it; `scripts/ui_tabmotion.lua` plays them in the real app on
either build (`LUNAR_TABMOTION_SHOTS=1` saves the frames; seed
`"motion_tab_transition"` in settings to pick a kind).

### Two moments left un-animated on the IUP build

Carbon's own worked example for *semantic consistency* is that a dropdown opening
should share the accordion's motion, and `fast_01` exists for hover. On the IUP build
neither is implemented, and that is a decision rather than an omission (the ImGui
host eases hover in its own controls, above).

**Menus and dropdowns** are not surfaces this app owns: `core.ui.ContextMenu` shows
a real Win32 popup menu and `IupDropButton` shows its drop child internally.
Animating either means owner-drawing menus, which costs their keyboard handling and
screen-reader behaviour to buy 150 ms of movement.

**Hover** is applied by IUP's flat controls themselves, the instant the pointer
enters. Tweening it would mean clearing `HLCOLOR` and driving `BGCOLOR` from
`ENTERWINDOW_CB` on every widget in the app, fighting each control's own state, for
a 70 ms transition that is close to the threshold of perception anyway.

Both are recorded in `MotionTokens.lua` so they are not "fixed" later by adding
tokens that nothing can consume.

### Themes can override them

`Theme:motion()` is the motion counterpart of `Theme:rules()`. It returns per-role
overrides that are merged **per field** over the Carbon defaults, so a theme states
only what it changes:

```lua
function MyDarkTheme:motion()
    return {
        -- Everything else stays Carbon default.
        tab_transition = { style = "expressive", travel = 0.18 },
    }
end
```

`ThemeManager` installs these on the director as part of the same `apply` that
paints the theme's colours, so there is no window in which the app looks like one
theme and moves like another. A theme that names a role the host does not
recognise degrades to the defaults rather than failing the switch.

## Animating something

`self:animate(spec)` is the whole API for extensions.

```lua
function M.register(ctx)
    local panel = iup.vbox{ ... }

    M:animate{
        distance = 240,          -- or: duration = 240
        curve    = "entrance",   -- "standard" (default), "entrance", "exit"
        style    = "productive", -- or "expressive"
        from     = 0,
        to       = 240,
        on_frame = function(v)
            iup.SetAttribute(panel, "RASTERSIZE", "x" .. math.floor(v))
        end,
        on_done  = function(completed)
            -- completed is false if the animation was cancelled
        end,
    }
end
```

`on_frame` runs up to 60 times a second, so keep it cheap — set attributes, do not
rebuild widget trees or touch the filesystem.

Prefer `self:animate` (the `Extension` wrapper) over `ctx:animate` for the same
reason as every other wrapper on `Extension`: it files the animation under your
extension, so unloading or reloading cancels anything still in flight. `ctx:animate`
takes an explicit second argument if you need it — `ctx:animate(spec, owner)`.

### Motion off is not a special case

When the user turns motion off, or the OS asks for reduced motion, `animate`
invokes `on_frame` **once with the final value** and then `on_done(true)`, both
synchronously before it returns.

That is the single most useful thing to know about this API. It means an animation
is always safe to write as the *only* way a property reaches its destination — you
never need to set the end state separately, and you never need to branch on whether
motion is enabled. Everything lands where it was going, instantly.

```lua
-- Correct in both modes. No `if motion_enabled` anywhere.
self:animate{
    duration = 150, from = 0, to = 1,
    on_frame = function(v) fade_to(v) end,
}
```

If you have work you genuinely want to *skip* when motion is off — an expensive
snapshot you would only throw away — check first:

```lua
local motion = self:motion()
if motion and motion:enabled() then
    -- ...
end
```

### Cancellation

Animations scheduled through `Extension:animate` are tagged with your extension, so
unloading or reloading cancels anything still in flight. Nothing keeps firing
callbacks against destroyed widgets.

Within an extension, pass a `target` to make a new animation supersede whatever was
already animating that widget:

```lua
self:animate{ duration = 150, target = panel, ... }
```

Without it, clicking rapidly stacks animations that fight over the same pixels.

## Choreography

When several things move at once, they need to move *together*.

**Never diagonally.** Carbon elements travel along the grid. A two-axis movement
should be split into staggered horizontal and vertical legs so the path has a
rounded corner; starting both at once produces a diagonal that breaks the grid.

```lua
local path = Tokens.cornerPath(dx, dy)
self:animate{ delay = path.x.delay, duration = path.x.duration, ... }
self:animate{ delay = path.y.delay, duration = path.y.duration, ... }
```

**Stagger entrances.** Introducing many elements simultaneously costs the user a
spike of cognitive load. `Tokens.stagger(index, total)` spreads them out and
automatically compresses the step so the whole sequence stays within Carbon's
500 ms ceiling, however long the list is.

```lua
for i, row in ipairs(rows) do
    self:animate{ delay = Tokens.stagger(i, #rows), ... }
end
```

**Sequence by importance.** Static shell first, then body content, then dynamic
content, then the primary action. Ending on what matters most is what directs the
user's attention there.

## User settings

Settings → Appearance:

- **Interface motion** — the master switch. Off means every animation in the app,
  host and extensions alike, completes instantly.
- **Motion speed** — 0.5× to 2×, multiplying every duration.
- **Follow system motion setting** — on by default. When Windows is set to reduce
  animations (Settings → Accessibility → Visual effects), motion switches itself
  off. A significant number of users disable animation because motion causes them
  genuine physical discomfort, so this should stay on unless the user deliberately
  overrides it.

## Host motion

Nine surfaces animate today.

**Modals** dim the page behind them and rise 16 px into place. The dim is the
slowest thing in the app — `slow_02`, 700 ms, the token Carbon publishes for exactly
this — because a scrim is context rather than content, and one that snaps reads as a
light being switched off instead of the page receding. It lifts on a shorter token,
because raising a dim is scene-setting but lowering it is the user getting control
back.

Confirming and cancelling a modal are deliberately *not* the same motion. Carbon
calls this **intentional inconsistency**: forward motion in the direction of entrance
signals affirmation, reversing it signals cancellation. So an affirmative dismissal
lifts the scrim on `modal_exit` (expressive, completing the arc it entered on) and
backing out uses `modal_cancel` (productive, about half as long, so the dialog reads
as withdrawn rather than sent).

Dialogs opt in by calling `ModalMotion.popup(iup, dlg)` instead of `iup.Popup`, and
by reporting which way the user went with `ModalMotion.result(iup, dlg, "confirm")`
from the affirmative handler. The exit of the *dialog itself* is deliberately not
animated: once a dismissal starts IUP is already tearing the window down, and
animating a window through its own destruction is how this kind of code earns access
violations. What is animated is the part that outlives it — the scrim.

**Lists** grow in rather than snapping. The machinery is Carbon's staggered
entrance — each widget starts 20 ms after the one before it, compressed so the whole
sequence lands inside the 500 ms ceiling however long it is — but be clear about what
that buys with the host's own list wrappers: `CheckList` and `ReorderableList` are
each a **single** `IupFlatList`, one native control whose rows are internal and not
reachable as separate widgets from Lua. Passing one widget means `stagger(1, 1)` is
zero, so what those two surfaces actually get is a single grow-in, not a row cascade.

The stagger is real for any caller that passes genuine sibling widgets, which is why
`ListEntrance.play` takes an array rather than a list handle. But no surface in the
host does that today, so treat the row-by-row cascade as available rather than as
shipped.

**Progress bars** ease between values instead of jumping, so a queue of eight items
reads as one thing advancing rather than eight unrelated states. Backwards is
treated as a reset and lands instantly — easing a bar *down* animates work being
undone.

**The status line** cross-fades. IUP has no per-widget opacity, so the fade is done
in colour space, driving the label's foreground from the bar's background up to its
resting text colour.

**Tab switches** slide horizontally in the direction implied by the tab's position
in the strip. This is Carbon's *pushing* transition: tab pages are peers on the
same layer, so both pages translate together, revealed through a mask, with nothing
dimmed. (Dimming, or moving only the new page, would imply a depth relationship
that does not exist.)

The pages travel a *fraction* of the page width — `travel`, 32% by default —
capped in absolute pixels by `max_travel` (360), with the incoming page
cross-fading in over the outgoing one.

The literal reading of a push is a rigid pair exactly one page width apart, and
that is what this did first, but it does not survive a large window: a maximised
4K page inside Carbon's 240 ms productive ceiling works out at roughly 16,000 px/s,
which the eye reads as a smear rather than as a direction.

The **pixel cap** rather than a small fraction is the part worth keeping. Perceived
speed is absolute distance over time, not the proportion of the window crossed, so
a fraction alone either whips on a large display or becomes so short that the
movement is barely there and the transition reads as a plain dissolve. Capping the
pixels holds the apparent speed constant at every window size — 360 px over 240 ms,
about 1500 px/s.

Setting `{ travel = 1, fade = false }` on the `tab_transition` role restores the
literal rigid pair.

**Settings sections** expand and collapse by animating the height of a clipping
container, with the chevron rotating in step. The duration is derived from the
distance, so a two-row section and a twenty-row one both feel brisk.

**Dragging a tab** shows what the drop will actually do. The same gesture can
reorder a tab or combine two tabs into a group, and those used to be
indistinguishable until the mouse came up:

- a thin **caret** slides between tabs — "this lands here"
- a **highlight** scales up over a tab — "these two become one"

That difference is Carbon's *intentional inconsistency*: when one gesture produces
meaningfully different outcomes, the motion should not be uniform.

**Creating a group** is the one expressive moment that the tab system inherited.
The highlight contracts from the span of both source tabs down to the new group
tab, telling the "two became one" story in a single 400 ms movement.

**Notifications (toasts)** are the second expressive moment, and the one Carbon
names directly: *"System alerts and the appearance of notification boxes are great
cases for expressive motion."* A toast slides into the top-right corner from
`travel` px off the right edge — the direction tells you it arrived from the
system, not from the page — holds for `hold` ms, then exits with Carbon's exit
easing (accelerating outward) to signal that it has said what it came to say.

Multiple toasts stack vertically. When one leaves, the survivors above it reflow
downward. The reflow is split by `MotionTokens.cornerPath` so it never moves two
axes simultaneously — the first movement locks in the horizontal position before
the vertical slides begin, keeping the path on the grid.

```lua
-- From an extension:
self:notify({ title = "Scan complete", kind = "success" })
self:notify({ title = "Connection failed",
              body  = "Check the backend URL in Settings.",
              kind  = "error",
              timeout = 8000 })

-- From host code:
ctx:notify({ title = "Watson training complete!",
             body  = "3 new intents were created and 1 updated.",
             kind  = "info" }, owner)
```

The four kinds map to the theme's semantic palette: `error`, `success`, `warning`,
`info`. The 3 px status bar on the left edge is painted from the same token as the
rest of Carbon's notification components, so it recolours on a theme switch without
any extra wiring.

### Roles

Two roles govern the toast lifecycle:

| Role | Default | Where |
| --- | --- | --- |
| `toast_enter` | 240 ms, entrance, expressive | Sliding in from the right |
| `toast_exit`  | 240 ms, exit, expressive    | Sliding out on dismiss    |

Both roles carry extras:

- `toast_enter.travel` — how far (px) the toast slides in from the right edge (32)
- `toast_enter.hold` — ms the toast waits before auto-dismissing (5000)

A theme can slow the entrance, widen the travel, or shorten the hold by naming
these roles in its `motion()` table.

## Implementation

| Module | Role |
| --- | --- |
| `core.lib.MotionTokens` | Carbon durations, curves, dynamic duration, roles, choreography helpers |
| `core.lib.MotionEasing` | Cubic-bezier solver, FFI sample table for allocation-free frames |
| `core.lib.MotionClock` | `QueryPerformanceCounter` monotonic clock; OS reduce-motion probe |
| `core.classes.MotionDirector` | The scheduler — one timer, every animation, the off-switch, role resolution |
| `core.lib.Compositor` | Per-dialog scene manager over the native overlay: z-banded groups, snapshots, one present per tick (Windows and Linux) |
| `core.ui.TabTransition` | The sliding page transition |
| `core.ui.TabDragMotion` | Drag feedback and the group-creation flourish |
| `core.ui.SettingsView` | The settings accordion |
| `core.ui.Toast` | Carbon notification toasts, stacking, reflow |
| `core.ui.ListEntrance` | Staggered entrance for a set of sibling widgets |
| `core.ui.Scrim` | Background dimming behind modals |
| `core.ui.ModalMotion` | Modal entrance, and the affirm/cancel exit distinction |
| `core.ui.ProgressMotion` | Eased progress-bar movement |

A few design points worth knowing if you extend this:

- **One timer.** Every animation ticks from a single shared 16 ms timer, so
  concurrent motion is frame-locked and cannot drift apart. The timer stops when
  the queue empties, so an idle app costs nothing.
- **Time-based, not frame-based.** Progress comes from the clock. Under load,
  frames are dropped and the animation still finishes on schedule — rather than
  stretching out exactly when the UI is already busy.
- **The compositor fails closed.** Every effect on the main window draws through the
  dialog's compositor. Where there is no native backend, or the overlay window can't
  be created, or a snapshot comes back empty, the effect does nothing and the UI
  behaves instantly. Losing the animation is the only consequence. Dialog movement
  (the modal rise) goes through `core.platform.move_window`, which reports false
  where the platform can't place windows (native Wayland), and the rise is skipped.

### Testing

`spec/motion_tokens_spec.lua`, `spec/motion_easing_spec.lua`,
`spec/motion_director_spec.lua` and `spec/motion_roles_spec.lua` cover the pure-Lua
layers under busted, with IUP faked and the clock injected so timing is
deterministic. The tab transition, drag feedback and scrim run over the real
`Compositor` manager with a fake backend that records presents. `spec/settings_view_spec.lua` covers the accordion the same way.

The native layer needs a real window, so it has a GUI harness instead:

```
build\bin\Lunar.exe scripts\motion_check.lua
```

That probes the clock, the FFI easing table, compositor creation, snapshot capture
(including a 200-cycle leak check) and a live transition.

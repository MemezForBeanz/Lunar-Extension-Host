# IUP fork (native gradients, rounded corners, flat scrollbars)

Lunar vendors IUP 3.32 and adds a small, **purely additive** set of native drawing
and scrolling features to IUP's *flat* controls:

- `CORNERRADIUS` – rounded corners on the control border/background.
- `GRADIENTCOLOR` + `GRADIENTDIRECTION` (`VERTICAL`/`HORIZONTAL`) – a gradient fill
  (from `BGCOLOR` to `GRADIENTCOLOR`) behind the control.
- `NATIVETEXTSCROLL` – lets an `IupFlatScrollBox` drive a native multiline `IupText`'s
  own virtualized scroll, so a log view keeps native virtualization, free-text
  selection and jump-to-line while showing the themed flat scrollbar instead of the
  Win32 one. Used by the Log File Parser (`plugins\logparser\libs\resultsview.lua`).

The gradient/rounded work replaces the old Lua-side `Gradient*` widgets (GradientKit
et al.), which drew onto separate `iup.canvas` overlays and caused artefacts such as
the double-scrollbar bug.

## Why patches, not a true fork

`vendor/` is gitignored and regenerated, so the fork is stored as a **patch series**
applied on top of a pristine upstream extract:

- the diff stays reviewable (one patch, ~1,100 lines across 16 files, all additive);
- rebasing onto a newer IUP release is a re-extract and a re-apply, not a merge;
- we don't have to mirror a ~85 MB upstream tree in a repo that deliberately keeps
  third-party sources out of version control.

Reconsider a real fork if the series grows past roughly five patches, if upstream
rebases start conflicting routinely, or if the changes stop being additive.

```
iup-fork/
  patches/    tracked *.patch files (git apply -p1, relative to the extracted iup/ root)
  verify/     standalone screenshot harness (verify_gradient.c)
  README.md
```

## Build flow (automatic via CMake)

`scripts/build-iup-fork.ps1` runs as the `iup_fork` CMake target and:

1. Downloads `iup-3.32_Sources.tar.gz` if missing, extracts a **pristine** tree to
   `vendor/iup-src/iup`.
2. Applies every patch in `iup-fork/patches/` (in filename order).
3. Compiles the core sources into `vendor/iup-src/build/libiup.a`
   (linked by Lunar via `${IUP_FORK_LIB}`).

A stamp file (`vendor/iup-src/.patch-stamp`, a hash of the patch set) makes step 1–2
re-run only when the patches change; otherwise the build is incremental.

```powershell
scripts\build-iup-fork.ps1          # prepare-if-needed, then incremental compile
scripts\build-iup-fork.ps1 -Fresh   # force re-extract + re-apply patches, full rebuild
scripts\build-iup-fork.ps1 -Clean   # wipe object cache, recompile from current source
```

After applying, the script asserts that both feature families actually made it into
the tree (`iupFlatDrawGradient` in `iup_draw.c`, `FIRSTVISIBLELINE` in
`win/iupwin_text.c`). A patch that silently no-ops would otherwise produce a
feature-less `libiup.a` that links and runs but quietly loses the themed UI.

## Editing the fork

Edit the extracted source under `vendor/iup-src/iup/src` directly, then capture your
changes back into the patch series:

```powershell
scripts\build-iup-fork.ps1          # 1. get a patched working tree
# 2. edit vendor\iup-src\iup\src\...
scripts\regen-iup-patch.ps1         # 3. capture the edits back into iup-fork\patches
scripts\build-iup-fork.ps1          # 4. stamp changed -> re-extract, re-apply, rebuild
```

`regen-iup-patch.ps1` extracts a pristine tree into a temporary throwaway git repo,
overlays your working tree, and writes the diff. It refuses to emit an empty patch,
normalizes line endings to LF, and **verifies the result applies to a clean extract**
before overwriting anything. If the series ever has more than one patch it will not
collapse them without an explicit `-Collapse`.

### Line endings

Patches **must** use LF. Upstream IUP sources are LF, and `git apply` rejects a CRLF
patch against them with `patch does not apply`. Two things keep that true:

- `.gitattributes` pins `*.patch` to `eol=lf`. Git for Windows sets
  `core.autocrlf=true` system-wide, so without this a fresh clone would check the
  patches out as CRLF and the fork build would fail on a clean machine.
- `build-iup-fork.ps1` applies with `-c core.autocrlf=false`, so patched files stay
  LF in the working tree. Otherwise `git apply` rewrites every file it touches as
  CRLF, and the next regeneration produces whole-file rewrites instead of real edits.

## What the patch touches

Drawing / theming:

- `src/iup_draw.c` / `src/iup_draw.h` – the reusable scanline primitives
  (`iupFlatDrawGradientBox`, `iupFlatDrawRoundBox`, `iupFlatDrawRoundBorder`) plus the
  attribute-aware wrappers `iupFlatDrawBoxAttrib` / `iupFlatDrawBorderAttrib`.
- `src/iup_flatbutton.c`, `iup_flatframe.c`, `iup_flatlabel.c`, `iup_flattoggle.c`,
  `iup_dropbutton.c` – swap their border/background draws to the `*Attrib` wrappers and
  register the three new attributes.
- `src/iup_gauge.c`, `src/iup_text.c`, `src/win/iupwin_draw_gdi.c`,
  `src/win/wdl/backend-gdix.c` / `.h` – supporting draw paths.

Native text scrolling:

- `src/iup_flatscrollbox.c`, `src/iup_flatscrollbar.c` – the `NATIVETEXTSCROLL` mode.
- `src/win/iupwin_text.c` – `FIRSTVISIBLELINE` get/set over `EM_GETFIRSTVISIBLELINE` /
  `EM_LINESCROLL`, plus wheel redirection to the hosting scrollbox.

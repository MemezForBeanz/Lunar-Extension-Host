# Workspace terminal

`Ctrl+\`` or **Toggle Terminal** opens one Lunar prompt below the workspace.
The header starts a fresh session, clears output, cancels a running CLI, maximizes
the panel, or closes it. Drag the top edge to resize it. Closing the panel keeps
its session and running job; the kill button or Ctrl+C cancels the job.

The prompt accepts quoted arguments, Up/Down history, Tab completion for commands,
headless flags and local paths, and Ctrl+L to clear. Ctrl+C copies when there is a
selection and cancels otherwise. Scrollback retains up to 256 KiB; history retains
200 commands. Starting a fresh session resets both.

Built-ins: `help [command]`, `clear`, `version`, `extensions`, `themes`, `problems`,
`lsp`, `show <file>`, `open <file[:line]>`, `settings`, `about`, `pwd`, and `exit`.
`show` prints text files up to 128 KiB. Diagnostic references beginning a line
(`file:line:column`) open the file when clicked. Lines and columns displayed to
the user are one-based.

Everything else runs the bundled `LunarCLI.exe` beside Lunar, or `lunar-cli` on
Linux. Examples: `script.lua "an argument"`, `lunar-cli script.lua`, and
`headless --dev --for 5`. `headless --help` lists the CLI options. The executable
is fixed by the host; arguments are passed as an array to `process.spawn`.
There is no system shell, expansion, piping, or redirection. Cancellation ends
the child process tree through the existing process module.

CodeView supplies language lexers and contrast-safe theme colours. Printed files
also request `textDocument/semanticTokens/full` if a server for the file is
already running and advertises full tokens. CodeBinder handles that connection;
CodeView has no server dependencies. Without a server, the lexer is used. Without
Scintilla, input and output use plain text controls. The output uses the org-pack
log viewer pattern: native text scrollbars disabled after construction, with a
themed `flatscrollbox` and, on Windows, `NATIVETEXTSCROLL=YES` owning the scroll and
mouse wheel. Other drivers use the flat container's ordinary scrolling.
Semantic token delta decoding
is available as a pure helper; the client currently requests full results only.

`core.lib.LunarShell` is UI-free. Its command table, parser, completion, history,
and `register(name, command)` can be reused without a terminal widget. Each
instance owns its registrations; no extension-facing session API is added yet.

`core.ui.ViewLayout` exposes `toggleBars()`, `barsVisible()`, `toggleTerminal()`,
`terminalVisible()`, and `onChange(fn)`. Bars means the tool rail and status bar
together; Ctrl+B still expands or collapses the rail independently. Settings are
`view_bars_visible`, `terminal_open`, and `terminal_height` (pixels). Motion goes
through the shared MotionDirector, including reversal, reduced motion and speed.

Native Windows checks: run `scripts/terminal_check.lua <output-dir> <prefix>`
with `build/sol-dev/bin/Lunar.exe`, an isolated APPDATA, and a settings.json with
`welcome_tour_dismissed=true`. Set `LUNAR_TERMINAL_PLAIN=1` to exercise the fallback.
The harness writes BMP screenshots and `terminal-check.txt`; convert BMPs to PNG
for review. Source changes require rebuilding the embedded Lua bundle.

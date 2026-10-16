#ifndef LOGSCAN_H
#define LOGSCAN_H

#include <lua.h>

/* Native high-performance log scanner used by the Log File Parser plugin.
 *
 * Replaces the standalone LogFileParser CLI: the whole recursive directory
 * walk and per-line FAILED detection run in C, so the Lua UI thread only
 * orchestrates batching + progress and never blocks on the network share.
 *
 * Lua API (require("logscan")):
 *   logscan.scan_file(path) -> { count = N, failures = {
 *           { line = <int>, message = <string>, type = <string|nil> }, ...
 *       }, error = <string|nil> }
 *       Scans one file for lines matching the whole word "failed"
 *       (case-insensitive), attaching the most recent parenthesized
 *       "(type)" seen on a preceding non-failure line.
 *
 *   logscan.file_context(path, line [, before [, after]]) -> {
 *           { n = <int>, text = <string> }, ...
 *       }
 *       Returns the lines surrounding `line` (1-based) for lazy detail views.
 *       `before`/`after` default to 3.
 */
int luaopen_logscan(lua_State *L);

#endif /* LOGSCAN_H */

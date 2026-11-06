# Native media transport measurements

Measured 2026-11-06, loopback only, generated local fixtures, warm filesystem cache.
No third-party media server was run or contacted.

## Machine and method

- Windows 11 Pro 10.0.22631; Intel Core i9-12900K, 16 physical / 24 logical cores;
  34,130,472,960 bytes installed RAM (31.79 GiB).
- Fixtures and executable on D:, NTFS, WDC WD10EZEX-08WN4A0 SATA HDD.
  This is **not** the proposed 8-core / 16-GiB NVMe reference machine.
- MinGW GCC 15.2.0 (MSYS2 Rev8), RelWithDebInfo, `build/sol/bin/LunarCLI.exe`.
- Python standard-library clients on the same machine. A 64-MiB repeating fixture,
  an empty fixture and a sparse 5-GiB fixture with known bytes crossing 4 GiB.
  Full SHA-256 comparison and exact range/body checks precede load measurement.
- Eight concurrent clients. Unpaced throughput is limited by host, Python clients
  and loopback together. Paced TLS requests target 25 Mb/s per reader.
- CPU is **host-process** user + kernel time / wall time, subtracting a 0.3-second
  idle baseline. One core = 1.0; machine percent divides by 24. System-process CPU,
  clients, scanning and catalog activity are excluded. Very short CPU samples have
  timer-resolution error; these are not end-to-end energy/cost measurements.
- RSS is Windows process working set, measured at idle and with 32 clients that
  read headers and retain unread bodies. Socket buffers belong to the OS and are
  not completely represented by process working set. Native queues do not grow
  with media size. Completion and worker cancellation are checked after disconnect.
- Loop lag is lateness against a 10-ms scheduler deadline while repeatedly stepping
  Copas; a late tick reschedules from current time. This measures deadline delay,
  not accumulated timer drift. No scanner or metadata workload is included.
- TLS uses a generated self-signed RSA certificate; the benchmark client disables
  certificate verification. Transport encryption uses OpenSSL; file bytes travel
  through a reusable 64-KiB native buffer, with no encrypted zero-copy claim.

## Results

| Measurement | Cleartext, unpaced | TLS, 8 x 25 Mb/s paced |
|---|---:|---:|
| Load duration | 3.003 s | 60.022 s |
| Aggregate throughput | 22,204 Mb/s | 199.926 Mb/s |
| Incremental host CPU, cores | 0.0104 | 0.0237 |
| Host CPU, percent of machine | 0.0434% | 0.0987% |
| Idle RSS | 6.21 MiB | 9.21 MiB |
| RSS with 32 slow readers | 12.05 MiB | 18.39 MiB |
| Incremental RSS | 5.85 MiB | 9.19 MiB |
| Range TTFB p95 | 15.45 ms | 26.12 ms |
| Loop delay p99 | 11.63 ms | 10.20 ms |
| Shutdown with active transfer | 46.9 ms | 7.5 ms |
| Range checks / mismatches | 1,000 / 0 | 1,000 / 0 |

An additional final-binary TLS smoke run passed all checks, including explicitly
waiting for active transfers to reach zero after the 32 disconnects: 3.020 s,
198.587 Mb/s, 0.0362 incremental cores, 8.65 MiB incremental RSS, range TTFB p95
26.28 ms, loop lag p99 14.15 ms, shutdown 12.1 ms. Its shorter duration makes
startup/stop pacing error more visible.

## Against the council's initial goals

- **1,000 random valid/invalid ranges and warm TTFB p95 <100 ms:** passed, plus
  exact signed-64-bit parser cases above Lua's exact-number limit and real
  overlapped offsets across 4 GiB. Every valid range matched fixture bytes.
- **Eight 25-Mb/s streams for ten minutes, 200 Mb/s aggregate LAN TLS:** only
  60 seconds on loopback was measured. Aggregate was 0.074 Mb/s below the nominal
  200-Mb/s goal, including pacing and startup/stop overhead. The ten-minute and
  LAN criteria remain unverified; this is not a claim of passing that target.
- **Incremental CPU <1 full core and RSS <128 MiB at 32 open streams:** below the
  numerical limits in this loopback test. A LAN run and broader CPU accounting
  are needed before applying these numbers to the reference workload.
- **Loop delay p99 <20 ms under scan plus eight streams:** below 20 ms without a
  scanner. Scan contention and metadata p95 <100 ms remain unmeasured.
- **Cancellation releases handles; shutdown within grace:** disconnects released
  native transfers, and Windows permitted renaming the fixture after 32 readers
  disconnected. Active-send cancellation and server shutdown passed. Unit specs
  also check host ownership, asynchronous stop and grace-drain integration. The
  standalone fixture exercises HttpServer stop; OS-signal delivery to a full
  installed headless service was not measured.
- Catalog browse/decision, inventory, transcode/HLS, crash recovery, cold cache
  and LAN runs are outside this transport benchmark and were not measured.
- Linux `sendfile`/`openat` implementation is present but **not compiled or run**
  here: this Windows machine has no usable WSL distribution. Linux acceptance
  remains outstanding. Desktop GUI integration was not exercised by this track.

## Reproduce

Build with the normal project toolchain, then run with MinGW removed from the
CLI child's PATH (the Python harness does that on Windows):

```
LunarCLI scripts/media_stream_check.lua
python scripts/benchmark_media.py --exe build/sol/bin/LunarCLI.exe --seconds 10
python scripts/benchmark_media.py --exe build/sol/bin/LunarCLI.exe --seconds 600 --mbps 25 --tls-cert <cert.pem> --tls-key <key.pem>
```

The script binds and connects only to `127.0.0.1`. Use `--scratch <directory>` on
Linux or outside the council worktree. JSON and server logs are written there.
Do not run simultaneous fixtures on the same port; use `--port` to separate them.
Each run generates its own data and creates a junction (Windows) or symlink
(Linux) outside its authorized root to test rejection.

Checks include bearer rejection, empty GET/range, HEAD metadata, closed/suffix/
open-ended/clamped/reversed/overflow/multiple ranges, exact Content-Range,
ETag/date conditions and precondition precedence, traversal, ADS, junction,
actual offsets over 4 GiB, full hash, concurrent streaming, bounded slow-reader
state, disconnect cleanup and active-transfer shutdown. Native arithmetic cases
also run as CTest `native.file_ranges`.

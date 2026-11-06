"""Loopback-only native transport correctness and load harness (standard Python).
Usage: python scripts/benchmark_media.py --exe build/sol/bin/LunarCLI.exe
--seconds 600 exercises the ten-minute goal; --tls-cert/--tls-key tests TLS.
Generated local bytes only. Does not access any external service.
"""
import argparse
import concurrent.futures
import ctypes
import hashlib
import http.client
import tempfile
import json
import os
from pathlib import Path
import random
import socket
import ssl
import subprocess
import time


def rss(pid):
    if os.name != 'nt':
        return int(Path(f'/proc/{pid}/statm').read_text().split()[1]) * os.sysconf('SC_PAGE_SIZE')
    class Counters(ctypes.Structure):
        _fields_ = [('cb', ctypes.c_ulong), ('faults', ctypes.c_ulong)] + [(n, ctypes.c_size_t) for n in
            ('peak', 'rss', 'peakPaged', 'paged', 'peakNonPaged', 'nonPaged', 'pagefile', 'peakPagefile')]
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.OpenProcess(0x410, False, pid)
    c = Counters(); c.cb = ctypes.sizeof(c)
    psapi = ctypes.WinDLL('psapi')
    psapi.GetProcessMemoryInfo.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong]
    if not psapi.GetProcessMemoryInfo(handle, ctypes.byref(c), c.cb):
        raise ctypes.WinError()
    kernel.CloseHandle(handle)
    return c.rss


def cpu(pid):
    if os.name != 'nt':
        values = Path(f'/proc/{pid}/stat').read_text().split()
        return (int(values[13]) + int(values[14])) / os.sysconf('SC_CLK_TCK')
    k = ctypes.WinDLL('kernel32', use_last_error=True)
    k.OpenProcess.restype = ctypes.c_void_p
    k.GetProcessTimes.argtypes = [ctypes.c_void_p] + [ctypes.c_void_p] * 4
    k.CloseHandle.argtypes = [ctypes.c_void_p]
    h = k.OpenProcess(0x410, False, pid)
    stamps = [ctypes.c_ulonglong() for _ in range(4)]
    if not k.GetProcessTimes(h, *(ctypes.byref(v) for v in stamps)): raise ctypes.WinError()
    k.CloseHandle(h)
    return (stamps[2].value + stamps[3].value) / 1e7


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--exe', required=True)
    ap.add_argument('--scratch', default=os.path.join(tempfile.gettempdir(), 'lunar-media-benchmark'))
    ap.add_argument('--seconds', type=float, default=10)
    ap.add_argument('--mbps', type=float, default=0, help='pace each of eight readers; 25 tests 200Mb/s aggregate')
    ap.add_argument('--port', type=int, default=18471)
    ap.add_argument('--tls-cert'); ap.add_argument('--tls-key')
    args = ap.parse_args()
    root = Path(args.scratch).resolve(); root.mkdir(parents=True, exist_ok=True)
    block = bytes(i % 251 for i in range(65536))
    media = root / 'fixture.bin'
    with media.open('wb') as f:
        for _ in range(1024): f.write(block)
    # A junction/symlink remains outside the authorized catalog root.
    outside = root.parent / 'outside-media'; outside.mkdir(exist_ok=True)
    (outside / 'fixture.bin').write_bytes(b'FORBIDDEN')
    link = root / 'link'
    if not link.exists():
        if os.name == 'nt':
            subprocess.run(['cmd', '/c', 'mklink', '/J', str(link), str(outside)], check=True, capture_output=True)
        else: link.symlink_to(outside, target_is_directory=True)
    (root / 'empty.bin').write_bytes(b'')
    with (root / 'large.bin').open('wb') as f:
        if os.name == 'nt':
            import msvcrt
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.DeviceIoControl.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p,
                ctypes.c_ulong, ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_void_p]
            returned = ctypes.c_ulong()
            if not kernel.DeviceIoControl(msvcrt.get_osfhandle(f.fileno()), 0x900C4,
                    None, 0, None, 0, ctypes.byref(returned), None): raise ctypes.WinError()
            kernel.SetFilePointerEx.argtypes = [ctypes.c_void_p, ctypes.c_longlong, ctypes.c_void_p, ctypes.c_ulong]
            kernel.SetEndOfFile.argtypes = [ctypes.c_void_p]
            handle = msvcrt.get_osfhandle(f.fileno())
            if not kernel.SetFilePointerEx(handle, 5 * 1024**3, None, 0) or not kernel.SetEndOfFile(handle):
                raise ctypes.WinError()
        else: f.truncate(5 * 1024**3)
        f.seek(2**32 - 4); f.write(b'wide-offset-check')
    command = [str(Path(args.exe).resolve()), 'scripts/media_stream_server.lua', str(root), str(args.port)]
    if args.tls_cert: command += [args.tls_cert, args.tls_key]
    env = os.environ.copy()
    if os.name == 'nt': env['PATH'] = os.environ.get('SystemRoot', 'C:/Windows') + '/System32'
    log = (root / 'server.log').open('w')
    proc = subprocess.Popen(command, stdout=log, stderr=log, env=env)
    context = ssl._create_unverified_context() if args.tls_cert else None
    def conn():
        if context: return http.client.HTTPSConnection('127.0.0.1', args.port, timeout=10, context=context)
        return http.client.HTTPConnection('127.0.0.1', args.port, timeout=10)
    def request(path='/media', method='GET', headers=None, auth=True):
        c = conn(); h = {'Authorization': 'Bearer bench'} if auth else {}
        h.update(headers or {}); start = time.perf_counter()
        c.request(method, path, headers=h); r = c.getresponse()
        ttfb = (time.perf_counter() - start) * 1000
        data = r.read(); result = (r.status, dict(r.getheaders()), data, ttfb)
        c.close(); return result
    try:
        for _ in range(100):
            if proc.poll() is not None: raise RuntimeError((root / 'server.log').read_text())
            try:
                request('/metrics'); break
            except OSError: time.sleep(.05)
        else: raise RuntimeError('startup timeout')
        baseline = rss(proc.pid)
        assert request(auth=False)[0] == 401
        for p in ('traversal', 'reparse', 'escape', 'ads'):
            assert request('/' + p)[0] == 404, p
        assert request('/absolute')[0] == 500
        assert request('/empty')[0:3:2] == (200, b'')
        assert request('/empty', headers={'Range': 'bytes=0-'})[0] == 416
        wide = request('/large', headers={'Range': f'bytes={2**32-4}-{2**32+12}'})
        assert wide[0] == 206 and wide[2] == b'wide-offset-check'
        full = request(); assert full[0] == 200 and len(full[2]) == media.stat().st_size
        assert hashlib.sha256(full[2]).digest() == hashlib.sha256(media.read_bytes()).digest()
        etag = full[1]['ETag']
        modified = full[1]['Last-Modified']
        assert request(headers={'If-Modified-Since': modified})[0] == 304
        assert request(headers={'If-Unmodified-Since': 'Thu, 01 Jan 1970 00:00:00 GMT'})[0] == 412
        assert request(headers={'If-Range': modified, 'Range': 'bytes=0-4'})[0] == 206
        assert request(headers={'If-None-Match': '"other"', 'If-Modified-Since': modified})[0] == 200
        assert request(headers={'If-None-Match': 'W/' + etag})[0] == 304
        assert request(headers={'If-Match': '"wrong"'})[0] == 412
        assert request(headers={'If-Range': '"wrong"', 'Range': 'bytes=0-4'})[0] == 200
        head = request(method='HEAD'); assert head[0] == 200 and not head[2]
        assert int(head[1]['Content-Length']) == media.stat().st_size
        rng = random.Random(42); ttfbs = []
        matrix = [('bytes=0-0', 206, 0, 1), ('bytes=-7', 206, media.stat().st_size-7, 7),
                  ('bytes=67108860-', 206, 67108860, 4), ('bytes=0-999999999', 206, 0, 67108864),
                  ('bytes=67108864-', 416, 0, 0), ('bytes=-0', 416, 0, 0),
                  ('bytes=9-8', 416, 0, 0), ('bytes=0-1,3-4', 416, 0, 0),
                  ('bytes=9223372036854775808-', 416, 0, 0), ('bytes=x-y', 416, 0, 0)]
        for _ in range(990):
            off = rng.randrange(67108864); count = min(rng.randrange(1, 65537), 67108864-off)
            matrix.append((f'bytes={off}-{off+count-1}', 206, off, count))
        with media.open('rb') as f:
            for value, status, off, count in matrix:
                r = request(headers={'Range': value}); assert r[0] == status, (value, r[0])
                f.seek(off); assert r[2] == f.read(count), value
                if status == 206:
                    assert r[1]['Content-Range'] == f'bytes {off}-{off+count-1}/67108864'
                else: assert r[1]['Content-Range'] == 'bytes */67108864'
                ttfbs.append(r[3])
        idle_cpu = cpu(proc.pid); idle_start = time.perf_counter(); time.sleep(.3)
        idle_cores = (cpu(proc.pid) - idle_cpu) / (time.perf_counter() - idle_start)
        start_cpu = cpu(proc.pid)
        started = time.perf_counter(); end = started + args.seconds
        def stream():
            total = 0; stream_start = time.perf_counter()
            while time.perf_counter() < end:
                c = conn(); c.request('GET', '/media', headers={'Authorization': 'Bearer bench'})
                r = c.getresponse(); assert r.status == 200
                while time.perf_counter() < end:
                    data = r.read(65536)
                    if not data: break
                    # fixture repeats at 64KiB boundaries
                    assert data == block[:len(data)]
                    total += len(data)
                    if args.mbps:
                        delay = total * 8 / (args.mbps * 1e6) - (time.perf_counter() - stream_start)
                        if delay > 0: time.sleep(delay)
                c.close()
            return total
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            total = sum(pool.map(lambda _: stream(), range(8)))
        elapsed = time.perf_counter() - started
        cores = (cpu(proc.pid) - start_cpu) / elapsed
        # 32 slow readers: consume no bodies, retaining bounded worker state.
        slow = []
        for _ in range(32):
            c = conn(); c.request('GET', '/media', headers={'Authorization': 'Bearer bench'})
            r = c.getresponse(); assert r.status == 200; slow.append((c, r))
        time.sleep(.2); peak = rss(proc.pid); metrics = json.loads(request('/metrics')[2])
        for c, r in slow: r.close(); c.close()
        deadline = time.perf_counter() + 5
        while json.loads(request('/metrics')[2])['active_transfers']:
            assert time.perf_counter() < deadline, 'cancelled transfers retained'
            time.sleep(.02)
        # Windows denies rename while a stream's owned handle is alive.
        renamed = root / 'released.bin'; media.rename(renamed); renamed.rename(media)
        c = conn(); c.request('GET', '/media', headers={'Authorization': 'Bearer bench'}); r = c.getresponse()
        stop_start = time.perf_counter(); assert request('/stop', 'POST')[0] == 204
        proc.wait(timeout=5); shutdown = time.perf_counter() - stop_start; r.close(); c.close()
        report = dict(platform=os.name, tls=bool(context), seconds=elapsed, streams=8,
                      throughput_mbps=total*8/elapsed/1e6, paced_mbps_per_stream=args.mbps,
                      cpu_cores=cores, incremental_cpu_cores=cores-idle_cores,
                      machine_cpu_percent=cores / (os.cpu_count() or 1) * 100, range_checks=len(matrix), hash_mismatches=0,
                      range_ttfb_p95_ms=sorted(ttfbs)[int(len(ttfbs)*.95)], baseline_rss=baseline,
                      rss_32_slow=peak, incremental_rss=peak-baseline, shutdown_seconds=shutdown, **metrics)
        print(json.dumps(report, indent=2)); (root / ('tls-results.json' if context else 'clear-results.json')).write_text(json.dumps(report, indent=2))
    finally:
        if proc.poll() is None: proc.terminate(); proc.wait(timeout=5)
        log.close()


if __name__ == '__main__': main()

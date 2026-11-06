#!/usr/bin/env python3
"""End-to-end check of the media server on the real headless host.

Builds a throwaway library of generated files, starts lunar-cli, scans, browses, then reads
files through authenticated range requests and compares the bytes. Loopback only.

Run: python scripts/media_server_check.py <lunar-cli> <repo>
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

PORT = 8431
TOKEN = "check-token-0123456789abcdef"
BASE = f"http://127.0.0.1:{PORT}/ext/media-server"


def call(method, path, body=None, headers=None, token=TOKEN):
    request = urllib.request.Request(BASE + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None)
    if token:
        request.add_header("Authorization", "Bearer " + token)
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read()


def expect(condition, label, detail=""):
    print(("ok   " if condition else "FAIL ") + label + (f"  {detail}" if detail and not condition else ""))
    if not condition:
        expect.failed += 1


expect.failed = 0


def main():
    cli, repo = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    work = tempfile.mkdtemp(prefix="lunar_media_check_")
    films = os.path.join(work, "Films")
    os.makedirs(os.path.join(films, "Alien (1979)"))
    payload = bytes(range(256)) * 4096
    with open(os.path.join(films, "Alien (1979)", "Alien (1979).mkv"), "wb") as out:
        out.write(payload)
    with open(os.path.join(films, "Heat (1995).mp4"), "wb") as out:
        out.write(payload[:1000])
    with open(os.path.join(work, "secret.txt"), "w") as out:
        out.write("outside the library")
    tokens = os.path.join(work, "tokens")
    with open(tokens, "w") as out:
        out.write("alice " + TOKEN + "\n")
    argv = [cli, "--headless", "--dev", "--extensions", os.path.join(repo, "extensions"),
            "--require", "media-server", "--listen", f"127.0.0.1:{PORT}", "--tokens-file", tokens,
            "--state-dir", os.path.join(work, "state"), "--log-level", "WARN"]
    server = subprocess.Popen(argv, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        for _ in range(60):
            try:
                if call("GET", "/v1/status")[0] == 200:
                    break
            except OSError:
                pass
            if server.poll() is not None:
                break
            time.sleep(0.25)
        status, _, body = call("GET", "/v1/status")
        expect(status == 200, "status answers", body.decode(errors="replace"))
        expect(json.loads(body)["analysis"] == "off", "says analysis is off without ffprobe")
        expect(call("GET", "/v1/status", token=None)[0] == 401, "refuses a request with no token")
        expect(call("GET", "/v1/status", token="wrong")[0] == 401, "refuses a wrong token")

        status, _, body = call("POST", "/v1/libraries", {"name": "Films", "kind": "movie", "root": films})
        expect(status == 201, "adds a library", body.decode(errors="replace"))
        library = json.loads(body)["id"]
        expect(call("POST", "/v1/libraries", {"name": "x", "kind": "movie", "root": "relative"})[0] == 400, "refuses a relative root")
        expect(call("POST", "/v1/libraries", {"name": "x", "kind": "movie", "root": films})[0] == 409, "refuses a duplicate root")

        items = []
        for _ in range(40):
            items = json.loads(call("GET", f"/v1/libraries/{library}/items")[2])["items"]
            if len(items) == 2:
                break
            time.sleep(0.1)
        expect([i["title"] for i in items] == ["Alien", "Heat"], "scan fills the library in order", str(items))

        found = json.loads(call("GET", "/v1/search?q=ali")[2])["items"]
        expect(len(found) == 1 and found[0]["title"] == "Alien", "search finds by prefix", str(found))

        item = json.loads(call("GET", f"/v1/items/{items[0]['id']}")[2])
        file_id = item["files"][0]["id"]
        path = f"/v1/files/{file_id}/stream"

        status, headers, body = call("GET", path)
        expect(status == 200 and body == payload, "streams the whole file", f"{status} {len(body)}")
        expect(call("GET", path, token=None)[0] == 401, "refuses a stream with no token")
        status, headers, body = call("HEAD", path)
        expect(status == 200 and body == b"", "HEAD has no body", str(status))
        status, headers, body = call("GET", path, headers={"Range": "bytes=1000-1999"})
        expect(status == 206 and body == payload[1000:2000], "reads a range", str(status))
        expect(headers.get("Content-Range") == f"bytes 1000-1999/{len(payload)}", "reports the range", str(headers))
        status, _, body = call("GET", path, headers={"Range": "bytes=-100"})
        expect(status == 206 and body == payload[-100:], "reads a suffix range", str(status))
        expect(call("GET", path, headers={"Range": f"bytes={len(payload)}-"})[0] == 416, "refuses a range past the end")
        expect(call("GET", "/v1/files/999999/stream")[0] == 404, "unknown file is 404")

        status, _, _ = call("POST", f"/v1/items/{items[0]['id']}/progress", {"position_ms": 5000, "duration_ms": 100000})
        expect(status == 204, "saves progress", str(status))
        resume = json.loads(call("GET", "/v1/continue")[2])["items"]
        expect(len(resume) == 1 and resume[0]["position_ms"] == 5000, "continue watching returns it", str(resume))

        decision = call("POST", f"/v1/files/{file_id}/decision", {"capabilities": {"containers": ["mp4"]}})
        expect(json.loads(decision[2])["mode"] == "refuse", "an unanalysed file is refused with a reason", str(decision[2]))

        os.remove(os.path.join(films, "Heat (1995).mp4"))
        call("POST", f"/v1/libraries/{library}/scan")
        for _ in range(40):
            if json.loads(call("GET", "/v1/status")[2])["missing"] == 1:
                break
            time.sleep(0.1)
        counts = json.loads(call("GET", "/v1/status")[2])
        expect(counts["missing"] == 1 and counts["items"] == 2, "a removed file is kept as missing", str(counts))
        heat = json.loads(call("GET", f"/v1/items/{items[1]['id']}")[2])
        expect(call("GET", f"/v1/files/{heat['files'][0]['id']}/stream")[0] == 410, "a missing file is 410")
    finally:
        server.terminate()
        try:
            output = server.communicate(timeout=15)[0]
        except subprocess.TimeoutExpired:
            server.kill()
            output = server.communicate()[0]
        print(output.decode(errors="replace")[-600:])
        shutil.rmtree(work, ignore_errors=True)
    print("failed:", expect.failed)
    return 1 if expect.failed else 0


if __name__ == "__main__":
    sys.exit(main())

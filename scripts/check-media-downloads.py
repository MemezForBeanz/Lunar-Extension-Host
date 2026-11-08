"""Loopback-only native discovery -> resolution -> download -> catalog check.

Usage: python scripts/check-media-downloads.py <LunarCLI.exe> <staged-plugins>
Uses generated media and isolated state; keeps logs under build/.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import uuid

repo = Path(__file__).resolve().parents[1]
exe, plugins = (Path(arg).resolve() for arg in sys.argv[1:3])
work = repo / "build" / ("download-native-check-" + uuid.uuid4().hex)
library = work / "library"
library.mkdir(parents=True)
fixture = work / "fixture.mp4"
ffmpeg = plugins / "media-server/runtime/windows-x86_64/bin/ffmpeg.exe"
subprocess.run([str(ffmpeg), "-v", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=1",
                "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(fixture)], check=True)
media = fixture.read_bytes()


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        status, headers = 200, {"Content-Type": "text/html"}
        if self.path == "/show":
            body = b'<title>Owned fixture</title><meta name="description" content="Owned test episode"><iframe src="/embed"></iframe>'
        elif self.path == "/embed":
            body = b'<video><source src="/redirect.mp4"></video>'
        elif self.path == "/redirect.mp4":
            status, body = 302, b"<html>redirect body must be discarded</html>"
            headers["Location"] = "/media.mp4"
        elif self.path == "/media.mp4":
            if self.headers.get("Referer") != fixture_base + "/embed":
                status, body = 403, b"missing episode referer"
            else:
                body, headers = media, {"Content-Type": "video/mp4"}
        else:
            status, body = 404, b"missing fixture"
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


fixture_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
fixture_base = "http://127.0.0.1:" + str(fixture_server.server_port)
threading.Thread(target=fixture_server.serve_forever, daemon=True).start()
with socket.socket() as reservation:
    reservation.bind(("127.0.0.1", 0))
    port = reservation.getsockname()[1]
token = "isolated-native-download-fixture-token"
tokens = work / "tokens"
tokens.write_text("fixture " + token)
base = f"http://127.0.0.1:{port}/ext/media-server/v1"


def call(method, path, body=None):
    request = urllib.request.Request(base + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": "Bearer " + token})
    if body is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)


def wait_for(operation, predicate, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        answer = operation()
        if predicate(answer):
            return answer
        time.sleep(0.05)
    raise AssertionError("Native fixture timed out")


with (work / "server.log").open("wb") as log:
    process = subprocess.Popen([str(exe), "--headless", "--dev", "--extensions", str(plugins),
                                "--require", "media-server", "--listen", f"127.0.0.1:{port}",
                                "--state-dir", str(work / "state"), "--secrets-dir", str(work / "secrets"),
                                "--tokens-file", str(tokens), "--for", "40"], cwd=str(repo),
                               stdout=log, stderr=subprocess.STDOUT,
                               creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    try:
        deadline = time.monotonic() + 10
        while True:
            try:
                call("GET", "/status")
                break
            except OSError:
                if process.poll() is not None or time.monotonic() > deadline:
                    raise AssertionError("Native server failed; see " + str(work / "server.log"))
                time.sleep(0.1)
        destination = call("POST", "/libraries", {"name": "Owned fixture", "kind": "movie", "root": str(library)})
        discovery = call("POST", "/discover", {"provider": "video-page", "url": fixture_base + "/show"})
        found = wait_for(lambda: call("GET", "/discover/" + discovery["id"]), lambda x: x["state"] in ("ready", "failed"))
        assert found["state"] == "ready", found
        item = found["result"]["items"][0]
        job = call("POST", f'/discover/{discovery["id"]}/download', {"key": item["key"], "library_id": destination["id"]})
        rows = wait_for(lambda: call("GET", "/downloads")["downloads"],
                        lambda xs: any(x["id"] == job["id"] and x["state"] in ("complete", "failed") for x in xs))
        finished = next(x for x in rows if x["id"] == job["id"])
        assert finished["state"] == "complete", finished
        assert "request_headers" not in finished and "temp_path" not in finished
        copied = library / finished["rel_path"]
        assert copied.read_bytes() == media, "Downloaded bytes differ from generated fixture"
        items = wait_for(lambda: call("GET", f'/libraries/{destination["id"]}/items')["items"], bool)
        detail = call("GET", f'/items/{items[0]["id"]}')
        assert detail["files"][0]["origin_url"] == fixture_base + "/show", detail
        assert not list(library.rglob("*.lunar-part")), "Partial output remained"
        print("PASS: native discovery, iframe resolution, Referer, redirect-safe transfer, exact bytes, post-scan provenance")
        print("Fixture SHA256: " + hashlib.sha256(media).hexdigest())
        print("Isolated artifacts: " + str(work))
    finally:
        process.terminate()
        process.wait(timeout=5)
        fixture_server.shutdown()

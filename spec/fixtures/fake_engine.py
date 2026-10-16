"""Fake engine for scripts/process_check.lua.

Speaks protocol v1 (one JSON object per stdout line) and misbehaves on purpose,
one way per mode. Standard library only.

    python -u fake_engine.py <mode> [args...]
"""
import json
import os
import subprocess
import sys
import time


def emit(**event):
    event["v"] = 1
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "ok"

    if mode == "ok":
        # Progress on stdout while stderr floods with warnings that look like protocol.
        for i in range(1, 51):
            emit(type="progress", step="upload", done=i, total=50)
            sys.stderr.write('UserWarning: {"v":1,"type":"result","ok":false} %d\n' % i)
        sys.stderr.flush()
        emit(type="result", ok=True, summary="50 uploaded")

    elif mode == "args":
        # Echo argv so the host can check quoting round-trips exactly.
        emit(type="result", ok=True, data={"argv": sys.argv[2:], "cwd": os.getcwd()})

    elif mode == "secrets":
        # Credentials arrive on stdin and in the environment, never in argv.
        token = sys.stdin.read().strip()
        emit(type="result", ok=True, data={"stdin": token, "env": os.environ.get("FAKE_TOKEN"),
                                           "removed": os.environ.get("FAKE_REMOVED")})

    elif mode == "ignore_stdin":
        # Never reads stdin: a host that writes it synchronously would hang here.
        emit(type="result", ok=True, summary="ignored stdin")

    elif mode == "crash":
        emit(type="progress", done=1, total=3)
        raise RuntimeError("boom in the engine")

    elif mode == "noresult":
        emit(type="progress", done=1, total=1)

    elif mode == "big":
        # One oversized line, then a burst of normal ones, then the result.
        sys.stdout.write("x" * (3 * 1024 * 1024) + "\n")
        for i in range(2000):
            emit(type="log", level="info", message="line %d" % i)
        emit(type="result", ok=True, summary="big done")

    elif mode == "slow":
        # A line written in pieces with pauses in between.
        line = json.dumps({"v": 1, "type": "result", "ok": True, "summary": "slow done"})
        for i in range(0, len(line), 7):
            sys.stdout.write(line[i:i + 7])
            sys.stdout.flush()
            time.sleep(0.02)
        sys.stdout.write("\n")

    elif mode == "hang":
        # Start a grandchild, report its pid, then never finish.
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)"])
        emit(type="log", level="info", message="grandchild", pid=child.pid)
        time.sleep(600)

    else:
        sys.stderr.write("unknown mode %s\n" % mode)
        sys.exit(64)


if __name__ == "__main__":
    main()

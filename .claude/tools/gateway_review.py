#!/usr/bin/env python3
"""Read-only council reviewer backed by the Vercel AI Gateway.

Usage:
    git diff main | python gateway_review.py "Review this change for bugs."
    python gateway_review.py "Review these" --file a.lua --file b.cpp
    python gateway_review.py "Review this" --diff main      # runs git diff main

Key lookup: $AI_GATEWAY_API_KEY, else the file named by $AI_GATEWAY_KEY_FILE.
Model: $AI_GATEWAY_MODEL (default meituan/longcat-2.5).
The model gets only the text you send it; it cannot read or change the repo.
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

URL = "https://ai-gateway.vercel.sh/v1/chat/completions"
SYSTEM = (
    "You are a senior code reviewer on a review council. You are read-only. "
    "Review the supplied material for correctness bugs, regressions, missing "
    "tests, and scope creep. Be concrete: cite file and line when you can, and "
    "skip style nitpicks. End with a line of the exact form `Score: N/10`."
)


def get_key():
    key = os.environ.get("AI_GATEWAY_API_KEY")
    if not key and os.environ.get("AI_GATEWAY_KEY_FILE"):
        with open(os.environ["AI_GATEWAY_KEY_FILE"], encoding="utf-8") as f:
            key = f.read()
    key = (key or "").strip()
    if not key:
        sys.exit("No key: set AI_GATEWAY_API_KEY or AI_GATEWAY_KEY_FILE.")
    return key


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("request", help="what to review / the question")
    ap.add_argument("--file", action="append", default=[], help="file to include")
    ap.add_argument("--diff", help="git ref to diff against (git diff <ref>)")
    ap.add_argument("--model", default=os.environ.get("AI_GATEWAY_MODEL", "meituan/longcat-2.5"))
    ap.add_argument("--max-tokens", type=int, default=8000)
    args = ap.parse_args()

    parts = [args.request]
    if args.diff:
        out = subprocess.run(["git", "diff", args.diff], capture_output=True, text=True, encoding="utf-8")
        parts.append("=== git diff %s ===\n%s" % (args.diff, out.stdout))
    for path in args.file:
        with open(path, encoding="utf-8", errors="replace") as f:
            parts.append("=== %s ===\n%s" % (path, f.read()))
    if not sys.stdin.isatty():
        piped = sys.stdin.read()
        if piped.strip():
            parts.append("=== stdin ===\n" + piped)

    body = json.dumps({
        "model": args.model,
        "max_tokens": args.max_tokens,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": "\n\n".join(parts)},
        ],
    }).encode("utf-8")
    req = urllib.request.Request(URL, data=body, headers={
        "Authorization": "Bearer " + get_key(),
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit("Gateway error %s: %s" % (e.code, e.read().decode("utf-8", "replace")[:500]))
    sys.stdout.reconfigure(encoding="utf-8")
    print(data["choices"][0]["message"]["content"])


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate abstract placeholder posters for the Media capture fixture, as PNG.

The art is original and procedural: flat shapes on a dark ground, no text, seeded so that
every run produces the same files. Standard library only.

Run: python make_media_fixture_art.py <out_dir> [count]
"""
import math
import os
import random
import struct
import sys
import zlib

WIDTH, HEIGHT = 600, 900

PALETTES = [
    ((15, 42, 63), (31, 111, 139), (242, 193, 78)), ((35, 25, 66), (94, 84, 142), (224, 177, 203)),
    ((27, 45, 42), (58, 125, 68), (201, 228, 202)), ((43, 26, 20), (164, 74, 63), (246, 189, 96)),
    ((16, 21, 28), (61, 90, 128), (238, 108, 77)), ((26, 20, 35), (109, 89, 122), (234, 172, 139)),
    ((11, 32, 39), (64, 121, 140), (207, 215, 199)), ((33, 19, 13), (153, 88, 42), (255, 230, 167)),
    ((20, 30, 48), (42, 157, 143), (233, 196, 106)), ((45, 15, 27), (154, 23, 80), (227, 175, 188)),
    ((16, 32, 26), (45, 106, 79), (183, 228, 199)), ((22, 26, 43), (67, 97, 238), (200, 211, 245)),
]


class Canvas:
    def __init__(self, ground):
        self.rows = [bytearray(bytes(ground) * WIDTH) for _ in range(HEIGHT)]

    def span(self, y, x0, x1, colour):
        if 0 <= y < HEIGHT:
            x0, x1 = max(0, int(x0)), min(WIDTH, int(x1))
            if x1 > x0:
                self.rows[y][x0 * 3:x1 * 3] = bytes(colour) * (x1 - x0)

    def rect(self, x, y, w, h, colour):
        for row in range(int(y), int(y + h)):
            self.span(row, x, x + w, colour)

    def circle(self, cx, cy, r, colour):
        for row in range(int(cy - r), int(cy + r) + 1):
            half = math.sqrt(max(0, r * r - (row - cy) ** 2))
            self.span(row, cx - half, cx + half, colour)

    def polygon(self, points, colour):
        for row in range(HEIGHT):
            crossings = []
            for i, (x0, y0) in enumerate(points):
                x1, y1 = points[(i + 1) % len(points)]
                if (y0 <= row < y1) or (y1 <= row < y0):
                    crossings.append(x0 + (row - y0) / (y1 - y0) * (x1 - x0))
            crossings.sort()
            for a, b in zip(crossings[::2], crossings[1::2]):
                self.span(row, a, b, colour)

    def png(self):
        raw = b"".join(b"\x00" + bytes(row) for row in self.rows)

        def chunk(tag, data):
            body = tag + data
            return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

        header = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0)
        return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")


def rings(canvas, rng, a, b):
    cx, cy = rng.uniform(.3, .7) * WIDTH, rng.uniform(.3, .6) * HEIGHT
    for i in range(rng.randint(3, 6), 0, -1):
        canvas.circle(cx, cy, i * WIDTH * .13, a if i % 2 else b)


def hills(canvas, rng, a, b):
    for i, colour in enumerate((a, b)):
        base = HEIGHT * (.55 + .2 * i)
        phase, amp = rng.uniform(0, 6), rng.uniform(.04, .1) * HEIGHT
        points = [(0, HEIGHT)]
        points += [(x, base + amp * math.sin(x / WIDTH * 6 + phase)) for x in range(0, WIDTH + 8, 8)]
        points.append((WIDTH, HEIGHT))
        canvas.polygon(points, colour)


def blocks(canvas, rng, a, b):
    x = 0
    while x < WIDTH:
        w, h = rng.randint(60, 140), rng.uniform(.25, .75) * HEIGHT
        canvas.rect(x, HEIGHT - h, w, h, rng.choice((a, b)))
        x += w + rng.randint(8, 24)


def beams(canvas, rng, a, b):
    origin = rng.uniform(.2, .8) * WIDTH
    for i in range(rng.randint(3, 5)):
        x1 = rng.uniform(-.2, 1.2) * WIDTH
        canvas.polygon([(origin, 0), (x1, HEIGHT), (x1 + rng.uniform(.1, .25) * WIDTH, HEIGHT)], a if i % 2 else b)


def draw(path, seed):
    rng = random.Random(seed)
    ground, a, b = PALETTES[seed % len(PALETTES)]
    canvas = Canvas(ground)
    (rings, hills, blocks, beams)[seed % 4](canvas, rng, a, b)
    with open(path, "wb") as out:
        out.write(canvas.png())


def main():
    global WIDTH, HEIGHT
    out_dir = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 32
    os.makedirs(out_dir, exist_ok=True)
    for seed in range(1, count + 1):
        WIDTH, HEIGHT = 600, 900
        draw(os.path.join(out_dir, f"poster-{seed:02d}.png"), seed)
        WIDTH, HEIGHT = 1280, 720
        draw(os.path.join(out_dir, f"backdrop-{seed:02d}.png"), seed)
    print(f"wrote {count} posters and backdrops to {out_dir}")


if __name__ == "__main__":
    main()

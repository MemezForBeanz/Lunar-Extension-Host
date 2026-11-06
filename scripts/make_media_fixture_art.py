#!/usr/bin/env python3
"""Generate abstract placeholder posters for the Media capture fixture.

The art is original and procedural: flat shapes on a dark ground, no text, seeded so that
every run produces the same files. Run: python make_media_fixture_art.py <out_dir> [count]
"""
import math
import os
import random
import sys

PALETTES = [
    ("#0f2a3f", "#1f6f8b", "#f2c14e"), ("#231942", "#5e548e", "#e0b1cb"), ("#1b2d2a", "#3a7d44", "#c9e4ca"),
    ("#2b1a14", "#a44a3f", "#f6bd60"), ("#10151c", "#3d5a80", "#ee6c4d"), ("#1a1423", "#6d597a", "#eaac8b"),
    ("#0b2027", "#40798c", "#cfd7c7"), ("#21130d", "#99582a", "#ffe6a7"), ("#141e30", "#2a9d8f", "#e9c46a"),
    ("#2d0f1b", "#9a1750", "#e3afbc"), ("#10201a", "#2d6a4f", "#b7e4c7"), ("#161a2b", "#4361ee", "#c8d3f5"),
]


def rings(rng, w, h, a, b):
    cx, cy = rng.uniform(.3, .7) * w, rng.uniform(.3, .6) * h
    out = []
    for i in range(rng.randint(3, 6), 0, -1):
        out.append(f'<circle cx="{cx:.0f}" cy="{cy:.0f}" r="{i * w * .13:.0f}" fill="{a if i % 2 else b}"/>')
    return out


def hills(rng, w, h, a, b):
    out = []
    for i, colour in enumerate((a, b)):
        base = h * (.55 + .2 * i)
        points = [f"0,{h}"]
        phase, amp = rng.uniform(0, 6), rng.uniform(.04, .1) * h
        for x in range(0, w + 20, 20):
            points.append(f"{x},{base + amp * math.sin(x / w * 6 + phase):.0f}")
        points.append(f"{w},{h}")
        out.append(f'<polygon points="{" ".join(points)}" fill="{colour}"/>')
    return out


def blocks(rng, w, h, a, b):
    out = []
    x = 0
    while x < w:
        bw = rng.randint(30, 70)
        bh = rng.uniform(.25, .75) * h
        out.append(f'<rect x="{x}" y="{h - bh:.0f}" width="{bw}" height="{bh:.0f}" fill="{rng.choice((a, b))}"/>')
        x += bw + rng.randint(4, 12)
    return out


def beams(rng, w, h, a, b):
    out = []
    ox = rng.uniform(.2, .8) * w
    for i in range(rng.randint(3, 5)):
        x1 = rng.uniform(-.2, 1.2) * w
        x2 = x1 + rng.uniform(.1, .25) * w
        out.append(f'<polygon points="{ox:.0f},0 {x1:.0f},{h} {x2:.0f},{h}" fill="{a if i % 2 else b}"/>')
    return out


def write_poster(path, seed, w=300, h=450):
    rng = random.Random(seed)
    ground, a, b = PALETTES[seed % len(PALETTES)]
    draw = (rings, hills, blocks, beams)[seed % 4]
    body = "\n".join(draw(rng, w, h, a, b))
    with open(path, "w", encoding="utf8") as out:
        out.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">\n'
                  f'<rect width="{w}" height="{h}" fill="{ground}"/>\n{body}\n</svg>\n')


def main():
    out_dir = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 32
    os.makedirs(out_dir, exist_ok=True)
    for i in range(1, count + 1):
        write_poster(os.path.join(out_dir, f"poster-{i:02d}.svg"), i)
    print(f"wrote {count} posters to {out_dir}")


if __name__ == "__main__":
    main()

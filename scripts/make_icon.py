#!/usr/bin/env python3
"""make_icon.py - Build the app icon files from PNG renders of assets/lunar-icon.svg.

Usage:
  make_icon.py <render dir> <assets dir>
  make_icon.py --from-ico <assets dir>     (extract all PNG assets from lunar.ico)

<render dir> holds lunar-<size>.png for every size in SIZES, rendered from the
SVG at that exact size (scripts/make-icon.ps1 does the rendering with a headless
browser, since the SVG embeds PNG layers that no stdlib renderer can draw).

Writes, into <assets dir>:
  lunar.ico          every size, as PNG entries (the exe's ICON resource)
  lunar-icon-32.png  the 32 px render (the embedded `lunar_icon_32` image and
                     the docs favicon)
  app-icon/lunar-<size>.png
                     the Linux icon set (window icon via GTK, and the hicolor
                     theme icons the .deb and AppImage install)

Preserves each render's colours and alpha without adding an outline or background.
Standard library only, like embed_images.py.
"""
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from embed_images import png_to_rgba  # noqa: E402

SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]
# The freedesktop hicolor sizes we ship (a subset of SIZES).
LINUX_SIZES = [16, 24, 32, 48, 64, 128, 256]


def encode_png(w, h, rgba):
    rows = b"".join(b"\x00" + bytes(rgba[y * w * 4:(y + 1) * w * 4]) for y in range(h))

    def chunk(kind, body):
        return (struct.pack(">I", len(body)) + kind + body
                + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9))
            + chunk(b"IEND", b""))


def encode_ico(images):
    """`images` is [(size, png bytes)]. PNG entries are valid in .ico since Vista."""
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    body = b""
    for size, data in images:
        header += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32,
                              len(data), offset + len(body))
        body += data
    return header + body


def dib_to_png(data, size):
    """Convert an uncompressed 32-bit icon bitmap, preserving its embedded alpha."""
    if len(data) < 40:
        sys.exit("truncated icon bitmap header")
    header, width, height, planes, bits, compression = struct.unpack_from("<IiiHHI", data)
    if (header != 40 or width != size or abs(height) != size * 2
            or planes != 1 or bits != 32 or compression != 0):
        sys.exit("only uncompressed 32-bit BITMAPINFOHEADER icon bitmaps are supported")
    if len(data) < header + size * size * 4:
        sys.exit("truncated icon bitmap pixels")
    rgba = bytearray(size * size * 4)
    for y in range(size):
        source_y = size - 1 - y if height > 0 else y
        for x in range(size):
            source = header + (source_y * size + x) * 4
            target = (y * size + x) * 4
            blue, green, red, alpha = data[source:source + 4]
            rgba[target:target + 4] = bytes((red, green, blue, alpha))
    return encode_png(size, size, rgba)


def decode_ico(data):
    """[(size, png bytes)] from PNG or uncompressed 32-bit bitmap ICO entries."""
    if len(data) < 6:
        sys.exit("truncated icon header")
    _, kind, count = struct.unpack_from("<HHH", data, 0)
    if kind != 1:
        sys.exit("not an icon file")
    if len(data) < 6 + 16 * count:
        sys.exit("truncated icon directory")
    out = []
    for i in range(count):
        w, h, _, _, _, _, length, offset = struct.unpack_from("<BBBBHHII", data, 6 + 16 * i)
        if w != h or offset < 6 + 16 * count or offset + length > len(data):
            sys.exit("invalid or non-square icon entry %d" % i)
        png = data[offset:offset + length]
        if not png.startswith(b"\x89PNG\r\n\x1a\n"):
            png = dib_to_png(png, w or 256)
        out.append((w or 256, png))
    return out


def write_linux_icons(images, assets_dir):
    by_size = dict(images)
    folder = os.path.join(assets_dir, "app-icon")
    os.makedirs(folder, exist_ok=True)
    for size in LINUX_SIZES:
        with open(os.path.join(folder, "lunar-%d.png" % size), "wb") as f:
            f.write(by_size[size])
    print("wrote app-icon/lunar-{%s}.png" % ",".join(str(s) for s in LINUX_SIZES))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--from-ico":
        with open(os.path.join(sys.argv[2], "lunar.ico"), "rb") as f:
            images = decode_ico(f.read())
        missing = set(LINUX_SIZES) - dict(images).keys()
        if missing:
            sys.exit("icon is missing required sizes: %s" % sorted(missing))
        with open(os.path.join(sys.argv[2], "lunar-icon-32.png"), "wb") as f:
            f.write(dict(images)[32])
        write_linux_icons(images, sys.argv[2])
        print("wrote lunar-icon-32.png; source lunar.ico unchanged")
        return
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    render_dir, assets_dir = sys.argv[1], sys.argv[2]
    images = []
    for size in SIZES:
        path = os.path.join(render_dir, "lunar-%d.png" % size)
        w, h, rgba = png_to_rgba(path)
        if (w, h) != (size, size):
            sys.exit("%s is %dx%d, expected %dx%d" % (path, w, h, size, size))
        images.append((size, encode_png(w, h, rgba)))
    with open(os.path.join(assets_dir, "lunar.ico"), "wb") as f:
        f.write(encode_ico(images))
    with open(os.path.join(assets_dir, "lunar-icon-32.png"), "wb") as f:
        f.write(dict(images)[32])
    print("wrote lunar.ico (%d sizes) and lunar-icon-32.png" % len(images))
    write_linux_icons(images, assets_dir)


if __name__ == "__main__":
    main()

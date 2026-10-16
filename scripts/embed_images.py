#!/usr/bin/env python3
"""embed_images.py - Decode PNGs into a C header of raw RGBA byte arrays.

Usage:
  embed_images.py <output.h> <name>=<input.png> [<name>=<input.png> ...]

Why this exists
---------------
The app used to call iup.LoadImage() on two small PNGs (the statusbar logo and
the window icon). That single call was the *only* reason the IM imaging library
was linked into the executable, and IM drags in TIFF fax tables, the EXIF/
MakerNote tag database, JPEG, templated colour-space conversion and a static
libstdc++ -- roughly a megabyte of binary for two images totalling 3364 pixels.

Decoding them here instead lets the host build them with IupImageRGBA and drop
IM entirely.

This uses only the Python standard library (zlib) on purpose: the build already
requires Python for embed_lua.py, but adding a Pillow dependency to every dev
machine for two tiny images is not a trade worth making.

Supports the 8-bit PNG colour types actually used by our assets: greyscale (0),
truecolour (2), palette (3), greyscale+alpha (4) and truecolour+alpha (6),
non-interlaced. Anything else raises rather than emitting silently wrong pixels.
"""
import os
import struct
import sys
import zlib

_CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def _read_chunks(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG file")
    pos = 8
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        yield ctype, body
        pos += 12 + length  # length + type + body + crc


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _unfilter(raw, width, height, bpp):
    """Reverse the per-scanline PNG filters. Returns unfiltered pixel bytes."""
    stride = width * bpp
    out = bytearray(stride * height)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        ftype = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride

        if ftype == 0:
            pass
        elif ftype == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                upleft = prev[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + _paeth(left, prev[i], upleft)) & 0xFF
        else:
            raise ValueError("unsupported PNG filter type %d on row %d" % (ftype, y))

        out[y * stride:(y + 1) * stride] = line
        prev = line
    return out


def png_to_rgba(path):
    """Decode a PNG file to (width, height, bytearray of RGBA pixels)."""
    with open(path, "rb") as f:
        data = f.read()

    width = height = depth = ctype = None
    idat = bytearray()
    palette = None
    trns = None

    for name, body in _read_chunks(data):
        if name == b"IHDR":
            width, height, depth, ctype, _comp, _filt, interlace = struct.unpack(
                ">IIBBBBB", body[:13]
            )
            if depth != 8:
                raise ValueError("%s: only 8-bit PNGs are supported (got %d)" % (path, depth))
            if interlace != 0:
                raise ValueError("%s: interlaced PNGs are not supported" % path)
            if ctype not in _CHANNELS:
                raise ValueError("%s: unsupported colour type %d" % (path, ctype))
        elif name == b"PLTE":
            palette = body
        elif name == b"tRNS":
            trns = body
        elif name == b"IDAT":
            idat += body
        elif name == b"IEND":
            break

    if width is None:
        raise ValueError("%s: no IHDR chunk" % path)

    bpp = _CHANNELS[ctype]
    pixels = _unfilter(zlib.decompress(bytes(idat)), width, height, bpp)

    rgba = bytearray(width * height * 4)
    for i in range(width * height):
        s = i * bpp
        d = i * 4
        if ctype == 6:
            rgba[d:d + 4] = pixels[s:s + 4]
        elif ctype == 2:
            rgba[d:d + 3] = pixels[s:s + 3]
            rgba[d + 3] = 255
        elif ctype == 0:
            g = pixels[s]
            rgba[d] = rgba[d + 1] = rgba[d + 2] = g
            rgba[d + 3] = 255
        elif ctype == 4:
            g = pixels[s]
            rgba[d] = rgba[d + 1] = rgba[d + 2] = g
            rgba[d + 3] = pixels[s + 1]
        elif ctype == 3:
            if palette is None:
                raise ValueError("%s: palette image with no PLTE chunk" % path)
            idx = pixels[s]
            rgba[d:d + 3] = palette[idx * 3:idx * 3 + 3]
            rgba[d + 3] = trns[idx] if trns and idx < len(trns) else 255

    return width, height, rgba


def emit(out_path, entries):
    lines = [
        "/* Auto-generated by scripts/embed_images.py -- do not edit.",
        " *",
        " * Raw RGBA pixel data for the handful of bitmaps the app needs at startup.",
        " * Generated at build time so the host does not have to link the IM imaging",
        " * library just to decode two small PNGs; see appimages_wrap.c.",
        " */",
        "#ifndef LUNAR_EMBEDDED_IMAGES_H",
        "#define LUNAR_EMBEDDED_IMAGES_H",
        "",
        "typedef struct LunarEmbeddedImage {",
        "    const char          *name;",
        "    int                  width;",
        "    int                  height;",
        "    const unsigned char *rgba;",
        "} LunarEmbeddedImage;",
        "",
    ]

    for name, path in entries:
        w, h, rgba = png_to_rgba(path)
        sym = "lunar_img_" + name
        lines.append("/* %s -- %dx%d, %d bytes RGBA */" % (os.path.basename(path), w, h, len(rgba)))
        lines.append("static const unsigned char %s[] = {" % sym)
        for i in range(0, len(rgba), 16):
            chunk = rgba[i:i + 16]
            lines.append("    " + ", ".join("0x%02x" % b for b in chunk) + ",")
        lines.append("};")
        lines.append("")
        print("embed_images: %s -> %s (%dx%d, %d bytes)" % (path, sym, w, h, len(rgba)))

    lines.append("static const LunarEmbeddedImage lunar_embedded_images[] = {")
    for name, path in entries:
        w, h, rgba = png_to_rgba(path)
        lines.append('    { "%s", %d, %d, lunar_img_%s },' % (name, w, h, name))
    lines.append("    { 0, 0, 0, 0 }")
    lines.append("};")
    lines.append("")
    lines.append("#endif /* LUNAR_EMBEDDED_IMAGES_H */")

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print(__doc__)
        sys.exit(1)

    out_path = args[0]
    entries = []
    for spec in args[1:]:
        if "=" not in spec:
            print("ERROR: expected <name>=<path>, got %r" % spec, file=sys.stderr)
            sys.exit(1)
        name, path = spec.split("=", 1)
        entries.append((name, path))

    emit(out_path, entries)


if __name__ == "__main__":
    main()

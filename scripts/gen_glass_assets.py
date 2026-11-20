"""Bake the Lunar glass backdrops and the floating-panel shadow into assets/glass/.

Run once, offline, whenever the art changes (needs Pillow and numpy):

    python scripts/gen_glass_assets.py

Writes, for each mode (dark, light):
  lunar-<mode>.png       the window floor: space, an oversized cropped crescent along the
                         upper-left perimeter, and (dark) a baked starfield
  lunar-<mode>-blur.png  the softened copy glass surfaces sample (quarter size)
and shadow.png, a white nine-slice whose alpha is a soft rounded-rect shadow.

core.ui.Glass loads them at run time and never generates pixels itself. The output is
deterministic (fixed seed), so re-running it without changes produces the same files.
"""
import os
import numpy as np
from PIL import Image, ImageFilter

W, H = 1600, 900          # stretched to the window by "cover" scaling, anchored top-left
BLUR_W, BLUR_H = 400, 225
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "glass")


def hexrgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float64) / 255.0


def to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


# The moon: a big disc whose centre is off the top-left corner. Its lit limb is the band
# inside the disc and outside a second disc shifted towards the corner, so the band is
# convex towards the window and widest across the upper-left shoulder.
CX, CY, R = -150.0, -250.0, 820.0
# The shadow disc is larger and pushed towards the corner, so the lit band tapers from
# about 110 px across the shoulder to about 40 px where it leaves the window.
R2 = R + 360.0
SHIFT = -470.0 * np.array([np.cos(np.radians(49)), np.sin(np.radians(49))])


def crescent_fields():
    y, x = np.mgrid[0:H, 0:W].astype(np.float64) + 0.5
    d1 = np.hypot(x - CX, y - CY)                       # distance to the outer disc's centre
    d2 = np.hypot(x - (CX + SHIFT[0]), y - (CY + SHIFT[1]))
    outer = R - d1                                       # > 0 inside the outer disc
    inner = d2 - R2                                      # > 0 outside the shadow disc
    band = np.clip(outer, 0, None) + np.clip(inner, 0, None)
    # s: 0 at the lit outer edge, 1 at the dark inner edge (where both distances meet).
    width = np.maximum(outer + inner, 1e-3)
    s = np.clip(1 - outer / width, 0, 1)
    inside = (outer > 0) & (inner > 0)
    # Anti-aliased coverage of the band.
    cover = np.clip(outer + 0.5, 0, 1) * np.clip(inner + 0.5, 0, 1)
    # Position along the arc: 0 where it leaves the top edge, 1 at the left edge.
    ang = np.arctan2(y - CY, x - CX)
    a0, a1 = np.arctan2(0 - CY, 600 - CX), np.arctan2(560 - CY, 0 - CX)
    along = np.clip((ang - a0) / (a1 - a0), 0, 1)
    return x, y, d1, s, inside, cover, along, outer, inner


def starfield(rng, mask_space, dark_mode):
    """Point stars (1-2 px, 15-30 %) and a few four-point stars, as an alpha map."""
    a = np.zeros((H, W))
    if not dark_mode:
        return a
    count = int(W * H / 9000)
    xs, ys = rng.integers(0, W, count), rng.integers(0, H, count)
    for x, y in zip(xs, ys):
        if not mask_space[y, x]:
            continue
        alpha = rng.uniform(0.15, 0.30)
        if rng.random() < 0.25 and 0 < x < W - 1 and 0 < y < H - 1:     # a 2 px star
            a[y, x] = max(a[y, x], alpha)
            a[y, x + 1] = max(a[y, x + 1], alpha * 0.7)
            a[y + 1, x] = max(a[y + 1, x], alpha * 0.7)
            a[y + 1, x + 1] = max(a[y + 1, x + 1], alpha * 0.45)
        else:
            a[y, x] = max(a[y, x], alpha)
    # Four-point stars, placed in margins that stay exposed: the empty middle of the
    # title strip between the search field and the window buttons, the rail's empty
    # middle, the right-hand reveal and the bottom corner.
    sparkles = [(1090, 18, 5, 0.55), (1270, 11, 3, 0.40), (20, 395, 5, 0.50), (22, 640, 3, 0.38),
                (1592, 300, 4, 0.42), (1593, 690, 3, 0.35), (1460, 880, 3, 0.35)]
    yy, xx = np.mgrid[-8:9, -8:9].astype(np.float64)
    for cx, cy, arm, peak in sparkles:
        # a thin cross with a soft core: the logo's four-point star
        cross = np.exp(-(np.abs(xx) / arm) ** 1.2) * np.exp(-(yy / 0.6) ** 2) \
            + np.exp(-(np.abs(yy) / arm) ** 1.2) * np.exp(-(xx / 0.6) ** 2)
        core = np.exp(-(xx ** 2 + yy ** 2) / 1.2)
        star = np.clip(cross * 0.8 + core, 0, 1) * peak
        y0, x0 = cy - 8, cx - 8
        ys0, xs0 = max(0, y0), max(0, x0)
        ys1, xs1 = min(H, y0 + 17), min(W, x0 + 17)
        a[ys0:ys1, xs0:xs1] = np.maximum(a[ys0:ys1, xs0:xs1], star[ys0 - y0:ys1 - y0, xs0 - x0:xs1 - x0])
    return a


def backdrop(dark_mode):
    rng = np.random.default_rng(731)
    x, y, d1, s, inside, cover, along, outer, inner = crescent_fields()
    if dark_mode:
        space = to_linear(hexrgb("#080A0F"))
        silver = to_linear(hexrgb("#67717E"))           # the brightest the arc gets
        base = np.broadcast_to(space, (H, W, 3)).copy()
        # A faint ambient glow just outside the lit limb, so the arc sits in light.
        halo = np.exp(-np.clip(-outer, 0, None) / 160.0) * (outer < 0) * 0.10
        base += halo[..., None] * (silver - space)
        # Across the band: a thin bright rim at the outer edge, a broad curved reflection,
        # then the dark inner edge.
        rim = np.exp(-(s / 0.035) ** 2) * 0.85
        sheen = np.exp(-((s - 0.32) / 0.20) ** 2) * 0.75
        body = 0.22 * (1 - s) ** 1.5
        k = np.clip(rim + sheen + body, 0, 1) * (1 - smoothstep(0.80, 1.0, s) * 0.9)
        # Along the arc: brightest at the shoulder, easing where it runs off the edges.
        k *= 0.55 + 0.45 * np.sin(np.pi * np.clip(along * 0.9 + 0.05, 0, 1))
        img = base + (cover * k)[..., None] * (silver - base)
        stars = starfield(rng, ~inside & (cover < 0.01), True)
        img = img + stars[..., None] * (to_linear(hexrgb("#F2F4F7")) - img)
    else:
        pearl, grey = to_linear(hexrgb("#E9EEF4")), to_linear(hexrgb("#BAC5D1"))
        # Pearl in the upper-left, silver-grey towards the far corner.
        t = np.clip((x / W) * 0.55 + (y / H) * 0.45, 0, 1)[..., None]
        img = pearl + (grey - pearl) * smoothstep(0.0, 1.0, t)
        white, graphite = np.ones(3), to_linear(hexrgb("#5B6573"))
        # The arc as a pearl highlight, with a soft graphite underside along its inner edge.
        rim = np.exp(-(s / 0.05) ** 2)
        sheen = np.exp(-((s - 0.30) / 0.22) ** 2) * 0.80
        k = np.clip(rim + sheen, 0, 1) * (1 - smoothstep(0.6, 1.0, s))
        k *= 0.65 + 0.35 * np.sin(np.pi * np.clip(along * 0.9 + 0.05, 0, 1))
        img = img + (cover * k)[..., None] * (white - img)
        under = np.exp(-((s - 0.93) / 0.12) ** 2) * cover * 0.22
        beyond = np.exp(-np.clip(-inner, 0, None) / 18.0) * (inner <= 0) * (outer > 0) * 0.16
        img = img + (under + beyond)[..., None] * (graphite - img)
        halo = np.exp(-np.clip(-outer, 0, None) / 140.0) * (outer < 0) * 0.25
        img = img + halo[..., None] * (white - img)
    rgb = (to_srgb(img) * 255 + rng.uniform(-0.5, 0.5, img.shape)).round().clip(0, 255).astype(np.uint8)
    return Image.fromarray(rgb)


def blurred(img):
    # About 24 window pixels of softening, then quarter size: the glass samples this.
    return img.filter(ImageFilter.GaussianBlur(12)).resize((BLUR_W, BLUR_H), Image.LANCZOS) \
        .filter(ImageFilter.GaussianBlur(2))


def shadow():
    """96x96 white, alpha = a rounded rect (48x48, radius 16) blurred over ~18 px."""
    size, pad, radius = 96, 24, 16
    scale = 4
    big = Image.new("L", (size * scale, size * scale), 0)
    from PIL import ImageDraw
    ImageDraw.Draw(big).rounded_rectangle(
        [pad * scale, pad * scale, (size - pad) * scale - 1, (size - pad) * scale - 1], radius * scale, fill=255)
    mask = big.resize((size, size), Image.LANCZOS).filter(ImageFilter.GaussianBlur(6))
    out = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    out.putalpha(mask)
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    for mode in ("dark", "light"):
        img = backdrop(mode == "dark")
        img.save(os.path.join(OUT, "lunar-%s.png" % mode), optimize=True)
        soft = blurred(img)
        soft.save(os.path.join(OUT, "lunar-%s-blur.png" % mode), optimize=True)
        # The palette's glassSampleWorst: the brightest (dark) / darkest (light) sample.
        px = np.asarray(soft.convert("RGB")).reshape(-1, 3).astype(int)
        pick = px[px.sum(1).argmax()] if mode == "dark" else px[px.sum(1).argmin()]
        print("lunar-%s glassSampleWorst = \"%d %d %d\"" % ((mode,) + tuple(pick)))
    shadow().save(os.path.join(OUT, "shadow.png"), optimize=True)
    print("wrote", os.path.abspath(OUT))


if __name__ == "__main__":
    main()

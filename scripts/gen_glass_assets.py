"""Bake the Lunar glass backdrops and the floating-panel shadow into assets/glass/.

Run once, offline, whenever the art changes (needs Pillow and numpy):

    python scripts/gen_glass_assets.py

Writes, for each mode (dark, light):
  lunar-<mode>.png       the window floor, 1600 x 900: space (dark) or pearl (light), the
                         logo's silver crescent in the exposed left strip with two four-point
                         stars on its open side, and fourteen point stars
  lunar-<mode>-blur.png  the softened 400 x 225 copy glass surfaces sample (6 px Gaussian on
                         the source, then downsampled)
and shadow.png, a white nine-slice whose alpha is a soft rounded-rect shadow.

core.ui.Glass loads them at run time and never generates pixels itself. Under the top-left
"cover" mapping the crescent is about 89 x 174 px at 1920 x 1080 and 66 x 129 px at
1100 x 800, inside the left strip the work sheet leaves bare (core.ui.WorkspaceFrame).
The output is deterministic, so re-running it without changes produces the same files.
It prints each mode's worst glass sample under labels (the palettes' glassSampleWorst).
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

W, H = 1600, 900
BLUR_W, BLUR_H = 400, 225
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "glass")

# The crescent: right-opening, 74 x 145 px with its box at (8, 105), 22 px at the shoulder.
# It is the part of the outer disc outside the inner one; both centres sit on the
# shoulder's row, the inner disc passing through both horns and the shoulder's inner edge.
OUTER = (80.5, 177.5, 72.5)
INNER = (106.5, 177.5, 76.5)
# The lower half turns 12 degrees clockwise about the shoulder; the result is fitted back
# into the same 74 x 145 box.
TILT, BOX = 12.0, (8.0, 105.0, 74.0, 145.0)
# Two four-point stars on the open side (tip to tip, peak opacity dark / light): the
# principal one clearly larger, both with sharp tips.
SPARKLES = [(58.0, 158.0, 22.0, 1.0, 1.0), (71.0, 210.0, 9.0, 0.64, 0.76)]
# The lower shoulder: up to 6 px more band on the concave side through the lower third,
# tapering to nothing at both tips.
LOWER_SHOULDER = 6.0
# Fourteen point stars, 1-2 px: eight near the crescent, six in exposed perimeter space
# (the left strip below the crescent, the top reveal, the right reveal). Clear of labels.
NEAR = [(22, 84), (44, 96), (95, 128), (88, 170), (54, 252), (94, 236), (58, 270), (16, 284)]
PERIMETER = [(30, 340), (62, 430), (20, 540), (1594, 150), (1594, 380), (1594, 640)]
COLORS = {
    "dark": dict(space="#080A0F", body="#B9C7D8", crest="#F2F6FC", inner="#334257",
                 star="#F2F6FC", far_star="#F2F6FC", alpha=(0.28, 0.52), tone=("#101721", "#374451")),
    "light": dict(sky="#B4C2D4", sky_max=0.70, body="#EDF3FB", crest="#FFFFFF", inner="#657284",
                  star="#FFFFFF", far_star="#4A5463", alpha=(0.44, 0.70), tone=("#E9EEF4", "#C9D3E0")),
}


def hexrgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float64) / 255.0


def to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def lin(h):
    return to_linear(hexrgb(h))


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def over(img, alpha, colour):
    """Blend `colour` (linear RGB) over img with a per-pixel alpha."""
    return img + alpha[..., None] * (colour - img)


def fields(x, y):
    """Signed distances into the outer disc and out of the inner one, for the tilted shape:
    a point in the lower half is turned back (anticlockwise) about the shoulder before
    sampling, so the drawn lower horn leans clockwise."""
    ox, oy, orad = OUTER
    ix, iy, irad = INNER
    px, py = OUTER[0] - OUTER[2] + 11.0, OUTER[1]          # the shoulder's middle
    w = smoothstep(0.0, 1.0, (y - py) / 72.5)
    a = -np.radians(TILT) * w
    dx, dy = x - px, y - py
    sx = px + dx * np.cos(a) - dy * np.sin(a)
    sy = py + dx * np.sin(a) + dy * np.cos(a)
    # Fuller through the lower third: the inner (shadow) disc gives way there, most at about
    # two thirds down, nothing at either tip.
    t = np.clip((sy - (oy - orad)) / (2 * orad), 0, 1)
    shoulder = LOWER_SHOULDER * np.sin(np.pi * t) * smoothstep(0.30, 0.72, t) * (1 - smoothstep(0.86, 1.0, t))
    return orad - np.hypot(sx - ox, sy - oy), np.hypot(sx - ix, sy - iy) - irad + shoulder


def fit():
    """The affine map from the box to the tilted shape's own bounds."""
    y, x = np.mgrid[60:300, -40:160].astype(np.float64) + 0.5
    outer, inner = fields(x, y)
    m = (outer > 0) & (inner > 0)
    ys, xs = np.nonzero(m)
    x0, x1 = x[0, xs.min()] - 0.5, x[0, xs.max()] + 0.5
    y0, y1 = y[ys.min(), 0] - 0.5, y[ys.max(), 0] + 0.5
    bx, by, bw, bh = BOX
    kx, ky = (x1 - x0) / bw, (y1 - y0) / bh
    return lambda X, Y: (x0 + (X - bx) * kx, y0 + (Y - by) * ky), min(kx, ky)


def crescent(img, c):
    y, x = np.mgrid[0:H, 0:W].astype(np.float64) + 0.5
    to_shape, k = fit()
    outer, inner = fields(*to_shape(x, y))
    outer, inner = outer / k, inner / k                   # back to output pixels
    cover = np.clip(outer + 0.5, 0, 1) * np.clip(inner + 0.5, 0, 1)
    width = np.maximum(outer + inner, 1e-3)
    # 0 on the convex shoulder (the lit crest) .. 1 at the concave cut (the shade).
    s = np.clip(np.clip(outer, 0, None) / width, 0, 1)
    body, crest, edge = lin(c["body"]), lin(c["crest"]), lin(c["inner"])
    # A bright crest on the convex shoulder, the broad silver body, the dark concave cut.
    shade = np.broadcast_to(body, (H, W, 3)).copy()
    shade = over(shade, np.exp(-(s / 0.10) ** 2), crest)
    shade = over(shade, np.exp(-((s - 0.42) / 0.16) ** 2) * 0.35, crest)     # broad reflection
    shade = over(shade, smoothstep(0.62, 1.0, s), edge)
    img = img + cover[..., None] * (shade - img)
    return img, outer, inner


def sparkle(a, cx, cy, size, peak):
    """A four-point star `size` px tip to tip: two thin tapering arms and a soft core."""
    arm = size / 2.0
    r = int(np.ceil(arm)) + 2
    yy, xx = np.mgrid[-r:r + 1, -r:r + 1].astype(np.float64)
    yy += cy - np.floor(cy) - 0.5
    xx += cx - np.floor(cx) - 0.5
    def ray(along, across):
        taper = np.clip(1 - np.abs(along) / arm, 0, 1)
        # Thin, tapering to a sharp point.
        return taper ** 2.2 * np.exp(-(across / (0.28 + 0.42 * taper)) ** 2)
    star = np.maximum(ray(xx, yy), ray(yy, xx))
    star = np.maximum(star, np.exp(-(xx ** 2 + yy ** 2) / 1.1))
    star = np.clip(star, 0, 1) * peak
    x0, y0 = int(np.floor(cx)) - r, int(np.floor(cy)) - r
    a[y0:y0 + 2 * r + 1, x0:x0 + 2 * r + 1] = np.maximum(a[y0:y0 + 2 * r + 1, x0:x0 + 2 * r + 1], star)


def point(a, x, y, alpha, two):
    a[y, x] = max(a[y, x], alpha)
    if two:
        a[y, x + 1] = max(a[y, x + 1], alpha * 0.7)
        a[y + 1, x] = max(a[y + 1, x], alpha * 0.7)
        a[y + 1, x + 1] = max(a[y + 1, x + 1], alpha * 0.45)


def tone(img, x, y, c):
    """Broad tonal variation behind the title strip and the transport, so the chrome glass
    over them has light to bend: two slow waves between the mode's pair of tones."""
    a, b = lin(c["tone"][0]), lin(c["tone"][1])
    v = 0.5 + 0.5 * np.sin(2 * np.pi * x / W * 1.35 + 0.9) * np.cos(2 * np.pi * x / W * 0.55 - 0.4)
    field = a + (b - a) * smoothstep(0.0, 1.0, v)[..., None]
    band = np.maximum(1 - smoothstep(34.0, 76.0, y), smoothstep(745.0, 805.0, y))
    return img + band[..., None] * (field - img)


def backdrop(mode):
    c = COLORS[mode]
    rng = np.random.default_rng(731)
    y, x = np.mgrid[0:H, 0:W].astype(np.float64) + 0.5
    near = np.hypot((x - 60) / 1.0, (y - 180) / 1.25)    # distance from the crescent's middle
    if mode == "dark":
        img = np.broadcast_to(lin(c["space"]), (H, W, 3)).copy()
        img = tone(img, x, y, c)
        # A faint silver halo, so the crescent sits in its own light.
        img = over(img, np.exp(-near / 70.0) * 0.07, lin(c["body"]))
    else:
        pearl, grey = lin("#E9EEF4"), lin("#BAC5D1")
        t = np.clip((x / W) * 0.55 + (y / H) * 0.45, 0, 1)[..., None]
        img = pearl + (grey - pearl) * smoothstep(0.0, 1.0, t)
        img = tone(img, x, y, c)
        # A local sky round the crescent's centre, feathered from 45 to 95 px.
        sky = np.hypot(x - (BOX[0] + BOX[2] / 2), y - (BOX[1] + BOX[3] / 2))
        img = over(img, c["sky_max"] * (1 - smoothstep(45.0, 95.0, sky)), lin(c["sky"]))
    img, outer, inner = crescent(img, c)
    band = (outer > -1) & (inner > -1)
    stars = np.zeros((H, W))
    for sx, sy, size, dark_peak, light_peak in SPARKLES:
        sparkle(stars, sx, sy, size, dark_peak if mode == "dark" else light_peak)
    lo, hi = c["alpha"]
    far = np.zeros((H, W))
    for i, (px, py) in enumerate(NEAR + PERIMETER):
        assert not band[py, px], (px, py)
        target = stars if i < len(NEAR) else far
        point(target, px, py, lo + (hi - lo) * rng.random(), i % 3 == 0)
    img = over(img, stars, lin(c["star"]))
    img = over(img, far, lin(c["far_star"]))
    rgb = (to_srgb(img) * 255 + rng.uniform(-0.5, 0.5, img.shape)).round().clip(0, 255).astype(np.uint8)
    return Image.fromarray(rgb)


def blurred(img):
    return img.filter(ImageFilter.GaussianBlur(6)).resize((BLUR_W, BLUR_H), Image.LANCZOS)


def worst_sample(soft, mode):
    """The extreme softened sample where glass labels sit: the title strip, the rail's top
    cap, and the bottom band (the rail's chevron cap, the transport, the status strip)."""
    px = np.asarray(soft.convert("RGB")).astype(int)
    k = BLUR_W / W
    mask = np.zeros(px.shape[:2], bool)
    mask[:int(34 * k) + 1, :] = True
    mask[:int(72 * k) + 1, :int(42 * k) + 1] = True
    mask[int(800 * k):, :] = True
    sel = px[mask]
    s = sel.sum(1)
    return sel[s.argmax()] if mode == "dark" else sel[s.argmin()]


def shadow():
    """96x96 white, alpha = a rounded rect (48x48, radius 16) blurred over ~18 px."""
    size, pad, radius = 96, 24, 16
    scale = 4
    big = Image.new("L", (size * scale, size * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        [pad * scale, pad * scale, (size - pad) * scale - 1, (size - pad) * scale - 1], radius * scale, fill=255)
    mask = big.resize((size, size), Image.LANCZOS).filter(ImageFilter.GaussianBlur(6))
    out = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    out.putalpha(mask)
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    for mode in ("dark", "light"):
        img = backdrop(mode)
        img.save(os.path.join(OUT, "lunar-%s.png" % mode), optimize=True)
        soft = blurred(img)
        soft.save(os.path.join(OUT, "lunar-%s-blur.png" % mode), optimize=True)
        print("lunar-%s glassSampleWorst = \"%d %d %d\"" % ((mode,) + tuple(worst_sample(soft, mode))))
    shadow().save(os.path.join(OUT, "shadow.png"), optimize=True)
    print("wrote", os.path.abspath(OUT))


if __name__ == "__main__":
    main()

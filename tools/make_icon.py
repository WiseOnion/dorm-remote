"""Dorm Remote icon: an LED strip bent into a doorway arch, a power glyph inside, light pooling on the floor.

Usage: python tools/make_icon.py DormRemote/Assets.xcassets/AppIcon.appiconset   (needs Pillow and NumPy)
"""
import math
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # supersampled, downscaled to 1024
OUT = sys.argv[1]

STOPS = [(0.0, (255, 122, 48)), (0.28, (255, 45, 120)), (0.5, (170, 60, 255)), (0.74, (61, 123, 255)), (1.0, (0, 217, 255))]


def grad(t):
    for (a, ca), (b, cb) in zip(STOPS, STOPS[1:]):
        if t <= b:
            k = (t - a) / (b - a)
            return tuple(int(ca[i] + (cb[i] - ca[i]) * k) for i in range(3))
    return STOPS[-1][1]


def arch_points(n):
    # Doorway: left leg up, half circle over the top, right leg down. Sampled evenly by length.
    cx, top, r, base = S / 2, S * 0.44, S * 0.235, S * 0.775
    leg = base - top
    total = 2 * leg + math.pi * r
    pts = []
    for i in range(n):
        d = total * i / (n - 1)
        if d <= leg:
            p = (cx - r, base - d)
        elif d <= leg + math.pi * r:
            a = math.pi - (d - leg) / r
            p = (cx + r * math.cos(a), top - r * math.sin(a))
        else:
            p = (cx + r, top + (d - leg - math.pi * r))
        pts.append((p, i / (n - 1)))
    return pts


def render(background=True, mono=False):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    if background:
        y = np.linspace(0, 1, S)[:, None]
        top, bot = np.array([22, 18, 36]), np.array([6, 6, 10])
        arr = np.zeros((S, S, 4), dtype=np.uint8)
        col = (top[None, :] * (1 - y) + bot[None, :] * y).astype(np.uint8)
        arr[:, :, :3] = col[:, None, :]
        arr[:, :, 3] = 255
        img = Image.fromarray(arr, "RGBA")

    pts = arch_points(17)
    color = (lambda t: (235, 235, 240)) if mono else grad

    # Light pooling on the floor under the doorway.
    pool = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    pd = ImageDraw.Draw(pool)
    pd.ellipse([S * 0.2, S * 0.76, S * 0.8, S * 0.88], fill=(*((200, 200, 210) if mono else (150, 80, 255)), 120))
    img.alpha_composite(pool.filter(ImageFilter.GaussianBlur(S * 0.05)))

    # The strip itself: a dark ribbon the LEDs sit on.
    strip = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(strip)
    w = int(S * 0.072)
    ribbon = (40, 38, 54, 255) if not mono else (90, 90, 96, 255)
    cx, top, r, base = S / 2, S * 0.44, S * 0.235, S * 0.775
    sd.arc([cx - r - w / 2, top - r - w / 2, cx + r + w / 2, top + r + w / 2], start=180, end=360, fill=ribbon, width=w)
    for x in (cx - r, cx + r):
        sd.rectangle([x - w / 2, top - 1, x + w / 2, base], fill=ribbon)
        sd.ellipse([x - w / 2, base - w / 2, x + w / 2, base + w / 2], fill=ribbon)

    # Glow, then the LEDs.
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for (x, y), t in pts:
        r = S * 0.045
        gd.ellipse([x - r, y - r, x + r, y + r], fill=(*color(t), 255))
    wide = glow.filter(ImageFilter.GaussianBlur(S * 0.045))
    img.alpha_composite(wide)
    img.alpha_composite(wide)
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(S * 0.016)))
    img.alpha_composite(strip)
    leds = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(leds)
    for (x, y), t in pts:
        r = S * 0.024
        c = color(t)
        ld.rounded_rectangle([x - r, y - r, x + r, y + r], radius=r * 0.45, fill=(*c, 255))
        core = tuple(int(v + (255 - v) * 0.65) for v in c)
        rc = r * 0.45
        ld.ellipse([x - rc, y - rc, x + rc, y + rc], fill=(*core, 255))
    img.alpha_composite(leds)

    # Power glyph inside the doorway: the remote.
    cx, cy, R = S / 2, S * 0.58, S * 0.092
    pw = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    pdw = ImageDraw.Draw(pw)
    lw = int(S * 0.022)
    pdw.arc([cx - R, cy - R, cx + R, cy + R], start=-60, end=240, fill=(245, 245, 250, 235), width=lw)
    pdw.line([(cx, cy - R * 1.25), (cx, cy - R * 0.15)], fill=(245, 245, 250, 235), width=lw)
    for (x, y) in [(cx, cy - R * 1.25), (cx, cy - R * 0.15)]:
        pdw.ellipse([x - lw / 2, y - lw / 2, x + lw / 2, y + lw / 2], fill=(245, 245, 250, 235))
    # Endpoints of the arc, rounded.
    for ang in (-60, 240):
        a = math.radians(ang)
        x, y = cx + (R - lw / 2) * math.cos(a), cy + (R - lw / 2) * math.sin(a)
        pdw.ellipse([x - lw / 2, y - lw / 2, x + lw / 2, y + lw / 2], fill=(245, 245, 250, 235))
    img.alpha_composite(pw.filter(ImageFilter.GaussianBlur(S * 0.012)))
    img.alpha_composite(pw)

    return img.resize((1024, 1024), Image.LANCZOS)


if __name__ == "__main__":
    render().convert("RGB").save(OUT + "/AppIcon.png")
    # Dark: same art; iOS shows dark icons on its own dark backdrop.
    render().convert("RGB").save(OUT + "/AppIcon-Dark.png")
    # Tinted: grayscale glyph on black, which iOS tints.
    t = render(background=True, mono=True).convert("L").convert("RGB")
    t.save(OUT + "/AppIcon-Tinted.png")
    print("ok")

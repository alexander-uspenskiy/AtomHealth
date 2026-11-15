"""Draw the AtomHealth Sync app icon (1024x1024, opaque) and write it into the asset catalog.

Run: .venv/bin/python tools/gen_app_icon.py
Concept: an atom (three orbits = sync) with a heart as the nucleus (= health).
"""
import json
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parent.parent / "ios/AtomHealthSync/Sources/Assets.xcassets/AppIcon.appiconset"
S = 4096          # supersampled canvas; downscaled to 1024 for clean edges
C = S / 2


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(size, c0, c1, c2=None):
    """Diagonal gradient, top-left to bottom-right."""
    n = 256
    strip = Image.new("RGB", (n, 1))
    for x in range(n):
        t = x / (n - 1)
        col = lerp(c0, c1, t * 2) if c2 and t < .5 else (lerp(c1, c2, (t - .5) * 2) if c2 else lerp(c0, c1, t))
        strip.putpixel((x, 0), col)
    big = strip.resize((n, n))
    # rotate the horizontal ramp by 45 degrees via a skew: sample along x+y
    img = Image.new("RGB", (n, n))
    px = img.load()
    for y in range(n):
        for x in range(n):
            px[x, y] = strip.getpixel((min(n - 1, (x + y) // 2), 0))
    return img.resize(size, Image.BICUBIC)


def ellipse_points(rx, ry, rot_deg, steps=1600):
    r = math.radians(rot_deg)
    pts = []
    for i in range(steps + 1):
        a = 2 * math.pi * i / steps
        x, y = rx * math.cos(a), ry * math.sin(a)
        pts.append((C + x * math.cos(r) - y * math.sin(r), C + x * math.sin(r) + y * math.cos(r)))
    return pts


def heart_points(scale, cx, cy, steps=900):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        pts.append((cx + x * scale, cy - y * scale))
    return pts


def on_ellipse(rx, ry, rot_deg, angle_deg):
    r, a = math.radians(rot_deg), math.radians(angle_deg)
    x, y = rx * math.cos(a), ry * math.sin(a)
    return C + x * math.cos(r) - y * math.sin(r), C + x * math.sin(r) + y * math.cos(r)


def main():
    # background: deep indigo -> blue -> teal, with a soft light bloom behind the nucleus
    bg = gradient((S, S), (38, 24, 110), (24, 86, 190), (18, 190, 190)).convert("RGBA")
    bloom = Image.new("L", (S, S), 0)
    ImageDraw.Draw(bloom).ellipse([C - 1100, C - 1100, C + 1100, C + 1100], fill=150)
    bloom = bloom.filter(ImageFilter.GaussianBlur(520))
    bg.paste(Image.new("RGBA", (S, S), (150, 215, 255, 255)), (0, 0), bloom.point(lambda v: v // 3))

    # orbits
    rx, ry, w = 1500, 560, 74
    orbits = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    od = ImageDraw.Draw(orbits)
    for rot in (0, 60, 120):
        # a ring = outer ellipse minus inner ellipse (smooth edges, unlike a stroked polyline)
        ring = Image.new("L", (S, S), 0)
        rd = ImageDraw.Draw(ring)
        rd.polygon(ellipse_points(rx + w / 2, ry + w / 2, rot, 4000), fill=255)
        rd.polygon(ellipse_points(rx - w / 2, ry - w / 2, rot, 4000), fill=0)
        orbits.paste((255, 255, 255, 235), (0, 0), ring)
    glow = orbits.filter(ImageFilter.GaussianBlur(46))
    bg = Image.alpha_composite(bg, glow)
    bg = Image.alpha_composite(bg, orbits)

    # electrons (one per orbit), with a soft halo
    dots = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dots)
    for rot, ang in ((0, 28), (60, 205), (120, 318)):
        x, y = on_ellipse(rx, ry, rot, ang)
        dd.ellipse([x - 120, y - 120, x + 120, y + 120], fill=(255, 255, 255, 255))
    bg = Image.alpha_composite(bg, dots.filter(ImageFilter.GaussianBlur(40)))
    bg = Image.alpha_composite(bg, dots)

    # nucleus: heart with warm gradient, soft shadow and a glossy highlight
    cy = C + 40
    heart = heart_points(66, C, cy)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(heart, fill=255)
    shadow = Image.new("RGBA", (S, S), (10, 10, 60, 0))
    shadow.putalpha(mask.filter(ImageFilter.GaussianBlur(70)).point(lambda v: int(v * .55)))
    shadow = ImageChops.offset(shadow, 0, 70)
    bg = Image.alpha_composite(bg, shadow)
    fill = gradient((S, S), (255, 120, 120), (255, 70, 110), (230, 30, 100))
    bg.paste(fill.convert("RGBA"), (0, 0), mask)

    hi = Image.new("L", (S, S), 0)
    ImageDraw.Draw(hi).ellipse([C - 560, cy - 640, C - 40, cy - 250], fill=120)
    hi = ImageChops.multiply(hi.filter(ImageFilter.GaussianBlur(70)), mask)
    bg.paste(Image.new("RGBA", (S, S), (255, 255, 255, 255)), (0, 0), hi)

    # heartbeat line crossing the heart
    pulse = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    y0 = cy + 30
    path = [(C - 560, y0), (C - 250, y0), (C - 140, y0 - 230), (C + 10, y0 + 260), (C + 140, y0 - 120),
            (C + 220, y0), (C + 560, y0)]
    ImageDraw.Draw(pulse).line(path, fill=(255, 255, 255, 255), width=64, joint="curve")
    for x, y in (path[0], path[-1]):
        ImageDraw.Draw(pulse).ellipse([x - 32, y - 32, x + 32, y + 32], fill=(255, 255, 255, 255))
    bg = Image.alpha_composite(bg, pulse)

    icon = bg.convert("RGB").resize((1024, 1024), Image.LANCZOS)   # opaque, as App Store requires
    OUT.mkdir(parents=True, exist_ok=True)
    icon.save(OUT / "icon-1024.png", optimize=True)
    (OUT / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (OUT.parent / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print("wrote", OUT / "icon-1024.png")


if __name__ == "__main__":
    main()

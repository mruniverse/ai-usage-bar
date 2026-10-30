#!/usr/bin/env python3
"""Generate the AI Usage Bar macOS app icon and iconset."""
from pathlib import Path
import math
from PIL import Image, ImageDraw, ImageFilter

root = Path(__file__).resolve().parents[1]
out = root / "Resources" / "AppIcon.iconset"
out.mkdir(parents=True, exist_ok=True)
S = 1024
# Rounded-square macOS icon, indigo night field with a glowing usage chart.
base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
p = base.load()
for y in range(S):
    for x in range(S):
        nx, ny = x / S, y / S
        p[x, y] = (int(17 + 32 * ny), int(28 + 10 * nx), int(72 + 95 * (1 - ny)), 255)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle((28, 28, 996, 996), radius=220, fill=255)
base.putalpha(mask)
# Subtle background radial glow.
glow = Image.new("RGBA", (S, S), (0,0,0,0))
gd = ImageDraw.Draw(glow)
gd.ellipse((115, 90, 900, 870), fill=(63, 115, 255, 52))
glow = glow.filter(ImageFilter.GaussianBlur(110))
base = Image.alpha_composite(base, glow)
# Glass-like panel.
panel = Image.new("RGBA", (S, S), (0,0,0,0))
d = ImageDraw.Draw(panel)
d.rounded_rectangle((160, 170, 864, 850), radius=125, fill=(245, 248, 255, 22), outline=(230, 240, 255, 105), width=10)
base = Image.alpha_composite(base, panel)
# Three rising bars with cyan-to-violet glow.
chart = Image.new("RGBA", (S, S), (0,0,0,0))
d = ImageDraw.Draw(chart)
colors = [(59, 225, 245, 255), (99, 190, 255, 255), (174, 132, 255, 255)]
rects = [(270, 570, 405, 750), (445, 430, 580, 750), (620, 280, 755, 750)]
for box, color in zip(rects, colors):
    d.rounded_rectangle(box, radius=46, fill=color)
blur = chart.filter(ImageFilter.GaussianBlur(42))
base = Image.alpha_composite(base, blur)
base = Image.alpha_composite(base, chart)
# Tiny glint accent.
d = ImageDraw.Draw(base)
d.arc((237, 224, 788, 775), start=205, end=330, fill=(255,255,255,140), width=9)

sizes = {
    "icon_16x16.png":16, "icon_16x16@2x.png":32,
    "icon_32x32.png":32, "icon_32x32@2x.png":64,
    "icon_128x128.png":128, "icon_128x128@2x.png":256,
    "icon_256x256.png":256, "icon_256x256@2x.png":512,
    "icon_512x512.png":512, "icon_512x512@2x.png":1024,
}
for name, size in sizes.items():
    base.resize((size,size), Image.Resampling.LANCZOS).save(out/name)

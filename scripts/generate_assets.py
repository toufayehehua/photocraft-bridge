#!/usr/bin/env python3
"""Render the project's own vector-style store artwork with Pillow."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets"
OUT.mkdir(exist_ok=True)


def font(size, bold=False):
    names = (["/System/Library/Fonts/Supplemental/Arial Bold.ttf", "DejaVuSans-Bold.ttf"] if bold
             else ["/System/Library/Fonts/Supplemental/Arial.ttf", "DejaVuSans.ttf"])
    for name in names:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default()


def icon(size):
    scale = 4
    canvas = Image.new("RGBA", (size * scale, size * scale))
    d = ImageDraw.Draw(canvas)
    def rect(box, radius, fill, outline=None, width=1):
        d.rounded_rectangle(tuple(int(x * size * scale) for x in box), radius=int(radius * size * scale),
                            fill=fill, outline=outline, width=max(1, int(width * size * scale)))
    rect((0, 0, 1, 1), .23, "#6558ef")
    rect((.16, .22, .65, .67), .06, "#b8adff")
    rect((.35, .36, .84, .81), .06, "#ffffff")
    d.line([(int(x * size * scale), int(y * size * scale)) for x, y in
            [(.44, .62), (.53, .53), (.64, .64), (.74, .53)]], fill="#6558ef", width=int(.035 * size * scale), joint="curve")
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


icon(128).save(OUT / "icon-128.png")
icon(512).save(OUT / "icon-512.png")
cover = Image.new("RGB", (1920, 1080), "#111528")
d = ImageDraw.Draw(cover)
d.rounded_rectangle((1120, 92, 1808, 988), 60, fill="#1c2240")
cover.paste(icon(168), (120, 125), icon(168))
d.text((120, 345), "PhotoCraft", fill="white", font=font(112, True))
d.text((120, 465), "Bridge", fill="white", font=font(112, True))
d.text((124, 655), "Edit images in PhotoCraft", fill="#bbbfe4", font=font(45))
d.text((124, 735), "Figma + Adobe XD", fill="#bbbfe4", font=font(39))
d.rounded_rectangle((124, 876, 660, 948), 36, fill="#6558ef")
d.text((157, 891), "Free + open source", fill="white", font=font(34, True))
for top, title, caption in [(174, "Select", "Image fill"), (444, "Edit", "PhotoCraft PSD"), (714, "Save", "Automatic sync")]:
    d.rounded_rectangle((1190, top, 1738, top + 180), 28, fill="#2b3358")
    d.text((1230, top + 25), title, fill="white", font=font(48, True))
    d.text((1230, top + 100), caption, fill="#c9ccec", font=font(31))
for y in [382, 652]:
    d.line([(1464, y - 16), (1464, y + 11)], fill="#a197ff", width=6)
    d.polygon([(1450, y + 4), (1464, y + 18), (1478, y + 4)], fill="#a197ff")
cover.save(OUT / "cover-1920x1080.png")
d.rectangle((120, 725, 1050, 810), fill="#111528")
d.text((124, 735), "Figma Design + PhotoCraft", fill="#bbbfe4", font=font(39))
cover.save(OUT / "cover-figma-1920x1080.png")
print(OUT)

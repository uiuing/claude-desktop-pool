#!/usr/bin/env python3
"""Compose docs/images/banner.png from the demo renders.

Run `zsh scripts/screenshots.sh ScreenshotTests.testRenderBannerScreens` and `zsh scripts/build.sh`
first: this reads the banner renders in .build/screenshots and the app icon in dist/. Needs Pillow and
the macOS system font.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SHOTS = ROOT / ".build" / "screenshots"
ICON = ROOT / "dist" / "Claude Pool.app" / "Contents" / "Resources" / "AppIcon.icns"
OUT = ROOT / "docs" / "images" / "banner.png"
SIZE = (1600, 800)
FONT = "/System/Library/Fonts/SFNS.ttf"

TITLE = "Claude Pool"
TAGLINE = ["Every conversation, subagent and task", "goes to the account best placed for it."]
CHIPS = ["Smart routing", "Prompt cache kept", "Privacy protected"]
CLOCK = "Thu 14:00"
INK = (52, 32, 24)
ACCENT_INK = (150, 72, 40)


def font(size, weight):
    face = ImageFont.truetype(FONT, size)
    face.set_variation_by_name(weight)
    return face


def background():
    # Warm light from the top left to the bottom right, as the app's own palette.
    corners = {"tl": (250, 236, 225), "tr": (244, 221, 207), "bl": (236, 203, 180), "br": (229, 189, 163)}
    small = Image.new("RGB", (2, 2))
    small.putpixel((0, 0), corners["tl"]); small.putpixel((1, 0), corners["tr"])
    small.putpixel((0, 1), corners["bl"]); small.putpixel((1, 1), corners["br"])
    return small.resize(SIZE, Image.BILINEAR).convert("RGBA")


def rounded(image, radius):
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, image.size[0] - 1, image.size[1] - 1), radius, fill=255)
    out = image.convert("RGBA")
    out.putalpha(Image.composite(out.getchannel("A"), mask, mask))
    return out


def shadow(canvas, box, radius, blur, offset, alpha):
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    x0, y0, x1, y1 = box
    ImageDraw.Draw(layer).rounded_rectangle((x0, y0 + offset, x1, y1 + offset), radius, fill=(90, 45, 20, alpha))
    canvas.alpha_composite(layer.filter(ImageFilter.GaussianBlur(blur)))


def place(canvas, image, at, radius):
    x, y = at
    box = (x, y, x + image.size[0], y + image.size[1])
    shadow(canvas, box, radius, 28, 18, 70)
    canvas.alpha_composite(rounded(image, radius), (x, y))
    ImageDraw.Draw(canvas).rounded_rectangle(box, radius, outline=(120, 80, 60, 40), width=1)


def icon():
    with tempfile.TemporaryDirectory() as folder:
        png = Path(folder) / "icon.png"
        subprocess.run(["sips", "-s", "format", "png", "-Z", "512", str(ICON), "--out", str(png)], check=True, capture_output=True)
        return Image.open(png).convert("RGBA").resize((128, 128), Image.LANCZOS)


def main():
    for name in ("banner-routing-en-light.png", "banner-menu-en-light.png", "banner-status-en-light.png"):
        if not (SHOTS / name).exists():
            sys.exit(f"missing {SHOTS / name}: render the banner screens first")
    canvas = background()
    draw = ImageDraw.Draw(canvas)

    # The menu bar, with the pool's item and the clock.
    bar = Image.new("RGBA", (SIZE[0], 38), (255, 255, 255, 120))
    canvas.alpha_composite(bar, (0, 0))
    status = Image.open(SHOTS / "banner-status-en-light.png").convert("RGBA")
    status = status.resize((status.size[0] * 30 // status.size[1], 30), Image.LANCZOS)
    clock = font(19, "Semibold")
    clock_width = draw.textlength(CLOCK, font=clock)
    clock_x = SIZE[0] - 28 - clock_width
    status_x = int(clock_x - 26 - status.size[0])
    highlight = Image.new("RGBA", (status.size[0] + 16, 32), (0, 0, 0, 0))
    ImageDraw.Draw(highlight).rounded_rectangle((0, 0, highlight.size[0] - 1, 31), 7, fill=(0, 0, 0, 26))
    canvas.alpha_composite(highlight, (status_x - 8, 3))
    canvas.alpha_composite(status, (status_x, 4))
    draw.text((clock_x, 19), CLOCK, font=clock, fill=(30, 20, 15), anchor="lm")

    # The window: the Routing page, each conversation and subagent on its account.
    window = Image.open(SHOTS / "banner-routing-en-light.png").convert("RGBA")
    window = window.crop((0, 0, window.size[0], 1290))
    window = window.resize((590, round(1290 * 590 / window.size[0])), Image.LANCZOS)
    place(canvas, window, (640, 150), 18)

    # The menu bar panel, opened from the item above it.
    panel = Image.open(SHOTS / "banner-menu-en-light.png").convert("RGBA")
    panel = panel.resize((320, round(panel.size[1] * 320 / panel.size[0])), Image.LANCZOS)
    place(canvas, panel, (1252, 48), 16)

    # The words on the left.
    mark = icon()
    glow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle((96, 226, 96 + 116, 226 + 116), 28, fill=(120, 50, 20, 90))
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(16)))
    canvas.alpha_composite(mark, (90, 206))
    draw = ImageDraw.Draw(canvas)
    draw.text((86, 362), TITLE, font=font(88, "Bold"), fill=INK)
    tagline = font(29, "Medium")
    for index, line in enumerate(TAGLINE):
        draw.text((90, 490 + index * 40), line, font=tagline, fill=(70, 44, 32))
    chip, x = font(17, "Semibold"), 90
    for text in CHIPS:
        width = draw.textlength(text, font=chip)
        draw.rounded_rectangle((x, 604, x + width + 32, 642), 19, fill=(255, 247, 241, 225), outline=(214, 170, 146), width=1)
        draw.text((x + 16, 623), text, font=chip, fill=ACCENT_INK, anchor="lm")
        x += width + 44
    canvas.convert("RGB").save(OUT, optimize=True)
    print(f"Banner: {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()

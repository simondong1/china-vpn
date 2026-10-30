#!/usr/bin/env python3
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "XrayVPN" / "Assets.xcassets" / "AppIcon.appiconset"
SIZE = 1024
SIZES = (16, 32, 64, 128, 256, 512, 1024)


def find_font():
    candidates = [os.environ.get("DONGVPN_ICON_FONT", "")]
    if os.name == "nt":
        candidates.extend((r"C:\Windows\Fonts\msyhbd.ttc", r"C:\Windows\Fonts\simhei.ttf"))
    else:
        candidates.extend((
            "/System/Library/Fonts/PingFang.ttc",
            "/System/Library/Fonts/STHeiti Medium.ttc",
            "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
            "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
        ))
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    raise SystemExit("Set DONGVPN_ICON_FONT to a bold font that includes the 董 character.")


def find_latin_font():
    candidates = [os.environ.get("DONGVPN_LATIN_FONT", "")]
    if os.name == "nt":
        candidates.append(r"C:\Windows\Fonts\arialbd.ttf")
    else:
        candidates.extend((
            "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
            "/Library/Fonts/Arial Bold.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        ))
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    raise SystemExit("Set DONGVPN_LATIN_FONT to a bold font that includes Latin characters.")


def render():
    image = Image.new("RGBA", (SIZE, SIZE))
    pixels = image.load()
    top = (16, 119, 108)
    bottom = (7, 47, 57)
    for y in range(SIZE):
        amount = y / (SIZE - 1)
        color = tuple(round(a + (b - a) * amount) for a, b in zip(top, bottom))
        for x in range(SIZE):
            pixels[x, y] = (*color, 255)

    mask = Image.new("L", (SIZE, SIZE))
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=226, fill=255)
    image.putalpha(mask)
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((31, 31, SIZE - 32, SIZE - 32), radius=202, outline=(178, 236, 209, 105), width=4)
    draw.line(((171, 286), (171, 229), (244, 229), (273, 258)), fill=(210, 244, 120, 255), width=15, joint="curve")
    draw.ellipse((148, 264, 194, 310), fill=(210, 244, 120, 255))
    draw.line(((788, 232), (848, 232), (848, 292)), fill=(250, 135, 101, 255), width=15, joint="curve")
    draw.ellipse((825, 269, 871, 315), fill=(250, 135, 101, 255))

    chinese = ImageFont.truetype(find_font(), 480, index=0)
    draw.text((SIZE // 2, 499), "董", font=chinese, fill=(248, 251, 241, 255), anchor="mm", stroke_width=1)
    draw.rounded_rectangle((311, 791, 713, 923), radius=66, fill=(211, 243, 118, 255))

    latin = ImageFont.truetype(find_latin_font(), 78)
    draw.text((SIZE // 2, 855), "VPN", font=latin, fill=(12, 55, 54, 255), anchor="mm")
    return image


def main():
    ICONSET.mkdir(parents=True, exist_ok=True)
    master = render()
    for size in SIZES:
        filename = "AppIcon-1024.png" if size == 1024 else f"AppIcon-{size}.png"
        master.resize((size, size), Image.Resampling.LANCZOS).save(ICONSET / filename, optimize=True)


if __name__ == "__main__":
    main()

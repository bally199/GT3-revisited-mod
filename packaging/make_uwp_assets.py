#!/usr/bin/env python3
"""Writes the UWP (Xbox) package images from packaging/icon.png into packaging/uwp/Assets.

The tiles are the app icon on the icon's own dark background; the wide tile and the splash
screen centre it. Needs Pillow:  python3 packaging/make_uwp_assets.py
"""
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "uwp", "Assets")
BACKGROUND = (22, 25, 38, 255)  # the icon's own dark blue (manifest BackgroundColor #161926)

# name: (width, height, icon height as a fraction of the image height)
IMAGES = {
    "Square44x44Logo.png": (44, 44, 1.0),
    "Square44x44Logo.targetsize-24_altform-unplated.png": (24, 24, 1.0),
    "Square150x150Logo.png": (150, 150, 0.8),
    "Wide310x150Logo.png": (310, 150, 0.8),
    "StoreLogo.png": (50, 50, 1.0),
    "SplashScreen.png": (620, 300, 0.6),
}


def main():
    icon = Image.open(os.path.join(HERE, "icon.png")).convert("RGBA")
    os.makedirs(OUT, exist_ok=True)
    for name, (w, h, frac) in IMAGES.items():
        img = Image.new("RGBA", (w, h), BACKGROUND)
        side = max(1, int(round(h * frac)))
        scaled = icon.resize((side, side), Image.LANCZOS)
        img.alpha_composite(scaled, ((w - side) // 2, (h - side) // 2))
        img.save(os.path.join(OUT, name))
        print("wrote", name)


if __name__ == "__main__":
    main()

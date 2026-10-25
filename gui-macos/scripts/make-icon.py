#!/usr/bin/env python3
"""Regenerate Resources/EmLoad.icns from Resources/E.png.

Run this after changing E.png:

    ../.venv/bin/python scripts/make-icon.py

The source art is a full-bleed rounded tile, so it is scaled to Apple's icon
grid (824 of a 1024 canvas, centred) to line up with other macOS icons in the
Dock and Finder. Requires Pillow; the generated .icns is committed, so a normal
build never needs this script.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # pragma: no cover - developer convenience only
    sys.exit("Pillow is required: ../.venv/bin/pip install pillow")

HERE = Path(__file__).resolve().parent.parent
RESOURCES = HERE / "Resources"
SOURCE = RESOURCES / "E.png"
ICONSET = RESOURCES / "EmLoad.iconset"
ICNS = RESOURCES / "EmLoad.icns"

MASTER = 1024  # Apple's icon canvas
ART = 824      # the rounded tile inside that canvas

SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def main() -> None:
    if not SOURCE.exists():
        sys.exit(f"missing source image: {SOURCE}")

    source = Image.open(SOURCE).convert("RGBA")
    art = source.resize((ART, ART), Image.LANCZOS)

    master = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    offset = (MASTER - ART) // 2
    master.paste(art, (offset, offset), art)

    if ICONSET.exists():
        shutil.rmtree(ICONSET)
    ICONSET.mkdir(parents=True)
    for name, pixels in SIZES.items():
        master.resize((pixels, pixels), Image.LANCZOS).save(ICONSET / name)

    subprocess.run(
        ["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)],
        check=True,
    )
    shutil.rmtree(ICONSET)
    print(f"wrote {ICNS.relative_to(HERE)}")


if __name__ == "__main__":
    main()

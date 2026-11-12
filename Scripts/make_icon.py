#!/usr/bin/env python3
"""Builds Resources/Ledge.icon/Assets/icon.png from Resources/AppIcon-source.png.

macOS 26 draws app icons inside its own rounded shape, so the layer must be a full-bleed square.
This crops the artwork, drops the old rounded edge, and extends the background gradient to every
corner. bundle.sh then compiles Resources/Ledge.icon with actool (Xcode 26 or later).
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

root = Path(__file__).resolve().parent.parent
src = Image.open(root / "Resources" / "AppIcon-source.png").convert("RGBA")

alpha = np.array(src)[:, :, 3]
cols = np.where((alpha > 200).sum(axis=0) > 150)[0]
rows = np.where((alpha > 200).sum(axis=1) > 150)[0]
art = src.crop((cols[0], rows[0], cols[-1] + 1, rows[-1] + 1)).resize((1024, 1024), Image.LANCZOS)
arr = np.array(art).astype(float)

# Background gradient: per-row colour sampled from a clean strip near the left edge.
solid = np.where(arr[:, 40:90, 3].mean(axis=1) > 250)[0]
strip = arr[:, 100:140, :3].mean(axis=1)
bg = np.empty((1024, 3))
for c in range(3):
    bg[:, c] = np.interp(np.arange(1024), solid, strip[solid, c])
background = np.repeat(bg[:, None, :], 1024, axis=1)

# Keep only the interior of the artwork and fade into the clean gradient near the old edge.
inner = art.getchannel("A").point(lambda v: 255 if v > 250 else 0)
inner = inner.filter(ImageFilter.MinFilter(91)).filter(ImageFilter.GaussianBlur(14))
m = np.array(inner).astype(float)[:, :, None] / 255
out = arr[:, :, :3] * m + background * (1 - m)

target = root / "Resources" / "Ledge.icon" / "Assets" / "icon.png"
Image.fromarray(out.astype("uint8")).save(target)
print("wrote", target)

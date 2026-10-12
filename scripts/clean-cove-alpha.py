#!/usr/bin/env python3
"""User-authorized alpha-only cleanup of the two generated Cove rig layers."""
from pathlib import Path
import shutil

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Sources/SneakPeek/Resources/Otter/Cove"
ORIGINALS = ROOT / "output/cove-animation-assets/originals"


def clean(name):
    path = ASSETS / f"{name}.png"
    backup = ORIGINALS / path.name
    ORIGINALS.mkdir(parents=True, exist_ok=True)
    if not backup.exists():
        shutil.copy2(path, backup)
    original = np.asarray(Image.open(backup).convert("RGBA"))
    rgba = original.copy()
    alpha = rgba[:, :, 3].astype(float)
    # The generated foreground is nearly opaque; the diffuse halo has low alpha.
    # Retain a two-pixel antialiased edge and bright fine whiskers independently.
    solid = Image.fromarray(np.where(alpha >= 225, 255, 0).astype(np.uint8))
    near_foreground = np.asarray(solid.filter(ImageFilter.MaxFilter(5))) > 0
    bright_whisker = (rgba[:, :, :3].astype(float).mean(axis=2) >= 150) & (alpha >= 15)
    keep = near_foreground | bright_whisker
    cleaned = np.where(keep, np.clip((alpha - 15) * 255 / 210, 0, 255), 0)
    cleaned = np.where(bright_whisker & ~near_foreground, np.minimum(alpha * 255 / 253, 255), cleaned)
    rgba[:, :, 3] = np.rint(cleaned).astype(np.uint8)
    assert np.array_equal(rgba[:, :, :3], original[:, :, :3])
    Image.fromarray(rgba).save(path)
    print(f"{name}: RGB and canvas preserved; diffuse alpha removed")


if __name__ == "__main__":
    for name in ("attention-arm", "raft"):
        clean(name)

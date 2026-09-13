#!/usr/bin/env python3
"""Generate the original CloudDesk-RDP wallpaper.

Produces a calm, macOS-inspired abstract gradient: deep indigo base with
soft aurora-like light blobs and a gentle vignette. Deterministic (seeded)
so re-runs produce the identical asset. Output: assets/wallpaper.png.

Usage:
    python3 assets/src/generate_wallpaper.py [output.png] [width] [height]
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SEED = 20260913

# Vertical base gradient stops (top -> bottom), deep indigo night tones.
GRADIENT_STOPS = [
    (28, 34, 74),     # indigo night
    (24, 28, 62),     # deep indigo
    (20, 22, 52),     # midnight blue
    (14, 15, 38),     # near-black blue
]

# Aurora blobs: (cx, cy, radius, rgba, blur)
BLOBS = [
    (0.78, 0.18, 0.55, (86, 130, 220, 70)),   # cool blue glow, upper right
    (0.18, 0.80, 0.60, (72, 118, 205, 60)),   # blue glow, lower left
    (0.55, 0.62, 0.40, (120, 92, 200, 46)),   # violet whisper, center-low
    (0.30, 0.30, 0.35, (60, 160, 175, 34)),   # faint teal, upper left
]


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def build_gradient(w, h):
    """Smooth vertical gradient through GRADIENT_STOPS."""
    img = Image.new("RGB", (w, h))
    px = img.load()
    seg = len(GRADIENT_STOPS) - 1
    for y in range(h):
        pos = y / (h - 1) * seg
        idx = min(int(pos), seg - 1)
        color = lerp(GRADIENT_STOPS[idx], GRADIENT_STOPS[idx + 1], pos - idx)
        for x in range(w):
            px[x, y] = color
    return img


def add_blobs(img, w, h):
    """Soft, heavily blurred light blobs (drawn at 1/8 scale, then upsampled)."""
    sw, sh = max(w // 8, 1), max(h // 8, 1)
    layer = Image.new("RGBA", (sw, sh), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for cx, cy, rad, rgba in BLOBS:
        r = int(rad * min(sw, sh) * 0.5 + min(sw, sh) * 0.2)
        x, y = int(cx * sw), int(cy * sh)
        d.ellipse([x - r, y - r, x + r, y + r], fill=rgba)
    layer = layer.filter(ImageFilter.GaussianBlur(min(sw, sh) // 6))
    layer = layer.resize((w, h), Image.LANCZOS)
    return Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")


def add_vignette(img, w, h):
    """Very subtle dark vignette to focus the center."""
    sw, sh = max(w // 8, 1), max(h // 8, 1)
    mask = Image.new("L", (sw, sh), 0)
    d = ImageDraw.Draw(mask)
    d.ellipse([-sw * 0.25, -sh * 0.35, sw * 1.25, sh * 1.35], fill=46)
    mask = mask.filter(ImageFilter.GaussianBlur(min(sw, sh) // 5))
    mask = mask.resize((w, h), Image.LANCZOS)
    black = Image.new("RGB", (w, h), (5, 6, 14))
    return Image.composite(black, img, mask)


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "wallpaper.png"
    w = int(sys.argv[2]) if len(sys.argv) > 2 else 1920
    h = int(sys.argv[3]) if len(sys.argv) > 3 else 1080

    img = build_gradient(w, h)
    img = add_blobs(img, w, h)
    img = add_vignette(img, w, h)
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, "PNG", optimize=True)
    print(f"wallpaper written: {out} ({out.stat().st_size / 1024:.0f} KB, {w}x{h})")


if __name__ == "__main__":
    main()

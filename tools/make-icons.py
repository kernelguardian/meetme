#!/usr/bin/env python3
"""Generate MeetMe extension icons.

Draws at 8x and downsamples with LANCZOS so the 16px toolbar icon stays crisp.
Run from the repo root: python3 tools/make-icons.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "extension" / "icons"
SS = 8

TILE_TOP = (35, 43, 61)
TILE_BOTTOM = (15, 17, 21)
RIM = (86, 96, 120, 255)
MIC = (240, 243, 248, 255)
DOT_IDLE = (124, 132, 146, 255)
DOT_REC = (229, 72, 77, 255)

SIZES = (16, 32, 48, 128)
REC_SIZES = (16, 32, 48)


def gradient(n):
    strip = Image.new("RGB", (1, n))
    for y in range(n):
        t = y / max(1, n - 1)
        strip.putpixel(
            (0, y),
            tuple(round(a + (b - a) * t) for a, b in zip(TILE_TOP, TILE_BOTTOM)),
        )
    return strip.resize((n, n), Image.BILINEAR)


def draw_icon(size, dot_color):
    # At 16px the stem and base bar blur into the cradle, so that grid gets a
    # heavier, detail-free glyph instead.
    compact = size <= 16
    n = size * SS
    radius = n * 0.225

    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, n - 1, n - 1], radius=radius, fill=255)
    img = gradient(n).convert("RGBA")
    img.putalpha(mask)
    d = ImageDraw.Draw(img)

    d.rounded_rectangle(
        [0, 0, n - 1, n - 1],
        radius=radius,
        outline=RIM,
        width=max(1, round(n * (0.010 if compact else 0.014))),
    )

    # Nudged off-centre so the record dot owns the bottom-right corner.
    cx = n * (0.43 if compact else 0.455)
    stroke = round(n * (0.105 if compact else 0.068))

    if compact:
        capsule_w, capsule_h, capsule_top = n * 0.24, n * 0.30, n * 0.145
        cradle_w, cradle_arms_at = n * 0.46, n * 0.58
    else:
        capsule_w, capsule_h, capsule_top = n * 0.215, n * 0.35, n * 0.155
        cradle_w, cradle_arms_at = n * 0.40, capsule_top + capsule_h * 0.46 + n * 0.20

    d.rounded_rectangle(
        [cx - capsule_w / 2, capsule_top, cx + capsule_w / 2, capsule_top + capsule_h],
        radius=capsule_w / 2,
        fill=MIC,
    )

    # Bottom half of a circle: the cradle the mic capsule sits in. `arc` draws the
    # lower semicircle, so its arm tips sit at the box's vertical midpoint — position
    # from there to keep a visible gap below the capsule at 16px.
    cradle_top = cradle_arms_at - cradle_w / 2
    cradle = [cx - cradle_w / 2, cradle_top, cx + cradle_w / 2, cradle_top + cradle_w]
    d.arc(cradle, start=0, end=180, fill=MIC, width=stroke)

    if not compact:
        stem_bottom = n * 0.80
        d.line([(cx, cradle[3] - stroke / 2), (cx, stem_bottom)], fill=MIC, width=stroke)
        base_w = n * 0.23
        d.rounded_rectangle(
            [
                cx - base_w / 2,
                stem_bottom - stroke / 2,
                cx + base_w / 2,
                stem_bottom + stroke / 2,
            ],
            radius=stroke / 2,
            fill=MIC,
        )

    if compact:
        dx, dy, dr = n * 0.775, n * 0.765, n * 0.165
        ring = round(n * 0.055)
    else:
        dx, dy, dr = n * 0.785, n * 0.775, n * 0.13
        ring = round(n * 0.045)
    d.ellipse(
        [dx - dr - ring, dy - dr - ring, dx + dr + ring, dy + dr + ring],
        fill=TILE_BOTTOM + (255,),
    )
    d.ellipse([dx - dr, dy - dr, dx + dr, dy + dr], fill=dot_color)

    return img.resize((size, size), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    written = []
    for size in SIZES:
        path = OUT / f"icon-{size}.png"
        draw_icon(size, DOT_IDLE).save(path)
        written.append(path)
    for size in REC_SIZES:
        path = OUT / f"icon-rec-{size}.png"
        draw_icon(size, DOT_REC).save(path)
        written.append(path)
    for path in written:
        print(f"{path.relative_to(OUT.parent.parent)}  {Image.open(path).size[0]}px")


if __name__ == "__main__":
    main()

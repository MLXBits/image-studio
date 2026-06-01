#!/usr/bin/env python3
"""Generate MLXBits Image Studio app icon: hexagonal network + camera lens aperture."""

import json
import math
import os
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

# ── Constants ─────────────────────────────────────────────────────────────────

ASSET_DIR = Path(__file__).parent / "Assets.xcassets" / "AppIcon.appiconset"

SIZES = {
    "AppIcon-16.png":   16,
    "AppIcon-32.png":   32,
    "AppIcon-64.png":   64,
    "AppIcon-128.png":  128,
    "AppIcon-256.png":  256,
    "AppIcon-512.png":  512,
    "AppIcon-1024.png": 1024,
}

CONTENTS = {
    "images": [
        {"filename": "AppIcon-16.png",   "idiom": "mac", "scale": "1x", "size": "16x16"},
        {"filename": "AppIcon-32.png",   "idiom": "mac", "scale": "2x", "size": "16x16"},
        {"filename": "AppIcon-32.png",   "idiom": "mac", "scale": "1x", "size": "32x32"},
        {"filename": "AppIcon-64.png",   "idiom": "mac", "scale": "2x", "size": "32x32"},
        {"filename": "AppIcon-128.png",  "idiom": "mac", "scale": "1x", "size": "128x128"},
        {"filename": "AppIcon-256.png",  "idiom": "mac", "scale": "2x", "size": "128x128"},
        {"filename": "AppIcon-256.png",  "idiom": "mac", "scale": "1x", "size": "256x256"},
        {"filename": "AppIcon-512.png",  "idiom": "mac", "scale": "2x", "size": "256x256"},
        {"filename": "AppIcon-512.png",  "idiom": "mac", "scale": "1x", "size": "512x512"},
        {"filename": "AppIcon-1024.png", "idiom": "mac", "scale": "2x", "size": "512x512"},
    ],
    "info": {"author": "xcode", "version": 1},
}

# ── Helpers ────────────────────────────────────────────────────────────────────

def squircle_pts(cx, cy, r, n=4.8, steps=512):
    pts = []
    for i in range(steps):
        a = 2 * math.pi * i / steps
        ca, sa = math.cos(a), math.sin(a)
        exp = 2.0 / n
        x = cx + r * math.copysign(abs(ca) ** exp, ca)
        y = cy + r * math.copysign(abs(sa) ** exp, sa)
        pts.append((x, y))
    return pts


def hex_pts(cx, cy, r):
    return [
        (cx + r * math.cos(math.pi / 3 * i), cy + r * math.sin(math.pi / 3 * i))
        for i in range(6)
    ]


def radial_alpha(dist, inner=0.22, ramp=0.30, peak=100):
    """Opacity for hex grid cell at normalised distance from centre."""
    if dist < inner:
        return 0
    if dist < inner + ramp:
        t = (dist - inner) / ramp
        return int(t * t * peak)
    t = min(1.0, (dist - inner - ramp) / 0.35)
    return int(peak + t * 40)


# ── Render ─────────────────────────────────────────────────────────────────────

def create_icon(size: int) -> Image.Image:
    SCALE = 4
    S = size * SCALE
    cx = cy = S / 2

    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # ── 1. Background ──────────────────────────────────────────────────────────
    bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bg_draw = ImageDraw.Draw(bg)

    # Radial gradient: dark navy at centre, slightly lighter edge
    max_r = S * 0.707
    for ring in range(int(max_r), 0, -2):
        t = ring / max_r
        r_val = int(8  + t * 10)
        g_val = int(10 + t * 12)
        b_val = int(24 + t * 18)
        bg_draw.ellipse([cx - ring, cy - ring, cx + ring, cy + ring],
                        fill=(r_val, g_val, b_val, 255))

    # Apply squircle mask
    sq_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sq_mask).polygon(squircle_pts(cx, cy, S * 0.49), fill=255)
    bg.putalpha(sq_mask)
    canvas = Image.alpha_composite(canvas, bg)

    # ── 2. Hex grid ────────────────────────────────────────────────────────────
    hex_r = S * 0.057          # circumradius of each cell
    col_dx = hex_r * 1.5       # flat-top: horizontal pitch
    row_dy = hex_r * math.sqrt(3)

    hex_lay = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    hex_draw = ImageDraw.Draw(hex_lay)

    n_cols = int(S / col_dx) + 5
    n_rows = int(S / row_dy) + 5

    for col in range(-2, n_cols):
        for row in range(-2, n_rows):
            hx = col * col_dx
            hy = row * row_dy + (col % 2) * row_dy / 2
            dist = math.hypot(hx - cx, hy - cy) / (S * 0.5)
            alpha = radial_alpha(dist)
            if alpha < 2:
                continue
            alpha = min(130, alpha)
            pts = hex_pts(hx, hy, hex_r * 0.87)
            hex_draw.polygon(pts, outline=(0, 200, 235, alpha), fill=None)

    # Mask hex layer to squircle too
    hex_lay.putalpha(
        Image.fromarray(
            __import__("numpy").minimum(
                __import__("numpy").array(hex_lay.split()[3]),
                __import__("numpy").array(sq_mask),
            ).astype("uint8")
        )
    )
    canvas = Image.alpha_composite(canvas, hex_lay)

    # ── 3. Lens rings ──────────────────────────────────────────────────────────
    lens_r   = S * 0.345
    ring_w   = max(2, int(S * 0.024))
    inner_r  = lens_r * 0.835

    ring_lay = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ring_draw = ImageDraw.Draw(ring_lay)

    # Outer glow
    for i in range(28, 0, -1):
        rg = lens_r + i * S * 0.0025
        a  = int(55 * math.sin(math.pi * i / 28))
        ring_draw.ellipse([cx - rg, cy - rg, cx + rg, cy + rg],
                          outline=(0, 140, 255, a), width=max(1, SCALE // 2))

    # Main outer ring
    ring_draw.ellipse([cx - lens_r, cy - lens_r, cx + lens_r, cy + lens_r],
                      outline=(50, 170, 255, 240), width=ring_w)
    # Tick marks on outer ring (12 positions)
    tick_outer = lens_r + ring_w * 0.3
    tick_inner = lens_r - ring_w * 2.5
    for i in range(12):
        a = 2 * math.pi * i / 12
        x0 = cx + tick_outer * math.cos(a); y0 = cy + tick_outer * math.sin(a)
        x1 = cx + tick_inner * math.cos(a); y1 = cy + tick_inner * math.sin(a)
        ring_draw.line([(x0, y0), (x1, y1)], fill=(80, 190, 255, 150), width=max(1, SCALE))

    # Inner ring
    rw2 = max(1, ring_w // 2)
    ring_draw.ellipse([cx - inner_r, cy - inner_r, cx + inner_r, cy + inner_r],
                      outline=(25, 110, 210, 180), width=rw2)

    canvas = Image.alpha_composite(canvas, ring_lay)

    # ── 4. Dark lens body ──────────────────────────────────────────────────────
    body_r = inner_r - rw2 - 1
    body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(body).ellipse([cx - body_r, cy - body_r, cx + body_r, cy + body_r],
                                  fill=(7, 11, 22, 245))
    canvas = Image.alpha_composite(canvas, body)

    # ── 5. Aperture blades (6 blades → hexagonal opening) ─────────────────────
    n_blades   = 6
    ap_r       = body_r * 0.415   # inner aperture radius (hexagonal opening)
    blade_or   = body_r * 0.93    # outer reach of each blade
    span       = 2 * math.pi / n_blades * 1.32
    offset     = math.pi / n_blades * 0.75

    blades = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    blades_draw = ImageDraw.Draw(blades)
    steps = 14

    for i in range(n_blades):
        base = 2 * math.pi * i / n_blades
        pts  = []
        # inner arc
        for k in range(steps + 1):
            a = base - span / 2 + span * k / steps
            pts.append((cx + ap_r * math.cos(a), cy + ap_r * math.sin(a)))
        # outer arc (rotated by offset)
        for k in range(steps, -1, -1):
            a = (base + offset) - span / 2 + span * k / steps
            pts.append((cx + blade_or * math.cos(a), cy + blade_or * math.sin(a)))
        blades_draw.polygon(pts, fill=(11, 17, 30, 225))

    canvas = Image.alpha_composite(canvas, blades)

    # ── 6. Centre aperture glow ────────────────────────────────────────────────
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    for ring in range(int(ap_r), 0, -2):
        t = ring / ap_r
        r_val = int(5  + (1 - t) * 20)
        g_val = int(90 + (1 - t) * 110)
        b_val = int(210 + (1 - t) * 45)
        a_val = int(t * 50 + (1 - t) * 200)
        glow_draw.ellipse([cx - ring, cy - ring, cx + ring, cy + ring],
                          fill=(r_val, g_val, b_val, a_val))
    canvas = Image.alpha_composite(canvas, glow)

    # Bright centre dot
    dot_r = ap_r * 0.22
    draw = ImageDraw.Draw(canvas)
    draw.ellipse([cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r],
                 fill=(200, 235, 255, 230))

    # ── 7. Lens-flare reflection (upper-left) ──────────────────────────────────
    refl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    refl_draw = ImageDraw.Draw(refl)
    ro = inner_r * 0.32
    rr = inner_r * 0.52
    refl_draw.ellipse([cx - ro - rr, cy - ro - rr, cx - ro + rr, cy - ro + rr],
                      fill=(255, 255, 255, 18))
    # Tiny secondary flare
    ro2 = inner_r * 0.55; rr2 = inner_r * 0.18
    refl_draw.ellipse([cx - ro2 - rr2, cy + ro2 * 0.3 - rr2,
                       cx - ro2 + rr2, cy + ro2 * 0.3 + rr2],
                      fill=(255, 255, 255, 10))
    canvas = Image.alpha_composite(canvas, refl)

    # ── 8. Final squircle clip ─────────────────────────────────────────────────
    import numpy as np
    r_ch, g_ch, b_ch, a_ch = canvas.split()
    clipped = np.minimum(np.array(a_ch), np.array(sq_mask)).astype("uint8")
    canvas.putalpha(Image.fromarray(clipped))

    # ── 9. Downscale ───────────────────────────────────────────────────────────
    return canvas.resize((size, size), Image.LANCZOS)


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    ASSET_DIR.mkdir(parents=True, exist_ok=True)

    print("Rendering master at 1024×1024 …")
    master = create_icon(1024)
    master.save(ASSET_DIR / "AppIcon-1024.png")
    print("  AppIcon-1024.png ✓")

    for fname, size in SIZES.items():
        if size == 1024:
            continue
        img = master.resize((size, size), Image.LANCZOS)
        img.save(ASSET_DIR / fname)
        print(f"  {fname} ({size}px) ✓")

    contents_path = ASSET_DIR / "Contents.json"
    contents_path.write_text(json.dumps(CONTENTS, indent=2) + "\n")
    print(f"\n✓ {contents_path}")
    print(f"✓ {len(SIZES)} sizes written to {ASSET_DIR}")


if __name__ == "__main__":
    main()

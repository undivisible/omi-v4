#!/usr/bin/env python3
"""Render the Omi launcher icons from the geometry in assets/images/omi_mark.svg.

Only the platforms that still shipped Flutter's default chevron are written:
macOS (Assets.xcassets), web (favicon plus the PWA icons) and the Windows
.ico. iOS and Android already carry the Omi mark and are left untouched.

Requires rsvg-convert on PATH; no Python packages beyond the standard library.
"""

import math
import struct
import subprocess
import sys
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent.parent

# Brand tokens, copied from lib/features/mobile_companion_shell.dart:
# _ink (0xff171716) for the plate, _cream (0xfffffcec) for the mark.
INK = "#171716"
CREAM = "#fffcec"

# Proportions of the mark inside its own 260x260 viewBox: the ring spans
# 2 * (86.71 + 17.2) = 207.82 units, the axis dots sit at radius 86.71, the
# diagonal dots at 91.92, and every dot has radius 17.2.
MARK_SPAN = 207.82
AXIS_RATIO = 86.71 / MARK_SPAN
DIAG_RATIO = 91.92 / MARK_SPAN
DOT_RATIO = 17.2 / MARK_SPAN


def _tuning(size: int) -> tuple[float, float]:
    """Art-area fraction and dot boost for a given output size in pixels.

    Small icons lose the ring entirely at the nominal proportions, so the mark
    is allowed to fill more of the plate and the dots are fattened until they
    nearly touch. Large icons keep the drawn proportions.
    """
    if size <= 32:
        return 0.92, 1.18
    if size <= 64:
        return 0.88, 1.10
    if size <= 128:
        return 0.84, 1.03
    return 0.80, 1.0


def _mark(cx: float, cy: float, art: float, size: int) -> str:
    axis = art * AXIS_RATIO
    diag = art * DIAG_RATIO / math.sqrt(2)
    _, boost = _tuning(size)
    dot = art * DOT_RATIO * boost
    # Keep a visible gap between neighbouring dots at every size.
    spacing = 2 * axis * math.sin(math.pi / 8)
    dot = min(dot, spacing * 0.36)
    centres = [
        (cx, cy - axis),
        (cx + diag, cy - diag),
        (cx + axis, cy),
        (cx + diag, cy + diag),
        (cx, cy + axis),
        (cx - diag, cy + diag),
        (cx - axis, cy),
        (cx - diag, cy - diag),
    ]
    dots = "".join(
        f'<circle cx="{x:.3f}" cy="{y:.3f}" r="{dot:.3f}"/>' for x, y in centres
    )
    if size >= 256:
        blur = art * 9 / 260
        glow = (
            f'<filter id="g" x="-40%" y="-40%" width="180%" height="180%"'
            f' color-interpolation-filters="sRGB">'
            f'<feGaussianBlur in="SourceGraphic" stdDeviation="{blur:.3f}" result="soft"/>'
            f'<feColorMatrix in="soft" type="matrix" result="halo"'
            f' values="1 0 0 0 0 0 1 0 0 0 0 0 1 0 0 0 0 0 0.85 0"/>'
            f'<feMerge><feMergeNode in="halo"/><feMergeNode in="halo"/>'
            f'<feMergeNode in="SourceGraphic"/></feMerge></filter>'
        )
        return f"<defs>{glow}</defs><g fill=\"{CREAM}\" filter=\"url(#g)\">{dots}</g>"
    return f'<g fill="{CREAM}">{dots}</g>'


def _document(size: int, inset: float, radius: float, art_scale: float) -> str:
    body = size * (1 - 2 * inset)
    origin = size * inset
    art_fraction, _ = _tuning(size)
    art = body * art_fraction * art_scale
    centre = size / 2
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}"'
        f' viewBox="0 0 {size} {size}">'
        f'<rect x="{origin:.3f}" y="{origin:.3f}" width="{body:.3f}" height="{body:.3f}"'
        f' rx="{body * radius:.3f}" ry="{body * radius:.3f}" fill="{INK}"/>'
        f"{_mark(centre, centre, art, size)}"
        "</svg>"
    )


def render(
    path: Path, size: int, inset: float, radius: float, art_scale: float = 1.0
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    svg = _document(size, inset, radius, art_scale).encode()
    png = subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), "-b", "none"],
        input=svg,
        stdout=subprocess.PIPE,
        check=True,
    ).stdout
    path.write_bytes(png)
    print(f"{path.relative_to(APP_DIR)} ({size}px)")


def _png(size: int, inset: float, radius: float, art_scale: float = 1.0) -> bytes:
    svg = _document(size, inset, radius, art_scale).encode()
    return subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), "-b", "none"],
        input=svg,
        stdout=subprocess.PIPE,
        check=True,
    ).stdout


def render_ico(path: Path, sizes: tuple[int, ...], radius: float) -> None:
    """Write a multi-resolution .ico whose entries are embedded PNGs."""
    frames = [_png(size, 0.0, radius) for size in sizes]
    header = struct.pack("<HHH", 0, 1, len(frames))
    offset = len(header) + 16 * len(frames)
    entries = b""
    for size, frame in zip(sizes, frames):
        entries += struct.pack(
            "<BBBBHHII",
            0 if size >= 256 else size,
            0 if size >= 256 else size,
            0,
            0,
            1,
            32,
            len(frame),
            offset,
        )
        offset += len(frame)
    path.write_bytes(header + entries + b"".join(frames))
    print(f"{path.relative_to(APP_DIR)} ({', '.join(str(s) for s in sizes)}px)")


def main() -> int:
    macos = APP_DIR / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    # Apple's macOS grid leaves the plate at 824/1024 of the canvas with a
    # continuous corner of roughly 0.225 of the plate.
    for size in (16, 32, 64, 128, 256, 512, 1024):
        render(macos / f"app_icon_{size}.png", size, (1 - 824 / 1024) / 2, 0.225)

    web = APP_DIR / "web"
    # The favicon is drawn edge to edge, so the ring is pulled in to keep
    # a margin the rounded PWA plates get for free.
    render(web / "favicon.png", 16, 0.0, 0.0, 0.80)
    for size in (192, 512):
        render(web / "icons" / f"Icon-{size}.png", size, 0.0, 0.22)
        # Maskable icons are cropped to a platform shape, so the plate is
        # full-bleed square and the mark stays inside the 80% safe zone.
        render(web / "icons" / f"Icon-maskable-{size}.png", size, 0.0, 0.0, 0.72)

    render_ico(
        APP_DIR / "windows/runner/resources/app_icon.ico",
        (16, 32, 48, 64, 128, 256),
        0.22,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Render assets/app-icon.svg onto the macOS icon grid.

Writes assets/dock-icon.png (the 1024 master used for the Dock and the bundle)
and assets/AppIcon.icns. The glyph path is read from the SVG so the shape lives
in one place.

macOS draws app icons as an 824x824 rounded body centred in a 1024x1024 canvas,
so the 100px margin is part of the artwork. A full-bleed square renders larger
than every other icon in the Dock, which is the bug this script fixes.

The corner and shadow constants were fitted to the silhouette macOS itself
applies to system app icons, sampled from Music.app's 256px representation.
The fitted corner tracks that silhouette to within 3px at 1024.
"""

import math
import re
import struct
import subprocess
import sys
import zlib
from collections.abc import Callable
from pathlib import Path

# The glyph is stored as flat polygons, so a point is just a coordinate pair.
Point = tuple[float, float]
Polygon = list[Point]
Edge = tuple[float, float, float, float]  # x0, y0, x1, y1

CANVAS = 1024
BODY = 824  # rounded body inside the canvas, per Apple's macOS icon grid
# The sides are straight; only the corners curve. Each corner spans this much of
# the body along both edges, and bends on a superellipse of this exponent. A
# circular arc (exponent 2) is visibly tighter than what macOS draws.
CORNER_EXTENT = 0.318
CORNER_EXPONENT = 3.06
GLYPH_FRACTION = 0.62  # glyph width as a fraction of the body
SHADOW_OFFSET = 0.004  # fraction of the canvas, downward
SHADOW_BLUR = 0.013
SHADOW_ALPHA = 0.26
SUBROWS = 8  # vertical supersampling used for antialiasing

BACKGROUND = (0x1A, 0x15, 0x14)
GLYPH = (0xD9, 0x77, 0x57)

ICONSET = {
    "icon_16x16": 16,
    "icon_16x16@2x": 32,
    "icon_32x32": 32,
    "icon_32x32@2x": 64,
    "icon_128x128": 128,
    "icon_128x128@2x": 256,
    "icon_256x256": 256,
    "icon_256x256@2x": 512,
    "icon_512x512": 512,
    "icon_512x512@2x": 1024,
}

ROOT = Path(__file__).resolve().parent.parent
SVG = ROOT / "assets" / "app-icon.svg"
DOCK_PNG = ROOT / "assets" / "dock-icon.png"
ICNS = ROOT / "assets" / "AppIcon.icns"

TOKEN = re.compile(r"([MmLlHhVvZz])|(-?\d*\.?\d+(?:[eE][-+]?\d+)?)")


def parse_path(d: str) -> list[Polygon]:
    """Turn an SVG path into closed polygons. Handles the M/L/H/V/Z subset."""
    subpaths: list[Polygon] = []
    current: Polygon = []
    command: str | None = None
    x, y = 0.0, 0.0
    start: Point = (0.0, 0.0)
    numbers: list[float] = []

    def flush() -> None:
        """Consume the numbers gathered since the last command letter."""
        nonlocal x, y, start, current, numbers
        if command in ("M", "m"):
            for i in range(0, len(numbers) - 1, 2):
                nx, ny = numbers[i], numbers[i + 1]
                if command == "m":
                    nx, ny = x + nx, y + ny
                # Only the first pair moves; the rest are implicit line-tos.
                if i == 0:
                    if len(current) > 1:
                        subpaths.append(current)
                    current, start = [(nx, ny)], (nx, ny)
                else:
                    current.append((nx, ny))
                x, y = nx, ny
        elif command in ("L", "l"):
            for i in range(0, len(numbers) - 1, 2):
                nx, ny = numbers[i], numbers[i + 1]
                if command == "l":
                    nx, ny = x + nx, y + ny
                current.append((nx, ny))
                x, y = nx, ny
        elif command in ("H", "h"):
            for value in numbers:
                x = x + value if command == "h" else value
                current.append((x, y))
        elif command in ("V", "v"):
            for value in numbers:
                y = y + value if command == "v" else value
                current.append((x, y))
        elif command in ("Z", "z"):
            if len(current) > 1:
                subpaths.append(current)
            current = []
            x, y = start
        numbers = []

    for letter, number in TOKEN.findall(d):
        if letter:
            if command is not None:
                flush()
            command = letter
        else:
            numbers.append(float(number))
    if command is not None:
        flush()
    if len(current) > 1:
        subpaths.append(current)
    return subpaths


def edges_of(polygons: list[Polygon]) -> list[Edge]:
    """Non-horizontal edges only. Horizontal ones never crosses a scanline."""
    out: list[Edge] = []
    for points in polygons:
        for i in range(len(points)):
            x0, y0 = points[i]
            x1, y1 = points[(i + 1) % len(points)]
            if y0 != y1:
                out.append((x0, y0, x1, y1))
    return out


def add_span(row: list[float], x0: float, x1: float, weight: float, width: int) -> None:
    """Accumulate coverage for the span [x0, x1), splitting the end pixels."""
    if x1 <= x0:
        return
    x0, x1 = max(x0, 0.0), min(x1, float(width))
    if x1 <= x0:
        return
    first, last = int(x0), int(math.ceil(x1)) - 1
    if first == last:
        row[first] += (x1 - x0) * weight
        return
    row[first] += (first + 1 - x0) * weight
    for px in range(first + 1, last):
        row[px] += weight
    row[last] += (x1 - last) * weight


def rasterize(
    size: int, polygons: list[Polygon], full_bleed: bool
) -> tuple[list[float], list[float]]:
    """Return (body coverage, glyph coverage) float arrays for one icon size."""
    scale = size / CANVAS
    body = BODY * scale
    half = body / 2.0
    corner = CORNER_EXTENT * body
    centre = size / 2.0
    weight = 1.0 / SUBROWS
    body_cov = [0.0] * (size * size)
    glyph_cov = [0.0] * (size * size)
    edges = edges_of(polygons)

    for row_index in range(size):
        body_row = body_cov[row_index * size:(row_index + 1) * size]
        glyph_row = glyph_cov[row_index * size:(row_index + 1) * size]
        for sub in range(SUBROWS):
            y = row_index + (sub + 0.5) / SUBROWS
            if full_bleed:
                add_span(body_row, 0.0, float(size), weight, size)
            else:
                # Distance from this scanline to the nearer horizontal body edge.
                depth = min(y - (centre - half), (centre + half) - y)
                if depth > 0.0:
                    if depth >= corner:
                        reach = half
                    else:
                        # Superellipse over the corner box: p^n + q^n = 1.
                        q = 1.0 - depth / corner
                        p = (1.0 - q**CORNER_EXPONENT) ** (1.0 / CORNER_EXPONENT)
                        reach = half - corner * (1.0 - p)
                    add_span(body_row, centre - reach, centre + reach, weight, size)

            crossings = sorted(
                x0 + (y - y0) * (x1 - x0) / (y1 - y0)
                for x0, y0, x1, y1 in edges
                if min(y0, y1) <= y < max(y0, y1)
            )
            # Even-odd fill: the eyes are holes inside the outer ring.
            for i in range(0, len(crossings) - 1, 2):
                add_span(glyph_row, crossings[i], crossings[i + 1], weight, size)
        body_cov[row_index * size:(row_index + 1) * size] = body_row
        glyph_cov[row_index * size:(row_index + 1) * size] = glyph_row
    return body_cov, glyph_cov


def box_blur(source: list[float], size: int, radius: int) -> list[float]:
    """Three box passes, which is close enough to a Gaussian for a shadow."""
    data = source
    for _ in range(3):
        for axis in range(2):
            out = [0.0] * (size * size)
            read: Callable[[int], float]
            for line in range(size):
                # Running sum over a (2 * radius + 1) window, clamped at the edges.
                if axis == 0:
                    read = lambda i, line=line: data[line * size + min(max(i, 0), size - 1)]
                else:
                    read = lambda i, line=line: data[min(max(i, 0), size - 1) * size + line]
                window = sum(read(i) for i in range(-radius, radius + 1))
                span = 2 * radius + 1
                for i in range(size):
                    if axis == 0:
                        out[line * size + i] = window / span
                    else:
                        out[i * size + line] = window / span
                    window += read(i + radius + 1) - read(i - radius)
            data = out
    return data


def render(
    size: int, polygons: list[Polygon], full_bleed: bool = False
) -> tuple[bytes, int]:
    body_cov, glyph_cov = rasterize(size, polygons, full_bleed)

    shadow = [0.0] * (size * size)
    radius = max(1, round(SHADOW_BLUR * size))
    offset = round(SHADOW_OFFSET * size)
    if not full_bleed and offset + radius > 0:
        shifted = [0.0] * (size * size)
        for row_index in range(size - offset):
            target = (row_index + offset) * size
            shifted[target:target + size] = body_cov[row_index * size:(row_index + 1) * size]
        shadow = box_blur(shifted, size, radius)

    pixels = bytearray()
    for row_index in range(size):
        pixels.append(0)  # PNG filter type: none
        for column in range(size):
            i = row_index * size + column
            body = min(1.0, body_cov[i])
            behind = min(1.0, shadow[i]) * SHADOW_ALPHA * (1.0 - body)
            alpha = body + behind
            if alpha <= 0.0:
                pixels.extend((0, 0, 0, 0))
                continue
            glyph = min(1.0, glyph_cov[i])
            for channel in range(3):
                tint = BACKGROUND[channel] * (1.0 - glyph) + GLYPH[channel] * glyph
                # Shadow is black, so it only dilutes the body colour.
                pixels.append(round(tint * body / alpha))
            pixels.append(round(alpha * 255))
    return bytes(pixels), size


def write_png(path: Path, raw: bytes, size: int) -> None:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def main() -> None:
    svg = SVG.read_text()
    match = re.search(r'\sd="([^"]+)"', svg, re.S)
    if not match:
        sys.exit(f"no path found in {SVG}")

    polygons = parse_path(match.group(1))
    points = [point for polygon in polygons for point in polygon]
    min_x = min(x for x, _ in points)
    max_x = max(x for x, _ in points)
    min_y = min(y for _, y in points)
    max_y = max(y for _, y in points)

    # Fit the glyph's bounding box into the body and centre it on the canvas.
    scale = (GLYPH_FRACTION * BODY) / (max_x - min_x)
    dx = CANVAS / 2 - (min_x + max_x) / 2 * scale
    dy = CANVAS / 2 - (min_y + max_y) / 2 * scale
    placed = [[(x * scale + dx, y * scale + dy) for x, y in polygon] for polygon in polygons]

    def at(size: int) -> list[Polygon]:
        factor = size / CANVAS
        return [[(x * factor, y * factor) for x, y in polygon] for polygon in placed]

    print(f"rendering {DOCK_PNG.name}")
    write_png(DOCK_PNG, *render(CANVAS, at(CANVAS)))

    iconset = ROOT / "assets" / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    rendered: dict[int, tuple[bytes, int]] = {}
    for name, size in ICONSET.items():
        if size not in rendered:
            print(f"rendering {size}x{size}")
            rendered[size] = render(size, at(size))
        write_png(iconset / f"{name}.png", *rendered[size])

    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ICNS)], check=True)
    for file in iconset.iterdir():
        file.unlink()
    iconset.rmdir()
    print(f"wrote {ICNS.name}")


if __name__ == "__main__":
    main()

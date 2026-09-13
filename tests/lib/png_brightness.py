#!/usr/bin/env python3
"""Print the mean pixel brightness (0-255) of a PNG or binary PPM screenshot.

Used by tests/vmbox_night_lockdown.sh to decide "is the screen black" from a
`vm screenshot` without depending on Pillow in the test environment. Handles
what QEMU's screendump produces: 8-bit RGB/RGBA non-interlaced PNG, or P6 PPM.
"""

from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path


def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def _unfilter(raw: bytes, width: int, height: int, bpp: int) -> bytearray:
    """Reverse PNG scanline filtering; returns the flat pixel bytes."""
    stride = width * bpp
    out = bytearray()
    prev = bytearray(stride)
    pos = 0
    for _ in range(height):
        ftype = raw[pos]
        pos += 1
        line = bytearray(raw[pos : pos + stride])
        pos += stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if ftype == 1:
                line[i] = (line[i] + a) & 0xFF
            elif ftype == 2:
                line[i] = (line[i] + b) & 0xFF
            elif ftype == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif ftype == 4:
                line[i] = (line[i] + _paeth(a, b, c)) & 0xFF
        out += line
        prev = line
    return out


def png_pixels(data: bytes) -> tuple[bytes, int]:
    """Return (pixel bytes, bytes per pixel) for an 8-bit RGB/RGBA PNG."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos = 8
    width = height = 0
    bpp = 3
    idat = b""
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        ctype = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(
                ">IIBBBBB", body
            )
            if depth != 8 or interlace != 0 or color not in (2, 6):
                raise ValueError(
                    f"unsupported PNG (depth={depth} color={color} interlace={interlace})"
                )
            bpp = 4 if color == 6 else 3
        elif ctype == b"IDAT":
            idat += body
        elif ctype == b"IEND":
            break
    return bytes(_unfilter(zlib.decompress(idat), width, height, bpp)), bpp


def ppm_pixels(data: bytes) -> tuple[bytes, int]:
    """Return (pixel bytes, 3) for a binary P6 PPM."""
    fields: list[bytes] = []
    pos = 2
    while len(fields) < 3:
        while data[pos : pos + 1].isspace():
            pos += 1
        start = pos
        while not data[pos : pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    pos += 1
    return data[pos:], 3


def mean_brightness(path: Path) -> float:
    data = path.read_bytes()
    pixels, bpp = png_pixels(data) if data[:4] == b"\x89PNG" else ppm_pixels(data)
    rgb = sum(
        pixels[i] + pixels[i + 1] + pixels[i + 2]
        for i in range(0, len(pixels) - bpp + 1, bpp)
    )
    return rgb / (3 * (len(pixels) // bpp))


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: png_brightness.py <screenshot.png|.ppm>", file=sys.stderr)
        return 2
    print(int(mean_brightness(Path(argv[1]))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

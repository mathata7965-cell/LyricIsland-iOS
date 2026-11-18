#!/usr/bin/env python3
"""
Generate a crisp 1024x1024 Obsidian-Acoustic AppIcon.png for LyricIsland
using pure Python standard library (zero external dependencies).
"""
import math
import os
import struct
import zlib


def clamp(v: float) -> int:
    if v <= 0.0:
        return 0
    if v >= 255.0:
        return 255
    return int(v + 0.5)


def smoothstep(edge0: float, edge1: float, x: float) -> float:
    if edge1 == edge0:
        return 0.0
    t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3.0 - 2.0 * t)


def sd_rounded_box(px: float, py: float, bx: float, by: float, r: float) -> float:
    qx = abs(px) - bx + r
    qy = abs(py) - by + r
    out_d = math.hypot(max(qx, 0.0), max(qy, 0.0))
    in_d = min(max(qx, qy), 0.0)
    return out_d + in_d - r


def sd_capsule(px: float, py: float, ax: float, ay: float, bx: float, by: float, r: float) -> float:
    pax = px - ax
    pay = py - ay
    bax = bx - ax
    bay = by - ay
    denom = bax * bax + bay * bay
    h = max(0.0, min(1.0, (pax * bax + pay * bay) / denom)) if denom > 0.0 else 0.0
    return math.hypot(pax - bax * h, pay - bay * h) - r


def write_png(path: str, width: int, height: int, raw: bytes) -> None:
    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    idat = zlib.compress(raw, level=6)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def generate_icon(out_path: str, size: int = 1024) -> None:
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    raw = bytearray()
    inv = 1.0 / size

    for y in range(size):
        raw.append(0)
        v = (y + 0.5) * inv
        ny = v * 2.0 - 1.0
        for x in range(size):
            u = (x + 0.5) * inv
            nx = u * 2.0 - 1.0

            # Deep obsidian metallic surface with subtle top-lit sheen
            r = 8.0 + 10.0 * max(0.0, 1.0 - v * 1.15)
            g = 8.5 + 10.5 * max(0.0, 1.0 - v * 1.15)
            b = 11.0 + 13.0 * max(0.0, 1.0 - v * 1.05)

            # Subtle radial vermilion-warm acoustic glow behind the pill
            glow = math.exp(-((nx * 1.05) ** 2 + ((ny + 0.08) * 1.45) ** 2) * 3.4)
            r += glow * 34.0
            g += glow * 10.0
            b += glow * 8.0

            # Outer recessed precision chassis frame
            d_chassis = sd_rounded_box(nx, ny, 0.72, 0.72, 0.24)
            chassis_rim = math.exp(-abs(d_chassis) * 160.0) * 0.26
            r += chassis_rim * 180.0
            g += chassis_rim * 184.0
            b += chassis_rim * 195.0

            # Primary Dynamic Island capsule (upper center)
            pill_y = -0.18
            d_pill = sd_rounded_box(nx, ny - pill_y, 0.54, 0.165, 0.165)

            # Soft drop shadow under pill
            pill_shadow = (1.0 - smoothstep(-0.02, 0.10, d_pill)) * 0.65
            r *= 1.0 - pill_shadow * 0.7
            g *= 1.0 - pill_shadow * 0.7
            b *= 1.0 - pill_shadow * 0.7

            pill_alpha = 1.0 - smoothstep(-0.004, 0.004, d_pill)
            if pill_alpha > 0.0:
                pr, pg, pb = 3.0, 3.0, 4.0
                # Specular top edge inside pill
                top_edge = math.exp(-abs(d_pill + 0.006) * 240.0) * max(0.0, -(ny - pill_y) * 5.0)
                pr += top_edge * 95.0
                pg += top_edge * 98.0
                pb += top_edge * 108.0

                r = r * (1.0 - pill_alpha) + pr * pill_alpha
                g = g * (1.0 - pill_alpha) + pg * pill_alpha
                b = b * (1.0 - pill_alpha) + pb * pill_alpha

            # Titanium hairline ring around pill
            pill_rim = math.exp(-abs(d_pill) * 280.0) * 0.55
            r += pill_rim * 165.0
            g += pill_rim * 170.0
            b += pill_rim * 185.0

            # Left active signal dot inside the Dynamic Island pill (Signal Vermilion #FF3B30)
            dot_x = -0.35
            d_dot = math.hypot(nx - dot_x, ny - pill_y) - 0.056
            dot_glow = math.exp(-max(0.0, d_dot) * 18.0) * 0.45
            r += dot_glow * 255.0
            g += dot_glow * 58.0
            b += dot_glow * 46.0

            dot_alpha = 1.0 - smoothstep(-0.004, 0.004, d_dot)
            if dot_alpha > 0.0:
                r = r * (1.0 - dot_alpha) + 255.0 * dot_alpha
                g = g * (1.0 - dot_alpha) + 68.0 * dot_alpha
                b = b * (1.0 - dot_alpha) + 52.0 * dot_alpha

            # Right precision equalizer / active waveform bars inside pill
            bar_specs = [
                (0.18, 0.048),
                (0.26, 0.078),
                (0.34, 0.056),
                (0.42, 0.036),
            ]
            for bx, bh in bar_specs:
                d_bar = sd_capsule(nx, ny, bx, pill_y - bh, bx, pill_y + bh, 0.017)
                ba = 1.0 - smoothstep(-0.004, 0.004, d_bar)
                if ba > 0.0:
                    r = r * (1.0 - ba) + 245.0 * ba
                    g = g * (1.0 - ba) + 245.0 * ba
                    b = b * (1.0 - ba) + 247.0 * ba

            # Below the island: three crisp lyric-typography bars (Active -> Secondary -> Faded)
            lyric_bars = [
                (-0.44, 0.17, 0.44, 0.17, 0.034, (245.0, 245.0, 247.0), 0.96),
                (-0.44, 0.31, 0.24, 0.31, 0.026, (175.0, 178.0, 185.0), 0.72),
                (-0.44, 0.43, 0.06, 0.43, 0.022, (110.0, 112.0, 118.0), 0.45),
            ]
            for ax, ay, bx, by, rad, col, alpha in lyric_bars:
                d_l = sd_capsule(nx, ny, ax, ay, bx, by, rad)
                la = (1.0 - smoothstep(-0.004, 0.004, d_l)) * alpha
                if la > 0.0:
                    r = r * (1.0 - la) + col[0] * la
                    g = g * (1.0 - la) + col[1] * la
                    b = b * (1.0 - la) + col[2] * la

            raw.append(clamp(r))
            raw.append(clamp(g))
            raw.append(clamp(b))

    write_png(out_path, size, size, bytes(raw))


if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)
    out = os.path.join(repo_root, "LyricIsland", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
    generate_icon(out)
    print(f"Generated {out}")

#!/usr/bin/env python3
"""Generate seamless 512x512 tangent-space rock normal & diffuse maps.

Produces weathered natural mineral stone textures for SurfaceScatter and RingField:
  - data/textures/rock_normal.png  (soft geological relief + beveled facets)
  - data/textures/rock_diffuse.png (neutral mottled mineral stone with crevice AO)
"""

from pathlib import Path
import numpy as np
from PIL import Image


def periodic_fbm(size: int, base_octaves: list[tuple[int, float]], rng: np.random.Generator) -> np.ndarray:
    """Synthesize seamless periodic heightfield using band-limited FFT noise."""
    fy = np.fft.fftfreq(size, d=1.0 / size)
    fx = np.fft.fftfreq(size, d=1.0 / size)
    KX, KY = np.meshgrid(fx, fy, indexing="xy")
    K = np.sqrt(KX ** 2 + KY ** 2)

    height = np.zeros((size, size), dtype=np.float64)
    for freq, amp in base_octaves:
        phase = rng.uniform(0.0, 2.0 * np.pi, size=(size, size))
        re = rng.normal(0.0, 1.0, size=(size, size))
        im = rng.normal(0.0, 1.0, size=(size, size))
        spec = (re + 1j * im) * np.exp(1j * phase)
        band = np.exp(-0.5 * ((K - freq) / max(1.0, freq * 0.50)) ** 2)
        band[0, 0] = 0.0
        layer = np.fft.ifft2(spec * band).real
        std = np.std(layer)
        if std > 1e-8:
            layer /= std
        height += amp * layer
    return height


def periodic_voronoi_facets(size: int, num_cells: int, rng: np.random.Generator) -> np.ndarray:
    """Compute seamless toroidal F2 - F1 distance field for softly beveled stone facets."""
    pts = rng.uniform(0.0, 1.0, size=(num_cells, 2))
    coords = np.linspace(0.0, 1.0, size, endpoint=False)
    gx, gy = np.meshgrid(coords, coords, indexing="xy")

    d1 = np.full((size, size), 10.0, dtype=np.float64)
    d2 = np.full((size, size), 10.0, dtype=np.float64)

    for px, py in pts:
        dx = np.abs(gx - px)
        dx = np.minimum(dx, 1.0 - dx)
        dy = np.abs(gy - py)
        dy = np.minimum(dy, 1.0 - dy)
        dist = np.sqrt(dx * dx + dy * dy)
        mask1 = dist < d1
        d2 = np.where(mask1, d1, np.minimum(d2, dist))
        d1 = np.where(mask1, dist, d1)

    ridge = np.clip((d2 - d1) * np.sqrt(num_cells) * 1.65, 0.0, 1.0)
    # Softly beveled mineral seams (smoothstep-like S-curve avoids jagged single-pixel ridges)
    bevel = ridge * ridge * (3.0 - 2.0 * ridge)
    return bevel


def main() -> None:
    size = 512
    rng = np.random.default_rng(20261125)

    macro = periodic_fbm(
        size,
        [(2, 0.45), (4, 0.30), (8, 0.16), (16, 0.08), (32, 0.035)],
        rng,
    )
    facets = periodic_voronoi_facets(size, 24, rng)
    mottle = periodic_fbm(size, [(5, 0.45), (12, 0.32), (24, 0.18)], rng)

    height = 0.58 * macro + 0.42 * (facets * 2.0 - 1.0)
    height = (height - np.mean(height)) / (np.std(height) + 1e-8)

    # Gentle central-difference gradient with periodic wrap (natural weathered rock relief)
    strength = 0.48
    dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5 * strength
    dy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * 0.5 * strength

    nx = -dx
    ny = -dy
    nz = np.ones_like(height)
    inv_len = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    nx *= inv_len
    ny *= inv_len
    nz *= inv_len

    normal_rgb = np.stack(
        [
            np.clip(np.round((nx * 0.5 + 0.5) * 255.0), 0, 255),
            np.clip(np.round((ny * 0.5 + 0.5) * 255.0), 0, 255),
            np.clip(np.round((nz * 0.5 + 0.5) * 255.0), 0, 255),
        ],
        axis=-1,
    ).astype(np.uint8)

    # Neutral mineral-stone diffuse albedo (values ~172..242) for clean biome tinting
    mottle_n = np.clip(mottle * 0.18 + 0.5, 0.0, 1.0)
    macro_n = np.clip(macro * 0.16 + 0.5, 0.0, 1.0)
    crevice_ao = 0.78 + 0.22 * facets
    base_val = (182.0 + 42.0 * macro_n + 20.0 * mottle_n) * crevice_ao
    diff_r = np.clip(np.round(base_val * 1.01), 165, 245)
    diff_g = np.clip(np.round(base_val * 0.99), 162, 242)
    diff_b = np.clip(np.round(base_val * 0.96), 158, 236)
    diffuse_rgb = np.stack([diff_r, diff_g, diff_b], axis=-1).astype(np.uint8)

    tex_dir = Path(__file__).resolve().parent.parent / "data" / "textures"
    tex_dir.mkdir(parents=True, exist_ok=True)
    normal_path = tex_dir / "rock_normal.png"
    diffuse_path = tex_dir / "rock_diffuse.png"

    Image.fromarray(normal_rgb, mode="RGB").save(normal_path, optimize=True)
    Image.fromarray(diffuse_rgb, mode="RGB").save(diffuse_path, optimize=True)
    print(f"Wrote {normal_path} and {diffuse_path} ({size}x{size})")


if __name__ == "__main__":
    main()

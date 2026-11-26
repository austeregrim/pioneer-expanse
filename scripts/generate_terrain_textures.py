#!/usr/bin/env python3
"""Generate seamless 1024x1024 linear RGBA PBR detail maps for planetary terrain.

Outputs:
  - data/textures/terrain_regolith.png (soil, gravel, pebbles & dry ground micro-detail)
  - data/textures/terrain_cliff.png    (stratified bedrock, vertical fractures & crags)

Channel layout (linear RGBA):
  R, G : Tangent-space Normal X, Y ([-1, 1] -> [0, 255])
  B    : Crisp albedo / crevice AO modulation (128 = neutral)
  A    : Cavity / roughness mask
"""

from pathlib import Path
import numpy as np
from PIL import Image


def periodic_fbm(size: int, octaves: list[tuple[float, float]], rng: np.random.Generator,
                 aniso_y: float = 1.0) -> np.ndarray:
    """Synthesize seamless periodic 2D FBM using band-limited FFT noise."""
    fy = np.fft.fftfreq(size, d=1.0 / size) * aniso_y
    fx = np.fft.fftfreq(size, d=1.0 / size)
    KX, KY = np.meshgrid(fx, fy, indexing="xy")
    K = np.sqrt(KX ** 2 + KY ** 2)

    height = np.zeros((size, size), dtype=np.float64)
    for freq, amp in octaves:
        phase = rng.uniform(0.0, 2.0 * np.pi, size=(size, size))
        re = rng.normal(0.0, 1.0, size=(size, size))
        im = rng.normal(0.0, 1.0, size=(size, size))
        spec = (re + 1j * im) * np.exp(1j * phase)
        band = np.exp(-0.5 * ((K - freq) / max(1.0, freq * 0.45)) ** 2)
        band[0, 0] = 0.0
        layer = np.fft.ifft2(spec * band).real
        std = np.std(layer)
        if std > 1e-8:
            layer /= std
        height += amp * layer
    return height


def periodic_voronoi(size: int, num_cells: int, rng: np.random.Generator,
                     y_squash: float = 1.0) -> tuple[np.ndarray, np.ndarray]:
    """Return seamless toroidal (F1, F2 - F1) normalized fields for pebbles/fractures."""
    pts = rng.uniform(0.0, 1.0, size=(num_cells, 2))
    coords = np.linspace(0.0, 1.0, size, endpoint=False)
    gx, gy = np.meshgrid(coords, coords, indexing="xy")

    d1 = np.full((size, size), 10.0, dtype=np.float64)
    d2 = np.full((size, size), 10.0, dtype=np.float64)

    for px, py in pts:
        dx = np.abs(gx - px)
        dx = np.minimum(dx, 1.0 - dx)
        dy = np.abs(gy - py)
        dy = np.minimum(dy, 1.0 - dy) * y_squash
        dist = np.sqrt(dx * dx + dy * dy)
        mask1 = dist < d1
        d2 = np.where(mask1, d1, np.minimum(d2, dist))
        d1 = np.where(mask1, dist, d1)

    scale = np.sqrt(num_cells)
    f1 = np.clip(d1 * scale * 1.35, 0.0, 1.0)
    edge = np.clip((d2 - d1) * scale * 1.55, 0.0, 1.0)
    return f1, edge


def height_to_normal_xy(height: np.ndarray, strength: float) -> tuple[np.ndarray, np.ndarray]:
    """Compute seamless tangent-space normal X, Y encoded in [0, 255]."""
    dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5 * strength
    dy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * 0.5 * strength
    nx = -dx
    ny = -dy
    nz = np.ones_like(height)
    inv_len = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    nx *= inv_len
    ny *= inv_len
    r = np.clip(np.round((nx * 0.5 + 0.5) * 255.0), 0, 255).astype(np.uint8)
    g = np.clip(np.round((ny * 0.5 + 0.5) * 255.0), 0, 255).astype(np.uint8)
    return r, g


def build_regolith(size: int = 1024) -> Image.Image:
    rng = np.random.default_rng(2026112501)

    clods = periodic_fbm(size, [(4, 0.42), (9, 0.34), (20, 0.24), (42, 0.16)], rng)
    grit = periodic_fbm(size, [(68, 0.42), (120, 0.32), (195, 0.20)], rng)

    f1_med, edge_med = periodic_voronoi(size, 110, rng)
    f1_sm, edge_sm = periodic_voronoi(size, 320, rng)
    _, cracks = periodic_voronoi(size, 42, rng)

    # Rounded gravel pebbles, soil clods, and dry-earth crack crevices
    pebble_med = np.clip(1.0 - f1_med, 0.0, 1.0) ** 1.25 * (edge_med * edge_med * (3.0 - 2.0 * edge_med))
    pebble_sm = np.clip(1.0 - f1_sm, 0.0, 1.0) ** 1.35 * (edge_sm * edge_sm * (3.0 - 2.0 * edge_sm))
    crack_carve = np.clip(1.0 - (cracks / 0.18), 0.0, 1.0) ** 1.6

    height = (
        0.48 * clods
        + 0.28 * grit
        + 0.58 * (pebble_med * 2.0 - 0.45)
        + 0.36 * (pebble_sm * 2.0 - 0.45)
        - 0.65 * crack_carve
    )
    height = (height - np.mean(height)) / (np.std(height) + 1e-8)

    r, g = height_to_normal_xy(height, strength=1.35)

    # High-contrast albedo modulation centered cleanly near 0.5 (B std ~ 40-45 / 255)
    crevice = 0.60 * (edge_med ** 0.55) + 0.40 * (edge_sm ** 0.55)
    albedo = (
        0.50
        + 0.18 * np.tanh(clods * 0.85)
        + 0.12 * np.tanh(grit * 0.80)
        + 0.26 * (pebble_med - 0.20)
        + 0.16 * (pebble_sm - 0.18)
        + 0.14 * (crevice - 0.65)
        - 0.22 * crack_carve
    )
    albedo += 0.50 - np.mean(albedo)
    b = np.clip(np.round(albedo * 255.0), 24, 240).astype(np.uint8)

    cavity = np.clip(
        0.18 + 0.58 * crevice + 0.24 * (0.5 + 0.5 * np.tanh(clods)) - 0.35 * crack_carve,
        0.15,
        1.0,
    )
    a = np.clip(np.round(cavity * 255.0), 0, 255).astype(np.uint8)

    return Image.fromarray(np.stack([r, g, b, a], axis=-1), mode="RGBA")


def build_cliff(size: int = 1024) -> Image.Image:
    rng = np.random.default_rng(2026112502)

    # Organic fractured angular bedrock with zero periodic sine banding
    crag = periodic_fbm(size, [(3, 0.44), (7, 0.36), (16, 0.26), (36, 0.18), (78, 0.12)], rng)
    rock_detail = periodic_fbm(size, [(52, 0.38), (110, 0.28), (190, 0.18)], rng)
    f1_lg, crack_lg = periodic_voronoi(size, 44, rng, y_squash=0.92)
    f1_sm, crack_sm = periodic_voronoi(size, 165, rng, y_squash=0.96)

    facet_lg = np.clip(1.0 - f1_lg, 0.0, 1.0) ** 1.15 * (crack_lg ** 0.55)
    fractures = 0.58 * (crack_lg ** 0.52) + 0.42 * (crack_sm ** 0.58)
    height = 0.52 * crag + 0.22 * rock_detail + 0.44 * (fractures * 2.0 - 1.0) + 0.28 * (facet_lg * 2.0 - 0.5)
    height = (height - np.mean(height)) / (np.std(height) + 1e-8)

    r, g = height_to_normal_xy(height, strength=1.25)

    albedo = (
        0.50
        + 0.20 * np.tanh(crag * 0.85)
        + 0.11 * np.tanh(rock_detail * 0.75)
        + 0.20 * (facet_lg - 0.22)
        + 0.26 * (fractures - 0.64)
    )
    albedo += 0.50 - np.mean(albedo)
    b = np.clip(np.round(albedo * 255.0), 22, 238).astype(np.uint8)

    cavity = np.clip(0.16 + 0.64 * fractures + 0.20 * (0.5 + 0.5 * np.tanh(crag)), 0.15, 1.0)
    a = np.clip(np.round(cavity * 255.0), 0, 255).astype(np.uint8)

    return Image.fromarray(np.stack([r, g, b, a], axis=-1), mode="RGBA")


def main() -> None:
    tex_dir = Path(__file__).resolve().parent.parent / "data" / "textures"
    tex_dir.mkdir(parents=True, exist_ok=True)

    reg_path = tex_dir / "terrain_regolith.png"
    cliff_path = tex_dir / "terrain_cliff.png"

    reg = build_regolith(1024)
    cliff = build_cliff(1024)
    reg.save(reg_path, optimize=True)
    cliff.save(cliff_path, optimize=True)
    print(f"Wrote {reg_path} and {cliff_path} (1024x1024 RGBA)")


if __name__ == "__main__":
    main()

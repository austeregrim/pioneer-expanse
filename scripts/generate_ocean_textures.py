#!/usr/bin/env python3
"""
Generate seamless 512x512 RGBA ocean wave textures using 2D Inverse FFT
Phillips/Tessendorf ocean spectrum physics + Jacobian crest whitecap foam.

Channels (linear RGBA):
  R: Tangent-space Normal X ([-1, 1] -> [0, 255])
  G: Tangent-space Normal Y ([-1, 1] -> [0, 255])
  B: Normalized Wave Height ([0, 255], 128 = mean sea level)
  A: Wispy Jacobian Whitecap Foam Mask ([0, 255])
"""

import os
import numpy as np
from PIL import Image


def generate_foam_lace(size: int, wind_angle_rad: float, rng: np.random.Generator) -> np.ndarray:
    """Synthesize seamless band-pass wispy sea-foam cellular/filament texture [0, 1]."""
    fy = np.fft.fftfreq(size, d=1.0 / size)
    fx = np.fft.fftfreq(size, d=1.0 / size)
    KX, KY = np.meshgrid(fx, fy, indexing="xy")

    c, s = np.cos(wind_angle_rad), np.sin(wind_angle_rad)
    # Stretch slightly along wind direction so foam trails form organic wind-streaked lace
    K_along = KX * c + KY * s
    K_cross = -KX * s + KY * c
    k_eff = np.sqrt((K_along * 1.45) ** 2 + (K_cross * 0.85) ** 2)

    # Multi-scale band-pass spectrum for frothy bubbles + wispy filaments (no smooth blobs)
    spec1 = np.exp(-0.5 * ((np.log2(np.maximum(k_eff, 1.0)) - 3.6) / 0.85) ** 2)
    spec2 = np.exp(-0.5 * ((np.log2(np.maximum(k_eff, 1.0)) - 5.3) / 0.90) ** 2) * 0.85
    spec = np.where(k_eff > 1.5, spec1 + spec2, 0.0)

    z1 = np.fft.fft2(rng.standard_normal((size, size))) / size
    z2 = np.fft.fft2(rng.standard_normal((size, size))) / size
    f1 = np.fft.ifft2(z1 * np.sqrt(spec)).real
    f2 = np.fft.ifft2(z2 * np.sqrt(spec)).real

    # Normalize and create lacy webbed filaments (1 - |f|) * texture contrast
    f1 = f1 / (np.std(f1) + 1e-8)
    f2 = f2 / (np.std(f2) + 1e-8)
    web = np.clip(1.0 - np.abs(f1) * 0.72, 0.0, 1.0)
    bubbles = np.clip(0.5 + 0.35 * f2, 0.0, 1.0)
    lace = np.clip((web ** 1.6) * (0.45 + 0.85 * bubbles), 0.0, 1.0)
    # Stretch contrast so foam reads crisp and ragged rather than uniform haze
    p_lo, p_hi = np.percentile(lace, [15, 97])
    lace = np.clip((lace - p_lo) / (p_hi - p_lo + 1e-8), 0.0, 1.0)
    return lace


def synthesize_ocean_map(
    out_path: str,
    size: int,
    domain_m: float,
    wind_speed: float,
    gravity: float,
    wind_angle_deg: float,
    cross_swell_floor: float,
    rms_height: float,
    choppy_lambda: float,
    damping_len: float,
    seed: int,
) -> None:
    rng = np.random.default_rng(seed)

    # Angular spatial frequencies kx, ky in rad/m (axis 1 = X/u, axis 0 = Y/v)
    kx = 2.0 * np.pi * np.fft.fftfreq(size, d=domain_m / size)
    ky = 2.0 * np.pi * np.fft.fftfreq(size, d=domain_m / size)
    KX, KY = np.meshgrid(kx, ky, indexing="xy")
    K2 = KX * KX + KY * KY
    K = np.sqrt(K2)

    wind_rad = np.deg2rad(wind_angle_deg)
    wx, wy = np.cos(wind_rad), np.sin(wind_rad)

    L_p = (wind_speed * wind_speed) / gravity
    with np.errstate(divide="ignore", invalid="ignore"):
        k_hat_x = np.where(K > 0.0, KX / K, 0.0)
        k_hat_y = np.where(K > 0.0, KY / K, 0.0)
        k_dot_w = k_hat_x * wx + k_hat_y * wy
        # Directional Phillips spectrum with controlled cross-swell spread (prevents parallel stripe grid)
        dir_factor = cross_swell_floor + (1.0 - cross_swell_floor) * (k_dot_w * k_dot_w)
        phillips = np.where(
            K > 1e-6,
            np.exp(-1.0 / (K2 * L_p * L_p + 1e-12)) / (K2 * K2) * dir_factor * np.exp(-K2 * damping_len * damping_len),
            0.0,
        )
    phillips[0, 0] = 0.0

    # Exact Hermitian-symmetric complex Gaussian amplitudes
    Z = np.fft.fft2(rng.standard_normal((size, size))) / size
    h0 = Z * np.sqrt(phillips * 0.5)

    # Raw spatial height field
    H_raw = np.fft.ifft2(h0).real
    scale = rms_height / (np.std(H_raw) + 1e-12)
    h0 *= scale

    # Scaled height, exact slopes, and horizontal choppy displacement gradients
    H = np.fft.ifft2(h0).real
    dHx = np.fft.ifft2(1j * KX * h0).real
    dHy = np.fft.ifft2(1j * KY * h0).real

    with np.errstate(divide="ignore", invalid="ignore"):
        invK = np.where(K > 1e-6, 1.0 / K, 0.0)
    # Using x_disp = x - lam * Dx where Dx = ifft(-i*(kx/k)*h0): dDx/dx = ifft((kx^2/k)*h0)
    dDxx = np.fft.ifft2((KX * KX * invK) * h0).real
    dDyy = np.fft.ifft2((KY * KY * invK) * h0).real
    dDxy = np.fft.ifft2((KX * KY * invK) * h0).real

    # Sharpen crests naturally via non-folding horizontal displacement resampling (Gerstner steepening)
    Dx = np.fft.ifft2((-1j * KX * invK) * h0).real
    Dy = np.fft.ifft2((-1j * KY * invK) * h0).real
    disp_steepen = 0.36
    # Periodic bilinear warp toward wave crests (pushes slopes into peaked crests and widens troughs)
    dx_pix = (-disp_steepen * Dx) * (size / domain_m)
    dy_pix = (-disp_steepen * Dy) * (size / domain_m)
    gx, gy = np.meshgrid(np.arange(size, dtype=np.float64), np.arange(size, dtype=np.float64), indexing="xy")

    def sample_periodic(field: np.ndarray, sx: np.ndarray, sy: np.ndarray) -> np.ndarray:
        x0 = np.floor(sx).astype(np.int64) % size
        y0 = np.floor(sy).astype(np.int64) % size
        x1 = (x0 + 1) % size
        y1 = (y0 + 1) % size
        fx = sx - np.floor(sx)
        fy = sy - np.floor(sy)
        return (
            field[y0, x0] * (1.0 - fx) * (1.0 - fy)
            + field[y0, x1] * fx * (1.0 - fy)
            + field[y1, x0] * (1.0 - fx) * fy
            + field[y1, x1] * fx * fy
        )

    # Inverse-map approximation: pull values from (x + steepen*Dx) so crests sharpen without folding
    sx = gx - dx_pix
    sy = gy - dy_pix
    H_p = sample_periodic(H, sx, sy)
    dHx_p = sample_periodic(dHx, sx, sy)
    dHy_p = sample_periodic(dHy, sx, sy)
    dDxx_p = sample_periodic(dDxx, sx, sy)
    dDyy_p = sample_periodic(dDyy, sx, sy)
    dDxy_p = sample_periodic(dDxy, sx, sy)

    # Tangent-space normal N = normalize(-dHx, -dHy, 1.0)
    nz = np.ones_like(dHx_p)
    nlen = np.sqrt(dHx_p * dHx_p + dHy_p * dHy_p + nz * nz)
    Nx = -dHx_p / nlen
    Ny = -dHy_p / nlen

    # Normalized height in [0, 1]
    h_std = np.std(H_p) + 1e-8
    H_norm = np.clip(0.5 + H_p / (4.5 * h_std), 0.0, 1.0)

    # Jacobian determinant for crest wave-breaking & whitecaps: J = (1 - lam*dDxx)(1 - lam*dDyy) - (lam*dDxy)^2
    J = (1.0 - choppy_lambda * dDxx_p) * (1.0 - choppy_lambda * dDyy_p) - (choppy_lambda * dDxy_p) ** 2
    fold = np.clip((0.86 - J) / 0.85, 0.0, 1.0)
    crest_weight = np.clip((H_norm - 0.50) / 0.36, 0.0, 1.0)

    # Combine folding Jacobian with wispy frothy sea-foam lace so whitecaps look ragged & organic
    lace = generate_foam_lace(size, wind_rad, rng)
    foam_raw = (fold ** 1.40) * (0.20 + 0.80 * (crest_weight ** 1.05))
    # Add faint residual foam streaks trailing just behind breaking crests
    trail = np.clip((0.88 - J) / 0.65, 0.0, 1.0) * (crest_weight ** 1.5) * 0.22
    foam = np.clip((foam_raw * 1.75 + trail) * (0.14 + 1.32 * (lace ** 1.2)), 0.0, 1.0)

    # Pack 8-bit RGBA
    r = np.clip(Nx * 0.5 + 0.5, 0.0, 1.0)
    g = np.clip(Ny * 0.5 + 0.5, 0.0, 1.0)
    b = H_norm
    a = foam

    rgba = np.stack([r, g, b, a], axis=-1)
    img_u8 = np.clip(np.round(rgba * 255.0), 0, 255).astype(np.uint8)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    Image.fromarray(img_u8, mode="RGBA").save(out_path, optimize=True)

    whitecap_pct = float(np.mean(a > 0.35) * 100.0)
    print(f"Saved {out_path} ({size}x{size}, L={domain_m}m):")
    print(f"  Nx [-1..1]: std={np.std(Nx):.3f}, min={np.min(Nx):.3f}, max={np.max(Nx):.3f}")
    print(f"  Ny [-1..1]: std={np.std(Ny):.3f}, min={np.min(Ny):.3f}, max={np.max(Ny):.3f}")
    print(f"  Height [0..1]: mean={np.mean(b):.3f}, std={np.std(b):.3f}, min={np.min(b):.3f}, max={np.max(b):.3f}")
    print(f"  Foam   [0..1]: mean={np.mean(a):.3f}, max={np.max(a):.3f}, >0.35={whitecap_pct:.2f}%")


def main() -> None:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    tex_dir = os.path.join(root, "data", "textures")

    synthesize_ocean_map(
        out_path=os.path.join(tex_dir, "ocean_waves_swell.png"),
        size=512,
        domain_m=64.0,
        wind_speed=6.2,
        gravity=9.81,
        wind_angle_deg=27.0,
        cross_swell_floor=0.30,
        rms_height=0.72,
        choppy_lambda=1.35,
        damping_len=64.0 / 160.0,
        seed=42,
    )

    synthesize_ocean_map(
        out_path=os.path.join(tex_dir, "ocean_waves_chop.png"),
        size=512,
        domain_m=16.0,
        wind_speed=3.1,
        gravity=9.81,
        wind_angle_deg=38.0,
        cross_swell_floor=0.42,
        rms_height=0.18,
        choppy_lambda=1.22,
        damping_len=16.0 / 240.0,
        seed=1337,
    )


if __name__ == "__main__":
    main()

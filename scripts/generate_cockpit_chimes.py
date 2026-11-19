#!/usr/bin/env python3
"""Synthesize warm 4-tier aircraft-style cockpit audio alerts and advisories.

Implements a 4-tier acoustic hierarchy encoded as 44.1 kHz stereo Ogg Vorbis:
  1. ALARMS (sweeping / whooping sirens, rounded & non-piercing)
  2. WARNINGS (fast repetitive warm beeps / boops)
  3. NOTIFICATIONS / AWARENESS (two-tone aircraft "bing-bong" chimes)
  4. INFORMATIONAL (single warm "ding" or "bong")
"""

import math
import os
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np

SAMPLE_RATE = 44100
REPO_ROOT = Path(__file__).resolve().parent.parent
SOUNDS_DIR = REPO_ROOT / "data" / "sounds"


def synth_bell_note(
    total_samples: int,
    start_sec: float,
    freq_hz: float,
    dur_sec: float,
    amp: float = 1.0,
    attack_ms: float = 12.0,
    decay_tau: float = 0.28,
    sub_octave: float = 0.18,
    harm2: float = 0.22,
    shimmer: float = 0.06,
    shimmer_ratio: float = 3.0,
    stereo_detune_hz: float = 0.65,
    pan: float = 0.0,
) -> np.ndarray:
    """Render a warm stereo bell/chime note into a (total_samples, 2) float64 buffer."""
    buf = np.zeros((total_samples, 2), dtype=np.float64)
    start_idx = max(0, int(round(start_sec * SAMPLE_RATE)))
    note_samples = min(total_samples - start_idx, int(round(dur_sec * SAMPLE_RATE)))
    if note_samples <= 0:
        return buf

    t = np.arange(note_samples, dtype=np.float64) / SAMPLE_RATE

    attack_sec = max(0.004, attack_ms / 1000.0)
    attack_env = np.where(
        t < attack_sec,
        0.5 * (1.0 - np.cos(math.pi * t / attack_sec)),
        1.0,
    )

    fade_sec = min(0.055, dur_sec * 0.28)
    fade_start = max(attack_sec, dur_sec - fade_sec)
    tail_env = np.where(
        t > fade_start,
        0.5 * (1.0 + np.cos(math.pi * (t - fade_start) / max(1e-6, dur_sec - fade_start))),
        1.0,
    )

    env_fund = attack_env * tail_env * np.exp(-t / max(0.03, decay_tau))
    env_sub = attack_env * tail_env * np.exp(-t / max(0.04, decay_tau * 1.18))
    env_h2 = attack_env * tail_env * np.exp(-t / max(0.02, decay_tau * 0.48))
    env_shim = attack_env * tail_env * np.exp(-t / max(0.015, decay_tau * 0.26))

    pan_l = math.cos((pan + 1.0) * math.pi * 0.25)
    pan_r = math.sin((pan + 1.0) * math.pi * 0.25)

    for ch_idx, (detune, ch_gain) in enumerate(((-0.5 * stereo_detune_hz, pan_l), (0.5 * stereo_detune_hz, pan_r))):
        f1 = freq_hz + detune
        sig = (
            np.sin(2.0 * math.pi * f1 * t) * env_fund
            + sub_octave * np.sin(2.0 * math.pi * (0.5 * f1) * t) * env_sub
            + harm2 * np.sin(2.0 * math.pi * (2.0 * f1) * t) * env_h2
            + shimmer * np.sin(2.0 * math.pi * (shimmer_ratio * f1) * t) * env_shim
        )
        buf[start_idx : start_idx + note_samples, ch_idx] = amp * ch_gain * sig

    return buf


def synth_whoop_sweep(
    total_samples: int,
    start_sec: float,
    dur_sec: float,
    f_start: float,
    f_peak: float,
    f_end: float | None = None,
    amp: float = 1.0,
    attack_ms: float = 14.0,
    release_ms: float = 24.0,
    sub_octave: float = 0.15,
    harm2: float = 0.17,
    stereo_detune_hz: float = 0.80,
    pan: float = 0.0,
) -> np.ndarray:
    """Render a smooth, non-piercing continuous frequency sweep (whoop or rise-fall siren)."""
    buf = np.zeros((total_samples, 2), dtype=np.float64)
    start_idx = max(0, int(round(start_sec * SAMPLE_RATE)))
    note_samples = min(total_samples - start_idx, int(round(dur_sec * SAMPLE_RATE)))
    if note_samples <= 0:
        return buf

    t = np.arange(note_samples, dtype=np.float64) / SAMPLE_RATE
    u = np.clip(t / max(1e-6, dur_sec), 0.0, 1.0)

    if f_end is None:
        # Smooth upward/downward whoop (perceptually balanced log sweep)
        curve = np.power(u, 0.85)
        f_base = f_start * np.power(f_peak / max(1.0, f_start), curve)
    else:
        # Smooth rise-and-fall siren cycle
        rise_end = 0.50
        f_base = np.where(
            u <= rise_end,
            f_start + (f_peak - f_start) * 0.5 * (1.0 - np.cos(math.pi * (u / rise_end))),
            f_peak + (f_end - f_peak) * 0.5 * (1.0 - np.cos(math.pi * ((u - rise_end) / (1.0 - rise_end)))),
        )

    attack_sec = max(0.005, min(dur_sec * 0.3, attack_ms / 1000.0))
    release_sec = max(0.008, min(dur_sec * 0.35, release_ms / 1000.0))
    att = np.where(t < attack_sec, 0.5 * (1.0 - np.cos(math.pi * t / attack_sec)), 1.0)
    rel_start = max(attack_sec, dur_sec - release_sec)
    rel = np.where(
        t > rel_start,
        0.5 * (1.0 + np.cos(math.pi * (t - rel_start) / max(1e-6, dur_sec - rel_start))),
        1.0,
    )
    env = att * rel

    pan_l = math.cos((pan + 1.0) * math.pi * 0.25)
    pan_r = math.sin((pan + 1.0) * math.pi * 0.25)

    for ch_idx, (detune, ch_gain) in enumerate(((-0.5 * stereo_detune_hz, pan_l), (0.5 * stereo_detune_hz, pan_r))):
        f_inst = np.maximum(20.0, f_base + detune)
        phase = 2.0 * math.pi * np.cumsum(f_inst) / SAMPLE_RATE
        sig = (
            np.sin(phase)
            + sub_octave * np.sin(0.5 * phase)
            + harm2 * np.sin(2.0 * phase)
        )
        buf[start_idx : start_idx + note_samples, ch_idx] = amp * ch_gain * env * sig

    return buf


def synth_rounded_boop(
    total_samples: int,
    start_sec: float,
    freq_hz: float,
    dur_sec: float,
    amp: float = 1.0,
    attack_ms: float = 8.0,
    release_ms: float = 14.0,
    sub_octave: float = 0.10,
    harm2: float = 0.14,
    stereo_detune_hz: float = 0.50,
    pan: float = 0.0,
) -> np.ndarray:
    """Render a fast, soft-edged rounded avionics beep/boop for warnings."""
    buf = np.zeros((total_samples, 2), dtype=np.float64)
    start_idx = max(0, int(round(start_sec * SAMPLE_RATE)))
    note_samples = min(total_samples - start_idx, int(round(dur_sec * SAMPLE_RATE)))
    if note_samples <= 0:
        return buf

    t = np.arange(note_samples, dtype=np.float64) / SAMPLE_RATE
    attack_sec = max(0.004, min(dur_sec * 0.35, attack_ms / 1000.0))
    release_sec = max(0.006, min(dur_sec * 0.45, release_ms / 1000.0))

    att = np.where(t < attack_sec, 0.5 * (1.0 - np.cos(math.pi * t / attack_sec)), 1.0)
    rel_start = max(attack_sec, dur_sec - release_sec)
    rel = np.where(
        t > rel_start,
        0.5 * (1.0 + np.cos(math.pi * (t - rel_start) / max(1e-6, dur_sec - rel_start))),
        1.0,
    )
    # Gentle 15% sustain droop keeps repetitive pulses musical
    sustain_taper = 1.0 - 0.15 * np.clip(t / max(1e-6, dur_sec), 0.0, 1.0)
    env = att * rel * sustain_taper

    pan_l = math.cos((pan + 1.0) * math.pi * 0.25)
    pan_r = math.sin((pan + 1.0) * math.pi * 0.25)

    for ch_idx, (detune, ch_gain) in enumerate(((-0.5 * stereo_detune_hz, pan_l), (0.5 * stereo_detune_hz, pan_r))):
        f1 = freq_hz + detune
        sig = (
            np.sin(2.0 * math.pi * f1 * t)
            + sub_octave * np.sin(2.0 * math.pi * (0.5 * f1) * t)
            + harm2 * np.sin(2.0 * math.pi * (2.0 * f1) * t)
        )
        buf[start_idx : start_idx + note_samples, ch_idx] = amp * ch_gain * env * sig

    return buf


def apply_cabin_acoustics(buf: np.ndarray, tail_fade_sec: float = 0.03) -> np.ndarray:
    """Add subtle cockpit early reflections (Haas warmth) and gentle fade-out."""
    out = buf.copy()
    n = out.shape[0]

    for delay_ms, gain in ((18.0, 0.10), (32.0, 0.06)):
        d = int(round((delay_ms / 1000.0) * SAMPLE_RATE))
        if d < n:
            out[d:, 0] += gain * buf[: n - d, 1]
            out[d:, 1] += gain * buf[: n - d, 0]

    fade_samples = min(n, int(round(tail_fade_sec * SAMPLE_RATE)))
    if fade_samples > 0:
        fade = 0.5 * (1.0 + np.cos(math.pi * np.arange(fade_samples) / fade_samples))
        out[-fade_samples:, 0] *= fade
        out[-fade_samples:, 1] *= fade

    return out


def normalize_headroom(buf: np.ndarray, target_peak: float = 0.56, target_rms_range=(0.06, 0.25)) -> np.ndarray:
    """Normalize buffer safely below 0 dBFS without clipping."""
    peak = float(np.max(np.abs(buf)))
    if peak <= 1e-9:
        return buf
    scaled = buf * (target_peak / peak)
    rms = float(np.sqrt(np.mean(scaled ** 2)))
    min_rms, max_rms = target_rms_range
    if rms > max_rms:
        scaled *= max_rms / rms
    elif rms < min_rms:
        boost = min(0.62 / float(np.max(np.abs(scaled))), min_rms / max(rms, 1e-9))
        scaled *= boost
    return np.clip(scaled, -0.65, 0.65)


def write_ogg(rel_path: str, stereo_buf: np.ndarray) -> None:
    """Write float64 stereo buffer [-1, 1] to 44.1 kHz stereo Ogg Vorbis."""
    out_path = SOUNDS_DIR / rel_path
    out_path.parent.mkdir(parents=True, exist_ok=True)

    pcm16 = np.clip(np.round(stereo_buf * 32767.0), -32767, 32767).astype("<i2")
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_wav = tmp.name

    try:
        with wave.open(tmp_wav, "wb") as wf:
            wf.setnchannels(2)
            wf.setsampwidth(2)
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(pcm16.tobytes())

        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-v",
                "error",
                "-i",
                tmp_wav,
                "-c:a",
                "libvorbis",
                "-ar",
                str(SAMPLE_RATE),
                "-ac",
                "2",
                "-q:a",
                "5",
                str(out_path),
            ],
            check=True,
        )
    finally:
        if os.path.exists(tmp_wav):
            os.remove(tmp_wav)


def build_all_chimes() -> dict:
    """Construct all 13 cockpit alert sounds across the 4 urgency tiers."""
    assets = {}

    # ------------------------------------------------------------------
    # TIER 1 — ALARMS (Sweeping / Whooping Sirens, warm & non-piercing)
    # ------------------------------------------------------------------

    # 1. Cockpit/Missile_Inbound.ogg (~1.65s): 3 urgent smooth rising "whoop-whoop-whoop" sweeps
    n = int(1.65 * SAMPLE_RATE)
    buf = np.zeros((n, 2), dtype=np.float64)
    for t0, pan in ((0.01, -0.06), (0.49, 0.06), (0.97, 0.0)):
        buf += synth_whoop_sweep(n, t0, 0.36, 340.0, 720.0, amp=1.0, attack_ms=12.0, release_ms=22.0, sub_octave=0.14, harm2=0.16, pan=pan)
    assets["Cockpit/Missile_Inbound.ogg"] = normalize_headroom(apply_cabin_acoustics(buf), target_peak=0.58)

    # 2. Cockpit/danger_siren.ogg (~2.00s): 2 continuous smooth rise-and-fall warm siren cycles
    n = int(2.00 * SAMPLE_RATE)
    buf = np.zeros((n, 2), dtype=np.float64)
    for t0, pan in ((0.02, -0.05), (0.96, 0.05)):
        buf += synth_whoop_sweep(n, t0, 0.90, 320.0, 640.0, f_end=320.0, amp=1.0, attack_ms=18.0, release_ms=26.0, sub_octave=0.16, harm2=0.16, pan=pan)
    assets["Cockpit/danger_siren.ogg"] = normalize_headroom(apply_cabin_acoustics(buf), target_peak=0.57)

    # 3. alarm_emer.ogg (~1.50s): 2 urgent warm upward thermal-emergency sweeps
    n = int(1.50 * SAMPLE_RATE)
    buf = np.zeros((n, 2), dtype=np.float64)
    for t0, pan in ((0.01, -0.06), (0.68, 0.06)):
        buf += synth_whoop_sweep(n, t0, 0.56, 380.0, 760.0, amp=1.0, attack_ms=12.0, release_ms=24.0, sub_octave=0.14, harm2=0.16, pan=pan)
    assets["alarm_emer.ogg"] = normalize_headroom(apply_cabin_acoustics(buf), target_peak=0.58)

    # 4. alarm_descent.ogg (~1.45s): 2 GPWS-style warm rising "whoop-whoop" pull-up sweeps
    n = int(1.45 * SAMPLE_RATE)
    buf = np.zeros((n, 2), dtype=np.float64)
    for t0, pan in ((0.01, -0.05), (0.64, 0.05)):
        buf += synth_whoop_sweep(n, t0, 0.54, 350.0, 690.0, amp=1.0, attack_ms=12.0, release_ms=24.0, sub_octave=0.16, harm2=0.15, pan=pan)
    assets["alarm_descent.ogg"] = normalize_headroom(apply_cabin_acoustics(buf), target_peak=0.57)

    # 5. alarm_generic1.ogg (~1.50s): 2 deeper resonant pressure-alarm sweeps
    n = int(1.50 * SAMPLE_RATE)
    buf = np.zeros((n, 2), dtype=np.float64)
    for t0, pan in ((0.02, -0.04), (0.72, 0.04)):
        buf += synth_whoop_sweep(n, t0, 0.64, 240.0, 480.0, f_end=260.0, amp=1.0, attack_ms=15.0, release_ms=26.0, sub_octave=0.18, harm2=0.16, pan=pan)
    assets["alarm_generic1.ogg"] = normalize_headroom(apply_cabin_acoustics(buf), target_peak=0.56)

    # ------------------------------------------------------------------
    # TIER 2 — WARNINGS (Fast Repetitive Rounded Beeps / Boops)
    # ------------------------------------------------------------------

    # 6. warning.ogg (~1.25s): 4 fast rounded warm boops (600 Hz, ~0.14s on / 0.10s off)
    n = int(1.25 * SAMPLE_RATE)
    buf = np.zeros((n, 2), dtype=np.float64)
    for idx in range(4):
        buf += synth_rounded_boop(n, 0.02 + idx * 0.24, 600.0, 0.14, amp=1.0, attack_ms=8.0, release_ms=14.0, pan=(-0.05 if idx % 2 == 0 else 0.05))
    assets["warning.ogg"] = normalize_headroom(apply_cabin_acoustics(buf), target_peak=0.56)

    # 7. Cockpit/Missile_lock.ogg (~0.65s): 4 rapid soft avionics beeps (740 Hz, ~0.075s on / 0.065s off)
    n = int(0.65 * SAMPLE_RATE)
    buf = np.zeros((n, 2), dtype=np.float64)
    for idx in range(4):
        buf += synth_rounded_boop(n, 0.01 + idx * 0.14, 740.0, 0.075, amp=1.0, attack_ms=6.0, release_ms=10.0, pan=(-0.04 if idx % 2 == 0 else 0.04))
    assets["Cockpit/Missile_lock.ogg"] = normalize_headroom(apply_cabin_acoustics(buf, tail_fade_sec=0.02), target_peak=0.55)

    # 8. impact_chime.ogg (~1.15s): 4 fast rounded low-mid boops (480 Hz, ~0.12s on / 0.09s off)
    n = int(1.15 * SAMPLE_RATE)
    buf = np.zeros((n, 2), dtype=np.float64)
    for idx in range(4):
        buf += synth_rounded_boop(n, 0.02 + idx * 0.21, 480.0, 0.12, amp=1.0, attack_ms=8.0, release_ms=14.0, pan=(-0.05 if idx % 2 == 0 else 0.05))
    assets["impact_chime.ogg"] = normalize_headroom(apply_cabin_acoustics(buf), target_peak=0.56)

    # 9. weather_windshear.ogg (~1.35s): 4 fast alternating warm boops (620 <-> 490 Hz)
    n = int(1.35 * SAMPLE_RATE)
    buf = np.zeros((n, 2), dtype=np.float64)
    for idx, freq in enumerate((620.0, 490.0, 620.0, 490.0)):
        buf += synth_rounded_boop(n, 0.02 + idx * 0.26, freq, 0.16, amp=1.0, attack_ms=8.0, release_ms=16.0, pan=(-0.06 if idx % 2 == 0 else 0.06))
    assets["weather_windshear.ogg"] = normalize_headroom(apply_cabin_acoustics(buf), target_peak=0.56)

    # ------------------------------------------------------------------
    # TIER 3 — NOTIFICATIONS / AWARENESS (Aircraft "Bing-Bong" Chimes)
    # ------------------------------------------------------------------

    # 10. fuel_low.ogg (~1.10s): Soft cabin "bing-bong" (F5 -> D5)
    n = int(1.10 * SAMPLE_RATE)
    buf = synth_bell_note(n, 0.01, 698.46, 0.45, amp=0.88, attack_ms=14.0, decay_tau=0.18, sub_octave=0.20, harm2=0.16, shimmer=0.03, pan=-0.06)
    buf += synth_bell_note(n, 0.25, 587.33, 0.82, amp=0.98, attack_ms=15.0, decay_tau=0.30, sub_octave=0.22, harm2=0.15, shimmer=0.03, pan=0.06)
    assets["fuel_low.ogg"] = normalize_headroom(apply_cabin_acoustics(buf), target_peak=0.54)

    # 11. weather_advisory.ogg (~1.15s): Classic aircraft cabin "bing-bong" (A4 -> F4)
    n = int(1.15 * SAMPLE_RATE)
    buf = synth_bell_note(n, 0.01, 440.00, 0.48, amp=0.90, attack_ms=14.0, decay_tau=0.21, sub_octave=0.20, harm2=0.18, shimmer=0.04, pan=-0.06)
    buf += synth_bell_note(n, 0.25, 349.23, 0.88, amp=1.00, attack_ms=14.0, decay_tau=0.33, sub_octave=0.22, harm2=0.16, shimmer=0.04, pan=0.06)
    assets["weather_advisory.ogg"] = normalize_headroom(apply_cabin_acoustics(buf), target_peak=0.53)

    # 12. weather_turbulence.ogg (~1.15s): Warm low-mid "bing-bong" (G4 -> D4)
    n = int(1.15 * SAMPLE_RATE)
    buf = synth_bell_note(n, 0.01, 392.00, 0.46, amp=0.92, attack_ms=13.0, decay_tau=0.20, sub_octave=0.22, harm2=0.18, shimmer=0.04, pan=-0.07)
    buf += synth_bell_note(n, 0.24, 293.66, 0.89, amp=1.00, attack_ms=13.0, decay_tau=0.34, sub_octave=0.24, harm2=0.16, shimmer=0.04, pan=0.07)
    assets["weather_turbulence.ogg"] = normalize_headroom(apply_cabin_acoustics(buf), target_peak=0.55)

    # ------------------------------------------------------------------
    # TIER 4 — INFORMATIONAL (Single Warm "Ding")
    # ------------------------------------------------------------------

    # 13. notify_beep.ogg (~0.45s): Clean single warm cabin "ding" (A5 + A4 body)
    n = int(0.45 * SAMPLE_RATE)
    buf = synth_bell_note(n, 0.006, 440.00, 0.43, amp=0.65, attack_ms=8.0, decay_tau=0.17, sub_octave=0.14, harm2=0.14, shimmer=0.02, pan=-0.03)
    buf += synth_bell_note(n, 0.006, 880.00, 0.41, amp=0.82, attack_ms=8.0, decay_tau=0.15, sub_octave=0.08, harm2=0.10, shimmer=0.0, pan=0.03)
    assets["notify_beep.ogg"] = normalize_headroom(apply_cabin_acoustics(buf, tail_fade_sec=0.03), target_peak=0.54)

    return assets


def main() -> None:
    assets = build_all_chimes()
    for rel_path, buf in assets.items():
        write_ogg(rel_path, buf)
        print(f"Generated {rel_path}")


if __name__ == "__main__":
    main()

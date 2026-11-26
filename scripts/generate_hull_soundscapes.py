#!/usr/bin/env python3
"""Synthesize situational hull, weather, ring-debris, and hangar audio assets.

Outputs 44.1 kHz stereo Ogg Vorbis files into data/sounds/Hull/:
  - hull_rain_canopy.ogg     (loopable: raindrops pelting cockpit canopy/hull)
  - hull_sand_ash.ogg        (loopable: fine mineral sand/ash grains pelting hull)
  - hull_reentry_roar.ogg    (loopable: deep plasma & airframe atmospheric entry roar)
  - hull_ring_debris.ogg     (loopable: sparse crystalline ice & micro-gravel hull pings)
  - hull_creak_stress.ogg    (one-shot: low metallic structural groan under high-G / heat)
  - hangar_hydraulics.ogg    (one-shot: heavy mechanical elevator hydraulics & lock clunk)
"""

from pathlib import Path
import subprocess
import tempfile
import wave
import numpy as np

SAMPLE_RATE = 44100
REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / "data" / "sounds" / "Hull"


def write_ogg_stereo(buf: np.ndarray, out_path: Path) -> None:
    buf = np.clip(buf, -0.98, 0.98)
    pcm = (buf * 32767.0).astype(np.int16)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as tmp:
        with wave.open(tmp.name, "wb") as wf:
            wf.setnchannels(2)
            wf.setsampwidth(2)
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(pcm.tobytes())
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-loglevel",
                "error",
                "-i",
                tmp.name,
                "-ar",
                str(SAMPLE_RATE),
                "-ac",
                "2",
                "-c:a",
                "libvorbis",
                "-q:a",
                "5",
                str(out_path),
            ],
            check=True,
        )


def loop_crossfade(buf: np.ndarray, fade_sec: float = 0.25) -> np.ndarray:
    """Wrap-crossfade tail into head for click-free seamless looping."""
    n = int(round(fade_sec * SAMPLE_RATE))
    if n <= 0 or n * 2 >= len(buf):
        return buf
    w = np.linspace(0.0, 1.0, n)[:, None]
    out = buf.copy()
    out[:n] = buf[:n] * w + buf[-n:] * (1.0 - w)
    return out[:-n]


def synth_rain_canopy(rng: np.random.Generator) -> np.ndarray:
    """Synthesize heavy non-tonal rain thrashing on a metal hull / tin roof."""
    dur = 4.25
    n = int(round(dur * SAMPLE_RATE))
    fade_sec = 0.25
    loop_dur = dur - fade_sec
    buf = np.zeros((n, 2), dtype=np.float64)

    # 1. Heavy broadband rain-on-metal wash bed (no narrow resonant peaks)
    noise = rng.normal(0.0, 1.0, size=(n, 2))
    freqs = np.fft.rfftfreq(n, 1.0 / SAMPLE_RATE)
    # Warm tin-roof spectrum: low-mid sheet thrum (180-450 Hz) + dense broadband patter (600-5200 Hz)
    low_body = 0.42 * np.exp(-0.5 * ((freqs - 310.0) / 170.0) ** 2)
    mid_sheet = 0.95 * np.exp(-0.5 * ((freqs - 1550.0) / 1250.0) ** 2)
    hi_spray = 0.48 * np.exp(-0.5 * ((freqs - 4200.0) / 1800.0) ** 2)
    bp = (low_body + mid_sheet + hi_spray) * (freqs > 110.0)
    bed = np.fft.irfft(np.fft.rfft(noise, axis=0) * bp[:, None], n=n, axis=0)
    bed /= max(1e-6, np.max(np.abs(bed)))

    # Subtle periodic wind-driven rain-sheet swell
    t_bed = np.arange(n) / SAMPLE_RATE
    swell = 0.84 + 0.16 * np.sin(2.0 * np.pi * (t_bed / loop_dur) * 2.0 + 0.4) * np.cos(
        2.0 * np.pi * (t_bed / loop_dur) * 1.0
    )
    buf += 0.34 * bed * swell[:, None]

    # 2. Dense non-tonal percussive raindrop impacts (filtered noise bursts — zero sine waves)
    def shape_burst(raw: np.ndarray, lp_alpha: float, hp_alpha: float) -> np.ndarray:
        # 1-pole high-pass followed by 1-pole low-pass for dry broadband impact transients
        y_hp = np.empty_like(raw)
        prev_x = 0.0
        prev_y = 0.0
        for i in range(len(raw)):
            x = raw[i]
            prev_y = hp_alpha * (prev_y + x - prev_x)
            prev_x = x
            y_hp[i] = prev_y
        y_lp = np.empty_like(y_hp)
        acc = 0.0
        for i in range(len(y_hp)):
            acc += lp_alpha * (y_hp[i] - acc)
            y_lp[i] = acc
        return y_lp

    num_drops = 1400
    for _ in range(num_drops):
        start = int(rng.integers(0, n - 320))
        dlen = int(rng.integers(56, 240))
        t = np.arange(dlen) / SAMPLE_RATE
        tau = rng.uniform(0.0007, 0.0028)
        env = (1.0 - np.exp(-t / 0.00018)) * np.exp(-t / tau)
        raw = rng.normal(0.0, 1.0, size=dlen)
        if rng.random() < 0.28:
            # Heavier alloy-panel thud
            burst = shape_burst(raw, lp_alpha=rng.uniform(0.08, 0.18), hp_alpha=0.95)
            amp = rng.uniform(0.08, 0.24)
        else:
            # Crisp high-mid canopy patter
            burst = shape_burst(raw, lp_alpha=rng.uniform(0.28, 0.62), hp_alpha=rng.uniform(0.76, 0.88))
            amp = rng.uniform(0.05, 0.18)
        burst /= max(1e-6, np.max(np.abs(burst)))
        hit = env * burst
        pan = rng.uniform(-0.88, 0.88)
        g_l = amp * np.cos((pan + 1.0) * np.pi * 0.25)
        g_r = amp * np.sin((pan + 1.0) * np.pi * 0.25)
        buf[start : start + dlen, 0] += g_l * hit
        buf[start : start + dlen, 1] += g_r * hit

    buf = loop_crossfade(buf, fade_sec)
    buf /= max(1.0, np.max(np.abs(buf)) / 0.78)
    return buf


def synth_sand_ash(rng: np.random.Generator) -> np.ndarray:
    dur = 4.25
    n = int(round(dur * SAMPLE_RATE))
    buf = np.zeros((n, 2), dtype=np.float64)

    # Dry broadband grit hiss
    noise = rng.normal(0.0, 1.0, size=(n, 2))
    freqs = np.fft.rfftfreq(n, 1.0 / SAMPLE_RATE)
    bp = np.exp(-0.5 * ((freqs - 3200.0) / 1800.0) ** 2) * (freqs > 600.0)
    bed = np.fft.irfft(np.fft.rfft(noise, axis=0) * bp[:, None], n=n, axis=0)
    bed /= max(1e-6, np.max(np.abs(bed)))
    buf += 0.16 * bed

    # Sharp dry mineral grain ticks against alloy plating
    for _ in range(380):
        start = int(rng.integers(0, n - 800))
        dlen = int(rng.integers(180, 520))
        t = np.arange(dlen) / SAMPLE_RATE
        f0 = rng.uniform(2100.0, 6200.0)
        tau = rng.uniform(0.0018, 0.0055)
        tick = np.exp(-t / tau) * (0.65 * np.sin(2.0 * np.pi * f0 * t) + 0.35 * rng.normal(0.0, 1.0, dlen))
        pan = rng.uniform(-0.9, 0.9)
        amp = rng.uniform(0.05, 0.20)
        buf[start : start + dlen, 0] += amp * np.cos((pan + 1.0) * np.pi * 0.25) * tick
        buf[start : start + dlen, 1] += amp * np.sin((pan + 1.0) * np.pi * 0.25) * tick

    buf = loop_crossfade(buf, 0.25)
    buf /= max(1.0, np.max(np.abs(buf)) / 0.70)
    return buf


def synth_reentry_roar(rng: np.random.Generator) -> np.ndarray:
    dur = 4.30
    n = int(round(dur * SAMPLE_RATE))
    noise = rng.normal(0.0, 1.0, size=(n, 2))
    freqs = np.fft.rfftfreq(n, 1.0 / SAMPLE_RATE)

    # Low aerodynamic hull rumble + mid plasma crackle
    low_shape = np.exp(-0.5 * ((freqs - 95.0) / 70.0) ** 2) * (freqs > 24.0)
    mid_shape = 0.35 * np.exp(-0.5 * ((freqs - 420.0) / 260.0) ** 2)
    spec = np.fft.rfft(noise, axis=0) * (low_shape + mid_shape)[:, None]
    roar = np.fft.irfft(spec, n=n, axis=0)

    # Slow buffeting amplitude modulation (periodic over loop length)
    t = np.arange(n) / SAMPLE_RATE
    loop_dur = dur - 0.30
    mod = 0.78 + 0.22 * np.sin(2.0 * np.pi * (t / loop_dur) * 3.0) * np.cos(2.0 * np.pi * (t / loop_dur) * 2.0)
    roar *= mod[:, None]
    roar = loop_crossfade(roar, 0.30)
    roar /= max(1e-6, np.max(np.abs(roar)) / 0.78)
    return roar


def synth_ring_debris(rng: np.random.Generator) -> np.ndarray:
    dur = 5.25
    n = int(round(dur * SAMPLE_RATE))
    buf = np.zeros((n, 2), dtype=np.float64)

    # Sparse crystalline ice/pebble hull pings
    for _ in range(52):
        start = int(rng.integers(0, n - 4500))
        dlen = int(rng.integers(900, 3200))
        t = np.arange(dlen) / SAMPLE_RATE
        f0 = rng.uniform(1100.0, 4200.0)
        tau = rng.uniform(0.008, 0.028)
        ping = (1.0 - np.exp(-t / 0.0006)) * np.exp(-t / tau) * (
            np.sin(2.0 * np.pi * f0 * t)
            + 0.4 * np.sin(2.0 * np.pi * f0 * 2.13 * t)
            + 0.2 * np.sin(2.0 * np.pi * (f0 * 0.48) * t)
        )
        pan = rng.uniform(-0.95, 0.95)
        amp = rng.uniform(0.08, 0.28)
        buf[start : start + dlen, 0] += amp * np.cos((pan + 1.0) * np.pi * 0.25) * ping
        buf[start : start + dlen, 1] += amp * np.sin((pan + 1.0) * np.pi * 0.25) * ping

    buf = loop_crossfade(buf, 0.25)
    buf /= max(1.0, np.max(np.abs(buf)) / 0.65)
    return buf


def synth_creak_stress(rng: np.random.Generator) -> np.ndarray:
    dur = 1.65
    n = int(round(dur * SAMPLE_RATE))
    t = np.arange(n) / SAMPLE_RATE

    # Low metallic bulkheads groaning with stick-slip pitch bend
    f_bend = 68.0 + 18.0 * np.sin(2.0 * np.pi * 1.4 * t) - 14.0 * (t / dur)
    phase = 2.0 * np.pi * np.cumsum(f_bend) / SAMPLE_RATE
    env = np.sin(np.pi * np.clip(t / dur, 0.0, 1.0)) ** 1.3
    groan = env * (
        0.55 * np.sin(phase)
        + 0.30 * np.sin(phase * 1.98)
        + 0.18 * np.sin(phase * 3.04)
    )
    # Subtle stick-slip impulse grain
    slip = rng.normal(0.0, 0.06, size=n) * env * (0.5 + 0.5 * np.sin(2.0 * np.pi * 16.0 * t))
    sig_l = groan + slip
    sig_r = groan * 0.95 - slip * 0.85
    out = np.stack([sig_l, sig_r], axis=-1)
    out /= max(1e-6, np.max(np.abs(out)) / 0.68)
    return out


def synth_hangar_hydraulics(rng: np.random.Generator) -> np.ndarray:
    dur = 1.90
    n = int(round(dur * SAMPLE_RATE))
    t = np.arange(n) / SAMPLE_RATE

    # Heavy hydraulic servo whine + fluid hiss + final mechanical clamp thud
    servo_freq = 145.0 + 35.0 * np.sin(np.pi * t / dur)
    servo_phase = 2.0 * np.pi * np.cumsum(servo_freq) / SAMPLE_RATE
    servo_env = np.clip(t / 0.15, 0.0, 1.0) * np.clip((1.55 - t) / 0.25, 0.0, 1.0)
    servo = servo_env * (0.45 * np.sin(servo_phase) + 0.22 * np.sin(servo_phase * 2.0) + 0.12 * np.sin(servo_phase * 3.0))

    noise = rng.normal(0.0, 1.0, size=(n, 2))
    freqs = np.fft.rfftfreq(n, 1.0 / SAMPLE_RATE)
    hp_bp = np.exp(-0.5 * ((freqs - 900.0) / 550.0) ** 2)
    hiss = np.fft.irfft(np.fft.rfft(noise, axis=0) * hp_bp[:, None], n=n, axis=0)
    hiss /= max(1e-6, np.max(np.abs(hiss)))
    hiss *= servo_env[:, None] * 0.28

    # Mechanical lock clunk at t = 1.48s
    clunk_idx = int(1.48 * SAMPLE_RATE)
    clunk_len = min(n - clunk_idx, int(0.38 * SAMPLE_RATE))
    tc = np.arange(clunk_len) / SAMPLE_RATE
    clunk = np.exp(-tc / 0.055) * (0.75 * np.sin(2.0 * np.pi * 82.0 * tc) + 0.35 * np.sin(2.0 * np.pi * 165.0 * tc))

    out = hiss + np.stack([servo, servo * 0.96], axis=-1)
    out[clunk_idx : clunk_idx + clunk_len, 0] += 0.65 * clunk
    out[clunk_idx : clunk_idx + clunk_len, 1] += 0.65 * clunk
    out /= max(1e-6, np.max(np.abs(out)) / 0.78)
    return out


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(20261125)

    assets = {
        "hull_rain_canopy.ogg": synth_rain_canopy(rng),
        "hull_sand_ash.ogg": synth_sand_ash(rng),
        "hull_reentry_roar.ogg": synth_reentry_roar(rng),
        "hull_ring_debris.ogg": synth_ring_debris(rng),
        "hull_creak_stress.ogg": synth_creak_stress(rng),
        "hangar_hydraulics.ogg": synth_hangar_hydraulics(rng),
    }

    for fname, buf in assets.items():
        out_path = OUT_DIR / fname
        write_ogg_stereo(buf, out_path)
        print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()

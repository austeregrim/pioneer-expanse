#!/usr/bin/env python3
"""Generate Cockpit AI Voice advisory clips ("Aria" — calm, slightly sultry US female).

Synthesizes neural speech via edge-tts (en-US-AvaNeural with subtle calm/warm
rate and pitch tuning) and applies gentle studio proximity EQ + compression +
loudnorm via ffmpeg, exporting 44.1 kHz mono Ogg Vorbis files into:
  data/sounds/Voice/aria/voice_aria_<id>.ogg
"""

from pathlib import Path
import subprocess
import tempfile

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / "data" / "sounds" / "Voice" / "aria"

VOICE_NAME = "en-US-AvaNeural"
VOICE_RATE = "-7%"
VOICE_PITCH = "-4Hz"

PHRASES = {
    "fsd_charging": "Frame Shift Drive charging.",
    "fsd_engaged": "Supercruise engaged.",
    "fsd_disengaged": "Supercruise disengaged.",
    "fsd_emergency_drop": "Warning. Emergency drop initiated.",
    "hyperspace_charging": "Hyperspace conduit charging.",
    "interdiction_detected": "Warning. Interdiction tether detected. Align with escape vector.",
    "interdiction_evaded": "Interdiction evaded.",
    "temp_critical": "Warning. Hull temperature critical.",
    "fuel_low": "Caution. Fuel reserves low.",
    "shields_offline": "Warning. Shields offline.",
    "shields_online": "Shields online.",
    "missile_inbound": "Warning. Incoming missile detected.",
    "wind_shear": "Caution. Severe wind shear ahead.",
    "turbulence": "Caution. Entering severe atmospheric turbulence.",
    "storm_advisory": "Advisory. Severe storm front ahead.",
    "docking_granted": "Docking clearance granted.",
    "landing_gear_down": "Landing gear deployed.",
    "landing_gear_up": "Landing gear retracted.",
}

AUDIO_FILTER = (
    "highpass=f=85,"
    "equalizer=f=185:t=q:w=1.2:g=2.2,"
    "equalizer=f=3200:t=q:w=1.5:g=-1.5,"
    "highshelf=f=8000:g=1.5,"
    "acompressor=threshold=-18dB:ratio=2.5:attack=10:release=120,"
    "loudnorm=I=-16:TP=-1.5:LRA=7"
)


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        for clip_id, text in PHRASES.items():
            mp3_path = tmp / f"{clip_id}.mp3"
            ogg_path = OUT_DIR / f"voice_aria_{clip_id}.ogg"
            print(f"Synthesizing {clip_id}: {text!r}")
            subprocess.run(
                [
                    "uvx",
                    "--from",
                    "edge-tts",
                    "edge-tts",
                    "--voice",
                    VOICE_NAME,
                    f"--rate={VOICE_RATE}",
                    f"--pitch={VOICE_PITCH}",
                    "--text",
                    text,
                    "--write-media",
                    str(mp3_path),
                ],
                check=True,
            )
            subprocess.run(
                [
                    "ffmpeg",
                    "-y",
                    "-loglevel",
                    "error",
                    "-i",
                    str(mp3_path),
                    "-af",
                    AUDIO_FILTER,
                    "-ar",
                    "44100",
                    "-ac",
                    "1",
                    "-c:a",
                    "libvorbis",
                    "-q:a",
                    "5",
                    str(ogg_path),
                ],
                check=True,
            )
    print(f"Generated {len(PHRASES)} voice clips in {OUT_DIR}")


if __name__ == "__main__":
    main()

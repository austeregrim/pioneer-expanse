# Pioneer: Dangerous — Agent Guidelines & Project Context

Welcome to the **Pioneer: Dangerous** workspace. This repository is an independent single-player fork of the open-source space simulation game **Pioneer** (`pioneerspacesim/pioneer`), modified to incorporate core gameplay mechanics and design philosophies inspired by *Elite Dangerous*.

---

## 1. Project Master Plan & Roadmap

The authoritative implementation roadmap is maintained in [`PIONEER_DANGEROUS_PLAN.md`](./PIONEER_DANGEROUS_PLAN.md).
Always consult this plan when implementing features across any phase:
* **Phase 1: Dev Environment & Native Build** — Completed.
* **Phase 2: Navigation & Map Quality of Life (QoL)** — Direct list targeting, station filters, cross-system destination retention.
* **Phase 3: Mission Overhaul & Aesthetic Polish** — Removal of joke missions, rebalancing mission payouts for real time, corporate/faction insignias replacing composite facegen, station "Pass Time" service.
* **Phase 4: Macro Galactic View** — 3D Milky Way disk/spiral arms overview with "You Are Here" indicator.
* **Phase 5: In-System FTL Supercruise Flight Mechanics** — Elite-style Supercruise mode ($30\text{ km/s}$ to $2,001c$), mass lock/drag, safe disengage dropout.

---

## 2. Core Architectural Directives

1. **Independent Fork Policy**:
   * Upstream Pioneer does not accept AI-generated code.
   * All development here is for a standalone offline single-player fork.
   * Remote `upstream` points to `https://github.com/pioneerspacesim/pioneer.git` for manual downstream merges only.
2. **Time Model (1:1 Real-Time & Offline Preservation)**:
   * During active gameplay, time progresses 1:1 real-time. In-flight time compression buttons are replaced by Supercruise throttle.
   * Game time freezes when the game is closed. Missions with deadlines specify actual gameplay hours; players never fail missions offline.
   * Station-docked time advancement ("Wait / Pass Time") is provided for missions requiring scheduled rendezvous.
3. **Aesthetics & Tone**:
   * Tone is serious space exploration, commercial trading, and tactical combat.
   * No procedural composite faces (`facegen`). Use clean faction emblems (Federation, Empire, Alliance, Independents), corporate logos, and starport seals.

---

## 3. Build & Development Instructions

* **Build System**: CMake + Ninja.
* **Dependencies**: Native Linux packages (`libsdl2-dev`, `libglew-dev`, `libassimp-dev`, `libvorbis-dev`, `libsigc++-2.0-dev`, `libfreetype-dev`, `libopenal-dev`, `ninja-build`).
* **Compile Game & Asset Data**:
  ```bash
  cmake --build build --target pioneer build-data -j 8
  ```
* **Run Unit Tests**:
  ```bash
  cmake --build build --target unittest && ./build/unittest
  ```
* **Run Game on Dedicated GPU (NVIDIA MX450)**:
  ```bash
  __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only ./build/pioneer
  ```

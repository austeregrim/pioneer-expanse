# Pioneer: Dangerous — Agent Guidelines & Project Context

Welcome to the **Pioneer: Dangerous** workspace. This repository is an independent single-player fork of the open-source space simulation game **Pioneer** (`pioneerspacesim/pioneer`), modified to incorporate core gameplay mechanics and design philosophies inspired by *Elite Dangerous*.

---

## 1. Project Master Plan & Roadmap

The authoritative implementation roadmap is maintained in [`PIONEER_DANGEROUS_PLAN.md`](./PIONEER_DANGEROUS_PLAN.md).
Always consult this plan when implementing features across any phase:
* **Phase 1: Dev Environment & Native Build** — Completed.
* **Phase 2: UI Density, Aesthetic Polish, Content Curation & Start Profiles** — Completed (`1920x1080` UI scale baseline, tighter typography/padding, procedural `facegen` and sliders replaced with non-customizable corporate/faction/authority SVG logos, Allegiance + Career Role new game starts, joke modules removed).
* **Phase 3: Navigation & Map Quality of Life (QoL)** — Next Up (direct list targeting, station filters, cross-system destination retention across hyperspace jumps).
* **Phase 4: Macro Galactic View** — Completed (Continuous 3D zoom out to $100,000\text{ ly}$ Milky Way disc + 3D volumetric star cloud/core glow, polar coordinate grid rings, sharp Voronoi faction boundaries, interactive raycast panning, and contextual adaptive faction dossier sidebar).
* **Phase 5: In-System FTL Supercruise Flight Mechanics** — Elite-style Supercruise mode ($30\text{ km/s}$ to $2,001c$), mass lock/drag, safe disengage dropout.
* **Phase 6: Real-Time Mission Economy & Station "Pass Time" Service** — Rebalance mission deadlines/payouts for Supercruise real-time play, station "Pass Time" service.

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
   * Procedural composite faces (`facegen`) and `<< >>` face sliders are disabled. Contact/character boxes render non-customizable high-resolution SVG corporate logos, faction crests, authority badges, and syndicate insignias (`data/icons/logos/`) with an organization header and Name/Title banner.

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

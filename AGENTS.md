# Pioneer: Expanse — Agent Guidelines & Project Context

Welcome to the **Pioneer: Expanse** workspace. This repository is an independent single-player fork of the open-source space simulation game **Pioneer** (`pioneerspacesim/pioneer`), modified to incorporate core gameplay mechanics and design philosophies inspired by *Elite Dangerous*.

---

## 1. Project Master Plan & Roadmap

The implementation plans and long-term roadmap are maintained in the [`plans/`](./plans/) directory:
* [`plans/01_EXPANSE_LONG_TERM_ROADMAP.md`](./plans/01_EXPANSE_LONG_TERM_ROADMAP.md): High-level architectural roadmap linking core foundation plans (`02`–`04`) and lettered expansion pillar plans (`A`–`J`).
* [`plans/02_PIONEER_EXPANSE_FOUNDATION_PLAN.md`](./plans/02_PIONEER_EXPANSE_FOUNDATION_PLAN.md): Core foundational implementation roadmap (**Completed** — Phases 1–8 including Cross-System Target Memory & F2 targeting).
* [`plans/03_VOLUMETRIC_RINGS_AND_MINING_PLAN.md`](./plans/03_VOLUMETRIC_RINGS_AND_MINING_PLAN.md): Volumetric planetary rings, 3-tier LOD asteroid field, and ring mining (**Completed**).
* [`plans/04_NPC_SUPERCRUISE_INTERDICTION_PLAN.md`](./plans/04_NPC_SUPERCRUISE_INTERDICTION_PLAN.md): Living NPC Supercruise traffic, sensors, and FSD interdiction mechanics (**Completed**).
* [`plans/A_PLAN_MULTI_SHIP_AND_CREW_AUTONOMY.md`](./plans/A_PLAN_MULTI_SHIP_AND_CREW_AUTONOMY.md): Multi-ship ownership, station hangars, Resident Station Storage, docked module transfer, NPC Captains, and X4-style autonomous fleet operations (**Completed**).
* [`plans/I_PLAN_TRANSPONDER_AND_STEALTH.md`](./plans/I_PLAN_TRANSPONDER_AND_STEALTH.md): Transponder on/off, dark running `< 1c`, persistent locks, police witness FOV + occlusion, bounty licences, Warrant Scanner, and sub-light sensors (**Completed**).
* [`plans/E_PLAN_GRAPHICS_AUDIO_OVERHAUL.md`](./plans/E_PLAN_GRAPHICS_AUDIO_OVERHAUL.md): PBR, Low–Extreme quality presets, flares, plumes, gas giants, clouds, water, chemistry/weather Rayleigh/Mie, galactic skybox, volcanic lava/plumes, bump-mapped 3D surface scatter & ring boulders, dwarf planets, 20m tri-planar terrain, 3D weather/lightning, 4-tier chimes, hull/weather soundscapes, OpenAL EFX vacuum low-pass & Aria Cockpit AI voice (**M1–7 Completed**; M8 3D Cockpits asset-gated).
* [`plans/J_PLAN_MILITARY_FRONTLINE_AND_DEPUTY.md`](./plans/J_PLAN_MILITARY_FRONTLINE_AND_DEPUTY.md): Military enlistment, non-combat frontline support, fleet support, optional combat zones, and Faction Deputy Charter (**Next Up**).
* `plans/B`–`D`, `F`–`H`: Engineering (`C`), Manufacturers/Combat (`F` — dealerships done, turrets/slots queued without `SYS/ENG/WEP` pips), Exploration/Aliens (`G` — Cartography/Discovery Scanner done, FSS/DSS/Evacs queued), SRVs (`B`), Infiltration (`D`), and Capital Ships/Station Building (`H`).

Always consult these plans when implementing features across any phase:
* **Phase 1: Dev Environment & Native Build** — Completed.
* **Phase 2: UI Density, Aesthetic Polish, Content Curation & Start Profiles** — Completed (`1920x1080` UI scale baseline, tighter typography/padding, procedural `facegen` and sliders replaced with non-customizable corporate/faction/authority SVG logos, Allegiance + Career Role new game starts, joke modules removed).
* **Phase 3: Navigation & Map Quality of Life (QoL)** — Completed (filters, Show All Ships, RMB panning, bookmarks, F2 `infoView` Set/Queue Target button, and Cross-System Target Memory via `CrossSystemNav.lua`).
* **Phase 4: Macro Galactic View** — Completed (Continuous 3D zoom out to $100,000\text{ ly}$ Milky Way disc + 3D volumetric star cloud/core glow, polar coordinate grid rings, sharp Voronoi faction boundaries, interactive raycast panning, and contextual adaptive faction dossier sidebar).
* **Phase 5: In-System FTL Supercruise Flight Mechanics** — Completed (*Elite Dangerous*-style Supercruise mode from $30\text{ km/s}$ to $2,001c$, 5s FSD charge-up, mass lock/gravity well drag, 75% blue-zone 6-second rule, exclusion zone emergency dropout with shield overload & heat spike, safe disengage orbital/surface drop-ins, Autopilot Mk 2–4, 3D orbital/exclusion rings, and 1:1 real-time flight clock enforcement).
* **Phase 6: Real-Time Mission Economy** — Completed (`MissionUtils` Supercruise travel times, shorter BBS deadlines & expiry cleanup; docked time dilation covers waiting).
* **Phase 7 & 8: NPC Supercruise, Interdiction, Crises, InterCast, ISX, Lottery, Taxes, Penal & SAR Rebuy** — Completed.

---

## 2. Core Architectural Directives

1. **Independent Fork Policy**:
   * Upstream Pioneer does not accept AI-generated code.
   * All development here is for a standalone offline single-player fork.
   * Remote `upstream` points to `https://github.com/pioneerspacesim/pioneer.git` for manual downstream merges only.
2. **Time Model (1:1 Real-Time & Offline Preservation)**:
   * During active gameplay, time progresses 1:1 real-time. In-flight time compression buttons are replaced by Supercruise throttle.
   * Game time freezes when the game is closed. Missions with deadlines specify actual gameplay hours; players never fail missions offline.
   * Standard time dilation remains available while docked at a starport for waiting on scheduled events or fleet transits.
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
* **Run Game**:
  ```bash
  ./build/pioneer
  ```
  *(Automatic dedicated GPU detection is built into the engine on Linux: NVIDIA Optimus and AMD PRIME hardware are automatically detected and used without requiring manual offload flags).*

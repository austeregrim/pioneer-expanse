[![Build](https://github.com/austeregrim/pioneer-expanse/actions/workflows/build-ci.yml/badge.svg)](https://github.com/austeregrim/pioneer-expanse/actions)
[![License GPLv3](https://img.shields.io/badge/license-GPL_v3-green.svg)](http://www.gnu.org/licenses/gpl-3.0.html)


# Pioneer: Expanse

<p align="center">
  <img src="data/icons/badge.png" alt="Pioneer: Expanse Badge" width="220" />
</p>

[![License GPLv3](https://img.shields.io/badge/license-GPL_v3-green.svg)](http://www.gnu.org/licenses/gpl-3.0.html)

**Pioneer: Expanse** is an independent single-player fork of the open-source space simulation game [Pioneer](https://github.com/pioneerspacesim/pioneer) (originally inspired by *Frontier: Elite II*).

This fork reimagines Pioneer with core flight mechanics, pacing, and visual systems inspired by *Elite: Dangerous*—replacing Newtonian time acceleration with real-time in-system **FTL Supercruise** flight, a multi-layered **Macro Galactic View** ($100,000\text{ ly}$ Milky Way disc and 3D faction territorial spheres), high-density cockpit and station UI scaling, corporate and faction SVG heraldry, dynamic crisis-driven galactic events (**InterCast News**), an interstellar equity exchange, and an emergency escape pod search-and-rescue rebuy loop.

---

## Key Features in Pioneer: Expanse

* **In-System FTL Supercruise (Frame Shift Drive)**:
  * Cruise within star systems seamlessly from $30\text{ km/s}$ ($0.0001c$) up to $2,001c$ in deep space.
  * Planetary and stellar gravity wells actively impose drag and throttle limits.
  * Authentic $75\%$ throttle "Blue Zone" dynamics and the 6-second approach rule ("loop of shame" avoidance).
  * Safe disengage dropouts at stations ($12\text{ km}$) and surface starports ($10\text{ km}$ altitude, $8\text{ km}$ standoff).
  * Dangerous exclusion zones with emergency dropouts, shield collapse, and severe heat spikes.
  * Supercruise Assist (Autopilot Mk 2) for automated target alignment, throttle lock, and safe drop.
* **1:1 Real-Time Flight Pacing & Offline Preservation**:
  * Flight simulation progresses in 1:1 real-time—no artificial time-acceleration warp buttons needed during flight.
  * The simulation clock freezes when the game is closed; missions with deadlines guarantee actual active gameplay hours.
  * Starport lounge services provide docked "Pass Time / Wait" capabilities for scheduled rendezvous.
* **Macro Galactic View**:
  * Smooth, continuous 3D camera zoom out to the entire $100,000\text{ ly}$ Milky Way disc without sector generation stalls.
  * 9-layer vertically stratified galactic disc with 45,000-particle volumetric star cloud and Sagittarius A* central bulge glow.
  * Galactic polar coordinate rings, Sol bubble distance markers, 3D Fresnel faction territorial spheres, Voronoi intersection boundaries, and interactive 3D raycast panning.
* **Living Galaxy & InterCast News**:
  * Hyperjumps trigger macro simulation ticks that drive dynamic crises (Frontline blockades, Humanitarian outbreaks, Market rushes, Political strikes) across populated systems.
  * 3D Sector Map tactical conflict overlay highlighting crisis systems.
  * In-flight sidebar ticker and station terminals broadcasting live Interstellar News dispatches.
* **Interstellar Stock Exchange (ISX) & Nav-Locus Sweepstakes**:
  * Trade shares in 8 megaconglomerates, 4 faction composite indices, and procedurally generated local starport ventures whose stock prices actively react to galactic crises.
  * High-stakes $90.7$-trillion-to-one astrolabe sweepstakes with compounding multi-billion credit jackpots.
* **Search & Rescue, Insurance Rebuy & Hardcore Mode**:
  * Fatal ship destruction triggers an emergency escape pod ejection sequence followed by a 14–28 day cryogenic stasis jump and medical recovery at the nearest starport.
  * Comprehensive Starport Insurance Terminal offering a 5% hull and module rebuy settlement (or starter loaner) with deep-space cargo flotsam coordinates.
  * Dedicated Hardcore Ironman charter mode with fatal permadeath.
* **Hyperdrive Auto-Feed & Dual-Tank Fuel Management**:
  * Hyperspace jumps automatically draw hydrogen from the main propellant tank into the hyperdrive reservoir, eliminating artificial single-jump fuel locks.
* **Curated Starts & Aesthetic Polish**:
  * Native $1920\times 1080$ UI density baseline, tightened typography, and streamlined window padding.
  * Procedural composite faces replaced with crisp SVG corporate logos, faction crests, authority seals, and syndicate insignias.
  * Allegiance + Career Role new game start profiles (Solar Federation, Commonwealth, Haber Corp, Independent; Trader, Miner, Explorer, Mercenary) equipped with working Class 2 Hyperdrives.

---

## Upstream Relationship & Independent Fork Policy

Upstream Pioneer (`pioneerspacesim/pioneer`) maintains an official policy against accepting AI-assisted or AI-generated contributions into its upstream codebase. 

Consequently, **Pioneer: Expanse is developed and maintained strictly as an independent standalone fork**. We do not submit pull requests, patches, or issues back to upstream Pioneer. This boundary respects upstream's preferences while allowing Pioneer: Expanse to freely explore modern human-AI software engineering methodologies.

---

## Open Source Licensing & AI Collaboration

### GNU General Public License v3 (GPLv3)
Pioneer: Expanse is free and open-source software distributed under the terms of the **[GNU General Public License version 3 (GPLv3)](http://www.gnu.org/licenses/gpl-3.0.html)** (or, at your option, any later version), maintaining complete licensing continuity with Pioneer.

The GPLv3 guarantees the four fundamental software freedoms: the freedom to run, study, modify, and redistribute the program. The GPLv3 governs the distribution of software and places zero restriction on the tools, compilers, editors, or artificial intelligence models utilized by developers to create or assist in authoring source code.

### AI Collaboration & Licensing Terms
This fork is developed in close human-AI architectural collaboration using Google DeepMind frontier models:
* **Google Argon / Gemini 4**
* **Gemini 3.8**

To ensure unambiguous legal clarity and full downstream open-source compliance:
1. **GPLv3 Licensing of All Contributions**: All modifications, architectures, algorithms, scripts, vector graphics, shaders, and assets introduced in Pioneer: Expanse are licensed under the GNU GPLv3.
2. **Public Domain Fallback**: To the extent that any legal jurisdiction deems machine-assisted or machine-generated expressions non-copyrightable, all such contributions are dedicated unconditionally to the **Public Domain** (or under the terms of the Creative Commons CC0 1.0 Universal Public Domain Dedication), which is fully permissive and 100% compatible with GPLv3 distribution.
3. **Freedom for All Downstream Users**: Anyone is free to fork, study, compile, modify, and redistribute Pioneer: Expanse under the terms of the GNU GPLv3.

---

## Community & Upstream Heritage

Pioneer: Expanse builds with deep appreciation upon the foundation created by the upstream Pioneer contributors over more than a decade:
* Upstream Pioneer Project: [https://pioneerspacesim.net/](https://pioneerspacesim.net/)
* Upstream Repository: [https://github.com/pioneerspacesim/pioneer](https://github.com/pioneerspacesim/pioneer)
* Original License: [GNU General Public License v3 (GPLv3)](http://www.gnu.org/licenses/gpl-3.0.html)

## Compiling from Source

Pioneer: Expanse builds using CMake and Ninja on modern Linux distributions:

```bash
# Install dependencies (Debian/Ubuntu)
sudo apt-get install cmake ninja-build libsdl2-dev libglew-dev libassimp-dev \
                     libvorbis-dev libsigc++-2.0-dev libfreetype-dev libopenal-dev

# Configure and compile
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --target pioneer unittest build-data -j $(nproc)

# Run unit tests
./build/unittest

# Launch game
./build/pioneer
```

For detailed platform compilation notes, see [COMPILING.txt](COMPILING.txt).

## Changelog

For the complete log of changes since the upstream baseline, please see [Changelog.txt](Changelog.txt).

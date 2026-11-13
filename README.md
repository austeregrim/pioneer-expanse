[![Build](https://github.com/pioneerspacesim/pioneer/workflows/Build%20Pioneer/badge.svg)](https://github.com/pioneerspacesim/pioneer/actions)
[![License GPLv3](https://img.shields.io/badge/license-GPL_v3-green.svg)](http://www.gnu.org/licenses/gpl-3.0.html)
[![#pioneer on Libera.Chat](https://img.shields.io/badge/LiberaChat-%23pioneer-brightgreen.svg)](https://kiwiirc.com/client/irc.libera.chat/pioneer)
[![Github All Releases](https://img.shields.io/github/downloads/pioneerspacesim/pioneer/latest/total)]()


# Pioneer: Dangerous

![](https://github.com/pioneerspacesim/pioneer/blob/master/data/icons/badge.png)

[![License GPLv3](https://img.shields.io/badge/license-GPL_v3-green.svg)](http://www.gnu.org/licenses/gpl-3.0.html)

**Pioneer: Dangerous** is an independent single-player fork of the open-source space simulation game [Pioneer](https://github.com/pioneerspacesim/pioneer) (originally inspired by *Frontier: Elite II*).

This fork reimagines Pioneer with core flight mechanics, pacing, and visual systems inspired by *Elite: Dangerous*—replacing Newtonian time acceleration with real-time in-system **FTL Supercruise** flight, a multi-layered **Macro Galactic View** ($100,000\text{ ly}$ Milky Way disc and 3D faction territorial spheres), high-density cockpit and station UI scaling, corporate and faction SVG heraldry, dynamic crisis-driven galactic events (**InterCast News**), an interstellar equity exchange, and an emergency escape pod search-and-rescue rebuy loop.

---

## Key Features in Pioneer: Dangerous

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

## Upstream Policy & AI Attribution

### Independent Standalone Fork
Upstream Pioneer (`pioneerspacesim/pioneer`) maintains an official policy rejecting AI-generated code contributions. Consequently, **Pioneer: Dangerous is maintained strictly as an independent standalone single-player fork**. We do not submit pull requests or patches to upstream Pioneer.

### AI Collaboration Disclosure
This project is developed in close human-AI architectural collaboration using Google DeepMind frontier models:
* **Google Argon / Gemini 4**
* **Gemini 3.8**

AI models have been utilized throughout the engineering lifecycle—collaborating on C++ core engine architecture (supercruise kinematic integration, Bullet collision decoupling, frame transition handling, death view lifecycle, 3D sector map visualization), GLSL shaders, Lua gameplay modules (InterCast news, stock exchange, insurance rebuy, navigation lottery, universal cartographics, hyperdrive auto-feed), high-resolution vector artwork, UI scaling, documentation, and automated unit test verification.

---

## Community & Upstream Heritage

Pioneer: Dangerous builds with deep appreciation upon the foundation created by the upstream Pioneer contributors over more than a decade:
* Upstream Pioneer Project: [https://pioneerspacesim.net/](https://pioneerspacesim.net/)
* Upstream Repository: [https://github.com/pioneerspacesim/pioneer](https://github.com/pioneerspacesim/pioneer)
* License: [GNU General Public License v3 (GPLv3)](http://www.gnu.org/licenses/gpl-3.0.html)

## Compiling from Source

Pioneer: Dangerous builds using CMake and Ninja on modern Linux distributions:

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

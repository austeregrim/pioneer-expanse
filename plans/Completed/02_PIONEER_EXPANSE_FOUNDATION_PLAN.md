# Pioneer: Expanse — Implementation & Modernization Plan

Transform the open-source space simulation game **Pioneer** (inspired by *Frontier: Elite II*) into an enhanced, single-player *Elite Dangerous*-style experience.

---

## Architectural Principles & Core Decisions

1. **Independent Fork**:
   * Upstream Pioneer does not accept AI-assisted code. This repository is an independent single-player fork.
   * Remote `upstream` tracks `https://github.com/pioneerspacesim/pioneer.git` for manual code merges and engine updates.
2. **Single-Player Real-Time Clock & Mission Timing**:
   * **1:1 Real-Time During Play**: In-flight time progression runs in 1:1 real-time. Supercruise allows in-system travel in minutes ($0.1c$ to $2,001c$), eliminating the need for flight time acceleration.
   * **Offline Time Freeze**: When the player exits the game, the in-game clock freezes. A "3-hour mission" guarantees 3 hours of **actual gameplay time**—the player will never fail a contract just because they were offline or busy in real life.
   * **Docked Time Dilation**: While docked at a starport, standard time acceleration remains available whenever a pilot needs to wait for a scheduled rendezvous, market cycle, or fleet transit—making a separate "Wait / Pass Time" service button unnecessary.
3. **Aesthetic, UI Density & Tone**:
   * Tighten UI scaling (native `1920x1080` baseline instead of `1600x900`), typography, and widget padding for a clean, professional, high-density cockpit and station interface.
   * Disable procedural composite `facegen` (`data/facegen/`) and `<< >>` customization sliders; replace contact portraits with high-resolution SVG **corporate logos, faction crests (Solar Federation, Commonwealth, Haber Corp, Independents), starport authority seals, police badges, engineering corps emblems, and syndicate insignias** (`data/icons/logos/`).
   * Structure New Game creation around **Allegiance** + **Career Role** buildouts so players start in allied space with role-appropriate ships, equipment, and working hyperdrives.
   * Remove joke/unserious missions (`DonateToCranks`, easter eggs) and placeholder dev text in favor of serious spaceflight and commerce.

---

## Project Roadmap

> [!NOTE]
> For the long-term expansion roadmap covering Planetary SRVs, Engineering/Crafting, Electronic Infiltration, Graphical/Audio overhauls, Aerospace Manufacturers, and Alien Civilizations, see [01_EXPANSE_LONG_TERM_ROADMAP.md](./01_EXPANSE_LONG_TERM_ROADMAP.md).

```mermaid
graph TD
    P1["Phase 1: Dev Environment & Native Build (DONE)"] --> P2["Phase 2: UI Density, Polish, Curation & Start Profiles (DONE)"]
    P2 --> P3["Phase 3: Navigation & Map QoL (DONE)"]
    P3 --> P4["Phase 4: Macro Galactic View (DONE)"]
    P3 --> P5["Phase 5: In-System FTL Supercruise (DONE)"]
    P5 --> P6["Phase 6: Real-Time Mission Economy (DONE)"]
    P5 --> P7["Phase 7: NPC Supercruise Traffic & Interdiction (DONE)"]
    P7 --> P8["Phase 8: Dynamic Galaxy, InterCast, SAR & Economy (DONE)"]
```

---

### Phase 1: Dev Environment & Build Pipeline (COMPLETED)
* [x] Extracted source code into `/home/austeregrim/Projects/pioneer`.
* [x] Initialized Git repository tracking `main` branch with `upstream` remote.
* [x] Installed Linux build dependencies (`cmake`, `ninja-build`, `libsdl2-dev`, `libglew-dev`, `libassimp-dev`, etc.).
* [x] Configured CMake with Ninja generator (`CMAKE_BUILD_TYPE=Release`).
* [x] Successfully compiled native binary `./build/pioneer` and `build-data` models.
* [x] Successfully ran and verified unit test suite (`./build/unittest` - 9/9 passed).

---

### Phase 2: UI Density, Aesthetic Polish, Content Curation & Start Profiles (COMPLETED)
* **Goal**: Tighten global UI scale/typography for a clean, professional layout, replace procedural `facegen` portraits with non-customizable corporate/faction/authority SVG logos, overhaul New Game start profiles into Allegiance + Career Role selectors, and remove goofy content.
* **Completed Work**:
  * [x] **Base Resolution & Global UI Tightening**:
    * Updated `defaultBaseResolution` from `1600x900` to `1920x1080` in `data/pigui/libs/rescale-ui.lua` and across 13 hardcoded station/info/table/chat UI modules.
    * Refined `pionillium` and `orbiteer` font breakpoints in `data/pigui/libs/text.lua`.
    * Tightened global button dimensions, spacing, and padding in `data/pigui/themes/default.lua`, `data/pigui/views/tab-view.lua`, `data/pigui/modules/time-window.lua`, and `data/pigui/modules/system-overview-window.lua`.
    * Compacted Bulletin Board (`data/pigui/modules/station-view/02-bulletinBoard.lua`) and Station View (`data/pigui/views/station-view.lua`) typography and row spacing (note: further HUD/station menu passes can be refined iteratively during playtesting).
  * [x] **Replaced `facegen` with Corporate, Faction & Authority Logos**:
    * Disabled procedural `facegen` compositing and removed all `<< >>` customization buttons in `data/pigui/libs/face.lua` and `data/pigui/modules/new-game-window/crew.lua`.
    * Created 12 high-resolution SVG emblems in `data/icons/logos/` (`faction_solfed`, `faction_commonwealth`, `faction_haber`, `faction_independent`, `authority_starport`, `authority_police`, `authority_engineering`, `pilots_federation`, `corp_logistics`, `corp_mining`, `corp_mercenary`, `corp_science`, `corp_syndicate`) and wired `data/pigui/libs/face.lua` to render them automatically by role, system faction, and contact seed.
  * [x] **New Game Start Profiles — Allegiance + Career Role** (`data/pigui/modules/new-game-window/class.lua`):
    * Replaced the 3 blind location-based starts with two side-by-side selectors:
      * **Allegiance**: *Solar Federation (Sol — Mars, Cydonia)*, *Commonwealth of Independent Worlds (Epsilon Eridani — New Hope)*, *Haber Corporation (Zekonbur — Fort Gaillard)*, *Independent Frontier (Barnard's Star — System Admin. Resting)*.
      * **Career Role**: *Trader / Hauler (`Sinonatrix`)*, *Miner / Prospector (`Coronatrix`)*, *Explorer / Pathfinder (`Coronatrix`)*, *Mercenary / Escort (`Coronatrix`)* — all equipped with a working Class 2 Hyperdrive and role-appropriate gear.
  * [x] **Content Curation & Lore Cleanup**:
    * Deactivated joke modules `data/modules/DonateToCranks/DonateToCranks.lua` and `data/modules/EasterEgg/Message.lua`.
    * Cleaned up placeholder faction descriptions in `data/factions/001_Solar_Federation.lua` and `data/factions/002_Commonwealth_of_Independent_Worlds.lua`, and updated `data/lang/module-advice/en.json`.

---

### Phase 3: Navigation & Map Quality of Life (QoL) (COMPLETED)
* **Goal**: Streamline target selection directly from sidebar lists and maintain destination lock across hyperspace jumps.
* **Completed Work**:
  * [x] System Overview station/ship/body filters, Show All Ships toggle, RMB focal-plane panning (`SectorView` & Orrery `F6`), and persistent Sector Map home bookmarks (`map-sector-view.lua`).
  * [x] Direct click targeting in Flight UI (`flight-ui/system-overview.lua`) and F2 System Map tree/right-click context menus (`system-view-ui.lua`).
  * [x] Direct **"Set as Navigation Target"** / **"Queue as Cross-System Target"** (and Combat Target) buttons in the F2 System Map `infoView` sidebar (`data/pigui/modules/system-view-ui.lua`).
  * [x] **Cross-System Target Memory** (`data/modules/System/CrossSystemNav.lua` & `data/pigui/modules/system-view-ui.lua`):
    * Target a specific station, planet, or moon in **another** star system while browsing the F2 System Map, select/queue the hyperjump target in `SectorView`/`hyperjump-planner`, and automatically lock `Game.player:SetNavTarget(body)` upon arrival (`onEnterSystem`).

---

### Phase 4: Macro Galactic View (COMPLETED)
* **Goal**: Provide galactic context showing the Milky Way structure, faction territories, coordinate grids, and the player's position in the galaxy via seamless 3D camera zoom.
* **Completed Work**:
  * [x] **Continuous 3D Camera Zoom & Smooth Cross-Fade LOD** (`src/SectorMap.h`, `src/SectorMap.cpp`, `src/SectorView.cpp`):
    * Extended camera zoom bounds (`FAR_MAX = 14,000.0`) with proportional scroll/zoom speed and dynamic perspective clip planes to pull back smoothly from local star systems to the entire $100,000\text{ ly}$ Milky Way disc.
    * Implemented smooth Hermite cross-fade (`m_voronoiAlpha` and `m_macroAlpha`) transitioning between local/regional star systems and the macro galactic view without sector generation stalls.
  * [x] **Multi-Layered 3D Galactic Disc + 3D Volumetric Star Cloud & Nebula/Bulge Glow** (`src/SectorMap.cpp`):
    * Rendered a 9-layer vertically stratified additive-alpha 3D disc stack using `data/galaxy_4k.png` aligned with the engine's physical galaxy coordinates (Galactic Core at $(-25000, 0, 0)\text{ ly}$, radius $50,000\text{ ly}$) so the galaxy retains vertical thickness when tilted in 3D.
    * Generated a 45,000-particle 3D volumetric star cloud + 24,000-star regional LOD cloud sampled from `DensityMapGalaxy::GetSectorDensity` with a realistic 3D central galactic bulge ($\pm 1,500\text{ ly}$) tapering into the spiral arms.
    * Added ~350 3D volumetric glow billboards (`textures/halo.dds`) across Sagittarius A*, the 3D ellipsoidal galactic bulge ($\pm 2,400\text{ ly}$), and high-density spiral arm star-forming regions, plus interior 3D glow for faction bubbles.
  * [x] **3D Galactic Plane Polar Grid & Light-Year Range Rings** (`src/SectorMap.cpp`):
    * Added concentric range rings around Sagittarius A* ($10\text{k}, 20\text{k}, 25\text{k}$ Sol Orbit, $30\text{k}, 40\text{k}, 50\text{k ly}$) with 12 radial azimuth spokes, plus Human Bubble range rings around Sol ($100, 250, 500, 1000, 2500\text{ ly}$).
  * [x] **3D Faction Territory Bubbles & Intersection Shells** (`src/SectorMap.cpp`, `data/shaders/opengl/FresnelColour.frag`):
    * Rendered translucent 3D Fresnel volume spheres (`m_sphere` + `fresnel_sphere`) and additive rim-glow passes at each faction's true 3D homeworld position and influence radius, sorted back-to-front in camera space.
    * Computed 3D sphere-sphere Voronoi intersection circles in 3D bisector planes and 3D spherical contour rings (equatorial, orthogonal meridians, and $\pm 42^\circ$ latitude rings) clipped in 3D against closer overlapping faction bubbles, plus 3D vertical anchor stems to the $Z = 0$ galactic reference plane.
  * [x] **Interactive Raycast Panning, Beacons & Contextual Adaptive Sidebar** (`src/SectorMap.cpp`, `src/lua/LuaSectorMap.cpp`, `data/pigui/views/map-sector-view.lua`):
    * Added scale-adaptive 3D beacons and clickable markers for **`YOU ARE HERE`**, **`SOL`**, **`SAGITTARIUS A*`**, and major/selected factions.
    * Implemented 3D mouse raycasting onto the $Z = 0$ galactic plane to pan anywhere in the galaxy and select faction territories on click.
    * Added the top Macro Galactic Telemetry Banner (Galactic $X, Y, Z$, Sol distance, Core distance, active territory) and Contextual Adaptive Sidebar (`GALACTIC OVERVIEW` & Territorial Dossier).

---

### Phase 5: In-System FTL Supercruise Flight Mechanics (COMPLETED)
* **Goal**: Implement an *Elite Dangerous*-style Frame Shift Drive (FSD) Supercruise mode for in-system space flight, replacing in-flight time compression with 1:1 real-time FTL travel.
* **Completed Implementation**:
  * [x] **Ship State Machine (`src/Ship.h`, `src/Ship.cpp`, `src/enum_table.cpp`)**:
    * Introduced `FlightState::SUPERCRUISE` into `Ship::FlightState`.
    * **FSD Engage Cycle**: Bound to `J` (and `F6` secondary / HUD FSD button). Requires landing gear retracted and zero mass lock ($>5\text{ km}$ from stations and $>5\text{ km}$ above terrain). Features a 5-second charge-up countdown.
    * **Bypass Rigid-Body Physics**: Decoupled `DynamicBody` from Bullet rigid-body collisions (`SetColliding(false)`) and Newtonian forces during Supercruise; velocity aligns kinematically with the ship's forward heading vector and active throttle percentage while preserving sub-frame camera/model interpolation.
    * **Rotational Handling Model**: Pitch and roll are responsive, yaw is sluggish ($0.28\text{ rad/s}$ base). Turn rate scales inversely with log velocity and receives a $1.25\times$ agility bonus inside the $75\%$ throttle "blue zone" (`[0.65, 0.80]`).
    * **Velocity Profile**: Smoothly ranges from $30\text{ km/s}$ ($0.0001c$) minimum floor up to $2,001c$ top speed in deep vacuum.
  * [x] **Gravity Well Drag & Exclusion Zones (`src/ship/SupercruiseController.h`, `src/ship/SupercruiseController.cpp`)**:
    * **Gravitational Mass Drag**: Dynamically suppresses local maximum speed (`m_maxEnvSpeed`) and increases gravity well strain near stars, gas giants, and rocky planets based on altitude above their exclusion zones.
    * **The 6-Second Rule ("Loop of Shame")**: Maintaining $75\%$ throttle inside the blue zone regulates target speed along $v = d / 6.0$ so target ETA stabilizes at $0:06$ down to safe dropout. Approaching faster than $0:05$ ETA triggers `[ SLOW DOWN ]` and gravitational overshoot.
    * **Exclusion Zone Collisions**: Swept ray-sphere intersection against body exclusion zones (or manual drop at $\ge 1,000\text{ km/s}$) triggers an immediate **Emergency Dropout**:
      * Shields are completely depleted (`Ship::DepleteShieldsForEmergencyDrop`) to absorb the impact shock.
      * Hull takes $10\%$ damage **only** if shields were already down or unequipped.
      * Ship suffers a $92\%$ thermal heat spike and a 25-second FSD emergency cooldown.
  * [x] **Frame Transitions & Safe Disengage / Drop-Out Logic (`src/Body.cpp`, `src/ship/SupercruiseController.cpp`)**:
    * **Reference Frame Handling**: While in Supercruise, `Body::UpdateFrame()` loops frame exits and skips rotating surface frames and $20\text{ km}$ orbital station frames.
    * **Safe Disengage Criteria**: Active when target distance $\le 1,000\text{ km}$ and speed $\le 1,000\text{ km/s}$.
    * **Orbital Station Drop-In**: Switches to the station's local frame at $12\text{ km}$ distance facing the station with zero relative velocity.
    * **Surface Starport Drop-In**: Switches to the planet's rotating frame at $10\text{ km}$ altitude and $8\text{ km}$ horizontal standoff facing the surface base with zero relative velocity.
    * **Deep Space Manual Drop**: Drops into normal flight at zero relative velocity in the current parent frame.
  * [x] **Autopilot & "Supercruise Assist" (Autopilot Mk 2) (`src/Ship-AI.cpp`, `data/modules/Equipment/Internal.lua`)**:
    * Standard `misc.autopilot` (`Autopilot Mk 1`) is restricted to sub-light docking, landing, and local orbital flight ($< 100\text{ km}$).
    * Added `misc.autopilot_mk2` (**Autopilot Mk 2 / Supercruise Assist**, `autopilot_cap = 2, supercruise_assist_cap = 1`), pre-installed on the Explorer / Pathfinder start profile and purchasable at tech level 4+ stations. Automatically aligns to target, locks throttle to $75\%$ in the blue zone, auto-disengages at safe drop criteria, and hands off to `AIDock` when initiated via "Dock with station".
  * [x] **Cockpit HUD, 3D Overlays & 1:1 Real-Time Clock (`src/WorldView.cpp`, `src/SpeedLines.cpp`, `src/Game.cpp`, `data/pigui/modules/flight-ui/supercruise.lua`)**:
    * Added Supercruise HUD gauges (vertical throttle bar with $75\%$ cyan blue zone, dynamic $\text{km/s}, \text{Mm/s}, c$ velocity readout, gravity well strain meter, target distance/ETA panel, dual distance/speed safe-drop alignment bars, FSD charge progress bar, and `[ SAFE DISENGAGE READY ]` / `[ SLOW DOWN ]` alerts).
    * Projected 3D orbital path ellipses and spherical exclusion zone silhouette rings in `WorldView::Draw3D()`.
    * Enhanced `SpeedLines.cpp` with double-precision velocity normalization and cyan FTL warp streaks.
    * Locked in-flight simulation speed to `1x` (1:1 real-time) in `Game::UpdateTimeAccel()` and replaced in-flight time compression buttons in `data/pigui/modules/time-window.lua` with FSD Supercruise & Supercruise Assist controls.

---

### Phase 6: Real-Time Mission Economy (COMPLETED)
* **Goal**: Rebalance mission travel times, deadlines, and payouts around actual Supercruise speeds and 1:1 real-time play.
* **Completed & Retired Scope**:
  * [x] `data/modules/MissionUtils.lua`: Replaced legacy multi-day Newtonian travel formulas (`MissionUtils.TravelTimeLocal`, `TravelTime`) with realistic Supercruise travel times, shorter BBS mission deadlines/expiry windows (`CalcBoardTimeout`, `IsAdExpired`), and security/risk-scaled rewards.
  * [~] *Retired (`08-stationHotel.lua` "Pass Time" service)*: Docked time dilation already enables fast-forwarding while berthed at any station, so a separate "Wait / Pass Time" tab is not needed.

---

### Phase 7: NPC Supercruise Traffic & System Interdiction (COMPLETED)
* **Detailed Plan**: See [`04_NPC_SUPERCRUISE_INTERDICTION_PLAN.md`](./04_NPC_SUPERCRUISE_INTERDICTION_PLAN.md).
* **Goal**: Enable universal NPC Supercruise flight, point-of-light FTL visuals, system-wide Supercruise sensors/targeting, FSD Interdiction tug-of-war mechanics, Low Wake distress drops, and post-interdiction escape/mass-lock rules.

---

### Phase 8: Dynamic Galaxy, InterCast News, Faction Wars, Taxation, Penal & SAR Rebuy (COMPLETED)
* **Goal**: Transform the static universe into an evolving single-player living galaxy. Hyperjumps act as macro turns driving territorial wars, economic blockades, and humanitarian crises across frontlines, broadcast via Interstellar Broadcast News (InterCast). Replace permadeath with an emergency escape pod ejection, cryogenic stasis time jump (+14 to 28 days), SAR hospital recovery, and 5% insurance rebuy loop.
* **Completed Implementation (Core + Expanded Systems)**:
  * [x] **Escape Pod, SAR Recovery, Insurance Rebuy & Hardcore Mode (Step 1)**:
    * `src/Body.h`, `src/Player.h`, `src/Player.cpp`: Added `Revive()` method resetting dead flag, restoring hull & shield integrity to 100%, and resetting flight velocities.
    * `src/Ship.cpp`: Queues and emits `onPlayerShipDestroyed` on player lethal explosion before body disposal.
    * `src/DeathView.h`, `src/DeathView.cpp`: Added two-phase death sequence with real-time frame timer, COSPAS-SARSAT telemetry, and Hardcore Ironman permadeath distinction.
    * `src/Game.h`, `src/Game.cpp`, `src/lua/LuaGame.cpp`, `src/Pi.cpp`: Added `m_hardcore`, `Game::TriggerPlayerEscapePodRecovery()`, and transition from `DeathView` to medical recovery or `TombstoneLoop`.
    * `data/pigui/modules/new-game-window/class.lua`, `data/modules/Insurance/Insurance.lua`, `data/pigui/modules/station-view/03-insuranceRebuy.lua`, `data/pigui/modules/station-view/01-lobby.lua`: Insurance buyouts, cargo flotsam, starter loaner workflow, and unresolved-claim launch locks.
  * [x] **InterCast News Engine & Hourly Ticker (Step 2)**:
    * `data/modules/InterCast/InterCast.lua`, `data/pigui/modules/flight-ui/intercast-ticker.lua`, `data/pigui/modules/station-view/06-interCastNews.lua`: Hourly and macro-tick news broadcasts across `FRONTLINE`, `HUMANITARIAN`, `MARKET`, and `POLITICS`.
  * [x] **Hyperdrive Auto-Feed & Dual-Tank Hyperspace Integration**:
    * `data/modules/Equipment/Types.lua`, `data/libs/Ship.lua`, `data/pigui/modules/hyperjump-planner.lua`, `data/pigui/modules/info-view/07-econ-trade.lua`, `data/modules/FuelScoop.lua`: Automatic main-tank feeding, scoopable star Dijkstra routing, and long-jump countdown HUD.
  * [x] **Sector Map Conflict Intel Overlay & Dynamic Crisis Engine (Steps 3–4)**:
    * `src/SectorMap.*`, `data/pigui/views/map-sector-view.lua`, `data/modules/MacroGalaxy/MacroGalaxyEngine.lua`: 3D octahedron conflict overlay, crisis progression, and player catalyst resolution.
  * [x] **Interstellar Stock Exchange (ISX) & Powerball-Scaled Nav-Locus Lottery (Steps 5–6)**:
    * `data/modules/Economy/StockExchange.lua` (`12-stockExchange.lua`) with daily stock ticks and `data/modules/Economy/NavLocusLottery.lua` (`13-navLocusLottery.lua`) with 3D Astrolabe globe and Powerball-scaled tiers.
  * [x] **Civil Taxation, Financial Manager & Penal System (Expanded)**:
    * `data/modules/Economy/TaxAuthority.lua` (quarterly taxation, deductible expenses, residency registration, Financial Manager), `data/modules/Penal/` (Correctional Stations, judicial sentencing, contraband scans), and `04-flightlog.lua` Financial Transaction Ledger.

---

## Verification & Build Commands

* **Compile Game & Assets**:
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
  *(Dedicated NVIDIA/AMD GPU offload is detected automatically on Linux without wrapper flags.)*

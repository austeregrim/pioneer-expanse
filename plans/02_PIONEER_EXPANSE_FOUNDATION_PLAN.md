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
   * **Station "Wait / Pass Time" Service**: If a mission requires waiting for a contact at a scheduled hour, station services (e.g. Starport Lounge / Berth) provide a "Wait / Advance Clock" feature.
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
    P2 --> P3["Phase 3: Navigation & Map QoL (NEXT)"]
    P3 --> P4["Phase 4: Macro Galactic View (DONE)"]
    P3 --> P5["Phase 5: In-System FTL Supercruise (Player Flight)"]
    P5 --> P6["Phase 6: Real-Time Mission Economy & Station Pass Time"]
    P5 --> P7["Phase 7: NPC Supercruise Traffic & System Interdiction"]
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

### Phase 3: Navigation & Map Quality of Life (QoL) (NEXT UP)
* **Goal**: Streamline target selection directly from sidebar lists and maintain destination lock across hyperspace jumps.
* **Target Files & Tasks**:
  * [ ] `data/pigui/modules/system-overview-window.lua`, `data/pigui/modules/flight-ui/system-overview.lua`, & `data/pigui/modules/system-view-ui.lua`:
    * Add direct **"Target"** / **"Set Destination"** action buttons or one-click/double-click targeting on rows in the celestial body and station tree list (both in Flight UI and F2 System Map).
    * Add a **"Set as Navigation Target"** action button in the F2 System Map `infoView` sidebar when inspecting a body/station.
    * Improve type filter toggles (Stations/Starports, Moons, Planets) in the system overview widget so stations are easy to see and target immediately.
  * [ ] **Cross-System Target Memory** (`data/pigui/modules/system-view-ui.lua` / `src/SystemView.cpp` / `onEnterSystem` hook):
    * Allow targeting a specific station, planet, or moon in **another** star system while browsing the F2 System Map (even when `sBody.physicsBody` is not yet instantiated because the player is in a different system), and store that target `SystemPath` in persistent player navigation state (while also queuing/selecting the destination star system for hyperjump).
    * Upon completing a hyperspace jump into the destination system (`onEnterSystem`), automatically resolve the physical `Body` from the saved `SystemPath` and lock it as the active nav target (`Game.player:SetNavTarget(body)`).

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

### Phase 6: Real-Time Mission Economy & Station "Pass Time" Service
* **Goal**: Rebalance mission travel times, deadlines, and payouts around actual Supercruise speeds and 1:1 real-time play, and add a docked clock-advance service.
* **Target Files**:
  * `data/modules/MissionUtils.lua`:
    * Replace legacy multi-day Newtonian travel formulas (`MissionUtils.TravelTimeLocal = distance/AU * 2*Days`) with realistic Supercruise travel times and reasonable gameplay deadlines (e.g. 2–8 hours of gameplay time).
    * Scale rewards based on distance, cargo mass, system security level, and pirate interdiction risk.
  * `data/pigui/modules/station-view/08-stationHotel.lua` (NEW):
    * Station "Pass Time" Service: Accessible when docked at any station or planetary outpost.
    * Allows the player to advance the in-game clock by 1 hour, 6 hours, or 24 hours if waiting for a specific event or mission contact.

---

### Phase 7: NPC Supercruise Traffic & System Interdiction (COMPLETED)
* **Detailed Plan**: See [`04_NPC_SUPERCRUISE_INTERDICTION_PLAN.md`](./04_NPC_SUPERCRUISE_INTERDICTION_PLAN.md).
* **Goal**: Enable universal NPC Supercruise flight, point-of-light FTL visuals, system-wide Supercruise sensors/targeting, FSD Interdiction tug-of-war mechanics, Low Wake distress drops, and post-interdiction escape/mass-lock rules.

---

### Phase 8: Dynamic Galaxy, InterCast News, Faction Wars & Escape Pod Rebuy System (IN PROGRESS)
* **Goal**: Transform the static universe into an evolving single-player living galaxy. Hyperjumps act as macro turns driving territorial wars, economic blockades, and humanitarian crises across frontlines, broadcast via Interstellar Broadcast News (InterCast). Replace permadeath with an emergency escape pod ejection, cryogenic stasis time jump (+14 to 28 days), SAR hospital recovery, and 5% insurance rebuy loop.
* **Implementation Progress**:
  * [x] **Escape Pod, SAR Recovery, Insurance Rebuy & Hardcore Mode (Step 1)**:
    * `src/Body.h`, `src/Player.h`, `src/Player.cpp`: Added `Revive()` method resetting dead flag, restoring hull & shield integrity to 100%, and resetting flight velocities.
    * `src/Ship.cpp`: Queues and emits `onPlayerShipDestroyed` on player lethal explosion before body disposal.
    * `src/DeathView.h`, `src/DeathView.cpp`: Added two-phase death sequence with real-time frame timer:
      * Phase 1 ($0.0\text{ to }2.5\text{s}$): Pulsing red critical hull breach alert and emergency escape pod ejection warning.
      * Phase 2 ($2.5\text{ to }7.5\text{s}$): Fade to deep stasis monitor with cyan/amber COSPAS-SARSAT $121.5\text{ MHz} / 406\text{ MHz}$ distress telemetry, pilot stasis readout, simulated passing days, and SAR patrol acquisition notification.
      * Hardcore Mode Distinction: If hardcore mode is enabled, displays fatal permadeath telemetry (`HARDCORE IRONMAN CHARTER - NO SEARCH & RESCUE TRANSPONDER`) and invokes classic `TombstoneLoop` game over.
    * `src/Game.h`, `src/Game.cpp`, `src/lua/LuaGame.cpp`: Added `m_hardcore` state, getters/setters, savegame JSON serialization, and `Game::TriggerPlayerEscapePodRecovery()` advancing simulation clock by $14\text{ to }28\text{ days}$, finding nearest starport in current system or nearest inhabited sector system, reviving and docking player in medical berth, and queueing `onPlayerRescued`.
    * `src/Pi.cpp`: Transitions from `DeathView` at $7.5\text{s}$ to `TriggerPlayerEscapePodRecovery()` (or `TombstoneLoop` if Hardcore), eliminating tombstone game-over for standard play while preserving permadeath for hardcore pilots.
    * `data/pigui/modules/new-game-window/class.lua`: Added Hardcore Ironman Mode checkbox in New Game bottom buttons passing `isHardcore` flag to `Game.SetHardcore()`.
    * `data/modules/Insurance/Insurance.lua`: Records destroyed ship specifications (hull, equipped items, value, 5% deductible), jettisons cargo as deep space flotsam canisters with coordinates, and handles Rebuy vs. Payout & Starter Loaner settlements. Suppressed when hardcore mode is active.
    * `data/pigui/modules/station-view/09-insuranceRebuy.lua`: Dedicated Starport Insurance & SAR Medical Terminal displaying discharge logs, cargo flotsam notes, 5% rebuy option, and policy schedule (or "UNINSURED HARDCORE CHARTER" notice).
    * `data/pigui/modules/station-view/01-lobby.lua`: Redirects recovered pilots to insurance terminal and locks launch button with warning if an active claim is unresolved.
  * [x] **InterCast (Interstellar Broadcast News) Engine & Cockpit Sidebar Drawer (Step 2)**:
    * `data/modules/InterCast/InterCast.lua`: Core wire service engine generating categorized news articles across `FRONTLINE` (military blockades, combat zones), `HUMANITARIAN` (epidemic outbreaks, famines, aid relief), `MARKET` (metal shortages, fuel tariffs, black market booms), and `POLITICS` (interstellar summits, high-value bounties, expansion treaties). Persists articles in savegames via `Serializer`.
    * `data/pigui/modules/flight-ui/intercast-ticker.lua`: Openable in-flight right-sidebar module registered beside the System Overview toggle button (`gameView.registerSidebarModule("intercast-news", ...)`). Displays category filter buttons, collapsible news dispatches, flash urgent warnings, date, system location, and full story readouts.
    * `data/pigui/modules/station-view/10-interCastNews.lua`: Dedicated Starport InterCast News Terminal with category tabs, article list browser, and full two-column article reader.
  * [x] **Hyperdrive Auto-Feed & Dual-Tank Hyperspace Integration**:
    * **The Problem**: In upstream Pioneer, hyperspace jumping exclusively consumed fuel from the tiny hyperdrive reservoir (1t–4t). Even if a ship had 15–40 tonnes of scooped stellar hydrogen in its main thruster tank, players were blocked from jumping after 1 jump ("INSUFFICIENT FUEL") and had to manually pump fuel through awkward sub-menus. Furthermore, transferring fuel from the drive to the tank failed when the main tank was full.
    * **Elite Dangerous Auto-Feed Solution**:
      * `data/modules/Equipment/Types.lua`:
        * `GetRange(ship)`: Accounts for the ship's full main hydrogen tank (`math.min(resv, storedFuel + fuelMassLeft)`), ensuring true maximum single-jump range is always available.
        * `HyperjumpTo(ship, dest)`: Automatically draws missing hydrogen from the main tank before jump initiation.
        * `OnLeaveHyperspace(ship)`: Automatically tops off the hyperdrive reservoir from the main fuel tank upon arrival in the new system.
      * `data/libs/Ship.lua`: `GetHyperspaceDetails` evaluates total available hydrogen (`engine.storedFuel + self.fuelMassLeft`), preventing false "INSUFFICIENT FUEL" locks.
      * `data/pigui/modules/hyperjump-planner.lua` & `data/pigui/views/map-sector-view.lua`: Route planners now calculate multi-jump reachability across the player's full fuel reserves (allowing 5–8 consecutive jumps on a single full tank).
      * `data/pigui/modules/info-view/03-econ-trade.lua`: Overhauled manual transfer UI with explicit bidirectional controls ("Feed Drive [From Tank]" / "Drain Drive [To Tank]"), audio feedback, full-capacity warnings, and "✓ HYPERDRIVE AUTO-FEED ACTIVE" status.
      * `data/modules/FuelScoop.lua`: Added comms log notifications when harvesting stellar hydrogen and when both reservoirs reach 100% capacity.
    * **PiGui Robustness Audit**: Audited and fixed all recent views (`intercast-ticker.lua`, `11-stockExchange.lua`, `12-navLocusLottery.lua`, `10-interCastNews.lua`, `08-universalCartographics.lua`, `09-insuranceRebuy.lua`). Eliminated boolean parameters in `ui.child()` which caused PiGui type mismatches (`Expected table, string, or integer, got boolean`) and disabled panels; enforced `ui.withStyleColors()`, `ui.withStyleVars()`, and `ui.withID()` RAII patterns across all UI code.
  * [x] **Sector Map Conflict Intel Overlay (Step 3)**:
    * `src/SectorMap.h`, `src/SectorMap.cpp`, `src/lua/LuaSectorMap.cpp`: Added `m_drawConflictOverlay`, `m_conflictSystems` map, and getters/setters/clear methods. In near-sector rendering, renders a tactical 3D octahedron ($d = 0.42\text{f}$) with an outer targeting bracket ($rd = 0.54\text{f}$) nested cleanly around charted system diamonds ($d = 0.28\text{f}$); in far-sector macro star rendering, highlights conflict systems with full-brightness beacon colors.
    * `data/pigui/views/map-sector-view.lua`: Added `draw_conflict_overlay` toggle and color legend in the Settings sidebar (Red = Frontline, Cyan = Humanitarian, Amber = Market, Purple = Politics). Added `syncConflictIntel()` extracting active conflict systems from `InterCast`. In the system info dossier sidebar (`infoView`), added an **[INTERCAST CRISIS DISPATCH]** dossier box with flash warnings, date, headline, and crisis briefing whenever a selected system is experiencing an active incident.
  * [x] **Dynamic Crisis State Machine & Hyperjump Macro Tick Engine (Step 4)**:
    * `data/modules/MacroGalaxy/MacroGalaxyEngine.lua`: Evaluates simulation turns during hyperjump elapsed calendar days ($\Delta t = \text{Game.time} - \text{lastSimTime}$). Maintains 12 to 18 active regional crisis nodes across 35 populated bubble systems across 4 categories: `FRONTLINE` (Orbital Blockades, Insurgencies), `HUMANITARIAN` (Viral Outbreaks, Agricultural Famine), `MARKET` (Precious Mineral Rush), and `POLITICS` (Dockworker Labor Strikes).
    * Handles multi-stage progressive escalation (Incipient $\to$ Epidemic $\to$ Severe Quarantine $\to$ Convalescence) and resolution, auto-publishing dispatches to `InterCast` and synchronizing the 3D `SectorMap` conflict overlay.
    * Features "Player as Catalyst" mechanics: player relief deliveries and tactical interventions advance crisis progress towards positive resolution, complemented by autonomous background NPC drift.
  * [x] **Interstellar Stock Exchange (ISX) Engine & Station Terminal (Step 5)**:
    * `data/modules/Economy/StockExchange.lua`: Three-tier interstellar equity structure:
      * **Tier 1 (8 Megaconglomerates)**: Sirius Heavy Industrial, Core Dynamics Aerospace, Ceti BioPharm, AgriCore Pan-Galactic, Universal Transit, Gutamaya Advanced Tech, Achilles Robotics, and Helios Fusion Cartel. Prices dynamically react to active galaxy-wide crises (e.g. BioPharm surges during viral outbreaks, Core Dynamics spikes during blockades).
      * **Tier 2 (4 Faction Indices)**: Federal Industrial Index (FII), Commonwealth Market Index (CMI), Ares Alliance Composite (AAC), and Outer Rim Independent Average (ORIA).
      * **Tier 3 (Procedural Local Enterprises)**: Dynamically generated on demand at every starport visited based on the local star system, economy, and active local crises. Local vaccine labs surge $+300\%\text{ to }+500\%$ during system outbreaks!
      * Features full player portfolio tracking, buy/sell orders ($\pm 1, 10, 100, 1000$ shares), and quarterly dividend payouts every 30 calendar days.
    * `data/pigui/modules/station-view/11-stockExchange.lua`: Dedicated Starport Trading Floor with live market index tickers, financial summary bar, sparkline price trends, and order execution.
  * [x] **90.7-Trillion-to-One Nav-Locus 3D Astrolabe Sweepstakes (Step 6)**:
    * `data/modules/Economy/NavLocusLottery.lua`: Interstellar astrogation coordinate lottery:
      $$\text{Sector Ring } (00\text{–}99) \times \text{Stellar Class } (\text{14 types}) \times \text{Right Ascension } (000.0\text{–}359.9^\circ) \times \text{Declination } (-90.0\text{–}+90.0^\circ) \times \text{Epoch Vector } (0000\text{–}9999) = \mathbf{90{,}770{,}400{,}000{,}000 \text{ to } 1}$$
      * 7-day drawing clock evaluated on the macro tick; unclaimed Grand Jackpot rolls over and compounds by $+75\text{M to }+150\text{M Cr}$ per cycle, generating multi-billion credit jackpots.
      * 5 payout tiers for partial matches ($15\text{ Cr}$ up to $2,500,000\text{ Cr}$).
      * Algorithmic bulk batch purchases: Cluster Batch (100 loci), Grid Saturation (1,000 loci), Sector Carpet (10,000 loci), and Armillary Blanket (100,000 loci).
    * `data/pigui/modules/station-view/12-navLocusLottery.lua`: Interactive Starport Lottery Terminal featuring an animated **3D Wireframe Rotating Celestial Globe / Astrolabe Ticket** rendered with low-level trigonometry in PiGui. Features glowing neon cyan equator, latitude parallels, longitude meridians, glowing target astrogation ray, reticle crosshairs, and animated 5-dial vector lock displays.

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
* **Run Game on Dedicated NVIDIA GPU**:
  ```bash
  __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only ./build/pioneer
  ```

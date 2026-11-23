[![Build](https://github.com/austeregrim/pioneer-expanse/actions/workflows/build-ci.yml/badge.svg)](https://github.com/austeregrim/pioneer-expanse/actions)
[![License GPLv3](https://img.shields.io/badge/license-GPL_v3-green.svg)](http://www.gnu.org/licenses/gpl-3.0.html)

# Pioneer: Expanse

<p align="center">
  <img src="data/icons/badge.png" alt="Pioneer: Expanse Badge" width="220" />
</p>

[![License GPLv3](https://img.shields.io/badge/license-GPL_v3-green.svg)](http://www.gnu.org/licenses/gpl-3.0.html)

**Pioneer: Expanse** is an independent single-player fork of the open-source space simulation game [Pioneer](https://github.com/pioneerspacesim/pioneer) (originally inspired by *Frontier: Elite II*).

This fork reimagines Pioneer with core flight mechanics, pacing, graphics, fleet management, and systemic gameplay inspired by *Elite: Dangerous* and *X4: Foundations*—replacing Newtonian time acceleration with real-time in-system **FTL Supercruise** flight, a multi-layered **Macro Galactic View** ($100,000\text{ ly}$ Milky Way disc and 3D faction territorial spheres), **Living NPC Supercruise Traffic & FSD Interdictions**, **Volumetric Planetary Rings & 3D Asteroid Mining**, **Multi-Ship Ownership & Autonomous Fleet Logistics**, **Enhanced PBR Graphics & Dynamic Planetary Weather**, **Subsystem Targeting & Component Wear**, **Manufacturer Franchise Dealerships & Specialized Starports**, **Universal Cartographics**, **Quarterly Taxation & Financial Ledgers**, dynamic crisis-driven galactic events (**InterCast News**), an **Interstellar Stock Exchange**, and an emergency **Escape Pod Search-and-Rescue Rebuy** loop.

---

## Community & Upstream Heritage

Pioneer: Expanse builds with deep appreciation upon the foundation created by the upstream Pioneer contributors over more than a decade:
* Upstream Pioneer Project: [https://pioneerspacesim.net/](https://pioneerspacesim.net/)
* Upstream Repository: [https://github.com/pioneerspacesim/pioneer](https://github.com/pioneerspacesim/pioneer)
* Original License: [GNU General Public License v3 (GPLv3)](http://www.gnu.org/licenses/gpl-3.0.html)

---

## Releases

Releases are published as soon as significant or major changes have been made, or if there is emergency bug fixes which is as soon as we see and can fix the bug.

Windows and Linux executable packages are built around 20 minutes after publishing the release on github.

We try to commit changes as soon as possible especially when working on bug fixes, if a release hasn't fixed a bug you're seeing try compiling from source, if you still experience issues please submit a bug.

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

---

## Major Differences & Implemented Features (Pioneer: Expanse vs. Original Pioneer)

This unified section provides an at-a-glance comparison against upstream Pioneer followed by a complete breakdown of every implemented system, mechanic, and function added in **Pioneer: Expanse**.

### Quick Comparison Matrix

| Gameplay System | Original Pioneer Baseline | Pioneer: Expanse |
| :--- | :--- | :--- |
| **In-System Travel** | Newtonian flight accelerated via manual time-warp buttons ($1\times$ to $10,000\times$). | **FTL Supercruise (Frame Shift Drive)** from $30\text{ km/s}$ to $2,001c$ with real-time gravity well drag, 75% blue-zone regulation, terrain-aware exclusion zones, and approach-vector safe dropouts. |
| **Flight Pacing & Clock** | Time compression during active flight; offline time can invalidate missions. | **1:1 Real-Time Flight Pacing**; simulation halts when game closes so deadlines guarantee active play time; docked starport "Pass Time" service. |
| **System NPC Traffic & Registry** | Ephemeral station-bound NPC spawns; static flight trajectories. | **Living Supercruise NPC Traffic & Persistent Regional Ship Registry**; up to 96 persistent regional vessels per hub with unique IDs (`PREFIX-NNNNNL`), shipping lanes, low wakes, and **FSD Interdiction** tug-of-war gameplay. |
| **Planetary Rings & Mining** | Flat 2D billboard ring textures with no physical depth or close-range interaction. | **Volumetric 3D Planetary Rings** with multi-band Roche/frost-line compositions, planetary self-shadowing, 3-tier LOD asteroid fields (up to 2,800 physical rocks), and laser mining. |
| **Ship Ownership & Fleet** | Single active ship only; buying a new vessel discards your previous ship. | **Multi-Ship Ownership & Station Hangars** (`PlayerFleet.lua`); hire NPC Captains, level 5 skills, delegate missions, and issue autonomous X4-style trade, ring-mining, escort, and patrol orders. |
| **Combat & Ship Integrity** | Whole-hull hitpoints only; static module reliability until random breakdown. | **Localized 3D Subsystem Targeting & Component Integrity Wear**; sub-target enemy Thrusters, Hyperdrives, Shields, Weapons, and Sensors; progressive combat damage and high-G environmental wear with drydock overhaul. |
| **Starports, ATC & Dealerships** | Generic stations with uniform markets and instant pad disappearance. | **8 Specialized Starport Profiles**, **6 Manufacturer Franchise Dealerships & Independent Used Brokers**, **3D Animated Hangar Bay Doors & Elevators**, and **Active Air Traffic Control (ATC)** with corridor separation and loitering defense. |
| **Galactic & System Maps** | Local sector grid views; camera cannot pull back to view the galaxy. | **Macro Galactic View ($100,000\text{ ly}$)** with continuous zoom, 45k-particle 3D star cloud, 3D Fresnel faction spheres & Voronoi borders, RMB focal-plane panning, and **Orrery (F6) / Tree (F7)** system maps. |
| **Exploration & Cartography** | Basic system view browsing with no dedicated discovery economy. | **Universal Cartographics & Survey Economy**; 3-second Discovery Scanner system ping, orbital/surface telemetry scans, exploration contracts, and a $10\text{ ly}$ minimum sale distance broker terminal. |
| **Graphics, Weather & Audio** | Classic Blinn-Phong shaders; static planet surfaces and basic cockpit beeps. | **Live-Toggleable Enhanced Graphics** (Cook-Torrance GGX PBR, star glare, terrain-occluded lens flares, solar plumes, dual-layer clouds, ocean wave reflections), **Tri-Planar PBR Terrain & Dwarf Planets**, **3D Spatiotemporal Weather & Lightning**, **Volumetric Ship Spotlights**, and a **4-Tier Aviation Audio Hierarchy**. |
| **Galaxy State & News** | Static system economies; generic BBS boards with static text. | **Living Galaxy Crisis Engine**; hyperjumps tick dynamic events (blockades, outbreaks, booms, strikes), 3D conflict map overlays, player catalyst resolution, and live **InterCast News** broadcasts. |
| **Financials, Stocks & Taxes** | Static commodity trading between ports; no taxation or accounting ledger. | **Interstellar Stock Exchange (ISX)** (megacorps, faction indices, local ventures), **90.7-Trillion-to-1 3D Astrolabe Sweepstakes**, **Quarterly Civil Taxation & Residency** with a hireable Financial Manager, and a **Captain's Log Financial Transaction Ledger**. |
| **Death, Rescue & Justice** | Sudden game over on destruction; basic fine payment at police tab. | **Search & Rescue (SAR) & 5% Insurance Rebuy** (or Hardcore Ironman permadeath), plus **Correctional Penal Stations**, judicial sentencing, contraband customs scans, and fine garnishment. |
| **Hyperspace & Fuel** | Manual single-jump fuel transfers; artificial single-jump locks. | **Hyperdrive Auto-Feed & Dual-Tank Routing** across total hydrogen capacity (5–8 jumps per tank), Dijkstra scoopable fuel-star routing, and a dark-space tabular countdown HUD for long jumps ($\ge 4\text{ days}$). |
| **Visuals & UI Density** | $1600\times 900$ baseline UI; procedural composite facegen sliders. | Native **$1920\times 1080$ UI density**, expanding folder tabs, semantic terminal encryption headers, crisp SVG corporate/faction crests, and automated Linux dedicated GPU offload (NVIDIA/AMD). |

---

### Detailed Breakdown of Implemented Features & Functions

#### 1. In-System FTL Supercruise & Flight Mechanics (`SupercruiseController`)
* **Seamless FTL Speed Envelope**: Cruise within star systems from $30\text{ km/s}$ ($0.0001c$) up to $2,001c$ in deep space following a 5-second FSD charge-up (`J` or `F6` / HUD button) with a $0.75\text{s}$ optical entry flash.
* **Gravity Well Drag & Mass Lock**: Planetary and stellar gravity wells dynamically suppress local maximum speed and apply gravity well strain; FSD engagement requires retracted landing gear and zero mass lock ($>5\text{ km}$ from stations/terrain). Nearby heavy vessels ($\le 3\text{ km}$) apply a Ship Mass-Lock Factor that slows Supercruise charge times ($5\text{s} \to 15\text{–}25\text{s}$).
* **75% Throttle "Blue Zone" & 6-Second Approach Rule**: Maintaining throttle in the cyan $75\%$ blue zone (`[0.65, 0.80]`) grants a $1.25\times$ pitch/roll agility bonus and automatically regulates approach speed along $v = d / 6.0$ (measured to the planetary exclusion surface) to prevent gravitational overshoots ("loop of shame").
* **Approach-Vector Safe Disengage Drop-Ins**: Disengaging when target distance $\le 1,000\text{ km}$ and speed $\le 1,000\text{ km/s}$ transitions cleanly into local reference frames:
  * **Orbital Stations**: Drops at $12\text{ km}$ standoff preserving your exact inbound approach vector and cockpit roll orientation with zero relative velocity.
  * **Surface Starports**: Drops into the planet's rotating frame at $10\text{ km}$ altitude and $8\text{ km}$ horizontal standoff facing the surface base.
  * **Planetary Orbital Insertion**: Safe disengaging at a planet inserts the vessel into a stable $250\text{ km}$ orbit with matching circular orbital velocity.
* **Terrain-Aware Exclusion Zones & Emergency Dropout**: Swept ray-sphere and 3D terrain-elevation intersection checks trigger an immediate Emergency Dropout if breached (or if manually dropped at $\ge 1,000\text{ km/s}$), depleting shields ($10\%$ hull damage if unshielded), spiking thermal heat to $92\%$, and enforcing a 25-second FSD cooldown.
* **Supercruise Assist (Autopilot Mk 2)**: Dedicated avionics module (`misc.autopilot_mk2`) providing automated target alignment, planetary occlusion routing around obstructing bodies, cross-system hyperjump vector alignment, $75\%$ throttle regulation, automatic safe disengage, and seamless handoff to sublight docking (`AIDock`).
* **Flight Assist & Surface Takeoff Controls**: Upgraded `PlayerShipController` Flight Assist with target acceleration, centripetal, and Coriolis compensation (`FOLLOW_ORI`), hold-Thrust-Up ($0.35\text{s}$) brisk planetary surface liftoff ($18\text{ m/s}$ ground, $10\text{ m/s}$ orbital), instant forward throttle takeover (`CRUISE_UP` $\to$ `CRUISE_FWD`), and double-click Middle-Mouse-Button internal cockpit **Freelook Lock** with auto-recentering on hyperjump.
* **Cockpit Supercruise HUD & 3D Overlays**: Vertical throttle gauge, dynamic $\text{km/s}$, $\text{Mm/s}$, and $c$ velocity readouts, gravity strain meter, dual distance/speed alignment bars, 3D orbital path ellipses, spherical exclusion zone silhouette rings, and double-precision cyan FTL warp speed lines.

#### 2. 1:1 Real-Time Flight Pacing & Offline Preservation
* **1:1 Real-Time Flight Clock**: Active flight simulation runs strictly at `1x` real-time; in-flight time-warp buttons are replaced by FSD Supercruise and Supercruise Assist controls.
* **Offline Time Freeze**: The simulation clock halts when the game is closed. Mission deadlines represent actual active gameplay hours, ensuring players never fail contracts while away from the game.
* **Rebalanced Supercruise Mission Economy & Docked "Pass Time"**: Mission travel formulas and payouts (`MissionUtils.lua`) are calibrated for real-time Supercruise transit and system security risk, paired with docked starport clock-advance services for scheduled rendezvous.

#### 3. Living NPC Supercruise Traffic, Persistent Ship Registry & FSD Interdiction
* **Universal NPC Supercruise Transit**: All NPC traders, couriers, bulk freighters, miners, police patrols, and pirates travel between jump clouds, planets, rings, and stations in real `SUPERCRUISE` ($> 2,500\text{ km}$), steering tangentially around planetary and stellar exclusion zones.
* **Persistent Regional Ship Registry (`ShipRegistry.lua`)**: Generates and tracks up to 96 persistent regional vessels per major system hub operating across $\sim 32\text{ ly}$ trade corridors. Assigns globally unique, non-reusable extended registration IDs (`PREFIX-NNNNNL`, e.g., `GR-48291K`), persistent vessel names (`MSV Alderney`, `OSV Deepcore`), commander identities, home ports, overnight hangar stowage schedules, and permanent casualty logs.
* **Dynamic Shipping Lane Traffic & Load Reconciliation**: Scales active traffic density by system population and starport count (up to 30 in-flight and 44 docked vessels in hubs like Sol) and reconciles traffic immediately upon loading saved games (`reconcileTrafficOnLoad`).
* **FTL Point-of-Light Visuals & Supercruise Sensors**: Vessels cruising at FTL ($\ge 1c$) render across the star system as glowing points of light with directional velocity wakes (occluded behind station hulls and terrain, and suppressed while docked). Supercruise sensors resolve ship type, pilot/faction, home port, and `WANTED`/`CLEAN` legal status while hiding cargo manifests and hull/shield percentages until sublight scan.
* **FSD Interdictor Module & Escape Vector Minigame**: Internal utility modules (`misc.fsd_interdictor_1` .. `_3`) enable rear-hemisphere ($\pm 35^\circ$ tail cone, speed-scaled range) FTL tether locks triggered via Secondary Fire (`M`). Initiates a dynamic **Escape Vector** tug-of-war HUD minigame where the evader steers into the escape reticle while the interdictor holds target lock:
  * **Submit ($0\%$ Throttle)**: Clean drop for both ships into the same local frame $1.5\text{–}2\text{ km}$ apart with a short $5\text{s}$ FSD cooldown and no thermal shock.
  * **Forced Interdiction Drop**: Target suffers emergency drop shock ($25\text{s}$ FSD cooldown, shield collapse, $92\%$ heat); attacker receives a $10\text{s}$ cooldown. Interdicting a `CLEAN` ship in policed space registers an immediate crime and dispatches security patrols.
* **Interdiction Nullifier Countermeasure**: Defensive electronic countermeasure (`misc.interdiction_nullifier`, standard on Explorer starts) that severs hostile interdiction tethers, dumps the attacking vessel out of Supercruise with a $45\text{s}$ FSD reboot lockout, and grants the defender $60\text{s}$ of tether immunity.
* **NPC-vs-NPC Interdictions & Low Wake Signals**: Background pirate/police interdictions resolve probabilistically and spawn targetable **Low Wake / Distress Signal** beacons in Supercruise that players can lock and drop into to intervene.

#### 4. Volumetric Planetary Rings & 3D Asteroid Mining (`RingField`)
* **Astrophysical Multi-Band Ring Generation (`RingStyle.h`, `StarSystemGenerator.cpp`)**: Procedural generation governed by stellar bolometric frost lines ($D_{\text{ice}} = 4.85\sqrt{L/L_\odot}\text{ AU}$), rigid/fluid Roche limits, and moon orbital Lindblad resonances (creating physical divisions like the Cassini gap). Classifies bands into 5 chemical compositions (`ICE_WATER`, `ICE_AMMONIA_METHANE`, `ROCKY_SILICATE`, `METAL_RICH`, `METALLIC_PRECIOUS`) and 5 reserve grades (`DEPLETED` to `PRISTINE`), inspectable in the System Map.
* **Planetary Self-Shadowing & Scattering Shaders (`planetrings.frag`)**: Dynamic ray-sphere planetary shadow projection across ring discs, forward Mie scattering on icy rings, and opposition backscatter on rocky/metallic bands.
* **Planar Supercruise Drop-In & Keplerian Ring Frame**: `SupercruiseController` detects planar ring boundaries, enforces mass-density deceleration, and drops ships cleanly into a local Keplerian rotating reference frame (`Frame::CreateRingFrame`) so surrounding boulders orbit stationarily relative to the pilot.
* **3-Tier Volumetric Asteroid Field (`RingField.cpp`, `RingAsteroid`)**: Deterministic 64-bit spatial hash grid spawning up to 2,800 deformed-icosahedron 3D boulders across three distance tiers:
  * **LOD 0 ($< 3\text{ km}$)**: 15–40 full rigid-body physical asteroids in `CollisionSpace` with kinetic impact damage, shield absorption, and reciprocal momentum tumble.
  * **LOD 1 ($3\text{–}15\text{ km}$)**: Up to 2,500 GPU hardware-instanced 3D asteroid meshes (`glDrawElementsInstanced`) across 4 morphological archetypes.
  * **LOD 1b/2 ($15\text{–}50\text{ km+}$)**: Volumetric backscatter dust fog and smooth close-range alpha fade of the macro 2D ring quad.
* **Laser Surface Mining & NPC Mining Fleets (`Mining.lua`, `Beam.cpp`)**: Mining lasers spark thermal hotspots on LOD 0 asteroids and chip off composition-matched mineral ore fragments (`CargoBody`) along surface normal vectors for cargo scooping. Automated NPC mining vessels also transit from starports to planetary rings to harvest and refine ore.

#### 5. Multi-Ship Ownership, Station Hangars & X4-Style Fleet Autonomy (`PlayerFleet.lua`)
* **Persistent Multi-Ship Fleet Registry**: Own and manage an unlimited roster of ships across the galaxy, preserving each vessel's custom callsign, hull livery/pattern, installed equipment, component integrity, fuel reserves, and cargo hold.
* **Shipyard Purchase Modes & Station Hangar Bay (`08-shipMarket.lua`, `11-hangar.lua`)**: Purchase vessels via **Trade-In**, **Buy & Switch (Store Current Ship)**, or **Buy into Hangar**. The dedicated Station Hangar tab provides 1-click flagship swapping, vessel renaming, drydock repairs, direct cargo/equipment transfers between docked ships, and remote inter-system ferry recalls.
* **NPC Captain & Crew Progression (`06-crew.lua`)**: Promote hired crew members to **Captain** of any secondary ship and level 5 specialized attributes (**Piloting**, **Navigation**, **Trading**, **Combat**, **Mining**) through active operations, backed by automated salary payroll and profit-sharing.
* **Autonomous X4-Style Fleet Command Suite (`05-fleet.lua`)**:
  * **Follow / Wingman Escort (`FOLLOW`)**: Launches into formation with the player flagship, synchronizes Supercruise and hyperspace jumps, and engages hostile targets (`FLT` cyan/emerald IFF markers).
  * **Dock / Transit (`DOCK`)**: Autonomous launch, multi-system hyperjump routing, Supercruise approach, and starport docking.
  * **Non-Blocking Autonomous Free Trade (`AUTO_TRADE`)**: Time-sliced C++ `Sector`-backed market route scanner across configurable jump radius presets, minimum profit-per-ton filters, and working capital budgets; autonomously buys, hauls, and liquidates commodities into the Fleet Ledger.
  * **Autonomous Ring Mining (`AUTO_MINE`)**: Flies to ringed planets, drops into `RingField` asteroid belts, extracts mineral ores up to cargo capacity, and returns to port to sell or stockpile.
  * **System Patrol & Bounty Sweep (`PATROL`)**: Patrols Supercruise lanes, interdicts `WANTED` pirates, credits bounty payouts to the player, and auto-docks for repairs below $50\%$ hull.
* **Contract Delegation & Dual IS/OOS Simulation (`02-missions.lua`)**: Delegate eligible Bulletin Board delivery, courier, and combat contracts directly to crewed fleet ships. Ships execute full C++ flight, Supercruise, and docking physics when In-System (IS) with the player, and transition seamlessly to a deterministic Out-of-System (OOS) background tick engine with pirate ambush resolution when in remote sectors.

#### 6. Localized 3D Subsystem Targeting & Component Integrity Wear (`Subsystems`, `ComponentIntegrity.lua`)
* **Spatial 3D Subsystem Hit-Zones (`src/ship/Subsystems.*`)**: Every ship maps installed equipment onto deterministic 3D hull AABB hit-zones across 6 targetable categories: **Thrusters**, **Hyperdrive**, **Shield Generator**, **Weapons** (individual hardpoints), **Sensors/Scanners**, and **Utility Modules**.
* **Cockpit Sub-Targeting & Penetrating Damage**: Cycle enemy subsystems in the Target Scanner HUD (`target-scanner.lua`) to display a precision 3D subsystem diamond reticle and live integrity bar. Weapon impacts that penetrate shields inflict localized integrity damage based on 3D impact proximity:
  * Degraded **Thrusters** suffer linear/angular thrust loss down to $35\%$ and momentary torque cutouts.
  * Degraded **Weapons** scale thermal heat generation up to $2.0\times$ and suffer firing malfunctions or complete offline lockout at $0\%$.
  * Degraded **Hyperdrives** and **Sensors** suffer range penalties and FSD offline lockouts.
* **Environmental High-G Wear & Drydock Overhaul (`10-shipRepairs.lua`)**: Prolonged atmospheric flight and high-gravity operations ($\ge 0.05\text{G}$, scaling nonlinearly above $1\text{G}$) apply gradual mechanical wear across ship components. The Station Ship Maintenance terminal provides per-module integrity telemetry and drydock overhaul servicing for any component below the $90\%$ threshold.

#### 7. Specialized Starport Profiles, Manufacturer Dealerships, 3D Hangars & ATC
* **8 Contextual Starport Profiles (`StationProfiles.lua`)**: Dynamically classifies orbital and surface starports by local industry and system metadata into **Military & Security Docks**, **Industrial & Mining Hubs**, **Gas Siphon & Propellant Depots**, **Research & Survey Observatories**, **Agricultural Platforms**, **Frontier Freeports**, **Commercial Hubs**, and **Correctional Facilities**—driving specialized equipment availability, tech-level floors, and regional price discounts/markups.
* **6 Manufacturer Franchise Dealerships & Independent Used Brokers (`ShipDealerships.lua`, `SecondHand.lua`)**:
  * **Franchise Showrooms**: **OPLI Orbital Yards**, **Kaluri Heavy Industries**, **Mandarava-Csepel Aero**, **ALBR Aerospace**, **Haber Industrial Works**, and **Auronox Corporation** operate faction- and purpose-weighted starport showrooms selling factory-new hulls in bespoke corporate palettes/decals alongside certified pre-owned trade-ins ($90\text{–}100\%$ module integrity).
  * **Independent Pre-Owned Brokerages**: Frontier and rim starports host independent used ship lots (*Rimward Used Ship Brokers*, *Freeport Pre-Owned Hulls*) offering role-outfitted vessels (Ex-Ring Miners, Frontier Smugglers with concealed holds, Bounty Interceptors, Survey Scouters).
* **Procedural 3D Hangar Bay Doors & Pad Elevators (`SpaceStation::RenderHangarBays`)**: Landing pads feature physical 3D recessed hangar apertures with twin sliding hazard-striped blast doors, pulsing landing beacons, and a 9.5-second 4-phase hydraulic elevator sequence (`HANGAR_STOWING` / `HANGAR_UNSTOWING`) that lowers docked ships beneath the pad deck.
* **Active Air Traffic Control (ATC), Orbital Detours & Loitering Enforcement (`StationTrafficControl.lua`, `OrbitalDockingGeometry.cpp`)**:
  * **Corridor Separation & Mutual Exclusion**: Enforces single-vessel mail-slot/airspace clearance (`CanLaunch`, `ClaimCorridor`) with live Lobby countdown badges (`AIRLOCK HOLD` / `AIR SPACE HOLD`), a $180\text{m}$ radial holding ring, and $250\text{m}$ depth staggering.
  * **Waypointed Orbital Collision Avoidance & Departure Peel-Off**: `OrbitalDockingGeometry` routes inbound vessels around rotating station rings and superstructure via radial clearance waypoints, while `AICmdDepart` executes lateral peel-off breakouts ($>320\text{m}$) and brisk ground climbouts ($>2,000\text{m}$).
  * **Starport Defense & Black Box Telemetry**: Unlawful pad/airlock loitering or station weapon discharge triggers warnings followed by lethal starport defense response. Fatal crashes write 30-frame kinematic history snapshots to `blackbox_diagnostics.log`.

#### 8. Macro Galactic View ($100,000\text{ ly}$), Navigation QoL & Universal Cartographics
* **Macro Galactic View (`SectorMap.cpp`, `map-sector-view.lua`)**:
  * Continuous 3D camera zoom out to the entire $100,000\text{ ly}$ Milky Way disc (`FAR_MAX = 14,000`) with smooth Hermite cross-fade LOD and zero sector-generation stalls.
  * 9-layer vertically stratified 3D galactic disc, 45,000-particle volumetric star cloud, 24,000-star regional LOD cloud, and ~350 volumetric glow halos across Sagittarius A* and spiral arms.
  * Concentric galactic polar coordinate rings ($10\text{k–}50\text{k ly}$), Sol Human Bubble rings ($100\text{–}2,500\text{ ly}$), translucent 3D Fresnel faction territorial spheres, 3D sphere-sphere Voronoi intersection borders, scale-adaptive 3D beacons (`YOU ARE HERE`, `SOL`, `SAGITTARIUS A*`), and a contextual Territorial Dossier sidebar.
* **Map Panning & Navigation QoL (`SystemView.cpp`, `SectorView.cpp`)**:
  * Right-Mouse-Button (RMB) planar focal-plane drag panning in both the 3D Sector Map and the **Orrery View (F6)** system map, plus **Hierarchical Tree View (F7)** labelling and double-precision orbital grid rendering.
  * Smart Sector Map camera focus prioritizing distinct selected systems first, followed by active route destination, hyperspace target, or current system, plus persistent sector map bookmarks.
* **Hyperdrive Auto-Feed, Scoopable Routing & Dark-Space Countdown HUD**:
  * Automatic hydrogen feed (`Types.lua`, `Ship.lua`) draws propellant from the main thruster tank into the hyperdrive reservoir before jump initiation and tops it off on arrival, enabling multi-jump Dijkstra auto-routing across full tank reserves (5–8 consecutive jumps).
  * Route Planner (`hyperjump-planner.lua`) features a maximum jump-distance slider, a **Scoopable Fuel Star filter**, and dual orange/red fuel pump indicators distinguishing drive cache vs. main tank depletion.
  * Long-distance hyperspace transits ($\ge 4\text{ days}$) smoothly fade the transit tunnel to deep black with a crimson glow clock and fixed-width tabular `DAYS / HRS / MIN` countdown HUD (`hyperspace.lua`).
* **Universal Cartographics & Exploration Economy (`Cartography.lua`, `04-universalCartographics.lua`)**:
  * Hold-to-charge ($3.0\text{s}$) **Discovery Scanner** system-wide ping recording stellar/planetary body counts, paired with close-range orbital and surface telemetry scans (`ScanManager`) and remote Cartography Survey missions.
  * Dedicated Starport **Universal Cartographics** broker terminal enforcing a $10\text{ ly}$ minimum sale distance, paying tiered bonuses for unexplored systems, complete system surveys, earth-like worlds, and high-value bodies.

#### 9. Enhanced Graphics Overhaul, Planetary Terrain, Weather & Aviation Audio
* **Live-Toggleable Enhanced Graphics (`EnhancedGraphics`)**: Instantaneous in-game Video Settings switch between **Enhanced Graphics** and **Classic Pioneer** rendering with zero restart required:
  * **Ship & Station Cook-Torrance GGX PBR (`multi.frag`)**: Physically plausible metallic/roughness response derived from existing textures, space environment IBL reflections, Fresnel grazing rim sheen, ACES filmic tone-mapping, and warm exterior station windows.
  * **Stars, Plumes & Terrain-Occluded Lens Flares (`star_corona.frag`, `lens_flare.frag`)**: Animated 3D cylindrical noise convective granulation, arching solar prominences/plumes, 6-point diffraction starbursts, anamorphic streaks, and multi-element optical lens flares that ray-march against local 3D terrain ridges, clouds, and station hulls for realistic horizon/eclipse occlusion.
  * **Gas Giants, Dual-Layer Clouds & Realistic Water (`gassphere_base.frag`, `planet_clouds.frag`)**: Deterministic per-planet gas giant profiles (Jupiter/Saturn/Uranus/Neptune archetypes) with counter-drifting 24h-periodic zonal bands, polar hoods, and cyclone vortices; dual-layer terrestrial cloud shells (cumulus/stratus + high cirrus) casting surface shadows; and normal-mapped ocean wave chop/swell with true atmospheric LUT sky reflections and coastal surf foam.
* **Always-On Planetary Terrain & Dwarf Planets (`TerrainFeature.cpp`, `GeoSphere.cpp`)**:
  * True 3D spherical cellular impact craters (`cellular_crater_layer`) with raised rims, ejecta aprons, and central rebound peaks.
  * Scale-accurate triaxial potato moons (Phobos/Deimos), contact binaries (67P), cratered protoplanets (Vesta), and dedicated **Dwarf Planet** generators (`TerrainHeightDwarfPlanet`) featuring smooth cryo-plains and tectonic chasma rifts.
  * Tightened $20\text{m}$ close-range `GeoSphere` patch resolution and world-locked **Tri-Planar PBR Multi-Splat** terrain shading eliminating cliff texture stretching and providing smooth drivable basin floors and terraced mesas.
* **Dynamic 3D Planetary Weather, Lightning & Aerodynamics (`WeatherSystem.cpp`, `WeatherEffects.cpp`)**:
  * Deterministic spatiotemporal weather engine computing latitude climate zones, seasonal orbital obliquity, zonal/cyclonic winds, vertical drafts, boundary-layer wind shear, precipitation (`RAIN`, `SNOW`, `DUST`, `ASH`), and multi-frame bloomed forked plasma lightning strikes with cloud-belly illumination and distance-delayed thunder claps.
  * Physical atmospheric flight forces (`CalcAtmosphericForce`, `CalcAtmoTorque`) applying relative-airspeed drag, weathercocking, and 3-axis storm turbulence buffeting (attenuated near landing pads), paired with an adaptive `PlanetaryInfo` wind/shear HUD and surface Starport ATC ATIS weather briefings.
* **Volumetric Ship Lighting (`ShipLights`)**: Mesh-snapped high-intensity forward spotlights and landing gear floodlights with exterior volumetric light cones, direct-view glare coronas, and lower-right cockpit HUD SVG toggle buttons (Beacon, Forward Headlights, Landing Floodlights).
* **4-Tier Aviation Cockpit Audio Hierarchy**: Warm, non-clipping procedural cockpit alert soundscape distinguishing sweeping/whooping critical sirens (`Missile_Inbound`, `alarm_emer`), rounded warning pulses (`weather_windshear`, `Missile_lock`), two-tone aircraft "bing-bong" awareness chimes (`fuel_low`, `weather_turbulence`), and soft informational dings.

#### 10. Living Galaxy Crisis Engine & InterCast News Network
* **Hyperjump Macro Crisis Engine (`MacroGalaxyEngine.lua`)**: Elapsed calendar days during hyperjumps advance a galaxy-wide simulation maintaining 12–18 active regional crises across populated systems in 4 categories: **`FRONTLINE`** (Orbital Blockades, Insurgencies), **`HUMANITARIAN`** (Viral Outbreaks, Agricultural Famines), **`MARKET`** (Precious Mineral Rushes, Fuel Tariffs), and **`POLITICS`** (Dockworker Strikes, Summits).
* **Multi-Stage Escalation & Player Catalyst Resolution**: Crises progress through lifecycle stages (Incipient $\to$ Peak Crisis $\to$ Convalescence) and dynamically shift local commodity prices and stock valuations. Player relief commodity deliveries and combat interventions actively accelerate crisis resolution.
* **3D Sector Map Conflict Intel Overlay**: Toggleable 3D tactical octahedron and targeting bracket overlay on the Sector Map color-coded by crisis category (Red/Cyan/Amber/Purple) with a live **[INTERCAST CRISIS DISPATCH]** briefing panel in the system dossier sidebar.
* **InterCast News Terminals (`InterCast.lua`, `intercast-ticker.lua`, `06-interCastNews.lua`)**: Collapsible in-flight right-sidebar news ticker and a two-column Starport InterCast News reader featuring category filtering, distance tags, ISO `YYYY-MM-DD` date navigation, read/unread tracking, and priority bookmarking.

#### 11. Financial Ecosystem: Stock Exchange, 3D Astrolabe Lottery, Quarterly Taxes & Ledger
* **Interstellar Stock Exchange (`StockExchange.lua`, `12-stockExchange.lua`)**:
  * Trade equities across **8 Pan-Galactic Megaconglomerates** (*Sirius Heavy Industrial*, *Core Dynamics Aerospace*, *Ceti BioPharm*, *AgriCore*, *Universal Transit*, *Gutamaya*, *Achilles Robotics*, *Helios Fusion*), **4 Faction Composite Indices** (*FII*, *CMI*, *AAC*, *ORIA*), and **Procedural Local Starport Ventures**.
  * Prices react dynamically to active galactic crises (e.g., *Ceti BioPharm* and local vaccine labs surge during viral outbreaks) as well as macroeconomic headwinds, antitrust probes, and supply gluts.
  * Full portfolio tracking, sparkline price history charts, remote holding liquidation, and 30-day quarterly dividend payouts.
* **90.7-Trillion-to-One Nav-Locus 3D Astrolabe Sweepstakes (`NavLocusLottery.lua`, `13-navLocusLottery.lua`)**:
  * 5-coordinate astrogation lottery ($\text{Sector Ring} \times \text{Stellar Class} \times \text{RA} \times \text{Dec} \times \text{Epoch Vector} = 90,770,400,000,000 : 1$) with a 7-day macro drawing clock, compounding multi-billion credit rollovers, 5 partial-match payout tiers, and bulk batch purchases up to 100,000 loci (*Armillary Blanket*).
  * Rendered on an interactive **3D Rotating Wireframe Celestial Astrolabe Globe** visualizing all purchased coordinate rays in real time.
* **Quarterly Civil Taxation, Residency & Financial Manager (`TaxAuthority.lua`, `01-lobby.lua`)**:
  * Synchronized civil Gregorian calendar-quarter tax cycle (`Q1`–`Q4`) with a full next-quarter grace period, tracking net profits across commodity trades, fleet operations, BBS contracts, cartography, and stock dividends (plus $30\%$ lottery windfall withholding).
  * **Deductible Operating Expenses**: Hull/module repairs, fuel purchases, crew wages, and shipyard maintenance automatically offset taxable income via a cost-basis ledger.
  * **Residency & Hireable Financial Manager**: Register official starport residency for preferential faction tax rates, and hire a **Financial Manager** ($2,500\text{ Cr}$ retainer, $1,500\text{ Cr}$/quarter) to automatically file and settle quarterly statements before delinquency penalties accrue.
* **Captain's Log Financial Transaction Ledger (`04-flightlog.lua`)**: Dedicated `Financial` audit tab in the Flight Log recording timestamped credit receipts and itemized breakdowns for every trade, stock order, dividend, tax settlement, police fine, lottery draw, shipyard purchase, and repair.

#### 12. Escape Pod SAR, Insurance Rebuy, Penal System & Hardcore Charter
* **Two-Phase Escape Pod Ejection & Cryogenic SAR (`DeathView.cpp`, `Game::TriggerPlayerEscapePodRecovery`)**:
  * Fatal ship destruction triggers a 2.5-second critical hull breach alert followed by an escape pod ejection sequence displaying COSPAS-SARSAT $121.5 / 406\text{ MHz}$ distress telemetry and a distance-scaled cryogenic stasis jump ($14\text{–}28\text{ days}$) to the nearest starport medical clinic.
* **Starport Insurance Terminal & Anti-Exploit Safeguards (`Insurance.lua`, `03-insuranceRebuy.lua`)**:
  * Settle hull and full equipment/sub-slot restoration for a **5% insurance deductible** (preserving your hired crew roster), or opt for a cash hull payout plus a Charter-Subsidized Starter Loaner (`Coronatrix`) with anti-exploit trade-in/strip capping.
  * Destroyed ship cargo is jettisoned into deep space as recoverable flotsam canisters with logged coordinates; unresolved claims lock undocking and market trading until settled.
* **Penal System, Correctional Stations & Judicial Sentencing (`PenalSystem.lua`, `02-police.lua`)**:
  * Dedicated high-security **Correctional / Penal Stations** (`orbital_station_penal`) where civilian shipyards, outfitting, and unauthorized concourse services are suspended.
  * Pilots rescued with outstanding criminal bounties/fines are routed directly to correctional detention for judicial sentencing, mandatory fine garnishment, and automated bio-magnetic contraband customs sweeps (bypassable only via shielded cargo holds).
* **Hardcore Ironman Charter Mode**: Optional New Game checkbox disabling Search & Rescue transponders and insurance underwriting for classic fatal permadeath (`TombstoneLoop`).

#### 13. UI Density, Corporate Heraldry, Security Modes & Hardware Offload
* **Native $1920\times 1080$ UI Baseline & Standardized Layouts**: Upgraded PiGui baseline resolution from $1600\times 900$ to $1920\times 1080$ with refined `pionillium`/`orbiteer` typography, standardized 45%/55% split market panels, clipped expanding folder tabs, restored flight-assist/target radial menus, and unified Galactic Credit (`Cr`) notation.
* **Semantic Terminal Verification & Quantum Encryption**: Shipboard and starport views execute contextual cryptographic header animations—**Public Key Signature Verification** for shipboard terminals and public feeds (Lobby, InterCast News) and **Quantum Channel Encryption** for private legal/financial communications (Police, BBS, Insurance, Cartographics, Markets, Stocks, Lottery).
* **Corporate, Faction & Manufacturer SVG Heraldry (`data/icons/logos/`)**: Replaced procedural composite `facegen` portraits and sliders with high-resolution vector crests for factions (*Solar Federation*, *Commonwealth*, *Haber Corp*, *Independent*), aerospace manufacturers (*OPLI*, *Kaluri*, *Mandarava-Csepel*, *ALBR*, *Auronox*), starport authorities, police, engineering corps, and syndicates.
* **Allegiance + Career Role New Game Starts (`class.lua`)**: Side-by-side selectors pairing 4 Faction Allegiances (*Sol/Mars*, *Epsilon Eridani*, *Zekonbur*, *Barnard's Star*) with 4 Career Roles (*Trader/Hauler*, *Miner/Prospector*, *Explorer/Pathfinder*, *Mercenary/Escort*)—all launching with working Class 2 Hyperdrives and role-tailored loadouts.
* **Automated Linux Dedicated GPU Offload**: Built-in engine detection automatically enables NVIDIA Optimus and AMD PRIME discrete hardware rendering on Linux without wrapper scripts.

---

## Strategic Roadmap: Remaining Expansions (Pillars B–H)

Our strategic long-term development roadmap is documented in detail in the [`plans/`](plans/) directory. The foundation, fleet autonomy (`Plan A`), and initial visual/weather/dealership milestones (`Plans E & F`) are implemented; the remaining expansion work focuses on planetary surface vehicles, engineering depth, covert operations, full 3D cockpit interiors, modular slot outfitting, deep-space alien expeditions, and capital-scale empire building:

* **[Plan B: Surface Reconnaissance Vehicles (SRVs) & Planetary Surface Operations](plans/B_PLAN_SRV_SURFACE_OPERATIONS.md)**:
  * Multi-wheel spring-damper suspension physics on `GroundVehicle` (`DynamicBody` subclass), Ackermann steering, and low-gravity vernier thrusters.
  * Amphibious waterjet and pontoon buoyancy mode for liquid hydrocarbon/water oceans.
  * Procedural instanced surface boulder scatter fields with physical Bullet convex colliders.
  * Acoustic-Spectral Waterfall Wave Scanner (`±90°` sweep) for locating mineral outcrops, crashes, and distress beacons.
  * Landed ship hangar deployment, boarding ramp transfer, and autonomous ship dismissal (> 2.5 km) & recall landing.
* **[Plan C: Engineering, Salvage & Matter Synthesis](plans/C_PLAN_ENGINEERING_CRAFTING.md)**:
  * Zero-cargo-mass player materials bank (Raw Elements, Manufactured Components, Encoded Data).
  * Atomic Scrap Reclamation from ship debris and ring mining fragments.
  * On-the-fly field Matter Synthesis (FSD injection range boosts, emergency life-support $O_2$, munitions re-arm, hull limpets).
  * Deterministic Grade 1–5 Engineer blueprint progression and unique Experimental Effect overrides.
* **[Plan D: Electronic Warfare, Infiltration & Megaships](plans/D_PLAN_HACKING_INFILTRATION.md)**:
  * Non-dockable orbital Megaships, orbital installations, and penal colonies with sub-targetable cargo bays, data relays, and defense grids.
  * Datalink Scanner with two-phase interactive signal intrusion and frequency-bypass minigames.
  * Planetary settlement trespass security zones, alarm klaxons, and automated Skimmer defense drone patrols.
* **[Plan E: Graphics, Atmospheric Shaders & Vacuum Audio Overhaul](plans/E_PLAN_GRAPHICS_AUDIO_OVERHAUL.md)**:
  * PBR multi-splat terrain shaders (`albedo`, `normal`, `roughness`, `metallic`, `AO`) with slope-based triplanar projection.
  * Analytical Rayleigh & Mie atmospheric scattering with realistic sunset limb glow and planetary shadow projection.
  * Dynamic cockpit canopy glass shaders: micro-abrasions, star glare, heat shimmer, and cold-running frost (< 20% heat).
  * OpenAL vacuum low-pass acoustic filtering (distinguishing exterior vacuum-attenuated detonations from internal hull transducer vibrations).
  * Synthesized Cockpit AI Voice advisory priority queue ("FSD charging", "Warning: Temperature critical", "Shields offline").
* **[Plan F: Aerospace Megacorporations & Modular Slot Outfitting](plans/F_PLAN_FLEET_MANUFACTURERS.md)**:
  * Four major aerospace manufacturers with unique design languages and flight philosophies.
  * Four-tier outfitting architecture: Core Internals (Class 1–8), Weapon Hardpoints (Class 1–4 Fixed/Gimballed/Turreted) & Utility Mounts, Dedicated Avionics, and Flexible Internal Compartments.
* **[Plan G: Deep Exploration, Wing Missions & Alien Civilizations](plans/G_PLAN_EXPLORATION_ALIENS.md)**:
  * Full-Spectrum System (FSS) waveform scanner and orbital Detailed Surface Scanner (DSS) gravity-curved mapping probes.
  * Wing escort contracts, VIP luxury passenger transport, and burning-station refugee evacuations.
  * Non-human deep-space civilizations guarding outer nebulae and relics (*Hydrazine Swarm* and *Archon Automata*).
* **[Plan H: Capital Ships, Station Construction & Grand Strategy](plans/H_PLAN_CAPITAL_SHIPS_AND_EMPIRE_BUILDING.md)**:
  * Playable and AI-commanded Capital Ships & Fleet Carriers with multi-turret fire control networks.
  * Modular player starport and orbital station construction.
  * Closed-loop industrial factories, NPC Station Managers, and sector-wide territorial sovereignty.

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

For detailed platform compilation notes, see [COMPILING.txt](COMPILING.txt).

## Changelog

For the complete log of changes since the upstream baseline, please see [Changelog.txt](Changelog.txt).

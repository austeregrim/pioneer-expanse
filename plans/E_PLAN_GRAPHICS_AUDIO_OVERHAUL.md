# Technical Implementation Plan: Graphics, Planetary Engine, Weather & Audio Overhaul

**Document Version**: 2.2  
**Status**: In Progress (Track 1 Milestones 1–2, Track 2 Milestones 4–5 & Track 3 Milestone 6 Completed)  
**Priority Tier**: Active Pillar (Foundation for SRV Surface Operations & Visual Polish)  
**Parent Roadmap**: [`01_EXPANSE_LONG_TERM_ROADMAP.md`](./01_EXPANSE_LONG_TERM_ROADMAP.md)  

---

## 1. Architectural Strategy: Three Clean Tracks

To preserve Pioneer's rock-solid playability and save/physics determinism while delivering a dramatic visual and planetary leap, this overhaul is split into three distinct tracks:

1. **Track 1 — Toggleable "Enhanced Graphics" (Settings Option, Classic Fallback Preserved)**
   * Controlled by a persistent **`EnhancedGraphics`** setting in Graphics Settings (toggles cleanly between **Enhanced** and **Classic Pioneer** rendering).
   * Purely visual/shader/post-processing upgrades that never alter hitboxes, terrain height, or gameplay determinism—so Classic remains a 100% playable fallback.
2. **Track 2 — Always-On Planetary Terrain & World Generation (Non-Toggleable, SRV Foundation)**
   * Heightfields, small-body generation (dwarf planets, irregular asteroid moons), and drivable/landable surface structure.
   * **Cannot be toggled off** because terrain geometry directly governs collisions, planetary starport placement, and future SRV suspension physics.
3. **Track 3 — Atmospheric Weather, Wind Turbulence & Soundscape**
   * Physically simulated atmospheric weather and wind/gust turbulence affecting atmospheric flight and planetary base approaches, paired with vacuum acoustics and cockpit voice advisories.

```mermaid
graph TD
    subgraph Track1["Track 1: Toggleable Enhanced Graphics (Classic Fallback)"]
        T1M1["Milestone 1: Enhanced Graphics Toggle + Ship/Station PBR + Glare & Lens Flare"]
        T1M2["Milestone 2: Stars (Plumes/Corona), Gas Giants, Terrestrial Clouds, Water & Ice Reflections"]
        T1M3["Milestone 3: Upgraded Rayleigh/Mie Atmospheres"]
    end

    subgraph Track2["Track 2: Always-On Planetary Terrain & World Gen (SRV Prep)"]
        T2M1["Milestone 4: Dwarf Planets & Irregular Asteroid Moons"]
        T2M2["Milestone 5: Landable/Drivable Surface Structure & PBR Multi-Splat Terrain"]
    end

    subgraph Track3["Track 3: Atmospheric Weather & Soundscape"]
        T3M1["Milestone 6: Atmospheric Weather, Wind Turbulence & Aviation Chimes (Completed)"]
        T3M2["Milestone 7: Vacuum Low-Pass Audio & Cockpit AI Voice"]
    end

    subgraph Track4["Track 4: Full 3D Cockpit Interior Overhaul"]
        T4M1["Milestone 8: 3D Cockpit Interiors, Diegetic Avionics & Canopy Glass"]
    end

    T1M1 --> T1M2 --> T1M3
    T2M1 --> T2M2
    T1M2 --> T3M1
    T2M2 --> T3M1
    T1M3 --> T4M1
    T3M2 --> T4M1
```

---

## 2. Track 1: Toggleable Enhanced Graphics (Settings Option)

### 2.1 Milestone 1 *(Active)*: Settings Toggle, Ship & Station PBR, Glare & Lens Flare
* **Enhanced Graphics Toggle (`EnhancedGraphics`)**:
  * Add `EnhancedGraphics` config key in `GameConfig` (default `1` / enabled), wired to C++ renderer/shader uniforms and exposed in the PiGui Video/Graphics Settings panel.
  * When `EnhancedGraphics == 0`, shaders execute the exact Classic Pioneer Blinn-Phong and star/atmosphere rendering paths with zero visual regressions.
* **Ship & Station PBR Beautification (`data/shaders/opengl/multi.*`, `lib.glsl`)**:
  * Upgrade `multi.frag` with a **Cook-Torrance GGX PBR** lighting model when Enhanced Graphics is enabled, deriving physically plausible roughness and metallic response from existing diffuse, specular, shininess, and AO maps (so all existing Pioneer ships and stations immediately benefit without requiring re-authored textures).
  * Add **analytical environment reflections / Fresnel grazing rim lighting** (star-lit specular sheen, metallic hull reflection of sky/nebula + local star, hemisphere ambient bounce, and crisp panel normal highlights) plus subtle filmic/ACES tone-mapping so bright highlights roll off naturally instead of clipping flat.
  * Enhance emissive glow on ship engines, windows, and station docking bays.
* **Star Glare & Optical Lens Flare (`src/Star.cpp`, `src/WorldView.cpp`, `data/shaders/opengl/lens_flare.*`)**:
  * Render crisp, physically tasteful **star glare, coronal diffraction spikes, and multi-element optical lens flare** for primary/nearby stars in the system.
  * Respect **line-of-sight occlusion** (smoothly attenuating when a planet, moon, or station eclipses the star) and fade smoothly with distance, star luminosity, and off-axis angle so it elevates cinematic beauty without obscuring HUD elements or combat targets.

### 2.2 Milestone 2: Stars, Gas Giants, Terrestrial Clouds, Water & Ice Reflections
* **Stars (`geosphere_star.*` + coronal shader)**: Animated convective granulation, limb darkening, radiant corona, and **stellar plumes / solar prominences** arching off stellar limbs.
* **Gas Giants (`gassphere_base.*`, `gen-gas-giant-colour.*`)**: Enhanced atmospheric limb scattering, richer multi-band storm/turbulence depth, and subtle terminator glow.
* **Terrestrial Cloud Layers**: Dedicated animated cloud shell rendering above terrestrial worlds with wind-drift parallax, variable coverage driven by `SystemBody` hydro/atmosphere parameters, and soft cloud-shadow tinting on the terrain below.
* **Water & Ice Surface Shaders**: Animated ocean micro-wave normal detail with Fresnel sky/sun reflections on liquid seas, and low-roughness crystalline specular glint on frozen/icy worlds.

### 2.3 Milestone 3: Upgraded Rayleigh/Mie Atmospheres
* **Unified Rayleigh/Mie Scattering**: Seamless orbital-to-surface transition, vivid twilight/sunset terminators, alien atmospheric chemistry tints (`SO2`, `CH4`, `NH3`), and Mie aerosol horizon haze. *(Canopy glass shaders deferred to Milestone 8 alongside full 3D cockpit interiors.)*

---

## 3. Track 2: Always-On Planetary Terrain & World Generation (Non-Toggleable) *(Completed)*

* **Milestone 4 — Dwarf Planets & Asteroid Moons *(Completed)***:
  * Added true 3D spherical cellular impact craters (`cellular_crater_layer`, `multi_scale_craters`) with parabolic/flat-floor bowls, raised rims, outer ejecta aprons, and central rebound peaks (`src/terrain/TerrainFeature.*`).
  * Overhauled all four `TerrainHeightAsteroid*` generators + `TerrainColorAsteroid` for scale-accurate triaxial potato moons (Phobos/Deimos), cratered oblate protoplanets (Vesta), bilobed contact-binary bodies (67P), and shattered angular monoliths (Psyche/Eros) without modifying `StarSystemGenerator` body counts or RNG order.
  * Added dedicated `TerrainHeightDwarfPlanet` & `TerrainColorDwarfPlanet` generators for rocky and icy dwarf planets / small sub-satellites (`< 0.28 R_earth`), featuring smooth flooded maria / Sputnik Planitia cryo-plains, tectonic chasma/linea rifts, and dense multi-scale craters.
* **Milestone 5 — Landable & Drivable Surface Structure *(Completed)***:
  * Tightened `GeoSphere` close-range patch triangle target from `100m` to `20m` and fixed `CalculateMaxPatchDepth()` reset behavior (`src/GeoSphere.cpp`).
  * Overhauled `TerrainHeightBarrenRock*`, `TerrainHeightHillsCraters2`, and `TerrainHeightMountainsCraters2` to eliminate high-frequency noise-aliasing spikes and introduce smooth drivable basin floors (`smooth_basin_floor`), terraced mesas (`smooth_terrace`), navigable canyons, and true cellular craters.
  * Added seamless world-locked **Tri-Planar PBR Multi-Splat** shading (`PatchTileOffset` modulo 256m double-precision offset in `src/GeoPatch.cpp`, plus stratified cliff rock, talus/scree mid-slopes, flat regolith/soil, and per-layer GGX microfacet roughness/Fresnel in `geosphere_terrain.*` and `rayleigh_geosphere_terrain.*`).
* **Future Follow-Up Note**: Add in-system procedural **asteroid fields / asteroid belts** as localized volumetric/navigable belts without altering existing `StarSystemGenerator` planetary seeds.

---

## 4. Track 3: Atmospheric Weather, Wind Turbulence & Soundscape

* **Milestone 6 — Atmospheric Weather, Wind Turbulence & Aviation Chime Overhaul *(Completed)***:
  * Implemented deterministic 3D spatiotemporal `WeatherSystem` (`src/planet/WeatherSystem.*`, `Planet::GetWeatherState`) deriving zonal/cyclonic wind vectors, gusts, vertical drafts, boundary-layer wind shear, storm intensity, cloud cover, precipitation type (`RAIN`/`SNOW`/`DUST`/`ASH`), and storm lightning windows from planetary pressure, temperature, rotation period, volatiles, and volcanicity without altering save-game schemas.
  * Applied balanced aviation-feel aerodynamic forces (`Ship::CalcAtmosphericForce`, `Ship::CalcAtmoTorque`, `Ship::SpawnThrusterExhaustParticles`, `Player::StaticUpdate` turbulence creak): relative-airspeed drag/lift/weathercocking, smooth 3-axis gust & turbulence buffeting attenuated for AI/docking and ground-pad proximity (`< 50 m` with gear down), and wind-driven thruster/dust plumes.
  * Added world-space weather visuals (`src/planet/WeatherEffects.*` in `WorldView`) rendering precipitation/dust/ash streaks and forked 3D storm lightning bolts, plus `planet_clouds.frag` / `GeoSphere.cpp` storm darkening, dust tinting, and internal sheet-lightning illumination.
  * Upgraded `AmbientSounds` (`src/sound/AmbientSounds.cpp`): fixed `NUM_SURFACE_DEAD_SOUNDS` array bounds (`12` -> `6`) and added continuous atmospheric wind, rain/storm loops, and distance-delayed thunder claps.
  * Added Lua `Body:GetWeatherState` (`src/lua/LuaBody.cpp`), adaptive `PlanetaryInfo` HUD wind/turbulence/shear telemetry (`data/pigui/modules/planetary-info.lua`), surface Starport ATC ATIS briefings (`data/modules/StationTrafficControl/StationTrafficControl.lua`), and hysteresis-guarded weather advisories (`data/pigui/modules/master-alarm.lua`).
  * Overhauled all 10 existing cockpit alarms/warnings/sirens/beeps plus 3 new weather alerts (`scripts/generate_cockpit_chimes.py`) into a warm, non-clipping 4-tier acoustic hierarchy (`data/sounds/*.ogg`, `data/sounds/Cockpit/*.ogg`): sweeping/whooping sirens for alarms (`Missile_Inbound`, `danger_siren`, `alarm_emer`, `alarm_descent`, `alarm_generic1`), fast repetitive rounded beeps/boops for warnings (`warning`, `Missile_lock`, `impact_chime`, `weather_windshear`), aircraft "bing-bong" two-tone chimes for awareness notifications (`fuel_low`, `weather_advisory`, `weather_turbulence`), and a single warm "ding" for informational notices (`notify_beep`).
* **Milestone 7 — Vacuum Acoustics & Cockpit AI Voice**:
  * OpenAL low-pass vacuum filtering for exterior sounds vs. crisp hull-transducer impacts/thrusters, plus a non-overlapping priority-queued Cockpit AI advisory voice.

---

## 4B. Track 4: Full 3D Cockpit Interior Overhaul *(Queued)*

* **Milestone 8 — Full 3D Cockpit Interiors, Diegetic Avionics & Canopy Glass**:
  * Replace the current incomplete free-camera cockpit placeholder (`ShipCockpit` / `default_cockpit`) with properly modeled, ship-class-appropriate 3D cockpit interiors with seated pilot framing and unobstructed canopy sightlines.
  * Integrate diegetic flight instrumentation / holographic cockpit MFDs synchronized with PiGui HUD telemetry (speed, attitude, Supercruise, weather/wind advisories, and master caution annunciators).
  * Implement dynamic canopy glass (`cockpit_glass.*`) shaders for micro-abrasion starlight glints, external raindrop/dust streaks, coronal heat shimmer, and cold-running frost crystallization (`< 20%` heat).

---

## 5. Verification Criteria (Milestone 1)

1. **Classic Fallback Integrity**: Toggle **Enhanced Graphics** OFF in Video Settings; verify ships, stations, and stars render identically to Classic Pioneer with no shader errors or artifacts.
2. **Ship & Station PBR Beautification**: Toggle **Enhanced Graphics** ON; inspect ships (in flight, external camera, and docked) and orbital/surface stations—verify realistic metallic/reflective specular highlights, Fresnel rim sheen, crisp panel normal response, and clean emissives without blown-out highlights.
3. **Star Glare & Lens Flare**: Look toward and away from the system star in normal space and Supercruise; verify smooth glare, subtle diffraction/optical flare elements, smooth distance/angle falloff, and proper attenuation when occluded behind a planet or station.
4. **Build & Tests**: `cmake --build build --target pioneer build-data unittest -j 8 && ./build/unittest` passes cleanly with zero shader compile warnings or runtime errors.

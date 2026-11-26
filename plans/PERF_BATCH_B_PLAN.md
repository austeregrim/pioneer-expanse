# Performance & Visual Fixes — Batch B: CPU Caching, Typed Space Lists, WorldView Deduplication, SectorMap Static VBOs & Lua Hygiene

> **Status**: **Completed** (released in `v2026.11.26.1-expanse`, commit `2b79565`).
> **Independent Agent Assignment**: This plan is self-contained and has zero file overlap with Batch A or Batch C.

---

## Scope & Goals

1. **Cache `WeatherSystem::Sample` & Seasonal Orbit Position (`Planet` + `WeatherSystem`)**: Collapse 7–8 redundant per-frame weather/Kepler evaluations near a planet down to 1, with zero gameplay behavior change. Also inspect and verify seasonal phase behavior on short-period worlds.
2. **Typed Celestial Body Lists on `Space` & `SupercruiseController` Loop Cleanup**: Eliminate repeated linear scans over 50–200+ dynamic ship/cargo/missile bodies when looking only for stars, planets, or stations.
3. **Deduplicate `WorldView` Occluder Collection**: Build the camera-space celestial/station occluder list once per frame instead of 3 separate times (lens flares, Supercruise wakes, star coronas).
4. **Eliminate Per-Frame 45k-Star VBO Re-Uploads in `SectorMap`**: Upload static galaxy/regional star clouds once and fade via uniform/material alpha.
5. **Lua HUD Polling & GC Hygiene**: Throttle per-frame HUD `GetWeatherState` calls and hoist constant `Vector2` allocations out of render loops.

---

## File Ownership (Batch B Only)

* `src/Planet.h`
* `src/Planet.cpp`
* `src/planet/WeatherSystem.h`
* `src/planet/WeatherSystem.cpp`
* `src/Space.h`
* `src/Space.cpp`
* `src/ship/SupercruiseController.cpp`
* `src/WorldView.h`
* `src/WorldView.cpp`
* `src/SectorMap.h`
* `src/SectorMap.cpp`
* `data/pigui/modules/master-alarm.lua`
* `data/pigui/modules/planetary-info.lua`
* `data/pigui/modules/radar.lua`
* `data/pigui/modules/flight-ui/supercruise.lua`

---

## Detailed Implementation Tasks

### Task B1: Cache `WeatherSystem::Sample` & Seasonal Orbit Position on `Planet`

**Context**: Currently `WeatherSystem::Sample` (`src/planet/WeatherSystem.cpp:57-350`) runs 2× `Orbit::OrbitalPosAtTime(...)`, 16 octaves of 3D Simplex noise (`Fbm3` × 6 + `noise` × 6), 5× `std::pow`, 4× `std::exp`, and multiple trig calls. Every frame near a planet, it is called 7–8+ times for nearly the same `(planet, camera/player pos, gameTime)` from `GeoSphere`, `WorldView`, `SurfaceScatter`, `WeatherEffects`, `AmbientSounds`, `master-alarm.lua`, `planetary-info.lua`, and `Ship::CalcAtmosphericForce()`.

**Steps**:
1. **Per-Planet Point Weather Cache (`src/Planet.h`, `src/Planet.cpp`)**:
   * Add a `mutable` cache struct inside `Planet`:
     ```cpp
     struct WeatherCache {
         bool valid = false;
         vector3d posRotFrame = vector3d(0.0);
         double gameTime = 0.0;
         WeatherState state{};
     } m_weatherCache;
     ```
   * In `Planet::GetWeatherState(const vector3d &posRotFrame, double gameTime) const`:
     * If `m_weatherCache.valid && (posRotFrame - m_weatherCache.posRotFrame).LengthSqr() < 25.0 && std::abs(gameTime - m_weatherCache.gameTime) < 0.05`, immediately return `m_weatherCache.state`.
     * Note: `25.0` ($5\text{ m}$ radius) and `0.05\text{ s}$` ensure identical gameplay physics, wind gusts, and audio/HUD state while collapsing all camera/player/HUD/sound/scatter queries in a frame (and physics substeps at high FPS) into 1 evaluation.
     * For callers outside `Planet` (`GeoSphere.cpp` calling `WeatherSystem::Sample(sbody, camDir, sampleAltM, gameTime)`), leave `WeatherSystem::Sample` intact or share the seasonal cache below.
2. **Seasonal Orbit Cache & Physics Review (`src/planet/WeatherSystem.h`, `src/planet/WeatherSystem.cpp`)**:
   * In `MakeParamsFromSystemBody` (`WeatherSystem.cpp:83-106`), `orb.OrbitalPosAtTime(gameTime)` and `orb.OrbitalPosAtTime(gameTime + ...)` are evaluated on every single `Sample()` call.
   * Add a small thread-safe/per-Planet or `thread_local` LRU map keyed by `const SystemBody *` (or `uint64_t` seed + `SystemPath` hash + `orb.Period()`) that caches `{ cachedTime, seasonSubsolarLatRad, seasonSolarTrend }` and only recomputes `OrbitalPosAtTime` when `std::abs(gameTime - cachedTime) >= std::min(60.0, orb.Period() * 0.0005)` (while still checking `sbody` pointer validity or storing directly on `Planet` / passing optional `WeatherPlanetParams` cache).
   * **Audit fast-changing seasons**: Check lines `89–106` and `204–219` of `WeatherSystem.cpp`. Notice:
     * When `orb.Period()` is short (e.g., a close-in planet or moon orbiting a parent, wait: `while (orbBody->GetParent() && orbBody->GetParent()->GetSuperType() != SUPERTYPE_STAR)` walks up to the planet orbiting the star, which is good, **but** hot Jupiters/close rocky worlds have orbital periods of only a few days!). Also check `TestWeatherSystem.cpp` so all existing unit tests continue to pass untouched.
   * Replace `std::pow((...), 2.0)` in `WeatherSystem.cpp:239, 240, 242, 284` with explicit squaring (`x * x`).

---

### Task B2: Typed Celestial Body Lists on `Space` & `SupercruiseController` Cleanup

**Files**: `src/Space.h`, `src/Space.cpp`, `src/ship/SupercruiseController.cpp`

**Context**: `SupercruiseController.cpp` iterates over the full `Pi::game->GetSpace()->GetBodies()` list in 8 hot paths (`L310`, `L945`, `L1335`, `L1456`, `L1574`, `L1615`, `L1806`, `L2380`), filtering only for `STAR`, `TERRAINBODY`, or `SPACESTATION`. In busy systems with 50–200+ ships, cargo pods, and missiles, every NPC in Supercruise pays $O(N_{\text{all bodies}})$.

**Steps**:
1. **Add Typed Lists to `Space` (`src/Space.h`, `src/Space.cpp`)**:
   * Add private vectors:
     * `std::vector<Body *> m_stars;`
     * `std::vector<Body *> m_terrainBodies;` (all `ObjectType::TERRAINBODY`, which includes `PLANET` and `STAR` — or keep `m_terrainBodies` matching `b->IsType(ObjectType::TERRAINBODY)` just like callers expect!)
     * `std::vector<Body *> m_stations;` (`ObjectType::SPACESTATION`)
   * Update them in `Space::AddBody(Body *)`, `Space::RemoveBody(Body *)`, and `Space::UpdateBodies()` when `KILL`/`REMOVE` prunes bodies (and clear in `~Space()` if needed; also check `Space` JSON load constructor to ensure `AddBody` is used or lists are populated).
   * Expose const/non-const `IterationProxy` getters:
     * `GetStars()`
     * `GetTerrainBodies()`
     * `GetStations()`
2. **Update `SupercruiseController.cpp`**:
   * Replace `GetBodies()` with `GetStars()` at `L1335` (`UpdateFuelScoop`).
   * Replace `GetBodies()` with `GetTerrainBodies()` at `L945`, `L1456`, `L1574`, `L1615`, `L1806`, `L2380`.
   * In `IsMassLocked` (`L310`), iterate `GetStations()` then `GetTerrainBodies()` instead of scanning all ships/missiles/cargo.

---

### Task B3: Deduplicate `WorldView` Per-Frame Occluder Collection

**Files**: `src/WorldView.h`, `src/WorldView.cpp`

**Context**: `WorldView.cpp` allocates a fresh `std::vector` and iterates over all `GetBodies()` 3 separate times every frame:
1. Lens flare occlusion (`L819-850`)
2. Supercruise wake occlusion (`L995-1026`)
3. Star corona / target occlusion (`L1353`)

**Steps**:
1. Define a single `WorldView::FrameOccluder` struct in `src/WorldView.h` (matching the union of needed fields: `pos`, `dist`, `radius`, `maxRadius`, `orientToCam`, `terrainBody`, `isStation`, `isInteriorBlocking` or handle station interior check cleanly) and a reusable member `std::vector<FrameOccluder> m_frameOccluders;` plus `bool m_insideOrbitalStation = false;`.
2. Add `void BuildFrameOccluders(FrameId camFrameId);` called once per frame before the flare / SC-wake / corona passes, iterating **only** `GetSpace()->GetStations()` and `GetSpace()->GetTerrainBodies()` (instead of all `GetBodies()`).
3. Reuse `m_frameOccluders` in all three passes, removing the duplicate per-frame vector allocations and repeated `GetInterpPositionRelTo` / `GetInterpOrientRelTo` calls.
4. Hoist the fullscreen lens-flare `Graphics::VertexArray` (`WorldView.cpp:855`) to a persistent member `m_flareQuadVerts` (rebuilt only when `winW` or `winH` changes).

---

### Task B4: Eliminate Per-Frame 45,000-Star VBO Re-Uploads in `SectorMap`

**Files**: `src/SectorMap.h`, `src/SectorMap.cpp`

**Context**: When zoomed out in the Galaxy/Sector Map:
* `SectorMap.cpp:2161-2170` loops over **45,000** `m_galaxyCloudBaseColor` entries every frame to scale alpha by `m_macroAlpha`, then calls `m_galaxyCloudPoints.SetData(...)` to re-upload 45,000 vertices + colors to the GPU.
* `SectorMap.cpp:2200-2206` does the same every frame for `m_regionalStarPoints`.
* `SectorMap.cpp:1303` copies `std::vector<Color> fadedColors = m_farstarsColor;` on the heap every frame when zoomed out.
* `SectorMap.cpp:2213-2260` recomputes hundreds of `std::cos`/`std::sin` line vertices every frame for static galactic core / Sol range rings.

**Steps**:
1. Check what material/shader `m_galaxyCloudPoints` and `m_regionalStarPoints` (`m_farStarsMat`) use in `SectorMap.cpp` (`PointSprites` -> check `src/graphics/Drawables.cpp` and `data/shaders/opengl/points.vert` / `vtxColor`).
2. Upload `m_galaxyCloudPoints` once after generation with `m_galaxyCloudBaseColor`, and upload `m_regionalStarPoints` only inside `UpdateRegionalStarField(...)`. Fade their alpha via a material color/uniform (`m_farStarsMat->diffuse` or a dedicated material/push constant per layer so `diffuse.a` multiplies vertex color alpha cleanly) instead of rewriting vertex buffers every frame.
3. For `m_farstarsColor` (`L1303`), reuse a preallocated member `m_farstarsDrawColor` buffer (or uniform alpha) rather than heap-allocating `fadedColors` every frame.
4. Precompute unit-circle sin/cos tables (or cached static `VertexArray`s scaled/colored by transform/material) for `addCircleXY` (`L2213-2260`).

---

### Task B5: Lua HUD Throttling & Constant `Vector2` Hoisting

**Files**:
* `data/pigui/modules/master-alarm.lua`
* `data/pigui/modules/planetary-info.lua`
* `data/pigui/modules/radar.lua`
* `data/pigui/modules/flight-ui/supercruise.lua`

**Steps**:
1. **Throttle `GetWeatherState` in Lua HUD**:
   * In `master-alarm.lua:211` and `planetary-info.lua:61`, cache the returned Lua weather table per `frame` for `0.20` seconds of `Game.time` (invalidate immediately if `frame` changes or `onGameEnd` fires). Cuts per-frame Lua table allocations and Lua->C++ crossings by ~12× at 60 FPS.
2. **Hoist Constant `Vector2` Allocations**:
   * In `radar.lua` and `supercruise.lua`, move constant `Vector2(...)` literals inside per-frame draw loops (e.g., `Vector2(12, 12)`, `Vector2(0, 1)`, `Vector2(1, 0)`, `Vector2(0, -1)`, `Vector2(-1, 0)`, `Vector2(8, 26)`, `Vector2(0, 0)`) to file-level `local` constants so LuaJIT/Lua doesn't allocate and GC dozens of userdata objects every frame.

---

## Verification & Pitfalls

1. **Build & Unit Tests**:
   ```bash
   cmake --build build --target pioneer build-data -j 8
   cmake --build build --target unittest && ./build/unittest
   ```
   Verify `TestWeatherSystem` passes completely.
2. **Runtime Verification**:
   * Fly into an atmospheric planet's clouds/storms, verify `planetary-info` and `master-alarm` still react promptly, wind/turbulence feels identical, and frame times drop.
   * Hyperspace jump between systems and load a save to verify `Space::m_stars`, `m_terrainBodies`, and `m_stations` stay consistent on system transitions and body destruction.
   * Open the Galaxy/Sector Map (`F2`), zoom all the way out to `100,000 ly`, pan/orbit smoothly, and verify galaxy cloud, regional star cloud, and range rings fade identically without per-frame stutter.
3. **Watch Out For**:
   * Keep `Space`'s typed body lists (`m_stars`, `m_terrainBodies`, `m_stations`) strictly synchronized across **all** paths that add or remove bodies (`AddBody`, `RemoveBody`, `UpdateBodies`, and the JSON load constructor in `Space.cpp`).
   * Ensure `Planet::m_weatherCache` is cleared or naturally invalidated if `gameTime` jumps backward (e.g., `std::abs(gameTime - m_weatherCache.gameTime) < 0.05` handles backward jumps safely!).

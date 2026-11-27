# Performance & Visual Fixes — Batch A: Planet/Sky Shaders, Cloud & Sunset Fixes (#5, #6), & Planet Inspector

> **Status**: **Completed** (released in `v2026.11.26-expanse`, commit `3e5a2e2`).
> **Independent Agent Assignment**: This plan is self-contained and has zero file overlap with Batch B or Batch C.
> *(Note: In `src/GeoSphere.cpp`, Batch A **only** modifies `GeoSphere::Render()` lines ~600–690 for clouds; Batch C only modifies `GeoSphere::Update()` / `ProcessQuadSplitRequests()`.)*

---

## Scope & Goals

1. **Planet Inspector Debug View (Upgrade `ObjectViewerView`)**: Turn Pioneer's built-in `ObjectViewerView` into a clean, isolated planet/body rendering inspector (no stations or ships) launchable from the System Map (`system-view-ui.lua`) or keybind, with camera presets (50 m surface to high orbit), live Sun Azimuth/Elevation scrub, quality/shader toggles, and FPS/frame-time readout.
2. **Terrain Shader Distance Gating & Unused Tap Removal**: Cut orbital/mid-altitude ALU and texture bandwidth in `geosphere_terrain.frag` and `rayleigh_geosphere_terrain.frag` by 60–75% without altering close-up or orbital visuals.
3. **Fix GitHub Issue #5 (Cloud Layer Flicker) + Realistic Thin-Atmosphere Cloud Speed + Early `effCoverage` Discard**: Smoothly cross-fade cloud shell inside/outside material switching and depth bias, scale cloud drift speed inversely by planet radius and proportionally to atmospheric density, and move `effCoverage` discard before FBM.
4. **Fix GitHub Issue #6 (Sunset & Sunrise Skybox Flicker)**: Prevent the local planet's geometric shadow from snapping `bgIntensity` off/on across the horizon so dusk and dawn fade smoothly between day sky, sunset edge-lit clouds, twilight, and night skybox.
5. **Quick Shader Tightening**: Gate east/west zonal FBM in `gassphere_base.frag`, gate high-latitude `skybox.frag` FBM, hoist invariant Rayleigh constants in `rayleigh-lib.glsl`, distance-gate `planetrings.frag` noise taps, and replace `pow(x, N)` with multiplications in `multi.frag`.

---

## File Ownership (Batch A Only)

* `src/ObjectViewerView.h`
* `src/ObjectViewerView.cpp`
* `src/lua/LuaGame.cpp` (only adding `Game.InspectBody` / `Game.ToggleObjectViewer` binding)
* `data/pigui/modules/system-view-ui.lua` (only adding "Inspect Body" button for selected system body)
* `src/Camera.h` & `src/Camera.cpp` (`CalcShadows` / `ShadowedIntensity` optional `ignoreBody` + `Update()` `bgIntensity` block lines ~287–367)
* `src/GeoSphere.cpp` (only `Render()` cloud setup lines ~600–690)
* `data/shaders/opengl/geosphere_terrain.frag`
* `data/shaders/opengl/rayleigh_geosphere_terrain.frag`
* `data/shaders/opengl/planet_clouds.frag`
* `data/shaders/opengl/gassphere_base.frag`
* `data/shaders/opengl/skybox.frag`
* `data/shaders/opengl/rayleigh-lib.glsl`
* `data/shaders/opengl/planetrings.frag`
* `data/shaders/opengl/multi.frag`

---

## Detailed Implementation Tasks

### Task A1: Upgrade `ObjectViewerView` into a Full Planet Inspector (No Ships/Stations)

**Context**: `CMakeLists.txt:194` already enables `option(WITH_OBJECTVIEWER "Include the object viewer in the build" ON)`, and `Pi::ToggleObjectViewer()` (`src/Pi.cpp:1332-1342`) switches between `WorldView` and `Game::GetObjectViewerView()`. Currently `ObjectViewerView` (`src/ObjectViewerView.h`, `src/ObjectViewerView.cpp`) only tracks `Pi::player->GetNavTarget()`, renders without skybox, has a fixed light direction `(0.577, 0.577, 0.577)`, and lacks surface-altitude presets or quality/frame-time telemetry.

**Steps**:
1. **Body Selection & View Return (`src/ObjectViewerView.h`, `src/ObjectViewerView.cpp`)**:
   * Add `void SetTargetBody(Body *body);` and store `View *m_returnView` (captured in `OnSwitchTo()` if coming from `WorldView`, `SystemView`, etc.) with a "Return" button / `Esc` handling.
   * Keep `Pi::player->GetNavTarget()` as fallback when opened via hotkey, plus an ImGui dropdown listing all `TERRAINBODY` and `STAR` bodies in `Pi::game->GetSpace()->GetBodies()` so any body in the current system can be inspected directly without flying to it.
   * Render **only** the background skybox (`Pi::game->GetSpace()->GetBackground()->Draw(...)`) + `m_targetBody->Render(...)` — never ships or stations.
2. **Camera Modes & Altitude Presets**:
   * **Orbital Free-Cam**: Keep RMB-drag rotation (`m_camRot`), add mouse-wheel zoom (`viewingDist`), plus `Shift` fine-zoom.
   * **Surface / Horizon Cam**: Allow switching to a horizon-aligned camera over `(latDeg, lonDeg)` at `altitudeM` above terrain (`GetTerrainHeight(unitDir)`), with pitch/yaw RMB look and quick altitude buttons: `50 m`, `2 km`, `8 km (Cloud Deck)`, `40 km`, `Orbit (1.5R)`, `Far (4R)`.
   * Properly update `m_cameraContext` frame/pos/orient and compute `bgIntensity` from the same atmospheric twilight formula used in `Camera::Update()` so sunset/sunrise skybox transitions (#6) can be inspected directly!
3. **Sun Direction Scrub & Visual Debug Controls**:
   * Add **"Override Sun"** toggle with **Sun Elevation (`-25°` to `+90°`)** and **Sun Azimuth (`0°` to `360°`)** sliders relative to the camera's local zenith/north (or body frame) so sunset, sunrise, twilight, and surface scatter shadows (#3) can be scrubbed frame-by-frame.
   * Add **Render Quality & Mode Controls**: `EnhancedGraphics` toggle, `AtmosphereQuality` (`0..4`), `WaterQuality` (`0..3`), `SurfaceScatterQuality` (`0..4`), `DetailPlanets` (`0..4`), `GeoSphere` wireframe toggle (`GeoSphere::SetDebugFlags`), and a live **FPS / Frame Time (ms)** readout (`ImGui::GetIO().Framerate`).
   * Keep the existing `SystemBody` parameter sliders behind a collapsible "Terrain Seed / Params (Mutates Body)" header so normal inspection never accidentally mutates the live system.
4. **Lua Entry Point (`src/lua/LuaGame.cpp` & `data/pigui/modules/system-view-ui.lua`)**:
   * Expose `Game.InspectBody(body)` (resolving `SystemBody` -> `Space::FindBodyForPath(&sbody->GetPath())` or taking a `Body*`, setting `ObjectViewerView::SetTargetBody`, and calling `Pi::SetView(Pi::game->GetObjectViewerView())`).
   * In `data/pigui/modules/system-view-ui.lua`, when a planet/moon/star is selected in the System Map sidebar, add an **"Inspect Planet"** button (guarded by `Game.InspectBody`) that jumps straight into `ObjectViewerView` focused on that body.

---

### Task A2: Distance-Gate Terrain Shaders & Skip Unused Classic Taps

**Files**: `data/shaders/opengl/geosphere_terrain.frag`, `data/shaders/opengl/rayleigh_geosphere_terrain.frag`

1. **Skip `hidetail` / `lodetail` in Enhanced Mode (`geosphere_terrain.frag:99-113`)**:
   * Currently `texture(texture0, ...)` and `texture(texture1, ...)` plus `exp(-0.004 * dist)` / `exp(-0.001 * dist)` execute unconditionally, even though Enhanced mode ignores `detailMul` (`L608`, `L642`).
   * Move those two texture fetches and `exp()` calls inside `if (enhancedGraphics < 0.5)` (or initialize `vec4 detailMul = vec4(1.0);` and only populate it when `!enhanced`).
2. **Hoist Distance & Fade Calculations (`geosphere_terrain.frag:153-166, 472-473, 501-518`)**:
   * Compute `metersPerViewUnit`, `distMeters`, `macroFade`, `midFade`, `closeFade`, `microFade`, and `fineFade` **once** per fragment instead of recomputing them across three separate blocks.
3. **Distance-Gate 3D FBM Octaves & Tri-Planar Texture Taps** (apply identically to both `geosphere_terrain.frag` and `rayleigh_geosphere_terrain.frag`):
   * Initialize `float triMacro = 0.0, triMid = 0.0, triClose = 0.0, triMicro = 0.0, triFine = 0.0;`
   * Always compute `macroGrad` and `microDetail` (unit-sphere FBM, visible from orbit), and `triMacro = geoFbm3D(...) * 2.0 - 1.0` when `macroFade > 0.005` (or always for coastline breakup if `rawWater > 0.01 && rawWater < 0.985`).
   * Gate `triMid` on `if (midFade > 0.005 || (rawWater > 0.01 && rawWater < 0.985))`.
   * Gate `triClose` on `if (closeFade > 0.005 || (rawWater > 0.01 && rawWater < 0.985))`.
   * Gate `triMicro` on `if (microFade > 0.005)` and `triFine` on `if (fineFade > 0.005)`.
   * Gate the 3 tri-planar texture cascades (`regMacro` + `clfMacro` on `midFade > 0.005`, `regMid` + `clfMid` on `closeFade > 0.005`, `regNear` + `clfNear` on `microFade > 0.005`), defaulting un-sampled taps to `vec4(0.5, 0.5, 0.5, 0.65)`.
4. **Optimize `sampleTriPlanar`**:
   * Replace unconditional 3-axis sampling with:
     ```glsl
     vec4 sampleTriPlanar(sampler2D tex, vec3 wPos, vec3 tw, float invScale)
     {
         vec4 acc = vec4(0.0);
         if (tw.x > 0.01) acc += texture(tex, wPos.yz * invScale) * tw.x;
         if (tw.y > 0.01) acc += texture(tex, wPos.xz * invScale) * tw.y;
         if (tw.z > 0.01) acc += texture(tex, wPos.xy * invScale) * tw.z;
         return acc;
     }
     ```
5. **Replace Integer `pow()`**:
   * Replace `pow(abs(sDir), vec3(4.0))` with `vec3 aDir = sDir * sDir; vec3 triW = aDir * aDir;` and `pow(1.0 - VdotH, 5.0)` / `pow(1.0 - NdotVWater, 4.0)` with explicit multiplications.

---

### Task A3: Fix Issue #5 (Cloud Flicker), Realistic Cloud Drift Speed, & Early `effCoverage` Discard

**Files**: `src/GeoSphere.cpp` (`Render()` lines ~600–690), `data/shaders/opengl/planet_clouds.frag`

1. **Fix Issue #5 — Eliminate Near-Plane Material Switch & Depth Bias Flicker**:
   * **Material Switch Margin (`GeoSphere.cpp:658`)**: Currently `camLenD < boundRadD * 0.996` switches from `m_cloudMaterial` (`CULL_BACK`) to `m_cloudInsideMaterial` (`CULL_FRONT`). At `boundRadD * 0.996..1.000`, the camera is inside or clipping the front faces of the bounding icosphere, causing front-faces to vanish/flicker right at cloud-layer crossing and orbital entry.
     * Fix: Compute a near-plane safe switch radius: e.g., obtain `znear` (or use `boundRadD * 1.03` / `camLenD < boundRadD + safeNearMargin` where `safeNearMargin = std::max(0.015, znear / planetRadM * 4.0)`). Switching to `m_cloudInsideMaterial` (`CULL_FRONT`) slightly **outside** `boundRadD` is completely safe because the fragment shader performs an exact analytical ray-sphere intersection (`planet_clouds.frag:134-150`) and discards misses—no front-face clipping can ever occur.
   * **Smooth Depth Bias (`planet_clouds.frag:152-159`)**: Replace the discontinuous steps:
     ```glsl
     if (camAltKm > cloudAltKm + 25.0) distZ *= 0.992;
     else if (camAltKm > cloudAltKm + 5.0) distZ *= 0.997;
     ```
     with a continuous curve:
     ```glsl
     float biasScale = mix(1.0, 0.992, smoothstep(cloudAltKm + 3.0, cloudAltKm + 30.0, camAltKm));
     distZ *= biasScale;
     ```
   * **Wider `shellPassFade` (`planet_clouds.frag:121`)**: Widen `smoothstep(0.18, 1.15, abs(camAltKm - cloudAltKm))` slightly (e.g. `smoothstep(0.25, 1.80, ...)`) and apply a gentle fade at the upper orbital transition if needed so entering/leaving a cloud deck never pops.
2. **Fix Cloud Drift Speed for Thin Atmospheres & Planet Radius**:
   * **Current bug**: `planet_clouds.frag:168` uses `driftAngle = uTime * 0.00018 * windDriftScale;` (`0.00018 rad/s` = **1,147 m/s** on Earth!), and `GeoSphere.cpp:640` clamps `windDriftScale = Clamp(0.75 + 0.35 * std::min(atmo, 2.5), 0.50, 1.80)` so thin 0.05–0.15 atm worlds move almost as fast as Earth.
   * **Fix in `GeoSphere.cpp:640`**: Compute physical wind scaling from `atmo` (and `weather.windSpeed` when near surface) divided by planet radius relative to Earth (`6371.0 km`):
     ```cpp
     const double atmoDrive = Clamp(std::pow(std::max(atmo, 0.01), 0.65), 0.06, 1.65);
     const double radiusRatio = Clamp(planetRadM / 6371000.0, 0.15, 25.0);
     const float windDriftScale = float(Clamp((atmoDrive / radiusRatio) * (1.0 + 0.35 * stormIntensity), 0.02, 2.5));
     ```
   * **Fix in `planet_clouds.frag:168, 172`**: Reduce base `driftAngle` rate to realistic tropospheric/jet-stream angular velocity (e.g., `uTime * 0.0000075 * windDriftScale` -> ~48 m/s = ~170 km/h on Earth at `windDriftScale = 1.0`, and ~4–8 m/s on thin-atmo Mars-like worlds), and scale `tMorph` to `uTime * 0.000045 * windDriftScale`. Also update `WeatherSystem.cpp` only if Batch B isn't touching it—actually leave `WeatherSystem.cpp` to Batch B (note this in Batch B plan or keep shader-only here).
3. **Move `effCoverage` Early-Out Before FBM (`planet_clouds.frag:166-225`)**:
   * Compute `surfaceBlend`, `underCloud`, `camDistKm`, `localZone`, and `effCoverage` right after `dir` is calculated (`L163`), and run `if (effCoverage <= 0.01) discard;` **before** evaluating `clFbm3D` / `warp` / `fronts` / `wisps`.
   * Pre-normalize `camDirObj` and `flashCell.xyz` in `GeoSphere.cpp` (`L617`, `L649`) so `planet_clouds.frag` doesn't call `normalize()` per pixel.
   * Replace `pow(..., 2.0)` and `pow(..., 6.0)` in `planet_clouds.frag:268, 271` with multiplies.

---

### Task A4: Fix Issue #6 (Sunset & Sunrise Skybox Flicker)

**Files**: `src/Camera.h`, `src/Camera.cpp` (`Update()` lines ~287–367, `CalcShadows()` / `ShadowedIntensity()` lines ~569–659)

**Root Cause**:
In `Camera.cpp:309`, inside `if (pressure >= 0.001)`:
```cpp
const float shadow = ShadowedIntensity(i, pBody);
...
const float sunSinElev = lightDir.Dot(localUp);
const float t = Clamp((sunSinElev - (-0.24f)) / ((-0.015f) - (-0.24f)), 0.0f, 1.0f);
const float twilightDay = t * t * (3.0f - 2.0f * t);
skyWashout = Clamp(skyWashout + shadow * starLum * twilightDay, 0.0f, 1.0f);
```
`ShadowedIntensity(i, pBody)` computes spherical disc occlusion against **all** bodies including `camParentBody` (the planet the camera is on). At the geometric horizon (`sunSinElev ≈ 0` to `-critAngle`), `shadow` drops sharply from `1.0` to `0.0` (and oscillates if altitude/orbit jitters by a meter), fighting `twilightDay` and causing `bgIntensity` to snap between `0.0` (blue/dusk atmosphere) and `1.0` (starfield skybox). The same happens in `maxStarGlare` at `Camera.cpp:361`.

**Fix**:
1. Add an optional parameter `const Body *ignoreBody = nullptr` to `Camera::CalcShadows(const int lightNum, const Body *b, std::vector<Shadow> &shadowsOut, const Body *ignoreBody = nullptr) const` and `Camera::ShadowedIntensity(const int lightNum, const Body *b, const Body *ignoreBody = nullptr) const`, skipping `ignoreBody` inside `CalcShadows`.
2. In `Camera::Update()` (`L309`), pass `camParentBody` as `ignoreBody` (`ShadowedIntensity(i, pBody, camParentBody)`). That way, **eclipses by moons or binary companions** still darken the twilight sky, while the local planet's sunset/sunrise horizon transition is governed smoothly by `twilightDay`.
3. Extend/tune the `twilightDay` elevation window if needed (e.g., `-0.26f` (~15° below horizon, civil→nautical→astronomical twilight) to `+0.03f` (~1.7° above horizon)) and incorporate `atmoOpacity` / `pressure` scaling so thin atmospheres transition faster and thick atmospheres hold a longer dusk/dawn glow—giving the exact smooth sequence:
   `Day Sky → Edge-lit Sunset → Dusk Fade → Galactic Skybox → Dawn Fade → Edge-lit Sunrise → Day Sky`.
4. Also in the `maxStarGlare` loop (`L332-365`), when `m_inAtmosphere` is true, pass `camParentBody` as `ignoreBody` and multiply `glare` by a smooth horizon elevation fade (`smoothstep(-0.04f, 0.04f, sunSinElev)`) so glare doesn't snap across the horizon.

---

### Task A5: Additional Quick Shader Wins

1. **`data/shaders/opengl/gassphere_base.frag`**:
   * Guard the east FBM block (`L192-206`) on `if (jetBlend > 0.001)` and west block on `if (jetBlend < 0.999)` (defaulting un-evaluated side to `0.5`). Cuts gas giant fragment ALU nearly in half across ~78% of the sphere.
   * Replace `pow(..., 2.0)` at `L119, L283, L324` with squaring.
2. **`data/shaders/opengl/skybox.frag`**:
   * Pre-normalize `planeNormal` and `coreDir` as `const vec3`.
   * Gate `rift` on `if (lat < 0.55)` (`exp(-0.55 * 11.0) ≈ 0.002`) and `nebWarm`/`nebCool` on `if (lat < 0.95)`.
3. **`data/shaders/opengl/rayleigh-lib.glsl`**:
   * Hoist `betaR`, `betaM`, `betaOzone` once per `processLight`, `calculateRayInscattering`, and `calculateReflectedSkyColor` call and pass them into a `calcTransmittancePrecomputed(opticalDepth, betaR, betaM, betaOzone)` helper instead of re-evaluating the 3 `getAtmosBeta*()` conditionals on every raymarch sample.
4. **`data/shaders/opengl/planetrings.frag`**:
   * Gate `coarseNoise` on `if (coarseDistance > 0.001)` and `fineNoise` on `if (fineDistance > 0.001)`.
   * Normalize `uLight[i].position.xyz` once per light (`vec3 lightDir = normalize(uLight[i].position.xyz);`), reuse `mu` as `muRev = -mu`, and replace `pow(x, 2.0)` with `x * x`.
5. **`data/shaders/opengl/multi.frag`**:
   * Replace `pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0)` in `FresnelSchlick` (`L70`) and `FresnelSchlickRoughness` (`L75`) with explicit `t2 = t * t; t2 * t2 * t`.

---

## Verification & Pitfalls

1. **Build & Unit Tests**:
   ```bash
   cmake --build build --target pioneer build-data -j 8
   cmake --build build --target unittest && ./build/unittest
   ```
2. **Visual Verification via Planet Inspector**:
   * Open System Map (`F2`), select Earth / Mars / a gas giant / a ringed planet, click **Inspect Planet**.
   * Scrub **Sun Elevation** from `+20° → 0° → -18° → +20°`: verify zero skybox flicker (#6), smooth dusk/dawn transition, and edge-lit sunset clouds.
   * Sweep **Altitude** from `50 m → 2 km → 8 km → 40 km → Orbit`: verify zero cloud shell flicker or depth-pop (#5).
   * Check thin-atmosphere planet (e.g., Mars or a 0.05 atm moon): verify clouds drift gently rather than racing across the sky.
   * Compare orbital, mid-altitude, and 50 m terrain visuals against pre-change quality while checking the FPS / ms readout.
3. **Watch Out For**:
   * Uniform Quad Control Flow for `dFdx`/`dFdy`: In `geosphere_terrain.frag` / `rayleigh_geosphere_terrain.frag`, keep `dFdx(varyingEyepos)`, `dFdy(varyingEyepos)`, `dFdx(bumpMeters)`, and `dFdy(bumpMeters)` outside non-uniform pixel branches (just ensure `bumpMeters` is cleanly initialized to `0.0` when gated).
   * Keep `ObjectViewerView` guarded cleanly inside `#if WITH_OBJECTVIEWER`.

# Performance & Visual Fixes — Batch C: Hardware Instancing (`RingField` & `SurfaceScatter`), Scatter Shadows (#3), & Proactive Planet LODs (#9)

> **Status**: **Completed** (released in `v2026.11.26.2-expanse`, including time-dilation, LRU sizing, instanced scratch-buffer, and visual/audio/supercruise fixes).
> **Independent Agent Assignment**: This plan is self-contained and has zero file overlap with Batch A or Batch B.
> *(Note: In `src/GeoSphere.cpp`, Batch C **only** modifies `Update()` / `UpdatePreloadState()` / `ProcessQuadSplitRequests()` / LOD preloading; Batch A only modifies `Render()` cloud setup.)*

---

## Scope & Goals

1. **Hardware Instancing for `RingField` & `SurfaceScatter` + Indexed Rock Meshes**: Eliminate **4,500–7,500 draw calls** in planetary rings and **750–1,400 draw calls** on planetary surfaces by batching boulders per variant into `glDrawElementsInstanced` (already supported by `CommandBufferGL`).
   * **Ring Mining Guarantee**: Mining raycasts (`RingField::TraceRay`), collision physics (`RingField::CheckCollisions` / `TimeStepUpdate`), and rock depletion (`m_depletedYield`) remain 100% CPU-identical and unaffected by GPU instancing.
2. **LRU Cell Caches for `RingField` & `SurfaceScatter`**: Add bounded cell caching to `RingField` (eliminating ~4,820 cell regenerations/frame) and replace `SurfaceScatter::m_cellCache.clear()` with LRU eviction (eliminating periodic surface traversal hitches).
3. **Fix GitHub Issue #3 (Shadows From and On Planet Surface Scatter)**:
   * **On scatter**: Occlude star lighting on boulders using planet horizon elevation + `WeatherSystem::ComputeTerrainRayVisibility(...)` so boulders are never lit through the planet or behind mountain ridges.
   * **From scatter**: Render batched directional ground contact/cast shadows beneath visible boulders projected away from the primary star.
4. **Fix GitHub Issue #9 (Proactive Planet Surface LOD Calculations) & `GeoPatch` Uniform Caching**: Pre-split surface LODs on the player's targeted planet/moon while approaching, and cache invariant patch shader uniforms on `GeoPatch`.

---

## File Ownership (Batch C Only)

* `src/graphics/Renderer.h`
* `src/graphics/dummy/RendererDummy.h`
* `src/graphics/opengl/RendererGL.h` & `src/graphics/opengl/RendererGL.cpp`
* `src/graphics/opengl/CommandBufferGL.h` & `src/graphics/opengl/CommandBufferGL.cpp` (only if adding an instanced `MeshObject` helper or using existing `DrawBuffersCmd` with `instanceCount`)
* `data/shaders/opengl/rock_instanced.shaderdef`
* `data/shaders/opengl/rock_instanced.vert`
* `data/shaders/opengl/rock_instanced.frag` (or `multi.frag` variant if appropriate—dedicated `rock_instanced.*` keeps Batch A's `multi.frag` untouched!)
* `src/planet/RingField.h` & `src/planet/RingField.cpp`
* `src/planet/SurfaceScatter.h` & `src/planet/SurfaceScatter.cpp`
* `src/GeoPatch.h` & `src/GeoPatch.cpp`
* `src/GeoSphere.h` & `src/GeoSphere.cpp` (only `Update()`, `ProcessQuadSplitRequests()`, and new `PreloadTargetLOD()` — do **not** touch `Render()` cloud code)

---

## Detailed Implementation Tasks

### Task C1: Instanced Rock Rendering Path & Indexed Rock Meshes

**Context**: `CommandBufferGL::ExecuteDrawBuffersCmd` (`src/graphics/opengl/CommandBufferGL.cpp:358-366`) already executes `glDrawElementsInstanced` / `glDrawArraysInstanced` when `cmd.instanceCount > 1`, and `VertexArray` / `VertexBuffer` already exist. However, `RingField` and `SurfaceScatter` currently call `r->SetTransform(m)` + `r->DrawMesh(...)` per rock, and `BuildRockMesh` emits unindexed triangle soups (`320 * 3 = 960` verts instead of `162` indexed verts at `subdivs = 2`).

**Steps**:
1. **Renderer Instanced Draw Helper (`src/graphics/Renderer.h`, `RendererGL`, `RendererDummy`)**:
   * Check how `DrawBuffer` / `DrawMesh` / `DrawMeshInstanced` map to `CommandList::AddDrawBuffersCmd` in `RendererGL.cpp`.
   * Add a clean virtual method on `Graphics::Renderer` (implemented in `RendererGL` and no-op `RendererDummy`):
     ```cpp
     virtual bool DrawMeshInstanced(MeshObject *mesh, Material *material, VertexBuffer *instanceBuffer, uint32_t instanceOffset, uint32_t instanceCount) = 0;
     ```
     (Or expose multi-stream `DrawMesh` taking a span of vertex buffers + `instanceCount` so `CommandBufferGL::ExecuteDrawBuffersCmd` binds `mesh`'s vertex buffer at stream 0 with step `PER_VERTEX` and `instanceBuffer` at stream 1 with step `PER_INSTANCE` via `glVertexBindingDivisor(1, 1)`.)
   * Verify `VertexFormatDesc` / `OGL::VertexFormat` (`src/graphics/opengl/`) supports per-instance `ATTRIB_FORMAT` bindings cleanly (`glVertexAttribDivisor`).
2. **Dedicated Instanced Rock Shader (`data/shaders/opengl/rock_instanced.*`)**:
   * Create `rock_instanced.shaderdef`, `rock_instanced.vert`, and `rock_instanced.frag`:
     * Vertex attributes: `a_position`, `a_normal`, `a_color`, `a_uv0`, `a_tangent` (when `MAP_NORMAL` enabled) + per-instance attributes:
       * `i_modelCol0..3` (`vec4` × 4 = model matrix in view space, since `RingField` and `SurfaceScatter` already build double-precision view-space `bx, by, bz, posView`!)
       * `i_diffuse` (`vec4` RGB tint + alpha)
       * `i_emissive` (`vec4` RGB sky-bounce/spotlight boost)
     * Fragment shader: replicate the PBR/Blinn-Phong rock lighting from `multi.frag` (including `MAP_NORMAL` with `rock_diffuse.png`/`rock_normal.png` and `spotlights.glsl`), **plus** a `uniform vec4 rockLightScale;` (or per-instance `i_sunVis` in `i_emissive.a`) so direct starlight (`uLight[i]`) is attenuated by horizon/terrain occlusion (#3).
     * Keeping `rock_instanced.*` separate avoids any merge conflict with Batch A's edits to `multi.frag`.
3. **Convert `BuildRockMesh` to Indexed Geometry (`RingField.cpp` & `SurfaceScatter.cpp`)**:
   * Build shared vertices + `IndexBuffer` (`uint16_t`) in `BuildRockMesh`. Note: when `withTangents == true`, `projectTriUV` depends on `domAxis` per face, so either compute smooth spherical/tri-planar UVs per vertex (eliminating face seams too!) or deduplicate `(vertexIndex, domAxis)` pairs. Smooth vertex UVs/tangents or `(pos, norm, color, uv, tang)` deduplication reduces vertex count by ~4–6×.

---

### Task C2: `RingField` Hardware Instancing + LRU Cell Cache (Mining Preserved)

**Files**: `src/planet/RingField.h`, `src/planet/RingField.cpp`

1. **Preserve Mining & Collisions 100%**:
   * Do **not** alter `RingField::TraceRay` (`m_depletedYield` depletion, fragment spawning, hit distance) or `RingField::TimeStepUpdate` collision resolution.
   * Only accelerate `GatherCellRocks` + `Render`.
2. **Add Bounded O(1) LRU Cell Cache**:
   * Implemented an O(1) `std::list` + `std::unordered_map` LRU cache with `MAX_CACHED_CELLS = 6144` (covering the ~4,820-cell working set across all 4 tiers without thrashing) keyed by `{ gx, gz, RockTier }` storing only static, un-spun `RockInstance` data (`phase`, `spinRate`, `pos`, etc.) so `m_elapsedTime`-driven spin and mining remain 100% time-dilation accurate.
   * In `Render`, continue checking `m_depletedYield.find(inst.id)` when gathering `visibleRocks` so mined-out boulders disappear immediately as before.
3. **Math & Culling Tightening (`RingField.cpp:705-801`)**:
   * Replace `std::hypot` / `Length()` distance checks in `gatherTier` (`L711`, `L720`, `L730`, `L755`) with squared-distance comparisons (`dx*dx + dz*dz > maxDistSq`), computing `std::sqrt` only for rocks that survive culling and need `Smoothstep` fade.
   * Hoist `const matrix3x3d viewSpinInvR = viewTran.GetOrient() * spinMatrix * (1.0 / m_planetRadius);` once per frame instead of multiplying `viewTran.ApplyRotationOnly(spinMatrix * ...)` 3× per rock (`L780-782`).
4. **Instanced Rendering**:
   * Bucket `visibleRocks` by `inst.variant` (`0..NUM_VARIANTS-1`).
   * Fill one persistent dynamic `VertexBuffer` with per-instance structs (`matrix4x4f` columns + `Color`/`vec4` diffuse + `vec4` emissive) and issue **at most 8 instanced draw calls** (1 per variant) instead of 4,500–7,500 `DrawMesh` calls.

---

### Task C3: Fix Issue #3 (Surface Scatter Shadows) + `SurfaceScatter` Instancing & LRU Cache

**Files**: `src/planet/SurfaceScatter.h`, `src/planet/SurfaceScatter.cpp`

1. **Fix #3 (Part 1) — Planet & Terrain-Ridge Occlusion on Boulders**:
   * Currently `SurfaceScatter::Render` (`L501-507`, `L680-692`) renders boulders via `"multi"` with unoccluded `uLight[0]`, so stars below the planet's horizon or behind mountain ridges continue illuminating rocks at night.
   * **Implemented Fix**:
     * Evaluated per-light geometric horizon attenuation (`rockLightScale`) and per-cell primary-star `WeatherSystem::ComputeTerrainRayVisibility(...)` when `sunElev` is in the horizon/ridge zone (`-0.025 <= sunElev <= 0.35`), refreshing cached cell `cachedSunVis` whenever `std::abs(gameTime - cell.sunVisGameTime) > 1.0` or `starDirRot` changes (safe under docked time acceleration). `sunVis` is passed via `i_emissive.a` in `rock_instanced.*`.
     * Modulated `skyBounce` (ambient/emissive) by `dayFactor * (0.35 + 0.65 * cellSunVis) * cloudAtten`, ensuring boulders match shadowed terrain brightness at dusk, night, and behind ridges.
2. **Fix #3 (Part 2) — Cast Ground Shadows From Boulders onto Planet Surface**:
   * Add a lightweight batched shadow-decal pass in `SurfaceScatter::Render` whenever `sunVis > 0.05` and the boulder is within shadow-draw distance (e.g. `dist < 320.0 * distMult` for `tier == 0`, `dist < 55.0` for `tier == 1`):
     * Project the primary star's direction onto the boulder's local tangent plane (`surfNormal`) to get the shadow stretch direction and elongation (`clamp(1.0 / max(sunElev, 0.22), 1.0, 3.8)`).
     * Build one soft radial/elliptical dark shadow quad (4 triangles or 1 quad with radial falloff in vertex alpha or a tiny 32×32 procedural radial-alpha texture, `BLEND_ALPHA`, `depthWrite = false`, offset `+0.03 * scale` along `surfNormal` to prevent z-fighting with terrain) into a single reusable `Graphics::VertexArray` (`m_shadowVerts`), and draw all scatter shadows in **1 draw call**.
3. **Hardware Instancing & LRU Cache**:
   * Replace `m_cellCache.clear()` at `SurfaceScatter.cpp:325` with LRU eviction (e.g. store `lastUsedFrame` on each cached cell or `std::list` LRU and evict oldest entries when exceeding `MAX_CACHED_CELLS`) so crossing cell boundaries never causes a full-cache flush hitch.
   * Hoist `const matrix3x3d viewRotInvR = viewTran.GetOrient() * m_invPlanetRadius;` once per frame (`L643-645`) and replace `std::hypot` (`L634`) with squared comparisons.
   * Bucket visible rocks by `inst.variant` (`0..NUM_VARIANTS-1`) and draw in **≤ 6 instanced draw calls** instead of 750–1,400.

---

### Task C4: Fix Issue #9 (Proactive Planet Surface LOD Pre-Generation) & `GeoPatch` Uniform Caching

**Files**: `src/GeoPatch.h`, `src/GeoPatch.cpp`, `src/GeoSphere.h`, `src/GeoSphere.cpp` (`Update()` / `PreloadTargetLOD()` only)

1. **Cache Invariant Patch Uniforms on `GeoPatch` (`GeoPatch.h`, `GeoPatch.cpp:342-357`)**:
   * Compute and store `m_detailFreq` and `m_tileOffset` once in `GeoPatch::UpdateVBOs` / constructor instead of calling `pow(2.0f, ...)` and 3× `fmod` inside `GeoPatch::RenderImmediate` on every patch every frame.
2. **Fix Issue #9 — Proactive LOD Pre-Generation for Targeted Planets**:
   * **Root cause**: `GeoSphere::Update()` (`src/GeoSphere.cpp:379-386`) only runs `LODUpdate(m_tempCampos, m_tempFrustum)` if `m_hasTempCampos` is true (meaning the planet has already rendered) and uses the current `m_tempCampos` (so while approaching in Supercruise or orbital glide, high-detail patches aren't requested until you are already close, causing visible popping/blurry terrain).
   * **Fix**:
     1. In `GeoSphere::Update()` (`UpdatePreloadState()`): gate preloading strictly to `Pi::game && !Pi::game->IsPaused() && Pi::game->GetTimeAccel() == Game::TIMEACCEL_1X` and `Pi::player->GetFlightState() == Ship::FLYING`, matching `GetNavTarget()` or the player's current body frame within `1.001 < distUnit < 25.0` (and approaching when `distUnit >= 15.0`).
     2. Compute a bounded 1x wall-clock lookahead camera position `m_preloadCampos` (`6.0s` lookahead clamped to `[1.005, distUnit]` radii).
     3. Run a budgeted `PreloadLODUpdate(m_preloadCampos, m_preloadDir, preloadBudget)` pass (`<= 8` jobs/frame, `maxPreloadDepth <= 10`) on the approach hemisphere (`Dot >= -0.15`).
     4. Guard `GeoPatch::LODUpdate` merge logic only while `m_geosphere->IsPreloadActive()`, automatically releasing preloaded patches if the player untargets, departs, docks, pauses, or engages time acceleration.

---

## Verification & Pitfalls

1. **Build & Unit Tests**:
   ```bash
   cmake --build build --target pioneer build-data -j 8
   cmake --build build --target unittest && ./build/unittest
   ```
2. **Functional & Visual Verification**:
   * **Ring Mining (#2A check)**: Fly into a planetary ring, verify boulders render smoothly with dramatically higher FPS, collide properly, and test shooting boulders with a mining laser—confirm beam hits, rock fragments spawn, and depleted rocks disappear.
   * **Surface Scatter Shadows (#3)**: Land near boulders/mountain ridges (or use Planet Inspector from Batch A if merged):
     * Verify boulders cast directional ground shadows away from the star.
     * Verify boulders go dark when the star sets below the horizon or behind a mountain ridge.
   * **Proactive Planet LODs (#9)**: Target a rocky planet from outer space, engage Supercruise toward it, and drop in—verify surface terrain patches are already crisp/subdivided on arrival instead of visibly popping from coarse tiles.
3. **Watch Out For**:
   * **File Boundary with Batch A**: In `src/GeoSphere.cpp`, touch **only** `Update()` / `ProcessQuadSplitRequests()` / new helper methods—do not edit `Render()` lines 600–690.
   * **OpenGL State & Stride**: When using `CommandBufferGL::ExecuteDrawBuffersCmd` with instancing, verify `VertexArray` / `OGL::VertexFormat` properly sets `glVertexAttribDivisor(attribLoc, 1)` for per-instance attributes and resets/uses distinct VAOs so non-instanced draws never inherit divisor `1`.
   * **Frustum / Horizon Culling for Cast Shadows**: Make sure shadow decals use `depthWrite = false` and a slight normal offset so they never z-fight or flicker on sloped terrain.

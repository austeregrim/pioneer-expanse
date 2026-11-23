# Pioneer: Expanse — NPC Supercruise & FSD Interdiction Plan

Detailed design and implementation roadmap for **Phase 7** (referenced from [02_PIONEER_EXPANSE_FOUNDATION_PLAN.md](./02_PIONEER_EXPANSE_FOUNDATION_PLAN.md)).

**Status:** **Completed** — All core milestones plus station occlusion, living traffic density, and active New-Game patrol/pirate FSD interdictions are implemented and verified.

---

## Core Design Decisions

### 1. Universal NPC Supercruise Flight & Traffic
* **Shared Physics & Rules**: NPCs use the exact same [`SupercruiseController`](src/ship/SupercruiseController.h) physics as the player:
  * `5s` FSD charge-up (requires zero station/planet mass-lock and retracted gear).
  * `30 km/s` (`0.0001c`) to `2,001c` speed envelope with gravity-well drag and strain.
  * 6-second rule deceleration (`v = d / 6.0` in the `75%` throttle blue zone).
  * Safe Disengage criteria (`distance <= 1,000 km` and `speed <= 1,000 km/s`).
* **Universal Supercruise Transit**: All NPC ships travel in `SUPERCRUISE` for inter-body, cloud-to-station, and patrol transit (`> 2,500 km`), dropping to normal sublight `FLYING` only for docking, atmospheric flight, or post-interdiction combat.
* **Obstacle / Exclusion-Zone Avoidance**: NPCs detect celestial exclusion zones along their flight vector and steer tangentially around planets/stars rather than slamming into exclusion zones.
* **Active AI Roles**:
  * **Traders (`TradeShips`)**: Spawn in Supercruise or jump-clouds, cruise shipping lanes, safe-disengage at destination stations, and dock.
  * **Pirates (`Pirates.lua`)**: Stalk Supercruise lanes, pursue targets at full throttle to close into the rear interdiction cone, and interdict if equipped with an FSD Interdictor.
  * **Police (`PolicePatrol`)**: Patrol Supercruise lanes, identify `WANTED` ships, and pursue/interdict criminals.

### 2. Visuals ("Light Itself"), Sensors & Scanning
* **Point-of-Light Rendering**: Every ship in `SUPERCRUISE` renders across the entire star system as a bright glowing point of light with a short directional velocity streak/wake—visible whether the player is in `SUPERCRUISE` or sublight `FLYING`.
* **Sensors & Targeting**:
  * `Sensors` expands in `SUPERCRUISE` to track system-wide Supercruise contacts (plus **Low Wake / Distress Signal** markers).
  * **Anyone can see and target a ship above 1c** (it is a point of light), whether they are in `SUPERCRUISE` or normal flight. *(Revised by [Plan I](./I_PLAN_TRANSPONDER_AND_STEALTH.md); the earlier "only while also in `SUPERCRUISE`" restriction was removed.)*
  * Successful interdiction preserves the player's combat target lock on the opponent when both transition to `FLYING`.
* **Scan Information Split**:
  * Resolving a Supercruise contact reveals **Ship Type, Pilot/Faction, and `WANTED`/`CLEAN` status** (via network ID).
  * **Cargo manifest and hull/shield health** remain hidden in Supercruise (`CARGO / HULL SCAN UNAVAILABLE IN SUPERCRUISE`) and require sublight scanning in normal space.

### 3. FSD Interdictor Module, Envelope & Tug-of-War
* **Equipment**: Internal utility module (`misc.fsd_interdictor_1` .. `_3` in `data/modules/Equipment/Internal.lua`) scaling range and cone angle.
* **Controls**: Triggered via **Secondary Fire (`M` / `BindSecondaryFire`)** while in `SUPERCRUISE` (plus optional dedicated binding).
* **Engagement Envelope (Elite Dangerous-style)**:
  * Target must be in `SUPERCRUISE`.
  * Speed-scaled tether range: `maxRange = max(10 ls, speed * 10s)`.
  * Rear-hemisphere cone: interdictor must be behind the target (`±35°` behind target tail) and aiming within `±25°` of the target.
* **Tug-of-War Minigame (Player Involved)**:
  * Clear HUD messaging explaining the state (`INTERDICTION DETECTED — ALIGN WITH ESCAPE VECTOR OR THROTTLE TO 0% TO SUBMIT` / `INTERDICTION TETHER ACTIVE — KEEP TARGET CENTERED`).
  * Dynamic **Escape Vector** reticle vs. Interdictor reticle, with competing blue (escape) and red (interdiction) progress bars.
  * Ship agility affects evasion difficulty; nimble ships evade more easily, while sluggish haulers struggle and some hauler pilots choose to **Submit** (`0%` throttle).
* **NPC-vs-NPC Interdiction**:
  * Resolves probabilistically without the interactive minigame (weighted by agility and interdictor class).
  * On success, both NPCs physically drop into normal sublight space at that location to dogfight, and spawn a targetable **Low Wake / Distress Signal** marker in Supercruise so the player can drop in.

### 4. Drop-Out Frame, Legal Rules, Cooldowns & Escape
* **Same Frame of Space**: Interdiction completion transitions both ships from `SUPERCRUISE` → `FLYING` in the target's `Frame`, placed ~`1.5–2 km` apart at combat speeds (`~200 m/s`).
* **Cooldowns & Penalties**:
  * **Submit (`0%` throttle)**: `5s` FSD cooldown for both ships, no heat/shield/hull shock.
  * **Forced Drop (Interdiction Succeeds)**: Target gets `25s` cooldown + emergency drop heat/shield shock; Interdictor gets `10s` cooldown.
  * **Evader Escapes**: Target stays in `SUPERCRUISE` unharmed; Interdictor suffers emergency drop (`25s` cooldown + heat/shield shock).
* **Crime & Wanted Status**:
  * Ship-level `wanted` / bounty state exposed to C++ and Lua.
  * Interdicting a `CLEAN` ship in a policed system incurs an immediate crime/fine and alerts Police; interdicting a `WANTED` ship is legal.
* **Post-Interdiction Escape & Ship Mass-Lock**:
  * **Ship Mass-Lock (Option A)**: Nearby larger ships (`<= 3 km`) apply a Mass Lock Factor that slows Supercruise FSD charge time (`5s` → `15–25s`); **Hyperspace** jumps ignore ship mass-lock.
  * **NPC FSD Damage (Option 1)**: Below `25%` hull, incoming combat hits have a chance to knock an NPC's FSD offline (`FSD OFFLINE`), preventing Supercruise escape. Above that threshold, losing NPCs attempt to flee into Supercruise once their cooldown clears.
  * **Player Escape**: The player can always re-engage Supercruise or Hyperspace once FSD cooldown completes, regardless of hull damage.

---

## Implementation Milestones

### Milestone 1: AI Supercruise Flight Core & Point-of-Light Visuals (COMPLETED)
* [x] Generalize [`SupercruiseController`](src/ship/SupercruiseController.h) to support NPC ships:
  * Add `SetTarget(Body *)` / `m_target` (with JSON save/load + `PostLoadFixup` + `OnDeleted`) so `GetActiveTarget()` works for both `Player` and AI ships.
  * Guard `StartCharge()` so AI-controlled supercruise commands aren't wiped by `AIClearInstructions()`.
  * Ensure NPCs update `SupercruiseController::TimeStepUpdate(...)` smoothly during `Ship::AITimeStep` / `ShipController::StaticUpdate`.
* [x] Implement Supercruise transit + obstacle avoidance in [`ShipAICmd`](src/ShipAICmd.h) / `Ship-AI.cpp`:
  * Tangential steering around planetary/stellar exclusion zones.
  * `AICmdFlyTo` and `AICmdDock` automatically engage Supercruise when target distance exceeds `SUBLIGHT_AUTOPILOT_MAX_DIST` (`2,500 km`), ride the 6-second rule (`75%` blue zone), and `SafeDisengage()` at `<= 1,000 km` & `<= 1,000 km/s` before completing sublight approach/docking.
  * `AICmdKill` / pursuit AI closes long-range gaps in Supercruise (`100%` throttle until close, then matches target envelope).
* [x] Render Supercruise ships as **bright points of light** ("light itself") with velocity streaks across the system in `WorldView::Draw3D()` (visible from both `SUPERCRUISE` and `FLYING`).

### Milestone 2: Supercruise Sensors, Targeting, Wanted Status & Scan Split (COMPLETED)
* [x] Expand [`Sensors`](src/Sensors.h) in `SUPERCRUISE` to detect system-wide Supercruise ships and Low Wakes.
* [x] ~~Enforce Supercruise-only targeting for Supercruise ships~~ — **superseded by Plan I**: any ship can see and target a ship above 1c; target lock is preserved across interdiction drops into `FLYING`.
* [x] Add ship-level `wanted` / bounty state (`Ship::IsWanted()`, Lua bindings, synced by `Pirates.lua` / `CrimeTracking`).
* [x] Update HUD target info (`data/pigui/modules/flight-ui/target-scanner.lua`) to show Ship Type, Pilot/Faction, and `WANTED`/`CLEAN` in Supercruise while hiding Cargo & Hull/Shield percentages until sublight.

### Milestone 3: FSD Interdictor Module, Tether Minigame & Drop-Out (COMPLETED)
* [x] Add `misc.fsd_interdictor_1` .. `_3` in `data/modules/Equipment/Internal.lua` (`fsd_interdictor_cap`).
* [x] Implement Supercruise interdiction state machine in `SupercruiseController` (envelope checks, `BindSecondaryFire` `M` trigger, Escape Vector physics, blue/red progress bars, `0%` throttle Submit, forced drop frame placement, `5s`/`10s`/`25s` cooldowns, and emergency drop shocks).
* [x] Build the Supercruise Interdiction HUD overlay (`data/pigui/modules/flight-ui/supercruise.lua`) with Escape Vector reticle, progress bars, and clear explanatory alerts.
* [x] Wire unlawful interdiction crimes (`CrimeTracking` / `PolicePatrol`) when interdicting `CLEAN` ships.

### Milestone 4: NPC Traffic Lanes, Piracy/Police AI, Low Wakes & Escape Rules (COMPLETED)
* [x] Update `TradeShips` (via `AICmdDock`/`AICmdFlyTo` Supercruise transit), `PolicePatrol`, and `Pirates.lua` to spawn/cruise in Supercruise, intercept `WANTED` targets or traders, and use FSD Interdictors.
* [x] Hide Supercruise points-of-light and Low Wakes when docked/landed/inside station interiors, and occlude them behind `SPACESTATION` hulls (`WorldView.cpp`).
* [x] Populate starports with docked ships, multi-station in-system Supercruise hops, short real-time cloud arrival timers, and `onGameStart` police/pirate ambient spawns + active rear-cone Supercruise interdictions (`Space.PutShipInSupercruiseBehind`, `misc.fsd_interdictor_1` available at `tech_level=2` and pre-equipped on Mercenary start).
* [x] Implement probabilistic NPC-vs-NPC interdiction drops with **Low Wake / Distress Signal** markers targetable in Supercruise (`HyperspaceCloud::SpawnLowWake` + `SafeDisengage` drop-in support).
* [x] Implement ship-to-ship Mass Lock Factor (Option A: slows Supercruise charge, ignored by Hyperspace) and NPC `< 25%` hull FSD offline disruption (Option 1) + NPC Supercruise flee behavior.

# Plan J — Batch 4: Plan A Autonomous Fleet Frontline Support

> **Status**: **Implemented**
> **Dependencies**: **Requires Batch 1 (`PLAN_J_BATCH_1`)**, **Batch 2 (`PLAN_J_BATCH_2`)** (`FrontlineCommon.lua`, `FrontlineSupply`), and **Batch 3 (`PLAN_J_BATCH_3`)** (`FrontlineExtraction`).
> **Parallelism**: Can run **in parallel with Batch 5 (`PLAN_J_BATCH_5`)** once Batches 1–3 are complete (zero overlapping files).

---

## Scope & Goals

Integrate Plan J's frontline war-effort mechanics with **Plan A (`PlayerFleet.lua`)** so crewed autonomous fleet ships can sustain a faction's warfront alongside (or on behalf of) the player:
1. **Mission Delegation (`FrontlineSupply` & `FrontlineExtraction`)**: Allow delegating frontline supply convoys and troop/refugee extractions to eligible crewed fleet vessels via `PlayerFleet.AssignMission`.
2. **Fleet `PATROL` Frontline Contribution**: When a fleet vessel completes a `PATROL` sweep in a system experiencing an active `FRONTLINE` crisis, credit periodic `MacroGalaxyEngine.ContributeToCrisis()` ticks and military XP (if player is enlisted in that faction).
3. **Fleet `AUTO_TRADE` Frontline Relief**: When a fleet vessel completes an `AUTO_TRADE` run delivering goods into a `FRONTLINE` crisis system, credit a modest frontline relief contribution to `MacroGalaxyEngine`.

---

## File Ownership (Batch 4 Only — Zero-Overlap Contract)

* `data/modules/PlayerFleet/PlayerFleet.lua` *(all changes isolated exclusively to `PlayerFleet.lua`)*

---

## Detailed Implementation Tasks

### Task 4.1: Delegate `FrontlineSupply` & `FrontlineExtraction` (`PlayerFleet.lua:5073–5310`)
1. **Register Supported Types**:
   * In `SUPPORTED_MISSION_TYPES` (`data/modules/PlayerFleet/PlayerFleet.lua:5073`), add:
     ```lua
     FrontlineSupply = true,
     FrontlineExtraction = true,
     ```
2. **Eligibility Checks in `PlayerFleet.GetEligibleShipsForMission(mission)` (`~line 5100`)**:
   * For `mission.type == "FrontlineSupply"`: reuse the `CargoRun` cargo capacity and flagship-or-fleet-hold cargo verification (`mission.cargotype`, `mission.amount`, `mission.pickup`).
   * For `mission.type == "FrontlineExtraction"`: compute the fleet entry's passenger berth capacity from `entry.modules` / equipment stats (add a small helper `PlayerFleet.GetPassengerCap(entry)` inspecting installed cabin equipment `cabin_cap` / `berths`), and reject ships with fewer berths than `mission.passengers or 1`. Also disallow delegating an extraction where passengers are already embarked on the Flagship (`mission.pickupDone == true`) unless transferring or restrict delegation to before pickup (`pickupDone == false`).
3. **Assignment in `PlayerFleet.AssignMission(uid, mission)` (`~line 5136`)**:
   * Transfer `FrontlineSupply` cargo from `Game.player` to `entry` if `not mission.pickup` (same pattern as `CargoRun`).
   * For `FrontlineExtraction` with `mission.originStation` (`not mission.pickupDone`), set outbound target to `mission.originStation` and `retPath` to `mission.location` (destination safe station) so the fleet ship flies `origin -> destination`.
4. **Completion in `completeFleetMission(entry, simNow, silentComms)` (`~line 5205`)**:
   * Handle cargo deduction for `FrontlineSupply` (`entry.stats.cargoHauled`).
   * Call `FrontlineCommon.RecordFrontlineContribution(...)` via `pcall(require, 'modules.FrontlineSupport.FrontlineCommon')` with the mission's `crisisSystemName`, `factionName`, `crisisDelta`, `militaryXP`, and `commendations` (or a fleet-scaled share, e.g., `100%` crisis progress and `50%`–`75%` captain-assisted military XP).
   * Neutralize `mission.status = "COMPLETED"`, `mission.location = farOff`, and `mission:Remove()` cleanly (preserving existing anti-double-pay logic at lines 5299–5308).

### Task 4.2: Autonomous `PATROL` & `AUTO_TRADE` Frontline Warfront Impact
1. **Patrol Sweeps (`~line 5839`)**:
   * At the end of a successful `PATROL` sweep in `entry.locationPath`:
     * Resolve system name and check `MacroGalaxyEngine.GetCrisisForSystem(sysName)`.
     * If `crisis and crisis.category == "FRONTLINE"`:
       * Call `FrontlineCommon.RecordFrontlineContribution` with a modest patrol delta (e.g. `crisisDelta = 1.5`, `militaryXP = 10`, `commendations = 0`, `standingDelta = 1`) guarded by a per-entry cooldown timestamp `entry.lastFrontlineTickTime` (`sweepEnd - (entry.lastFrontlineTickTime or 0) >= 600`) so OOS catch-up bursts never explode crisis progress to 100% instantly.
       * Log to `addLog(entry.shipName, ...)` when frontline security sweep contributes to system defense.
2. **Auto-Trade Relief (`AUTO_TRADE` trade completion path)**:
   * Locate where `AUTO_TRADE` completes a cargo sell leg in `PlayerFleet.lua`.
   * If the sell destination system has an active `FRONTLINE` crisis, trigger a small `FrontlineCommon.RecordFrontlineContribution` (`crisisDelta = 1.0`, `militaryXP = 5`, `standingDelta = 1`) with the same `entry.lastFrontlineTickTime` guard (`>= 900s`).

---

## Edge Cases & Pitfalls
* **OOS Catch-Up Safety**: When docked time dilation advances hours or days, `PlayerFleet` runs catch-up simulation loops (`isCatchUp == true`, `silentComms == true`). Always use `simNow` / `sweepEnd` (NOT `Game.time`) for `lastFrontlineTickTime` comparisons, and pass `silentComms` checks so hundreds of comms popups don't queue during time dilation.
* **No `FrontlineSupport` Hard Crash**: Wrap `require('modules.FrontlineSupport.FrontlineCommon')` in `pcall` so `PlayerFleet` stays resilient if loaded in minimal test harnesses.
* **Passengers Already on Flagship**: Never silently strand `Passengers` objects inside the player's ship when delegating an extraction—either restrict `FrontlineExtraction` delegation to `not mission.pickupDone` (rear-line dispatch contracts) or cleanly disembark from Flagship on `AssignMission`.

---

## Verification & Break-Fix Checklist
1. **Mission Delegation**:
   * Delegate a `FrontlineSupply` contract to a crewed cargo ship with sufficient hold space; verify cargo moves from Flagship to fleet ship, ship completes transit (live or OOS), money pays once, `MacroGalaxyEngine` crisis progresses, and BBS script never double-pays on future player dock.
   * Test `FrontlineExtraction` eligibility rejection when a fleet fighter has `0` passenger berths vs. success on a ship with cabins.
2. **Autonomous `PATROL` / `AUTO_TRADE` in `FRONTLINE` Systems**:
   * Assign a fleet combat ship to `PATROL` in an active `FRONTLINE` system; advance time via docked dilation and confirm bounded `ContributeToCrisis()` progression and ship log entries.
3. **Save/Load & Unit Tests**:
   * Save while a fleet ship is mid-transit on a `FrontlineSupply` mission, reload, let it complete, and verify clean state.
   * Run `./build/unittest`.

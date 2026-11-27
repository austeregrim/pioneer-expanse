# Plan J — Batch 3: Troop/Refugee Extractions & Dark-Running Frontline Recon

> **Status**: **Implemented**
> **Dependencies**: **Requires Batch 1 (`PLAN_J_BATCH_1`)** and **Batch 2 (`PLAN_J_BATCH_2`)** (`FrontlineCommon.lua`).
> **Parallelism**: Can run **in parallel with Batch 5 (`PLAN_J_BATCH_5`)**. **Batch 4** waits on Batch 3 for `FrontlineExtraction` delegation compatibility.

---

## Scope & Goals

Deliver the remaining two first-class **non-combat** frontline support gameplay loops:
1. **Troop & Refugee Extraction (`FrontlineExtraction.lua`)**: Evacuate wounded personnel, diplomatic envoys, and displaced civilians from contested `FRONTLINE` stations to safe rear-line starports using `Passengers` cabin berths (`data/libs/Passengers.lua`).
2. **Frontline Recon & Telemetry Scans (`FrontlineRecon.lua`)**: Accept covert or tactical reconnaissance orders in `FRONTLINE` systems using `ScanManager` (`data/modules/Scout/ScanManager.lua`), explicitly rewarding **Plan I dark-running** (`GetTransponder() == false`, speed `< 1c`, and no citations) with a stealth bonus.

---

## File Ownership (Batch 3 Only — Zero-Overlap Contract)

* `data/modules/FrontlineSupport/FrontlineExtraction.lua` *(new file)*
* `data/modules/FrontlineSupport/FrontlineRecon.lua` *(new file)*

---

## Exact Interfaces & Integration Points

* **Shared Frontline Foundation (`data/modules/FrontlineSupport/FrontlineCommon.lua`)**:
  * Reuse `IsPrisonStationPath`, `FindRearLineStations`, `GetActiveFrontlines`, `GetCrisisForSystem`, `ComputeReward`, `RecordFrontlineContribution`, and `IsEnlistedInFaction`.
* **Passenger Cabins (`data/libs/Passengers.lua`)**:
  * Check free berths: `Passengers.CountFreeBerths(Game.player)`
  * Embark passengers: `Passengers.EmbarkPassenger(Game.player, passengerObj)` where each `passengerObj` is created via `Character.New({ role = ..., org = ... })` (matching `Taxi.lua`)
  * Verify embarked count: `Passengers.CheckEmbarked(ship, passengerList)`
  * Disembark passengers: `pcall(Passengers.DisembarkPassenger, ship, passengerObj)` (wrapped in `pcall` to guard `ship["cabin_occupied_cap"] - 1` against sold/swapped cabins)
  * Tax integration: `TaxAuthority.RecordBBSIncome(reward, false)`
* **Scanners (`data/modules/Scout/ScanManager.lua`)**:
  * `local scanMgr = Game.player:GetComponent("ScanManager")` (auto-attaching `ScanManager.New(Game.player)` if absent)
  * Verify orbital scanner capability on accept: `scanMgr:HasSensorOfType(true)`
  * Queue orbital scan: `scanMgr:AddNewOrbitalScan(bodyPath, minResolution, coverageKm2)` where `coverageKm2 = utils.round(4 * math.pi * radiusKm^2 * bodyCoverageFraction, 0.0001)` (`>= 50` km²) and `minResolution` is in meters (`45`–`110` m scaled for large planets, matching `Scout.lua`)
  * Handle completion via `Event.Register("onScanComplete", ...)` with local `missionKey[scanId]` lookup, calling `scanMgr:AcceptScanComplete(scanId)` on turn-in and `scanMgr:AcceptScanComplete` / `scanMgr:CancelScan` on expiry cleanup so no orphaned scans remain in `ScanManager`
* **Plan I Dark-Running Check (`src/lua/LuaShip.cpp`)**:
  * Transponder state: `player.GetTransponder and (not player:GetTransponder())` (reflects actual active transponder state, distinct from `GetTransponderRequested` / `IsTransponderWarmingUp`)
  * Speed `< 1c` (`299792458.0` m/s): use `(player.IsSupercruiseActive and player:IsSupercruiseActive() and player.GetSupercruiseSpeed) and player:GetSupercruiseSpeed() or player:GetVelocity():length()` (since `GetVelocity()` alone does not reflect supercruise speed)
  * Citation/crime check: compare `PlayerState.GetCrimeOutstanding()` fine against `mission.baselineFine` recorded on accept
  * Sampling: `Timer:CallEvery(2, ...)` poller active only while uncompleted `FrontlineRecon` missions exist in the current `Game.system`
* **Piracy Note (`data/modules/Pirates.lua`)**:
  * `Pirates.lua` interdiction scaling remains focused on `FRONTLINE` crises + `FrontlineSupply` convoys; extraction and recon pilots still experience the base `FRONTLINE` crisis piracy modifier without extra convoy stacking.

---

## Detailed Implementation Tasks

### Task 3.1: Create `data/modules/FrontlineSupport/FrontlineExtraction.lua`
1. **BBS Generation (`onCreateBB` & `onUpdateBB`)**:
   * Generate extraction adverts primarily **at contested `FRONTLINE` stations** (evacuating `2`–`8` wounded troops, medical staff, diplomatic envoys, or displaced civilians out to a safe rear-line system within 25–35 ly), plus occasional rear-line `"Mercy Dispatch"` contracts sending the pilot to pick up `2`–`6` evacuees at a nearby frontline port.
   * Refresh `ad.reward` on `onUpdateBB` if player standing or enlistment changed.
   * Set `mission.type = "FrontlineExtraction"`.
   * Store `mission.passengers` (count), `mission.passengerList` (`Character[]` from `Character.New`), `mission.originStation` (`SystemPath`), `mission.location` (safe destination `SystemPath`), `mission.pickupDone` (boolean), `mission.fleetAssignedUid = nil`, `mission.factionName`, `mission.crisisSystemName`, `mission.crisisDelta`, `mission.militaryXP`, `mission.reward`, `mission.due`, `mission.status`.
2. **Accept & Embark Flow**:
   * For frontline evacuations (`not ad.isDispatch`): check `Passengers.CountFreeBerths(Game.player) >= ad.passengers`. If insufficient berths, show clear message (`"Insufficient passenger berths (X free berths required)."`). Otherwise create `Character.New` records and embark immediately (`mission.pickupDone = true`, `status = "ACTIVE"`).
   * For rear-line dispatch (`ad.isDispatch`): set `mission.pickupDone = false`, `status = "TO_PICK_UP"` until docking at `mission.originStation`, where passengers automatically embark (or via custom mission action) if berths are available.
3. **Completion, Undock Integrity & Failure**:
   * On `onPlayerDocked`: expire overdue/failed missions at any docked station (safely disembarking any embarked evacuees, applying `-2` standing penalty, and removing the mission). On docking at `mission.location` with `mission.pickupDone == true`, verify `Passengers.CheckEmbarked`, disembark all `mission.passengerList` via `pcall`-wrapped `Passengers.DisembarkPassenger`, pay `mission.reward`, record `TaxAuthority.RecordBBSIncome`, call `FrontlineCommon.RecordFrontlineContribution(...)`, and mark `COMPLETED`.
   * On `onPlayerUndocked`: verify `Passengers.CheckEmbarked(player, mission.passengerList) >= #mission.passengerList`; if cabins were sold or passengers lost, disembark remainder, penalize standing, and fail/remove the mission.
   * Serialize `{ ads = ads, missions = missions }` and restore overdue timers in `onGameStart`.

### Task 3.2: Create `data/modules/FrontlineSupport/FrontlineRecon.lua`
1. **BBS Generation (`onCreateBB` & `onUpdateBB`)**:
   * At rear-line or frontline stations near/in an active `FRONTLINE` crisis, generate **Frontline Telemetry / Orbital Recon** contracts (`mission.type = "FrontlineRecon"`).
   * Refresh `ad.reward` on `onUpdateBB` if player standing or enlistment changed.
   * Check `scanMgr:HasSensorOfType(true)` on accept before queuing the scan via `ScanManager:AddNewOrbitalScan(bodyPath, minRes, coverageKm2)`.
   * Target a planetary body inside the `FRONTLINE` system with brisk orbital coverage requirements (`0.006`–`0.018` nominal fraction adjusted by planet radius, clamped `<= 0.35`, converted to km²) so tactical sweeps feel responsive under blockade/patrol risk.
2. **Dark-Running Stealth Telemetry Bonus**:
   * Poll via `Timer:CallEvery(2, ...)` while in the target system and `scan.coverage` increases:
     * Check `(not player:GetTransponder())`, supercruise/sublight speed `< LIGHT_SPEED`, and `PlayerState.GetCrimeOutstanding()` fine `<= mission.baselineFine`.
     * If maintained through scan completion, award a **+25% Stealth Recon Bonus** to payout and `+15` bonus military XP.
     * Clearly explain this optional stealth bonus in the BBS briefing (`"[OPTIONAL STEALTH BONUS] Run dark (<1c, transponder OFF, no citations) during telemetry sweep for +25% hazard pay and +15 military XP."`).
3. **Completion & Cleanup**:
   * Handle `Event.Register("onScanComplete", ...)` via `missionKey[scanId]`, evaluate final stealth status, update `mission.scanComplete = true` and `mission.destination = mission.backstation`, and notify pilot to dock at `mission.backstation` (or any same-faction station).
   * On `onPlayerDocked`: expire overdue/failed missions at any docked station (cleaning up `ScanManager` via `AcceptScanComplete`/`CancelScan`). On valid turn-in, consume scan via `AcceptScanComplete`, pay reward + stealth bonus, record `TaxAuthority.RecordBBSIncome`, and call `FrontlineCommon.RecordFrontlineContribution(...)`.

---

## Edge Cases & Pitfalls
* **Exact Transponder & Speed API**: `GetTransponder()` returns actual active transponder state; `IsSupercruiseActive()` + `GetSupercruiseSpeed()` returns SC speed while `GetVelocity():length()` returns sublight speed.
* **Passenger Disembark Safety**: Wrap `Passengers.DisembarkPassenger` in `pcall` and reconcile with `Passengers.CheckEmbarked` on `onPlayerUndocked` and `onGameStart` so sold cabins or ship swaps never leave orphaned locks.
* **Delegation Tagging**: Expose `mission.passengers`, `mission.originStation`, `mission.location`, `mission.pickupDone`, `mission.crisisSystemName`, and `mission.fleetAssignedUid = nil` cleanly on `FrontlineExtraction` so Batch 4 (`PlayerFleet.lua`) can check fleet passenger capacity and delegate `not mission.pickupDone` extractions.

---

## Verification & Break-Fix Checklist
1. **Extraction**:
   * Verify BBS advert rejects acceptance at frontline ports if ship lacks enough passenger berths.
   * Accept extraction at a `FRONTLINE` station, confirm `Passengers.CountFreeBerths` decreases by exact passenger count, fly to destination station, dock, confirm berths restore, money + crisis progress + military XP apply.
2. **Recon**:
   * Accept `FrontlineRecon`, verify orbital scanner check and `ScanManager` orbital scan target in the target `FRONTLINE` system.
   * Test completing scan with transponder ON (standard reward) vs. transponder OFF `< 1c` (stealth bonus awarded).
   * Confirm returning and docking advances `MacroGalaxyEngine` crisis progress and clears `ScanManager`.
3. Save/reload mid-mission for both `FrontlineExtraction` and `FrontlineRecon` and confirm clean persistence.
4. Run `./build/unittest` and verify zero Lua errors in logs.

# Plan J — Batch 5: Optional Combat Zones & Naval Skirmish Bonds

> **Status**: **Implemented**
> **Dependencies**: **Requires Batch 1 (`PLAN_J_BATCH_1`)** (`FactionRoles`, `02-police.lua` Military & Deputy tab). Can use `FrontlineCommon.lua` if Batch 2 is present (with safe `pcall` fallback to `MacroGalaxyEngine` directly so Batch 5 can run **completely in parallel with Batches 2–4**).
> **Parallelism**: Can run **in parallel with Batches 2, 3, and 4** once Batch 1 is complete. Coordinate only the small `02-police.lua` Combat Bonds panel and `CrimeTracking.lua` CZ exemption after Batch 1 merges.

---

## Scope & Goals

Provide **optional** high-intensity naval skirmishes in active Stage 2 `INSURGENCY` and `BLOCKADE` `FRONTLINE` systems so combat-oriented pilots and escort wings can earn **Combat Bonds**, military rank XP, and crisis progress—while strictly preserving Plan J's rule that **combat is never mandatory** for rank or Deputy progression.

1. **`FrontlineCombatZones.lua`**: Manage Combat Zone spawn triggers, friendly naval defense wings vs. hostile insurgent/blockade wings, kill tracking, Combat Bond ledger, and clean despawn.
2. **Crime Exemption (`CrimeTracking.lua`)**: Exempt hits/kills/interdictions against marked Combat Zone hostiles from `PIRACY` and `MURDER` citations.
3. **Bond Redemption UI (`02-police.lua`)**: Add a **Combat Bonds** redemption block inside the Batch 1 **Military & Deputy** tab.

---

## File Ownership (Batch 5 Only — Zero-Overlap Contract)

* `data/modules/FrontlineSupport/FrontlineCombatZones.lua` *(new file)*
* `data/modules/CrimeTracking/CrimeTracking.lua` *(add CZ hostile exemption check in `onShipHit`, `onShipDestroyed`, `onShipInterdicted` — touches only lines ~111–148, separate from Batch 1's Deputy logic if merged sequentially after Batch 1)*
* `data/pigui/modules/station-view/02-police.lua` *(add Combat Bonds redemption UI block inside the Batch 1 "Military & Deputy" tab)*

---

## Exact Data Schemas & API Signatures (`FrontlineCombatZones.lua`)

### Serialized State (`FrontlineCombatZonesDB`)
```lua
pendingBonds = { [factionName] = number } -- unredeemed Combat Bonds in credits
```
*(Transient active zone ships are system-local and cleaned up on `onLeaveSystem` / `onGameEnd` / `onShipDocked`.)*

### Required Public Functions
* `FrontlineCombatZones.IsHostileTarget(ship)` -> `boolean, factionName` (true if `ship` is an active spawned hostile belonging to the current system's CZ)
* `FrontlineCombatZones.GetZoneSummary()` -> `{ active, systemName, factionName, crisisType, friendlyCount, hostileCount, killsThisSortie }`
* `FrontlineCombatZones.GetPendingBonds(factionName)` -> `number`
* `FrontlineCombatZones.GetAllPendingBonds()` -> `{ { factionName = string, amount = number }, ... }`
* `FrontlineCombatZones.RedeemBonds(factionName)` -> `amountPaid, err` (pays via `PlayerState.AddMoney`, records `TaxAuthority.RecordOperationsIncome` if applicable + `FlightLog.RecordTransaction`, clears `pendingBonds[factionName]`)

---

## Detailed Implementation Tasks

### Task 5.1: Create `data/modules/FrontlineSupport/FrontlineCombatZones.lua`
1. **Trigger Condition (`onEnterSystem` / periodic 10s check)**:
   * Query `MacroGalaxyEngine.GetCrisisForSystem(Game.system.name)`.
   * Activate a Combat Zone **only** when `crisis` exists, `crisis.category == "FRONTLINE"`, `(crisis.type == "INSURGENCY" or crisis.type == "BLOCKADE")`, and `crisis.severity >= 2`.
   * Pick a contested orbital body (e.g., an inhabited/primary planet or outer station perimeter at `15–40 km` offset) and announce via a single non-intrusive `Comms.Message` (`"TACTICAL ADVISORY: Contested Naval Zone detected near <Body>. Combat participation optional."`).
2. **Lazy Wave Spawning**:
   * **Important**: Do **not** spawn heavy combat fleets immediately at system entry while the player is far away in Supercruise. Spawn the skirmish wing (e.g., 3–4 friendly faction patrol/navy ships vs. 3–4 hostile insurgent/blockade ships) only once `Game.player` drops out of Supercruise within engagement range (or within `100 km` of the designated zone anchor) so Supercruise frame rates stay untouched.
   * Tag spawned hostile ships with `czHostiles[ship] = { factionName = sysFaction, bondValue = ..., crisisType = crisis.type }` and set AI orders (`AIKill` against opposing CZ ships, prioritizing threats).
   * Cap simultaneous active CZ ships (max `4` friendly + `4` hostile, at most `2` reinforcement waves per sortie) to maintain smooth FPS.
3. **Kill & Bond Accounting (`onShipDestroyed`)**:
   * When a ship in `czHostiles` is destroyed and `attacker` is `Game.player` (or an allied `PlayerFleet` escort ship):
     * Award bond credit (`3,500`–`12,000 Cr` scaled by ship class/threat) into `pendingBonds[sysFaction]`.
     * Call `MacroGalaxyEngine.ContributeToCrisis(sysName, 2.5)` (and if enlisted in `sysFaction`, `FactionRoles.AddMilitaryXP(sysFaction, 15, 0, "Combat Zone victory")` via `pcall`).
     * Show brief `Comms.Message` (`"+X Cr Combat Bond awarded (Redeem at any <Faction> station)."`).
4. **Cleanup**:
   * On `onLeaveSystem`, `onGameEnd`, and `onShipDestroyed` (pruning dead entries), clear transient CZ ship tables cleanly so no stale ship userdata persists.

### Task 5.2: Crime Exemption (`data/modules/CrimeTracking/CrimeTracking.lua`)
1. Add a small local helper `isCombatZoneHostile(ship)`:
   ```lua
   local okCZ, FrontlineCZ = pcall(require, 'modules.FrontlineSupport.FrontlineCombatZones')
   return okCZ and FrontlineCZ and FrontlineCZ.IsHostileTarget and FrontlineCZ.IsHostileTarget(ship)
   ```
2. In `onShipHit`, `onShipDestroyed`, and `onShipInterdicted`, if `attacker:IsPlayer()` and `isCombatZoneHostile(ship)`, return early without recording `PIRACY` or `MURDER`.

### Task 5.3: Combat Bond Redemption UI (`data/pigui/modules/station-view/02-police.lua`)
1. Inside the **"Military & Deputy"** tab (added by Batch 1), add a **Combat Bonds** section:
   * Show pending Combat Bonds for the current `factionName` and a **Redeem Combat Bonds (`X Cr`)** button.
   * Also list any unredeemed bonds held for other factions so pilots know where to cash them in.

---

## Edge Cases & Pitfalls
* **Zero Impact on Non-Combat Pilots**: Never spawn CZ hostiles on top of stations or Supercruise arrival points; keep the zone clearly anchored away from docking corridors (`> 20 km` from stations or around a secondary planet) so freighters/explorers are never ambushed involuntarily.
* **Friendly Fire Guard**: Hitting a friendly CZ ship still triggers normal crime warnings—only `FrontlineCombatZones.IsHostileTarget(ship)` is exempt.
* **Stale Userdata**: Never serialize live `Ship` references in `FrontlineCombatZonesDB`; only serialize `pendingBonds`.

---

## Verification & Break-Fix Checklist
1. Enter a Stage 2 `INSURGENCY` or `BLOCKADE` `FRONTLINE` system:
   * Confirm no CZ ships spawn while cruising far away in Supercruise.
   * Drop near the contested planet anchor and verify friendly + hostile wings spawn cleanly and engage each other.
   * Destroy a marked CZ hostile: verify **no `PIRACY`/`MURDER` fine**, Combat Bond increments, and `MacroGalaxyEngine` crisis progresses.
2. Dock at a faction station, open Police -> **Military & Deputy**, and redeem Combat Bonds; verify credits added, `FlightLog` entry created, and bond balance resets to `0`.
3. Leave system / save & reload and confirm no dangling ship references or Lua errors.
4. Run `./build/unittest`.

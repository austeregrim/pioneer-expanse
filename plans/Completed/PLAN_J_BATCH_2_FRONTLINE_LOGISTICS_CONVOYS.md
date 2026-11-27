# Plan J — Batch 2: MacroGalaxy Frontline Hooks, Supply Convoys & Blockade Running

> **Status**: **Implemented**
> **Dependencies**: **Requires Batch 1 (`PLAN_J_BATCH_1`)** (`FactionRoles.AddMilitaryXP`, `GetHazardPayMultiplier`, `activeEnlistment`).
> **Parallelism**: Can run **in parallel with Batch 5 (`PLAN_J_BATCH_5`)** once Batch 1 is complete (zero overlapping files). **Batch 3** depends on `FrontlineCommon.lua` created here.

---

## Scope & Goals

Create the shared `FrontlineSupport` foundation and the primary non-combat frontline cargo/blockade-running gameplay loop:
1. **`FrontlineCommon.lua`**: Shared helper querying `MacroGalaxyEngine` for active `FRONTLINE` crises (`BLOCKADE`, `INSURGENCY`, `INDUSTRIAL_DISASTER`), resolving rear-line vs. frontline systems, calculating rank/standing-scaled payouts, and applying crisis resolution progress (`MacroGalaxyEngine.ContributeToCrisis`), military XP, and `FlightLog` entries.
2. **`FrontlineLogistics.lua`**: BBS mission module (`mission.type = "FrontlineSupply"`) generating:
   * **Supply Convoy** contracts from rear-line faction stations into active `FRONTLINE` systems.
   * **Blockade Runner** sourcing contracts posted directly at contested `FRONTLINE` stations (higher hazard bonus).
3. **`Pirates.lua` Threat Scaling**: Increase interdiction probability when carrying an active `FrontlineSupply` contract into a `FRONTLINE` system, using `MacroGalaxyEngine.GetPiracyEffectForCrisis`.

---

## File Ownership (Batch 2 Only — Zero-Overlap Contract)

* `data/modules/FrontlineSupport/FrontlineCommon.lua` *(new file)*
* `data/modules/FrontlineSupport/FrontlineLogistics.lua` *(new file)*
* `data/modules/Pirates.lua` *(add frontline convoy interdiction modifier in `shouldInterdictPlayerInSC` / `pirateIsInterested`)*

---

## Exact Data Schemas & API Signatures (`FrontlineCommon.lua`)

### Crisis Types Considered Frontline
```lua
FrontlineCommon.FRONTLINE_CRISIS_TYPES = {
    BLOCKADE = true,
    INSURGENCY = true,
    INDUSTRIAL_DISASTER = true,
}
```

### Required Public Functions on `FrontlineCommon`
* `FrontlineCommon.GetActiveFrontlines(factionFilter)` -> array of `{ crisis, systemName, systemPath, starSystem, factionName, severity }`
* `FrontlineCommon.GetCrisisForSystem(systemName)` -> returns `crisis` from `MacroGalaxyEngine.GetCrisisForSystem(systemName)` if `crisis.category == "FRONTLINE"` (or nil)
* `FrontlineCommon.FindRearLineStations(targetSystemPath, factionName, maxRangeLy)` -> candidate safe non-frontline stations within range
* `FrontlineCommon.ComputeReward(baseReward, factionName, isEnlistedBonus, crisisSeverity)` -> applies `FactionStanding.GetRewardMultiplier(factionName)`, `FactionRoles.GetHazardPayMultiplier(factionName)` (when `isEnlistedBonus`), and severity multiplier (`1.0 + 0.15 * (severity - 1)`)
* `FrontlineCommon.RecordFrontlineContribution(opts)`:
  * `opts = { systemName, factionName, crisisDelta, militaryXP, commendations, standingDelta, reason, logTitle, reward }`
  * Calls `MacroGalaxyEngine.ContributeToCrisis(opts.systemName, opts.crisisDelta)`
  * Calls `FactionStanding.ApplyMissionOutcome(opts.factionName, opts.standingDelta, nil, opts.reason)`
  * If `FactionRoles.HasActiveRole(opts.factionName, "enlisted")` (i.e. `FactionRoles.GetMilitaryInfo(opts.factionName).enlisted`), calls `FactionRoles.AddMilitaryXP(opts.factionName, opts.militaryXP, opts.commendations, opts.reason)`
  * Records `FlightLog` transaction if `opts.reward` or `opts.logTitle` is provided.
* `FrontlineCommon.IsEnlistedInFaction(factionName)` -> boolean via `FactionRoles.GetMilitaryInfo(factionName).enlisted`

---

## Detailed Implementation Tasks

### Task 2.1: Create `data/modules/FrontlineSupport/FrontlineCommon.lua`
1. Require `Game`, `Space`, `FactionRoles`, `FactionStanding`, `MacroGalaxyEngine`, `Format`, and optional `FlightLog`.
2. Implement `GetActiveFrontlines(factionFilter)`:
   * Read `MacroGalaxyEngine.GetActiveCrises()`.
   * Filter where `c.category == "FRONTLINE"`.
   * Resolve `SystemPath` safely using `Space.GetBodies` / `StarSystem` lookup or `SectorMap` / `Game.system:GetNearbySystems` (note: Pioneer's `MacroGalaxyEngine.REGIONAL_SYSTEMS` uses known named systems—verify how `MacroGalaxyEngine` / `Economy` resolves a `systemName` to a `SystemPath`, e.g., `Game.system:GetNearbySystems(range)` or `Galaxy` lookup, and cache resolved paths!).
3. Implement `ComputeReward` and `RecordFrontlineContribution` cleanly so Batches 2, 3, 4, and 5 can reuse the exact same progression and crisis-contribution pipeline.

### Task 2.2: Create `data/modules/FrontlineSupport/FrontlineLogistics.lua`
1. Follow the `DeliverPackage.lua` / `CargoRun` BBS + `Mission.New` + `MissionUtils.SetupOverdueTimer` lifecycle pattern:
   * Set `mission.type = "FrontlineSupply"`.
   * Store `mission.cargotype` (`Commodities[cname]`), `mission.amount` (tons), `mission.pickup` (`false` for Supply Convoy loaded at origin or player-sourced; `true` or `false` clearly flagged), `mission.location` (destination `SystemPath`), `mission.station` (origin `SystemPath` for return if needed), `mission.factionName`, `mission.crisisSystemName`, `mission.crisisDelta` (e.g., `4.0`–`10.0` scaled by tonnage & severity), `mission.militaryXP` (e.g., `25`–`75`), `mission.reward`, `mission.due`.
   * Use real commodity keys verified in `data/libs/Commodities.lua`: `medicines`, `metal_alloys`, `air_processors`, `hydrogen`, `liquid_oxygen`, `industrial_machinery`, `hand_weapons`, `battle_weapons` (filter out commodities illegal in the origin or destination system via `sys:IsCommodityLegal(cname)` unless explicitly flagged as a Blockade Runner).
2. **BBS Generation (`onCreateBB`)**:
   * If docked in a `FRONTLINE` crisis system: generate 1–2 **Blockade Runner** sourcing/relief contracts (fetch critical supplies from a nearby rear-line system back to this contested port, or emergency outbound/inbound relief).
   * If docked in a non-frontline system within 25–35 ly of an active `FRONTLINE` crisis controlled by the same (or non-hostile) faction: generate 1–3 **Supply Convoy** contracts delivering relief/military materiel to the frontline system.
   * Tag adverts clearly (`[FRONTLINE CONVOY]` / `[BLOCKADE RUN]`) and display whether **Enlisted Rank Hazard Bonus** applies.
3. **Completion (`onShipDocked`)**:
   * Verify `mission.status == "ACTIVE"` and `not mission.fleetAssignedUid` (or neutralized path per `PlayerFleet` delegation).
   * Verify cargo aboard `Game.player:GetComponent('CargoManager')` and deduct `mission.amount` of `mission.cargotype`.
   * Pay `mission.reward` via `PlayerState.AddMoney`, call `FrontlineCommon.RecordFrontlineContribution(...)`, notify via `Comms.ImportantMessage`, mark `mission.status = "COMPLETED"`, and `mission:Remove()`.
4. **Expiry & Serialization**:
   * Handle `MissionUtils` overdue/expiry (`mission.status = "FAILED"`, slight standing penalty `-2`).
   * Register with `Serializer:Register("FrontlineLogistics", ...)` and clean up in `onGameEnd`.

### Task 2.3: Scale Piracy / Blockade Interdiction Risk (`data/modules/Pirates.lua`)
1. Add a helper in `Pirates.lua`: `hasActiveFrontlineConvoyInSystem()`:
   * Check `Character.persistent.player.missions` for an active `"FrontlineSupply"` mission targeting the current `Game.system.name`.
2. In `shouldInterdictPlayerInSC(player)` (`data/modules/Pirates.lua:147`) and `pirateIsInterested(player)`:
   * Query `MacroGalaxyEngine.GetCrisisForSystem(Game.system.name)` and `MacroGalaxyEngine.GetPiracyEffectForCrisis(crisis)`.
   * Add a modest additive interdiction probability bonus (e.g., `+0.10` during `FRONTLINE` crises, `+0.15` when carrying an active `FrontlineSupply` contract) capped safely so blockade running feels tense without becoming constant spam (respect existing `nextPlayerInterdictTime` cooldown).

---

## Edge Cases & Pitfalls
* **Illegal Commodities**: Do not accidentally make a lawful Supply Convoy carry `battle_weapons` into a system where `battle_weapons` is illegal (`sys:IsCommodityLegal("battle_weapons") == false`) unless it is explicitly labeled a covert **Blockade Run** and warns the pilot.
* **No Active Frontlines Nearby**: If `GetActiveFrontlines` finds no nearby frontline crises within jump range, gracefully generate 0 adverts without errors.
* **Mission Delegation Compatibility (Batch 4)**: Expose `mission.type == "FrontlineSupply"`, `mission.cargotype`, `mission.amount`, `mission.location`, `mission.factionName`, `mission.crisisSystemName`, `mission.crisisDelta`, `mission.militaryXP`, and `mission.fleetAssignedUid = nil` (nil-safe forward field) on the mission object cleanly so Batch 4 (`PlayerFleet.lua`) can delegate it without touching `FrontlineLogistics.lua`.
* **Verified Lifecycle & Mechanics**:
  * Dock completion hooks `onPlayerDocked` (matching `CargoRun`/`DeliverPackage`) and registers the mission type via `Mission.RegisterType("FrontlineSupply", "Frontline Supply", buildMissionDescription)`.
  * `crisisDelta` (`4.0`–`10.0`) adds directly to `MacroGalaxyEngine` crisis progress (`0`–`100` scale).
  * If a crisis resolves while a pilot is en route, `FrontlineLogistics` still honors full payout and military XP upon delivery.
  * `Pirates.lua` applies the frontline/convoy bonus before probability caps (including low-lawlessness systems where `lawlessness < 0.15`) while preserving the 180s `nextPlayerInterdictTime` cooldown.

---

## Verification & Break-Fix Checklist
1. Dock at a system near an active `BLOCKADE`/`INSURGENCY`/`INDUSTRIAL_DISASTER` crisis (or trigger one via Lua console / `MacroGalaxyEngine` for testing) and verify BBS adverts appear with correct commodity, tonnage, deadline, and reward math.
2. Accept a Supply Convoy as:
   * **Un-enlisted pilot**: verify completion pays base + standing multiplier, advances `MacroGalaxyEngine` crisis progress, and awards **0** military XP.
   * **Enlisted pilot**: verify rank hazard-pay multiplier applies, crisis progress advances, InterCast stage bulletin fires when crossing threshold, and `FactionRoles.AddMilitaryXP` increases rank XP.
3. Verify `Pirates.lua` interdiction cooldown (`180s`) is still respected and doesn't lock up Supercruise.
4. Save and reload with an active `FrontlineSupply` mission; verify completion still works and cargo deduction is exact.
5. Run `./build/unittest` and verify zero Lua errors in logs.

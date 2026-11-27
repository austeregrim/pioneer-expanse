# Plan J — Batch 1: Citizenship, Military Enlistment, Rank Ladder & Deputy Charter

> **Status**: **Ready for Implementation**
> **Dependencies**: None (Foundation batch — **must complete before Batches 2–5**).
> **Independent Agent Assignment**: Self-contained foundation batch. Batches 2–5 depend on the APIs and schemas defined here.

---

## Scope & Goals

Build the foundational state machine, legal hooks, and station UI for **Residency → Citizenship → Military Enlistment** and the **Faction Deputy Charter**:
1. **Citizenship & Enlistment Registry (`FactionRoles.lua`)**: Extend `FactionRolesDB` to track `citizenship`, `activeEnlistment`, `serviceHistory`, rank progression, and rival enlistment lockouts.
2. **Enlisted Residency Lock (`TaxAuthority.lua`)**: Enforce the rule that an enlisted pilot can relocate residency after the 90-day term **only** to another station under their citizenship faction until they resign from military service.
3. **Permanent Rival Military Lockout**: Once a pilot has enlisted with any faction, they are permanently barred from enlisting in any rival/opposing faction's military—even after resigning and acquiring residency/citizenship elsewhere.
4. **Deputy Charter & Legal Interdiction (`Legal.lua`, `CrimeTracking.lua`)**: Standing-gated (`Allied >= 75`) deputization waiving bounty-hunter licence fees, granting persistent faction-wide warrant access, and authorizing legal interdiction/engagement of `WANTED` targets.
5. **Station UI (`01-lobby.lua`, `02-police.lua`)**: Add Citizenship registration/status to the Lobby Civil Administration view and a **Military & Deputy** tab to the Police & Security view.

---

## File Ownership (Batch 1 Only — Zero-Overlap Contract)

* `data/libs/FactionRoles.lua`
* `data/modules/Economy/TaxAuthority.lua`
* `data/libs/Legal.lua`
* `data/modules/CrimeTracking/CrimeTracking.lua`
* `data/pigui/modules/station-view/01-lobby.lua`
* `data/pigui/modules/station-view/02-police.lua` *(Note: Batch 5 later adds a small Combat Bonds redemption panel to `02-police.lua` after Batch 1 lands.)*

---

## Confirmed Design Rules (Non-Negotiable)

1. **Residency → Citizenship Prerequisite**:
   * Pilot must hold active civil residency (`TaxAuthority.GetResidencyInfo().isResident == true`) in a faction before claiming citizenship in that faction (`FactionRoles.ClaimCitizenship(factionName)`).
   * If a **non-enlisted** pilot moves residency to a different faction (after the 90-day term), their prior citizenship is cleared (they become stateless/resident until they claim citizenship in the new faction).
2. **Enlisted Citizenship & Residency Lock**:
   * Enlisting in a faction's military (`FactionRoles.Enlist(factionName)`) requires holding **Citizenship** in that faction.
   * While **actively enlisted**, the pilot **cannot renounce or change citizenship**.
   * While **actively enlisted**, once the 90-day residency term (`RESIDENCY_TERM_DAYS = 90` in `TaxAuthority.lua`) expires, the pilot **can** move residency, **but ONLY to another station controlled by their citizenship faction**. Moving to any other faction's station is rejected until the pilot resigns (`FactionRoles.ResignMilitary()`).
3. **Permanent Rival Enlistment Lockout**:
   * `FactionRoles` records every faction the pilot has ever enlisted with in `serviceHistory[factionName] = true`.
   * Even after resigning and legally moving residency + citizenship to a rival faction, the pilot is **permanently blocked** from enlisting in any faction listed as a rival/opponent of any faction in `serviceHistory`.
   * A pilot **may** still perform non-enlisted independent/auxiliary contracts or hold residency/citizenship in that rival faction; only **military enlistment** is permanently locked out.
4. **Deputy Charter Eligibility**:
   * Standing: `FactionStanding.Get(factionName) >= 75` (**Allied**).
   * Citizenship: Must hold active **Citizenship** in `factionName` (`citizenship.factionName == factionName`).
   * Clean record: `PlayerState.GetCrimeOutstanding()` fine `== 0` and player not wanted.
   * Service credential: either holds/held a Bounty Hunter Licence for `factionName` **OR** has at least `3` frontline commendations / active military service in `factionName`.
   * Reclaim cooldown: If Deputy status was revoked due to a criminal offence or standing drop, a **30-day** reclaim cooldown applies before re-applying.
   * Perpetual waiver: `FactionRoles.HasBountyLicence(factionName)` already checks `HasActiveRole(name, "deputy")` (`data/libs/FactionRoles.lua:72`), so setting `rec.deputy` automatically waives renewal fees.
   * Jurisdiction-scoped warrant execution: Deputy interdiction and engagement exemptions apply **only** to targets wanted in the jurisdiction of the faction where the player holds active Deputy status (and while operating in that faction's system).

---

## Exact Data Schemas & API Signatures (`data/libs/FactionRoles.lua`)

### Serialized State (`FactionRolesDB`)
Preserve existing `rolesByFaction[factionName]` (`bounty_hunter`, `deputy`, `enlisted`) and add:
```lua
citizenship = {
    factionName = string, -- or nil
    grantedAt = number,
} -- nil when stateless
activeEnlistment = string or nil -- factionName currently serving in
serviceHistory = { [factionName] = { firstEnlistedAt = number, totalXP = number, commendations = number, resignedAt = number|nil, reenlistCooldownUntil = number|nil } }
dynamicRivalries = { [factionA] = { [factionB] = true } }
deputyCooldownUntil = { [factionName] = number }
```

### Rank Table (`FactionRoles.MILITARY_RANKS`)
```lua
{
    { rank = 1, title = "Auxiliary",  minXP = 0,    hazardBonus = 0.05, serviceDiscount = 0.02 },
    { rank = 2, title = "Ensign",     minXP = 150,  hazardBonus = 0.10, serviceDiscount = 0.05 },
    { rank = 3, title = "Lieutenant", minXP = 450,  hazardBonus = 0.15, serviceDiscount = 0.08 },
    { rank = 4, title = "Commander",  minXP = 1000, hazardBonus = 0.20, serviceDiscount = 0.12 },
    { rank = 5, title = "Captain",    minXP = 2000, hazardBonus = 0.25, serviceDiscount = 0.15 },
    { rank = 6, title = "Commodore",  minXP = 3500, hazardBonus = 0.30, serviceDiscount = 0.20 },
}
```

### Rivalries Table (`FACTION_RIVALRIES`)
* Seed bilateral rivalries between major geopolitical blocs (check exact faction names in `data/factions/*.lua`), at minimum:
  * `"Solar Federation"` ↔ `"Commonwealth of Independent Worlds"`
  * `"Solar Federation"` ↔ `"Haber Corporation"`
  * `"Commonwealth of Independent Worlds"` ↔ `"Haber Corporation"`
* Also treat any faction where `FactionStanding.Get(f) <= -60` (snapshotted across known factions at the time of enlistment) or recorded via `FactionRoles.RecordFactionConflict(factionA, factionB)` (stored in `dynamicRivalries`) as a rival.

### Required Public Functions on `FactionRoles`
* `FactionRoles.IsStatelessFaction(factionOrName)` -> `boolean` (canonical guard for `nil`, `""`, `"Independent"`, `"Independent Systems"`, `"Stateless / Independent"`, `"Local Authority"`)
* `FactionRoles.GetCitizenship()` -> `{ factionName, grantedAt, lockedByMilitary } | nil`
* `FactionRoles.ClaimCitizenship(factionName)` -> `ok, errOrMsg` (verifies `TaxAuthority.GetResidencyInfo()` matches `factionName`, non-stateless, and not locked by active enlistment)
* `FactionRoles.RenounceCitizenship()` -> `ok, errOrMsg` (fails if `activeEnlistment ~= nil`; revokes active Deputy in that faction without penalty cooldown)
* `FactionRoles.CanChangeResidencyToFaction(targetFactionName)` -> `ok, reason` (if `activeEnlistment`, only allows `targetFactionName == citizenship.factionName`)
* `FactionRoles.OnResidencyChanged(newFactionName)` -> clears non-enlisted citizenship if `newFactionName ~= citizenship.factionName`
* `FactionRoles.IsEnlistmentBlacklisted(factionName)` -> `isBlacklisted, rivalFactionName`
* `FactionRoles.RecordFactionConflict(factionA, factionB)` -> records mutual rivalry in `dynamicRivalries`
* `FactionRoles.GetActiveEnlistment()` -> `string | nil`
* `FactionRoles.IsEnlisted(factionOrName)` -> `boolean`
* `FactionRoles.CanEnlist(factionName)` -> `ok, reason, details` (requires citizenship in `factionName`, non-stateless, standing `>= 0`, clean record, no re-enlistment cooldown, not rival-blacklisted)
* `FactionRoles.Enlist(factionName)` -> `ok, msg`
* `FactionRoles.ResignMilitary(isDishonourable, reason)` -> `ok, msg` (clears `activeEnlistment`, keeps `serviceHistory[factionName]` & `rolesByFaction[factionName].enlisted` rank/XP intact, applies `-5` standing and 14-day cooldown on voluntary resignation, or `-15` standing and 30-day cooldown on dishonourable discharge)
* `FactionRoles.GetMilitaryInfo(factionName)` -> `{ factionName, enlisted, activeFaction, rank, rankTitle, xp, nextRankXP, hazardBonus, serviceDiscount, commendations, blacklisted, rivalFaction, reenlistCooldownDays }`
* `FactionRoles.AddMilitaryXP(factionName, xpDelta, commendationDelta, reason)` -> updates `enlisted.xp` / `commendations` & `serviceHistory`, queues `"onMilitaryRankChanged"` on promotion
* `FactionRoles.GetHazardPayMultiplier(factionName)` -> `1.0 + hazardBonus` if actively enlisted in `factionName`, else `1.0`
* `FactionRoles.GetDeputyEligibility(factionName)` -> `{ eligible, isDeputy, citizenshipOk, standingOk, cleanRecordOk, credentialOk, cooldownOk, cooldownRemDays, standing, fine, commendations, reasons }`
* `FactionRoles.ClaimDeputyCharter(factionName)` -> `ok, msg`
* `FactionRoles.RevokeDeputyCharter(factionName, reason, applyCooldown)` -> clears `rec.deputy` (preserving any `bounty_hunter` licence fallback), optionally sets 30-day reclaim cooldown, queues `"onFactionRoleChanged"`

### Queued Events
* `onCitizenshipChanged(newFactionName, oldFactionName)`
* `onEnlistmentChanged(factionName, isEnlisted, reasonCode)`
* `onMilitaryRankChanged(factionName, newRank, newTitle, xp)`
* `onFactionRoleChanged(factionName, roleKey, recordOrNil)`

---

## Detailed Implementation Tasks

### Task 1.1: Implement Citizenship, Military Enlistment & Deputy APIs in `data/libs/FactionRoles.lua`
1. Add `citizenship`, `activeEnlistment`, `serviceHistory`, `dynamicRivalries` locals and include them in `Serializer:Register("FactionRolesDB", ...)` with nil-safe backward compatibility for old saves (`loaded_data.rolesByFaction` only).
2. Reset all new state cleanly in `onGameStart` (when no `loaded_data`) and `onGameEnd`.
3. Implement all public APIs listed above, including `FlightLog.RecordTransaction` notices for Citizenship, Enlistment, Resignation, Rank Promotion, and Deputy Charter grant/revocation.
4. Listen to `"onFactionStandingChanged"`: if `rolesByFaction[name]` has active `deputy` and `newScore < 40`, call `RevokeDeputyCharter(name, "Standing fell below Friendly threshold")`.

### Task 1.2: Enforce Military Residency Lock in `data/modules/Economy/TaxAuthority.lua`
1. In `TaxAuthority.RegisterResidency(station)` (`data/modules/Economy/TaxAuthority.lua:352`):
   * After `TaxAuthority.CanChangeResidency()`, resolve `factionName = (sys and sys.faction and sys.faction.name) or "Independent Systems"`.
   * Call `pcall(require, 'FactionRoles')` and check `FactionRoles.CanChangeResidencyToFaction(factionName)`. If `false`, return `false, reason`.
2. After setting `state.homeFaction = factionName` (`~line 371`), call `FactionRoles.OnResidencyChanged(factionName)` so a non-enlisted pilot moving to a new faction loses stale citizenship cleanly.

### Task 1.3: Deputy Legal Interdiction & Revocation in `data/libs/Legal.lua` & `data/modules/CrimeTracking/CrimeTracking.lua`
1. In `data/libs/Legal.lua`:
   * Add `Legal.IsAuthorizedDeputy(ship, system)`: returns `true` if `ship:IsPlayer()`, `system` has a non-stateless `faction.name`, and `FactionRoles.HasActiveRole(system.faction.name, "deputy")`.
   * Add `Legal.CanDeputyExecuteWarrant(attacker, target, system)`: returns `true` only if `Legal.IsAuthorizedDeputy(attacker, system)`, `target` is `WANTED`, and (if `target.GetWantedFaction` is available) the warrant faction matches `system.faction.name`.
   * Centralize crime consequences (`Legal.OnCrimeRecorded(ship, crime, system)`) called by both `Legal:recordPoliceCitation` and `Legal:notifyOfCrime` (and deep-space fallback in `CrimeTracking.lua`): revokes active Deputy Charter (with 30-day cooldown) on `MURDER`, `PIRACY`, `TRADING_ILLEGAL_GOODS`, or becoming wanted (`totalFine > 5500`) in that faction's jurisdiction, and issues dishonourable discharge (`ResignMilitary(true, ...)`) on `MURDER`, `PIRACY`, or becoming wanted while enlisted in that faction.
2. In `data/modules/CrimeTracking/CrimeTracking.lua`:
   * `onShipInterdicted(ship, attacker)` (`~line 117`): if `Legal.CanDeputyExecuteWarrant(attacker, ship, sys)`, allow interdiction without `PIRACY` citation; if a non-wanted interdiction hits the fallback `PlayerState.AddCrime`, also invoke `Legal.OnCrimeRecorded(attacker, "PIRACY", sys)`.
   * `onShipHit(ship, attacker)` (`~line 111`) and `onShipDestroyed(ship, attacker)` (`~line 142`): if `Legal.CanDeputyExecuteWarrant(attacker, ship, Game.system)`, exempt from `PIRACY` / `MURDER` citations.

### Task 1.4: Lobby Citizenship Panel (`data/pigui/modules/station-view/01-lobby.lua`)
1. In `drawCivilAdministrationSection(station)` (`~line 186`), under the Left Column ("CIVIL RESIDENCY & JURISDICTION"):
   * Display current **Citizenship** status (`Stateless` vs. `Citizen of <Faction>` + `Military Service Lock` badge if `activeEnlistment`).
   * Add **Claim Citizenship** button when resident at a non-penal station in a faction and not yet a citizen of that faction (and not military-locked).
   * If enlisted, disable/annotate residency transfer buttons at stations outside the citizenship faction with: `"RESIDENCY TRANSFER LOCKED TO <FACTION> (ACTIVE MILITARY SERVICE)"`.

### Task 1.5: Police Station "Military & Deputy" Tab (`data/pigui/modules/station-view/02-police.lua`)
1. Add a new tab `"Military & Deputy"` to `policeTabs` (`~line 273–357`):
   * **Military Enlistment Section**:
     * Show faction military name (`faction.militaryName` from `data/factions/*.lua`), current citizenship check, active enlistment status, Rank + XP progress gauge, hazard-pay bonus, and commendation count.
     * Show **Enlist** button (or disabled reason: missing citizenship, already enlisted elsewhere, or **PERMANENTLY BARRED: Prior service with rival `<Rival>`**), and **Resign Commission** button (with confirmation) when actively enlisted here.
   * **Faction Deputy Charter Section**:
     * Display the 3 eligibility checklist rows (`Allied Standing >= 75`, `Clean Criminal Record`, `Bounty Licence or 3+ Commendations`) with green/red indicators.
     * Add **Claim Deputy Charter** button when eligible and not yet deputized, or **ACTIVE — DEPUTIZED (PERPETUAL)** badge when active.

---

## Edge Cases & Pitfalls
* **Old Saves**: Existing saves have `FactionRolesDB` without `citizenship`, `activeEnlistment`, `serviceHistory`, or `dynamicRivalries`. Always default missing keys to `nil` / `{}` on load.
* **Independent / Uncontrolled Systems**: `Game.system.faction` can be `nil` or `"Independent"`/`"Independent Systems"`. Guard against `nil` faction names everywhere; disallow military enlistment if `not sys or not sys.faction` or at penal stations.
* **Resign + Re-enlist**: Resigning clears `activeEnlistment`, preserves rank/XP in `rolesByFaction[faction].enlisted` and `serviceHistory[faction]`, and keeps rival factions permanently blacklisted.

---

## Verification & Break-Fix Checklist
1. **Unit / Integration Checks**:
   * Start game, verify stateless pilot cannot claim citizenship without residency, and cannot enlist without citizenship.
   * Register residency at Station A (Faction X) → Claim Citizenship (Faction X) → Enlist in Faction X.
   * Advance time 90+ days (docked time dilation): verify residency transfer succeeds to Station B (Faction X) and is **blocked** at Station C (Faction Y).
   * Resign from Faction X → verify residency transfer to Station C (Faction Y) succeeds → claim Citizenship in Faction Y → verify Faction Y **Military Enlistment remains permanently locked** due to prior Faction X service.
   * Test Deputy Charter eligibility gate (`< 75` standing blocked, active fine blocked, `>= 75` + clean + licence/commendations succeeds), verify Bounty Licence tab displays `"DEPUTIZED (PERPETUAL)"`, and verify interdicting/destroying a `WANTED` ship in faction space incurs no fine while firing on a `CLEAN` ship revokes Deputy status.
   * Save and reload mid-enlistment and verify all state persists cleanly.
2. **Build & Syntax Check**:
   ```bash
   cmake --build build --target pioneer build-data -j 8 && cmake --build build --target unittest && ./build/unittest
   ```

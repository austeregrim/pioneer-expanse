# Plan J: Complete Gameplay Test Plan & Walkthrough

This walkthrough covers every system implemented across **Plan J (Batches 1–5)**:
1. **Batch 1**: Residency → Citizenship → Military Enlistment chain, 90-day residency lock, permanent rival lockout, and Faction Deputy Charter.
2. **Batch 2**: `[FRONTLINE CONVOY]` supply runs, `[BLOCKADE RUN]` sourcing, enlisted hazard pay, and `Pirates.lua` convoy risk scaling.
3. **Batch 3**: `[FRONTLINE EVAC]` / `[MERCY DISPATCH]` passenger extractions and `[FRONTLINE RECON]` orbital sweeps with Plan I dark-running stealth bonuses.
4. **Batch 4**: Autonomous **Plan A** fleet delegation (`FrontlineSupply` & `FrontlineExtraction`) plus `PATROL` and `AUTO_TRADE` warfront relief.
5. **Batch 5**: Optional **Naval Combat Zones**, crime exemptions, and **Combat Bond** redemption.

---

## Pre-Flight Setup

1. **Launch the game**:
   ```bash
   ./build/pioneer
   ```
2. **Recommended Test Loadout**:
   - **Flagship**: A medium/multi-role ship (or switchable fleet ships) equipped with:
     - **Cargo capacity** (`>= 25t` free) for Supply Convoys.
     - **Passenger Cabin(s)** (`>= 4–8` free berths, e.g., `misc.cabin_s3`) for Extractions.
     - **Orbital Scanner** for Frontline Recon.
     - **FSD Interdictor + Warrant Scanner + Weapons/Shields** for Deputy enforcement and Combat Zones.
   - **Plan A Fleet** (for Phase 5): At least **2 crewed fleet vessels** with Captains hired—one cargo hauler with a passenger cabin installed (or two ships: one freighter, one passenger/combat ship), plus one armed combat ship for `PATROL`.
3. **Locate Active `FRONTLINE` Crises**:
   - Open **InterCast** or the **Galactic / Sector Map** and look for active `FRONTLINE` crises (`BLOCKADE`, `INSURGENCY`, `PIRATE_SURGE`, or `INDUSTRIAL_DISASTER`), especially **Severity 2+** `INSURGENCY` or `BLOCKADE` systems for Phase 6.
   - Keep a **clean baseline save** before starting destructive/penalty tests (such as Deputy revocation or friendly fire).

---

## Phase 1: Residency, Citizenship, Military Enlistment & Rival Lockout (Batch 1)

### 1.1 Stateless Gate & Residency Registration
1. Dock at a non-penal station in **Faction X** (e.g., Solar Federation / Commonwealth / Haber, etc.) while still **Stateless**.
2. Open **Station Lobby** → **Civil Residency & Jurisdiction**:
   - Verify Citizenship shows `Stateless`.
   - Verify **Claim Citizenship** is blocked/disabled until you hold civil residency in that faction.
3. Open **Police** → **Military & Deputy** tab:
   - Verify Enlistment is unavailable (`Citizenship required` / disabled button).
4. Return to **Lobby**, register **Residency** at the current station, then click **Claim Citizenship**:
   - **Check**: Citizenship updates to `Citizen of <Faction X>` and a **FlightLog** entry is recorded.

### 1.2 Military Enlistment & 90-Day Residency Lock
1. Open **Police** → **Military & Deputy**:
   - Verify faction military name (e.g., *Federal Navy*), rank (`Rank 0` / initial rank), hazard bonus, service discount, and XP gauge.
   - Click **Enlist** → verify status switches to `ACTIVE COMMISSION` and a **FlightLog** entry is created.
2. Open **Lobby**:
   - Verify the `Military Service Lock` badge is displayed.
   - Verify residency transfer shows locked (`RESIDENCY TRANSFER LOCKED TO <Faction X> (ACTIVE MILITARY SERVICE)`).
3. Use **docked time dilation** to advance **90+ days** until your residency relocation cooldown clears:
   - **Same-faction test**: Fly to another station in **Faction X** and relocate residency → **Must succeed**.
   - **Cross-faction test**: Fly to a station in **Faction Y** (a rival/different faction) and inspect **Lobby** → residency transfer **must remain blocked** while enlisted in Faction X.

### 1.3 Resignation & Permanent Rival Lockout
1. Return to a **Faction X** station, open **Police** → **Military & Deputy**, and click **Resign Commission** (confirm the modal):
   - **Check**: Standing drops by `-5`, a **14-day re-enlistment cooldown** begins, and your earned Rank/XP remain preserved in service history.
2. Verify **Lobby** residency lock is cleared (once the 90-day residency term is up, you can relocate residency to **Faction Y**).
3. Relocate residency to **Faction Y** and click **Claim Citizenship** in **Faction Y** → **Must succeed**.
4. Open **Police** → **Military & Deputy** at **Faction Y**:
   - **Check**: Military enlistment **must remain permanently barred**: `PERMANENTLY BARRED: Prior service with rival <Faction X>`.
5. *(Optional sanity check)* Visit a **Penal / Prison** station and an **Independent** system:
   - **Check**: Both display clear disabled notices explaining that enlistment and Deputy charters are unavailable there.

> [!TIP]
> Reload your baseline save (or stay enlisted in your preferred faction) before starting Phase 2–6 so you have an active military commission for hazard bonuses and military XP tests!

---

## Phase 2: Faction Deputy Charter & Warrant Enforcement (Batch 1)

1. Dock at a station in your enlisted/allied faction and open **Police** → **Military & Deputy** → **Faction Deputy Charter**:
   - Verify the 4 requirement rows:
     - Citizenship in `<Faction>`
     - Allied Standing `>= 75`
     - Clean Criminal Record (`0` fine)
     - Bounty Licence, Active Military, or `3+` Commendations
2. Once all rows show `[PASS]`, click **Claim Deputy Charter**:
   - **Check**: Status becomes `ACTIVE — DEPUTIZED (PERPETUAL)` and a **FlightLog** entry is logged.
   - Switch to the **Bounty Licence** tab in Police → verify it reflects perpetual Deputy status / waived renewal fees.
3. Launch into **Faction** space, scan traffic with a **Warrant Scanner** to find a ship `WANTED` by that faction:
   - Interdict the target in Supercruise (FSD Interdictor) and destroy it.
   - **Check**: **Zero** `PIRACY` or `MURDER` citations are recorded.
4. **Revocation Check (on a throwaway save)**:
   - Fire on a `CLEAN` ship in faction jurisdiction.
   - **Check**: Deputy Charter is revoked (with a 30-day cooldown) and, if actively enlisted in that faction, triggers a **dishonourable discharge** (`ResignMilitary`). Reload your main save afterward.

---

## Phase 3: Frontline Supply Convoys & Blockade Running (Batch 2)

1. **Rear-Line Supply Convoy (`[FRONTLINE CONVOY]`)**:
   - Dock at a non-frontline station within `25–35 ly` of an active `FRONTLINE` system.
   - Open the **Bulletin Board (BBS)** and look for `[FRONTLINE CONVOY]` adverts.
   - **Check**: Verify the advert notes your **Enlisted Rank Hazard Bonus** (if enlisted), commodity legality, tonnage, and deadline.
   - Accept the contract (cargo loads directly into your hold), fly to the `FRONTLINE` station, and dock.
   - **Check on completion**:
     - Cargo is deducted accurately.
     - Credits paid include standing + hazard bonus.
     - **FlightLog** records the Frontline Supply transaction with crisis relief %.
     - `MacroGalaxyEngine` crisis progress increases (and InterCast publishes a stage update if a threshold is crossed).
     - **Police → Military & Deputy** shows increased Military XP and `+1` Commendation.
2. **Frontline Blockade Run (`[BLOCKADE RUN]`)**:
   - While docked at the `FRONTLINE` station, check the BBS for `[BLOCKADE RUN]` pickup contracts (requiring you to fly to a rear-line supplier, load materiel, and haul it back).
   - **Check**: On arrival at the supplier port, verify cargo auto-loads (or via mission action) and delivers cleanly upon returning to the frontline port.
3. **Save/Reload & Piracy Pacing Check**:
   - Accept a supply mission, save mid-transit, reload, and finish delivery → verify normal completion and exact cargo deduction.
   - While carrying an active `FrontlineSupply` contract in the target `FRONTLINE` system, cruise in Supercruise and verify pirate interdiction risk feels elevated without bypassing the `180s` interdiction cooldown.

---

## Phase 4: Troop/Refugee Extractions & Dark-Running Recon (Batch 3)

### 4.1 Frontline Extractions (`FrontlineExtraction`)
1. **Direct Evacuation (`[FRONTLINE EVAC]`)**:
   - At a `FRONTLINE` station, open the BBS and check `[FRONTLINE EVAC]` contracts (`2–8` wounded personnel, medical staff, envoys, or civilians).
   - **Berth guard check**: If your ship has fewer free berths than required, attempting to accept must fail cleanly with a clear berth message without taking the contract.
   - Accept with sufficient free berths → verify passengers embark immediately (`Passengers` berth count updates).
   - Deliver to the safe rear-line port → verify evacuees disembark, payout + tax + military XP + commendation + crisis relief are applied.
2. **Mercy Dispatch (`[MERCY DISPATCH]`)**:
   - At a safe rear-line station, accept a `[MERCY DISPATCH]` contract (`2–6` evacuees, `pickupDone == false`).
   - Fly to the frontline `originStation` and dock → verify evacuees embark automatically on dock (or via the mission screen's **Embark Evacuees** button if you freed berths after docking).
   - Return to the safe port → verify completion, payout, and clean disembarkation.

### 4.2 Dark-Running Frontline Recon (`FrontlineRecon`)
1. **Stealth Run (Dark-Running Bonus)**:
   - Ensure an **Orbital Scanner** is installed; accept a `[FRONTLINE RECON]` BBS contract at or near a `FRONTLINE` system.
   - Fly to the target body. **Before** starting the orbital scan coverage:
     - Switch **Transponder OFF**.
     - Keep speed **`< 1c`** (`< 299,792,458 m/s`, both in sub-light and Supercruise).
     - Commit **no crimes / citations** (keep outstanding fines `<= baselineFine`).
   - Complete the orbital sweep → verify the `onScanComplete` comms message confirms **Dark-running telemetry verified (+25% Stealth Recon Bonus secured)**.
   - Check the **Missions (F4)** panel → `Dark-Running` should display `INTACT (+25% bonus)`.
   - Dock at the return station (or another station controlled by the issuing faction) → verify you receive **+25% bonus pay**, **`+15` bonus Military XP**, and **`2` Commendations**.
2. **Compromised Stealth Run + Mid-Sweep Save/Reload**:
   - Accept a second `[FRONTLINE RECON]` mission.
   - Start the sweep, then briefly turn **Transponder ON** or exceed **`1c`** while coverage is advancing.
   - **Check**: Missions UI updates `Dark-Running` to `COMPROMISED (standard rate)`.
   - **Save and reload** before finishing the sweep, then finish scanning and turn it in → verify `ScanManager` + `FrontlineRecon` still complete cleanly at the standard payout (no +25% bonus).

---

## Phase 5: Autonomous Fleet Frontline Support (Batch 4)

### 5.1 Mission Delegation (`FrontlineSupply` & `FrontlineExtraction`)
1. **Delegate Direct-Haul `FrontlineSupply`**:
   - Accept a `[FRONTLINE CONVOY]` contract while docked with a crewed fleet cargo ship available.
   - Delegate it to that fleet ship via the Fleet Mission Delegation UI.
   - **Check**:
     - Cargo transfers out of your Flagship into the fleet ship's hold.
     - When the fleet ship completes transit (live or via docked time dilation), verify single payout + operations tax, ship log entry, crisis progress tick, and `65%` military XP (if enlisted).
     - Dock at the mission's target/origin station afterward → verify **no double payout** or phantom mission failure.
2. **Delegate 2-Leg `FrontlineSupply` (`[BLOCKADE RUN]`)**:
   - Accept a `[BLOCKADE RUN]` (`pickup = true`, `cargo_picked_up = false`) and delegate it to a fleet cargo ship with sufficient free hold space.
   - **Check**: Ship flies `supplier -> ON_SITE pickup -> frontline delivery`, completes cleanly, and pays once.
3. **Delegate `FrontlineExtraction`**:
   - **Guard 1 (Embarked on Flagship)**: Accept a `[FRONTLINE EVAC]` (`pickupDone = true`) and verify delegation is **rejected** (`Evacuees are already embarked on the Flagship`).
   - **Guard 2 (Berth Check)**: Accept a `[MERCY DISPATCH]` (`pickupDone = false`) requiring `N` berths:
     - Verify a fleet fighter with `0` cabins shows ineligible (`Needs N passenger berths (0 installed)`).
     - Delegate to a crewed fleet ship with `>= N` passenger berths → verify it flies `originStation (pickup) -> ON_SITE -> destination`, pays once, updates crisis progress, and awards `65%` military XP.

### 5.2 Autonomous `PATROL` and `AUTO_TRADE` in `FRONTLINE` Systems
1. Order a crewed combat fleet ship to **`PATROL`** inside an active `FRONTLINE` system.
2. Order a crewed freighter fleet ship to **`AUTO_TRADE`** near an active `FRONTLINE` system.
3. Advance time via **docked time dilation** (several hours):
   - **Check Fleet Logs**:
     - `PATROL` sweep victories log `Frontline security patrol stabilized <System> (+1.5% warfront relief)` no more often than once per `600s` sim-time.
     - `AUTO_TRADE` deliveries into the `FRONTLINE` system log `Frontline trade delivery relieved <System> (+1.0% warfront relief)` no more often than once per `900s` sim-time.
   - **Check Performance/UI**: Zero comms popup flood during catch-up time dilation, and crisis progress advances steadily without exploding to `100%` in a single tick.

---

## Phase 6: Optional Combat Zones & Naval Combat Bonds (Batch 5)

1. **System Entry & Supercruise Safety**:
   - Jump into a **Severity 2+** `FRONTLINE` system whose crisis type is **`INSURGENCY`** or **`BLOCKADE`**.
   - **Check**: Receive **one** tactical advisory (`TACTICAL ADVISORY: Contested Naval Zone detected near <Planet>. Combat participation optional.`).
   - Cruise around in Supercruise far from the anchor planet → verify **no CZ wings spawn** and Supercruise FPS remains completely unaffected.
2. **Dropping into the Combat Zone**:
   - Approach the announced anchor planet, drop out of Supercruise within `150 km` of its surface (and `> 20 km` from any station).
   - **Check**:
     - **Wave 1** spawns cleanly nearby: up to 3–4 `<Faction> Defense Wing` friendlies and 3–4 `Insurgent Raider` / `Blockade Enforcer` hostiles engaging each other.
     - Destroy hostiles until `<= 1` hostile remains → **Wave 2** reinforces (never exceeding 4 friendly + 4 hostile active ships).
3. **Kill Accounting, Crime Exemption & Escort Kills**:
   - Hit, interdict (if tested in-system), and destroy marked CZ hostiles:
     - **Check**: **Zero** `PIRACY` or `MURDER` fines/warnings.
     - **Check**: Each kill awards a **Combat Bond** (`3,500–12,000 Cr`), adds `+2.5` crisis progress (capped at `15.0` max per sortie), and awards `+15` Military XP if enlisted in that faction.
   - *(If accompanied by a `PlayerFleet` ship on `FOLLOW`)* Let your fleet ship score a killing blow on a CZ hostile → verify the Combat Bond still credits to your ledger.
   - *(Friendly-fire check on throwaway save)* Fire on a `<Faction> Defense Wing` friendly ship → verify normal `PIRACY` crime applies.
4. **Combat Bond Redemption & Multi-Faction Ledger**:
   - Dock at a station in that faction → open **Police** → **Military & Deputy** → **Naval Combat Bonds**.
   - Verify pending Combat Bonds appear for the current faction. (If you also hold bonds from another faction, verify they are listed under *Unredeemed Bonds Held for Other Factions*).
   - Click **Redeem Combat Bonds** → verify credits are added, **FlightLog** records the `BOUNTY` / Combat Bonds entry, and the pending balance resets to `0`.
5. **Cleanup & Save/Reload**:
   - Save and reload while holding unredeemed Combat Bonds → verify `pendingBonds` persists cleanly.
   - Leave the system (or dock during an active skirmish) → verify no stale ship references or Lua errors occur.

# Pioneer: Expanse — Plan I: Transponder, Dark Running & Sub-Light Detection

**Status:** **Completed** — All core milestones (M1–M9), unit tests, and NPC/HUD/equipment integrations implemented and verified.
**Depends on:** Plan 04 (Supercruise, FSD Interdictor, PolicePatrol, Pirates). **Related:** Plan A (wingmen; keep fights at most 2v1 vs the player).

> **Scope rule:** every rule below applies identically to the player and NPCs. NPCs need the same modules and obey the same perception limits. No omniscient AI.

---

## 0. Fundamentals (read first)

**Supercruise is not the same as "faster than light".** Supercruise is an FSD flight mode with a speed range from **30 km/s (0.0001c) up to 2,001c**. Only the part of that range at or above **1c** makes a ship a point of light.

| Flight state | Speed | Visible to others? |
|---|---|---|
| Normal flight | any | By radar/sensors/visual range, like any ship |
| Supercruise, **below 1c** | 30 km/s to just under c | **Not a light.** Same stealth situation as dark sub-light flight; only transponder or sensors reveal it |
| Supercruise, **at or above 1c** | 1c to 2,001c | **Everyone sees it.** An arc-welding-bright point of light |

Rules for the light above c:
- **Everyone sees it. No computer, module, sensor or cone is needed**, and **nothing can hide it** (the transponder, silent running, etc. do not matter). If you stood outside a ship with no equipment you would still see something travelling faster than light.
- The **only** ways to avoid being seen are to **drop below 1c** or to **be hidden behind a body** (star, planet, moon, or a future anomaly such as a nebula or cloud). Occlusion is line-of-sight only.
- Being visible is what makes it **targetable**: anyone can target it, from anywhere in the system, like targeting a bright star. No module required.

Rules for supercruise in general:
- **You cannot attack or land in supercruise.** To dogfight, one ship must pull the other out of supercruise (interdiction).
- A smuggler can enter supercruise and stay **below 1c** to cross the system quickly and unseen. They only become visible if they speed up past c.

---

## 1. Design Summary

Space is huge. A ship is seen only if it is a bright light (above c) or is broadcasting. There is **no "invisible" flag**; stealth falls out of brightness, range and line of sight.

| State | Seen by others as |
|---|---|
| Supercruise ≥ 1c, transponder on | Point of light, **with ship ID** |
| Supercruise ≥ 1c, transponder off | Point of light, **unidentified** |
| Below 1c (supercruise or normal flight), transponder on | A **targetable object with its ship ID**. Anyone can target it |
| Below 1c (supercruise or normal flight), transponder off ("dark") | **Not seen** beyond 1 km (hull ID readable) unless the observer has a sensor that detects dark ships (§6), or already holds a lock (§2) |

### Transponder switch
- A simple on/off button on the flight HUD, next to the lights button. New key binding too.
- **Off is instant** (logically a physical disconnect).
- **On is nearly instant: 1 s or less** to start broadcasting.
- No cooldown on toggling.
- Docking: stations refuse dark ships; the player turns it on themselves (no auto-toggle; show a refusal message).

---

## 2. Target-Lock Persistence (core rule)

- A lock is held until the **locker changes target**, the target dies or leaves the system, or **line of sight is lost** (§3).
- Going dark, dropping below c, or exiting supercruise does **not** break a lock. A locked dark ship keeps a live marker for the locker as long as line of sight holds.
- Distance does not break a lock. The locker's own loss of interest does (they pick another target, §4).
- The target is **not told** it was locked (unless it has a scan-detection module, §5).
- The target knows only what *it* did (went above c with transponder off). Its escapes:
  1. **Break line of sight** behind a star/planet/other body.
  2. **Hyperjump out** (all locks cleared on system change).
  3. **Dock at a station** (locks cleared on dock).
  4. Wait for the locker to drop it for a higher-priority target.
- Cloaking/ECM-type lock breaking is **out of scope**.

---

## 3. Line of Sight (what hides you)

- **Occlusion test:** a ray between observer and target blocked by a body sphere (star, planet, moon) = no line of sight. Design the occluder list so nebulae/clouds/anomalies can be added later (e.g. `IsOccluded(from, to) -> bool` over a list of occluder volumes).
- **Seeing and targeting a light above c has no cone.** Anyone with a clear line sees it and can target it.
- **Police witnessing is different: it uses a field of view.** To count as a witness, a police ship must have the light **inside its forward field of view (about 65°, tune)** and a clear line of sight. A dark light that is behind police, or outside their field of view, or occluded, is not witnessed.
- Line of sight is used for: seeing a light above c, keeping a lock (§2), and police witnessing (with the field-of-view test added).
- Whether police *act* on a witnessed light is a valuation decision (distance, catch-up time, patrol duty), see §4.

#### Police response sequence
1. **See:** a dark light above c enters a police ship's field of view with clear line of sight. That is the witness event.
2. **Target** it (lock persists, §2).
3. **Pursue and warn:** two warnings, each 3 to 5 s, ordering the transponder on.
4. **Scan for illegal cargo** (needs lock, range, scanner module). Police announce the scan first.
5. **Interdict if illegal cargo is found.**
6. **If the transponder is still off** after the warnings, **interdict anyway** and, once the ship is out of supercruise and within 1 km, **read the ship ID and check for bounties/warrants.**
- Interdicting an unidentified ship in a system that requires transponders is legal for police.

### Transponder law by system type
| System type | Transponder law | Dark ship consequence |
|---|---|---|
| Lawful / peaceful (most inhabited systems) | **Required on at all times** in open space | Being dark is an offence on its own, sub-light or supercruise, once a police ship witnesses it. Police **warn**, order the transponder on, and then have a **reason to cargo-scan** for illicit goods |
| Lawless / pirate | Not required | No offence, no police interest |
| Uninhabited | No laws | No offence, no police |

- Penalty severity scales with system security (fine at low, bounty and active pursuit at high). Add a per-system "transponder required" flag derived from government/law level in `data/libs/Legal.lua`; do not hard-code system names.
- New `CrimeTracking` type, e.g. `TRANSPONDER_OFF`. It is committed when a police ship with the dark light in its field of view and clear line of sight (§3) sees a dark ship above c, or reads a dark ship's hull within 1 km, in a system that requires the transponder.
- **Police have legal authority to cargo-scan** any ship they have locked in a policed system. This is separate from the crime: a warning plus a dark ship is the usual trigger, but police also scan transponder-on ships, per the standing rules below.
- Docking: refused to dark ships in any system whose stations enforce the law.

---

## 3b. Identity & Warrants

What other ships can learn about you:

| Your state | What an observer gets |
|---|---|
| Transponder **on** (any speed) | A targetable object with its **ship ID**. The ship ID can be looked up in the warrant database (see below) |
| Above c, transponder **off** | A targetable, **unidentified** object. No ID, so **no warrant lookup is possible** |
| Sub-light, dark, within **1 km** | The painted hull ID is readable, like a licence-plate reader. Any ship can do this with no module. Gives the ship ID, so warrants can be looked up |

Consequences for play:
- **Police can check warrants instantly from the ship ID**, so a transponder-on wanted ship can be identified and chased across the system without being interdicted.
- **Visual ID only works out of supercruise.** It never works above c, whatever the distance.
- A dark ship above c is unidentified. Police do not know whether it is wanted, only that it is breaking transponder law. To learn its ID they must force it out of supercruise (interdiction) and close to 1 km. That gap is the core tension of the mechanic. Interdicting an unidentified ship counts as legal for police when the system requires transponders (so police are not penalised under the Plan 04 "interdicting a clean ship" rule).
- **Bounty hunter licence (per faction):**
  - Bought on the **police page in a station**, from a faction-controlled station. It covers all systems controlled by **that faction**, not the whole galaxy.
  - It has a small fee, **at most ~300 cr**, and an **expiry date** (game time; renewal at the same page). An expired licence stops the Warrant Scanner from showing that faction's warrants.
  - **Fee and term depend on the faction's need for hunters** (a per-faction value, e.g. from crime level or an unrest/war state): a faction with big crime problems charges less, offers a longer term, or grants a **perpetual licence**. Default is annual.
  - A licence is needed to **take bounty jobs/contracts** from that faction. Without it, a player in e.g. an independent system cannot pick them up.
  - A player can still **claim a bounty** they happen to earn by killing a wanted ship in other space, per existing bounty rules; the licence gates *jobs and warrant visibility*, not the payout of a lawful kill. (If this is wrong, change it here.)
- **Warrant Scanner** (module, requires at least one active licence): looks up warrants by ship ID, but **only shows warrants issued by factions you hold a current licence for**. Warrants from other factions show as "no access". It cannot identify unidentified ships; only the transponder or 1 km visual ID gives an ID.
- **Deputy (later, optional):** a player can be **deputized** by a faction, which removes the licence requirement for that faction, shows its warrants, and gives access to police ships. Requires high standing with the faction; exact path to deputy is open.
- Police always see their own faction's warrants (no licence needed). NPC bounty hunters follow the same licence and module rules.
- Spoofed or faked IDs: **not in scope** (deferred).


---

## 3c. What Plan 04 Actually Implemented (verified in code and git history)

I checked the code, not just the plan text. The relevant parts:

| Feature | State | Where |
|---|---|---|
| Supercruise speed range 30 km/s to 2,001c | **Done** | `SupercruiseController.h` (`MIN_SPEED`, `MAX_SPEED`) |
| "FTL" flag (≥ 1c) | **Done** | `SupercruiseController::IsShipFTL` |
| Observer in supercruise sees only FTL ships or **tracked locks** | **Done** | `IsShipVisibleToSensors` (commit `c22e7b9`, "FTL sensor locks") |
| Tracked lock = combat/nav target of an observer who is **also in supercruise**, with the target also in supercruise | **Done, but narrower than this plan** | `HasTrackedLock` |
| Glow/point-of-light rendering for supercruise ships | **Done** (`scGlow` material in `WorldView.cpp`; I did not verify who it draws for) | `WorldView.cpp` |
| FSD interdictor tiers 1–3 and tug-of-war | **Done** | `Internal.lua`, `SupercruiseController::CanInterdict`/`StartInterdiction` |
| Interdiction needs target ≥ 1c **or a tracked lock** ("TARGET IS SUBLIGHT" message otherwise) | **Done** | `CanInterdict` |
| Counter module: `misc.interdiction_nullifier` | **Done**: **60 s** cooldown, attacker gets an emergency drop, heat spike and **45 s** FSD reboot | `SupercruiseController.cpp` (~line 2210) |
| Pirates, PolicePatrol, CrimeTracking Lua modules | **Exist** (not audited in detail) | `data/modules/` |
| Ship-level wanted state | **Exists** | `Ship::IsWanted` |
| Transponder, hull ID visual read, warrants by ship ID, licences, witness/LOS, standing-based scans | **Not implemented** | n/a |

Gaps between today's code and this plan (the implementer must change these):
1. **A sub-light observer cannot see any supercruise ship**, including ships above c. `IsShipVisibleToSensors` returns `!targetInSC` when the observer is not in supercruise. Per §0, anyone sees ships above c, so this must change.
2. **Locks only count while the observer is also in supercruise**, and **dropping out clears them** (`ClearStaleSupercruiseTarget` after `NormalDrop`/`EmergencyDrop`). Per §2 locks should survive the observer's own drop and any change of the target's speed or flight state. This also means a countered interdictor currently loses its target on drop; the plan wants it to keep it.
3. The nullifier is one cooldown **per target ship** (good for tag-teaming), but check that an attacker that was countered is allowed to retain the lock (see gap 2).
4. Plan 04's statement "locking Supercruise ships is only permitted while the player is also in supercruise" is **replaced by this plan**. When implementing, update Plan 04's text too.

---

## 4. NPC Behaviour

### Police
- Follow the response sequence in §3: see (field of view + line of sight), target, pursue and warn, scan, interdict. Pursuit is subject to valuation below.
- **Priority/valuation:** pursuit value is weighted by distance/catch-up time vs. their patrol duty. A dark ship 500 AU away is worth less than a pirate 1 AU away or the station lane. Police may **drop the target** for a higher-value one, which releases the lock (the only way a lock breaks).
- Procedure when in range: announce → order "transponder on" → **cargo scan** (illegal goods) → fine/attack as appropriate. Scans are never automatic; the police must have the target locked and a scanner module.
- Do not interdict first unless the target is already known wanted (existing Plan 04 rules), or the §3 sequence has reached its interdiction steps.

### Pirates
- Stalk traders in supercruise (they are visible while above c), close into the rear cone, interdict.
- After the interdiction, **cargo scan** to judge value; if worth it, demand the cargo ejected, then attack.
- Ambush variant: sit **below 1c** (or drop out) near a lane/station arrival with the transponder off and wait. To see traders that are below c they need a sensor that detects ships; traders above c are visible to anyone. Same perception rules as everyone.
- Remember a ship cannot attack in supercruise: the interdiction is what brings the fight into normal space.
- Pirates flagged dark and witnessed above c in policed space get chased like anyone else, so they favour lawless/low-security systems or short hops.

### Smugglers (new, light-weight)
- NPC carrying illegal goods: transponder off in policed systems, travels below 1c (in supercruise or normal flight) to the destination, and only goes above c when no police have line of sight (behind bodies) or in lawless systems.
- Optional later; start with pirates and police.

### Tag-team interdiction
- The counter-interdiction module has a **cooldown**; one counter per cooldown. A second attacker landing during that cooldown pulls the target out. Same for NPC vs NPC.
- A failed/countered attacker is dropped out of supercruise and has an **FSD cooldown** (existing). They keep their **target lock**, so they know roughly where the target is, but may be unable to re-enter supercruise in time to catch up. A teammate who succeeds in pulling the target out lets the team close in 2v1 (rare, by design).
- Interdiction is a **minigame**; attentive traders can evade. It is not a guaranteed pull. NPC-vs-NPC resolves probabilistically (existing Plan 04 behaviour).
- NPCs may also fit counter-interdiction modules (same rules, same cooldown). Cap wing size at 2 attackers vs. the player (coordinate with Plan A).

### Despawn / persistence
- All ships are simulated. After a hyperjump (days of simulated time), ships known to be in system are regenerated in the system; their exact positions need not be tracked.
- Locks must be cleared on system change (§2).

### Who police scan, and who they escort (standing-based)
Police scan a locked ship based mostly on that ship's **standing with the controlling faction/government** (existing `FactionStanding.lua`), plus a little randomness ("boredom") so it is not predictable:
- Low or negative standing: scanned often.
- Neutral: scanned occasionally.
- High standing: **rarely or never scanned**. Even a player who carries illegal cargo is usually left alone. This is intended: earning high standing is how a player legitimately ends up smuggling undetected.
- Police may **escort** a high-standing ship (player or NPC) as a patrol task. Escort frequency is a tuning value; escorts must not make the player's own flight miserable (they can be dismissed or ignored).
- The transponder still matters here: a transponder-on high-standing ship is treated as trusted. A dark one is still breaking law, but a ship may have left it off by mistake, so **police always give two warnings** ("transponder off, turn it on") for every ship regardless of standing, before any standing loss, fine or bounty. **Each warning window is 3 to 5 seconds**, always longer than the transponder's turn-on time (≤ 1 s), so an honest mistake is always fixable in time.
- The warnings matter most for players, so the HUD should show the warning clearly and offer the transponder button prominently.
- All of this applies the same to NPC traders.

---

## 5. Scanning Rules

- Cargo scan and equipment scan are available to **anyone** with the right module, at any time, on a **locked** target within scan range. (Sub-light scans need sub-light range. Plan 04 currently says cargo/hull scans are unavailable in supercruise; keep that.)
- **Police** scan for illegal goods; **pirates** scan for valuables. Neither is automatic.
- Before scanning, police **announce it**; pirates **order cargo ejected** before attacking (comms messages).
- The target is notified only if it has a **scan detection module** (new, small utility slot item). Otherwise no warning.
- Because a lock is needed, a dark ship is only scannable if it was locked earlier (§2) or detected by a new sensor module.

---

## 6. Sensors & Radar Modules

Existing `sensor.radar` (see `data/modules/Equipment/Internal.lua`, `capabilities = { radar=1 }`) is the base. Radar range code was not traced; the implementer should read `src/Sensors.cpp`, `src/pigui/Radar.cpp`, and `Ship.cpp` (`radar_cap` stat).

- **Nerf the base radar:** it shows transponder-on ships (below c) within radar range and lights above c. (Targeting is separate and works on anyone transponder-on or above c.) Dark ships below c are not shown.
- **Upgrades drop into the existing radar slot** (`slot = { type="sensor.radar" }`) as new tiered items. Do not add a new slot type unless slots can't hold them.
- Suggested new items (names provisional):
  | Module | Effect |
  |---|---|
  | Sub-light Sensor Array I–III | Detect dark sub-light ships out to a short/medium range; higher tier = more range |
  | Wake Tracer (optional) | Shows supercruise wake origin and heading (helps the stalking/ambush loop) |
  | Scan Detector | Notifies owner when scanned (§5) |
- Mass/power costs scale with tier. Player and NPC ships buy from the same pool.

> **Save compatibility:** keep the old `sensor.radar` item id (retuned) so existing saves load. Add new items under new ids.

---

## 7. Worked Scenarios (for tests and design checks)

1. **Pirate stalks a trader.** Both in supercruise, visible to each other. Pirate closes into the rear cone and interdicts. Trader wins the minigame and escapes; pirate is dropped, keeps its lock, but is on FSD cooldown, so the trader gets away.
2. **Tag-team.** Two pirates. The trader's nullifier stops the first interdiction. The second hits during the counter cooldown and pulls the trader out; the pirates scan cargo and demand it ejected.
3. **Dark smuggler.** In a policed system the smuggler arrives, turns the transponder off and travels in **supercruise below 1c** (or normal flight) to a distant station. Never witnessed, never locked. Docking needs the transponder on.
4. **Smuggler gets seen.** The smuggler goes above c with a police ship having it in its field of view and clear line of sight. Police lock it, chase if the value is high enough, announce a scan, and order the transponder on. The smuggler's real escape options are hyperjump, or dock, or hope police drop the target.
5. **Police distraction.** A police ship has locked a dark ship 500 AU away; a pirate attacks a trader 1 AU away. Police drop the old lock and engage.
6. **Pirate ambush.** A pirate sits dark near a station arrival, with a Sub-light Sensor Array. Traders without one never see it until the interdiction.

---

## 8. Implementation Milestones

Suggested order; each milestone should build and be playable before moving on.

1. **M1: Transponder state.**
   - Add `m_transponderOn` (default true) to `Ship` (`src/Ship.h/.cpp`), with ~3 s turn-on delay and instant turn-off; serialize in save/load.
   - Lua API in `src/lua/LuaShip.cpp`: `SetTransponder(bool)`, `GetTransponder()`.
   - HUD button next to the lights button in `data/pigui/modules/flight-ui/`; new key binding in `PlayerShipController` bindings.
2. **M2: Sensors respect transponder.**
   - Rewrite `SupercruiseController::IsShipVisibleToSensors` (and the contact loop in `src/Sensors.cpp`): a ship above c is visible and targetable to **every** observer with line of sight; below c it is targetable if its transponder is on, or the observer has a dark-ship sensor, or the observer holds a lock. Transponder-on ships show their ship ID; transponder-off ships show none.
   - Fix gap 1 in §3c: sub-light observers must be able to see and target ships above c.
3. **M3: Lock persistence.**
   - Fix gap 2 in §3c: change `HasTrackedLock` and `ClearStaleSupercruiseTarget` so a lock survives the observer's own drop and the target changing speed or state. Clear only on target change, target death/leave, hyperjump, dock, or **line of sight lost** (§3).
   - Make sure `Sensors::OnDeleted` etc. still null correctly.
4. **M4: Witness model, system transponder law and identity.**
   - Add the "transponder required" flag to `Legal.lua` by law level; add ship-ID visibility rules (§3b) and a warrant lookup function.
   - Implement the line-of-sight (occlusion) test and the police field-of-view test as reusable helpers (new small file, e.g. `src/ship/Visibility.h/.cpp`).
   - Hook into `PolicePatrol.lua` (system-wide check on a timer, per police ship) and `CrimeTracking.lua` (new crime type).
5. **M5: Police behaviour.** Pursuit valuation, announce/order/scan sequence, dropping a lock for a better target.
6. **M6: Pirate behaviour.** Cargo scan, eject-cargo demand, ambush logic in `data/modules/Pirates.lua`.
7. **M7: Modules and licences.** Per-faction bounty hunter licence on the police station page (fee, expiry, saved per faction), Warrant Scanner (filters by licence), Sub-light sensor tiers, scan detector, retuned base radar, NPC loadouts and shop stocking.
8. **M8: Counter-interdiction tag-team checks.** The nullifier (60 s per-ship cooldown, 45 s attacker FSD reboot) already exists; verify a second attacker can land during the cooldown, and that a countered attacker keeps its lock (gap 2). Fix gaps only.
9. **M9: Smuggler NPCs and missions (optional).**

---

## 9. Verification

- **Unit tests** (`./build/unittest`): line-of-sight/occlusion and field-of-view helpers; transponder delay and instant-off; lock persistence across mode change; lock clears on hyperjump/dock.
- **Manual scenarios:** each of §7, run with the debug spawn tools.
- **Regression:** old saves load; radar still works for transponder-on ships; docking still works.

---

## 10. Open / Deliberately Deferred

- Licence base fee (cap ~300 cr), per-faction need formula, perpetual-licence threshold, renewal UI.
- **Deputy status** and police ship access (needs its own design; do not build in the first pass).
- **Military enlistment** (not in the game yet, only news reports exist): enlisting to support a faction's war effort would reuse this licence/standing/warrant structure (per-faction, standing-gated, with access to faction ships and warrants). Keep licence and standing data structures generic (e.g. a per-faction "role" record, not a bounty-hunter-only flag) so enlistment and deputy can be added later. Needs its own plan.
- Nebula/cloud occluders (interface only for now).
- Police field of view value (draft ~65°) and how far a transponder-on ship can be seen on the radar display (targeting itself is unrestricted).
- Stealth heat/silent-running mechanics (not wanted yet).
- Spoofed transponders / fake identity (not wanted yet).
- Black-market docking rules (not important per design).

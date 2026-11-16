# Plan A: Multi-Ship Ownership, Station Hangars, Crewed Fleet & X4-Style Autonomy

**Document Version**: 1.0  
**Status**: Next Up (Zero New Assets Required)  
**Priority Tier**: Plan A (Immediate Next Priority Ahead of Plan B SRVs)  
**Parent Roadmap**: [`01_EXPANSE_LONG_TERM_ROADMAP.md`](./01_EXPANSE_LONG_TERM_ROADMAP.md)  

---

## 1. Strategic Objective

Transform **Pioneer: Expanse** from a single-ship piloting experience into a living fleet management simulation inspired by *X4: Foundations*—requiring **zero new 3D models or asset creation** by building cleanly on existing hull definitions, `Character` crew members, `SpaceStation` hangars, `AICmd` / `SupercruiseController` flight, and Lua/PiGui panels.

Players can purchase and store multiple ships across stations, hire captains and bridge/engineering crew with skill progression, issue autonomous orders (escort, auto-trade, ring mining, bounty patrol, ferrying), delegate Bulletin Board missions to crewed ships, and track fleet operations both in-system (live C++ physics & Supercruise) and out-of-system (real-time OOS background simulation).

---

## 2. Phase Breakdown & Architecture

### Phase A1: Player Fleet Registry & Station Hangar Storage

#### Core Data Model (`data/modules/PlayerFleet.lua`)
Maintain a serialized `PlayerFleet` registry indexed by persistent `shipUid`:
* **Ship Record Schema**:
  * `uid`, `shipName` (callsign/label), `hullId`, `skin`, `pattern`
  * `equipment`: list of `{ slot, id }` installed modules (preserving custom player outfits & upgrades)
  * `cargo`: commodity count table `{ [commId] = count }`
  * `fuel` (`0..100`), `hyperdriveFuel`, `hullPercent`
  * `location`: `{ mode = "DOCKED" | "IN_SYSTEM" | "OOS", systemPath, stationPath, liveShip }`
  * `crew`: `{ captain = Character?, members = Character[] }`
  * `order`: `{ type = "IDLE" | "FOLLOW" | "DOCK" | "AUTO_TRADE" | "AUTO_MINE" | "PATROL" | "MISSION", params = {}, state = ..., budget = 0 }`
  * `stats`: lifetime trade profit, ore mined, bounties collected, missions completed.

#### Shipyard & Hangar UI
* **Shipyard Purchase Modes** ([`04-shipMarket.lua`](../data/pigui/modules/station-view/04-shipMarket.lua)):
  * **Trade-In Current Ship** (existing flow).
  * **Buy & Switch (Store Current Ship Here)**: Purchases the new hull, transfers the player's current vessel into the current station's Hangar (`PlayerFleet`), and transfers the player directly to the new vessel.
  * **Buy into Hangar**: Purchases the hull directly into the current station's Hangar without leaving the active flagship.
* **Station Hangar Bay Tab** (`data/pigui/modules/station-view/13-hangar.lua`):
  * Lists all ships stored at the current station and remotely across the galaxy (showing system, station, status, captain, current order, and hull/fuel).
  * **Swap Active Ship**: Board any docked ship at the current station; packs the previous flagship into `PlayerFleet` (retaining its fitted equipment, modules, and cargo) and instantiates the newly boarded ship on pad (`SetShipType`, skin/pattern, `EquipSet`, `CargoManager`, crew roster).
  * **Remote Transfer / Ferry**: Order a ship stored at another station to be ferried to the current port (time-scaled by jump/Supercruise distance, or piloted live if a Captain is assigned and the route is safe).
  * **Cargo & Module Swap**: Move stored cargo or uninstalled/compatible equipment between ships docked at the same station.

---

### Phase A2: Hiring Captains, Crew Roles & Skill Progression

#### Captain Assignment & Roles ([`06-crew.lua`](../data/pigui/modules/info-view/06-crew.lua), `data/libs/Character.lua`)
* Allow any hired `Character` crew member to be designated **Captain** of a docked or active ship, enabling that ship to launch and operate autonomously without the player aboard.
* Track 5 role-relevant skills (`1–5` stars or `0–100` XP) per `Character`:
  * **Piloting**: improves Supercruise acceleration/brake precision, interdiction evasion, and docking speed.
  * **Navigation**: widens automatic jump routing radius and cuts jump fuel usage / cooldown turnaround.
  * **Trading**: discovers better buy/sell spreads within allowed sector range and avoids saturated low-margin markets.
  * **Combat**: improves weapon accuracy, target leading, shield management, and hostile threat assessment.
  * **Mining**: increases `RingField` yield efficiency, heat tolerance, and fragment scoop speed.
* Crew earn skill XP whenever completing autonomous orders or missions; support automated periodic salary payroll (`CrewRoster` + `PlayerFleet` crew) with optional per-run profit share.

---

### Phase A3: Autonomous Fleet Orders (X4-Inspired Command Suite)

#### Fleet Command View (`data/pigui/modules/info-view/05-fleet.lua`) + Map Context Actions
Provide a unified **Fleet Command** tab in `InfoView` (plus right-click/target actions in `SystemView` and `SectorView`) to command any crewed ship in the fleet:

1. **Follow / Wingman Escort (`FOLLOW`)**:
   * Undock from current station (if docked), enter formation offset relative to `Game.player`, match Supercruise engagements and hyperspace jumps along with the player, and automatically engage hostiles (`AIKill`) targeting the player or the wingman.
2. **Dock At / Fly To Station (`DOCK`)**:
   * Autonomous launch, Supercruise transit (using `AICmdFlyTo` and hyperspace jumps if cross-system), safe disengage, and docking at the designated destination station.
3. **Auto-Trade (`AUTO_TRADE`)**:
   * Configurable `homeSystem` and max jump radius (`0–3` jumps), minimum profit-per-ton filter, and working trade budget.
   * Evaluates known/scanned system market prices, purchases high-margin cargo at the source port, transits to destination port, sells cargo, logs transaction history to the Fleet Ledger, and repeats.
4. **Auto-Mine Planetary Rings (`AUTO_MINE`)**:
   * Launches from home station, enters Supercruise toward a chosen ringed planet (`HasRings()`), drops into the `RingField` at safe standoff, harvests ore fragments (or mines ring nodes when equipped with mining lasers), scoops/collects ore up to cargo capacity, returns to station, and sells or stockpiles cargo.
5. **System Patrol / Bounty Sweep (`PATROL`)**:
   * Cruises trade lanes in Supercruise (`AIFlyTo` between planetary/station waypoints), intercepts `IsWanted()` pirate contacts (including Supercruise interdiction when fitted with `misc.fsd_interdictor_*`), collects bounty payouts into the player account, and docks for repairs when hull `< 50%`.

---

### Phase A4: Autonomous Mission Delegation & Dual In-System / Out-of-System Simulation

#### Mission Delegation (`MissionUtils` & [`02-missions.lua`](../data/pigui/modules/info-view/02-missions.lua))
* Add **"Assign to Fleet Ship"** on eligible active contracts (`DeliverPackage`, `CargoRun`, `SearchRescue` supply/recovery, or `Combat` patrols) when a docked/idle crewed ship satisfies cargo capacity / jump range / weapon requirements.
* Upon autonomous delivery/completion at the target station or waypoint, credit reward + reputation changes to the player and send a Comms report.

#### Dual Simulation Architecture (IS vs. OOS)
* **In-System (IS) — Live Simulation**:
  * Whenever a player-owned ship resides in `Game.system`, spawn/keep it as a real `Ship` entity in `Game.space` (`ShipBuilder` / `Space::AddBody`) running full `AICmdFlyTo`, `SupercruiseController`, docking bay animation, and `RingField` physics.
  * Friendly fleet ships render with distinct cyan/emerald wingman IFF markers (`"FLT"` / fleet tag) on sensors and in Supercruise HUD.
  * When the player enters another system (`onLeaveSystem`) or a fleet ship hyperjumps out of the current system (`onShipLeaveSystem`), snapshot the ship's live state (hull, fuel, cargo, equipment, crew, active order) into `PlayerFleet`.
* **Out-of-System (OOS) — Background Tick Simulation**:
  * Advance OOS ships continuously via a lightweight real-time timer (`Game.time` delta) stepping state machines (`UNDOCKING -> SC_OUTBOUND -> HYPERSPACE_JUMP -> SC_APPROACH -> DOCKING -> EXECUTING_ORDER`).
  * Resolve deterministic + probabilistic hazards (pirate ambush roll weighted by system `lawlessness`, ship shields/weapons, and captain `combat`/`piloting` skill), sending urgent Comms alerts if a fleet vessel suffers hull damage or flees to a nearby port.
  * When the player later jumps into a system containing an active OOS fleet ship (`onEnterSystem`), materialize that ship in `Game.space` at its current simulated orbit, Supercruise vector, or docking pad.

---

## 3. Target Files

* **New Lua Modules & UI Views**:
  * `data/modules/PlayerFleet.lua` (fleet registry, serialization, IS/OOS sync, order state machine, mission delegation hooks)
  * `data/pigui/modules/station-view/13-hangar.lua` (Station Hangar / Ship Swap / Cargo & Module Transfer / Remote Ferry UI)
  * `data/pigui/modules/info-view/05-fleet.lua` (Fleet Command roster, ship telemetry, autonomous orders, profit/event log)
* **Updates to Existing Files**:
  * `data/libs/Ship.lua` & `data/libs/Character.lua` (captain skill attributes, fleet crew transfer helpers)
  * `data/pigui/modules/station-view/04-shipMarket.lua` (Buy & Store vs Trade-In flow)
  * `data/pigui/modules/info-view/06-crew.lua` (assign crew to specific fleet ships / Captain promotion)
  * `data/pigui/modules/info-view/02-missions.lua` (delegate eligible contracts to a crewed fleet vessel)
  * Optional small C++ helpers in `src/lua/LuaSpace.cpp` / `src/Space.cpp` for spawning/despawning persistent fleet vessels cleanly on dock/system entry without leaving orphan hulls.

---

## 4. Verification Plan

1. **Multi-Ship Ownership & Swap**: Purchase a second vessel via **"Buy into Hangar"** and **"Buy & Switch"**; confirm previous ship retains fitted equipment, cargo, and fuel inside the station hangar and can be re-boarded cleanly.
2. **Crew & Launch Integrity**: Assign a hired NPC as Captain of a secondary ship, confirm the player remains crew on the active flagship, launch in the flagship while the secondary ship remains docked or launches autonomously.
3. **Autonomous Orders (IS & OOS)**:
   * Issue `FOLLOW` and verify the wingman undocks, follows in Supercruise, and assists against hostile ships.
   * Issue `AUTO_TRADE` and `AUTO_MINE` and confirm real credits/cargo accumulate across in-system runs and while the player jumps to another system (OOS simulation) and returns.
   * Delegate a courier/cargo contract to a fleet vessel and verify completion payout.
4. **Persistence & Tests**: Save, reload, rebuild with `cmake --build build --target pioneer build-data unittest -j 8`, and confirm `./build/unittest` passes with `0` failures.

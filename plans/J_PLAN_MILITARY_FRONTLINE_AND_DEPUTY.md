# Plan J: Military Enlistment, Frontline Support & Deputy Charter

**Document Version**: 1.0  
**Status**: Queued (After Plan E Soundscapes & Visuals — Ready for Design Discussion)  
**Priority Tier**: Plan J (Active Systemic Gameplay Pillar)  
**Parent Roadmap**: [`01_EXPANSE_LONG_TERM_ROADMAP.md`](./01_EXPANSE_LONG_TERM_ROADMAP.md)  
**Depends On**: [`I_PLAN_TRANSPONDER_AND_STEALTH.md`](./I_PLAN_TRANSPONDER_AND_STEALTH.md) (per-faction licence/standing/warrant architecture) & `MacroGalaxyEngine` (`FRONTLINE` crises)  

---

## 1. Strategic Objective

Build upon **Plan I**'s per-faction licence, standing, and warrant framework and **MacroGalaxyEngine**'s `FRONTLINE` conflict crises to give players and their **Plan A** fleets meaningful ways to participate in faction conflicts and law enforcement—prioritizing **non-combat logistics, reconnaissance, fleet delegation, and patrol authority** alongside optional direct combat zones.

> **Design Principle**: Combat is never mandatory for progression. Freight haulers, blockade runners, scouts, and fleet commanders can shape warfronts and earn military rank or Deputy status without forced dogfighting.

---

## 2. Core Pillars (For Design Discussion)

### 2.1 Non-Combat & Logistics Frontline Support (First-Class Loops)
* **Blockade Running & Supply Convoys**: Deliver high-priority munitions, reactive armor plates, fusion cells, and medical supplies into `FRONTLINE` crisis systems under active patrol/interdiction risk.
* **Troop & Refugee Extraction**: Evacuate wounded personnel, diplomatic envoys, and displaced civilians from contested stations to safe rear-line starports.
* **Frontline Recon & Telemetry Scans**: Scan contested beacons, orbital staging zones, and hostile logistics convoys (synergizing with Plan I dark-running and `ScanManager`) to supply intelligence that shifts frontline crisis progress.
* **Plan A Autonomous Fleet Support**: Delegate supply runs, recon routes, or defensive patrol/escort orders to crewed **PlayerFleet** vessels, letting player-built logistics wings sustain a warfront.

### 2.2 Military Enlistment & Rank Progression
* **Generic Per-Faction Role Record**: Extend Plan I's per-faction role/licence structure (explicitly left extensible in Plan I §10) to track military enlistment, service rank, and campaign commendations per major faction.
* **Frontline Contract Boards & Warfront Impact**: Enlisted pilots unlock dedicated faction logistics/recon/patrol assignments, military hazard pay bonuses, and preferential starport servicing—directly accelerating positive `FRONTLINE` crisis resolution in `MacroGalaxyEngine`.

### 2.3 Faction Deputy Charter (from Plan I §10)
* **Standing-Gated Deputization**: Pilots who reach high standing and clean service records with a controlling faction can earn **Deputy** status.
* **Privileges**: Waives ongoing bounty-hunter licence renewal fees for that faction, grants persistent faction-wide warrant visibility, and authorizes legal interdiction/detainment of `WANTED` targets within faction jurisdiction.

### 2.4 Optional Combat Zones
* **Contested Space Skirmishes**: Optional high-intensity naval conflict zones in `FRONTLINE` systems for combat-focused pilots or **Plan A** escort wings, paying combat bonds and rank progression without gating non-combat players out of the war effort.

---

## 3. Target Integration Points (Preliminary)
* `data/modules/CrimeTracking/` & `data/libs/Legal.lua` (per-faction role/deputy/enlistment records extending Plan I licences)
* `data/modules/MacroGalaxy/MacroGalaxyEngine.lua` (`FRONTLINE` crisis progression hooks from logistics/recon/combat deliveries)
* `data/modules/PlayerFleet/PlayerFleet.lua` (frontline logistics/patrol delegation compatibility)
* `data/pigui/modules/station-view/02-police.lua` & `05-bulletinBoard.lua` (Deputy charter status & frontline military assignments)

---

## 4. Open Design Questions (To Discuss Before Implementation)
1. Should enlistment be exclusive to one faction at a time (with desertion/transfer cooldowns) or allow independent auxiliary contracts across non-hostile factions?
2. Which specific non-combat frontline missions (supply convoys, wounded extraction, dark-running recon, fleet logistics) should ship in the first milestone?
3. What standing threshold and prerequisite milestones should gate **Deputy** status?

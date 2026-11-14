# Plan H: Capital Ships, Station Construction & Grand Strategy (X4-Style Endgame)

**Document Version**: 1.0  
**Status**: Queued (Post-Aliens / Late-Game Expansion)  
**Priority Tier**: Plan H (Grand Strategy Endgame after Plans A–G)  
**Parent Roadmap**: [`01_EXPANSE_LONG_TERM_ROADMAP.md`](./01_EXPANSE_LONG_TERM_ROADMAP.md)  

---

## 1. Strategic Objective

Build the grand-strategy endgame tier of **Pioneer: Expanse** on top of Plan A's multi-ship fleet autonomy, Plan 03/A ring mining, and Plan F/G vessel ecosystems: playable and AI-commanded **Capital Ships & Fleet Carriers**, modular **Player Station Construction**, closed-loop **Industrial Production Chains** managed by NPC **Station Managers**, and sector-scale **Task Force Command & Territorial Sovereignty**.

---

## 2. Phase Breakdown & Architecture

### Phase H1: Capital Ship Command, Multi-Turret Fire Control & Fleet Carriers

* **Capital Hull Classes**:
  * **Corvette / Frigate**: Heavily armed escort flagships bridges between heavy fighters (Plan F) and full capital hulls.
  * **Destroyer / Cruiser**: Slow-turning multi-hardpoint warships relying on directional broadside/dorsal/ventral weapon batteries.
  * **Heavy Industrial Hauler**: High-tonnage bulk freighter serving station logistics (Phase H3).
  * **Mobile Fleet Carrier**: Deep-space command base with internal landing pads/docking bays, repair/rearm/refuel services, commodity storage vaults, and long-range tritium/hydrogen carrier jump drive.
* **Multi-Turret Fire Control System**:
  * Extend `Ship` weapon mounting so turret hardpoints track independent gimbal arcs driven by configurable fire-control groups (`TARGET_ALL_HOSTILES`, `CAPITAL_SHIPS_ONLY`, `MISSILE_POINT_DEFENSE`, `ATTACK_MY_TARGET`, `HOLD_FIRE`).
* **Carrier Docking Integration**:
  * Allow the player and autonomous ships from **Plan A (`PlayerFleet`)** to dock inside a player-owned Fleet Carrier in orbit, transfer cargo/modules, and jump together with the carrier across deep space.

### Phase H2: Modular Station Construction & Frontier Colonization

* **Construction Plots & Claim Beacons**:
  * Deployable orbital (`TYPE_STARPORT_ORBITAL`) or planetary surface (`TYPE_STARPORT_SURFACE`) construction plot claims in frontier or uninhabited systems (subject to faction permitting in core space).
* **Construction Logistics**:
  * Deploy a hired or player-owned **Construction Vessel** alongside a blueprint manifest specifying required structural commodities (Steel Alloys, Industrial Machinery, Fusion Reactors, Habitat Composites, Electronics).
  * Autonomous freighters assigned from **Plan A** (and optional NPC haulers contracted by price) automatically ferry construction materials until each module finishes assembly.
* **Modular Facility Expansion**:
  * Dockable Core Hub & Landing Pads (Small/Medium/Large/Capital collars)
  * **Ore Refinery**: Converts ring-mined minerals & ices (Plan 03 & Plan A) into refined metals, hydrogen fuel, and reactor isotopes.
  * **Industrial Factory / Shipyard**: Fabricates ship modules, munitions, drones, and eventually player-built hulls.
  * **Habitat Ring & Hydroponics**: Supplies workforce population and agricultural goods.
  * **Defense Platform**: Automated heavy laser/railgun turrets and patrol drone bays for station security.

### Phase H3: Closed-Loop Supply Chains & NPC Station Managers

* **Station Manager Role (`Character`)**:
  * Assign an NPC Station Manager to each player-owned station with an operating budget, automated buy/sell pricing thresholds, and subordinate miner/trader ships (extending **Plan A** fleet orders with `HOME_BASE = stationUid`).
* **Production Economy Simulation**:
  * Background real-time production ticks (aligned with Pioneer's 1:1 clock and OOS simulation) consuming raw inputs, paying workforce upkeep, filling storage modules, and trading surpluses with AI megacorps and passing trade ships (`TradeShips`).

### Phase H4: Sector Sovereignty, Fleet Task Forces & Strategic Map Command

* **RTS-Style Map Command Layer**:
  * Extend `SystemView` and `SectorView` with a **Tactical Fleet Overlay** allowing selection and drag/group assignment of entire Fleet Task Forces (Carrier + Destroyer escorts + Fighter wings).
* **Territorial Control & Dynamic Defense**:
  * Constructing Administration / Defense Modules in uninhabited systems establishes player/faction outpost control, generating local traffic, bulletin board contracts, and dynamic defense scenarios against pirate syndicates, rival megacorp raids, and *Hydrazine Swarm* / *Archon Automata* incursions (**Plan G**).

---

## 3. Dependencies

* **Plan A** (*Multi-Ship Ownership, Station Hangars & Crew Autonomy*): Required for `PlayerFleet`, NPC Captains, autonomous miners/traders, and OOS simulation.
* **Plan 03** (*Volumetric Planetary Rings & Mining*): Raw resource supply chain source.
* **Plan F** (*Aerospace Manufacturers & Modular Slots*): Class 1–4 weapon mount and turret infrastructure.
* **Plan G** (*Deep Exploration, Wing Missions & Alien Civilizations*): Endgame threat escalation and deep-space expansion targets.

---

## 4. Verification Plan

1. Spawn and pilot a multi-turret Corvette/Carrier prototype; verify independent turret tracking modes (`POINT_DEFENSE`, `ATTACK_TARGET`, `HOLD_FIRE`) and wingman docking on the Fleet Carrier.
2. Claim an orbital construction site in an uninhabited system, assign a Plan A freighter to deliver required commodities, and verify live construction completion into a persistent dockable `SpaceStation`.
3. Assign a Station Manager + Ore Refinery + Plan A autonomous miner, verify raw ore converts into refined commodities both in-system and out-of-system, and verify full save/load persistence and `./build/unittest` (`0` failures).

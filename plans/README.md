# Pioneer: Expanse — Project Plans & Roadmaps Index

This directory centralizes all implementation plans, technical designs, and strategic roadmaps for the **Pioneer: Expanse** single-player space simulation project.

---

## Core Roadmaps & Completed Foundation Plans (`01`–`04`)

| File | Title | Description | Status |
| :--- | :--- | :--- | :--- |
| **[`01_EXPANSE_LONG_TERM_ROADMAP.md`](./01_EXPANSE_LONG_TERM_ROADMAP.md)** | **Expanse Long-Term Master Roadmap & Priority Index** | Executive charter, architecture dependency graph, and sequenced priority matrix linking Core Plans `02`–`04` and Pillar Plans `A`–`J`. | **Master Index** |
| **[`02_PIONEER_EXPANSE_FOUNDATION_PLAN.md`](./02_PIONEER_EXPANSE_FOUNDATION_PLAN.md)** | **Core Foundation Implementation Plan** | Groundwork and foundational milestones (Phases 1–8: Native build, 1080p UI, Allegiance starts, Cross-System Target Memory, Macro Galactic Map, FSD Supercruise, Real-Time Economy, Crises, InterCast, ISX, Lottery, Taxes, Penal & SAR Rebuy). | **Completed** |
| **[`03_VOLUMETRIC_RINGS_AND_MINING_PLAN.md`](./03_VOLUMETRIC_RINGS_AND_MINING_PLAN.md)** | **Volumetric Planetary Rings & Asteroid Mining** | Planetary ring lifecycle: astrophysical frost-line/Roche generation, self-shadowing shaders, close-range 2D fade-out, Supercruise planar drops, 3-tier LOD 3D asteroid field (`RingField`), physical collisions, and laser mining. | **Completed** |
| **[`04_NPC_SUPERCRUISE_INTERDICTION_PLAN.md`](./04_NPC_SUPERCRUISE_INTERDICTION_PLAN.md)** | **NPC Supercruise & Interdiction Plan** | Universal NPC Supercruise traffic, station occlusion, active patrol/pirate spawns, FSD interdictor tug-of-war mechanics, NPC evasion steering, low-wake drops, and security-scaled interdiction pacing. | **Completed** |

---

## Lettered Expansion Pillar Plans (`A`–`J`)

| File | Pillar | Scope & Key Systems | Priority | Status |
| :--- | :--- | :--- | :--- | :--- |
| **[`A_PLAN_MULTI_SHIP_AND_CREW_AUTONOMY.md`](./A_PLAN_MULTI_SHIP_AND_CREW_AUTONOMY.md)** | **Plan A** | Multi-ship ownership & hangars, ship swap, cargo/module transfer, Resident Station Storage Vaults (500t/50 modules), NPC Captains & 5 skills/payroll, `FOLLOW`/`DOCK`/`AUTO_TRADE` Cr/hr/`AUTO_MINE`/`PATROL`/piracy, mission delegation & IS/OOS sim. | **Shipped** | **Completed** |
| **[`I_PLAN_TRANSPONDER_AND_STEALTH.md`](./I_PLAN_TRANSPONDER_AND_STEALTH.md)** | **Plan I** | Transponder on/off switch, dark running `<1c`, persistent locks, police witness FOV + occlusion, per-faction bounty licences, Warrant Scanner, sub-light sensors & smugglers. | **Shipped** | **Completed** |
| **[`E_PLAN_GRAPHICS_AUDIO_OVERHAUL.md`](./E_PLAN_GRAPHICS_AUDIO_OVERHAUL.md)** | **Plan E** | **Completed (M1–6)**: Enhanced Graphics toggle, PBR, terrain-occluded flares, plumes, gas giants, dual clouds, ocean waves, chemistry/weather Rayleigh/Mie, dwarf planets, 20m tri-planar terrain, 3D weather/lightning, ship lights & 4-tier chimes. **Next Up**: **M7** (situational hull/weather audio, OpenAL vacuum low-pass, Cockpit AI voice). **Asset-Gated**: **M8** (3D cockpits). | **Next Up** | **In Progress (M7 Next Up)** |
| **[`J_PLAN_MILITARY_FRONTLINE_AND_DEPUTY.md`](./J_PLAN_MILITARY_FRONTLINE_AND_DEPUTY.md)** | **Plan J** | Military enlistment, non-combat frontline support (blockade running, supply convoys, evacuations, recon, Plan A fleet support), optional combat zones, and high-standing **Faction Deputy Charter**. | **P3** | **Queued (Design Discussion)** |
| **[`C_PLAN_ENGINEERING_CRAFTING.md`](./C_PLAN_ENGINEERING_CRAFTING.md)** | **Plan C** | Zero-mass raw/manufactured/encoded `MaterialsInventory`, Scrap Reclamation, in-field matter synthesis (FSD boosts, O2, ammo), and deterministic G1–G5 Engineers with Experimental overrides. | **P4** | **Queued (Design Discussion)** |
| **[`F_PLAN_FLEET_MANUFACTURERS.md`](./F_PLAN_FLEET_MANUFACTURERS.md)** | **Plan F** | **Completed**: 6 aerospace franchise dealerships (`corp_*.svg`) & 8 station profiles. **Queued**: Modular slot cleanup, Fixed/Gimballed/Turreted weapons, deployable hardpoints & countermeasures *(no `SYS/ENG/WEP` pips)*; **Asset-Gated**: `.gltf` fleet. | **P5** | **Partially Done (Combat/Slots Queued)** |
| **[`G_PLAN_EXPLORATION_ALIENS.md`](./G_PLAN_EXPLORATION_ALIENS.md)** | **Plan G** | **Completed**: Universal Cartographics, Discovery Scanner & Scan Manager. **Queued**: Waveform FSS scanner, orbital DSS probes (POIs & ring hotspots), VIP liners & burning-station evacs; **Asset-Gated**: Alien fleets. | **P6** | **Partially Done (FSS/DSS/Evacs Queued)** |
| **[`B_PLAN_SRV_SURFACE_OPERATIONS.md`](./B_PLAN_SRV_SURFACE_OPERATIONS.md)** | **Plan B** | `GroundVehicle` raycast suspension, amphibious waterjet mode, SRV bay deploy/dismissal (`> 2.5 km`)/recall (`< 500 m`), surface boulder scatter & acoustic-spectral waterfall scanner. | **Asset-Gated** | **Ready for Assets (SRV Model)** |
| **[`D_PLAN_HACKING_INFILTRATION.md`](./D_PLAN_HACKING_INFILTRATION.md)** | **Plan D** | Line-of-sight `DatalinkScanner`, two-phase waveform/node-routing frequency-bypass puzzle, non-dockable orbital `Megaship` complexes, and settlement trespass escalation + Skimmer drones. | **Queued / Assets** | **Queued** |
| **[`H_PLAN_CAPITAL_SHIPS_AND_EMPIRE_BUILDING.md`](./H_PLAN_CAPITAL_SHIPS_AND_EMPIRE_BUILDING.md)** | **Plan H** | Capital ships & mobile Fleet Carriers, multi-turret fire control, modular player station construction, NPC Station Managers, closed-loop production chains & sector sovereignty. | **Endgame** | **Queued (Endgame)** |

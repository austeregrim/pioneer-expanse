# Pioneer: Expanse — Project Plans & Roadmaps Index

This directory centralizes all implementation plans, technical designs, and strategic roadmaps for the **Pioneer: Expanse** single-player space simulation project.

---

## Core Roadmaps & Completed Foundation Plans (`01`–`04`)

| File | Title | Description | Status |
| :--- | :--- | :--- | :--- |
| **[`01_EXPANSE_LONG_TERM_ROADMAP.md`](./01_EXPANSE_LONG_TERM_ROADMAP.md)** | **Expanse Long-Term Master Roadmap & Priority Index** | Executive charter, architecture dependency graph, and sequenced priority matrix linking Pillar Plans `A`–`H` and Core Plans `02`–`04`. | **Master Index** |
| **[`02_PIONEER_EXPANSE_FOUNDATION_PLAN.md`](./02_PIONEER_EXPANSE_FOUNDATION_PLAN.md)** | **Core Foundation Implementation Plan** | Groundwork and foundational milestones (Phases 1–8: Native Linux build, 1080p UI tightening, Allegiance starts, Macro Galactic Map, FSD Supercruise, Real-Time Clock, Dynamic Galaxy Crises, InterCast News, and Escape Pod Insurance Rebuy). | **Phases 1–5, 7–8 Completed; Phase 6 Queued** |
| **[`03_VOLUMETRIC_RINGS_AND_MINING_PLAN.md`](./03_VOLUMETRIC_RINGS_AND_MINING_PLAN.md)** | **Volumetric Planetary Rings & Asteroid Mining** | Planetary ring lifecycle: astrophysical frost-line/Roche generation, self-shadowing shaders, close-range 2D fade-out, Supercruise planar drops, 3-tier LOD 3D asteroid field (`RingField`), physical collisions, and laser mining. | **Completed** |
| **[`04_NPC_SUPERCRUISE_INTERDICTION_PLAN.md`](./04_NPC_SUPERCRUISE_INTERDICTION_PLAN.md)** | **NPC Supercruise & Interdiction Plan** | Universal NPC Supercruise traffic, station occlusion, active patrol/pirate spawns, FSD interdictor tug-of-war mechanics, NPC evasion steering, low-wake drops, and security-scaled interdiction pacing. | **Completed** |

---

## Lettered Expansion Pillar Plans (`A`–`H`)

| File | Pillar | Scope & Key Systems | Priority | Status |
| :--- | :--- | :--- | :--- | :--- |
| **[`A_PLAN_MULTI_SHIP_AND_CREW_AUTONOMY.md`](./A_PLAN_MULTI_SHIP_AND_CREW_AUTONOMY.md)** | **Plan A** | Multi-ship ownership & station hangar storage, ship swapping, NPC Captains & skill progression, autonomous Wingman/Auto-Trade/Auto-Mine/Patrol orders, mission delegation & IS/OOS simulation *(zero new 3D assets)*. | **Next Up** | **Ready to Plan** |
| **[`B_PLAN_SRV_SURFACE_OPERATIONS.md`](./B_PLAN_SRV_SURFACE_OPERATIONS.md)** | **Plan B** | `GroundVehicle` raycast suspension, amphibious waterjet mode, SRV bay deploy/dismissal (`> 2.5 km`)/recall (`< 500 m`), surface boulder scatter & acoustic-spectral waterfall scanner. | **P2** | **Ready for Assets (SRV Model)** |
| **[`C_PLAN_ENGINEERING_CRAFTING.md`](./C_PLAN_ENGINEERING_CRAFTING.md)** | **Plan C** | Zero-mass raw/manufactured/encoded `MaterialsInventory`, Scrap Reclamation, in-field matter synthesis (FSD injections, O2, ammo), and deterministic G1–G5 Engineers with Experimental overrides. | **P4** | **Queued** |
| **[`D_PLAN_HACKING_INFILTRATION.md`](./D_PLAN_HACKING_INFILTRATION.md)** | **Plan D** | Line-of-sight `DatalinkScanner`, two-phase waveform/node-routing frequency-bypass puzzle, non-dockable orbital `Megaship` complexes, and settlement trespass escalation + Skimmer drones. | **P5** | **Queued** |
| **[`E_PLAN_GRAPHICS_AUDIO_OVERHAUL.md`](./E_PLAN_GRAPHICS_AUDIO_OVERHAUL.md)** | **Plan E** | PBR multi-splat GeoSphere terrain shaders, Rayleigh & Mie atmospheric scattering, canopy glass scratch/glare/frost shader (`< 20%` heat), OpenAL vacuum low-pass acoustics & Cockpit AI Voice. | **P3** | **Queued** |
| **[`F_PLAN_FLEET_MANUFACTURERS.md`](./F_PLAN_FLEET_MANUFACTURERS.md)** | **Plan F** | Four aerospace megacorps (*Sol-Dynamics*, *Aethelgard*, *Guan-Haber*, *Frontier Voidcraft*), 4-tier modular slot refactor, Fixed/Gimballed/Turreted Class 1–4 mounts & `.gltf`/`.glb` fleet pipeline. | **P3** | **Queued** |
| **[`G_PLAN_EXPLORATION_ALIENS.md`](./G_PLAN_EXPLORATION_ALIENS.md)** | **Plan G** | Waveform FSS scanner, gravity-curving orbital DSS probes (POIs & ring hotspots), wing escorts, VIP/refugee liners, and the *Hydrazine Swarm* + *Archon Automata* alien fleets. | **P6** | **Queued** |
| **[`H_PLAN_CAPITAL_SHIPS_AND_EMPIRE_BUILDING.md`](./H_PLAN_CAPITAL_SHIPS_AND_EMPIRE_BUILDING.md)** | **Plan H** | Capital ships & mobile Fleet Carriers, multi-turret fire control, modular player station construction, NPC Station Managers, closed-loop production chains & sector sovereignty. | **P7 (Endgame)** | **Queued** |

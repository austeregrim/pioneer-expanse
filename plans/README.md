# Pioneer: Expanse — Project Plans & Roadmaps Index

This directory centralizes all implementation plans, technical designs, and strategic roadmaps for the **Pioneer: Expanse** single-player space simulation project.

---

## Core Roadmaps & Active System Plans

| File | Title | Description | Status |
| :--- | :--- | :--- | :--- |
| **[`01_EXPANSE_LONG_TERM_ROADMAP.md`](./01_EXPANSE_LONG_TERM_ROADMAP.md)** | **Expanse Long-Term Master Roadmap & Priority Index** | Executive charter, architecture dependency graph, and sequenced priority matrix linking standalone Pillar Plans `05`–`10` and Core Plans `02`–`04`. | **Master Index** |
| **[`02_PIONEER_EXPANSE_FOUNDATION_PLAN.md`](./02_PIONEER_EXPANSE_FOUNDATION_PLAN.md)** | **Core Foundation Implementation Plan** | Groundwork and foundational milestones (Phases 1–8: Native Linux build, 1080p UI tightening, Allegiance starts, Macro Galactic Map, FSD Supercruise, Real-Time Clock, Dynamic Galaxy Crises, InterCast News, and Escape Pod Insurance Rebuy). | **Phases 1–5, 7–8 Completed; Phase 6 Queued** |
| **[`03_VOLUMETRIC_RINGS_AND_MINING_PLAN.md`](./03_VOLUMETRIC_RINGS_AND_MINING_PLAN.md)** | **Volumetric Planetary Rings & Asteroid Mining** | Detailed technical specification for the planetary ring lifecycle: astrophysical frost-line/Roche generation, self-shadowing shaders, Supercruise planar ring drops, 3-tier LOD asteroid field (`RingField`), physical collisions, and mining mechanics. | **Ready for Implementation** |
| **[`04_NPC_SUPERCRUISE_INTERDICTION_PLAN.md`](./04_NPC_SUPERCRUISE_INTERDICTION_PLAN.md)** | **NPC Supercruise & Interdiction Plan** | Architectural blueprint for universal NPC Supercruise traffic, station occlusion, active rear-cone patrol/pirate spawns, FSD interdictor tug-of-war mechanics, low-wake drops, and post-interdiction flight rules. | **Completed (Phase 7)** |

---

## Standalone Pillar Technical Plans (`05`–`10`)

| File | Pillar | Scope & Key Systems | Suggested Priority | Status |
| :--- | :--- | :--- | :--- | :--- |
| **[`05_PLAN_SRV_SURFACE_OPERATIONS.md`](./05_PLAN_SRV_SURFACE_OPERATIONS.md)** | **Pillar 1** | `GroundVehicle` raycast suspension, amphibious waterjet mode, SRV bay deploy/dismissal (`> 2.5 km`)/recall (`< 500 m`), surface boulder scatter & acoustic-spectral waterfall scanner. | **P3** | **Ready to Plan** |
| **[`06_PLAN_ENGINEERING_CRAFTING.md`](./06_PLAN_ENGINEERING_CRAFTING.md)** | **Pillar 2** | Zero-mass raw/manufactured/encoded `MaterialsInventory`, Scrap Reclamation, in-field matter synthesis (FSD injections, O2, ammo), and deterministic G1–G5 Engineers with Experimental overrides. | **P4** | **Queued** |
| **[`07_PLAN_HACKING_INFILTRATION.md`](./07_PLAN_HACKING_INFILTRATION.md)** | **Pillar 3** | Line-of-sight `DatalinkScanner`, two-phase waveform/node-routing frequency-bypass puzzle, non-dockable orbital `Megaship` complexes, and settlement trespass escalation + Skimmer drones. | **P5** | **Queued** |
| **[`08_PLAN_GRAPHICS_AUDIO_OVERHAUL.md`](./08_PLAN_GRAPHICS_AUDIO_OVERHAUL.md)** | **Pillar 4** | PBR multi-splat GeoSphere terrain shaders, Rayleigh & Mie atmospheric scattering, canopy glass scratch/glare/frost shader (`< 20%` heat), OpenAL vacuum low-pass acoustics & Cockpit AI Voice. | **P2** | **Queued** |
| **[`09_PLAN_FLEET_MANUFACTURERS.md`](./09_PLAN_FLEET_MANUFACTURERS.md)** | **Pillar 5** | Four aerospace megacorps (*Sol-Dynamics*, *Aethelgard*, *Guan-Haber*, *Frontier Voidcraft*), 4-tier modular slot refactor, Fixed/Gimballed/Turreted Class 1–4 mounts & `.gltf`/`.glb` fleet pipeline. | **P1** | **Queued** |
| **[`10_PLAN_EXPLORATION_ALIENS.md`](./10_PLAN_EXPLORATION_ALIENS.md)** | **Pillar 6** | Waveform FSS scanner, gravity-curving orbital DSS probes (POIs & ring hotspots), wing escorts, VIP/refugee liners, and the *Hydrazine Swarm* + *Archon Automata* alien fleets. | **P6** | **Queued** |

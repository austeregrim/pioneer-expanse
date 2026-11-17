# Contributing

Contributions are welcome!
Portions of this text was written with AI.

## Asset & Contribution Needs: 3D Models, Audio & Rigging Specifications

To bring the remaining roadmap to life, **Pioneer: Expanse welcomes contributions of 3D models, audio soundscapes, and original music**. Because the game runs on a custom C++/OpenGL engine with strict physical simulation, please review the requirements below.

### 1. 3D Models Needed

* **Surface Reconnaissance Vehicles (SRVs)**:
  * Rugged multi-wheel (6x6 or 4x4) planetary rovers.
  * Articulated suspension geometry with clearance for ground deployment from starship cargo ramps.
  * Top-mounted 360-degree dual plasma repeater turret and vernier thruster nozzle locations.
* **New Starships across Manufacturer Lines**:
  * Light interceptors, multi-role couriers, heavy industrial mining barges, long-range exploration cruisers, and capital warships.
* **Orbital Structures & Surface Props**:
  * Non-dockable industrial Megaships, orbital defense relays, surface skimmer drones, and mineral outcrop surface boulders.

### 2. Audio, Sound Design & Music Contributions

* **Original Music**:
  * Ambient deep-space exploration suites and quiet planetary surface tracks.
  * Dynamic, escalating combat tracks for dogfights, capital ship skirmishes, and pirate interdictions.
  * Distinctive starport dock atmosphere and trade lounge themes.
* **Sound Effects (SFX) & Voice**:
  * Frame Shift Drive charging sweeps, witch-space sub-bass thrum, and drop-in boom signatures.
  * Vacuum-filtered low-pass engine and thruster acoustic profiles.
  * Impact rumbles, shield deflection crackles, and mining laser resonance hums.
  * Voice advisory packs (clear, synthesized procedural or voiced callouts for cockpit alerts).

### 3. Guidelines for Generative AI Models (Style & Brand Consistency)

If 3D assets or texture concepts are generated or assisted by AI models, **they must adhere to the consistent visual identity and engineering philosophy of the in-universe aerospace brands**:

* **Sol-Dynamics Aerospace (SDA)** *(Solar Federation)*:
  * **Aesthetic**: Brutalist, angular, faceted composite armor plating, exposed heavy radiator ribs, reinforced dorsal spines.
  * **Role & Palette**: High-durability military dropships, patrol craft; gunmetal gray, matte olive, and hazard amber markings.
* **Aethelgard Starworks** *(Commonwealth)*:
  * **Aesthetic**: Swept aerodynamic curves, sleek organic silhouettes, pristine continuous surfaces, flowing nacelles, and panoramic tinted glass canopies.
  * **Role & Palette**: VIP passenger liners, luxury couriers, high-speed blockade interceptors; pearlescent white, royal navy, and gold trim.
* **Guan-Haber Industrial Heavyworks** *(Haber Corporation)*:
  * **Aesthetic**: Industrial exposed box-truss lattices, raw tungsten-steel plating, twin external cargo booms, external piping, and massive hydraulic clamps.
  * **Role & Palette**: Deep-core asteroid haulers, mobile refineries, heavy industrial transports; weathered steel, safety yellow, and hazard chevron striping.
* **Frontier Voidcraft Cooperative** *(Independent / Rim Worlds)*:
  * **Aesthetic**: Rugged, asymmetric hulls, kit-bashed retrofits, external fuel pods, exposed wiring looms, and functional forward cockpits.
  * **Role & Palette**: Long-range expedition vessels, rugged scout ships, multi-role mercenary hulls; oxidized red-orange, weathered primer, and field-repaired patches.

### 4. Engine Rigging & Technical Asset Pipeline

Models are loaded via Assimp into Pioneer's scene graph. Assets should be exported in **`.gltf` / `.glb`** (preferred) or **Collada (`.dae`)** accompanied by an engine definition file (`.model`).

#### Required Rigging Nodes & Locators (`tag_*`)
To integrate properly into flight physics, camera views, and combat systems, models must include specific dummy/locator nodes (empty nodes or bones):

* **Landing Reference**:
  * `tag_landing`: Defines the exact ground-contact plane and vertical offset when landing gear is deployed. Essential for planetary touchdown without sinking or floating.
* **Weapon Mounts**:
  * `tag_gun_0`, `tag_gun_1`, ...: Weapon hardpoint mounting anchors and projectile ejection origins (facing along local `+Z` or forward vector).
  * `tag_gunmount_0`, ...: Turret or gimbal rotation pivot anchor.
* **Cameras**:
  * `tag_camera`: Cockpit first-person eye anchor.
  * `tag_camera_front`, `tag_camera_rear`, `tag_camera_left`, `tag_camera_right`, `tag_camera_top`, `tag_camera_bottom`: Exterior hull chase and orbital camera anchors.
* **Thrusters & Visual Effects**:
  * `thruster_<direction>_<idx>` (e.g., `thruster_linear_fwd_0`, `thruster_linear_rev_0`, `thruster_up_0`): Origin point and exhaust orientation for engine plumes and RCS verniers.
  * `navlight_<color>_<idx>` (e.g., `navlight_red_0`, `navlight_green_0`, `navlight_white_0`): Position markers for synchronized blinking/strobe beacons.
* **Dynamic Decals & Labels**:
  * `label_<idx>`: Flat polygon quads reserved for dynamic vector-rendered ship names and registration serials.
  * `decal_01` .. `decal_04`: Mesh zones for corporate logos and faction crests.

#### Collision Geometry (`collision_*`)
* Never use high-poly render meshes for physics!
* Include simplified, convex hull geometry named `collision_<name>` (or a dynamic collision mesh named `collision_d<name>`), or supply a dedicated low-poly collision file (e.g. `ship_coll.dae` referenced by `collision "ship_coll.dae"` in `.model`).

#### Animation Rigging
* **Landing Gear**: Defined in the `.model` file via frame ranges (e.g. `anim "gear_down" 1 100`) animating gear doors, hydraulic struts, and wheel locks.
* **Weapon Bays / Hardpoint Doors**: Bones named `hardpoint_<idx>_door` that open during weapon deployment before weapons can fire.
* **SRV Wheel Suspension**: Hierarchical steering nodes (`wheel_steer_FL`, `wheel_steer_FR`) and strut compression transforms along local `+Y`.

---

## Upstream Relationship & Independent Fork Policy

Upstream Pioneer (`pioneerspacesim/pioneer`) maintains an official policy against accepting AI-assisted or AI-generated contributions into its upstream codebase. 

Consequently, **Pioneer: Expanse is developed and maintained strictly as an independent standalone fork**. We do not submit pull requests, patches, or issues back to upstream Pioneer. This boundary respects upstream's preferences while allowing Pioneer: Expanse to freely explore modern human-AI software engineering methodologies.

---

The following text assumes you're about to submit a new pull request.

### Check before submitting

- If new to github, make sure you're not opening this pull request from your _master_ branch, but rather a new separate branch.
- Have you reviewed your code? Don't trust the developers to do it, as they don't have time to read your code.
- Do you foresee any potential pitfalls or issues? If so please mention them.
- If a new feature, then please describe it, possibly with screenshot if something graphical.
- If a bug fix, then please use key phrases so that the original issue will be auto-closed upon merge. E.g.:

```
    fix #1234
    fixes #1234
    close #1234
    closes #1234
    resolve #1234
    resolves #1234
```


### Consider after submitting
After a pull request has been submitted, it is more common than not, that the branch keeps being modified, as bugs or issues are raised. If the change is to the latest commit on the branch, use `git add`, followed by `git commit --amend`, followed by a forced push, `git push -f`, to keep commit history clean.


Thanks for your contribution!

// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#pragma once

#include "Aabb.h"
#include "vector3.h"

#include <string>
#include <vector>

namespace Subsystems {

	struct SubsystemNode {
		std::string id;       // e.g. "thrusters", "hyperdrive", "shields", "weapon:weapon_s2_1", "sensors"
		std::string name;     // Display label, e.g. "Thrusters", "2MW Pulse Cannon"
		std::string slotId;   // EquipSet slot ID (or empty for synthetic fallback)
		std::string category; // "thrusters", "hyperdrive", "shields", "weapon", "sensors", "utility"
		vector3d localPos = vector3d::Zero;
		float radius = 1.0f;
		float integrity = 1.0f; // 0.0..1.0
		bool disabled = false;  // true when integrity <= 0.001f
	};

	struct HitResult {
		int index = -1;
		float proximityFactor = 0.0f;
	};

	// Computes deterministic ship-local hit-zone center & radius from hull AABB for a subsystem category.
	void ComputeDefaultZoneForCategory(const std::string &category, const Aabb &aabb, vector3d &outPos, float &outRadius);

	// Maps a ship-local collision position onto the closest intersecting subsystem node (or -1 for bare hull).
	HitResult ResolveHit(const std::vector<SubsystemNode> &nodes, const vector3d &localHitPos);

	// Computes normalized integrity loss [0..1] for a subsystem struck by penetrating hull damage (in tonnes).
	float CalcSubsystemDamage(float penetratingTons, float hullMassTons, float proximityFactor);

	// Converts component integrity [0..1] into functional performance multiplier [0..1].
	// Above 75% integrity there is zero performance penalty; below 75% efficiency tapers cleanly down to 35% before hitting 0% at 0% integrity.
	float CalcPerformanceMultiplier(float integrity);

} // namespace Subsystems

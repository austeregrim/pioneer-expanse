// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "Subsystems.h"
#include "MathUtil.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace Subsystems {

	void ComputeDefaultZoneForCategory(const std::string &category, const Aabb &aabb, vector3d &outPos, float &outRadius)
	{
		vector3d bmin = aabb.min;
		vector3d bmax = aabb.max;
		if (bmin.x > bmax.x || bmin.y > bmax.y || bmin.z > bmax.z) {
			bmin = vector3d(-5.0, -3.0, -8.0);
			bmax = vector3d(5.0, 3.0, 8.0);
		}

		const vector3d center = (bmin + bmax) * 0.5;
		const vector3d half(
			std::max(1.5, (bmax.x - bmin.x) * 0.5),
			std::max(1.5, (bmax.y - bmin.y) * 0.5),
			std::max(1.5, (bmax.z - bmin.z) * 0.5));

		const double length = 2.0 * half.z;
		const double minorHalf = std::min(half.x, half.y);

		if (category == "thrusters") {
			outPos = center + vector3d(0.0, 0.0, 0.72 * half.z);
			outRadius = float(std::max(0.32 * length, 0.45 * minorHalf));
		} else if (category == "hyperdrive") {
			outPos = center + vector3d(0.0, 0.22 * half.y, 0.32 * half.z);
			outRadius = float(std::max(0.24 * length, 0.38 * minorHalf));
		} else if (category == "shields") {
			outPos = center + vector3d(0.0, 0.55 * half.y, -0.05 * half.z);
			outRadius = float(std::max(0.22 * length, 0.35 * minorHalf));
		} else if (category == "sensors") {
			outPos = center + vector3d(0.0, 0.28 * half.y, -0.62 * half.z);
			outRadius = float(std::max(0.20 * length, 0.32 * minorHalf));
		} else if (category == "weapon") {
			outPos = center + vector3d(0.0, 0.0, -0.55 * half.z);
			outRadius = float(std::max(0.18 * length, 0.28 * minorHalf));
		} else {
			outPos = center + vector3d(0.0, -0.45 * half.y, 0.0);
			outRadius = float(std::max(0.20 * length, 0.30 * minorHalf));
		}
	}

	HitResult ResolveHit(const std::vector<SubsystemNode> &nodes, const vector3d &localHitPos)
	{
		if (nodes.empty())
			return HitResult {};

		constexpr float kMaxHitNormDist = 1.35f;
		constexpr float kTieMargin = 0.15f;

		float bestNormDist = std::numeric_limits<float>::max();
		for (const auto &node : nodes) {
			const float r = std::max(node.radius, 0.5f);
			const float normDist = float((localHitPos - node.localPos).Length()) / r;
			if (normDist < bestNormDist)
				bestNormDist = normDist;
		}

		if (bestNormDist > kMaxHitNormDist)
			return HitResult {};

		int chosenIdx = -1;
		float chosenNormDist = bestNormDist;
		bool chosenActive = false;

		for (size_t i = 0; i < nodes.size(); ++i) {
			const auto &node = nodes[i];
			const float r = std::max(node.radius, 0.5f);
			const float normDist = float((localHitPos - node.localPos).Length()) / r;
			if (normDist > kMaxHitNormDist || normDist > bestNormDist + kTieMargin)
				continue;

			const bool isActive = !node.disabled && node.integrity > 0.001f;
			if (chosenIdx < 0 ||
				(isActive && !chosenActive) ||
				(isActive == chosenActive && normDist < chosenNormDist)) {
				chosenIdx = int(i);
				chosenNormDist = normDist;
				chosenActive = isActive;
			}
		}

		if (chosenIdx < 0)
			return HitResult {};

		const float proximityFactor = Clamp(1.15f - 0.50f * chosenNormDist, 0.45f, 1.0f);
		return HitResult { chosenIdx, proximityFactor };
	}

	float CalcSubsystemDamage(float penetratingTons, float hullMassTons, float proximityFactor)
	{
		if (penetratingTons <= 0.0f || hullMassTons <= 0.0f || proximityFactor <= 0.0f)
			return 0.0f;

		const float hullFrac = penetratingTons / hullMassTons;
		const float raw = hullFrac * 2.8f * proximityFactor;
		const float perHitCap = std::max(0.65f, hullFrac * 1.4f);
		return Clamp(std::min(raw, perHitCap), 0.0f, 1.0f);
	}

	float CalcPerformanceMultiplier(float integrity)
	{
		if (integrity <= 0.001f)
			return 0.0f;
		if (integrity >= 0.75f)
			return 1.0f;
		const float t = Clamp((integrity - 0.01f) / 0.74f, 0.0f, 1.0f);
		return 0.35f + 0.65f * t;
	}

} // namespace Subsystems

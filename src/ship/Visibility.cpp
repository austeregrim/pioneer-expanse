// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "ship/Visibility.h"

#include <algorithm>
#include <cmath>

namespace Visibility {

	void TransponderState::Set(bool on)
	{
		if (!on) {
			requested = false;
			active = false;
			warmupRemaining = 0.0f;
			return;
		}
		if (active) {
			requested = true;
			warmupRemaining = 0.0f;
			return;
		}
		if (!requested) {
			requested = true;
			warmupRemaining = WARMUP_TIME;
		}
	}

	bool TransponderState::Toggle()
	{
		Set(!requested);
		return requested;
	}

	void TransponderState::Update(float dt)
	{
		if (dt <= 0.0f)
			return;
		if (requested && !active) {
			warmupRemaining = std::max(0.0f, warmupRemaining - dt);
			if (warmupRemaining <= 0.0f) {
				active = true;
				warmupRemaining = 0.0f;
			}
		} else if (!requested) {
			active = false;
			warmupRemaining = 0.0f;
		}
	}

	bool SegmentIntersectsSphere(const vector3d &from, const vector3d &to, const vector3d &center, double radius)
	{
		if (radius <= 0.0)
			return false;

		const vector3d seg = to - from;
		const double segLenSq = seg.LengthSqr();
		if (segLenSq <= 1e-6)
			return false;

		const double rSq = radius * radius;
		// Do not self-occlude if either endpoint lies on or inside the occluder sphere.
		if ((from - center).LengthSqr() <= rSq || (to - center).LengthSqr() <= rSq)
			return false;

		const double t = std::clamp((center - from).Dot(seg) / segLenSq, 0.0, 1.0);
		if (t <= 0.0 || t >= 1.0)
			return false;

		const vector3d closest = from + seg * t;
		return (closest - center).LengthSqr() < rSq;
	}

	bool IsOccluded(const vector3d &from, const vector3d &to, const std::vector<OccluderVolume> &occluders)
	{
		for (const OccluderVolume &occ : occluders) {
			if (SegmentIntersectsSphere(from, to, occ.center, occ.radius))
				return true;
		}
		return false;
	}

	bool IsWithinFieldOfView(const vector3d &observerForwardUnit, const vector3d &toTarget, double halfAngleDeg)
	{
		const double distSq = toTarget.LengthSqr();
		if (distSq <= 1e-12)
			return true;
		const vector3d dir = toTarget / std::sqrt(distSq);
		const double clampedHalfDeg = std::clamp(halfAngleDeg, 0.0, 180.0);
		const double cosLimit = std::cos(clampedHalfDeg * (M_PI / 180.0));
		return observerForwardUnit.Dot(dir) >= cosLimit;
	}

	double GetDarkSensorRangeForLevel(int level)
	{
		switch (level) {
		case 1: return 15000.0;  // 15 km
		case 2: return 45000.0;  // 45 km
		case 3: return 120000.0; // 120 km
		default: return (level > 3) ? 120000.0 : 0.0;
		}
	}

	double GetBaseRadarRangeForLevel(int radarCap, int sublightSensorCap)
	{
		if (radarCap <= 0 && sublightSensorCap <= 0)
			return 0.0;
		if (sublightSensorCap >= 3)
			return 300000.0; // 300 km
		if (sublightSensorCap == 2)
			return 150000.0; // 150 km
		if (sublightSensorCap == 1)
			return 80000.0;  // 80 km
		return 50000.0;      // 50 km nerfed base radar
	}

	bool EvaluateSensorVisibility(const SensorVisibilityParams &p)
	{
		if (!p.targetAlive || !p.targetInSpace || p.targetDocked)
			return false;
		if (p.isOccluded)
			return false;
		// Lights >= 1c are visible to every observer with line of sight.
		if (p.targetIsFTL)
			return true;
		// Persistent target locks keep a live marker while line of sight holds.
		if (p.hasExistingLock)
			return true;
		// Transponder-on ships below 1c are targetable by anyone with line of sight.
		if (p.targetTransponderActive)
			return true;
		// Dark ships below 1c: 1 km visual hull-ID range (sub-light) or dedicated dark-ship sensor.
		if (!p.targetInSC && !p.observerInSC && p.distance <= HULL_ID_READ_RANGE)
			return true;
		if (p.darkSensorRange > 0.0 && p.distance <= p.darkSensorRange)
			return true;
		return false;
	}

	bool EvaluateLockPersistence(bool targetAlive, bool targetInSpace, bool targetDocked, bool observerDocked, bool isOccluded)
	{
		if (!targetAlive || !targetInSpace || targetDocked || observerDocked)
			return false;
		if (isOccluded)
			return false;
		return true;
	}

	bool EvaluateIdentityReadable(bool targetTransponderActive, bool observerInSC, bool targetInSC, double distance)
	{
		if (targetTransponderActive)
			return true;
		// Visual hull-ID read only works out of supercruise within 1 km.
		if (!observerInSC && !targetInSC && distance <= HULL_ID_READ_RANGE)
			return true;
		return false;
	}

} // namespace Visibility

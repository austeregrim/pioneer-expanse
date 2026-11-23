// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#pragma once

#include "vector3.h"
#include <vector>

class Body;
class Ship;
class Space;

namespace Visibility {

	static constexpr double POLICE_WITNESS_FOV_FULL_ANGLE_DEG = 65.0;
	static constexpr double HULL_ID_READ_RANGE = 1000.0; // 1 km visual hull-ID range (sub-light only)

	// Transponder activation / deactivation state shared by player and NPCs.
	// Turning OFF is instant; turning ON takes <= 1s (0.85s) so pilots can always
	// comply within a 3-5s police warning window.
	struct TransponderState {
		static constexpr float WARMUP_TIME = 0.85f;

		bool requested = true;
		bool active = true;
		float warmupRemaining = 0.0f;

		void Set(bool on);
		bool Toggle();
		void Update(float dt);

		bool IsActive() const { return active; }
		bool IsRequested() const { return requested; }
		bool IsWarmingUp() const { return requested && !active && warmupRemaining > 0.0f; }
		float GetWarmupRemaining() const { return warmupRemaining; }
	};

	// Extensible occluder list so nebulae/clouds/anomalies can be added later.
	enum class OccluderKind {
		Body,
		Anomaly
	};

	struct OccluderVolume {
		vector3d center;
		double radius = 0.0;
		OccluderKind kind = OccluderKind::Body;
	};

	// Returns true if segment [from, to] intersects the interior of the sphere (center, radius).
	// Skips if either endpoint lies inside or on the sphere surface so ships near a body are not self-occluded.
	bool SegmentIntersectsSphere(const vector3d &from, const vector3d &to, const vector3d &center, double radius);

	// Returns true if any occluder blocks the line of sight from `from` to `to`.
	bool IsOccluded(const vector3d &from, const vector3d &to, const std::vector<OccluderVolume> &occluders);

	// Line-of-sight occlusion test in Space over stars and planets/moons.
	bool IsOccludedInSpace(const Space *space, const Body *observer, const Body *target);

	// Forward field-of-view cone test (`halfAngleDeg` is half of the full FOV cone).
	bool IsWithinFieldOfView(const vector3d &observerForwardUnit, const vector3d &toTarget, double halfAngleDeg);

	// Tiered dark-ship sub-light sensor array detection range (meters).
	double GetDarkSensorRangeForLevel(int level);

	// Base and upgraded radar display range for transponder-on sub-1c ships (meters).
	double GetBaseRadarRangeForLevel(int radarCap, int sublightSensorCap);

	struct SensorVisibilityParams {
		bool targetAlive = false;
		bool targetInSpace = false;
		bool targetDocked = false;
		bool targetInSC = false;
		bool targetIsFTL = false;
		bool targetTransponderActive = false;
		bool observerInSC = false;
		bool hasExistingLock = false;
		bool isOccluded = false;
		double distance = 0.0;
		double darkSensorRange = 0.0;
	};

	// Pure visibility rule used by Sensors, HUD targeting, and AI perception identically.
	bool EvaluateSensorVisibility(const SensorVisibilityParams &p);

	// Pure target-lock persistence rule: survives speed/mode/transponder changes;
	// breaks only on death, leaving space, docking, or losing line of sight.
	bool EvaluateLockPersistence(bool targetAlive, bool targetInSpace, bool targetDocked, bool observerDocked, bool isOccluded);

	// Pure ship-ID readability rule: transponder ON at any speed, or sub-light <= 1 km hull read.
	// Never readable above 1c or while in Supercruise when transponder is OFF.
	bool EvaluateIdentityReadable(bool targetTransponderActive, bool observerInSC, bool targetInSC, double distance);

	// Ship-level convenience wrappers
	double GetDarkSensorRange(const Ship *observer);
	double GetRadarDisplayRange(const Ship *observer);
	bool CanReadShipIdentity(const Ship *observer, const Ship *target);
	bool CanWitnessDarkFTL(const Space *space, const Ship *observer, const Ship *target, double fovFullAngleDeg = POLICE_WITNESS_FOV_FULL_ANGLE_DEG);

} // namespace Visibility

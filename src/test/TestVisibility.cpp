// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "doctest.h"
#include "ship/SupercruiseController.h"
#include "ship/Visibility.h"
#include <cmath>
#include <vector>

TEST_CASE("Visibility")
{
	SUBCASE("SegmentIntersectsSphere and IsOccluded")
	{
		const vector3d center(500.0, 0.0, 0.0);
		const double radius = 100.0;

		// Direct hit through planet center
		CHECK(Visibility::SegmentIntersectsSphere(vector3d(0.0, 0.0, 0.0), vector3d(1000.0, 0.0, 0.0), center, radius));
		// Grazing miss outside sphere radius
		CHECK_FALSE(Visibility::SegmentIntersectsSphere(vector3d(0.0, 105.0, 0.0), vector3d(1000.0, 105.0, 0.0), center, radius));
		// Body behind observer
		CHECK_FALSE(Visibility::SegmentIntersectsSphere(vector3d(700.0, 0.0, 0.0), vector3d(1200.0, 0.0, 0.0), center, radius));
		// Body beyond target
		CHECK_FALSE(Visibility::SegmentIntersectsSphere(vector3d(0.0, 0.0, 0.0), vector3d(350.0, 0.0, 0.0), center, radius));
		// Endpoint inside sphere does not self-occlude
		CHECK_FALSE(Visibility::SegmentIntersectsSphere(vector3d(450.0, 0.0, 0.0), vector3d(1000.0, 0.0, 0.0), center, radius));

		std::vector<Visibility::OccluderVolume> occluders = {
			{ vector3d(0.0, 500.0, 0.0), 50.0, Visibility::OccluderKind::Body },
			{ center, radius, Visibility::OccluderKind::Anomaly }
		};
		CHECK(Visibility::IsOccluded(vector3d(0.0, 0.0, 0.0), vector3d(1000.0, 0.0, 0.0), occluders));
		CHECK_FALSE(Visibility::IsOccluded(vector3d(0.0, -200.0, 0.0), vector3d(1000.0, -200.0, 0.0), occluders));
	}

	SUBCASE("IsWithinFieldOfView respects 65-degree police cone")
	{
		const vector3d fwd(0.0, 0.0, -1.0);
		const double halfAngle = Visibility::POLICE_WITNESS_FOV_FULL_ANGLE_DEG * 0.5; // 32.5 deg

		// Straight ahead -> inside
		CHECK(Visibility::IsWithinFieldOfView(fwd, vector3d(0.0, 0.0, -1000.0), halfAngle));
		// 20 deg off-axis -> inside
		const double rad20 = 20.0 * (M_PI / 180.0);
		CHECK(Visibility::IsWithinFieldOfView(fwd, vector3d(std::sin(rad20), 0.0, -std::cos(rad20)), halfAngle));
		// 40 deg off-axis -> outside 65 deg full cone (half angle 32.5 deg)
		const double rad40 = 40.0 * (M_PI / 180.0);
		CHECK_FALSE(Visibility::IsWithinFieldOfView(fwd, vector3d(std::sin(rad40), 0.0, -std::cos(rad40)), halfAngle));
		// Directly behind -> outside
		CHECK_FALSE(Visibility::IsWithinFieldOfView(fwd, vector3d(0.0, 0.0, 1000.0), halfAngle));
	}

	SUBCASE("TransponderState instant-off and <= 1s warmup")
	{
		Visibility::TransponderState xp;
		CHECK(xp.IsActive());
		CHECK(xp.IsRequested());
		CHECK_FALSE(xp.IsWarmingUp());

		// Off is instant
		xp.Set(false);
		CHECK_FALSE(xp.IsActive());
		CHECK_FALSE(xp.IsRequested());
		CHECK_FALSE(xp.IsWarmingUp());

		// On takes <= 1s (0.85s)
		CHECK(Visibility::TransponderState::WARMUP_TIME <= 1.0f);
		xp.Set(true);
		CHECK(xp.IsRequested());
		CHECK(xp.IsWarmingUp());
		CHECK_FALSE(xp.IsActive());

		xp.Update(0.5f);
		CHECK(xp.IsWarmingUp());
		CHECK_FALSE(xp.IsActive());

		// Turning off mid-warmup is instant
		xp.Set(false);
		CHECK_FALSE(xp.IsActive());
		CHECK_FALSE(xp.IsWarmingUp());

		// Full warmup completes cleanly
		xp.Set(true);
		xp.Update(0.9f);
		CHECK(xp.IsActive());
		CHECK_FALSE(xp.IsWarmingUp());
	}

	SUBCASE("EvaluateSensorVisibility covers FTL, sublight, dark, and locked targets")
	{
		Visibility::SensorVisibilityParams p;
		p.targetAlive = true;
		p.targetInSpace = true;
		p.targetDocked = false;
		p.targetInSC = true;
		p.targetIsFTL = true;
		p.targetTransponderActive = false;
		p.observerInSC = false; // Sub-light observer!
		p.hasExistingLock = false;
		p.isOccluded = false;
		p.distance = 1.0e12;
		p.darkSensorRange = 0.0;

		// Sub-light observer sees dark >= 1c FTL ship with clear LOS
		CHECK(Visibility::EvaluateSensorVisibility(p));

		// Occlusion hides even FTL light
		p.isOccluded = true;
		CHECK_FALSE(Visibility::EvaluateSensorVisibility(p));

		// Dark sub-1c ship beyond 1 km is hidden without sensor or lock
		p.isOccluded = false;
		p.targetIsFTL = false;
		p.targetInSC = false;
		p.distance = 5000.0;
		CHECK_FALSE(Visibility::EvaluateSensorVisibility(p));

		// Visible within 1 km sub-light (visual hull ID)
		p.distance = 950.0;
		CHECK(Visibility::EvaluateSensorVisibility(p));

		// Visible within dark-ship sensor array range
		p.distance = 12000.0;
		p.darkSensorRange = Visibility::GetDarkSensorRangeForLevel(1); // 15 km
		CHECK(Visibility::EvaluateSensorVisibility(p));
		p.distance = 20000.0;
		CHECK_FALSE(Visibility::EvaluateSensorVisibility(p));

		// Transponder ON below 1c is visible/targetable
		p.targetTransponderActive = true;
		CHECK(Visibility::EvaluateSensorVisibility(p));
	}

	SUBCASE("EvaluateLockPersistence survives mode/speed/transponder, breaks on LOS/dock/death")
	{
		CHECK(Visibility::EvaluateLockPersistence(true, true, false, false, false));
		CHECK_FALSE(Visibility::EvaluateLockPersistence(false, true, false, false, false)); // dead
		CHECK_FALSE(Visibility::EvaluateLockPersistence(true, false, false, false, false)); // left system
		CHECK_FALSE(Visibility::EvaluateLockPersistence(true, true, true, false, false));  // target docked
		CHECK_FALSE(Visibility::EvaluateLockPersistence(true, true, false, true, false));  // observer docked
		CHECK_FALSE(Visibility::EvaluateLockPersistence(true, true, false, false, true));  // occluded
	}

	SUBCASE("EvaluateIdentityReadable enforces transponder and 1 km sub-light hull ID rule")
	{
		// Transponder ON -> readable at any speed/mode
		CHECK(Visibility::EvaluateIdentityReadable(true, true, true, 1e12));
		CHECK(Visibility::EvaluateIdentityReadable(true, false, true, 1e12));

		// Dark in supercruise -> NEVER readable even within 1 km
		CHECK_FALSE(Visibility::EvaluateIdentityReadable(false, true, true, 500.0));
		CHECK_FALSE(Visibility::EvaluateIdentityReadable(false, false, true, 500.0));
		CHECK_FALSE(Visibility::EvaluateIdentityReadable(false, true, false, 500.0));

		// Dark in normal space -> readable <= 1 km only
		CHECK(Visibility::EvaluateIdentityReadable(false, false, false, 999.0));
		CHECK_FALSE(Visibility::EvaluateIdentityReadable(false, false, false, 1001.0));
	}
}

TEST_CASE("Supercruise entry threshold and smooth acceleration transition")
{
	CHECK(SupercruiseController::MIN_ENGAGE_SPEED == doctest::Approx(350.0));

	double speed = SupercruiseController::MIN_ENGAGE_SPEED;
	const double desiredSpeed = 150000.0; // 150 km/s at 75% throttle
	const float dt = 1.0f / 60.0f;

	// First frame starts ramping smoothly from current sublight velocity instead of snapping to 30 km/s
	speed = SupercruiseController::StepSpeed(speed, desiredSpeed, 0.75, 0.0, true, dt);
	CHECK(speed > 350.0);
	CHECK(speed < 1000.0);

	// Stepping over 5 seconds crosses MIN_SPEED smoothly and reaches desiredSpeed
	bool sawIntermediate = false;
	for (int i = 0; i < 300; ++i) {
		speed = SupercruiseController::StepSpeed(speed, desiredSpeed, 0.75, 0.0, true, dt);
		if (speed > 2000.0 && speed < SupercruiseController::MIN_SPEED)
			sawIntermediate = true;
	}
	CHECK(sawIntermediate);
	CHECK(speed == doctest::Approx(desiredSpeed));

	// Once >= MIN_SPEED, zero throttle decelerates smoothly and floors at MIN_SPEED (30 km/s)
	for (int i = 0; i < 300; ++i) {
		speed = SupercruiseController::StepSpeed(speed, SupercruiseController::MIN_SPEED, 0.0, 0.0, false, dt);
	}
	CHECK(speed == doctest::Approx(SupercruiseController::MIN_SPEED));
}

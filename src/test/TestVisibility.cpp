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

TEST_CASE("SupercruiseAutopilotMk3AndMk4")
{
	SUBCASE("ComputeSafeSurveyOrbitRadius")
	{
		// Standard rocky planet (~6,000 km radius, exclusion ~7,800 km), orbital scan up to 60,000 km
		const double planetR = 6.0e6;
		const double planetExcl = 7.8e6;
		const double rOrbit = SupercruiseController::ComputeSafeSurveyOrbitRadius(
			planetExcl, planetR, false, false, 0.0, 0.0, 60.0e6, 0.0, false);
		CHECK(rOrbit >= planetExcl * 1.35);
		CHECK(rOrbit <= 60.0e6 * 0.90);

		// Tiny moon/asteroid (20 km radius) still enforces >= 250 km turn-rate radius floor
		const double tinyR = SupercruiseController::ComputeSafeSurveyOrbitRadius(
			30.0e3, 20.0e3, false, false, 0.0, 0.0, 10.0e6, 0.0, false);
		CHECK(tinyR >= 250000.0);

		// Star enforces corona clearance (>= max(excl * 2.1, bodyRadius * 2.5))
		const double starR = 7.0e8;
		const double starExcl = 1.4e9;
		const double starOrbit = SupercruiseController::ComputeSafeSurveyOrbitRadius(
			starExcl, starR, true, false, 0.0, 0.0, 10.0e9, 0.0, false);
		CHECK(starOrbit >= starExcl * 2.1);

		// Ringed gas giant:
		// 1) Equatorial orbit requested inside the ring band pushes outside outer ring edge (> ringOuter * 1.15)
		const double ggR = 7.0e7;
		const double ggExcl = 8.4e7;
		const double ringIn = 1.6e8;
		const double ringOut = 2.4e8;
		const double eqOrbit = SupercruiseController::ComputeSafeSurveyOrbitRadius(
			ggExcl, ggR, false, true, ringIn, ringOut, 5.0e8, 2.0e8, false);
		CHECK(eqOrbit >= ringOut * 1.15);

		// 2) Polar sweep with inner clearance can skim inside inner ring edge
		const double polarOrbit = SupercruiseController::ComputeSafeSurveyOrbitRadius(
			ggExcl, ggR, false, true, ringIn, ringOut, 5.0e8, 2.0e8, true);
		CHECK(polarOrbit < ringIn);
		CHECK(polarOrbit >= ggExcl * 1.28);

		// 3) Tight inner ring that would intrude inside exclusion clearance pushes polar sweep outside rings
		const double tightPolarOrbit = SupercruiseController::ComputeSafeSurveyOrbitRadius(
			ggExcl, ggR, false, true, 1.0e8, 1.8e8, 5.0e8, 1.2e8, true);
		CHECK(tightPolarOrbit >= 1.8e8 * 1.15);
	}

	SUBCASE("ComputeAssistApproachThrottle")
	{
		// assistLevel: 1 = Autopilot Mk 2, 2 = Autopilot Mk 3, 3 = Autopilot Mk 4
		// Mk 3 / Mk 4 use full 1.0 throttle in aligned deep space
		const double mk3Deep = SupercruiseController::ComputeAssistApproachThrottle(
			1.0e12, 5.0e8, 1.0e10, 1.0, false, false, 2);
		CHECK(mk3Deep == doctest::Approx(1.0));
		const double mk4Deep = SupercruiseController::ComputeAssistApproachThrottle(
			1.0e12, 5.0e8, 1.0e10, 1.0, false, true, 3);
		CHECK(mk4Deep == doctest::Approx(1.0));

		// Mk 2 (assistLevel 1) caps cruise throttle at 0.75
		const double mk2Deep = SupercruiseController::ComputeAssistApproachThrottle(
			1.0e12, 5.0e8, 1.0e10, 1.0, false, false, 1);
		CHECK(mk2Deep == doctest::Approx(0.75));

		// Slowdown warning or high closing velocity triggers predictive braking on Mk 3 / Mk 4
		const double mk3Brake = SupercruiseController::ComputeAssistApproachThrottle(
			1.0e8, 8.0e7, 5.0e6, 1.0, true, false, 2);
		CHECK(mk3Brake < 0.3);
		const double mk4Brake = SupercruiseController::ComputeAssistApproachThrottle(
			1.0e8, 8.0e7, 5.0e6, 1.0, true, true, 3);
		CHECK(mk4Brake < 0.3);

		// Mk 2 (assistLevel 1) brakes to 0.15 only near orbit (< 1.5 Mm) when overspeeding
		const double mk2OrbitBrake = SupercruiseController::ComputeAssistApproachThrottle(
			1.0e6, 2.0e6, 5.0e6, 1.0, true, true, 1);
		CHECK(mk2OrbitBrake == doctest::Approx(0.15));
	}

	SUBCASE("ComputeOrbitSteeringDir")
	{
		const double orbitR = 1.0e7;
		const double exclR = 5.0e6;
		const vector3d tangent(0.0, 1.0, 0.0);

		// Far approach (> 2.2 * orbitR) steers toward limb point rather than direct center
		const vector3d farToBody(5.0e7, 0.0, 0.0);
		const vector3d farDir = SupercruiseController::ComputeOrbitSteeringDir(farToBody, tangent, orbitR, exclR);
		CHECK(farDir.Length() == doctest::Approx(1.0));
		CHECK(farDir.y > 0.1);
		CHECK(farDir.x > 0.8);

		// At exact orbit radius, steers essentially along tangent
		const vector3d onOrbitToBody(orbitR, 0.0, 0.0);
		const vector3d onOrbitDir = SupercruiseController::ComputeOrbitSteeringDir(onOrbitToBody, tangent, orbitR, exclR);
		CHECK(onOrbitDir.Length() == doctest::Approx(1.0));
		CHECK(onOrbitDir.y > 0.95);

		// Inside exclusion safety zone (< 1.18 * exclR), pushes strongly outward away from body
		const vector3d closeToBody(exclR * 1.05, 0.0, 0.0);
		const vector3d escapeDir = SupercruiseController::ComputeOrbitSteeringDir(closeToBody, tangent, orbitR, exclR);
		CHECK(escapeDir.Length() == doctest::Approx(1.0));
		CHECK(escapeDir.x < -0.5);
	}
}

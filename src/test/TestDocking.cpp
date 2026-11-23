// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "doctest.h"
#include "ship/OrbitalDockingGeometry.h"

#include <cmath>

TEST_CASE("OrbitalStationDetour")
{
	const vector3d corridorDir(0.0, 0.0, 1.0);
	const vector3d fallbackDir(1.0, 0.0, 0.0);

	SUBCASE("Large 2-10k ring station allows unobstructed front and abeam approaches")
	{
		const double clipRadius = 5339.0;
		const vector3d portPos(0.0, 0.0, 511.0);
		const vector3d approach1(0.0, 0.0, 1111.0);
		vector3d detour;

		// 6 km directly in front of the airlock -> no detour
		CHECK_FALSE(ComputeOrbitalStationDetourLocal(vector3d(0.0, 0.0, 6511.0), approach1, portPos, corridorDir, fallbackDir, clipRadius, detour));

		// 6 km front-angled -> no detour
		CHECK_FALSE(ComputeOrbitalStationDetourLocal(vector3d(3500.0, 1500.0, 4500.0), approach1, portPos, corridorDir, fallbackDir, clipRadius, detour));

		// 6 km front-abeam -> no detour
		CHECK_FALSE(ComputeOrbitalStationDetourLocal(vector3d(5800.0, 0.0, 1200.0), approach1, portPos, corridorDir, fallbackDir, clipRadius, detour));

		// Close outside airlock inside approach cone -> no detour
		CHECK_FALSE(ComputeOrbitalStationDetourLocal(vector3d(50.0, 20.0, 750.0), approach1, portPos, corridorDir, fallbackDir, clipRadius, detour));
	}

	SUBCASE("Compact 2-2k ring station allows unobstructed front and abeam approaches")
	{
		const double clipRadius = 2027.0;
		const vector3d portPos(0.0, 0.0, 133.0);
		const vector3d approach1(0.0, 0.0, 733.0);
		vector3d detour;

		CHECK_FALSE(ComputeOrbitalStationDetourLocal(vector3d(0.0, 0.0, 6133.0), approach1, portPos, corridorDir, fallbackDir, clipRadius, detour));
		CHECK_FALSE(ComputeOrbitalStationDetourLocal(vector3d(2500.0, -900.0, 1500.0), approach1, portPos, corridorDir, fallbackDir, clipRadius, detour));
		CHECK_FALSE(ComputeOrbitalStationDetourLocal(vector3d(30.0, -40.0, 400.0), approach1, portPos, corridorDir, fallbackDir, clipRadius, detour));
	}

	SUBCASE("Approaches from behind station hub converge in 2 unobstructed rim detours")
	{
		const double clipRadius = 5339.0;
		const vector3d portPos(0.0, 0.0, 511.0);
		const vector3d approach1(0.0, 0.0, 1111.0);

		const vector3d starts[] = {
			vector3d(0.0, 0.0, -2000.0),    // directly behind hub
			vector3d(3000.0, 0.0, -1500.0), // behind ring rim
		};

		for (const vector3d &start : starts) {
			vector3d d1;
			REQUIRE(ComputeOrbitalStationDetourLocal(start, approach1, portPos, corridorDir, fallbackDir, clipRadius, d1));
			// Detour 1 clears outer disc radius and is itself unobstructed from start
			const double r1 = vector3d(d1.x, d1.y, 0.0).Length();
			CHECK(r1 > clipRadius + 180.0);
			vector3d checkSeg1;
			CHECK_FALSE(ComputeOrbitalStationDetourLocal(start, d1, portPos, corridorDir, fallbackDir, clipRadius, checkSeg1));

			vector3d d2;
			REQUIRE(ComputeOrbitalStationDetourLocal(d1, approach1, portPos, corridorDir, fallbackDir, clipRadius, d2));
			// Detour 2 clears front slab plane and is unobstructed from d1
			CHECK(d2.z >= portPos.z + 280.0);
			vector3d checkSeg2;
			CHECK_FALSE(ComputeOrbitalStationDetourLocal(d1, d2, portPos, corridorDir, fallbackDir, clipRadius, checkSeg2));

			// Step 3 from front plane directly to APPROACH1 requires no further detour
			vector3d d3;
			CHECK_FALSE(ComputeOrbitalStationDetourLocal(d2, approach1, portPos, corridorDir, fallbackDir, clipRadius, d3));
		}
	}

	SUBCASE("Front-half inside-slab positions exit forward axially without flying aft or to ring")
	{
		struct Case {
			double clipRadius;
			vector3d startOffset;
		};
		const Case cases[] = {
			{ 5339.0, vector3d(800.0, 0.0, 150.0) },
			{ 3052.3, vector3d(400.0, 0.0, 50.0) },
		};
		const vector3d portPos(0.0, 0.0, 511.0);
		const vector3d approach1(0.0, 0.0, 1111.0);

		for (const auto &c : cases) {
			const vector3d start = portPos + c.startOffset;
			const double r0 = vector3d(start.x, start.y, 0.0).Length();
			vector3d d1;
			REQUIRE(ComputeOrbitalStationDetourLocal(start, approach1, portPos, corridorDir, fallbackDir, c.clipRadius, d1));
			CHECK(d1.z >= portPos.z + 240.0);
			CHECK(vector3d(d1.x, d1.y, 0.0).Length() == doctest::Approx(r0));

			vector3d d2;
			CHECK_FALSE(ComputeOrbitalStationDetourLocal(d1, approach1, portPos, corridorDir, fallbackDir, c.clipRadius, d2));
		}
	}

	SUBCASE("Rear-half inside-slab position executes unobstructed 3-stage orthogonal escape")
	{
		const double clipRadius = 5339.0;
		const vector3d portPos(0.0, 0.0, 511.0);
		const vector3d approach1(0.0, 0.0, 1111.0);
		const vector3d start = portPos + vector3d(1500.0, 0.0, -500.0);

		vector3d d1;
		REQUIRE(ComputeOrbitalStationDetourLocal(start, approach1, portPos, corridorDir, fallbackDir, clipRadius, d1));
		CHECK(d1.z <= portPos.z - 1200.0);
		CHECK(vector3d(d1.x, d1.y, 0.0).Length() == doctest::Approx(1500.0));

		vector3d d2;
		REQUIRE(ComputeOrbitalStationDetourLocal(d1, approach1, portPos, corridorDir, fallbackDir, clipRadius, d2));
		CHECK(vector3d(d2.x, d2.y, 0.0).Length() > clipRadius + 220.0);
		CHECK(d2.z <= portPos.z - 1200.0);
		vector3d check12;
		CHECK_FALSE(ComputeOrbitalStationDetourLocal(d1, d2, portPos, corridorDir, fallbackDir, clipRadius, check12));

		vector3d d3;
		REQUIRE(ComputeOrbitalStationDetourLocal(d2, approach1, portPos, corridorDir, fallbackDir, clipRadius, d3));
		CHECK(d3.z >= portPos.z + 240.0);
		vector3d check23;
		CHECK_FALSE(ComputeOrbitalStationDetourLocal(d2, d3, portPos, corridorDir, fallbackDir, clipRadius, check23));

		vector3d d4;
		CHECK_FALSE(ComputeOrbitalStationDetourLocal(d3, approach1, portPos, corridorDir, fallbackDir, clipRadius, d4));
	}

	SUBCASE("Front-to-rear transit routes around rim cleanly")
	{
		const double clipRadius = 5339.0;
		const vector3d portPos(0.0, 0.0, 511.0);
		const vector3d start = portPos + vector3d(200.0, 0.0, 600.0);
		const vector3d target = portPos + vector3d(0.0, 0.0, -2000.0);

		vector3d d1;
		REQUIRE(ComputeOrbitalStationDetourLocal(start, target, portPos, corridorDir, fallbackDir, clipRadius, d1));
		CHECK(d1.z >= portPos.z + 240.0);
		CHECK(vector3d(d1.x, d1.y, 0.0).Length() > clipRadius + 220.0);
		vector3d check01;
		CHECK_FALSE(ComputeOrbitalStationDetourLocal(start, d1, portPos, corridorDir, fallbackDir, clipRadius, check01));

		vector3d d2;
		REQUIRE(ComputeOrbitalStationDetourLocal(d1, target, portPos, corridorDir, fallbackDir, clipRadius, d2));
		CHECK(d2.z <= portPos.z - 1200.0);
		vector3d check12;
		CHECK_FALSE(ComputeOrbitalStationDetourLocal(d1, d2, portPos, corridorDir, fallbackDir, clipRadius, check12));

		vector3d d3;
		CHECK_FALSE(ComputeOrbitalStationDetourLocal(d2, target, portPos, corridorDir, fallbackDir, clipRadius, d3));
	}
}

TEST_CASE("OrbitalCorridorGuidance")
{
	const vector3d portPos(0.0, 0.0, 511.0);
	const vector3d corridorDir(0.0, 0.0, 1.0);
	const vector3d zeroLat(0.0);
	constexpr double kPi = 3.14159265358979323846;
	auto deg2rad = [kPi](double d) { return d * (kPi / 180.0); };

	SUBCASE("CanSkipOrbitalApproach1 enforces narrow aligned cone and low speed")
	{
		// Rejects off-axis / close-to-wall / fast-lateral approaches
		CHECK_FALSE(CanSkipOrbitalApproach1(50.0, 20.0, 2.0, 20.0));
		CHECK_FALSE(CanSkipOrbitalApproach1(300.0, 120.0, 2.0, 20.0));
		CHECK_FALSE(CanSkipOrbitalApproach1(400.0, 10.0, 25.0, 30.0));
		CHECK_FALSE(CanSkipOrbitalApproach1(400.0, 10.0, 2.0, 90.0));
		// Accepts tight aligned low-speed corridor approaches
		CHECK(CanSkipOrbitalApproach1(400.0, 20.0, 5.0, 25.0));
		CHECK(CanSkipOrbitalApproach1(150.0, 10.0, 2.0, 18.0));
	}

	SUBCASE("Off-axis ship holds axial advance and strafes cleanly onto axis")
	{
		// Far off-axis (80m at 400m axial) -> zero forward advance, purely inward centering
		const auto gFar = ComputeOrbitalCorridorGuidance(
			portPos + vector3d(80.0, 0.0, 400.0), portPos, corridorDir, zeroLat,
			60.0, 1.0, 8.0, 8.0, deg2rad(2.0), deg2rad(2.0), false);
		CHECK_FALSE(gFar.resetToApproach1);
		CHECK_FALSE(gFar.readyForDockingSequence);
		CHECK(gFar.fwdSpeed == doctest::Approx(0.0));
		CHECK(gFar.desiredVelInStation.z == doctest::Approx(0.0));
		CHECK(gFar.desiredVelInStation.x < 0.0);

		// Close off-axis (25m at 100m axial) -> zero forward advance
		const auto gClose = ComputeOrbitalCorridorGuidance(
			portPos + vector3d(0.0, 25.0, 100.0), portPos, corridorDir, zeroLat,
			28.0, 1.0, 8.0, 8.0, deg2rad(2.0), deg2rad(2.0), false);
		CHECK_FALSE(gClose.resetToApproach1);
		CHECK(gClose.fwdSpeed == doctest::Approx(0.0));
		CHECK(gClose.desiredVelInStation.y < 0.0);
	}

	SUBCASE("Misaligned attitude holds forward ingress near airlock")
	{
		// Nose pointing 35 deg away
		const auto gNose = ComputeOrbitalCorridorGuidance(
			portPos + vector3d(0.0, 0.0, 200.0), portPos, corridorDir, zeroLat,
			40.0, 1.0, 8.0, 8.0, deg2rad(35.0), deg2rad(2.0), false);
		CHECK(gNose.fwdSpeed == doctest::Approx(0.0));
		CHECK_FALSE(gNose.readyForDockingSequence);

		// Roll misaligned by 40 deg close to mail-slot
		const auto gRoll = ComputeOrbitalCorridorGuidance(
			portPos + vector3d(0.0, 0.0, 80.0), portPos, corridorDir, zeroLat,
			25.0, 1.0, 8.0, 8.0, deg2rad(2.0), deg2rad(40.0), false);
		CHECK(gRoll.fwdSpeed == doctest::Approx(0.0));
		CHECK_FALSE(gRoll.readyForDockingSequence);
	}

	SUBCASE("Ship beside or behind airlock face triggers APPROACH1 reset and backs clear")
	{
		const auto gWall = ComputeOrbitalCorridorGuidance(
			portPos + vector3d(60.0, 0.0, 5.0), portPos, corridorDir, zeroLat,
			25.0, 1.0, 8.0, 8.0, deg2rad(2.0), deg2rad(2.0), false);
		CHECK(gWall.resetToApproach1);
		CHECK(gWall.desiredVelInStation.z > 0.0);
	}

	SUBCASE("Critically damped lateral velocity prevents heavy-ship overshoot")
	{
		const double latAccel = 3.0;
		const double offAxis = 20.0;
		const auto gHeavy = ComputeOrbitalCorridorGuidance(
			portPos + vector3d(offAxis, 0.0, 300.0), portPos, corridorDir, zeroLat,
			40.0, 1.0, latAccel, 4.0, deg2rad(2.0), deg2rad(2.0), false);
		const double maxStoppingSpeed = std::sqrt(2.0 * (0.65 * latAccel) * offAxis);
		CHECK(std::fabs(gHeavy.desiredVelInStation.x) <= maxStoppingSpeed + 1e-6);
	}

	SUBCASE("Aligned ship inside doorway triggers docking sequence")
	{
		const auto gReady = ComputeOrbitalCorridorGuidance(
			portPos + vector3d(2.0, -3.0, 14.0), portPos, corridorDir, zeroLat,
			25.0, 1.0, 8.0, 8.0, deg2rad(2.0), deg2rad(5.0), false);
		CHECK_FALSE(gReady.resetToApproach1);
		CHECK(gReady.readyForDockingSequence);
	}
}

TEST_CASE("SupercruiseStationDropIn")
{
	const vector3d stationPos(1000.0, 2000.0, -3000.0);
	const double orbitalDropDist = 12000.0;
	const double surfaceDropDist = 12800.0;
	const double minClear = 1500.0;

	SUBCASE("Orbital straight-in approach drops at 12 km preserving exact approach vector and roll")
	{
		const vector3d approachFwd = vector3d(0.0, 0.0, -1.0);
		const vector3d rollUp = vector3d(0.6, 0.8, 0.0).Normalized();
		const matrix3x3d shipOrient = BuildDropOrientPreservingUp(approachFwd, rollUp);
		const vector3d shipPos = stationPos - approachFwd * 400000.0;

		const auto res = ComputeOrbitalStationDropIn(stationPos, shipPos, shipOrient, orbitalDropDist, minClear);
		CHECK(res.preservedApproachVector);
		CHECK((res.position - stationPos).Length() == doctest::Approx(orbitalDropDist));
		CHECK((stationPos - res.position).Normalized().Dot(approachFwd) == doctest::Approx(1.0));
		CHECK((-res.orient.VectorZ()).Dot(approachFwd) == doctest::Approx(1.0));
		CHECK(res.orient.VectorY().Dot(rollUp) == doctest::Approx(1.0));
	}

	SUBCASE("Orbital angled approach (25 deg off radial line) drops along approach vector, not radial line")
	{
		const vector3d radialFromSt = vector3d(0.0, 0.0, 1.0);
		const vector3d shipPos = stationPos + radialFromSt * 500000.0;
		// Ship steered 25 degrees sideways in Supercruise before hitting Safe Disengage
		const vector3d approachFwd = (matrix3x3d::RotateY(0.436332) * (-radialFromSt)).Normalized();
		const vector3d customUp = vector3d(-0.3, 0.9, 0.2).Normalized();
		const matrix3x3d shipOrient = BuildDropOrientPreservingUp(approachFwd, customUp);

		const auto res = ComputeOrbitalStationDropIn(stationPos, shipPos, shipOrient, orbitalDropDist, minClear);
		CHECK(res.preservedApproachVector);
		CHECK((res.position - stationPos).Length() == doctest::Approx(orbitalDropDist));
		// Ship drops directly behind its own Supercruise approach vector with zero orientation snap
		CHECK((stationPos - res.position).Normalized().Dot(approachFwd) == doctest::Approx(1.0));
		CHECK(res.orient.VectorZ().Dot(shipOrient.VectorZ()) == doctest::Approx(1.0));
		CHECK(res.orient.VectorY().Dot(shipOrient.VectorY()) == doctest::Approx(1.0));
	}

	SUBCASE("Orbital disengage pointed > 60 deg away falls back to ship's side of station")
	{
		const vector3d radialFromSt = vector3d(1.0, 0.0, 0.0);
		const vector3d shipPos = stationPos + radialFromSt * 300000.0;
		const vector3d awayFwd = vector3d(0.0, 0.0, -1.0); // 90 deg off
		const vector3d shipUp = vector3d(0.0, 1.0, 0.0);
		const matrix3x3d shipOrient = BuildDropOrientPreservingUp(awayFwd, shipUp);

		const auto res = ComputeOrbitalStationDropIn(stationPos, shipPos, shipOrient, orbitalDropDist, minClear);
		CHECK_FALSE(res.preservedApproachVector);
		CHECK((res.position - stationPos).Normalized().Dot(radialFromSt) == doctest::Approx(1.0));
		CHECK((-res.orient.VectorZ()).Dot(-radialFromSt) == doctest::Approx(1.0));
		CHECK(res.orient.VectorY().Dot(shipUp) == doctest::Approx(1.0));
	}

	SUBCASE("Surface overhead and moderate glide approaches preserve exact pitch and inverted roll")
	{
		const vector3d planetUp(0.0, 1.0, 0.0);
		// Case A: steep ~80 deg overhead descent with inverted cockpit roll
		const vector3d steepDropDir = vector3d(0.1736, 0.9848, 0.0).Normalized();
		const vector3d steepFwd = -steepDropDir;
		const vector3d invertedUp = vector3d(0.0, 0.0, -1.0);
		const matrix3x3d steepOrient = BuildDropOrientPreservingUp(steepFwd, invertedUp);
		const auto resSteep = ComputeSurfaceStationDropIn(
			stationPos, planetUp, stationPos + steepDropDir * 500000.0, steepOrient, surfaceDropDist, 0.25);

		CHECK(resSteep.preservedApproachVector);
		CHECK((resSteep.position - stationPos).Length() == doctest::Approx(surfaceDropDist));
		CHECK((stationPos - resSteep.position).Normalized().Dot(steepFwd) == doctest::Approx(1.0));
		CHECK(resSteep.orient.VectorZ().Dot(steepOrient.VectorZ()) == doctest::Approx(1.0));
		CHECK(resSteep.orient.VectorY().Dot(steepOrient.VectorY()) == doctest::Approx(1.0));

		// Case B: moderate 30 deg glide angle (elevSin = 0.50 > 0.25)
		const vector3d glideDropDir = vector3d(0.8660254, 0.5, 0.0).Normalized();
		const vector3d glideFwd = -glideDropDir;
		const matrix3x3d glideOrient = BuildDropOrientPreservingUp(glideFwd, invertedUp);
		const auto resGlide = ComputeSurfaceStationDropIn(
			stationPos, planetUp, stationPos + glideDropDir * 400000.0, glideOrient, surfaceDropDist, 0.25);

		CHECK(resGlide.preservedApproachVector);
		CHECK((resGlide.position - stationPos).Dot(planetUp) / surfaceDropDist == doctest::Approx(0.5));
		CHECK(resGlide.orient.VectorY().Dot(glideOrient.VectorY()) == doctest::Approx(1.0));
	}

	SUBCASE("Surface shallow below-horizon approach lifts only to minElevationSin along same azimuth")
	{
		const vector3d planetUp(0.0, 1.0, 0.0);
		// Approaching barely 3 degrees above horizon (sin ~ 0.05 < 0.25) from the +Z azimuth
		const vector3d shallowDropDir = vector3d(0.0, 0.05, 0.99875).Normalized();
		const vector3d shallowFwd = -shallowDropDir;
		const vector3d cockpitUp = vector3d(0.7071, 0.7071, 0.0).Normalized();
		const matrix3x3d shallowOrient = BuildDropOrientPreservingUp(shallowFwd, cockpitUp);

		const auto res = ComputeSurfaceStationDropIn(
			stationPos, planetUp, stationPos + shallowDropDir * 350000.0, shallowOrient, surfaceDropDist, 0.25);

		CHECK_FALSE(res.preservedApproachVector);
		const vector3d rel = res.position - stationPos;
		CHECK(rel.Length() == doctest::Approx(surfaceDropDist));
		CHECK(rel.Dot(planetUp) / surfaceDropDist == doctest::Approx(0.25));
		// Same horizontal azimuth (+Z)
		const vector3d horizDir = (rel - planetUp * rel.Dot(planetUp)).Normalized();
		CHECK(horizDir.Dot(vector3d(0.0, 0.0, 1.0)) == doctest::Approx(1.0));
		// Nose points directly at starport, cockpit roll stays near original up
		CHECK((-res.orient.VectorZ()).Dot(-rel.Normalized()) == doctest::Approx(1.0));
		CHECK(res.orient.VectorY().Dot(cockpitUp) > 0.8);
	}

	SUBCASE("Disengage already within safeDropDist keeps current position and orientation")
	{
		const vector3d approachFwd = vector3d(-0.6, 0.0, -0.8).Normalized();
		const matrix3x3d shipOrient = BuildDropOrientPreservingUp(approachFwd, vector3d(0.0, 1.0, 0.0));
		const vector3d closePos = stationPos + vector3d(0.0, 0.0, 8000.0);

		const auto resOrb = ComputeOrbitalStationDropIn(stationPos, closePos, shipOrient, orbitalDropDist, minClear);
		CHECK(resOrb.preservedApproachVector);
		CHECK((resOrb.position - closePos).Length() == doctest::Approx(0.0));
		CHECK(resOrb.orient.VectorZ().Dot(shipOrient.VectorZ()) == doctest::Approx(1.0));

		const vector3d tooClosePos = stationPos + vector3d(0.0, 0.0, 500.0);
		const auto resPush = ComputeOrbitalStationDropIn(stationPos, tooClosePos, shipOrient, orbitalDropDist, minClear);
		CHECK((resPush.position - stationPos).Length() == doctest::Approx(minClear));
		CHECK(resPush.orient.VectorZ().Dot(shipOrient.VectorZ()) == doctest::Approx(1.0));
	}
}

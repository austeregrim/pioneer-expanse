// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "doctest.h"
#include "ship/OrbitalDockingGeometry.h"

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
}

// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "doctest.h"
#include "ship/Subsystems.h"

namespace {

	std::vector<Subsystems::SubsystemNode> MakeSampleShipSubsystems()
	{
		const Aabb hull(vector3d(-8.0, -4.0, -15.0), vector3d(8.0, 4.0, 15.0), 18.0);
		std::vector<Subsystems::SubsystemNode> nodes;

		auto makeNode = [&](const std::string &id, const std::string &cat, const std::string &slotId = "") {
			Subsystems::SubsystemNode n;
			n.id = id;
			n.name = id;
			n.category = cat;
			n.slotId = slotId;
			Subsystems::ComputeDefaultZoneForCategory(cat, hull, n.localPos, n.radius);
			n.integrity = 1.0f;
			n.disabled = false;
			return n;
		};

		nodes.push_back(makeNode("thrusters", "thrusters"));
		nodes.push_back(makeNode("hyperdrive", "hyperdrive"));
		nodes.push_back(makeNode("shields", "shields"));
		nodes.push_back(makeNode("sensors", "sensors"));

		Subsystems::SubsystemNode wingGun;
		wingGun.id = "weapon:weapon_s2_1";
		wingGun.name = "Pulse Laser";
		wingGun.category = "weapon";
		wingGun.slotId = "weapon_s2_1";
		wingGun.localPos = vector3d(-6.0, 0.0, -10.0);
		wingGun.radius = 2.5f;
		nodes.push_back(wingGun);

		return nodes;
	}

} // namespace

TEST_CASE("Subsystems")
{
	SUBCASE("Default zones place subsystems in intuitive physical regions")
	{
		const Aabb hull(vector3d(-10.0, -5.0, -20.0), vector3d(10.0, 5.0, 20.0), 23.0);
		vector3d thrusterPos, sensorPos, shieldPos, hdPos;
		float thrusterR, sensorR, shieldR, hdR;

		Subsystems::ComputeDefaultZoneForCategory("thrusters", hull, thrusterPos, thrusterR);
		Subsystems::ComputeDefaultZoneForCategory("sensors", hull, sensorPos, sensorR);
		Subsystems::ComputeDefaultZoneForCategory("shields", hull, shieldPos, shieldR);
		Subsystems::ComputeDefaultZoneForCategory("hyperdrive", hull, hdPos, hdR);

		// +Z is aft, -Z is forward, +Y is dorsal
		CHECK(thrusterPos.z > 10.0);
		CHECK(hdPos.z > 0.0);
		CHECK(hdPos.z < thrusterPos.z);
		CHECK(sensorPos.z < -10.0);
		CHECK(shieldPos.y > 2.0);
		CHECK(thrusterR > 5.0f);
	}

	SUBCASE("ResolveHit maps physical impact coordinates to the struck component")
	{
		auto nodes = MakeSampleShipSubsystems();

		// Aft engine hit -> thrusters
		const auto aftHit = Subsystems::ResolveHit(nodes, nodes[0].localPos + vector3d(0.2, -0.1, 0.3));
		REQUIRE(aftHit.index == 0);
		CHECK(aftHit.proximityFactor > 0.85f);

		// Forward nose/dorsal hit -> sensors
		const auto noseHit = Subsystems::ResolveHit(nodes, nodes[3].localPos);
		REQUIRE(noseHit.index == 3);

		// Port wing hardpoint hit -> weapon mount
		const auto gunHit = Subsystems::ResolveHit(nodes, vector3d(-6.2, 0.2, -10.1));
		REQUIRE(gunHit.index == 4);

		// Far wingtip graze outside every component radius -> bare hull hit (-1)
		const auto outerHullHit = Subsystems::ResolveHit(nodes, vector3d(18.0, 0.0, 0.0));
		CHECK(outerHullHit.index == -1);
		CHECK(outerHullHit.proximityFactor == doctest::Approx(0.0f));
	}

	SUBCASE("CalcSubsystemDamage disables aimed subsystems before hull fails")
	{
		const float hullMass = 50.0f;
		// 10 tonnes penetrating hull (~20% hull) with direct proximity should deal ~56% component damage
		const float directDmg = Subsystems::CalcSubsystemDamage(10.0f, hullMass, 1.0f);
		CHECK(directDmg == doctest::Approx(0.56f).epsilon(0.01));

		// Focused fire (~40% raw hull worth of penetrating shots) can disable a component cleanly
		CHECK(directDmg * 2.0f >= 1.0f);

		// Tiny scratch doesn't shred components
		const float tinyDmg = Subsystems::CalcSubsystemDamage(0.5f, hullMass, 0.6f);
		CHECK(tinyDmg < 0.03f);
	}

	SUBCASE("CalcPerformanceMultiplier preserves full output until 75%, tapers cleanly to 0%")
	{
		CHECK(Subsystems::CalcPerformanceMultiplier(1.0f) == doctest::Approx(1.0f));
		CHECK(Subsystems::CalcPerformanceMultiplier(0.75f) == doctest::Approx(1.0f));
		CHECK(Subsystems::CalcPerformanceMultiplier(0.38f) > 0.5f);
		CHECK(Subsystems::CalcPerformanceMultiplier(0.38f) < 0.8f);
		CHECK(Subsystems::CalcPerformanceMultiplier(0.0005f) == doctest::Approx(0.0f));
		CHECK(Subsystems::CalcPerformanceMultiplier(0.0f) == doctest::Approx(0.0f));
	}
}

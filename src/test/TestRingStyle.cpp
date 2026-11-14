// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "doctest.h"
#include "galaxy/RingStyle.h"

#include <string>

TEST_CASE("RingStyle")
{
	SUBCASE("Default and Clear state")
	{
		RingStyle style;
		CHECK_FALSE(style.HasRings());

		style.minRadius = fixed(14, 10);
		style.maxRadius = fixed(24, 10);
		CHECK(style.HasRings());

		style.Clear();
		CHECK_FALSE(style.HasRings());
		CHECK(style.bands.empty());
	}

	SUBCASE("Multi-band TryGetBandAtRadius and resonance gaps")
	{
		RingStyle style;
		style.minRadius = fixed(13, 10);
		style.maxRadius = fixed(25, 10);

		RingBand innerBand;
		innerBand.minRadius = fixed(13, 10);
		innerBand.maxRadius = fixed(18, 10);
		innerBand.composition = RingComposition::METAL_RICH;
		innerBand.reserveGrade = RingReserveGrade::MAJOR;
		innerBand.thickness = fixed(90, 1);

		RingBand outerBand;
		outerBand.minRadius = fixed(195, 100);
		outerBand.maxRadius = fixed(25, 10);
		outerBand.composition = RingComposition::ICE_WATER;
		outerBand.reserveGrade = RingReserveGrade::PRISTINE;
		outerBand.thickness = fixed(150, 1);

		style.bands.push_back(innerBand);
		style.bands.push_back(outerBand);

		RingBand out;
		CHECK_FALSE(style.TryGetBandAtRadius(1.20, out));
		CHECK(style.TryGetBandAtRadius(1.55, out));
		CHECK(out.composition == RingComposition::METAL_RICH);
		CHECK(out.reserveGrade == RingReserveGrade::MAJOR);

		// Cassini/resonance gap between 1.80 and 1.95
		CHECK_FALSE(style.TryGetBandAtRadius(1.88, out));

		CHECK(style.TryGetBandAtRadius(2.20, out));
		CHECK(out.composition == RingComposition::ICE_WATER);
		CHECK(out.reserveGrade == RingReserveGrade::PRISTINE);
		CHECK_FALSE(style.TryGetBandAtRadius(2.60, out));
	}

	SUBCASE("Legacy single-band fallback carves Cassini gap")
	{
		RingStyle legacy;
		legacy.minRadius = fixed(10, 10);
		legacy.maxRadius = fixed(20, 10);
		legacy.composition = RingComposition::ROCKY_SILICATE;
		legacy.reserveGrade = RingReserveGrade::COMMON;

		RingBand out;
		CHECK(legacy.TryGetBandAtRadius(1.25, out));
		CHECK(out.composition == RingComposition::ROCKY_SILICATE);
		// u = 0.60 falls inside [0.585, 0.625] synthetic Cassini division
		CHECK_FALSE(legacy.TryGetBandAtRadius(1.60, out));
		CHECK(legacy.TryGetBandAtRadius(1.80, out));
	}

	SUBCASE("Reserve multipliers and metadata labels")
	{
		CHECK(RingStyle::GetReserveMultiplier(RingReserveGrade::DEPLETED) < RingStyle::GetReserveMultiplier(RingReserveGrade::COMMON));
		CHECK(RingStyle::GetReserveMultiplier(RingReserveGrade::PRISTINE) > RingStyle::GetReserveMultiplier(RingReserveGrade::MAJOR));
		CHECK(std::string(RingStyle::GetCompositionName(RingComposition::METALLIC_PRECIOUS)) == "Metallic");
		CHECK(std::string(RingStyle::GetReserveGradeName(RingReserveGrade::PRISTINE)) == "Pristine");
	}
}


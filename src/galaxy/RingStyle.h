// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef _RINGSTYLE_H
#define _RINGSTYLE_H

#include "Color.h"
#include "fixed.h"

#include <cstdint>
#include <vector>

enum class RingComposition : uint8_t {
	ICE_WATER = 0,		  // High-albedo H2O ice (Saturn archetype)
	ICE_AMMONIA_METHANE,  // Tholin-darkened volatile clathrates (Uranus/Neptune archetype)
	ROCKY_SILICATE,		  // Basalt, pyroxene, olivine
	METAL_RICH,			  // Iron-nickel, titanium/aluminium ores
	METALLIC_PRECIOUS	  // High-value platinum, gold, alloy veins
};

enum class RingReserveGrade : uint8_t {
	DEPLETED = 0,
	LOW,
	COMMON,
	MAJOR,
	PRISTINE
};

struct RingBand {
	// note: radius values are given as proportions of the planet radius (e.g., 1.6)
	fixed minRadius;
	fixed maxRadius;
	fixed thickness = fixed(80, 1);	   // Vertical semi-thickness in meters (e.g. 40m..220m)
	fixed opticalDepth = fixed(8, 10); // Tau optical depth (0.20..2.0)
	RingComposition composition = RingComposition::ICE_WATER;
	RingReserveGrade reserveGrade = RingReserveGrade::COMMON;
	Color baseColor = Color(255, 255, 255, 255);
	uint32_t seedOffset = 0;
};

struct RingStyle {
	// Outer/aggregate envelope as proportions of planet radius
	fixed minRadius;
	fixed maxRadius;
	Color baseColor;

	fixed thickness = fixed(80, 1);
	RingComposition composition = RingComposition::ICE_WATER;
	RingReserveGrade reserveGrade = RingReserveGrade::COMMON;
	std::vector<RingBand> bands;

	void Clear()
	{
		minRadius = fixed();
		maxRadius = fixed();
		baseColor = Color(255, 255, 255, 255);
		thickness = fixed(80, 1);
		composition = RingComposition::ICE_WATER;
		reserveGrade = RingReserveGrade::COMMON;
		bands.clear();
	}

	bool HasRings() const { return maxRadius > minRadius && bool(maxRadius.v); }

	bool TryGetBandAtRadius(double radiusRatio, RingBand &outBand) const
	{
		if (!HasRings())
			return false;

		if (!bands.empty()) {
			for (const RingBand &b : bands) {
				if (radiusRatio >= b.minRadius.ToDouble() && radiusRatio <= b.maxRadius.ToDouble()) {
					outBand = b;
					return true;
				}
			}
			return false;
		}

		const double rMin = minRadius.ToDouble();
		const double rMax = maxRadius.ToDouble();
		if (radiusRatio < rMin || radiusRatio > rMax)
			return false;

		// Carve a Cassini-style division out of legacy/custom single-band definitions
		const double u = (radiusRatio - rMin) / std::max(1e-6, rMax - rMin);
		if (u > 0.585 && u < 0.625)
			return false;

		outBand.minRadius = minRadius;
		outBand.maxRadius = maxRadius;
		outBand.thickness = thickness;
		outBand.opticalDepth = fixed(9, 10);
		outBand.composition = composition;
		outBand.reserveGrade = reserveGrade;
		outBand.baseColor = baseColor;
		outBand.seedOffset = 0;
		return true;
	}

	static const char *GetCompositionName(RingComposition comp)
	{
		switch (comp) {
		case RingComposition::ICE_WATER: return "Icy (Water)";
		case RingComposition::ICE_AMMONIA_METHANE: return "Icy (Ammonia/Methane)";
		case RingComposition::ROCKY_SILICATE: return "Rocky";
		case RingComposition::METAL_RICH: return "Metal-Rich";
		case RingComposition::METALLIC_PRECIOUS: return "Metallic";
		default: return "Unknown";
		}
	}

	static const char *GetReserveGradeName(RingReserveGrade grade)
	{
		switch (grade) {
		case RingReserveGrade::DEPLETED: return "Depleted";
		case RingReserveGrade::LOW: return "Low";
		case RingReserveGrade::COMMON: return "Common";
		case RingReserveGrade::MAJOR: return "Major";
		case RingReserveGrade::PRISTINE: return "Pristine";
		default: return "Common";
		}
	}

	static double GetReserveMultiplier(RingReserveGrade grade)
	{
		switch (grade) {
		case RingReserveGrade::DEPLETED: return 0.4;
		case RingReserveGrade::LOW: return 0.7;
		case RingReserveGrade::COMMON: return 1.0;
		case RingReserveGrade::MAJOR: return 1.45;
		case RingReserveGrade::PRISTINE: return 2.0;
		default: return 1.0;
		}
	}
};

#endif /* _RINGSTYLE_H */

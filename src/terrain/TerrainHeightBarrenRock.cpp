// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "Terrain.h"
#include "TerrainFeature.h"
#include "TerrainNoise.h"
#include "../galaxy/SystemBody.h"

#include <algorithm>

using namespace TerrainNoise;
using namespace TerrainFeature;

// Stratified rocky mesas, terraced canyon benches, ridged mountain belts, and wide drivable basin floors (or oceanic archipelagos)

template <>
const char *TerrainHeightFractal<TerrainHeightBarrenRock>::GetHeightFractalName() const { return "Barren Rock"; }

template <>
TerrainHeightFractal<TerrainHeightBarrenRock>::TerrainHeightFractal(const SystemBody *body) :
	Terrain(body)
{
	const double planetRad = body->GetRadius();
	const double sealevel = Clamp(body->GetVolatileLiquid(), 0.0, 1.0);
	const bool isOceanWorld = sealevel >= 0.45;
	const double minOct = std::clamp(planetRad * 0.000015, 12.0, 60.0);
	// Macro continents/archipelagos, basins & plateaus
	const double macroW = isOceanWorld ? std::min(planetRad * 0.25, 1800000.0) : std::min(planetRad * 0.70, 5000000.0);
	// Ridged mountain ranges & volcanic island spines
	const double ridgeW = isOceanWorld ? std::min(planetRad * 0.08, 480000.0) : std::min(planetRad * 0.24, 900000.0);
	SetFracDef(0, m_maxHeightInMeters * 0.55, macroW, minOct * 8.0);
	SetFracDef(1, m_maxHeightInMeters * 0.35, ridgeW, minOct * 2.0);
	// Drivable regolith / rolling plains micro-relief (capped in km so super-Earths keep ground relief)
	SetFracDef(2, m_maxHeightInMeters * 0.06, std::min(planetRad * 0.025, 90000.0), minOct);
	// Biome / colour noise fracdefs read by TerrainColorTFPoor / TFGood / Rock
	SetFracDef(3, m_maxHeightInMeters * 0.35, std::min(planetRad * 0.35, 1800000.0), minOct * 4.0);
	SetFracDef(4, m_maxHeightInMeters * 0.12, std::min(planetRad * 0.08, 250000.0), minOct * 2.0);
	SetFracDef(5, m_maxHeightInMeters * 0.06, std::min(planetRad * 0.02, 60000.0), minOct);
	SetFracDef(8, m_maxHeightInMeters * 0.50, std::min(planetRad * 0.65, 3000000.0), minOct * 6.0);
}

template <>
void TerrainHeightFractal<TerrainHeightBarrenRock>::GetHeights(const vector3d *vP, double *heightsOut, const size_t count) const
{
	const bool hasSea = m_sealevel > 0.01;
	const bool isOceanWorld = m_sealevel >= 0.45;
	const double seaThresh = hasSea ? (0.29 + 0.415 * m_sealevel) : 0.0;
	const double islandElevScale = hasSea ? (1.0 - 0.55 * m_sealevel) : 1.0;
	const double craterScale = hasSea ? std::max(0.08, 1.0 - m_sealevel * 0.90) : 1.0;

	for (size_t i = 0; i < count; i++) {
		const vector3d &p = vP[i];
		const double macro = octavenoise(m_fracdef[0], 0.50, p);
		const double island = isOceanWorld ? (octavenoise(m_fracdef[1], 0.52, p) - 0.5) * 0.30 : 0.0;
		const double landSignal = macro + island;

		double h = 0.0;
		double highlandMask = 0.0;
		double coastMask = 1.0;

		if (hasSea) {
			const double continent = landSignal - seaThresh;
			if (continent <= 0.0) {
				heightsOut[i] = 0.0;
				continue;
			}
			coastMask = Clamp(continent / 0.05, 0.0, 1.0);
			// Coastal shelves rise gently from sea level into island plains & volcanic ridges
			const double shelf = continent * 1.45;
			h = smooth_basin_floor(shelf, 0.025, 0.02) * coastMask;
			highlandMask = Clamp((shelf - 0.08) / 0.16, 0.0, 1.0);
			h = h + (smooth_terrace(h, 0.10, 0.45) - h) * highlandMask * 0.45;
			const double ridges = ridged_octavenoise(m_fracdef[1], 0.48, p);
			h += ridges * ridges * 0.30 * highlandMask;
			h += multi_scale_craters(p, 4.2, 3, 0.09, 0.42, 0.18, m_seed ^ 0xB401u) * craterScale * coastMask;
			h += (octavenoise(m_fracdef[2], 0.48, p) - 0.5) * 0.035 * coastMask;
			h *= m_maxHeight * islandElevScale;
		} else {
			// Broad drivable basin floors near nominal datum, terraced sedimentary mesas above
			const double dryMacro = std::max(0.0, (macro - 0.20) * 0.82);
			h = smooth_basin_floor(dryMacro, 0.05, 0.045);
			highlandMask = Clamp((dryMacro - 0.18) / 0.22, 0.0, 1.0);
			// Gentle sedimentary terracing on plateaus & canyon walls
			h = h + (smooth_terrace(h, 0.10, 0.55) - h) * highlandMask * 0.55;
			// Ridged mountain belts concentrated in highlands
			const double ridges = ridged_octavenoise(m_fracdef[1], 0.48, p);
			h += ridges * ridges * 0.34 * highlandMask;
			// Sparse impact craters across basins and mesas
			h += multi_scale_craters(p, 4.2, 3, 0.09, 0.42, 0.18, m_seed ^ 0xB401u) * craterScale;
			// Gentle micro-undulations for realistic SRV/landing terrain
			h += (octavenoise(m_fracdef[2], 0.48, p) - 0.5) * 0.045;
			h *= m_maxHeight;
		}

		heightsOut[i] = Clamp(h, 0.0, m_maxHeight);
	}
}

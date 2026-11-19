// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "Terrain.h"
#include "TerrainFeature.h"
#include "TerrainNoise.h"
#include "../galaxy/SystemBody.h"

#include <algorithm>

using namespace TerrainNoise;
using namespace TerrainFeature;

// Ancient wind/impact-eroded highlands with wide alluvial plains and smooth rolling hills (or oceanic archipelagos)

template <>
const char *TerrainHeightFractal<TerrainHeightBarrenRock2>::GetHeightFractalName() const { return "Barren Rock 2"; }

template <>
TerrainHeightFractal<TerrainHeightBarrenRock2>::TerrainHeightFractal(const SystemBody *body) :
	Terrain(body)
{
	const double planetRad = body->GetRadius();
	const double sealevel = Clamp(body->GetVolatileLiquid(), 0.0, 1.0);
	const bool isOceanWorld = sealevel >= 0.45;
	const double minOct = std::clamp(planetRad * 0.000015, 12.0, 60.0);
	const double macroW = isOceanWorld ? std::min(planetRad * 0.25, 1800000.0) : std::min(planetRad * 0.72, 5000000.0);
	const double hillW = isOceanWorld ? std::min(planetRad * 0.08, 480000.0) : std::min(planetRad * 0.22, 850000.0);
	SetFracDef(0, m_maxHeightInMeters * 0.50, macroW, minOct * 8.0);
	SetFracDef(1, m_maxHeightInMeters * 0.28, hillW, minOct * 2.0);
	SetFracDef(2, m_maxHeightInMeters * 0.05, std::min(planetRad * 0.025, 90000.0), minOct);
	// Biome / colour noise fracdefs read by TerrainColorTFPoor / TFGood / Rock
	SetFracDef(3, m_maxHeightInMeters * 0.35, std::min(planetRad * 0.35, 1800000.0), minOct * 4.0);
	SetFracDef(4, m_maxHeightInMeters * 0.12, std::min(planetRad * 0.08, 250000.0), minOct * 2.0);
	SetFracDef(5, m_maxHeightInMeters * 0.06, std::min(planetRad * 0.02, 60000.0), minOct);
	SetFracDef(8, m_maxHeightInMeters * 0.50, std::min(planetRad * 0.65, 3000000.0), minOct * 6.0);
}

template <>
void TerrainHeightFractal<TerrainHeightBarrenRock2>::GetHeights(const vector3d *vP, double *heightsOut, const size_t count) const
{
	const bool hasSea = m_sealevel > 0.01;
	const bool isOceanWorld = m_sealevel >= 0.45;
	const double seaThresh = hasSea ? (0.29 + 0.415 * m_sealevel) : 0.0;
	const double islandElevScale = hasSea ? (1.0 - 0.55 * m_sealevel) : 1.0;
	const double craterScale = hasSea ? std::max(0.08, 1.0 - m_sealevel * 0.90) : 1.0;

	for (size_t i = 0; i < count; i++) {
		const vector3d &p = vP[i];
		const double macro = octavenoise(m_fracdef[0], 0.52, p);
		const double island = isOceanWorld ? (octavenoise(m_fracdef[1], 0.52, p) - 0.5) * 0.30 : 0.0;
		const double landSignal = macro + island;

		double h = 0.0;
		double hillMask = 0.0;
		double coastMask = 1.0;

		if (hasSea) {
			const double continent = landSignal - seaThresh;
			if (continent <= 0.0) {
				heightsOut[i] = 0.0;
				continue;
			}
			coastMask = Clamp(continent / 0.05, 0.0, 1.0);
			const double shelf = continent * 1.45;
			h = smooth_basin_floor(shelf, 0.025, 0.02) * coastMask;
			hillMask = Clamp((shelf - 0.08) / 0.16, 0.0, 1.0);
		} else {
			// Wide, smooth alluvial plains ideal for starports & SRV exploration near datum
			const double dryMacro = std::max(0.0, (macro - 0.20) * 0.82);
			h = smooth_basin_floor(dryMacro, 0.05, 0.045);
			hillMask = Clamp((dryMacro - 0.18) / 0.22, 0.0, 1.0);
		}

		// Eroded rolling hills and soft billowed dunes/hummocks
		const double hills = billow_octavenoise(m_fracdef[1], 0.44, p) * 0.24;
		h += hills * hillMask;

		// Softened ancient impact craters (weathered down on ocean worlds)
		h += multi_scale_craters(p, 3.6, 3, 0.075, 0.45, 0.12, m_seed ^ 0xB402u) * craterScale * (hasSea ? coastMask : 1.0);

		// Subtle drivable surface relief
		h += (octavenoise(m_fracdef[2], 0.46, p) - 0.5) * (hasSea ? 0.035 * coastMask : 0.042);

		h *= m_maxHeight * islandElevScale;
		heightsOut[i] = Clamp(h, 0.0, m_maxHeight);
	}
}

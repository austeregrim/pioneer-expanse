// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "Terrain.h"
#include "TerrainFeature.h"
#include "TerrainNoise.h"
#include "../galaxy/SystemBody.h"

#include <algorithm>

using namespace TerrainNoise;
using namespace TerrainFeature;

// Dramatic navigable tectonic canyons, fractured rocky highlands, and cratered flat-topped plateaus (or oceanic archipelagos)

template <>
const char *TerrainHeightFractal<TerrainHeightBarrenRock3>::GetHeightFractalName() const { return "Barren Rock 3"; }

template <>
TerrainHeightFractal<TerrainHeightBarrenRock3>::TerrainHeightFractal(const SystemBody *body) :
	Terrain(body)
{
	const double planetRad = body->GetRadius();
	const double sealevel = Clamp(body->GetVolatileLiquid(), 0.0, 1.0);
	const bool isOceanWorld = sealevel >= 0.45;
	const double minOct = std::clamp(planetRad * 0.000015, 12.0, 60.0);
	const double macroW = isOceanWorld ? std::min(planetRad * 0.25, 1800000.0) : std::min(planetRad * 0.70, 5000000.0);
	const double faultW = isOceanWorld ? std::min(planetRad * 0.08, 480000.0) : std::min(planetRad * 0.32, 1100000.0);
	// Plateau / archipelago elevation
	SetFracDef(0, m_maxHeightInMeters * 0.55, macroW, minOct * 8.0);
	// Canyon network (tectonic fault valleys & island ridges)
	SetFracDef(1, m_maxHeightInMeters * 0.38, faultW, minOct * 2.0);
	// Secondary highland ridges
	SetFracDef(2, m_maxHeightInMeters * 0.22, std::min(planetRad * 0.16, 600000.0), minOct * 2.0);
	// Drivable canyon floor & plateau micro-relief (and biome noise defs read by TFPoor / TFGood / Rock)
	SetFracDef(3, m_maxHeightInMeters * 0.04, std::min(planetRad * 0.025, 90000.0), minOct);
	SetFracDef(4, m_maxHeightInMeters * 0.12, std::min(planetRad * 0.08, 250000.0), minOct * 2.0);
	SetFracDef(5, m_maxHeightInMeters * 0.06, std::min(planetRad * 0.02, 60000.0), minOct);
	SetFracDef(8, m_maxHeightInMeters * 0.50, std::min(planetRad * 0.65, 3000000.0), minOct * 6.0);
}

template <>
void TerrainHeightFractal<TerrainHeightBarrenRock3>::GetHeights(const vector3d *vP, double *heightsOut, const size_t count) const
{
	const bool hasSea = m_sealevel > 0.01;
	const bool isOceanWorld = m_sealevel >= 0.45;
	const double seaThresh = hasSea ? (0.29 + 0.415 * m_sealevel) : 0.0;
	const double islandElevScale = hasSea ? (1.0 - 0.55 * m_sealevel) : 1.0;
	const double craterScale = hasSea ? std::max(0.08, 1.0 - m_sealevel * 0.90) : 1.0;

	for (size_t i = 0; i < count; i++) {
		const vector3d &p = vP[i];
		const double macro = octavenoise(m_fracdef[0], 0.48, p);
		const double island = isOceanWorld ? (octavenoise(m_fracdef[1], 0.52, p) - 0.5) * 0.30 : 0.0;
		const double landSignal = macro + island;

		double h = 0.0;
		double canyonMask = 1.0;
		double coastMask = 1.0;

		if (hasSea) {
			const double continent = landSignal - seaThresh;
			if (continent <= 0.0) {
				heightsOut[i] = 0.0;
				continue;
			}
			coastMask = Clamp(continent / 0.05, 0.0, 1.0);
			h = smooth_basin_floor(continent * 1.45, 0.025, 0.02) * coastMask;
			canyonMask = Clamp((h - 0.08) / 0.14, 0.0, 1.0);
		} else {
			// Elevated plateau base with smooth basin floors near datum
			const double dryMacro = std::max(0.0, (macro - 0.18) * 0.85);
			h = smooth_basin_floor(dryMacro, 0.06, 0.045);
			canyonMask = Clamp((h - 0.08) / 0.14, 0.0, 1.0);
		}

		// Carve dramatic Valles Marineris-style navigable canyons along ridged fault lines
		const double fault = ridged_octavenoise(m_fracdef[1], 0.46, p);
		if (fault > 0.62 && canyonMask > 0.01) {
			const double t = Clamp((fault - 0.62) / 0.26, 0.0, 1.0);
			const double s = t * t * (3.0 - 2.0 * t);
			h -= s * 0.26 * canyonMask;
		}
		if (!hasSea) {
			// Keep canyon bottoms flat & drivable above a clean floor on dry worlds
			h = smooth_basin_floor(h, 0.05, 0.03);
		}

		// Ridged highland crests outside canyons
		const double plateauMask = Clamp((h - 0.14) / 0.18, 0.0, 1.0);
		const double ridges = ridged_octavenoise(m_fracdef[2], 0.48, p) * 0.22 * plateauMask;
		h += ridges;

		// Multi-scale impact craters (weathered down on ocean worlds)
		h += multi_scale_craters(p, 4.0, 3, 0.095, 0.50, 0.20, m_seed ^ 0xB403u) * craterScale * (hasSea ? coastMask : 1.0);

		// Gentle drivable micro-relief
		h += (octavenoise(m_fracdef[3], 0.46, p) - 0.5) * (hasSea ? 0.035 * coastMask : 0.042);

		h *= m_maxHeight * islandElevScale;
		heightsOut[i] = Clamp(h, 0.0, m_maxHeight);
	}
}

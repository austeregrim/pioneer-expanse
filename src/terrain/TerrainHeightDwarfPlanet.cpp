// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "Terrain.h"
#include "TerrainFeature.h"
#include "TerrainNoise.h"

using namespace TerrainNoise;
using namespace TerrainFeature;

// Cratered dwarf planets & rocky/icy sub-satellites (Ceres, Pluto, Charon, Europa, Lunar-scale bodies)
// Combines flooded maria / cryo-ice plains (smooth & drivable) with heavily cratered highlands and tectonic rifts.

template <>
const char *TerrainHeightFractal<TerrainHeightDwarfPlanet>::GetHeightFractalName() const { return "DwarfPlanet"; }

template <>
TerrainHeightFractal<TerrainHeightDwarfPlanet>::TerrainHeightFractal(const SystemBody *body) :
	Terrain(body)
{
	const double minOct = std::max(8.0, m_planetRadius * 0.00015);
	// Macro basins & highlands
	SetFracDef(0, m_maxHeightInMeters * 0.50, m_planetRadius * 0.95, minOct * 8.0);
	// Tectonic rifts / cryovolcanic linea
	SetFracDef(1, m_maxHeightInMeters * 0.16, m_planetRadius * 0.28, minOct * 2.0);
	// Gentle rolling regolith micro-relief (drivable slopes)
	SetFracDef(2, m_maxHeightInMeters * 0.05, m_planetRadius * 0.07, minOct);

	m_quatDefs[0].SetAxisAngle(m_rand.Double(0.0, DEG2RAD(360.0)), GetVector3Random(m_rand));
}

template <>
void TerrainHeightFractal<TerrainHeightDwarfPlanet>::GetHeights(const vector3d *vP, double *heightsOut, const size_t count) const
{
	const double iceFactor = Clamp(m_icyness, 0.0, 1.0);
	// Icy dwarf planets have shallower relaxed craters and wider smooth cryo-plains
	const double craterDepth = (0.16 - 0.06 * iceFactor);
	const double craterDensity = (0.62 - 0.18 * iceFactor);
	const double basinFloor = 0.26 + 0.12 * iceFactor;

	for (size_t i = 0; i < count; i++) {
		const vector3d &p = vP[i];

		// Macro highlands vs. broad flooded basins / Sputnik Planitia-style plains
		const double macro = octavenoise(m_fracdef[0], 0.50, p);
		// Smoothly flatten low basins into landable/drivable plains while keeping highlands elevated
		double h = smooth_basin_floor(macro * 0.72, basinFloor, 0.075);

		// Mask: 0.0 inside smooth flooded basins, 1.0 in ancient highlands
		const double highlandMask = Clamp((macro * 0.72 - basinFloor) / 0.22, 0.0, 1.0);

		// Multi-scale true cellular impact craters (denser & deeper on highlands, sparse/fresh on flooded basins)
		const double craterMod = 0.30 + 0.70 * highlandMask;
		h += multi_scale_craters(p, 3.8, 4, craterDepth * craterMod, craterDensity, 0.28, m_seed ^ 0xD4AFu);

		// Cryovolcanic fracture rifts (linea/chasma) appear regionally on icy cryo-moons only
		// (avoids unnatural global scarring lines on rocky dwarf planets)
		if (iceFactor > 0.40) {
			const vector3d q = m_quatDefs[0] * p;
			const double regionMask = Clamp((octavenoise(m_fracdef[0], 0.48, q * 1.35 + vector3d(3.1, -1.7, 2.4)) - 0.56) * 3.5, 0.0, 1.0);
			if (regionMask > 0.01) {
				const double riftNoise = ridged_octavenoise(m_fracdef[1], 0.45, q);
				if (riftNoise > 0.80) {
					const double t = (riftNoise - 0.80) / 0.20;
					const double iceWeight = Clamp((iceFactor - 0.40) / 0.45, 0.0, 1.0);
					const double riftDepth = 0.095 * iceWeight * regionMask * t * t * (3.0 - 2.0 * t);
					h -= riftDepth;
				}
			}
		}

		// Subtle rolling regolith & ejecta hummocks (gentle enough for ship landing & SRV driving)
		const double micro = (octavenoise(m_fracdef[2], 0.46, p) - 0.5) * (0.045 - 0.015 * iceFactor);
		h += micro;

		h *= m_maxHeight;
		heightsOut[i] = Clamp(h, 0.0, m_maxHeight);
	}
}

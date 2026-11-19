// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "Terrain.h"
#include "TerrainFeature.h"
#include "TerrainNoise.h"

using namespace TerrainNoise;
using namespace TerrainFeature;

// Bilobed contact-binary comet / asteroid archetype (67P / Arrokoth / Itokawa)

template <>
const char *TerrainHeightFractal<TerrainHeightAsteroid3>::GetHeightFractalName() const { return "Asteroid3"; }

template <>
TerrainHeightFractal<TerrainHeightAsteroid3>::TerrainHeightFractal(const SystemBody *body) :
	Terrain(body)
{
	m_quatDefs[0].SetAxisAngle(m_rand.Double(0.0, DEG2RAD(360.0)), GetVector3Random(m_rand));

	const double minOct = std::max(2.0, m_planetRadius * 0.002);
	SetFracDef(0, m_maxHeightInMeters * 0.16, m_planetRadius * 0.85, minOct * 4.0);
	SetFracDef(1, m_maxHeightInMeters * 0.09, m_planetRadius * 0.24, minOct);
	SetFracDef(2, m_maxHeightInMeters * 0.04, m_planetRadius * 0.10, minOct);
}

template <>
void TerrainHeightFractal<TerrainHeightAsteroid3>::GetHeights(const vector3d *vP, double *heightsOut, const size_t count) const
{
	const double shapeScale = std::min(m_maxHeight, 0.55);
	const double craterScale = std::min(m_maxHeight * 0.18, 0.08);

	for (size_t i = 0; i < count; i++) {
		const vector3d &p = vP[i];
		const vector3d q = m_quatDefs[0] * p;

		// Contact-binary bilobed silhouette: two asymmetric lobes along X with a pinched neck near x = 0
		const double ax = fabs(q.x);
		const double lobeAsym = (q.x > 0.0) ? 1.0 : 0.78;
		const double neckPinch = exp(-q.x * q.x * 9.5);
		const double bilobe = 0.28 + 0.52 * (ax * ax) * lobeAsym - 0.24 * neckPinch + 0.08 * (q.y * q.y - q.z * q.z);

		const double macro = (octavenoise(m_fracdef[0], 0.5, p) - 0.5) * 0.28;
		double h = (bilobe + macro) * shapeScale;

		// Angular cliffs, terraced scarps, and rubble-pile boulders
		const double cliffs = (ridged_octavenoise(m_fracdef[1], 0.5, p) - 0.45) * shapeScale * 0.14;
		const double rubble = (octavenoise(m_fracdef[2], 0.52, p) - 0.5) * shapeScale * 0.06;
		h += cliffs + rubble;

		// Impact pits & sublimation depressions
		h += multi_scale_craters(p, 3.2, 3, craterScale, 0.48, 0.0, m_seed ^ 0x67C0u);

		heightsOut[i] = Clamp(h, 0.0, m_maxHeight);
	}
}

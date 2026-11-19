// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "Terrain.h"
#include "TerrainFeature.h"
#include "TerrainNoise.h"

using namespace TerrainNoise;
using namespace TerrainFeature;

// Heavily cratered rocky protoplanet / Vesta archetype (oblate spheroid + polar impact basin + dense craters)

template <>
const char *TerrainHeightFractal<TerrainHeightAsteroid2>::GetHeightFractalName() const { return "Asteroid2"; }

template <>
TerrainHeightFractal<TerrainHeightAsteroid2>::TerrainHeightFractal(const SystemBody *body) :
	Terrain(body)
{
	m_quatDefs[0].SetAxisAngle(m_rand.Double(0.0, DEG2RAD(360.0)), GetVector3Random(m_rand));

	const double minOct = std::max(2.0, m_planetRadius * 0.002);
	SetFracDef(0, m_maxHeightInMeters * 0.14, m_planetRadius * 0.9, minOct * 4.0);
	SetFracDef(1, m_maxHeightInMeters * 0.08, m_planetRadius * 0.28, minOct);
	SetFracDef(2, m_maxHeightInMeters * 0.04, m_planetRadius * 0.12, minOct);
}

template <>
void TerrainHeightFractal<TerrainHeightAsteroid2>::GetHeights(const vector3d *vP, double *heightsOut, const size_t count) const
{
	const double shapeScale = std::min(m_maxHeight, 0.34);
	const double craterScale = std::min(m_maxHeight * 0.30, 0.12);

	for (size_t i = 0; i < count; i++) {
		const vector3d &p = vP[i];
		const vector3d q = m_quatDefs[0] * p;

		// Oblate protoplanet bulge (wider equator, slightly flattened poles)
		const double oblate = 0.54 + 0.18 * (1.0 - q.y * q.y) + 0.08 * (q.x * q.x - q.z * q.z);
		const double highlands = (octavenoise(m_fracdef[0], 0.52, p) - 0.5) * 0.32;

		double h = (oblate + highlands) * shapeScale;

		// Rheasilvia-style southern polar mega-basin with central peak
		if (q.y < -0.55) {
			const double u = Clamp((1.0 + q.y) / 0.45, 0.0, 1.0); // 0 at south pole, 1 at rim
			const double bowl = (u * u - 1.0) * 0.72;
			const double rim = 0.28 * u * u * u * u;
			const double peak = 0.32 * exp(-u * u * 18.0);
			h += (bowl + rim + peak) * shapeScale * 0.42;
		}

		// Dense multi-scale impact craters with central peaks on largest impacts
		h += multi_scale_craters(p, 3.0, 4, craterScale, 0.65, 0.25, m_seed ^ 0xB357u);

		// Ejecta ridges and rocky micro-relief
		const double ridges = (ridged_octavenoise(m_fracdef[1], 0.48, p) - 0.4) * shapeScale * 0.09;
		const double detail = (octavenoise(m_fracdef[2], 0.5, p) - 0.5) * shapeScale * 0.05;
		h += ridges + detail;

		heightsOut[i] = Clamp(h, 0.0, m_maxHeight);
	}
}

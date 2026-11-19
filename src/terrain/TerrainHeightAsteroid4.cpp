// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "Terrain.h"
#include "TerrainFeature.h"
#include "TerrainNoise.h"

using namespace TerrainNoise;
using namespace TerrainFeature;

// Shattered angular metallic / silicate monolith asteroid (Psyche / Eros archetype)

template <>
const char *TerrainHeightFractal<TerrainHeightAsteroid4>::GetHeightFractalName() const { return "Asteroid4"; }

template <>
TerrainHeightFractal<TerrainHeightAsteroid4>::TerrainHeightFractal(const SystemBody *body) :
	Terrain(body)
{
	m_quatDefs[0].SetAxisAngle(m_rand.Double(0.0, DEG2RAD(360.0)), GetVector3Random(m_rand));

	const double minOct = std::max(2.0, m_planetRadius * 0.002);
	SetFracDef(0, m_maxHeightInMeters * 0.18, m_planetRadius * 0.75, minOct * 4.0);
	SetFracDef(1, m_maxHeightInMeters * 0.12, m_planetRadius * 0.26, minOct);
	SetFracDef(2, m_maxHeightInMeters * 0.05, m_planetRadius * 0.11, minOct);
}

template <>
void TerrainHeightFractal<TerrainHeightAsteroid4>::GetHeights(const vector3d *vP, double *heightsOut, const size_t count) const
{
	const double shapeScale = std::min(m_maxHeight, 0.46);
	const double craterScale = std::min(m_maxHeight * 0.24, 0.10);

	for (size_t i = 0; i < count; i++) {
		const vector3d &p = vP[i];
		const vector3d q = m_quatDefs[0] * p;

		// Angular faceted elongation
		const double base = 0.44 + 0.26 * (q.x * q.x) - 0.14 * (q.y * q.y) + 0.08 * fabs(q.z);
		// Sharp planar facets & fracture scarps
		const double facet = ridged_octavenoise(m_fracdef[0], 0.48, q) * 0.34;
		const double crags = ridged_octavenoise(m_fracdef[1], 0.52, p) * 0.14;
		const double fine = (octavenoise(m_fracdef[2], 0.5, p) - 0.5) * 0.06;

		double h = (base + facet + crags + fine - 0.20) * shapeScale;

		// Crisp metallic impact craters
		h += multi_scale_craters(p, 2.8, 3, craterScale, 0.52, 0.15, m_seed ^ 0xE205u);

		heightsOut[i] = Clamp(h, 0.0, m_maxHeight);
	}
}

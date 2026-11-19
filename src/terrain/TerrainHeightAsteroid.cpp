// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "Terrain.h"
#include "TerrainFeature.h"
#include "TerrainNoise.h"

using namespace TerrainNoise;
using namespace TerrainFeature;

// Triaxial / oblate potato asteroid moon (Phobos / Deimos archetype) with Stickney-style basin & multi-scale craters

template <>
const char *TerrainHeightFractal<TerrainHeightAsteroid>::GetHeightFractalName() const { return "Asteroid"; }

template <>
TerrainHeightFractal<TerrainHeightAsteroid>::TerrainHeightFractal(const SystemBody *body) :
	Terrain(body)
{
	// Random triaxial orientation
	m_quatDefs[0].SetAxisAngle(m_rand.Double(0.0, DEG2RAD(360.0)), GetVector3Random(m_rand));
	// Direction of signature large impact basin
	m_quatDefs[1].SetAxisAngle(m_rand.Double(0.0, DEG2RAD(360.0)), GetVector3Random(m_rand));

	const double minOct = std::max(2.0, m_planetRadius * 0.002);
	SetFracDef(0, m_maxHeightInMeters * 0.18, m_planetRadius * 1.1, minOct * 4.0);
	SetFracDef(1, m_maxHeightInMeters * 0.08, m_planetRadius * 0.32, minOct);
	SetFracDef(2, m_maxHeightInMeters * 0.04, m_planetRadius * 0.14, minOct);
}

template <>
void TerrainHeightFractal<TerrainHeightAsteroid>::GetHeights(const vector3d *vP, double *heightsOut, const size_t count) const
{
	// Scale irregular triaxial amplitude based on m_maxHeight (stronger on smaller bodies)
	const double shapeScale = std::min(m_maxHeight, 0.42);
	const double craterScale = std::min(m_maxHeight * 0.26, 0.11);

	for (size_t i = 0; i < count; i++) {
		const vector3d &p = vP[i];
		const vector3d q = m_quatDefs[0] * p;

		// Triaxial potato base shape: elongated along X, slightly compressed along Z
		const double triaxial = 0.50 + 0.34 * (q.x * q.x) + 0.14 * (q.y * q.y) - 0.18 * (q.z * q.z);
		const double macroLump = (octavenoise(m_fracdef[0], 0.5, p) - 0.5) * 0.42;

		double h = (triaxial + macroLump) * shapeScale;

		// Signature Stickney-style giant impact basin
		const vector3d basinDir = m_quatDefs[1] * vector3d(1.0, 0.0, 0.0);
		const double dotB = Clamp(p.Dot(basinDir), -1.0, 1.0);
		const double ang = acos(dotB);
		constexpr double basinR = 0.42; // ~24 deg angular radius
		if (ang < basinR * 1.4) {
			const double u = ang / basinR;
			if (u < 1.0) {
				const double bowl = (u * u - 1.0) * 0.85;
				const double rim = 0.24 * u * u * u * u;
				h += (bowl + rim) * shapeScale * 0.38;
			} else {
				const double t = (1.4 - u) / 0.4;
				h += 0.24 * t * t * (3.0 - 2.0 * t) * shapeScale * 0.38;
			}
		}

		// Multi-scale cellular impact craters across the body
		h += multi_scale_craters(p, 2.6, 3, craterScale, 0.58, 0.0, m_seed ^ 0xA571u);

		// Subtle Phobos-like surface grooves and regolith micro-relief
		const double grooves = (ridged_octavenoise(m_fracdef[1], 0.48, q * vector3d(1.0, 1.6, 1.0)) - 0.5) * shapeScale * 0.06;
		const double regolith = (octavenoise(m_fracdef[2], 0.5, p) - 0.5) * shapeScale * 0.05;
		h += grooves + regolith;

		heightsOut[i] = Clamp(h, 0.0, m_maxHeight);
	}
}

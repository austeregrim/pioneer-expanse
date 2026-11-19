// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "Terrain.h"
#include "TerrainNoise.h"

using namespace TerrainNoise;

template <>
const char *TerrainColorFractal<TerrainColorAsteroid>::GetColorFractalName() const { return "Asteroid"; }

template <>
TerrainColorFractal<TerrainColorAsteroid>::TerrainColorFractal(const SystemBody *body) :
	Terrain(body)
{
}

template <>
vector3d TerrainColorFractal<TerrainColorAsteroid>::GetColor(const vector3d &p, double height, const vector3d &norm) const
{
	const double hNorm = Clamp(m_invMaxHeight * height, 0.0, 1.0);
	const double flatness = Clamp(p.Dot(norm), 0.0, 1.0);
	const double steepness = Clamp(1.0 - pow(flatness, 4.0), 0.0, 1.0);

	// Space-weathered regolith vs freshly exposed crater walls and ridges
	const double regolithVar = octavenoise(6, 0.52, 2.1, p * 4.5);
	const double mineralBand = octavenoise(5, 0.5, 2.0, p * 1.8 + vector3d(0.0, hNorm * 1.5, 0.0));

	const vector3d darkRegolith = m_darkrockColor[0] * 0.65 + m_greyrockColor[0] * 0.25;
	const vector3d midRegolith = interpolate_color(mineralBand, m_greyrockColor[1] * 0.85, m_rockColor[0] * 0.82);
	const vector3d freshRock = interpolate_color(regolithVar, m_greyrockColor[2] * 1.08, m_rockColor[2] * 1.05);

	// Deeper basins collect darker weathered dust; higher ridges & crater rims expose brighter silicate/iron
	vector3d col = interpolate_color(Clamp(hNorm * 1.35 + (regolithVar - 0.5) * 0.25, 0.0, 1.0), darkRegolith, midRegolith);
	col = interpolate_color(steepness, col, freshRock);

	// Subtle frost/bright mineral glint on icy asteroids
	if (m_icyness > 0.25) {
		const double frostMask = Clamp((m_icyness - 0.25) * 1.2 * (0.4 + 0.6 * steepness) * regolithVar, 0.0, 0.75);
		col = interpolate_color(frostMask, col, vector3d(0.82, 0.86, 0.92));
	}

	return col;
}

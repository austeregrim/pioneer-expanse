// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "Terrain.h"
#include "TerrainNoise.h"

using namespace TerrainNoise;

template <>
const char *TerrainColorFractal<TerrainColorDwarfPlanet>::GetColorFractalName() const { return "DwarfPlanet"; }

template <>
TerrainColorFractal<TerrainColorDwarfPlanet>::TerrainColorFractal(const SystemBody *body) :
	Terrain(body)
{
}

template <>
vector3d TerrainColorFractal<TerrainColorDwarfPlanet>::GetColor(const vector3d &p, double height, const vector3d &norm) const
{
	const double hNorm = Clamp(m_invMaxHeight * height, 0.0, 1.0);
	const double flatness = Clamp(p.Dot(norm), 0.0, 1.0);
	const double steepness = Clamp(1.0 - pow(flatness, 5.0), 0.0, 1.0);
	const double iceFactor = Clamp(m_icyness, 0.0, 1.0);

	const double regional = octavenoise(6, 0.52, 2.0, p * 3.2);
	const double fineDust = octavenoise(5, 0.50, 2.2, p * 14.0);

	if (iceFactor > 0.45) {
		// Icy dwarf planet / cryo-moon (Pluto / Europa / Enceladus palette)
		const vector3d cryoPlain(0.84, 0.89, 0.95);
		const vector3d dirtyIce = interpolate_color(regional, vector3d(0.62, 0.68, 0.76), vector3d(0.76, 0.72, 0.68));
		// Tholin-stained dark highlands (Pluto Cthulhu Macula / Charon Mordor Macula style)
		const vector3d tholinDark = interpolate_color(fineDust, m_darkrockColor[0] * 0.7 + vector3d(0.22, 0.11, 0.08), m_rockColor[1] * 0.65);
		const vector3d freshIceCliff(0.90, 0.95, 1.00);

		const double plainMask = Clamp((0.36 - hNorm) / 0.14, 0.0, 1.0);
		vector3d col = interpolate_color(Clamp((hNorm - 0.30) * 2.2, 0.0, 1.0), dirtyIce, tholinDark);
		col = interpolate_color(plainMask, col, cryoPlain);
		// Bright exposed crystalline ice on steep chasma walls and crater rims
		col = interpolate_color(steepness * 0.85, col, freshIceCliff);
		// Polar frost caps
		const double polar = Clamp((fabs(p.y) - 0.68) * 3.2, 0.0, 1.0);
		col = interpolate_color(polar * 0.65, col, vector3d(0.92, 0.95, 0.99));
		return col;
	} else {
		// Rocky cratered dwarf planet / airless moon (Ceres / Moon / Mercury palette)
		const vector3d mareBasalt = interpolate_color(fineDust, m_darkrockColor[0] * 0.72, m_greyrockColor[0] * 0.48);
		const vector3d highlandDust = interpolate_color(regional, m_greyrockColor[1] * 0.82, m_rockColor[0] * 0.78);
		const vector3d freshEjecta = interpolate_color(fineDust, m_greyrockColor[2] * 1.12, vector3d(0.85, 0.84, 0.82));

		// Smooth low basins are darker basaltic maria; highlands are brighter regolith
		const double highlandBlend = Clamp((hNorm - 0.28) / 0.24, 0.0, 1.0);
		vector3d col = interpolate_color(highlandBlend, mareBasalt, highlandDust);
		// Fresh bright rock & ejecta exposed on crater rims, central peaks, and steep walls
		col = interpolate_color(steepness * 0.90, col, freshEjecta);

		// Subtle icy frost in polar shadow / high-ice rocky worlds
		if (iceFactor > 0.15) {
			const double polarIce = Clamp((fabs(p.y) - 0.75) * 4.0 * iceFactor * 2.0, 0.0, 0.7);
			col = interpolate_color(polarIce, col, vector3d(0.86, 0.90, 0.96));
		}
		return col;
	}
}

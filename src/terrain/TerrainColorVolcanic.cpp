// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "Terrain.h"
#include "TerrainNoise.h"

using namespace TerrainNoise;

template <>
const char *TerrainColorFractal<TerrainColorVolcanic>::GetColorFractalName() const { return "Volcanic"; }

template <>
TerrainColorFractal<TerrainColorVolcanic>::TerrainColorFractal(const SystemBody *body) :
	Terrain(body)
{
	// percent chance of there being exposed lava based on planets volcanicity
	if (m_rand.Double(1.0) > (1.0 - m_volcanic)) {
		m_surfaceEffects |= Terrain::EFFECT_LAVA;
	}

	SetFracDef(0, m_maxHeightInMeters, m_rand.Double(1e6, 1e7));
}

template <>
vector3d TerrainColorFractal<TerrainColorVolcanic>::GetColor(const vector3d &p, double height, const vector3d &norm) const
{
	const double n = Clamp(m_invMaxHeight * height, 0.0, 1.0);
	const double flatness = pow(Clamp(p.Dot(norm), 0.0, 1.0), 6.0);
	const double equator = Clamp(1.0 - p.y * p.y, 0.0, 1.0);
	const double detail = octavenoise(m_fracdef[0], 0.5, (0.35 + n * 1.8) * p);

	// Smooth continuous volcanic strata from dark basalt lowlands to warm ash/ochre highlands
	vector3d colBasalt = interpolate_color(detail, m_darkrockColor[0], m_rockColor[0]);
	vector3d colPlains = interpolate_color(detail, m_rockColor[1], vector3d(0.42, 0.26, 0.14));
	vector3d colHigh = interpolate_color(detail, m_rockColor[2], vector3d(0.50, 0.32, 0.20));

	vector3d col = interpolate_color(Clamp(n * 3.0, 0.0, 1.0), colBasalt, colPlains);
	col = interpolate_color(Clamp((n - 0.30) * 1.8, 0.0, 1.0), col, colHigh);
	col = interpolate_color(equator * 0.28, col, vector3d(0.48, 0.28, 0.14));
	col = interpolate_color(flatness, m_rockColor[2], col);

	if (m_surfaceEffects & Terrain::EFFECT_LAVA) {
		const double lavaNoise = octavenoise(m_fracdef[0], 0.55, p * 2.4);
		const double elevFactor = Clamp((0.28 - n) / 0.18, 0.0, 1.0);
		const double basinFactor = Clamp((lavaNoise - 0.42) / 0.22, 0.0, 1.0);
		const double lavaAmount = Clamp(elevFactor * basinFactor * (0.65 + 0.55 * m_volcanic), 0.0, 1.0);
		col = interpolate_color(lavaAmount, col, vector3d(0.98, 0.03, 0.0));
	}
	return col;
}

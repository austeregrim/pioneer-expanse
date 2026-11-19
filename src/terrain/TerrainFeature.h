// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef _TERRAINFEATURE_H
#define _TERRAINFEATURE_H

#include "../vector3.h"

struct fracdef_t;

namespace TerrainFeature {

	double canyon_ridged_function(const fracdef_t &def, const vector3d &p);
	double canyon2_ridged_function(const fracdef_t &def, const vector3d &p);
	double canyon3_ridged_function(const fracdef_t &def, const vector3d &p);
	double canyon_normal_function(const fracdef_t &def, const vector3d &p);
	double canyon2_normal_function(const fracdef_t &def, const vector3d &p);
	double canyon3_normal_function(const fracdef_t &def, const vector3d &p);
	double canyon_voronoi_function(const fracdef_t &def, const vector3d &p);
	double canyon2_voronoi_function(const fracdef_t &def, const vector3d &p);
	double canyon3_voronoi_function(const fracdef_t &def, const vector3d &p);
	double canyon_billow_function(const fracdef_t &def, const vector3d &p);
	double canyon2_billow_function(const fracdef_t &def, const vector3d &p);
	double canyon3_billow_function(const fracdef_t &def, const vector3d &p);
	double crater_function(const fracdef_t &def, const vector3d &p);
	double impact_crater_function(const fracdef_t &def, const vector3d &p);
	double volcano_function(const fracdef_t &def, const vector3d &p);
	double megavolcano_function(const fracdef_t &def, const vector3d &p);
	double river_function(const fracdef_t &def, const vector3d &p, int style = 0);

	// True spherical 3D cellular impact craters (parabolic/flat-floor bowl, raised rim, ejecta apron, optional central peak)
	double cellular_crater_layer(const vector3d &p, double frequency, double density, double depth, double rimHeight, double centralPeak = 0.0, uint32_t seedOffset = 0);
	double multi_scale_craters(const vector3d &p, double baseFreq, int layers, double baseDepth, double density, double centralPeakScale = 0.0, uint32_t seedOffset = 0);

	// C1-smooth basin/plain floor shaping for realistic landable & drivable terrain
	double smooth_basin_floor(double h, double floorLevel, double smoothness);
	double smooth_terrace(double h, double stepSize, double sharpness);

} // namespace TerrainFeature

#endif

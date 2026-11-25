#ifndef ATMOSPHEREPARAMETERS_H_INCLUDED
#define ATMOSPHEREPARAMETERS_H_INCLUDED

#include "Color.h"
#include "vector3.h"

#define DENSITY_STEPS 255

struct AtmosphereParameters {
	float atmosRadius;
	float atmosInvScaleHeight;
	float atmosDensity;
	float planetRadius;
	Color atmosCol;
	vector3d center;
	vector3f rayleighBeta = vector3f(3.8e-6f, 13.5e-6f, 33.1e-6f);
	float ozoneStrength = 0.0f;
	vector3f mieBeta = vector3f(21.0e-6f, 21.0e-6f, 21.0e-6f);
	float mieG = 0.76f;
	// Runtime per-frame weather modulation (populated in GeoSphere::Render)
	float weatherMieMult = 1.0f;
	float weatherOvercast = 0.0f;
	vector3f weatherMieTint = vector3f(1.0f, 1.0f, 1.0f);
	vector2f logDensityMap[DENSITY_STEPS + 1];
	float logDensityMapR[(DENSITY_STEPS + 1)*(DENSITY_STEPS + 1)];
	float logDensityMapM[(DENSITY_STEPS + 1)*(DENSITY_STEPS + 1)];
};

#endif // ATMOSPHEREPARAMETERS_H_INCLUDED

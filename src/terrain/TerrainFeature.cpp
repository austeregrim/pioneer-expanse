// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "FracDef.h"
#include "TerrainFeature.h"
#include "TerrainNoise.h"

using namespace TerrainNoise;

namespace TerrainFeature {

	namespace {
		inline double smooth_canyon_profile(double n, double outer, double inner, double inner2, double outer2)
		{
			if (n > outer2)
				return 1.0;
			if (n > inner2) {
				const double t = (n - inner2) / (outer2 - inner2);
				return t * t * (3.0 - 2.0 * t);
			}
			if (n > inner)
				return 0.0;
			if (n > outer) {
				const double t = (n - outer) / (inner - outer);
				return 1.0 - t * t * (3.0 - 2.0 * t);
			}
			return 1.0;
		}
	} // namespace

	// Creates small canyons (smoothstep walls, octave-capped to prevent jagged vertical aliasing)
	double canyon_ridged_function(const fracdef_t &def, const vector3d &p)
	{
		const int oct = std::min(def.octaves, 7);
		const double n = ridged_octavenoise(oct, 0.52, 2.0, def.frequency * p);
		return smooth_canyon_profile(n, 0.655, 0.708, 0.722, 0.775) * def.amplitude;
	}

	// Larger canyon (smoothstep sloped walls, octave-capped to avoid jagged drop-offs)
	double canyon2_ridged_function(const fracdef_t &def, const vector3d &p)
	{
		const int oct = std::min(def.octaves, 7);
		const double n = ridged_octavenoise(oct, 0.54, 2.0, def.frequency * p);
		return smooth_canyon_profile(n, 0.635, 0.700, 0.725, 0.790) * def.amplitude;
	}

	// Largest canyon (smoothstep sloped walls, octave-capped to avoid jagged drop-offs)
	double canyon3_ridged_function(const fracdef_t &def, const vector3d &p)
	{
		const int oct = std::min(def.octaves, 7);
		const double n = ridged_octavenoise(oct, 0.56, 2.0, def.frequency * p);
		return smooth_canyon_profile(n, 0.635, 0.700, 0.725, 0.790) * def.amplitude;
	}

	double canyon_normal_function(const fracdef_t &def, const vector3d &p)
	{
		const int oct = std::min(def.octaves, 7);
		const double n = octavenoise(oct, 0.54, 2.0, def.frequency * p);
		return smooth_canyon_profile(n, 0.655, 0.708, 0.722, 0.775) * def.amplitude;
	}

	double canyon2_normal_function(const fracdef_t &def, const vector3d &p)
	{
		const int oct = std::min(def.octaves, 7);
		const double n = octavenoise(oct, 0.56, 2.0, def.frequency * p);
		return smooth_canyon_profile(n, 0.635, 0.700, 0.725, 0.790) * def.amplitude;
	}

	double canyon3_normal_function(const fracdef_t &def, const vector3d &p)
	{
		const int oct = std::min(def.octaves, 7);
		const double n = octavenoise(oct, 0.585, 2.0, def.frequency * p);
		return smooth_canyon_profile(n, 0.635, 0.700, 0.725, 0.790) * def.amplitude;
	}

	double canyon_voronoi_function(const fracdef_t &def, const vector3d &p)
	{
		const int oct = std::min(def.octaves, 7);
		const double n = octavenoise(oct, 0.54, 2.0, def.frequency * p);
		return smooth_canyon_profile(n, 0.655, 0.708, 0.722, 0.775) * def.amplitude;
	}

	double canyon2_voronoi_function(const fracdef_t &def, const vector3d &p)
	{
		const int oct = std::min(def.octaves, 7);
		const double n = octavenoise(oct, 0.56, 2.0, def.frequency * p);
		return smooth_canyon_profile(n, 0.635, 0.700, 0.725, 0.790) * def.amplitude;
	}

	double canyon3_voronoi_function(const fracdef_t &def, const vector3d &p)
	{
		const int oct = std::min(def.octaves, 7);
		const double n = octavenoise(oct, 0.585, 2.0, def.frequency * p);
		return smooth_canyon_profile(n, 0.635, 0.700, 0.725, 0.790) * def.amplitude;
	}

	double canyon_billow_function(const fracdef_t &def, const vector3d &p)
	{
		const int oct = std::min(def.octaves, 7);
		const double n = octavenoise(oct, 0.54, 2.0, def.frequency * p);
		return smooth_canyon_profile(n, 0.655, 0.708, 0.722, 0.775) * def.amplitude;
	}

	double canyon2_billow_function(const fracdef_t &def, const vector3d &p)
	{
		const int oct = std::min(def.octaves, 7);
		const double n = octavenoise(oct, 0.56, 2.0, def.frequency * p);
		return smooth_canyon_profile(n, 0.635, 0.700, 0.725, 0.790) * def.amplitude;
	}

	double canyon3_billow_function(const fracdef_t &def, const vector3d &p)
	{
		const int oct = std::min(def.octaves, 7);
		const double n = octavenoise(oct, 0.585, 2.0, def.frequency * p);
		return smooth_canyon_profile(n, 0.635, 0.700, 0.725, 0.790) * def.amplitude;
	}

	/*double rock_function(const fracdef_t &def, const vector3d &p)
{
	double h;
	double n = octavenoise(def.octaves, 0.788, 2.0, def.frequency*p);
	constexpr double outer = 0.1;
	constexpr double inner = 0.3;
	constexpr double inner2 = 0.7;
	constexpr double outer2 = 0.9;
	if (n > outer2) {
		h = 0.0;
	} else if (n > inner2) {
		h = 1.0 - ((n-inner2)*(1.0/(outer2-inner2)));
	} else if (n > inner) {
		h = 1.0;
	} else if (n > outer) {
		h = 0.0+1.0*(n-outer)*(1.0/(inner-outer));
	} else {
		h = 0.0;
	}
	return h * def.amplitude;
}*/

	void crater_function_1pass(const vector3d &p, double &out, const double height)
	{
		double n = fabs(noise(p));
		constexpr double ejecta_outer = 0.6;
		constexpr double outer = 0.9;
		constexpr double inner = 0.94;
		constexpr double midrim = 0.93;
		if (n > inner) {
			//out = 0;
		} else if (n > midrim) {
			double hrim = inner - midrim;
			double descent = (hrim - (n - midrim)) / hrim;
			out += height * descent * descent;
		} else if (n > outer) {
			double hrim = midrim - outer;
			double ascent = (n - outer) / hrim;
			out += height * ascent * ascent;
		} else if (n > ejecta_outer) {
			// blow down walls of other craters too near this one,
			// so we don't have sharp transition
			//out *= (outer-n)/-(ejecta_outer-outer);
		}
	}

	// makes large and small craters across the entire planet.
	double crater_function(const fracdef_t &def, const vector3d &p)
	{
		double crater = 0.0;
		double sz = def.frequency;
		double max_h = def.amplitude;
		for (int i = 0; i < def.octaves; i++) {
			crater_function_1pass(sz * p, crater, max_h);
			sz *= 2.0;
			max_h *= 0.5;
		}
		return crater;
	}

	void impact_crater_function_1pass(const vector3d &p, double &out, const double height)
	{
		double n = fabs(noise(p));
		constexpr double ejecta_outer = 0.6;
		constexpr double outer = 0.9;
		constexpr double midrim = 0.93;
		double hrim;
		double descent;
		if (n > midrim) {
			out -= height;
		} else if (n > outer) {
			hrim = midrim - outer;
			descent = (n - outer) / hrim;
			out -= height * descent * descent;
		} else if (n > ejecta_outer) {
			// blow down walls of other craters too near this one,
			// so we don't have sharp transition
			//out *= (outer-n)/-(ejecta_outer-outer);
		}
	}

	// makes large and small craters across the entire planet.
	double impact_crater_function(const fracdef_t &def, const vector3d &p)
	{
		double crater = 0.0;
		double sz = def.frequency;
		double max_h = def.amplitude;
		for (int i = 0; i < def.octaves; i++) {
			impact_crater_function_1pass(sz * p, crater, max_h);
			sz *= 2.0;
			max_h *= 0.5;
		}
		return crater;
	}

	void volcano_function_1pass(const vector3d &p, double &out, const double height)
	{
		double n = fabs(noise(p));
		constexpr double ejecta_outer = 0.6;
		constexpr double outer = 0.9;
		constexpr double inner = 0.975;
		constexpr double midrim = 0.971;
		if (n > inner) {
			//out = 0;
		} else if (n > midrim) {
			double hrim = inner - midrim;
			double descent = (hrim - (n - midrim)) / hrim;
			out += height * descent;
		} else if (n > outer) {
			double hrim = midrim - outer;
			double ascent = (n - outer) / hrim;
			out += height * ascent * ascent;
		} else if (n > ejecta_outer) {
			// blow down walls of other craters too near this one,
			// so we don't have sharp transition
			out *= (outer - n) / -(ejecta_outer - outer);
		}
	}

	double volcano_function(const fracdef_t &def, const vector3d &p)
	{
		double crater = 0.0;
		double sz = def.frequency;
		double max_h = def.amplitude;
		for (int i = 0; i < def.octaves; i++) {
			volcano_function_1pass(sz * p, crater, max_h);
			sz *= 1.0; //frequency?
			max_h *= 0.4; // height??
		}
		return 3.0 * crater;
	}

	void megavolcano_function_1pass(const vector3d &p, double &out, const double height)
	{
		double n = fabs(noise(p));
		constexpr double ejecta_outer = 0.6;
		constexpr double outer = 0.76; //Radius
		constexpr double inner = 0.98;
		constexpr double midrim = 0.964;
		if (n > inner) {
			//out = 0;
		} else if (n > midrim) {
			double hrim = inner - midrim;
			double descent = (hrim - (n - midrim)) / hrim;
			out += height * descent;
		} else if (n > outer) {
			double hrim = midrim - outer;
			double ascent = (n - outer) / hrim;
			out += height * ascent * ascent;
		} else if (n > ejecta_outer) {
			// blow down walls of other craters too near this one,
			// so we don't have sharp transition
			out *= (outer - n) / -(ejecta_outer - outer);
		}
	}

	double megavolcano_function(const fracdef_t &def, const vector3d &p)
	{
		double crater = 0.0;
		double sz = def.frequency;
		double max_h = def.amplitude;
		for (int i = 0; i < def.octaves; i++) {
			megavolcano_function_1pass(sz * p, crater, max_h);
			sz *= 1.0; //frequency?
			max_h *= 0.15; // height??
		}
		return 4.0 * crater;
	}

	double river_function(const fracdef_t &def, const vector3d &p, int style)
	{
		assert(style >= 0 && style < 2);
		const int oct = std::min(def.octaves, 7);
		const double n = octavenoise(oct, 0.585, 2.0, def.frequency * p * 0.5);
		constexpr double outer[] = { 0.64, 0.01 };
		constexpr double inner[] = { 0.71, 0.49 };
		constexpr double inner2[] = { 0.72, 0.51 };
		constexpr double outer2[] = { 0.79, 0.99 };
		return smooth_canyon_profile(n, outer[style], inner[style], inner2[style], outer2[style]) * def.amplitude;
	}

	namespace {
		inline uint32_t cell_hash(int32_t x, int32_t y, int32_t z, uint32_t seed)
		{
			uint32_t h = static_cast<uint32_t>(x) * 374761393u +
				static_cast<uint32_t>(y) * 668265263u +
				static_cast<uint32_t>(z) * 2147483647u +
				seed * 1274126177u;
			h = (h ^ (h >> 13)) * 1274126177u;
			return h ^ (h >> 16);
		}

		inline double hash_to_unit(uint32_t h)
		{
			return static_cast<double>(h & 0x00FFFFFFu) * (1.0 / 16777216.0);
		}
	} // namespace

	double cellular_crater_layer(const vector3d &p, double frequency, double density, double depth, double rimHeight, double centralPeak, uint32_t seedOffset)
	{
		const vector3d q = p * frequency;
		const int32_t ix = static_cast<int32_t>(floor(q.x));
		const int32_t iy = static_cast<int32_t>(floor(q.y));
		const int32_t iz = static_cast<int32_t>(floor(q.z));

		double total = 0.0;

		for (int32_t dz = -1; dz <= 1; ++dz) {
			const int32_t cz = iz + dz;
			for (int32_t dy = -1; dy <= 1; ++dy) {
				const int32_t cy = iy + dy;
				for (int32_t dx = -1; dx <= 1; ++dx) {
					const int32_t cx = ix + dx;

					const uint32_t h0 = cell_hash(cx, cy, cz, seedOffset);
					if (hash_to_unit(h0) > density)
						continue;

					const uint32_t h1 = cell_hash(cx, cy, cz, seedOffset + 101u);
					const uint32_t h2 = cell_hash(cx, cy, cz, seedOffset + 211u);
					const uint32_t h3 = cell_hash(cx, cy, cz, seedOffset + 307u);
					const uint32_t h4 = cell_hash(cx, cy, cz, seedOffset + 409u);
					const uint32_t h5 = cell_hash(cx, cy, cz, seedOffset + 521u);

					// Jittered crater center inside cell [0.15, 0.85]
					const double centerX = static_cast<double>(cx) + 0.15 + 0.70 * hash_to_unit(h1);
					const double centerY = static_cast<double>(cy) + 0.15 + 0.70 * hash_to_unit(h2);
					const double centerZ = static_cast<double>(cz) + 0.15 + 0.70 * hash_to_unit(h3);

					const double rx = q.x - centerX;
					const double ry = q.y - centerY;
					const double rz = q.z - centerZ;
					const double d2 = rx * rx + ry * ry + rz * rz;

					// Crater radius in cell units [0.20, 0.42], ejecta extends to 1.48 * r (< 0.63, safely inside 3x3x3)
					const double r = 0.20 + 0.22 * hash_to_unit(h4);
					const double outerR = r * 1.48;
					if (d2 >= outerR * outerR)
						continue;

					// Per-crater geological age: 0.0 = fresh young impact, 1.0 = ancient eroded/slumped ghost crater
					const double age = hash_to_unit(h5);
					const double freshness = 1.0 - age;

					// Organic rim & wall perturbation so craters aren't sterile geometric circles
					const double warpAmt = 0.055 + 0.085 * age;
					const double organicWarp = noise(q * 2.6 + vector3d(11.3, 7.1, 5.9)) * warpAmt;
					const double uRaw = sqrt(d2) / r;
					// Fade warp smoothly to 0 at outer boundary so cell continuity remains C1-exact
					const double boundaryFade = Clamp((1.48 - uRaw) / 0.28, 0.0, 1.0);
					const double u = std::max(0.0, uRaw + organicWarp * boundaryFade);

					// Scale depth and rim with both crater radius and geological age
					const double sizeScale = r / 0.36;
					const double ageDepthScale = 0.32 + 0.68 * freshness * freshness;
					const double ageRimScale = 0.16 + 0.84 * freshness * freshness;
					const double cDepth = depth * sizeScale * ageDepthScale;
					const double cRim = rimHeight * sizeScale * ageRimScale;

					double dh = 0.0;
					if (u < 1.0) {
						// Aged craters have shallower, wider-sloped, sediment-filled floors
						const double bowlRaw = u * u - 1.0;
						const double floorLvl = -0.80 + 0.24 * age;
						const double k = 0.14 + 0.12 * age;
						const double diff = bowlRaw - floorLvl;
						const double bowl = 0.5 * (bowlRaw + floorLvl + sqrt(diff * diff + k * k)) - 0.5 * k;

						const double u2 = u * u;
						const double rim = cRim * u2 * u2;

						// Central rebound peaks survive primarily in younger, fresher large impacts
						double peak = 0.0;
						if (centralPeak > 0.0 && freshness > 0.35 && u < 0.42) {
							const double peakFresh = (freshness - 0.35) / 0.65;
							peak = centralPeak * sizeScale * peakFresh * exp(-u2 * 22.0);
						}

						dh = bowl * cDepth + rim + peak;
					} else if (u < 1.48) {
						// Smooth outer ejecta apron decaying to 0 with zero derivative at u = 1.48
						const double t = (1.48 - u) / 0.48;
						dh = cRim * t * t * (3.0 - 2.0 * t);
					}

					total += dh;
				}
			}
		}

		return total;
	}

	double multi_scale_craters(const vector3d &p, double baseFreq, int layers, double baseDepth, double density, double centralPeakScale, uint32_t seedOffset)
	{
		double sum = 0.0;
		double freq = baseFreq;
		double depth = baseDepth;
		double dens = density;

		for (int i = 0; i < layers; ++i) {
			const double peak = (i == 0) ? (depth * centralPeakScale) : 0.0;
			const double rim = depth * 0.28;
			// Slight coordinate offset per octave prevents inter-layer alignment
			const vector3d offsetP(p.x + 0.17 * i, p.y - 0.23 * i, p.z + 0.31 * i);
			sum += cellular_crater_layer(offsetP, freq, dens, depth, rim, peak, seedOffset + static_cast<uint32_t>(i) * 997u);
			freq *= 2.15;
			depth *= 0.48;
			dens = std::min(0.85, dens * 1.15);
		}
		return sum;
	}

	double smooth_basin_floor(double h, double floorLevel, double smoothness)
	{
		const double d = h - floorLevel;
		return 0.5 * (h + floorLevel + sqrt(d * d + smoothness * smoothness));
	}

	double smooth_terrace(double h, double stepSize, double sharpness)
	{
		if (stepSize <= 1e-9) return h;
		const double scaled = h / stepSize;
		const double base = floor(scaled);
		const double frac = scaled - base;
		// Smoothstep blend toward flat terrace ledges
		const double s = frac * frac * (3.0 - 2.0 * frac);
		const double blended = frac + (s - frac) * sharpness;
		return (base + blended) * stepSize;
	}

// Original canyon function, But really it generates cliffs.
#if 0
double cliff_function(const fracdef_t &def, const vector3d &p)
{
	double h;
	double n = octavenoise(def.octaves, 0.54, 2.0, def.frequency*p);
	constexpr double outer = 0.7;
	constexpr double inner = 0.71;
	if (n > inner) {
		h = 0;
	} else if (n > outer) {
		h = 1.0-1.0*(n-outer)*(1.0/(inner-outer));
	} else {
		h = 1.0;
	}
	return h;
}
#endif

} // namespace TerrainFeature

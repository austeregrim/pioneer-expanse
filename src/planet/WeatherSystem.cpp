// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "WeatherSystem.h"

#include "MathUtil.h"
#include "galaxy/SystemBody.h"
#include "perlin.h"

#include <algorithm>
#include <cmath>

namespace {

	inline double Smoothstep(double edge0, double edge1, double x)
	{
		if (edge1 <= edge0)
			return (x >= edge1) ? 1.0 : 0.0;
		const double t = Clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
		return t * t * (3.0 - 2.0 * t);
	}

	inline double Fbm3(vector3d p, int octaves)
	{
		double sum = 0.0;
		double amp = 0.55;
		double norm = 0.0;
		for (int i = 0; i < octaves; ++i) {
			sum += amp * noise(p);
			norm += amp;
			p = p * 2.07 + vector3d(11.3, 5.7, 8.9);
			amp *= 0.5;
		}
		return (norm > 0.0) ? (sum / norm) : 0.0;
	}

	inline vector3d RotateY(const vector3d &v, double ang)
	{
		const double c = std::cos(ang);
		const double s = std::sin(ang);
		return vector3d(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
	}

	inline uint64_t SplitMix64(uint64_t x)
	{
		x += 0x9e3779b97f4a7c15ULL;
		x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
		x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
		return x ^ (x >> 31);
	}

	inline double HashToUnitDouble(uint64_t x)
	{
		return double(SplitMix64(x) >> 11) * (1.0 / 9007199254740992.0);
	}

	WeatherPlanetParams MakeParamsFromSystemBody(const SystemBody *sbody, double altitudeM, double gameTime, double aglM = -1.0)
	{
		WeatherPlanetParams params;
		if (!sbody)
			return params;

		params.hasAtmosphere = sbody->HasAtmosphere();
		params.planetRadius = sbody->GetRadius();
		params.atmRadius = sbody->GetAtmRadius();
		params.surfacePressureAtm = sbody->GetAtmSurfacePressure();
		params.surfaceDensity = sbody->GetAtmSurfaceDensity();
		params.averageTempK = double(sbody->GetAverageTemp());
		params.volatileGas = sbody->GetVolatileGas();
		params.volatileLiquid = sbody->GetVolatileLiquid();
		params.volatileIces = sbody->GetVolatileIces();
		params.volcanicity = sbody->GetVolcanicity();
		params.rotationPeriodSec = sbody->GetRotationPeriod();
		// Moist/greenhouse lapse rate scaled by surface gravity & ocean/pressure damping
		const double gravity = sbody->CalcSurfaceGravity();
		const double dryLapse = (gravity / 1000.5) * 0.66;
		const double moistDamping = 1.0 - 0.28 * Clamp(params.volatileLiquid, 0.0, 1.0) * Clamp(params.surfacePressureAtm / 2.0, 0.0, 1.0);
		params.lapseRateKPerM = Clamp(dryLapse * moistDamping, 0.0018, 0.0085);
		params.aglM = aglM;
		params.axialTiltRad = sbody->GetAxialTilt();
		params.seed = sbody->GetSeed();

		// Resolve orbital position around parent star (walking up for moons) for true seasonal subsolar latitude
		const SystemBody *orbBody = sbody;
		while (orbBody->GetParent() && orbBody->GetParent()->GetSuperType() != SystemBody::SUPERTYPE_STAR) {
			orbBody = orbBody->GetParent();
		}
		if (orbBody && orbBody->GetParent() && orbBody->GetParent()->GetSuperType() == SystemBody::SUPERTYPE_STAR) {
			const Orbit &orb = orbBody->GetOrbit();
			if (orb.GetSemiMajorAxis() > 1.0 && orb.GetEccentricity() >= 0.0 && orb.GetEccentricity() < 1.0) {
				const double period = orb.Period();
				if (period > 1.0) {
					const vector3d orbPos = orb.OrbitalPosAtTime(gameTime);
					const vector3d orbPosNext = orb.OrbitalPosAtTime(gameTime + std::max(3600.0, period * 0.002));
					if (orbPos.LengthSqr() > 1e-6) {
						const vector3d spinAxis = matrix3x3d::RotateX(params.axialTiltRad) * vector3d(0.0, 1.0, 0.0);
						const vector3d sunDir = (-orbPos).Normalized();
						const vector3d sunDirNext = (-orbPosNext).NormalizedSafe();
						const double sinSub = Clamp(spinAxis.Dot(sunDir), -1.0, 1.0);
						const double sinSubNext = Clamp(spinAxis.Dot(sunDirNext), -1.0, 1.0);
						params.seasonSubsolarLatRad = std::asin(sinSub);
						params.seasonSolarTrend = sinSubNext - sinSub;
					}
				}
			}
		}

		if (params.hasAtmosphere && params.atmRadius > 1.0 && altitudeM < params.atmRadius) {
			const double h = std::max(0.0, altitudeM);
			params.pressureAtAlt = (h <= 0.0) ? params.surfacePressureAtm : sbody->GetAtmPressure(h);
			params.densityAtAlt = (h <= 0.0) ? params.surfaceDensity : sbody->GetAtmDensity(h, params.pressureAtAlt);
		}
		return params;
	}

} // namespace

void WeatherSystem::BuildLocalENU(const vector3d &posRotFrame, vector3d &outEast, vector3d &outNorth, vector3d &outUp)
{
	outUp = posRotFrame.NormalizedSafe();
	if (outUp.LengthSqr() < 1e-12)
		outUp = vector3d(0.0, 1.0, 0.0);

	outEast = vector3d(0.0, 1.0, 0.0).Cross(outUp);
	if (outEast.LengthSqr() < 1e-8)
		outEast = vector3d(1.0, 0.0, 0.0).Cross(outUp);
	outEast = outEast.NormalizedSafe();
	outNorth = outUp.Cross(outEast).NormalizedSafe();
}

WeatherState WeatherSystem::Sample(const SystemBody *sbody, const vector3d &posRotFrame, double gameTime)
{
	return SampleWithAgl(sbody, posRotFrame, gameTime, -1.0);
}

WeatherState WeatherSystem::SampleWithAgl(const SystemBody *sbody, const vector3d &posRotFrame, double gameTime, double aglM)
{
	if (!sbody)
		return WeatherState{};

	const double dist = posRotFrame.Length();
	const double altitudeM = std::max(0.0, dist - sbody->GetRadius());
	const WeatherPlanetParams params = MakeParamsFromSystemBody(sbody, altitudeM, gameTime, aglM);
	return SampleFromParams(params, posRotFrame, gameTime);
}

WeatherState WeatherSystem::Sample(const SystemBody *sbody, const vector3d &unitDir, double altitudeM, double gameTime)
{
	if (!sbody)
		return WeatherState{};

	const vector3d dir = (unitDir.LengthSqr() > 1e-12) ? unitDir.Normalized() : vector3d(0.0, 1.0, 0.0);
	const double clampedAlt = std::max(0.0, altitudeM);
	const WeatherPlanetParams params = MakeParamsFromSystemBody(sbody, clampedAlt, gameTime);
	return SampleFromParams(params, dir * (params.planetRadius + clampedAlt), gameTime);
}

WeatherState WeatherSystem::SampleFromParams(const WeatherPlanetParams &params, const vector3d &posRotFrame, double gameTime)
{
	WeatherState out;
	const double dist = posRotFrame.Length();
	const double altitudeM = std::max(0.0, dist - params.planetRadius);
	out.altitudeM = altitudeM;
	out.pressureAtm = std::max(0.0, params.pressureAtAlt);
	out.densityKgM3 = std::max(0.0, params.densityAtAlt);

	if (!params.hasAtmosphere || params.atmRadius <= 1.0 || altitudeM >= params.atmRadius || out.densityKgM3 < 1e-4) {
		out.hasAtmosphere = false;
		return out;
	}

	out.hasAtmosphere = true;

	vector3d east, north, up;
	BuildLocalENU(posRotFrame, east, north, up);

	// Deterministic 3D seed offset away from noise origin symmetries
	const vector3d seedOff(
		(HashToUnitDouble(uint64_t(params.seed) * 3ULL + 1ULL) - 0.5) * 400.0,
		(HashToUnitDouble(uint64_t(params.seed) * 3ULL + 2ULL) - 0.5) * 400.0,
		(HashToUnitDouble(uint64_t(params.seed) * 3ULL + 3ULL) - 0.5) * 400.0);

	// Slowly drift planetary weather fronts with time while keeping short approaches coherent
	const double t = std::max(0.0, gameTime);
	const double driftAngle = t * 0.00018;
	const vector3d pUnit = RotateY(up, driftAngle);

	// Macro pressure systems & mesoscale storm fronts
	const double macroRaw = Fbm3(pUnit * 2.2 + seedOff, 3);
	const double frontRaw = Fbm3(pUnit * 6.5 + seedOff * 1.7 + vector3d(t * 0.00025, 0.0, -t * 0.00018), 3);
	const double macroField = Clamp(0.5 + 0.62 * macroRaw, 0.0, 1.0);
	const double frontField = Clamp(0.5 + 0.62 * frontRaw, 0.0, 1.0);

	// Latitude, orbital seasons, and regional climate biome
	const double latSin = Clamp(up.y, -1.0, 1.0);
	const double latRad = std::asin(latSin);
	const double absLat = std::abs(latRad);
	const double effectiveLat = std::abs(latRad - params.seasonSubsolarLatRad * 0.72);
	const double latGradientSpan = Clamp(38.0 / std::pow(std::max(params.surfacePressureAtm, 0.25), 0.38), 10.0, 52.0);
	const double surfaceLocalTempK = params.averageTempK + (0.36 - std::sin(Clamp(effectiveLat, 0.0, M_PI * 0.5)) * 0.92) * latGradientSpan;
	const double cloudCeiling = Clamp(params.planetRadius * 0.0015, 6500.0, 13500.0);
	out.localTempK = surfaceLocalTempK - params.lapseRateKPerM * std::min(altitudeM, cloudCeiling);

	if (std::abs(params.axialTiltRad) < 0.04) {
		out.season = SeasonPhase::NONE;
	} else {
		const double hemi = (latRad >= 0.0) ? 1.0 : -1.0;
		const double tiltSin = std::max(0.05, std::abs(std::sin(params.axialTiltRad)));
		const double localSolar = std::sin(params.seasonSubsolarLatRad) * hemi;
		const double localTrend = params.seasonSolarTrend * hemi;
		if (localSolar > 0.35 * tiltSin)
			out.season = SeasonPhase::SUMMER;
		else if (localSolar < -0.35 * tiltSin)
			out.season = SeasonPhase::WINTER;
		else if (localTrend >= 0.0)
			out.season = SeasonPhase::SPRING;
		else
			out.season = SeasonPhase::AUTUMN;
	}

	const bool isWet = params.volatileLiquid > 0.02;
	const bool isVolcanic = params.volcanicity >= 0.35;
	if (surfaceLocalTempK >= 345.0)
		out.climateZone = ClimateZone::SUPERHEATED;
	else if (!isWet && isVolcanic)
		out.climateZone = ClimateZone::VOLCANIC;
	else if (surfaceLocalTempK < 256.0 || absLat > DEG2RAD(72.0))
		out.climateZone = ClimateZone::POLAR;
	else if (surfaceLocalTempK < 276.0 || absLat > DEG2RAD(54.0))
		out.climateZone = ClimateZone::BOREAL;
	else if (!isWet || (params.volatileLiquid < 0.22 && effectiveLat > DEG2RAD(15.0) && effectiveLat < DEG2RAD(36.0)))
		out.climateZone = ClimateZone::ARID;
	else if (effectiveLat < DEG2RAD(24.0) && surfaceLocalTempK >= 292.0)
		out.climateZone = ClimateZone::TROPICAL;
	else
		out.climateZone = ClimateZone::TEMPERATE;

	// Seasonal ITCZ & mid-latitude storm-track forcing
	const double itczBelt = std::exp(-std::pow((latRad - params.seasonSubsolarLatRad * 0.65) / 0.28, 2.0));
	const double midLatBelt = std::exp(-std::pow((absLat - 0.84) / 0.26, 2.0));
	const double winterBoost = (out.season == SeasonPhase::AUTUMN || out.season == SeasonPhase::WINTER) ? 1.0 : 0.45;
	const double subtropDry = std::exp(-std::pow((effectiveLat - 0.48) / 0.18, 2.0));
	const double climateCloudBias = isWet ? (0.10 * itczBelt + 0.07 * midLatBelt * winterBoost - 0.06 * subtropDry) : 0.0;
	const double climateStormBias = 0.07 * itczBelt + 0.06 * midLatBelt * winterBoost;

	// Baseline planetary cloud coverage consistent with terrestrial cloud layer heuristic
	double baseCloud = 0.0;
	if (params.volatileLiquid > 0.01) {
		baseCloud = Clamp(0.34 + 0.34 * std::min(params.volatileLiquid, 1.0) + 0.12 * std::min(params.surfaceDensity, 1.5), 0.25, 0.78);
	} else {
		baseCloud = Clamp(0.14 + 0.22 * std::min(params.surfaceDensity, 2.0), 0.12, 0.56);
	}
	const double macroCloud = Clamp(baseCloud * 0.72 + (macroField - 0.45) * 0.65 + (frontField - 0.50) * 0.35 + climateCloudBias, 0.0, 1.0);

	// Planetary atmospheric forcing (pressure, Coriolis rotation rate, thermal energy)
	const double pressFactor = Clamp(std::pow(std::max(params.surfacePressureAtm, 0.05), 0.26), 0.32, 1.65);
	const double rotHours = (std::abs(params.rotationPeriodSec) > 10.0) ? (std::abs(params.rotationPeriodSec) / 3600.0) : 24.0;
	const double coriolisFactor = Clamp(std::pow(24.0 / std::max(rotHours, 3.0), 0.22), 0.72, 1.45);
	const double thermalFactor = Clamp(0.75 + 0.25 * (params.averageTempK / 288.0), 0.65, 1.45);

	const double rawStorm = macroField * 0.58 + frontField * 0.42 + climateStormBias;
	const double stormDrive = Clamp(0.68 + 0.32 * pressFactor * thermalFactor, 0.60, 1.35);
	out.stormIntensity = Clamp((rawStorm - 0.56) * 2.80 * stormDrive, 0.0, 1.0);

	// Dynamic multi-altitude cloud decks (lower cumulus/storm base lowers in storm fronts, upper cirrus rises slightly)
	const double baseLowAlt = Clamp(params.planetRadius * 0.00052, 2200.0, 5000.0);
	const double baseHighAlt = Clamp(params.planetRadius * 0.00142, 7400.0, 12800.0);
	const double altWave = Fbm3(pUnit * 3.1 + seedOff * 1.3 + vector3d(0.0, t * 0.00030, -t * 0.00022), 2);
	const double dryLift = (out.climateZone == ClimateZone::ARID || !isWet) ? 0.22 : 0.0;
	const double stormDrop = 0.36 * out.stormIntensity + 0.16 * std::max(0.0, macroCloud - 0.45);
	out.lowerCloudAltM = Clamp(baseLowAlt * (1.0 + dryLift - stormDrop + 0.16 * altWave), 1400.0, baseHighAlt - 2400.0);
	out.upperCloudAltM = Clamp(baseHighAlt * (1.0 + 0.10 * out.stormIntensity + 0.10 * altWave), out.lowerCloudAltM + 2400.0, std::max(8500.0, params.atmRadius * 0.52));

	out.lowerCloudCover = Clamp(macroCloud * 0.85 + out.stormIntensity * 0.42 + (frontField - 0.5) * 0.22, 0.0, 0.99);
	const double cirrusNoise = Clamp(0.5 + 0.65 * Fbm3(pUnit * 3.6 + seedOff * 2.7 + vector3d(t * 0.00038, 0.0, 0.0), 2), 0.0, 1.0);
	out.upperCloudCover = Clamp(0.18 + 0.36 * cirrusNoise + 0.38 * out.stormIntensity + 0.18 * macroCloud, 0.05, 0.92);
	out.cloudCover = Clamp(std::max(macroCloud, out.lowerCloudCover * 0.88 + out.upperCloudCover * 0.18), 0.0, 1.0);

	// Altitude profile (surface boundary layer uses true AGL when available)
	const double effectiveAgl = (params.aglM >= 0.0) ? params.aglM : altitudeM;
	const double relDensity = Clamp(out.densityKgM3 / std::max(params.surfaceDensity, 0.05), 0.0, 1.0);
	const double upperFade = std::pow(relDensity, 0.45);
	const double boundaryFactor = 0.68 + 0.32 * Smoothstep(0.0, 450.0, effectiveAgl);
	const double jetPeak = std::exp(-std::pow((altitudeM - cloudCeiling * 0.95) / (cloudCeiling * 0.45), 2.0));
	const double tropoFactor = 1.0 - Smoothstep(cloudCeiling * 0.85, cloudCeiling * 1.45, altitudeM);

	// 3-cell zonal planetary circulation (equatorial easterlies, mid-latitude westerlies, weak polar)
	const double zonalBase = -std::cos(3.0 * latRad);

	const double uNoise = Fbm3(pUnit * 3.8 + seedOff * 2.3 + vector3d(t * 0.00020, 0.0, 0.0), 2);
	const double vNoise = Fbm3(pUnit * 3.8 + seedOff * 3.1 + vector3d(0.0, t * 0.00020, 4.7), 2);

	const double dirEast = zonalBase * (0.65 + 0.55 * jetPeak) + uNoise * (0.85 + 0.65 * out.stormIntensity);
	const double dirNorth = vNoise * (0.95 + 0.70 * out.stormIntensity);
	vector3d flowDir = east * dirEast + north * dirNorth;
	if (flowDir.LengthSqr() < 1e-10)
		flowDir = east;
	else
		flowDir = flowDir.Normalized();

	double steadySpeed = (4.5 + 11.0 * macroField + 20.0 * out.stormIntensity) * pressFactor * coriolisFactor;
	steadySpeed *= boundaryFactor * (1.0 + 0.35 * jetPeak) * upperFade;
	out.windSpeed = Clamp(steadySpeed, 0.0, 62.0);
	out.steadyWindVec = flowDir * out.windSpeed;

	// Meteorological "blowing FROM" azimuth [0, 360)
	if (out.windSpeed > 0.05) {
		const vector3d fromVec = -out.steadyWindVec;
		double deg = RAD2DEG(std::atan2(fromVec.Dot(east), fromVec.Dot(north)));
		if (deg < 0.0)
			deg += 360.0;
		if (deg >= 360.0)
			deg -= 360.0;
		out.windHeadingDeg = deg;
	} else {
		out.windHeadingDeg = 0.0;
	}

	// Mechanical + convective turbulence
	const double boundaryTurbBoost = 1.0 + 0.25 * (1.0 - Smoothstep(0.0, 1200.0, effectiveAgl));
	out.turbulence = Clamp((0.10 + 0.44 * out.stormIntensity + 0.24 * (out.windSpeed / 30.0) + 0.18 * std::max(0.0, frontField - 0.35)) * boundaryTurbBoost * upperFade, 0.0, 1.0);

	// Time-varying tangential gusts
	const double gEast = 0.65 * noise(pUnit * 18.0 + seedOff * 0.5 + vector3d(t * 0.14, 0.0, 0.0)) +
		0.35 * noise(pUnit * 37.0 + seedOff * 0.9 + vector3d(0.0, t * 0.38, 9.2));
	const double gNorth = 0.65 * noise(pUnit * 18.0 + seedOff * 0.7 + vector3d(0.0, 5.1, t * 0.14)) +
		0.35 * noise(pUnit * 37.0 + seedOff * 1.1 + vector3d(t * 0.38, 0.0, -4.4));

	const double gustMagScale = (2.0 + 18.0 * out.stormIntensity + 0.32 * out.windSpeed) * out.turbulence * upperFade;
	const vector3d gustVec = (east * gEast + north * gNorth) * gustMagScale;
	out.gustSpeed = Clamp(gustVec.Length(), 0.0, 28.0);

	// Vertical thermals and storm drafts, tapering smoothly to zero near pad surface
	const double groundTaper = Smoothstep(20.0, 150.0, effectiveAgl);
	const double draftNoise = 0.65 * noise(pUnit * 14.0 + seedOff * 0.4 + vector3d(0.0, t * 0.18, 3.1)) +
		0.35 * noise(pUnit * 29.0 + seedOff * 0.8 + vector3d(t * 0.35, 1.7, 0.0));
	const double maxDraft = (1.5 + 7.5 * out.stormIntensity + 2.0 * thermalFactor) * out.turbulence * groundTaper * tropoFactor * upperFade;
	out.verticalDraft = Clamp(draftNoise * maxDraft, -9.0, 9.0);

	out.windVec = out.steadyWindVec + gustVec + up * out.verticalDraft;
	out.totalWindSpeed = out.windVec.Length();

	// Low-altitude & frontal wind shear metric
	const double shearBoundary = (out.windSpeed * (1.0 - Smoothstep(0.0, 900.0, effectiveAgl))) / 24.0;
	const double shearStorm = out.stormIntensity * 0.45 + std::abs(out.verticalDraft) / 14.0 + out.gustSpeed / 26.0;
	out.windShear = Clamp((shearBoundary * 0.45 + shearStorm * 0.65) * upperFade, 0.0, 1.0);

	// Precipitation & lightning
	if (isWet) {
		out.precipIntensity = Clamp((out.cloudCover - 0.48) * 1.4 + out.stormIntensity * 0.72, 0.0, 1.0) * tropoFactor * upperFade;
	} else if (isVolcanic) {
		const double ashFade = 1.0 - Smoothstep(4500.0, 9000.0, altitudeM);
		out.precipIntensity = Clamp((out.stormIntensity * 0.75 + (out.windSpeed / 40.0) * 0.35) * params.volcanicity, 0.0, 1.0) * ashFade * upperFade;
	} else {
		const double dustFade = 1.0 - Smoothstep(3200.0, 6500.0, altitudeM);
		out.precipIntensity = Clamp(out.stormIntensity * 0.85 + std::max(0.0, (out.windSpeed - 12.0) / 28.0) * 0.55, 0.0, 1.0) * dustFade * upperFade;
	}

	if (out.precipIntensity <= 0.06) {
		out.precipType = PrecipitationType::NONE;
	} else if (isWet) {
		out.precipType = (out.localTempK < 273.15) ? PrecipitationType::SNOW : PrecipitationType::RAIN;
	} else if (isVolcanic) {
		out.precipType = PrecipitationType::ASH;
	} else {
		out.precipType = PrecipitationType::DUST;
	}

	// Gate lightning strictly to thick convective storm cells rather than thin scattered clouds
	if (isWet) {
		if (out.stormIntensity > 0.48 && out.lowerCloudCover >= 0.62) {
			out.lightningActivity = Clamp((out.stormIntensity - 0.48) / 0.52, 0.0, 1.0) * Smoothstep(0.62, 0.86, out.lowerCloudCover) * upperFade;
		} else {
			out.lightningActivity = 0.0;
		}
	} else if (isVolcanic) {
		if (out.stormIntensity > 0.45 && out.precipIntensity >= 0.30) {
			out.lightningActivity = Clamp((out.stormIntensity - 0.45) / 0.55, 0.0, 1.0) * upperFade;
		} else {
			out.lightningActivity = 0.0;
		}
	} else if (out.stormIntensity > 0.65) {
		out.lightningActivity = Clamp((out.stormIntensity - 0.65) / 0.35, 0.0, 1.0) * upperFade;
	} else {
		out.lightningActivity = 0.0;
	}

	// Condition classification
	if (out.precipType == PrecipitationType::DUST && out.precipIntensity >= 0.25) {
		out.condition = WeatherCondition::DUST_STORM;
	} else if (out.precipType == PrecipitationType::SNOW && (out.stormIntensity >= 0.35 || out.windSpeed >= 18.0)) {
		out.condition = WeatherCondition::SNOW_STORM;
	} else if (out.stormIntensity >= 0.72) {
		out.condition = WeatherCondition::SEVERE_STORM;
	} else if (out.stormIntensity >= 0.42 || (out.precipType == PrecipitationType::ASH && out.precipIntensity >= 0.25)) {
		out.condition = WeatherCondition::STORM;
	} else if (out.precipType == PrecipitationType::RAIN && out.precipIntensity >= 0.15) {
		out.condition = WeatherCondition::RAIN;
	} else if (out.windSpeed >= 17.0) {
		out.condition = WeatherCondition::WINDY;
	} else if (out.cloudCover >= 0.65) {
		out.condition = WeatherCondition::OVERCAST;
	} else if (out.windSpeed >= 8.0) {
		out.condition = WeatherCondition::BREEZY;
	} else {
		out.condition = WeatherCondition::CLEAR;
	}

	return out;
}

LightningFlash WeatherSystem::SampleLightningFlash(uint32_t planetSeed, double gameTime, double lightningActivity)
{
	LightningFlash flash;
	const double act = Clamp(lightningActivity, 0.0, 1.0);
	if (act <= 0.05)
		return flash;

	const double t = std::max(0.0, gameTime);
	const double slotPeriod = 26.0 - 16.0 * act; // 25.2 s in moderate storm down to 10.0 s in severe storm
	const uint64_t slotIdx = static_cast<uint64_t>(std::floor(t / slotPeriod));
	const double slotPhase = t - double(slotIdx) * slotPeriod;

	const uint64_t baseKey = (uint64_t(planetSeed) << 32) ^ (slotIdx * 0x9e3779b97f4a7c15ULL);
	const double pOccur = HashToUnitDouble(baseKey + 1ULL);
	if (pOccur > (0.28 + 0.52 * act))
		return flash;

	const double rOffset = HashToUnitDouble(baseKey + 2ULL);
	const double triggerOffset = 0.4 + rOffset * std::max(0.1, slotPeriod - 1.6);
	const double localT = slotPhase - triggerOffset;

	// Smooth 0.88s multi-frame envelope: soft attack, double-stroke peak flicker, and lingering plasma afterglow
	if (localT < 0.0 || localT >= 0.88)
		return flash;

	const double attack = Clamp(localT / 0.045, 0.0, 1.0);
	const double smoothAttack = attack * attack * (3.0 - 2.0 * attack);
	const double pulse1 = std::exp(-std::pow((localT - 0.09) / 0.075, 2.0));
	const double pulse2 = 0.72 * std::exp(-std::pow((localT - 0.25) / 0.090, 2.0));
	const double tailGate = 1.0 - std::pow(Clamp(localT / 0.88, 0.0, 1.0), 3.0);
	const double afterglow = 0.48 * std::exp(-std::max(0.0, localT - 0.10) * 3.4) * tailGate;
	const double envelope = smoothAttack * std::max(std::min(1.0, pulse1 + pulse2 * 0.85), afterglow);
	flash.intensity = float(Clamp(envelope * (0.65 + 0.35 * act), 0.0, 1.0));
	flash.distanceM = float(950.0 + 3550.0 * HashToUnitDouble(baseKey + 3ULL));
	flash.azimuthRad = float(HashToUnitDouble(baseKey + 4ULL) * 2.0 * M_PI);
	flash.boltSeed = static_cast<uint32_t>(SplitMix64(baseKey + 5ULL)) | 1u;
	flash.triggeredThisWindow = true;
	return flash;
}

float WeatherSystem::ComputeTerrainRayVisibility(
	const vector3d &camPosP, const vector3d &starDirP, double starDist,
	double baseRadius, double maxRadius, double angStar,
	const std::function<double(const vector3d &)> &sampleHeight)
{
	if (!sampleHeight || starDist <= 1.0)
		return 1.0f;

	const double outerR = std::max(baseRadius, maxRadius) + 50.0;
	const double bDot = camPosP.Dot(starDirP);
	const double cVal = camPosP.LengthSqr() - outerR * outerR;
	const double disc = bDot * bDot - cVal;
	if (disc <= 0.0)
		return 1.0f;

	const double sqrtDisc = std::sqrt(disc);
	const double sEnter = std::max(0.0, -bDot - sqrtDisc);
	const double sExit = std::min(starDist, -bDot + sqrtDisc);
	const double sStart = std::max(sEnter, 15.0);
	const double span = sExit - sStart;
	if (span <= 1.0)
		return 1.0f;

	const double softEdge = std::max(angStar, 0.0008);
	const double earlyHideThresh = 0.0010 - softEdge;

	constexpr int kSamples = 36;
	const bool insideShell = (sEnter <= 1.0);
	double minAngClear = 1.0e9;
	int minIdx = -1;
	double sPrev = sStart;
	double sBest = sStart;
	double sNext = sExit;
	double prevSampleS = sStart;

	for (int k = 1; k <= kSamples; ++k) {
		const double u = double(k) / double(kSamples);
		const double s = insideShell
			? (sStart + span * std::pow(u, 2.5))
			: (sStart + span * u);
		const vector3d pt = camPosP + starDirP * s;
		const double ptLen = pt.Length();
		if (ptLen <= 1e-6) {
			return 0.0f;
		}
		const double surfR = sampleHeight(pt / ptLen);
		const double angClear = std::atan2(ptLen - surfR, s);
		if (angClear < minAngClear) {
			minAngClear = angClear;
			minIdx = k;
			sPrev = prevSampleS;
			sBest = s;
		}
		if (angClear <= earlyHideThresh) {
			return 0.0f;
		}
		prevSampleS = s;
	}

	if (minIdx > 0 && minAngClear > -0.06 && minAngClear < 0.08) {
		if (minIdx < kSamples) {
			const double uNext = double(minIdx + 1) / double(kSamples);
			sNext = insideShell
				? (sStart + span * std::pow(uNext, 2.5))
				: (sStart + span * uNext);
		}
		const double refStart = std::max(sStart, (minIdx == 1) ? sStart : sPrev);
		const double refSpan = std::max(0.0, sNext - refStart);
		if (refSpan > 1.0) {
			constexpr int kRefine = 8;
			for (int r = 1; r <= kRefine; ++r) {
				const double s = refStart + refSpan * (double(r) / double(kRefine + 1));
				if (std::abs(s - sBest) < 1e-3)
					continue;
				const vector3d pt = camPosP + starDirP * s;
				const double ptLen = pt.Length();
				if (ptLen <= 1e-6) {
					return 0.0f;
				}
				const double surfR = sampleHeight(pt / ptLen);
				const double angClear = std::atan2(ptLen - surfR, s);
				minAngClear = std::min(minAngClear, angClear);
				if (minAngClear <= earlyHideThresh) {
					return 0.0f;
				}
			}
		}
	}

	const double shifted = minAngClear - 0.0010;
	if (shifted <= -softEdge)
		return 0.0f;
	if (shifted >= softEdge)
		return 1.0f;

	const float frac = float((shifted + softEdge) / (2.0 * softEdge));
	return frac * frac * (3.0f - 2.0f * frac);
}

const char *WeatherSystem::GetConditionName(WeatherCondition cond)
{
	switch (cond) {
	case WeatherCondition::CLEAR: return "CLEAR";
	case WeatherCondition::BREEZY: return "BREEZY";
	case WeatherCondition::WINDY: return "WINDY";
	case WeatherCondition::OVERCAST: return "OVERCAST";
	case WeatherCondition::RAIN: return "RAIN";
	case WeatherCondition::STORM: return "STORM";
	case WeatherCondition::SEVERE_STORM: return "SEVERE STORM";
	case WeatherCondition::DUST_STORM: return "DUST STORM";
	case WeatherCondition::SNOW_STORM: return "SNOW STORM";
	default: return "CLEAR";
	}
}

const char *WeatherSystem::GetPrecipitationName(PrecipitationType precip)
{
	switch (precip) {
	case PrecipitationType::NONE: return "NONE";
	case PrecipitationType::RAIN: return "RAIN";
	case PrecipitationType::SNOW: return "SNOW";
	case PrecipitationType::DUST: return "DUST";
	case PrecipitationType::ASH: return "ASH";
	default: return "NONE";
	}
}

const char *WeatherSystem::GetClimateName(ClimateZone zone)
{
	switch (zone) {
	case ClimateZone::TEMPERATE: return "TEMPERATE";
	case ClimateZone::TROPICAL: return "TROPICAL";
	case ClimateZone::ARID: return "ARID";
	case ClimateZone::BOREAL: return "BOREAL";
	case ClimateZone::POLAR: return "POLAR";
	case ClimateZone::VOLCANIC: return "VOLCANIC";
	case ClimateZone::SUPERHEATED: return "SUPERHEATED";
	default: return "TEMPERATE";
	}
}

const char *WeatherSystem::GetSeasonName(SeasonPhase season)
{
	switch (season) {
	case SeasonPhase::NONE: return "NONE";
	case SeasonPhase::SPRING: return "SPRING";
	case SeasonPhase::SUMMER: return "SUMMER";
	case SeasonPhase::AUTUMN: return "AUTUMN";
	case SeasonPhase::WINTER: return "WINTER";
	default: return "NONE";
	}
}

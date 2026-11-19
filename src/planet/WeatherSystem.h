// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef _WEATHERSYSTEM_H
#define _WEATHERSYSTEM_H

#include "vector3.h"

#include <cstdint>
#include <functional>

class SystemBody;

enum class WeatherCondition : uint8_t {
	CLEAR = 0,
	BREEZY,
	WINDY,
	OVERCAST,
	RAIN,
	STORM,
	SEVERE_STORM,
	DUST_STORM,
	SNOW_STORM
};

enum class PrecipitationType : uint8_t {
	NONE = 0,
	RAIN,
	SNOW,
	DUST,
	ASH
};

enum class ClimateZone : uint8_t {
	TEMPERATE = 0,
	TROPICAL,
	ARID,
	BOREAL,
	POLAR,
	VOLCANIC,
	SUPERHEATED
};

enum class SeasonPhase : uint8_t {
	NONE = 0,
	SPRING,
	SUMMER,
	AUTUMN,
	WINTER
};

struct WeatherPlanetParams {
	bool hasAtmosphere = false;
	double planetRadius = 6371000.0;
	double atmRadius = 0.0; // Atmospheric shell height above surface (m), matching SystemBody::GetAtmRadius()
	double surfacePressureAtm = 0.0;
	double surfaceDensity = 0.0;
	double pressureAtAlt = 0.0;
	double densityAtAlt = 0.0;
	double averageTempK = 288.0;
	double volatileGas = 0.0;
	double volatileLiquid = 0.0;
	double volatileIces = 0.0;
	double volcanicity = 0.0;
	double rotationPeriodSec = 86400.0;
	double lapseRateKPerM = 0.0065;
	double aglM = -1.0; // Optional Height Above Ground Level (m); < 0 falls back to altitudeM
	double axialTiltRad = 0.0;
	double seasonSubsolarLatRad = 0.0; // Latitude of subsolar point [-pi/2..pi/2]
	double seasonSolarTrend = 0.0;     // + toward northern summer, - toward northern winter
	uint32_t seed = 0;
};

struct WeatherState {
	bool hasAtmosphere = false;
	double pressureAtm = 0.0;
	double densityKgM3 = 0.0;
	double altitudeM = 0.0;
	double localTempK = 288.0;

	double windSpeed = 0.0;
	double gustSpeed = 0.0;
	double totalWindSpeed = 0.0;
	double verticalDraft = 0.0;
	double windHeadingDeg = 0.0; // Meteorological "blowing FROM" azimuth [0, 360)

	vector3d steadyWindVec = vector3d(0.0); // Planet rotating frame, m/s
	vector3d windVec = vector3d(0.0);       // Steady + gust + vertical draft in planet rotating frame, m/s

	double turbulence = 0.0;        // [0..1]
	double windShear = 0.0;         // [0..1]
	double stormIntensity = 0.0;    // [0..1]
	double cloudCover = 0.0;        // [0..1]
	double lowerCloudCover = 0.0;   // [0..1] dynamic cumulus/storm deck
	double upperCloudCover = 0.0;   // [0..1] dynamic high cirrus/anvil deck
	double lowerCloudAltM = 0.0;    // Dynamic altitude of lower cloud base (m)
	double upperCloudAltM = 0.0;    // Dynamic altitude of upper cirrus deck (m)
	double precipIntensity = 0.0;   // [0..1]
	double lightningActivity = 0.0; // [0..1]

	PrecipitationType precipType = PrecipitationType::NONE;
	WeatherCondition condition = WeatherCondition::CLEAR;
	ClimateZone climateZone = ClimateZone::TEMPERATE;
	SeasonPhase season = SeasonPhase::NONE;
};

struct LightningFlash {
	float intensity = 0.0f;
	float distanceM = 2500.0f;
	float azimuthRad = 0.0f;
	uint32_t boltSeed = 0;
	bool triggeredThisWindow = false;
};

class WeatherSystem {
public:
	static WeatherState Sample(const SystemBody *sbody, const vector3d &posRotFrame, double gameTime);
	static WeatherState SampleWithAgl(const SystemBody *sbody, const vector3d &posRotFrame, double gameTime, double aglM);
	static WeatherState Sample(const SystemBody *sbody, const vector3d &unitDir, double altitudeM, double gameTime);
	static WeatherState SampleFromParams(const WeatherPlanetParams &params, const vector3d &posRotFrame, double gameTime);

	static LightningFlash SampleLightningFlash(uint32_t planetSeed, double gameTime, double lightningActivity);

	static void BuildLocalENU(const vector3d &posRotFrame, vector3d &outEast, vector3d &outNorth, vector3d &outUp);

	static float ComputeTerrainRayVisibility(
		const vector3d &camPosP, const vector3d &starDirP, double starDist,
		double baseRadius, double maxRadius, double angStar,
		const std::function<double(const vector3d &)> &sampleHeight);

	static const char *GetConditionName(WeatherCondition cond);
	static const char *GetPrecipitationName(PrecipitationType precip);
	static const char *GetClimateName(ClimateZone zone);
	static const char *GetSeasonName(SeasonPhase season);
};

#endif /* _WEATHERSYSTEM_H */

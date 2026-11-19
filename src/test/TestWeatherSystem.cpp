// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "doctest.h"
#include "planet/WeatherSystem.h"

#include <cmath>
#include <cstring>

namespace {

	WeatherPlanetParams MakeEarthLikeParams(double altitudeM, double pressureAtAlt, double densityAtAlt)
	{
		WeatherPlanetParams p;
		p.hasAtmosphere = true;
		p.planetRadius = 6371000.0;
		p.atmRadius = 90000.0;
		p.surfacePressureAtm = 1.0;
		p.surfaceDensity = 1.225;
		p.pressureAtAlt = pressureAtAlt;
		p.densityAtAlt = densityAtAlt;
		p.averageTempK = 288.0;
		p.volatileGas = 1.225;
		p.volatileLiquid = 0.7;
		p.volatileIces = 0.03;
		p.volcanicity = 0.05;
		p.rotationPeriodSec = 86400.0;
		p.seed = 424242u;
		(void)altitudeM;
		return p;
	}

} // namespace

TEST_CASE("WeatherSystem")
{
	SUBCASE("Airless and above-atmosphere early-out")
	{
		WeatherPlanetParams airless;
		airless.hasAtmosphere = false;
		airless.planetRadius = 1737000.0;
		airless.atmRadius = 0.0;

		const WeatherState s1 = WeatherSystem::SampleFromParams(airless, vector3d(1737500.0, 0.0, 0.0), 120.0);
		CHECK_FALSE(s1.hasAtmosphere);
		CHECK(s1.windSpeed == 0.0);
		CHECK(s1.gustSpeed == 0.0);
		CHECK(s1.totalWindSpeed == 0.0);
		CHECK(s1.precipIntensity == 0.0);
		CHECK(s1.condition == WeatherCondition::CLEAR);
		CHECK(s1.precipType == PrecipitationType::NONE);

		WeatherPlanetParams aboveAtm = MakeEarthLikeParams(95000.0, 0.0, 0.0);
		const WeatherState s2 = WeatherSystem::SampleFromParams(aboveAtm, vector3d(6371000.0 + 95000.0, 0.0, 0.0), 120.0);
		CHECK_FALSE(s2.hasAtmosphere);
		CHECK(s2.windSpeed == 0.0);
		CHECK(s2.turbulence == 0.0);
	}

	SUBCASE("Earth-like atmosphere ENU orthogonality, bounds, and altitude behavior")
	{
		const vector3d unitPos = vector3d(0.45, 0.55, 0.70).Normalized();
		const WeatherPlanetParams seaParams = MakeEarthLikeParams(0.0, 1.0, 1.225);
		const WeatherState sea = WeatherSystem::SampleFromParams(seaParams, unitPos * seaParams.planetRadius, 500.0);

		CHECK(sea.hasAtmosphere);
		CHECK(std::isfinite(sea.windSpeed));
		CHECK(std::isfinite(sea.gustSpeed));
		CHECK(std::isfinite(sea.totalWindSpeed));
		CHECK(std::isfinite(sea.verticalDraft));
		CHECK(std::isfinite(sea.windHeadingDeg));
		CHECK(sea.windHeadingDeg >= 0.0);
		CHECK(sea.windHeadingDeg < 360.0);
		CHECK(sea.turbulence >= 0.0);
		CHECK(sea.turbulence <= 1.0);
		CHECK(sea.windShear >= 0.0);
		CHECK(sea.windShear <= 1.0);
		CHECK(sea.cloudCover >= 0.0);
		CHECK(sea.cloudCover <= 1.0);
		// Steady wind is strictly tangent to local sphere
		CHECK(std::abs(sea.steadyWindVec.Dot(unitPos)) < 1e-6);
		// Surface pad safety taper keeps vertical draft zero right on ground
		CHECK(std::abs(sea.verticalDraft) < 1e-6);

		// Mid-troposphere allows convective drafts and non-zero winds
		const WeatherPlanetParams tropoParams = MakeEarthLikeParams(4000.0, 0.61, 0.82);
		const WeatherState tropo = WeatherSystem::SampleFromParams(tropoParams, unitPos * (tropoParams.planetRadius + 4000.0), 500.0);
		CHECK(tropo.hasAtmosphere);
		CHECK(std::abs(tropo.steadyWindVec.Dot(unitPos)) < 1e-6);

		// Thin upper atmosphere attenuates winds and turbulence smoothly
		const WeatherPlanetParams highParams = MakeEarthLikeParams(65000.0, 0.002, 0.004);
		const WeatherState high = WeatherSystem::SampleFromParams(highParams, unitPos * (highParams.planetRadius + 65000.0), 500.0);
		CHECK(high.hasAtmosphere);
		CHECK(high.windSpeed < sea.windSpeed);
		CHECK(high.turbulence <= sea.turbulence);
	}

	SUBCASE("Deterministic reproducibility")
	{
		const WeatherPlanetParams p = MakeEarthLikeParams(1500.0, 0.84, 1.05);
		const vector3d pos = vector3d(-0.3, 0.6, 0.74).Normalized() * (p.planetRadius + 1500.0);
		const WeatherState a = WeatherSystem::SampleFromParams(p, pos, 1234.56);
		const WeatherState b = WeatherSystem::SampleFromParams(p, pos, 1234.56);

		CHECK(a.windSpeed == b.windSpeed);
		CHECK(a.gustSpeed == b.gustSpeed);
		CHECK(a.windHeadingDeg == b.windHeadingDeg);
		CHECK(a.stormIntensity == b.stormIntensity);
		CHECK(a.turbulence == b.turbulence);
		CHECK(a.condition == b.condition);
		CHECK(a.precipType == b.precipType);
		CHECK(a.windVec.x == b.windVec.x);
		CHECK(a.windVec.y == b.windVec.y);
		CHECK(a.windVec.z == b.windVec.z);
	}

	SUBCASE("Precipitation classification across world types")
	{
		auto findSampleWithPrecip = [](WeatherPlanetParams base, PrecipitationType expected) {
			for (int i = 0; i < 64; ++i) {
				const double ang = double(i) * 0.37;
				const vector3d dir = vector3d(std::cos(ang), std::sin(ang * 0.7) * 0.8, std::sin(ang)).Normalized();
				base.seed = 1000u + uint32_t(i) * 7919u;
				const WeatherState w = WeatherSystem::SampleFromParams(base, dir * (base.planetRadius + 600.0), 250.0);
				if (w.precipType == expected)
					return true;
			}
			return false;
		};

		WeatherPlanetParams rainWorld = MakeEarthLikeParams(600.0, 0.93, 1.15);
		rainWorld.averageTempK = 290.0;
		rainWorld.volatileLiquid = 0.85;
		CHECK(findSampleWithPrecip(rainWorld, PrecipitationType::RAIN));

		WeatherPlanetParams snowWorld = MakeEarthLikeParams(600.0, 0.93, 1.15);
		snowWorld.averageTempK = 240.0;
		snowWorld.volatileLiquid = 0.75;
		CHECK(findSampleWithPrecip(snowWorld, PrecipitationType::SNOW));

		WeatherPlanetParams dustWorld = MakeEarthLikeParams(600.0, 1.8, 2.2);
		dustWorld.volatileLiquid = 0.0;
		dustWorld.volcanicity = 0.0;
		dustWorld.surfacePressureAtm = 2.0;
		dustWorld.surfaceDensity = 2.4;
		dustWorld.rotationPeriodSec = 28800.0;
		CHECK(findSampleWithPrecip(dustWorld, PrecipitationType::DUST));

		WeatherPlanetParams ashWorld = MakeEarthLikeParams(600.0, 1.2, 1.5);
		ashWorld.volatileLiquid = 0.0;
		ashWorld.volcanicity = 0.85;
		ashWorld.surfacePressureAtm = 1.4;
		ashWorld.surfaceDensity = 1.6;
		CHECK(findSampleWithPrecip(ashWorld, PrecipitationType::ASH));
	}

	SUBCASE("Hot low-gravity super-Earth lapse rate and true AGL ground taper")
	{
		WeatherPlanetParams atlantica;
		atlantica.hasAtmosphere = true;
		atlantica.planetRadius = 15609000.0;
		atlantica.atmRadius = 120000.0;
		atlantica.surfacePressureAtm = 8.36;
		atlantica.surfaceDensity = 9.0;
		atlantica.pressureAtAlt = 3.12;
		atlantica.densityAtAlt = 4.2;
		atlantica.averageTempK = 328.0;
		atlantica.volatileGas = 9.0;
		atlantica.volatileLiquid = 0.80;
		atlantica.volatileIces = 0.0;
		atlantica.volcanicity = 0.60;
		atlantica.rotationPeriodSec = 243.0 * 86400.0;
		atlantica.lapseRateKPerM = 0.00264;
		atlantica.aglM = 4.0;

		bool sawRain = false;
		for (int i = 0; i < 64; ++i) {
			const double ang = double(i) * 0.37;
			const vector3d dir = vector3d(std::cos(ang), std::sin(ang * 0.7) * 0.8, std::sin(ang)).Normalized();
			atlantica.seed = 2000u + uint32_t(i) * 7919u;

			for (double msl : { 0.0, 4000.0, 14000.0, 18500.0 }) {
				const WeatherState w = WeatherSystem::SampleFromParams(atlantica, dir * (atlantica.planetRadius + msl), 250.0);
				CHECK(w.hasAtmosphere);
				CHECK(w.precipType != PrecipitationType::SNOW);
				CHECK(w.condition != WeatherCondition::SNOW_STORM);
				CHECK(std::abs(w.verticalDraft) < 1e-6);
				if (msl <= 4000.0 && w.precipType == PrecipitationType::RAIN)
					sawRain = true;
			}
		}
		CHECK(sawRain);
	}

	SUBCASE("Lightning flash bounds and inactive behavior")
	{
		const LightningFlash inactive = WeatherSystem::SampleLightningFlash(12345u, 42.0, 0.0);
		CHECK(inactive.intensity == 0.0f);
		CHECK_FALSE(inactive.triggeredThisWindow);

		bool sawFlash = false;
		bool inRun = false;
		int runSamples = 0;
		float firstIntensity = 0.0f;
		float lastIntensity = 0.0f;
		float peakIntensity = 0.0f;
		int maxRunSamples = 0;
		for (int i = 0; i < 4000; ++i) {
			const double t = double(i) * 0.03;
			const LightningFlash f = WeatherSystem::SampleLightningFlash(98765u, t, 0.9);
			CHECK(f.intensity >= 0.0f);
			CHECK(f.intensity <= 1.0f);
			if (f.triggeredThisWindow) {
				sawFlash = true;
				CHECK(f.distanceM >= 950.0f);
				CHECK(f.distanceM <= 4500.0f);
				CHECK(f.boltSeed != 0u);
				if (!inRun) {
					inRun = true;
					runSamples = 1;
					firstIntensity = f.intensity;
					peakIntensity = f.intensity;
					lastIntensity = f.intensity;
				} else {
					++runSamples;
					peakIntensity = std::max(peakIntensity, f.intensity);
					lastIntensity = f.intensity;
				}
			} else if (inRun) {
				maxRunSamples = std::max(maxRunSamples, runSamples);
				CHECK(runSamples >= 18); // >= 0.50 s contiguous persistence at 30 ms steps
				CHECK(firstIntensity < peakIntensity * 0.70f);
				CHECK(lastIntensity < peakIntensity * 0.25f);
				inRun = false;
			}
		}
		if (inRun) {
			maxRunSamples = std::max(maxRunSamples, runSamples);
		}
		CHECK(sawFlash);
		CHECK(double(maxRunSamples) * 0.03 >= 0.50);
	}

	SUBCASE("Multi-altitude dynamic cloud decks respond to storms and aridity")
	{
		WeatherPlanetParams wetWorld = MakeEarthLikeParams(800.0, 0.90, 1.12);
		wetWorld.volatileLiquid = 0.80;

		double minStormLowAlt = 1e9;
		double maxClearLowAlt = 0.0;
		for (int i = 0; i < 64; ++i) {
			const double ang = double(i) * 0.41;
			const vector3d dir = vector3d(std::cos(ang), std::sin(ang * 0.5) * 0.6, std::sin(ang)).Normalized();
			wetWorld.seed = 3000u + uint32_t(i) * 6151u;
			const WeatherState w = WeatherSystem::SampleFromParams(wetWorld, dir * (wetWorld.planetRadius + 800.0), 400.0);
			CHECK(w.lowerCloudAltM > 1000.0);
			CHECK(w.upperCloudAltM > w.lowerCloudAltM + 2000.0);
			CHECK(w.lowerCloudCover >= 0.0);
			CHECK(w.lowerCloudCover <= 1.0);
			CHECK(w.upperCloudCover >= 0.0);
			CHECK(w.upperCloudCover <= 1.0);
			if (w.stormIntensity > 0.55)
				minStormLowAlt = std::min(minStormLowAlt, w.lowerCloudAltM);
			else if (w.stormIntensity < 0.05 && w.cloudCover < 0.45)
				maxClearLowAlt = std::max(maxClearLowAlt, w.lowerCloudAltM);
		}
		CHECK(minStormLowAlt < maxClearLowAlt);

		// Arid worlds lift the cumulus condensation base compared to wet ocean worlds
		WeatherPlanetParams aridWorld = MakeEarthLikeParams(800.0, 0.90, 1.12);
		aridWorld.volatileLiquid = 0.0;
		const vector3d eqDir = vector3d(1.0, 0.0, 0.0);
		const WeatherState wetSample = WeatherSystem::SampleFromParams(wetWorld, eqDir * (wetWorld.planetRadius + 800.0), 400.0);
		const WeatherState aridSample = WeatherSystem::SampleFromParams(aridWorld, eqDir * (aridWorld.planetRadius + 800.0), 400.0);
		CHECK(aridSample.climateZone == ClimateZone::ARID);
		CHECK(aridSample.upperCloudAltM > aridSample.lowerCloudAltM);
		CHECK(aridSample.lowerCloudAltM > wetSample.lowerCloudAltM * 0.9);
	}

	SUBCASE("Orbital axial tilt drives opposing hemisphere seasons and temperatures")
	{
		WeatherPlanetParams northSummer = MakeEarthLikeParams(200.0, 0.98, 1.20);
		northSummer.axialTiltRad = 0.41; // ~23.5 deg Earth-like obliquity
		northSummer.seasonSubsolarLatRad = 0.38;
		northSummer.seasonSolarTrend = -0.01;

		const vector3d northMid = vector3d(0.7, 0.68, 0.21).Normalized() * (northSummer.planetRadius + 200.0);
		const vector3d southMid = vector3d(0.7, -0.68, 0.21).Normalized() * (northSummer.planetRadius + 200.0);

		const WeatherState nSummer = WeatherSystem::SampleFromParams(northSummer, northMid, 100.0);
		const WeatherState sWinter = WeatherSystem::SampleFromParams(northSummer, southMid, 100.0);
		CHECK(nSummer.season == SeasonPhase::SUMMER);
		CHECK(sWinter.season == SeasonPhase::WINTER);
		CHECK(nSummer.localTempK > sWinter.localTempK);

		WeatherPlanetParams southSummer = northSummer;
		southSummer.seasonSubsolarLatRad = -0.38;
		const WeatherState nWinter = WeatherSystem::SampleFromParams(southSummer, northMid, 100.0);
		const WeatherState sSummer = WeatherSystem::SampleFromParams(southSummer, southMid, 100.0);
		CHECK(nWinter.season == SeasonPhase::WINTER);
		CHECK(sSummer.season == SeasonPhase::SUMMER);
		CHECK(sSummer.localTempK > nWinter.localTempK);
	}

	SUBCASE("Terrain ray occlusion blocks sun glare behind mountains and below horizon")
	{
		const double R = 6371000.0;
		const double starDist = 1.5e11;
		const double angSun = 0.00465; // ~1 AU solar angular radius (~0.27 deg)

		// Camera at R + 100 m over north pole (+Y), sun in +Z/+Y plane
		const vector3d camPos(0.0, R + 100.0, 0.0);
		auto sunDirElevDeg = [](double deg) -> vector3d {
			const double rad = deg * (M_PI / 180.0);
			return vector3d(0.0, std::sin(rad), std::cos(rad)).Normalized();
		};

		// Mountain ridge rising to +3500 m centered 20 km ahead (+Z)
		auto mountainSampler = [&](const vector3d &u) -> double {
			const double arcDistM = std::atan2(u.z, u.y) * R;
			const double dz = (arcDistM - 20000.0) / 3500.0;
			return R + 3500.0 * std::exp(-dz * dz);
		};
		auto flatOceanSampler = [&](const vector3d &) -> double {
			return R;
		};

		// 1. Sun at +2.5 deg above horizontal is well above sea-level horizon, but hidden behind the 3.5 km mountain ridge
		CHECK(WeatherSystem::ComputeTerrainRayVisibility(
			camPos, sunDirElevDeg(2.5), starDist, R, R + 5000.0, angSun, mountainSampler) == 0.0f);

		// 2. Over flat ocean at the exact same +2.5 deg elevation, sun glare is fully visible
		CHECK(WeatherSystem::ComputeTerrainRayVisibility(
			camPos, sunDirElevDeg(2.5), starDist, R, R + 5000.0, angSun, flatOceanSampler) == 1.0f);

		// 3. Sun at -1.0 deg below horizon behind the mountain remains completely occluded (never re-appears)
		CHECK(WeatherSystem::ComputeTerrainRayVisibility(
			camPos, sunDirElevDeg(-1.0), starDist, R, R + 5000.0, angSun, mountainSampler) == 0.0f);

		// 4. Camera in a basin below nominal radius (R - 50 m) surrounded by +800 m hills 10 km away
		const vector3d valleyCam(0.0, R - 50.0, 0.0);
		auto valleyRimSampler = [&](const vector3d &u) -> double {
			const double arcDistM = std::atan2(u.z, u.y) * R;
			const double dz = (arcDistM - 10000.0) / 2500.0;
			return R - 60.0 + 860.0 * std::exp(-dz * dz);
		};
		CHECK(WeatherSystem::ComputeTerrainRayVisibility(
			valleyCam, sunDirElevDeg(1.0), starDist, R, R + 1200.0, angSun, valleyRimSampler) == 0.0f);
		CHECK(WeatherSystem::ComputeTerrainRayVisibility(
			valleyCam, sunDirElevDeg(20.0), starDist, R, R + 1200.0, angSun, valleyRimSampler) == 1.0f);

		// 5. Low-orbit view (R + 50 km) looking across a mountainous limb (peaks at R + 8 km)
		const double orbitR = R + 50000.0;
		const double limbDist = std::sqrt(orbitR * orbitR - R * R);
		const vector3d orbitCam(0.0, orbitR, 0.0);
		auto limbRidgeSampler = [&](const vector3d &u) -> double {
			// Limb tangent point lies near atan2(z, y) == acos(R / orbitR)
			const double limbAng = std::acos(R / orbitR);
			const double curAng = std::atan2(u.z, u.y);
			const double arcDiffM = (curAng - limbAng) * R;
			const double dz = arcDiffM / 15000.0;
			return R + 8000.0 * std::exp(-dz * dz);
		};
		const vector3d dir1kmBelowPeak = (vector3d(0.0, (R + 7000.0) * (R / orbitR), (R + 7000.0) * (limbDist / orbitR)) - orbitCam).Normalized();
		const vector3d dir2kmAbovePeak = (vector3d(0.0, (R + 10000.0) * (R / orbitR), (R + 10000.0) * (limbDist / orbitR)) - orbitCam).Normalized();
		CHECK(WeatherSystem::ComputeTerrainRayVisibility(
			orbitCam, dir1kmBelowPeak, starDist, R, R + 8500.0, 0.0005, limbRidgeSampler) == 0.0f);
		CHECK(WeatherSystem::ComputeTerrainRayVisibility(
			orbitCam, dir2kmAbovePeak, starDist, R, R + 8500.0, 0.0005, limbRidgeSampler) == 1.0f);
	}
}

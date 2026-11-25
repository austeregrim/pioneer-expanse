// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "WeatherEffects.h"

#include "Frame.h"
#include "Game.h"
#include "MathUtil.h"
#include "Pi.h"
#include "Planet.h"
#include "Ship.h"
#include "SpaceStation.h"
#include "galaxy/SystemBody.h"
#include "graphics/RenderState.h"
#include "graphics/Renderer.h"
#include "graphics/Types.h"
#include "planet/WeatherSystem.h"
#include "profiler/Profiler.h"

#include <algorithm>
#include <cmath>

namespace {

	inline float WrapCoord(float v, float bounds)
	{
		const float span = bounds * 2.0f;
		while (v > bounds)
			v -= span;
		while (v < -bounds)
			v += span;
		return v;
	}

	inline uint32_t NextLcg(uint32_t &state)
	{
		state = state * 1664525u + 1013904223u;
		return state;
	}

	inline float LcgSigned(uint32_t &state)
	{
		return (float(NextLcg(state) >> 8) * (1.0f / 16777216.0f)) * 2.0f - 1.0f;
	}

	inline float LcgUnit(uint32_t &state)
	{
		return float(NextLcg(state) >> 8) * (1.0f / 16777216.0f);
	}

} // namespace

WeatherEffects::WeatherEffects(Ship *ship) :
	m_ship(ship),
	m_precipVerts(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE, NUM_PARTICLES * 2),
	m_volcanicVerts(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE, NUM_VOLCANIC_PARTICLES * 2),
	m_lightningVerts(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE, 1600),
	m_lightningBloomVerts(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE | Graphics::ATTRIB_UV0, 24),
	m_transform(matrix4x4d::Identity),
	m_precipVisible(false),
	m_volcanicVisible(false),
	m_lightningVisible(false)
{
	PROFILE_SCOPED();

	InitMaterials(Pi::renderer);

	m_particles.reserve(NUM_PARTICLES);
	uint32_t rng = 0x7A4B13F9u;
	for (int i = 0; i < NUM_PARTICLES; ++i) {
		const float bounds = (i < NEAR_PARTICLES) ? NEAR_BOUNDS : BOX_BOUNDS;
		m_particles.emplace_back(
			LcgSigned(rng) * bounds,
			LcgSigned(rng) * bounds,
			LcgSigned(rng) * bounds);
	}

	m_volcanicParticles.reserve(NUM_VOLCANIC_PARTICLES);
	for (int i = 0; i < NUM_VOLCANIC_PARTICLES; ++i) {
		m_volcanicParticles.emplace_back(
			LcgSigned(rng) * VOLCANIC_BOUNDS,
			LcgSigned(rng) * VOLCANIC_BOUNDS,
			LcgSigned(rng) * VOLCANIC_BOUNDS);
	}
}

void WeatherEffects::InitMaterials(Graphics::Renderer *r)
{
	if (!r)
		return;

	Graphics::MaterialDescriptor desc;
	desc.vertexColors = true;

	auto vfmt = Graphics::VertexFormatDesc::FromAttribSet(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE);

	Graphics::RenderStateDesc precipRsd;
	precipRsd.blendMode = Graphics::BLEND_ALPHA;
	precipRsd.depthWrite = false;
	precipRsd.primitiveType = Graphics::LINE_SINGLE;
	m_precipMaterial.Reset(r->CreateMaterial("unlit", desc, precipRsd, vfmt));

	Graphics::RenderStateDesc lightningRsd;
	lightningRsd.blendMode = Graphics::BLEND_ADDITIVE;
	lightningRsd.depthWrite = false;
	lightningRsd.cullMode = Graphics::CULL_NONE;
	lightningRsd.primitiveType = Graphics::TRIANGLES;
	m_lightningMaterial.Reset(r->CreateMaterial("unlit", desc, lightningRsd, vfmt));

	const auto bloomVfmt = Graphics::VertexFormatDesc::FromAttribSet(
		Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE | Graphics::ATTRIB_UV0);
	Graphics::RenderStateDesc bloomRsd;
	bloomRsd.blendMode = Graphics::BLEND_ADDITIVE;
	bloomRsd.depthWrite = false;
	bloomRsd.cullMode = Graphics::CULL_NONE;
	bloomRsd.primitiveType = Graphics::TRIANGLES;
	m_lightningBloomMaterial.Reset(r->CreateMaterial("ship_light_glare", desc, bloomRsd, bloomVfmt));
}

void WeatherEffects::BuildLightningBolt(
	const vector3d &east, const vector3d &north, const vector3d &up,
	double aglMeters, double cloudBaseMeters, float distanceM, float azimuthRad,
	uint32_t boltSeed, float intensity)
{
	m_lightningVerts.Clear();
	m_lightningBloomVerts.Clear();

	const vector3d horizDir = east * std::cos(double(azimuthRad)) + north * std::sin(double(azimuthRad));
	const vector3d latAxis = up.Cross(horizDir).NormalizedSafe();

	const double baseRelY = -Clamp(aglMeters, 0.0, 6000.0);
	const double topRelY = baseRelY + Clamp(cloudBaseMeters * 0.92, 1600.0, 5600.0);
	const vector3d centerBase = horizDir * double(distanceM) + up * baseRelY;

	uint32_t rng = boltSeed | 1u;
	const int mainSegs = 11;
	const vector3f topPt = vector3f(centerBase + up * (topRelY - baseRelY));
	vector3f prevPt = topPt;

	auto scaleAdditiveCol = [](float r, float g, float b, float s) -> Color {
		return Color(
			Uint8(Clamp(r * s, 0.0f, 255.0f)),
			Uint8(Clamp(g * s, 0.0f, 255.0f)),
			Uint8(Clamp(b * s, 0.0f, 255.0f)),
			255);
	};

	const Color edgeZero(0, 0, 0, 0);
	const vector3f upF = vector3f(up);
	const float baseWidth = std::clamp(distanceM * 0.0022f, 2.2f, 11.5f) * (0.45f + 0.65f * intensity);

	auto emitRibbon = [&](const vector3f &p0, const vector3f &p1, float halfWidth, const Color &spineCol) {
		const vector3f seg = p1 - p0;
		const float lenSq = seg.LengthSqr();
		if (lenSq < 1e-4f || halfWidth <= 0.01f)
			return;
		const vector3f dir = seg * (1.0f / std::sqrt(lenSq));
		const vector3f mid = (p0 + p1) * 0.5f;
		vector3f toCam = -mid;
		if (toCam.LengthSqr() > 1e-6f)
			toCam = toCam.Normalized();
		else
			toCam = vector3f(0.0f, 0.0f, 1.0f);

		vector3f side = dir.Cross(toCam);
		if (side.LengthSqr() < 1e-6f)
			side = dir.Cross(vector3f(1.0f, 0.0f, 0.0f));
		side = side.NormalizedSafe() * halfWidth;

		const vector3f cap = dir * (halfWidth * 0.35f);
		const vector3f a0 = p0 - cap;
		const vector3f a1 = p1 + cap;
		const vector3f l0 = a0 - side;
		const vector3f r0 = a0 + side;
		const vector3f l1 = a1 - side;
		const vector3f r1 = a1 + side;

		// Left wing fading smoothly from bright plasma spine to zero at edge
		m_lightningVerts.Add(l0, edgeZero);
		m_lightningVerts.Add(a0, spineCol);
		m_lightningVerts.Add(a1, spineCol);
		m_lightningVerts.Add(l0, edgeZero);
		m_lightningVerts.Add(a1, spineCol);
		m_lightningVerts.Add(l1, edgeZero);

		// Right wing fading smoothly from bright plasma spine to zero at edge
		m_lightningVerts.Add(a0, spineCol);
		m_lightningVerts.Add(r0, edgeZero);
		m_lightningVerts.Add(r1, edgeZero);
		m_lightningVerts.Add(a0, spineCol);
		m_lightningVerts.Add(r1, edgeZero);
		m_lightningVerts.Add(a1, spineCol);
	};

	auto emitLayeredSegment = [&](const vector3f &p0, const vector3f &p1, float widthMul, float gain) {
		const float w = baseWidth * widthMul;
		emitRibbon(p0, p1, w * 6.8f, scaleAdditiveCol(72.0f, 108.0f, 215.0f, intensity * 0.42f * gain));
		emitRibbon(p0, p1, w * 2.4f, scaleAdditiveCol(120.0f, 178.0f, 255.0f, intensity * 0.68f * gain));
		emitRibbon(p0, p1, w * 0.65f, scaleAdditiveCol(240.0f, 248.0f, 255.0f, Clamp(intensity * 1.15f, 0.0f, 1.0f) * gain));
	};

	auto emitBloomDisc = [&](const vector3f &center, float discRadius, const Color &centerCol) {
		if (discRadius <= 0.1f)
			return;
		vector3f toCam = -center;
		if (toCam.LengthSqr() > 1e-6f)
			toCam = toCam.Normalized();
		else
			toCam = vector3f(0.0f, 0.0f, 1.0f);
		vector3f camRight = upF.Cross(toCam);
		if (camRight.LengthSqr() < 1e-6f)
			camRight = vector3f(1.0f, 0.0f, 0.0f).Cross(toCam);
		camRight = camRight.NormalizedSafe() * discRadius;
		const vector3f camUp = toCam.Cross(camRight).NormalizedSafe() * discRadius;

		const int slices = 12;
		const float stepRad = float(2.0 * M_PI / double(slices));
		for (int s = 0; s < slices; ++s) {
			const float th0 = stepRad * float(s);
			const float th1 = stepRad * float((s + 1) % slices);
			const vector3f rim0 = center + camRight * std::cos(th0) + camUp * std::sin(th0);
			const vector3f rim1 = center + camRight * std::cos(th1) + camUp * std::sin(th1);
			m_lightningVerts.Add(center, centerCol);
			m_lightningVerts.Add(rim0, edgeZero);
			m_lightningVerts.Add(rim1, edgeZero);
		}
	};

	auto emitGlareQuad = [&](const vector3f &center, float halfRadius, const Color &glareCol) {
		if (halfRadius <= 0.5f)
			return;
		vector3f toCam = -center;
		if (toCam.LengthSqr() > 1e-6f)
			toCam = toCam.Normalized();
		else
			toCam = vector3f(0.0f, 0.0f, 1.0f);
		vector3f camRight = upF.Cross(toCam);
		if (camRight.LengthSqr() < 1e-6f)
			camRight = vector3f(1.0f, 0.0f, 0.0f).Cross(toCam);
		camRight = camRight.NormalizedSafe() * halfRadius;
		const vector3f camUp = toCam.Cross(camRight).NormalizedSafe() * halfRadius;

		const vector3f p00 = center - camRight - camUp;
		const vector3f p10 = center + camRight - camUp;
		const vector3f p11 = center + camRight + camUp;
		const vector3f p01 = center - camRight + camUp;

		m_lightningBloomVerts.Add(p00, glareCol, vector2f(-1.0f, -1.0f));
		m_lightningBloomVerts.Add(p10, glareCol, vector2f(1.0f, -1.0f));
		m_lightningBloomVerts.Add(p11, glareCol, vector2f(1.0f, 1.0f));
		m_lightningBloomVerts.Add(p00, glareCol, vector2f(-1.0f, -1.0f));
		m_lightningBloomVerts.Add(p11, glareCol, vector2f(1.0f, 1.0f));
		m_lightningBloomVerts.Add(p01, glareCol, vector2f(-1.0f, 1.0f));
	};

	vector3f endPt = topPt;
	for (int i = 1; i <= mainSegs; ++i) {
		const double frac = double(i) / double(mainSegs);
		const double curH = (topRelY - baseRelY) * (1.0 - frac);
		const double jitterAmp = (i == mainSegs) ? 20.0 : (70.0 + 50.0 * (1.0 - frac));
		const vector3d offset = latAxis * (double(LcgSigned(rng)) * jitterAmp) +
			horizDir * (double(LcgSigned(rng)) * jitterAmp * 0.45);
		const vector3f nextPt = vector3f(centerBase + up * curH + offset);

		emitLayeredSegment(prevPt, nextPt, 1.0f, 1.0f);

		// Spawn 2-3 forked side branches from upper/mid trunk segments
		if (i >= 2 && i <= mainSegs - 3 && LcgUnit(rng) < 0.45f) {
			vector3f forkStart = nextPt;
			const vector3d forkSide = (latAxis * double(LcgSigned(rng)) + horizDir * double(LcgSigned(rng))).NormalizedSafe();
			const int forkSegs = 4;
			for (int f = 1; f <= forkSegs; ++f) {
				const vector3f forkNext = forkStart + vector3f(
					(forkSide * (90.0 + 70.0 * double(LcgUnit(rng))) -
						up * (140.0 + 110.0 * double(LcgUnit(rng))) +
						latAxis * (45.0 * double(LcgSigned(rng)))));
				emitLayeredSegment(forkStart, forkNext, 0.55f, 0.72f);
				forkStart = forkNext;
			}
		}

		prevPt = nextPt;
		endPt = nextPt;
	}

	// Volumetric cloud-belly discharge glow and ground touchdown flash bloom
	const float cloudGlowR = std::clamp(distanceM * 0.24f, 180.0f, 920.0f) * (0.45f + 0.55f * intensity);
	const float groundGlowR = std::clamp(distanceM * 0.09f, 55.0f, 320.0f) * (0.45f + 0.55f * intensity);
	emitBloomDisc(topPt, cloudGlowR, scaleAdditiveCol(145.0f, 185.0f, 255.0f, intensity * 0.58f));
	emitBloomDisc(endPt, groundGlowR, scaleAdditiveCol(175.0f, 210.0f, 255.0f, intensity * 0.65f));

	const float glareFade = Clamp((intensity - 0.12f) / 0.88f, 0.0f, 1.0f);
	if (glareFade > 0.001f) {
		Color topGlareCol = scaleAdditiveCol(165.0f, 200.0f, 255.0f, intensity * 0.85f);
		topGlareCol.a = Uint8(Clamp(glareFade * 95.0f, 0.0f, 255.0f));
		emitGlareQuad(topPt, std::clamp(distanceM * 0.14f, 110.0f, 520.0f) * glareFade, topGlareCol);

		Color endGlareCol = scaleAdditiveCol(215.0f, 232.0f, 255.0f, Clamp(intensity * 1.05f, 0.0f, 1.0f));
		endGlareCol.a = Uint8(Clamp(glareFade * 185.0f, 0.0f, 255.0f));
		emitGlareQuad(endPt, std::clamp(distanceM * 0.075f, 48.0f, 280.0f) * glareFade, endGlareCol);
	}

	m_lightningVisible = (m_lightningVerts.GetNumVerts() >= 3);
}

void WeatherEffects::Update(float timeStep)
{
	PROFILE_SCOPED();
	if (!m_ship || m_ship->IsDead()) {
		m_precipVisible = false;
		m_volcanicVisible = false;
		m_lightningVisible = false;
		return;
	}

	const Ship::FlightState fs = m_ship->GetFlightState();
	if (fs == Ship::SUPERCRUISE || fs == Ship::HYPERSPACE) {
		m_precipVisible = false;
		m_volcanicVisible = false;
		m_lightningVisible = false;
		return;
	}

	if (fs == Ship::DOCKED) {
		const SpaceStation *station = m_ship->GetDockedWith();
		if (!station || !station->IsGroundStation()) {
			m_precipVisible = false;
			m_volcanicVisible = false;
			m_lightningVisible = false;
			return;
		}
	}

	const Frame *frame = Frame::GetFrame(m_ship->GetFrame());
	const Body *astro = frame ? frame->GetBody() : nullptr;
	if (!frame || !frame->IsRotFrame() || !astro || !astro->IsType(ObjectType::PLANET)) {
		m_precipVisible = false;
		m_volcanicVisible = false;
		m_lightningVisible = false;
		return;
	}

	const Planet *planet = static_cast<const Planet *>(astro);
	const SystemBody *sbody = planet->GetSystemBody();
	if (!sbody) {
		m_precipVisible = false;
		m_volcanicVisible = false;
		m_lightningVisible = false;
		return;
	}

	const double gameTime = Pi::game ? Pi::game->GetTime() : 0.0;
	const WeatherState weather = planet->GetWeatherState(m_ship->GetPosition(), gameTime);
	const double cloudCeiling = (weather.lowerCloudAltM > 100.0)
		? weather.lowerCloudAltM
		: Clamp(sbody->GetRadius() * 0.0012, 2400.0, 5500.0);

	if (!weather.hasAtmosphere) {
		m_precipVisible = false;
		m_volcanicVisible = false;
		m_lightningVisible = false;
		return;
	}

	vector3d east, north, up;
	WeatherSystem::BuildLocalENU(m_ship->GetPosition(), east, north, up);

	const bool isPaused = (Pi::game && Pi::game->IsPaused()) || (timeStep <= 0.0f);
	const double agl = m_ship->GetAltitudeRelTo(planet, AltitudeType::ABOVE_TERRAIN);
	const vector3d shipVel = (fs == Ship::DOCKED || fs == Ship::LANDED) ? vector3d(0.0) : m_ship->GetVelocity();

	// 1. Forked lightning bolts in storms
	m_lightningVisible = false;
	if (weather.altitudeM <= cloudCeiling * 1.18 && weather.lightningActivity > 0.05) {
		const LightningFlash flash = WeatherSystem::SampleLightningFlash(sbody->GetSeed(), gameTime, weather.lightningActivity);
		if (flash.intensity > 0.02f) {
			BuildLightningBolt(east, north, up, agl, cloudCeiling, flash.distanceM, flash.azimuthRad, flash.boltSeed, flash.intensity);
		}
	}

	// 2. Precipitation & blowing dust streaks
	m_precipVisible = false;
	if (weather.altitudeM <= cloudCeiling * 1.18 && weather.precipType != PrecipitationType::NONE && weather.precipIntensity > 0.05) {
		vector3d fallVel(0.0);
		vector3d windMult = weather.windVec;
		Color baseCol(198, 222, 245, 232);
		float minStreak = 0.5f;
		float maxStreak = 6.0f;
		float streakTimeScale = 0.052f;
		bool hasValidPrecip = true;

		switch (weather.precipType) {
		case PrecipitationType::RAIN:
			fallVel = -up * (15.5 + 5.5 * weather.stormIntensity);
			baseCol = Color(198, 222, 245, 232);
			minStreak = 0.75f;
			maxStreak = 6.2f;
			streakTimeScale = 0.052f;
			break;
		case PrecipitationType::SNOW:
			fallVel = -up * 2.4;
			baseCol = Color(235, 242, 252, 215);
			minStreak = 0.18f;
			maxStreak = 1.2f;
			streakTimeScale = 0.032f;
			break;
		case PrecipitationType::DUST: {
			fallVel = -up * 1.2;
			windMult = weather.windVec * 1.15;
			const Color dust = sbody->CalcSurfaceDustColor();
			baseCol = Color(dust.r, dust.g, dust.b, 200);
			minStreak = 0.40f;
			maxStreak = 3.8f;
			streakTimeScale = 0.040f;
			break;
		}
		case PrecipitationType::ASH:
			fallVel = -up * 2.0;
			baseCol = Color(95, 88, 84, 195);
			minStreak = 0.22f;
			maxStreak = 1.6f;
			streakTimeScale = 0.035f;
			break;
		default:
			hasValidPrecip = false;
			break;
		}

		if (hasValidPrecip) {
			const vector3d relVelD = fallVel + windMult - shipVel;
			const double relSpeedD = relVelD.Length();
			const vector3f relVel = vector3f(relVelD);
			const vector3f relDir = (relSpeedD > 1e-4) ? vector3f(relVelD / relSpeedD) : vector3f(-up);

			const float altFade = float(1.0 - Clamp((weather.altitudeM - cloudCeiling * 0.85) / std::max(1.0, cloudCeiling * 0.33), 0.0, 1.0));
			const int activeCount = Clamp(int(180.0 + 1620.0 * std::pow(weather.precipIntensity, 0.85)), 0, NUM_PARTICLES);
			const float streakLen = Clamp(float(relSpeedD) * streakTimeScale, minStreak, maxStreak);
			const vector3f streakVec = relDir * streakLen;
			const float intensityAlpha = float(Clamp(0.36 + 0.62 * weather.precipIntensity + 0.12 * weather.stormIntensity, 0.0, 0.98)) * altFade;

			if (activeCount > 0 && intensityAlpha > 0.02f) {
				m_precipVerts.Clear();
				const vector3f step = relVel * timeStep;
				const vector3f swirlAxis = vector3f(east);

				for (int i = 0; i < activeCount; ++i) {
					const float bounds = (i < NEAR_PARTICLES) ? NEAR_BOUNDS : BOX_BOUNDS;
					vector3f &pt = m_particles[i];
					if (!isPaused) {
						vector3f curStep = step;
						if (weather.precipType == PrecipitationType::SNOW || weather.precipType == PrecipitationType::ASH) {
							const float swirl = std::sin(float(gameTime * 2.2) + float(i) * 0.73f) * 1.4f * timeStep;
							curStep += swirlAxis * swirl;
						}
						pt.x = WrapCoord(pt.x + curStep.x, bounds);
						pt.y = WrapCoord(pt.y + curStep.y, bounds);
						pt.z = WrapCoord(pt.z + curStep.z, bounds);
					}

					const float distFade = Clamp(1.0f - pt.Length() / bounds, 0.0f, 1.0f);
					Color cHead = baseCol;
					cHead.a = Uint8(Clamp(float(baseCol.a) * intensityAlpha * distFade, 0.0f, 255.0f));
					if (cHead.a < 4)
						continue;
					Color cTail = cHead;
					cTail.a = Uint8(float(cHead.a) * 0.35f);

					m_precipVerts.Add(pt, cHead);
					m_precipVerts.Add(pt - streakVec, cTail);
				}

				m_precipVisible = (m_precipVerts.GetNumVerts() >= 2);
			}
		}
	}

	// 3. Atmosphere-dependent volcanic steam / smoke / rising embers at low altitude
	m_volcanicVisible = false;
	const double volc = sbody->GetVolcanicity();
	if (volc >= 0.40 && agl < 2000.0) {
		double pressure = 0.0, density = 0.0;
		planet->GetAtmosphericState(m_ship->GetPosition().Length(), &pressure, &density);
		if (pressure >= 0.005) {
			const float volcFactor = Clamp(float((volc - 0.35) / 0.65), 0.15f, 1.0f);
			const float altFade = Clamp(float(1.0 - agl / 2000.0), 0.0f, 1.0f);
			const float atmScale = Clamp(float(pressure / 0.18), 0.20f, 1.0f);
			const bool humidSteam = (sbody->GetVolatileLiquid() > 0.05) ||
				(weather.precipType == PrecipitationType::RAIN) ||
				(weather.climateZone == ClimateZone::TROPICAL) ||
				(weather.climateZone == ClimateZone::TEMPERATE);

			const vector3d plumeVelD = up * (humidSteam ? 3.2 : 2.6) + weather.windVec * 0.85 - shipVel;
			const double relSpeedD = plumeVelD.Length();
			const vector3f plumeVel = vector3f(plumeVelD);
			const vector3f plumeDir = (relSpeedD > 1e-4) ? vector3f(plumeVelD / relSpeedD) : vector3f(up);
			const float streakLen = Clamp(float(relSpeedD) * 0.045f, 0.28f, 2.2f);
			const vector3f streakVec = plumeDir * streakLen;

			const int activeCount = Clamp(int(120.0f + 240.0f * volcFactor), 0, NUM_VOLCANIC_PARTICLES);
			const float alphaScale = volcFactor * altFade * atmScale;
			if (activeCount > 0 && alphaScale > 0.02f) {
				m_volcanicVerts.Clear();
				const vector3f baseStep = plumeVel * timeStep;
				const vector3f swirlEast = vector3f(east);
				const vector3f swirlNorth = vector3f(north);

				for (int i = 0; i < activeCount; ++i) {
					vector3f &pt = m_volcanicParticles[i];
					if (!isPaused) {
						const float swirlA = std::sin(float(gameTime * 1.4) + float(i) * 0.61f) * 0.85f * timeStep;
						const float swirlB = std::cos(float(gameTime * 1.1) + float(i) * 0.43f) * 0.85f * timeStep;
						const vector3f curStep = baseStep + swirlEast * swirlA + swirlNorth * swirlB;
						pt.x = WrapCoord(pt.x + curStep.x, VOLCANIC_BOUNDS);
						pt.y = WrapCoord(pt.y + curStep.y, VOLCANIC_BOUNDS);
						pt.z = WrapCoord(pt.z + curStep.z, VOLCANIC_BOUNDS);
					}

					const float distFade = Clamp(1.0f - pt.Length() / VOLCANIC_BOUNDS, 0.0f, 1.0f);
					Color cHead;
					if (humidSteam) {
						cHead = Color(210, 206, 198, 120);
					} else if ((i & 3) == 0) {
						cHead = Color(255, 135, 38, 210);
					} else {
						cHead = Color(72, 66, 62, 130);
					}
					cHead.a = Uint8(Clamp(float(cHead.a) * alphaScale * distFade, 0.0f, 255.0f));
					if (cHead.a < 4)
						continue;

					Color cTail = cHead;
					cTail.a = Uint8(float(cHead.a) * 0.25f);
					m_volcanicVerts.Add(pt, cHead);
					m_volcanicVerts.Add(pt - streakVec * (((i & 3) == 0 && !humidSteam) ? 0.55f : 1.0f), cTail);
				}

				m_volcanicVisible = (m_volcanicVerts.GetNumVerts() >= 2);
			}
		}
	}
}

void WeatherEffects::Render(Graphics::Renderer *r)
{
	PROFILE_SCOPED();
	if (!r || (!m_precipVisible && !m_lightningVisible && !m_volcanicVisible))
		return;

	r->SetTransform(matrix4x4f(m_transform));

	if (m_precipVisible && m_precipMaterial.Valid() && m_precipVerts.GetNumVerts() >= 2) {
		r->DrawBuffer(&m_precipVerts, m_precipMaterial.Get());
	}

	if (m_volcanicVisible && m_precipMaterial.Valid() && m_volcanicVerts.GetNumVerts() >= 2) {
		r->DrawBuffer(&m_volcanicVerts, m_precipMaterial.Get());
	}

	if (m_lightningVisible) {
		if (m_lightningMaterial.Valid() && m_lightningVerts.GetNumVerts() >= 3) {
			r->DrawBuffer(&m_lightningVerts, m_lightningMaterial.Get());
		}
		if (m_lightningBloomMaterial.Valid() && m_lightningBloomVerts.GetNumVerts() >= 3) {
			r->DrawBuffer(&m_lightningBloomVerts, m_lightningBloomMaterial.Get());
		}
	}
}

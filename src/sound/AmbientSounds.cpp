// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "AmbientSounds.h"

#include "Frame.h"
#include "Game.h"
#include "Pi.h"
#include "Planet.h"
#include "Player.h"
#include "Sound.h"
#include "Space.h"
#include "SpaceStation.h"
#include "WorldView.h"
#include "planet/WeatherSystem.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

enum EAtmosphereNoiseChannels {
	eAtmoNoise1 = 0,
	eAtmoNoise2,
	eAtmoNoise3,
	eAtmoNoise4,
	eMaxNumAtmosphereSounds
};

static const char *s_airflowTable[eMaxNumAtmosphereSounds] = {
	"airflow01",
	"airflow02",
	"airflow03",
	"airflow04"
};

//	start, inverse range
static const float s_rangeTable[eMaxNumAtmosphereSounds][2] = {
	{ 0.0f, 1.0f / (1.0f - 0.0f) }, // 1
	{ 1.0f, 1.0f / (3.0f - 1.0f) }, // 2
	{ 2.0f, 1.0f / (7.0f - 3.0f) }, // 4
	{ 4.0f, 1.0f / (15.0f - 7.0f) } // 8
};

static const Uint32 NUM_SURFACE_LIFE_SOUNDS = 5;
static const char *s_surfaceLifeSounds[NUM_SURFACE_LIFE_SOUNDS] = {
	"River", "RainForestIntroducedNight", "RainForestIntroduced",
	"NormalForestIntroduced", "RainForestIndigeniusNight"
};

static const Uint32 NUM_STATION_SOUNDS = 3;
static const char *s_stationNoiseSounds[NUM_STATION_SOUNDS] = {
	"Large_Station_ambient",
	"Medium_Station_ambient",
	"Small_Station_ambient"
};

static int astroNoiseSeed;
static Sound::Event s_stationNoise;
static Sound::Event s_starNoise;
static Sound::Event s_atmosphereNoises[eMaxNumAtmosphereSounds];
static Sound::Event s_planetSurfaceNoise;
static Sound::Event s_weatherWindNoise;
static Sound::Event s_weatherStormNoise;
static std::string s_activeWeatherStormSample;
struct PendingThunder {
	float delaySec = 0.0f;
	float volL = 0.0f;
	float volR = 0.0f;
	uint32_t sampleIdx = 0;
};

static uint32_t s_lastLightningSeed = 0;
static std::vector<PendingThunder> s_pendingThunders;
static sigc::connection onChangeCamTypeConnection;

static void FadeOutWeatherSounds()
{
	if (s_weatherWindNoise.IsPlaying()) {
		s_weatherWindNoise.FadeOut(1.0f, Sound::OP_REPEAT);
	}
	if (s_weatherStormNoise.IsPlaying()) {
		s_weatherStormNoise.FadeOut(1.0f, Sound::OP_REPEAT);
	}
	s_activeWeatherStormSample.clear();
	s_pendingThunders.clear();
}

static void UpdateWeatherSounds(float v_env, bool isExterior)
{
	if (!Pi::player || !Pi::game) {
		FadeOutWeatherSounds();
		return;
	}

	const Ship::FlightState fs = Pi::player->GetFlightState();
	if (fs == Ship::SUPERCRUISE || fs == Ship::HYPERSPACE) {
		FadeOutWeatherSounds();
		return;
	}

	if (fs == Ship::DOCKED) {
		const SpaceStation *station = Pi::player->GetDockedWith();
		if (!station || !station->IsGroundStation()) {
			FadeOutWeatherSounds();
			return;
		}
	}

	Frame *playerFrame = Frame::GetFrame(Pi::player->GetFrame());
	const Body *astro = (playerFrame && playerFrame->IsRotFrame()) ? playerFrame->GetBody() : nullptr;
	if (!astro || !astro->IsType(ObjectType::PLANET)) {
		FadeOutWeatherSounds();
		return;
	}

	const Planet *planet = static_cast<const Planet *>(astro);
	const double gameTime = Pi::game->GetTime();
	const WeatherState weather = planet->GetWeatherState(Pi::player->GetPosition(), gameTime);
	if (!weather.hasAtmosphere || weather.densityKgM3 <= 0.005) {
		FadeOutWeatherSounds();
		return;
	}

	const SystemBody *sbody = planet->GetSystemBody();
	const double cloudCeiling = (weather.upperCloudAltM > 100.0)
		? weather.upperCloudAltM
		: (sbody ? Clamp(sbody->GetRadius() * 0.0022, 6500.0, 14000.0) : 10000.0);
	const float altFade = 1.0f - float(Clamp((weather.altitudeM - cloudCeiling * 0.75) / std::max(1.0, cloudCeiling * 0.65), 0.0, 1.0));
	const float densityGain = float(Clamp(weather.densityKgM3 / 1.225, 0.05, 1.35));

	const float windNorm = float(Clamp((weather.totalWindSpeed - 3.0) / 36.0 + 0.35 * weather.turbulence, 0.0, 1.0));
	const float targetWindVol = Clamp(windNorm * densityGain * altFade * 0.50f, 0.0f, 0.60f) * v_env;
	if (targetWindVol > 0.01f) {
		if (s_weatherWindNoise.IsPlaying()) {
			s_weatherWindNoise.VolumeAnimate(targetWindVol, targetWindVol, 0.6f, 0.6f);
		} else {
			s_weatherWindNoise.Play("Wind", targetWindVol, targetWindVol, Sound::OP_REPEAT);
		}
	} else if (s_weatherWindNoise.IsPlaying()) {
		s_weatherWindNoise.FadeOut(1.0f, Sound::OP_REPEAT);
	}

	const float precipDrive = (weather.precipType != PrecipitationType::NONE) ? float(weather.precipIntensity) : 0.0f;
	const float stormNorm = std::max(precipDrive, float(Clamp((weather.stormIntensity - 0.25) / 0.75, 0.0, 1.0)));
	const float targetStormVol = Clamp(stormNorm * densityGain * altFade * 0.38f, 0.0f, 0.45f) * v_env;
	const char *wantedSample = (weather.precipType == PrecipitationType::RAIN && weather.stormIntensity < 0.42) ? "Rain_Light" : "Storm";

	if (targetStormVol > 0.01f) {
		if (s_weatherStormNoise.IsPlaying() && s_activeWeatherStormSample != wantedSample) {
			s_weatherStormNoise.Stop();
			s_activeWeatherStormSample = wantedSample;
			s_weatherStormNoise.Play(wantedSample, targetStormVol, targetStormVol, Sound::OP_REPEAT);
		} else if (s_weatherStormNoise.IsPlaying()) {
			s_weatherStormNoise.VolumeAnimate(targetStormVol, targetStormVol, 0.5f, 0.5f);
		} else {
			s_activeWeatherStormSample = wantedSample;
			s_weatherStormNoise.Play(wantedSample, targetStormVol, targetStormVol, Sound::OP_REPEAT);
		}
	} else if (s_weatherStormNoise.IsPlaying()) {
		s_weatherStormNoise.FadeOut(1.0f, Sound::OP_REPEAT);
		s_activeWeatherStormSample.clear();
	}

	if (sbody && weather.lightningActivity > 0.05 && altFade > 0.05f) {
		const LightningFlash flash = WeatherSystem::SampleLightningFlash(sbody->GetSeed(), gameTime, weather.lightningActivity);
		if (flash.triggeredThisWindow && flash.boltSeed != 0 && flash.boltSeed != s_lastLightningSeed) {
			s_lastLightningSeed = flash.boltSeed;
			const size_t maxQueued = (Pi::game->GetTimeAccel() > Game::TIMEACCEL_1X) ? 1u : 4u;
			if (s_pendingThunders.size() < maxQueued) {
				vector3d east, north, up;
				WeatherSystem::BuildLocalENU(Pi::player->GetPosition(), east, north, up);
				const vector3d strikeDirHoriz = east * std::cos(double(flash.azimuthRad)) + north * std::sin(double(flash.azimuthRad));
				const vector3d shipRight = Pi::player->GetOrient().VectorX();
				const float pan = Clamp(float(strikeDirHoriz.Dot(shipRight)) * 0.55f, -0.55f, 0.55f);

				const float delaySec = Clamp(flash.distanceM / 340.0f, 0.9f, 6.5f);
				const float distAtten = Clamp(1.18f - (flash.distanceM / 5800.0f), 0.32f, 1.0f);
				const float hullScale = isExterior ? 1.0f : 0.74f;
				// Note: Sound::PlaySfx already scales by Sound::GetSfxVolume() inside the backend
				const float baseVol = Clamp(0.95f * distAtten * Clamp(densityGain, 0.35f, 1.25f) * altFade * hullScale, 0.16f, 1.0f);
				const float volL = Clamp(baseVol * (1.0f - pan * 0.45f), 0.08f, 1.0f);
				const float volR = Clamp(baseVol * (1.0f + pan * 0.45f), 0.08f, 1.0f);
				s_pendingThunders.push_back({ delaySec, volL, volR, flash.boltSeed % 4u });
			}
		}
	}

	if (!Pi::game->IsPaused() && !s_pendingThunders.empty()) {
		static const char *const s_thunderSamples[4] = { "Thunder_1", "Thunder_2", "Thunder_3", "Thunder_4" };
		const float dt = std::max(0.0f, Pi::GetFrameTime());
		for (auto it = s_pendingThunders.begin(); it != s_pendingThunders.end();) {
			it->delaySec -= dt;
			if (it->delaySec <= 0.0f) {
				Sound::PlaySfx(s_thunderSamples[it->sampleIdx], it->volL, it->volR, 0);
				it = s_pendingThunders.erase(it);
			} else {
				++it;
			}
		}
	}
}

void AmbientSounds::Init()
{
	onChangeCamTypeConnection = Pi::game->GetWorldView()->shipView->onChangeCamType.connect(sigc::ptr_fun(&AmbientSounds::UpdateForCamType));
}

void AmbientSounds::Uninit()
{
	onChangeCamTypeConnection.disconnect();
	FadeOutWeatherSounds();
	s_lastLightningSeed = 0;
}

void AmbientSounds::Update()
{
	const bool isExterior = Pi::game->GetWorldView()->shipView->IsExteriorView();
	const float v_env = (isExterior ? 1.0f : 0.5f) * Sound::GetSfxVolume();
	UpdateWeatherSounds(v_env, isExterior);

	if (Pi::player->GetFlightState() == Ship::DOCKED) {
		if (s_starNoise.IsPlaying()) {
			s_starNoise.FadeOut(1.0f, Sound::OP_REPEAT);
		}
		for (int i = 0; i < eMaxNumAtmosphereSounds; i++) {
			if (s_atmosphereNoises[i].IsPlaying()) {
				s_atmosphereNoises[i].FadeOut(1.0f, Sound::OP_REPEAT);
			}
		}
		if (s_planetSurfaceNoise.IsPlaying()) {
			s_planetSurfaceNoise.FadeOut(1.0f, Sound::OP_REPEAT);
		}

		if (!s_stationNoise.IsPlaying()) {
			// just use a random station noise until we have a
			// concept of 'station size'
			s_stationNoise.Play(s_stationNoiseSounds[Pi::player->GetDockedWith()->GetSystemBody()->GetSeed() % NUM_STATION_SOUNDS],
				0.3f * v_env, 0.3f * v_env, Sound::OP_REPEAT);
		}
	} else if (Pi::player->GetFlightState() == Ship::LANDED) {
		/* Planet surface noise on rough-landing */
		if (s_starNoise.IsPlaying()) {
			s_starNoise.FadeOut(1.0f, Sound::OP_REPEAT);
		}
		for (int i = 0; i < eMaxNumAtmosphereSounds; i++) {
			if (s_atmosphereNoises[i].IsPlaying()) {
				s_atmosphereNoises[i].FadeOut(1.0f, Sound::OP_REPEAT);
			}
		}
		if (s_stationNoise.IsPlaying()) {
			s_stationNoise.FadeOut(1.0f, Sound::OP_REPEAT);
		}

		// Dynamic weather sounds (Wind, Rain_Light, Storm, Thunder_1..4) are handled by UpdateWeatherSounds().
		if (!s_planetSurfaceNoise.IsPlaying()) {
			Frame *pFrame = Frame::GetFrame(Pi::player->GetFrame());
			const SystemBody *sbody = pFrame ? pFrame->GetSystemBody() : nullptr;
			if (!sbody) return;
			const char *sample = nullptr;

			if (sbody->GetLifeAsFixed() > fixed(1, 5)) {
				sample = s_surfaceLifeSounds[sbody->GetSeed() % NUM_SURFACE_LIFE_SOUNDS];
			}

			if (sample) {
				s_planetSurfaceNoise.Play(sample, 0.3f * v_env, 0.3f * v_env, Sound::OP_REPEAT);
			}
		}
	} else if (s_planetSurfaceNoise.IsPlaying()) {
		// s_planetSurfaceNoise.IsPlaying() - if player is no longer on the ground then stop playing
		Frame *playerFrame = Frame::GetFrame(Pi::player->GetFrame());
		if (playerFrame && playerFrame->IsRotFrame()) {
			const Body *astro = playerFrame->GetBody();
			if (astro && astro->IsType(ObjectType::PLANET)) {
				const double dist = Pi::player->GetPosition().Length();
				double pressure, density;
				static_cast<const Planet *>(astro)->GetAtmosphericState(dist, &pressure, &density);
				if (Pi::player->GetFlightState() != Ship::LANDED) {
					// Stop playing surface noise once the ship is off the ground
					s_planetSurfaceNoise.Stop();
				}
			}
		} else if (Pi::game->IsHyperspace()) {
			s_planetSurfaceNoise.Stop();
		}
	} else {
		if (s_stationNoise.IsPlaying()) {
			s_stationNoise.FadeOut(1.0f, Sound::OP_REPEAT);
		}
		if (Pi::game->IsNormalSpace()) {
			StarSystem *s = Pi::game->GetSpace()->GetStarSystem().Get();
			if (astroNoiseSeed != s->GetSeed()) {
				// change sound!
				astroNoiseSeed = s->GetSeed();
				s_starNoise.FadeOut(0.1f, Sound::OP_REPEAT);
				// XXX the way Sound::Event works isn't totally obvious.
				// to destroy the object doesn't stop the sound. it is
				// really just a sound event reference
				s_starNoise = Sound::Event();
			}
		}
		// when all the sounds are in we can use the body we are in frame of reference to
		if (!s_starNoise.IsPlaying()) {
			Frame *f = Frame::GetFrame(Pi::player->GetFrame());
			if (!f) return; // When player has no frame (game abort) then get outta here!!
			const SystemBody *sbody = f->GetSystemBody();
			const char *sample = 0;
			for (; sbody && !sample; sbody = f->GetSystemBody()) {
				switch (sbody->GetType()) {
				case SystemBody::TYPE_BROWN_DWARF: sample = "Brown_Dwarf_Substellar_Object"; break;
				case SystemBody::TYPE_STAR_M: sample = "M_Red_Star"; break;
				case SystemBody::TYPE_STAR_K: sample = "K_Star"; break;
				case SystemBody::TYPE_WHITE_DWARF: sample = "White_Dwarf_Star"; break;
				case SystemBody::TYPE_STAR_G: sample = "G_Star"; break;
				case SystemBody::TYPE_STAR_F: sample = "F_Star"; break;
				case SystemBody::TYPE_STAR_A: sample = "A_Star"; break;
				case SystemBody::TYPE_STAR_B: sample = "B_Hot_Blue_STAR"; break;
				case SystemBody::TYPE_STAR_O: sample = "Blue_Super_Giant"; break;
				case SystemBody::TYPE_PLANET_GAS_GIANT: {
					if (sbody->GetMassAsFixed() > fixed(400, 1)) {
						sample = "Very_Large_Gas_Giant";
					} else if (sbody->GetMassAsFixed() > fixed(80, 1)) {
						sample = "Large_Gas_Giant";
					} else if (sbody->GetMassAsFixed() > fixed(20, 1)) {
						sample = "Medium_Gas_Giant";
					} else {
						sample = "Small_Gas_Giant";
					}
				} break;
				default: sample = 0; break;
				}
				if (sample) {
					s_starNoise.Play(sample, 0.0f, 0.0f, Sound::OP_REPEAT);
					s_starNoise.VolumeAnimate(.3f * v_env, .3f * v_env, .05f, .05f);
				} else {
					// go up orbital hierarchy tree to see if we can find a sound
					FrameId parent = f->GetParent();
					f = Frame::GetFrame(parent);
					if (f == nullptr) break;
				}
			}
		}

		Frame *playerFrame = Frame::GetFrame(Pi::player->GetFrame());
		const Body *astro = playerFrame->GetBody();
		if (astro && playerFrame->IsRotFrame() && (astro->IsType(ObjectType::PLANET))) {
			double dist = Pi::player->GetPosition().Length();
			double pressure, density;
			static_cast<const Planet *>(astro)->GetAtmosphericState(dist, &pressure, &density);
			// maximum volume at around 2km/sec at earth density, pressure
			const float pressureVolume = float(density * Pi::player->GetVelocity().Length() * 0.0005);
			//volume = Clamp(volume, 0.0f, 1.0f) * v_env;
			float volumes[eMaxNumAtmosphereSounds];
			for (int i = 0; i < eMaxNumAtmosphereSounds; i++) {
				const float beg = s_rangeTable[i][0];
				const float inv = s_rangeTable[i][1];
				volumes[i] = Clamp((pressureVolume - beg) * inv, 0.0f, 1.0f) * v_env;
			}

			for (int i = 0; i < eMaxNumAtmosphereSounds; i++) {
				const float volume = volumes[i];
				if (s_atmosphereNoises[i].IsPlaying()) {
					const float target[2] = { volume, volume };
					const float dv_dt[2] = { 1.0f, 1.0f };
					s_atmosphereNoises[i].VolumeAnimate(target, dv_dt);
				} else {
					s_atmosphereNoises[i].Play(s_airflowTable[i], volume, volume, Sound::OP_REPEAT);
				}
			}
		} else {
			for (int i = 0; i < eMaxNumAtmosphereSounds; i++) {
				s_atmosphereNoises[i].FadeOut(1.0f, Sound::OP_REPEAT);
			}
		}
	}
}

void AmbientSounds::UpdateForCamType()
{
	const ShipViewController::CamType cam = Pi::game->GetWorldView()->shipView->GetCamType();
	float v_env = (cam == ShipViewController::CAM_EXTERNAL ? 1.0f : 0.5f) * Sound::GetSfxVolume();

	if (s_stationNoise.IsPlaying())
		s_stationNoise.SetVolume(0.3f * v_env, 0.3f * v_env);
	if (s_starNoise.IsPlaying())
		s_starNoise.SetVolume(0.3f * v_env, 0.3f * v_env);
	if (s_planetSurfaceNoise.IsPlaying())
		s_planetSurfaceNoise.SetVolume(0.3f * v_env, 0.3f * v_env);
}

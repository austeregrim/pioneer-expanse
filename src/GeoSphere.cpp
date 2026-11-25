// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "GeoSphere.h"

#include "Game.h"
#include "GameConfig.h"
#include "GeoPatch.h"
#include "GeoPatchContext.h"
#include "GeoPatchJobs.h"
#include "Pi.h"
#include "RefCounted.h"
#include "galaxy/AtmosphereParameters.h"
#include "galaxy/StarSystem.h"
#include "planet/WeatherSystem.h"
#include "graphics/Drawables.h"
#include "graphics/Frustum.h"
#include "graphics/Graphics.h"
#include "graphics/Material.h"
#include "graphics/RenderState.h"
#include "graphics/Renderer.h"
#include "graphics/Texture.h"
#include "graphics/TextureBuilder.h"
#include "graphics/Types.h"
#include "graphics/VertexArray.h"
#include "perlin.h"
#include "utils.h"
#include "vcacheopt/vcacheopt.h"
#include <algorithm>
#include <deque>

RefCountedPtr<GeoPatchContext> GeoSphere::s_patchContext;

// must be odd numbers
static const int detail_edgeLen[5] = {
	//7, 15, 25, 35, 55 -- old non power-of-2+1 values
	// some detail settings duplicated intentionally
	// in real terms provides only 3 settings
	// however this value is still used for gas giants
	// with 5 distinct settings elsewhere
	9, 17, 17, 33, 33
};

static const double detail_targetTriLength[5] = { 120.0, 80.0, 55.0, 38.0, 25.0 };
static std::vector<GeoSphere *> s_allGeospheres;
static Uint32 s_debugFlags = GeoSphere::DebugFlags::DEBUG_NONE;

void GeoSphere::InitGeoSphere()
{
	s_patchContext.Reset(new GeoPatchContext(detail_edgeLen[Pi::detail.planets > 4 ? 4 : Pi::detail.planets]));
}

void GeoSphere::UninitGeoSphere()
{
	assert(s_patchContext.Unique());
	s_patchContext.Reset();
}

static void print_info(const SystemBody *sbody, const Terrain *terrain)
{
	Log::Verbose(
		"Geosphere Init for {}:\n" \
		"\theight fractal: {}\n" \
		"\tcolour fractal: {}\n" \
		"\tseed: {}\n",
		sbody->GetName(), terrain->GetHeightFractalName(), terrain->GetColorFractalName(), sbody->GetSeed());
}

// static
void GeoSphere::UpdateAllGeoSpheres()
{
	PROFILE_SCOPED()
	for (std::vector<GeoSphere *>::iterator i = s_allGeospheres.begin(); i != s_allGeospheres.end(); ++i) {
		(*i)->Update();
	}
}

// static
void GeoSphere::OnChangeGeoSphereDetailLevel()
{
	s_patchContext.Reset(new GeoPatchContext(detail_edgeLen[Pi::detail.planets > 4 ? 4 : Pi::detail.planets]));

	// reinit the geosphere terrain data
	for (std::vector<GeoSphere *>::iterator i = s_allGeospheres.begin(); i != s_allGeospheres.end(); ++i) {
		// clearout anything we don't need
		(*i)->Reset();

		// reinit the terrain with the new settings
		(*i)->m_terrain.Reset(Terrain::InstanceTerrain((*i)->GetSystemBody()));
		print_info((*i)->GetSystemBody(), (*i)->m_terrain.Get());

		// Reload the surface and atmosphere material (scattering option)
		if ((*i)->m_surfaceMaterial.Valid()) {
			(*i)->SetUpMaterials();
		}
	}
}

//static
bool GeoSphere::OnAddQuadSplitResult(const SystemPath &path, SQuadSplitResult *res)
{
	// Find the correct GeoSphere via it's system path, and give it the split result
	for (std::vector<GeoSphere *>::iterator i = s_allGeospheres.begin(), iEnd = s_allGeospheres.end(); i != iEnd; ++i) {
		if (path == (*i)->GetSystemBody()->GetPath()) {
			(*i)->AddQuadSplitResult(res);
			return true;
		}
	}
	// GeoSphere not found to return the data to, cancel and delete it instead
	if (res) {
		res->OnCancel();
		delete res;
	}
	return false;
}

//static
bool GeoSphere::OnAddSingleSplitResult(const SystemPath &path, SSingleSplitResult *res)
{
	// Find the correct GeoSphere via it's system path, and give it the split result
	for (std::vector<GeoSphere *>::iterator i = s_allGeospheres.begin(), iEnd = s_allGeospheres.end(); i != iEnd; ++i) {
		if (path == (*i)->GetSystemBody()->GetPath()) {
			(*i)->AddSingleSplitResult(res);
			return true;
		}
	}
	// GeoSphere not found to return the data to, cancel and delete it instead
	if (res) {
		res->OnCancel();
		delete res;
	}
	return false;
}

//static
void GeoSphere::SetDebugFlags(Uint32 flags)
{
	s_debugFlags = flags;
}

//static
Uint32 GeoSphere::GetDebugFlags()
{
	return s_debugFlags;
}

void GeoSphere::Reset()
{
	{
		std::deque<SSingleSplitResult *>::iterator iter = mSingleSplitResults.begin();
		while (iter != mSingleSplitResults.end()) {
			// finally pass SplitResults
			SSingleSplitResult *psr = (*iter);
			assert(psr);

			psr->OnCancel();

			// tidyup
			delete psr;

			// Next!
			++iter;
		}
		mSingleSplitResults.clear();
	}

	{
		std::deque<SQuadSplitResult *>::iterator iter = mQuadSplitResults.begin();
		while (iter != mQuadSplitResults.end()) {
			// finally pass SplitResults
			SQuadSplitResult *psr = (*iter);
			assert(psr);

			psr->OnCancel();

			// tidyup
			delete psr;

			// Next!
			++iter;
		}
		mQuadSplitResults.clear();
	}

	for (int p = 0; p < NUM_PATCHES; p++) {
		// delete patches
		if (m_patches[p]) {
			m_patches[p].reset();
		}
	}

	CalculateMaxPatchDepth();

	m_visiblePatches.reserve(1024);

	m_initStage = eBuildFirstPatches;
}

GeoSphere::GeoSphere(const SystemBody *body) :
	BaseSphere(body),
	m_hasTempCampos(false),
	m_tempCampos(0.0),
	m_tempFrustum(800, 600, 0.5, 1.0, 1000.0),
	m_initStage(eBuildFirstPatches),
	m_maxDepth(0)
{
	print_info(body, m_terrain.Get());

	s_allGeospheres.emplace_back(this);

	CalculateMaxPatchDepth();

	m_visiblePatches.reserve(1024);

	if (Pi::config->Int("SortGeoPatches") == 0) {
		SetDebugFlags(GetDebugFlags() & ~DebugFlags::DEBUG_SORTGEOPATCHES);
	} else {
		SetDebugFlags(GetDebugFlags() | DebugFlags::DEBUG_SORTGEOPATCHES);
	}

	//SetUpMaterials is not called until first Render since light count is zero :)
}

GeoSphere::~GeoSphere()
{
	// update thread should not be able to access us now, so we can safely continue to delete
	assert(std::count(s_allGeospheres.begin(), s_allGeospheres.end(), this) == 1);
	s_allGeospheres.erase(std::find(s_allGeospheres.begin(), s_allGeospheres.end(), this));
}

bool GeoSphere::AddQuadSplitResult(SQuadSplitResult *res)
{
	bool result = false;
	assert(res);
	assert(mQuadSplitResults.size() < MAX_SPLIT_OPERATIONS);
	if (mQuadSplitResults.size() < MAX_SPLIT_OPERATIONS) {
		mQuadSplitResults.emplace_back(res);
		result = true;
	}
	return result;
}

bool GeoSphere::AddSingleSplitResult(SSingleSplitResult *res)
{
	bool result = false;
	assert(res);
	assert(mSingleSplitResults.size() < MAX_SPLIT_OPERATIONS);
	if (mSingleSplitResults.size() < MAX_SPLIT_OPERATIONS) {
		mSingleSplitResults.emplace_back(res);
		result = true;
	}
	return result;
}

void GeoSphere::ProcessSplitResults()
{
	PROFILE_SCOPED()
	// now handle the single split results that define the base level of the quad tree
	{
		std::deque<SSingleSplitResult *>::iterator iter = mSingleSplitResults.begin();
		while (iter != mSingleSplitResults.end()) {
			// finally pass SplitResults
			SSingleSplitResult *psr = (*iter);
			assert(psr);

			const int32_t faceIdx = psr->face();
			if (m_patches[faceIdx]) {
				m_patches[faceIdx]->ReceiveHeightmap(psr);
			} else {
				psr->OnCancel();
			}

			// tidyup
			delete psr;

			// Next!
			++iter;
		}
		mSingleSplitResults.clear();
	}

	// now handle the quad split results
	{
		std::deque<SQuadSplitResult *>::iterator iter = mQuadSplitResults.begin();
		while (iter != mQuadSplitResults.end()) {
			// finally pass SplitResults
			SQuadSplitResult *psr = (*iter);
			assert(psr);

			const int32_t faceIdx = psr->face();
			if (m_patches[faceIdx]) {
				m_patches[faceIdx]->ReceiveHeightmaps(psr);
			} else {
				psr->OnCancel();
			}

			// tidyup
			delete psr;

			// Next!
			++iter;
		}
		mQuadSplitResults.clear();
	}
}

void GeoSphere::BuildFirstPatches()
{
	PROFILE_SCOPED()
	assert(!m_patches[0]);
	if (m_patches[0])
		return;

	CalculateMaxPatchDepth();

	// generate root face patches of the cube/sphere
	static const vector3d p1 = (vector3d(1, 1, 1)).Normalized();
	static const vector3d p2 = (vector3d(-1, 1, 1)).Normalized();
	static const vector3d p3 = (vector3d(-1, -1, 1)).Normalized();
	static const vector3d p4 = (vector3d(1, -1, 1)).Normalized();
	static const vector3d p5 = (vector3d(1, 1, -1)).Normalized();
	static const vector3d p6 = (vector3d(-1, 1, -1)).Normalized();
	static const vector3d p7 = (vector3d(-1, -1, -1)).Normalized();
	static const vector3d p8 = (vector3d(1, -1, -1)).Normalized();

	const uint64_t maxShiftDepth = GeoPatchID::MAX_SHIFT_DEPTH;

	m_patches[0].reset(new GeoPatch(s_patchContext, this, p1, p2, p3, p4, 0, (0ULL << maxShiftDepth)));
	m_patches[1].reset(new GeoPatch(s_patchContext, this, p4, p3, p7, p8, 0, (1ULL << maxShiftDepth)));
	m_patches[2].reset(new GeoPatch(s_patchContext, this, p1, p4, p8, p5, 0, (2ULL << maxShiftDepth)));
	m_patches[3].reset(new GeoPatch(s_patchContext, this, p2, p1, p5, p6, 0, (3ULL << maxShiftDepth)));
	m_patches[4].reset(new GeoPatch(s_patchContext, this, p3, p2, p6, p7, 0, (4ULL << maxShiftDepth)));
	m_patches[5].reset(new GeoPatch(s_patchContext, this, p8, p7, p6, p5, 0, (5ULL << maxShiftDepth)));

	for (int i = 0; i < NUM_PATCHES; i++) {
		m_patches[i]->RequestSinglePatch();
	}

	m_initStage = eRequestedFirstPatches;
}

void GeoSphere::CalculateMaxPatchDepth()
{
	m_maxDepth = 0;
	const double targetTriLength = detail_targetTriLength[Clamp<int>(Pi::detail.planets, 0, 4)];
	const double circumference = 2.0 * M_PI * m_sbody->GetRadius();
	// calculate length of each edge segment (quad) times 4 due to that being the number around the sphere (1 per side, 4 sides for Root).
	double edgeMetres = circumference / double(s_patchContext->GetEdgeLen() * 8);
	// find out what depth we reach the desired resolution
	while (edgeMetres > targetTriLength && m_maxDepth < GEOPATCH_MAX_DEPTH) {
		edgeMetres *= 0.5;
		++m_maxDepth;
	}
}

void GeoSphere::Update()
{
	switch (m_initStage) {
	case eBuildFirstPatches:
		BuildFirstPatches();
		break;
	case eRequestedFirstPatches: {
		ProcessSplitResults();
		uint8_t numValidPatches = 0;
		for (int i = 0; i < NUM_PATCHES; i++) {
			if (m_patches[i]->HasHeightData()) {
				++numValidPatches;
			}
		}
		m_initStage = (NUM_PATCHES == numValidPatches) ? eReceivedFirstPatches : eRequestedFirstPatches;
	} break;
	case eReceivedFirstPatches: {
		for (int i = 0; i < NUM_PATCHES; i++) {
			m_patches[i]->SetNeedToUpdateVBOs();
		}
		m_initStage = eDefaultUpdateState;
	} break;
	case eDefaultUpdateState:
		if (m_hasTempCampos) {
			ProcessSplitResults();
			for (int i = 0; i < NUM_PATCHES; i++) {
				m_patches[i]->LODUpdate(m_tempCampos, m_tempFrustum);
			}
			ProcessQuadSplitRequests();
		}
		break;
	}
}

void GeoSphere::AddQuadSplitRequest(double dist, SQuadSplitRequest *pReq, GeoPatch *pPatch)
{
	mQuadSplitRequests.emplace_back(dist, pReq, pPatch);
}

void GeoSphere::ProcessQuadSplitRequests()
{
	std::sort(mQuadSplitRequests.begin(), mQuadSplitRequests.end(), [](TDistanceRequest &a, TDistanceRequest &b) { return a.mDistance < b.mDistance; });

	for (auto iter : mQuadSplitRequests) {
		SQuadSplitRequest *ssrd = iter.mpRequest;
		iter.mpRequester->ReceiveJobHandle(Pi::GetAsyncJobQueue()->Queue(new QuadPatchJob(ssrd)));
	}
	mQuadSplitRequests.clear();
}

void GeoSphere::Render(Graphics::Renderer *renderer, const matrix4x4d &modelView, vector3d campos, const float radius, const std::vector<Camera::Shadow> &shadows)
{
	PROFILE_SCOPED()
	// store this for later usage in the update method.
	m_tempCampos = campos;
	m_hasTempCampos = true;

	if (m_initStage < eDefaultUpdateState)
		return;

	matrix4x4d trans = modelView;
	trans.Translate(-campos.x, -campos.y, -campos.z);
	renderer->SetTransform(matrix4x4f(trans)); //need to set this for the following line to work
	matrix4x4d modv = matrix4x4d(renderer->GetTransform());
	matrix4x4d proj = matrix4x4d(renderer->GetProjection());
	Graphics::Frustum frustum(modv, proj);
	m_tempFrustum = frustum;

	// no frustum test of entire geosphere, since Space::Render does this
	// for each body using its GetBoundingRadius() value

	//First draw - create materials (they do not change afterwards)
	if (!m_surfaceMaterial)
		SetUpMaterials();

	const SystemBody *sbody = GetSystemBody();
	const double hydro = sbody ? sbody->GetVolatileLiquid() : 0.0;
	const double atmo = sbody ? std::max(0.0, sbody->GetAtmSurfaceDensity()) : 0.0;
	const bool hasWeatherAtmo = sbody && sbody->HasAtmosphere() &&
		atmo > 0.08 &&
		sbody->GetSuperType() != SystemBody::SUPERTYPE_STAR &&
		sbody->GetType() != SystemBody::TYPE_BROWN_DWARF;
	const double planetRadM = sbody ? std::max(sbody->GetRadius(), 100000.0) : 1000000.0;
	const double atmTopM = sbody ? std::max(sbody->GetAtmRadius(), 15000.0) : 15000.0;
	const double camLenD = campos.Length();
	const vector3d camDir = (camLenD > 1e-9) ? (campos / camLenD) : vector3d(0.0, 1.0, 0.0);
	const double camAltM = (camLenD - 1.0) * planetRadM;
	const double gameTime = Pi::game ? Pi::game->GetTime() : 0.0;
	WeatherState weather{};
	LightningFlash flash{};
	if (hasWeatherAtmo) {
		const double sampleAltM = std::clamp(camAltM, 0.0, std::max(1000.0, atmTopM * 0.45));
		weather = WeatherSystem::Sample(sbody, camDir, sampleAltM, gameTime);
		if (weather.hasAtmosphere) {
			flash = WeatherSystem::SampleLightningFlash(sbody->GetSeed(), gameTime, weather.lightningActivity);
		}
	}

	float coverage = 0.0f;
	if (hasWeatherAtmo) {
		if (hydro > 0.01) {
			coverage = float(Clamp(0.36 + 0.34 * std::min(hydro, 1.0) + 0.12 * std::min(atmo, 1.5), 0.32, 0.76));
		} else if (atmo > 0.35) {
			coverage = float(Clamp(0.18 + 0.24 * std::min(atmo, 2.0), 0.18, 0.56));
		}
	}

	const double altFadeT = Clamp((camAltM - 22000.0) / 108000.0, 0.0, 1.0);
	const float nearSurfaceWeight = (hasWeatherAtmo && weather.hasAtmosphere)
		? float(1.0 - altFadeT * altFadeT * (3.0 - 2.0 * altFadeT))
		: 0.0f;

	float localOvercast = 0.0f;
	float stormVal = 0.0f;
	float surfWeight = 0.0f;
	float lightningAmb = 0.0f;
	if (hasWeatherAtmo && weather.hasAtmosphere && coverage > 0.05f && m_atmos && renderer->IsEnhancedGraphicsEnabled()) {
		const float lowCov = Clamp(float(weather.lowerCloudCover), 0.0f, 1.0f);
		const float highCov = Clamp(float(weather.upperCloudCover), 0.0f, 1.0f);
		const float rawCover = Clamp(lowCov + 0.40f * highCov * (1.0f - lowCov), 0.0f, 1.0f);
		localOvercast = Clamp((rawCover - 0.18f) / 0.72f, 0.0f, 1.0f);
		stormVal = Clamp(float(weather.stormIntensity), 0.0f, 1.0f);
		surfWeight = nearSurfaceWeight;
		lightningAmb = Clamp(flash.intensity, 0.0f, 1.0f) * nearSurfaceWeight * (0.35f + 0.65f * localOvercast);
	}

	// Couple live WeatherSystem haze & aerosols to atmospheric Rayleigh/Mie UBO
	m_atmosphereParameters.weatherMieMult = 1.0f;
	m_atmosphereParameters.weatherOvercast = 0.0f;
	m_atmosphereParameters.weatherMieTint = vector3f(1.0f, 1.0f, 1.0f);
	if (hasWeatherAtmo && weather.hasAtmosphere && renderer->IsEnhancedGraphicsEnabled()) {
		const float stormW = Clamp(float(weather.stormIntensity), 0.0f, 1.0f) * nearSurfaceWeight;
		const float overcastW = localOvercast * nearSurfaceWeight;
		const float precipW = Clamp(float(weather.precipIntensity), 0.0f, 1.0f) * nearSurfaceWeight;
		float mieMult = 1.0f + 0.45f * overcastW + 0.75f * stormW;
		vector3f mieTint(1.0f, 1.0f, 1.0f);

		if (weather.precipType == PrecipitationType::DUST) {
			mieMult += 0.85f * precipW;
			mieTint = mieTint * (1.0f - precipW) + vector3f(1.28f, 0.96f, 0.62f) * precipW;
		} else if (weather.precipType == PrecipitationType::ASH) {
			mieMult += 0.95f * precipW;
			mieTint = mieTint * (1.0f - precipW) + vector3f(1.10f, 0.86f, 0.68f) * precipW;
		} else if (weather.precipType == PrecipitationType::RAIN || weather.precipType == PrecipitationType::SNOW) {
			mieMult += 0.40f * precipW;
			mieTint = mieTint * (1.0f - 0.5f * precipW) + vector3f(0.94f, 0.98f, 1.05f) * (0.5f * precipW);
		}

		m_atmosphereParameters.weatherMieMult = Clamp(mieMult, 1.0f, 2.8f);
		m_atmosphereParameters.weatherOvercast = overcastW;
		m_atmosphereParameters.weatherMieTint = mieTint;
	}

	//Update material parameters
	SetMaterialParameters(trans, radius, shadows, m_atmosphereParameters);

	if (m_atmosphereMaterial.Valid() && m_atmosphereParameters.atmosDensity > 0.0) {
		// make atmosphere sphere slightly bigger than required so
		// that the edges of the pixel shader atmosphere jizz doesn't
		// show ugly polygonal angles
		DrawAtmosphereSurface(renderer, trans, campos,
			m_atmosphereParameters.atmosRadius * 1.02,
			m_atmosphereMaterial);
	}

	Color ambient;
	Color &emission = m_surfaceMaterial->emissive;

	// save old global ambient
	const Color oldAmbient = renderer->GetAmbientColor();

	if ((GetSystemBody()->GetSuperType() == SystemBody::SUPERTYPE_STAR) || (GetSystemBody()->GetType() == SystemBody::TYPE_BROWN_DWARF)) {
		// stars should emit light and terrain should be visible from distance
		ambient.r = ambient.g = ambient.b = 51;
		ambient.a = 255;
		emission = GetSystemBody()->GetStarColor();
		emission.a = 255;
	} else {
		// give planet some ambient lighting if the viewer is close to it
		double camdist = 0.1 / campos.LengthSqr();
		// why the fuck is this returning 0.1 when we are sat on the planet??
		// JJ: Because campos is relative to a unit-radius planet - 1.0 at the surface
		// XXX oh well, it is the value we want anyway...
		ambient.r = ambient.g = ambient.b = camdist * 255;
		ambient.a = 255;
	}

	renderer->SetAmbientColor(ambient);

	// Physically scaled ocean turbulence from local atmosphere density (wind forcing) & surface gravity (restoring force)
	if (m_surfaceMaterial.Valid()) {
		const double gNorm = Clamp(sbody->CalcSurfaceGravity() / 9.80665, 0.15, 4.0);
		const double atm = atmo;
		const float stormBoost = (hasWeatherAtmo && weather.hasAtmosphere) ? float(weather.stormIntensity) * nearSurfaceWeight : 0.0f;
		const float turbulence = float(Clamp(pow(std::max(atm, 0.08), 0.55) / pow(gNorm, 0.45) + 0.35 * double(stormBoost), 0.25, 2.35));
		const float waveSpeed = float(Clamp(sqrt(gNorm) * (0.75 + 0.35 * std::min(atm, 2.5)) + 0.22 * double(stormBoost), 0.45, 2.35));
		const float whitecapFactor = float(Clamp((atm * 0.90) / pow(gNorm, 0.55) - 0.12 + 0.60 * double(stormBoost), 0.0, 2.10));
		const float waterQuality = float(Clamp(Pi::config->Int("WaterQuality", 2), 0, 3));
		static const size_t s_waterParamsHash = "WaterParams"_hash;
		m_surfaceMaterial->SetPushConstant(s_waterParamsHash, vector3f(turbulence, waveSpeed, whitecapFactor), waterQuality);

		static const size_t s_cloudWeatherHash = "CloudWeather"_hash;
		m_surfaceMaterial->SetPushConstant(s_cloudWeatherHash, vector3f(localOvercast, stormVal, surfWeight), lightningAmb);
	}

	renderer->SetTransform(matrix4x4f(modelView));

	if (s_debugFlags & GeoSphere::DebugFlags::DEBUG_WIREFRAME)
		renderer->SetWireFrameMode(true);

	if (s_debugFlags & GeoSphere::DebugFlags::DEBUG_SORTGEOPATCHES) {
		// Gather the patches that could be rendered
		for (int i = 0; i < NUM_PATCHES; i++) {
			m_patches[i]->GatherRenderablePatches(m_visiblePatches, renderer, campos, frustum);
		}

		// distance sort the patches
		std::sort(m_visiblePatches.begin(), m_visiblePatches.end(), [&, campos](const std::pair<double, GeoPatch *> &a, const std::pair<double, GeoPatch *> &b) {
			return (a.first) < (b.first);
		});

		// cull occluded patches somehow?
		// create frustum from corner points, something vertical, and the campos??? Cull anything within that frustum?

		// render the sorted patches
		for (std::pair<double, GeoPatch *> &pPatch : m_visiblePatches) {
			pPatch.second->RenderImmediate(renderer, campos, modelView);
		}

		// must clear this after each render otherwise it just accumulates every patch ever drawn!
		m_visiblePatches.clear();
	} else {
		for (int i = 0; i < NUM_PATCHES; i++) {
			m_patches[i]->Render(renderer, campos, modelView, frustum);
		}
	}

	if (s_debugFlags & GeoSphere::DebugFlags::DEBUG_WIREFRAME)
		renderer->SetWireFrameMode(false);

	// Enhanced Graphics: analytical ray-sphere dual-deck dynamic cloud layers (zero sagitta, visible from ground & orbit)
	if (renderer->IsEnhancedGraphicsEnabled() && m_cloudMaterial.Valid() && m_cloudInsideMaterial.Valid() && hasWeatherAtmo) {
		if (coverage > 0.05f && m_atmos) {
			const double maxTerrainM = m_terrain ? (m_terrain->GetMaxHeight() * planetRadM) : 0.0;
			const double effectiveTerrainM = (hydro > 0.01) ? maxTerrainM * (1.0 - 0.52 * std::min(hydro, 1.0)) : maxTerrainM;

			const double terrainClearLow = effectiveTerrainM * 0.45 + 1400.0;
			const double weatherLowM = (weather.hasAtmosphere && weather.lowerCloudAltM > 100.0)
				? weather.lowerCloudAltM
				: std::clamp(planetRadM * 0.00052, 2200.0, 5000.0);
			const double lowerAltM = std::clamp(std::max(weatherLowM, terrainClearLow), 1600.0, std::max(5500.0, atmTopM * 0.36));

			const double weatherHighM = (weather.hasAtmosphere && weather.upperCloudAltM > 100.0)
				? weather.upperCloudAltM
				: std::clamp(planetRadM * 0.00142, 7400.0, 12800.0);
			const double upperAltM = std::clamp(std::max(weatherHighM, lowerAltM + 2600.0), lowerAltM + 2400.0, std::max(8500.0, atmTopM * 0.54));

			vector3d east, north, up;
			WeatherSystem::BuildLocalENU(camDir, east, north, up);
			const vector3d strikePos = camDir * (planetRadM + lowerAltM) +
				(east * std::cos(double(flash.azimuthRad)) + north * std::sin(double(flash.azimuthRad))) * double(flash.distanceM);
			const vector3f strikeDirObj = vector3f(strikePos.NormalizedSafe());

			const float seed = float(sbody->GetSeed() & 0xFFFFu) * 0.001f;
			const float camAlt = float(camLenD);
			const Color4f aCol = m_atmosphereParameters.atmosCol.ToColor4f();
			const vector3f sphereCenter = vector3f(trans * vector3d(0.0)) / radius;
			const matrix4x4f &projMat = renderer->GetProjection();
			const float projC = projMat[10];
			const float projD = projMat[14];

			static const size_t s_cloudParamsName = "cloudParams"_hash;
			static const size_t s_cloudTintName = "cloudTint"_hash;
			static const size_t s_weatherParamsName = "weatherParams"_hash;
			static const size_t s_cloudScaleName = "cloudScale"_hash;
			static const size_t s_cloudGeomName = "cloudGeom"_hash;
			static const size_t s_cloudCenterName = "cloudCenter"_hash;
			static const size_t s_layerParamsName = "layerParams"_hash;
			static const size_t s_flashCellName = "flashCell"_hash;
			static const size_t s_camDirObjName = "camDirObj"_hash;

			const float stormIntensity = weather.hasAtmosphere ? float(weather.stormIntensity) : 0.0f;
			const float windDriftScale = float(Clamp(0.75 + 0.35 * std::min(atmo, 2.5), 0.50, 1.80));
			const float dustFactor = (weather.hasAtmosphere && weather.precipType == PrecipitationType::DUST) ? float(weather.precipIntensity) : 0.0f;
			const float planetRadKm = float(planetRadM * 0.001);
			const float camAltKm = float(camAltM * 0.001);
			const float atmoDense = float(Clamp(atmo / 2.5, 0.0, 1.0));
			const float camLocalWeight = weather.hasAtmosphere ? 1.0f : 0.0f;
			const float lowerLocalCover = weather.hasAtmosphere ? float(weather.lowerCloudCover) : coverage;
			const float upperLocalCover = weather.hasAtmosphere ? float(weather.upperCloudCover) : (coverage * 0.55f);
			const float upperGlobalCover = Clamp(coverage * 0.58f + 0.14f, 0.18f, 0.68f);
			const vector3f camDirF = vector3f(camDir);

			auto drawCloudLayer = [&](double layerAltM, float layerType, float globalCov, float localCov, float windMult, float opacityScale, float seedOff, float flashScale) {
				const double cloudRadD = 1.0 + (layerAltM / planetRadM);
				const double rDiffD = (cloudRadD - camLenD) * (cloudRadD + camLenD);
				const double boundRadD = std::max(double(m_atmosphereParameters.atmosRadius) * 1.02, cloudRadD * 1.025);
				const float cloudRad = float(cloudRadD);
				const float cloudAltKm = float(layerAltM * 0.001);

				Graphics::Material *cloudMat = (camLenD < boundRadD * 0.996) ? m_cloudInsideMaterial.Get() : m_cloudMaterial.Get();
				cloudMat->SetPushConstant(s_cloudParamsName, vector3f(globalCov, seed + seedOff, camAlt), cloudRad);
				cloudMat->SetPushConstant(s_cloudTintName, vector3f(
					Clamp(0.78f + 0.22f * aCol.r, 0.0f, 1.0f),
					Clamp(0.82f + 0.18f * aCol.g, 0.0f, 1.0f),
					Clamp(0.88f + 0.12f * aCol.b, 0.0f, 1.0f)), 0.94f);
				cloudMat->SetPushConstant(s_weatherParamsName, vector3f(stormIntensity, windDriftScale * windMult, flash.intensity * flashScale), dustFactor);
				cloudMat->SetPushConstant(s_cloudScaleName, vector3f(planetRadKm, cloudAltKm, camAltKm), atmoDense);
				cloudMat->SetPushConstant(s_cloudGeomName, vector3f(float(rDiffD), float(planetRadM), projC), projD);
				cloudMat->SetPushConstant(s_cloudCenterName, sphereCenter);
				cloudMat->SetPushConstant(s_layerParamsName, vector3f(layerType, localCov, camLocalWeight), opacityScale);
				cloudMat->SetPushConstant(s_flashCellName, strikeDirObj, flash.intensity * flashScale);
				cloudMat->SetPushConstant(s_camDirObjName, camDirF);

				renderer->SetTransform(matrix4x4f(trans * matrix4x4d::ScaleMatrix(boundRadD)));
				m_atmos->Draw(renderer, cloudMat);
			};

			// Render far-to-near relative to camera altitude so upper cirrus and lower cumulus composite cleanly
			if (camAltM < lowerAltM) {
				drawCloudLayer(upperAltM, 1.0f, upperGlobalCover, upperLocalCover, 1.55f, 0.62f, 13.7f, 0.35f);
				drawCloudLayer(lowerAltM, 0.0f, coverage, lowerLocalCover, 1.0f, 0.98f, 0.0f, 1.0f);
			} else {
				drawCloudLayer(lowerAltM, 0.0f, coverage, lowerLocalCover, 1.0f, 0.98f, 0.0f, 1.0f);
				drawCloudLayer(upperAltM, 1.0f, upperGlobalCover, upperLocalCover, 1.55f, 0.62f, 13.7f, 0.35f);
			}
		}
	}

	renderer->SetAmbientColor(oldAmbient);

	renderer->GetStats().AddToStatCount(Graphics::Stats::STAT_PLANETS, 1);
}

void GeoSphere::SetUpMaterials()
{
	// XXX: this has to be synced with the vertex format used in GeoPatch
	auto vtxFormat = Graphics::VertexFormatDesc::FromAttribSet(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_NORMAL | Graphics::ATTRIB_DIFFUSE | Graphics::ATTRIB_UV0);

	GetSystemBody()->CalcAtmosphereParams(m_atmosphereParameters);
	// normal star has a different setup path than geosphere terrain does
	if (GetSystemBody()->GetSuperType() == SystemBody::SUPERTYPE_STAR) {
		Graphics::MaterialDescriptor surfDesc;
		surfDesc.lighting = false;
		Graphics::RenderStateDesc rsd;
		m_surfaceMaterial.Reset(Pi::renderer->CreateMaterial("geosphere_star", surfDesc, rsd, vtxFormat));
	} else {
		// Request material for this star or planet, with or without
		// atmosphere. Separate material for surface and sky.
		Graphics::MaterialDescriptor surfDesc;
		const Uint32 effect_flags = m_terrain->GetSurfaceEffects();
		if (effect_flags & Terrain::EFFECT_LAVA)
			surfDesc.effect = Graphics::EFFECT_GEOSPHERE_TERRAIN_WITH_LAVA;
		else if (effect_flags & Terrain::EFFECT_WATER)
			surfDesc.effect = Graphics::EFFECT_GEOSPHERE_TERRAIN_WITH_WATER;
		else
			surfDesc.effect = Graphics::EFFECT_GEOSPHERE_TERRAIN;

		if ((GetSystemBody()->GetType() == SystemBody::TYPE_BROWN_DWARF) ||
			(GetSystemBody()->GetType() == SystemBody::TYPE_STAR_M)) {
			//dim star (emits and receives light)
			surfDesc.lighting = true;
			// emits light, so atmosphere should not affect visible light
			surfDesc.quality &= ~Graphics::HAS_ATMOSPHERE;
		} else {
			//planetoid with or without atmosphere
			surfDesc.lighting = true;
			if (m_atmosphereParameters.atmosDensity > 0.0) {
				surfDesc.quality |= Graphics::HAS_ATMOSPHERE;
			}
		}

		//solid blendmode
		Graphics::RenderStateDesc rsd;
		surfDesc.quality |= Graphics::HAS_ECLIPSES;
		const int scattering = Pi::config->Int("RealisticScattering");
		switch (scattering) {
		case 1:
			/* fallthrough */
		case 2:
			m_surfaceMaterial.Reset(Pi::renderer->CreateMaterial("rayleigh_geosphere_terrain", surfDesc, rsd, vtxFormat));
			break;
		default:
			m_surfaceMaterial.Reset(Pi::renderer->CreateMaterial("geosphere_terrain", surfDesc, rsd, vtxFormat));
			break;
		}

		m_texHi.Reset(Graphics::TextureBuilder::Model("textures/high.dds").GetOrCreateTexture(Pi::renderer, "model"));
		m_texLo.Reset(Graphics::TextureBuilder::Model("textures/low.dds").GetOrCreateTexture(Pi::renderer, "model"));
		m_texOceanSwell.Reset(Graphics::TextureBuilder("textures/ocean_waves_swell.png", Graphics::LINEAR_REPEAT, true, false, true, false, true).GetOrCreateTexture(Pi::renderer, "ocean"));
		m_texOceanChop.Reset(Graphics::TextureBuilder("textures/ocean_waves_chop.png", Graphics::LINEAR_REPEAT, true, false, true, false, true).GetOrCreateTexture(Pi::renderer, "ocean"));
		m_surfaceMaterial->SetTexture("texture0"_hash, m_texHi.Get());
		m_surfaceMaterial->SetTexture("texture1"_hash, m_texLo.Get());
		m_surfaceMaterial->SetTexture("oceanTexA"_hash, m_texOceanSwell.Get());
		m_surfaceMaterial->SetTexture("oceanTexB"_hash, m_texOceanChop.Get());
	}

	CreateAtmosphereMaterial();
}

void GeoSphere::CreateAtmosphereMaterial()
{
	Graphics::RenderStateDesc rsd;
	// atmosphere is blended over the background
	rsd.blendMode = Graphics::BLEND_ALPHA_ONE;
	rsd.cullMode = Graphics::CULL_FRONT;
	rsd.depthWrite = false;

	Graphics::MaterialDescriptor skyDesc;
	skyDesc.effect = Graphics::EFFECT_GEOSPHERE_SKY;
	skyDesc.lighting = true;
	skyDesc.quality |= Graphics::HAS_ECLIPSES;

	Graphics::VertexFormatDesc atmosVtxFmt = m_atmos->GetVertexFormat();

	const int scattering = Pi::config->Int("RealisticScattering");
	switch (scattering) {
	case 1:
		m_atmosphereMaterial.Reset(Pi::renderer->CreateMaterial("rayleigh_geosphere_sky_fast", skyDesc, rsd, atmosVtxFmt));
		break;
	case 2:
		m_atmosphereMaterial.Reset(Pi::renderer->CreateMaterial("rayleigh_geosphere_sky_full", skyDesc, rsd, atmosVtxFmt));
		break;
	default:
		m_atmosphereMaterial.Reset(Pi::renderer->CreateMaterial("geosphere_sky", skyDesc, rsd, atmosVtxFmt));
		break;
	}

	Graphics::RenderStateDesc cloudRsd;
	cloudRsd.blendMode = Graphics::BLEND_ALPHA;
	cloudRsd.cullMode = Graphics::CULL_BACK;
	cloudRsd.depthTest = true;
	cloudRsd.depthWrite = false;

	Graphics::MaterialDescriptor cloudDesc;
	cloudDesc.lighting = true;
	m_cloudMaterial.Reset(Pi::renderer->CreateMaterial("planet_clouds", cloudDesc, cloudRsd, atmosVtxFmt));

	Graphics::RenderStateDesc cloudInsideRsd = cloudRsd;
	cloudInsideRsd.cullMode = Graphics::CULL_FRONT;
	m_cloudInsideMaterial.Reset(Pi::renderer->CreateMaterial("planet_clouds", cloudDesc, cloudInsideRsd, atmosVtxFmt));
}

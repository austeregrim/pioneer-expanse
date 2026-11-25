// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "SurfaceScatter.h"

#include "Body.h"
#include "Frame.h"
#include "Game.h"
#include "MathUtil.h"
#include "Pi.h"
#include "Planet.h"
#include "Player.h"
#include "Random.h"
#include "Space.h"
#include "SpaceStation.h"
#include "galaxy/SystemBody.h"
#include "graphics/Light.h"
#include "graphics/Material.h"
#include "graphics/RenderState.h"
#include "graphics/Renderer.h"
#include "graphics/Types.h"
#include "graphics/VertexArray.h"
#include "perlin.h"
#include "profiler/Profiler.h"

#include <algorithm>
#include <cmath>

namespace {

inline uint64_t SplitMix64(uint64_t x)
{
	x += 0x9E3779B97F4A7C15ULL;
	x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
	x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
	return x ^ (x >> 31);
}

inline uint64_t HashCell(int face, uint8_t tier, int64_t gx, int64_t gz, uint32_t seed)
{
	uint64_t h = SplitMix64(uint64_t(gx) ^ 0xA5A5A5A5A5A5A5A5ULL);
	h ^= SplitMix64(uint64_t(gz) + 0x5555555555555555ULL);
	h ^= SplitMix64((uint64_t(seed) << 16) | (uint64_t(face) << 8) | uint64_t(tier));
	return SplitMix64(h);
}

inline double NextRand01(uint64_t &state)
{
	state = SplitMix64(state);
	return double(state >> 11) * (1.0 / 9007199254740992.0);
}

inline int64_t FloorCell(double coord, double cellSize)
{
	return static_cast<int64_t>(std::floor(coord / cellSize));
}

inline double Smoothstep(double edge0, double edge1, double x)
{
	const double t = Clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

struct CellOffset {
	int64_t dx;
	int64_t dz;
	int64_t distSq;
};

const std::vector<CellOffset> &GetSortedCellOffsets(int range)
{
	thread_local std::unordered_map<int, std::vector<CellOffset>> s_cache;
	auto it = s_cache.find(range);
	if (it != s_cache.end())
		return it->second;

	std::vector<CellOffset> offsets;
	const int span = 2 * range + 1;
	offsets.reserve(size_t(span) * size_t(span));
	for (int64_t dz = -range; dz <= range; ++dz) {
		for (int64_t dx = -range; dx <= range; ++dx) {
			offsets.push_back({ dx, dz, dx * dx + dz * dz });
		}
	}
	std::sort(offsets.begin(), offsets.end(), [](const CellOffset &a, const CellOffset &b) {
		return a.distSq < b.distSq;
	});
	return s_cache.emplace(range, std::move(offsets)).first->second;
}

struct IcoTri {
	int a, b, c;
};

} // namespace

size_t SurfaceScatter::CellKeyHash::operator()(const CellKey &k) const noexcept
{
	uint64_t h = SplitMix64(uint64_t(k.gx));
	h ^= SplitMix64(uint64_t(k.gz) + 0x9E3779B97F4A7C15ULL);
	h ^= SplitMix64((uint64_t(k.face) << 8) | uint64_t(k.tier));
	return size_t(SplitMix64(h));
}

SurfaceScatter::SurfaceScatter(Planet *planet) :
	m_planet(planet),
	m_planetRadius(1.0),
	m_invPlanetRadius(1.0),
	m_baseSeed(1),
	m_hasOcean(false),
	m_hasLava(false),
	m_icyness(0.0),
	m_volcanicity(0.0),
	m_dustColor(168, 152, 136, 255)
{
	const SystemBody *sbody = m_planet ? m_planet->GetSystemBody() : nullptr;
	if (sbody) {
		m_planetRadius = std::max(1.0, sbody->GetRadius());
		m_invPlanetRadius = 1.0 / m_planetRadius;
		m_baseSeed = sbody->GetSeed();
		m_hasOcean = (sbody->GetVolatileLiquid() > 0.05);
		m_icyness = Clamp(sbody->GetVolatileIces(), 0.0, 1.0);
		m_volcanicity = Clamp(sbody->GetVolcanicity(), 0.0, 1.0);
		m_hasLava = (m_volcanicity > 0.70);
		m_dustColor = sbody->CalcSurfaceDustColor();
	}
}

SurfaceScatter::~SurfaceScatter() = default;

void SurfaceScatter::InitGraphics(Graphics::Renderer *r)
{
	Graphics::MaterialDescriptor rockDesc;
	rockDesc.lighting = true;
	rockDesc.vertexColors = true;

	Graphics::RenderStateDesc rockRsd;
	for (int i = 0; i < NUM_VARIANTS; ++i) {
		m_rockMeshes[i] = BuildRockMesh(r, m_baseSeed + uint32_t(i) * 4999U + 271U, i);
	}
	m_rockMaterial.reset(r->CreateMaterial("multi", rockDesc, rockRsd, m_rockMeshes[0]->GetFormat()));
	m_rockMaterial->diffuse = Color::WHITE;
	m_rockMaterial->specular = Color(42, 40, 38, 255);
	m_rockMaterial->shininess = 10.0f;
}

std::unique_ptr<Graphics::MeshObject> SurfaceScatter::BuildRockMesh(Graphics::Renderer *r, uint32_t seed, int variant) const
{
	Random rng(seed);
	const float phi = (1.0f + std::sqrt(5.0f)) * 0.5f;

	std::vector<vector3f> verts = {
		vector3f(-1, phi, 0).Normalized(), vector3f(1, phi, 0).Normalized(),
		vector3f(-1, -phi, 0).Normalized(), vector3f(1, -phi, 0).Normalized(),
		vector3f(0, -1, phi).Normalized(), vector3f(0, 1, phi).Normalized(),
		vector3f(0, -1, -phi).Normalized(), vector3f(0, 1, -phi).Normalized(),
		vector3f(phi, 0, -1).Normalized(), vector3f(phi, 0, 1).Normalized(),
		vector3f(-phi, 0, -1).Normalized(), vector3f(-phi, 0, 1).Normalized()
	};

	std::vector<IcoTri> tris = {
		{ 0, 11, 5 }, { 0, 5, 1 }, { 0, 1, 7 }, { 0, 7, 10 }, { 0, 10, 11 },
		{ 1, 5, 9 }, { 5, 11, 4 }, { 11, 10, 2 }, { 10, 7, 6 }, { 7, 1, 8 },
		{ 3, 9, 4 }, { 3, 4, 2 }, { 3, 2, 6 }, { 3, 6, 8 }, { 3, 8, 9 },
		{ 4, 9, 5 }, { 2, 4, 11 }, { 6, 2, 10 }, { 8, 6, 7 }, { 9, 8, 1 }
	};

	auto midpoint = [&](int i1, int i2, std::unordered_map<uint64_t, int> &cache) -> int {
		const uint32_t lo = std::min(i1, i2);
		const uint32_t hi = std::max(i1, i2);
		const uint64_t key = (uint64_t(lo) << 32) | hi;
		auto it = cache.find(key);
		if (it != cache.end())
			return it->second;
		vector3f mid = (verts[i1] + verts[i2]).Normalized();
		int idx = int(verts.size());
		verts.push_back(mid);
		cache.emplace(key, idx);
		return idx;
	};

	// One subdivision yields 80 crisp faceted mineral faces
	{
		std::unordered_map<uint64_t, int> cache;
		std::vector<IcoTri> nextTris;
		nextTris.reserve(tris.size() * 4);
		for (const IcoTri &t : tris) {
			int ab = midpoint(t.a, t.b, cache);
			int bc = midpoint(t.b, t.c, cache);
			int ca = midpoint(t.c, t.a, cache);
			nextTris.push_back({ t.a, ab, ca });
			nextTris.push_back({ t.b, bc, ab });
			nextTris.push_back({ t.c, ca, bc });
			nextTris.push_back({ ab, bc, ca });
		}
		tris.swap(nextTris);
	}

	const vector3d noiseOff(rng.Double(0.0, 256.0), rng.Double(0.0, 256.0), rng.Double(0.0, 256.0));
	const bool isFlatSlab = (variant == 2 || variant == 3);
	const vector3f axisScale(
		float(rng.Double(0.85, 1.32)),
		isFlatSlab ? float(rng.Double(0.45, 0.65)) : float(rng.Double(0.68, 1.08)),
		float(rng.Double(0.85, 1.32)));

	std::vector<uint8_t> vertShade(verts.size());
	for (size_t i = 0; i < verts.size(); ++i) {
		const vector3d p = vector3d(verts[i]) * 2.2 + noiseOff;
		const double disp = 1.0 + 0.28 * noise(p) + 0.14 * noise(p * 2.5);
		vector3f sculpted(
			verts[i].x * axisScale.x * float(disp),
			verts[i].y * axisScale.y * float(disp),
			verts[i].z * axisScale.z * float(disp));
		verts[i] = sculpted;

		// Subtle base ambient occlusion near bottom of rock so it blends firmly into ground regolith
		const float heightWeight = Clamp((verts[i].y + 1.0f) * 0.5f, 0.0f, 1.0f);
		const int ao = Clamp(int((148.0 + 92.0 * heightWeight) + 28.0 * noise(p * 1.8)), 120, 255);
		vertShade[i] = uint8_t(ao);
	}

	Graphics::VertexArray va(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_NORMAL | Graphics::ATTRIB_DIFFUSE);
	for (const IcoTri &t : tris) {
		const vector3f &v0 = verts[t.a];
		const vector3f &v1 = verts[t.b];
		const vector3f &v2 = verts[t.c];
		const vector3f normal = (v1 - v0).Cross(v2 - v0).NormalizedSafe();

		const Color c0(vertShade[t.a], vertShade[t.a], vertShade[t.a], 255);
		const Color c1(vertShade[t.b], vertShade[t.b], vertShade[t.b], 255);
		const Color c2(vertShade[t.c], vertShade[t.c], vertShade[t.c], 255);

		va.Add(v0, c0, normal);
		va.Add(v1, c1, normal);
		va.Add(v2, c2, normal);
	}

	return std::unique_ptr<Graphics::MeshObject>(r->CreateMeshObjectFromArray(&va));
}

vector3d SurfaceScatter::CubeMetersToUnit(int face, double uM, double vM) const
{
	const double su = uM * m_invPlanetRadius;
	const double sv = vM * m_invPlanetRadius;
	vector3d v;
	switch (face) {
	case 0: v = vector3d(1.0, su, sv); break;
	case 1: v = vector3d(-1.0, su, sv); break;
	case 2: v = vector3d(su, 1.0, sv); break;
	case 3: v = vector3d(su, -1.0, sv); break;
	case 4: v = vector3d(su, sv, 1.0); break;
	default: v = vector3d(su, sv, -1.0); break;
	}
	return v.Normalized();
}

const std::vector<SurfaceScatter::RockInstance> &SurfaceScatter::GetOrBuildCell(int face, uint8_t tier, int64_t gx, int64_t gz)
{
	const CellKey key{ gx, gz, uint8_t(face), tier };
	auto it = m_cellCache.find(key);
	if (it != m_cellCache.end())
		return it->second;

	if (m_cellCache.size() >= MAX_CACHED_CELLS)
		m_cellCache.clear();

	std::vector<RockInstance> rocks;
	const double cellSize = (tier == 0) ? CELL_LARGE : CELL_SMALL;
	uint64_t state = HashCell(face, tier, gx, gz, m_baseSeed);

	const int maxAttempts = (tier == 0) ? 5 : 6;
	rocks.reserve(size_t(maxAttempts));

	for (int i = 0; i < maxAttempts; ++i) {
		const double uOff = NextRand01(state);
		const double vOff = NextRand01(state);
		const double uM = (double(gx) + uOff) * cellSize;
		const double vM = (double(gz) + vOff) * cellSize;

		const vector3d unitDir = CubeMetersToUnit(face, uM, vM);
		const double h0 = m_planet->GetTerrainHeight(unitDir);

		// Exclude submerged ocean beds
		if (m_hasOcean && h0 <= m_planetRadius + 2.0)
			continue;

		// Exclude low-elevation active lava basins on highly volcanic planets
		if (m_hasLava && h0 <= m_planetRadius + 18.0)
			continue;

		// Build orthonormal local tangent frame for terrain slope & normal alignment
		const vector3d refAxis = (std::abs(unitDir.y) < 0.92) ? vector3d(0.0, 1.0, 0.0) : vector3d(1.0, 0.0, 0.0);
		const vector3d east = refAxis.Cross(unitDir).Normalized();
		const vector3d north = unitDir.Cross(east).Normalized();

		const double epsRad = 1.5 * m_invPlanetRadius;
		const double hE = m_planet->GetTerrainHeight((unitDir + east * epsRad).Normalized());
		const double hN = m_planet->GetTerrainHeight((unitDir + north * epsRad).Normalized());

		const vector3d p0 = unitDir * h0;
		const vector3d pE = (unitDir + east * epsRad).Normalized() * hE;
		const vector3d pN = (unitDir + north * epsRad).Normalized() * hN;
		vector3d surfNormal = (pE - p0).Cross(pN - p0).NormalizedSafe();
		if (surfNormal.Dot(unitDir) < 0.0)
			surfNormal = -surfNormal;

		const double cosSlope = Clamp(surfNormal.Dot(unitDir), 0.0, 1.0);
		const double slope = 1.0 - cosSlope;

		// Skip vertical cliffs so boulders don't jut sideways
		if (slope > 0.68)
			continue;

		// Regional clumping + scree/talus affinity on moderate slopes
		const double clump = noise(unitDir * 2200.0);
		double spawnProb = (tier == 0)
			? Clamp(0.32 + 0.35 * clump + (slope > 0.08 && slope < 0.45 ? 0.25 : 0.0), 0.12, 0.88)
			: Clamp(0.45 + 0.30 * clump + (slope > 0.06 ? 0.20 : 0.0), 0.20, 0.92);

		if (NextRand01(state) > spawnProb)
			continue;

		RockInstance inst;
		const double uScale = NextRand01(state);
		if (tier == 0) {
			const bool megaOutcrop = (NextRand01(state) < 0.18);
			inst.scale = megaOutcrop ? (3.6 + 2.8 * std::pow(uScale, 1.4)) : (1.1 + 3.2 * std::pow(uScale, 1.6));
			inst.maxDist = megaOutcrop ? 680.0 : 360.0;
			inst.variant = uint8_t(NextRand01(state) * 4.0) % 4;
		} else {
			inst.scale = 0.22 + 0.62 * std::pow(uScale, 1.5);
			inst.maxDist = 115.0;
			inst.variant = uint8_t(4 + int(NextRand01(state) * 2.0) % 2);
		}

		// Embed boulder bottom ~28% into the regolith so nothing appears to hover
		inst.posRotM = unitDir * (h0 - inst.scale * 0.28);

		// Align +Y to local terrain normal with slight slope bias & random yaw/tilt
		const vector3d upDir = (surfNormal * 0.65 + unitDir * 0.35).Normalized();
		const vector3d yawRef = (std::abs(upDir.y) < 0.92) ? vector3d(0.0, 1.0, 0.0) : vector3d(1.0, 0.0, 0.0);
		const vector3d bX0 = yawRef.Cross(upDir).Normalized();
		const vector3d bZ0 = bX0.Cross(upDir).Normalized();
		const double yaw = NextRand01(state) * 2.0 * M_PI;
		const double tilt = (NextRand01(state) - 0.5) * 0.22;
		const matrix3x3d localRot = matrix3x3d::RotateY(yaw) * matrix3x3d::RotateX(tilt);
		const matrix3x3d basis = matrix3x3d::FromVectors(bX0, upDir, bZ0);
		inst.orient = basis * localRot;

		// Biome mineral tinting
		const double toneShift = 0.80 + 0.38 * NextRand01(state);
		double rC = double(m_dustColor.r) * 0.82 * toneShift;
		double gC = double(m_dustColor.g) * 0.82 * toneShift;
		double bC = double(m_dustColor.b) * 0.82 * toneShift;

		if (m_icyness > 0.35) {
			const double iceMix = (m_icyness - 0.35) / 0.65;
			rC = MathUtil::mix(rC, 175.0 * toneShift, iceMix * 0.45);
			gC = MathUtil::mix(gC, 192.0 * toneShift, iceMix * 0.45);
			bC = MathUtil::mix(bC, 212.0 * toneShift, iceMix * 0.45);
		} else if (m_volcanicity > 0.65) {
			const double basaltMix = (m_volcanicity - 0.65) / 0.35;
			rC = MathUtil::mix(rC, 68.0 * toneShift, basaltMix * 0.55);
			gC = MathUtil::mix(gC, 62.0 * toneShift, basaltMix * 0.55);
			bC = MathUtil::mix(bC, 60.0 * toneShift, basaltMix * 0.55);
		}

		inst.color = Color(
			uint8_t(Clamp(rC, 25.0, 235.0)),
			uint8_t(Clamp(gC, 25.0, 235.0)),
			uint8_t(Clamp(bC, 25.0, 235.0)),
			255);

		rocks.push_back(inst);
	}

	return m_cellCache.emplace(key, std::move(rocks)).first->second;
}

void SurfaceScatter::Render(Graphics::Renderer *r, const matrix4x4d &viewTran, const vector3d &camPos)
{
	PROFILE_SCOPED()
	if (!m_planet || !r)
		return;

	// -camPos * m_planetRadius is camera position in planet rotating frame (meters)
	const vector3d camRotM = (-camPos) * m_planetRadius;
	const double camLen = camRotM.Length();
	if (camLen < 1.0)
		return;

	const vector3d camUnit = camRotM / camLen;
	const double camTerrainRad = m_planet->GetTerrainHeight(camUnit);
	const double agl = camLen - camTerrainRad;
	if (agl > 1150.0)
		return;

	if (!m_rockMaterial)
		InitGraphics(r);

	// Collect ground starport positions once per frame to exclude landing pads from rocks
	std::vector<vector3d> portPositions;
	const FrameId planetFrameId = m_planet->GetFrame();
	if (Pi::game && Pi::game->GetSpace()) {
		for (const Body *b : Pi::game->GetSpace()->GetBodies()) {
			if (b->IsType(ObjectType::SPACESTATION) && b->GetFrame() == planetFrameId) {
				const SpaceStation *st = static_cast<const SpaceStation *>(b);
				if (st->IsGroundStation())
					portPositions.push_back(st->GetInterpPosition());
			}
		}
	}

	// Day/night solar elevation, overcast cloud darkening, and active ship spotlight parameters
	double dayFactor = 1.0;
	if (r->GetNumLights() > 0) {
		const vector3d camUpView = (viewTran.ApplyRotationOnly(camUnit) * m_invPlanetRadius).NormalizedSafe();
		const vector3d starDirView = vector3d(r->GetLight(0).GetPosition()).NormalizedSafe();
		const double sunElev = camUpView.Dot(starDirView);
		dayFactor = Smoothstep(-0.08, 0.18, sunElev);
	}
	const double gameTime = Pi::game ? Pi::game->GetTime() : 0.0;
	const WeatherState weather = m_planet->GetWeatherState(camRotM, gameTime);
	const double cloudAtten = weather.hasAtmosphere
		? Clamp(1.0 - weather.lowerCloudCover * 0.62 - weather.stormIntensity * 0.22, 0.22, 1.0)
		: 1.0;
	const double ambientLit = Clamp(0.04 + 0.96 * dayFactor * cloudAtten, 0.04, 1.0);

	bool hasShipSpot = false;
	bool fwdLightOn = false;
	bool ldgLightOn = false;
	vector3d shipPosRot(0.0), shipFwdRot(0.0, 0.0, -1.0), shipLdgRot(0.0, -0.64, -0.77);
	if (Pi::player && !Pi::player->IsDead() && Pi::player->GetFlightState() != Ship::HYPERSPACE &&
		Pi::player->GetFrame() == planetFrameId &&
		(Pi::player->GetForwardLightsEnabled() || Pi::player->GetLandingLightsEnabled())) {
		hasShipSpot = true;
		fwdLightOn = Pi::player->GetForwardLightsEnabled();
		ldgLightOn = Pi::player->GetLandingLightsEnabled();
		shipPosRot = Pi::player->GetInterpPosition();
		const matrix3x3d shipRot = Pi::player->GetInterpOrient();
		shipFwdRot = (shipRot * vector3d(0.0, -0.055, -1.0)).NormalizedSafe();
		shipLdgRot = (shipRot * vector3d(0.0, -0.64, -0.77)).NormalizedSafe();
	}
	const double fwdInnerCos = std::cos(DEG2RAD(14.0));
	const double fwdOuterCos = std::cos(DEG2RAD(28.0));
	const double ldgInnerCos = std::cos(DEG2RAD(22.0));
	const double ldgOuterCos = std::cos(DEG2RAD(42.0));

	// Dominant cube-sphere face for camera
	const double ax = std::abs(camUnit.x), ay = std::abs(camUnit.y), az = std::abs(camUnit.z);
	int face = 0;
	double su = 0.0, sv = 0.0;
	if (ax >= ay && ax >= az) {
		face = (camUnit.x >= 0.0) ? 0 : 1;
		su = camUnit.y / ax;
		sv = camUnit.z / ax;
	} else if (ay >= ax && ay >= az) {
		face = (camUnit.y >= 0.0) ? 2 : 3;
		su = camUnit.x / ay;
		sv = camUnit.z / ay;
	} else {
		face = (camUnit.z >= 0.0) ? 4 : 5;
		su = camUnit.x / az;
		sv = camUnit.y / az;
	}
	const double camUM = su * m_planetRadius;
	const double camVM = sv * m_planetRadius;

	int rendered = 0;
	const double aglFade = Clamp(1.0 - (agl - 650.0) / 500.0, 0.0, 1.0);
	const double smallAglFade = Clamp(1.0 - (agl - 140.0) / 140.0, 0.0, 1.0);

	auto renderTier = [&](uint8_t tier, double cellSize, int range, double tierFade, int budget) {
		if (tierFade <= 0.01 || rendered >= MAX_VISIBLE_ROCKS || budget <= 0)
			return;

		const int64_t cx = FloorCell(camUM, cellSize);
		const int64_t cz = FloorCell(camVM, cellSize);
		int tierCount = 0;

		for (const CellOffset &off : GetSortedCellOffsets(range)) {
			const int64_t gx = cx + off.dx;
			const int64_t gz = cz + off.dz;
			const std::vector<RockInstance> &cellRocks = GetOrBuildCell(face, tier, gx, gz);

			for (const RockInstance &inst : cellRocks) {
				// Exclude rocks within 650m of ground starport centers
				bool nearPort = false;
				for (const vector3d &pPos : portPositions) {
					if ((inst.posRotM - pPos).LengthSqr() < (650.0 * 650.0)) {
						nearPort = true;
						break;
					}
				}
				if (nearPort)
					continue;

				const vector3d relM = inst.posRotM - camRotM;
				const double distSq = relM.LengthSqr();
				if (distSq > inst.maxDist * inst.maxDist)
					continue;

				const vector3d posView = viewTran.ApplyRotationOnly(relM) * m_invPlanetRadius;
				if (posView.z > inst.scale * 2.0)
					continue;

				const double forwardDist = std::max(1.0, -posView.z);
				if (std::hypot(posView.x, posView.y) > forwardDist * 1.65 + inst.scale * 3.0)
					continue;

				const double dist = std::sqrt(distSq);
				const double fadeOut = 1.0 - Smoothstep(inst.maxDist * 0.68, inst.maxDist, dist);
				const double s = inst.scale * fadeOut * tierFade;
				if (s <= 0.04)
					continue;

				const vector3d bx = viewTran.ApplyRotationOnly(inst.orient * vector3d(s, 0.0, 0.0)) * m_invPlanetRadius;
				const vector3d by = viewTran.ApplyRotationOnly(inst.orient * vector3d(0.0, s, 0.0)) * m_invPlanetRadius;
				const vector3d bz = viewTran.ApplyRotationOnly(inst.orient * vector3d(0.0, 0.0, s)) * m_invPlanetRadius;

				matrix4x4f m = matrix4x4f::Identity;
				m[0] = float(bx.x);
				m[1] = float(bx.y);
				m[2] = float(bx.z);
				m[4] = float(by.x);
				m[5] = float(by.y);
				m[6] = float(by.z);
				m[8] = float(bz.x);
				m[9] = float(bz.y);
				m[10] = float(bz.z);
				m[12] = float(posView.x);
				m[13] = float(posView.y);
				m[14] = float(posView.z);

				double spotBoost = 0.0;
				if (hasShipSpot) {
					const vector3d fromShip = inst.posRotM - shipPosRot;
					const double dShip = fromShip.Length();
					if (dShip > 0.5 && dShip < 240.0) {
						const vector3d dirFromShip = fromShip / dShip;
						const double dFade = Clamp(1.0 - dShip / 240.0, 0.0, 1.0);
						const double att = dFade * dFade;
						if (fwdLightOn) {
							const double c = dirFromShip.Dot(shipFwdRot);
							spotBoost = std::max(spotBoost, Smoothstep(fwdOuterCos, fwdInnerCos, c) * att * 0.95);
						}
						if (ldgLightOn) {
							const double c = dirFromShip.Dot(shipLdgRot);
							spotBoost = std::max(spotBoost, Smoothstep(ldgOuterCos, ldgInnerCos, c) * att * 0.90);
						}
					}
				}
				const double litScale = Clamp(ambientLit + spotBoost, 0.04, 1.0);
				m_rockMaterial->diffuse = Color(
					uint8_t(Clamp(double(inst.color.r) * litScale, 0.0, 255.0)),
					uint8_t(Clamp(double(inst.color.g) * litScale, 0.0, 255.0)),
					uint8_t(Clamp(double(inst.color.b) * litScale, 0.0, 255.0)),
					255);
				r->SetTransform(m);
				r->DrawMesh(m_rockMeshes[inst.variant].get(), m_rockMaterial.get());

				++rendered;
				++tierCount;
				if (rendered >= MAX_VISIBLE_ROCKS || tierCount >= budget)
					return;
			}
		}
	};

	renderTier(0, CELL_LARGE, 6, aglFade, 420);
	renderTier(1, CELL_SMALL, 5, smallAglFade, 330);
}

// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "RingField.h"

#include "Body.h"
#include "CargoBody.h"
#include "Frame.h"
#include "Game.h"
#include "MathUtil.h"
#include "Pi.h"
#include "Planet.h"
#include "Player.h"
#include "Random.h"
#include "Sfx.h"
#include "Ship.h"
#include "Space.h"
#include "collider/CollisionContact.h"
#include "galaxy/Galaxy.h"
#include "galaxy/StarSystem.h"
#include "galaxy/SystemBody.h"
#include "graphics/Material.h"
#include "graphics/RenderState.h"
#include "graphics/Renderer.h"
#include "graphics/Types.h"
#include "graphics/VertexArray.h"
#include "graphics/VertexBuffer.h"
#include "lua/Lua.h"
#include "lua/LuaObject.h"
#include "lua/LuaUtils.h"
#include "perlin.h"
#include "profiler/Profiler.h"

#include <algorithm>
#include <array>
#include <cmath>

namespace {

inline uint64_t SplitMix64(uint64_t x)
{
	x += 0x9E3779B97F4A7C15ULL;
	x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
	x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
	return x ^ (x >> 31);
}

inline uint64_t HashCell(int64_t gx, int64_t gz, uint32_t seed, uint32_t salt)
{
	uint64_t h = SplitMix64(uint64_t(gx) ^ 0xA5A5A5A5A5A5A5A5ULL);
	h ^= SplitMix64(uint64_t(gz) + 0x5555555555555555ULL);
	h ^= SplitMix64((uint64_t(seed) << 32) | uint64_t(salt));
	return SplitMix64(h);
}

inline double NextRand01(uint64_t &state)
{
	state = SplitMix64(state);
	// Convert upper 53 bits to uniform double in [0, 1)
	return double(state >> 11) * (1.0 / 9007199254740992.0);
}

inline int64_t FloorCell(double coord, double cellSize)
{
	return static_cast<int64_t>(std::floor(coord / cellSize));
}

bool RaySphereIntersect(const vector3d &start, const vector3d &dir, const vector3d &center, double radius, double maxLen, double &outT)
{
	const vector3d oc = start - center;
	const double b = oc.Dot(dir);
	const double c = oc.LengthSqr() - radius * radius;
	const double disc = b * b - c;
	if (disc < 0.0)
		return false;

	const double sqrtD = std::sqrt(disc);
	double t = -b - sqrtD;
	if (t < 0.0) {
		const double tExit = -b + sqrtD;
		if (tExit > 0.0)
			t = 0.001;
		else
			return false;
	}
	if (t > maxLen)
		return false;
	outT = t;
	return true;
}

struct IcoTri {
	int a, b, c;
};

} // namespace

RingField::RingField(Planet *planet) :
	m_planet(planet),
	m_planetRadius(1.0),
	m_axialTilt(0.0),
	m_axialRot(matrix3x3d::Identity),
	m_baseSeed(1),
	m_elapsedTime(0.0),
	m_dustVerts(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE)
{
	const SystemBody *sbody = m_planet->GetSystemBody();
	if (sbody) {
		m_planetRadius = std::max(1.0, sbody->GetRadius());
		m_axialTilt = sbody->GetAxialTilt();
		m_axialRot = matrix3x3d::RotateX(m_axialTilt);
		m_baseSeed = sbody->GetSeed();
	}
}

RingField::~RingField() = default;

FrameId RingField::GetOrbitalFrameId() const
{
	const FrameId planetFrameId = m_planet->GetFrame();
	const Frame *pf = Frame::GetFrame(planetFrameId);
	return pf ? pf->GetNonRotFrame() : planetFrameId;
}

void RingField::InitGraphics(Graphics::Renderer *r)
{
	Graphics::MaterialDescriptor rockDesc;
	rockDesc.lighting = true;
	rockDesc.vertexColors = true;

	Graphics::RenderStateDesc rockRsd;
	for (int i = 0; i < NUM_VARIANTS; ++i) {
		m_rockMeshes[i] = BuildRockMesh(r, m_baseSeed + uint32_t(i) * 7919U + 131U);
	}
	m_rockMaterial.reset(r->CreateMaterial("multi", rockDesc, rockRsd, m_rockMeshes[0]->GetFormat()));
	m_rockMaterial->diffuse = Color::WHITE;
	m_rockMaterial->specular = Color(72, 72, 78, 255);
	m_rockMaterial->shininess = 18.0f;

	Graphics::MaterialDescriptor dustDesc;
	Graphics::RenderStateDesc dustRsd;
	dustRsd.blendMode = Graphics::BLEND_ALPHA;
	dustRsd.depthWrite = false;
	dustRsd.cullMode = Graphics::CULL_NONE;
	dustRsd.primitiveType = Graphics::TRIANGLES;

	auto dustVfmt = Graphics::VertexFormatDesc::FromAttribSet(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE);
	m_dustMaterial.reset(r->CreateMaterial("vtxColor", dustDesc, dustRsd, dustVfmt));
}

std::unique_ptr<Graphics::MeshObject> RingField::BuildRockMesh(Graphics::Renderer *r, uint32_t seed) const
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

	// One subdivision yields 80 sharp faceted faces per boulder
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
	const vector3f axisScale(
		float(rng.Double(0.72, 1.24)),
		float(rng.Double(0.66, 1.12)),
		float(rng.Double(0.74, 1.26)));

	std::vector<uint8_t> vertShade(verts.size());
	for (size_t i = 0; i < verts.size(); ++i) {
		const vector3d p = vector3d(verts[i]) * 2.1 + noiseOff;
		const double disp = 1.0 +
			0.30 * noise(p) +
			0.14 * noise(p * 2.4);
		vector3f sculpted(
			verts[i].x * axisScale.x * float(disp),
			verts[i].y * axisScale.y * float(disp),
			verts[i].z * axisScale.z * float(disp));
		verts[i] = sculpted;

		const int shade = Clamp(int(215.0 + 42.0 * noise(p * 1.7)), 145, 255);
		vertShade[i] = uint8_t(shade);
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

Color RingField::ComputeRockColor(const RingBand &band, uint64_t seed) const
{
	uint64_t s = seed;
	const double tone = NextRand01(s);
	const double tint = NextRand01(s);

	const Color bc = band.baseColor;
	double r = bc.r;
	double g = bc.g;
	double b = bc.b;

	switch (band.composition) {
	case RingComposition::ICE_WATER:
		// Frosty icy blues and bright snow-white chunks
		r = 0.72 * r + 0.28 * (195.0 + 55.0 * tone);
		g = 0.72 * g + 0.28 * (210.0 + 42.0 * tone);
		b = 0.72 * b + 0.28 * (225.0 + 30.0 * tone);
		break;
	case RingComposition::ICE_AMMONIA_METHANE:
		r = 0.75 * r + 0.25 * (135.0 + 60.0 * tone);
		g = 0.75 * g + 0.25 * (145.0 + 55.0 * tone);
		b = 0.75 * b + 0.25 * (175.0 + 60.0 * tone);
		break;
	case RingComposition::ROCKY_SILICATE:
		r = 0.65 * r + 0.35 * (118.0 + 72.0 * tone);
		g = 0.65 * g + 0.35 * (104.0 + 65.0 * tone);
		b = 0.65 * b + 0.35 * (92.0 + 55.0 * tone);
		break;
	case RingComposition::METAL_RICH:
		r = 0.62 * r + 0.38 * (132.0 + 75.0 * tone);
		g = 0.62 * g + 0.38 * (136.0 + 75.0 * tone);
		b = 0.62 * b + 0.38 * (148.0 + 78.0 * tone);
		break;
	case RingComposition::METALLIC_PRECIOUS:
		if (tint > 0.65) {
			// Golden / platinum vein sheen
			r = 0.55 * r + 0.45 * (205.0 + 45.0 * tone);
			g = 0.55 * g + 0.45 * (182.0 + 48.0 * tone);
			b = 0.55 * b + 0.45 * (128.0 + 52.0 * tone);
		} else {
			r = 0.60 * r + 0.40 * (162.0 + 68.0 * tone);
			g = 0.60 * g + 0.40 * (168.0 + 68.0 * tone);
			b = 0.60 * b + 0.40 * (182.0 + 66.0 * tone);
		}
		break;
	}

	return Color(
		uint8_t(Clamp(int(r), 45, 255)),
		uint8_t(Clamp(int(g), 45, 255)),
		uint8_t(Clamp(int(b), 45, 255)),
		255);
}

void RingField::GatherCellRocks(int64_t gx, int64_t gz, double cellSize, bool coarse, std::vector<RockInstance> &out) const
{
	const SystemBody *sbody = m_planet->GetSystemBody();
	if (!sbody || !sbody->HasRings())
		return;

	const RingStyle &rings = sbody->GetRings();
	const double cx = (double(gx) + 0.5) * cellSize;
	const double cz = (double(gz) + 0.5) * cellSize;
	const double rCenter = std::hypot(cx, cz);

	RingBand band;
	if (!rings.TryGetBandAtRadius(rCenter / m_planetRadius, band))
		return;

	// Edge fade near Cassini/band edges so boulder density tapers naturally
	const double bandInnerM = band.minRadius.ToDouble() * m_planetRadius;
	const double bandOuterM = band.maxRadius.ToDouble() * m_planetRadius;
	const double edgeMargin = std::min(15000.0, (bandOuterM - bandInnerM) * 0.12);
	const double edgeFade = (edgeMargin > 1.0)
		? Clamp(std::min(rCenter - bandInnerM, bandOuterM - rCenter) / edgeMargin, 0.25, 1.0)
		: 1.0;

	const double tau = std::max(0.25, band.opticalDepth.ToDouble());
	const double halfThick = std::max(30.0, band.thickness.ToDouble());
	uint64_t state = HashCell(gx, gz, m_baseSeed + band.seedOffset, coarse ? 0xC0A5E2U : 0xF1E1D0U);

	int count = 0;
	if (coarse) {
		const double prob = Clamp(0.55 * tau * edgeFade, 0.15, 0.95);
		if (NextRand01(state) < prob) {
			count = (NextRand01(state) < 0.35 * tau) ? 2 : 1;
		}
	} else {
		const double avgCount = Clamp(1.6 * tau * edgeFade, 0.5, 4.0);
		const int baseCount = int(avgCount);
		count = baseCount + (NextRand01(state) < (avgCount - baseCount) ? 1 : 0);
	}

	for (int i = 0; i < count; ++i) {
		const double ox = (NextRand01(state) - 0.5) * cellSize * 0.88;
		const double oz = (NextRand01(state) - 0.5) * cellSize * 0.88;
		const double px = cx + ox;
		const double pz = cz + oz;
		const double rRock = std::hypot(px, pz);

		RingBand rockBand;
		if (!rings.TryGetBandAtRadius(rRock / m_planetRadius, rockBand))
			continue;

		const double uY = NextRand01(state) * 2.0 - 1.0;
		// Concentrate boulders near the equatorial midplane
		const double py = uY * std::abs(uY) * halfThick;

		const double rScale = NextRand01(state);
		const double scale = coarse
			? (24.0 + std::pow(rScale, 1.5) * 68.0)
			: (5.5 + std::pow(rScale, 1.8) * 34.0);

		const uint64_t rockId = SplitMix64(HashCell(gx, gz, m_baseSeed, coarse ? 1000U + uint32_t(i) : uint32_t(i)));

		const double ax = NextRand01(state) * 2.0 - 1.0;
		const double ay = NextRand01(state) * 2.0 - 1.0;
		const double az = NextRand01(state) * 2.0 - 1.0;
		vector3d axis(ax, ay, az);
		if (axis.LengthSqr() < 1e-4)
			axis = vector3d(0.0, 1.0, 0.0);
		else
			axis.Normalize();

		RockInstance inst;
		inst.id = rockId;
		inst.pos = vector3d(px, py, pz);
		inst.scale = scale;
		inst.collRadius = scale * 0.90;
		inst.spinAxis = axis;
		inst.spinRate = (NextRand01(state) - 0.5) * 0.28;
		inst.phase = NextRand01(state) * (2.0 * M_PI);
		inst.color = ComputeRockColor(rockBand, rockId);
		inst.variant = uint8_t(HashCell(gx, gz, uint32_t(rockId), 7U) % uint64_t(NUM_VARIANTS));
		inst.coarse = coarse;
		out.push_back(inst);
	}
}

void RingField::TimeStepUpdate(float timeStep)
{
	PROFILE_SCOPED()
	m_elapsedTime += timeStep;

	const SystemBody *sbody = m_planet ? m_planet->GetSystemBody() : nullptr;
	if (!sbody || !sbody->HasRings() || !Pi::game || !Pi::game->GetSpace())
		return;

	const RingStyle &rings = sbody->GetRings();
	const FrameId orbFrameId = GetOrbitalFrameId();
	const FrameId planetFrameId = m_planet->GetFrame();
	const vector3d planetPosOrb = m_planet->GetPositionRelTo(orbFrameId);
	const double minR = rings.minRadius.ToDouble() * m_planetRadius - 500.0;
	const double maxR = rings.maxRadius.ToDouble() * m_planetRadius + 500.0;

	std::vector<RockInstance> nearby;
	nearby.reserve(64);

	for (Body *b : Pi::game->GetSpace()->GetBodies()) {
		if (!b || b->IsDead() || !b->IsType(ObjectType::SHIP))
			continue;

		Ship *ship = static_cast<Ship *>(b);
		if (ship->GetFlightState() != Ship::FLYING)
			continue;

		const FrameId shipFrameId = ship->GetFrame();
		if (shipFrameId != orbFrameId && shipFrameId != planetFrameId)
			continue;

		vector3d shipPosOrb = ship->GetPosition();
		vector3d shipVelOrb = ship->GetVelocity();
		matrix3x3d shipFrameToOrb = matrix3x3d::Identity;
		if (shipFrameId != orbFrameId) {
			Frame *sf = Frame::GetFrame(shipFrameId);
			if (!sf)
				continue;
			shipFrameToOrb = sf->GetOrientRelTo(orbFrameId);
			shipPosOrb = shipFrameToOrb * shipPosOrb + sf->GetPositionRelTo(orbFrameId);
			shipVelOrb = shipFrameToOrb * shipVelOrb;
		}

		const vector3d shipRing = m_axialRot.Transpose() * (shipPosOrb - planetPosOrb);
		const double r = std::hypot(shipRing.x, shipRing.z);
		if (r < minR || r > maxR || std::abs(shipRing.y) > 450.0)
			continue;

		RingBand band;
		if (!rings.TryGetBandAtRadius(r / m_planetRadius, band))
			continue;
		if (std::abs(shipRing.y) > band.thickness.ToDouble() + 180.0)
			continue;

		nearby.clear();
		const int64_t fx = FloorCell(shipRing.x, CELL_FINE);
		const int64_t fz = FloorCell(shipRing.z, CELL_FINE);
		for (int64_t dz = -1; dz <= 1; ++dz) {
			for (int64_t dx = -1; dx <= 1; ++dx) {
				GatherCellRocks(fx + dx, fz + dz, CELL_FINE, false, nearby);
			}
		}
		const int64_t cx = FloorCell(shipRing.x, CELL_COARSE);
		const int64_t cz = FloorCell(shipRing.z, CELL_COARSE);
		for (int64_t dz = -1; dz <= 1; ++dz) {
			for (int64_t dx = -1; dx <= 1; ++dx) {
				GatherCellRocks(cx + dx, cz + dz, CELL_COARSE, true, nearby);
			}
		}

		const double shipRad = std::max(5.0, ship->GetPhysRadius());
		const vector3d velRing = m_axialRot.Transpose() * shipVelOrb;

		for (const RockInstance &rock : nearby) {
			const vector3d delta = shipRing - rock.pos;
			const double combinedR = shipRad + rock.collRadius;
			const double distSqr = delta.LengthSqr();
			if (distSqr >= combinedR * combinedR)
				continue;

			const double dist = std::max(0.01, std::sqrt(distSqr));
			const vector3d normalRing = (dist > 0.02) ? (delta / dist) : vector3d(0.0, 1.0, 0.0);
			const double penDepth = combinedR - dist;
			const double velInto = velRing.Dot(normalRing);

			const vector3d normalOrb = m_axialRot * normalRing;
			const vector3d pushOrb = normalOrb * (penDepth + 0.35);

			if (shipFrameId == orbFrameId) {
				ship->SetPosition(ship->GetPosition() + pushOrb);
			} else {
				ship->SetPosition(ship->GetPosition() + shipFrameToOrb.Transpose() * pushOrb);
			}

			if (velInto < -0.5) {
				const double impactSpeed = -velInto;
				const vector3d bounceVelOrb = shipVelOrb - (1.42 * velInto) * normalOrb;
				if (shipFrameId == orbFrameId) {
					ship->SetVelocity(bounceVelOrb);
				} else {
					ship->SetVelocity(shipFrameToOrb.Transpose() * bounceVelOrb);
				}

				const vector3d spinAxis = shipVelOrb.Cross(normalOrb).NormalizedSafe();
				ship->SetAngVelocity(ship->GetAngVelocity() + spinAxis * Clamp(impactSpeed * 0.025, 0.05, 2.5));

				// Convert kinetic jolt into kg-scaled impact damage (1t hull ~ 1000 kgDamage).
				const float kgDamage = float(Clamp(impactSpeed * impactSpeed * 0.45 + 35.0, 40.0, 45000.0));
				const vector3d contactOrb = shipPosOrb - normalOrb * shipRad;
				CollisionContact contact;
				contact.pos = (shipFrameId == orbFrameId)
					? contactOrb
					: shipFrameToOrb.Transpose() * (contactOrb - Frame::GetFrame(shipFrameId)->GetPositionRelTo(orbFrameId));
				contact.normal = (shipFrameId == orbFrameId) ? normalOrb : (shipFrameToOrb.Transpose() * normalOrb);
				contact.depth = penDepth;
				ship->OnDamage(m_planet, kgDamage, contact);
			}

			break;
		}
	}
}

void RingField::Render(Graphics::Renderer *r, const matrix4x4d &viewTran, const vector3d &camPos)
{
	PROFILE_SCOPED()
	const SystemBody *sbody = m_planet ? m_planet->GetSystemBody() : nullptr;
	if (!sbody || !sbody->HasRings())
		return;

	const Frame *pf = Frame::GetFrame(m_planet->GetFrame());
	const FrameId orbFrameId = pf ? pf->GetNonRotFrame() : m_planet->GetFrame();
	const matrix3x3d spinMatrix = (pf ? pf->GetInterpOrientRelTo(orbFrameId).Transpose() : matrix3x3d::Identity) * m_axialRot;

	// In TerrainBody::Render, -camPos * m_planetRadius is camera position in planet rotating frame (meters).
	const vector3d camInRotMeters = (-camPos) * m_planetRadius;
	const vector3d camInRing = spinMatrix.Transpose() * camInRotMeters;

	const RingStyle &rings = sbody->GetRings();
	const double camR = std::hypot(camInRing.x, camInRing.z);
	const double minR = rings.minRadius.ToDouble() * m_planetRadius;
	const double maxR = rings.maxRadius.ToDouble() * m_planetRadius;

	if (std::abs(camInRing.y) > 25000.0 || camR < minR - 25000.0 || camR > maxR + 25000.0)
		return;

	if (!m_rockMaterial)
		InitGraphics(r);

	std::vector<RockInstance> visibleRocks;
	visibleRocks.reserve(MAX_VISIBLE_ROCKS);

	// Pass 1: Fine local asteroid field (up to 3.4 km)
	{
		const int64_t cx = FloorCell(camInRing.x, CELL_FINE);
		const int64_t cz = FloorCell(camInRing.z, CELL_FINE);
		const int range = 11;
		std::vector<RockInstance> cellRocks;
		cellRocks.reserve(8);

		for (int64_t dz = -range; dz <= range; ++dz) {
			for (int64_t dx = -range; dx <= range; ++dx) {
				const double distSqGuess = (double(dx) * CELL_FINE) * (double(dx) * CELL_FINE) +
					(double(dz) * CELL_FINE) * (double(dz) * CELL_FINE);
				if (distSqGuess > 3600.0 * 3600.0)
					continue;

				cellRocks.clear();
				GatherCellRocks(cx + dx, cz + dz, CELL_FINE, false, cellRocks);
				for (const RockInstance &inst : cellRocks) {
					const double d2 = (inst.pos - camInRing).LengthSqr();
					if (d2 > 3500.0 * 3500.0)
						continue;
					visibleRocks.push_back(inst);
					if (int(visibleRocks.size()) >= MAX_VISIBLE_ROCKS - 140)
						break;
				}
				if (int(visibleRocks.size()) >= MAX_VISIBLE_ROCKS - 140)
					break;
			}
			if (int(visibleRocks.size()) >= MAX_VISIBLE_ROCKS - 140)
				break;
		}
	}

	// Pass 2: Coarse horizon boulders (1.8 km to 18 km)
	{
		const int64_t cx = FloorCell(camInRing.x, CELL_COARSE);
		const int64_t cz = FloorCell(camInRing.z, CELL_COARSE);
		const int range = 14;
		std::vector<RockInstance> cellRocks;
		cellRocks.reserve(4);

		for (int64_t dz = -range; dz <= range; ++dz) {
			for (int64_t dx = -range; dx <= range; ++dx) {
				const double d2Guess = (double(dx) * CELL_COARSE) * (double(dx) * CELL_COARSE) +
					(double(dz) * CELL_COARSE) * (double(dz) * CELL_COARSE);
				if (d2Guess > 18500.0 * 18500.0)
					continue;

				cellRocks.clear();
				GatherCellRocks(cx + dx, cz + dz, CELL_COARSE, true, cellRocks);
				for (const RockInstance &inst : cellRocks) {
					const double d2 = (inst.pos - camInRing).LengthSqr();
					if (d2 < 1600.0 * 1600.0 || d2 > 18000.0 * 18000.0)
						continue;
					visibleRocks.push_back(inst);
					if (int(visibleRocks.size()) >= MAX_VISIBLE_ROCKS)
						break;
				}
				if (int(visibleRocks.size()) >= MAX_VISIBLE_ROCKS)
					break;
			}
			if (int(visibleRocks.size()) >= MAX_VISIBLE_ROCKS)
				break;
		}
	}

	// Draw boulders in camera view space using double-precision offsets first to avoid jitter.
	for (const RockInstance &inst : visibleRocks) {
		// Skip completely depleted boulders if fully harvested
		auto depIt = m_depletedYield.find(inst.id);
		if (depIt != m_depletedYield.end() && depIt->second <= 0.0f)
			continue;

		const vector3d posView = viewTran * ((spinMatrix * inst.pos) / m_planetRadius);
		if (posView.z > inst.scale * 2.5)
			continue;
		const double forwardDist = std::max(1.0, -posView.z);
		if (std::hypot(posView.x, posView.y) > forwardDist * 1.65 + inst.scale * 3.0)
			continue;

		const double angle = inst.phase + inst.spinRate * m_elapsedTime;
		const matrix3x3d rockRot = matrix3x3d::Rotate(angle, inst.spinAxis);

		const vector3d bx = viewTran.ApplyRotationOnly(spinMatrix * (rockRot * vector3d(inst.scale, 0.0, 0.0))) / m_planetRadius;
		const vector3d by = viewTran.ApplyRotationOnly(spinMatrix * (rockRot * vector3d(0.0, inst.scale, 0.0))) / m_planetRadius;
		const vector3d bz = viewTran.ApplyRotationOnly(spinMatrix * (rockRot * vector3d(0.0, 0.0, inst.scale))) / m_planetRadius;

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

		m_rockMaterial->diffuse = inst.color;
		r->SetTransform(m);
		r->DrawMesh(m_rockMeshes[inst.variant].get(), m_rockMaterial.get());
	}

	// Pass 3: Soft translucent dust puffs around ship when flying inside the ring plane
	if (std::abs(camInRing.y) < 5000.0) {
		m_dustVerts.Clear();
		const double dustCell = 900.0;
		const int64_t cx = FloorCell(camInRing.x, dustCell);
		const int64_t cz = FloorCell(camInRing.z, dustCell);
		const int dustRange = 5;

		for (int64_t dz = -dustRange; dz <= dustRange; ++dz) {
			for (int64_t dx = -dustRange; dx <= dustRange; ++dx) {
				uint64_t st = HashCell(cx + dx, cz + dz, m_baseSeed, 0xD057ULL);
				if (NextRand01(st) > 0.72)
					continue;

				const double px = (double(cx + dx) + 0.15 + 0.70 * NextRand01(st)) * dustCell;
				const double pz = (double(cz + dz) + 0.15 + 0.70 * NextRand01(st)) * dustCell;
				const double rDust = std::hypot(px, pz);

				RingBand band;
				if (!rings.TryGetBandAtRadius(rDust / m_planetRadius, band))
					continue;

				const double py = (NextRand01(st) * 2.0 - 1.0) * std::max(45.0, band.thickness.ToDouble() * 1.4);
				const vector3d dustPosRing(px, py, pz);
				const double camDist = (dustPosRing - camInRing).Length();
				if (camDist < 160.0 || camDist > 5200.0)
					continue;

				const vector3d pViewD = viewTran * ((spinMatrix * dustPosRing) / m_planetRadius);
				if (pViewD.z > -40.0)
					continue;

				const double distFade = Clamp((camDist - 160.0) / 380.0, 0.0, 1.0) * Clamp((5200.0 - camDist) / 1400.0, 0.0, 1.0);
				const int alpha = Clamp(int(30.0 * band.opticalDepth.ToDouble() * distFade), 0, 40);
				if (alpha <= 2)
					continue;

				const float halfSize = float(420.0 + 480.0 * NextRand01(st));
				const vector3f center(float(pViewD.x), float(pViewD.y), float(pViewD.z));
				const Color colCenter(band.baseColor.r, band.baseColor.g, band.baseColor.b, uint8_t(alpha));
				const Color colEdge(band.baseColor.r, band.baseColor.g, band.baseColor.b, 0);

				const vector3f tl = center + vector3f(-halfSize, halfSize, 0.0f);
				const vector3f tr = center + vector3f(halfSize, halfSize, 0.0f);
				const vector3f br = center + vector3f(halfSize, -halfSize, 0.0f);
				const vector3f bl = center + vector3f(-halfSize, -halfSize, 0.0f);

				// 4 triangles forming a soft center-lit billboard diamond without harsh quad corners
				m_dustVerts.Add(center, colCenter);
				m_dustVerts.Add(tl, colEdge);
				m_dustVerts.Add(tr, colEdge);

				m_dustVerts.Add(center, colCenter);
				m_dustVerts.Add(tr, colEdge);
				m_dustVerts.Add(br, colEdge);

				m_dustVerts.Add(center, colCenter);
				m_dustVerts.Add(br, colEdge);
				m_dustVerts.Add(bl, colEdge);

				m_dustVerts.Add(center, colCenter);
				m_dustVerts.Add(bl, colEdge);
				m_dustVerts.Add(tl, colEdge);
			}
		}

		if (!m_dustVerts.IsEmpty()) {
			r->SetTransform(matrix4x4f::Identity);
			r->DrawBuffer(&m_dustVerts, m_dustMaterial.get());
		}
	}
}

void RingField::SpawnMiningFragment(const vector3d &hitPosOrb, const vector3d &normalOrb, const RingBand &band)
{
	const SystemBody *sbody = m_planet->GetSystemBody();
	if (!sbody || !Pi::game || !Pi::game->GetSpace() || !Pi::player)
		return;

	RefCountedPtr<StarSystem> s = Pi::game->GetGalaxy()->GetStarSystem(sbody->GetPath());
	SystemBody *liveBody = s ? s->GetBodyByPath(sbody->GetPath()) : nullptr;
	if (!liveBody)
		return;

	lua_State *l = Lua::manager->GetLuaState();
	LUA_DEBUG_START(l);
	LuaObject<Player>::PushToLua(Pi::player);
	lua_getfield(l, -1, "SpawnRingMiningContainer");
	if (lua_isfunction(l, -1)) {
		lua_pushvalue(l, -2); // self (Player)
		lua_remove(l, -3);
		LuaObject<SystemBody>::PushToLua(liveBody);
		lua_pushstring(l, RingStyle::GetCompositionName(band.composition));
		lua_pushstring(l, RingStyle::GetReserveGradeName(band.reserveGrade));
		pi_lua_protected_call(l, 4, 1);
	} else {
		lua_pop(l, 1);
		lua_getfield(l, -1, "SpawnMiningContainer");
		lua_pushvalue(l, -2);
		lua_remove(l, -3);
		LuaObject<SystemBody>::PushToLua(liveBody);
		pi_lua_protected_call(l, 2, 1);
	}

	if (lua_isnil(l, -1)) {
		lua_pop(l, 1);
		LUA_DEBUG_END(l, 0);
		return;
	}

	CargoBody *cargo = new CargoBody(LuaRef(l, -1), 480.0f);
	lua_pop(l, 1);
	LUA_DEBUG_END(l, 0);

	const FrameId orbFrameId = GetOrbitalFrameId();
	cargo->SetFrame(orbFrameId);
	cargo->SetPosition(hitPosOrb + normalOrb * 3.5);

	vector3d ejectDir = normalOrb.NormalizedSafe();
	const double rx = Pi::rng.Double();
	ejectDir.ArbRotate(vector3d(rx, 1.0 - rx, 0.0), Pi::rng.Double(-0.35, 0.35));
	cargo->SetVelocity(ejectDir * Pi::rng.Double(12.0, 28.0));

	Pi::game->GetSpace()->AddBody(cargo);
	SfxManager::Add(cargo, TYPE_DAMAGE);
}

bool RingField::TraceRay(FrameId rayFrameId, const vector3d &startPos, const vector3d &dir, double maxLen, bool isMining, double &outHitDist)
{
	const SystemBody *sbody = m_planet ? m_planet->GetSystemBody() : nullptr;
	if (!sbody || !sbody->HasRings() || maxLen <= 0.0)
		return false;

	const vector3d normDir = dir.NormalizedSafe();
	if (normDir.LengthSqr() < 0.5)
		return false;

	const FrameId orbFrameId = GetOrbitalFrameId();
	vector3d startOrb = startPos;
	vector3d dirOrb = normDir;
	if (rayFrameId != orbFrameId) {
		Frame *rf = Frame::GetFrame(rayFrameId);
		if (!rf)
			return false;
		const matrix3x3d rToOrb = rf->GetOrientRelTo(orbFrameId);
		startOrb = rToOrb * startPos + rf->GetPositionRelTo(orbFrameId);
		dirOrb = (rToOrb * normDir).NormalizedSafe();
	}

	const vector3d planetPosOrb = m_planet->GetPositionRelTo(orbFrameId);
	const vector3d startRing = m_axialRot.Transpose() * (startOrb - planetPosOrb);
	const vector3d dirRing = m_axialRot.Transpose() * dirOrb;
	const vector3d endRing = startRing + dirRing * maxLen;

	const double minY = std::min(startRing.y, endRing.y);
	const double maxY = std::max(startRing.y, endRing.y);
	if (minY > 900.0 || maxY < -900.0)
		return false;

	const RingStyle &rings = sbody->GetRings();
	const double minR = rings.minRadius.ToDouble() * m_planetRadius - 900.0;
	const double maxR = rings.maxRadius.ToDouble() * m_planetRadius + 900.0;
	const double rStart = std::hypot(startRing.x, startRing.z);
	const double rEnd = std::hypot(endRing.x, endRing.z);
	if (std::min(rStart, rEnd) > maxR && std::max(rStart, rEnd) > maxR) {
		if (startRing.x * endRing.x > 0 && startRing.z * endRing.z > 0)
			return false;
	}
	if (std::max(rStart, rEnd) < minR)
		return false;

	std::vector<RockInstance> candidates;
	candidates.reserve(64);

	auto gatherAlongSegment = [&](double cellSize, bool coarse) {
		int64_t x0 = FloorCell(std::min(startRing.x, endRing.x), cellSize) - 1;
		int64_t x1 = FloorCell(std::max(startRing.x, endRing.x), cellSize) + 1;
		int64_t z0 = FloorCell(std::min(startRing.z, endRing.z), cellSize) - 1;
		int64_t z1 = FloorCell(std::max(startRing.z, endRing.z), cellSize) + 1;
		x0 = std::max(x0, x1 - 30);
		z0 = std::max(z0, z1 - 30);
		for (int64_t gz = z0; gz <= z1; ++gz) {
			for (int64_t gx = x0; gx <= x1; ++gx) {
				GatherCellRocks(gx, gz, cellSize, coarse, candidates);
			}
		}
	};

	gatherAlongSegment(CELL_FINE, false);
	gatherAlongSegment(CELL_COARSE, true);

	bool hit = false;
	double bestT = maxLen;
	RockInstance bestRock{};

	for (const RockInstance &rock : candidates) {
		auto depIt = m_depletedYield.find(rock.id);
		if (depIt != m_depletedYield.end() && depIt->second <= 0.0f)
			continue;

		double t = 0.0;
		if (RaySphereIntersect(startRing, dirRing, rock.pos, rock.collRadius, bestT, t)) {
			bestT = t;
			bestRock = rock;
			hit = true;
		}
	}

	if (!hit)
		return false;

	outHitDist = bestT;

	if (isMining) {
		RingBand band;
		const double rHit = std::hypot(bestRock.pos.x, bestRock.pos.z);
		if (rings.TryGetBandAtRadius(rHit / m_planetRadius, band)) {
			float &yield = m_depletedYield.emplace(bestRock.id, 1.0f).first->second;
			if (yield > 0.0f) {
				const float drain = float(0.125 / RingStyle::GetReserveMultiplier(band.reserveGrade));
				yield = std::max(0.0f, yield - drain);

				const vector3d hitRing = startRing + dirRing * bestT;
				const vector3d normalRing = (hitRing - bestRock.pos).NormalizedSafe();
				const vector3d hitOrb = planetPosOrb + (m_axialRot * hitRing);
				const vector3d normalOrb = (m_axialRot * normalRing).NormalizedSafe();
				SpawnMiningFragment(hitOrb, normalOrb, band);

				// Keep yield cache bounded over long mining sessions
				if (m_depletedYield.size() > 4096) {
					m_depletedYield.clear();
				}
			}
		}
	}

	return true;
}

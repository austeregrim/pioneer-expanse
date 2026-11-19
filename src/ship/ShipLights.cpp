// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "ShipLights.h"

#include "CollMesh.h"
#include "MathUtil.h"
#include "collider/GeomTree.h"
#include "graphics/RenderState.h"
#include "graphics/Types.h"
#include "scenegraph/FindNodeVisitor.h"
#include "scenegraph/MatrixTransform.h"
#include "scenegraph/SceneGraph.h"

#include <algorithm>
#include <cfloat>
#include <cmath>

namespace {

	inline Color MakeEncodedColor(const vector3f &rgb, float intensity, float glareFactor)
	{
		return Color(
			uint8_t(Clamp(rgb.x * intensity, 0.0f, 1.0f) * 255.0f),
			uint8_t(Clamp(rgb.y * intensity, 0.0f, 1.0f) * 255.0f),
			uint8_t(Clamp(rgb.z * intensity, 0.0f, 1.0f) * 255.0f),
			uint8_t(Clamp(glareFactor, 0.0f, 1.0f) * 255.0f));
	}

	inline vector3f ExtractNodePos(SceneGraph::MatrixTransform *mt)
	{
		return mt ? mt->CalcGlobalTransform().GetTranslate() : vector3f(0.0f);
	}

} // namespace

ShipLights::ShipLights(SceneGraph::Model *model, double fallbackRadius) :
	m_beamVerts(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_NORMAL | Graphics::ATTRIB_UV0, 512),
	m_glareVerts(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE | Graphics::ATTRIB_UV0, 128),
	m_podVerts(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE, 512)
{
	const GeomTree *hull = (model && model->GetCollisionMesh()) ? model->GetCollisionMesh()->GetGeomTree() : nullptr;

	vector3f bmin(-float(fallbackRadius) * 0.55f);
	vector3f bmax(float(fallbackRadius) * 0.55f);

	if (hull) {
		const Aabb &hullAabb = hull->GetAabb();
		const vector3d extent = hullAabb.max - hullAabb.min;
		if (extent.x > 0.5 && extent.y > 0.5 && extent.z > 0.5) {
			bmin = vector3f(hullAabb.min);
			bmax = vector3f(hullAabb.max);
		}
	} else if (model && model->GetCollisionMesh()) {
		const Aabb &aabb = model->GetCollisionMesh()->GetAabb();
		const vector3d extent = aabb.max - aabb.min;
		if (extent.x > 0.5 && extent.y > 0.5 && extent.z > 0.5) {
			bmin = vector3f(aabb.min);
			bmax = vector3f(aabb.max);
		}
	}

	const vector3f center = (bmin + bmax) * 0.5f;
	const vector3f size = bmax - bmin;
	const float refScale = Clamp(std::max({ size.x, size.y, size.z }), 10.0f, 220.0f);
	const float podR = Clamp(refScale * 0.0055f, 0.09f, 0.26f);
	const float beaconPodR = Clamp(refScale * 0.0045f, 0.07f, 0.20f);
	const float beamScale = Clamp(refScale / 26.0f, 0.80f, 2.4f);

	// Raycast onto static fuselage collision mesh so emitters sit flush on the ship skin (never floating)
	auto snapToHull = [&](const vector3f &rayStart, const vector3f &rayDir, float maxDist, vector3f &outPos) -> bool {
		if (!hull || maxDist <= 0.1f)
			return false;
		const vector3f dir = rayDir.NormalizedSafe();
		isect_t isect;
		isect.triIdx = -1;
		isect.dist = maxDist;
		hull->TraceRay(rayStart, dir, &isect);
		if (isect.triIdx >= 0 && isect.dist > 0.0f && isect.dist < maxDist) {
			vector3f norm = hull->GetTriNormal(isect.triIdx).NormalizedSafe();
			if (norm.LengthSqr() < 1e-6f)
				norm = -dir;
			else if (norm.Dot(dir) > 0.0f)
				norm = -norm;
			outPos = rayStart + dir * isect.dist + norm * 0.03f;
			return true;
		}
		return false;
	};

	// Measure actual fuselage cross-sections in forward nose, forward belly, and mid spine bands
	float noseMinX = center.x - size.x * 0.20f, noseMaxX = center.x + size.x * 0.20f;
	float noseMinY = center.y - size.y * 0.20f, noseMaxY = center.y + size.y * 0.20f;
	float bellyMinX = center.x - size.x * 0.25f, bellyMaxX = center.x + size.x * 0.25f;
	vector3f portTip(bmin.x, center.y, center.z);
	vector3f stbdTip(bmax.x, center.y, center.z);
	vector3f dorsalPeak(center.x, bmax.y, center.z);
	vector3f ventralKeel(center.x, bmin.y, center.z);
	vector3f sternTail(center.x, center.y, bmax.z);

	if (hull && !hull->GetVertices().empty()) {
		const auto &verts = hull->GetVertices();
		bool hasNose = false, hasBelly = false;
		float nMinX = FLT_MAX, nMaxX = -FLT_MAX, nMinY = FLT_MAX, nMaxY = -FLT_MAX;
		float bMinX = FLT_MAX, bMaxX = -FLT_MAX;
		float minX = FLT_MAX, maxX = -FLT_MAX, maxY = -FLT_MAX, minY = FLT_MAX, maxZ = -FLT_MAX;

		const float noseZCutoff = bmin.z + size.z * 0.24f;
		const float bellyZMin = bmin.z + size.z * 0.16f;
		const float bellyZMax = bmin.z + size.z * 0.50f;

		for (const vector3f &v : verts) {
			if (v.x < minX) { minX = v.x; portTip = v; }
			if (v.x > maxX) { maxX = v.x; stbdTip = v; }
			if (v.y > maxY) { maxY = v.y; dorsalPeak = v; }
			if (v.y < minY) { minY = v.y; ventralKeel = v; }
			if (v.z > maxZ) { maxZ = v.z; sternTail = v; }

			if (v.z <= noseZCutoff) {
				nMinX = std::min(nMinX, v.x);
				nMaxX = std::max(nMaxX, v.x);
				nMinY = std::min(nMinY, v.y);
				nMaxY = std::max(nMaxY, v.y);
				hasNose = true;
			}
			if (v.z >= bellyZMin && v.z <= bellyZMax && std::abs(v.x - center.x) <= size.x * 0.45f) {
				bMinX = std::min(bMinX, v.x);
				bMaxX = std::max(bMaxX, v.x);
				hasBelly = true;
			}
		}

		if (hasNose && (nMaxY - nMinY) > 0.1f) {
			noseMinX = nMinX;
			noseMaxX = nMaxX;
			noseMinY = nMinY;
			noseMaxY = nMaxY;
		}
		if (hasBelly && (bMaxX - bMinX) > 0.2f) {
			bellyMinX = bMinX;
			bellyMaxX = bMaxX;
		}
	}

	// Optional model tags for headlights / landing lights / navlights
	std::vector<vector3f> taggedForward;
	std::vector<vector3f> taggedLanding;
	std::vector<vector3f> taggedRedBeacons;
	std::vector<vector3f> taggedGreenBeacons;

	if (model && model->GetRoot()) {
		SceneGraph::FindNodeVisitor fwdVisitor(SceneGraph::FindNodeVisitor::MATCH_NAME_STARTSWITH, "headlight");
		model->GetRoot()->Accept(fwdVisitor);
		for (SceneGraph::Node *n : fwdVisitor.GetResults()) {
			if (auto *mt = dynamic_cast<SceneGraph::MatrixTransform *>(n))
				taggedForward.push_back(ExtractNodePos(mt));
		}

		SceneGraph::FindNodeVisitor ldgVisitor(SceneGraph::FindNodeVisitor::MATCH_NAME_STARTSWITH, "landinglight");
		model->GetRoot()->Accept(ldgVisitor);
		for (SceneGraph::Node *n : ldgVisitor.GetResults()) {
			if (auto *mt = dynamic_cast<SceneGraph::MatrixTransform *>(n))
				taggedLanding.push_back(ExtractNodePos(mt));
		}

		SceneGraph::FindNodeVisitor redVisitor(SceneGraph::FindNodeVisitor::MATCH_NAME_STARTSWITH, "navlight_red");
		model->GetRoot()->Accept(redVisitor);
		for (SceneGraph::Node *n : redVisitor.GetResults()) {
			if (auto *mt = dynamic_cast<SceneGraph::MatrixTransform *>(n))
				taggedRedBeacons.push_back(ExtractNodePos(mt));
		}

		SceneGraph::FindNodeVisitor greenVisitor(SceneGraph::FindNodeVisitor::MATCH_NAME_STARTSWITH, "navlight_green");
		model->GetRoot()->Accept(greenVisitor);
		for (SceneGraph::Node *n : greenVisitor.GetResults()) {
			if (auto *mt = dynamic_cast<SceneGraph::MatrixTransform *>(n))
				taggedGreenBeacons.push_back(ExtractNodePos(mt));
		}
	}

	// 1. Forward searchlights (-Z is ship forward in Pioneer)
	const vector3f fwdDir = vector3f(0.0f, -0.055f, -1.0f).Normalized();
	auto addForwardFixture = [&](const vector3f &pos) {
		BeamFixture fx;
		fx.localPos = pos;
		fx.localDir = fwdDir;
		fx.colorRGB = vector3f(0.95f, 0.98f, 1.0f);
		fx.spotIntensity = 12.0f;
		fx.rangeM = 2500.0f;
		fx.innerHalfRad = DEG2RAD(14.0f);
		fx.outerHalfRad = DEG2RAD(28.0f);
		fx.coneLenM = 240.0f * beamScale;
		fx.startRadiusM = podR * 1.15f;
		fx.endRadiusM = 46.0f * beamScale;
		fx.podRadiusM = podR;
		m_forwardBeams.push_back(fx);
	};

	if (!taggedForward.empty()) {
		for (size_t i = 0; i < std::min<size_t>(2, taggedForward.size()); ++i)
			addForwardFixture(taggedForward[i]);
	} else {
		const float noseMidY = noseMinY + (noseMaxY - noseMinY) * 0.44f;
		const float noseHalfW = std::max(0.35f, (noseMaxX - noseMinX) * 0.5f);
		const float noseCenterX = 0.5f * (noseMinX + noseMaxX);
		const float rayMax = size.z * 0.70f + 6.0f;
		bool placedPair = false;

		for (float frac : { 0.46f, 0.28f, 0.14f }) {
			const float offX = noseHalfW * frac;
			vector3f hitL, hitR;
			const bool okL = snapToHull(vector3f(noseCenterX - offX, noseMidY, bmin.z - 5.0f), vector3f(0.0f, 0.0f, 1.0f), rayMax, hitL);
			const bool okR = snapToHull(vector3f(noseCenterX + offX, noseMidY, bmin.z - 5.0f), vector3f(0.0f, 0.0f, 1.0f), rayMax, hitR);
			if (okL && okR) {
				// Use the forwardmost Z hit for symmetric bow mounting
				const float symZ = std::min(hitL.z, hitR.z);
				addForwardFixture(vector3f(hitL.x, hitL.y, symZ));
				addForwardFixture(vector3f(hitR.x, hitR.y, symZ));
				placedPair = true;
				break;
			}
		}
		if (!placedPair) {
			vector3f centerNose(noseCenterX, noseMidY, bmin.z + size.z * 0.05f);
			snapToHull(vector3f(noseCenterX, noseMidY, bmin.z - 5.0f), vector3f(0.0f, 0.0f, 1.0f), rayMax, centerNose);
			const float smallOff = std::min(0.6f, noseHalfW * 0.18f);
			addForwardFixture(centerNose + vector3f(-smallOff, 0.0f, 0.0f));
			addForwardFixture(centerNose + vector3f(+smallOff, 0.0f, 0.0f));
		}
	}

	// 2. Landing floodlights (~40 deg forward-downward on forward belly hull skin)
	const vector3f ldgDir = vector3f(0.0f, -0.64f, -0.77f).Normalized();
	auto addLandingFixture = [&](const vector3f &pos) {
		BeamFixture fx;
		fx.localPos = pos;
		fx.localDir = ldgDir;
		fx.colorRGB = vector3f(1.0f, 0.92f, 0.76f);
		fx.spotIntensity = 7.0f;
		fx.rangeM = 950.0f;
		fx.innerHalfRad = DEG2RAD(22.0f);
		fx.outerHalfRad = DEG2RAD(42.0f);
		fx.coneLenM = 115.0f * beamScale;
		fx.startRadiusM = podR * 1.1f;
		fx.endRadiusM = 38.0f * beamScale;
		fx.podRadiusM = podR * 0.95f;
		m_landingBeams.push_back(fx);
	};

	if (!taggedLanding.empty()) {
		for (size_t i = 0; i < std::min<size_t>(2, taggedLanding.size()); ++i)
			addLandingFixture(taggedLanding[i]);
	} else {
		const float bellyZ = bmin.z + size.z * 0.28f;
		const float bellyHalfW = std::max(0.35f, (bellyMaxX - bellyMinX) * 0.5f);
		const float bellyCenterX = 0.5f * (bellyMinX + bellyMaxX);
		const float rayMaxY = size.y + 8.0f;
		bool placedBelly = false;

		for (float frac : { 0.22f, 0.12f, 0.04f }) {
			const float offX = bellyHalfW * frac;
			vector3f hitL, hitR;
			const bool okL = snapToHull(vector3f(bellyCenterX - offX, bmin.y - 5.0f, bellyZ), vector3f(0.0f, 1.0f, 0.0f), rayMaxY, hitL);
			const bool okR = snapToHull(vector3f(bellyCenterX + offX, bmin.y - 5.0f, bellyZ), vector3f(0.0f, 1.0f, 0.0f), rayMaxY, hitR);
			if (okL && okR) {
				addLandingFixture(hitL);
				addLandingFixture(hitR);
				placedBelly = true;
				break;
			}
		}
		if (!placedBelly) {
			vector3f fallbackBelly(bellyCenterX, noseMinY, bellyZ);
			snapToHull(vector3f(bellyCenterX, bmin.y - 5.0f, bellyZ), vector3f(0.0f, 1.0f, 0.0f), rayMaxY, fallbackBelly);
			addLandingFixture(fallbackBelly + vector3f(-0.35f, 0.0f, 0.0f));
			addLandingFixture(fallbackBelly + vector3f(+0.35f, 0.0f, 0.0f));
		}
	}

	// 3. Navigation & anti-collision beacon emissives snapped flush to hull geometry
	auto addBeacon = [&](const vector3f &pos, const vector3f &col, StrobePattern pattern, float gScale) {
		BeaconFixture b;
		b.localPos = pos;
		b.colorRGB = col;
		b.podRadiusM = beaconPodR;
		b.glareRadiusM = Clamp(refScale * 0.075f, 1.1f, 3.6f) * gScale;
		b.pattern = pattern;
		m_beacons.push_back(b);
	};

	if (!taggedRedBeacons.empty()) {
		for (const vector3f &p : taggedRedBeacons)
			addBeacon(p, vector3f(1.0f, 0.14f, 0.10f), StrobePattern::PULSE, 0.78f);
	} else {
		vector3f snappedPort = portTip;
		snapToHull(vector3f(portTip.x - 4.0f, portTip.y, portTip.z), vector3f(1.0f, 0.0f, 0.0f), size.x * 0.4f + 5.0f, snappedPort);
		addBeacon(snappedPort, vector3f(1.0f, 0.14f, 0.10f), StrobePattern::PULSE, 0.78f);
	}

	if (!taggedGreenBeacons.empty()) {
		for (const vector3f &p : taggedGreenBeacons)
			addBeacon(p, vector3f(0.14f, 1.0f, 0.36f), StrobePattern::PULSE, 0.78f);
	} else {
		vector3f snappedStbd = stbdTip;
		snapToHull(vector3f(stbdTip.x + 4.0f, stbdTip.y, stbdTip.z), vector3f(-1.0f, 0.0f, 0.0f), size.x * 0.4f + 5.0f, snappedStbd);
		addBeacon(snappedStbd, vector3f(0.14f, 1.0f, 0.36f), StrobePattern::PULSE, 0.78f);
	}

	// Aft tail position beacon snapped to upper stern
	vector3f snappedTail = sternTail;
	snapToHull(vector3f(center.x, sternTail.y, bmax.z + 4.0f), vector3f(0.0f, 0.0f, -1.0f), size.z * 0.35f + 5.0f, snappedTail);
	addBeacon(snappedTail, vector3f(1.0f, 0.94f, 0.82f), StrobePattern::STEADY, 0.68f);

	// Dorsal & ventral anti-collision double-flash strobes snapped to spine and keel
	vector3f snappedDorsal = dorsalPeak;
	snapToHull(vector3f(center.x, bmax.y + 4.0f, dorsalPeak.z), vector3f(0.0f, -1.0f, 0.0f), size.y * 0.5f + 5.0f, snappedDorsal);
	addBeacon(snappedDorsal, vector3f(1.0f, 0.28f, 0.08f), StrobePattern::DOUBLE_STROBE_A, 1.15f);

	vector3f snappedVentral = ventralKeel;
	snapToHull(vector3f(center.x, bmin.y - 4.0f, ventralKeel.z), vector3f(0.0f, 1.0f, 0.0f), size.y * 0.5f + 5.0f, snappedVentral);
	addBeacon(snappedVentral, vector3f(0.95f, 0.98f, 1.0f), StrobePattern::DOUBLE_STROBE_B, 1.15f);
}

void ShipLights::EnsureMaterials(Graphics::Renderer *r)
{
	if (!r)
		return;

	if (!m_beamMat.Valid()) {
		Graphics::MaterialDescriptor desc;
		Graphics::RenderStateDesc rsd;
		rsd.blendMode = Graphics::BLEND_ADDITIVE;
		rsd.depthTest = true;
		rsd.depthWrite = false;
		rsd.cullMode = Graphics::CULL_NONE;
		rsd.primitiveType = Graphics::TRIANGLES;
		const auto vfmt = Graphics::VertexFormatDesc::FromAttribSet(
			Graphics::ATTRIB_POSITION | Graphics::ATTRIB_NORMAL | Graphics::ATTRIB_UV0);
		m_beamMat.Reset(r->CreateMaterial("ship_light_beam", desc, rsd, vfmt));
	}

	if (!m_glareMat.Valid()) {
		Graphics::MaterialDescriptor desc;
		desc.vertexColors = true;
		Graphics::RenderStateDesc rsd;
		rsd.blendMode = Graphics::BLEND_ADDITIVE;
		rsd.depthTest = true;
		rsd.depthWrite = false;
		rsd.cullMode = Graphics::CULL_NONE;
		rsd.primitiveType = Graphics::TRIANGLES;
		const auto vfmt = Graphics::VertexFormatDesc::FromAttribSet(
			Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE | Graphics::ATTRIB_UV0);
		m_glareMat.Reset(r->CreateMaterial("ship_light_glare", desc, rsd, vfmt));
	}

	if (!m_podMat.Valid()) {
		Graphics::MaterialDescriptor desc;
		desc.vertexColors = true;
		Graphics::RenderStateDesc rsd;
		rsd.blendMode = Graphics::BLEND_SOLID;
		rsd.depthTest = true;
		rsd.depthWrite = true;
		rsd.cullMode = Graphics::CULL_NONE;
		rsd.primitiveType = Graphics::TRIANGLES;
		const auto vfmt = Graphics::VertexFormatDesc::FromAttribSet(
			Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE);
		m_podMat.Reset(r->CreateMaterial("unlit", desc, rsd, vfmt));
	}
}

void ShipLights::Update(float timeStep)
{
	if (timeStep > 0.0f) {
		m_time = std::fmod(m_time + timeStep, 640.0f);
	}
}

float ShipLights::EvalStrobeIntensity(StrobePattern pattern) const
{
	switch (pattern) {
	case StrobePattern::STEADY:
		return 0.78f;
	case StrobePattern::PULSE: {
		const float wave = 0.5f + 0.5f * std::sin(m_time * 3.1f);
		return 0.52f + 0.42f * wave;
	}
	case StrobePattern::DOUBLE_STROBE_A:
	case StrobePattern::DOUBLE_STROBE_B: {
		const float offset = (pattern == StrobePattern::DOUBLE_STROBE_B) ? 0.82f : 0.0f;
		const float phase = std::fmod(m_time + offset, 1.64f);
		const float p1 = std::exp(-std::pow((phase - 0.10f) / 0.038f, 2.0f));
		const float p2 = 0.85f * std::exp(-std::pow((phase - 0.25f) / 0.042f, 2.0f));
		return Clamp(0.18f + 0.82f * std::max(p1, p2), 0.18f, 1.0f);
	}
	default:
		return 0.75f;
	}
}

void ShipLights::CollectSpotLights(const matrix4x4d &shipToCam, bool forwardOn, bool landingOn,
	std::vector<Graphics::SpotLight> &outLights) const
{
	if (!forwardOn && !landingOn)
		return;

	const matrix3x3d rot = shipToCam.GetOrient();

	auto pushGroup = [&](const std::vector<BeamFixture> &fixtures) {
		for (const BeamFixture &fx : fixtures) {
			if (outLights.size() >= Graphics::MAX_SPOT_LIGHTS)
				return;
			Graphics::SpotLight sl;
			sl.position = vector3f(shipToCam * vector3d(fx.localPos));
			sl.range = fx.rangeM;
			sl.direction = vector3f((rot * vector3d(fx.localDir)).NormalizedSafe());
			sl.innerCos = std::cos(fx.innerHalfRad);
			sl.color = fx.colorRGB * fx.spotIntensity;
			sl.outerCos = std::cos(fx.outerHalfRad);
			outLights.push_back(sl);
		}
	};

	// Prioritize landing floodlights when both are active if the ship has multiple sources
	if (forwardOn)
		pushGroup(m_forwardBeams);
	if (landingOn)
		pushGroup(m_landingBeams);
}

void ShipLights::AppendBeamCones(Graphics::VertexArray &va, const BeamFixture &fx, bool innerCore) const
{
	constexpr int NUM_SLICES = 18;
	const vector3f axis = fx.localDir.NormalizedSafe();
	vector3f upRef = (std::abs(axis.y) < 0.9f) ? vector3f(0.0f, 1.0f, 0.0f) : vector3f(1.0f, 0.0f, 0.0f);
	const vector3f tangent = upRef.Cross(axis).NormalizedSafe();
	const vector3f bitangent = axis.Cross(tangent).NormalizedSafe();

	const float r0 = fx.startRadiusM * (innerCore ? 0.70f : 1.05f);
	const float r1 = fx.endRadiusM * (innerCore ? 0.58f : 1.0f);
	const float len = fx.coneLenM * (innerCore ? 1.0f : 0.78f);
	const vector3f tip = fx.localPos;
	const vector3f base = fx.localPos + axis * len;
	const float tiltLen = std::sqrt(len * len + (r1 - r0) * (r1 - r0));
	const float radialSlope = (r1 - r0) / std::max(tiltLen, 0.001f);
	const float axialSlope = len / std::max(tiltLen, 0.001f);

	for (int i = 0; i < NUM_SLICES; ++i) {
		const float a0 = (2.0f * float(M_PI) * float(i)) / float(NUM_SLICES);
		const float a1 = (2.0f * float(M_PI) * float(i + 1)) / float(NUM_SLICES);

		const vector3f rad0 = tangent * std::cos(a0) + bitangent * std::sin(a0);
		const vector3f rad1 = tangent * std::cos(a1) + bitangent * std::sin(a1);
		const vector3f n0 = (rad0 * axialSlope - axis * radialSlope).NormalizedSafe();
		const vector3f n1 = (rad1 * axialSlope - axis * radialSlope).NormalizedSafe();

		const vector3f p00 = tip + rad0 * r0;
		const vector3f p01 = tip + rad1 * r0;
		const vector3f p10 = base + rad0 * r1;
		const vector3f p11 = base + rad1 * r1;

		va.Add(p00, n0, vector2f(0.0f, 0.0f));
		va.Add(p10, n0, vector2f(1.0f, 0.0f));
		va.Add(p11, n1, vector2f(1.0f, 0.0f));

		va.Add(p00, n0, vector2f(0.0f, 0.0f));
		va.Add(p11, n1, vector2f(1.0f, 0.0f));
		va.Add(p01, n1, vector2f(0.0f, 0.0f));
	}
}

void ShipLights::AppendEmitterPod(Graphics::VertexArray &va, const vector3f &pos, float radius, const Color &col) const
{
	// Compact 8-triangle octahedron housing marker anchored on ship exterior
	const vector3f px = pos + vector3f(radius, 0.0f, 0.0f);
	const vector3f nx = pos - vector3f(radius, 0.0f, 0.0f);
	const vector3f py = pos + vector3f(0.0f, radius, 0.0f);
	const vector3f ny = pos - vector3f(0.0f, radius, 0.0f);
	const vector3f pz = pos + vector3f(0.0f, 0.0f, radius);
	const vector3f nz = pos - vector3f(0.0f, 0.0f, radius);

	auto addTri = [&](const vector3f &a, const vector3f &b, const vector3f &c) {
		va.Add(a, col);
		va.Add(b, col);
		va.Add(c, col);
	};

	addTri(py, pz, px);
	addTri(py, px, nz);
	addTri(py, nz, nx);
	addTri(py, nx, pz);
	addTri(ny, px, pz);
	addTri(ny, nz, px);
	addTri(ny, nx, nz);
	addTri(ny, pz, nx);
}

void ShipLights::AppendGlareQuad(Graphics::VertexArray &va, const vector3f &viewPos, float worldRadius, const Color &col) const
{
	const vector3f camFwd = (-viewPos).NormalizedSafe();
	vector3f right = vector3f(0.0f, 1.0f, 0.0f).Cross(camFwd);
	if (right.LengthSqr() < 1e-5f)
		right = vector3f(1.0f, 0.0f, 0.0f);
	else
		right = right.Normalized();
	const vector3f up = camFwd.Cross(right).NormalizedSafe();

	const vector3f rx = right * worldRadius;
	const vector3f uy = up * worldRadius;

	const vector3f bl = viewPos - rx - uy;
	const vector3f br = viewPos + rx - uy;
	const vector3f tr = viewPos + rx + uy;
	const vector3f tl = viewPos - rx + uy;

	va.Add(bl, col, vector2f(-1.0f, -1.0f));
	va.Add(br, col, vector2f(+1.0f, -1.0f));
	va.Add(tr, col, vector2f(+1.0f, +1.0f));

	va.Add(bl, col, vector2f(-1.0f, -1.0f));
	va.Add(tr, col, vector2f(+1.0f, +1.0f));
	va.Add(tl, col, vector2f(-1.0f, +1.0f));
}

void ShipLights::DrawBeamBatch(Graphics::Renderer *r, const matrix4x4d &shipToCam,
	const std::vector<BeamFixture> &fixtures, float atmoScatter, float nearFade)
{
	if (fixtures.empty() || !m_beamMat.Valid())
		return;

	static const size_t s_beamColorHash = "beamColor"_hash;
	static const size_t s_nearFadeHash = "nearFade"_hash;

	r->SetTransform(matrix4x4f(shipToCam));
	const vector3f rgb = fixtures.front().colorRGB;
	const float scatter = Clamp(atmoScatter, 0.14f, 0.85f);

	// 1. Wide outer volumetric atmospheric scatter sheath
	m_beamVerts.Clear();
	for (const BeamFixture &fx : fixtures)
		AppendBeamCones(m_beamVerts, fx, false);
	if (!m_beamVerts.IsEmpty()) {
		m_beamMat->SetPushConstant(s_beamColorHash, rgb, Clamp(scatter * 0.30f, 0.05f, 0.28f));
		m_beamMat->SetPushConstant(s_nearFadeHash, nearFade);
		r->DrawBuffer(&m_beamVerts, m_beamMat.Get());
	}

	// 2. Concentrated inner beam core
	m_beamVerts.Clear();
	for (const BeamFixture &fx : fixtures)
		AppendBeamCones(m_beamVerts, fx, true);
	if (!m_beamVerts.IsEmpty()) {
		m_beamMat->SetPushConstant(s_beamColorHash, rgb, Clamp(scatter * 0.62f, 0.12f, 0.50f));
		m_beamMat->SetPushConstant(s_nearFadeHash, nearFade);
		r->DrawBuffer(&m_beamVerts, m_beamMat.Get());
	}
}

void ShipLights::RenderExterior(Graphics::Renderer *r, const matrix4x4d &shipToCam,
	bool beaconsOn, bool forwardOn, bool landingOn, float atmoScatter)
{
	EnsureMaterials(r);

	// 1. Physical 3D light housings & lenses on the hull
	m_podVerts.Clear();
	for (const BeamFixture &fx : m_forwardBeams) {
		const Color col = forwardOn
			? Color(245, 250, 255, 255)
			: Color(36, 44, 54, 255);
		AppendEmitterPod(m_podVerts, fx.localPos, fx.podRadiusM, col);
	}
	for (const BeamFixture &fx : m_landingBeams) {
		const Color col = landingOn
			? Color(255, 236, 195, 255)
			: Color(42, 38, 32, 255);
		AppendEmitterPod(m_podVerts, fx.localPos, fx.podRadiusM, col);
	}
	for (const BeaconFixture &b : m_beacons) {
		const float k = beaconsOn ? EvalStrobeIntensity(b.pattern) : 0.14f;
		const Color col = MakeEncodedColor(b.colorRGB, beaconsOn ? (0.35f + 0.65f * k) : 0.16f, 1.0f);
		AppendEmitterPod(m_podVerts, b.localPos, b.podRadiusM, col);
	}
	if (!m_podVerts.IsEmpty() && m_podMat.Valid()) {
		r->SetTransform(matrix4x4f(shipToCam));
		r->DrawBuffer(&m_podVerts, m_podMat.Get());
	}

	// 2. Volumetric light beam cones in ship-local space
	if (forwardOn)
		DrawBeamBatch(r, shipToCam, m_forwardBeams, atmoScatter, 0.0f);
	if (landingOn)
		DrawBeamBatch(r, shipToCam, m_landingBeams, atmoScatter, 0.0f);

	// 3. Visible camera-facing lens glow & direct-view starburst glare (view space, depth-tested against ship hull)
	m_glareVerts.Clear();
	const matrix3x3d rot = shipToCam.GetOrient();

	auto addBeamGlare = [&](const std::vector<BeamFixture> &fixtures) {
		for (const BeamFixture &fx : fixtures) {
			const vector3f viewPos = vector3f(shipToCam * vector3d(fx.localPos));
			const float dist = viewPos.Length();
			if (dist < 0.5f || dist > 6000.0f)
				continue;

			const vector3f toCam = (-viewPos) / dist;
			const vector3f viewDir = vector3f((rot * vector3d(fx.localDir)).NormalizedSafe());
			const float align = std::max(0.0f, viewDir.Dot(toCam));
			const float glare = std::pow(Clamp((align - 0.12f) / 0.88f, 0.0f, 1.0f), 1.85f);

			const vector3f glarePos = viewPos + toCam * (fx.podRadiusM * 1.45f);
			const float baseSize = std::max(fx.podRadiusM * 3.8f, Clamp(dist * 0.020f, 1.2f, 5.5f));
			const float glareSize = baseSize * (1.0f + 2.35f * glare);
			const float intensity = 0.55f + 0.45f * glare;
			AppendGlareQuad(m_glareVerts, glarePos, glareSize, MakeEncodedColor(fx.colorRGB, intensity, glare));
		}
	};

	if (forwardOn)
		addBeamGlare(m_forwardBeams);
	if (landingOn)
		addBeamGlare(m_landingBeams);

	if (beaconsOn) {
		for (const BeaconFixture &b : m_beacons) {
			const vector3f viewPos = vector3f(shipToCam * vector3d(b.localPos));
			const float dist = viewPos.Length();
			if (dist < 0.4f || dist > 8000.0f)
				continue;

			const float k = EvalStrobeIntensity(b.pattern);
			const bool isStrobe = (b.pattern == StrobePattern::DOUBLE_STROBE_A || b.pattern == StrobePattern::DOUBLE_STROBE_B);
			const float glare = isStrobe
				? Clamp((k - 0.25f) * 1.35f, 0.0f, 1.0f)
				: (0.28f + 0.35f * k);
			const vector3f toCam = (-viewPos) / dist;
			const vector3f glarePos = viewPos + toCam * (b.podRadiusM * 1.45f);
			const float radius = std::max(b.glareRadiusM, Clamp(dist * 0.018f, 1.0f, 4.8f)) * (0.65f + 0.55f * k);
			AppendGlareQuad(m_glareVerts, glarePos, radius, MakeEncodedColor(b.colorRGB, 0.40f + 0.60f * k, glare));
		}
	}

	if (!m_glareVerts.IsEmpty() && m_glareMat.Valid()) {
		r->SetTransform(matrix4x4f::Identity);
		r->DrawBuffer(&m_glareVerts, m_glareMat.Get());
	}
}

void ShipLights::RenderCockpitBeams(Graphics::Renderer *r, const matrix4x4d &shipToCam,
	bool forwardOn, bool landingOn, float atmoScatter)
{
	if (!forwardOn && !landingOn)
		return;
	EnsureMaterials(r);

	if (forwardOn)
		DrawBeamBatch(r, shipToCam, m_forwardBeams, atmoScatter, 1.0f);
	if (landingOn)
		DrawBeamBatch(r, shipToCam, m_landingBeams, atmoScatter, 1.0f);
}

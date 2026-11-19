// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef _SHIPLIGHTS_H
#define _SHIPLIGHTS_H

#include "Color.h"
#include "graphics/Material.h"
#include "graphics/Renderer.h"
#include "graphics/VertexArray.h"
#include "matrix4x4.h"
#include "vector3.h"

#include <vector>

namespace SceneGraph {
	class Model;
} // namespace SceneGraph

class ShipLights {
public:
	enum class StrobePattern : uint8_t {
		STEADY = 0,
		PULSE,
		DOUBLE_STROBE_A,
		DOUBLE_STROBE_B
	};

	struct BeamFixture {
		vector3f localPos;
		vector3f localDir;
		vector3f colorRGB;
		float spotIntensity = 2.5f;
		float rangeM = 1200.0f;
		float innerHalfRad = 0.24f;
		float outerHalfRad = 0.48f;
		float coneLenM = 140.0f;
		float startRadiusM = 0.45f;
		float endRadiusM = 28.0f;
		float podRadiusM = 0.30f;
	};

	struct BeaconFixture {
		vector3f localPos;
		vector3f colorRGB;
		float podRadiusM = 0.22f;
		float glareRadiusM = 2.6f;
		StrobePattern pattern = StrobePattern::STEADY;
	};

	ShipLights(SceneGraph::Model *model, double fallbackRadius);

	void Update(float timeStep);

	void CollectSpotLights(const matrix4x4d &shipToCam, bool forwardOn, bool landingOn,
		std::vector<Graphics::SpotLight> &outLights) const;

	void RenderExterior(Graphics::Renderer *r, const matrix4x4d &shipToCam,
		bool beaconsOn, bool forwardOn, bool landingOn, float atmoScatter);

	void RenderCockpitBeams(Graphics::Renderer *r, const matrix4x4d &shipToCam,
		bool forwardOn, bool landingOn, float atmoScatter);

private:
	void EnsureMaterials(Graphics::Renderer *r);
	float EvalStrobeIntensity(StrobePattern pattern) const;
	void AppendBeamCones(Graphics::VertexArray &va, const BeamFixture &fx, bool innerCore) const;
	void AppendEmitterPod(Graphics::VertexArray &va, const vector3f &pos, float radius, const Color &col) const;
	void AppendGlareQuad(Graphics::VertexArray &va, const vector3f &viewPos, float worldRadius, const Color &col) const;
	void DrawBeamBatch(Graphics::Renderer *r, const matrix4x4d &shipToCam,
		const std::vector<BeamFixture> &fixtures, float atmoScatter, float nearFade);

	std::vector<BeamFixture> m_forwardBeams;
	std::vector<BeamFixture> m_landingBeams;
	std::vector<BeaconFixture> m_beacons;

	float m_time = 0.0f;

	RefCountedPtr<Graphics::Material> m_beamMat;
	RefCountedPtr<Graphics::Material> m_glareMat;
	RefCountedPtr<Graphics::Material> m_podMat;
	Graphics::VertexArray m_beamVerts;
	Graphics::VertexArray m_glareVerts;
	Graphics::VertexArray m_podVerts;
};

#endif /* _SHIPLIGHTS_H */

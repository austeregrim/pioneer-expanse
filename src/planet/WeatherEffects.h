// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef _WEATHEREFFECTS_H
#define _WEATHEREFFECTS_H

#include "graphics/Material.h"
#include "graphics/VertexArray.h"
#include "matrix4x4.h"
#include "vector3.h"

#include <memory>
#include <vector>

namespace Graphics {
	class Renderer;
} // namespace Graphics

class Ship;

class WeatherEffects {
public:
	explicit WeatherEffects(Ship *ship);

	void Update(float timeStep);
	void Render(Graphics::Renderer *r);

	void SetTransform(const matrix4x4d &t) { m_transform = t; }

private:
	static constexpr int NUM_PARTICLES = 1800;
	static constexpr int NEAR_PARTICLES = 1150;
	static constexpr int NUM_VOLCANIC_PARTICLES = 360;
	static constexpr float NEAR_BOUNDS = 18.0f;
	static constexpr float BOX_BOUNDS = 40.0f;
	static constexpr float VOLCANIC_BOUNDS = 34.0f;

	void InitMaterials(Graphics::Renderer *r);
	void BuildLightningBolt(const vector3d &east, const vector3d &north, const vector3d &up,
		double aglMeters, double cloudBaseMeters, float distanceM, float azimuthRad, uint32_t boltSeed, float intensity);

	Ship *m_ship;
	std::vector<vector3f> m_particles;
	std::vector<vector3f> m_volcanicParticles;

	RefCountedPtr<Graphics::Material> m_precipMaterial;
	RefCountedPtr<Graphics::Material> m_lightningMaterial;
	RefCountedPtr<Graphics::Material> m_lightningBloomMaterial;
	Graphics::VertexArray m_precipVerts;
	Graphics::VertexArray m_volcanicVerts;
	Graphics::VertexArray m_lightningVerts;
	Graphics::VertexArray m_lightningBloomVerts;

	matrix4x4d m_transform;
	bool m_precipVisible;
	bool m_volcanicVisible;
	bool m_lightningVisible;
};

#endif /* _WEATHEREFFECTS_H */

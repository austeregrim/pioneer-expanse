// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef _PLANET_H
#define _PLANET_H

#include "RefCounted.h"
#include "TerrainBody.h"
#include "graphics/VertexArray.h"
#include "planet/WeatherSystem.h"

namespace Graphics {
	class Renderer;
	class Texture;
	class Material;
	class MeshObject;
} // namespace Graphics

class RingField;
class SurfaceScatter;

class Planet : public TerrainBody {
public:
	OBJDEF(Planet, TerrainBody, PLANET);
	Planet() = delete;
	Planet(SystemBody *);
	Planet(const Json &jsonObj, Space *space);
	virtual ~Planet();

	void TimeStepUpdate(const float timeStep) override;
	void SubRender(Graphics::Renderer *r, const matrix4x4d &viewTran, const vector3d &camPos) override;
	bool TraceRingRay(FrameId rayFrameId, const vector3d &startPos, const vector3d &dir, double maxLen, bool isMining, double &outHitDist);

	void GetAtmosphericState(double dist, double *outPressure, double *outDensity) const;
	WeatherState GetWeatherState(const vector3d &posRotFrame, double gameTime) const;
	double GetAtmosphereRadius() const { return m_atmosphereRadius; }

	friend class ObjectViewerView;

protected:
private:
	void InitParams(const SystemBody *);
	void GenerateRings(Graphics::Renderer *renderer);
	void DrawGasGiantRings(Graphics::Renderer *r, const matrix4x4d &modelView);

	double m_atmosphereRadius;
	double m_surfaceGravity_g;
	struct WeatherCacheEntry {
		bool valid = false;
		vector3d posRotFrame = vector3d(0.0);
		double gameTime = 0.0;
		WeatherState state{};
	};
	static constexpr size_t WEATHER_CACHE_SLOTS = 4;
	mutable WeatherCacheEntry m_weatherCache[WEATHER_CACHE_SLOTS];
	mutable size_t m_weatherCacheCursor = 0;
	RefCountedPtr<Graphics::Texture> m_ringTexture;
	RefCountedPtr<Graphics::Texture> m_ringNoiseTexture;
	std::unique_ptr<Graphics::Material> m_ringMaterial;
	std::unique_ptr<Graphics::MeshObject> m_ringMesh;
	std::unique_ptr<RingField> m_ringField;
	std::unique_ptr<SurfaceScatter> m_surfaceScatter;
};

#endif /* _PLANET_H */

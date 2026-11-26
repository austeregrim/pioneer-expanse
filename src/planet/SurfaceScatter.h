// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef _SURFACESCATTER_H
#define _SURFACESCATTER_H

#include "Color.h"
#include "graphics/VertexArray.h"
#include "matrix3x3.h"
#include "matrix4x4.h"
#include "vector3.h"

#include <array>
#include <cstdint>
#include <list>
#include <memory>
#include <unordered_map>
#include <vector>

class Planet;

namespace Graphics {
	class Material;
	class MeshObject;
	class Renderer;
} // namespace Graphics

// Deterministic procedural 3D boulder, outcrop, and cobble scatter for rocky planet surfaces.
class SurfaceScatter {
public:
	explicit SurfaceScatter(Planet *planet);
	~SurfaceScatter();

	void Render(Graphics::Renderer *r, const matrix4x4d &viewTran, const vector3d &camPos);

private:
	struct RockInstance {
		vector3d posRotM;    // World position in planet rotating frame (meters)
		vector3d surfNormal; // Local terrain surface normal in planet rotating frame
		matrix3x3d orient;   // Orientation aligned to local terrain normal + yaw/tilt
		double scale;        // Visual scale in meters
		double maxDist;      // Tier cull distance in meters
		Color color;         // Biome-tinted vertex modulation color
		uint8_t variant;     // Mesh variant index [0..NUM_VARIANTS-1]
	};

	struct RockInstanceGPU {
		matrix4x4f modelView;
		Color4f diffuse;
		Color4f emissive; // rgb = skyBounce + spotlight boost, a = primary star terrain visibility
	};

	struct CellKey {
		int64_t gx;
		int64_t gz;
		uint8_t face;
		uint8_t tier;

		bool operator==(const CellKey &o) const
		{
			return gx == o.gx && gz == o.gz && face == o.face && tier == o.tier;
		}
	};

	struct CellKeyHash {
		size_t operator()(const CellKey &k) const noexcept;
	};

	struct CachedCell {
		std::vector<RockInstance> rocks;
		std::list<CellKey>::iterator lruIt;
		vector3d centerPosRotM = vector3d::Zero;
		float cachedSunVis = 1.0f;
		double sunVisGameTime = -1e30;
		vector3d sunVisStarDir = vector3d::Zero;
	};

	static constexpr int NUM_VARIANTS = 6;
	static constexpr int MAX_VISIBLE_ROCKS = 1400;
	static constexpr size_t MAX_CACHED_CELLS = 1024;
	static constexpr double CELL_LARGE = 64.0;
	static constexpr double CELL_SMALL = 24.0;

	void InitGraphics(Graphics::Renderer *r, int quality, bool enhanced);
	std::unique_ptr<Graphics::MeshObject> BuildRockMesh(Graphics::Renderer *r, uint32_t seed, int variant, int subdivs, bool withTangents) const;
	vector3d CubeMetersToUnit(int face, double uM, double vM) const;
	CachedCell &GetOrBuildCell(int face, uint8_t tier, int64_t gx, int64_t gz);

	Planet *m_planet;
	double m_planetRadius;
	double m_invPlanetRadius;
	uint32_t m_baseSeed;
	bool m_hasOcean;
	bool m_hasLava;
	double m_icyness;
	double m_volcanicity;
	Color m_dustColor;
	int m_builtQuality = -1;
	bool m_builtEnhanced = false;

	std::unique_ptr<Graphics::Material> m_rockMaterial;
	std::unique_ptr<Graphics::Material> m_shadowMaterial;
	std::array<std::unique_ptr<Graphics::MeshObject>, NUM_VARIANTS> m_rockMeshes;
	Graphics::VertexArray m_shadowVerts;
	std::list<CellKey> m_lruList;
	std::unordered_map<CellKey, CachedCell, CellKeyHash> m_cellCache;
	std::array<std::vector<RockInstanceGPU>, NUM_VARIANTS> m_variantBuckets;
};

#endif /* _SURFACESCATTER_H */

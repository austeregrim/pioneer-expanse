// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef _SURFACESCATTER_H
#define _SURFACESCATTER_H

#include "Color.h"
#include "matrix3x3.h"
#include "matrix4x4.h"
#include "vector3.h"

#include <array>
#include <cstdint>
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
		vector3d posRotM;   // World position in planet rotating frame (meters)
		matrix3x3d orient;  // Orientation aligned to local terrain normal + yaw/tilt
		double scale;       // Visual scale in meters
		double maxDist;     // Tier cull distance in meters
		Color color;        // Biome-tinted vertex modulation color
		uint8_t variant;    // Mesh variant index [0..NUM_VARIANTS-1]
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

	static constexpr int NUM_VARIANTS = 6;
	static constexpr int MAX_VISIBLE_ROCKS = 750;
	static constexpr size_t MAX_CACHED_CELLS = 512;
	static constexpr double CELL_LARGE = 64.0;
	static constexpr double CELL_SMALL = 24.0;

	void InitGraphics(Graphics::Renderer *r);
	std::unique_ptr<Graphics::MeshObject> BuildRockMesh(Graphics::Renderer *r, uint32_t seed, int variant) const;
	vector3d CubeMetersToUnit(int face, double uM, double vM) const;
	const std::vector<RockInstance> &GetOrBuildCell(int face, uint8_t tier, int64_t gx, int64_t gz);

	Planet *m_planet;
	double m_planetRadius;
	double m_invPlanetRadius;
	uint32_t m_baseSeed;
	bool m_hasOcean;
	bool m_hasLava;
	double m_icyness;
	double m_volcanicity;
	Color m_dustColor;

	std::unique_ptr<Graphics::Material> m_rockMaterial;
	std::array<std::unique_ptr<Graphics::MeshObject>, NUM_VARIANTS> m_rockMeshes;
	std::unordered_map<CellKey, std::vector<RockInstance>, CellKeyHash> m_cellCache;
};

#endif /* _SURFACESCATTER_H */

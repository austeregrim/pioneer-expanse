// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef _RINGFIELD_H
#define _RINGFIELD_H

#include "FrameId.h"
#include "galaxy/RingStyle.h"
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
class SystemBody;

namespace Graphics {
	class Material;
	class MeshObject;
	class Renderer;
} // namespace Graphics

class RingField {
public:
	explicit RingField(Planet *planet);
	~RingField();

	void TimeStepUpdate(float timeStep);
	void Render(Graphics::Renderer *r, const matrix4x4d &viewTran, const vector3d &camPos);

	// Traces a weapon/mining ray against volumetric ring boulders.
	// Coordinates are expressed in rayFrameId; outHitDist returns hit distance along dir.
	bool TraceRay(FrameId rayFrameId, const vector3d &startPos, const vector3d &dir, double maxLen, bool isMining, double &outHitDist);

private:
	enum class RockTier : uint8_t {
		MICRO = 0,
		FINE = 1,
		COARSE = 2,
		FAR = 3
	};

	struct RockInstance {
		uint64_t id;
		vector3d pos;	  // position in axial-tilted non-spinning ringLocal frame (meters)
		vector3d posView; // cached view-space position during frustum-culled render gathering
		double scale;	  // visual radius in meters
		double collRadius;
		vector3d spinAxis;
		double spinRate;
		double phase;
		Color color;
		uint8_t variant;
		RockTier tier;
	};

	struct RockInstanceGPU {
		matrix4x4f modelView;
		Color4f diffuse;
		Color4f emissive;
	};

	struct CellKey {
		int64_t gx;
		int64_t gz;
		uint8_t tier;

		bool operator==(const CellKey &o) const
		{
			return gx == o.gx && gz == o.gz && tier == o.tier;
		}
	};

	struct CellKeyHash {
		size_t operator()(const CellKey &k) const noexcept;
	};

	struct CachedCell {
		std::vector<RockInstance> rocks;
		std::list<CellKey>::iterator lruIt;
	};

	static constexpr int NUM_VARIANTS = 8;
	static constexpr int MAX_VISIBLE_ROCKS = 4500;
	static constexpr size_t MAX_CACHED_CELLS = 6144;
	static constexpr double CELL_MICRO = 105.0;
	static constexpr double CELL_FINE = 210.0;
	static constexpr double CELL_COARSE = 850.0;
	static constexpr double CELL_FAR = 2100.0;

	void InitGraphics(Graphics::Renderer *r, int quality, bool enhanced);
	std::unique_ptr<Graphics::MeshObject> BuildRockMesh(Graphics::Renderer *r, uint32_t seed, int subdivs, bool withTangents) const;

	FrameId GetOrbitalFrameId() const;
	void GatherCellRocks(int64_t gx, int64_t gz, double cellSize, RockTier tier, std::vector<RockInstance> &out) const;
	const std::vector<RockInstance> &GetOrBuildCell(int64_t gx, int64_t gz, double cellSize, RockTier tier) const;
	Color ComputeRockColor(const RingBand &band, uint64_t seed) const;
	void SpawnMiningFragment(const vector3d &hitPosOrb, const vector3d &normalOrb, const RingBand &band);

	Planet *m_planet;
	double m_planetRadius;
	double m_axialTilt;
	matrix3x3d m_axialRot; // maps ringLocal -> orbFrame
	uint32_t m_baseSeed;
	double m_elapsedTime;
	int m_builtQuality = -1;
	bool m_builtEnhanced = false;

	std::unique_ptr<Graphics::Material> m_rockMaterial;
	std::unique_ptr<Graphics::Material> m_dustMaterial;
	std::unique_ptr<Graphics::MeshObject> m_rockMeshes[NUM_VARIANTS];
	Graphics::VertexArray m_dustVerts;

	// O(1) render-frame LRU cache storing un-spun base RockInstances (spin & posView computed per-frame).
	mutable std::list<CellKey> m_lruList;
	mutable std::unordered_map<CellKey, CachedCell, CellKeyHash> m_cellCache;
	std::array<std::vector<RockInstanceGPU>, NUM_VARIANTS> m_variantBuckets;

	// Remaining fractional mining yield [0.0..1.0] for rocks damaged by mining lasers.
	std::unordered_map<uint64_t, float> m_depletedYield;
};

#endif /* _RINGFIELD_H */


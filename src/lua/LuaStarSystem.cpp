// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "EnumStrings.h"
#include "FileSystem.h"
#include "Game.h"
#include "GameSaveError.h"
#include "LuaObject.h"
#include "LuaTable.h"
#include "LuaUtils.h"
#include "Pi.h"
#include "Space.h"
#include "SpaceStation.h"
#include "Star.h"
#include "galaxy/Economy.h"
#include "galaxy/Factions.h"
#include "galaxy/Galaxy.h"
#include "galaxy/GalaxyCache.h"
#include "galaxy/Sector.h"
#include "galaxy/StarSystem.h"

#include "profiler/Profiler.h"

#include <algorithm>
#include <cmath>
#include <vector>

/*
 * Class: StarSystem
 *
 * Representation of a star system.
 *
 * <StarSystem> holds properties that are used to generate a system when a
 * player enters it, as well as various non-physical attributes relating to
 * the system, eg political and economical data. It typically contains a
 * number of <SystemBody> objects. It does not have a direct relationship to
 * the physics <Body> objects in the system and as such, its possible to
 * access <StarSystem> objects for systems the player is not currently in.
 *
 * The <StarSystem> for the system the player is currently in is always
 * available via <Game.system>.
 */

/*
 * Method: GetStationPaths
 *
 * Get the <SystemPaths> to stations in this system
 *
 * > paths = system:GetStationPaths()
 *
 * Return:
 *
 *   paths - an array of <SystemPath> objects, one for each space station
 */
static int l_starsystem_get_station_paths(lua_State *l)
{
	PROFILE_SCOPED()
	LUA_DEBUG_START(l);

	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);

	lua_newtable(l);

	for (const SystemBody *station : s->GetSpaceStations()) {
		lua_pushinteger(l, lua_rawlen(l, -1) + 1);
		LuaObject<SystemPath>::PushToLua(&station->GetPath());
		lua_rawset(l, -3);
	}

	LUA_DEBUG_END(l, 1);

	return 1;
}

/*
 * Method: GetBodyPaths
 *
 * Get the <SystemPaths> to bodies (planets, stations, starports) in this system
 *
 * > paths = system:GetBodyPaths()
 *
 * Return:
 *
 *   paths - an array of <SystemPath> objects, one for each <SystemBody>
 */
static int l_starsystem_get_body_paths(lua_State *l)
{
	PROFILE_SCOPED()
	LUA_DEBUG_START(l);

	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);

	lua_newtable(l);

	for (RefCountedPtr<const SystemBody> sb : s->GetBodies()) {
		lua_pushinteger(l, lua_rawlen(l, -1) + 1);
		LuaObject<SystemPath>::PushToLua(&sb->GetPath());
		lua_rawset(l, -3);
	}

	LUA_DEBUG_END(l, 1);

	return 1;
}

static int l_starsystem_get_body_by_path(lua_State *l)
{
	PROFILE_SCOPED()

	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	const SystemPath *path = LuaObject<SystemPath>::CheckFromLua(2);
	LuaObject<SystemBody>::PushToLua(s->GetBodyByPath(*path));
	return 1;
}

/*
 * Method: GetCommodityBasePriceAlterations
 *
 * Get the price alterations for commodities bought and sold in this system
 *
 * > alteration = system:GetCommodityBasePriceAlterations(commodity)
 *
 * Parameters:
 *
 *   commodity	- The commodity name to look up. Should be a valid name returned
 *                by Economy.GetCommodities()
 * Return:
 *
 *   percentage	- percentage change to the cargo base price. Loosely,
 *                positive values make the commodity more expensive,
 *                indicating it is in demand, while negative values make the
 *                commodity cheaper, indicating a surplus.
 */
static int l_starsystem_get_commodity_base_price_alterations(lua_State *l)
{
	PROFILE_SCOPED()
	LUA_DEBUG_START(l);

	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	std::string commodityName = luaL_checkstring(l, 2);

	GalacticEconomy::CommodityId commId = GalacticEconomy::GetCommodityByName(commodityName);
	if (commId != GalacticEconomy::InvalidCommodityId) {
		lua_pushnumber(l, s->GetCommodityBasePriceModPercent(commId));
	} else {
		lua_pushnumber(l, 0);
	}

	LUA_DEBUG_END(l, 1);
	return 1;
}

/*
 * Method: IsCommodityLegal
 *
 * Determine if a given commodity is legal for trade in this system
 *
 * > is_legal = system:IsCommodityLegal(commodity)
 *
 * Parameters:
 *
 *   commodity - the wanted commodity; should be a commodity name returned by Economy.GetCommodities()
 *               (for instance, "hydrogen")
 *
 * Return:
 *
 *   is_legal  - true if the commodity is legal, otherwise false
 */
static int l_starsystem_is_commodity_legal(lua_State *l)
{
	PROFILE_SCOPED()
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	std::string commName = luaL_checkstring(l, 2);

	GalacticEconomy::CommodityId commId = GalacticEconomy::GetCommodityByName(commName);
	if (commId != GalacticEconomy::InvalidCommodityId)
		lua_pushboolean(l, s->IsCommodityLegal(commId));
	else
		lua_pushboolean(l, true);

	return 1;
}

static inline float sectorMinDistSqr(const vector3f &originFullPos, int sx, int sy, int sz)
{
	const float minX = float(sx) * Sector::SIZE;
	const float maxX = minX + Sector::SIZE;
	const float minY = float(sy) * Sector::SIZE;
	const float maxY = minY + Sector::SIZE;
	const float minZ = float(sz) * Sector::SIZE;
	const float maxZ = minZ + Sector::SIZE;

	const float dx = (originFullPos.x < minX) ? (minX - originFullPos.x) : ((originFullPos.x > maxX) ? (originFullPos.x - maxX) : 0.0f);
	const float dy = (originFullPos.y < minY) ? (minY - originFullPos.y) : ((originFullPos.y > maxY) ? (originFullPos.y - maxY) : 0.0f);
	const float dz = (originFullPos.z < minZ) ? (minZ - originFullPos.z) : ((originFullPos.z > maxZ) ? (originFullPos.z - maxZ) : 0.0f);
	return dx * dx + dy * dy + dz * dz;
}

/*
 * Method: GetNearbySystems
 *
 * Get a list of nearby <StarSystems> that match some criteria
 *
 * > systems = system:GetNearbySystems(range, filter)
 *
 * Parameters:
 *
 *   range - distance from this system to search, in light years
 *
 *   filter - an optional function. If specified the function will be called
 *            once for each candidate system with the <StarSystem> object
 *            passed as the only parameter. If the filter function returns
 *            true then the system will be included in the array returned by
 *            <GetNearbySystems>, otherwise it will be omitted. If no filter
 *            function is specified then all systems in range are returned.
 *
 * Return:
 *
 *  systems - an array of systems in range that matched the filter
 */
static int l_starsystem_get_nearby_systems(lua_State *l)
{
	PROFILE_SCOPED()
	LUA_DEBUG_START(l);

	const StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	const double dist_ly = luaL_checknumber(l, 2);

	bool filter = false;
	if (lua_gettop(l) >= 3) {
		luaL_checktype(l, 3, LUA_TFUNCTION); // any type of function
		filter = true;
	}

	lua_newtable(l);
	if (dist_ly <= 0.0) {
		LUA_DEBUG_END(l, 1);
		return 1;
	}

	const SystemPath &here = s->GetPath();
	const SystemPath hereSys = here.SystemOnly();
	const int distMilliLy = int(std::llround(dist_ly * 1000.0));

	struct NearbySysCacheKey {
		const Galaxy *galaxy;
		int seed;
		SystemPath here;
		int distMilliLy;
		bool operator==(const NearbySysCacheKey &o) const
		{
			return galaxy == o.galaxy && seed == o.seed && distMilliLy == o.distMilliLy && here == o.here;
		}
	};
	struct NearbySysCacheEntry {
		NearbySysCacheKey key;
		std::vector<SystemPath> systems;
		uint64_t lastUsed = 0;
	};
	static std::vector<NearbySysCacheEntry> s_nearbyCache;
	static uint64_t s_nearbyUseSeq = 0;
	static constexpr size_t NEARBY_CACHE_MAX = 32;

	const NearbySysCacheKey reqKey { s->m_galaxy.Get(), s->GetSeed(), hereSys, distMilliLy };
	const std::vector<SystemPath> *cachedPaths = nullptr;
	for (NearbySysCacheEntry &entry : s_nearbyCache) {
		if (entry.key == reqKey) {
			entry.lastUsed = ++s_nearbyUseSeq;
			cachedPaths = &entry.systems;
			break;
		}
	}

	if (!cachedPaths) {
		std::vector<SystemPath> discovered;
		const int here_x = here.sectorX;
		const int here_y = here.sectorY;
		const int here_z = here.sectorZ;
		const Uint32 here_idx = here.systemIndex;
		RefCountedPtr<const Sector> here_sec = s->m_galaxy->GetSector(here);
		if (here_idx >= here_sec->m_systems.size()) {
			LUA_DEBUG_END(l, 1);
			return 1;
		}

		const vector3f here_pos = here_sec->m_systems[here_idx].GetFullPosition();
		const float dist_sqr = float(dist_ly * dist_ly);
		const float sec_dist_sqr = float((dist_ly + 0.01) * (dist_ly + 0.01));

		const int diff_sec = int(ceil(dist_ly / Sector::SIZE));

		for (int x = here_x - diff_sec; x <= here_x + diff_sec; x++) {
			for (int y = here_y - diff_sec; y <= here_y + diff_sec; y++) {
				for (int z = here_z - diff_sec; z <= here_z + diff_sec; z++) {
					if (sectorMinDistSqr(here_pos, x, y, z) > sec_dist_sqr)
						continue;

					RefCountedPtr<const Sector> sec = s->m_galaxy->GetSector(SystemPath(x, y, z));

					for (unsigned int idx = 0; idx < sec->m_systems.size(); idx++) {
						if (x == here_x && y == here_y && z == here_z && idx == here_idx)
							continue;

						if (Sector::DistanceBetweenSqr(here_sec, here_idx, sec, idx) > dist_sqr)
							continue;

						discovered.emplace_back(x, y, z, idx);
					}
				}
			}
		}

		if (s_nearbyCache.size() >= NEARBY_CACHE_MAX) {
			auto victim = std::min_element(s_nearbyCache.begin(), s_nearbyCache.end(),
				[](const NearbySysCacheEntry &a, const NearbySysCacheEntry &b) {
					return a.lastUsed < b.lastUsed;
				});
			*victim = NearbySysCacheEntry { reqKey, std::move(discovered), ++s_nearbyUseSeq };
			cachedPaths = &victim->systems;
		} else {
			s_nearbyCache.push_back(NearbySysCacheEntry { reqKey, std::move(discovered), ++s_nearbyUseSeq });
			cachedPaths = &s_nearbyCache.back().systems;
		}
	}

	uint32_t numSystems = 0;
	for (const SystemPath &sysPath : *cachedPaths) {
		RefCountedPtr<StarSystem> sys = s->m_galaxy->GetStarSystem(sysPath);
		if (filter) {
			lua_pushvalue(l, 3);
			LuaObject<StarSystem>::PushToLua(sys.Get());
			lua_call(l, 1, 1);
			if (!lua_toboolean(l, -1)) {
				lua_pop(l, 1);
				continue;
			}
			lua_pop(l, 1);
		}

		lua_pushinteger(l, ++numSystems);
		LuaObject<StarSystem>::PushToLua(sys.Get());
		lua_rawset(l, -3);
	}

	LUA_DEBUG_END(l, 1);

	return 1;
}

/*
 * Method: GetNearbySystemPaths
 *
 * Get sorted <SystemPath> entries and distances for nearby systems without
 * generating full <StarSystem> objects.
 *
 * > paths, dists = system:GetNearbySystemPaths(range [, inhabitableOnly [, maxResults]])
 */
static int l_starsystem_get_nearby_system_paths(lua_State *l)
{
	PROFILE_SCOPED()
	LUA_DEBUG_START(l);

	const StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	double dist_ly = luaL_checknumber(l, 2);
	dist_ly = std::min(dist_ly, 120.0);

	const bool inhabitableOnly = (lua_gettop(l) >= 3) ? (lua_toboolean(l, 3) != 0) : false;
	const lua_Integer maxResultsRaw = luaL_optinteger(l, 4, 0);
	const size_t maxResults = (maxResultsRaw > 0) ? size_t(maxResultsRaw) : 0;

	if (dist_ly <= 0.0) {
		lua_newtable(l);
		lua_newtable(l);
		LUA_DEBUG_END(l, 2);
		return 2;
	}

	const SystemPath &here = s->GetPath();
	const int here_x = here.sectorX;
	const int here_y = here.sectorY;
	const int here_z = here.sectorZ;
	const Uint32 here_idx = here.systemIndex;
	RefCountedPtr<const Sector> here_sec = s->m_galaxy->GetSector(here);
	if (here_idx >= here_sec->m_systems.size()) {
		lua_newtable(l);
		lua_newtable(l);
		LUA_DEBUG_END(l, 2);
		return 2;
	}

	const vector3f here_pos = here_sec->m_systems[here_idx].GetFullPosition();
	const float dist_sqr = float(dist_ly * dist_ly);
	const float sec_dist_sqr = float((dist_ly + 0.01) * (dist_ly + 0.01));
	const int diff_sec = int(ceil(dist_ly / Sector::SIZE));

	struct NearbyPathEntry {
		SystemPath path;
		float distSqr;
	};
	std::vector<NearbyPathEntry> entries;
	entries.reserve(maxResults > 0 ? std::min<size_t>(maxResults * 2, 512) : 128);

	for (int x = here_x - diff_sec; x <= here_x + diff_sec; x++) {
		for (int y = here_y - diff_sec; y <= here_y + diff_sec; y++) {
			for (int z = here_z - diff_sec; z <= here_z + diff_sec; z++) {
				if (sectorMinDistSqr(here_pos, x, y, z) > sec_dist_sqr)
					continue;

				RefCountedPtr<const Sector> sec = s->m_galaxy->GetSector(SystemPath(x, y, z));
				for (unsigned int idx = 0; idx < sec->m_systems.size(); idx++) {
					if (x == here_x && y == here_y && z == here_z && idx == here_idx)
						continue;

					const Sector::System &secSys = sec->m_systems[idx];
					if (inhabitableOnly && secSys.GetExplored() != StarSystem::eEXPLORED_AT_START && secSys.GetCustomSystem() == nullptr)
						continue;

					const float dSqr = Sector::DistanceBetweenSqr(here_sec, here_idx, sec, idx);
					if (dSqr > dist_sqr)
						continue;

					entries.push_back({ secSys.GetPath(), dSqr });
				}
			}
		}
	}

	if (maxResults > 0 && entries.size() > maxResults) {
		std::partial_sort(entries.begin(), entries.begin() + maxResults, entries.end(),
			[](const NearbyPathEntry &a, const NearbyPathEntry &b) { return a.distSqr < b.distSqr; });
		entries.resize(maxResults);
	} else {
		std::sort(entries.begin(), entries.end(),
			[](const NearbyPathEntry &a, const NearbyPathEntry &b) { return a.distSqr < b.distSqr; });
	}

	lua_createtable(l, int(entries.size()), 0);
	lua_createtable(l, int(entries.size()), 0);
	for (size_t i = 0; i < entries.size(); ++i) {
		const lua_Integer luaIdx = lua_Integer(i + 1);
		SystemPath p = entries[i].path;
		lua_pushinteger(l, luaIdx);
		LuaObject<SystemPath>::PushToLua(&p);
		lua_rawset(l, -4);

		lua_pushinteger(l, luaIdx);
		lua_pushnumber(l, std::sqrt(double(entries[i].distSqr)));
		lua_rawset(l, -3);
	}

	LUA_DEBUG_END(l, 2);
	return 2;
}

/*
 * Method: FindJumpRoute
 *
 * Compute a greedy corridor-bounded multi-hop jump route using Sector data only.
 *
 * > hops, hopDists = system:FindJumpRoute(dest, maxJumpRangeLy)
 */
static int l_starsystem_find_jump_route(lua_State *l)
{
	PROFILE_SCOPED()
	LUA_DEBUG_START(l);

	const StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	const SystemPath srcPath = s->GetPath();

	const SystemPath *dstPtr = LuaObject<SystemPath>::GetFromLua(2);
	if (!dstPtr) {
		StarSystem *s2 = LuaObject<StarSystem>::CheckFromLua(2);
		dstPtr = &(s2->GetPath());
	}

	if (!srcPath.HasValidSystem() || !dstPtr->HasValidSystem()) {
		return luaL_error(l, "StarSystem:FindJumpRoute() requires valid system paths");
	}

	const SystemPath srcSys = srcPath.SystemOnly();
	const SystemPath dstSys = dstPtr->SystemOnly();
	if (srcSys.IsSameSystem(dstSys)) {
		lua_newtable(l);
		lua_newtable(l);
		LUA_DEBUG_END(l, 2);
		return 2;
	}

	const double effRange = std::max(1.5, luaL_optnumber(l, 3, 8.0));
	RefCountedPtr<const Sector> srcSec = s->m_galaxy->GetSector(srcSys);
	RefCountedPtr<const Sector> dstSec = s->m_galaxy->GetSector(dstSys);
	if (srcSys.systemIndex >= srcSec->m_systems.size() || dstSys.systemIndex >= dstSec->m_systems.size()) {
		lua_newtable(l);
		lua_newtable(l);
		LUA_DEBUG_END(l, 2);
		return 2;
	}

	const float directDist = Sector::DistanceBetween(srcSec, srcSys.systemIndex, dstSec, dstSys.systemIndex);
	std::vector<SystemPath> hops;
	std::vector<float> hopDists;

	if (double(directDist) <= effRange) {
		hops.push_back(dstSys);
		hopDists.push_back(directDist);
	} else {
		std::vector<SystemPath> visited;
		visited.push_back(srcSys);
		auto isVisited = [&visited](const SystemPath &p) {
			for (const SystemPath &v : visited) {
				if (v.IsSameSystem(p)) return true;
			}
			return false;
		};

		SystemPath curSys = srcSys;
		RefCountedPtr<const Sector> curSec = srcSec;
		Uint32 curIdx = srcSys.systemIndex;
		vector3f curPos = curSec->m_systems[curIdx].GetFullPosition();
		const vector3f dstPos = dstSec->m_systems[dstSys.systemIndex].GetFullPosition();
		const float effRangeF = float(effRange);
		const float effRangeSqr = effRangeF * effRangeF;

		for (int step = 0; step < 16; ++step) {
			const vector3f vec = dstPos - curPos;
			const float dToDest = vec.Length();
			if (dToDest <= effRangeF) {
				hops.push_back(dstSys);
				hopDists.push_back(dToDest);
				break;
			}

			const vector3f dir = (dToDest > 1e-6f) ? (vec / dToDest) : vector3f(1.0f, 0.0f, 0.0f);
			const float curRemSqr = dToDest * dToDest;

			bool found = false;
			SystemPath bestNext;
			RefCountedPtr<const Sector> bestSec;
			Uint32 bestIdx = 0;
			vector3f bestPos;
			float bestRemSqr = curRemSqr;
			float bestHopDist = 0.0f;

			auto searchAround = [&](const vector3f &center, float radius) {
				const int minSX = int(floor((center.x - radius) / Sector::SIZE));
				const int maxSX = int(floor((center.x + radius) / Sector::SIZE));
				const int minSY = int(floor((center.y - radius) / Sector::SIZE));
				const int maxSY = int(floor((center.y + radius) / Sector::SIZE));
				const int minSZ = int(floor((center.z - radius) / Sector::SIZE));
				const int maxSZ = int(floor((center.z + radius) / Sector::SIZE));
				const float secRadSqr = (radius + 0.01f) * (radius + 0.01f);

				for (int x = minSX; x <= maxSX; ++x) {
					for (int y = minSY; y <= maxSY; ++y) {
						for (int z = minSZ; z <= maxSZ; ++z) {
							if (sectorMinDistSqr(center, x, y, z) > secRadSqr)
								continue;
							RefCountedPtr<const Sector> sec = s->m_galaxy->GetSector(SystemPath(x, y, z));
							for (unsigned int idx = 0; idx < sec->m_systems.size(); ++idx) {
								const SystemPath candPath(x, y, z, idx);
								if (isVisited(candPath))
									continue;
								const float hopDistSqr = Sector::DistanceBetweenSqr(curSec, curIdx, sec, idx);
								if (hopDistSqr > effRangeSqr)
									continue;
								const vector3f candPos = sec->m_systems[idx].GetFullPosition();
								const float remSqr = (candPos - dstPos).LengthSqr();
								if (remSqr < bestRemSqr) {
									found = true;
									bestRemSqr = remSqr;
									bestNext = candPath;
									bestSec = sec;
									bestIdx = idx;
									bestPos = candPos;
									bestHopDist = std::sqrt(hopDistSqr);
								}
							}
						}
					}
				}
			};

			const vector3f idealPos = curPos + dir * (effRangeF * 0.90f);
			searchAround(idealPos, 16.0f);
			if (!found) {
				searchAround(idealPos, 28.0f);
			}
			if (!found && effRangeF > 32.0f) {
				const vector3f midPos = curPos + dir * (effRangeF * 0.50f);
				searchAround(midPos, 24.0f);
			}
			if (!found && effRangeF <= 32.0f) {
				searchAround(curPos, effRangeF);
			}

			if (!found)
				break;

			visited.push_back(bestNext);
			hops.push_back(bestNext);
			hopDists.push_back(bestHopDist);
			curSys = bestNext;
			curSec = bestSec;
			curIdx = bestIdx;
			curPos = bestPos;
		}

		if (hops.empty()) {
			hops.push_back(dstSys);
			hopDists.push_back(directDist);
		} else if (!hops.back().IsSameSystem(dstSys)) {
			hops.push_back(dstSys);
			hopDists.push_back(Sector::DistanceBetween(curSec, curIdx, dstSec, dstSys.systemIndex));
		}
	}

	lua_createtable(l, int(hops.size()), 0);
	lua_createtable(l, int(hopDists.size()), 0);
	for (size_t i = 0; i < hops.size(); ++i) {
		const lua_Integer luaIdx = lua_Integer(i + 1);
		SystemPath p = hops[i];
		lua_pushinteger(l, luaIdx);
		LuaObject<SystemPath>::PushToLua(&p);
		lua_rawset(l, -4);

		lua_pushinteger(l, luaIdx);
		lua_pushnumber(l, double(hopDists[i]));
		lua_rawset(l, -3);
	}

	LUA_DEBUG_END(l, 2);
	return 2;
}

static int l_starsystem_get_stars(lua_State *l)
{
	const StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	lua_newtable(l);
	int i = 1;
	for (SystemBody *star : s->GetStars()) {
		lua_pushnumber(l, i++);
		LuaObject<SystemBody>::PushToLua(star);
		lua_settable(l, -3);
	}
	return 1;
}

static int l_starsystem_get_jumpable(lua_State *l)
{
	const StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	lua_newtable(l);
	int i = 1;
	for (RefCountedPtr<SystemBody> sb : s->GetBodies())
		if (sb->IsJumpable()) {
			lua_pushnumber(l, i++);
			LuaObject<SystemBody>::PushToLua(sb.Get());
			lua_settable(l, -3);
		}
	return 1;
}

/*
 * Method: DistanceTo
 *
 * Calculate the distance between this and another system
 *
 * > dist = system:DistanceTo(system)
 *
 * Parameters:
 *
 *   system - a <SystemPath> or <StarSystem> to calculate the distance to
 *
 * Return:
 *
 *   dist - the distance, in light years
 */
static int l_starsystem_distance_to(lua_State *l)
{
	PROFILE_SCOPED()
	LUA_DEBUG_START(l);

	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	const SystemPath *loc1 = &(s->GetPath());

	const SystemPath *loc2 = LuaObject<SystemPath>::GetFromLua(2);
	if (!loc2) {
		StarSystem *s2 = LuaObject<StarSystem>::CheckFromLua(2);
		loc2 = &(s2->GetPath());
	}

	RefCountedPtr<const Sector> sec1 = s->m_galaxy->GetSector(*loc1);
	RefCountedPtr<const Sector> sec2 = s->m_galaxy->GetSector(*loc2);

	// this only works if the SystemPath is valid
	if (loc1->HasValidSystem() && loc2->HasValidSystem()) {
		double dist = Sector::DistanceBetween(sec1, loc1->systemIndex, sec2, loc2->systemIndex);
		lua_pushnumber(l, dist);
	} else {
		lua_pushnumber(l, FLT_MAX);
		return luaL_error(l, "Cannot compare non-systemPaths");
	}

	LUA_DEBUG_END(l, 1);
	return 1;
}

/*
 * Method: ExportToLua
 *
 * Export of generated system for personal interest, customisation, etc
 */
static int l_starsystem_export_to_lua(lua_State *l)
{
	PROFILE_SCOPED()
	LUA_DEBUG_START(l);

	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);

	static const std::string EXPORTED_SYSTEMS_DIR_NAME("exported_systems");
	if (!FileSystem::userFiles.MakeDirectory(EXPORTED_SYSTEMS_DIR_NAME)) {
		throw CouldNotOpenFileException();
	}

	// construct the filename with folder and extension
	try {
		const std::string filename(EXPORTED_SYSTEMS_DIR_NAME + "/" + FileSystem::SanitiseFileName(s->GetName()) + ".lua");
		const std::string finalPath = FileSystem::NormalisePath(
			FileSystem::JoinPathBelow(FileSystem::GetUserDir(), filename));
		s->ExportToLua(finalPath.c_str());
	} catch (std::invalid_argument &) {
		return luaL_error(l, "could not export system -- name forms an invalid path");
	}

	LUA_DEBUG_END(l, 0);
	return 0;
}

/*
 * Method: Explore
 *
 * Set the star system to be explored by the Player.
 *
 * > system:Explore(time)
 *
 * Parameters:
 *
 *   time - optional, the game time at which the system was explored.
 *          Defaults to current game time.
 */
static int l_starsystem_explore(lua_State *l)
{
	LUA_DEBUG_START(l);

	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	double time;
	if (lua_isnumber(l, 2))
		time = luaL_checknumber(l, 2);
	else
		time = Pi::game->GetTime();

	s->ExploreSystem(time);

	LUA_DEBUG_END(l, 0);
	return 0;
}

/*
 * Attribute: name
 *
 * The name of the system. This is usually the same as the name of the primary
 * star.
 */
static int l_starsystem_attr_name(lua_State *l)
{
	PROFILE_SCOPED()
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	lua_pushstring(l, s->GetName().c_str());
	return 1;
}

static int l_starsystem_attr_other_names(lua_State *l)
{
	PROFILE_SCOPED();
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	LuaTable names(l);
	int i = 1;
	for (const std::string &n : s->GetOtherNames()) {
		LuaPush(l, i++);
		LuaPush(l, n);
		lua_settable(l, -3);
	}
	return 1;
}

/*
 * Attribute: path
 *
 * The <SystemPath> to the system
 */
static int l_starsystem_attr_path(lua_State *l)
{
	PROFILE_SCOPED()
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	SystemPath path = s->GetPath();
	LuaObject<SystemPath>::PushToLua(&path);
	return 1;
}

/*
 * Attribute: seed
 *
 * The integer seed of the system
 *
 */
static int l_starsystem_attr_seed(lua_State *l)
{
	PROFILE_SCOPED()
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	LuaPush(l, s->GetSeed());
	return 1;
}

/*
 * Attribute: lawlessness
 *
 * The lawlessness value for the system, 0 for peaceful, 1 for raging
 * hordes of pirates
 */
static int l_starsystem_attr_lawlessness(lua_State *l)
{
	PROFILE_SCOPED()
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	lua_pushnumber(l, s->GetSysPolit().lawlessness.ToDouble());
	return 1;
}

/*
 * Attribute: population
 *
 * The population of this system, in billions of people
 */
static int l_starsystem_attr_population(lua_State *l)
{
	PROFILE_SCOPED()
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	lua_pushnumber(l, s->GetTotalPop().ToDouble());
	return 1;
}

/*
 * Attribute: faction
 *
 * The <Faction> that controls this system
 */
static int l_starsystem_attr_faction(lua_State *l)
{
	PROFILE_SCOPED()
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	if (s->GetFaction()->IsValid()) {
		LuaObject<Faction>::PushToLua(const_cast<Faction *>(s->GetFaction())); // XXX const-correctness violation
		return 1;
	} else {
		return 0;
	}
}

static int l_starsystem_attr_number_of_stars(lua_State *l)
{
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	LuaPush(l, s->GetNumStars());
	return 1;
}

static int l_starsystem_attr_number_of_stations(lua_State *l)
{
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	LuaPush(l, s->GetNumSpaceStations());
	return 1;
}

static int l_starsystem_attr_number_of_bodies(lua_State *l)
{
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	LuaPush(l, s->GetNumBodies());
	return 1;
}

static int l_starsystem_attr_root_system_body(lua_State *l)
{
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	SystemBody *body = s->GetBodyByPath(s->GetRootBody()->GetPath());
	LuaObject<SystemBody>::PushToLua(body);
	return 1;
}

static int l_starsystem_attr_short_description(lua_State *l)
{
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	LuaPush(l, s->GetShortDescription());
	return 1;
}

static int l_starsystem_attr_long_description(lua_State *l)
{
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	LuaPush(l, s->GetLongDescription());
	return 1;
}

/*
* Attribute: govDescription
*
* The translated description of the system's government type.
*/
static int l_starsystem_attr_gov_description(lua_State *l)
{
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	LuaPush(l, s->GetSysPolit().GetGovernmentDesc());
	return 1;
}

/*
* Attribute: econDescription
*
* The translated description of the system's economy type.
*/
static int l_starsystem_attr_econ_description(lua_State *l)
{
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	LuaPush(l, s->GetSysPolit().GetEconomicDesc());
	return 1;
}

/*
* Attribute: govtype
*
* The government type used in the system
* (PolitGovType string constant, EARTHCOLONIAL, EARTHDEMOC, EMPIRERULE, etc.
*/
static int l_starsystem_attr_govtype(lua_State *l)
{
	PROFILE_SCOPED()
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	lua_pushstring(l, EnumStrings::GetString("PolitGovType", s->GetSysPolit().govType));
	return 1;
}

/*
 * Attribute: explored
 *
 *   If this system has been explored then returns true
 */

static int l_starsystem_attr_explored(lua_State *l)
{
	PROFILE_SCOPED()
	StarSystem *s = LuaObject<StarSystem>::CheckFromLua(1);
	lua_pushboolean(l, !s->GetUnexplored());
	return 1;
}

template <>
const char *LuaObject<StarSystem>::s_type = "StarSystem";

template <>
void LuaObject<StarSystem>::RegisterClass()
{
	static const luaL_Reg l_methods[] = {
		{ "GetStationPaths", l_starsystem_get_station_paths },
		{ "GetBodyPaths", l_starsystem_get_body_paths },
		{ "GetBodyByPath", l_starsystem_get_body_by_path },
		{ "GetStars", l_starsystem_get_stars },
		{ "GetJumpable", l_starsystem_get_jumpable },

		{ "GetCommodityBasePriceAlterations", l_starsystem_get_commodity_base_price_alterations },
		{ "IsCommodityLegal", l_starsystem_is_commodity_legal },

		{ "GetNearbySystems", l_starsystem_get_nearby_systems },
		{ "GetNearbySystemPaths", l_starsystem_get_nearby_system_paths },
		{ "FindJumpRoute", l_starsystem_find_jump_route },

		{ "DistanceTo", l_starsystem_distance_to },

		{ "ExportToLua", l_starsystem_export_to_lua },

		{ "Explore", l_starsystem_explore },

		{ 0, 0 }
	};

	static const luaL_Reg l_attrs[] = {
		{ "name", l_starsystem_attr_name },
		{ "other_names", l_starsystem_attr_other_names },
		{ "path", l_starsystem_attr_path },
		{ "seed", l_starsystem_attr_seed },

		{ "lawlessness", l_starsystem_attr_lawlessness },
		{ "population", l_starsystem_attr_population },
		{ "faction", l_starsystem_attr_faction },
		{ "govtype", l_starsystem_attr_govtype },
		{ "explored", l_starsystem_attr_explored },
		{ "numberOfStars", l_starsystem_attr_number_of_stars },
		{ "numberOfStations", l_starsystem_attr_number_of_stations },
		{ "numberOfBodies", l_starsystem_attr_number_of_bodies },
		{ "rootSystemBody", l_starsystem_attr_root_system_body },
		{ "shortDescription", l_starsystem_attr_short_description },
		{ "longDescription", l_starsystem_attr_long_description },
		{ "govDescription", l_starsystem_attr_gov_description },
		{ "econDescription", l_starsystem_attr_econ_description },
		{ 0, 0 }
	};

	LuaObjectBase::CreateClass(s_type, 0, l_methods, l_attrs, 0);
}

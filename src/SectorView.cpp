// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "SectorView.h"

#include "AnimationCurves.h"
#include "Game.h"
#include "GameSaveError.h"
#include "Input.h"
#include "Json.h"
#include "JsonUtils.h"
#include "MathUtil.h"
#include "Pi.h"
#include "Player.h"
#include "ShipType.h"
#include "RefCounted.h"
#include "SectorMap.h"
#include "SectorMapContext.h"
#include "Space.h"
#include "core/Log.h"
#include "galaxy/Galaxy.h"
#include "galaxy/Sector.h"
#include "galaxy/StarSystem.h"
#include "galaxy/Factions.h"
#include "imgui/imgui.h"
#include "lua/LuaObject.h"
#include "lua/LuaRef.h"
#include "lua/LuaTable.h"
#include "matrix4x4.h"

#include "profiler/Profiler.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <queue>
#include <unordered_map>
#include <unordered_set>

SectorView::~SectorView() {}

using namespace Graphics;

enum DetailSelection {
	DETAILBOX_NONE = 0,
	DETAILBOX_INFO = 1,
	DETAILBOX_FACTION = 2
};

REGISTER_INPUT_BINDING(SectorView)
{
	using namespace InputBindings;
	auto *mapView = input->GetBindingPage("MapControls");
	Input::BindingGroup *group;

#define BINDING_GROUP(n) group = mapView->GetBindingGroup(#n);
#define KEY_BINDING(name, k1, k2) \
	input->AddActionBinding(name, group, InputBindings::Action({ k1 }, { k2 }));
#define AXIS_BINDING(name, k1, k2) \
	input->AddAxisBinding(name, group, InputBindings::Axis({}, { k1 }, { k2 }));

	BINDING_GROUP(SectorMapViewControls)
	KEY_BINDING("BindMapToggleSelectionFollowView", SDLK_RETURN, SDLK_KP_ENTER)
	KEY_BINDING("BindMapWarpToCurrentSystem", SDLK_c, 0)
	KEY_BINDING("BindMapWarpToSelectedSystem", SDLK_g, 0)

#undef KEY_BINDING
#undef AXIS_BINDING
#undef BINDING_GROUP
}

void SectorView::InputBinding::RegisterBindings()
{
	mapViewReset = AddAction("BindResetOrientationAndZoom");
	mapToggleSelectionFollowView = AddAction("BindMapToggleSelectionFollowView");
	mapWarpToCurrent = AddAction("BindMapWarpToCurrentSystem");
	mapWarpToSelected = AddAction("BindMapWarpToSelectedSystem");
}

// callbacks for the SectorMap
class SectorView::SectorMapCallbacks : public SectorMapContext::Callbacks {
	SectorView &sv;

public:
	SectorMapCallbacks(SectorView &sv) :
		sv(sv) {}

	void OnClickLabel(const SystemPath &clickedLabel) override
	{
		sv.SwitchToPath(clickedLabel);
	}

	SectorMapContext::DisplayMode GetDisplayMode(const SystemPath &system) override
	{
		if (system.IsSameSystem(sv.m_selected)) return DisplayModes::ALWAYS;
		if (system.IsSameSystem(sv.m_current)) return DisplayModes::ALWAYS;
		// always show systems that are in route
		if (std::find_if(sv.m_route.begin(), sv.m_route.end(), [system](const SystemPath &a) { return system.IsSameSystem(a); }) != sv.m_route.end())
			return DisplayModes::ALWAYS;

		// hide labels outside of hyperjump range if option is set
		RefCountedPtr<const Sector> sec1 = sv.m_game.GetGalaxy()->GetSector(system);
		RefCountedPtr<const Sector> sec2 = sv.m_game.GetGalaxy()->GetSector(sv.m_current);
		float dist = Sector::DistanceBetween(sec1, system.systemIndex, sec2, sv.m_current.systemIndex);

		if (dist > sv.m_playerHyperspaceRange) {
			if (sv.m_drawOutRangeLabels) {
				return DisplayModes::SHADOW_LABEL;
			} else {
				return DisplayModes::HIDE_LABEL;
			}
		}
		return DisplayModes::DEFAULT;
	}
};

SectorMapContext SectorView::CreateMapContext()
{
	SectorMapContext context;
	context.galaxy = m_game.GetGalaxy();
	context.input = Pi::input;
	context.config = Pi::config;
	context.renderer = Pi::renderer;
	context.callbacks = std::make_unique<SectorView::SectorMapCallbacks>(*this);
	context.pigui = Pi::pigui;
	return context;
}

SectorView::SectorView(Game *game) :
	View("SectorView"),
	InputBindings(Pi::input),
	m_game(*game),
	m_map(new SectorMap(CreateMapContext()))
{
	InitDefaults();

	m_inSystem = true;

	RefCountedPtr<StarSystem> system = game->GetSpace()->GetStarSystem();
	m_current = system->GetPath();
	assert(!m_current.IsSectorPath());
	m_current = m_current.SystemOnly();
	m_selected = m_hyperspaceTarget = system->GetStars()[0]->GetPath();

	m_map->GotoSystem(m_current);

	m_automaticSystemSelection = true;
	m_detailBoxVisible = DETAILBOX_INFO;

	InitObject();
}

SectorView::SectorView(const Json &jsonObj, Game *game) :
	View("SectorView"),
	InputBindings(Pi::input),
	m_game(*game)
{
	InitDefaults();

	try {
		Json sectorViewObj = jsonObj["sector_view"];

		m_inSystem = sectorViewObj["in_system"];
		m_current = SystemPath::FromJson(sectorViewObj["current"]);
		m_selected = SystemPath::FromJson(sectorViewObj["selected"]);
		m_hyperspaceTarget = SystemPath::FromJson(sectorViewObj["hyperspace"]);
		m_automaticSystemSelection = sectorViewObj["automatic_system_selection"];
		m_map.reset(new SectorMap(sectorViewObj["map"], CreateMapContext()));
	} catch (Json::type_error &) {
		throw SavedGameCorruptException();
	}

	InitObject();
}

void SectorView::InitDefaults()
{
	InputBindings.RegisterBindings();
	m_drawRouteLines = true; // where should this go?!
	m_setupLines = true;
	m_route = std::vector<SystemPath>();
}

void SectorView::SetDrawRouteLines(bool value)
{
	m_drawRouteLines = value;
	m_setupLines = true;
}

void SectorView::InitObject()
{
	// single keystroke handlers
	m_onToggleSelectionFollowView =
		InputBindings.mapToggleSelectionFollowView->onPressed.connect([&]() {
			m_automaticSystemSelection = !m_automaticSystemSelection;
		});
	m_onWarpToCurrent =
		InputBindings.mapWarpToCurrent->onPressed.connect([&]() {
			m_map->GotoSystem(m_current);
		});
	m_onWarpToSelected =
		InputBindings.mapWarpToSelected->onPressed.connect([&]() {
			m_map->GotoSystem(m_selected);
		});
	m_onViewReset =
		InputBindings.mapViewReset->onPressed.connect([&]() {
			m_map->ResetView();
		});
}

void SectorView::SaveToJson(Json &jsonObj)
{
	Json sectorViewObj({}); // Create JSON object to contain sector view data.

	sectorViewObj["in_system"] = m_inSystem;

	Json currentSystemObj({}); // Create JSON object to contain current system data.
	m_current.ToJson(currentSystemObj);
	sectorViewObj["current"] = currentSystemObj; // Add current system object to sector view object.

	Json selectedSystemObj({}); // Create JSON object to contain selected system data.
	m_selected.ToJson(selectedSystemObj);
	sectorViewObj["selected"] = selectedSystemObj; // Add selected system object to sector view object.

	Json hyperspaceSystemObj({}); // Create JSON object to contain hyperspace system data.
	m_hyperspaceTarget.ToJson(hyperspaceSystemObj);
	sectorViewObj["hyperspace"] = hyperspaceSystemObj; // Add hyperspace system object to sector view object.
	sectorViewObj["automatic_system_selection"] = m_automaticSystemSelection;

	Json sectorMapObj{};
	m_map->SaveToJson(sectorMapObj);
	sectorViewObj["map"] = sectorMapObj;

	jsonObj["sector_view"] = sectorViewObj; // Add sector view object to supplied object.
}

void SectorView::Draw3D()
{
	PROFILE_SCOPED()

	matrix4x4f modelview = m_map->PointOfView();
	modelview.Translate(-m_map->GetPosition() * Sector::SIZE);

	// calculate the player's location (it will be interpolated between systems during a hyperjump)
	vector3f playerPos;
	float currentStarSize;
	GetPlayerPosAndStarSize(playerPos, currentStarSize);

	const vector3f selectedPos = m_map->GetSystemPosition(m_selected);
	m_map->SetMacroMarkers(playerPos, selectedPos, true);

	if (m_map->GetMacroAlpha() < 0.85f) {
		// player location indicator
		matrix4x4f trans = modelview * matrix4x4f::Translation(playerPos);
		// prior to modelview transformation, rotate in the opposite direction so
		// that the billboard is always facing the camera
		matrix4x4f rot = modelview;
		rot.ClearToRotOnly();
		rot = rot.Inverse();
		// move this disk 0.03 light years further so that it does not overlap the star, and selected indicator and hyperspace target indicator
		m_map->AddStarBillboard(trans * rot, vector3f(0.f, 0.f, -0.03f), Color(0, 0, 204), 1.5f);

		// selected indicator
		trans = modelview * matrix4x4f::Translation(selectedPos);
		// move this disk 0.01 light years further so that it does not overlap the star
		m_map->AddStarBillboard(trans * rot, vector3f(0.f, 0.f, -0.01), Color(0, 204, 0), 1.0);

		// hyperspace target indicator
		if (m_hyperspaceTarget != m_selected && (!m_inSystem || m_hyperspaceTarget != m_current)) {
			trans = modelview * matrix4x4f::Translation(m_map->GetSystemPosition(m_hyperspaceTarget));
			// move this disk 0.02 light years further so that it does not overlap the star, and selected indicator
			m_map->AddStarBillboard(trans * rot, vector3f(0.f, 0.f, -0.02), Color(77, 77, 77), 1.0);
		}
	}

	// all the lines
	if (m_setupLines) {
		SetupLines(playerPos, modelview);
	}

	// hyperspace range sphere
	if (m_playerHyperspaceRange > 0.0f) {
		const matrix4x4f sphTrans = modelview * matrix4x4f::Translation(playerPos);
		m_map->AddSphere(sphTrans * matrix4x4f::ScaleMatrix(m_playerHyperspaceRange));
	}

	// actually rendering
	m_map->Draw3D();
}

void SectorView::DrawUIContents()
{
	m_map->DrawLabels(ImGui::IsWindowHovered());
}

void SectorView::SetHyperspaceTarget(const SystemPath &path)
{
	if (m_hyperspaceTarget != path) {
		m_hyperspaceTarget = path;
		onHyperspaceTargetChanged.emit();
	}
}

void SectorView::ResetHyperspaceTarget()
{
	SystemPath old = m_hyperspaceTarget;
	m_hyperspaceTarget = m_game.GetSpace()->GetStarSystem()->GetStars()[0]->GetPath();

	if (!old.IsSameSystem(m_hyperspaceTarget)) {
		onHyperspaceTargetChanged.emit();
	}
}

void SectorView::SetSelectedPath(const SystemPath &path)
{
	if (path.IsBodyPath())
		m_selected = path;
	else if (path.IsSystemPath()) {
		RefCountedPtr<StarSystem> system = m_game.GetGalaxy()->GetStarSystem(path);
		m_selected = CheckPathInRoute(system->GetStars()[0]->GetPath());
	}
	m_setupLines = true;
}

void SectorView::SwitchToPath(const SystemPath &path)
{
	SetSelectedPath(path);
	if (m_automaticSystemSelection)
		m_map->GotoSystem(path);
}

// check the route, maybe this system is there, then we'll take the path from the route
const SystemPath &SectorView::CheckPathInRoute(const SystemPath &path)
{
	for (const auto &p : m_route)
		if (p.IsSameSystem(path))
			return p;
	return path;
}

bool SectorView::MoveRouteItemUp(const std::vector<SystemPath>::size_type element)
{
	if (element == 0 || element >= m_route.size()) return false;

	std::swap(m_route[element - 1], m_route[element]);

	m_setupLines = true;
	return true;
}

bool SectorView::MoveRouteItemDown(const std::vector<SystemPath>::size_type element)
{
	if (element >= m_route.size() - 1) return false;

	std::swap(m_route[element + 1], m_route[element]);

	m_setupLines = true;
	return true;
}

void SectorView::UpdateRouteItem(const std::vector<SystemPath>::size_type element, const SystemPath &path)
{
	m_route[element] = path;
	m_setupLines = true;
}

void SectorView::AddToRoute(const SystemPath &path)
{
	m_route.push_back(path);
	m_setupLines = true;
}

bool SectorView::RemoveRouteItem(const std::vector<SystemPath>::size_type element)
{
	if (element < m_route.size()) {
		m_route.erase(m_route.begin() + element);
		m_setupLines = true;
		return true;
	} else {
		return false;
	}
}

void SectorView::ClearRoute()
{
	m_route.clear();
	m_setupLines = true;
}

const std::vector<SystemPath> &SectorView::GetRoute() const
{
	return m_route;
}

struct SectorView::AutoRouteState {
	enum class Status {
		RUNNING,
		FINISHED_OKAY,
		FINISHED_NO_DRIVE,
		FINISHED_NO_VALID_ROUTE
	};

	struct RouteCost {
		uint32_t jumps = UINT32_MAX;
		float duration = INFINITY;
		float fuel_remaining = 0.0f;

		bool operator<(const RouteCost &other) const
		{
			if (jumps != other.jumps)
				return jumps < other.jumps;
			if (duration != other.duration)
				return duration < other.duration;
			return fuel_remaining > other.fuel_remaining;
		}

		bool operator!=(const RouteCost &other) const
		{
			return jumps != other.jumps || duration != other.duration || fuel_remaining != other.fuel_remaining;
		}
	};

	struct PQNode {
		uint32_t f_jumps;
		RouteCost cost;
		size_t nodeIdx;

		// Min-heap comparator (priority_queue pops the "largest", so invert <)
		bool operator>(const PQNode &other) const
		{
			if (f_jumps != other.f_jumps)
				return f_jumps > other.f_jumps;
			return other.cost < cost;
		}
	};

	struct SectorKey {
		Sint32 x, y, z;
		bool operator==(const SectorKey &o) const { return x == o.x && y == o.y && z == o.z; }
	};

	struct SectorKeyHash {
		size_t operator()(const SectorKey &k) const noexcept
		{
			size_t h1 = std::hash<Sint32>{}(k.x);
			size_t h2 = std::hash<Sint32>{}(k.y);
			size_t h3 = std::hash<Sint32>{}(k.z);
			return h1 ^ (h2 * 2654435761u) ^ (h3 * 2246822519u);
		}
	};

	Status status = Status::RUNNING;
	SystemPath start;
	SystemPath target;
	float maxJumpDist = 0.0f;
	bool findFuelStar = false;
	float maxLawlessness = 1.0f;
	std::string factionFilter;

	LuaRef hyperdrive;
	float max_range = 0.0f;
	float max_range_sqr = 0.0f;
	float initial_total_fuel = 0.0f;
	float max_total_fuel_capacity = 0.0f;
	float distSqr = 0.0f;
	float max_dist_from_straight_line = 0.0f;
	int sectorRadius = 1;

	RefCountedPtr<const Sector> start_sec;
	RefCountedPtr<const Sector> target_sec;
	vector3f start_pos;
	vector3f target_pos;

	uint32_t currentHops = 0;
	std::vector<SystemPath> nodes;
	std::vector<vector3f> nodePositions;
	std::vector<RouteCost> path_cost;
	std::vector<size_t> path_prev;
	std::unordered_map<SectorKey, std::vector<size_t>, SectorKeyHash> sectorNodesMap;
	std::priority_queue<PQNode, std::vector<PQNode>, std::greater<PQNode>> pq;
	std::vector<SystemPath> outRoute;
};

std::unique_ptr<SectorView::AutoRouteState> SectorView::CreateAutoRouteState(const SystemPath &start, const SystemPath &target, float maxJumpDist, bool findFuelStar, float maxLawlessness, const std::string &factionFilter) const
{
	auto state = std::make_unique<AutoRouteState>();
	state->start = start;
	state->target = target;
	state->maxJumpDist = maxJumpDist;
	state->findFuelStar = findFuelStar;
	state->maxLawlessness = maxLawlessness;
	state->factionFilter = factionFilter;

	LuaRef try_hdrive = LuaObject<Player>::CallMethod<LuaRef>(Pi::player, "GetInstalledHyperdrive");
	if (try_hdrive.IsNil()) {
		state->status = AutoRouteState::Status::FINISHED_NO_DRIVE;
		return state;
	}

	if (start.IsSameSystem(target)) {
		state->status = AutoRouteState::Status::FINISHED_OKAY;
		return state;
	}

	state->hyperdrive = try_hdrive;
	const ScopedTable hyperdrive(try_hdrive);
	const float drive_max_range = hyperdrive.CallMethod<float>("GetMaximumRange", Pi::player);
	state->max_range = (maxJumpDist > 0.0f && maxJumpDist < drive_max_range) ? maxJumpDist : drive_max_range;
	if (state->max_range <= 0.0f) {
		state->status = AutoRouteState::Status::FINISHED_NO_VALID_ROUTE;
		return state;
	}
	state->max_range_sqr = state->max_range * state->max_range;

	float drive_fuel = 0.0f;
	hyperdrive.Get("storedFuel", drive_fuel);
	const float drive_max_fuel = hyperdrive.CallMethod<float>("GetMaxFuel");
	const float tank_fuel = (Pi::player && Pi::player->GetShipType()) ? float(Pi::player->GetShipType()->fuelTankMass * Pi::player->GetFuel()) : 0.0f;
	const float tank_max_fuel = (Pi::player && Pi::player->GetShipType()) ? float(Pi::player->GetShipType()->fuelTankMass) : 0.0f;
	state->initial_total_fuel = drive_fuel + tank_fuel;
	state->max_total_fuel_capacity = drive_max_fuel + tank_max_fuel;

	state->start_sec = m_game.GetGalaxy()->GetSector(start);
	state->target_sec = m_game.GetGalaxy()->GetSector(target);
	state->start_pos = state->start_sec->m_systems[start.systemIndex].GetFullPosition();
	state->target_pos = state->target_sec->m_systems[target.systemIndex].GetFullPosition();

	state->distSqr = Sector::DistanceBetweenSqr(state->start_sec, start.systemIndex, state->target_sec, target.systemIndex) * 1.10f;
	state->max_dist_from_straight_line = Sector::SIZE * 3.0f;
	state->sectorRadius = int(std::ceil(state->max_range / Sector::SIZE)) + 1;

	state->nodes.push_back(start);
	state->nodePositions.push_back(state->start_pos);
	state->path_cost.push_back(AutoRouteState::RouteCost{ 0, 0.f, state->initial_total_fuel });
	state->path_prev.push_back(0);

	const float startDist = (state->target_pos - state->start_pos).Length();
	const uint32_t h0 = uint32_t(std::ceil(startDist / state->max_range));
	state->pq.push(AutoRouteState::PQNode{ h0, state->path_cost[0], 0 });
	state->status = AutoRouteState::Status::RUNNING;

	return state;
}

void SectorView::StepAutoRoute(AutoRouteState &state, bool runToCompletion) const
{
	if (state.status != AutoRouteState::Status::RUNNING)
		return;

	const ScopedTable hyperdrive(state.hyperdrive);
	const auto frameStart = std::chrono::steady_clock::now();
	constexpr int MAX_EXPANSIONS_PER_FRAME = 2;
	constexpr double TIME_BUDGET_MS = 8.0;
	int expansions = 0;

	while (!state.pq.empty()) {
		if (!runToCompletion) {
			if (expansions >= MAX_EXPANSIONS_PER_FRAME)
				return;
			const double elapsedMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - frameStart).count();
			if (expansions > 0 && elapsedMs >= TIME_BUDGET_MS)
				return;
		}

		const AutoRouteState::PQNode top = state.pq.top();
		state.pq.pop();

		const size_t closest_i = top.nodeIdx;
		if (top.cost != state.path_cost[closest_i])
			continue;

		state.currentHops = std::max(state.currentHops, std::min(top.cost.jumps, MAX_ROUTE_HOPS));

		const SystemPath closest = state.nodes[closest_i];
		if (closest.IsSameSystem(state.target)) {
			size_t u = closest_i;
			state.outRoute.reserve(top.cost.jumps);
			while (u != 0) {
				state.outRoute.push_back(m_game.GetGalaxy()->GetStarSystem(state.nodes[u])->GetStars()[0]->GetPath());
				u = state.path_prev[u];
			}
			if (!state.outRoute.empty()) {
				state.outRoute.begin()->bodyIndex = state.target.bodyIndex;
				std::reverse(std::begin(state.outRoute), std::end(state.outRoute));
			}
			state.status = AutoRouteState::Status::FINISHED_OKAY;
			return;
		}

		// Hard stop at MAX_ROUTE_HOPS: do not expand beyond the hop limit
		if (top.cost.jumps >= MAX_ROUTE_HOPS)
			continue;

		++expansions;
		const vector3f closest_pos = state.nodePositions[closest_i];
		const int r = state.sectorRadius;

		for (Sint32 sx = closest.sectorX - r; sx <= closest.sectorX + r; ++sx) {
			const Sint32 dx = std::max(0, std::abs(closest.sectorX - sx) - 1);
			for (Sint32 sy = closest.sectorY - r; sy <= closest.sectorY + r; ++sy) {
				const Sint32 dy = std::max(0, std::abs(closest.sectorY - sy) - 1);
				for (Sint32 sz = closest.sectorZ - r; sz <= closest.sectorZ + r; ++sz) {
					const Sint32 dz = std::max(0, std::abs(closest.sectorZ - sz) - 1);
					const float min_dist_sqr = float(dx * dx + dy * dy + dz * dz) * (Sector::SIZE * Sector::SIZE);
					if (min_dist_sqr > state.max_range_sqr)
						continue;

					const vector3f sec_centre(Sector::SIZE * vector3f(float(sx) + 0.5f, float(sy) + 0.5f, float(sz) + 0.5f));
					const float secLineDist = MathUtil::DistanceFromLine(state.start_pos, state.target_pos, sec_centre);
					if ((secLineDist - Sector::SIZE) > state.max_dist_from_straight_line)
						continue;

					const AutoRouteState::SectorKey key{ sx, sy, sz };
					auto mapIt = state.sectorNodesMap.find(key);
					if (mapIt == state.sectorNodesMap.end()) {
						RefCountedPtr<const Sector> sec = m_game.GetGalaxy()->GetSector(SystemPath(sx, sy, sz));
						std::vector<size_t> &secNodes = state.sectorNodesMap[key];
						secNodes.reserve(sec->m_systems.size());

						for (std::vector<Sector::System>::size_type s = 0; s < sec->m_systems.size(); ++s) {
							const SystemPath sp = sec->m_systems[s].GetPath();
							if (state.start.IsSameSystem(sp))
								continue;

							const vector3f spos = sec->m_systems[s].GetFullPosition();
							const bool isTarget = state.target.IsSameSystem(sp);
							if (!isTarget) {
								const float lineDist = MathUtil::DistanceFromLine(state.start_pos, state.target_pos, spos);
								if (lineDist >= state.max_dist_from_straight_line)
									continue;
								if (Sector::DistanceBetweenSqr(state.start_sec, state.start.systemIndex, sec, sec->m_systems[s].idx) > state.distSqr ||
									Sector::DistanceBetweenSqr(state.target_sec, state.target.systemIndex, sec, sec->m_systems[s].idx) > state.distSqr)
									continue;
							}

							const size_t newIdx = state.nodes.size();
							state.nodes.push_back(sp);
							state.nodePositions.push_back(spos);
							state.path_cost.push_back(AutoRouteState::RouteCost{});
							state.path_prev.push_back(0);
							secNodes.push_back(newIdx);
						}
						mapIt = state.sectorNodesMap.find(key);
					}

					const std::vector<size_t> &secNodes = mapIt->second;
					for (size_t it : secNodes) {
						if (state.path_cost[it].jumps < top.cost.jumps + 1)
							continue;

						const float v_dist_sqr = (state.nodePositions[it] - closest_pos).LengthSqr();
						if (v_dist_sqr > state.max_range_sqr)
							continue;

						const SystemPath &v = state.nodes[it];
						const bool isTarget = state.target.IsSameSystem(v);

						// Safety / Threat filter: skip systems with lawlessness higher than maxLawlessness
						if (state.maxLawlessness > 0.0f && state.maxLawlessness < 1.0f && !isTarget && !v.IsSameSystem(state.start)) {
							RefCountedPtr<StarSystem> sys = m_game.GetGalaxy()->GetStarSystem(v);
							if (sys && sys->GetSysPolit().lawlessness.ToDouble() > state.maxLawlessness)
								continue;
						}

						// Faction filter: skip systems not belonging to the chosen faction
						RefCountedPtr<const Sector> v_sec;
						if (!state.factionFilter.empty() && state.factionFilter != "ALL" && !isTarget && !v.IsSameSystem(state.start)) {
							v_sec = m_game.GetGalaxy()->GetSector(v);
							const Faction *sysFaction = v_sec->m_systems[v.systemIndex].GetFaction();
							if (!sysFaction || sysFaction->name != state.factionFilter)
								continue;
						}

						const float v_dist_ly = std::sqrt(v_dist_sqr);
						const float v_duration = hyperdrive.CallMethod<float>("GetDuration", Pi::player, v_dist_ly, state.max_range);
						const float v_fuel = hyperdrive.CallMethod<float>("GetFuelUse", Pi::player, v_dist_ly);

						if (state.findFuelStar && top.cost.fuel_remaining < v_fuel)
							continue;

						float next_fuel = top.cost.fuel_remaining - v_fuel;
						if (state.findFuelStar) {
							if (!v_sec)
								v_sec = m_game.GetGalaxy()->GetSector(v);
							bool isFuelStar = false;
							for (unsigned sIdx = 0; sIdx < v_sec->m_systems[v.systemIndex].GetNumStars(); ++sIdx) {
								auto st = v_sec->m_systems[v.systemIndex].GetStarType(sIdx);
								if (st >= SystemBody::TYPE_STAR_M && st <= SystemBody::TYPE_STAR_O_HYPER_GIANT) {
									isFuelStar = true;
									break;
								}
							}
							if (isFuelStar)
								next_fuel = state.max_total_fuel_capacity;
						}

						const AutoRouteState::RouteCost candidate{ top.cost.jumps + 1, top.cost.duration + v_duration, next_fuel };
						if (candidate < state.path_cost[it]) {
							state.path_cost[it] = candidate;
							state.path_prev[it] = closest_i;
							const uint32_t h = isTarget ? 0 : uint32_t(std::ceil((state.target_pos - state.nodePositions[it]).Length() / state.max_range));
							state.pq.push(AutoRouteState::PQNode{ candidate.jumps + h, candidate, it });
						}
					}
				}
			}
		}
	}

	state.currentHops = MAX_ROUTE_HOPS;
	state.status = AutoRouteState::Status::FINISHED_NO_VALID_ROUTE;
}

void SectorView::StartAutoRoute(const SystemPath &start, const SystemPath &target, float maxJumpDist, bool findFuelStar, float maxLawlessness, const std::string &factionFilter)
{
	m_autoRouteState = CreateAutoRouteState(start, target, maxJumpDist, findFuelStar, maxLawlessness, factionFilter);
	if (m_autoRouteState && m_autoRouteState->status == AutoRouteState::Status::RUNNING) {
		StepAutoRoute(*m_autoRouteState, false);
		if (m_autoRouteState->status == AutoRouteState::Status::FINISHED_OKAY) {
			m_route = m_autoRouteState->outRoute;
			m_setupLines = true;
		}
	}
}

void SectorView::CancelAutoRoute()
{
	m_autoRouteState.reset();
}

bool SectorView::IsAutoRouting() const
{
	return m_autoRouteState && m_autoRouteState->status == AutoRouteState::Status::RUNNING;
}

float SectorView::GetAutoRouteProgress() const
{
	if (!m_autoRouteState)
		return 0.0f;
	return std::min(1.0f, float(m_autoRouteState->currentHops) / float(MAX_ROUTE_HOPS));
}

std::string SectorView::ConsumeAutoRouteResult()
{
	if (!m_autoRouteState || m_autoRouteState->status == AutoRouteState::Status::RUNNING)
		return "";

	std::string res;
	switch (m_autoRouteState->status) {
	case AutoRouteState::Status::FINISHED_OKAY:
		res = "OKAY";
		break;
	case AutoRouteState::Status::FINISHED_NO_DRIVE:
		res = "NO_DRIVE";
		break;
	case AutoRouteState::Status::FINISHED_NO_VALID_ROUTE:
	default:
		res = "NO_VALID_ROUTE";
		break;
	}
	m_autoRouteState.reset();
	return res;
}

const std::string SectorView::AutoRoute(const SystemPath &start, const SystemPath &target, std::vector<SystemPath> &outRoute, float maxJumpDist, bool findFuelStar, float maxLawlessness, const std::string &factionFilter) const
{
	auto state = CreateAutoRouteState(start, target, maxJumpDist, findFuelStar, maxLawlessness, factionFilter);
	if (state->status == AutoRouteState::Status::RUNNING) {
		StepAutoRoute(*state, true);
	}
	if (state->status == AutoRouteState::Status::FINISHED_NO_DRIVE)
		return "NO_DRIVE";
	if (state->status == AutoRouteState::Status::FINISHED_OKAY) {
		outRoute = std::move(state->outRoute);
		return "OKAY";
	}
	return "NO_VALID_ROUTE";
}

void SectorView::SetupLines(const vector3f &playerAbsPos, const matrix4x4f &trans)
{
	assert(m_setupLines);
	m_setupLines = false;

	m_map->ClearLineVerts();

	// line to selected system
	if (!m_current.IsSameSystem(m_selected)) {
		m_map->AddLineVert(m_map->GetSystemPosition(m_selected), Color::BLANK);
		m_map->AddLineVert(playerAbsPos, Color::WHITE);
	}

	if (!m_drawRouteLines || m_route.empty()) return;

	// line from the end of the route to the selected
	const SystemPath &routeBack = m_route.back();
	if (!routeBack.IsSameSystem(m_selected)) {
		m_map->AddLineVert(m_map->GetSystemPosition(m_selected), Color::BLANK);
		m_map->AddLineVert(m_map->GetSystemPosition(routeBack), Color::WHITE);
	}

	vector3f startPos = playerAbsPos;
	for (std::vector<SystemPath>::size_type i = 0; i < m_route.size(); ++i) {
		const vector3f jumpAbsPos = m_map->GetSystemPosition(m_route[i]);
		if (i > 0) {
			startPos = m_map->GetSystemPosition(m_route[i - 1]);
		}

		m_map->AddLineVert(startPos, Color(20, 20, 0, 127));
		m_map->AddLineVert(jumpAbsPos, Color(255, 255, 0, 255));
	}
}

void SectorView::GetPlayerPosAndStarSize(vector3f &playerPosOut, float &currentStarSizeOut)
{
	// calculate the player's location (it will be interpolated between systems during a hyperjump)
	const Sector::System currentSystem = m_map->GetCached(m_current)->m_systems[m_current.systemIndex];
	playerPosOut = Sector::SIZE * vector3f(float(m_current.sectorX), float(m_current.sectorY), float(m_current.sectorZ)) + currentSystem.GetPosition();
	currentStarSizeOut = StarSystem::starScale[currentSystem.GetStarType(0)];
	if (!m_inSystem) {
		// we are in hyperspace, interpolate
		// m_current has been set to the destination path
		// destination system data:
		const SystemPath dstPath = m_game.GetHyperspaceDest();
		const Sector::System dstSystem = m_map->GetCached(dstPath)->m_systems[dstPath.systemIndex];
		const vector3f dstPos = Sector::SIZE * vector3f(float(dstPath.sectorX), float(dstPath.sectorY), float(dstPath.sectorZ)) + dstSystem.GetPosition();
		// jumpProcess: 0.0f (at source) .. 1.0f (at destination)
		// smoothing speed at the ends with cubic interpolation
		const float jumpProcess = AnimationCurves::InOutCubicEasing(m_game.GetHyperspaceProgress() / m_game.GetHyperspaceDuration());
		// player location indicator's size of the star, on which it is drawn
		// so we interpolate it too
		const float dstStarSize = StarSystem::starScale[dstSystem.GetStarType(0)];
		// interpolating player location indicator's position and size
		playerPosOut = playerPosOut.Lerp(dstPos, jumpProcess);
		currentStarSizeOut = MathUtil::Lerp(currentStarSizeOut, dstStarSize, jumpProcess);
	}
}

SystemPath SectorView::GetDefaultFocusPath() const
{
	// Prefer a distinct selected system first; if none is selected beyond the current system,
	// fall back to the active route destination, hyperspace target, or current system.
	if (m_selected.HasValidSystem() && (!m_current.HasValidSystem() || !m_selected.IsSameSystem(m_current))) {
		return m_selected;
	}
	if (!m_route.empty() && m_route.back().HasValidSystem()) {
		return m_route.back();
	}
	if (m_hyperspaceTarget.HasValidSystem() && (!m_current.HasValidSystem() || !m_hyperspaceTarget.IsSameSystem(m_current))) {
		return m_hyperspaceTarget;
	}
	if (m_selected.HasValidSystem()) {
		return m_selected;
	}
	if (m_current.HasValidSystem()) {
		return m_current;
	}
	return SystemPath();
}

void SectorView::OnSwitchTo()
{
	InputBindings.manager->AddInputFrame(&InputBindings);
	InputBindings.manager->AddInputFrame(&m_map->InputBindings);
	Update();

	const SystemPath focusPath = GetDefaultFocusPath();
	if (focusPath.HasValidSystem()) {
		SetSelectedPath(focusPath);
		m_map->GotoSystem(focusPath);
	}
}

void SectorView::OnSwitchFrom()
{
	m_map->ReleaseMouseCapture();
	InputBindings.manager->RemoveInputFrame(&InputBindings);
	InputBindings.manager->RemoveInputFrame(&m_map->InputBindings);
}

void SectorView::Update()
{
	PROFILE_SCOPED()
	SystemPath last_current = m_current;

	m_map->Update(Pi::GetFrameTime());

	if (m_game.IsNormalSpace()) {
		m_inSystem = true;
		m_current = m_game.GetSpace()->GetStarSystem()->GetPath();
	} else {
		m_inSystem = false;
		m_current = m_game.GetHyperspaceSource();
	}

	if (m_automaticSystemSelection && m_map->IsManualMove() && m_map->GetMacroAlpha() < 0.5f) {
		SystemPath new_selected = m_map->NearestSystemToPos(m_map->GetPosition());
		if (new_selected.IsSystemPath() && !m_selected.IsSameSystem(new_selected)) {
			RefCountedPtr<StarSystem> system = m_game.GetGalaxy()->GetStarSystem(new_selected);
			SetSelectedPath(CheckPathInRoute(system->GetStars()[0]->GetPath()));
		}
	}

	m_playerHyperspaceRange = LuaObject<Player>::CallMethod<float>(Pi::player, "GetHyperspaceRange");

	if (m_autoRouteState && m_autoRouteState->status == AutoRouteState::Status::RUNNING) {
		StepAutoRoute(*m_autoRouteState, false);
		if (m_autoRouteState->status == AutoRouteState::Status::FINISHED_OKAY) {
			m_route = m_autoRouteState->outRoute;
			m_setupLines = true;
		}
	}
}

void SectorView::ResetView()
{
	const SystemPath focusPath = GetDefaultFocusPath();
	if (focusPath.HasValidSystem()) {
		SetSelectedPath(focusPath);
		m_map->GotoSystem(focusPath);
	}
	m_map->ResetView();
}

void SectorView::GotoCurrentSystem() { m_map->GotoSystem(m_current); }
void SectorView::GotoSelectedSystem() { m_map->GotoSystem(m_selected); }
void SectorView::GotoHyperspaceTarget() { m_map->GotoSystem(m_hyperspaceTarget); }

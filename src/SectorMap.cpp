// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "SectorMap.h"

#include "GameSaveError.h"
#include "Input.h"
#include "Json.h"
#include "MathUtil.h"
#include "core/Log.h"
#include "core/StringUtils.h"
#include "pigui/PiGuiRenderer.h"
#include "galaxy/Sector.h"
#include "galaxy/Galaxy.h"
#include "GameConfig.h"
#include "Random.h"
#include "graphics/Material.h"
#include "graphics/RenderState.h"
#include "graphics/Renderer.h"
#include "graphics/TextureBuilder.h"
#include "matrix3x3.h"
#include "matrix4x4.h"
#include "vector3.h"
#include "pigui/PiGui.h"
#include "profiler/Profiler.h"

#include <float.h>
#include <array>
#include <cmath>
#include <sstream>

using namespace Graphics;

static const int DRAW_RAD = 5;
#define INNER_RADIUS (Sector::SIZE * 1.5f)
#define OUTER_RADIUS (Sector::SIZE * float(DRAW_RAD))
static const float FAR_THRESHOLD = 7.5f;
static const float FAR_LIMIT = 36.f;
static const float FAR_MAX = 14000.f;
static const float ZOOM_VORONOI_START = 9.0f;
static const float ZOOM_VORONOI_FULL = 20.0f;
static const float ZOOM_MACRO_START = 22.0f;
static const float ZOOM_MACRO_FULL = 65.0f;

class SectorMap::Label {
public:
	virtual ~Label() {}
	// check if the cursor has hit the label, and if so, also save the boxes to select the text
	// should run inside imgui context
	virtual bool Hovered(const ImVec2 &p) = 0;
	virtual void Draw(ImDrawList &dl, bool hovered = false) = 0;
	virtual void OnClick() = 0;
	ImVec2 GetPos() { return ImVec2{ pos.x, pos.y }; }
	float Depth() const { return pos.z; }
	Label(Labels &host, const vector3f &pos, ImU32 color) :
		pos(pos), color(color), host(host){};

protected:
	vector3f pos;
	ImU32 color;
	Labels &host;
};

// the Label type must be complete for this constructor to work, because we
// have a unique_ptr<Label> here
SectorMap::Labels::Labels(SectorMap &map) :
	map(map) {}

// helper functions to detect when the cursor hits the label
static bool inbox(ImRect b, ImVec2 p)
{
	return p.x > b.Min.x && p.x < b.Max.x && p.y > b.Min.y && p.y < b.Max.y;
}

static bool incircle(ImVec2 c, float r, ImVec2 p)
{
	return (p.x - c.x) * (p.x - c.x) + (p.y - c.y) * (p.y - c.y) < r * r;
}

static bool indiamond(ImVec2 c, float r, ImVec2 p)
{
	float dx = p.x - c.x;
	float dy1 = p.y - (c.y - r);
	float dy2 = p.y - (c.y + r);
	return dy1 > dx && dy1 > -dx && dy2 < dx && dy2 < -dx;
}

class SectorMap::StarLabel : public SectorMap::Label {

	std::string name;
	ImVec2 namePos;
	// screen radius of the star
	float radius;
	// the height of the text of each label is different
	float textHeight;
	float scaledGap;
	SystemPath path;

	//  how much we will increase the original font so that it is less blurry for heavily enlarged labels
	static constexpr float fontScale = 5.f;

public:
	StarLabel(Labels &host, const vector3f &pos, const Color &color_, const std::string &name, const float radius, const SystemPath &path) :
		Label(host, pos, 0),
		name(name),
		radius(radius),
		path(path)
	{
		ImFont *font = host.starLabelFont;
		// we want to shade more distant labels, and make the closer ones transparent
		const float far = -0.001;
		// at a given depth, we see a label with a nominal font size
		const float mid = -0.03;
		const float near = -0.08;
		// the font may not exist in the very first frame
		const float fsize = host.fontSize;
		textHeight = std::min(fsize / mid * pos.z, 72.f);
		scaledGap = host.gap / mid * pos.z;
		const int alpha = pos.z > near ? 255 : std::max(int(near / pos.z * 255), 0);
		const float shad = pos.z < mid ? 1.0f : std::max((far - pos.z) / (far - mid), .0f);
		namePos = ImVec2(pos.x + radius + scaledGap + scaledGap, pos.y - textHeight / 2);
		color = IM_COL32(color_.r * shad, color_.g * shad, color_.b * shad, alpha);
	};

	bool Hovered(const ImVec2 &p) override
	{
		// something we can weed out right away
		if (p.x < pos.x - radius) return false;
		if (p.y < std::min(pos.y - radius, namePos.y)) return false;
		if (p.y > std::max(pos.y + radius, namePos.y + textHeight)) return false;
		ImVec2 ts = host.starLabelFont->CalcTextSizeA(host.fontSize, FLT_MAX, -1, name.c_str(), name.c_str() + name.size());
		// scale the size
		ts.x = textHeight / ts.y * ts.x;
		ts.y = textHeight;
		// sift out by last dimension
		if (p.x > namePos.x + ts.x + scaledGap) return false;
		// so, the cursor is somewhere in the dimensions of this label
		if (incircle(ImVec2(pos.x, pos.y), radius, p) ||
			inbox(ImRect(namePos.x - scaledGap, namePos.y - scaledGap, namePos.x + ts.x + scaledGap, namePos.y + host.fontSize + scaledGap), p)) {
			// so the cursor really covers this label
			// save the boxes for further highlighting the label
			host.starLabelHoverArea = ImRect(namePos.x - scaledGap, namePos.y - scaledGap, namePos.x + ts.x + scaledGap, namePos.y + ts.y + scaledGap);
			return true;
		} else
			return false;
	}

	void Draw(ImDrawList &dl, bool hovered = false) override
	{
		if (hovered) {
			dl.AddCircleFilled(ImVec2(pos.x, pos.y), radius + scaledGap, host.highlightColor);
			auto &box = host.starLabelHoverArea;
			dl.AddRectFilled(box.Min, box.Max, host.shadeColor, scaledGap);
		}
		ImFont *font = host.starLabelFont;
		dl.AddText(font, textHeight, namePos, color, name.c_str());
	}

	void OnClick() override
	{
		host.map.OnClickLabel(path);
	}

	static void InitFonts(Labels &host, ImDrawList &dl)
	{
		ImFont *&font = host.starLabelFont;
		font = host.map.GetContext().pigui->GetFont(host.fontName);
		if (!font) font = ImGui::GetFont();
	}
};

class SectorMap::FactionLabel : public SectorMap::Label {

	// how much the font of the name of the faction is smaller than the font of the name of the homeworld
	constexpr static float nameScale = .8f;
	std::string home;
	ImVec2 homePos;
	std::string name;
	ImVec2 namePos;
	// half the width of the rhombus
	float radius;
	SystemPath path;

public:
	FactionLabel(Labels &host, const vector3f &pos, const Color &color, const std::string &home, const std::string &name, const float radius, const SystemPath &path) :
		Label(host, pos, IM_COL32(color.r, color.g, color.b, color.a)),
		home(home),
		homePos(pos.x + radius + host.gap, pos.y - host.fontSize - host.gap),
		name(name),
		namePos(pos.x + radius + host.gap, pos.y + host.gap),
		radius(radius),
		path(path){};

	bool Hovered(const ImVec2 &p) override
	{
		// something we can weed out right away
		auto &gap = host.gap;
		if (p.x < pos.x - radius) return false;
		if (p.y < std::min(pos.y - radius, homePos.y - gap)) return false;
		if (p.y > std::max(pos.y + radius, namePos.y + host.fontSize * nameScale + gap)) return false;

		ImVec2 ts1 = host.factionHomeFont->CalcTextSizeA(host.fontSize, FLT_MAX, -1, home.c_str());
		ImVec2 ts2 = host.factionNameFont->CalcTextSizeA(host.fontSize * nameScale, FLT_MAX, -1, name.c_str());
		// sift out by last dimension
		if (p.x > std::max(homePos.x + ts1.x + gap, namePos.x + ts2.x + gap)) return false;
		// so, the cursor is somewhere in the dimensions of this label
		if (indiamond(ImVec2(pos.x, pos.y), radius + gap * 1.4142, p) ||
			inbox(ImRect(homePos.x - gap, homePos.y - gap, homePos.x + ts1.x + gap, homePos.y + ts1.y + gap), p) ||
			inbox(ImRect(namePos.x - gap, namePos.y - gap, namePos.x + ts2.x + gap, namePos.y + ts2.y + gap), p)) {
			// so the cursor really covers this label
			// save the boxes for further highlighting the label
			host.factionHomeHoverArea = { homePos.x - gap, homePos.y - gap, homePos.x + ts1.x + gap, homePos.y + ts1.y + gap };
			host.factionNameHoverArea = { namePos.x - gap, namePos.y - gap, namePos.x + ts2.x + gap, namePos.y + ts2.y + gap };
			return true;
		} else
			return false;
	}

	void Draw(ImDrawList &dl, bool hovered = false) override
	{
		const float x = pos.x;
		const float y = pos.y;
		// rhombus
		ImVec2 points[] = {
			{ x, y - radius }, { x + radius, y }, { x, y + radius }, { x - radius, y }
		};
		dl.AddConvexPolyFilled(points, 4, color);

		if (hovered) {
			auto hcolor = host.highlightColor;
			auto scolor = host.shadeColor;
			auto &box1 = host.factionHomeHoverArea;
			auto &box2 = host.factionNameHoverArea;
			dl.AddRectFilled(box1.Min, box1.Max, scolor, host.gap);
			dl.AddRectFilled(box2.Min, box2.Max, scolor, host.gap);
			// 1.4142 ~ sqrt(2)
			float diaGap = host.gap * 1.4142;
			// rhombus enlarged by the gap and cut off from the side of the text, so as not to run over the text boxes
			ImVec2 pointsWithGap[] = {
				{ x, y - radius - diaGap }, { x + radius, y - diaGap }, { x + radius, y + diaGap }, { x, y + radius + diaGap }, { x - radius - diaGap, y }
			};
			dl.AddConvexPolyFilled(pointsWithGap, 5, hcolor);
		}
		dl.AddText(host.factionHomeFont, host.fontSize, homePos, color, home.c_str());
		dl.AddText(host.factionNameFont, host.fontSize * nameScale, namePos, color, name.c_str());
	}

	void OnClick() override
	{
		host.map.OnClickLabel(path);
	}

	static void InitFonts(Labels &host, ImDrawList &dl)
	{
		auto *&factionHomeFont = host.factionHomeFont;
		auto *&factionNameFont = host.factionNameFont;
		auto &fontName = host.fontName;
		auto &fontSize = host.fontSize;
		factionHomeFont = host.map.GetContext().pigui->GetFont(fontName);
		if (!factionHomeFont) factionHomeFont = ImGui::GetFont();
		factionNameFont = host.map.GetContext().pigui->GetFont(fontName);
		if (!factionNameFont) factionNameFont = ImGui::GetFont();
	}
};

class SectorMap::MacroMarkerLabel : public SectorMap::Label {
	std::string title;
	std::string subtitle;
	float radius;
	vector3f worldPosLy;
	const Faction *faction;
	ImRect hoverBox;

public:
	MacroMarkerLabel(Labels &host, const vector3f &screenPos, const Color &color_, const std::string &title_, const std::string &subtitle_, float radius_, const vector3f &worldPosLy_, const Faction *faction_ = nullptr) :
		Label(host, screenPos, IM_COL32(color_.r, color_.g, color_.b, color_.a)),
		title(title_),
		subtitle(subtitle_),
		radius(radius_),
		worldPosLy(worldPosLy_),
		faction(faction_)
	{}

	bool Hovered(const ImVec2 &p) override
	{
		ImFont *font = host.starLabelFont ? host.starLabelFont : ImGui::GetFont();
		float fsize = float(host.fontSize);
		ImVec2 ts1 = font->CalcTextSizeA(fsize, FLT_MAX, -1.0f, title.c_str());
		ImVec2 ts2 = subtitle.empty() ? ImVec2(0, 0) : font->CalcTextSizeA(fsize * 0.85f, FLT_MAX, -1.0f, subtitle.c_str());
		float boxW = std::max(ts1.x, ts2.x) + 12.0f;
		float boxH = ts1.y + (subtitle.empty() ? 0.0f : ts2.y + 2.0f) + 6.0f;
		ImVec2 boxMin(pos.x + radius + 6.0f, pos.y - boxH * 0.5f);
		ImVec2 boxMax(boxMin.x + boxW, boxMin.y + boxH);
		hoverBox = ImRect(boxMin, boxMax);

		if (indiamond(ImVec2(pos.x, pos.y), radius + 4.0f, p) || inbox(hoverBox, p)) {
			return true;
		}
		return false;
	}

	void Draw(ImDrawList &dl, bool hovered = false) override
	{
		ImFont *font = host.starLabelFont ? host.starLabelFont : ImGui::GetFont();
		float fsize = float(host.fontSize);
		ImVec2 ts1 = font->CalcTextSizeA(fsize, FLT_MAX, -1.0f, title.c_str());
		ImVec2 ts2 = subtitle.empty() ? ImVec2(0, 0) : font->CalcTextSizeA(fsize * 0.85f, FLT_MAX, -1.0f, subtitle.c_str());
		float boxW = std::max(ts1.x, ts2.x) + 12.0f;
		float boxH = ts1.y + (subtitle.empty() ? 0.0f : ts2.y + 2.0f) + 6.0f;
		ImVec2 boxMin(pos.x + radius + 6.0f, pos.y - boxH * 0.5f);
		ImVec2 boxMax(boxMin.x + boxW, boxMin.y + boxH);

		const float x = pos.x;
		const float y = pos.y;
		ImVec2 pts[] = {
			{ x, y - radius },
			{ x + radius, y },
			{ x, y + radius },
			{ x - radius, y }
		};
		dl.AddQuad(pts[0], pts[1], pts[2], pts[3], color, hovered ? 2.5f : 1.5f);
		dl.AddCircleFilled(ImVec2(x, y), hovered ? 3.5f : 2.5f, color);

		ImU32 bgCol = hovered ? IM_COL32(30, 65, 95, 230) : IM_COL32(10, 18, 28, 195);
		dl.AddRectFilled(boxMin, boxMax, bgCol, 3.0f);
		dl.AddRect(boxMin, boxMax, color, 3.0f, 0, hovered ? 2.0f : 1.0f);

		dl.AddText(font, fsize, ImVec2(boxMin.x + 6.0f, boxMin.y + 3.0f), color, title.c_str());
		if (!subtitle.empty()) {
			ImU32 subCol = IM_COL32(190, 210, 225, (color >> IM_COL32_A_SHIFT) & 0xFF);
			dl.AddText(font, fsize * 0.85f, ImVec2(boxMin.x + 6.0f, boxMin.y + 3.0f + ts1.y + 1.0f), subCol, subtitle.c_str());
		}
	}

	void OnClick() override
	{
		if (faction) {
			host.map.SetSelectedFaction(faction);
		}
		host.map.GotoPositionLy(worldPosLy);
	}
};

enum DetailSelection {
	DETAILBOX_NONE = 0,
	DETAILBOX_INFO = 1,
	DETAILBOX_FACTION = 2
};

static const float ZOOM_SPEED = 15;
static const float WHEEL_SENSITIVITY = .03f; // Should be a variable in user settings.

#define FFRAC(_x) ((_x)-floor(_x))

enum Side {
	XMIN,
	XMAX,
	YMIN,
	YMAX,
	ZMIN,
	ZMAX,
	SIDES
};

using box_t = std::array<int, SIDES>;

static bool in_box(int x, int y, int z, const box_t &box)
{
	return x >= box[XMIN] && x < box[XMAX] &&
		y >= box[YMIN] && y < box[YMAX] &&
		z >= box[ZMIN] && z < box[ZMAX];
}

static int box_max_size(const box_t &box)
{
	return std::max(std::max(box[XMAX] - box[XMIN], box[YMAX] - box[YMIN]), box[ZMAX] - box[ZMIN]);
}

// helper function
// cache - source of sector and system data
// crd - coordinates of the origin point in the sector, l.y.
// originSector - coordinates of the sector containing the origin point
// targetSector - coordinates of the sector in which we are looking for the nearest system
// min_dist_sq - here we will accumulate the minimum distance
// best_sys - here we will accumulate the nearest system
static void try_sector_for_nearer_system(SectorCache::Slave *cache, const vector3f &crd, const SystemPath &originSector, const SystemPath &targetSector, float &min_dist_sq, SystemPath &best_sys)
{
	RefCountedPtr<Sector> ps = cache->GetCached(targetSector);
	vector3f base(
		targetSector.sectorX - originSector.sectorX,
		targetSector.sectorY - originSector.sectorY,
		targetSector.sectorZ - originSector.sectorZ);
	base *= Sector::SIZE;
	for (unsigned int i = 0; i < ps->m_systems.size(); i++) {
		Sector::System *ss = &ps->m_systems[i];
		vector3f dx = crd - (ss->GetPosition() + base);
		float dist = dx.LengthSqr();
		if (dist < min_dist_sq) {
			min_dist_sq = dist;
			best_sys = ss->GetPath();
		}
	}
}

// helper function
// return true, if at least one system is found
// cache - source of sector and system data
// sectorPos - coordinates of the sector containing the origin point
// crd - coordinates of the origin point in the sector, l.y.
// searchBox - we should search inside this box
// prevSearchBox - we shouldn't search inside this box (because already searched)
// min_dist_sq - here we will accumulate the minimum distance
// best_sys - here we will accumulate the nearest system
static bool search_nearest_in_box(SectorCache::Slave *cache, const SystemPath &sectorPos, const vector3f &crd, box_t &searchBox, box_t &prevSearchBox, float &min_dist_sq, SystemPath &best_sys)
{
	for (int x = searchBox[XMIN]; x < searchBox[XMAX]; ++x)
		for (int y = searchBox[YMIN]; y < searchBox[YMAX]; ++y)
			for (int z = searchBox[ZMIN]; z < searchBox[ZMAX]; ++z)
				if (!in_box(x, y, z, prevSearchBox)) // we are not looking where we have already looked
					try_sector_for_nearer_system(cache, crd, sectorPos, SystemPath(x, y, z), min_dist_sq, best_sys);
	// we will not search next time where already searched
	prevSearchBox = searchBox;
	return min_dist_sq != FLT_MAX;
}

// the function searches for the closest star to the given coordinates
// cache - source of sector and system data
// pos -  absolute coordinates of a point (in sectors, float)
// returns the found SystemPath, (system closest to the given position)
// if returned !SystemPath.IsSystemPath(), it means that nothing was found
SystemPath SectorMap::NearestSystemToPos(const vector3f &pos)
{
	// maximum size in sectors of the search box
	const int MAX_SEARCH_BOX = 10;
	// extract the coordinates of the sector, and the coordinates of the position within the sector
	SystemPath sectorPos(floor(pos.x), floor(pos.y), floor(pos.z));
	vector3f crd(FFRAC(pos.x), FFRAC(pos.y), FFRAC(pos.z));
	crd *= Sector::SIZE; // convert to l.y.
	// directions of "growth" of the search box, if necessary
	box_t enlarge = { -1, 1, -1, 1, -1, 1 };
	// remember the initial sector coordinates and point coordinates as boxes with size 0, for ease of comparison
	box_t originBox = {
		sectorPos.sectorX, sectorPos.sectorX,
		sectorPos.sectorY, sectorPos.sectorY,
		sectorPos.sectorZ, sectorPos.sectorZ
	};
	std::array<float, SIDES> posBox = { crd.x, crd.x, crd.y, crd.y, crd.z, crd.z };
	// we will remember in which box we were already looked, so as not to repeat the search
	box_t prevSearchBox = originBox;
	// here we will accumulate the minimum distance
	float min_dist_sq = FLT_MAX;
	// here we will accumulate the nearest system (this will be the result of the function)
	SystemPath best_sys;

	// the first iteration of the search - only in the sector where the base point is located
	box_t searchBox = {
		sectorPos.sectorX, sectorPos.sectorX + 1,
		sectorPos.sectorY, sectorPos.sectorY + 1,
		sectorPos.sectorZ, sectorPos.sectorZ + 1
	};
	// scan sectors, and expand the search box until we find at least one nearest system
	while (!search_nearest_in_box(m_sectorCache.Get(), sectorPos, crd, searchBox, prevSearchBox, min_dist_sq, best_sys)) {
		// expand the search box
		for (int side = 0; side < SIDES; ++side) {
			searchBox[side] += enlarge[side];
		}
		// could not find anything, within the maximum search range - we return an empty path
		if (box_max_size(searchBox) > MAX_SEARCH_BOX)
			return SystemPath();
	}

	// we found a system, but it may not be the closest one - let's check all the
	// edges of the search box, whether they are closer than the found star
	bool search_complete = true;
	for (int side = 0; side < SIDES; ++side) {
		float dist_to_edge = posBox[side] - (searchBox[side] - originBox[side]) * Sector::SIZE;
		if (dist_to_edge * dist_to_edge < min_dist_sq) {
			// the origin is closer to this edge of the search box than to the nearest found - we expand in this direction
			searchBox[side] += enlarge[side];
			search_complete = false;
		}
	}
	// if we enlarged the box, we will finally look for the closest system once again
	if (!search_complete)
		search_nearest_in_box(m_sectorCache.Get(), sectorPos, crd, searchBox, prevSearchBox, min_dist_sq, best_sys);
	return best_sys;
}

REGISTER_INPUT_BINDING(SectorMap)
{
	using namespace InputBindings;
	auto *mapView = input->GetBindingPage("MapControls");
	Input::BindingGroup *group;

#define BINDING_GROUP(n) group = mapView->GetBindingGroup(#n);
#define KEY_BINDING(name, k1, k2) \
	input->AddActionBinding(name, group, InputBindings::Action({ k1 }, { k2 }));
#define AXIS_BINDING(name, k1, k2) \
	input->AddAxisBinding(name, group, InputBindings::Axis({}, { k1 }, { k2 }));

	BINDING_GROUP(GeneralViewControls)
	KEY_BINDING("BindResetOrientationAndZoom", SDLK_t, 0)
	AXIS_BINDING("BindMapViewYaw", SDLK_KP_4, SDLK_KP_6)
	AXIS_BINDING("BindMapViewPitch", SDLK_KP_8, SDLK_KP_2)
	AXIS_BINDING("BindMapViewZoom", SDLK_KP_PLUS, SDLK_KP_MINUS)
	AXIS_BINDING("BindMapViewMoveUp", SDLK_r, SDLK_f)
	AXIS_BINDING("BindMapViewMoveLeft", SDLK_a, SDLK_d)
	AXIS_BINDING("BindMapViewMoveForward", SDLK_w, SDLK_s)

	BINDING_GROUP(SectorMapViewControls)
	KEY_BINDING("BindMapToggleSelectionFollowView", SDLK_RETURN, SDLK_KP_ENTER)
	KEY_BINDING("BindMapWarpToSelectedSystem", SDLK_g, 0)

#undef KEY_BINDING
#undef AXIS_BINDING
#undef BINDING_GROUP
}

void SectorMap::InputBinding::RegisterBindings()
{
	mapViewMoveForward = AddAxis("BindMapViewMoveForward");
	mapViewMoveLeft = AddAxis("BindMapViewMoveLeft");
	mapViewMoveUp = AddAxis("BindMapViewMoveUp");

	mapViewYaw = AddAxis("BindMapViewYaw");
	mapViewPitch = AddAxis("BindMapViewPitch");
	mapViewZoom = AddAxis("BindMapViewZoom");
}

SectorMap::SectorMap(SectorMapContext &&context) :
	InputBindings(context.input),
	m_context(std::move(context)),
	m_pos{},
	m_posMovingTo{},
	m_labels(*this)
{
	InitDefaults();

	m_rotX = m_rotXMovingTo = m_rotXDefault;
	m_rotZ = m_rotZMovingTo = m_rotZDefault;
	m_zoom = m_zoomMovingTo = m_zoomDefault;
	m_zoomClamped = Clamp(m_zoom, 1.f, FAR_LIMIT);

	m_detailBoxVisible = DETAILBOX_INFO;
	m_toggledFaction = false;

	InitObject();
}

SectorMap::SectorMap(const Json &jsonObj, SectorMapContext &&context) :
	InputBindings(context.input),
	m_context(std::move(context)),
	m_labels(*this)
{
	InitDefaults();

	try {
		Json sectorViewObj = jsonObj["sector_map"];

		m_pos.x = m_posMovingTo.x = sectorViewObj["pos_x"];
		m_pos.y = m_posMovingTo.y = sectorViewObj["pos_y"];
		m_pos.z = m_posMovingTo.z = sectorViewObj["pos_z"];
		m_rotX = m_rotXMovingTo = sectorViewObj["rot_x"];
		m_rotZ = m_rotZMovingTo = sectorViewObj["rot_z"];
		m_zoom = m_zoomMovingTo = sectorViewObj["zoom"];
		m_zoomClamped = Clamp(m_zoom, 1.f, FAR_LIMIT);
		m_visibleSphereScale = sectorViewObj.value("sphere_scale", 0.75f);
		m_detailBoxVisible = sectorViewObj["detail_box_visible"];
	} catch (Json::type_error &) {
		throw SavedGameCorruptException();
	}

	InitObject();
}

void SectorMap::InitDefaults()
{
	m_rotXDefault = m_context.config->Float("SectorViewXRotation");
	m_rotZDefault = m_context.config->Float("SectorViewZRotation");
	m_zoomDefault = m_context.config->Float("SectorViewZoom");
	m_rotXDefault = Clamp(m_rotXDefault, -170.0f, -10.0f);
	m_zoomDefault = Clamp(m_zoomDefault, 0.1f, 5.0f);
	m_visibleSphereScale = m_context.config->Float("SectorViewSphereScale", 0.75f);
	m_visibleSphereScale = Clamp(m_visibleSphereScale, 0.35f, 1.0f);

	// Note: INT_MAX != (int) ((float) INT_MAX)
	const float farPos = static_cast<float>(INT_MAX);
	m_secPosFar = vector3f(farPos, farPos, farPos);
	m_radiusFar = 0;
	m_cacheXMin = 0;
	m_cacheXMax = 0;
	m_cacheYMin = 0;
	m_cacheYMax = 0;
	m_cacheYMin = 0;
	m_cacheYMax = 0;

	m_sectorCache = m_context.galaxy->NewSectorSlaveCache();
	InputBindings.RegisterBindings();
	m_size.x = m_context.renderer->GetWindowWidth();
	m_size.y = m_context.renderer->GetWindowHeight();
}

void SectorMap::InitObject()
{
	m_lineVerts.reset(new Graphics::VertexArray(Graphics::ATTRIB_POSITION, 500));
	m_customLineVerts.reset(new Graphics::VertexArray(Graphics::ATTRIB_POSITION, 500));
	m_secLineVerts.reset(new Graphics::VertexArray(Graphics::ATTRIB_POSITION, 500));
	m_macroLineVerts.reset(new Graphics::VertexArray(Graphics::ATTRIB_POSITION, 2000));
	m_starVerts.reset(new Graphics::VertexArray(
		Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE | Graphics::ATTRIB_UV0, 500));
	m_galaxyDiscVerts.reset(new Graphics::VertexArray(
		Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE | Graphics::ATTRIB_UV0, 64));
	m_galaxyGlowVerts.reset(new Graphics::VertexArray(
		Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE | Graphics::ATTRIB_UV0, 2400));

	Graphics::RenderStateDesc rsd{};
	rsd.blendMode = Graphics::BLEND_ALPHA;

	Graphics::MaterialDescriptor bbMatDesc;

	auto vfmt = Graphics::VertexFormatDesc::FromAttribSet(m_starVerts->GetAttributeSet());
	m_starMaterial.Reset(m_context.renderer->CreateMaterial("sphereimpostor", bbMatDesc, rsd, vfmt));

	rsd.depthWrite = false;
	rsd.cullMode = CULL_NONE;

	Graphics::MaterialDescriptor starPointDesc;
	starPointDesc.vertexColors = true;
	m_farStarsMat.Reset(m_context.renderer->CreateMaterial("unlit", starPointDesc, rsd, m_farstarsPoints.GetVertexFormat()));

	Graphics::RenderStateDesc discRsd{};
	discRsd.blendMode = Graphics::BLEND_ALPHA_ONE;
	discRsd.depthWrite = false;
	discRsd.depthTest = true;
	discRsd.cullMode = CULL_NONE;
	Graphics::MaterialDescriptor discMatDesc;
	discMatDesc.textures = 1;
	discMatDesc.vertexColors = true;
	auto discVfmt = Graphics::VertexFormatDesc::FromAttribSet(m_galaxyDiscVerts->GetAttributeSet());
	m_galaxyDiscMat.Reset(m_context.renderer->CreateMaterial("unlit", discMatDesc, discRsd, discVfmt));
	Graphics::TextureBuilder tb("galaxy_4k.png", Graphics::LINEAR_CLAMP, true, false, false, false, true);
	Graphics::Texture *galTex = tb.GetOrCreateTexture(m_context.renderer, "galaxy_4k");
	m_galaxyDiscMat->SetTexture("texture0"_hash, galTex);

	m_galaxyGlowMat.Reset(m_context.renderer->CreateMaterial("unlit", discMatDesc, discRsd, discVfmt));
	Graphics::Texture *glowTex = Graphics::TextureBuilder::Billboard("textures/halo.dds").GetOrCreateTexture(m_context.renderer, "billboard");
	m_galaxyGlowMat->SetTexture("texture0"_hash, glowTex);

	rsd.primitiveType = Graphics::LINE_SINGLE;

	Graphics::MaterialDescriptor lineDesc;
	m_lineMat.Reset(m_context.renderer->CreateMaterial("vtxColor", lineDesc, rsd, m_lines.GetVertexFormat()));

	m_drawList.reset(new ImDrawList(ImGui::GetDrawListSharedData()));
}

SectorMap::~SectorMap() {}

void SectorMap::SaveToJson(Json &jsonObj)
{
	Json sectorMapObj{};

	sectorMapObj["pos_x"] = m_pos.x;
	sectorMapObj["pos_y"] = m_pos.y;
	sectorMapObj["pos_z"] = m_pos.z;
	sectorMapObj["rot_x"] = m_rotX;
	sectorMapObj["rot_z"] = m_rotZ;
	sectorMapObj["zoom"] = m_zoom;
	sectorMapObj["sphere_scale"] = m_visibleSphereScale;

	sectorMapObj["detail_box_visible"] = m_detailBoxVisible;

	jsonObj["sector_map"] = sectorMapObj; // Add sector view object to supplied object.
}

matrix4x4f SectorMap::PointOfView() {
	matrix4x4f result = matrix4x4f::Identity;
	// units are lightyears, my friend
	result.Translate(0.f, 0.f, -10.f - 10.f * m_zoom); // not zoomClamped, let us zoom out a bit beyond what we're drawing
	result.Rotate(DEG2RAD(m_rotX), 1.f, 0.f, 0.f);
	result.Rotate(DEG2RAD(m_rotZ), 0.f, 0.f, 1.f);
	return result;
}

void SectorMap::Draw3D()
{
	PROFILE_SCOPED()

	auto &renderer = m_context.renderer;
	m_secLineVerts->Clear();
	m_labels.array.clear();

	float aspect = m_size.x / m_size.y;

	const float camDist = 10.f + 10.f * m_zoom;
	if (m_zoom <= FAR_THRESHOLD) {
		renderer->SetPerspectiveProjection(40.f, aspect, 1.f, 300.f);
	} else {
		const float nearClip = std::max(1.f, camDist * 0.005f);
		const float farClip = std::max(600.f, camDist * 4.5f + 150000.f);
		renderer->SetPerspectiveProjection(40.f, aspect, nearClip, farClip);
	}

	renderer->ClearScreen();

	Graphics::Renderer::MatrixTicket ticket(renderer);

	matrix4x4f modelview = PointOfView();

	// sector drawing expects only the fractional part of the position,
	// and handles sector offset internally
	matrix4x4f sectorTrans = modelview;
	sectorTrans.Translate(-FFRAC(m_pos.x) * Sector::SIZE, -FFRAC(m_pos.y) * Sector::SIZE, -FFRAC(m_pos.z) * Sector::SIZE);
	renderer->SetTransform(sectorTrans);

	if (m_macroAlpha < 0.99f) {
		if (m_zoomClamped <= FAR_THRESHOLD)
			DrawNearSectors(sectorTrans);
		else
			DrawFarSectors(sectorTrans);
	}

	modelview.Translate(-m_pos * Sector::SIZE);

	if (m_voronoiAlpha > 0.01f || m_macroAlpha > 0.01f || m_regionalAlpha > 0.01f) {
		DrawMacroGalaxy(modelview);
	}

	//draw custom line verts in one go
	renderer->SetTransform(modelview);
	if (!m_customLineVerts->IsEmpty() && m_macroAlpha < 0.95f) {
		if(m_updateCustomLines) {
			m_customlines.SetData(m_customLineVerts->GetNumVerts(), &m_customLineVerts->position[0], &m_customLineVerts->diffuse[0]);
			m_updateCustomLines = false;
		}
		m_customlines.Draw(renderer, m_lineMat.Get());
	}

	renderer->SetTransform(matrix4x4f::Identity);

	//draw star billboards in one go
	renderer->SetAmbientColor(Color(30, 30, 30));
	if (!m_starVerts->IsEmpty()) {
		renderer->DrawBuffer(m_starVerts.get(), m_starMaterial.Get());
		m_starVerts->Clear();
	}

	//draw sector legs in one go
	if (!m_lineVerts->IsEmpty() && m_macroAlpha < 0.95f) {
		m_lines.SetData(m_lineVerts->GetNumVerts(), &m_lineVerts->position[0], &m_lineVerts->diffuse[0]);
		m_lines.Draw(renderer, m_lineMat.Get());
	}

	if (!m_secLineVerts->IsEmpty() && m_macroAlpha < 0.95f) {
		m_sectorlines.SetData(m_secLineVerts->GetNumVerts(), &m_secLineVerts->position[0], &m_secLineVerts->diffuse[0]);
		m_sectorlines.Draw(renderer, m_lineMat.Get());
	}

	if (!m_sphereParams.empty() && m_macroAlpha < 0.85f) {
		for (const auto& s : m_sphereParams) {
			m_context.renderer->SetTransform(s.trans);
			m_fresnelMat->diffuse = s.color;
			m_fresnelMat->diffuse.a = Uint8(float(s.color.a) * (1.0f - m_macroAlpha));
			m_sphere->Draw(m_context.renderer, m_fresnelMat.Get());
		}
	}
}

void SectorMap::DrawLabels(bool interactive, const ImVec2 &imagePos)
{
	if (!m_hideLabels) DrawLabelsInternal(interactive, imagePos);
}

void SectorMap::SetSize(vector2d size)
{
	ImVec2 new_size(size.x, size.y);
	if (new_size.x == m_size.x && new_size.y == m_size.y) return;

	m_size = new_size;
	m_needsResize = true;
}

void SectorMap::CreateRenderTarget()
{
	if (m_renderTarget)
		m_renderTarget.reset();

	Graphics::RenderTargetDesc rtDesc{
		uint16_t(m_size.x), uint16_t(m_size.y),
		Graphics::TextureFormat::TEXTURE_RGBA_8888,
		Graphics::TextureFormat::TEXTURE_DEPTH, true
	};

	m_renderTarget.reset(m_context.renderer->CreateRenderTarget(rtDesc));
	if (!m_renderTarget) Error("Error creating render target for model viewer.");

	m_needsResize = false;
}

// render to image and insert
void SectorMap::DrawEmbed()
{
	PROFILE_SCOPED()

	if (m_needsResize) CreateRenderTarget();
	if (!m_renderTarget) return;

	// Draw the image and stretch it over the available region.
	// ImGui inverts the vertical axis to get top-left coordinates, so we need to invert our UVs to match.
	ImVec2 imagePos = ImGui::GetCursorScreenPos();
	ImGui::Image(reinterpret_cast<ImTextureID>(m_renderTarget->GetColorTexture()), m_size, ImVec2(0, 1), ImVec2(1, 0));

	auto *r = m_context.renderer;
	const auto &desc = m_renderTarget.get()->GetDesc();

	{
		// state ticket resets all draw state at the end of the scope
		Graphics::Renderer::StateTicket ticket(r);

		r->SetRenderTarget(m_renderTarget.get());
		r->SetViewport({ 0, 0, desc.width, desc.height });

		Draw3D();
		DrawLabels(ImGui::IsItemHovered(), imagePos);
	}

	if (ImGui::IsItemHovered()) {
		ImGui::SetNextFrameWantCaptureMouse(false);
	}
}

// function is used to pass label parameters from lua
void SectorMap::SetLabelParams(std::string fontName, int fontSize, float gap, Color highlight, Color shade)
{
	m_labels.fontName = fontName;
	m_labels.fontSize = fontSize;
	m_labels.gap = gap;
	m_labels.highlightColor = IM_COL32(highlight.r, highlight.g, highlight.b, highlight.a);
	m_labels.shadeColor = IM_COL32(shade.r, shade.g, shade.b, shade.a);
}

// function should run inside imgui context
void SectorMap::DrawLabelsInternal(bool interactive, const ImVec2 &imagePos)
{
	// sort the labels to draw them starting from the farthest
	std::sort(m_labels.array.begin(), m_labels.array.end(), [](const std::unique_ptr<Label> &a, const std::unique_ptr<Label> &b) {
		return a->Depth() > b->Depth();
	});

	const size_t NOT_FOUND = m_labels.array.size();
	// the index of the label the cursor is hovering over
	size_t hovered_i = NOT_FOUND;

	m_drawList->_ResetForNewFrame();
	StarLabel::InitFonts(m_labels, *m_drawList);
	FactionLabel::InitFonts(m_labels, *m_drawList);
	m_drawList->PushClipRect({ 0.f, 0.f }, m_size);
	m_drawList->PushTexture(ImGui::GetFont()->OwnerAtlas->TexRef);

	// iterate over the labels starting with the closest one until we find the one over which the cursor is hanging
	if (interactive) {
		ImVec2 mpos = ImGui::GetMousePos();
		mpos.x -= imagePos.x;
		mpos.y -= imagePos.y;
		for (int i = m_labels.array.size() - 1; i >= 0; --i) {
			Label &label = *m_labels.array[i];
			if (hovered_i == NOT_FOUND && !m_rotateWithMouseButton && label.Hovered(mpos)) {
				hovered_i = i;
				if (m_context.input->IsMouseButtonReleased(SDL_BUTTON_LEFT)) {
					label.OnClick();
				}
				break;
			}
		}
		if (hovered_i == NOT_FOUND && !m_rotateWithMouseButton && m_voronoiAlpha > 0.1f && m_context.input->IsMouseButtonReleased(SDL_BUTTON_LEFT)) {
			HandleMacroClick(mpos);
		}
	}

	// draw labels
	for (size_t i = 0; i < m_labels.array.size(); ++i) {
		if (i == hovered_i) continue;
		Label &label = *m_labels.array[i];
		m_drawList->AddDrawCmd();
		m_drawList->CmdBuffer.back().PrimDepth = -label.Depth() * 1.01;
		label.Draw(*m_drawList);
	}

	// draw the label over which the cursor is hovering the most recent
	if (hovered_i != NOT_FOUND) {
		Label &hovered = *m_labels.array[hovered_i];
		m_drawList->AddDrawCmd();
		// seems with this depth, the label will be drawn on top of all objects
		m_drawList->CmdBuffer.back().PrimDepth = 1.0f;
		hovered.Draw(*m_drawList, true);
	}

	ImDrawData drawData{};
	ImDrawList *dl = m_drawList.get();

	drawData.Valid = true;
	drawData.CmdLists.push_back(dl);
	drawData.CmdListsCount = 1;
	drawData.TotalVtxCount = dl->VtxBuffer.size();
	drawData.TotalIdxCount = dl->IdxBuffer.size();

	drawData.DisplayPos = ImVec2(0.0f, 0.0f);
	drawData.DisplaySize = ImVec2(m_size.x, m_size.y);
	drawData.FramebufferScale = ImVec2(1.0f, 1.0f);
	// Have to get the TexList here because we're midframe and PlatformIO hasn't been updated yet
    drawData.Textures = &ImGui::GetIO().Fonts->TexList;

	m_context.pigui->GetRenderer()->RenderDrawData(&drawData);
}

void SectorMap::GotoSector(const SystemPath &path)
{
	m_posMovingTo = vector3f(path.sectorX, path.sectorY, path.sectorZ);
}

void SectorMap::GotoSystem(const SystemPath &path)
{
	RefCountedPtr<Sector> ps = GetCached(path);
	const vector3f &p = ps->m_systems[path.systemIndex].GetPosition();
	m_posMovingTo.x = path.sectorX + p.x / Sector::SIZE;
	m_posMovingTo.y = path.sectorY + p.y / Sector::SIZE;
	m_posMovingTo.z = path.sectorZ + p.z / Sector::SIZE;
}

bool SectorMap::IsCenteredOn(const SystemPath &path)
{
	RefCountedPtr<Sector> ps = GetCached(path);
	const vector3f &p = ps->m_systems[path.systemIndex].GetPosition();
	vector3f diff = vector3f(
		fabs(m_pos.x - path.sectorX - p.x / Sector::SIZE),
		fabs(m_pos.y - path.sectorY - p.y / Sector::SIZE),
		fabs(m_pos.z - path.sectorZ - p.z / Sector::SIZE));
	return ((diff.x < 0.005f && diff.y < 0.005f && diff.z < 0.005f));
}

void SectorMap::OnClickLabel(const SystemPath &path)
{
	// redirect to the real host
	m_context.callbacks->OnClickLabel(path);
}

void SectorMap::PutSystemLabel(const Sector::System &sys, bool shadow)
{
	PROFILE_SCOPED()

	// place the label
	//vector3d systemPos = vector3d((*sys).GetFullPosition() - origin);
	vector3d screenPos = Graphics::ProjectToScreen(m_context.renderer, vector3d(0.0));
	// reject back-projected labels (negative Z in clipspace is in front of the view plane)
	if (screenPos.z < 0.0f && (sys.GetPopulation() > 0 || m_drawUninhabitedLabels)) {
		vector3d screenStarEdge = Graphics::ProjectToScreen(m_context.renderer, vector3d(0.25, 0.0, 0.0));
		float screenStarRadius = screenStarEdge.x - screenPos.x;
		// work out the colour
		Color labelColor = sys.GetFaction()->AdjustedColour(sys.GetPopulation(), shadow);
		// get a system path to pass to the event handler when the label is clicked
		SystemPath sysPath = sys.GetPath();
		// label text
		std::string text = sys.GetName();
		const float x = screenPos.x;
		const float y = m_size.y - screenPos.y;
		const float z = screenPos.z;
		m_labels.array.emplace_back(std::make_unique<StarLabel>(m_labels, vector3f(x, y, z), labelColor, text, screenStarRadius, sysPath));
	}
}

void SectorMap::PutFactionLabels(const vector3f &origin)
{
	PROFILE_SCOPED()
	for (auto it = m_visibleFactions.begin(); it != m_visibleFactions.end(); ++it) {
		if ((*it)->hasHomeworld && m_hiddenFactions.find((*it)) == m_hiddenFactions.end()) {
			Sector::System sys = GetCached((*it)->homeworld)->m_systems[(*it)->homeworld.systemIndex];
			const float maxCap = 7.5f + (25.0f - 7.5f) * m_visibleSphereScale;
			const float effectiveZoom = std::min(m_zoomClamped, maxCap);
			if ((m_pos * Sector::SIZE - sys.GetFullPosition()).Length() > (effectiveZoom / FAR_THRESHOLD) * OUTER_RADIUS) continue;

			vector3d pos = Graphics::ProjectToScreen(m_context.renderer, vector3d(sys.GetFullPosition() - origin));
			if (pos.z < 0.0f) { // reject back-projected stars
				pos.y = m_size.y - pos.y;

				std::string factionHome = sys.GetName();
				std::string factionName = (*it)->name;
				Color labelColor = (*it)->colour;

				m_labels.array.emplace_back(std::make_unique<FactionLabel>(m_labels, vector3f(pos), labelColor, factionHome, factionName, 15.f, sys.GetPath()));
			}
		}
	}
}

void SectorMap::AddSphere(const matrix4x4f &trans, const Color &color)
{
	m_sphereParams.push_back({ trans, color });
}

void SectorMap::AddStarBillboard(const matrix4x4f &trans, const vector3f &pos, const Color &col, float size)
{
	const matrix3x3f rot = trans.GetOrient().Transpose();

	const vector3f offset = trans * pos;

	const vector3f rotv1 = rot * vector3f(size / 2.f, -size / 2.f, 0.0f);
	const vector3f rotv2 = rot * vector3f(size / 2.f, size / 2.f, 0.0f);

	Graphics::VertexArray &va = *m_starVerts;
	va.Add(offset - rotv1, col, vector2f(0.f, 0.f)); //top left
	va.Add(offset - rotv2, col, vector2f(0.f, 1.f)); //bottom left
	va.Add(offset + rotv2, col, vector2f(1.f, 0.f)); //top right

	va.Add(offset + rotv2, col, vector2f(1.f, 0.f)); //top right
	va.Add(offset - rotv2, col, vector2f(0.f, 1.f)); //bottom left
	va.Add(offset + rotv1, col, vector2f(1.f, 1.f)); //bottom right
}

void SectorMap::AddLineVert(const vector3f &v, const Color &c)
{
	m_customLineVerts->Add(v, c);
}

void SectorMap::ClearLineVerts()
{
	m_customLineVerts->Clear();
	m_updateCustomLines = true;
}

void SectorMap::DrawNearSectors(const matrix4x4f &modelview)
{
	PROFILE_SCOPED()
	m_visibleFactions.clear();

	for (int sx = -DRAW_RAD; sx <= DRAW_RAD; sx++) {
		for (int sy = -DRAW_RAD; sy <= DRAW_RAD; sy++) {
			for (int sz = -DRAW_RAD; sz <= DRAW_RAD; sz++) {
				DrawNearSector(int(floorf(m_pos.x)) + sx, int(floorf(m_pos.y)) + sy, int(floorf(m_pos.z)) + sz,
					modelview * matrix4x4f::Translation(Sector::SIZE * sx, Sector::SIZE * sy, Sector::SIZE * sz));
			}
		}
	}
}

void SectorMap::DrawNearSector(const int sx, const int sy, const int sz, const matrix4x4f &trans)
{
	PROFILE_SCOPED()
	m_context.renderer->SetTransform(trans);
	RefCountedPtr<Sector> ps = GetCached(SystemPath(sx, sy, sz));

	const int cz = int(floor(m_pos.z + 0.5f));

	if (cz == sz) {
		static const Color darkgreen(0, 51, 0, 255);
		const vector3f vts[] = {
			trans * vector3f(0.f, 0.f, 0.f),
			trans * vector3f(0.f, Sector::SIZE, 0.f),
			trans * vector3f(Sector::SIZE, Sector::SIZE, 0.f),
			trans * vector3f(Sector::SIZE, 0.f, 0.f)
		};

		// reserve some more space
		const size_t newNum = m_secLineVerts->GetNumVerts() + 8;
		m_secLineVerts->position.reserve(newNum);
		m_secLineVerts->diffuse.reserve(newNum);

		m_secLineVerts->Add(vts[0], darkgreen); // line segment 1
		m_secLineVerts->Add(vts[1], darkgreen);
		m_secLineVerts->Add(vts[1], darkgreen); // line segment 2
		m_secLineVerts->Add(vts[2], darkgreen);
		m_secLineVerts->Add(vts[2], darkgreen); // line segment 3
		m_secLineVerts->Add(vts[3], darkgreen);
		m_secLineVerts->Add(vts[3], darkgreen); // line segment 4
		m_secLineVerts->Add(vts[0], darkgreen);
	}

	const size_t numLineVerts = ps->m_systems.size() * 8;
	m_lineVerts->position.reserve(numLineVerts);
	m_lineVerts->diffuse.reserve(numLineVerts);

	Uint32 sysIdx = 0;
	for (std::vector<Sector::System>::iterator i = ps->m_systems.begin(); i != ps->m_systems.end(); ++i, ++sysIdx) {
		// calculate where the system is in relation the centre of the view...
		const vector3f sysAbsPos = Sector::SIZE * vector3f(float(sx), float(sy), float(sz)) + i->GetPosition();
		const vector3f toCentreOfView = m_pos * Sector::SIZE - sysAbsPos;

		// ...and skip the system if it doesn't fall within the sphere we're viewing.
		if (toCentreOfView.Length() > OUTER_RADIUS) continue;

		auto showMode = m_context.callbacks->GetDisplayMode(i->GetPath());

		bool can_skip = !(showMode & m_context.ALWAYS);

		// if the system belongs to a faction we've chosen to temporarily hide
		// then skip it if we can
		m_visibleFactions.insert(i->GetFaction());
		if (can_skip && m_hiddenFactions.find(i->GetFaction()) != m_hiddenFactions.end()) continue;

		// don't worry about looking for inhabited systems if they're
		// unexplored (same calculation as in StarSystem.cpp) or we've
		// already retrieved their population.
		const int64_t distSqSec = int64_t(sx) * sx + int64_t(sy) * sy + int64_t(sz) * sz;
		if (i->GetPopulation() < 0 && distSqSec <= 90 * 90) {

			// only do this once we've pretty much stopped moving.
			vector3f diff = vector3f(
				fabs(m_posMovingTo.x - m_pos.x),
				fabs(m_posMovingTo.y - m_pos.y),
				fabs(m_posMovingTo.z - m_pos.z));

			// Ideally, since this takes so f'ing long, it wants to be done as a threaded job but haven't written that yet.
			if ((diff.x < 0.001f && diff.y < 0.001f && diff.z < 0.001f)) {
				SystemPath current = SystemPath(sx, sy, sz, sysIdx);
				RefCountedPtr<StarSystem> pSS = m_context.galaxy->GetStarSystem(current);
				i->SetPopulation(pSS->GetTotalPop());
			}
		}

		matrix4x4f systrans = trans * matrix4x4f::Translation(i->GetPosition().x, i->GetPosition().y, i->GetPosition().z);
		m_context.renderer->SetTransform(systrans);

		if (m_drawUnchartedOverlay) {
			// Only draw diamond markers on charted systems (green for discovered by player, cyan for pre-charted)
			// Unexplored/uncharted systems do not get diamond markers
			if (i->IsExplored()) {
				Color markerCol = (i->GetExplored() == StarSystem::eEXPLORED_BY_PLAYER)
					? Color(75, 255, 145, 210) // Emerald: Discovered by player
					: Color(55, 215, 255, 175); // Cyan: Pre-charted

				const float d = 0.28f;
				const vector3f px = systrans * vector3f(d, 0.f, 0.f);
				const vector3f nx = systrans * vector3f(-d, 0.f, 0.f);
				const vector3f py = systrans * vector3f(0.f, d, 0.f);
				const vector3f ny = systrans * vector3f(0.f, -d, 0.f);
				const vector3f pz = systrans * vector3f(0.f, 0.f, d);
				const vector3f nz = systrans * vector3f(0.f, 0.f, -d);
				// Equatorial diamond
				m_lineVerts->Add(px, markerCol); m_lineVerts->Add(py, markerCol);
				m_lineVerts->Add(py, markerCol); m_lineVerts->Add(nx, markerCol);
				m_lineVerts->Add(nx, markerCol); m_lineVerts->Add(ny, markerCol);
				m_lineVerts->Add(ny, markerCol); m_lineVerts->Add(px, markerCol);
				// Vertical struts
				m_lineVerts->Add(pz, markerCol); m_lineVerts->Add(px, markerCol);
				m_lineVerts->Add(pz, markerCol); m_lineVerts->Add(nx, markerCol);
				m_lineVerts->Add(nz, markerCol); m_lineVerts->Add(py, markerCol);
				m_lineVerts->Add(nz, markerCol); m_lineVerts->Add(ny, markerCol);
			}
		}

		if (m_drawConflictOverlay) {
			auto it = m_conflictSystems.find(i->GetName());
			if (it != m_conflictSystems.end()) {
				Color markerCol;
				switch (it->second) {
				case 1: // Frontline Combat / Blockade
					markerCol = Color(255, 45, 45, 240); // Bright Red
					break;
				case 2: // Humanitarian / Outbreak / Famine
					markerCol = Color(45, 215, 255, 240); // Bright Cyan
					break;
				case 3: // Market Embargo / Deficit
					markerCol = Color(255, 185, 30, 240); // Amber
					break;
				case 4: // Political Unrest / Summit
				default:
					markerCol = Color(210, 80, 255, 240); // Purple
					break;
				}

				// Larger octahedron (0.42f) so it nests cleanly around charted diamond (0.28f)
				const float d = 0.42f;
				const vector3f px = systrans * vector3f(d, 0.f, 0.f);
				const vector3f nx = systrans * vector3f(-d, 0.f, 0.f);
				const vector3f py = systrans * vector3f(0.f, d, 0.f);
				const vector3f ny = systrans * vector3f(0.f, -d, 0.f);
				const vector3f pz = systrans * vector3f(0.f, 0.f, d);
				const vector3f nz = systrans * vector3f(0.f, 0.f, -d);

				// Equatorial diamond
				m_lineVerts->Add(px, markerCol); m_lineVerts->Add(py, markerCol);
				m_lineVerts->Add(py, markerCol); m_lineVerts->Add(nx, markerCol);
				m_lineVerts->Add(nx, markerCol); m_lineVerts->Add(ny, markerCol);
				m_lineVerts->Add(ny, markerCol); m_lineVerts->Add(px, markerCol);
				// Top pyramid struts (all 4 sides)
				m_lineVerts->Add(pz, markerCol); m_lineVerts->Add(px, markerCol);
				m_lineVerts->Add(pz, markerCol); m_lineVerts->Add(nx, markerCol);
				m_lineVerts->Add(pz, markerCol); m_lineVerts->Add(py, markerCol);
				m_lineVerts->Add(pz, markerCol); m_lineVerts->Add(ny, markerCol);
				// Bottom pyramid struts (all 4 sides)
				m_lineVerts->Add(nz, markerCol); m_lineVerts->Add(px, markerCol);
				m_lineVerts->Add(nz, markerCol); m_lineVerts->Add(nx, markerCol);
				m_lineVerts->Add(nz, markerCol); m_lineVerts->Add(py, markerCol);
				m_lineVerts->Add(nz, markerCol); m_lineVerts->Add(ny, markerCol);

				// Outer hazard bracket ring around octahedron
				const float rd = 0.54f;
				const vector3f r_px = systrans * vector3f(rd, 0.f, 0.f);
				const vector3f r_nx = systrans * vector3f(-rd, 0.f, 0.f);
				const vector3f r_py = systrans * vector3f(0.f, rd, 0.f);
				const vector3f r_ny = systrans * vector3f(0.f, -rd, 0.f);
				Color ringCol = markerCol;
				ringCol.a = 150;
				m_lineVerts->Add(r_px, ringCol); m_lineVerts->Add(r_py, ringCol);
				m_lineVerts->Add(r_py, ringCol); m_lineVerts->Add(r_nx, ringCol);
				m_lineVerts->Add(r_nx, ringCol); m_lineVerts->Add(r_ny, ringCol);
				m_lineVerts->Add(r_ny, ringCol); m_lineVerts->Add(r_px, ringCol);
			}
		}

		if ((m_drawVerticalLines && (i->GetPopulation() > 0 || m_drawUninhabitedLabels)) || !can_skip) {

			const Color light(128, 128, 128);
			const Color dark(51, 51, 51);

			// draw system "leg"
			float z = -i->GetPosition().z;
			if (sz <= cz)
				z = z + abs(cz - sz) * Sector::SIZE;
			else
				z = z - abs(cz - sz) * Sector::SIZE;
			m_lineVerts->Add(systrans * vector3f(0.f, 0.f, z), light);
			m_lineVerts->Add(systrans * vector3f(0.f, 0.f, z * 0.5f), dark);
			m_lineVerts->Add(systrans * vector3f(0.f, 0.f, z * 0.5f), dark);
			m_lineVerts->Add(systrans * vector3f(0.f, 0.f, 0.f), light);

			//cross at other end
			m_lineVerts->Add(systrans * vector3f(-0.1f, -0.1f, z), light);
			m_lineVerts->Add(systrans * vector3f(0.1f, 0.1f, z), light);
			m_lineVerts->Add(systrans * vector3f(-0.1f, 0.1f, z), light);
			m_lineVerts->Add(systrans * vector3f(0.1f, -0.1f, z), light);
		}

		// draw star blob itself
		systrans.Rotate(DEG2RAD(-m_rotZ), 0, 0, 1);
		systrans.Rotate(DEG2RAD(-m_rotX), 1, 0, 0);

		// fallback to M-class star scaling if the system doesn't have any stars (degenerate case)
		SystemBodyType::BodyType starType = (*i).GetNumStars() > 0 ? (*i).GetStarType(0) : SystemBodyType::TYPE_STAR_M;
		systrans.Scale((StarSystem::starScale[starType]));
		m_context.renderer->SetTransform(systrans);

		const Uint8 *col = StarSystem::starColors[starType];
		AddStarBillboard(systrans, vector3f(0.f), Color(col[0], col[1], col[2], 255), 0.5f);

		// add label
		if (!(showMode & m_context.HIDE_LABEL)) PutSystemLabel(*i, showMode & m_context.SHADOW_LABEL);
	}
}

void SectorMap::DrawFarSectors(const matrix4x4f &modelview)
{
	PROFILE_SCOPED()
	const float maxCap = 7.5f + (25.0f - 7.5f) * m_visibleSphereScale;
	int buildRadius = ceilf((std::min(m_zoomClamped, maxCap) / FAR_THRESHOLD) * DRAW_RAD);
	if (buildRadius <= DRAW_RAD) buildRadius = DRAW_RAD;

	const vector3f secOrigin = vector3f(int(floorf(m_pos.x)), int(floorf(m_pos.y)), int(floorf(m_pos.z)));

	// Rebuild far sector cache whenever the camera moves sectors, zoom level shifts the sector build radius, or factions toggle
	if (m_zoom < 65.0f && (m_toggledFaction || buildRadius != m_radiusFar || !secOrigin.ExactlyEqual(m_secPosFar))) {
		m_farstars.clear();
		m_farstarsColor.clear();
		m_visibleFactions.clear();

		for (int sx = secOrigin.x - buildRadius; sx <= secOrigin.x + buildRadius; sx++) {
			for (int sy = secOrigin.y - buildRadius; sy <= secOrigin.y + buildRadius; sy++) {
				for (int sz = secOrigin.z - buildRadius; sz <= secOrigin.z + buildRadius; sz++) {
					if ((vector3f(sx, sy, sz) - secOrigin).Length() <= buildRadius) {
						BuildFarSector(GetCached(SystemPath(sx, sy, sz)), Sector::SIZE * secOrigin, m_farstars, m_farstarsColor);
					}
				}
			}
		}

		m_secPosFar = secOrigin;
		m_radiusFar = buildRadius;
		m_toggledFaction = false;
	}

	// always draw the stars, slightly altering their size for different resolutions, so they still look okay
	if (m_farstars.size() > 0 && m_macroAlpha < 0.99f) {
		float sizeFactor = 0.25f * (m_context.renderer->GetWindowHeight() / 720.f);
		matrix4x4f farTrans = modelview;
		const vector3f curSecOrigin(int(floorf(m_pos.x)), int(floorf(m_pos.y)), int(floorf(m_pos.z)));
		farTrans.Translate((m_secPosFar - curSecOrigin) * Sector::SIZE);
		if (m_macroAlpha > 0.01f) {
			std::vector<Color> fadedColors = m_farstarsColor;
			const float fade = 1.0f - m_macroAlpha;
			for (auto &c : fadedColors) {
				c.a = Uint8(float(c.a) * fade);
			}
			m_farstarsPoints.SetData(m_context.renderer, m_farstars.size(), &m_farstars[0], &fadedColors[0], farTrans, sizeFactor);
		} else {
			m_farstarsPoints.SetData(m_context.renderer, m_farstars.size(), &m_farstars[0], &m_farstarsColor[0], farTrans, sizeFactor);
		}
		m_farstarsPoints.Draw(m_context.renderer, m_farStarsMat.Get());
	}

	// also add labels for any faction homeworlds among the systems we've drawn when not in macro mode
	if (m_macroAlpha < 0.35f) {
		PutFactionLabels(Sector::SIZE * secOrigin);
	}
}

void SectorMap::BuildFarSector(RefCountedPtr<Sector> sec, const vector3f &origin, std::vector<vector3f> &points, std::vector<Color> &colors)
{
	PROFILE_SCOPED()
	const float maxCap = 7.5f + (25.0f - 7.5f) * m_visibleSphereScale;
	const float effectiveZoom = std::min(m_zoomClamped, maxCap);
	Color starColor;
	for (std::vector<Sector::System>::iterator i = sec->m_systems.begin(); i != sec->m_systems.end(); ++i) {
		// skip the system if it doesn't fall within the sphere we're viewing.
		if ((m_pos * Sector::SIZE - (*i).GetFullPosition()).Length() > (effectiveZoom / FAR_THRESHOLD) * OUTER_RADIUS) continue;

		if (m_drawConflictOverlay) {
			auto it = m_conflictSystems.find(i->GetName());
			if (it != m_conflictSystems.end()) {
				points.push_back((*i).GetFullPosition() - origin);
				Color cCol;
				switch (it->second) {
				case 1: cCol = Color(255, 45, 45, 255); break; // Red
				case 2: cCol = Color(45, 215, 255, 255); break; // Cyan
				case 3: cCol = Color(255, 185, 30, 255); break; // Amber
				case 4:
				default: cCol = Color(210, 80, 255, 255); break; // Purple
				}
				colors.push_back(cCol);
				continue;
			}
		}

		if (m_drawUnchartedOverlay) {
			points.push_back((*i).GetFullPosition() - origin);
			if (!i->IsExplored()) {
				colors.push_back({ 100, 100, 100, 140 }); // Natural dim gray for unexplored systems
			} else if (i->GetExplored() == StarSystem::eEXPLORED_BY_PLAYER) {
				colors.push_back({ 75, 255, 145, 215 }); // Emerald: Discovered by player
			} else {
				colors.push_back({ 55, 215, 255, 185 }); // Cyan: Pre-charted
			}
			continue;
		}

		if (!i->IsExplored()) {
			points.push_back((*i).GetFullPosition() - origin);
			colors.push_back({ 100, 100, 100, 155 }); // flat gray for unexplored systems
			continue;
		}

		// if the system belongs to a faction we've chosen to hide also skip it, if it's not selectd in some way
		m_visibleFactions.insert(i->GetFaction());
		if (m_hiddenFactions.find(i->GetFaction()) != m_hiddenFactions.end()) continue;

		// otherwise add the system's position (origin must be m_pos's *sector* or we get judder)
		// and faction color to the list to draw
		starColor = i->GetFaction()->colour;
		starColor.a = 120;

		points.push_back((*i).GetFullPosition() - origin);
		colors.push_back(starColor);
	}
}

void SectorMap::Update(float frameTime)
{
	PROFILE_SCOPED()

	auto input = m_context.input;

	matrix4x4f rot = matrix4x4f::Identity;
	rot.RotateX(DEG2RAD(-m_rotX));
	rot.RotateZ(DEG2RAD(-m_rotZ));

	matrix3x3f shiftRot = matrix3x3f::Rotate(DEG2RAD(m_rotZ), { 0, 0, 1 });

	const float moveSpeed = input->GetMoveSpeedShiftModifier();
	float move = moveSpeed * frameTime * std::max(1.0f, m_zoom);
	vector3f shift(0.0f);
	if (m_manualMove && (m_pos - m_posMovingTo).LengthSqr() < 0.001f)
		m_manualMove = false; // used so that when you click on a system and move there, passing systems are not selected
	if (InputBindings.mapViewMoveLeft->IsActive()) {
		shift.x -= move * InputBindings.mapViewMoveLeft->GetValue();
		m_manualMove = true;
	}
	if (InputBindings.mapViewMoveForward->IsActive()) {
		shift.y += move * InputBindings.mapViewMoveForward->GetValue();
		m_manualMove = true;
	}
	if (InputBindings.mapViewMoveUp->IsActive()) {
		shift.z += move * InputBindings.mapViewMoveUp->GetValue();
		m_manualMove = true;
	}
	m_posMovingTo += shift * shiftRot;

	const float zoomScale = std::max(1.0f, m_zoomMovingTo * 0.35f);
	int wheel = input->GetMouseWheel();
	if (wheel != 0) {
		m_zoomMovingTo -= wheel * ZOOM_SPEED * WHEEL_SENSITIVITY * zoomScale * input->GetMoveSpeedShiftModifier();
	}

	if (InputBindings.mapViewZoom->IsActive()) {
		m_zoomMovingTo -= moveSpeed * frameTime * ZOOM_SPEED * 0.25f * zoomScale * InputBindings.mapViewZoom->GetValue();
	}

	m_zoomMovingTo = Clamp(m_zoomMovingTo, 0.1f, FAR_MAX);

	if (InputBindings.mapViewYaw->IsActive()) m_rotZMovingTo += 0.5f * moveSpeed * InputBindings.mapViewYaw->GetValue();
	if (InputBindings.mapViewPitch->IsActive()) m_rotXMovingTo += 0.5f * moveSpeed * InputBindings.mapViewPitch->GetValue();

	// to capture mouse when button was pressed and release when released
	if (input->MouseButtonState(SDL_BUTTON_MIDDLE) != m_rotateWithMouseButton) {
		m_rotateWithMouseButton = !m_rotateWithMouseButton;
		input->SetCapturingMouse(m_rotateWithMouseButton);
	}

	if (m_rotateWithMouseButton || m_rotateView) {
		int motion[2];
		input->GetMouseMotion(motion);
		m_rotXMovingTo += 0.2f * float(motion[1]);
		m_rotZMovingTo += 0.2f * float(motion[0]);
	} else if (m_zoomView) {
		input->SetCapturingMouse(true);
		int motion[2];
		input->GetMouseMotion(motion);
		m_zoomMovingTo += ZOOM_SPEED * 0.002f * zoomScale * motion[1];
	}

	m_rotXMovingTo = Clamp(m_rotXMovingTo, -170.0f, -10.0f);

	{
		vector3f diffPos = m_posMovingTo - m_pos;
		vector3f travelPos = diffPos * 10.0f * frameTime;
		if (travelPos.Length() > diffPos.Length())
			m_pos = m_posMovingTo;
		else
			m_pos = m_pos + travelPos;

		float diffX = m_rotXMovingTo - m_rotX;
		float travelX = diffX * 10.0f * frameTime;
		if (fabs(travelX) > fabs(diffX))
			m_rotX = m_rotXMovingTo;
		else
			m_rotX = m_rotX + travelX;

		float diffZ = m_rotZMovingTo - m_rotZ;
		float travelZ = diffZ * 10.0f * frameTime;
		if (fabs(travelZ) > fabs(diffZ))
			m_rotZ = m_rotZMovingTo;
		else
			m_rotZ = m_rotZ + travelZ;

		float diffZoom = m_zoomMovingTo - m_zoom;
		float travelZoom = diffZoom * ZOOM_SPEED * frameTime;
		if (fabs(travelZoom) > fabs(diffZoom))
			m_zoom = m_zoomMovingTo;
		else
			m_zoom = m_zoom + travelZoom;
		m_zoomClamped = Clamp(m_zoom, 1.f, FAR_LIMIT);
	}

	// Compute smooth cross-fade LOD alphas for Voronoi borders, Regional Star Field, and Macro Galactic View
	{
		float tVor = Clamp((m_zoom - ZOOM_VORONOI_START) / (ZOOM_VORONOI_FULL - ZOOM_VORONOI_START), 0.0f, 1.0f);
		m_voronoiAlpha = tVor * tVor * (3.0f - 2.0f * tVor);

		float tMac = Clamp((m_zoom - ZOOM_MACRO_START) / (ZOOM_MACRO_FULL - ZOOM_MACRO_START), 0.0f, 1.0f);
		m_macroAlpha = tMac * tMac * (3.0f - 2.0f * tMac);

		// Regional Star Field LOD: smoothly fades in as camera zooms from macro toward regional clusters (15 ly to 500 ly)
		const float regIn = Clamp((m_zoom - 14.0f) / 10.0f, 0.0f, 1.0f);
		const float regOut = Clamp((550.0f - m_zoom) / 380.0f, 0.0f, 1.0f);
		m_regionalAlpha = (regIn * regIn * (3.0f - 2.0f * regIn)) * (regOut * regOut * (3.0f - 2.0f * regOut));
	}

	if (m_macroAlpha < 0.95f) {
		ShrinkCache();
	}

	if (!m_sphere) {
		m_sphere.reset(new Graphics::Drawables::Sphere3D(m_context.renderer, 4, 1.0f));

		Graphics::RenderStateDesc rsd;
		rsd.blendMode = Graphics::BLEND_ALPHA;
		rsd.depthTest = false;
		rsd.depthWrite = false;
		rsd.cullMode = Graphics::CULL_NONE;

		Graphics::MaterialDescriptor matdesc;

		m_fresnelMat.Reset(m_context.renderer->CreateMaterial("fresnel_sphere", matdesc, rsd, m_sphere->GetVertexFormat()));
		m_fresnelMat->diffuse = Color::WHITE;

		Graphics::RenderStateDesc bubbleRsd;
		bubbleRsd.blendMode = Graphics::BLEND_ALPHA;
		bubbleRsd.depthTest = true;
		bubbleRsd.depthWrite = false;
		bubbleRsd.cullMode = Graphics::CULL_BACK;
		m_bubbleMat.Reset(m_context.renderer->CreateMaterial("fresnel_sphere", matdesc, bubbleRsd, m_sphere->GetVertexFormat()));
		m_bubbleMat->diffuse = Color::WHITE;

		Graphics::RenderStateDesc bubbleGlowRsd = bubbleRsd;
		bubbleGlowRsd.blendMode = Graphics::BLEND_ALPHA_ONE;
		m_bubbleGlowMat.Reset(m_context.renderer->CreateMaterial("fresnel_sphere", matdesc, bubbleGlowRsd, m_sphere->GetVertexFormat()));
		m_bubbleGlowMat->diffuse = Color::WHITE;
	}
	m_sphereParams.clear();
	m_lineVerts->Clear();
}

void SectorMap::ShrinkCache()
{
	PROFILE_SCOPED()
	// we're going to use these to determine if our sectors are within the range that we'll ever render
	const float maxCap = 7.5f + (25.0f - 7.5f) * m_visibleSphereScale;
	const int drawRadius = (m_zoomClamped <= FAR_THRESHOLD) ? DRAW_RAD : ceilf((std::min(m_zoomClamped, maxCap) / FAR_THRESHOLD) * DRAW_RAD);

	const int xmin = int(floorf(m_pos.x)) - drawRadius;
	const int xmax = int(floorf(m_pos.x)) + drawRadius;
	const int ymin = int(floorf(m_pos.y)) - drawRadius;
	const int ymax = int(floorf(m_pos.y)) + drawRadius;
	const int zmin = int(floorf(m_pos.z)) - drawRadius;
	const int zmax = int(floorf(m_pos.z)) + drawRadius;

	if (xmin != m_cacheXMin || xmax != m_cacheXMax || ymin != m_cacheYMin || ymax != m_cacheYMax || zmin != m_cacheZMin || zmax != m_cacheZMax) {
		auto iter = m_sectorCache->Begin();
		while (iter != m_sectorCache->End()) {
			RefCountedPtr<Sector> s = iter->second;
			//check_point_in_box
			if (!s->WithinBox(xmin, xmax, ymin, ymax, zmin, zmax)) {
				m_sectorCache->Erase(iter++);
			} else {
				iter++;
			}
		}

		m_cacheXMin = xmin;
		m_cacheXMax = xmax;
		m_cacheYMin = ymin;
		m_cacheYMax = ymax;
		m_cacheZMin = zmin;
		m_cacheZMax = zmax;
	}
}

double SectorMap::GetZoomLevel() const
{
	const float maxCap = 7.5f + (25.0f - 7.5f) * m_visibleSphereScale;
	const float effectiveZoom = std::min(m_zoomClamped, maxCap);
	return ((effectiveZoom / FAR_THRESHOLD) * (OUTER_RADIUS)) + 0.5 * Sector::SIZE;
}

std::vector<SystemPath> SectorMap::GetNearbyStarSystemsByName(std::string pattern)
{
	std::vector<SystemPath> result;
	for (auto i = m_sectorCache->Begin(); i != m_sectorCache->End(); ++i) {
		for (unsigned int systemIndex = 0; systemIndex < (*i).second->m_systems.size(); systemIndex++) {
			const Sector::System *ss = &((*i).second->m_systems[systemIndex]);

			// compare with the start of the current system
			if (strncasecmp(pattern.c_str(), ss->GetName().c_str(), pattern.size()) == 0
				// look for the pattern term somewhere within the current system
				|| pi_strcasestr(ss->GetName().c_str(), pattern.c_str())) {
				SystemPath match((*i).first);
				match.systemIndex = systemIndex;
				result.push_back(match);
				continue; // only need to add once
			} else {
				// If we didn't match the main name also check other names of this system, if there are any
				for (const std::string &other_name : ss->GetOtherNames()) {
					if (strncasecmp(pattern.c_str(), other_name.c_str(), pattern.size()) == 0
						// look for the pattern term somewhere within the current system
						|| pi_strcasestr(other_name.c_str(), pattern.c_str())) {
						SystemPath match((*i).first);
						match.systemIndex = systemIndex;
						result.push_back(match);
						continue; // only need to add once
					}
				}
			}
		}
	}
	return result;
}

void SectorMap::SetFactionVisible(const Faction *faction, bool visible)
{
	if (visible)
		m_hiddenFactions.erase(faction);
	else
		m_hiddenFactions.insert(faction);
	m_toggledFaction = true;
}

void SectorMap::SetZoomMode(bool enable)
{
	if (enable != m_zoomView) {
		m_context.input->SetCapturingMouse(enable);
		m_zoomView = enable;
		if (m_zoomView) m_rotateView = false;
	}
}

void SectorMap::SetRotateMode(bool enable)
{
	if (enable != m_rotateView) {
		m_context.input->SetCapturingMouse(enable);
		m_rotateView = enable;
		if (m_rotateView) m_zoomView = false;
	}
}

void SectorMap::ResetView()
{
	while (m_rotZ < -180.0f)
		m_rotZ += 360.0f;
	while (m_rotZ > 180.0f)
		m_rotZ -= 360.0f;
	m_rotXMovingTo = m_rotXDefault;
	m_rotZMovingTo = m_rotZDefault;
	m_zoomMovingTo = m_zoomDefault;
}

vector3f SectorMap::GetSystemPosition(const SystemPath &path)
{
	const Sector::System sys = GetCached(path)->m_systems[path.systemIndex];
	return Sector::SIZE * vector3f(float(path.sectorX), float(path.sectorY), float(path.sectorZ)) + sys.GetPosition();
}

void SectorMap::GotoPositionLy(const vector3f &posLy)
{
	m_posMovingTo = posLy * (1.0f / Sector::SIZE);
}

void SectorMap::GotoSol()
{
	m_posMovingTo = vector3f(0.0f, 0.0f, 0.0f);
}

void SectorMap::GotoGalacticCore()
{
	m_posMovingTo = GetGalacticCorePositionLy() * (1.0f / Sector::SIZE);
}

void SectorMap::SetMacroZoom(float zoom)
{
	m_zoomMovingTo = Clamp(zoom, 0.1f, FAR_MAX);
}

vector3f SectorMap::GetPositionLy() const
{
	return m_pos * Sector::SIZE;
}

vector3f SectorMap::GetGalacticCorePositionLy() const
{
	if (!m_context.galaxy) return vector3f(-25000.0f, 0.0f, 0.0f);
	return vector3f(-m_context.galaxy->SOL_OFFSET_X, m_context.galaxy->SOL_OFFSET_Y, 0.0f);
}

float SectorMap::GetGalaxyRadiusLy() const
{
	if (!m_context.galaxy) return 50000.0f;
	return m_context.galaxy->GALAXY_RADIUS;
}

void SectorMap::SetMacroMarkers(const vector3f &playerPosLy, const vector3f &selectedPosLy, bool hasSelected)
{
	m_playerPosLy = playerPosLy;
	m_selectedPosLy = selectedPosLy;
	m_hasSelectedMarker = hasSelected;
}

const Faction *SectorMap::GetFactionAtPositionLy(const vector3f &posLy) const
{
	if (!m_context.galaxy) return nullptr;
	FactionsDatabase *factionsDb = m_context.galaxy->GetFactions();
	if (!factionsDb) return nullptr;

	const Faction *bestFaction = nullptr;
	float bestDist = FLT_MAX;

	if (!m_factionSites.empty()) {
		for (const auto &site : m_factionSites) {
			const float dist3D = (posLy - site.homePosLy).Length();
			if (dist3D <= site.radiusLy && dist3D < bestDist) {
				bestDist = dist3D;
				bestFaction = site.faction;
			}
		}
	} else {
		const Uint32 numFactions = factionsDb->GetNumFactions();
		for (Uint32 i = 0; i < numFactions; ++i) {
			const Faction *f = factionsDb->GetFaction(i);
			if (!f || !f->hasHomeworld || f->Radius() <= 0.0) continue;
			const vector3f fpos = Sector::SIZE * vector3f(float(f->homeworld.sectorX), float(f->homeworld.sectorY), float(f->homeworld.sectorZ));
			const float dist3D = (posLy - fpos).Length();
			if (dist3D <= float(f->Radius()) && dist3D < bestDist) {
				bestDist = dist3D;
				bestFaction = f;
			}
		}
	}

	if (!bestFaction) {
		bestFaction = factionsDb->GetFaction("Independent");
	}
	return bestFaction;
}

void SectorMap::InitMacroGalaxy()
{
	if (m_macroInitialized) return;
	m_macroInitialized = true;

	if (!m_context.galaxy) return;

	// 1. Gather faction sites and compute 3D Bubble territorial shells & 3D intersection rings
	m_factionSites.clear();
	m_voronoiEdges.clear();

	FactionsDatabase *factionsDb = m_context.galaxy->GetFactions();
	if (factionsDb) {
		const Uint32 numFactions = factionsDb->GetNumFactions();
		m_factionSites.reserve(numFactions);
		for (Uint32 i = 0; i < numFactions; ++i) {
			const Faction *f = factionsDb->GetFaction(i);
			if (!f || !f->hasHomeworld || f->Radius() <= 0.0) continue;
			RefCountedPtr<Sector> sec = GetCached(f->homeworld);
			vector3f homePos = Sector::SIZE * vector3f(float(f->homeworld.sectorX), float(f->homeworld.sectorY), float(f->homeworld.sectorZ));
			if (f->homeworld.systemIndex < sec->m_systems.size()) {
				homePos += sec->m_systems[f->homeworld.systemIndex].GetPosition();
			}
			m_factionSites.push_back({ f, homePos, float(f->Radius()) });
		}

		const size_t nSites = m_factionSites.size();

		// Pass 1: 3D Sphere-Sphere Intersection Rings where two faction bubbles meet in 3D space
		for (size_t i = 0; i < nSites; ++i) {
			const vector3f pi = m_factionSites[i].homePosLy;
			const float ri = m_factionSites[i].radiusLy;

			for (size_t j = i + 1; j < nSites; ++j) {
				const vector3f pj = m_factionSites[j].homePosLy;
				const float rj = m_factionSites[j].radiusLy;
				const vector3f diff = pj - pi;
				const float dist = diff.Length();
				const float rMin = std::min(ri, rj);
				if (dist < 0.1f || dist * 0.5f >= rMin) continue;

				// 3D Voronoi bisector plane between pi and pj
				const vector3f mid = (pi + pj) * 0.5f;
				const vector3f normal = diff * (1.0f / dist);
				const float ringRadius = std::sqrt(rMin * rMin - (dist * 0.5f) * (dist * 0.5f));

				// Orthonormal basis (uAxis, vAxis) in the 3D bisector plane
				vector3f refUp = (std::fabs(normal.z) < 0.85f) ? vector3f(0.0f, 0.0f, 1.0f) : vector3f(1.0f, 0.0f, 0.0f);
				const vector3f uAxis = normal.Cross(refUp).Normalized();
				const vector3f vAxis = normal.Cross(uAxis).Normalized();

				const int steps = 36;
				for (int s = 0; s < steps; ++s) {
					const float a0 = (2.0f * float(M_PI) * float(s)) / float(steps);
					const float a1 = (2.0f * float(M_PI) * float(s + 1)) / float(steps);
					const float aMid = 0.5f * (a0 + a1);
					const vector3f qMid = mid + (uAxis * std::cos(aMid) + vAxis * std::sin(aMid)) * ringRadius;
					const float d_ij = (qMid - pi).Length();

					bool occluded = false;
					for (size_t k = 0; k < nSites; ++k) {
						if (k == i || k == j) continue;
						const float dk = (qMid - m_factionSites[k].homePosLy).Length();
						if (dk < m_factionSites[k].radiusLy && dk < d_ij - 0.05f) {
							occluded = true;
							break;
						}
					}
					if (!occluded) {
						const vector3f q0 = mid + (uAxis * std::cos(a0) + vAxis * std::sin(a0)) * ringRadius;
						const vector3f q1 = mid + (uAxis * std::cos(a1) + vAxis * std::sin(a1)) * ringRadius;
						m_voronoiEdges.push_back({
							q0,
							q1,
							m_factionSites[i].faction,
							m_factionSites[j].faction
						});
					}
				}
			}
		}

		// Pass 2: 3D Spherical Bubble Contour Rings (Equatorial, Orthogonal Meridians & Latitude Rings)
		for (size_t i = 0; i < nSites; ++i) {
			const vector3f pi = m_factionSites[i].homePosLy;
			const float ri = m_factionSites[i].radiusLy;
			const Faction *fac = m_factionSites[i].faction;

			auto addClippedRing3D = [&](const vector3f &ringCenter, const vector3f &uAxis, const vector3f &vAxis, float ringRad, int arcSteps) {
				for (int s = 0; s < arcSteps; ++s) {
					const float a0 = (2.0f * float(M_PI) * float(s)) / float(arcSteps);
					const float a1 = (2.0f * float(M_PI) * float(s + 1)) / float(arcSteps);
					const float aMid = 0.5f * (a0 + a1);
					const vector3f qMid = ringCenter + (uAxis * std::cos(aMid) + vAxis * std::sin(aMid)) * ringRad;

					bool occluded = false;
					for (size_t k = 0; k < nSites; ++k) {
						if (k == i) continue;
						const float dk = (qMid - m_factionSites[k].homePosLy).Length();
						if (dk < m_factionSites[k].radiusLy && dk < ri - 0.05f) {
							occluded = true;
							break;
						}
					}
					if (!occluded) {
						const vector3f q0 = ringCenter + (uAxis * std::cos(a0) + vAxis * std::sin(a0)) * ringRad;
						const vector3f q1 = ringCenter + (uAxis * std::cos(a1) + vAxis * std::sin(a1)) * ringRad;
						m_voronoiEdges.push_back({ q0, q1, fac, nullptr });
					}
				}
			};

			// Equatorial ring (XY plane at faction homeworld Z)
			addClippedRing3D(pi, vector3f(1.0f, 0.0f, 0.0f), vector3f(0.0f, 1.0f, 0.0f), ri, 48);
			// Meridian ring 1 (XZ plane)
			addClippedRing3D(pi, vector3f(1.0f, 0.0f, 0.0f), vector3f(0.0f, 0.0f, 1.0f), ri, 40);
			// Meridian ring 2 (YZ plane)
			addClippedRing3D(pi, vector3f(0.0f, 1.0f, 0.0f), vector3f(0.0f, 0.0f, 1.0f), ri, 40);
			// Upper & lower latitude rings (+/- 42 degrees) for clear 3D spherical curvature
			const float latSin = std::sin(DEG2RAD(42.0f));
			const float latCos = std::cos(DEG2RAD(42.0f));
			addClippedRing3D(pi + vector3f(0.0f, 0.0f, ri * latSin), vector3f(1.0f, 0.0f, 0.0f), vector3f(0.0f, 1.0f, 0.0f), ri * latCos, 36);
			addClippedRing3D(pi - vector3f(0.0f, 0.0f, ri * latSin), vector3f(1.0f, 0.0f, 0.0f), vector3f(0.0f, 1.0f, 0.0f), ri * latCos, 36);
		}
	}

	// 2. Generate 3D Volumetric Galactic Star Cloud from Galaxy Density Map (45,000 points)
	m_galaxyCloudPos.clear();
	m_galaxyCloudBaseColor.clear();
	const vector3f corePos = GetGalacticCorePositionLy();
	const float galRad = GetGalaxyRadiusLy();

	Random rng(0x50104E34);
	const int targetParticles = 45000;
	m_galaxyCloudPos.reserve(targetParticles);
	m_galaxyCloudBaseColor.reserve(targetParticles);

	for (int attempt = 0; attempt < targetParticles * 5 && int(m_galaxyCloudPos.size()) < targetParticles; ++attempt) {
		const float u = float(rng.Double());
		// Bias slightly toward inner and mid disc while covering outer arms
		const float r = galRad * std::pow(u, 0.65f);
		const float theta = float(rng.Double()) * 2.0f * float(M_PI);

		const float wx = corePos.x + r * std::cos(theta);
		const float wy = corePos.y + r * std::sin(theta);
		const int sx = int(std::floor(wx / Sector::SIZE));
		const int sy = int(std::floor(wy / Sector::SIZE));

		const Uint8 density = m_context.galaxy->GetSectorDensity(sx, sy, 0);
		const float normDens = float(density) / 255.0f;
		const float bulgeBoost = std::exp(-(r * r) / (8500.0f * 8500.0f)) * 0.45f;

		if (float(rng.Double()) > (normDens * 0.85f + bulgeBoost)) continue;

		// 3D vertical thickness: thicker central bulge (~1500 ly), thinner spiral disc (~280 ly)
		const float sigmaZ = 260.0f + 1350.0f * std::exp(-(r * r) / (8000.0f * 8000.0f));
		const float g1 = float(rng.Double()) + float(rng.Double()) + float(rng.Double()) - 1.5f;
		const float wz = g1 * sigmaZ;

		m_galaxyCloudPos.push_back(vector3f(wx, wy, wz));

		// Color temperature gradient: warm golden-amber core to crisp blue-white spiral arms
		const float coreFactor = std::exp(-(r * r) / (11000.0f * 11000.0f));
		const float armFactor = Clamp((normDens - 0.35f) * 1.6f, 0.0f, 1.0f) * (1.0f - coreFactor);
		const Uint8 cr = Uint8(Clamp(175.0f + 80.0f * coreFactor - 25.0f * armFactor + float(rng.Int32(-12, 12)), 120.0f, 255.0f));
		const Uint8 cg = Uint8(Clamp(185.0f + 35.0f * coreFactor + 15.0f * armFactor + float(rng.Int32(-10, 10)), 140.0f, 255.0f));
		const Uint8 cb = Uint8(Clamp(210.0f - 55.0f * coreFactor + 45.0f * armFactor + float(rng.Int32(-10, 10)), 135.0f, 255.0f));
		const Uint8 ca = Uint8(Clamp(95.0f + 115.0f * normDens + 40.0f * coreFactor, 65.0f, 225.0f));

		m_galaxyCloudBaseColor.push_back(Color(cr, cg, cb, ca));
	}
	m_galaxyCloudDrawColor = m_galaxyCloudBaseColor;

	// 3. Generate 3D Volumetric Galactic Glow Billboards (Central Bulge, Sagittarius A* & Spiral Arm Nebulae)
	m_galaxyGlowBillboards.clear();
	m_galaxyGlowBillboards.reserve(360);

	// A. Multi-layer Sagittarius A* & Central Galactic Core Glow
	m_galaxyGlowBillboards.push_back({ corePos, 18500.0f, Color(255, 190, 110, 85) });
	m_galaxyGlowBillboards.push_back({ corePos, 11000.0f, Color(255, 220, 155, 135) });
	m_galaxyGlowBillboards.push_back({ corePos, 5200.0f,  Color(255, 245, 215, 195) });
	m_galaxyGlowBillboards.push_back({ corePos + vector3f(0.0f, 0.0f, 950.0f),  9200.0f, Color(255, 200, 130, 75) });
	m_galaxyGlowBillboards.push_back({ corePos + vector3f(0.0f, 0.0f, -950.0f), 9200.0f, Color(255, 200, 130, 75) });

	// B. 3D Ellipsoidal Galactic Bulge Glow Cloud (rising +/- 2,400 ly above and below the plane)
	Random glowRng(0x610A9E4B);
	for (int i = 0; i < 70; ++i) {
		const float u = float(glowRng.Double());
		const float rXY = 9500.0f * std::pow(u, 0.7f);
		const float theta = float(glowRng.Double()) * 2.0f * float(M_PI);
		const float gZ = float(glowRng.Double()) + float(glowRng.Double()) + float(glowRng.Double()) - 1.5f;
		const float sigmaZ = 1450.0f * std::exp(-(rXY * rXY) / (7500.0f * 7500.0f)) + 350.0f;
		const vector3f pos(
			corePos.x + rXY * std::cos(theta),
			corePos.y + rXY * std::sin(theta),
			gZ * sigmaZ);
		const float puffRad = 3600.0f + float(glowRng.Double()) * 4600.0f;
		const float warm = std::exp(-(rXY * rXY) / (8000.0f * 8000.0f));
		const Uint8 cr = Uint8(Clamp(225.0f + 30.0f * warm, 200.0f, 255.0f));
		const Uint8 cg = Uint8(Clamp(175.0f + 45.0f * warm, 150.0f, 235.0f));
		const Uint8 cb = Uint8(Clamp(125.0f + 35.0f * warm, 100.0f, 190.0f));
		const Uint8 ca = Uint8(Clamp(26.0f + 36.0f * warm, 18.0f, 68.0f));
		m_galaxyGlowBillboards.push_back({ pos, puffRad, Color(cr, cg, cb, ca) });
	}

	// C. 3D Spiral Arm & Star-Forming Nebula Glow Puffs distributed in 3D across the disc
	const int targetArmGlows = 280;
	for (int attempt = 0; attempt < targetArmGlows * 8 && int(m_galaxyGlowBillboards.size()) < 75 + targetArmGlows; ++attempt) {
		const float u = float(glowRng.Double());
		const float r = 4500.0f + (galRad * 0.92f - 4500.0f) * std::pow(u, 0.62f);
		const float theta = float(glowRng.Double()) * 2.0f * float(M_PI);
		const float wx = corePos.x + r * std::cos(theta);
		const float wy = corePos.y + r * std::sin(theta);
		const int sx = int(std::floor(wx / Sector::SIZE));
		const int sy = int(std::floor(wy / Sector::SIZE));

		const Uint8 density = m_context.galaxy->GetSectorDensity(sx, sy, 0);
		const float normDens = float(density) / 255.0f;
		if (normDens < 0.34f || float(glowRng.Double()) > normDens * 0.95f) continue;

		const float sigmaZ = 340.0f + 780.0f * std::exp(-(r * r) / (15000.0f * 15000.0f));
		const float gZ = float(glowRng.Double()) + float(glowRng.Double()) - 1.0f;
		const float wz = gZ * sigmaZ;
		const float puffRad = 2600.0f + float(glowRng.Double()) * 3600.0f;

		const float coreBlend = std::exp(-(r * r) / (14000.0f * 14000.0f));
		const bool isNebulaKnot = (glowRng.Double() < 0.22);
		Uint8 cr, cg, cb;
		if (isNebulaKnot) {
			// Luminous rose-violet / magenta H-II star-forming nebula glow
			cr = Uint8(Clamp(210.0f + 35.0f * normDens, 180.0f, 255.0f));
			cg = Uint8(Clamp(115.0f + 45.0f * coreBlend, 95.0f, 180.0f));
			cb = Uint8(Clamp(220.0f - 30.0f * coreBlend, 165.0f, 255.0f));
		} else {
			// Cool sapphire-cyan spiral arm starlight glow blending to golden inner arms
			cr = Uint8(Clamp(125.0f + 115.0f * coreBlend, 110.0f, 245.0f));
			cg = Uint8(Clamp(170.0f + 40.0f * coreBlend + 25.0f * normDens, 145.0f, 240.0f));
			cb = Uint8(Clamp(245.0f - 75.0f * coreBlend, 155.0f, 255.0f));
		}
		const Uint8 ca = Uint8(Clamp(18.0f + 34.0f * normDens, 14.0f, 52.0f));
		m_galaxyGlowBillboards.push_back({ vector3f(wx, wy, wz), puffRad, Color(cr, cg, cb, ca) });
	}
}

void SectorMap::UpdateRegionalStarField(const vector3f &centerLy)
{
	m_regionalStarPos.clear();
	m_regionalStarBaseColor.clear();
	m_lastRegionalCenterLy = centerLy;

	if (!m_context.galaxy)
		return;

	const int targetRegionalStars = 24000;
	m_regionalStarPos.reserve(targetRegionalStars);
	m_regionalStarBaseColor.reserve(targetRegionalStars);

	Random rng(0x7A1F2C5B);
	const float maxRadiusLy = 2800.0f;

	for (int attempt = 0; attempt < targetRegionalStars * 5 && int(m_regionalStarPos.size()) < targetRegionalStars; ++attempt) {
		const float u = float(rng.Double());
		// Bias slightly toward the focal center for crisp regional star density
		const float r = maxRadiusLy * std::pow(u, 0.45f);
		const float theta = float(rng.Double()) * 2.0f * float(M_PI);
		const float phi = std::acos(2.0f * float(rng.Double()) - 1.0f);

		const float x = centerLy.x + r * std::sin(phi) * std::cos(theta);
		const float y = centerLy.y + r * std::sin(phi) * std::sin(theta);
		// Flatten vertically to match realistic galactic disc scale height (~320 ly)
		const float z = (centerLy.z + r * std::cos(phi)) * 0.35f;

		const int sx = int(std::floor(x / Sector::SIZE));
		const int sy = int(std::floor(y / Sector::SIZE));
		const int sz = int(std::floor(z / Sector::SIZE));

		const Uint8 dens = m_context.galaxy->GetSectorDensity(sx, sy, sz);
		if (dens == 0)
			continue;

		const float normDens = float(dens) / 255.0f;
		if (float(rng.Double()) > normDens * 1.15f)
			continue;

		// Exact star position with sub-sector jitter
		const float ox = float(rng.Double() * Sector::SIZE);
		const float oy = float(rng.Double() * Sector::SIZE);
		const float oz = float(rng.Double() * Sector::SIZE);
		m_regionalStarPos.push_back(vector3f(float(sx) * Sector::SIZE + ox, float(sy) * Sector::SIZE + oy, float(sz) * Sector::SIZE + oz));

		// Spectral type determination matching stellar population distribution
		const double stRoll = rng.Double();
		Uint8 cr, cg, cb, ca;
		if (stRoll < 0.05) {
			// Type O/B: luminous blue giant
			cr = 180; cg = 210; cb = 255; ca = 240;
		} else if (stRoll < 0.18) {
			// Type A: bright white star
			cr = 225; cg = 235; cb = 255; ca = 220;
		} else if (stRoll < 0.38) {
			// Type F/G: yellow-white / solar type
			cr = 255; cg = 245; cb = 195; ca = 205;
		} else if (stRoll < 0.68) {
			// Type K: orange star
			cr = 255; cg = 190; cb = 115; ca = 185;
		} else {
			// Type M: red dwarf
			cr = 255; cg = 135; cb = 90; ca = 160;
		}

		m_regionalStarBaseColor.push_back(Color(cr, cg, cb, ca));
	}

	m_regionalStarDrawColor = m_regionalStarBaseColor;
}

void SectorMap::DrawMacroGalaxy(const matrix4x4f &modelview)
{
	PROFILE_SCOPED()
	InitMacroGalaxy();

	auto &renderer = m_context.renderer;
	const vector3f corePos = GetGalacticCorePositionLy();
	const float galRad = GetGalaxyRadiusLy();

	// 1. Render Multi-Layered 3D Textured Galactic Disc Stack, 3D Volumetric Glow Cloud & Global Star Cloud
	const matrix3x3f camOrient = modelview.GetOrient().Transpose();
	const vector3f camRight = camOrient * vector3f(1.0f, 0.0f, 0.0f);
	const vector3f camUp    = camOrient * vector3f(0.0f, 1.0f, 0.0f);

	auto addGlowQuad = [&](const vector3f &centerLy, float radiusLy, const Color &col) {
		if (col.a == 0) return;
		const vector3f r1 = (camRight - camUp) * radiusLy;
		const vector3f r2 = (camRight + camUp) * radiusLy;
		m_galaxyGlowVerts->Add(centerLy - r1, col, vector2f(0.0f, 0.0f));
		m_galaxyGlowVerts->Add(centerLy - r2, col, vector2f(0.0f, 1.0f));
		m_galaxyGlowVerts->Add(centerLy + r2, col, vector2f(1.0f, 0.0f));

		m_galaxyGlowVerts->Add(centerLy + r2, col, vector2f(1.0f, 0.0f));
		m_galaxyGlowVerts->Add(centerLy - r2, col, vector2f(0.0f, 1.0f));
		m_galaxyGlowVerts->Add(centerLy + r1, col, vector2f(1.0f, 1.0f));
	};

	m_galaxyGlowVerts->Clear();

	if (m_macroAlpha > 0.01f) {
		m_galaxyDiscVerts->Clear();

		auto addDiscLayer = [&](float zOffset, float radialScale, const Color &tint, float alphaScale) {
			const Uint8 a = Uint8(Clamp(m_macroAlpha * alphaScale * 255.0f, 0.0f, 255.0f));
			if (a == 0) return;
			const Color c(tint.r, tint.g, tint.b, a);
			const float rScaled = galRad * radialScale;
			const float xMin = corePos.x - rScaled;
			const float xMax = corePos.x + rScaled;
			const float yMin = corePos.y - rScaled;
			const float yMax = corePos.y + rScaled;

			const vector3f pTL(xMin, yMax, zOffset);
			const vector3f pBL(xMin, yMin, zOffset);
			const vector3f pBR(xMax, yMin, zOffset);
			const vector3f pTR(xMax, yMax, zOffset);

			m_galaxyDiscVerts->Add(pTL, c, vector2f(0.0f, 0.0f));
			m_galaxyDiscVerts->Add(pBL, c, vector2f(0.0f, 1.0f));
			m_galaxyDiscVerts->Add(pBR, c, vector2f(1.0f, 1.0f));

			m_galaxyDiscVerts->Add(pTL, c, vector2f(0.0f, 0.0f));
			m_galaxyDiscVerts->Add(pBR, c, vector2f(1.0f, 1.0f));
			m_galaxyDiscVerts->Add(pTR, c, vector2f(1.0f, 0.0f));
		};

		// Fade disc smoothly when zooming into regional scale so 3D stars take over
		const float discAlphaScale = 0.85f * Clamp((m_zoom - 35.0f) / 120.0f, 0.15f, 1.0f);
		// Multi-plane 3D vertical stack so the galactic disc has true 3D thickness and glow when tilted
		addDiscLayer(0.0f,     1.00f, Color(255, 255, 255), discAlphaScale * 0.62f);
		addDiscLayer(180.0f,   0.99f, Color(245, 240, 255), discAlphaScale * 0.16f);
		addDiscLayer(-180.0f,  0.99f, Color(245, 240, 255), discAlphaScale * 0.16f);
		addDiscLayer(420.0f,   0.95f, Color(235, 220, 250), discAlphaScale * 0.10f);
		addDiscLayer(-420.0f,  0.95f, Color(235, 220, 250), discAlphaScale * 0.10f);
		addDiscLayer(780.0f,   0.86f, Color(255, 205, 175), discAlphaScale * 0.06f);
		addDiscLayer(-780.0f,  0.86f, Color(255, 205, 175), discAlphaScale * 0.06f);
		addDiscLayer(1250.0f,  0.70f, Color(255, 190, 140), discAlphaScale * 0.035f);
		addDiscLayer(-1250.0f, 0.70f, Color(255, 190, 140), discAlphaScale * 0.035f);

		renderer->SetTransform(modelview);
		renderer->DrawBuffer(m_galaxyDiscVerts.get(), m_galaxyDiscMat.Get());

		// Populate 3D volumetric glow billboards for Galactic Core, 3D Bulge & Spiral Arm Nebulae
		const float glowFade = Clamp((m_zoom - 25.0f) / 90.0f, 0.2f, 1.0f) * m_macroAlpha;
		for (const auto &gb : m_galaxyGlowBillboards) {
			Color gc = gb.color;
			gc.a = Uint8(Clamp(float(gb.color.a) * glowFade, 0.0f, 255.0f));
			addGlowQuad(gb.posLy, gb.radiusLy, gc);
		}

		// Draw 3D volumetric star particle cloud (Global Milky Way Cloud - 45,000 points)
		if (!m_galaxyCloudPos.empty()) {
			for (size_t i = 0; i < m_galaxyCloudBaseColor.size(); ++i) {
				m_galaxyCloudDrawColor[i] = m_galaxyCloudBaseColor[i];
				m_galaxyCloudDrawColor[i].a = Uint8(float(m_galaxyCloudBaseColor[i].a) * m_macroAlpha);
			}
			const float ptSize = Clamp(0.32f * (renderer->GetWindowHeight() / 720.0f), 0.2f, 1.0f);
			m_galaxyCloudPoints.SetData(renderer, m_galaxyCloudPos.size(), &m_galaxyCloudPos[0], &m_galaxyCloudDrawColor[0], modelview, ptSize);
			m_galaxyCloudPoints.Draw(renderer, m_farStarsMat.Get());
		}
	}

	// Add 3D interior glow for visible Faction Bubbles & Sol so regional space has warm 3D volume
	if (m_voronoiAlpha > 0.01f) {
		const float bubbleScaleFade = Clamp(1.0f - (m_zoom - 750.0f) / 1600.0f, 0.0f, 1.0f);
		const float fGlowAlpha = m_voronoiAlpha * bubbleScaleFade;
		if (fGlowAlpha > 0.01f) {
			for (const auto &site : m_factionSites) {
				if (m_hiddenFactions.find(site.faction) != m_hiddenFactions.end()) continue;
				const bool isSelected = (site.faction == m_selectedFaction);
				Color gc = site.faction->colour;
				gc.a = Uint8(Clamp((isSelected ? 75.0f : 32.0f) * fGlowAlpha, 0.0f, 255.0f));
				addGlowQuad(site.homePosLy, site.radiusLy * (isSelected ? 1.85f : 1.45f), gc);
			}
		}
	}

	if (!m_galaxyGlowVerts->IsEmpty()) {
		renderer->SetTransform(modelview);
		renderer->DrawBuffer(m_galaxyGlowVerts.get(), m_galaxyGlowMat.Get());
	}

	// 2. Render Regional 3D Star Cloud (LOD 1 - 200 to 5,000 ly)
	if (m_regionalAlpha > 0.01f) {
		const vector3f curCenterLy = m_pos * Sector::SIZE;
		if ((curCenterLy - m_lastRegionalCenterLy).Length() > 75.0f || m_regionalStarPos.empty()) {
			UpdateRegionalStarField(curCenterLy);
		}
		if (!m_regionalStarPos.empty()) {
			for (size_t i = 0; i < m_regionalStarBaseColor.size(); ++i) {
				m_regionalStarDrawColor[i] = m_regionalStarBaseColor[i];
				m_regionalStarDrawColor[i].a = Uint8(float(m_regionalStarBaseColor[i].a) * m_regionalAlpha);
			}
			const float ptSize = Clamp(0.38f * (renderer->GetWindowHeight() / 720.0f), 0.25f, 1.2f);
			m_regionalStarPoints.SetData(renderer, m_regionalStarPos.size(), &m_regionalStarPos[0], &m_regionalStarDrawColor[0], modelview, ptSize);
			m_regionalStarPoints.Draw(renderer, m_farStarsMat.Get());
		}
	}

	// 2. Build 3D Galactic Plane Grid, Range Rings, Voronoi Borders & 3D Beacons
	m_macroLineVerts->Clear();

	auto addCircleXY = [&](const vector3f &center, float radius, int segments, const Color &col) {
		for (int s = 0; s < segments; ++s) {
			const float a0 = (2.0f * float(M_PI) * float(s)) / float(segments);
			const float a1 = (2.0f * float(M_PI) * float(s + 1)) / float(segments);
			m_macroLineVerts->Add(center + vector3f(std::cos(a0) * radius, std::sin(a0) * radius, 0.0f), col);
			m_macroLineVerts->Add(center + vector3f(std::cos(a1) * radius, std::sin(a1) * radius, 0.0f), col);
		}
	};

	// A. Galactic Core Polar Coordinate Grid & Light-Year Range Rings
	if (m_macroAlpha > 0.01f) {
		const Uint8 gridAlpha = Uint8(95.0f * m_macroAlpha);
		const Uint8 solOrbitAlpha = Uint8(150.0f * m_macroAlpha);
		const Color gridCol(50, 110, 155, gridAlpha);
		const Color cardinalCol(75, 155, 210, Uint8(135.0f * m_macroAlpha));
		const Color solOrbitCol(70, 185, 220, solOrbitAlpha);

		const float coreRings[] = { 10000.0f, 20000.0f, 30000.0f, 40000.0f, 50000.0f };
		for (float r : coreRings) {
			addCircleXY(corePos, r, 128, gridCol);
		}
		// Sol's 25,000 ly Galactic Orbit Ring
		addCircleXY(corePos, 25000.0f, 144, solOrbitCol);

		// 12 Polar Radial Azimuth Spokes every 30 degrees
		for (int i = 0; i < 12; ++i) {
			const float ang = DEG2RAD(float(i * 30));
			const vector3f dir(std::cos(ang), std::sin(ang), 0.0f);
			const Color &c = (i % 3 == 0) ? cardinalCol : gridCol;
			m_macroLineVerts->Add(corePos + dir * 2500.0f, c);
			m_macroLineVerts->Add(corePos + dir * 50000.0f, c);
		}
	}

	// B. Sol / Human Bubble Range Rings (100 ly, 250 ly, 500 ly, 1000 ly, 2500 ly)
	if (m_voronoiAlpha > 0.01f) {
		const float bubbleFade = Clamp(1.0f - (m_zoom - 600.0f) / 1800.0f, 0.15f, 1.0f);
		const Uint8 bAlpha = Uint8(120.0f * m_voronoiAlpha * bubbleFade);
		const Color bubbleRingCol(65, 155, 145, bAlpha);
		const Color bubbleOuterCol(95, 200, 185, Uint8(165.0f * m_voronoiAlpha));

		addCircleXY(vector3f(0.0f), 100.0f, 64, bubbleRingCol);
		addCircleXY(vector3f(0.0f), 250.0f, 72, bubbleRingCol);
		addCircleXY(vector3f(0.0f), 500.0f, 96, bubbleOuterCol);
		if (m_macroAlpha > 0.05f) {
			addCircleXY(vector3f(0.0f), 1000.0f, 96, bubbleRingCol);
			addCircleXY(vector3f(0.0f), 2500.0f, 96, bubbleRingCol);
		}
	}

	// C. 3D Faction Territory Bubbles (Translucent Fresnel 3D Spheres + 3D Spherical Contours & Anchor Stems)
	if (m_voronoiAlpha > 0.01f) {
		const float bubbleZoomFade = Clamp(1.0f - (m_zoom - 900.0f) / 1800.0f, 0.10f, 1.0f);
		const float effBubbleAlpha = m_voronoiAlpha * bubbleZoomFade;

		// 1) Render 3D Translucent Fresnel Spheres at each faction's 3D Homeworld coordinates
		if (m_sphere && m_bubbleMat && effBubbleAlpha > 0.02f) {
			struct SortedBubble {
				const FactionSite *site;
				float eyeZ;
			};
			std::vector<SortedBubble> sortedBubbles;
			sortedBubbles.reserve(m_factionSites.size());
			for (const auto &site : m_factionSites) {
				if (m_hiddenFactions.find(site.faction) != m_hiddenFactions.end()) continue;
				const vector3f eyePos = modelview * site.homePosLy;
				sortedBubbles.push_back({ &site, eyePos.z });
			}
			// Sort back-to-front in camera space (more negative Z is farther from camera)
			std::sort(sortedBubbles.begin(), sortedBubbles.end(), [](const SortedBubble &a, const SortedBubble &b) {
				return a.eyeZ < b.eyeZ;
			});

			for (const auto &sb : sortedBubbles) {
				const FactionSite &site = *sb.site;
				const bool isSelected = (site.faction == m_selectedFaction);
				const bool isMajor = (site.faction->name == "Solar Federation" ||
					site.faction->name == "Commonwealth of Independent Worlds" ||
					site.faction->name == "Haber Corporation");

				const matrix4x4f bubbleTrans = modelview * matrix4x4f::Translation(site.homePosLy) * matrix4x4f::ScaleMatrix(site.radiusLy);
				renderer->SetTransform(bubbleTrans);

				Color bCol = site.faction->colour;
				if (isSelected) {
					bCol.r = Uint8(std::min(255, int(bCol.r) + 50));
					bCol.g = Uint8(std::min(255, int(bCol.g) + 50));
					bCol.b = Uint8(std::min(255, int(bCol.b) + 50));
					bCol.a = Uint8(Clamp(225.0f * effBubbleAlpha, 0.0f, 255.0f));
				} else if (isMajor) {
					bCol.a = Uint8(Clamp(165.0f * effBubbleAlpha, 0.0f, 255.0f));
				} else {
					bCol.a = Uint8(Clamp(120.0f * effBubbleAlpha, 0.0f, 255.0f));
				}

				m_bubbleMat->diffuse = bCol;
				m_sphere->Draw(renderer, m_bubbleMat.Get());

				// Additive rim glow pass for selected or major superpower bubbles
				if (m_bubbleGlowMat && (isSelected || isMajor)) {
					Color gCol = bCol;
					gCol.a = Uint8(Clamp((isSelected ? 150.0f : 65.0f) * effBubbleAlpha, 0.0f, 255.0f));
					m_bubbleGlowMat->diffuse = gCol;
					m_sphere->Draw(renderer, m_bubbleGlowMat.Get());
				}
			}
		}

		// 2) Render 3D Spherical Bubble Contours & 3D Intersection Rings
		for (const auto &edge : m_voronoiEdges) {
			if (m_hiddenFactions.find(edge.factionA) != m_hiddenFactions.end()) continue;
			if (edge.factionB && m_hiddenFactions.find(edge.factionB) != m_hiddenFactions.end()) continue;

			const bool isSelected = (m_selectedFaction != nullptr) &&
				(edge.factionA == m_selectedFaction || edge.factionB == m_selectedFaction);
			const bool isIntersection = (edge.factionB != nullptr);

			Color col = edge.factionA->colour;
			if (isIntersection && !isSelected) {
				col.r = Uint8((int(edge.factionA->colour.r) + int(edge.factionB->colour.r)) / 2);
				col.g = Uint8((int(edge.factionA->colour.g) + int(edge.factionB->colour.g)) / 2);
				col.b = Uint8((int(edge.factionA->colour.b) + int(edge.factionB->colour.b)) / 2);
			}
			if (isSelected) {
				col = m_selectedFaction->colour;
				col.r = Uint8(std::min(255, int(col.r) + 65));
				col.g = Uint8(std::min(255, int(col.g) + 65));
				col.b = Uint8(std::min(255, int(col.b) + 65));
				col.a = Uint8(Clamp((isIntersection ? 255.0f : 220.0f) * effBubbleAlpha, 0.0f, 255.0f));
			} else {
				col.a = Uint8(Clamp((isIntersection ? 195.0f : 125.0f) * effBubbleAlpha, 0.0f, 255.0f));
			}

			m_macroLineVerts->Add(edge.p0, col);
			m_macroLineVerts->Add(edge.p1, col);
		}

		// 3) Draw 3D vertical reference stems from faction bubble centers to the Z=0 galactic plane
		for (const auto &site : m_factionSites) {
			if (m_hiddenFactions.find(site.faction) != m_hiddenFactions.end()) continue;
			const bool isSelected = (site.faction == m_selectedFaction);
			const bool isMajor = (site.faction->name == "Solar Federation" ||
				site.faction->name == "Commonwealth of Independent Worlds" ||
				site.faction->name == "Haber Corporation");
			if (!isSelected && !isMajor && std::fabs(site.homePosLy.z) < 15.0f) continue;

			Color hCol = site.faction->colour;
			hCol.a = Uint8(Clamp((isSelected ? 235.0f : (isMajor ? 140.0f : 65.0f)) * effBubbleAlpha, 0.0f, 255.0f));
			const vector3f planePt(site.homePosLy.x, site.homePosLy.y, 0.0f);
			m_macroLineVerts->Add(planePt, hCol);
			m_macroLineVerts->Add(site.homePosLy, hCol);
			if (isSelected || isMajor) {
				const float rRet = std::max(6.0f, m_zoom * (isSelected ? 0.12f : 0.07f));
				addCircleXY(planePt, rRet, 24, hCol);
			}
		}
	}

	// D. 3D Scale-Adaptive Reticles & Stems for Player ("YOU ARE HERE"), Sol, and Selected System
	if (m_voronoiAlpha > 0.01f) {
		const float markerScale = std::max(4.0f, m_zoom * 0.14f);
		const Color playerCol(65, 225, 255, Uint8(245.0f * m_voronoiAlpha));
		const vector3f playerPlane(m_playerPosLy.x, m_playerPosLy.y, 0.0f);

		// Vertical stem from galactic plane to player's 3D position + elevated beacon stem
		const float beaconHeight = std::max(20.0f, m_zoom * 0.35f);
		m_macroLineVerts->Add(playerPlane, playerCol);
		m_macroLineVerts->Add(m_playerPosLy + vector3f(0.0f, 0.0f, beaconHeight), playerCol);

		// Concentric reticle rings on the galactic plane around Player position
		addCircleXY(playerPlane, markerScale, 32, playerCol);
		addCircleXY(playerPlane, markerScale * 1.8f, 32, Color(65, 225, 255, Uint8(140.0f * m_voronoiAlpha)));

		if (m_hasSelectedMarker && (m_selectedPosLy - m_playerPosLy).Length() > 1.0f) {
			const Color selCol(80, 255, 130, Uint8(220.0f * m_voronoiAlpha));
			const vector3f selPlane(m_selectedPosLy.x, m_selectedPosLy.y, 0.0f);
			m_macroLineVerts->Add(selPlane, selCol);
			m_macroLineVerts->Add(m_selectedPosLy + vector3f(0.0f, 0.0f, beaconHeight * 0.75f), selCol);
			addCircleXY(selPlane, markerScale * 0.85f, 24, selCol);
			// Direct navigation line from Player to Selected target
			m_macroLineVerts->Add(m_playerPosLy, playerCol);
			m_macroLineVerts->Add(m_selectedPosLy, selCol);
		}
	}

	if (!m_macroLineVerts->IsEmpty()) {
		renderer->SetTransform(modelview);
		m_macroLines.SetData(m_macroLineVerts->GetNumVerts(), &m_macroLineVerts->position[0], &m_macroLineVerts->diffuse[0]);
		m_macroLines.Draw(renderer, m_lineMat.Get());
	}

	PutMacroLabels(modelview);
}

void SectorMap::PutMacroLabels(const matrix4x4f &modelview)
{
	PROFILE_SCOPED()
	if (m_voronoiAlpha < 0.25f) return;

	auto &renderer = m_context.renderer;
	renderer->SetTransform(modelview);

	auto addMarker = [&](const vector3f &worldPosLy, const Color &col, const std::string &title, const std::string &subtitle, float radius, const Faction *fac = nullptr) {
		vector3d sp = Graphics::ProjectToScreen(renderer, vector3d(worldPosLy));
		if (sp.z < 0.0 && sp.x >= -100.0 && sp.x <= m_size.x + 100.0 && sp.y >= -100.0 && sp.y <= m_size.y + 100.0) {
			sp.y = m_size.y - sp.y;
			m_labels.array.emplace_back(std::make_unique<MacroMarkerLabel>(
				m_labels, vector3f(sp), col, title, subtitle, radius, worldPosLy, fac));
		}
	};

	const Uint8 alpha = Uint8(Clamp(m_voronoiAlpha * 255.0f, 0.0f, 255.0f));
	const float distPlayerToSol = m_playerPosLy.Length();

	// 1. YOU ARE HERE (Player Marker)
	char coordBuf[96];
	snprintf(coordBuf, sizeof(coordBuf), "Sol Dist: %.0f ly  |  XYZ: (%.0f, %.0f, %.0f)",
		distPlayerToSol, m_playerPosLy.x, m_playerPosLy.y, m_playerPosLy.z);
	if (distPlayerToSol < 4.0f) {
		addMarker(m_playerPosLy, Color(75, 230, 255, alpha), "YOU ARE HERE [SOL]", coordBuf, 9.0f);
	} else {
		addMarker(m_playerPosLy, Color(75, 230, 255, alpha), "YOU ARE HERE", coordBuf, 9.0f);
		if (m_zoom > 18.0f) {
			addMarker(vector3f(0.0f, 0.0f, 0.0f), Color(255, 215, 95, alpha), "SOL [EARTH / MARS]", "Humanity Birthplace (0, 0, 0)", 7.5f);
		}
	}

	// 2. SAGITTARIUS A* (Galactic Core)
	if (m_macroAlpha > 0.15f) {
		const vector3f corePos = GetGalacticCorePositionLy();
		const float distToCore = (m_playerPosLy - corePos).Length();
		char coreBuf[96];
		snprintf(coreBuf, sizeof(coreBuf), "Galactic Center  |  %.0f ly from Ship", distToCore);
		const Uint8 coreAlpha = Uint8(Clamp(m_macroAlpha * 255.0f, 0.0f, 255.0f));
		addMarker(corePos, Color(255, 205, 115, coreAlpha), "SAGITTARIUS A*", coreBuf, 10.0f);
	}

	// 3. Major Superpowers & Selected Faction Labels at Bubble/Regional Scale
	if (m_zoom < 600.0f) {
		for (const auto &site : m_factionSites) {
			const Faction *f = site.faction;
			if (m_hiddenFactions.find(f) != m_hiddenFactions.end()) continue;

			const bool isSelected = (f == m_selectedFaction);
			const bool isMajor = (f->name == "Solar Federation" ||
				f->name == "Commonwealth of Independent Worlds" ||
				f->name == "Haber Corporation");

			if (!isSelected && !isMajor) continue;
			// Avoid overlapping YOU ARE HERE right on Sol unless specifically selected
			if (!isSelected && (site.homePosLy - m_playerPosLy).Length() < m_zoom * 0.45f) continue;

			Color fCol = f->colour;
			fCol.a = alpha;
			std::string sub = isSelected ? "Selected Faction Territory" : f->description_short;
			addMarker(site.homePosLy, fCol, f->name, sub, isSelected ? 8.5f : 6.5f, f);
		}
	}
}

void SectorMap::HandleMacroClick(const ImVec2 &mpos)
{
	if (m_size.x <= 1.0f || m_size.y <= 1.0f) return;

	const float aspect = m_size.x / m_size.y;
	const float tanHalfFov = std::tan(DEG2RAD(20.0f)); // 40 deg vertical FOV
	const float ndcX = (2.0f * mpos.x) / m_size.x - 1.0f;
	const float ndcY = 1.0f - (2.0f * mpos.y) / m_size.y;

	vector3f rayCam(ndcX * aspect * tanHalfFov, ndcY * tanHalfFov, -1.0f);
	rayCam = rayCam.Normalized();

	const float camDist = 10.0f + 10.0f * m_zoom;
	matrix4x4f invRot = matrix4x4f::Identity;
	invRot.Rotate(DEG2RAD(-m_rotZ), 0.0f, 0.0f, 1.0f);
	invRot.Rotate(DEG2RAD(-m_rotX), 1.0f, 0.0f, 0.0f);

	const vector3f targetLy = m_pos * Sector::SIZE;
	const vector3f camOriginLy = targetLy + invRot * vector3f(0.0f, 0.0f, camDist);
	const vector3f rayDirLy = (invRot * rayCam).Normalized();

	// 1. Raycast against 3D Faction Bubbles in 3D space when viewing regional/bubble scale
	if (m_zoom < 1200.0f && !m_factionSites.empty()) {
		const FactionSite *bestSite = nullptr;
		float bestT = FLT_MAX;

		for (const auto &site : m_factionSites) {
			if (m_hiddenFactions.find(site.faction) != m_hiddenFactions.end()) continue;
			const vector3f oc = camOriginLy - site.homePosLy;
			const float b = oc.Dot(rayDirLy);
			const float c = oc.Dot(oc) - site.radiusLy * site.radiusLy;
			const float disc = b * b - c;
			if (disc < 0.0f) continue;

			const float sqrtDisc = std::sqrt(disc);
			float tHit = -b - sqrtDisc;
			if (tHit <= 0.0f) tHit = -b + sqrtDisc;
			if (tHit > 0.0f && tHit < bestT) {
				// Check if the 3D entry point is actually claimed by a closer overlapping bubble
				const vector3f hitPt = camOriginLy + rayDirLy * tHit;
				const Faction *owner = GetFactionAtPositionLy(hitPt);
				if (owner == site.faction) {
					bestT = tHit;
					bestSite = &site;
				}
			}
		}

		if (bestSite) {
			m_selectedFaction = bestSite->faction;
			GotoPositionLy(bestSite->homePosLy);
			return;
		}
	}

	// 2. Fallback: Raycast onto the Z=0 Galactic Plane
	if (std::fabs(rayDirLy.z) < 1e-4f) return;
	const float t = -camOriginLy.z / rayDirLy.z;
	if (t <= 0.0f) return;

	const vector3f hitLy = camOriginLy + rayDirLy * t;
	const vector3f corePos = GetGalacticCorePositionLy();
	const float maxGalDist = GetGalaxyRadiusLy() * 1.15f;
	if ((hitLy - corePos).Length() > maxGalDist) return;

	const Faction *clickedFaction = GetFactionAtPositionLy(hitLy);
	if (clickedFaction && clickedFaction->hasHomeworld) {
		m_selectedFaction = clickedFaction;
	} else {
		m_selectedFaction = nullptr;
	}

	GotoPositionLy(vector3f(hitLy.x, hitLy.y, 0.0f));
}

// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef _SECTORMAP_H
#define _SECTORMAP_H

#include "Color.h"
#include "DeleteEmitter.h"
#include "Input.h"
#include "RefCounted.h"
#include "galaxy/Factions.h"
#include "galaxy/Sector.h"
#include "galaxy/SystemPath.h"
#include "graphics/Drawables.h"
#include "imgui/imgui.h"
#include "imgui/imgui_internal.h"
#include "SectorMapContext.h"
#include <map>
#include <string>

namespace Graphics {
	class RenderTarget;
}

class SectorMap : public DeleteEmitter {
public:

	SectorMap(SectorMapContext &&context);
	SectorMap(const Json &jsonObj, SectorMapContext &&context);
	~SectorMap();

	void Update(float frameTime);
	void Draw3D();
	void DrawLabels(bool interactive, const ImVec2 &imagePos = { 0.0, 0.0 });
	void DrawEmbed();

	vector3f GetPosition() const { return m_pos; }
	vector3f GetSystemPosition(const SystemPath &path);
	double GetZoomLevel() const;
	RefCountedPtr<Sector> GetCached(const SystemPath &loc) { return m_sectorCache->GetCached(loc); }
	bool IsCenteredOn(const SystemPath &path);
	bool IsManualMove() { return m_manualMove; }
	SystemPath NearestSystemToPos(const vector3f &pos);
	matrix4x4f PointOfView();
	SectorMapContext &GetContext() { return m_context; }

	void SetDrawUninhabitedLabels(bool value) { m_drawUninhabitedLabels = value; }
	void SetDrawVerticalLines(bool value) { m_drawVerticalLines = value; }
	void SetDrawUnchartedOverlay(bool value)
	{
		if (m_drawUnchartedOverlay != value) {
			m_drawUnchartedOverlay = value;
			m_toggledFaction = true;
		}
	}
	bool GetDrawUnchartedOverlay() const { return m_drawUnchartedOverlay; }
	void SetDrawConflictOverlay(bool value)
	{
		if (m_drawConflictOverlay != value) {
			m_drawConflictOverlay = value;
			m_toggledFaction = true;
		}
	}
	bool GetDrawConflictOverlay() const { return m_drawConflictOverlay; }
	void SetConflictSystem(const std::string &sysName, int type)
	{
		m_conflictSystems[sysName] = type;
		m_toggledFaction = true;
	}
	void ClearConflictSystems()
	{
		m_conflictSystems.clear();
		m_toggledFaction = true;
	}
	void SetVisibleSphereScale(float scale)
	{
		scale = std::clamp(scale, 0.35f, 1.0f);
		if (std::fabs(m_visibleSphereScale - scale) > 0.01f) {
			m_visibleSphereScale = scale;
			m_toggledFaction = true;
		}
	}
	float GetVisibleSphereScale() const { return m_visibleSphereScale; }
	void SetFactionVisible(const Faction *faction, bool visible);
	void SetZoomMode(bool enable);
	void SetRotateMode(bool enable);
	void SetLabelParams(std::string fontName, int fontSize, float gap, Color highlight, Color shade);
	void SetLabelsVisibility(bool hideLabels) { m_hideLabels = hideLabels; }
	void GotoSector(const SystemPath &path);
	void GotoSystem(const SystemPath &path);
	void GotoPositionLy(const vector3f &posLy);
	void GotoSol();
	void GotoGalacticCore();
	void SetMacroZoom(float zoom);
	float GetMacroZoom() const { return m_zoom; }
	float GetMacroAlpha() const { return m_macroAlpha; }
	float GetVoronoiAlpha() const { return m_voronoiAlpha; }
	vector3f GetPositionLy() const;
	vector3f GetPlayerPositionLy() const { return m_playerPosLy; }
	vector3f GetGalacticCorePositionLy() const;
	float GetGalaxyRadiusLy() const;
	const Faction *GetSelectedFaction() const { return m_selectedFaction; }
	void SetSelectedFaction(const Faction *faction) { m_selectedFaction = faction; }
	const Faction *GetFactionAtPositionLy(const vector3f &posLy) const;
	void SetMacroMarkers(const vector3f &playerPosLy, const vector3f &selectedPosLy, bool hasSelected);
	void ZoomIn();
	void ZoomOut();
	void ResetView();
	void ReleaseMouseCapture();

	void CreateRenderTarget();
	void SetSize(vector2d size);
	void SaveToJson(Json &jsonObj);

	// creating objects on the map
	void AddStarBillboard(const matrix4x4f &modelview, const vector3f &pos, const Color &col, float size);
	void AddSphere(const matrix4x4f &trans, const Color &color = Color::WHITE);
	void AddLineVert(const vector3f &v, const Color &c);
	// lines are not automatically cleared every frame
	void ClearLineVerts();

	std::vector<SystemPath> GetNearbyStarSystemsByName(std::string pattern);
	const std::set<const Faction *> &GetVisibleFactions() { return m_visibleFactions; }
	const std::set<const Faction *> &GetHiddenFactions() { return m_hiddenFactions; }

	struct InputBinding : public Input::InputFrame {
		using InputFrame::InputFrame;

		Action *mapToggleSelectionFollowView;
		Action *mapWarpToCurrent;
		Action *mapWarpToSelected;
		Action *mapViewReset;

		Axis *mapViewMoveForward;
		Axis *mapViewMoveLeft;
		Axis *mapViewMoveUp;
		Axis *mapViewYaw;
		Axis *mapViewPitch;
		Axis *mapViewZoom;

		void RegisterBindings() override;
	} InputBindings;

private:
	void InitDefaults();
	void InitObject();

	void DrawNearSectors(const matrix4x4f &modelview);
	void DrawNearSector(const int sx, const int sy, const int sz, const matrix4x4f &trans);
	void DrawLabelsInternal(bool interactive, const ImVec2 &imagePos = { 0.0, 0.0 });
	void PutSystemLabels(RefCountedPtr<Sector> sec, const vector3f &origin, int drawRadius);
	void PutSystemLabel(const Sector::System &sys, bool shadow);

	void DrawFarSectors(const matrix4x4f &modelview);
	void BuildFarSector(RefCountedPtr<Sector> sec, const vector3f &origin, std::vector<vector3f> &points, std::vector<Color> &colors);
	void PutFactionLabels(const vector3f &secPos);

	void InitMacroGalaxy();
	void DrawMacroGalaxy(const matrix4x4f &modelview);
	void PutMacroLabels(const matrix4x4f &modelview);
	void HandleMacroClick(const ImVec2 &mpos);

	void OnClickLabel(const SystemPath &path);

	void ShrinkCache();
	void SetSelected(const SystemPath &path);

	void MouseWheel(bool up);

	SectorMapContext m_context;

	vector3f m_pos;
	vector3f m_posMovingTo;

	float m_rotXDefault, m_rotZDefault, m_zoomDefault;

	float m_rotX, m_rotZ;
	float m_rotXMovingTo, m_rotZMovingTo;

	float m_zoom;
	float m_zoomClamped;
	float m_zoomMovingTo;

	bool m_rotateWithMouseButton = false;
	bool m_panWithMouseButton = false;
	bool m_rotateView = false;
	bool m_zoomView = false;
	bool m_manualMove = false;

	bool m_drawUninhabitedLabels = false;
	bool m_drawUnchartedOverlay = false;
	bool m_drawConflictOverlay = false;
	std::map<std::string, int> m_conflictSystems;
	float m_visibleSphereScale = 0.75f;
	bool m_drawVerticalLines = false;

	std::set<const Faction *> m_visibleFactions;
	std::set<const Faction *> m_hiddenFactions;

	Uint8 m_detailBoxVisible;

	sigc::connection m_onToggleSelectionFollowView;
	sigc::connection m_onWarpToSelected;
	sigc::connection m_onViewReset;

	RefCountedPtr<SectorCache::Slave> m_sectorCache;

	std::vector<vector3f> m_farstars;
	std::vector<Color> m_farstarsColor;
	std::vector<Color> m_farstarsDrawColor;

	vector3f m_secPosFar;
	int m_radiusFar;
	bool m_toggledFaction;

	int m_cacheXMin;
	int m_cacheXMax;
	int m_cacheYMin;
	int m_cacheYMax;
	int m_cacheZMin;
	int m_cacheZMax;

	std::unique_ptr<ImDrawList> m_drawList;
	std::unique_ptr<Graphics::RenderTarget> m_renderTarget;
	ImVec2 m_size;
	bool m_needsResize;

	std::unique_ptr<Graphics::VertexArray> m_lineVerts;
	std::unique_ptr<Graphics::VertexArray> m_secLineVerts;
	std::unique_ptr<Graphics::VertexArray> m_starVerts;
	std::unique_ptr<Graphics::VertexArray> m_customLineVerts;
	bool m_updateCustomLines = false;

	RefCountedPtr<Graphics::Material> m_starMaterial;
	RefCountedPtr<Graphics::Material> m_fresnelMat;
	RefCountedPtr<Graphics::Material> m_bubbleMat;
	RefCountedPtr<Graphics::Material> m_bubbleGlowMat;
	RefCountedPtr<Graphics::Material> m_lineMat;
	RefCountedPtr<Graphics::Material> m_farStarsMat;

	Graphics::Drawables::Lines m_lines;
	Graphics::Drawables::Lines m_customlines;
	Graphics::Drawables::Lines m_sectorlines;
	Graphics::Drawables::Points m_farstarsPoints;

	struct SphereParam {
		matrix4x4f trans;
		Color color;
	};
	std::vector<SphereParam> m_sphereParams;
	std::unique_ptr<Graphics::Drawables::Sphere3D> m_sphere;

	class Label;
	class StarLabel;
	class FactionLabel;
	class MacroMarkerLabel;
	struct Labels {
		// the constructor can only be defined after defining the Label class
		Labels(SectorMap &map);
		// settings and globals for labels
		// this is not hardcode, these are the defaults
		std::string fontName = "sector-map";
		int fontSize = 15;
		float gap = 2.f;
		ImFont *starLabelFont = nullptr;
		ImFont *factionHomeFont = nullptr;
		ImFont *factionNameFont = nullptr;
		ImRect starLabelHoverArea;
		ImRect factionHomeHoverArea;
		ImRect factionNameHoverArea;
		ImU32 highlightColor = IM_COL32(255, 255, 255, 100);
		ImU32 shadeColor = IM_COL32(25, 51, 82, 200);
		// owning object
		SectorMap &map;
		// array
		std::vector<std::unique_ptr<Label>> array;
	};
	Labels m_labels;
	bool m_hideLabels = false;

	// Macro Galactic View state & geometry
	bool m_macroInitialized = false;
	float m_macroAlpha = 0.0f;
	float m_voronoiAlpha = 0.0f;
	vector3f m_playerPosLy = vector3f(0.0f);
	vector3f m_selectedPosLy = vector3f(0.0f);
	bool m_hasSelectedMarker = false;
	const Faction *m_selectedFaction = nullptr;

	struct VoronoiEdge {
		vector3f p0;
		vector3f p1;
		const Faction *factionA;
		const Faction *factionB;
	};
	struct FactionSite {
		const Faction *faction;
		vector3f homePosLy;
		float radiusLy;
	};
	struct GlowBillboard {
		vector3f posLy;
		float radiusLy;
		Color color;
	};
	std::vector<VoronoiEdge> m_voronoiEdges;
	std::vector<FactionSite> m_factionSites;
	std::vector<GlowBillboard> m_galaxyGlowBillboards;

	std::unique_ptr<Graphics::VertexArray> m_galaxyDiscVerts;
	std::unique_ptr<Graphics::VertexArray> m_galaxyGlowVerts;
	std::unique_ptr<Graphics::VertexArray> m_macroLineVerts;
	RefCountedPtr<Graphics::Material> m_galaxyDiscMat;
	RefCountedPtr<Graphics::Material> m_galaxyGlowMat;
	RefCountedPtr<Graphics::Material> m_macroStarCloudMat;
	Graphics::Drawables::Lines m_macroLines;
	std::unique_ptr<Graphics::Drawables::PointSprites> m_galaxyCloudPoints;
	std::vector<vector3f> m_galaxyCloudPos;
	std::vector<Color> m_galaxyCloudBaseColor;

	void UpdateRegionalStarField(const vector3f &centerLy);
	std::unique_ptr<Graphics::Drawables::PointSprites> m_regionalStarPoints;
	std::vector<vector3f> m_regionalStarPos;
	std::vector<Color> m_regionalStarBaseColor;
	vector3f m_lastRegionalCenterLy{ 1e9f, 1e9f, 1e9f };
	float m_regionalAlpha = 0.0f;
};

#endif /* _SECTORMAP_H */

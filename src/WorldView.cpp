// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "WorldView.h"

#include "Frame.h"
#include "Game.h"
#include "GameConfig.h"
#include "GameSaveError.h"
#include "HudTrail.h"
#include "HyperspaceCloud.h"
#include "Input.h"
#include "Json.h"
#include "Pi.h"
#include "Player.h"
#include <SDL_keycode.h>
#include "SectorView.h"
#include "Sensors.h"
#include "SpeedLines.h"
#include "graphics/Graphics.h"
#include "graphics/Material.h"
#include "graphics/Renderer.h"
#include "graphics/RenderState.h"
#include "matrix4x4.h"
#include "MathUtil.h"
#include "Space.h"
#include "SpaceStation.h"
#include "galaxy/SystemBody.h"
#include "ship/GunManager.h"
#include "ship/ShipViewController.h"
#include "ship/SupercruiseController.h"
#include "sound/Sound.h"

WorldView::~WorldView() {}

namespace {
	static const float HUD_CROSSHAIR_SIZE = 8.0f;
	static const Color green(0, 255, 0, 204);
	static const Color red(255, 0, 0, 128);
} // namespace

REGISTER_INPUT_BINDING(WorldView)
{
	using namespace InputBindings;
	Input::BindingGroup *group = input->GetBindingPage("General")->GetBindingGroup("Miscellaneous");

	input->AddActionBinding("BindToggleHudMode", group, Action({ SDLK_TAB }));
	input->AddActionBinding("BindIncreaseTimeAcceleration", group, Action({ SDLK_PAGEUP }));
	input->AddActionBinding("BindDecreaseTimeAcceleration", group, Action({ SDLK_PAGEDOWN }));
	// universal axes for selecting an item from a radial menu
	input->AddAxisBinding("BindRadialHorizontalSelection", group, Axis({}, { SDLK_LEFT }, { SDLK_RIGHT }));
	input->AddAxisBinding("BindRadialVerticalSelection", group, Axis({}, { SDLK_UP }, { SDLK_DOWN }));
	// radial menu activators
	input->AddActionBinding("BindFlightAssistRadial", group, Action{});
	input->AddActionBinding("BindFixheadingRadial", group, Action{});
	input->AddActionBinding("BindTargetRadial", group, Action{});
}

void WorldView::InputBinding::RegisterBindings()
{
	toggleHudMode = AddAction("BindToggleHudMode");
	increaseTimeAcceleration = AddAction("BindIncreaseTimeAcceleration");
	decreaseTimeAcceleration = AddAction("BindDecreaseTimeAcceleration");
	AddAxis("BindRadialVerticalSelection");
	AddAxis("BindRadialHorizontalSelection");
	AddAction("BindFlightAssistRadial");
	AddAction("BindFixheadingRadial");
	AddAction("BindTargetRadial");
}

WorldView::WorldView(Game *game) :
	View("WorldView"),
	m_game(game),
	InputBindings(Pi::input)
{
	InitObject();
}

WorldView::WorldView(const Json &jsonObj, Game *game) :
	View("WorldView"),
	m_game(game),
	InputBindings(Pi::input)
{
	if (!jsonObj["world_view"].is_object()) throw SavedGameCorruptException();
	Json worldViewObj = jsonObj["world_view"];

	InitObject();

	shipView->LoadFromJson(worldViewObj);
}

void WorldView::InitObject()
{
	m_labelsOn = true;

	Graphics::MaterialDescriptor desc;

	Graphics::RenderStateDesc rsd;
	rsd.blendMode = Graphics::BLEND_ALPHA;
	rsd.depthWrite = false;
	rsd.depthTest = false;
	rsd.primitiveType = Graphics::LINE_SINGLE;
	m_indicatorMat.reset(Pi::renderer->CreateMaterial("vtxColor", desc, rsd, m_indicator.GetVertexFormat()));

	/*
	  NEW UI
	*/

	m_speedLines.reset(new SpeedLines(Pi::player));

	//get near & far clipping distances
	//XXX m_renderer not set yet
	float znear;
	float zfar;
	Pi::renderer->GetNearFarRange(znear, zfar);

	const float fovY = Pi::config->Float("FOVVertical");

	m_cameraContext.Reset(new CameraContext(Pi::renderer->GetWindowWidth(), Pi::renderer->GetWindowHeight(), fovY, znear, zfar));
	m_camera.reset(new Camera(m_cameraContext, Pi::renderer));

	InputBindings.RegisterBindings();
	shipView.reset(new ShipViewController(this));
	shipView->Init();
	SetViewController(shipView.get());

	m_onToggleHudModeCon = InputBindings.toggleHudMode->onPressed.connect(sigc::mem_fun(this, &WorldView::OnToggleLabels));
	m_onIncTimeAccelCon = InputBindings.increaseTimeAcceleration->onPressed.connect(sigc::mem_fun(this, &WorldView::OnRequestTimeAccelInc));
	m_onDecTimeAccelCon = InputBindings.decreaseTimeAcceleration->onPressed.connect(sigc::mem_fun(this, &WorldView::OnRequestTimeAccelDec));
}


void WorldView::SaveToJson(Json &jsonObj)
{
	Json worldViewObj = Json::object(); // Create JSON object to contain world view data.

	shipView->SaveToJson(worldViewObj);

	jsonObj["world_view"] = worldViewObj; // Add world view object to supplied object.
}

void WorldView::OnRequestTimeAccelInc()
{
	// requests an increase in time acceleration
	Pi::game->RequestTimeAccelInc();
}

void WorldView::OnRequestTimeAccelDec()
{
	// requests a decrease in time acceleration
	Pi::game->RequestTimeAccelDec();
}

void WorldView::SetViewController(ViewController *newView)
{
	m_viewController = newView;
}

void WorldView::Draw3D()
{
	PROFILE_SCOPED()
	assert(m_game);
	assert(Pi::player);
	assert(!Pi::player->IsDead());

	m_cameraContext->ApplyDrawTransforms(m_renderer);

	m_camera->Draw();

	// NB: Do any screen space rendering after here:
	// Things like the cockpit and AR features like hudtrails, space dust etc.
	m_viewController->Draw(m_camera.get());

	// Draw 3D HUD
	// Speed lines
	if (Pi::AreSpeedLinesDisplayed())
		m_speedLines->Render(m_renderer);

	// Contact trails
	if (Pi::AreHudTrailsDisplayed()) {
		for (auto it = Pi::player->GetSensors()->GetContacts().begin(); it != Pi::player->GetSensors()->GetContacts().end(); ++it)
			it->trail->Render(m_renderer);
	}

	// don't draw crosshairs etc in hyperspace
	if (Pi::player->GetFlightState() == Ship::HYPERSPACE) {
		m_cameraContext->EndFrame();
		return;
	}

	// setup orthographic projection the indicator coordinate system expects
	// (could also draw this using ImGui methods in DrawPiGui, but this is a quick patch for release)
	m_renderer->SetProjection(matrix4x4f::OrthoFrustum(0, m_renderer->GetWindowWidth(), m_renderer->GetWindowHeight(), 0, 0, 1));
	m_renderer->SetTransform(matrix4x4f::Identity);

	// Supercruise 3D HUD overlays (orbital path lines & body exclusion zone rings)
	DrawSupercruiseOverlays();

	m_cameraContext->EndFrame();

	// combat target indicator
	DrawCombatTargetIndicator(m_combatTargetIndicator, m_targetLeadIndicator, red);
}

void WorldView::OnToggleLabels()
{
	if (Pi::GetView() == this) {
		if (Pi::DrawGUI && m_labelsOn) {
			m_labelsOn = false;
		} else if (Pi::DrawGUI && !m_labelsOn) {
			Pi::DrawGUI = false;
		} else if (!Pi::DrawGUI) {
			Pi::DrawGUI = true;
			m_labelsOn = true;
		}
	}
}

void WorldView::Update()
{
	PROFILE_SCOPED()
	assert(m_game);
	assert(Pi::player);
	assert(!Pi::player->IsDead());

	m_viewController->Update();

	m_cameraContext->BeginFrame();
	m_camera->Update();

	UpdateProjectedObjects();

	FrameId playerFrameId = Pi::player->GetFrame();
	FrameId camFrameId = m_cameraContext->GetTempFrame();

	//speedlines and contact trails need camFrame for transform, so they must be updated here
	if (m_speedLines.get() && Pi::AreSpeedLinesDisplayed()) {
		m_speedLines->Update(m_game->GetTimeStep());

		matrix4x4d trans;
		Frame::GetFrameTransform(playerFrameId, camFrameId, trans);
		trans[12] = trans[13] = trans[14] = 0.0;
		trans[15] = 1.0;
		m_speedLines->SetTransform(trans);
	}

	if (Pi::AreHudTrailsDisplayed()) {
		matrix4x4d trans;
		// HudTrail stores its points in the non-rotating frame, so the display transform must be built from that same frame.
		FrameId nonRotFrameId = Frame::GetFrame(playerFrameId)->GetNonRotFrame();
		Frame::GetFrameTransform(nonRotFrameId, camFrameId, trans);

		for (auto it = Pi::player->GetSensors()->GetContacts().begin(); it != Pi::player->GetSensors()->GetContacts().end(); ++it)
			it->trail->SetTransform(trans);
	} else {
		for (auto it = Pi::player->GetSensors()->GetContacts().begin(); it != Pi::player->GetSensors()->GetContacts().end(); ++it)
			it->trail->Reset(playerFrameId);
	}
}

void WorldView::OnSwitchTo()
{
	if (m_viewController)
		m_viewController->Activated();
	Pi::input->AddInputFrame(&InputBindings);
}

void WorldView::OnSwitchFrom()
{
	if (m_viewController)
		m_viewController->Deactivated();
	Pi::input->RemoveInputFrame(&InputBindings);
	Pi::DrawGUI = true;
}

int WorldView::GetActiveWeapon() const
{
	using CamType = ShipViewController::CamType;
	switch (shipView->GetCamType()) {
	case CamType::CAM_INTERNAL:
		return shipView->m_internalCameraController->GetMode() == InternalCameraController::MODE_REAR ? 1 : 0;

	case CamType::CAM_EXTERNAL:
	case CamType::CAM_SIDEREAL:
	case CamType::CAM_FLYBY:
	default:
		return 0;
	}
}

void WorldView::UpdateProjectedObjects()
{
	const Frame *cam_frame = Frame::GetFrame(m_cameraContext->GetTempFrame());
	matrix3x3d cam_rot = cam_frame->GetOrient().Inverse() * Pi::player->GetOrient();

	// later we might want non-ship enemies (e.g., for assaults on military bases)
	assert(!Pi::player->GetCombatTarget() || Pi::player->GetCombatTarget()->IsType(ObjectType::SHIP) || Pi::player->GetCombatTarget()->IsType(ObjectType::MISSILE));

	// update combat HUD
	Ship *enemy = static_cast<Ship *>(Pi::player->GetCombatTarget());
	if (enemy) {
		const vector3d targScreenPos = enemy->GetInterpPositionRelTo(cam_frame->GetId());

		UpdateIndicator(m_combatTargetIndicator, targScreenPos);

		// calculate firing solution and relative velocity along our z axis
		int laser = -1;
		if (shipView->GetCamType() == ShipViewController::CAM_INTERNAL) {
			switch (shipView->m_internalCameraController->GetMode()) {
			case InternalCameraController::MODE_FRONT: laser = 0; break;
			case InternalCameraController::MODE_REAR: laser = 1; break;
			default: break;
			}
		}

		GunManager *gunManager = Pi::player->GetComponent<GunManager>();
		if (laser >= 0 && laser < gunManager->GetWeaponGroups().size()) {
			const auto &group = gunManager->GetWeaponGroups()[laser];

			if (gunManager->GetGroupTarget(laser)) {
				UpdateIndicator(m_targetLeadIndicator, cam_rot * gunManager->GetGroupLeadPos(laser));
				if ((m_targetLeadIndicator.side != INDICATOR_ONSCREEN) || (m_combatTargetIndicator.side != INDICATOR_ONSCREEN))
					HideIndicator(m_targetLeadIndicator);
			} else {
				HideIndicator(m_targetLeadIndicator);
			}
		} else {
			HideIndicator(m_targetLeadIndicator);
		}
	} else {
		HideIndicator(m_combatTargetIndicator);
		HideIndicator(m_targetLeadIndicator);
	}
}

void WorldView::UpdateIndicator(Indicator &indicator, const vector3d &cameraSpacePos)
{
	const float BORDER = 10.0;
	const float BORDER_BOTTOM = 90.0;
	// XXX BORDER_BOTTOM is 10+the control panel height and shouldn't be needed at all

	const float w = m_cameraContext->GetWidth();
	const float h = m_cameraContext->GetHeight();

	if (cameraSpacePos.LengthSqr() < 1e-6) { // length < 1e-3
		indicator.pos.x = w / 2.0f;
		indicator.pos.y = h / 2.0f;
		indicator.side = INDICATOR_ONSCREEN;
		return;
	}

	vector3f screenPos = Graphics::ProjectToScreen(vector3f(cameraSpacePos), m_cameraContext->GetProjectionMatrix());
	vector3f proj = vector3f(screenPos.x * w, h - screenPos.y * h, screenPos.z);

	indicator.realpos.x = int(proj.x);
	indicator.realpos.y = int(proj.y);

	bool onscreen =
		(cameraSpacePos.z < 0.0) &&
		(proj.x >= BORDER) && (proj.x < w - BORDER) &&
		(proj.y >= BORDER) && (proj.y < h - BORDER_BOTTOM);

	if (onscreen) {
		indicator.pos.x = int(proj.x);
		indicator.pos.y = int(proj.y);
		indicator.side = INDICATOR_ONSCREEN;
	} else {
		// homogeneous 2D points and lines are really useful
		const vector3d ptCentre(w / 2.0, h / 2.0, 1.0);
		const vector3d ptProj(proj.x, proj.y, 1.0);
		const vector3d lnDir = ptProj.Cross(ptCentre);

		indicator.side = INDICATOR_TOP;

		// this fallback is used if direction is close to (0, 0, +ve)
		indicator.pos.x = w / 2.0;
		indicator.pos.y = BORDER;

		if (cameraSpacePos.x < -1e-3) {
			vector3d ptLeft = lnDir.Cross(vector3d(-1.0, 0.0, BORDER));
			ptLeft /= ptLeft.z;
			if (ptLeft.y >= BORDER && ptLeft.y < h - BORDER_BOTTOM) {
				indicator.pos.x = ptLeft.x;
				indicator.pos.y = ptLeft.y;
				indicator.side = INDICATOR_LEFT;
			}
		} else if (cameraSpacePos.x > 1e-3) {
			vector3d ptRight = lnDir.Cross(vector3d(-1.0, 0.0, w - BORDER));
			ptRight /= ptRight.z;
			if (ptRight.y >= BORDER && ptRight.y < h - BORDER_BOTTOM) {
				indicator.pos.x = ptRight.x;
				indicator.pos.y = ptRight.y;
				indicator.side = INDICATOR_RIGHT;
			}
		}

		if (cameraSpacePos.y < -1e-3) {
			vector3d ptBottom = lnDir.Cross(vector3d(0.0, -1.0, h - BORDER_BOTTOM));
			ptBottom /= ptBottom.z;
			if (ptBottom.x >= BORDER && ptBottom.x < w - BORDER) {
				indicator.pos.x = ptBottom.x;
				indicator.pos.y = ptBottom.y;
				indicator.side = INDICATOR_BOTTOM;
			}
		} else if (cameraSpacePos.y > 1e-3) {
			vector3d ptTop = lnDir.Cross(vector3d(0.0, -1.0, BORDER));
			ptTop /= ptTop.z;
			if (ptTop.x >= BORDER && ptTop.x < w - BORDER) {
				indicator.pos.x = ptTop.x;
				indicator.pos.y = ptTop.y;
				indicator.side = INDICATOR_TOP;
			}
		}
	}
}

void WorldView::HideIndicator(Indicator &indicator)
{
	indicator.side = INDICATOR_HIDDEN;
	indicator.pos = vector2f(0.0f, 0.0f);
}

void WorldView::DrawCombatTargetIndicator(const Indicator &target, const Indicator &lead, const Color &c)
{
	if (target.side == INDICATOR_HIDDEN) return;

	if (target.side == INDICATOR_ONSCREEN) {
		const float x1 = target.pos.x, y1 = target.pos.y;
		const float x2 = lead.pos.x, y2 = lead.pos.y;

		float xd = x2 - x1, yd = y2 - y1;
		if (lead.side != INDICATOR_ONSCREEN) {
			xd = 1.0f;
			yd = 0.0f;
		} else {
			float len = xd * xd + yd * yd;
			if (len < 1e-6) {
				xd = 1.0f;
				yd = 0.0f;
			} else {
				len = sqrt(len);
				xd /= len;
				yd /= len;
			}
		}

		const vector3f vts[] = {
			// target crosshairs
			vector3f(x1 + 10 * xd, y1 + 10 * yd, 0.0f),
			vector3f(x1 + 20 * xd, y1 + 20 * yd, 0.0f),
			vector3f(x1 - 10 * xd, y1 - 10 * yd, 0.0f),
			vector3f(x1 - 20 * xd, y1 - 20 * yd, 0.0f),
			vector3f(x1 - 10 * yd, y1 + 10 * xd, 0.0f),
			vector3f(x1 - 20 * yd, y1 + 20 * xd, 0.0f),
			vector3f(x1 + 10 * yd, y1 - 10 * xd, 0.0f),
			vector3f(x1 + 20 * yd, y1 - 20 * xd, 0.0f),

			// lead crosshairs
			vector3f(x2 - 10 * xd, y2 - 10 * yd, 0.0f),
			vector3f(x2 + 10 * xd, y2 + 10 * yd, 0.0f),
			vector3f(x2 - 10 * yd, y2 + 10 * xd, 0.0f),
			vector3f(x2 + 10 * yd, y2 - 10 * xd, 0.0f),

			// line between crosshairs
			vector3f(x1 + 20 * xd, y1 + 20 * yd, 0.0f),
			vector3f(x2 - 10 * xd, y2 - 10 * yd, 0.0f)
		};
		if (lead.side == INDICATOR_ONSCREEN) {
			m_indicator.SetData(14, vts, c);
		} else {
			m_indicator.SetData(8, vts, c);
		}
		m_indicator.Draw(m_renderer, m_indicatorMat.get());
	} else {
		DrawEdgeMarker(target, c);
	}
}

void WorldView::DrawEdgeMarker(const Indicator &marker, const Color &c)
{
	const vector2f screenCentre(m_renderer->GetWindowWidth() / 2.0f, m_renderer->GetWindowHeight() / 2.0f);
	vector2f dir = screenCentre - marker.pos;
	float len = dir.Length();
	dir *= HUD_CROSSHAIR_SIZE / len;

	const vector3f vts[2] = {
		vector3f(marker.pos, 0.f),
		vector3f(marker.pos + dir, 0.f)
	};
	m_indicator.SetData(2, vts, c);
	m_indicator.Draw(m_renderer, m_indicatorMat.get());
}

// project vector vec onto plane (normal must be normalized)
static vector3d projectVecOntoPlane(const vector3d &vec, const vector3d &normal)
{
	return (vec - vec.Dot(normal) * normal);
}

static double wrapAngleToPositive(const double theta)
{
	return (theta >= 0.0 ? theta : M_PI * 2 + theta);
}

/*
  heading range: 0 - 359 deg
  heading  0 - north
  heading 90 - east
  pitch range: -90 - +90 deg
  pitch  0 - level with surface
  pitch 90 - up
*/
std::tuple<double, double, double> WorldView::CalculateHeadingPitchRoll(PlaneType pt)
{
	FrameId frameId = Pi::player->GetFrame();

	if (pt == ROTATIONAL)
		frameId = Frame::GetFrame(frameId)->GetRotFrame();
	else if (pt == PARENT)
		frameId = Frame::GetFrame(frameId)->GetNonRotFrame();

	// construct a frame of reference aligned with the ground plane
	// and with lines of longitude and latitude
	const vector3d up = Pi::player->GetPositionRelTo(frameId).NormalizedSafe();
	const vector3d north = projectVecOntoPlane(vector3d(0, 1, 0), up).NormalizedSafe();
	const vector3d east = north.Cross(up);

	// find the direction that the ship is facing
	const auto shpRot = Pi::player->GetOrientRelTo(frameId);
	const vector3d hed = -shpRot.VectorZ();
	const vector3d right = shpRot.VectorX();
	const vector3d groundHed = projectVecOntoPlane(hed, up).NormalizedSafe();

	const double pitch = asin(up.Dot(hed));

	const double hedNorth = groundHed.Dot(north);
	const double hedEast = groundHed.Dot(east);
	const double heading = wrapAngleToPositive(atan2(hedEast, hedNorth));
	const double roll = (acos(right.Dot(up.Cross(hed).Normalized())) - M_PI) * (right.Dot(up) >= 0 ? -1 : 1);

	return std::make_tuple(
		std::isnan(heading) ? 0.0 : heading,
		std::isnan(pitch) ? 0.0 : pitch,
		std::isnan(roll) ? 0.0 : roll);
}

// Project a point in camera space to the screen
static vector3d projectToScreenSpace(const vector3d &pos, RefCountedPtr<CameraContext> cameraContext, const bool adjustZ = true)
{
	const float h = cameraContext->GetHeight();
	const float w = cameraContext->GetWidth();

	vector3f screenPos = Graphics::ProjectToScreen(vector3f(pos), cameraContext->GetProjectionMatrix());
	vector3d proj = vector3d(screenPos.x * w, h - screenPos.y * h, screenPos.z);

	// linearize depth coordinate
	// see https://thxforthefish.com/posts/reverse_z/
	// Note this is normally -znear / proj.z, but proj.z is already negated in ProjectToScreen
	proj.z = cameraContext->GetZNear() / proj.z;

	// set z to -1 if in front of camera, 1 else
	if (adjustZ)
		proj.z = pos.z < 0 ? -1 : 1;

	return proj;
}

// project a body in world-space to a screen-space location
vector3d WorldView::WorldSpaceToScreenSpace(const Body *body) const
{
	if (body->IsType(ObjectType::PLAYER) && !shipView->IsExteriorView())
		return vector3d::Zero;

	vector3d pos = body->GetInterpPositionRelTo(m_cameraContext->GetCameraFrame());
	return WorldSpaceToScreenSpace(pos);
}

// position is relative to the parent frame of the camera
// use the Body* overload to convert from other frames' spaces
vector3d WorldView::WorldSpaceToScreenSpace(const vector3d &position) const
{
	vector3d pos = (position - m_cameraContext->GetCameraPos()) * m_cameraContext->GetCameraOrient();
	return projectToScreenSpace(pos, m_cameraContext);
}

// convert a direction in world-space coordinates to a position in screen-space coordinates
vector3d WorldView::WorldDirToScreenSpace(const vector3d &pos) const
{
	// rotate world-space coordinates into the camera frame orientation
	return projectToScreenSpace(pos * m_cameraContext->GetCameraOrient(), m_cameraContext, false);
}

vector3d WorldView::CameraSpaceToScreenSpace(const vector3d &pos) const
{
	return projectToScreenSpace(pos, m_cameraContext);
}

vector3d WorldView::GetTargetIndicatorScreenPosition(const Body *body) const
{
	if (body->IsType(ObjectType::PLAYER) && !shipView->IsExteriorView())
		return vector3d::Zero;

	// get the target indicator position in body-local coordinates
	vector3d pos = body->GetInterpPositionRelTo(m_cameraContext->GetCameraFrame());
	pos += body->GetInterpOrientRelTo(m_cameraContext->GetCameraFrame()) * body->GetTargetIndicatorPosition();
	return WorldSpaceToScreenSpace(pos);
}

void WorldView::DrawSupercruiseOverlays()
{
	if (!Pi::DrawGUI || !m_labelsOn || !Pi::player || !m_game || !m_game->GetSpace())
		return;

	const SupercruiseController *sc = Pi::player->GetSupercruise();
	const bool showOverlays = (Pi::player->GetFlightState() == Ship::SUPERCRUISE) || (sc && sc->IsCharging());
	if (!showOverlays)
		return;

	const FrameId camFrameId = m_cameraContext->GetTempFrame();
	if (!camFrameId.valid())
		return;

	const double zClip = -1.0; // camera-space near plane clip (camera looks along -Z)
	const float winW = float(m_renderer->GetWindowWidth());
	const float winH = float(m_renderer->GetWindowHeight());

	auto appendClippedSegment = [&](std::vector<vector3f> &verts, vector3d p0, vector3d p1) {
		if (p0.z > zClip && p1.z > zClip)
			return;
		if (p0.z > zClip) {
			const double t = (zClip - p0.z) / (p1.z - p0.z);
			p0 = p0 + (p1 - p0) * t;
		} else if (p1.z > zClip) {
			const double t = (zClip - p1.z) / (p0.z - p1.z);
			p1 = p1 + (p0 - p1) * t;
		}
		const vector3d s0 = projectToScreenSpace(p0, m_cameraContext, false);
		const vector3d s1 = projectToScreenSpace(p1, m_cameraContext, false);
		// Skip segments completely outside screen bounds with generous margin
		if ((s0.x < -500.0 && s1.x < -500.0) || (s0.x > winW + 500.0 && s1.x > winW + 500.0) ||
			(s0.y < -500.0 && s1.y < -500.0) || (s0.y > winH + 500.0 && s1.y > winH + 500.0))
			return;
		verts.emplace_back(float(s0.x), float(s0.y), 0.0f);
		verts.emplace_back(float(s1.x), float(s1.y), 0.0f);
	};

	std::vector<vector3f> orbitVerts;
	std::vector<vector3f> targetOrbitVerts;
	std::vector<vector3f> exclVerts;
	std::vector<vector3f> dangerExclVerts;

	const Body *navTarget = Pi::player->GetNavTarget();

	for (Body *b : m_game->GetSpace()->GetBodies()) {
		if (!b)
			continue;

		// 1. Orbital trajectory lines for planets and orbital stations
		const bool isTerrain = b->IsType(ObjectType::TERRAINBODY);
		const bool isOrbStation = b->IsType(ObjectType::SPACESTATION) && !static_cast<SpaceStation *>(b)->IsGroundStation();
		if (isTerrain || isOrbStation) {
			const SystemBody *sb = b->GetSystemBody();
			if (sb && sb->GetOrbit().GetSemiMajorAxis() > 0.0) {
				Frame *bFrame = Frame::GetFrame(b->GetFrame());
				Frame *parentFrame = isOrbStation ? bFrame : (bFrame ? Frame::GetFrame(bFrame->GetParent()) : nullptr);
				if (parentFrame) {
					const vector3d parentCamPos = parentFrame->GetInterpPositionRelTo(camFrameId);
					const matrix3x3d parentCamOrient = parentFrame->GetInterpOrientRelTo(camFrameId);
					const Orbit &orbit = sb->GetOrbit();
					const double period = orbit.Period();
					if (period > 0.0 && std::isfinite(period)) {
						constexpr int ORBIT_SEGS = 96;
						std::vector<vector3f> &dest = (b == navTarget) ? targetOrbitVerts : orbitVerts;
						vector3d prevPt = parentCamPos + parentCamOrient * orbit.OrbitalPosAtTime(0.0);
						for (int k = 1; k <= ORBIT_SEGS; ++k) {
							const double t = period * (double(k) / double(ORBIT_SEGS));
							const vector3d curPt = parentCamPos + parentCamOrient * orbit.OrbitalPosAtTime(t);
							appendClippedSegment(dest, prevPt, curPt);
							prevPt = curPt;
						}
					}
				}
			}
		}

		// 2. Spherical exclusion zone silhouette rings around stars, gas giants, and planets
		if (isTerrain) {
			const double exclR = SupercruiseController::GetExclusionZoneRadius(b);
			if (exclR > 0.0) {
				const vector3d bodyCamPos = b->GetInterpPositionRelTo(camFrameId);
				const double dist = bodyCamPos.Length();
				if (dist > exclR * 1.002 && (exclR / dist) > 0.004) {
					const double ratio = exclR / dist;
					const double ratioSq = ratio * ratio;
					const vector3d ringCenter = bodyCamPos * (1.0 - ratioSq);
					const double ringRadius = exclR * std::sqrt(std::max(0.0, 1.0 - ratioSq));
					const vector3d u = bodyCamPos * (1.0 / dist);
					const vector3d e1 = MathUtil::OrthogonalDirection(u).Normalized();
					const vector3d e2 = u.Cross(e1).Normalized();

					constexpr int RING_SEGS = 64;
					std::vector<vector3f> &dest = (dist < exclR * 2.2) ? dangerExclVerts : exclVerts;
					vector3d prevPt = ringCenter + e1 * ringRadius;
					for (int k = 1; k <= RING_SEGS; ++k) {
						const double ang = (2.0 * M_PI * double(k)) / double(RING_SEGS);
						const vector3d curPt = ringCenter + (e1 * std::cos(ang) + e2 * std::sin(ang)) * ringRadius;
						appendClippedSegment(dest, prevPt, curPt);
						prevPt = curPt;
					}
				}
			}
		}
	}

	if (!orbitVerts.empty()) {
		m_indicator.SetData(orbitVerts.size(), orbitVerts.data(), Color(45, 145, 220, 85));
		m_indicator.Draw(m_renderer, m_indicatorMat.get());
	}
	if (!targetOrbitVerts.empty()) {
		m_indicator.SetData(targetOrbitVerts.size(), targetOrbitVerts.data(), Color(90, 215, 255, 155));
		m_indicator.Draw(m_renderer, m_indicatorMat.get());
	}
	if (!exclVerts.empty()) {
		m_indicator.SetData(exclVerts.size(), exclVerts.data(), Color(255, 185, 40, 150));
		m_indicator.Draw(m_renderer, m_indicatorMat.get());
	}
	if (!dangerExclVerts.empty()) {
		m_indicator.SetData(dangerExclVerts.size(), dangerExclVerts.data(), Color(255, 75, 45, 215));
		m_indicator.Draw(m_renderer, m_indicatorMat.get());
	}
}

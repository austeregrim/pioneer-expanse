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
#include "lua/LuaEvent.h"
#include "Pi.h"
#include "Planet.h"
#include "Player.h"
#include <SDL_keycode.h>
#include "SectorView.h"
#include "Sensors.h"
#include "SpeedLines.h"
#include "TerrainBody.h"
#include "planet/WeatherEffects.h"
#include "planet/WeatherSystem.h"
#include "graphics/Graphics.h"
#include "graphics/Material.h"
#include "graphics/Renderer.h"
#include "graphics/RenderState.h"
#include "graphics/TextureBuilder.h"
#include "graphics/VertexArray.h"
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
	input->AddActionBinding("BindDiscoveryScan", group, Action({ SDLK_b }));
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
	discoveryScan = AddAction("BindDiscoveryScan");
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

	Graphics::RenderStateDesc scGlowRsd;
	scGlowRsd.blendMode = Graphics::BLEND_ALPHA_ONE;
	scGlowRsd.depthWrite = false;
	scGlowRsd.depthTest = false;
	scGlowRsd.cullMode = Graphics::CULL_NONE;
	Graphics::MaterialDescriptor scGlowDesc;
	scGlowDesc.textures = 1;
	scGlowDesc.vertexColors = true;
	auto scGlowVfmt = Graphics::VertexFormatDesc::FromAttribSet(
		Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE | Graphics::ATTRIB_UV0);
	m_scGlowMat.reset(Pi::renderer->CreateMaterial("unlit", scGlowDesc, scGlowRsd, scGlowVfmt));
	Graphics::Texture *scGlowTex = Graphics::TextureBuilder::Billboard("textures/halo.dds").GetOrCreateTexture(Pi::renderer, "billboard");
	m_scGlowMat->SetTexture("texture0"_hash, scGlowTex);

	Graphics::RenderStateDesc flareRsd;
	flareRsd.blendMode = Graphics::BLEND_ALPHA_ONE;
	flareRsd.depthWrite = false;
	flareRsd.depthTest = false;
	flareRsd.cullMode = Graphics::CULL_NONE;
	Graphics::MaterialDescriptor flareDesc;
	auto flareVfmt = Graphics::VertexFormatDesc::FromAttribSet(
		Graphics::ATTRIB_POSITION | Graphics::ATTRIB_UV0);
	m_lensFlareMat.reset(Pi::renderer->CreateMaterial("lens_flare", flareDesc, flareRsd, flareVfmt));

	/*
	  NEW UI
	*/

	m_speedLines.reset(new SpeedLines(Pi::player));
	m_weatherEffects.reset(new WeatherEffects(Pi::player));

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
	m_onDiscoveryScanCon = InputBindings.discoveryScan->onPressed.connect(sigc::mem_fun(this, &WorldView::OnDiscoveryScan));
}


void WorldView::SaveToJson(Json &jsonObj)
{
	Json worldViewObj = Json::object(); // Create JSON object to contain world view data.

	shipView->SaveToJson(worldViewObj);

	jsonObj["world_view"] = worldViewObj; // Add world view object to supplied object.
}

void WorldView::UpdateFov(float fov)
{
	if (m_cameraContext)
		m_cameraContext->SetFovAng(fov);
	if (shipView)
		shipView->SetFov(fov);
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
	// Speed lines and weather particles
	if (Pi::AreSpeedLinesDisplayed())
		m_speedLines->Render(m_renderer);

	if (m_weatherEffects)
		m_weatherEffects->Render(m_renderer);

	// Cockpit view: render active volumetric forward/landing beam cones ahead of the ship
	if (Pi::player && !Pi::player->IsDead() && shipView && !shipView->IsExteriorView() &&
		Pi::player->GetFlightState() != Ship::HYPERSPACE &&
		(!Pi::player->IsDocked() || (Pi::player->GetDockedWith() && Pi::player->GetDockedWith()->IsGroundStation())) &&
		(Pi::player->GetForwardLightsEnabled() || Pi::player->GetLandingLightsEnabled())) {
		const FrameId camFrameId = m_cameraContext->GetTempFrame();
		Frame *shipFrame = Frame::GetFrame(Pi::player->GetFrame());
		if (camFrameId.valid() && shipFrame) {
			matrix4x4d shipToCam = shipFrame->GetInterpOrientRelTo(camFrameId);
			shipToCam.SetTranslate(shipFrame->GetInterpPositionRelTo(camFrameId));
			shipToCam = shipToCam * Pi::player->GetInterpMatrix();
			Pi::player->RenderCockpitLights(m_renderer, shipToCam);
		}
	}

	// Contact trails (sublight contacts only; Supercruise ships draw short white/Doppler FTL wakes)
	if (Pi::AreHudTrailsDisplayed()) {
		for (auto it = Pi::player->GetSensors()->GetContacts().begin(); it != Pi::player->GetSensors()->GetContacts().end(); ++it) {
			if (it->body && !it->body->IsDead() && it->body->IsType(ObjectType::SHIP) &&
				static_cast<const Ship *>(it->body)->GetFlightState() == Ship::SUPERCRUISE) {
				continue;
			}
			if (it->trail)
				it->trail->Render(m_renderer);
		}
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

	// Enhanced Graphics: procedural star glare, diffraction starburst, and optical lens flare
	DrawStarLensFlare();

	// Supercruise ships appear as radiant points of light across the system
	DrawSupercruiseShips();

	// Supercruise 3D HUD overlays (orbital path lines & body exclusion zone rings)
	DrawSupercruiseOverlays();

	// Active planetary surface scan 3D coverage grid sphere
	DrawSurfaceScanOverlay();

	// Hyperjump star-streaking surge right before hyperspace transit
	DrawHyperspaceJumpStreaks();

	m_cameraContext->EndFrame();

	// combat target indicator
	DrawCombatTargetIndicator(m_combatTargetIndicator, m_targetLeadIndicator, red);
}

void WorldView::OnDiscoveryScan()
{
	if (Pi::GetView() == this) {
		LuaEvent::Queue("onDiscoveryScanRequested");
	}
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

	// Hyperjump wide-angle FOV warp: widen toward ~360 deg feel during jump-out surge,
	// and snap back from ultra-wide down to normal FOV when emerging into the destination system.
	if (Pi::player && m_cameraContext) {
		const float defaultFov = Pi::config->Float("FOVVertical");
		const float baseFov = (shipView && !shipView->IsExteriorView()) ? m_cameraContext->GetFovAng() : defaultFov;
		constexpr float kWarpMaxFov = 168.0f;
		if (Pi::player->IsHyperspaceJumpSurging()) {
			const float p = Pi::player->GetHyperspaceJumpSurgeProgress();
			m_cameraContext->SetFovAng(baseFov + (kWarpMaxFov - baseFov) * (p * p));
		} else if (m_game && m_game->GetHyperspaceEntryFovFactor() > 0.0f) {
			const float f = m_game->GetHyperspaceEntryFovFactor();
			m_cameraContext->SetFovAng(baseFov + (kWarpMaxFov - baseFov) * (f * f));
		} else if (shipView && shipView->IsExteriorView()) {
			m_cameraContext->SetFovAng(defaultFov);
		}
	}

	m_cameraContext->BeginFrame();
	m_camera->Update();

	UpdateProjectedObjects();

	FrameId playerFrameId = Pi::player->GetFrame();
	FrameId camFrameId = m_cameraContext->GetTempFrame();
	matrix4x4d frameRotToCam;
	Frame::GetFrameTransform(playerFrameId, camFrameId, frameRotToCam);
	frameRotToCam[12] = frameRotToCam[13] = frameRotToCam[14] = 0.0;
	frameRotToCam[15] = 1.0;

	//speedlines and contact trails need camFrame for transform, so they must be updated here
	if (m_speedLines.get() && Pi::AreSpeedLinesDisplayed()) {
		m_speedLines->Update(m_game->GetTimeStep());
		m_speedLines->SetTransform(frameRotToCam);
	}

	if (m_weatherEffects) {
		m_weatherEffects->Update(m_game->GetTimeStep());
		m_weatherEffects->SetTransform(frameRotToCam);
	}

	if (Pi::AreHudTrailsDisplayed()) {
		matrix4x4d trans;
		// HudTrail stores its points in the non-rotating frame, so the display transform must be built from that same frame.
		FrameId nonRotFrameId = Frame::GetFrame(playerFrameId)->GetNonRotFrame();
		Frame::GetFrameTransform(nonRotFrameId, camFrameId, trans);

		for (auto it = Pi::player->GetSensors()->GetContacts().begin(); it != Pi::player->GetSensors()->GetContacts().end(); ++it) {
			if (it->body && !it->body->IsDead() && it->trail)
				it->trail->SetTransform(trans);
		}
	} else {
		for (auto it = Pi::player->GetSensors()->GetContacts().begin(); it != Pi::player->GetSensors()->GetContacts().end(); ++it) {
			if (it->body && !it->body->IsDead() && it->trail)
				it->trail->Reset(playerFrameId);
		}
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

void WorldView::DrawStarLensFlare()
{
	if (!m_renderer || !m_renderer->IsEnhancedGraphicsEnabled() || !m_lensFlareMat)
		return;
	if (!Pi::player || !m_game || !m_game->GetSpace())
		return;

	const Ship::FlightState pState = Pi::player->GetFlightState();
	if (pState == Ship::DOCKED || pState == Ship::HYPERSPACE || Pi::player->GetDockedWith() != nullptr)
		return;

	const FrameId camFrameId = m_cameraContext->GetTempFrame();
	if (!camFrameId.valid())
		return;

	const float winW = float(m_renderer->GetWindowWidth());
	const float winH = float(m_renderer->GetWindowHeight());
	if (winW <= 1.0f || winH <= 1.0f)
		return;
	const float aspect = winW / winH;

	// Gently soften lens flare inside atmosphere & under thick overcast cloud decks
	float atmoAtten = 1.0f;
	if (m_camera && m_camera->IsInAtmosphere()) {
		atmoAtten = 0.72f;
		const Frame *camFrame = Frame::GetFrame(camFrameId);
		const Frame *camParent = camFrame ? Frame::GetFrame(camFrame->GetParent()) : nullptr;
		if (camParent && camParent->IsRotFrame() && camParent->GetBody() && camParent->GetBody()->IsType(ObjectType::PLANET)) {
			const Planet *planet = static_cast<const Planet *>(camParent->GetBody());
			const vector3d camInRot = -(camParent->GetInterpOrientRelTo(camFrameId).Transpose() * camParent->GetInterpPositionRelTo(camFrameId));
			const WeatherState weather = planet->GetWeatherState(camInRot, m_game->GetTime());
			if (weather.hasAtmosphere && weather.altitudeM < weather.lowerCloudAltM + 1500.0) {
				const float cloudOcc = Clamp(float(weather.lowerCloudCover * 0.85 + weather.upperCloudCover * 0.25), 0.0f, 1.0f);
				atmoAtten = 0.72f * (1.0f - 0.80f * cloudOcc);
			}
		}
	}

	// Collect celestial and orbital station occluders in camera space for smooth eclipse & terrain ray occlusion
	struct FlareOccluder {
		vector3d pos;
		double dist;
		double radius;
		double maxRadius;
		matrix3x3d orientToCam;
		const TerrainBody *terrainBody;
	};
	std::vector<FlareOccluder> occluders;
	for (Body *b : m_game->GetSpace()->GetBodies()) {
		if (!b)
			continue;

		if (b->IsType(ObjectType::SPACESTATION)) {
			const vector3d p = b->GetInterpPositionRelTo(camFrameId);
			const double dist = p.Length();
			const SpaceStation *st = static_cast<const SpaceStation *>(b);
			if (!st->IsGroundStation() && dist < b->GetClipRadius())
				return; // Camera is inside an orbital station bay; hide exterior star flare
			const double r = std::max(b->GetPhysRadius(), 350.0);
			if (dist > r)
				occluders.push_back({ p, dist, r, r, matrix3x3d::Identity, nullptr });
			continue;
		}

		if (!b->IsType(ObjectType::TERRAINBODY) || b->IsType(ObjectType::STAR))
			continue;
		const TerrainBody *tb = static_cast<const TerrainBody *>(b);
		const SystemBody *sb = tb->GetSystemBody();
		const double r = sb ? sb->GetRadius() : tb->GetPhysRadius();
		if (r <= 0.0)
			continue;
		const double maxR = std::max(r, tb->GetMaxFeatureRadius());
		const vector3d p = tb->GetInterpPositionRelTo(camFrameId);
		const double dist = p.Length();
		if (dist > 1.0)
			occluders.push_back({ p, dist, r, maxR, tb->GetInterpOrientRelTo(camFrameId), tb });
	}

	const double fovRad = DEG2RAD(std::max(10.0f, m_cameraContext->GetFovAng()));
	const double tanHalfFov = std::tan(fovRad * 0.5);

	Graphics::VertexArray quad(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_UV0);
	quad.Add(vector3f(0.0f, 0.0f, 0.0f), vector2f(0.0f, 0.0f));
	quad.Add(vector3f(winW, 0.0f, 0.0f), vector2f(1.0f, 0.0f));
	quad.Add(vector3f(winW, winH, 0.0f), vector2f(1.0f, 1.0f));
	quad.Add(vector3f(0.0f, 0.0f, 0.0f), vector2f(0.0f, 0.0f));
	quad.Add(vector3f(winW, winH, 0.0f), vector2f(1.0f, 1.0f));
	quad.Add(vector3f(0.0f, winH, 0.0f), vector2f(0.0f, 1.0f));

	static const size_t s_starParamsName = "starParams"_hash;
	static const size_t s_starColorName = "starColor"_hash;
	static const size_t s_flareParamsName = "flareParams"_hash;
	const float bgVis = m_camera ? Clamp(m_camera->GetBackgroundIntensity(), 0.0f, 1.0f) : 1.0f;

	for (Body *b : m_game->GetSpace()->GetBodies()) {
		if (!b || !b->IsType(ObjectType::STAR))
			continue;

		const SystemBody *sb = b->GetSystemBody();
		if (!sb)
			continue;
		// Skip black holes (non-luminous gravitational singularities)
		if (sb->GetType() >= SystemBody::TYPE_STAR_S_BH && sb->GetType() <= SystemBody::TYPE_STAR_IM_BH)
			continue;

		const vector3d starCamPos = b->GetInterpPositionRelTo(camFrameId);
		if (starCamPos.z >= -1.0)
			continue; // Behind camera

		const double dist = starCamPos.Length();
		if (dist <= 1.0)
			continue;

		const vector3d screenPos = projectToScreenSpace(starCamPos, m_cameraContext, false);
		const float ndcX = (float(screenPos.x) / winW) * 2.0f - 1.0f;
		const float ndcY = (float(screenPos.y) / winH) * 2.0f - 1.0f;

		// Smooth off-screen fade so glare/streaks glide cleanly across viewport edges
		const float maxEdge = std::max(std::abs(ndcX), std::abs(ndcY));
		if (maxEdge > 1.45f)
			continue;
		const float edgeFade = Clamp(1.0f - std::max(0.0f, (maxEdge - 0.92f) / 0.53f), 0.0f, 1.0f);

		const double starR = std::max(1000.0, sb->GetRadius());
		const double angStar = std::asin(Clamp(starR / dist, 0.0, 1.0));
		const vector3d starDir = starCamPos / dist;

		// Smooth angular eclipse & 3D terrain ridge occlusion against planets, mountains, moons, and stations
		float visibility = 1.0f;
		for (const FlareOccluder &occ : occluders) {
			if (occ.dist >= dist)
				continue;
			const vector3d occDir = occ.pos / occ.dist;
			const double dotDir = Clamp(starDir.Dot(occDir), -1.0, 1.0);
			if (occ.dist > occ.radius && dotDir > 0.0) {
				const double angOcc = std::asin(Clamp(occ.radius / occ.dist, 0.0, 1.0));
				const double angSep = std::acos(dotDir);
				if (angSep <= angOcc - angStar) {
					visibility = 0.0f;
					break;
				}
				if (angSep < angOcc + angStar) {
					const float frac = float(Clamp((angSep - (angOcc - angStar)) / std::max(2.0 * angStar, 1e-5), 0.0, 1.0));
					visibility = std::min(visibility, frac * frac * (3.0f - 2.0f * frac));
				}
			}

			if (visibility > 0.005f && occ.terrainBody && occ.maxRadius > occ.radius + 1.0) {
				const matrix3x3d camToBody = occ.orientToCam.Transpose();
				const vector3d camPosP = camToBody * (-occ.pos);
				const vector3d starDirP = (camToBody * starDir).NormalizedSafe();
				const float terrVis = WeatherSystem::ComputeTerrainRayVisibility(
					camPosP, starDirP, dist, occ.radius, occ.maxRadius, angStar,
					[tb = occ.terrainBody](const vector3d &u) { return tb->GetTerrainHeight(u); });
				visibility = std::min(visibility, terrVis);
				if (visibility <= 0.005f) {
					visibility = 0.0f;
					break;
				}
			}
		}
		if (visibility <= 0.005f)
			continue;

		const double lum = (sb->GetType() <= SystemBody::TYPE_STAR_MAX) ? std::max(0.01, StarSystem::starLuminosities[sb->GetType()]) : 1.0;
		const double effDistRadii = dist / (starR * std::max(0.65, std::pow(lum, 0.35)));
		const float distFade = float(Clamp(1.0 / (1.0 + std::pow(effDistRadii / 180.0, 1.15)), 0.14, 1.0));
		const float lumBoost = float(Clamp(0.65 + 0.35 * std::pow(lum, 0.18), 0.45, 1.15));

		const float intensity = Clamp(distFade * lumBoost * edgeFade * visibility * atmoAtten * 0.92f, 0.0f, 1.0f);
		if (intensity <= 0.005f)
			continue;

		const float discRadiusNdc = float(Clamp(std::tan(angStar) / std::max(tanHalfFov, 0.1), 0.01, 0.65));
		const Color4f starCol = sb->GetStarColor().ToColor4f();

		// Fade out pinpoint glare lines & diffraction spikes as the star resolves into a visible orb
		// and as camera exposure darkens the background skybox
		const float orbFade = Clamp(1.0f - (discRadiusNdc - 0.022f) / 0.085f, 0.0f, 1.0f);
		const float skyExposureFade = Clamp((bgVis - 0.20f) / 0.72f, 0.0f, 1.0f);
		const float pinpointFactor = orbFade * orbFade * skyExposureFade;
		const float ghostFactor = Clamp(0.55f + 0.45f * bgVis, 0.45f, 1.0f);

		m_lensFlareMat->SetPushConstant(s_starParamsName, vector3f(ndcX, ndcY, aspect), intensity);
		m_lensFlareMat->SetPushConstant(s_starColorName, vector3f(starCol.r, starCol.g, starCol.b), discRadiusNdc);
		m_lensFlareMat->SetPushConstant(s_flareParamsName, vector3f(pinpointFactor, ghostFactor, 0.0f), 0.0f);

		m_renderer->DrawBuffer(&quad, m_lensFlareMat.get());
	}
}

void WorldView::DrawSupercruiseShips()
{
	if (!Pi::player || !m_game || !m_game->GetSpace() || !m_scGlowMat)
		return;

	const Ship::FlightState pState = Pi::player->GetFlightState();
	if (pState == Ship::DOCKED || pState == Ship::LANDED || pState == Ship::HYPERSPACE || Pi::player->GetDockedWith() != nullptr)
		return;

	const FrameId camFrameId = m_cameraContext->GetTempFrame();
	if (!camFrameId.valid())
		return;

	const Frame *rootFrame = Frame::GetFrame(m_game->GetSpace()->GetRootFrame());
	const vector3d rootCamPos = rootFrame ? rootFrame->GetInterpPositionRelTo(camFrameId) : vector3d(0.0);
	const matrix3x3d rootCamOrient = rootFrame ? rootFrame->GetInterpOrientRelTo(camFrameId) : matrix3x3d::Identity;

	const float winW = float(m_renderer->GetWindowWidth());
	const float winH = float(m_renderer->GetWindowHeight());
	const double zClip = -1.0;

	// Collect celestial and station occluders in camera space
	struct Occluder {
		vector3d pos;
		double radiusSq;
	};
	std::vector<Occluder> occluders;
	for (Body *b : m_game->GetSpace()->GetBodies()) {
		if (!b)
			continue;

		if (b->IsType(ObjectType::SPACESTATION)) {
			const vector3d p = b->GetInterpPositionRelTo(camFrameId);
			const double distSq = p.LengthSqr();
			const SpaceStation *st = static_cast<const SpaceStation *>(b);
			if (!st->IsGroundStation() && distSq < b->GetClipRadius() * b->GetClipRadius())
				return; // Camera is inside orbital station superstructure; hide external Supercruise wakes
			const double r = std::max(b->GetPhysRadius(), 450.0);
			if (distSq > r * r)
				occluders.push_back({ p, r * r });
			continue;
		}

		if (!b->IsType(ObjectType::TERRAINBODY))
			continue;
		const SystemBody *sb = b->GetSystemBody();
		const double r = sb ? sb->GetRadius() : b->GetPhysRadius();
		if (r <= 0.0)
			continue;
		const vector3d p = b->GetInterpPositionRelTo(camFrameId);
		if (p.LengthSqr() <= r * r)
			continue;
		occluders.push_back({ p, r * r });
	}

	auto isOccluded = [&](const vector3d &targetCamPos, double targetDist) -> bool {
		if (targetDist <= 1.0)
			return false;
		const vector3d dir = targetCamPos / targetDist;
		for (const Occluder &occ : occluders) {
			const double proj = occ.pos.Dot(dir);
			if (proj <= 0.0 || proj >= targetDist)
				continue;
			const double perpSq = occ.pos.LengthSqr() - proj * proj;
			if (perpSq < occ.radiusSq)
				return true;
		}
		return false;
	};

	const bool inAtmosphere = m_camera && m_camera->IsInAtmosphere();
	const float bgVis = m_camera ? Clamp(m_camera->GetBackgroundIntensity(), 0.0f, 1.0f) : 1.0f;
	if (inAtmosphere && bgVis <= 0.04f)
		return;

	Graphics::VertexArray glowVerts(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE | Graphics::ATTRIB_UV0);

	auto addGlowQuad = [&](float cx, float cy, float halfSize, const Color &col) {
		const vector3f p0(cx - halfSize, cy - halfSize, 0.0f);
		const vector3f p1(cx + halfSize, cy - halfSize, 0.0f);
		const vector3f p2(cx + halfSize, cy + halfSize, 0.0f);
		const vector3f p3(cx - halfSize, cy + halfSize, 0.0f);
		glowVerts.Add(p0, col, vector2f(0.0f, 0.0f));
		glowVerts.Add(p1, col, vector2f(1.0f, 0.0f));
		glowVerts.Add(p2, col, vector2f(1.0f, 1.0f));
		glowVerts.Add(p0, col, vector2f(0.0f, 0.0f));
		glowVerts.Add(p2, col, vector2f(1.0f, 1.0f));
		glowVerts.Add(p3, col, vector2f(0.0f, 1.0f));
	};

	for (Body *b : m_game->GetSpace()->GetBodies()) {
		if (!b)
			continue;

		// Low Wake / Distress Signal beacon (visible in Supercruise)
		if (b->IsType(ObjectType::HYPERSPACECLOUD) && static_cast<const HyperspaceCloud *>(b)->IsLowWake()) {
			const vector3d wakeCamPos = b->GetInterpPositionRelTo(camFrameId);
			if (wakeCamPos.z <= zClip) {
				const double dist = wakeCamPos.Length();
				if (dist >= 250.0 && !isOccluded(wakeCamPos, dist)) {
					const vector3d screenHead = projectToScreenSpace(wakeCamPos, m_cameraContext, false);
					if (screenHead.x >= -80.0 && screenHead.x <= winW + 80.0 &&
						screenHead.y >= -80.0 && screenHead.y <= winH + 80.0) {
						const float cx = float(screenHead.x);
						const float cy = float(screenHead.y);
						const float pulse = 0.75f + 0.25f * float(std::sin(m_game->GetTime() * 5.0));
						addGlowQuad(cx, cy, 13.0f * pulse, Color(255, 165, 45, 195));
						addGlowQuad(cx, cy, 5.0f, Color(255, 235, 185, 255));
					}
				}
			}
			continue;
		}

		if (!b->IsType(ObjectType::SHIP))
			continue;
		const Ship *ship = static_cast<const Ship *>(b);
		if (ship->IsDead() || ship->GetFlightState() != Ship::SUPERCRUISE)
			continue;
		if (ship == Pi::player)
			continue;

		const vector3d shipCamPos = ship->GetInterpPositionRelTo(camFrameId);
		if (shipCamPos.z > zClip)
			continue;

		const double dist = shipCamPos.Length();
		if (dist < 250.0 || isOccluded(shipCamPos, dist))
			continue;

		const vector3d screenHead = projectToScreenSpace(shipCamPos, m_cameraContext, false);
		if (screenHead.x < -80.0 || screenHead.x > winW + 80.0 ||
			screenHead.y < -80.0 || screenHead.y > winH + 80.0)
			continue;

		const SupercruiseController *sc = ship->GetSupercruise();
		const double speed = sc ? sc->GetSpeed() : SupercruiseController::MIN_SPEED;
		const double speedLog = Clamp(
			std::log10(std::max(speed, SupercruiseController::MIN_SPEED) / SupercruiseController::MIN_SPEED) /
			std::log10(SupercruiseController::MAX_SPEED / SupercruiseController::MIN_SPEED),
			0.0, 1.0);

		const float visAlpha = inAtmosphere ? (bgVis * 0.78f) : Clamp(0.25f + 0.75f * bgVis, 0.25f, 1.0f);
		const float outerHalf = inAtmosphere ? float(2.4 + 1.4 * speedLog) : float(5.5 + 4.5 * speedLog);
		const float coreHalf = inAtmosphere ? float(1.2 + 0.8 * speedLog) : float(2.3 + 1.7 * speedLog);
		const float cx = float(screenHead.x);
		const float cy = float(screenHead.y);

		// Subtle relativistic Doppler shift based on radial direction of travel relative to camera:
		// pure white laterally, subtle cool-white blueshift approaching, warm amber-reddish shift receding.
		const vector3d shipFwdCam = (-ship->GetInterpOrientRelTo(camFrameId).VectorZ()).NormalizedSafe();
		const vector3d toCamDir = (-shipCamPos).NormalizedSafe();
		const float radialDot = float(Clamp(shipFwdCam.Dot(toCamDir), -1.0, 1.0));
		const float doppler = 0.38f * float(speedLog) * radialDot;

		auto makeDopplerColor = [&](Uint8 alpha) -> Color {
			const Uint8 scaledA = Uint8(Clamp(int(float(alpha) * visAlpha), 0, 255));
			if (doppler >= 0.0f) {
				// Blueshift (approaching): crisp cool-white
				const Uint8 r = Uint8(Clamp(int(255.0f - 65.0f * doppler), 160, 255));
				const Uint8 g = Uint8(Clamp(int(252.0f - 18.0f * doppler), 200, 255));
				return Color(r, g, 255, scaledA);
			} else {
				// Redshift (receding): warm amber-white
				const float red = -doppler;
				const Uint8 g = Uint8(Clamp(int(250.0f - 95.0f * red), 120, 255));
				const Uint8 b = Uint8(Clamp(int(242.0f - 155.0f * red), 75, 255));
				return Color(255, g, b, scaledA);
			}
		};

		// Short, subtle luminous wake along recent trajectory (in atmosphere: thin shooting-star streak)
		if (sc && rootFrame && !sc->GetTrailPositions().empty()) {
			const float maxTrailPix = inAtmosphere ? float(10.0 + 14.0 * speedLog) : float(8.0 + 10.0 * speedLog);
			float accumPix = 0.0f;
			float prevX = cx;
			float prevY = cy;
			vector3d prevCam = shipCamPos;

			for (const vector3d &rootPt : sc->GetTrailPositions()) {
				vector3d camPt = rootCamPos + rootCamOrient * rootPt;
				if (camPt.z > zClip) {
					const double denom = camPt.z - prevCam.z;
					if (std::fabs(denom) < 1e-6)
						break;
					const double t = Clamp((zClip - prevCam.z) / denom, 0.0, 1.0);
					camPt = prevCam + (camPt - prevCam) * t;
				}
				const vector3d sPt = projectToScreenSpace(camPt, m_cameraContext, false);
				const float sx = float(sPt.x);
				const float sy = float(sPt.y);
				const float dx = sx - prevX;
				const float dy = sy - prevY;
				const float segLen = std::sqrt(dx * dx + dy * dy);
				if (segLen > maxTrailPix * 3.0f)
					break;
				if (segLen > 0.5f) {
					const float remain = maxTrailPix - accumPix;
					if (remain <= 0.0f)
						break;
					const float useLen = std::min(segLen, remain);
					const int steps = std::max(1, int(std::ceil(useLen / 2.2f)));
					for (int k = 1; k <= steps; ++k) {
						const float frac = (float(k) / float(steps)) * (useLen / segLen);
						const float px = prevX + dx * frac;
						const float py = prevY + dy * frac;
						const float d = accumPix + useLen * (float(k) / float(steps));
						const float norm = Clamp(d / maxTrailPix, 0.0f, 1.0f);
						const float fade = std::pow(1.0f - norm, inAtmosphere ? 1.6f : 2.0f);
						const float puffRadius = inAtmosphere
							? float(0.75 + 0.45 * speedLog) * (1.0f - 0.72f * norm)
							: (coreHalf * 0.90f) * (1.0f - 0.65f * norm);
						const Uint8 baseAlpha = Uint8(Clamp(int((inAtmosphere ? 115.0f : 95.0f) * fade), 0, 255));
						if (baseAlpha > 2) {
							addGlowQuad(px, py, puffRadius, makeDopplerColor(baseAlpha));
						}
					}
					accumPix += useLen;
					if (accumPix >= maxTrailPix)
						break;
				}
				prevX = sx;
				prevY = sy;
				prevCam = camPt;
			}
		}

		addGlowQuad(cx, cy, outerHalf, makeDopplerColor(inAtmosphere ? 135 : 175));
		addGlowQuad(cx, cy, coreHalf, Color(255, 254, 250, Uint8(Clamp(int(255.0f * visAlpha), 0, 255))));
	}

	if (!glowVerts.IsEmpty()) {
		m_renderer->DrawBuffer(&glowVerts, m_scGlowMat.get());
	}
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
	const double gameTime = m_game->GetTime();
	std::vector<FrameId> drawnGravFrames;

	auto drawOrbitInParentFrame = [&](const Orbit &orbit, Frame *parentFrame, std::vector<vector3f> &dest) {
		if (!parentFrame || orbit.GetSemiMajorAxis() <= 0.0 || orbit.GetEccentricity() >= 1.0)
			return;
		const double period = orbit.Period();
		if (!(period > 0.0 && std::isfinite(period)))
			return;

		const vector3d parentCamPos = parentFrame->GetInterpPositionRelTo(camFrameId);
		const matrix3x3d parentCamOrient = parentFrame->GetInterpOrientRelTo(camFrameId);

		constexpr int ORBIT_SEGS = 256;
		auto sampleOrbitPt = [&](int k) -> vector3d {
			const double s = 2.0 * (double(k) / double(ORBIT_SEGS)) - 1.0;
			const double u = 0.5 * (0.2 * s + 0.8 * s * s * s);
			return parentCamPos + parentCamOrient * orbit.EvenSpacedPosTrajectory(u, gameTime);
		};

		vector3d prevPt = sampleOrbitPt(0);
		for (int k = 1; k <= ORBIT_SEGS; ++k) {
			const vector3d curPt = sampleOrbitPt(k);
			appendClippedSegment(dest, prevPt, curPt);
			prevPt = curPt;
		}
	};

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
				Frame *orbFrame = bFrame ? Frame::GetFrame(bFrame->GetNonRotFrame()) : nullptr;
				Frame *parentFrame = orbFrame ? Frame::GetFrame(orbFrame->GetParent()) : nullptr;
				if (parentFrame) {
					std::vector<vector3f> &dest = (b == navTarget) ? targetOrbitVerts : orbitVerts;
					drawOrbitInParentFrame(sb->GetOrbit(), parentFrame, dest);

					// If the parent is a binary barycenter (TYPE_GRAVPOINT) that itself orbits a parent body, draw its orbit once too
					Frame *ancFrame = parentFrame;
					while (ancFrame && ancFrame->GetSystemBody() &&
						ancFrame->GetSystemBody()->GetType() == SystemBody::TYPE_GRAVPOINT &&
						ancFrame->GetSystemBody()->GetOrbit().GetSemiMajorAxis() > 0.0) {
						const FrameId ancId = ancFrame->GetId();
						Frame *ancParent = Frame::GetFrame(ancFrame->GetParent());
						if (!ancParent)
							break;
						if (std::find(drawnGravFrames.begin(), drawnGravFrames.end(), ancId) == drawnGravFrames.end()) {
							drawnGravFrames.push_back(ancId);
							drawOrbitInParentFrame(ancFrame->GetSystemBody()->GetOrbit(), ancParent, orbitVerts);
						}
						ancFrame = ancParent;
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

void WorldView::SetSurfaceScanOverlay(const Body *body, bool active, float coverage, const std::string &grid)
{
	m_surfaceScan.body = body;
	m_surfaceScan.active = active;
	m_surfaceScan.coverage = coverage;
	m_surfaceScan.grid = grid;
}

void WorldView::DrawSurfaceScanOverlay()
{
	if (!m_surfaceScan.active || !m_surfaceScan.body || !Pi::DrawGUI || !m_labelsOn || !m_game || !m_game->GetSpace())
		return;

	// Verify body still exists in current space
	const Body *targetBody = nullptr;
	for (const Body *b : m_game->GetSpace()->GetBodies()) {
		if (b == m_surfaceScan.body) {
			targetBody = b;
			break;
		}
	}
	if (!targetBody || !targetBody->IsType(ObjectType::TERRAINBODY)) {
		m_surfaceScan.active = false;
		m_surfaceScan.body = nullptr;
		return;
	}

	const FrameId camFrameId = m_cameraContext->GetTempFrame();
	if (!camFrameId.valid())
		return;

	const double R = targetBody->GetPhysRadius() * 1.015;
	if (R <= 0.0)
		return;

	const vector3d bodyCamPos = targetBody->GetInterpPositionRelTo(camFrameId);
	const matrix3x3d bodyCamOrient = targetBody->GetInterpOrientRelTo(camFrameId);

	const double zClip = -1.0;
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
		if ((s0.x < -500.0 && s1.x < -500.0) || (s0.x > winW + 500.0 && s1.x > winW + 500.0) ||
			(s0.y < -500.0 && s1.y < -500.0) || (s0.y > winH + 500.0 && s1.y > winH + 500.0))
			return;
		verts.emplace_back(float(s0.x), float(s0.y), 0.0f);
		verts.emplace_back(float(s1.x), float(s1.y), 0.0f);
	};

	const size_t gridLen = m_surfaceScan.grid.size();
	int NLAT = 14;
	int NLON = 28;
	if (gridLen > 0) {
		NLAT = std::max(8, int(std::round(std::sqrt(double(gridLen) / 2.0))));
		NLON = NLAT * 2;
	}
	const size_t expectedLen = size_t(NLAT * NLON);

	auto spherePt = [&](int i, int j) -> vector3d {
		const double lat = -0.5 * M_PI + M_PI * (double(i) / double(NLAT));
		const double lon = 2.0 * M_PI * (double(j) / double(NLON));
		const double clat = std::cos(lat);
		return bodyCamPos + bodyCamOrient * vector3d(clat * std::cos(lon) * R, std::sin(lat) * R, clat * std::sin(lon) * R);
	};

	std::vector<vector3f> unscannedVerts;
	std::vector<vector3f> scannedVerts;
	unscannedVerts.reserve(NLAT * NLON * 10);
	scannedVerts.reserve(NLAT * NLON * 10);

	for (int i = 0; i < NLAT; ++i) {
		const double latMid = -0.5 * M_PI + M_PI * ((double(i) + 0.5) / double(NLAT));
		const double clatMid = std::cos(latMid);
		const double slatMid = std::sin(latMid);

		for (int j = 0; j < NLON; ++j) {
			const double lonMid = 2.0 * M_PI * ((double(j) + 0.5) / double(NLON));
			const vector3d relCenter = bodyCamOrient * vector3d(clatMid * std::cos(lonMid) * R, slatMid * R, clatMid * std::sin(lonMid) * R);
			// Back-face cull far-side cells for clean holographic readability
			if (relCenter.Dot(bodyCamPos) > R * bodyCamPos.Length() * 0.12) {
				continue;
			}

			const size_t idx = size_t(i * NLON + j);
			const bool isScanned = (m_surfaceScan.grid.size() == expectedLen) && (m_surfaceScan.grid[idx] == '1');
			std::vector<vector3f> &dest = isScanned ? scannedVerts : unscannedVerts;

			const vector3d p00 = spherePt(i, j);
			const vector3d p10 = spherePt(i + 1, j);
			const vector3d p01 = spherePt(i, j + 1);
			const vector3d p11 = spherePt(i + 1, j + 1);

			// Triangulated wireframe mesh: quad edges + diagonal
			appendClippedSegment(dest, p00, p01);
			appendClippedSegment(dest, p00, p10);
			appendClippedSegment(dest, p10, p11);
			appendClippedSegment(dest, p01, p11);
			appendClippedSegment(dest, p00, p11);
		}
	}

	if (!unscannedVerts.empty()) {
		m_indicator.SetData(unscannedVerts.size(), unscannedVerts.data(), Color(45, 175, 255, 65));
		m_indicator.Draw(m_renderer, m_indicatorMat.get());
	}
	if (!scannedVerts.empty()) {
		const float t = Clamp(m_surfaceScan.coverage / 0.85f, 0.0f, 1.0f);
		const Uint8 r = Uint8(50 + int(110.0f * t));
		const Uint8 g = Uint8(245);
		const Uint8 b = Uint8(165 - int(75.0f * t));
		m_indicator.SetData(scannedVerts.size(), scannedVerts.data(), Color(r, g, b, 225));
		m_indicator.Draw(m_renderer, m_indicatorMat.get());
	}
}

void WorldView::DrawHyperspaceJumpStreaks()
{
	if (!Pi::player || !Pi::player->IsHyperspaceJumpSurging())
		return;

	const float p = Pi::player->GetHyperspaceJumpSurgeProgress();
	if (p <= 0.001f)
		return;

	const float winW = float(m_renderer->GetWindowWidth());
	const float winH = float(m_renderer->GetWindowHeight());
	const float cx = winW * 0.5f;
	const float cy = winH * 0.5f;
	const float maxR = std::sqrt(cx * cx + cy * cy) * 1.2f;

	std::vector<vector3f> cyanStreaks;
	std::vector<vector3f> whiteStreaks;
	constexpr int NUM_RAYS = 260;
	cyanStreaks.reserve(NUM_RAYS);
	whiteStreaks.reserve(NUM_RAYS * 2);

	const float surgeEase = p * p;
	for (int i = 0; i < NUM_RAYS; ++i) {
		// Deterministic quasi-random angle and radial phase per ray
		const float fi = float(i);
		const float ang = std::fmod(fi * 2.3999632f, 2.0f * float(M_PI));
		const float phase = std::fmod(fi * 0.6180339f + 0.17f * std::sin(fi * 1.31f), 1.0f);
		const float speedFactor = 0.65f + 0.70f * std::fmod(fi * 0.371f, 1.0f);

		const float travel = std::fmod(phase + p * (1.2f + 2.4f * surgeEase) * speedFactor, 1.0f);
		const float rOuter = 18.0f + std::pow(travel, 1.45f) * maxR;
		const float streakLen = (24.0f + 380.0f * surgeEase) * (0.35f + 0.65f * (rOuter / maxR));
		const float rInner = std::max(8.0f, rOuter - streakLen);

		const float dx = std::cos(ang);
		const float dy = std::sin(ang);
		const vector3f p0(cx + dx * rInner, cy + dy * rInner, 0.0f);
		const vector3f p1(cx + dx * rOuter, cy + dy * rOuter, 0.0f);

		if (i % 3 == 0 && p < 0.85f) {
			cyanStreaks.push_back(p0);
			cyanStreaks.push_back(p1);
		} else {
			whiteStreaks.push_back(p0);
			whiteStreaks.push_back(p1);
		}
	}

	if (!cyanStreaks.empty()) {
		const Uint8 alpha = Uint8(Clamp(int((140.0f + 115.0f * p)), 0, 255));
		m_indicator.SetData(cyanStreaks.size(), cyanStreaks.data(), Color(140, 225, 255, alpha));
		m_indicator.Draw(m_renderer, m_indicatorMat.get());
	}
	if (!whiteStreaks.empty()) {
		const Uint8 alpha = Uint8(Clamp(int((185.0f + 70.0f * p)), 0, 255));
		m_indicator.SetData(whiteStreaks.size(), whiteStreaks.data(), Color(255, 255, 255, alpha));
		m_indicator.Draw(m_renderer, m_indicatorMat.get());
	}
}

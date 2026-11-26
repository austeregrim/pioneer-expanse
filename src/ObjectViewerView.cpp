// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "ObjectViewerView.h"
#include "Background.h"
#include "DateTime.h"
#include "FileSystem.h"
#include "Frame.h"
#include "Game.h"
#include "GameConfig.h"
#include "GeoSphere.h"
#include "Pi.h"
#include "Planet.h"
#include "Player.h"
#include "PngWriter.h"
#include "SectorView.h"
#include "Space.h"
#include "SpaceStation.h"
#include "SystemView.h"
#include "WorldView.h"

#include "buildopts.h"
#include "galaxy/StarSystem.h"
#include "galaxy/SystemBody.h"
#include "graphics/Drawables.h"
#include "graphics/Graphics.h"
#include "graphics/Light.h"
#include "graphics/RenderTarget.h"
#include "graphics/Renderer.h"
#include "imgui/imgui.h"
#include "pigui/LuaPiGui.h"
#include "planet/WeatherSystem.h"
#include "profiler/Profiler.h"
#include "utils.h"

#include <ft2build.h>
#include FT_FREETYPE_H

#include <algorithm>
#include <cmath>
#include <ctime>
#include <limits>
#include <vector>

#if WITH_OBJECTVIEWER

namespace {
	static bool s_planetInspectorEnabled = false;
	static bool s_hasPreviewTime = false;
	static double s_previewTime = 0.0;

	static bool IsInspectableBody(const Body *b)
	{
		return b && (b->IsType(ObjectType::TERRAINBODY) || b->IsType(ObjectType::STAR));
	}

	struct PreviewTimeScope {
		bool active = false;
		Graphics::Renderer *renderer = nullptr;
		float prevShaderTime = 0.0f;
		std::vector<Frame::CelestialSnapshot> frameSnap;

		PreviewTimeScope(bool useCustom, double customTime, Graphics::Renderer *r) :
			renderer(r)
		{
			if (!useCustom)
				return;
			active = true;
			Frame::SaveCelestialFrameState(frameSnap);
			Frame::ApplyCelestialTimeForPreview(customTime);
			s_hasPreviewTime = true;
			s_previewTime = customTime;
			if (renderer) {
				prevShaderTime = renderer->GetShaderTime();
				renderer->SetShaderTime(float(std::fmod(std::max(0.0, customTime), 86400.0 * 365.0)));
			}
		}

		~PreviewTimeScope()
		{
			if (!active)
				return;
			Frame::RestoreCelestialFrameState(frameSnap);
			s_hasPreviewTime = false;
			if (renderer) {
				renderer->SetShaderTime(prevShaderTime);
			}
		}
	};

	static void BlendPixelRGB(Uint8 *dst, Uint8 r, Uint8 g, Uint8 b, Uint8 alpha)
	{
		if (alpha == 0)
			return;
		const uint32_t a = alpha;
		const uint32_t inv = 255 - a;
		dst[0] = Uint8((dst[0] * inv + r * a) / 255);
		dst[1] = Uint8((dst[1] * inv + g * a) / 255);
		dst[2] = Uint8((dst[2] * inv + b * a) / 255);
	}

	static void DrawTextToScreendump(
		Graphics::ScreendumpState &sd,
		const std::string &text,
		int startX,
		int topY,
		int pixelSize,
		Uint8 r,
		Uint8 g,
		Uint8 b)
	{
		if (text.empty() || !sd.pixels || sd.width <= 0 || sd.height <= 0)
			return;

		static RefCountedPtr<FileSystem::FileData> s_fontData;
		static FT_Library s_ftLib = nullptr;
		static FT_Face s_ftFace = nullptr;
		static bool s_ftInitTried = false;

		if (!s_ftInitTried) {
			s_ftInitTried = true;
			s_fontData = FileSystem::gameDataFiles.ReadFile("fonts/PionilliumText22L-Medium.ttf");
			if (s_fontData && FT_Init_FreeType(&s_ftLib) == 0) {
				if (FT_New_Memory_Face(s_ftLib,
						reinterpret_cast<const FT_Byte *>(s_fontData->GetData()),
						FT_Long(s_fontData->GetSize()), 0, &s_ftFace) != 0) {
					s_ftFace = nullptr;
				}
			}
		}
		if (!s_ftFace)
			return;

		FT_Set_Pixel_Sizes(s_ftFace, 0, FT_UInt(std::max(8, pixelSize)));
		const int baselineTopY = topY + int(s_ftFace->size->metrics.ascender >> 6);
		const int shadowOffset = std::max(1, pixelSize / 14);

		int penX = startX;
		for (unsigned char ch : text) {
			if (FT_Load_Char(s_ftFace, ch, FT_LOAD_RENDER) != 0)
				continue;

			const FT_GlyphSlot slot = s_ftFace->glyph;
			const FT_Bitmap &bmp = slot->bitmap;
			const int gx0 = penX + slot->bitmap_left;
			const int gy0 = baselineTopY - slot->bitmap_top;

			// Drop shadow pass + foreground pass (ScreendumpState is bottom-up RGB)
			for (int pass = 0; pass < 2; ++pass) {
				const int ox = (pass == 0) ? shadowOffset : 0;
				const int oy = (pass == 0) ? shadowOffset : 0;
				const Uint8 cr = (pass == 0) ? 0 : r;
				const Uint8 cg = (pass == 0) ? 0 : g;
				const Uint8 cb = (pass == 0) ? 0 : b;
				const int alphaScale = (pass == 0) ? 210 : 255;

				for (unsigned int row = 0; row < bmp.rows; ++row) {
					const int imgTopY = gy0 + int(row) + oy;
					if (imgTopY < 0 || imgTopY >= int(sd.height))
						continue;
					const int bufY = (int(sd.height) - 1) - imgTopY;
					const Uint8 *srcRow = bmp.buffer + row * bmp.pitch;
					Uint8 *dstRow = sd.pixels.get() + size_t(bufY) * size_t(sd.stride);

					for (unsigned int col = 0; col < bmp.width; ++col) {
						const int imgX = gx0 + int(col) + ox;
						if (imgX < 0 || imgX >= int(sd.width))
							continue;
						const Uint8 a = Uint8((uint32_t(srcRow[col]) * uint32_t(alphaScale)) / 255u);
						BlendPixelRGB(dstRow + imgX * sd.bpp, cr, cg, cb, a);
					}
				}
			}

			penX += int(slot->advance.x >> 6);
		}
	}
} // namespace

bool ObjectViewerView::IsInspectorEnabled()
{
	return s_planetInspectorEnabled;
}

void ObjectViewerView::SetInspectorEnabled(bool enabled)
{
	s_planetInspectorEnabled = enabled;
}

bool ObjectViewerView::HasPreviewTime()
{
	return s_hasPreviewTime;
}

double ObjectViewerView::GetPreviewTime()
{
	return s_previewTime;
}

ObjectViewerView::ObjectViewerView() :
	View("ObjectViewerView"),
	m_targetBody(nullptr),
	m_systemBody(nullptr),
	m_isTerrainBody(false),
	m_userSelectedBody(false),
	m_returnView(nullptr),
	viewingDist(1000.0f),
	m_camRot(matrix4x4d::Identity),
	m_surfaceMode(false),
	m_showAxes(false),
	m_overrideSun(false),
	m_latDeg(0.0),
	m_lonDeg(0.0),
	m_altitudeM(2000.0),
	m_headingDeg(0.0f),
	m_pitchDeg(5.0f),
	m_rollDeg(0.0f),
	m_sunElevDeg(20.0f),
	m_sunAzimDeg(45.0f),
	m_lastBgIntensity(1.0f),
	m_ignoreEscFirstFrame(false),
	m_useCustomTime(false),
	m_customTime(0.0),
	m_screenshotScaleIndex(1),
	m_pendingCaptureScale(0),
	m_ssIncludeLabel(true),
	m_ssIncludeTelemetry(true)
{
	float znear;
	float zfar;
	Pi::renderer->GetNearFarRange(znear, zfar);

	const float fovY = Pi::config->Float("FOVVertical");
	m_cameraContext.Reset(new CameraContext(Pi::renderer->GetWindowWidth(), Pi::renderer->GetWindowHeight(), fovY, znear, zfar));
	m_camera.reset(new Camera(m_cameraContext, Pi::renderer));

	if (Pi::player) {
		m_cameraContext->SetCameraFrame(Pi::player->GetFrame());
		m_cameraContext->SetCameraPosition(Pi::player->GetInterpPosition() + vector3d(0, 0, viewingDist));
	}
	m_cameraContext->SetCameraOrient(matrix3x3d::Identity);
}

void ObjectViewerView::SetTargetBody(Body *body)
{
	m_targetBody = body;
	m_userSelectedBody = (body != nullptr);
	m_isTerrainBody = false;
	m_systemBody = nullptr;
	if (body) {
		ReloadState();
		const double rad = std::max(body->GetClipRadius(), 100.0);
		viewingDist = float(rad * 2.2);
		m_altitudeM = 2000.0;
	}
}

void ObjectViewerView::ReturnToPreviousView()
{
	if (!Pi::game)
		return;

	View *target = static_cast<View *>(Pi::game->GetWorldView());
	if (m_returnView && (m_returnView == Pi::game->GetWorldView() ||
							m_returnView == Pi::game->GetSystemView() ||
							m_returnView == Pi::game->GetSectorView() ||
							m_returnView == Pi::game->GetInfoView() ||
							m_returnView == Pi::game->GetSpaceStationView())) {
		target = m_returnView;
	}
	Pi::SetView(target);
}

void ObjectViewerView::ValidateTargetBody()
{
	if (!Pi::game || !Pi::game->GetSpace()) {
		m_targetBody = nullptr;
		m_systemBody = nullptr;
		m_isTerrainBody = false;
		return;
	}

	bool found = false;
	if (m_targetBody) {
		for (Body *b : Pi::game->GetSpace()->GetBodies()) {
			if (b == m_targetBody) {
				found = true;
				break;
			}
		}
	}

	if (!found) {
		m_targetBody = nullptr;
		m_systemBody = nullptr;
		m_isTerrainBody = false;
		m_userSelectedBody = false;
	}

	if (!m_userSelectedBody) {
		Body *nav = Pi::player ? Pi::player->GetNavTarget() : nullptr;
		if (IsInspectableBody(nav) && nav != m_targetBody) {
			m_targetBody = nav;
			m_isTerrainBody = false;
			m_systemBody = nullptr;
			ReloadState();
			viewingDist = float(std::max(nav->GetClipRadius(), 100.0) * 2.2);
		}
	}

	if (!m_targetBody) {
		for (Body *b : Pi::game->GetSpace()->GetBodies()) {
			if (IsInspectableBody(b)) {
				m_targetBody = b;
				m_isTerrainBody = false;
				m_systemBody = nullptr;
				ReloadState();
				viewingDist = float(std::max(b->GetClipRadius(), 100.0) * 2.2);
				break;
			}
		}
	}
}

void ObjectViewerView::Draw3D()
{
	PROFILE_SCOPED()
	m_renderer->ClearScreen();

	ValidateTargetBody();
	if (!m_targetBody || !Pi::game || !Pi::game->GetSpace())
		return;

	const int winW = std::max(1, m_renderer->GetWindowWidth());
	const int winH = std::max(1, m_renderer->GetWindowHeight());
	const float fovY = Pi::config ? Pi::config->Float("FOVVertical") : 65.0f;
	if (!m_cameraContext || !m_camera ||
		int(m_cameraContext->GetWidth()) != winW ||
		int(m_cameraContext->GetHeight()) != winH ||
		std::abs(m_cameraContext->GetFovAng() - fovY) > 0.01f) {
		float znear = 0.0f;
		float zfar = 0.0f;
		m_renderer->GetNearFarRange(znear, zfar);
		m_cameraContext.Reset(new CameraContext(float(winW), float(winH), fovY, znear, zfar));
		m_camera.reset(new Camera(m_cameraContext, m_renderer));
	}

	const double bodyRad = std::max(m_targetBody->GetClipRadius(), 100.0);
	const bool shiftHeld = Pi::input->KeyState(SDLK_LSHIFT) || Pi::input->KeyState(SDLK_RSHIFT);

	// Handle RMB look/orbit drag when not interacting with ImGui
	if (!ImGui::GetIO().WantCaptureMouse && Pi::input->MouseButtonState(SDL_BUTTON_RIGHT)) {
		int m[2];
		Pi::input->GetMouseMotion(m);
		const float sens = shiftHeld ? 0.03f : 0.14f;
		if (m_surfaceMode) {
			m_headingDeg = std::fmod(m_headingDeg + sens * float(m[0]) + 360.0f, 360.0f);
			m_pitchDeg = Clamp(m_pitchDeg - sens * float(m[1]), -89.0f, 89.0f);
		} else {
			const double orbSens = shiftHeld ? 0.0004 : 0.002;
			m_camRot = matrix4x4d::RotateXMatrix(-orbSens * m[1]) *
				matrix4x4d::RotateYMatrix(-orbSens * m[0]) * m_camRot;
		}
	}

	// Non-destructively apply custom time/date for full-system celestial rendering & cloud/weather time
	PreviewTimeScope previewScope(m_useCustomTime, m_customTime, m_renderer);

	vector3d camPosBody(0.0, 0.0, double(viewingDist));
	matrix3x3d camOrient = matrix3x3d::Identity;
	matrix3x3d bodyToCam = matrix3x3d::Identity;
	vector3d viewCoords(0.0, 0.0, -double(viewingDist));
	matrix4x4d viewTransform = m_camRot;
	vector3d localUpBody(0.0, 1.0, 0.0);
	double camDistFromCenter = double(viewingDist);

	if (m_surfaceMode) {
		const double latR = DEG2RAD(m_latDeg);
		const double lonR = DEG2RAD(m_lonDeg);
		localUpBody = vector3d(
			std::cos(latR) * std::cos(lonR),
			std::sin(latR),
			std::cos(latR) * std::sin(lonR)).Normalized();

		vector3d eastBody, northBody, enuUp;
		WeatherSystem::BuildLocalENU(localUpBody, eastBody, northBody, enuUp);

		double surfRadM = bodyRad;
		if (m_targetBody->IsType(ObjectType::TERRAINBODY)) {
			surfRadM = static_cast<TerrainBody *>(m_targetBody)->GetTerrainHeight(localUpBody);
		}
		camDistFromCenter = surfRadM + std::max(2.0, m_altitudeM);
		camPosBody = localUpBody * camDistFromCenter;

		const double headingR = DEG2RAD(double(m_headingDeg));
		const double pitchR = DEG2RAD(double(m_pitchDeg));
		const double rollR = DEG2RAD(double(m_rollDeg));
		const vector3d horizDir = (northBody * std::cos(headingR) + eastBody * std::sin(headingR)).Normalized();
		const vector3d forward = (horizDir * std::cos(pitchR) + localUpBody * std::sin(pitchR)).Normalized();
		const vector3d right0 = forward.Cross(localUpBody).NormalizedSafe();
		const vector3d up0 = right0.Cross(forward).NormalizedSafe();
		const vector3d right = (right0 * std::cos(rollR) - up0 * std::sin(rollR)).NormalizedSafe();
		const vector3d upCam = (right0 * std::sin(rollR) + up0 * std::cos(rollR)).NormalizedSafe();

		// Camera orient columns in body space: (+X = right, +Y = upCam, +Z = -forward)
		camOrient = matrix3x3d::FromVectors(right, upCam, -forward);
		bodyToCam = camOrient.Transpose();
		viewTransform = matrix4x4d(bodyToCam);
		viewCoords = bodyToCam * (-camPosBody);
	} else {
		viewTransform = matrix4x4d::RotateZMatrix(-DEG2RAD(double(m_rollDeg))) * m_camRot;
		const matrix3x3d rot3 = viewTransform.GetOrient();
		bodyToCam = rot3;
		camOrient = rot3.Transpose();
		camPosBody = camOrient * vector3d(0.0, 0.0, double(viewingDist));
		localUpBody = camPosBody.NormalizedSafe();
		camDistFromCenter = double(viewingDist);
		viewCoords = vector3d(0.0, 0.0, -double(viewingDist));
	}

	FrameId targetFrameId = m_targetBody->GetFrame();
	if (!targetFrameId.valid() && Pi::player)
		targetFrameId = Pi::player->GetFrame();
	if (!targetFrameId.valid())
		targetFrameId = Pi::game->GetSpace()->GetRootFrame();

	// Compute override directional sun light in camera space if enabled
	vector3d sunDirCam(0.57735, 0.57735, 0.57735);
	if (m_overrideSun) {
		const double elevR = DEG2RAD(double(m_sunElevDeg));
		const double azimR = DEG2RAD(double(m_sunAzimDeg));
		vector3d sunDirBody;
		if (m_surfaceMode) {
			vector3d eastBody, northBody, enuUp;
			WeatherSystem::BuildLocalENU(localUpBody, eastBody, northBody, enuUp);
			sunDirBody =
				(eastBody * std::sin(azimR) + northBody * std::cos(azimR)) * std::cos(elevR) +
				localUpBody * std::sin(elevR);
		} else {
			sunDirBody = vector3d(
				std::cos(elevR) * std::cos(azimR),
				std::sin(elevR),
				std::cos(elevR) * std::sin(azimR)).Normalized();
		}
		sunDirCam = (bodyToCam * sunDirBody).NormalizedSafe();
	}

	// Render full celestial system via Camera::Draw() in scenic mode (no ships/stations)
	m_cameraContext->SetCameraFrame(targetFrameId);
	m_cameraContext->SetCameraPosition(m_targetBody->GetInterpPosition() + camPosBody);
	m_cameraContext->SetCameraOrient(camOrient);
	m_cameraContext->BeginFrame();

	m_camera->SetScenicMode(true);
	m_camera->SetOverrideLight(m_overrideSun, vector3f(sunDirCam), Color::WHITE);
	m_cameraContext->ApplyDrawTransforms(m_renderer);
	m_camera->Update();
	m_camera->Draw();
	m_lastBgIntensity = m_camera->GetBackgroundIntensity();

	if (m_showAxes) {
		matrix4x4d trans = matrix4x4d::Translation(viewCoords) * viewTransform * matrix4x4d::ScaleMatrix(m_targetBody->GetClipRadius() * 2.0);
		m_renderer->SetTransform(matrix4x4f(trans));
		Graphics::Drawables::GetAxes3DDrawable(m_renderer)->Draw(m_renderer);
	}

	m_cameraContext->EndFrame();

	// High-res offscreen scenic screenshot capture (1x / 2x / 4x) without inspector UI
	if (m_pendingCaptureScale > 0) {
		const int reqScale = m_pendingCaptureScale;
		m_pendingCaptureScale = 0;

		const int winW = std::max(1, m_renderer->GetWindowWidth());
		const int winH = std::max(1, m_renderer->GetWindowHeight());
		const int maxTex = std::max(2048, m_renderer->GetMaxTextureSize());
		int capW = winW * reqScale;
		int capH = winH * reqScale;
		if (capW > maxTex || capH > maxTex) {
			const double fit = std::min(double(maxTex) / double(capW), double(maxTex) / double(capH));
			capW = std::max(1, int(std::floor(capW * fit)));
			capH = std::max(1, int(std::floor(capH * fit)));
		}

		Graphics::RenderTargetDesc rtDesc(Uint16(capW), Uint16(capH), Graphics::TEXTURE_RGBA_8888, Graphics::TEXTURE_DEPTH, false, 0);
		std::unique_ptr<Graphics::RenderTarget> rt(m_renderer->CreateRenderTarget(rtDesc));
		if (rt) {
			Graphics::RenderTarget *prevRT = m_renderer->GetRenderTarget();
			const Graphics::ViewportExtents prevVP = m_renderer->GetViewport();

			m_renderer->SetRenderTarget(rt.get());
			m_renderer->SetViewport({ 0, 0, capW, capH });

			float znear = 0.0f, zfar = 0.0f;
			m_renderer->GetNearFarRange(znear, zfar);
			const float fovY = Pi::config->Float("FOVVertical");
			RefCountedPtr<CameraContext> capCtx(new CameraContext(float(capW), float(capH), fovY, znear, zfar));
			Camera capCam(capCtx, m_renderer);
			capCam.SetScenicMode(true);
			capCam.SetOverrideLight(m_overrideSun, vector3f(sunDirCam), Color::WHITE);

			capCtx->SetCameraFrame(targetFrameId);
			capCtx->SetCameraPosition(m_targetBody->GetInterpPosition() + camPosBody);
			capCtx->SetCameraOrient(camOrient);
			capCtx->BeginFrame();
			capCtx->ApplyDrawTransforms(m_renderer);
			capCam.Update();
			capCam.Draw();
			capCtx->EndFrame();

			Graphics::ScreendumpState sd;
			const bool okRead = m_renderer->ScreendumpRenderTarget(rt.get(), sd);

			m_renderer->SetRenderTarget(prevRT);
			m_renderer->SetViewport(prevVP);
			m_cameraContext->ApplyDrawTransforms(m_renderer);

			if (okRead) {
				const double scaleFactor = double(capH) / double(std::max(1, winH));
				if (m_ssIncludeLabel) {
					std::string labelText = m_targetBody->GetLabel();
					const StarSystem *sys = Pi::game->GetSpace()->GetStarSystem().Get();
					if (sys) {
						const SystemPath &sp = sys->GetPath();
						labelText += fmt::format(", {} ({}, {}, {})", sys->GetName(), sp.sectorX, sp.sectorY, sp.sectorZ);
					}
					const int margin = std::max(12, int(std::round(20.0 * scaleFactor)));
					const int fontPx = std::max(16, int(std::round(24.0 * scaleFactor)));
					DrawTextToScreendump(sd, labelText, margin, margin, fontPx, 245, 248, 255);
				}

				if (m_ssIncludeTelemetry) {
					const double activeTime = m_useCustomTime ? m_customTime : Pi::game->GetTime();
					const Time::DateTime dt(activeTime);
					const double altM = m_surfaceMode ? m_altitudeM : std::max(0.0, double(viewingDist) - bodyRad);
					std::string teleText;
					if (m_surfaceMode) {
						teleText = fmt::format(
							"LAT {:+.5f} deg  LON {:+.5f} deg  ALT {}  HDG {:05.1f} deg  PITCH {:+.1f} deg  ROLL {:+.1f} deg  |  {} {}",
							m_latDeg, m_lonDeg, format_distance(altM), m_headingDeg, m_pitchDeg, m_rollDeg,
							dt.ToDateString(), dt.ToTimeString());
					} else {
						const double subLat = RAD2DEG(std::asin(Clamp(localUpBody.y, -1.0, 1.0)));
						const double subLon = RAD2DEG(std::atan2(localUpBody.z, localUpBody.x));
						teleText = fmt::format(
							"ORBIT  SUB-LAT {:+.4f} deg  SUB-LON {:+.4f} deg  ALT {}  ROLL {:+.1f} deg  |  {} {}",
							subLat, subLon, format_distance(altM), m_rollDeg,
							dt.ToDateString(), dt.ToTimeString());
					}
					const int marginX = std::max(12, int(std::round(20.0 * scaleFactor)));
					const int fontPx = std::max(11, int(std::round(14.0 * scaleFactor)));
					const int topY = std::max(8, capH - int(std::round(28.0 * scaleFactor)));
					DrawTextToScreendump(sd, teleText, marginX, topY, fontPx, 215, 224, 238);
				}

				char buf[256];
				const time_t now = time(0);
				struct tm *_tm = localtime(&now);
				strftime(buf, sizeof(buf), "inspector-%Y%m%d-%H%M%S", _tm);
				const std::string fname = fmt::format("{}-{}x.png", buf, reqScale);
				write_screenshot(sd, fname.c_str());
				m_lastScreenshotMsg = fmt::format("Saved screenshots/{} ({}x{})", fname, capW, capH);
			} else {
				m_lastScreenshotMsg = "Screenshot capture failed (readback error)";
			}
		} else {
			m_lastScreenshotMsg = "Screenshot capture failed (RenderTarget error)";
		}
	}
}

void ObjectViewerView::OnSwitchTo()
{
	// rotate X is vertical, rotate Y is horizontal
	m_camRot = matrix4x4d::RotateXMatrix(DEG2RAD(-20.0)) * matrix4x4d::RotateYMatrix(DEG2RAD(-15.0));
	m_ignoreEscFirstFrame = true;
	if (!m_useCustomTime && Pi::game) {
		m_customTime = Pi::game->GetTime();
	}
	ValidateTargetBody();
}

void ObjectViewerView::ReloadState()
{
	if (!m_targetBody)
		return;

	if (m_targetBody->IsType(ObjectType::SPACESTATION)) {
		m_systemBody = static_cast<SpaceStation *>(m_targetBody)->GetSystemBody();
	} else if (m_targetBody->IsType(ObjectType::TERRAINBODY)) {
		m_systemBody = static_cast<TerrainBody *>(m_targetBody)->GetSystemBody();
		m_isTerrainBody = m_systemBody != nullptr;
	}
}

void ObjectViewerView::Update()
{
	ValidateTargetBody();
	if (!m_targetBody)
		return;

	const double dt = Clamp(double(Pi::GetFrameTime()), 0.0, 0.1);
	const bool shiftHeld = Pi::input->KeyState(SDLK_LSHIFT) || Pi::input->KeyState(SDLK_RSHIFT);
	const bool ctrlHeld = Pi::input->KeyState(SDLK_LCTRL) || Pi::input->KeyState(SDLK_RCTRL);

	// Zoom / Altitude controls
	const float keyZoom = shiftHeld ? 0.002f : 0.015f;
	const int wheel = ImGui::GetIO().WantCaptureMouse ? 0 : Pi::input->GetMouseWheel();

	if (m_surfaceMode) {
		const double maxAlt = std::max(m_targetBody->GetClipRadius() * 10.0, 1e8);
		if (!ImGui::GetIO().WantCaptureKeyboard) {
			if (Pi::input->KeyState(SDLK_EQUALS)) m_altitudeM *= (1.0 - keyZoom);
			if (Pi::input->KeyState(SDLK_MINUS)) m_altitudeM *= (1.0 + keyZoom);
		}
		if (wheel != 0) {
			const double step = shiftHeld ? 1.04 : 1.18;
			m_altitudeM *= (wheel > 0) ? (1.0 / step) : step;
		}
		m_altitudeM = Clamp(m_altitudeM, 2.0, maxAlt);
	} else {
		if (!ImGui::GetIO().WantCaptureKeyboard) {
			if (Pi::input->KeyState(SDLK_EQUALS)) viewingDist *= (1.0f - keyZoom);
			if (Pi::input->KeyState(SDLK_MINUS)) viewingDist *= (1.0f + keyZoom);
		}
		if (wheel != 0) {
			const float step = shiftHeld ? 1.03f : 1.15f;
			viewingDist *= (wheel > 0) ? (1.0f / step) : step;
		}
		const float minDist = float(std::max(10.0, m_targetBody->GetClipRadius() * 1.0005));
		viewingDist = Clamp(viewingDist, minDist, 1e12f);
	}

	// Keyboard flight/camera controls: WASD horizontal, Q/E Roll, R/F Pitch (Tilt)
	if (!ImGui::GetIO().WantCaptureKeyboard && dt > 0.0) {
		const double moveMult = shiftHeld ? 0.12 : (ctrlHeld ? 4.0 : 1.0);
		const float rotMult = shiftHeld ? 0.22f : (ctrlHeld ? 2.5f : 1.0f);

		double fwd = 0.0;
		double right = 0.0;
		if (Pi::input->KeyState(SDLK_w)) fwd += 1.0;
		if (Pi::input->KeyState(SDLK_s)) fwd -= 1.0;
		if (Pi::input->KeyState(SDLK_d)) right += 1.0;
		if (Pi::input->KeyState(SDLK_a)) right -= 1.0;

		float rollDelta = 0.0f;
		if (Pi::input->KeyState(SDLK_e)) rollDelta += 1.0f;
		if (Pi::input->KeyState(SDLK_q)) rollDelta -= 1.0f;

		float pitchDelta = 0.0f;
		if (Pi::input->KeyState(SDLK_r)) pitchDelta += 1.0f;
		if (Pi::input->KeyState(SDLK_f)) pitchDelta -= 1.0f;

		if (rollDelta != 0.0f) {
			m_rollDeg += rollDelta * 45.0f * rotMult * float(dt);
			while (m_rollDeg > 180.0f) m_rollDeg -= 360.0f;
			while (m_rollDeg < -180.0f) m_rollDeg += 360.0f;
		}

		if (m_surfaceMode) {
			if (pitchDelta != 0.0f) {
				m_pitchDeg = Clamp(m_pitchDeg + pitchDelta * 35.0f * rotMult * float(dt), -89.0f, 89.0f);
			}
			if (fwd != 0.0 || right != 0.0) {
				const double bodyRad = std::max(m_targetBody->GetClipRadius(), 100.0);
				const double speedMps = std::clamp(m_altitudeM * 0.45, 8.0, bodyRad * 0.25) * moveMult;
				const double dAng = (speedMps * dt) / bodyRad;
				const double hR = DEG2RAD(double(m_headingDeg));
				const double northStep = (fwd * std::cos(hR) - right * std::sin(hR)) * dAng;
				const double eastStep = (fwd * std::sin(hR) + right * std::cos(hR)) * dAng;
				m_latDeg = Clamp(m_latDeg + RAD2DEG(northStep), -89.999, 89.999);
				const double cosLat = std::max(std::cos(DEG2RAD(m_latDeg)), 0.02);
				m_lonDeg += RAD2DEG(eastStep / cosLat);
				while (m_lonDeg >= 180.0) m_lonDeg -= 360.0;
				while (m_lonDeg < -180.0) m_lonDeg += 360.0;
			}
		} else {
			const double orbRate = 0.65 * double(rotMult) * dt;
			if (fwd != 0.0 || pitchDelta != 0.0) {
				const double pitchInput = fwd + double(pitchDelta);
				m_camRot = matrix4x4d::RotateXMatrix(-pitchInput * orbRate) * m_camRot;
			}
			if (right != 0.0) {
				m_camRot = matrix4x4d::RotateYMatrix(-right * orbRate) * m_camRot;
			}
		}
	}
}

void ObjectViewerView::DrawInfoWindow()
{
	const float fps = ImGui::GetIO().Framerate;
	const float ms = (fps > 0.001f) ? (1000.0f / fps) : 0.0f;
	const double altMeters = m_surfaceMode
		? m_altitudeM
		: std::max(0.0, double(viewingDist) - m_targetBody->GetClipRadius());

	const double activeTime = m_useCustomTime ? m_customTime : (Pi::game ? Pi::game->GetTime() : 0.0);
	const Time::DateTime dt(activeTime);

	std::string infoLabel = fmt::format("FPS: {:.1f} ({:.2f} ms) | Body: {} | Alt: {} | Skybox: {:.2f} | {} {}",
		fps, ms, m_targetBody->GetLabel(), format_distance(altMeters), m_lastBgIntensity, dt.ToDateString(), dt.ToTimeString());

	ImVec2 vpSize = ImGui::GetMainViewport()->Size;
	float xpos = ImGui::GetStyle().WindowPadding.x * 2;
	float ypos = vpSize.y - (ImGui::GetTextLineHeightWithSpacing() * 4 + ImGui::GetFrameHeightWithSpacing());

	ImGui::SetNextWindowPos({ xpos, ypos });
	ImGui::SetNextWindowSize({ vpSize.x - xpos, vpSize.y - ypos });
	ImGui::Begin("ObjectViewerView#Info", nullptr, ImGuiWindowFlags_NoBringToFrontOnFocus | ImGuiWindowFlags_NoBackground | ImGuiWindowFlags_NoDecoration);

	ImGui::TextUnformatted(infoLabel.c_str());

	if (m_systemBody)
		ImGui::TextUnformatted(fmt::format("SystemPath: {} {}", m_systemBody->GetName(), to_string(m_systemBody->GetPath())).c_str());

	ImGui::TextUnformatted("Controls: RMB = Heading/Pitch (or Orbit) | WASD = Move | Q/E = Roll | R/F = Tilt | Wheel/+/- = Alt/Dist | Shift = Fine | Esc = Return");

	ImGui::End();
}

namespace ImGui {
	bool DragDouble(const char *label, double *v, double v_speed = 1.0f, double v_min = 0.0f, double v_max = 0.0f, const char *format = "%.3f")
	{
		return DragScalar(label, ImGuiDataType_Double, v, v_speed, &v_min, &v_max, format);
	}
} // namespace ImGui

void ObjectViewerView::DrawControlsWindow()
{
	ImVec2 vpSize = ImGui::GetMainViewport()->Size;

	const float panelW = std::clamp(vpSize.x * 0.24f, 340.0f, 460.0f);
	const float xpos = vpSize.x - panelW - ImGui::GetStyle().WindowPadding.x;
	const float ypos = ImGui::GetStyle().WindowPadding.y;

	ImGui::SetNextWindowPos({ xpos, ypos }, ImGuiCond_Always);
	ImGui::SetNextWindowSize({ panelW, vpSize.y - ypos * 2.0f }, ImGuiCond_Always);
	ImGui::Begin("Planet Inspector##ObjectViewerView", nullptr, ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoResize);

	if (ImGui::Button("Return to Game (Esc)", ImVec2(-1, 0))) {
		ReturnToPreviousView();
		ImGui::End();
		return;
	}

	ImGui::Separator();

	// Body selector dropdown
	if (Pi::game && Pi::game->GetSpace()) {
		const char *preview = m_targetBody ? m_targetBody->GetLabel().c_str() : "<None>";
		if (ImGui::BeginCombo("Inspect Body", preview)) {
			for (Body *b : Pi::game->GetSpace()->GetBodies()) {
				if (!IsInspectableBody(b))
					continue;
				const bool isSelected = (b == m_targetBody);
				if (ImGui::Selectable(b->GetLabel().c_str(), isSelected)) {
					SetTargetBody(b);
				}
				if (isSelected)
					ImGui::SetItemDefaultFocus();
			}
			ImGui::EndCombo();
		}
	}

	ImGui::Separator();
	ImGui::TextUnformatted("Camera Mode & Altitude Presets");
	if (ImGui::RadioButton("Orbital Free-Cam", !m_surfaceMode))
		m_surfaceMode = false;
	ImGui::SameLine();
	if (ImGui::RadioButton("Surface / Horizon", m_surfaceMode))
		m_surfaceMode = true;

	const double bodyRad = m_targetBody ? std::max(m_targetBody->GetClipRadius(), 100.0) : 6371000.0;
	if (ImGui::Button("50 m")) { m_surfaceMode = true; m_altitudeM = 50.0; }
	ImGui::SameLine();
	if (ImGui::Button("2 km")) { m_surfaceMode = true; m_altitudeM = 2000.0; }
	ImGui::SameLine();
	if (ImGui::Button("8 km")) { m_surfaceMode = true; m_altitudeM = 8000.0; }
	ImGui::SameLine();
	if (ImGui::Button("40 km")) { m_surfaceMode = true; m_altitudeM = 40000.0; }
	if (ImGui::Button("Orbit (1.5R)")) { m_surfaceMode = false; viewingDist = float(bodyRad * 1.5); }
	ImGui::SameLine();
	if (ImGui::Button("Far (4R)")) { m_surfaceMode = false; viewingDist = float(bodyRad * 4.0); }
	ImGui::SameLine();
	if (ImGui::Button("Level Camera")) { m_rollDeg = 0.0f; m_pitchDeg = 0.0f; }

	if (m_surfaceMode) {
		ImGui::Text("Pos: Lat %+.6f deg | Lon %+.6f deg", m_latDeg, m_lonDeg);
		const double latMin = -89.999, latMax = 89.999;
		const double lonMin = -180.0, lonMax = 180.0;
		ImGui::SliderScalar("Latitude (deg)", ImGuiDataType_Double, &m_latDeg, &latMin, &latMax, "%.4f deg");
		ImGui::SliderScalar("Longitude (deg)", ImGuiDataType_Double, &m_lonDeg, &lonMin, &lonMax, "%.4f deg");
		ImGui::DragDouble("Altitude (m)", &m_altitudeM, std::max(0.5, m_altitudeM * 0.01), 2.0, bodyRad * 10.0, "%.2f");
		ImGui::SliderFloat("Heading (deg)", &m_headingDeg, 0.0f, 360.0f, "%.2f deg");
		ImGui::SliderFloat("Pitch / Tilt (deg)", &m_pitchDeg, -89.0f, 89.0f, "%.2f deg");
	}
	ImGui::SliderFloat("Roll (deg)", &m_rollDeg, -180.0f, 180.0f, "%.2f deg");

	ImGui::Separator();
	ImGui::TextUnformatted("Inspector System Time & Date");
	bool prevUseCustom = m_useCustomTime;
	if (ImGui::Checkbox("Use Custom Time", &m_useCustomTime)) {
		if (m_useCustomTime && !prevUseCustom && Pi::game) {
			m_customTime = Pi::game->GetTime();
		}
	}
	if (m_useCustomTime) {
		Time::DateTime dt(m_customTime);
		int yr = 3200, mo = 1, dy = 1, hr = 0, mn = 0, sc = 0;
		dt.GetDateParts(&yr, &mo, &dy);
		dt.GetTimeParts(&hr, &mn, &sc);

		bool dtChanged = false;
		ImGui::SetNextItemWidth(72);
		dtChanged |= ImGui::InputInt("Y##insp_yr", &yr, 0, 0);
		ImGui::SameLine();
		ImGui::SetNextItemWidth(44);
		dtChanged |= ImGui::InputInt("M##insp_mo", &mo, 0, 0);
		ImGui::SameLine();
		ImGui::SetNextItemWidth(44);
		dtChanged |= ImGui::InputInt("D##insp_dy", &dy, 0, 0);

		ImGui::SetNextItemWidth(44);
		dtChanged |= ImGui::InputInt("H##insp_hr", &hr, 0, 0);
		ImGui::SameLine();
		ImGui::SetNextItemWidth(44);
		dtChanged |= ImGui::InputInt("Min##insp_mn", &mn, 0, 0);
		ImGui::SameLine();
		ImGui::SetNextItemWidth(44);
		dtChanged |= ImGui::InputInt("S##insp_sc", &sc, 0, 0);

		if (dtChanged) {
			yr = Clamp(yr, 1, 9999);
			mo = Clamp(mo, 1, 12);
			dy = Clamp(dy, 1, 28);
			hr = Clamp(hr, 0, 23);
			mn = Clamp(mn, 0, 59);
			sc = Clamp(sc, 0, 59);
			m_customTime = Time::DateTime(yr, mo, dy, hr, mn, sc).ToGameTime();
		}

		float todHours = float(hr) + float(mn) / 60.0f + float(sc) / 3600.0f;
		if (ImGui::SliderFloat("Time of Day (h)", &todHours, 0.0f, 23.999f, "%.2f h")) {
			const int nHr = Clamp(int(todHours), 0, 23);
			const float remM = (todHours - float(nHr)) * 60.0f;
			const int nMn = Clamp(int(remM), 0, 59);
			const int nSc = Clamp(int((remM - float(nMn)) * 60.0f), 0, 59);
			m_customTime = Time::DateTime(yr, mo, dy, nHr, nMn, nSc).ToGameTime();
		}

		if (ImGui::Button("-1d")) m_customTime -= 86400.0;
		ImGui::SameLine();
		if (ImGui::Button("-1h")) m_customTime -= 3600.0;
		ImGui::SameLine();
		if (ImGui::Button("-10m")) m_customTime -= 600.0;
		ImGui::SameLine();
		if (ImGui::Button("+10m")) m_customTime += 600.0;
		ImGui::SameLine();
		if (ImGui::Button("+1h")) m_customTime += 3600.0;
		ImGui::SameLine();
		if (ImGui::Button("+1d")) m_customTime += 86400.0;
		ImGui::SameLine();
		if (ImGui::Button("Now") && Pi::game) m_customTime = Pi::game->GetTime();
	}

	ImGui::Separator();
	ImGui::TextUnformatted("Scenic Screenshot");
	const int scales[3] = { 1, 2, 4 };
	const int winW = std::max(1, m_renderer->GetWindowWidth());
	const int winH = std::max(1, m_renderer->GetWindowHeight());
	const int maxTex = std::max(2048, m_renderer->GetMaxTextureSize());
	const int curScale = scales[Clamp(m_screenshotScaleIndex, 0, 2)];
	int prevW = winW * curScale;
	int prevH = winH * curScale;
	if (prevW > maxTex || prevH > maxTex) {
		const double fit = std::min(double(maxTex) / double(prevW), double(maxTex) / double(prevH));
		prevW = std::max(1, int(std::floor(prevW * fit)));
		prevH = std::max(1, int(std::floor(prevH * fit)));
	}

	ImGui::RadioButton("1x", &m_screenshotScaleIndex, 0);
	ImGui::SameLine();
	ImGui::RadioButton("2x", &m_screenshotScaleIndex, 1);
	ImGui::SameLine();
	ImGui::RadioButton("4x", &m_screenshotScaleIndex, 2);
	ImGui::SameLine();
	ImGui::Text("(%dx%d)", prevW, prevH);

	ImGui::Checkbox("Body & System Label", &m_ssIncludeLabel);
	ImGui::SameLine();
	ImGui::Checkbox("Telemetry Footer", &m_ssIncludeTelemetry);

	if (ImGui::Button("Capture Screenshot", ImVec2(-1, 0))) {
		m_pendingCaptureScale = curScale;
	}
	if (!m_lastScreenshotMsg.empty()) {
		ImGui::TextWrapped("%s", m_lastScreenshotMsg.c_str());
	}

	ImGui::Separator();
	ImGui::TextUnformatted("Sun Lighting Debug");
	ImGui::Checkbox("Override Sun", &m_overrideSun);
	if (m_overrideSun) {
		const float minElev = m_surfaceMode ? -25.0f : -90.0f;
		m_sunElevDeg = Clamp(m_sunElevDeg, minElev, 90.0f);
		ImGui::SliderFloat("Sun Elevation", &m_sunElevDeg, minElev, 90.0f, "%.1f deg");
		ImGui::SliderFloat("Sun Azimuth", &m_sunAzimDeg, 0.0f, 360.0f, "%.1f deg");
	}

	ImGui::Separator();
	ImGui::TextUnformatted("Quality & Shader Toggles");
	bool enhanced = m_renderer->IsEnhancedGraphicsEnabled();
	if (ImGui::Checkbox("Enhanced Graphics", &enhanced)) {
		m_renderer->SetEnhancedGraphics(enhanced);
		if (Pi::config)
			Pi::config->SetInt("EnhancedGraphics", enhanced ? 1 : 0);
	}

	if (Pi::config) {
		int atmoQ = Clamp(Pi::config->Int("AtmosphereQuality", 3), 0, 4);
		if (ImGui::SliderInt("Atmosphere Quality", &atmoQ, 0, 4))
			Pi::config->SetInt("AtmosphereQuality", atmoQ);

		int waterQ = Clamp(Pi::config->Int("WaterQuality", 2), 0, 3);
		if (ImGui::SliderInt("Water Quality", &waterQ, 0, 3))
			Pi::config->SetInt("WaterQuality", waterQ);

		int scatterQ = Clamp(Pi::config->Int("SurfaceScatterQuality", 3), 0, 4);
		if (ImGui::SliderInt("Scatter Quality", &scatterQ, 0, 4))
			Pi::config->SetInt("SurfaceScatterQuality", scatterQ);

		int detailPlanets = Clamp(Pi::detail.planets, 0, 4);
		if (ImGui::SliderInt("Detail Planets", &detailPlanets, 0, 4)) {
			Pi::detail.planets = detailPlanets;
			Pi::config->SetInt("DetailPlanets", detailPlanets);
			Pi::OnChangeDetailLevel();
		}
	}

	bool wireframe = (GeoSphere::GetDebugFlags() & GeoSphere::DebugFlags::DEBUG_WIREFRAME) != 0;
	if (ImGui::Checkbox("GeoSphere Wireframe", &wireframe)) {
		Uint32 flags = GeoSphere::GetDebugFlags();
		if (wireframe)
			flags |= GeoSphere::DebugFlags::DEBUG_WIREFRAME;
		else
			flags &= ~GeoSphere::DebugFlags::DEBUG_WIREFRAME;
		GeoSphere::SetDebugFlags(flags);
	}
	ImGui::SameLine();
	ImGui::Checkbox("Show Axes", &m_showAxes);

	if (m_systemBody) {
		ImGui::Separator();
		if (ImGui::CollapsingHeader("Planet / Body Details")) {
			ImGui::TextWrapped("%s", m_systemBody->GetAstroDescription().c_str());
			ImGui::Spacing();

			ImGui::Text("Seed: %u (0x%08X)", m_systemBody->GetSeed(), m_systemBody->GetSeed());
			if (m_isTerrainBody) {
				if (const TerrainBody *terrainBody = static_cast<const TerrainBody *>(m_targetBody)) {
					const char *heightFractalName = terrainBody->GetHeightFractalName();
					const char *colorFractalName = terrainBody->GetColorFractalName();
					if (heightFractalName) ImGui::Text("Height fractal: %s", heightFractalName);
					if (colorFractalName) ImGui::Text("Color fractal: %s", colorFractalName);
				}
			}

			ImGui::Spacing();
			ImGui::Text("Radius: %s (%.3f Earths)",
				format_distance(m_systemBody->GetRadius()).c_str(),
				m_systemBody->GetRadiusAsFixed().ToDouble());
			if (m_systemBody->GetSuperType() == SystemBody::SUPERTYPE_STAR) {
				ImGui::Text("Mass: %.3f Sols", m_systemBody->GetMassInSols().ToDouble());
			} else {
				ImGui::Text("Mass: %.3f Earths", m_systemBody->GetMassInEarths().ToDouble());
			}
			const double grav = m_systemBody->CalcSurfaceGravity();
			ImGui::Text("Surface Gravity: %.2f m/s^2 (%.2f g)", grav, grav / 9.80665);
			ImGui::Text("Avg Temperature: %d K (%d C)", m_systemBody->GetAverageTemp(), m_systemBody->GetAverageTemp() - 273);
			ImGui::Text("Rotation Period: %.2f days", m_systemBody->GetRotationPeriodInDays());
			ImGui::Text("Axial Tilt: %.2f deg", RAD2DEG(m_systemBody->GetAxialTilt()));
			ImGui::Text("Rings: %s", m_systemBody->HasRings() ? "Yes" : "No");

			ImGui::Spacing();
			if (m_systemBody->HasAtmosphere()) {
				ImGui::Text("Atmosphere: Yes (Top %s)", format_distance(m_systemBody->GetAtmRadius()).c_str());
				ImGui::Text("Surface Pressure: %.4f atm", m_systemBody->GetAtmSurfacePressure());
				ImGui::Text("Atmo Density: %.4f | Oxidizing: %.3f",
					m_systemBody->GetAtmSurfaceDensity(),
					m_systemBody->GetAtmosOxidizing());
			} else {
				ImGui::TextUnformatted("Atmosphere: None");
			}

			ImGui::Spacing();
			ImGui::Text("Volatile Gas: %.3f | Liquid: %.3f | Ices: %.3f",
				m_systemBody->GetVolatileGas(),
				m_systemBody->GetVolatileLiquid(),
				m_systemBody->GetVolatileIces());
			ImGui::Text("Metallicity: %.3f | Volcanicity: %.3f | Life: %.3f",
				m_systemBody->GetMetallicity(),
				m_systemBody->GetVolcanicity(),
				m_systemBody->GetLife());
		}
	}

	PiGui::RunHandler(Pi::GetFrameTime(), GetViewName() + ".Controls");

	ImGui::End();
}

void ObjectViewerView::DrawPiGui()
{
	if (m_ignoreEscFirstFrame) {
		m_ignoreEscFirstFrame = false;
	} else if (!ImGui::GetIO().WantCaptureKeyboard && ImGui::IsKeyPressed(ImGuiKey_Escape, false)) {
		ReturnToPreviousView();
		return;
	}

	if (m_targetBody) {
		DrawInfoWindow();

		DrawControlsWindow();
	}

	View::DrawPiGui();
}

#endif

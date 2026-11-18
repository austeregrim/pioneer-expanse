// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "DeathView.h"

#include "Camera.h"
#include "Game.h"
#include "GameConfig.h"
#include "Input.h"
#include "Pi.h"
#include "Player.h"
#include "graphics/Graphics.h"
#include "graphics/Renderer.h"
#include "pigui/PiGui.h"
#include "profiler/Profiler.h"
#include "imgui/imgui.h"
#include "imgui/imgui_internal.h"
#include "ship/GunManager.h"
#include "ship/PlayerShipController.h"

#include <cmath>

DeathView::DeathView(Game *game) :
	View("DeathView"),
	m_cameraDist(0.0f),
	m_deathTimer(0.0f),
	m_game(game)
{
	float znear;
	float zfar;
	Pi::renderer->GetNearFarRange(znear, zfar);

	const float fovY = Pi::config->Float("FOVVertical");
	m_cameraContext.Reset(new CameraContext(Pi::renderer->GetWindowWidth(), Pi::renderer->GetWindowHeight(), fovY, znear, zfar));
	m_camera.reset(new Camera(m_cameraContext, Pi::renderer));
}

DeathView::~DeathView() {}

void DeathView::Init()
{
	m_cameraDist = Pi::player->GetClipRadius() * 5.0;
	m_cameraContext->SetCameraFrame(Pi::player->GetFrame());
	m_cameraContext->SetCameraPosition(Pi::player->GetInterpPosition() + vector3d(0, 0, m_cameraDist));
	m_cameraContext->SetCameraOrient(matrix3x3d::Identity);
	m_deathTimer = 0.0f;
	if (Pi::input) {
		Pi::input->ClearAllInput();
	}
	if (Pi::player) {
		if (PlayerShipController *psc = Pi::player->GetPlayerController()) {
			psc->ResetMouseCapture();
		}
		auto gm = Pi::player->GetComponent<GunManager>();
		if (gm) {
			gm->SetAllGroupsFiring(false);
		}
	}
	ImGui::GetIO().ClearInputKeys();
	ImGui::GetIO().ClearInputMouse();
	ImGui::ClearActiveID();
	ImGui::SetWindowFocus(nullptr);
	ImGui::SetMouseCursor(ImGuiMouseCursor_Arrow);
}

void DeathView::OnSwitchTo()
{
}

void DeathView::Update()
{
	assert(Pi::player->IsDead());

	m_deathTimer += Pi::GetFrameTime();
	m_cameraDist += 160.0 * Pi::GetFrameTime();
	m_cameraContext->SetCameraPosition(Pi::player->GetInterpPosition() + vector3d(0, 0, m_cameraDist));
	m_cameraContext->BeginFrame();
	m_camera->Update();
}

void DeathView::Draw3D()
{
	PROFILE_SCOPED()
	m_cameraContext->ApplyDrawTransforms(Pi::renderer);
	m_camera->Draw();
	m_cameraContext->EndFrame();
}

void DeathView::DrawPiGui()
{
	PROFILE_SCOPED()
	const float t = m_deathTimer;
	const ImVec2 scrSize = ImGui::GetIO().DisplaySize;

	if (t < 2.5f) {
		// Phase 1: Hull Breach & Emergency Ejection Alert
		const float pulse = (std::sin(t * 12.0f) > 0.0f) ? 1.0f : 0.4f;
		const float bannerW = 760.0f;
		const float bannerH = 92.0f;

		ImGui::SetNextWindowPos(ImVec2(scrSize.x * 0.5f, 120.0f), ImGuiCond_Always, ImVec2(0.5f, 0.0f));
		ImGui::SetNextWindowSize(ImVec2(bannerW, bannerH));

		ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.7f, 0.06f, 0.06f, 0.75f * pulse));
		ImGui::PushStyleColor(ImGuiCol_Border, ImVec4(1.0f, 0.28f, 0.28f, pulse));
		ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 8.0f);
		ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 2.5f);
		ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(24.0f, 14.0f));

		ImGuiWindowFlags bFlags = ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoInputs |
		                          ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoFocusOnAppearing |
		                          ImGuiWindowFlags_NoMove;

		if (ImGui::Begin("##DeathAlert", nullptr, bFlags)) {
			ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.0f, 1.0f, 1.0f, pulse));
			ImGui::SetWindowFontScale(1.35f);
			ImGui::TextUnformatted("CRITICAL STRUCTURAL FAILURE - HULL DESTROYED");
			ImGui::SetWindowFontScale(1.05f);
			ImGui::Spacing();
			ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.0f, 0.85f, 0.4f, 1.0f));
			ImGui::TextUnformatted(">>> EMERGENCY ESCAPE POD EJECTED <<<");
			ImGui::PopStyleColor(2);
			ImGui::SetWindowFontScale(1.0f);
		}
		ImGui::End();
		ImGui::PopStyleVar(3);
		ImGui::PopStyleColor(2);
	} else {
		// Phase 2: Fade to deep black with SAR Cryo-Stasis Telemetry Monitor
		const float fade = Clamp((t - 2.5f) / 1.0f, 0.0f, 1.0f);

		// Full-screen dark fade overlay
		ImGui::SetNextWindowPos(ImVec2(0, 0));
		ImGui::SetNextWindowSize(scrSize);
		ImGuiWindowFlags bgFlags = ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoInputs |
		                           ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoFocusOnAppearing |
		                           ImGuiWindowFlags_NoBackground;
		if (ImGui::Begin("##DeathFadeBg", nullptr, bgFlags)) {
			ImDrawList *dl = ImGui::GetWindowDrawList();
			dl->AddRectFilled(ImVec2(0, 0), scrSize, IM_COL32(3, 5, 9, int(250 * fade)));
		}
		ImGui::End();

		// Centered Telemetry Monitor Window
		const float boxW = 860.0f;
		const float boxH = 430.0f;
		const ImVec2 center(scrSize.x * 0.5f, scrSize.y * 0.46f);

		ImGui::SetNextWindowPos(center, ImGuiCond_Always, ImVec2(0.5f, 0.5f));
		ImGui::SetNextWindowSize(ImVec2(boxW, boxH));

		ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.025f, 0.045f, 0.07f, fade * 0.98f));
		ImGui::PushStyleColor(ImGuiCol_Border, ImVec4(0.0f, 0.75f, 0.9f, fade * 0.9f));
		ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 12.0f);
		ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 2.0f);
		ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(32.0f, 16.0f));

		ImGuiWindowFlags mFlags = ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoInputs |
		                          ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoFocusOnAppearing |
		                          ImGuiWindowFlags_NoMove;

		if (ImGui::Begin("##StasisTelemetryMonitor", nullptr, mFlags)) {
			// Header accent bar across the top of the monitor window
			ImDrawList *dl = ImGui::GetWindowDrawList();
			const ImVec2 wPos = ImGui::GetWindowPos();
			const ImVec2 wSize = ImGui::GetWindowSize();
			dl->AddRectFilled(wPos, ImVec2(wPos.x + wSize.x, wPos.y + 48.0f), IM_COL32(0, 65, 100, int(250 * fade)), 12.0f, ImDrawFlags_RoundCornersTop);

			const bool isHardcore = (m_game && m_game->IsHardcore());

			ImGui::SetCursorPosY(12.0f);
			if (isHardcore) {
				ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.0f, 0.35f, 0.35f, fade));
				ImGui::SetWindowFontScale(1.2f);
				ImGui::TextUnformatted("HARDCORE IRONMAN CHARTER - NO SEARCH & RESCUE TRANSPONDER");
				ImGui::SetWindowFontScale(1.0f);
				ImGui::PopStyleColor();

				ImGui::SetCursorPosY(68.0f);
				ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.85f, 0.88f, 0.95f, fade));
				ImGui::TextUnformatted("HULL STATUS: CATASTROPHIC DESTRUCTION IN VACUUM");
				ImGui::Spacing();
				ImGui::TextUnformatted("SEARCH & RESCUE PROTOCOLS: VOID UNDER IRONMAN CHARTER TERMS");
				ImGui::Spacing();
				ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.0f, 0.4f, 0.4f, fade));
				ImGui::TextUnformatted("PILOT STATUS: DECEASED  |  VESSEL DESTRUCTION IS FINAL");
				ImGui::PopStyleColor();
				ImGui::Spacing();
				ImGui::Separator();
				ImGui::Spacing();
				if (t >= 4.5f) {
					ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.7f, 0.7f, 0.7f, fade));
					ImGui::TextUnformatted("[+] ARCHIVING FINAL FLIGHT RECORDER LOGS...");
					ImGui::PopStyleColor();
				}
				ImGui::PopStyleColor();
			} else {
				ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.35f, 0.92f, 1.0f, fade));
				ImGui::SetWindowFontScale(1.2f);
				ImGui::TextUnformatted("COSPAS-SARSAT EMERGENCY ESCAPE POD TRANSPONDER");
				ImGui::SetWindowFontScale(1.0f);
				ImGui::PopStyleColor();

				ImGui::SetCursorPosY(68.0f);
				ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.85f, 0.88f, 0.95f, fade));
				ImGui::TextUnformatted("BEACON FREQUENCY: 121.5 MHz / 406.025 MHz (Sub-space Distress Pulse Active)");
				ImGui::Spacing();
				ImGui::TextUnformatted("PILOT VITALS: STABLE  |  LIFE SUPPORT: CRYOGENIC STASIS ENGAGED");
				ImGui::Spacing();

				// Simulated time progress
				const float simulatedDays = Clamp((t - 3.2f) / 3.8f, 0.0f, 1.0f) * 19.8f;
				ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.0f, 0.8f, 0.25f, fade));
				ImGui::Text("TIME ELAPSED IN CRYOGENIC STASIS: %.1f DAYS", simulatedDays);
				ImGui::PopStyleColor();

				ImGui::Spacing();
				ImGui::Separator();
				ImGui::Spacing();

				if (t >= 4.2f) {
					ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.3f, 1.0f, 0.5f, fade));
					ImGui::TextUnformatted("[+] EMERGENCY DISTRESS SIGNAL ACQUIRED BY REGIONAL SAR PATROL");
					ImGui::PopStyleColor();
				}
				if (t >= 5.5f) {
					ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.4f, 0.88f, 1.0f, fade));
					ImGui::TextUnformatted("[+] ESCAPE POD DOCKED ABOARD RESCUE TRANSPORT");
					ImGui::TextUnformatted("[+] TRANSFER EN ROUTE TO REGIONAL STARPORT MEDICAL BAY...");
					ImGui::PopStyleColor();
				}

				ImGui::PopStyleColor();
			}
		}
		ImGui::End();
		ImGui::PopStyleVar(3);
		ImGui::PopStyleColor(2);
	}
}

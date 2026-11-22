// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "HudTrail.h"

#include "Body.h"
#include "Frame.h"
#include "Pi.h"
#include "Player.h"
#include "Ship.h"
#include "graphics/Material.h"
#include "graphics/RenderState.h"
#include "graphics/Renderer.h"
#include "graphics/Types.h"

#include "profiler/Profiler.h"

const float UPDATE_INTERVAL = 0.08f;
const Uint16 MAX_POINTS = 32;
const double MAX_TRAIL_STEP_DIST_SQR = 50000.0 * 50000.0;

HudTrail::HudTrail(Body *b, const Color &c) :
	m_body(b),
	m_updateTime(0.f),
	m_color(c)
{
	Graphics::MaterialDescriptor desc;

	Graphics::RenderStateDesc rsd;
	rsd.blendMode = Graphics::BLEND_ALPHA_ONE;
	rsd.depthWrite = false;
	rsd.primitiveType = Graphics::LINE_STRIP;
	m_lineMat.reset(Pi::renderer->CreateMaterial("vtxColor", desc, rsd, m_lines.GetVertexFormat()));
}

void HudTrail::Update(float time)
{
	PROFILE_SCOPED();
	// Body may already be marked dead (and soon deleted), so do not try to draw a HUD trail
	if (!m_body || m_body->IsDead() || !m_body->GetFrame().valid()) {
		m_trailPoints.clear();
		return;
	}

	// Supercruise ships and player Supercruise/Hyperspace do not show sublight HUD trails
	if ((m_body->IsType(ObjectType::SHIP) && static_cast<const Ship *>(m_body)->GetFlightState() == Ship::SUPERCRUISE) ||
		(Pi::player && (Pi::player->GetFlightState() == Ship::SUPERCRUISE || Pi::player->GetFlightState() == Ship::HYPERSPACE))) {
		m_trailPoints.clear();
		return;
	}

	//record the position relative to the player, the HUD trail then displays the history of this object's trajectory around the player
	m_updateTime += time;
	if (m_updateTime > UPDATE_INTERVAL) {
		m_updateTime = 0.f;
		// Always use a non-rotating frame, so that the relative positions are un-rotated
		Frame *pFrame = Frame::GetFrame(Pi::player->GetFrame());
		if (!pFrame) return;
		FrameId nrf = pFrame->GetNonRotFrame();
		const vector3d relPos = m_body->GetInterpPositionRelTo(nrf) - Pi::player->GetInterpPositionRelTo(nrf);
		if (!m_trailPoints.empty() && (relPos - m_trailPoints.back()).LengthSqr() > MAX_TRAIL_STEP_DIST_SQR)
			m_trailPoints.clear();
		m_trailPoints.emplace_back(relPos);
	}

	while (m_trailPoints.size() > MAX_POINTS)
		m_trailPoints.pop_front();
}

void HudTrail::Render(Graphics::Renderer *r)
{
	PROFILE_SCOPED();
	// Body may already be marked dead (and soon deleted), so do not try to draw a HUD trail
	if (!m_body || m_body->IsDead() || !m_body->GetFrame().valid()) {
		m_trailPoints.clear();
		return;
	}

	// Supercruise ships and player Supercruise/Hyperspace do not show sublight HUD trails
	if ((m_body->IsType(ObjectType::SHIP) && static_cast<const Ship *>(m_body)->GetFlightState() == Ship::SUPERCRUISE) ||
		(Pi::player && (Pi::player->GetFlightState() == Ship::SUPERCRUISE || Pi::player->GetFlightState() == Ship::HYPERSPACE))) {
		m_trailPoints.clear();
		return;
	}

	//render trail relative to the player's current position, this ensures that relative motion is displayed
	if (m_trailPoints.size() > 1) {
		// Set up a transform that includes the player's current position, so that everything we draw is relative to that
		// Always use a non-rotating frame, so that the relative positions are un-rotated
		Frame *pFrame = Frame::GetFrame(Pi::player->GetFrame());
		if (!pFrame) return;
		FrameId nrf = pFrame->GetNonRotFrame();
		const vector3d vpos = m_transform * Pi::player->GetInterpPositionRelTo(nrf);
		m_transform[12] = vpos.x;
		m_transform[13] = vpos.y;
		m_transform[14] = vpos.z;
		m_transform[15] = 1.0;

		static std::vector<vector3f> tvts;
		static std::vector<Color> colors;
		tvts.clear();
		colors.clear();
		tvts.reserve(MAX_POINTS);
		colors.reserve(MAX_POINTS);

		// Start with the object's current position relative to the player (so when we apply the above transform this
		// works out to the object's current position). Then draw a line along the trail history, gradually fading out.
		float alpha = 0.65f;
		const Color tcolor = m_color;
		tvts.emplace_back(m_body->GetInterpPositionRelTo(nrf) - Pi::player->GetInterpPositionRelTo(nrf));
		colors.emplace_back(tcolor.r, tcolor.g, tcolor.b, Uint8(alpha * 255));
		const float decrement = alpha / m_trailPoints.size();
		for (size_t i = m_trailPoints.size() - 1; i > 0; i--) {
			tvts.emplace_back(vector3f(m_trailPoints[i]));
			alpha = std::max(0.f, alpha - decrement);
			colors.emplace_back(tcolor.r, tcolor.g, tcolor.b, Uint8(alpha * 255));
		}

		r->SetTransform(matrix4x4f(m_transform));
		m_lines.SetData(tvts.size(), &tvts[0], &colors[0]);
		m_lines.Draw(r, m_lineMat.get());
	}
}

void HudTrail::Reset(FrameId newFrame)
{
	m_trailPoints.clear();
}

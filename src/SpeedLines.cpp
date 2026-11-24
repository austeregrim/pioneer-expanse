// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "SpeedLines.h"

#include "FileSystem.h"
#include "Frame.h"
#include "Game.h"
#include "Pi.h"
#include "Ship.h"
#include "core/IniConfig.h"
#include "graphics/RenderState.h"
#include "graphics/Renderer.h"
#include "graphics/Types.h"
#include "profiler/Profiler.h"

// default values
float SpeedLines::BOUNDS = 2000.f;
int SpeedLines::DEPTH = 9;
float SpeedLines::SPACING = 750.f;
float SpeedLines::MAX_VEL = 100.f;

SpeedLines::SpeedLines(Ship *s) :
	m_ship(s),
	m_visible(false),
	m_dir(0.f)
{
	PROFILE_SCOPED();

	// init the static data
	SpeedLines::Init();

	m_points.reserve(static_cast<size_t>(DEPTH) * DEPTH * DEPTH);
	for (int x = -DEPTH / 2; x < DEPTH / 2; x++) {
		for (int y = -DEPTH / 2; y < DEPTH / 2; y++) {
			for (int z = -DEPTH / 2; z < DEPTH / 2; z++) {
				m_points.push_back(vector3f(x * SPACING, y * SPACING, z * SPACING));
			}
		}
	}

	const Uint32 doubleNumPoints = static_cast<Uint32>(m_points.size()) * 2;
	m_varray.reset(new Graphics::VertexArray(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE, doubleNumPoints));
	for (Uint32 i = 0; i < doubleNumPoints; i++)
		m_varray->Add(vector3f(0.0f), Color::BLACK);

	CreateVertexBuffer(Pi::renderer, doubleNumPoints);
}

void SpeedLines::Update(float time)
{
	PROFILE_SCOPED();
	if (Pi::game && Pi::game->IsPaused())
		return;
	if (time <= 0.0f)
		return;

	const vector3d velD = m_ship->GetVelocity();
	const double absVelD = velD.Length();

	// don't show if
	//   vel < 100m/s
	//   in rotating frame (near station or planet surface)
	const Frame *frame = Frame::GetFrame(m_ship->GetFrame());
	if (absVelD < 100.0 || (frame && frame->IsRotFrame())) {
		m_visible = false;
		return;
	}
	m_visible = true;

	const bool inSupercruise = (m_ship->GetFlightState() == Ship::SUPERCRUISE);
	const bool inJumpSurge = (m_ship->GetFlightState() == Ship::JUMPING);
	m_dir = vector3f(velD * (1.0 / absVelD));

	float d;
	if (inJumpSurge) {
		const float surge = m_ship->GetHyperspaceJumpSurgeProgress();
		m_lineLength = 120.f + 380.f * (surge * surge);
		d = MAX_VEL * (time * (45.0f + 65.0f * surge));
	} else if (inSupercruise) {
		const double logNorm = Clamp(std::log10(std::max(absVelD, 30000.0) / 30000.0) / 7.3, 0.0, 1.0);
		m_lineLength = float(65.0 + 175.0 * logNorm);
		d = float(35.0 + (MAX_VEL - 35.0) * logNorm) * (time * 60.0f);
	} else {
		const float absVel = float( std::min(absVelD, 1e7) );
		float mult;
		if (absVel > 100000.f)
			mult = 0.001f;
		else if (absVel > 10000.f)
			mult = 0.01f;
		else if (absVel > 5000.f)
			mult = 0.1f;
		else
			mult = 1.f;

		d = absVel * time * mult;
		m_lineLength = Clamp(absVel * 0.1f, 2.f, 100.f);
	}

	vector3f stepVel = m_dir * std::min(d, MAX_VEL);

	for (size_t i = 0; i < m_points.size(); i++) {

		vector3f &pt = m_points[i];

		pt -= stepVel;

		//wrap around
		if (pt.x > BOUNDS)
			pt.x -= BOUNDS * 2.f;
		if (pt.x < -BOUNDS)
			pt.x += BOUNDS * 2.f;
		if (pt.y > BOUNDS)
			pt.y -= BOUNDS * 2.f;
		if (pt.y < -BOUNDS)
			pt.y += BOUNDS * 2.f;
		if (pt.z > BOUNDS)
			pt.z -= BOUNDS * 2.f;
		if (pt.z < -BOUNDS)
			pt.z += BOUNDS * 2.f;
	}
}

void SpeedLines::Render(Graphics::Renderer *r)
{
	PROFILE_SCOPED();
	if (!m_visible || m_points.empty()) return;

	const vector3f dir = m_dir * m_lineLength;

	Uint16 vtx = 0;
	//distance fade
	const bool inSupercruise = m_ship && (m_ship->GetFlightState() == Ship::SUPERCRUISE);
	const bool inJumpSurge = m_ship && (m_ship->GetFlightState() == Ship::JUMPING);
	const float surge = inJumpSurge ? m_ship->GetHyperspaceJumpSurgeProgress() : 0.0f;
	Color col = inJumpSurge ? Color(255, 255, 255, 255) : (inSupercruise ? Color(125, 210, 255, 255) : Color(Color::GRAY));
	for (auto it = m_points.begin(); it != m_points.end(); ++it) {
		const float baseAlpha = inJumpSurge ? (1.0f + 0.45f * surge - it->Length() / BOUNDS) : (1.0f - it->Length() / BOUNDS);
		col.a = Clamp(baseAlpha, 0.f, 1.f) * 255;

		m_varray->Set(vtx, *it - dir, col);
		m_varray->Set(vtx + 1, *it + dir, col);

		vtx += 2;
	}

	m_varray->Populate(m_mesh->GetVertexBuffer());

	r->SetTransform(matrix4x4f(m_transform));
	r->DrawMesh(m_mesh.get(), m_material.Get());
}

void SpeedLines::CreateVertexBuffer(Graphics::Renderer *r, const Uint32 size)
{
	PROFILE_SCOPED();
	Graphics::MaterialDescriptor desc;
	desc.vertexColors = true;

	Graphics::RenderStateDesc rsd;
	rsd.blendMode = Graphics::BLEND_ALPHA_ONE;
	rsd.depthWrite = false;
	rsd.primitiveType = Graphics::LINE_SINGLE;

	auto vbd = Graphics::VertexFormatDesc::FromAttribSet(m_varray->GetAttributeSet());

	m_material.Reset(r->CreateMaterial("unlit", desc, rsd, vbd));
	m_mesh.reset(r->CreateMeshObject(vbd, r->CreateVertexBuffer(Graphics::BUFFER_USAGE_DYNAMIC, size, vbd.bindings[0].stride)));
}

void SpeedLines::Init()
{
	IniConfig cfg;
	cfg.Read(FileSystem::gameDataFiles, "configs/SpeedLines.ini");

	// NB: limit the ranges of all values loaded from the file
	BOUNDS = Clamp(cfg.Float("bounds", 2000.0f), 100.0f, 4000.0f);
	DEPTH = Clamp(cfg.Int("depth", 9), 1, 32);
	SPACING = Clamp(cfg.Float("spacing", 750.0f), 250.0f, 2000.0f);
	MAX_VEL = Clamp(cfg.Float("max_vel", 100.0f), 50.0f, 200.0f);
}

// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "Star.h"

#include "Pi.h"
#include "galaxy/StarSystem.h"
#include "galaxy/SystemBody.h"
#include "graphics/Material.h"
#include "graphics/Renderer.h"
#include "graphics/RenderState.h"
#include "graphics/Types.h"
#include "graphics/VertexArray.h"
#include "graphics/VertexBuffer.h"

Star::Star(SystemBody *sbody) :
	TerrainBody(sbody)
{
	InitStar();
}

Star::Star(const Json &jsonObj, Space *space) :
	TerrainBody(jsonObj, space)
{
	InitStar();
}

Star::~Star()
{
}

void Star::InitStar()
{
	// this one should be atmosphere radius when stars have atmosphere
	SetPhysRadius(GetMaxFeatureRadius());

	// this one is much larger because stars have halo effect
	// if star is wolf-rayet it gets a very large halo effect
	const SystemBody *sbody = GetSystemBody();
	const float wf = (sbody->GetType() < SystemBody::TYPE_STAR_S_BH && sbody->GetType() > SystemBody::TYPE_STAR_O_HYPER_GIANT) ? 100.0f : 1.0f;
	SetClipRadius(sbody->GetRadius() * 8 * wf);

	Graphics::MaterialDescriptor desc;
	desc.vertexColors = true;

	Graphics::RenderStateDesc rsd;
	rsd.blendMode = Graphics::BLEND_ALPHA;
	rsd.depthWrite = false;
	rsd.primitiveType = Graphics::TRIANGLE_FAN;

	auto vtxFormat = Graphics::VertexFormatDesc::FromAttribSet(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE);
	m_haloMat.reset(Pi::renderer->CreateMaterial("vtxColor", desc, rsd, vtxFormat));

	Graphics::MaterialDescriptor coronaDesc;
	Graphics::RenderStateDesc coronaRsd;
	coronaRsd.blendMode = Graphics::BLEND_ALPHA_ONE;
	coronaRsd.depthWrite = false;
	coronaRsd.cullMode = Graphics::CULL_NONE;
	auto coronaVfmt = Graphics::VertexFormatDesc::FromAttribSet(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_UV0);
	m_coronaMat.reset(Pi::renderer->CreateMaterial("star_corona", coronaDesc, coronaRsd, coronaVfmt));
}

void Star::BuildCoronaBuffer(Graphics::Renderer *renderer)
{
	Graphics::VertexArray va(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_UV0);
	va.Add(vector3f(-1.f, -1.f, 0.f), vector2f(0.f, 0.f));
	va.Add(vector3f(1.f, -1.f, 0.f), vector2f(1.f, 0.f));
	va.Add(vector3f(1.f, 1.f, 0.f), vector2f(1.f, 1.f));
	va.Add(vector3f(-1.f, -1.f, 0.f), vector2f(0.f, 0.f));
	va.Add(vector3f(1.f, 1.f, 0.f), vector2f(1.f, 1.f));
	va.Add(vector3f(-1.f, 1.f, 0.f), vector2f(0.f, 1.f));
	m_coronaMesh.reset(renderer->CreateMeshObjectFromArray(&va));
}

void Star::BuildHaloBuffer(Graphics::Renderer *renderer, double rad)
{
	// build halo vertex buffer
	Random rand;
	Graphics::VertexArray va(Graphics::ATTRIB_POSITION | Graphics::ATTRIB_DIFFUSE);
	const Color bright(GetSystemBody()->GetStarColor());
	const Color dark(Color::BLANK);

	va.Add(vector3f(0.f), bright);
	for (float ang = 0; ang < 2 * M_PI; ang += 0.26183 + rand.Double(0, 0.4)) {
		va.Add(vector3f(sin(ang), cos(ang), 0), dark);
	}
	va.Add(vector3f(0.f, 1.f, 0.f), dark);

	//create buffer and upload data
	m_haloMesh.reset(renderer->CreateMeshObjectFromArray(&va));
}

void Star::Render(Graphics::Renderer *renderer, const Camera *camera, const vector3d &viewCoords, const matrix4x4d &viewTransform)
{
	double rad = GetClipRadius();
	vector3d fpos = viewCoords;
	double len = fpos.Length();

	while (len > 1000.0f) {
		rad *= 0.25;
		fpos = 0.25 * fpos;
		len *= 0.25;
	}

	matrix4x4d trans = matrix4x4d::Identity;
	trans.Translate(float(fpos.x), float(fpos.y), float(fpos.z));

	// face the camera dammit
	vector3d zaxis = viewCoords.NormalizedSafe();
	vector3d xaxis = vector3d(0, 1, 0).Cross(zaxis).Normalized();
	vector3d yaxis = zaxis.Cross(xaxis);
	matrix4x4d rot = matrix4x4d::MakeRotMatrix(xaxis, yaxis, zaxis).Inverse();

	// Generate the halo if we don't have one
	if (!m_haloMesh) {
		BuildHaloBuffer(renderer, rad);
	}

	const SystemBody *sbody = GetSystemBody();
	const bool isBlackHole = sbody && (sbody->GetType() >= SystemBody::TYPE_STAR_S_BH && sbody->GetType() <= SystemBody::TYPE_STAR_IM_BH);

	if (renderer->IsEnhancedGraphicsEnabled() && m_coronaMat && !isBlackHole) {
		if (!m_coronaMesh) {
			BuildCoronaBuffer(renderer);
		}
		// Render the star photosphere first, then layer the animated chromosphere, corona streamers, and solar flares
		TerrainBody::Render(renderer, camera, viewCoords, viewTransform);

		constexpr float kCoronaExtentRadii = 2.6f;
		double coronaRad = std::max(GetPhysRadius(), sbody ? sbody->GetRadius() : GetPhysRadius()) * kCoronaExtentRadii;
		vector3d cfpos = viewCoords;
		double clen = cfpos.Length();
		while (clen > 1000.0) {
			coronaRad *= 0.25;
			cfpos = 0.25 * cfpos;
			clen *= 0.25;
		}
		matrix4x4d ctrans = matrix4x4d::Identity;
		ctrans.Translate(float(cfpos.x), float(cfpos.y), float(cfpos.z));

		const Color4f col = sbody ? sbody->GetStarColor().ToColor4f() : Color4f(1.0f, 0.85f, 0.65f, 1.0f);
		static const size_t s_starColorName = "starColor"_hash;
		static const size_t s_starAxisXName = "starAxisX"_hash;
		static const size_t s_starAxisYName = "starAxisY"_hash;
		m_coronaMat->SetPushConstant(s_starColorName, vector3f(col.r, col.g, col.b), kCoronaExtentRadii);

		// Anchor the corona billboard's up-axis to the star's own 3D rotational pole in camera space
		// so coronal plumes and solar prominence flares stay locked to the star instead of rolling with the ship
		vector3d starUp = viewTransform.ApplyRotationOnly(vector3d(0.0, 1.0, 0.0)).NormalizedSafe();
		if (std::abs(starUp.Dot(zaxis)) > 0.995) {
			starUp = viewTransform.ApplyRotationOnly(vector3d(1.0, 0.0, 0.0)).NormalizedSafe();
		}
		vector3d cxaxis = starUp.Cross(zaxis).NormalizedSafe();
		vector3d cyaxis = zaxis.Cross(cxaxis).NormalizedSafe();
		matrix4x4d coronaRot = matrix4x4d::MakeRotMatrix(cxaxis, cyaxis, zaxis).Inverse();

		// Project billboard basis vectors back into the star's 3D rotating frame so shaders evaluate flares on the 3D star surface
		const matrix3x3d camToStar = viewTransform.GetOrient().Transpose();
		const vector3d starAxisX = (camToStar * cxaxis).NormalizedSafe();
		const vector3d starAxisY = (camToStar * cyaxis).NormalizedSafe();
		m_coronaMat->SetPushConstant(s_starAxisXName, vector3f(starAxisX));
		m_coronaMat->SetPushConstant(s_starAxisYName, vector3f(starAxisY));

		renderer->SetTransform(matrix4x4f(ctrans * matrix4x4d::ScaleMatrix(coronaRad) * coronaRot));
		renderer->DrawMesh(m_coronaMesh.get(), m_coronaMat.get());
	} else {
		// Classic Pioneer fallback
		renderer->SetTransform(matrix4x4f(trans * matrix4x4d::ScaleMatrix(rad) * rot));
		renderer->DrawMesh(m_haloMesh.get(), m_haloMat.get());
		TerrainBody::Render(renderer, camera, viewCoords, viewTransform);
	}

	renderer->GetStats().AddToStatCount(Graphics::Stats::STAT_STARS, 1);
}

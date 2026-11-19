// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"
#include "basesphere_uniforms.glsl"

out vec3 varyingEyepos;
out vec3 varyingNormal;
out vec3 objNormal;
out vec3 patchLocalPos;
out vec3 varyingObjX;
out vec3 varyingObjY;
out vec3 varyingObjZ;
out vec4 vertexColor;

out vec2 texCoord0;
out float dist;

#ifdef TERRAIN_WITH_LAVA
out vec4 varyingEmission;
#endif

void main(void)
{
	gl_Position = matrixTransform();
	vertexColor = a_color;
	varyingEyepos = vec3(uViewMatrix * a_vertex);
	mat3 nMat = normalMatrix();
	varyingNormal = normalize(nMat * a_normal);
	objNormal = normalize(a_normal);
	patchLocalPos = a_vertex.xyz;
	varyingObjX = normalize(nMat * vec3(1.0, 0.0, 0.0));
	varyingObjY = normalize(nMat * vec3(0.0, 1.0, 0.0));
	varyingObjZ = normalize(nMat * vec3(0.0, 0.0, 1.0));

	texCoord0 = a_uv0.xy;
	dist = length(varyingEyepos);

#ifdef TERRAIN_WITH_LAVA
	varyingEmission = material.emission;
	//Glow lava terrains
	if ( vertexColor.r > 0.4 && vertexColor.g < 0.2 && vertexColor.b < 0.4 )
	{
		varyingEmission = 3.0*vertexColor;
		varyingEmission *= (vertexColor.r+vertexColor.g+vertexColor.b);
	}
#endif
}

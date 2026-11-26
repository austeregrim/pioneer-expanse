// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

layout (location = 10) in vec4 a_instDiffuse;
layout (location = 11) in vec4 a_instEmissive; // rgb = emissive/skyBounce/spotBoost, a = sunVis [0..1]

#ifdef TEXTURE0
out vec2 texCoord0;
#endif
#ifdef VERTEXCOLOR
out vec4 vertexColor;
#endif
out vec4 instDiffuse;
out vec4 instEmissive;

#if (NUM_LIGHTS > 0)
out vec3 eyePos;
out vec3 normal;
#ifdef MAP_NORMAL
	out vec3 tangent;
	out vec3 bitangent;
#endif
#endif

void main(void)
{
	// a_transform is already constructed in camera view space (meters)
	vec4 viewPos = a_transform * a_vertex;
	gl_Position = uViewProjectionMatrix * viewPos;

	instDiffuse = a_instDiffuse;
	instEmissive = a_instEmissive;

#ifdef VERTEXCOLOR
	vertexColor = a_color;
#endif
#ifdef TEXTURE0
	texCoord0 = a_uv0.xy;
#endif

#if (NUM_LIGHTS > 0)
	eyePos = viewPos.xyz;
	mat3 instRot = mat3(a_transform);
	normal = normalize(instRot * a_normal);
	#ifdef MAP_NORMAL
		tangent = normalize(instRot * a_tangent);
		bitangent = normalize(cross(normal, tangent));
	#endif
#endif
}

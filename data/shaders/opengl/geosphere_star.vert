// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

out vec4 vertexColor;
out vec3 objPos;
out vec3 viewNormal;
out vec3 eyePos;

void main(void)
{
	gl_Position = matrixTransform();
	vertexColor = a_color;
	// GeoPatch vertices are patch-local, whereas a_normal is the continuous unit sphere position
	objPos = normalize(a_normal);
	viewNormal = normalize(normalMatrix() * a_normal);
	eyePos = vec3(uViewMatrix * a_vertex);
}

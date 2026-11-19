// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

out vec3 objPos;
out vec3 viewNormal;
out vec3 eyePos;

void main(void)
{
	gl_Position = matrixTransform();
	objPos = normalize(a_vertex.xyz);
	viewNormal = normalize(normalMatrix() * normalize(a_vertex.xyz));
	eyePos = vec3(uViewMatrix * a_vertex);
}

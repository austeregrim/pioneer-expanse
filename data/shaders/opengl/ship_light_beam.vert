// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

out vec3 vEyePos;
out vec3 vNormal;
out float vAlong;

void main(void)
{
	gl_Position = matrixTransform();
	vEyePos = vec3(uViewMatrix * a_vertex);
	vNormal = normalize(normalMatrix() * a_normal);
	vAlong = a_uv0.x;
}

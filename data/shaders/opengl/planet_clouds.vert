// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

out vec3 eyePos;
flat out vec3 objAxisX;
flat out vec3 objAxisY;
flat out vec3 objAxisZ;

void main(void)
{
	gl_Position = matrixTransform();
	eyePos = vec3(uViewMatrix * a_vertex);
	objAxisX = normalize(uViewMatrix[0].xyz);
	objAxisY = normalize(uViewMatrix[1].xyz);
	objAxisZ = normalize(uViewMatrix[2].xyz);
}

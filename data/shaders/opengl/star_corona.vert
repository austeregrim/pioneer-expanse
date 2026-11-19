// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

out vec2 coronaUV;

void main(void)
{
	gl_Position = matrixTransform();
	coronaUV = a_uv0.xy;
}

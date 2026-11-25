// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

out vec4 v_color;
out float v_pointSize;

uniform vec4 starBoost;

void main(void)
{
	gl_Position = uViewProjectionMatrix * a_vertex;
	float ptSize = (a_normal.z > 0.05) ? (1.0 + a_normal.z * max(starBoost.x, 0.75)) : 1.0;
	gl_PointSize = ptSize;
	v_pointSize = ptSize;
	v_color = a_color;
}

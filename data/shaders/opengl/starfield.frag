// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

uniform sampler2D texture0;
uniform vec4 starBoost;

in vec4 v_color;

out vec4 frag_color;

void main(void)
{
	vec3 starRgb = mix(v_color.rgb, vec3(1.0), clamp(starBoost.z, 0.0, 1.0));
	vec4 boostedColor = vec4(starRgb * max(starBoost.y, 1.0), v_color.a);
	frag_color = (texture(texture0, gl_PointCoord) * boostedColor) * material.emission;
}

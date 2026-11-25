// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

uniform sampler2D texture0;
uniform vec4 starBoost;

in vec4 v_color;
in float v_pointSize;

out vec4 frag_color;

void main(void)
{
	vec3 lifted = pow(max(v_color.rgb, vec3(0.001)), vec3(mix(1.0, 0.50, clamp(starBoost.z, 0.0, 1.0))));
	vec3 starCol = lifted;
	float shape = 1.0;
	if (v_pointSize > 1.05) {
		vec2 d = gl_PointCoord - vec2(0.5);
		float r2 = dot(d, d);
		float core = exp(-r2 * 48.0);
		float halo = exp(-r2 * 9.5) * 0.32;
		shape = core + halo;
		starCol = mix(lifted, vec3(1.0), core * 0.45);
	}
	vec4 boostedColor = vec4(starCol * max(starBoost.y, 1.0) * shape, v_color.a * shape);
	frag_color = boostedColor * material.emission;
}

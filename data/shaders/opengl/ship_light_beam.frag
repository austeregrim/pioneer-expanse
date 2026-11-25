// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

in vec3 vEyePos;
in vec3 vNormal;
in float vAlong;

uniform vec4 beamColor;
uniform float nearFade;

out vec4 frag_color;

void main(void)
{
	float dist = length(vEyePos);
	vec3 V = (dist > 0.0001) ? (-vEyePos / dist) : vec3(0.0, 0.0, 1.0);
	vec3 N = normalize(vNormal);

	float edge = pow(abs(dot(N, V)), 1.55);
	float lengthFade = smoothstep(0.0, 0.06, vAlong) * pow(max(1.0 - vAlong, 0.0), 1.80);
	float cockpitFade = (nearFade > 0.5) ? smoothstep(5.5, 16.0, dist) : smoothstep(0.25, 1.4, dist);

	float intensity = clamp(edge * lengthFade * cockpitFade * beamColor.a, 0.0, 1.0);
	if (intensity <= 0.002)
		discard;

	frag_color = vec4(beamColor.rgb * intensity, 1.0);
}

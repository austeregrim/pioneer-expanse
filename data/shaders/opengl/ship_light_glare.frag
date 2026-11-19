// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

in vec2 vQuadUV;
in vec4 vColor;

out vec4 frag_color;

void main(void)
{
	float r = length(vQuadUV);
	if (r >= 1.0)
		discard;

	float edgeMask = 1.0 - smoothstep(0.68, 1.0, r);
	float glare = vColor.a;

	float core = exp(-r * 9.5) * 1.15;
	float halo = exp(-r * 3.4) * (0.42 + 0.38 * glare);

	float anamorphic = 0.0;
	float starburst = 0.0;
	if (glare > 0.01) {
		anamorphic = exp(-abs(vQuadUV.y) * 24.0) * exp(-abs(vQuadUV.x) * 2.2) * glare * 0.78;
		float ang = atan(vQuadUV.y, vQuadUV.x) + 0.261799;
		float rays = pow(abs(cos(ang * 3.0)), 20.0);
		starburst = rays * exp(-r * 3.0) * smoothstep(0.0, 0.04, r) * glare * 0.68;
	}

	vec3 coreCol = mix(vColor.rgb, vec3(1.0), clamp(exp(-r * 12.0) * 0.75, 0.0, 1.0));
	vec3 glowCol = vColor.rgb * (halo + starburst) + mix(vColor.rgb, vec3(0.85, 0.94, 1.0), 0.35) * anamorphic;
	vec3 finalRGB = (coreCol * core + glowCol) * edgeMask;

	frag_color = vec4(clamp(finalRGB, 0.0, 1.5), 1.0);
}

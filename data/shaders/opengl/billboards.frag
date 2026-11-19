// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

uniform sampler2D texture0;
uniform float coordDownScale;
uniform float enhancedGraphics;
in vec2 uv;

out vec4 frag_color;

void main(void)
{
	if (enhancedGraphics < 0.5) {
#ifdef USE_SPRITE_ATLAS
		frag_color = texture(texture0, (gl_PointCoord * coordDownScale) + uv);
#else
		frag_color = texture(texture0, gl_PointCoord);
#endif
		return;
	}

	// Enhanced Graphics: brighter station/ship lights with crisp radial halo + 4-point optical glare
	vec2 centered = gl_PointCoord * 2.0 - 1.0;
	float dist = length(centered);

	// Sample the center of the sprite atlas tile to obtain the light's true color
	vec2 innerCoord = clamp(centered * 1.75 * 0.5 + 0.5, 0.0, 1.0);
#ifdef USE_SPRITE_ATLAS
	vec4 texCore = texture(texture0, (innerCoord * coordDownScale) + uv);
	vec3 lightTint = texture(texture0, (vec2(0.5) * coordDownScale) + uv).rgb;
#else
	vec4 texCore = texture(texture0, innerCoord);
	vec3 lightTint = texture(texture0, vec2(0.5)).rgb;
#endif

	// Fallback to texCore tint if sprite center is dark
	vec3 tint = max(lightTint, texCore.rgb);
	float edgeFade = 1.0 - smoothstep(0.62, 1.0, dist);

	float halo = exp(-dist * 4.4) * 0.42 * edgeFade;
	float spikeH = exp(-abs(centered.y) * 18.0) * exp(-abs(centered.x) * 2.8) * 0.36 * edgeFade;
	float spikeV = exp(-abs(centered.x) * 20.0) * exp(-abs(centered.y) * 4.2) * 0.18 * edgeFade;

	vec3 coreBoost = texCore.rgb * 1.32;
	vec3 glare = tint * (halo + spikeH + spikeV);
	vec3 hotCenter = vec3(1.0, 0.98, 0.94) * exp(-dist * 10.5) * 0.34 * max(max(tint.r, tint.g), tint.b);

	float alpha = clamp(max(texCore.a, (halo + spikeH + spikeV) * 0.78), 0.0, 1.0);
	frag_color = vec4(coreBoost + glare + hotCenter, alpha);
}

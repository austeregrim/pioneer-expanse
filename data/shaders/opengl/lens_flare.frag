// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

in vec2 screenUV;

// starParams: xy = star NDC [-1..1], z = aspect ratio (w/h), w = overall intensity [0..1]
uniform vec4 starParams;
// starColor: rgb = spectral star color, a = angular disc radius in NDC
uniform vec4 starColor;
// flareParams: x = pinpoint glare/streak factor [0..1] (fades out as star resolves into an orb), y = ghost factor [0..1]
uniform vec4 flareParams;

out vec4 frag_color;

float softDisc(vec2 p, float radius, float softness)
{
	float d = length(p);
	return smoothstep(radius + softness, max(0.0, radius - softness), d);
}

float softRing(vec2 p, float radius, float width)
{
	float d = abs(length(p) - radius);
	return exp(-(d * d) / max(width * width, 0.00001));
}

void main(void)
{
	float intensity = starParams.w;
	if (intensity <= 0.001) {
		discard;
	}

	float aspect = starParams.z;
	vec2 ndc = screenUV * 2.0 - 1.0;
	vec2 starPos = starParams.xy;

	// Aspect-corrected vector from star center to fragment
	vec2 delta = ndc - starPos;
	delta.x *= aspect;
	float dist = length(delta);

	// Scale bloom gently with apparent stellar disc size
	float discScale = clamp(starColor.a * 4.5, 0.25, 2.2);
	vec3 baseCol = clamp(starColor.rgb, vec3(0.15), vec3(1.0));
	vec3 hotCoreCol = mix(baseCol, vec3(1.0), 0.65);
	vec3 coolStreakCol = mix(baseCol, vec3(0.55, 0.78, 1.0), 0.45);

	float pinpoint = clamp(flareParams.x, 0.0, 1.0);
	float ghostScale = clamp(flareParams.y, 0.0, 1.0);

	vec3 accum = vec3(0.0);

	// 1. Radiant stellar glare & wide coronal veil
	// Reduce central washout when star resolves into a visible orb so surface granulation & flares stay crisp
	float coreGlow = exp(-dist * (7.5 / sqrt(discScale))) * (0.12 + 0.43 * pinpoint);
	float coronaHalo = (0.015 * discScale) / (dist * dist + 0.025 * discScale);
	float wideVeil = exp(-dist * 1.9) * 0.12 * clamp(discScale, 0.5, 1.35);
	accum += hotCoreCol * coreGlow + baseCol * (coronaHalo * (0.22 + 0.30 * pinpoint) + wideVeil);

	// 2. Anamorphic horizontal optical streak (fades away as star resolves into an orb / skybox darkens)
	if (pinpoint > 0.005) {
		float streakY = exp(-abs(delta.y) * (58.0 / sqrt(discScale)));
		float streakX = exp(-abs(delta.x) * (1.85 / clamp(discScale, 0.65, 1.5)));
		float streakCore = exp(-abs(delta.y) * 140.0) * exp(-abs(delta.x) * 4.2);
		accum += (coolStreakCol * (streakY * streakX * 0.34) + hotCoreCol * (streakCore * 0.42)) * pinpoint;

		// 3. Delicate 6-point diffraction starburst (only for pinpoint/distant stars)
		float ang = atan(delta.y, delta.x) + 0.261799; // 15-degree rotation
		float rays = pow(abs(cos(ang * 3.0)), 28.0);
		float rayFalloff = exp(-dist * (4.2 / sqrt(discScale))) * smoothstep(0.0, 0.018, dist);
		accum += mix(baseCol, vec3(1.0), 0.35) * rays * rayFalloff * 0.36 * pinpoint;
	}

	// 4. Multi-element optical lens flare ghosts along the star-to-center axis
	// Smoothly attenuate ghosts when the star is very close to the viewport border
	float starEdgeDist = length(starPos);
	float ghostPresence = clamp(1.0 - smoothstep(0.95, 1.45, starEdgeDist), 0.0, 1.0) * clamp(intensity * 1.15, 0.0, 1.0) * ghostScale;

	if (ghostPresence > 0.005) {
		vec2 pAspect = vec2(ndc.x * aspect, ndc.y);
		vec2 sAspect = vec2(starPos.x * aspect, starPos.y);

		// Ghost 1: Warm inner aperture disc
		vec2 g1 = pAspect - (-0.32 * sAspect);
		accum += mix(baseCol, vec3(1.0, 0.78, 0.45), 0.45) * softDisc(g1, 0.048, 0.014) * 0.085 * ghostPresence;

		// Ghost 2: Chromatic dispersion ring (subtle R/G/B radial offset)
		vec2 g2 = pAspect - (-0.68 * sAspect);
		float rRing = softRing(g2, 0.112, 0.016);
		float gRing = softRing(g2, 0.106, 0.015);
		float bRing = softRing(g2, 0.100, 0.016);
		accum += vec3(rRing * 0.95, gRing * 0.85, bRing * 1.05) * baseCol * 0.11 * ghostPresence;

		// Ghost 3: Cool cyan-blue secondary bokeh disc
		vec2 g3 = pAspect - (-1.12 * sAspect);
		accum += vec3(0.45, 0.78, 1.0) * softDisc(g3, 0.072, 0.022) * 0.075 * ghostPresence;

		// Ghost 4: Crisp small counter-ghost near the star
		vec2 g4 = pAspect - (0.42 * sAspect);
		accum += mix(baseCol, vec3(0.75, 0.92, 1.0), 0.5) * softDisc(g4, 0.024, 0.009) * 0.095 * ghostPresence;

		// Ghost 5: Faint wide outer aperture halo
		vec2 g5 = pAspect - (-1.55 * sAspect);
		accum += mix(baseCol, vec3(0.85, 0.65, 1.0), 0.5) * softRing(g5, 0.165, 0.026) * 0.065 * ghostPresence;
	}

	vec3 finalRGB = accum * intensity;
	frag_color = vec4(finalRGB, 1.0);
}

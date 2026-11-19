// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

in vec2 coronaUV;

// starColor: rgb = spectral star color, a = quad half-extent in stellar radii (e.g. 2.6)
uniform vec4 starColor;
uniform float uTime;

out vec4 frag_color;

float hash21(vec2 p)
{
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float noise2D(vec2 p)
{
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm2D(vec2 p)
{
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; ++i) {
		sum += amp * noise2D(p);
		p = p * 2.05 + vec2(9.2, 4.7);
		amp *= 0.5;
	}
	return sum;
}

void main(void)
{
	float extent = max(starColor.a, 1.5);
	vec2 p = (coronaUV * 2.0 - 1.0) * extent;
	float r = length(p);

	// Smoothly fade to zero before quad boundary so there is never a hard edge
	float edgeMask = 1.0 - smoothstep(extent * 0.72, extent * 0.99, r);
	if (edgeMask <= 0.001)
		discard;

	// Use periodic direction vector so noise never has an atan seam
	vec2 dir = p / max(r, 0.0001);
	float t = uTime * 0.14;

	vec3 baseCol = clamp(starColor.rgb, vec3(0.12), vec3(1.0));
	vec3 hotCol = mix(baseCol, vec3(1.0, 0.96, 0.85), 0.65);
	vec3 flareCol = mix(baseCol * vec3(1.15, 0.68, 0.45), hotCol, 0.28);

	// Distance outside stellar photosphere limb (r = 1.0)
	float h = max(0.0, r - 0.97);

	// 1. Tight boiling chromosphere atmosphere hugging the star's limb
	float chromoNoise = fbm2D(dir * 6.5 + vec2(t * 0.7, -t * 0.5));
	float chromosphere = exp(-h * (13.5 - 3.5 * chromoNoise)) * smoothstep(0.88, 1.0, r);

	// 2. Animated radial coronal streamers / plasma plumes
	float streamerNoise = fbm2D(dir * 4.2 + vec2(-t * 0.35, t * 0.25) - dir * (h * 1.4 - t * 0.45));
	float finePlumes = fbm2D(dir * 10.5 - dir * (h * 2.6 - t * 0.85) + vec2(3.1, t * 0.3));
	float plumeMask = smoothstep(0.32, 0.78, streamerNoise * 0.68 + finePlumes * 0.32);
	float streamers = exp(-h * 3.1) * plumeMask * smoothstep(0.92, 1.03, r);

	// 3. Eruptive solar prominence arches & flares licking off active longitudes
	float angle = atan(dir.y, dir.x);
	float archField = 0.0;
	for (int i = 0; i < 4; ++i) {
		float fi = float(i);
		float centerAng = fi * 1.570796 + sin(t * (0.18 + fi * 0.05) + fi * 2.1) * 0.45;
		float dAng = atan(sin(angle - centerAng), cos(angle - centerAng));
		float halfWidth = 0.16 + 0.05 * sin(t * 0.31 + fi * 1.7);
		float u = dAng / halfWidth;
		if (abs(u) < 1.15) {
			float archHeight = (0.14 + 0.11 * sin(t * (0.27 + fi * 0.09) + fi * 3.3)) * max(0.0, 1.0 - u * u);
			float archDist = abs(h - archHeight);
			float loopThickness = 0.018 + 0.014 * finePlumes;
			float loopGlow = exp(-(archDist * archDist) / (loopThickness * loopThickness));
			float wisp = 0.55 + 0.45 * fbm2D(dir * 14.0 + vec2(t * 1.1, fi * 5.0));
			archField += loopGlow * wisp * smoothstep(1.15, 0.65, abs(u)) * smoothstep(0.96, 1.01, r);
		}
	}

	// 4. Soft wide atmospheric corona glow
	float outerCorona = exp(-h * 1.95) * 0.36;

	vec3 col = vec3(0.0);
	col += hotCol * chromosphere * 0.95;
	col += baseCol * (streamers * 0.62 + outerCorona);
	col += flareCol * archField * 0.85;

	col *= edgeMask;
	frag_color = vec4(col, 1.0);
}

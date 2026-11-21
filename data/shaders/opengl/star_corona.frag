// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

in vec2 coronaUV;

// starColor: rgb = spectral star color, a = quad half-extent in stellar radii (e.g. 2.6)
uniform vec4 starColor;
uniform float uTime;

out vec4 frag_color;

float hash31(vec3 p)
{
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float noise3D(vec3 p)
{
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float n000 = hash31(i + vec3(0.0, 0.0, 0.0));
	float n100 = hash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash31(i + vec3(1.0, 1.0, 1.0));

	float nx00 = mix(n000, n100, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx11 = mix(n011, n111, f.x);

	float nxy0 = mix(nx00, nx10, f.y);
	float nxy1 = mix(nx01, nx11, f.y);

	return mix(nxy0, nxy1, f.z);
}

float fbm3D(vec3 p)
{
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; ++i) {
		sum += amp * noise3D(p);
		p = p * 2.03 + vec3(9.2, 4.7, 6.1);
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

	// Use periodic direction vector on a fixed-radius cylinder in 3D noise space:
	// never scale dir by time or radial height, so angular plume frequency stays strictly constant
	vec2 dir = p / max(r, 0.0001);
	float t = mod(uTime * 0.14, 512.0);

	vec3 baseCol = clamp(starColor.rgb, vec3(0.12), vec3(1.0));
	vec3 hotCol = mix(baseCol, vec3(1.0, 0.96, 0.85), 0.65);
	vec3 flareCol = mix(baseCol * vec3(1.15, 0.68, 0.45), hotCol, 0.28);

	// Distance outside stellar photosphere limb (r = 1.0)
	float h = max(0.0, r - 0.97);

	// 1. Tight boiling chromosphere atmosphere hugging the star's limb
	float chromoNoise = fbm3D(vec3(dir * 5.2, t * 0.55));
	float chromosphere = exp(-h * (13.5 - 3.5 * chromoNoise)) * smoothstep(0.88, 1.0, r);

	// 2. Animated radial coronal streamers / plasma plumes (outward advection along orthogonal Z axis)
	float streamerNoise = fbm3D(vec3(dir * 2.3, h * 1.25 - t * 0.38));
	float finePlumes = fbm3D(vec3(dir * 4.6 + vec2(3.1, -1.7), h * 2.10 - t * 0.65));
	float plumeMask = smoothstep(0.34, 0.78, streamerNoise * 0.72 + finePlumes * 0.28);
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
			float wisp = 0.55 + 0.45 * fbm3D(vec3(dir * 6.0, t * 0.8 + fi * 5.0));
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

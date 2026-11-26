// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

in vec2 coronaUV;

// starColor: rgb = spectral star color, a = quad half-extent in stellar radii (e.g. 2.6)
uniform vec4 starColor;
uniform vec3 starAxisX;
uniform vec3 starAxisY;
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

	// Map 2D billboard limb direction into the star's 3D rotating coordinate frame
	// so chromosphere, streamers, and solar flares stay pinned to 3D surface positions regardless of camera orbit/roll
	vec2 dir = p / max(r, 0.0001);
	vec3 limbDir3D = normalize(starAxisX * dir.x + starAxisY * dir.y);
	vec3 starViewDir = normalize(cross(starAxisX, starAxisY));
	float t = mod(uTime * 0.14, 512.0);

	vec3 baseCol = clamp(starColor.rgb, vec3(0.12), vec3(1.0));
	vec3 hotCol = mix(baseCol, vec3(1.0, 0.96, 0.85), 0.65);
	vec3 flareCol = mix(baseCol * vec3(1.15, 0.68, 0.45), hotCol, 0.28);

	// Distance outside stellar photosphere limb (r = 1.0)
	float h = max(0.0, r - 0.97);

	// 1. Tight boiling chromosphere atmosphere hugging the star's limb (3D star-locked)
	float chromoNoise = fbm3D(limbDir3D * 4.8 + vec3(0.0, 0.0, t * 0.45));
	float chromosphere = exp(-h * (13.5 - 3.5 * chromoNoise)) * smoothstep(0.88, 1.0, r);

	// 2. Animated radial coronal streamers / plasma plumes (outward advection along 3D limb normal)
	float streamerNoise = fbm3D(limbDir3D * (2.6 + h * 0.35) - limbDir3D * (t * 0.28));
	float finePlumes = fbm3D(limbDir3D * (5.2 + h * 0.55) + vec3(3.1, -1.7, 2.3) - limbDir3D * (t * 0.48));
	float plumeMask = smoothstep(0.34, 0.78, streamerNoise * 0.72 + finePlumes * 0.28);
	float streamers = exp(-h * 3.1) * plumeMask * smoothstep(0.92, 1.03, r);

	// 3. Eruptive solar prominence arches & flares anchored to 3D active belts on the star
	const vec3 kFlareDirs[8] = vec3[](
		normalize(vec3( 0.94,  0.22,  0.25)),
		normalize(vec3(-0.91, -0.26,  0.32)),
		normalize(vec3( 0.28,  0.34, -0.90)),
		normalize(vec3(-0.32, -0.28, -0.90)),
		normalize(vec3( 0.72, -0.35, -0.60)),
		normalize(vec3(-0.74,  0.38, -0.55)),
		normalize(vec3( 0.45, -0.32,  0.83)),
		normalize(vec3(-0.48,  0.30,  0.82))
	);
	float archField = 0.0;
	for (int i = 0; i < 8; ++i) {
		float fi = float(i);
		// Gentle slow magnetic drift around the fixed 3D active site
		vec3 jitter = vec3(
			sin(t * (0.14 + fi * 0.02) + fi * 2.1),
			cos(t * (0.11 + fi * 0.03) + fi * 1.4) * 0.6,
			cos(t * (0.13 + fi * 0.025) + fi * 3.1)
		) * 0.08;
		vec3 archDir = normalize(kFlareDirs[i] + jitter);

		// Prominences are visible when near the 3D stellar limb relative to the camera
		float viewDot = dot(archDir, starViewDir);
		float limbVis = smoothstep(0.68, 0.18, abs(viewDot));
		if (limbVis <= 0.001)
			continue;

		vec3 archLimb = normalize(archDir - starViewDir * viewDot);
		float dAng = acos(clamp(dot(limbDir3D, archLimb), -1.0, 1.0));
		float halfWidth = 0.15 + 0.045 * sin(t * 0.31 + fi * 1.7);
		float u = dAng / halfWidth;
		if (u < 1.15) {
			float archHeight = (0.14 + 0.10 * sin(t * (0.27 + fi * 0.07) + fi * 3.3)) * max(0.0, 1.0 - u * u);
			float archDist = abs(h - archHeight);
			float loopThickness = 0.018 + 0.014 * finePlumes;
			float loopGlow = exp(-(archDist * archDist) / (loopThickness * loopThickness));
			float wisp = 0.55 + 0.45 * fbm3D(limbDir3D * 6.0 + vec3(0.0, t * 0.65, fi * 5.0));
			archField += loopGlow * wisp * limbVis * smoothstep(1.15, 0.65, u) * smoothstep(0.96, 1.01, r);
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

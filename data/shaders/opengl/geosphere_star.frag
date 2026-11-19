// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

in vec4 vertexColor;
in vec3 objPos;
in vec3 viewNormal;
in vec3 eyePos;

uniform float enhancedGraphics;
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
		p = p * 2.07 + vec3(13.1, 7.7, 5.3);
		amp *= 0.5;
	}
	return sum;
}

void main(void)
{
	vec4 baseCol = material.emission + vertexColor;
	if (enhancedGraphics < 0.5) {
		// Classic Pioneer fallback
		frag_color = baseCol;
		return;
	}

	vec3 N = normalize(viewNormal);
	vec3 V = normalize(-eyePos);
	float NdotV = clamp(dot(N, V), 0.0, 1.0);

	// Animated 3D domain-warped convective granulation & dense boiling plasma
	// objPos is the seamless unit sphere direction from a_normal
	float t = uTime * 0.032;
	vec3 sphereDir = normalize(objPos);
	vec3 p = sphereDir * 12.5;
	vec3 warp = vec3(
		fbm3D(p * 0.75 + vec3(t, -t * 0.6, t * 0.4)),
		fbm3D(p * 0.75 + vec3(-t * 0.5, t * 0.8, 3.7)),
		fbm3D(p * 0.75 + vec3(5.2, -t * 0.4, -t * 0.7))
	);

	// Multi-scale dense solar granulation cells, active regions, and crisp boiling micro-granules
	float granMacro = fbm3D(p * 0.72 + warp * 1.9 + vec3(0.0, t * 0.7, 0.0));
	float granMid = fbm3D(p * 2.4 - warp * 1.6 - vec3(t * 1.0, 0.0, t * 0.5));
	float granFine = fbm3D(p * 6.8 + warp * 1.2 + vec3(-t * 1.3, t * 0.8, 0.0));
	float granMicro = noise3D(p * 18.0 + warp * 2.0 + vec3(t * 1.8, -t * 1.2, t * 0.9));
	float granGrain = noise3D(p * 36.0 - vec3(t * 2.2, t * 1.4, -t * 1.1));

	float plasma = clamp(granMacro * 0.34 + granMid * 0.30 + granFine * 0.20 + granMicro * 0.10 + granGrain * 0.06, 0.0, 1.0);

	// Crisp convective cell ridges & fine solar boiling network
	float filaments = 1.0 - abs(granFine * 2.0 - 1.0);
	filaments = pow(clamp(filaments, 0.0, 1.0), 2.2);
	float microCells = 1.0 - abs(granMicro * 2.0 - 1.0);
	microCells = pow(clamp(microCells, 0.0, 1.0), 1.8);

	// Magnetic sunspot pores and incandescent faculae ridges
	float spotMask = smoothstep(0.24, 0.39, granMacro * 0.82 + granMid * 0.18);
	float faculae = smoothstep(0.60, 0.83, plasma + filaments * 0.22 + microCells * 0.10);

	// Eddington-style limb darkening + softer radiant chromosphere edge
	float limbDark = pow(NdotV, 0.52);
	float chromoRim = pow(1.0 - NdotV, 3.8);

	vec3 starRGB = clamp(baseCol.rgb, vec3(0.08), vec3(1.0));
	vec3 deepCool = starRGB * vec3(0.26, 0.10, 0.04);
	vec3 fieryMid = starRGB * (0.58 + 0.66 * plasma + 0.24 * filaments + 0.12 * microCells);
	vec3 hotCore = mix(starRGB, vec3(1.0, 0.97, 0.88), 0.72);

	// Combine granulation, sunspots, limb darkening, and incandescent faculae
	vec3 surfaceCol = mix(deepCool, fieryMid, spotMask);
	surfaceCol = mix(surfaceCol * 0.50, mix(surfaceCol, hotCore, 0.30), limbDark);
	surfaceCol = mix(surfaceCol, hotCore, faculae * 0.62);

	// Radiant boiling chromosphere rim blending naturally into the solar corona & flares
	vec3 rimCol = mix(starRGB * 1.15, vec3(1.0, 0.82, 0.48), 0.25) * (0.68 + 0.52 * granFine);
	surfaceCol += rimCol * chromoRim * 0.58;

	frag_color = vec4(clamp(surfaceCol, 0.0, 1.0), baseCol.a);
}

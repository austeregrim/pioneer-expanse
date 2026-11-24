// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

in vec2 screenUV;

uniform sampler2D texture0;
// warpParams: x = warpAmount [0..1], y = tanHalfBaseFov, z = tanHalfCapFov, w = aspect (w/h)
uniform vec4 warpParams;
// bloomParams: x = exposureProg [0..1], y = bloomStrength, z = bloomRadius, w = whiteoutFloor
uniform vec4 bloomParams;

out vec4 frag_color;

vec3 sampleBloomTap(vec2 uv, float threshold, float lumaPow)
{
	vec3 c = texture(texture0, clamp(uv, vec2(0.0005), vec2(0.9995))).rgb;
	float luma = max(max(c.r, c.g), c.b);
	float weight = smoothstep(threshold, 1.0, luma);
	float boost = pow(max(luma, 0.0001), lumaPow) / max(luma, 0.0001);
	return c * weight * boost;
}

void main(void)
{
	// screenUV has v=0 at bottom and v=1 at top (OpenGL FBO UV convention passed from quad)
	vec2 ndc = screenUV * 2.0 - 1.0;
	float aspect = max(warpParams.w, 0.1);
	vec2 q = vec2(ndc.x * aspect, ndc.y);
	float r = length(q);
	float rMax = sqrt(aspect * aspect + 1.0);
	float t = clamp(r / rMax, 0.0, 1.0);

	float tanCap = max(warpParams.z, 0.05);
	float thetaMax = atan(rMax * tanCap);
	float thetaRect = atan(r * tanCap);
	float thetaEq = t * thetaMax;
	float thetaOrtho = asin(clamp(t * sin(thetaMax), 0.0, 0.9999));
	float thetaFlat = mix(thetaEq, thetaOrtho, 0.50);
	float theta = mix(thetaRect, thetaFlat, clamp(warpParams.x, 0.0, 1.0));

	vec2 srcUV = screenUV;
	if (r > 1e-5 && warpParams.x > 1e-4) {
		float rSrc = tan(theta) / tanCap;
		vec2 qSrc = q * (rSrc / r);
		srcUV = vec2(qSrc.x / aspect, qSrc.y) * 0.5 + 0.5;
	}
	srcUV = clamp(srcUV, vec2(0.0005), vec2(0.9995));

	vec3 baseCol = texture(texture0, srcUV).rgb;

	float eProg = clamp(bloomParams.x, 0.0, 1.0);
	float threshold = mix(0.28, 0.02, eProg);
	float lumaPow = mix(1.45, 0.65, eProg);

	vec2 invAspect = vec2(1.0 / aspect, 1.0);
	float baseRad = max(bloomParams.z, 0.001);
	float rad1 = baseRad * 0.45;
	float rad2 = baseRad * 1.15;
	float rad3 = baseRad * 2.40;

	vec3 bloomAccum = vec3(0.0);
	const float TAU = 6.28318530718;

	for (int i = 0; i < 8; ++i) {
		float a1 = float(i) * (TAU / 8.0);
		float a2 = a1 + (TAU / 16.0);
		vec2 d1 = vec2(cos(a1), sin(a1)) * invAspect;
		vec2 d2 = vec2(cos(a2), sin(a2)) * invAspect;

		bloomAccum += sampleBloomTap(srcUV + d1 * rad1, threshold, lumaPow) * 0.060;
		bloomAccum += sampleBloomTap(srcUV + d2 * rad2, threshold, lumaPow) * 0.045;
		bloomAccum += sampleBloomTap(srcUV + d1 * rad3, threshold, lumaPow) * 0.028;
	}

	// Outward radial streak bloom for stars and dust lines
	vec2 radialDir = srcUV - vec2(0.5);
	float radLen = length(radialDir);
	if (radLen > 1e-4) {
		vec2 dirN = radialDir / radLen;
		for (int j = 1; j <= 4; ++j) {
			float stepDist = float(j) * baseRad * 0.85;
			float w = 0.055 * (1.0 - float(j - 1) * 0.18);
			bloomAccum += sampleBloomTap(srcUV - dirN * stepDist, threshold, lumaPow) * w;
		}
	}

	float exposure = exp2(eProg * eProg * 7.8);
	vec3 hdr = baseCol * exposure + bloomAccum * (bloomParams.y * exposure * 0.85);

	float maxCh = max(hdr.r, max(hdr.g, hdr.b));
	float bleach = smoothstep(0.75, 2.6, maxCh);
	vec3 col = mix(hdr, vec3(maxCh), bleach * 0.88);
	col += vec3(bloomParams.w);

	frag_color = vec4(clamp(col, 0.0, 1.0), 1.0);
}

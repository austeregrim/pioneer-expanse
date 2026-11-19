// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"
#include "basesphere_uniforms.glsl"

#define WATER_SHINE 16.0

uniform sampler2D texture0;
uniform sampler2D texture1;
in vec2 texCoord0;

in float dist;

in vec3 varyingEyepos;
in vec3 varyingNormal;
in vec3 objNormal;
in vec3 rawAlbedo;
in vec4 vertexColor;

out vec4 frag_color;

uniform float PatchDetailFrequency;
uniform float enhancedGraphics;
uniform float uTime;

#define detailScaleHi (PatchDetailFrequency * 4.0)
#define detailScaleLo (PatchDetailFrequency * 0.5)

float rgeoHash31(vec3 p)
{
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float rgeoNoise3D(vec3 p)
{
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float n000 = rgeoHash31(i + vec3(0.0, 0.0, 0.0));
	float n100 = rgeoHash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = rgeoHash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = rgeoHash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = rgeoHash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = rgeoHash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = rgeoHash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = rgeoHash31(i + vec3(1.0, 1.0, 1.0));

	float nx00 = mix(n000, n100, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx11 = mix(n011, n111, f.x);

	return mix(mix(nx00, nx10, f.y), mix(nx01, nx11, f.y), f.z);
}

float rgeoFbm3D(vec3 p)
{
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; ++i) {
		sum += amp * rgeoNoise3D(p);
		p = p * 2.12 + vec3(7.3, 13.7, 5.1);
		amp *= 0.5;
	}
	return sum;
}

void main(void)
{
	vec4 hidetail = texture(texture0, texCoord0 * detailScaleHi);
	vec4 lodetail = texture(texture1, texCoord0 * detailScaleLo);

	// calculate the detail texture contribution from hi and lo textures
	float hiloMix = exp(-0.004 * dist);
	float detailMix = exp(-0.001 * dist);
	vec4 detailVal = mix(lodetail, hidetail, hiloMix);
	vec4 detailMul = mix(vec4(1.0), detailVal, detailMix);

	// Use the detail value to multiply the final colour before lighting
	vec4 ambient = scene.ambient * vertexColor * 0.f;
	vec4 final = detailMul * vertexColor;

#ifdef ATMOSPHERE
	final = ambient + final;
#else
	// add extra brightness to atmosphere-less planetoids and dim stars
	final = ambient + final * 2.0;
#endif

	if (enhancedGraphics >= 0.5) {
		vec3 tnorm = normalize(varyingNormal);
		vec3 eyenorm = normalize(varyingEyepos);
		vec3 sDir = normalize(objNormal);

		// Multi-scale procedural geological contrast, animated ocean waves/surf, and micro-relief
		float macroGrad = rgeoFbm3D(sDir * 9.0);
		float microDetail = rgeoFbm3D(sDir * 36.0 + vec3(macroGrad * 1.4));
		float fineCrack = rgeoNoise3D(sDir * 110.0);

		float waterMask = 0.0;
		float surfFoam = 0.0;
#ifdef TERRAIN_WITH_WATER
		float blueCheck = smoothstep(0.03, 0.09, rawAlbedo.b);
		float redCheck = 1.0 - smoothstep(0.025, 0.085, rawAlbedo.r);
		waterMask = blueCheck * redCheck;
#endif

		float bumpH = macroGrad * 0.45 + microDetail * 0.40 + fineCrack * 0.15;
		float bumpStrength = 0.45;

#ifdef TERRAIN_WITH_WATER
		if (waterMask > 0.01) {
			// Animated multi-directional ocean wave ripples (works cleanly from orbit down to sea level)
			vec2 wUV = texCoord0 * (detailScaleLo * 6.5);
			float wt = uTime * 1.15;
			float w1 = sin(wUV.x * 5.2 + wUV.y * 3.1 + wt * 1.3);
			float w2 = sin(-wUV.x * 3.7 + wUV.y * 6.4 + wt * 1.7 + 1.4);
			float w3 = rgeoNoise3D(sDir * 180.0 + vec3(uTime * 0.18, -uTime * 0.12, uTime * 0.09)) * 2.0 - 1.0;
			float closeBlend = exp(-0.00018 * dist);
			float waveH = mix(w3 * 0.35, (w1 * 0.38 + w2 * 0.32 + w3 * 0.45), closeBlend);
			bumpH = mix(bumpH, waveH * 0.5 + 0.5, waterMask);
			bumpStrength = mix(bumpStrength, mix(0.28, 0.72, closeBlend), waterMask);

			// Delicate animated coastal surf & whitecap foam along shorelines
			float shoreBand = smoothstep(0.02, 0.25, waterMask) * (1.0 - smoothstep(0.45, 0.92, waterMask));
			float edgeGrad = clamp(fwidth(waterMask) * 6.0, 0.0, 1.0);
			float surfRoll = 0.5 + 0.5 * sin(waterMask * 22.0 - uTime * 2.6 + w3 * 3.5);
			surfFoam = clamp((shoreBand * (0.45 + 0.55 * surfRoll) + edgeGrad * 0.35) * (0.4 + 0.6 * closeBlend), 0.0, 0.85);
		}
#endif

		vec3 dPdx = dFdx(varyingEyepos);
		vec3 dPdy = dFdy(varyingEyepos);
		vec3 bumpGrad = dFdx(bumpH) * normalize(dPdx + vec3(1e-6)) + dFdy(bumpH) * normalize(dPdy + vec3(1e-6));
		vec3 surfNorm = normalize(tnorm - bumpGrad * bumpStrength);

		// Auto-detect icy/frosted terrain from raw vertex albedo (excluding liquid oceans)
		float cMax = max(max(rawAlbedo.r, rawAlbedo.g), rawAlbedo.b);
		float cMin = min(min(rawAlbedo.r, rawAlbedo.g), rawAlbedo.b);
		float sat = (cMax > 0.001) ? (cMax - cMin) / cMax : 0.0;
		float lum = dot(rawAlbedo, vec3(0.2126, 0.7152, 0.0722));
		float coolBias = clamp((rawAlbedo.b - rawAlbedo.r) * 2.5 + 0.5, 0.0, 1.0);
		float iceMask = smoothstep(0.38, 0.72, lum) * (1.0 - smoothstep(0.18, 0.48, sat)) * (0.65 + 0.35 * coolBias) * (1.0 - waterMask);

		// Enrich surface contrast & mineral color gradients on land; keep oceans clean with subtle wave shading
		float contrastMod = mix(0.72, 1.32, clamp(macroGrad * 0.55 + microDetail * 0.45, 0.0, 1.0));
		vec3 mineralTint = mix(vec3(0.90, 0.96, 1.05), vec3(1.07, 0.97, 0.88), macroGrad);
		vec3 icyLift = mix(vec3(1.0), vec3(0.90, 0.98, 1.12), iceMask * 0.55);
		vec3 landMul = contrastMod * mineralTint * icyLift;
		float waveShade = mix(0.92, 1.08, clamp(bumpH, 0.0, 1.0));
		final.rgb *= mix(landMul, vec3(waveShade), waterMask);

#if (NUM_LIGHTS > 0)
		vec3 viewDir = -eyenorm;
		float maxSunLit = 0.0;
		vec3 specAccum = vec3(0.0);

		for (int i = 0; i < NUM_LIGHTS; ++i) {
			vec3 L = normalize(uLight[i].position.xyz);
			float NdotL = max(dot(surfNorm, L), 0.0);
			maxSunLit = max(maxSunLit, NdotL);
			if (NdotL <= 0.0)
				continue;

			vec3 lightCol = toLinear(uLight[i].diffuse.rgb);
			float lMax = max(max(lightCol.r, lightCol.g), lightCol.b);
			float lMin = min(min(lightCol.r, lightCol.g), lightCol.b);
			float lSat = (lMax > 0.001) ? (lMax - lMin) / lMax : 0.0;
			float lLum = dot(lightCol, vec3(0.2126, 0.7152, 0.0722));
			float wbStrength = smoothstep(0.45, 0.88, lSat) * 0.24;
			lightCol = mix(lightCol, vec3(max(lLum, 0.24)), wbStrength);

			vec3 H = normalize(L + viewDir);
			float NdotH = max(dot(surfNorm, H), 0.0);

			// Crisp crystalline specular highlights on ice worlds + subtle silicate sheen on rocky worlds
			float iceGlint = (pow(NdotH, 52.0) * 1.10 + pow(NdotH, 11.0) * 0.28) * (0.72 + 0.55 * microDetail);
			float rockSpec = (pow(NdotH, 22.0) * 0.24 + pow(NdotH, 8.0) * 0.09) * smoothstep(0.35, 0.80, microDetail);
			vec3 iceSpecCol = mix(lightCol, vec3(0.84, 0.94, 1.0), 0.52);
			vec3 rockSpecCol = mix(lightCol, vec3(1.0, 0.95, 0.88), 0.28);

			// Rippling ocean sun sparkle + coastal surf foam illumination
			float waterSpec = (pow(NdotH, 110.0) * 1.65 + pow(NdotH, 18.0) * 0.24) * waterMask * (1.0 - surfFoam * 0.8);
			vec3 landSpec = (iceSpecCol * iceGlint * iceMask + rockSpecCol * rockSpec * (1.0 - iceMask * 0.65)) * (1.0 - waterMask);
			vec3 foamLight = lightCol * vec3(0.90, 0.94, 0.98) * surfFoam * 0.55;
			specAccum += (landSpec + lightCol * waterSpec + foamLight) * NdotL;
		}

		final.rgb += specAccum;

#ifdef ATMOSPHERE
		// Visible atmospheric Fresnel limb halo (strictly dark on the night side!)
		float NdotV = clamp(dot(tnorm, viewDir), 0.0, 1.0);
		float limb = pow(1.0 - NdotV, 3.2);
		vec3 atmoTint = toLinear(mix(atmosColor.rgb, vec3(0.62, 0.86, 1.0), 0.35 + 0.30 * iceMask));
		float litFactor = smoothstep(0.0, 0.16, maxSunLit) * pow(maxSunLit, 0.55);
		final.rgb += atmoTint * limb * litFactor * 0.82;
#endif
#endif // NUM_LIGHTS > 0
	}

	frag_color = final;
#ifdef TERRAIN_WITH_LAVA
	frag_color += vertexColor;
#endif

	frag_color = toSRGB(1 - exp(-frag_color));
}

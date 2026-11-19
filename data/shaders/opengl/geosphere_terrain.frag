// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"
#include "basesphere_uniforms.glsl"

#define WATER_SHINE 16.0

uniform sampler2D texture0;
uniform sampler2D texture1;
in vec2 texCoord0;

uniform int NumShadows;
uniform float enhancedGraphics;
uniform float uTime;

in float dist;

in vec3 varyingEyepos;
in vec3 varyingNormal;
in vec3 objNormal;
in vec4 vertexColor;

#ifdef TERRAIN_WITH_LAVA
in vec4 varyingEmission;
#endif

out vec4 frag_color;

uniform float PatchDetailFrequency;

#define detailScaleHi (PatchDetailFrequency * 4.0)
#define detailScaleLo (PatchDetailFrequency * 0.5)

float geoHash31(vec3 p)
{
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float geoNoise3D(vec3 p)
{
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float n000 = geoHash31(i + vec3(0.0, 0.0, 0.0));
	float n100 = geoHash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = geoHash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = geoHash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = geoHash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = geoHash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = geoHash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = geoHash31(i + vec3(1.0, 1.0, 1.0));

	float nx00 = mix(n000, n100, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx11 = mix(n011, n111, f.x);

	return mix(mix(nx00, nx10, f.y), mix(nx01, nx11, f.y), f.z);
}

float geoFbm3D(vec3 p)
{
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; ++i) {
		sum += amp * geoNoise3D(p);
		p = p * 2.12 + vec3(7.3, 13.7, 5.1);
		amp *= 0.5;
	}
	return sum;
}

void main(void)
{
	vec4 hidetail = texture(texture0, texCoord0 * detailScaleHi);
	vec4 lodetail = texture(texture1, texCoord0 * detailScaleLo);

	vec3 eyeposScaled = varyingEyepos * geosphereInvRadius;
	vec3 eyenorm = normalize(varyingEyepos);
	vec3 tnorm = normalize(varyingNormal);
	vec4 diff = vec4(0.0);

	float surfaceDist = dist * geosphereInvRadius;

	// calculate the detail texture contribution from hi and lo textures
	float hiloMix = exp(-0.004 * dist);
	float detailMix = exp(-0.001 * dist);
	vec4 detailVal = mix(lodetail, hidetail, hiloMix);
	vec4 detailMul = mix(vec4(1.0), detailVal, detailMix);

#ifdef TERRAIN_WITH_WATER
	float specularReflection=0.0;
#endif

#if (NUM_LIGHTS > 0)
	vec3 V = normalize(eyeposScaled - geosphereCenter);

	// Enhanced Graphics: multi-scale geological contrast, animated ocean waves/surf, icy/mineral speculars, and sunlit limb glow
	bool enhanced = (enhancedGraphics >= 0.5);
	vec3 surfNorm = tnorm;
	float macroGrad = 0.5;
	float microDetail = 0.5;
	float iceMask = 0.0;
	float waterMask = 0.0;
	float surfFoam = 0.0;
	vec3 enhancedSpec = vec3(0.0);
	float maxSunLit = 0.0;

	if (enhanced) {
		vec3 sDir = normalize(objNormal);
		macroGrad = geoFbm3D(sDir * 9.0);
		microDetail = geoFbm3D(sDir * 36.0 + vec3(macroGrad * 1.4));
		float fineCrack = geoNoise3D(sDir * 110.0);

#ifdef TERRAIN_WITH_WATER
		// Smooth water mask (1.0 open ocean, 0.0..1.0 along shoreline, 0.0 land)
		float blueCheck = smoothstep(0.03, 0.09, vertexColor.b);
		float redCheck = 1.0 - smoothstep(0.025, 0.085, vertexColor.r);
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
			float w3 = geoNoise3D(sDir * 180.0 + vec3(uTime * 0.18, -uTime * 0.12, uTime * 0.09)) * 2.0 - 1.0;
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
		surfNorm = normalize(tnorm - bumpGrad * bumpStrength);

		// Detect icy / frosted surfaces (exclude liquid oceans)
		float cMax = max(max(vertexColor.r, vertexColor.g), vertexColor.b);
		float cMin = min(min(vertexColor.r, vertexColor.g), vertexColor.b);
		float sat = (cMax > 0.001) ? (cMax - cMin) / cMax : 0.0;
		float lum = dot(vertexColor.rgb, vec3(0.2126, 0.7152, 0.0722));
		float coolBias = clamp((vertexColor.b - vertexColor.r) * 2.5 + 0.5, 0.0, 1.0);
		iceMask = smoothstep(0.38, 0.72, lum) * (1.0 - smoothstep(0.18, 0.48, sat)) * (0.65 + 0.35 * coolBias) * (1.0 - waterMask);
	}

	for (int i=0; i<NUM_LIGHTS; ++i) {
		vec3 L = normalize(uLight[i].position.xyz);
		float uneclipsed = clamp(calcUneclipsed(eclipse, NumShadows, V, L), 0.0, 1.0);
		vec4 lightDiff = uLight[i].diffuse;
		if (enhanced) {
			// Only apply gentle white-balance when starlight is strongly monochrome (e.g. deep M-dwarfs)
			float lMax = max(max(lightDiff.r, lightDiff.g), lightDiff.b);
			float lMin = min(min(lightDiff.r, lightDiff.g), lightDiff.b);
			float lSat = (lMax > 0.001) ? (lMax - lMin) / lMax : 0.0;
			float lLum = dot(lightDiff.rgb, vec3(0.2126, 0.7152, 0.0722));
			float wbStrength = smoothstep(0.45, 0.88, lSat) * 0.24;
			lightDiff.rgb = mix(lightDiff.rgb, vec3(max(lLum, 0.26)), wbStrength);
		}
		CalcPlanetDiffuse(diff, lightDiff, L, surfNorm, uneclipsed);

		if (enhanced) {
			float NdotL = max(dot(surfNorm, L), 0.0) * uneclipsed;
			maxSunLit = max(maxSunLit, NdotL);
			vec3 viewDir = -eyenorm;
			vec3 H = normalize(L + viewDir);
			float NdotH = max(dot(surfNorm, H), 0.0);

			// Crystalline specular glint on icy terrain + subtle mineral/silicate sheen on rocky worlds
			float iceGlint = (pow(NdotH, 54.0) * 0.85 + pow(NdotH, 12.0) * 0.24) * (0.7 + 0.6 * microDetail);
			float rockSpec = (pow(NdotH, 24.0) * 0.22 + pow(NdotH, 8.0) * 0.08) * smoothstep(0.35, 0.80, microDetail);
			vec3 iceSpecCol = mix(lightDiff.rgb, vec3(0.84, 0.94, 1.0), 0.48);
			vec3 rockSpecCol = mix(lightDiff.rgb, vec3(1.0, 0.95, 0.88), 0.25);

			// Rippling ocean sun sparkle & grazing Fresnel sky reflection
			float waterSpec = (pow(NdotH, 96.0) * 1.45 + pow(NdotH, 16.0) * 0.22) * waterMask * (1.0 - surfFoam * 0.8);
			vec3 landSpec = (iceSpecCol * iceGlint * iceMask + rockSpecCol * rockSpec * (1.0 - iceMask * 0.65)) * (1.0 - waterMask);
			enhancedSpec += (landSpec + lightDiff.rgb * waterSpec) * NdotL;
		}

#ifdef TERRAIN_WITH_WATER
		//water only for specular
	    if (vertexColor.b > 0.05 && vertexColor.r < 0.05) {
			CalcPlanetSpec(specularReflection, uLight[i], L, surfNorm, eyenorm, WATER_SHINE);
		}
#endif
	}

	vec4 surfAlbedo = vertexColor;
	if (enhanced) {
		// Richer geological gradient & surface contrast (land only; keep oceans clean with subtle coastal surf foam)
		float contrastMod = mix(0.74, 1.28, clamp(macroGrad * 0.55 + microDetail * 0.45, 0.0, 1.0));
		vec3 mineralTint = mix(vec3(0.92, 0.96, 1.04), vec3(1.06, 0.98, 0.90), macroGrad);
		vec3 icyLift = mix(vec3(1.0), vec3(0.92, 0.98, 1.08), iceMask * 0.55);
		vec3 landAlbedo = clamp(surfAlbedo.rgb * contrastMod * mineralTint * icyLift, 0.0, 1.25);
		vec3 waterAlbedo = mix(surfAlbedo.rgb, vec3(0.88, 0.93, 0.98), surfFoam * 0.72);
		surfAlbedo.rgb = mix(landAlbedo, waterAlbedo, waterMask);
	}

	// Use the detail value to multiply the final colour before lighting
	vec4 ambient = scene.ambient * surfAlbedo;
	vec4 final = surfAlbedo * detailMul * diff;

#ifdef ATMOSPHERE
	float ldprod=0.0;
	float fogFactor=0.0;
	CalcPlanetFogFactor(ldprod, fogFactor, eyenorm, eyeposScaled - geosphereCenter, surfaceDist);

	//calculate sunset tone red when passing through more atmosphere, clamp everything.
	float atmpower = (diff.r+diff.g+diff.b)/3.0;
	vec4 sunset = vec4(0.8,clamp(pow(atmpower,0.8),0.0,1.0),clamp(pow(atmpower,1.2),0.0,1.0),1.0);

	final = fogFactor * (ambient + final);
#else
	// add extra brightness to atmosphere-less planetoids and dim stars
	final = ambient + final * 2.0;
#endif

	if (enhanced) {
		final.rgb += enhancedSpec * 1.15;
	}

	frag_color =
		material.emission +
#ifdef TERRAIN_WITH_LAVA
		varyingEmission +
#endif
		final;

#ifdef ATMOSPHERE
	frag_color +=
		(1.0-fogFactor) * (diff*atmosColor) +
#ifdef TERRAIN_WITH_WATER
		  diff * specularReflection * sunset +
#endif
		  (0.02-clamp(fogFactor,0.0,0.01))*diff*ldprod*sunset +	      //increase fog scatter
		  (pow((1.0-pow(fogFactor,0.75)),256.0)*0.4*diff*atmosColor)*sunset;  //distant fog.

	if (enhanced) {
		// Visible atmospheric Fresnel limb halo (strictly dark on the night side!)
		float NdotV = clamp(dot(tnorm, -eyenorm), 0.0, 1.0);
		float limb = pow(1.0 - NdotV, 3.1);
		vec3 atmoTint = mix(atmosColor.rgb, vec3(0.65, 0.85, 1.0), 0.35 + 0.25 * iceMask);
		float litFactor = smoothstep(0.0, 0.16, maxSunLit) * pow(maxSunLit, 0.55);
		frag_color.rgb += atmoTint * limb * litFactor * 0.72;
	}
#endif //ATMOSPHERE

#else // NUM_LIGHTS > 0 -- unlit rendering - stars
	//emission is used to boost colour of stars, which is a bit odd
	frag_color = material.emission + vertexColor;
#endif
}

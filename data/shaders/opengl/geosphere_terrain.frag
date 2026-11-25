// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"
#include "basesphere_uniforms.glsl"
#include "spotlights.glsl"

#define WATER_SHINE 16.0

uniform sampler2D texture0;
uniform sampler2D texture1;
uniform sampler2D oceanTexA;
uniform sampler2D oceanTexB;
in vec2 texCoord0;

uniform int NumShadows;
uniform vec3 PatchTileOffset;
uniform vec4 WaterParams;
uniform float enhancedGraphics;
uniform float uTime;
uniform vec4 CloudWeather;

in float dist;

in vec3 varyingEyepos;
in vec3 varyingNormal;
in vec3 objNormal;
in vec3 patchLocalPos;
in vec3 varyingObjX;
in vec3 varyingObjY;
in vec3 varyingObjZ;
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
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);

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
	for (int i = 0; i < 3; ++i) {
		sum += amp * geoNoise3D(p);
		p = p * 2.12 + vec3(7.3, 13.7, 5.1);
		amp *= 0.5;
	}
	return sum * (1.0 / 0.875);
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

	// Enhanced Graphics: multi-scale geological contrast, tri-planar PBR multi-splat (cliff strata / scree / regolith),
	// animated ocean waves/surf, icy/mineral speculars, and sunlit limb glow
	bool enhanced = (enhancedGraphics >= 0.5);
	vec3 surfNorm = tnorm;
	float macroGrad = 0.5;
	float microDetail = 0.5;
	float iceMask = 0.0;
	float waterMask = 0.0;
	float surfFoam = 0.0;
	float waterTurb = 0.5;
	float cliffMask = 0.0;
	float screeMask = 0.0;
	float triAlbedoMod = 1.0;
	vec3 triTint = vec3(1.0);
	float matRoughness = 0.85;
	vec3 enhancedSpec = vec3(0.0);
	float maxSunLit = 0.0;
	float lavaMask = 0.0;
	float charredRim = 0.0;
	vec3 lavaGlow = vec3(0.0);

	if (enhanced) {
		vec3 sDir = normalize(objNormal);

		float metersPerViewUnit = geosphereRadius * geosphereInvRadius;
		float distMeters = dist * metersPerViewUnit;

		// Seamless world-locked tri-planar coordinates (exact modulo 4096m across all GeoPatch boundaries)
		vec3 worldM = patchLocalPos * geosphereRadius + PatchTileOffset;
		vec3 triW = pow(abs(sDir), vec3(4.0));
		triW /= max(triW.x + triW.y + triW.z, 1e-5);

		// Multi-octave orbital-to-ground distance fades (1024m, 256m, 32m, 8m)
		float macroFade = exp(-0.000018 * distMeters);
		float midFade = exp(-0.00008 * distMeters);
		float closeFade = exp(-0.00045 * distMeters);
		float microFade = exp(-0.0022 * distMeters);

		float rawWater = 0.0;
#ifdef TERRAIN_WITH_WATER
		float blueCheck = smoothstep(0.04, 0.095, vertexColor.b);
		float redCheck = 1.0 - smoothstep(0.01, 0.12, vertexColor.r);
		float blueDom = smoothstep(0.03, 0.09, vertexColor.b - vertexColor.r);
		rawWater = blueCheck * redCheck * blueDom;
		waterMask = rawWater;
#endif

		float triMid = 0.0;
		float bumpMeters = 0.0;

		// Skip expensive 3D FBM & tri-planar land lookups on pure open-ocean pixels
		if (rawWater < 0.985) {
			macroGrad = geoFbm3D(sDir * 9.0);
			microDetail = geoFbm3D(sDir * 36.0 + vec3(macroGrad * 1.4));

			// Pure 4-scale 3D quintic FBM geological detail (zero BC1 block compression artifacts at any distance or angle)
			float triMacro = geoFbm3D(worldM * (1.0 / 680.0)) * 2.0 - 1.0;
			triMid = geoFbm3D(worldM * (1.0 / 160.0) + vec3(triMacro * 0.65)) * 2.0 - 1.0;
			float triClose = geoFbm3D(worldM * (1.0 / 28.0) + vec3(triMid * 0.65)) * 2.0 - 1.0;
			float triMicro = geoFbm3D(worldM * (1.0 / 5.5) + vec3(triClose * 0.75)) * 2.0 - 1.0;

#ifdef TERRAIN_WITH_WATER
			// Organic anti-aliased shoreline mask: breaks up per-vertex triangle edges at close range into natural coves/beaches
			float coastNoise = triMid * 0.45 + triClose * 0.25 + (microDetail - 0.5) * 0.45;
			float coastZone = smoothstep(0.03, 0.32, rawWater) * (1.0 - smoothstep(0.68, 0.97, rawWater));
			waterMask = smoothstep(0.22, 0.78, clamp(rawWater + coastNoise * coastZone * (0.45 + 0.55 * macroFade), 0.0, 1.0));
#endif

			// Physical surface slope relative to radial planet up-vector (0 = flat plain, 1 = vertical cliff)
			float slope = 1.0 - clamp(dot(tnorm, V), 0.0, 1.0);
			cliffMask = smoothstep(0.10, 0.34, slope) * (1.0 - waterMask);
			screeMask = smoothstep(0.03, 0.14, slope) * (1.0 - cliffMask) * (1.0 - waterMask);

			// Sedimentary / basalt cliff stratification driven by true elevation in meters
			float radialElevM = (length(eyeposScaled - geosphereCenter) - 1.0) * geosphereRadius;
			float strata = 0.5 + 0.5 * sin(radialElevM * 0.18 + triMid * 2.6 + macroGrad * 3.5);
			float rippleWave = sin(dot(worldM, vec3(0.38, 0.09, 0.31)) + triClose * 2.4);
			float flatMask = (1.0 - cliffMask) * (1.0 - screeMask * 0.5) * (1.0 - waterMask);

			bumpMeters = (triMacro * 12.0 * macroFade + triMid * 3.6 * midFade + triClose * 0.85 * closeFade + triMicro * 0.20 * microFade) *
				(0.80 + 0.55 * screeMask + 0.85 * cliffMask) +
				(strata - 0.5) * 2.4 * cliffMask * midFade +
				rippleWave * 0.06 * closeFade * flatMask;

			float detailSigned = triMacro * 0.12 * macroFade + triMid * 0.16 * midFade + triClose * 0.17 * closeFade + triMicro * 0.11 * microFade + rippleWave * 0.03 * closeFade * flatMask;
			float cliffStrataDelta = (strata - 0.5) * 0.28 * cliffMask * midFade;
			float creviceAO = mix(1.0, 0.88, smoothstep(0.15, 0.85, -triMid) * midFade);
			triAlbedoMod = clamp((1.0 + detailSigned + cliffStrataDelta) * creviceAO, 0.62, 1.38);

			// Expose slightly cooler/darker fractured bedrock on steep canyon & crater walls
			vec3 cliffBedrockTint = mix(vec3(0.86, 0.88, 0.92), vec3(1.04, 0.99, 0.94), strata);
			triTint = mix(vec3(1.0), cliffBedrockTint, cliffMask * midFade * 0.75);

#ifdef TERRAIN_WITH_LAVA
			if (waterMask < 0.5) {
				float rawLava = smoothstep(0.38, 0.72, vertexColor.r)
					* (1.0 - smoothstep(0.06, 0.18, vertexColor.g))
					* (1.0 - smoothstep(0.06, 0.18, vertexColor.b))
					* (1.0 - waterMask);
				if (rawLava > 0.01) {
					float lavaEdgeFade = exp(-0.00004 * distMeters);
					float lavaDetailFade = exp(-0.00012 * distMeters);
					float edgeN = (lavaEdgeFade > 0.02)
						? (geoFbm3D(worldM * 0.0085) * 0.58 + geoFbm3D(worldM * 0.036) * 0.42)
						: 0.5;
					float lavaZone = smoothstep(0.02, 0.36, rawLava) * (1.0 - smoothstep(0.64, 0.98, rawLava));
					float coastLava = triMid * 0.42 + triClose * 0.24 + (edgeN - 0.5) * 0.55;
					float lavaField = clamp(rawLava + coastLava * lavaZone * (0.45 + 0.55 * lavaEdgeFade), 0.0, 1.0);
					lavaMask = smoothstep(0.30, 0.46, lavaField);
					charredRim = smoothstep(0.10, 0.32, lavaField) * (1.0 - lavaMask) * smoothstep(0.02, 0.18, rawLava);

					if (lavaMask > 0.002 || charredRim > 0.002) {
						float interior = smoothstep(0.34, 0.78, lavaField);
						float baseTemp = 0.42 + 0.45 * interior;
						float detailedTemp = baseTemp;
						float lavaFine = 0.5;
						if (lavaDetailFade > 0.02) {
							vec3 flowP = worldM * 0.016 + vec3(uTime * 0.020, 0.0, -uTime * 0.014);
							float warp = geoFbm3D(flowP * 0.65) * 1.5;
							float lavaCrust = geoFbm3D(flowP + vec3(warp, -warp * 0.7, warp * 0.5));
							lavaFine = geoFbm3D(worldM * 0.088 + vec3(uTime * 0.032, 0.0, -uTime * 0.024));
							float cracks = pow(1.0 - abs(lavaCrust * 2.0 - 1.0), 3.0) * 0.85 + pow(1.0 - abs(lavaFine * 2.0 - 1.0), 3.8) * 0.45;
							float pulse = 0.90 + 0.10 * sin(uTime * 0.65 + lavaCrust * 6.2831);
							detailedTemp = clamp((cracks * (0.80 + 0.45 * interior) + interior * 0.48 - smoothstep(0.54, 0.84, lavaCrust) * 0.44) * pulse, 0.0, 1.0);

							float plateBump = (smoothstep(0.35, 0.72, lavaCrust) * 1.4 - cracks * 0.8) * closeFade;
							bumpMeters = mix(bumpMeters, plateBump, lavaMask * 0.85 * lavaDetailFade);
						}
						float lavaTemp = mix(baseTemp, detailedTemp, lavaDetailFade);

						vec3 fissureCol = mix(
							vec3(0.04, 0.03, 0.03),
							mix(vec3(0.95, 0.14, 0.01),
								mix(vec3(1.65, 0.58, 0.04), vec3(2.2, 1.45, 0.35), smoothstep(0.76, 1.0, lavaTemp)),
								smoothstep(0.46, 0.76, lavaTemp)),
							smoothstep(0.16, 0.46, lavaTemp)
						);
						vec3 rimBounce = vec3(0.75, 0.18, 0.02) * charredRim * (0.45 + 0.55 * lavaFine);
						float lavaDistAtten = 0.72 + 0.28 * exp(-0.000018 * distMeters);
						lavaGlow = (fissureCol * lavaMask + rimBounce) * lavaDistAtten;
#ifdef ATMOSPHERE
						float smokeFade = exp(-0.00014 * distMeters) * smoothstep(0.05, 0.35, lavaMask + charredRim * 0.6);
						if (smokeFade > 0.01) {
							vec3 smokeP = worldM * 0.022 + vec3(uTime * 0.065, uTime * 0.035, -uTime * 0.048);
							float sFbm = geoFbm3D(smokeP);
							float smokeDensity = smoothstep(0.42, 0.80, sFbm) * smokeFade * 0.48;
							vec3 smokeTint = mix(vec3(0.08, 0.075, 0.082), vec3(0.82, 0.28, 0.06), clamp(lavaTemp * 1.15, 0.0, 1.0));
							lavaGlow = mix(lavaGlow, smokeTint, smokeDensity);
						}
#endif
					}
				}
			}
#endif
		}

		vec3 waterSurfNorm = tnorm;
#ifdef TERRAIN_WITH_WATER
		if (waterMask > 0.01) {
			int waterQual = int(WaterParams.w + 0.5);
			if (waterQual > 0) {
				// Quality-tiered world-locked FFT ocean waves (1=Medium 1-layer, 2=High 2-layer, 3=Very High 4-cascade)
				vec2 wPos = worldM.xz * triW.y + worldM.xy * triW.z + worldM.yz * triW.x;
				float wTurb = clamp(WaterParams.x, 0.30, 2.20);
				float wSpeed = clamp(WaterParams.y, 0.45, 2.20);
				float wCapScale = max(WaterParams.z, 0.0);
				float wt = uTime * wSpeed;

				float waveBlend = exp(-0.000035 * distMeters);
				float nearBlend = exp(-0.003 * distMeters);

				vec2 nXY = vec2(0.0);
				float texH = 0.5;
				float foamField = 0.0;

				if (waterQual == 1) {
					vec4 c2 = texture(oceanTexB, wPos * (16.0 / 256.0) + vec2(-wt * 0.048, wt * 0.034));
					nXY = (c2.rg * 2.0 - 1.0) * 0.58;
					texH = c2.b;
					foamField = c2.a * 0.65;
				} else if (waterQual == 2) {
					vec4 c1 = texture(oceanTexA, wPos * (4.0 / 256.0) + vec2(wt * 0.022, wt * 0.013));
					vec4 c2 = texture(oceanTexB, wPos * (16.0 / 256.0) + vec2(-wt * 0.048, wt * 0.034));
					vec2 n1 = c1.rg * 2.0 - 1.0;
					vec2 n2 = c2.rg * 2.0 - 1.0;
					nXY = n1 * 0.50 + n2 * 0.42;
					texH = c1.b * 0.55 + c2.b * 0.45;
					foamField = (max(c1.a * 0.85, c2.a * 0.95) * 0.72 + c2.a * 0.45) * (0.55 + 0.70 * c1.b);
				} else {
					vec4 c0 = texture(oceanTexA, wPos.yx * (1.0 / 256.0) + vec2(wt * 0.008, -wt * 0.006));
					vec4 c1 = texture(oceanTexA, wPos * (4.0 / 256.0) + vec2(wt * 0.022, wt * 0.013));
					vec4 c2 = texture(oceanTexB, wPos * (16.0 / 256.0) + vec2(-wt * 0.048, wt * 0.034));
					vec4 c3 = texture(oceanTexB, wPos.yx * (64.0 / 256.0) + vec2(wt * 0.095, -wt * 0.072));
					vec2 n0 = c0.gr * 2.0 - 1.0;
					vec2 n1 = c1.rg * 2.0 - 1.0;
					vec2 n2 = c2.rg * 2.0 - 1.0;
					vec2 n3 = c3.gr * 2.0 - 1.0;
					nXY = n0 * 0.16 + n1 * 0.38 + n2 * 0.32 + n3 * (0.24 * nearBlend);
					texH = c0.b * 0.18 + c1.b * 0.42 + c2.b * 0.28 + mix(c2.b, c3.b, nearBlend) * 0.12;
					float texFoam = max(c1.a * 0.85, c2.a * 0.95) * 0.70 + (c2.a * 0.55 + c3.a * 0.45 * nearBlend) * 0.55;
					foamField = texFoam * (0.45 + 0.85 * c0.b);
				}

				// World-locked tangent basis aligned with wPos (stays locked to planet surface when banking/pitching)
				vec3 wTanRaw = varyingObjY * triW.x + varyingObjX * triW.y + varyingObjX * triW.z;
				vec3 wTanOrtho = wTanRaw - tnorm * dot(wTanRaw, tnorm);
				vec3 wTan = (dot(wTanOrtho, wTanOrtho) > 1e-4) ? normalize(wTanOrtho) : normalize(cross(vec3(0.0, 1.0, 0.0), tnorm + vec3(0.0, 0.0, 1e-4)));
				vec3 wBitanRaw = varyingObjZ * (triW.x + triW.y) + varyingObjY * triW.z;
				vec3 wBitanOrtho = wBitanRaw - tnorm * dot(wBitanRaw, tnorm) - wTan * dot(wBitanRaw, wTan);
				vec3 wBitan = (dot(wBitanOrtho, wBitanOrtho) > 1e-4) ? normalize(wBitanOrtho) : normalize(cross(tnorm, wTan));

				float normalStrength = (0.78 + 0.32 * nearBlend) * clamp(0.55 + 0.55 * wTurb, 0.35, 1.85) * waveBlend;
				waterSurfNorm = normalize(tnorm + (wTan * nXY.x + wBitan * nXY.y) * normalStrength);

				float wOrbital = (waterQual >= 2 && waveBlend < 0.92)
					? geoNoise3D(sDir * 160.0 + vec3(uTime * 0.07, -uTime * 0.05, uTime * 0.04))
					: texH;
				waterTurb = mix(wOrbital, clamp(0.5 + (texH - 0.5) * clamp(0.75 + 0.45 * wTurb, 0.5, 1.6), 0.0, 1.0), waveBlend);

				float whitecap = clamp((foamField - 0.12) * 1.45 * clamp(wCapScale, 0.0, 1.85), 0.0, 1.0) * waveBlend * waterMask;

				float shoreBand = smoothstep(0.06, 0.30, waterMask) * (1.0 - smoothstep(0.36, 0.74, waterMask));
				surfFoam = clamp(shoreBand * smoothstep(0.35, 0.72, texH) * 0.42 * waveBlend + whitecap, 0.0, 0.92);
			}
		}
#endif

		// Mikkelsen physical-meter surface-gradient bump normal (executed in uniform quad control flow)
		vec3 dPdx = dFdx(varyingEyepos) * metersPerViewUnit;
		vec3 dPdy = dFdy(varyingEyepos) * metersPerViewUnit;
		vec3 r1 = cross(dPdy, tnorm);
		vec3 r2 = cross(tnorm, dPdx);
		float det = dot(dPdx, r1);
		vec3 surfGrad = sign(det) * (dFdx(bumpMeters) * r1 + dFdy(bumpMeters) * r2) / max(abs(det), 1e-4);
		float gradLen = length(surfGrad);
		if (gradLen > 0.62) {
			surfGrad *= (0.62 / gradLen);
		}
		float grazingFade = smoothstep(0.03, 0.16, abs(dot(tnorm, -eyenorm)));
		vec3 landNorm = normalize(tnorm - surfGrad * grazingFade);
		surfNorm = normalize(mix(landNorm, waterSurfNorm, waterMask));

		// Detect icy / frosted surfaces (exclude liquid oceans)
		float cMax = max(max(vertexColor.r, vertexColor.g), vertexColor.b);
		float cMin = min(min(vertexColor.r, vertexColor.g), vertexColor.b);
		float sat = (cMax > 0.001) ? (cMax - cMin) / cMax : 0.0;
		float lum = dot(vertexColor.rgb, vec3(0.2126, 0.7152, 0.0722));
		float coolBias = clamp((vertexColor.b - vertexColor.r) * 2.5 + 0.5, 0.0, 1.0);
		iceMask = smoothstep(0.38, 0.72, lum) * (1.0 - smoothstep(0.18, 0.48, sat)) * (0.65 + 0.35 * coolBias) * (1.0 - waterMask);

		// Matte soil/grass roughness (0.96), scree (0.90), exposed cliff rock (0.68), ice (0.24), water (0.08)
		float rockRough = mix(0.96, 0.68, cliffMask) - 0.06 * screeMask;
		matRoughness = mix(rockRough, 0.24, iceMask);
		matRoughness = mix(matRoughness, 0.08, waterMask);
#ifdef TERRAIN_WITH_LAVA
		matRoughness = mix(matRoughness, 0.52, lavaMask * 0.85);
#endif
	}

#ifdef ATMOSPHERE
	float cloudShade = clamp(CloudWeather.x * CloudWeather.z, 0.0, 1.0);
	float stormShade = clamp(CloudWeather.y * CloudWeather.z, 0.0, 1.0);
	float lightningPulse = clamp(CloudWeather.w, 0.0, 1.0);
#else
	float cloudShade = 0.0;
	float stormShade = 0.0;
	float lightningPulse = 0.0;
#endif
	float maxSunElev = -1.0;
	vec3 oceanFinal = vec3(0.0);

	for (int i=0; i<NUM_LIGHTS; ++i) {
		vec3 L = normalize(uLight[i].position.xyz);
		maxSunElev = max(maxSunElev, dot(V, L));
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
			float VdotH = max(dot(viewDir, H), 0.0);

			// GGX microfacet specular with roughness-damped Fresnel (prevents plastic sheen on matte soil/grass)
			float a = max(matRoughness * matRoughness, 0.02);
			float a2 = a * a;
			float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
			float D = a2 / (3.14159 * denom * denom + 1e-4);
			float F0 = mix(mix(0.02, 0.055, cliffMask), 0.045, iceMask);
			float fresnel = F0 + (max(1.0 - matRoughness, F0) - F0) * pow(1.0 - VdotH, 5.0);
			float ggxSpec = clamp(D * fresnel * 0.35, 0.0, 1.6);

			// Crystalline specular glint on icy terrain + subtle mineral sheen strictly on exposed rock/cliffs
			float metersPerViewUnit = geosphereRadius * geosphereInvRadius;
			float distMeters = dist * metersPerViewUnit;
			float iceGlint = (pow(NdotH, 52.0) * 0.80 + ggxSpec * 0.85) * (0.7 + 0.6 * microDetail);
			float rockSpec = ggxSpec * (cliffMask * 0.24 + screeMask * 0.06) * (0.65 + 0.35 * microDetail);
			vec3 iceSpecCol = mix(lightDiff.rgb, vec3(0.84, 0.94, 1.0), 0.48);
			vec3 rockSpecCol = mix(lightDiff.rgb, vec3(1.0, 0.95, 0.88), 0.25);

			float sunElev = dot(V, L);
			float sunAboveHoriz = smoothstep(-0.005, 0.10, sunElev);
			float cwDirect = clamp(1.0 - cloudShade * 0.92 - stormShade * 0.08, 0.04, 1.0);
			// Crisp glittering ocean sun sparkle + whitecap illumination (attenuated by clouds and warm dusk limb shift)
			vec3 sunGlintCol = lightDiff.rgb * mix(vec3(1.0, 0.48, 0.18), vec3(1.0), smoothstep(0.0, 0.22, sunElev));
			float waterSpec = (pow(NdotH, 240.0) * 2.4 + pow(NdotH, 42.0) * 0.16) * waterMask * (1.0 - surfFoam * 0.85) * cwDirect * cwDirect * sunAboveHoriz;
			vec3 landSpec = (iceSpecCol * iceGlint * iceMask + rockSpecCol * rockSpec * (1.0 - iceMask * 0.65)) *
				(1.0 - waterMask) * exp(-0.000045 * distMeters);
			vec3 foamLight = lightDiff.rgb * vec3(0.92, 0.95, 0.98) * surfFoam * 0.55 * mix(1.0, 0.40, cloudShade) * smoothstep(-0.02, 0.14, sunElev);
			enhancedSpec += (landSpec + sunGlintCol * waterSpec + foamLight) * NdotL;
		}

#ifdef TERRAIN_WITH_WATER
		// Legacy broad WATER_SHINE=16 specular only for Classic mode (Enhanced renders Fresnel sky reflection + crisp glitter)
		if (!enhanced && vertexColor.b > 0.05 && vertexColor.r < 0.05) {
			CalcPlanetSpec(specularReflection, uLight[i], L, surfNorm, eyenorm, WATER_SHINE);
		}
#endif
	}

	vec4 surfAlbedo = vertexColor;
	if (enhanced) {
		float metersPerViewUnit = geosphereRadius * geosphereInvRadius;
		float distMeters = dist * metersPerViewUnit;
		float macroFade = exp(-0.000018 * distMeters);
		float orbitalContrast = mix(0.86, 1.16, clamp(macroGrad * 0.55 + microDetail * 0.45, 0.0, 1.0));
		float contrastMod = mix(1.0, orbitalContrast, mix(0.35, 1.0, 1.0 - macroFade)) * triAlbedoMod;
		vec3 mineralTint = mix(vec3(0.94, 0.97, 1.03), vec3(1.04, 0.98, 0.93), macroGrad) * triTint;
		vec3 icyLift = mix(vec3(1.0), vec3(0.92, 0.98, 1.08), iceMask * 0.55);
		vec3 landAlbedo = clamp(surfAlbedo.rgb * contrastMod * mineralTint * icyLift, 0.0, 1.25);
#ifdef TERRAIN_WITH_LAVA
		vec3 cooledBasalt = vec3(0.055) * triAlbedoMod;
		landAlbedo = mix(landAlbedo, cooledBasalt, clamp(lavaMask + charredRim * 0.82, 0.0, 1.0));
#endif
		// Smooth organic beach / true sky-reflected ocean with steep dusk darkening (bypasses flat scene.ambient glow)
		float wetEdge = waterMask * (1.0 - waterMask) * 4.0;
		vec3 beachSand = mix(landAlbedo, vec3(0.42, 0.37, 0.30) * triAlbedoMod, wetEdge * 0.55);
		surfAlbedo.rgb = mix(beachSand, vec3(0.02, 0.06, 0.14), waterMask);

		if (waterMask > 0.005) {
			float NdotVWater = clamp(dot(surfNorm, -eyenorm), 0.0, 1.0);
			float waterFresnel = 0.03 + 0.97 * pow(1.0 - NdotVWater, 4.0);
			vec3 waterReflDir = reflect(eyenorm, surfNorm);
			vec3 skyReflDir = normalize(waterReflDir + V * max(0.018 - dot(waterReflDir, V), 0.0));

			vec3 deepOcean = mix(
				mix(vec3(0.025, 0.11, 0.26), vec3(0.06, 0.22, 0.36), clamp((waterTurb - 0.28) * 1.9, 0.0, 1.0)),
				vec3(0.012, 0.042, 0.072),
				clamp(cloudShade * 0.72 + stormShade * 0.28, 0.0, 1.0));
			vec3 shallowWater = mix(deepOcean, vec3(0.05, 0.22, 0.32) * mix(1.0, 0.42, cloudShade), wetEdge * 0.55);

#ifdef ATMOSPHERE
			vec3 surfPos = eyeposScaled - geosphereCenter;
			vec2 rView = raySphereIntersect(-surfPos, skyReflDir, geosphereAtmosTopRad);
			float rAtmosDist = max(rView.y, 0.0) * geosphereRadius;
			vec3 rA = surfPos;
			vec3 rB = surfPos + skyReflDir * max(rView.y, 0.0);
			float rLdprod = AtmosLengthDensityProduct(rA, rB, atmosColor.a * geosphereAtmosFogDensity, rAtmosDist, geosphereAtmosInvScaleHeight);
			float rFog = 1.0 / exp(rLdprod);
			vec4 rAtmosDiff = vec4(0.0);
			float rSkySpec = 0.0;
			vec3 duskSunAccent = vec3(0.0);
			if (rView.y > 0.001) {
				for (int j = 0; j < NUM_LIGHTS; ++j) {
					vec3 L = normalize(uLight[j].position.xyz);
					float unecl = clamp(calcUneclipsedSky(eclipse, NumShadows, rA, rB, L), 0.0, 1.0);
					CalcPlanetDiffuse(rAtmosDiff, toLinear(uLight[j].diffuse), L, V, unecl);
					rSkySpec += pow(max(dot(L, skyReflDir), 0.0), 64.0) * unecl * INV_NUM_LIGHTS;
					float sElev = dot(V, L);
					float tw = exp(-pow((sElev - 0.015) * 9.0, 2.0)) * smoothstep(-0.08, 0.02, sElev);
					float sAlign = pow(max(dot(skyReflDir, L), 0.0), 3.0);
					duskSunAccent += vec3(0.95, 0.42, 0.14) * uLight[j].diffuse.rgb * tw * sAlign * unecl * 0.45;
				}
			}
			rAtmosDiff = toSRGB(rAtmosDiff);
			rAtmosDiff = 1.0 - exp(-rAtmosDiff);
			float rAtmPower = (rAtmosDiff.r + rAtmosDiff.g + rAtmosDiff.b) / 3.0;
			vec4 rSunset = vec4(0.8, clamp(pow(rAtmPower, 0.8), 0.0, 1.0), clamp(pow(rAtmPower, 1.2), 0.0, 1.0), 1.0);
			vec3 trueSkyRefl = ((1.0 - rFog) * (rAtmosDiff * vec4(atmosColor.rgb, 1.0))
				+ (0.02 - clamp(rFog, 0.0, 0.01)) * rAtmosDiff * rLdprod * rSunset
				+ atmosColor * rSkySpec * (1.0 - rFog) * rSunset).rgb;
			float duskReflFade = smoothstep(-0.14, 0.24, maxSunElev);
			trueSkyRefl = trueSkyRefl * mix(0.08, 1.0, duskReflFade) * smoothstep(-0.20, -0.04, maxSunElev) + duskSunAccent * (1.0 - rFog);
#else
			vec3 trueSkyRefl = vec3(0.0);
#endif
			float cDay = smoothstep(-0.06, 0.24, maxSunElev) * (0.14 + 0.86 * pow(max(maxSunElev, 0.0), 0.80));
			vec3 overcastCloudRefl = mix(vec3(0.20, 0.24, 0.29), vec3(0.11, 0.14, 0.18), stormShade) * cDay;
			vec3 waterSkyRefl = mix(
				max(trueSkyRefl, vec3(0.004, 0.006, 0.010)),
				max(overcastCloudRefl, vec3(0.003, 0.004, 0.007)),
				clamp(cloudShade * (0.82 + 0.14 * stormShade), 0.0, 0.95));
			waterSkyRefl += vec3(0.55, 0.72, 1.0) * lightningPulse * 0.22;

			float oceanBodyLit = pow(smoothstep(-0.005, 0.42, maxSunElev), 1.85) * (1.0 - cloudShade * (0.62 + 0.18 * stormShade));
			float skyLum = dot(waterSkyRefl, vec3(0.2126, 0.7152, 0.0722));
			vec3 oceanBase = shallowWater * (oceanBodyLit + skyLum * 0.12 + 0.004);
			oceanFinal = mix(oceanBase, waterSkyRefl, clamp(waterFresnel * 0.94, 0.03, 0.96));
			vec3 foamCol = vec3(0.88, 0.93, 0.97) * clamp(oceanBodyLit * 0.92 + skyLum * 0.32 + 0.006, 0.006, 1.0);
			oceanFinal = mix(oceanFinal, foamCol, surfFoam * 0.82);
			oceanFinal += vec3(0.58, 0.74, 1.0) * lightningPulse * (0.04 + 0.22 * waterFresnel + 0.10 * surfFoam);
		}
	}

	// Use the detail value to multiply the final colour before lighting in Classic mode; Enhanced uses world-locked tri-planar detail
	vec4 ambient = scene.ambient * surfAlbedo;
	vec4 final = enhanced ? (surfAlbedo * diff) : (surfAlbedo * detailMul * diff);

#ifdef TERRAIN_WITH_LAVA
	if (enhanced) {
		final.rgb += lavaGlow;
	}
#endif

#ifdef ATMOSPHERE
	float ldprod=0.0;
	float fogFactor=0.0;
	CalcPlanetFogFactor(ldprod, fogFactor, eyenorm, eyeposScaled - geosphereCenter, surfaceDist);

	//calculate sunset tone red when passing through more atmosphere, clamp everything.
	float atmpower = (diff.r+diff.g+diff.b)/3.0;
	vec4 sunset = vec4(0.8,clamp(pow(atmpower,0.8),0.0,1.0),clamp(pow(atmpower,1.2),0.0,1.0),1.0);

	final = fogFactor * (ambient + final);
	if (enhanced && waterMask > 0.005) {
		final.rgb = mix(final.rgb, fogFactor * oceanFinal, waterMask);
	}
#else
	// add extra brightness to atmosphere-less planetoids and dim stars
	final = ambient + final * 2.0;
	if (enhanced && waterMask > 0.005) {
		final.rgb = mix(final.rgb, oceanFinal, waterMask);
	}
#endif

	if (enhanced) {
		final.rgb += enhancedSpec * 1.15;
	}

	vec3 fragPosM = varyingEyepos * (geosphereRadius * geosphereInvRadius);
	vec3 spotAlbedo = enhanced ? surfAlbedo.rgb : (surfAlbedo.rgb * detailMul.rgb);
	vec3 spotContrib = EvalShipSpotLights(fragPosM, surfNorm, -eyenorm, spotAlbedo, matRoughness, waterMask);

	frag_color =
		material.emission +
#ifdef TERRAIN_WITH_LAVA
		(enhanced ? vec4(0.0) : varyingEmission) +
#endif
		final +
		vec4(1.0 - exp(-spotContrib * 0.85), 0.0);

#ifdef ATMOSPHERE
	float waterFogAtten = enhanced
		? mix(1.0, (1.0 - cloudShade * 0.65) * mix(0.18, 1.0, smoothstep(-0.12, 0.18, maxSunElev)), waterMask)
		: 1.0;
	frag_color +=
		((1.0-fogFactor) * (diff*atmosColor) +
#ifdef TERRAIN_WITH_WATER
		  diff * specularReflection * sunset +
#endif
		  (0.02-clamp(fogFactor,0.0,0.01))*diff*ldprod*sunset +	      //increase fog scatter
		  (pow((1.0-pow(fogFactor,0.75)),256.0)*0.4*diff*atmosColor)*sunset) * waterFogAtten;  //distant fog.

	if (enhanced) {
		// Atmospheric Fresnel limb halo strictly gated to orbital/space views (eliminates milky wash at low altitude)
		float camAltRad = max(length(geosphereCenter) - 1.0, 0.0);
		float orbitLimbFade = smoothstep(0.05, 0.25, camAltRad);
		float NdotV = clamp(dot(tnorm, -eyenorm), 0.0, 1.0);
		float limb = pow(1.0 - NdotV, 3.1);
		vec3 atmoTint = mix(atmosColor.rgb, vec3(0.65, 0.85, 1.0), 0.35 + 0.25 * iceMask);
		float litFactor = smoothstep(0.0, 0.16, maxSunLit) * pow(maxSunLit, 0.55);
		frag_color.rgb += atmoTint * limb * litFactor * 0.72 * orbitLimbFade;
	}
#endif //ATMOSPHERE

#else // NUM_LIGHTS > 0 -- unlit rendering - stars
	//emission is used to boost colour of stars, which is a bit odd
	frag_color = material.emission + vertexColor;
#endif
}

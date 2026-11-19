// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"
#include "basesphere_uniforms.glsl"
#include "rayleigh-lib.glsl"
#include "spotlights.glsl"

#define WATER_SHINE 16.0

uniform sampler2D texture0;
uniform sampler2D texture1;
uniform sampler2D densityLUT;
uniform sampler2D scatterLUT;
uniform sampler2D oceanTexA;
uniform sampler2D oceanTexB;
uniform int NumShadows;
in vec2 texCoord0;

in float dist;

in vec3 varyingEyepos;
in vec3 varyingNormal;
in vec3 objNormal;
in vec3 patchLocalPos;
in vec3 varyingObjX;
in vec3 varyingObjY;
in vec3 varyingObjZ;
in vec3 rawAlbedo;
in vec3 varyingInscatter;
in vec4 vertexColor;

out vec4 frag_color;

uniform float PatchDetailFrequency;
uniform vec3 PatchTileOffset;
uniform vec4 WaterParams;
uniform float enhancedGraphics;
uniform float uTime;
uniform vec4 CloudWeather;

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
	for (int i = 0; i < 2; ++i) {
		sum += amp * rgeoNoise3D(p);
		p = p * 2.12 + vec3(7.3, 13.7, 5.1);
		amp *= 0.5;
	}
	return sum * (1.0 / 0.75);
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

	bool enhanced = (enhancedGraphics >= 0.5);

	// In Classic mode preserve legacy detailMul + pre-baked atmospheric inscattering.
	// In Enhanced mode apply crisp world-locked surface detail & micro-shading before adding varyingInscatter.
	vec4 baseColor = enhanced ? vertexColor : (vertexColor + vec4(varyingInscatter, 0.0));
	vec4 ambient = scene.ambient * baseColor * 0.f;
	vec4 final = enhanced ? baseColor : (detailMul * baseColor);

#ifdef ATMOSPHERE
	final = ambient + final;
#else
	// add extra brightness to atmosphere-less planetoids and dim stars
	final = ambient + final * 2.0;
#endif

	if (enhanced) {
		vec3 tnorm = normalize(varyingNormal);
		vec3 eyenorm = normalize(varyingEyepos);
		vec3 sDir = normalize(objNormal);
		vec3 eyeposScaled = varyingEyepos * geosphereInvRadius;
		vec3 radialUp = normalize(eyeposScaled - geosphereCenter);

		float metersPerViewUnit = geosphereRadius * geosphereInvRadius;
		float distMeters = dist * metersPerViewUnit;

		vec3 worldM = patchLocalPos * geosphereRadius + PatchTileOffset;
		vec3 triW = pow(abs(sDir), vec3(4.0));
		triW /= max(triW.x + triW.y + triW.z, 1e-5);

		float macroFade = exp(-0.000018 * distMeters);
		float midFade = exp(-0.00008 * distMeters);
		float closeFade = exp(-0.00045 * distMeters);
		float microFade = exp(-0.0022 * distMeters);

		float rawWater = 0.0;
		float waterMask = 0.0;
		float surfFoam = 0.0;
		float whitecap = 0.0;
		float waterTurb = 0.5;
#ifdef TERRAIN_WITH_WATER
		float blueCheck = smoothstep(0.04, 0.095, rawAlbedo.b);
		float redCheck = 1.0 - smoothstep(0.01, 0.12, rawAlbedo.r);
		float blueDom = smoothstep(0.03, 0.09, rawAlbedo.b - rawAlbedo.r);
		rawWater = blueCheck * redCheck * blueDom;
		waterMask = rawWater;
#endif

		float macroGrad = 0.5;
		float microDetail = 0.5;
		float triMid = 0.0;
		float cliffMask = 0.0;
		float screeMask = 0.0;
		float bumpMeters = 0.0;
		float triAlbedoMod = 1.0;
		vec3 triTint = vec3(1.0);

		// Skip expensive 3D FBM & tri-planar land lookups on pure open-ocean pixels
		if (rawWater < 0.985) {
			macroGrad = rgeoFbm3D(sDir * 9.0);
			microDetail = rgeoFbm3D(sDir * 36.0 + vec3(macroGrad * 1.4));

			// 4-octave seamless world-locked tri-planar detail (1024m, 256m, 32m, 8m)
			vec3 uvMacro = worldM * (1.0 / 1024.0);
			vec3 uvMid = worldM * (1.0 / 256.0);
			vec3 uvClose = worldM * (1.0 / 32.0);
			vec3 uvMicro = worldM * (1.0 / 8.0);

			float t1024 = texture(texture1, uvMacro.yz).r * triW.x +
				texture(texture1, uvMacro.xz).r * triW.y +
				texture(texture1, uvMacro.xy).r * triW.z;
			float t256 = texture(texture1, uvMid.yz).r * triW.x +
				texture(texture1, uvMid.xz).r * triW.y +
				texture(texture1, uvMid.xy).r * triW.z;
			float t32 = texture(texture0, uvClose.yz).r * triW.x +
				texture(texture0, uvClose.xz).r * triW.y +
				texture(texture0, uvClose.xy).r * triW.z;
			float t8 = texture(texture0, uvMicro.yz).r * triW.x +
				texture(texture0, uvMicro.xz).r * triW.y +
				texture(texture0, uvMicro.xy).r * triW.z;

			// Re-center and contrast-stretch DDS detail maps (low.dds mean 0.502, high.dds mean 0.673)
			float triMacro = clamp((t1024 - 0.502) * 3.2, -1.0, 1.0);
			triMid = clamp((t256 - 0.502) * 3.4, -1.0, 1.0);
			float triClose = clamp((t32 - 0.673) * 3.8, -1.0, 1.0);
			float triMicro = clamp((t8 - 0.673) * 3.6, -1.0, 1.0);

#ifdef TERRAIN_WITH_WATER
			// Multi-scale organic shoreline breakup (breaks straight triangle edges into natural coves)
			float coastNoise = triMid * 0.45 + triClose * 0.25 + (microDetail - 0.5) * 0.45;
			float coastZone = smoothstep(0.03, 0.32, rawWater) * (1.0 - smoothstep(0.68, 0.97, rawWater));
			waterMask = smoothstep(0.22, 0.78, clamp(rawWater + coastNoise * coastZone * (0.45 + 0.55 * macroFade), 0.0, 1.0));
#endif

			// Physical surface slope & tri-planar multi-splat weights (cliffs, scree/talus, flat regolith)
			float slope = 1.0 - clamp(dot(tnorm, radialUp), 0.0, 1.0);
			cliffMask = smoothstep(0.10, 0.34, slope) * (1.0 - waterMask);
			screeMask = smoothstep(0.03, 0.14, slope) * (1.0 - cliffMask) * (1.0 - waterMask);

			float radialElevM = (length(eyeposScaled - geosphereCenter) - 1.0) * geosphereRadius;
			float strata = 0.5 + 0.5 * sin(radialElevM * 0.18 + triMid * 2.6 + macroGrad * 3.5);

			bumpMeters = (triMacro * 14.0 * macroFade + triMid * 4.5 * midFade + triClose * 0.75 * closeFade + triMicro * 0.16 * microFade) *
				(0.80 + 0.55 * screeMask + 0.85 * cliffMask) +
				(strata - 0.5) * 2.4 * cliffMask * midFade;

			float detailSigned = triMacro * 0.14 * macroFade + triMid * 0.20 * midFade + triClose * 0.18 * closeFade + triMicro * 0.11 * microFade;
			float cliffStrataDelta = (strata - 0.5) * 0.28 * cliffMask * midFade;
			float creviceAO = mix(1.0, 0.88, smoothstep(0.15, 0.85, -triMid) * midFade);
			triAlbedoMod = clamp((1.0 + detailSigned + cliffStrataDelta) * creviceAO, 0.62, 1.38);

			vec3 cliffBedrockTint = mix(vec3(0.86, 0.88, 0.92), vec3(1.04, 0.99, 0.94), strata);
			triTint = mix(vec3(1.0), cliffBedrockTint, cliffMask * midFade * 0.75);
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
					? rgeoNoise3D(sDir * 160.0 + vec3(uTime * 0.07, -uTime * 0.05, uTime * 0.04))
					: texH;
				waterTurb = mix(wOrbital, clamp(0.5 + (texH - 0.5) * clamp(0.75 + 0.45 * wTurb, 0.5, 1.6), 0.0, 1.0), waveBlend);

				whitecap = clamp((foamField - 0.12) * 1.45 * clamp(wCapScale, 0.0, 1.85), 0.0, 1.0) * waveBlend * waterMask;

				// Soft organic coastal foam on breaking swells
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
		vec3 surfNorm = normalize(mix(landNorm, waterSurfNorm, waterMask));

		// Auto-detect icy/frosted terrain from raw vertex albedo (excluding liquid oceans)
		float cMax = max(max(rawAlbedo.r, rawAlbedo.g), rawAlbedo.b);
		float cMin = min(min(rawAlbedo.r, rawAlbedo.g), rawAlbedo.b);
		float sat = (cMax > 0.001) ? (cMax - cMin) / cMax : 0.0;
		float lum = dot(rawAlbedo, vec3(0.2126, 0.7152, 0.0722));
		float coolBias = clamp((rawAlbedo.b - rawAlbedo.r) * 2.5 + 0.5, 0.0, 1.0);
		float iceMask = smoothstep(0.38, 0.72, lum) * (1.0 - smoothstep(0.18, 0.48, sat)) * (0.65 + 0.35 * coolBias) * (1.0 - waterMask);

		// Enrich surface contrast & tri-planar mineral color gradients on land; deep turbulent ocean on water
		float orbitalContrast = mix(0.86, 1.16, clamp(macroGrad * 0.55 + microDetail * 0.45, 0.0, 1.0));
		float contrastMod = mix(1.0, orbitalContrast, mix(0.35, 1.0, 1.0 - macroFade)) * triAlbedoMod;
		vec3 mineralTint = mix(vec3(0.94, 0.97, 1.03), vec3(1.04, 0.98, 0.93), macroGrad) * triTint;
		vec3 icyLift = mix(vec3(1.0), vec3(0.90, 0.98, 1.12), iceMask * 0.55);
		vec3 landColor = final.rgb * contrastMod * mineralTint * icyLift;

#if (NUM_LIGHTS > 0)
		// Per-pixel directional micro-relief shading on sunlit land
		vec3 L0 = normalize(uLight[0].position.xyz);
		float nBase = max(dot(tnorm, L0), 0.0);
		float nSurf = max(dot(landNorm, L0), 0.0);
		float microShade = mix(1.0, clamp((nSurf + 0.10) / (nBase + 0.10), 0.58, 1.42), smoothstep(0.02, 0.14, nBase) * (1.0 - waterMask));
		landColor *= microShade;
#endif

#ifdef ATMOSPHERE
		float cloudShade = clamp(CloudWeather.x * CloudWeather.z, 0.0, 1.0);
		float stormShade = clamp(CloudWeather.y * CloudWeather.z, 0.0, 1.0);
		float lightningPulse = clamp(CloudWeather.w, 0.0, 1.0);
#else
		float cloudShade = 0.0;
		float stormShade = 0.0;
		float lightningPulse = 0.0;
#endif

		// Deep ocean color + true reflected sky-dome colors via Rayleigh+Mie LUT along reflect(eyenorm, surfNorm)
		vec3 oceanColor = vec3(0.0);
		if (waterMask > 0.005) {
			float NdotVWater = clamp(dot(surfNorm, -eyenorm), 0.0, 1.0);
			float waterFresnel = 0.03 + 0.97 * pow(1.0 - NdotVWater, 4.0);
			vec3 waterReflDir = reflect(eyenorm, surfNorm);
			// Lift grazing wave-trough reflections slightly above local tangent plane so rays never plunge underground
			vec3 skyReflDir = normalize(waterReflDir + radialUp * max(0.018 - dot(waterReflDir, radialUp), 0.0));
			vec3 P = eyeposScaled - geosphereCenter;
			vec3 pSurf = radialUp * max(length(P), 1.0001);

			vec3 skyReflCol = vec3(0.0);
			vec3 oceanBodyLight = vec3(0.0);
			vec3 cloudReflLit = vec3(0.0);
#if (NUM_LIGHTS > 0)
			const float kAU = 149598000000.0;
			for (int i = 0; i < NUM_LIGHTS; ++i) {
				vec3 L = normalize(uLight[i].position.xyz);
				float sunElev = dot(radialUp, L);
				float uneclipsed = clamp(calcUneclipsed(eclipse, NumShadows, radialUp, L), 0.0, 1.0);
				vec3 lightPosAU = uLight[i].position.xyz / kAU;
				float skyIntensity = 1.0 / max(dot(lightPosAU, lightPosAU), 1e-6);
				float surfIntensity = 1.0 / max(length(lightPosAU), 1e-4);

				vec3 linearStarCol = toLinear(uLight[i].diffuse.rgb);
#ifdef ATMOSPHERE
				skyReflCol += calculateReflectedSkyColor(pSurf, skyReflDir, L, linearStarCol, densityLUT, scatterLUT) * skyIntensity * 20.0 * uneclipsed;
				vec3 surfTrans = calculateRayTransmittance(pSurf, L, scatterLUT);
				float bodyElev = pow(smoothstep(-0.005, 0.42, sunElev), 1.85);
				oceanBodyLight += linearStarCol * surfTrans * bodyElev * surfIntensity * uneclipsed;
				float cDay = smoothstep(-0.06, 0.24, sunElev) * (0.12 + 0.88 * pow(max(sunElev, 0.0), 0.80));
				float cTw = exp(-pow((sunElev - 0.015) * 9.5, 2.0)) * smoothstep(-0.08, 0.02, sunElev);
				cloudReflLit += (linearStarCol * cDay + vec3(0.85, 0.34, 0.12) * max(max(linearStarCol.r, linearStarCol.g), linearStarCol.b) * cTw * 0.22) * uneclipsed;
#else
				oceanBodyLight += linearStarCol * pow(smoothstep(-0.01, 0.40, sunElev), 1.75) * surfIntensity * uneclipsed;
#endif
			}
#else
			skyReflCol = toLinear(atmosColor.rgb) * 0.20;
			oceanBodyLight = vec3(0.20);
			cloudReflLit = vec3(0.20);
#endif
			vec3 nightSkyFloor = vec3(0.0008, 0.0014, 0.0026);
			vec3 finalSkyRefl = max(skyReflCol, nightSkyFloor);
			vec3 overcastCloudRefl = max(
				mix(vec3(0.055, 0.068, 0.088), vec3(0.024, 0.030, 0.042), stormShade) * cloudReflLit,
				nightSkyFloor * 0.65);
			finalSkyRefl = mix(finalSkyRefl, overcastCloudRefl, clamp(cloudShade * (0.82 + 0.14 * stormShade), 0.0, 0.95));
			finalSkyRefl += vec3(0.55, 0.72, 1.0) * lightningPulse * 0.22;

			vec3 deepOcean = mix(vec3(0.006, 0.036, 0.110), vec3(0.003, 0.018, 0.042), clamp(cloudShade * 0.72 + stormShade * 0.28, 0.0, 1.0));
			vec3 crestOcean = mix(vec3(0.018, 0.095, 0.175), vec3(0.009, 0.038, 0.065), clamp(cloudShade * 0.72 + stormShade * 0.28, 0.0, 1.0));
			float turbidity = clamp((waterTurb - 0.28) * 1.9, 0.0, 1.0);
			float overcastAtten = 1.0 - cloudShade * (0.62 + 0.18 * stormShade);
			vec3 oceanBase = mix(deepOcean, crestOcean, turbidity) * (oceanBodyLight * overcastAtten + finalSkyRefl * 0.08 + vec3(0.0008));
			float reflMix = clamp(waterFresnel * 0.94, 0.03, 0.96);
			oceanColor = mix(oceanBase, finalSkyRefl, reflMix);
			vec3 foamLit = oceanBodyLight * overcastAtten * 0.95 + finalSkyRefl * 0.30 + vec3(0.0012);
			vec3 foamBase = vec3(0.86, 0.91, 0.95) * foamLit;
			oceanColor = mix(oceanColor, foamBase, surfFoam * 0.82);
			oceanColor += vec3(0.58, 0.74, 1.0) * lightningPulse * (0.04 + 0.22 * waterFresnel + 0.10 * surfFoam);
		}

		// Soft wet-sand transition along the organically perturbed shoreline
		float wetEdge = waterMask * (1.0 - waterMask) * 4.0;
		landColor = mix(landColor, landColor * vec3(0.68, 0.65, 0.60), wetEdge * 0.55);
		final.rgb = (waterMask > 0.005) ? mix(landColor, oceanColor, waterMask) : landColor;

		// Matte soil/grass roughness (0.96), scree (0.90), exposed cliff rock (0.68), ice (0.24), water (0.08)
		float rockRough = mix(0.96, 0.68, cliffMask) - 0.06 * screeMask;
		float matRoughness = mix(mix(rockRough, 0.24, iceMask), 0.08, waterMask);

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
			float VdotH = max(dot(viewDir, H), 0.0);

			// GGX microfacet specular with roughness-damped Fresnel (prevents plastic sheen on matte soil/grass)
			float a = max(matRoughness * matRoughness, 0.02);
			float a2 = a * a;
			float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
			float D = a2 / (3.14159 * denom * denom + 1e-4);
			float F0 = mix(mix(0.02, 0.055, cliffMask), 0.045, iceMask);
			float fresnel = F0 + (max(1.0 - matRoughness, F0) - F0) * pow(1.0 - VdotH, 5.0);
			float ggxSpec = clamp(D * fresnel * 0.35, 0.0, 1.6);

			// Crisp crystalline specular highlights on ice + subtle mineral sheen strictly on exposed rock/cliffs
			float iceGlint = (pow(NdotH, 52.0) * 1.00 + ggxSpec * 0.90) * (0.72 + 0.55 * microDetail);
			float rockSpec = ggxSpec * (cliffMask * 0.24 + screeMask * 0.06) * (0.65 + 0.35 * clamp(triMid * 0.5 + 0.5, 0.0, 1.0));
			vec3 iceSpecCol = mix(lightCol, vec3(0.84, 0.94, 1.0), 0.52);
			vec3 rockSpecCol = mix(lightCol, vec3(1.0, 0.95, 0.88), 0.28);

			// Crisp glittering ocean sun sparkle + whitecap illumination (attenuated under overcast clouds and sunset transmittance)
			float sunAboveHoriz = smoothstep(-0.005, 0.08, dot(radialUp, L));
#ifdef ATMOSPHERE
			vec3 pSpecSurf = radialUp * max(length(eyeposScaled - geosphereCenter), 1.0001);
			vec3 specAtmosTrans = calculateRayTransmittance(pSpecSurf, L, scatterLUT);
#else
			vec3 specAtmosTrans = vec3(1.0);
#endif
			float directCloudTrans = clamp(1.0 - cloudShade * 0.92 - stormShade * 0.08, 0.04, 1.0);
			float waterSpec = (pow(NdotH, 240.0) * 2.4 + pow(NdotH, 42.0) * 0.16) * waterMask * (1.0 - surfFoam * 0.85) * directCloudTrans * directCloudTrans * sunAboveHoriz;
			vec3 landSpec = (iceSpecCol * iceGlint * iceMask + rockSpecCol * rockSpec * (1.0 - iceMask * 0.65)) *
				(1.0 - waterMask) * exp(-0.000045 * distMeters);
			vec3 foamLight = lightCol * vec3(0.92, 0.95, 0.98) * surfFoam * 0.68 * mix(1.0, 0.40, cloudShade) * sunAboveHoriz;
			specAccum += (landSpec + lightCol * specAtmosTrans * waterSpec + foamLight) * NdotL;
		}

		final.rgb += specAccum;

#ifdef ATMOSPHERE
		// Add atmospheric Rayleigh aerial perspective after surface detail and micro-shading (dampened over overcast ocean)
		final.rgb += varyingInscatter * (1.0 - waterMask * cloudShade * 0.65);

		// Atmospheric Fresnel limb halo strictly gated to orbital/space views (eliminates milky wash at low altitude)
		float camAltRad = max(length(geosphereCenter) - 1.0, 0.0);
		float orbitLimbFade = smoothstep(0.05, 0.25, camAltRad);
		float NdotV = clamp(dot(tnorm, viewDir), 0.0, 1.0);
		float limb = pow(1.0 - NdotV, 3.2);
		vec3 atmoTint = toLinear(mix(atmosColor.rgb, vec3(0.62, 0.86, 1.0), 0.35 + 0.30 * iceMask));
		float litFactor = smoothstep(0.0, 0.16, maxSunLit) * pow(maxSunLit, 0.55);
		final.rgb += atmoTint * limb * litFactor * 0.82 * orbitLimbFade;
#endif
#endif // NUM_LIGHTS > 0
		vec3 fragPosM = varyingEyepos * metersPerViewUnit;
		vec3 spotLandAlbedo = clamp(toLinear(clamp(rawAlbedo, 0.0, 1.0)) * contrastMod * mineralTint * icyLift, 0.0, 1.25);
		vec3 spotAlbedo = mix(spotLandAlbedo, vec3(0.015, 0.055, 0.14), waterMask);
		final.rgb += EvalShipSpotLights(fragPosM, surfNorm, -eyenorm, spotAlbedo, matRoughness, waterMask);
	} else {
		float metersPerViewUnit = geosphereRadius * geosphereInvRadius;
		vec3 fragPosM = varyingEyepos * metersPerViewUnit;
		vec3 spotAlbedo = toLinear(clamp(rawAlbedo, 0.0, 1.0)) * detailMul.rgb;
		final.rgb += EvalShipSpotLights(fragPosM, normalize(varyingNormal), -normalize(varyingEyepos), spotAlbedo, 0.85, 0.0);
	}

	frag_color = final;
#ifdef TERRAIN_WITH_LAVA
	frag_color += vertexColor;
#endif

	frag_color = toSRGB(1 - exp(-frag_color));
}

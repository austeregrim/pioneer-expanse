// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"
#include "basesphere_uniforms.glsl"

in vec3 varyingEyepos;
in vec3 varyingNormal;
in vec3 varyingTexCoord0;
flat in vec3 varyingPoleView;

uniform samplerCube texture0; //diffuse

uniform int NumShadows;
uniform float enhancedGraphics;
uniform float uTime;
uniform vec4 ggParams;      // x: archetype (0=Jup,1=Sat,2=Ura,3=Nep), y: seed, z: turbulence, w: bandScale
uniform vec4 ggStormParams; // x: stormStrength, y: primaryLat, z: primaryLon, w: stormStyle

out vec4 frag_color;

float ggHash31(vec3 p)
{
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float ggNoise3D(vec3 p)
{
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float n000 = ggHash31(i + vec3(0.0, 0.0, 0.0));
	float n100 = ggHash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = ggHash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = ggHash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = ggHash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = ggHash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = ggHash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = ggHash31(i + vec3(1.0, 1.0, 1.0));

	float nx00 = mix(n000, n100, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx11 = mix(n011, n111, f.x);

	return mix(mix(nx00, nx10, f.y), mix(nx01, nx11, f.y), f.z);
}

// Band-limited 3D FBM centered at 0.5; smoothly attenuates sub-pixel octaves to prevent aliasing
float ggFbmBL(vec3 p, float pixelFreq)
{
	float sum = 0.0;
	float amp = 0.5;
	float freqMult = 1.0;
	for (int i = 0; i < 4; ++i) {
		float nyquistFade = 1.0 - smoothstep(0.18, 0.52, pixelFreq * freqMult);
		if (nyquistFade <= 0.001)
			break;
		sum += amp * nyquistFade * (ggNoise3D(p * freqMult + vec3(11.3, 7.1, 5.9) * float(i)) - 0.5);
		freqMult *= 2.03;
		amp *= 0.48;
	}
	return clamp(0.5 + sum, 0.0, 1.0);
}

vec3 ggRotateY(vec3 v, float ang)
{
	float c = cos(ang);
	float s = sin(ang);
	return vec3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
}

// Zero-shear anticyclonic storm vortex: bounded static streamline deflection + rigid-body internal spin
vec3 applyVortexStorm(vec3 dir, vec3 stormCenter, float stormRadius, float swirlAmount, float spinPhase,
	out float stormRim, out float stormCore, out float spiralArms)
{
	vec3 sc = normalize(stormCenter);
	vec3 diff = dir - sc;
	float d = length(diff);
	if (d > stormRadius * 2.8) {
		stormRim = 0.0;
		stormCore = 0.0;
		spiralArms = 0.0;
		return dir;
	}

	vec3 upRef = abs(sc.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 east = normalize(cross(upRef, sc));
	vec3 north = cross(sc, east);

	// Elliptical anticyclone footprint (wider along longitude)
	float rx = stormRadius * 1.65;
	float ry = stormRadius;
	float u = dot(diff, east) / rx;
	float v = dot(diff, north) / ry;
	float r = sqrt(u * u + v * v);

	// Bounded time-independent streamline deflection so surrounding bands curve smoothly around the oval
	float env = exp(-r * r * 1.45);
	float ang = clamp(swirlAmount, -2.4, 2.4) * env;
	float c = cos(ang);
	float s = sin(ang);
	vec2 rotUV = vec2(u * c - v * s, u * s + v * c);

	// Rigid-body internal vortex rotation (constant angular velocity across radius = zero spiral winding shear)
	float cs = cos(spinPhase);
	float sn = sin(spinPhase);
	vec2 spinUV = vec2(u * cs - v * sn, u * sn + v * cs);
	float theta = atan(spinUV.y, spinUV.x);
	float swirlSign = (swirlAmount >= 0.0) ? 1.0 : -1.0;
	float arms = 0.5 + 0.5 * sin(theta * 2.0 + r * 4.2 * swirlSign);
	spiralArms = arms * smoothstep(1.30, 0.18, r) * smoothstep(0.06, 0.38, r);

	// Raised eyewall collar & recessed inner storm core
	stormRim = exp(-pow((r - 0.62) / 0.28, 2.0));
	stormCore = exp(-r * r * 3.8);

	vec3 warped = sc + east * (rotUV.x * rx) + north * (rotUV.y * ry);
	return normalize(mix(dir, normalize(warped), smoothstep(1.9, 0.35, r)));
}

void main(void)
{
	vec3 eyeposScaled = varyingEyepos * geosphereInvRadius;
	vec3 eyenorm = normalize(varyingEyepos);
	vec3 tnorm = normalize(varyingNormal);
	vec4 diff = vec4(0.0);
	float surfaceDist = length(eyeposScaled);

	vec3 V = (eyeposScaled - geosphereCenter);

	if (enhancedGraphics < 0.5) {
		// Classic Pioneer fallback
		for (int i=0; i<NUM_LIGHTS; ++i) {
			vec3 L = normalize(uLight[i].position.xyz);
			float uneclipsed = clamp(calcUneclipsed(eclipse, NumShadows, V, L), 0.0, 1.0);
			CalcPlanetDiffuse(diff, uLight[i].diffuse, L, tnorm, uneclipsed);
		}

		float ldprod=0.0;
		float fogFactor=0.0;
		CalcPlanetFogFactor(ldprod, fogFactor, eyenorm, eyeposScaled - geosphereCenter, surfaceDist);

		float atmpower = (diff.r+diff.g+diff.b)/3.0;
		vec4 sunset = vec4(0.8,clamp(pow(atmpower,0.8),0.0,1.0),clamp(pow(atmpower,1.2),0.0,1.0),1.0);
		vec4 texColor = texture(texture0, varyingTexCoord0);

		frag_color =
			material.emission +
			fogFactor *
			((scene.ambient * texColor) +
			(diff * texColor)) +
			(1.0-fogFactor)*(diff*atmosColor) +
			  (0.02-clamp(fogFactor,0.0,0.01))*diff*ldprod*sunset +
			  (pow((1.0-pow(fogFactor,0.75)),256.0)*0.4*diff*atmosColor)*sunset;
		return;
	}

	// Enhanced Graphics: Zero-shear, band-limited smoothly layered gas giant atmosphere
	const float TWO_PI = 2.0 * PI;

	vec3 dir = normalize(varyingTexCoord0);
	float lat = clamp(dir.y, -1.0, 1.0);
	float absLat = abs(lat);
	float lon = (absLat < 0.999) ? atan(dir.z, dir.x) : 0.0;
	float pixelFootprint = clamp(max(length(dFdx(dir)), length(dFdy(dir))), 0.0005, 0.5);

	float archetype = ggParams.x;
	float seed = ggParams.y;
	float turbulence = (ggParams.w > 0.1) ? clamp(ggParams.z, 0.0, 1.0) : 0.45;
	float bandScale = (ggParams.w > 0.1) ? clamp(ggParams.w, 2.0, 10.0) : 5.5;
	float dayPhase = uTime * (TWO_PI / 86400.0);

	// 1. Zero-shear rigid-body counter-drifting zonal frames (integer multiples of 2*PI/86400s wrap seamlessly)
	vec3 dirEast = ggRotateY(dir, dayPhase * 6.0);
	vec3 dirWest = ggRotateY(dir, -dayPhase * 4.0);
	vec3 driftDir = ggRotateY(dir, dayPhase * 2.0);

	float bandPhase = lat * bandScale * PI + seed * 0.37;
	float rawJet = sin(bandPhase);
	float shearEdge = 1.0 - abs(rawJet);
	float jetBlend = smoothstep(-0.35, 0.35, rawJet);

	// 2. Band-limited macro warp & smooth atmospheric cloud decks sampled separately per frame
	vec3 seedShift = vec3(seed * 0.31, seed * 0.17, -seed * 0.23);
	float warpAmp = 0.22 + 0.48 * turbulence;

	vec3 warpEast = vec3(
		ggFbmBL(dirEast * vec3(2.0, 4.2, 2.0) + seedShift + vec3(0.0, 1.3, 2.7), pixelFootprint * 4.2) - 0.5,
		ggFbmBL(dirEast * vec3(2.0, 4.2, 2.0) + seedShift + vec3(5.2, -2.1, 1.4), pixelFootprint * 4.2) - 0.5,
		ggFbmBL(dirEast * vec3(2.0, 4.2, 2.0) + seedShift + vec3(-3.4, 4.8, -1.9), pixelFootprint * 4.2) - 0.5
	);
	vec3 warpWest = vec3(
		ggFbmBL(dirWest * vec3(2.0, 4.2, 2.0) + seedShift + vec3(2.1, -0.7, 3.3), pixelFootprint * 4.2) - 0.5,
		ggFbmBL(dirWest * vec3(2.0, 4.2, 2.0) + seedShift + vec3(-4.1, 1.8, -2.5), pixelFootprint * 4.2) - 0.5,
		ggFbmBL(dirWest * vec3(2.0, 4.2, 2.0) + seedShift + vec3(1.7, 3.6, -0.9), pixelFootprint * 4.2) - 0.5
	);

	float cloudEast = ggFbmBL(dirEast * vec3(3.2, 6.8, 3.2) + seedShift + warpEast * warpAmp, pixelFootprint * 6.8);
	float cloudWest = ggFbmBL(dirWest * vec3(3.2, 6.8, 3.2) + seedShift + warpWest * warpAmp, pixelFootprint * 6.8);
	float wispEast  = ggFbmBL(dirEast * vec3(5.4, 10.8, 5.4) + seedShift * 1.3 + warpEast * (warpAmp * 1.25), pixelFootprint * 10.8);
	float wispWest  = ggFbmBL(dirWest * vec3(5.4, 10.8, 5.4) + seedShift * 1.3 + warpWest * (warpAmp * 1.25), pixelFootprint * 10.8);

	float cloudDeck = mix(cloudWest, cloudEast, jetBlend);
	float cloudWisps = mix(wispWest, wispEast, jetBlend);

	// 3. Archetype-appropriate zero-shear storms
	float stormStrength = clamp(ggStormParams.x, 0.0, 1.0);
	float primaryRim = 0.0, primaryCore = 0.0, primaryArms = 0.0;
	float ovalRim = 0.0, ovalCore = 0.0, ovalArms = 0.0;
	vec3 stormDir = driftDir;

	if (stormStrength > 0.01) {
		float stormLat = clamp(ggStormParams.y, -0.65, 0.65);
		float stormLon = ggStormParams.z;
		float cLat = sqrt(max(1.0 - stormLat * stormLat, 0.0));
		vec3 primaryCenter = vec3(cos(stormLon) * cLat, stormLat, sin(stormLon) * cLat);
		float baseR = (archetype < 0.5) ? 0.125 : ((archetype >= 2.5) ? 0.095 : 0.072);
		float primaryRadius = baseR * (0.75 + 0.35 * stormStrength);
		float swirlSign = (stormLat < 0.0) ? 1.0 : -1.0;

		stormDir = applyVortexStorm(
			stormDir,
			ggRotateY(primaryCenter, dayPhase * 3.0),
			primaryRadius,
			swirlSign * (1.7 + 0.65 * stormStrength),
			swirlSign * dayPhase * 12.0,
			primaryRim, primaryCore, primaryArms
		);

		if (archetype < 0.5 && stormStrength > 0.35) {
			float r2, c2, a2;
			float r3, c3, a3;
			float lat2 = -stormLat * 0.72 + 0.08 * sin(seed);
			float lon2 = stormLon + 2.25 + 0.5 * cos(seed * 1.7);
			float cLat2 = sqrt(max(1.0 - lat2 * lat2, 0.0));
			vec3 center2 = vec3(cos(lon2) * cLat2, lat2, sin(lon2) * cLat2);
			float sign2 = (lat2 < 0.0) ? 1.0 : -1.0;

			stormDir = applyVortexStorm(
				stormDir,
				ggRotateY(center2, dayPhase * 1.0),
				0.058,
				sign2 * 1.65,
				sign2 * dayPhase * 14.0,
				r2, c2, a2
			);

			float lat3 = stormLat * 0.60 - 0.12 * cos(seed * 0.9);
			float lon3 = stormLon - 2.15 + 0.4 * sin(seed * 2.3);
			float cLat3 = sqrt(max(1.0 - lat3 * lat3, 0.0));
			vec3 center3 = vec3(cos(lon3) * cLat3, lat3, sin(lon3) * cLat3);
			float sign3 = (lat3 < 0.0) ? 1.0 : -1.0;

			stormDir = applyVortexStorm(
				stormDir,
				ggRotateY(center3, dayPhase * 4.0),
				0.046,
				sign3 * 1.55,
				sign3 * dayPhase * 14.0,
				r3, c3, a3
			);

			ovalRim = clamp(r2 + r3, 0.0, 1.0);
			ovalCore = clamp(c2 + c3, 0.0, 1.0);
			ovalArms = clamp(a2 + a3, 0.0, 1.0);
		}
	}

	// 4. Smoothly defined gas layers & bounded Rossby waves
	float warpedLat = clamp(stormDir.y, -1.0, 1.0);
	float eqMask = 1.0 - smoothstep(0.58, 0.90, abs(warpedLat));
	float rossbyWave = sin(lon * 4.0 - dayPhase * 4.0 + seed * 0.7) * 0.60
					 + cos(lon * 7.0 + dayPhase * 6.0 - seed * 1.1) * 0.40;
	float waveLatDisp = rossbyWave * (0.005 + 0.016 * turbulence) * eqMask;

	// Subtle Saturnian polar hexagonal wave
	float isSaturn = (archetype >= 0.5 && archetype < 1.5) ? 1.0 : 0.0;
	float hexRing = exp(-pow((absLat - 0.80) / 0.065, 2.0));
	waveLatDisp += isSaturn * hexRing * sin(lon * 6.0 - dayPhase * 6.0 + seed) * 0.015;

	float eddyLatOffset = ((cloudDeck - 0.5) * 0.032 + (cloudWisps - 0.5) * 0.012) * (0.25 + 0.95 * shearEdge) * turbulence * eqMask;
	float bandLat = clamp(warpedLat + waveLatDisp + eddyLatOffset, -0.9998, 0.9998);

	float lonOffset = ((cloudDeck - 0.5) * 0.035 + (cloudWisps - 0.5) * 0.015) * turbulence * eqMask;
	vec3 lonShifted = ggRotateY(stormDir, lonOffset);
	float horizLen = length(lonShifted.xz);
	vec2 horizUnit = (horizLen > 1e-5) ? (lonShifted.xz / horizLen) : vec2(1.0, 0.0);

	float rUpper = sqrt(max(1.0 - bandLat * bandLat, 0.0));
	vec3 sampleDirUpper = vec3(horizUnit.x * rUpper, bandLat, horizUnit.y * rUpper);

	float bandLatDeep = clamp(bandLat - 0.022 * sign(lat + 0.001), -0.9998, 0.9998);
	float rLower = sqrt(max(1.0 - bandLatDeep * bandLatDeep, 0.0));
	vec3 sampleDirLower = vec3(horizUnit.x * rLower, bandLatDeep, horizUnit.y * rLower);

	vec4 texUpper = texture(texture0, sampleDirUpper);
	vec4 texLower = texture(texture0, sampleDirLower);

	// Broad, smooth layered zones & belts
	float b1 = sin(bandLat * bandScale * PI + seed * 0.37);
	float b2 = sin(bandLat * bandScale * 1.85 * PI + seed * 1.13 + 0.7);
	float b3 = cos(bandLat * bandScale * 0.52 * PI - seed * 0.61);
	float layerSignal = b1 * 0.58 + b2 * 0.27 + b3 * 0.15;
	float zoneFactor = smoothstep(-0.72, 0.72, layerSignal);
	float subLayer = 0.5 + 0.5 * sin(bandLat * bandScale * 2.8 * PI + b1 * 0.7 + seed * 2.1);

	float cloudBillow = smoothstep(0.28, 0.74, cloudDeck * 0.72 + cloudWisps * 0.28);
	float deckMix = clamp(mix(zoneFactor, zoneFactor * 0.58 + cloudBillow * 0.42, 0.25 + 0.75 * turbulence), 0.0, 1.0);

	vec3 deepBelt = texLower.rgb * mix(0.89, 0.78, 0.35 + 0.65 * turbulence);
	vec3 brightZone = texUpper.rgb * mix(1.07, 1.16, 0.35 + 0.65 * turbulence);
	vec3 cloudCol = mix(deepBelt, brightZone, deckMix);

	cloudCol *= mix(0.94, 1.06, subLayer * (0.45 + 0.45 * turbulence));
	cloudCol *= (1.0 + (cloudWisps - 0.5) * (0.04 + 0.20 * turbulence));

	// High-altitude pale methane cirrus streaks on Neptune-class worlds
	if (archetype >= 2.5) {
		float cirrusBand = exp(-pow((absLat - 0.36) / 0.11, 2.0)) + 0.6 * exp(-pow((absLat - 0.56) / 0.08, 2.0));
		float cirrusStreak = smoothstep(0.56, 0.80, cloudWisps * 0.65 + cloudDeck * 0.35);
		vec3 cirrusCol = mix(brightZone * 1.18, vec3(0.84, 0.93, 0.99), 0.45);
		cloudCol = mix(cloudCol, cirrusCol, clamp(cirrusBand * cirrusStreak * 0.42, 0.0, 0.5));
	}

	// Palette-harmonized storm shading
	if (stormStrength > 0.01) {
		float stormStyle = ggStormParams.w;
		vec3 pRimCol;
		vec3 pCoreCol;
		if (stormStyle < 0.25) {
			pRimCol = mix(cloudCol * 1.24, vec3(0.95, 0.87, 0.76), 0.30);
			pCoreCol = mix(cloudCol * 0.78, vec3(0.76, 0.42, 0.27), 0.42);
		} else if (stormStyle < 0.75) {
			pRimCol = mix(cloudCol * 1.18, vec3(0.94, 0.96, 0.98), 0.35);
			pCoreCol = mix(cloudCol * 1.08, vec3(0.88, 0.91, 0.94), 0.28);
		} else {
			pRimCol = mix(cloudCol * 1.22, vec3(0.84, 0.93, 0.99), 0.44);
			pCoreCol = mix(cloudCol * 0.56, vec3(0.08, 0.14, 0.32), 0.45);
		}
		float pSwirlW = clamp((primaryRim * 0.55 + primaryArms * 0.42) * stormStrength, 0.0, 0.80);
		float pCoreW = clamp(primaryCore * 0.62 * stormStrength, 0.0, 0.72);
		cloudCol = mix(cloudCol, pRimCol, pSwirlW);
		cloudCol = mix(cloudCol, pCoreCol, pCoreW);

		if (ovalRim + ovalCore + ovalArms > 0.001) {
			vec3 oRimCol = mix(cloudCol * 1.18, vec3(0.94, 0.96, 0.98), 0.35);
			vec3 oCoreCol = mix(cloudCol * 1.08, vec3(0.88, 0.91, 0.94), 0.28);
			cloudCol = mix(cloudCol, oRimCol, clamp(ovalRim * 0.48 + ovalArms * 0.35, 0.0, 0.65));
			cloudCol = mix(cloudCol, oCoreCol, clamp(ovalCore * 0.45, 0.0, 0.55));
		}
	}

	// 5. Smooth circumpolar hood (zero chord-mix folding)
	float polarHood = smoothstep(0.66, 0.96, absLat);
	if (polarHood > 0.001) {
		vec3 polarDir = ggRotateY(dir, sign(lat) * dayPhase * 4.0);
		float polarCloud = ggFbmBL(polarDir * 4.2 + seedShift, pixelFootprint * 4.2);
		vec3 icePolarCol = mix(cloudCol * 1.08, mix(texUpper.rgb, atmosColor.rgb, 0.35) * 1.14, 0.45);
		vec3 gasPolarCol = cloudCol * mix(0.82, 0.96, polarCloud);
		vec3 polarCol = (archetype >= 1.5) ? icePolarCol : mix(gasPolarCol, icePolarCol, 0.25);
		cloudCol = mix(cloudCol, mix(polarCol, polarCol * (0.90 + 0.20 * polarCloud), 0.5 + 0.5 * turbulence), polarHood * 0.65);
	}

	// 6. Artifact-free analytical band-edge normal shading (no screen-space dFdx/dFdy bump stippling)
	vec3 poleProj = varyingPoleView - tnorm * dot(varyingPoleView, tnorm);
	float poleProjLen = length(poleProj);
	vec3 cloudNorm = tnorm;
	if (poleProjLen > 1e-4) {
		vec3 northTangent = poleProj / poleProjLen;
		float bandSlope = cos(bandLat * bandScale * PI + seed * 0.37) * (0.035 + 0.045 * turbulence) * (1.0 - polarHood);
		cloudNorm = normalize(tnorm + northTangent * bandSlope);
	}

	for (int i=0; i<NUM_LIGHTS; ++i) {
		vec3 L = normalize(uLight[i].position.xyz);
		float uneclipsed = clamp(calcUneclipsed(eclipse, NumShadows, V, L), 0.0, 1.0);
		vec4 lightDiff = uLight[i].diffuse;
		// Only apply gentle white-balance when starlight is strongly monochrome (e.g. deep M-dwarfs)
		float lMax = max(max(lightDiff.r, lightDiff.g), lightDiff.b);
		float lMin = min(min(lightDiff.r, lightDiff.g), lightDiff.b);
		float lSat = (lMax > 0.001) ? (lMax - lMin) / lMax : 0.0;
		float lLum = dot(lightDiff.rgb, vec3(0.2126, 0.7152, 0.0722));
		float wbStrength = smoothstep(0.45, 0.88, lSat) * 0.26;
		lightDiff.rgb = mix(lightDiff.rgb, vec3(max(lLum, 0.28)), wbStrength);
		CalcPlanetDiffuse(diff, lightDiff, L, cloudNorm, uneclipsed);
	}

	float ldprod=0.0;
	float fogFactor=0.0;
	CalcPlanetFogFactor(ldprod, fogFactor, eyenorm, eyeposScaled - geosphereCenter, surfaceDist);

	float atmpower = (diff.r+diff.g+diff.b)/3.0;
	vec4 sunset = vec4(0.8,clamp(pow(atmpower,0.8),0.0,1.0),clamp(pow(atmpower,1.2),0.0,1.0),1.0);

	// 7. Sunlit Fresnel atmospheric limb glow (strictly dark on the night side!)
	float NdotV = clamp(dot(tnorm, -eyenorm), 0.0, 1.0);
	float limbFresnel = pow(max(1.0 - NdotV, 0.0), 3.6);
	float litLevel = clamp(max(max(diff.r, diff.g), diff.b), 0.0, 1.0);
	vec3 limbTint = mix(atmosColor.rgb, mix(texUpper.rgb, vec3(0.72, 0.86, 1.0), 0.45), 0.5);
	vec3 limbGlow = limbTint * limbFresnel * smoothstep(0.0, 0.22, litLevel) * pow(max(litLevel, 0.0), 0.65) * 0.62;

	vec4 enhancedTex = vec4(clamp(cloudCol, 0.0, 1.25), texUpper.a);

	frag_color =
		material.emission +
		fogFactor *
		((scene.ambient * enhancedTex) +
		(diff * enhancedTex)) +
		(1.0-fogFactor)*(diff*atmosColor) +
		  (0.02-clamp(fogFactor,0.0,0.01))*diff*ldprod*sunset +
		  (pow((1.0-pow(fogFactor,0.75)),256.0)*0.4*diff*atmosColor)*sunset +
		vec4(limbGlow, 0.0);
}

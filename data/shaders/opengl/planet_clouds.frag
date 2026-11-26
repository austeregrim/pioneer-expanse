// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

in vec3 eyePos;
flat in vec3 objAxisX;
flat in vec3 objAxisY;
flat in vec3 objAxisZ;

// cloudParams: x = coverage [0..1], y = seed offset, z = camera radial distance (planet radii), w = cloud shell radius
uniform vec4 cloudParams;
// cloudTint: rgb = atmospheric/cloud color tint, a = opacity scale
uniform vec4 cloudTint;
// weatherParams: x = stormIntensity [0..1], y = planetary wind drift scale, z = lightningFlash [0..1], w = dustFactor [0..1]
uniform vec4 weatherParams;
// cloudScale: x = planetRadKm, y = cloudAltKm, z = camAltKm, w = atmoDense [0..1]
uniform vec4 cloudScale;
// cloudGeom: x = cloudRad^2 - camLen^2, y = planetRadM, z = projC (m[10]), w = projD (m[14])
uniform vec4 cloudGeom;
// cloudCenter: planet center in view space (in planet radii)
uniform vec3 cloudCenter;
// layerParams: x = layerType (0=lower cumulus/storm, 1=upper cirrus/anvil), y = localCover [0..1], z = camLocalWeight [0..1], w = layerOpacity
uniform vec4 layerParams;
// flashCell: xyz = lightning cell unit dir in planet object space, w = flash intensity [0..1]
uniform vec4 flashCell;
// camDirObj: camera unit radial direction in planet object space
uniform vec3 camDirObj;
uniform float uTime;
uniform float cloudQuality;

out vec4 frag_color;

float clHash31(vec3 p)
{
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float clNoise3D(vec3 p)
{
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float n000 = clHash31(i + vec3(0.0, 0.0, 0.0));
	float n100 = clHash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = clHash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = clHash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = clHash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = clHash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = clHash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = clHash31(i + vec3(1.0, 1.0, 1.0));

	float nx00 = mix(n000, n100, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx11 = mix(n011, n111, f.x);

	return mix(mix(nx00, nx10, f.y), mix(nx01, nx11, f.y), f.z);
}

float clFbm3D(vec3 p)
{
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 5; ++i) {
		sum += amp * clNoise3D(p);
		p = p * 2.08 + vec3(11.7, 5.3, 9.1);
		amp *= 0.5;
	}
	return sum;
}

float clFbm3D_3(vec3 p)
{
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 3; ++i) {
		sum += amp * clNoise3D(p);
		p = p * 2.08 + vec3(11.7, 5.3, 9.1);
		amp *= 0.5;
	}
	return sum * (1.0 / 0.875);
}

float clFbm3D_2(vec3 p)
{
	float sum = 0.5 * clNoise3D(p);
	p = p * 2.08 + vec3(11.7, 5.3, 9.1);
	sum += 0.25 * clNoise3D(p);
	return sum * (1.0 / 0.75);
}

vec3 clRotateY(vec3 v, float ang)
{
	float c = cos(ang);
	float s = sin(ang);
	return vec3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
}

void main(void)
{
	float stormIntensity = clamp(weatherParams.x, 0.0, 1.0);
	float windDriftScale = max(weatherParams.y, 0.25);
	float dustFactor = clamp(weatherParams.w, 0.0, 1.0);
	float layerType = layerParams.x;
	float isUpperLayer = step(0.5, layerType);

	float baseCoverage = clamp(cloudParams.x + stormIntensity * mix(0.16, 0.20, isUpperLayer), 0.0, 0.96);
	if (baseCoverage <= 0.01 && layerParams.y <= 0.01)
		discard;

	// Smoothly soften clouds when flying directly through the cloud shell altitude (in physical km)
	float planetRadKm = max(cloudScale.x, 100.0);
	float cloudAltKm = max(cloudScale.y, 0.5);
	float camAltKm = cloudScale.z;
	float atmoDense = clamp(cloudScale.w, 0.0, 1.0);
	float shellPassFade = smoothstep(0.18, 1.15, abs(camAltKm - cloudAltKm));
	if (shellPassFade <= 0.01)
		discard;

	// Analytical ray-sphere intersection on exact cloud radius (eliminates icosphere chord sagitta)
	vec3 eyenorm = normalize(eyePos);
	float camLen = cloudParams.z;
	float cloudRad = cloudParams.w;
	float rDiff = cloudGeom.x;
	float viewRad = max(cloudGeom.y, 1.0);
	float projC = cloudGeom.z;
	float projD = cloudGeom.w;

	float b = dot(cloudCenter, eyenorm);
	// Early discard when inside cloud deck and ray plunges into solid planet body
	if (rDiff > 0.0 && b > 0.0) {
		float minRadSq = camLen * camLen - b * b;
		if (minRadSq < 0.996)
			discard;
	}

	// Cancellation-free perpendicular distance discriminant prevents 32-bit float jitter at orbital limbs
	vec3 perp = cloudCenter - eyenorm * b;
	float det = cloudRad * cloudRad - dot(perp, perp);
	if (det <= 0.0)
		discard;
	float sdet = sqrt(det);
	float tHit = (rDiff > 0.0) ? (b + sdet) : (b - sdet);
	if (tHit <= 0.0)
		discard;

	float distZ = -eyenorm.z * tHit * viewRad;
	if (camAltKm > cloudAltKm + 25.0)
		distZ *= 0.992;
	else if (camAltKm > cloudAltKm + 5.0)
		distZ *= 0.997;
	if (distZ <= 0.0)
		discard;
	gl_FragDepth = clamp(projD / distZ - projC, 0.0, 1.0);

	vec3 hitFromCenterView = eyenorm * tHit - cloudCenter;
	vec3 N = normalize(hitFromCenterView);
	vec3 dir = normalize(vec3(dot(N, objAxisX), dot(N, objAxisY), dot(N, objAxisZ)));
	vec3 V = -eyenorm;

	float seed = cloudParams.y;
	// Zero-shear rigid-body drift + bounded time-independent Coriolis bend (never multiply lat * uTime!)
	float driftAngle = uTime * 0.00018 * windDriftScale;
	float lat = clamp(dir.y, -1.0, 1.0);
	float coriolisBend = mix(0.16, 0.26, isUpperLayer) * sin(lat * 3.14159);
	vec3 windDir = clRotateY(dir, driftAngle + coriolisBend + seed);
	float tMorph = uTime * 0.00035 * windDriftScale;

	// Domain-warped swirling weather fronts & wispy cumulus/cirrus formations
	float q = clamp(cloudQuality, 1.0, 4.0);
	vec3 pScale = mix(vec3(4.2, 5.4, 4.2), vec3(2.8, 7.6, 2.8), isUpperLayer);
	vec3 p = windDir * pScale + vec3(seed * 3.1, seed * 1.7, -seed * 2.3);
	vec3 warp = vec3(0.0);
	float fronts = 0.0;
	float wisps = 0.0;
	float detail = 0.0;

	if (q < 1.5) {
		// Low quality: zero domain warp, 2-octave FBM
		fronts = clFbm3D_2(p);
		wisps = clFbm3D_2(p * mix(2.4, 3.0, isUpperLayer) + vec3(tMorph * 0.8, 0.0, 0.0));
	} else if (q < 2.5) {
		// Medium quality: single-sample lightweight warp + 3-octave FBM
		float w = clFbm3D_2(p * 0.75 + vec3(tMorph * 0.4, 0.0, -tMorph * 0.3));
		warp = vec3(w, w * 0.85, w * 0.7);
		fronts = clFbm3D_3(p + warp * 1.65);
		wisps = clFbm3D_3(p * mix(2.6, 3.2, isUpperLayer) - warp + vec3(tMorph * 0.8, 0.0, 0.0));
	} else if (q < 3.5) {
		// High quality: full 3-axis 3-octave warp + rich fronts/wisps
		warp = vec3(
			clFbm3D_3(p * 0.75 + vec3(tMorph * 0.4, 0.0, -tMorph * 0.3)),
			clFbm3D_3(p * 0.75 + vec3(4.2, tMorph * 0.25, 1.9)),
			clFbm3D_3(p * 0.75 + vec3(-2.7, 3.1, tMorph * 0.35))
		);
		fronts = clFbm3D(p + warp * 1.85);
		wisps = clFbm3D_3(p * mix(2.8, 3.4, isUpperLayer) - warp * 1.1 + vec3(tMorph * 0.8, 0.0, 0.0));
		detail = clNoise3D(windDir * 28.0 + warp * 2.2);
	} else {
		// Extreme quality: full 5-octave 3-axis warp + full fronts/wisps/detail
		warp = vec3(
			clFbm3D(p * 0.75 + vec3(tMorph * 0.4, 0.0, -tMorph * 0.3)),
			clFbm3D(p * 0.75 + vec3(4.2, tMorph * 0.25, 1.9)),
			clFbm3D(p * 0.75 + vec3(-2.7, 3.1, tMorph * 0.35))
		);
		fronts = clFbm3D(p + warp * 1.85);
		wisps = clFbm3D(p * mix(2.8, 3.4, isUpperLayer) - warp * 1.1 + vec3(tMorph * 0.8, 0.0, 0.0));
		detail = clNoise3D(windDir * 28.0 + warp * 2.2);
	}

	float rawCloud = mix(fronts * 0.64 + wisps * 0.26 + detail * 0.10, fronts * 0.35 + wisps * 0.52 + detail * 0.13, isUpperLayer);

	// Blend physical km-scale cumulus/cirrus structure + local WeatherSystem coverage overhead for surface sky views
	float surfaceBlend = 1.0 - smoothstep(cloudAltKm * 1.6, cloudAltKm * 6.5, max(camAltKm, 0.0));
	float underCloud = 1.0 - smoothstep(cloudAltKm - 1.2, cloudAltKm + 0.6, camAltKm);
	float camDistKm = length(dir - normalize(camDirObj)) * planetRadKm;
	float localZone = (1.0 - smoothstep(140.0, 480.0, camDistKm)) * surfaceBlend * clamp(layerParams.z, 0.0, 1.0);
	float effCoverage = clamp(mix(baseCoverage, layerParams.y, localZone), 0.0, 0.98);
	if (effCoverage <= 0.01)
		discard;

	float combinedRaw = rawCloud;
	float localRelief = wisps;
	if (surfaceBlend > 0.005 && q >= 1.5) {
		float localScale1 = clamp(planetRadKm / mix(55.0, 42.0, isUpperLayer), 22.0, 260.0);
		float localScale2 = localScale1 * mix(2.8, 3.3, isUpperLayer);
		vec3 localDrift = vec3(tMorph * 1.1, tMorph * 0.2, -tMorph * 0.8);
		float localDecks = (q < 2.5)
			? clFbm3D_2(windDir * localScale1 + localDrift + vec3(seed * 7.3, -seed * 3.1, seed * 5.1))
			: clFbm3D_3(windDir * localScale1 + localDrift + vec3(seed * 7.3, -seed * 3.1, seed * 5.1));
		float localPuffs = (q < 3.5)
			? clFbm3D_2(windDir * localScale2 + localDrift * 1.4 + vec3(-seed * 4.1, seed * 2.9, 1.7))
			: clFbm3D_3(windDir * localScale2 + localDrift * 1.4 + vec3(-seed * 4.1, seed * 2.9, 1.7));
		float localClouds = mix(localDecks * 0.62 + localPuffs * 0.38, localDecks * 0.44 + localPuffs * 0.56, isUpperLayer);
		float rawSurface = localClouds * 0.68 + rawCloud * 0.32;
		combinedRaw = mix(rawCloud, rawSurface, surfaceBlend);
		localRelief = mix(wisps, localPuffs, surfaceBlend);
	}

	// Threshold according to layer coverage: thick heavy overcast in storms, translucent lacy wisps in high cirrus
	float lowCut = mix(mix(0.64, 0.24, effCoverage), mix(0.66, 0.34, effCoverage), isUpperLayer);
	float highCut = lowCut + mix(mix(0.24, 0.16, stormIntensity), 0.30, isUpperLayer);
	float density = smoothstep(lowCut, highCut, combinedRaw);
	if (density <= 0.005)
		discard;

	// Lighting: crisp sunlit white cloud tops from orbit, self-shadowed slate undersides from the ground, night side dark
	vec3 litColor = vec3(0.0);
	float maxDayLit = 0.0;
#if (NUM_LIGHTS > 0)
	float thickness = smoothstep(0.15, 0.85, density);
	float darkCore = mix(0.46, 0.22, clamp(stormIntensity * 0.72 + atmoDense * 0.28, 0.0, 1.0));
	darkCore = mix(darkCore, 0.76, isUpperLayer * 0.65);
	float underBase = mix(0.95, darkCore, thickness * (0.65 + 0.35 * (1.0 - localRelief)));
	vec3 underTint = mix(vec3(0.98, 0.99, 1.0), vec3(0.60, 0.69, 0.82), thickness * (0.55 + 0.45 * underCloud) * (1.0 - 0.55 * isUpperLayer));

	for (int i = 0; i < NUM_LIGHTS; ++i) {
		vec3 L = normalize(uLight[i].position.xyz);
		float ndotl = dot(N, L);

		// Soft atmospheric wrap across the terminator, dropping strictly to 0 on the night side
		float dayLit = smoothstep(-0.08, 0.22, ndotl) * (0.28 + 0.72 * max(ndotl, 0.0));
		maxDayLit = max(maxDayLit, dayLit);
		float twilight = exp(-pow((ndotl - 0.02) * 8.5, 2.0)) * smoothstep(-0.12, 0.0, ndotl);

		// Subtle forward-scatter silver lining when looking toward the sun through clouds from the ground
		float forwardScatter = pow(max(dot(-V, L), 0.0), 6.0) * (1.0 - density * 0.6) * smoothstep(-0.10, 0.15, ndotl);

		vec3 sunCol = uLight[i].diffuse.rgb;
		float lMax = max(max(sunCol.r, sunCol.g), sunCol.b);
		float lMin = min(min(sunCol.r, sunCol.g), sunCol.b);
		float lSat = (lMax > 0.001) ? (lMax - lMin) / lMax : 0.0;
		float lLum = dot(sunCol, vec3(0.2126, 0.7152, 0.0722));
		float wbStrength = smoothstep(0.45, 0.88, lSat) * 0.38;
		sunCol = mix(sunCol, vec3(max(lLum, 0.26)), wbStrength);

		vec3 cloudBase = mix(vec3(0.95, 0.97, 1.0), cloudTint.rgb, mix(0.22, 0.14, isUpperLayer));
		cloudBase = mix(cloudBase, cloudBase * underTint, underCloud);
		vec3 sunsetCol = vec3(1.0, 0.54, 0.26) * max(max(sunCol.r, sunCol.g), sunCol.b);

		// Self-shadowing thickness contrast (brighter cloud tops, shaded slate-grey undersides when below cloud deck)
		float topRelief = 0.78 + 0.28 * localRelief;
		float litWeight = mix(topRelief, topRelief * 0.38 + underBase * 0.70, underCloud);
		litColor += cloudBase * sunCol * dayLit * litWeight;
		litColor += sunsetCol * twilight * 0.52;
		litColor += sunCol * forwardScatter * mix(0.45, 0.65, isUpperLayer);
	}
#else
	litColor = cloudTint.rgb * 0.5;
	maxDayLit = 0.5;
#endif

	// Soft horizon fade when viewed near grazing edge from orbit or surface
	float ndotv = abs(dot(N, V));
	float horizonMin = mix(0.04, 0.012, underCloud);
	float horizonMax = mix(0.22, 0.11, underCloud);
	float horizonFade = smoothstep(horizonMin, horizonMax, ndotv);

	litColor = mix(litColor, litColor * vec3(0.50, 0.56, 0.65), stormIntensity * density * mix(0.68, 0.32, isUpperLayer));
	litColor = mix(litColor, litColor * vec3(1.12, 0.90, 0.68), dustFactor * density * 0.45);
	float horizonHaze = (1.0 - smoothstep(0.04, 0.20, ndotv)) * underCloud * 0.45;
	litColor = mix(litColor, cloudTint.rgb * maxDayLit, horizonHaze);

	// Localized storm-cell lightning glow inside thick clouds (instead of flashing the entire sky)
	float strikeIntensity = clamp(flashCell.w, 0.0, 1.0);
	if (strikeIntensity > 0.005) {
		float strikeDistKm = length(dir - normalize(flashCell.xyz)) * planetRadKm;
		float cellFalloff = exp(-strikeDistKm / mix(16.0, 26.0, stormIntensity));
		float thickMask = smoothstep(0.40, 0.85, density) * (1.0 - 0.55 * isUpperLayer);
		litColor += vec3(0.68, 0.82, 1.0) * strikeIntensity * cellFalloff * thickMask * 1.15;
	}

	float layerOpacity = clamp(layerParams.w, 0.05, 1.0);
	float alpha = clamp(density * cloudTint.a * layerOpacity * shellPassFade * horizonFade, 0.0, 0.95);
	frag_color = vec4(clamp(litColor, 0.0, 1.0), alpha);
}

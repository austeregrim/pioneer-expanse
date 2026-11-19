// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"
#include "basesphere_uniforms.glsl"

in vec3 varyingEyepos;
in vec3 varyingNormal;
in vec3 varyingTexCoord0;

uniform samplerCube texture0; //diffuse

uniform int NumShadows;
uniform float enhancedGraphics;
uniform float uTime;

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

float ggFbm3D(vec3 p)
{
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; ++i) {
		sum += amp * ggNoise3D(p);
		p = p * 2.07 + vec3(11.3, 7.1, 5.9);
		amp *= 0.5;
	}
	return sum;
}

vec3 ggRotateY(vec3 v, float ang)
{
	float c = cos(ang);
	float s = sin(ang);
	return vec3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
}

// Applies a bold, rotating anticyclonic storm vortex (Great Red Spot / Oval BA style)
vec3 applyVortexStorm(vec3 dir, vec3 stormCenter, float stormRadius, float swirlAmount, float spinTime,
	out float stormRim, out float stormCore, out float spiralBands)
{
	vec3 sc = normalize(stormCenter);
	vec3 diff = dir - sc;
	float d = length(diff);
	if (d > stormRadius * 2.6) {
		stormRim = 0.0;
		stormCore = 0.0;
		spiralBands = 0.0;
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

	// Differential vortex rotation (faster near core, tapering smoothly outward)
	float env = exp(-r * r * 1.45);
	float ang = swirlAmount * env + spinTime * env * 0.45;
	float c = cos(ang);
	float s = sin(ang);
	vec2 rotUV = vec2(u * c - v * s, u * s + v * c);

	// Spiral cloud arms inside the storm
	float theta = atan(v, u);
	float arms = 0.5 + 0.5 * sin(theta * 2.0 + r * 9.5 - spinTime * 0.75);
	spiralBands = arms * smoothstep(1.35, 0.15, r) * smoothstep(0.05, 0.35, r);

	// Raised bright eyewall collar & recessed inner storm core
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

	// Enhanced Graphics: Planetary-scale fluid-advected cloud bands, Kelvin-Helmholtz eddies, rotating cyclone storms & polar vortices
	vec3 dir = normalize(varyingTexCoord0);
	float lat = clamp(dir.y, -1.0, 1.0);
	float absLat = abs(lat);
	float t = uTime * 0.0025;

	// 1. Alternating East/West zonal jet streams with shear zones between bands
	float jetBands = sin(lat * 17.0) * 0.55 + cos(lat * 8.5 + 0.6) * 0.28;
	float shearZone = abs(cos(lat * 17.0)); // strongest eddy curling right along jet boundaries
	vec3 advected = ggRotateY(dir, t * jetBands * 0.24);

	// 2. Polar angular wind currents & swirling polar cyclone ring near both poles
	float polarWeight = smoothstep(0.60, 0.94, absLat);
	float polarSwirlPattern = 0.0;
	if (polarWeight > 0.001) {
		float polarLon = atan(dir.z, dir.x);
		float hexJet = sin(polarLon * 6.0 + sign(lat) * t * 1.1) * 0.045;
		float polarAngle = sign(lat) * (t * 0.42 + (1.0 - absLat) * 9.5 + hexJet * 10.0);
		vec3 polarDir = ggRotateY(advected, polarAngle * polarWeight);
		advected = normalize(mix(advected, polarDir, polarWeight));
		// Ring of polar cyclones around the pole
		polarSwirlPattern = ggFbm3D(polarDir * 12.0 + vec3(t * 0.4, 0.0, -t * 0.4)) * polarWeight;
	}

	// 3. Bold, rotating anticyclonic vortex storms (4 distinct latitudes/longitudes)
	float rim1, core1, arm1;
	float rim2, core2, arm2;
	float rim3, core3, arm3;
	float rim4, core4, arm4;
	vec3 stormDir = applyVortexStorm(advected, ggRotateY(vec3(0.86, -0.34, 0.38), t * 0.08), 0.17, 5.2, t * 1.2, rim1, core1, arm1);
	stormDir = applyVortexStorm(stormDir, ggRotateY(vec3(-0.66, 0.42, -0.62), -t * 0.10), 0.13, -4.6, -t * 1.4, rim2, core2, arm2);
	stormDir = applyVortexStorm(stormDir, ggRotateY(vec3(-0.22, -0.58, 0.78), t * 0.12), 0.105, 4.2, t * 1.6, rim3, core3, arm3);
	stormDir = applyVortexStorm(stormDir, ggRotateY(vec3(0.32, 0.22, -0.92), -t * 0.09), 0.115, -4.4, -t * 1.3, rim4, core4, arm4);

	float totalRim = clamp(rim1 + rim2 + rim3 + rim4, 0.0, 1.0);
	float totalCore = clamp(core1 + core2 + core3 + core4, 0.0, 1.0);
	float totalArms = clamp(arm1 + arm2 + arm3 + arm4, 0.0, 1.0);

	// 4. Two-stage domain-warped fluid turbulence (strong latitude+longitude curling = real Kelvin-Helmholtz eddies & festoons!)
	vec3 flowCoord = stormDir * vec3(4.5, 11.5, 4.5) + vec3(t * 0.45, 0.0, -t * 0.35);
	vec3 warp1 = vec3(
		ggFbm3D(flowCoord + vec3(0.0, 1.3, 2.7)) - 0.5,
		ggFbm3D(flowCoord + vec3(5.2, -2.1, 1.4)) - 0.5,
		ggFbm3D(flowCoord + vec3(-3.4, 4.8, -1.9)) - 0.5
	);
	vec3 eddyCoord = stormDir * vec3(10.5, 22.0, 10.5) + warp1 * 3.2 + vec3(-t * 0.65, 0.0, t * 0.55);
	float eddyField = ggFbm3D(eddyCoord);
	float fineFilaments = ggFbm3D(stormDir * 28.0 + warp1 * 4.5 + vec3(t * 0.8, eddyField * 2.0, -t * 0.6));

	// Displace latitude (y) strongly along jet shear boundaries so bands curl into real swirling plumes & eddies
	float latWarp = (warp1.y * 0.11 + (eddyField - 0.5) * 0.075) * (0.45 + 0.85 * shearZone);
	float lonWarp = warp1.x * 0.14 + (fineFilaments - 0.5) * 0.05;
	vec3 sampleDirUpper = normalize(ggRotateY(stormDir, lonWarp) + vec3(0.0, latWarp, 0.0));
	vec3 sampleDirLower = normalize(ggRotateY(stormDir, lonWarp * 0.5) + vec3(0.0, latWarp * 0.4 - 0.045, 0.0));

	vec4 texUpper = texture(texture0, sampleDirUpper);
	vec4 texLower = texture(texture0, sampleDirLower);

	// Blend upper bright ammonia cloud tops with deeper darker troposphere belts
	float deckMix = smoothstep(0.28, 0.76, eddyField * 0.65 + fineFilaments * 0.35);
	vec3 cloudCol = mix(texLower.rgb * 0.82, texUpper.rgb * 1.16, deckMix);

	// Crisp cloud festoons & billowing convective ridges
	float ridge = 1.0 - abs(fineFilaments * 2.0 - 1.0);
	ridge = pow(clamp(ridge, 0.0, 1.0), 2.2);
	cloudCol *= (0.86 + 0.26 * ridge);

	// Sculpt the rotating cyclone storms with distinct warm/bright swirling collars and deep storm cores
	vec3 stormHighlight = mix(cloudCol * 1.32, vec3(0.96, 0.86, 0.72), 0.28);
	vec3 stormCenterCol = mix(cloudCol * 0.72, vec3(0.78, 0.42, 0.28), 0.32);
	cloudCol = mix(cloudCol, stormHighlight, clamp(totalRim * 0.65 + totalArms * 0.45, 0.0, 0.85));
	cloudCol = mix(cloudCol, stormCenterCol, totalCore * 0.55);

	// Polar vortex atmospheric depth & swirling cloud contrast
	cloudCol = mix(cloudCol, cloudCol * (0.78 + 0.48 * polarSwirlPattern) + atmosColor.rgb * 0.12, polarWeight * 0.65);

	// 5. Screen-space micro-bump normal shading so sunlight catches raised billowing cloud tops & storm walls
	float cloudHeight = deckMix * 0.45 + ridge * 0.25 + totalRim * 0.40 - totalCore * 0.25 + polarSwirlPattern * 0.20;
	vec3 dPdx = dFdx(varyingEyepos);
	vec3 dPdy = dFdy(varyingEyepos);
	vec3 bumpGrad = dFdx(cloudHeight) * normalize(dPdx + vec3(1e-6)) + dFdy(cloudHeight) * normalize(dPdy + vec3(1e-6));
	vec3 cloudNorm = normalize(tnorm - bumpGrad * 0.42);

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

	// 6. Sunlit Fresnel atmospheric limb glow (strictly dark on the night side!)
	float NdotV = clamp(dot(tnorm, -eyenorm), 0.0, 1.0);
	float limbFresnel = pow(1.0 - NdotV, 3.2);
	float litLevel = clamp(max(max(diff.r, diff.g), diff.b), 0.0, 1.0);
	vec3 limbTint = mix(atmosColor.rgb, mix(texUpper.rgb, vec3(0.72, 0.86, 1.0), 0.45), 0.5);
	vec3 limbGlow = limbTint * limbFresnel * smoothstep(0.0, 0.22, litLevel) * pow(litLevel, 0.65) * 0.78;

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

// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

in vec3 objPos;
in vec3 viewNormal;
in vec3 eyePos;

// cloudParams: x = coverage [0..1], y = seed offset, z = camera altitude in planet radii, w = cloud shell radius
uniform vec4 cloudParams;
// cloudTint: rgb = atmospheric/cloud color tint, a = opacity scale
uniform vec4 cloudTint;
uniform float uTime;

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

vec3 clRotateY(vec3 v, float ang)
{
	float c = cos(ang);
	float s = sin(ang);
	return vec3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
}

void main(void)
{
	float coverage = clamp(cloudParams.x, 0.0, 1.0);
	if (coverage <= 0.01)
		discard;

	// Smoothly soften clouds right when the camera flies directly through the cloud shell altitude
	float camAlt = cloudParams.z;
	float shellRad = cloudParams.w;
	float altDist = abs(camAlt - shellRad);
	float shellPassFade = smoothstep(0.00015, 0.0012, altDist);
	if (shellPassFade <= 0.01)
		discard;

	vec3 dir = normalize(objPos);
	float seed = cloudParams.y;
	float t = uTime * 0.0045;

	// Gentle trade-wind drift by latitude + planetary seed rotation
	float lat = clamp(dir.y, -1.0, 1.0);
	float tradeWind = (0.65 + 0.35 * cos(lat * 6.28318)) * t;
	vec3 windDir = clRotateY(dir, tradeWind + seed);

	// Domain-warped swirling weather fronts & wispy cumulus/cirrus formations
	vec3 p = windDir * vec3(4.2, 5.4, 4.2) + vec3(seed * 3.1, seed * 1.7, -seed * 2.3);
	vec3 warp = vec3(
		clFbm3D(p * 0.75 + vec3(t * 0.6, 0.0, -t * 0.4)),
		clFbm3D(p * 0.75 + vec3(4.2, t * 0.3, 1.9)),
		clFbm3D(p * 0.75 + vec3(-2.7, 3.1, t * 0.5))
	);

	float fronts = clFbm3D(p + warp * 1.85);
	float wisps = clFbm3D(p * 2.8 - warp * 1.1 + vec3(t * 1.2, 0.0, 0.0));
	float detail = clNoise3D(windDir * 28.0 + warp * 2.2);

	float rawCloud = fronts * 0.64 + wisps * 0.26 + detail * 0.10;

	// Threshold according to planet coverage so breaks clearly reveal oceans and continents
	float lowCut = mix(0.68, 0.36, coverage);
	float highCut = lowCut + 0.26;
	float density = smoothstep(lowCut, highCut, rawCloud);
	if (density <= 0.005)
		discard;

	vec3 N = normalize(viewNormal);
	vec3 V = normalize(-eyePos);

	// Lighting: crisp sunlit white clouds, warm golden twilight terminator, pitch-dark night side
	vec3 litColor = vec3(0.0);
#if (NUM_LIGHTS > 0)
	for (int i = 0; i < NUM_LIGHTS; ++i) {
		vec3 L = normalize(uLight[i].position.xyz);
		float ndotl = dot(N, L);

		// Soft atmospheric wrap across the terminator, dropping strictly to 0 on the night side
		float dayLit = smoothstep(-0.08, 0.22, ndotl) * (0.28 + 0.72 * max(ndotl, 0.0));
		float twilight = exp(-pow((ndotl - 0.02) * 8.5, 2.0)) * smoothstep(-0.12, 0.0, ndotl);

		// Subtle forward-scatter silver lining when looking toward the sun through clouds from the ground
		float forwardScatter = pow(max(dot(-V, L), 0.0), 6.0) * (1.0 - density * 0.6) * smoothstep(-0.10, 0.15, ndotl);

		vec3 sunCol = uLight[i].diffuse.rgb;
		vec3 cloudBase = mix(vec3(0.95, 0.97, 1.0), cloudTint.rgb, 0.22);
		vec3 sunsetCol = vec3(1.0, 0.54, 0.26) * max(max(sunCol.r, sunCol.g), sunCol.b);

		// Self-shadowing thickness contrast (brighter cloud tops, slightly cooler/softer cloud undersides)
		float topRelief = 0.78 + 0.28 * wisps;
		litColor += cloudBase * sunCol * dayLit * topRelief;
		litColor += sunsetCol * twilight * 0.52;
		litColor += sunCol * forwardScatter * 0.45;
	}
#else
	litColor = cloudTint.rgb * 0.5;
#endif

	// Soft horizon fade when viewed near grazing edge from orbit or surface
	float ndotv = abs(dot(N, V));
	float horizonFade = smoothstep(0.04, 0.24, ndotv);

	float alpha = clamp(density * cloudTint.a * shellPassFade * horizonFade, 0.0, 0.92);
	frag_color = vec4(clamp(litColor, 0.0, 1.0), alpha);
}

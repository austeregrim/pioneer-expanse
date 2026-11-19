// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

struct ShipSpotLight {
	vec4 posRange; // xyz = view-space position (meters), w = range (meters)
	vec4 dirInner; // xyz = normalized view-space dir, w = cos(innerHalfAngle)
	vec4 colOuter; // rgb = linear color * intensity, w = cos(outerHalfAngle)
};

layout(std140) uniform SpotLightData {
	ShipSpotLight uSpotLight[4];
	vec4 uSpotMeta; // x = active spotlight count [0..4]
};

vec3 EvalShipSpotLights(vec3 fragPosM, vec3 N, vec3 V, vec3 albedoLinear, float roughness, float waterMask)
{
	int count = int(uSpotMeta.x + 0.5);
	if (count <= 0)
		return vec3(0.0);

	vec3 accum = vec3(0.0);
	for (int i = 0; i < 4; ++i) {
		if (i >= count)
			break;
		float range = uSpotLight[i].posRange.w;
		if (range <= 0.001)
			continue;

		vec3 toLight = uSpotLight[i].posRange.xyz - fragPosM;
		float d = length(toLight);
		if (d >= range)
			continue;

		vec3 L = toLight / max(d, 0.001);
		float spotCos = dot(-L, normalize(uSpotLight[i].dirInner.xyz));
		float cone = smoothstep(uSpotLight[i].colOuter.w, uSpotLight[i].dirInner.w, spotCos);
		if (cone <= 0.001)
			continue;

		float normD = clamp(d / range, 0.0, 1.0);
		float edgeFade = 1.0 - normD * normD;
		float halfDist = range * 0.34;
		float atten = (edgeFade * edgeFade) / (1.0 + (d * d) / (halfDist * halfDist));

		float NdotL = max(dot(N, L), 0.0);
		// Rough micro-facets on rocky/soil terrain scatter grazing searchlights back toward the viewer
		float roughScatter = (NdotL > 0.0) ? mix(NdotL, pow(NdotL, 0.42), (1.0 - waterMask) * clamp(roughness, 0.2, 1.0) * 0.72) : 0.0;
		vec3 H = normalize(L + V);
		float shininess = mix(160.0, 14.0, roughness);
		float spec = pow(max(dot(N, H), 0.0), shininess) * mix(0.24, 1.55, clamp(waterMask + (1.0 - roughness) * 0.45, 0.0, 1.2));

		accum += uSpotLight[i].colOuter.rgb * cone * atten * (albedoLinear * roughScatter + vec3(spec) * NdotL);
	}
	return accum;
}

// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"
#include "spotlights.glsl"

#ifdef TEXTURE0
uniform sampler2D texture0; // diffuse
uniform sampler2D texture6; // normal
in vec2 texCoord0;
#endif

#ifdef VERTEXCOLOR
in vec4 vertexColor;
#endif
in vec4 instDiffuse;
in vec4 instEmissive;

#if (NUM_LIGHTS > 0)
in vec3 eyePos;
in vec3 normal;
#ifdef MAP_NORMAL
	in vec3 tangent;
	in vec3 bitangent;
#endif
#endif

uniform vec4 lightIntensity;
uniform vec4 rockLightScale;
uniform float enhancedGraphics;

out vec4 frag_color;

const float PBR_PI = 3.14159265359;

float DistributionGGX(vec3 N, vec3 H, float roughness)
{
	float a = roughness * roughness;
	float a2 = a * a;
	float NdotH = max(dot(N, H), 0.0);
	float NdotH2 = NdotH * NdotH;
	float denom = (NdotH2 * (a2 - 1.0) + 1.0);
	return a2 / max(PBR_PI * denom * denom, 0.0001);
}

float GeometrySchlickGGX(float NdotV, float roughness)
{
	float r = roughness + 1.0;
	float k = (r * r) / 8.0;
	return NdotV / max(NdotV * (1.0 - k) + k, 0.0001);
}

float GeometrySmith(float NdotV, float NdotL, float roughness)
{
	return GeometrySchlickGGX(NdotV, roughness) * GeometrySchlickGGX(NdotL, roughness);
}

vec3 FresnelSchlick(float cosTheta, vec3 F0)
{
	float t = clamp(1.0 - cosTheta, 0.0, 1.0);
	float t2 = t * t;
	return F0 + (1.0 - F0) * (t2 * t2 * t);
}

vec3 FresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness)
{
	float t = clamp(1.0 - cosTheta, 0.0, 1.0);
	float t2 = t * t;
	return F0 + (max(vec3(1.0 - roughness), F0) - F0) * (t2 * t2 * t);
}

vec3 ACESFilm(vec3 x)
{
	return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

vec3 SampleSpaceEnvironment(vec3 worldDir, vec3 viewDir, vec3 primaryLightDir, vec3 primaryLightCol, float primaryIntensity, vec3 ambientLinear, float roughness)
{
	float band = exp(-abs(worldDir.y) * 4.5);
	float neb = 0.5 + 0.5 * sin(worldDir.x * 3.2 + worldDir.z * 2.4) * cos(worldDir.y * 2.7 - worldDir.x * 1.9);
	vec3 deepSpace = vec3(0.018, 0.024, 0.042);
	vec3 galacticBand = mix(vec3(0.06, 0.09, 0.16), vec3(0.14, 0.11, 0.18), neb) * band;
	vec3 hemiBounce = ambientLinear * (0.65 + 0.35 * clamp(worldDir.y * 0.5 + 0.5, 0.0, 1.0));

	float starAlign = max(dot(viewDir, primaryLightDir), 0.0);
	float starExp = mix(42.0, 3.5, roughness);
	vec3 starReflect = primaryLightCol * primaryIntensity * pow(starAlign, starExp) * mix(0.95, 0.18, roughness);

	return deepSpace + galacticBand + hemiBounce + starReflect;
}

void main(void)
{
	Surface surface = Surface(vec4(1.0), vec3(1.0), 100.0, vec3(0, 0, 1), vec3(0), 1.0);

#ifdef VERTEXCOLOR
	surface.color = vertexColor * instDiffuse * material.diffuse;
#else
	surface.color = instDiffuse * material.diffuse;
#endif
#ifdef TEXTURE0
	surface.color *= texture(texture0, texCoord0);
#endif

	surface.specular = material.specular.xyz;
	surface.shininess = material.shininess;

#if (NUM_LIGHTS > 0)
#ifdef MAP_NORMAL
	vec3 bump = (texture(texture6, texCoord0).xyz * 2.0) - vec3(1.0);
	mat3 tangentFrame = mat3(tangent, bitangent, normal);
	surface.normal = tangentFrame * bump;
#else
	surface.normal = normal;
#endif
#else
	surface.normal = vec3(0, 0, 1);
#endif
	surface.normal = normalize(surface.normal);
	surface.ambientOcclusion = 1.0;
	surface.emissive = instEmissive.rgb;

#if (NUM_LIGHTS > 0)
	float sunVis = clamp(instEmissive.a, 0.0, 1.0);
	float intensity[4] = float[](
		lightIntensity.x * rockLightScale.x * sunVis,
		lightIntensity.y * rockLightScale.y,
		lightIntensity.z * rockLightScale.z,
		lightIntensity.w * rockLightScale.w
	);

	vec3 final_color;

	if (enhancedGraphics >= 0.5) {
		vec3 albedo = toLinear(clamp(surface.color.rgb, 0.0, 1.0));
		vec3 specLinear = toLinear(clamp(surface.specular, 0.0, 1.0));
		vec3 ambientLinear = toLinear(clamp(scene.ambient.xyz, 0.0, 1.0));
		float specLum = dot(surface.specular, vec3(0.2126, 0.7152, 0.0722));

		float shininessNorm = clamp(log2(max(surface.shininess, 2.0)) / 7.5, 0.0, 1.0);
		float metallic = smoothstep(0.26, 0.78, specLum) * 0.78;
		float baseRoughness = clamp(1.0 - mix(shininessNorm * 0.58, clamp(specLum * 1.05, 0.0, 1.0), 0.55), 0.16, 0.86);

		vec3 N = surface.normal;
		vec3 V = normalize(-eyePos);
		mat3 invViewRot = mat3(uViewMatrixInverse);
		vec3 worldN = normalize(invViewRot * N);
		float microGrain = fract(sin(dot(floor(worldN * 48.0), vec3(12.9898, 78.233, 37.719))) * 43758.5453);
		float roughness = clamp(baseRoughness + (microGrain - 0.5) * 0.05 * (0.35 + metallic), 0.14, 0.90);

		float NdotV = max(dot(N, V), 0.001);
		vec3 F0 = mix(vec3(0.045), mix(albedo, specLinear, 0.45), metallic);
		vec3 Lo = vec3(0.0);

		for (int i = 0; i < NUM_LIGHTS; ++i) {
			vec3 L = normalize(uLight[i].position.xyz);
			vec3 H = normalize(V + L);
			float NdotL = max(dot(N, L), 0.0);
			if (NdotL <= 0.0 || intensity[i] <= 0.0)
				continue;

			vec3 lightDiff = toLinear(clamp(uLight[i].diffuse.rgb, 0.0, 1.0));
			vec3 lightSpec = toLinear(clamp(uLight[i].specular.rgb, 0.0, 1.0));
			vec3 radiance = lightDiff * intensity[i] * 2.55;

			float NDF = DistributionGGX(N, H, roughness);
			float G = GeometrySmith(NdotV, NdotL, roughness);
			vec3 F = FresnelSchlick(max(dot(H, V), 0.0), F0);

			vec3 specBRDF = (NDF * G * F) / max(4.0 * NdotV * NdotL, 0.001);
			vec3 kD = (vec3(1.0) - F) * (1.0 - metallic * 0.85);

			Lo += (kD * albedo / PBR_PI) * radiance * NdotL;
			Lo += specBRDF * lightSpec * intensity[i] * 2.35 * NdotL;
		}

		vec3 R = reflect(-V, N);
		vec3 worldR = normalize(invViewRot * R);

		vec3 primaryL = normalize(uLight[0].position.xyz);
		vec3 primaryCol = toLinear(clamp(uLight[0].specular.rgb, 0.0, 1.0));
		vec3 envColor = SampleSpaceEnvironment(worldR, R, primaryL, primaryCol, intensity[0], ambientLinear, roughness);

		vec3 F_ibl = FresnelSchlickRoughness(NdotV, F0, roughness);
		vec3 kD_ibl = (vec3(1.0) - F_ibl) * (1.0 - metallic * 0.75);

		vec3 iblDiffuse = kD_ibl * albedo * (ambientLinear * 1.45 + vec3(0.018, 0.022, 0.032));
		vec3 iblSpecular = envColor * F_ibl * mix(1.25, 0.28, roughness);
		vec3 ambientTerm = (iblDiffuse + iblSpecular) * surface.ambientOcclusion;

		Lo += EvalShipSpotLights(eyePos, N, V, albedo, roughness, 0.0);

		vec3 litSRGB = toSRGB(ACESFilm(ambientTerm + Lo));
		final_color = clamp(litSRGB + surface.emissive * 0.85, 0.0, 1.0);
	} else {
		vec3 diffuse = scene.ambient.xyz * surface.color.xyz;
		vec3 specular = vec3(0.0);

		for (int i = 0; i < NUM_LIGHTS; ++i) {
			BlinnPhongDirectionalLight(uLight[i], intensity[i], surface, eyePos, diffuse, specular);
		}

		vec3 spotClassic = EvalShipSpotLights(eyePos, surface.normal, normalize(-eyePos), surface.color.rgb, 0.5, 0.0);
		final_color = diffuse * surface.ambientOcclusion + surface.emissive + specular + (1.0 - exp(-spotClassic * 0.85));
	}

	frag_color = vec4(final_color, surface.color.w);
#else
	frag_color = surface.color;
#endif
}

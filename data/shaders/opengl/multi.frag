// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"
#include "sgaussian.glsl"
#include "spotlights.glsl"

#ifdef TEXTURE0
uniform sampler2D texture0; //diffuse
uniform sampler2D texture1; //specular
uniform sampler2D texture2; //glow
uniform sampler2D texture3; //ambient
uniform sampler2D texture4; //pattern
uniform sampler2D texture5; //color
uniform sampler2D texture6; //normal
in vec2 texCoord0;
#endif

#ifdef VERTEXCOLOR
in vec4 vertexColor;
#endif
#if (NUM_LIGHTS > 0)
in vec3 eyePos;
in vec3 normal;
#ifdef MAP_NORMAL
	in vec3 tangent;
	in vec3 bitangent;
#endif
#ifdef HEAT_COLOURING
	uniform sampler2D heatGradient;
#endif // HEAT_COLOURING
#endif // (NUM_LIGHTS > 0)

// Use raw OpenGL uniforms here similar to push constants,
// as a payload for small per-draw data that would otherwise
// have to go in a separate UBO
uniform vec4 lightIntensity;
uniform vec4 heatingNormal;
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
	return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

vec3 FresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness)
{
	return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

vec3 ACESFilm(vec3 x)
{
	return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

vec3 SampleSpaceEnvironment(vec3 worldDir, vec3 viewDir, vec3 primaryLightDir, vec3 primaryLightCol, float primaryIntensity, vec3 ambientLinear, float roughness)
{
	// Subtle deep-space sky + galactic plane band for metallic hull reflections
	float band = exp(-abs(worldDir.y) * 4.5);
	float neb = 0.5 + 0.5 * sin(worldDir.x * 3.2 + worldDir.z * 2.4) * cos(worldDir.y * 2.7 - worldDir.x * 1.9);
	vec3 deepSpace = vec3(0.018, 0.024, 0.042);
	vec3 galacticBand = mix(vec3(0.06, 0.09, 0.16), vec3(0.14, 0.11, 0.18), neb) * band;
	vec3 hemiBounce = ambientLinear * (0.65 + 0.35 * clamp(worldDir.y * 0.5 + 0.5, 0.0, 1.0));

	// Reflected broad coronal/star sheen across polished metallic panels
	float starAlign = max(dot(viewDir, primaryLightDir), 0.0);
	float starExp = mix(42.0, 3.5, roughness);
	vec3 starReflect = primaryLightCol * primaryIntensity * pow(starAlign, starExp) * mix(0.95, 0.18, roughness);

	return deepSpace + galacticBand + hemiBounce + starReflect;
}

void getSurface(inout Surface surf)
{
#ifdef VERTEXCOLOR
	surf.color = vertexColor;
#else
	surf.color = material.diffuse;
#endif
#ifdef TEXTURE0
	surf.color *= texture(texture0, texCoord0);
#endif

	//patterns - simple lookup
#ifdef MAP_COLOR
	vec4 pat = texture(texture4, texCoord0);
	vec4 mapColor = texture(texture5, vec2(pat.r, 0.0));
	vec4 tint = mix(vec4(1.0),mapColor,pat.a);
	surf.color *= tint;
#endif

	surf.specular = material.specular.xyz;
#ifdef MAP_SPECULAR
	surf.specular *= texture(texture1, texCoord0).xyz;
#endif
	surf.shininess = material.shininess;

#if (NUM_LIGHTS > 0)
//directional lighting
#ifdef MAP_NORMAL
	vec3 bump = (texture(texture6, texCoord0).xyz * 2.0) - vec3(1.0);
	mat3 tangentFrame = mat3(tangent, bitangent, normal);
	surf.normal = tangentFrame * bump;
#else
	surf.normal = normal;
#endif
#else
	// pointing directly at the viewer
	surf.normal = vec3(0, 0, 1);
#endif
	surf.normal = normalize(surf.normal);

	// this is crude "baked ambient occulsion" - basically multiply everything by the ambient texture
	// scaling whatever we've decided the lighting contribution is by 0.0 to 1.0 to account for sheltered/hidden surfaces
#ifdef MAP_AMBIENT
	surf.ambientOcclusion = texture(texture3, texCoord0).r;
#else
	surf.ambientOcclusion = 1.0;
#endif

	//emissive only make sense with lighting
#ifdef MAP_EMISSIVE
	// HACK emissive maps are authored weirdly, mostly under the assumption that they will be multiplied by diffuse
	// We mix a litle towards white to make the emissives pop more
	surf.emissive = mix(surf.color.xyz, vec3(1.0), 0.4) * texture(texture2, texCoord0).xyz; //glow map
#else
	surf.emissive = material.emission.xyz; //just emissive parameter
#endif
}

void main(void)
{
	// initialize here to prevent warnings about possibly-unused variables
	Surface surface = Surface(vec4(1.0), vec3(1.0), 100.0, vec3(0, 0, 1), vec3(0), 1.0);
	getSurface(surface);

#ifdef ALPHA_TEST
	if (surface.color.a < 0.5)
		discard;
#endif

//directional lighting
#if (NUM_LIGHTS > 0)
	float intensity[4] = float[](
		lightIntensity.x,
		lightIntensity.y,
		lightIntensity.z,
		lightIntensity.w
	);

	vec3 final_color;

	if (enhancedGraphics >= 0.5) {
		// Enhanced Graphics: Cook-Torrance GGX PBR + Space Environment IBL + Luminous Emissives
		vec3 albedo = toLinear(clamp(surface.color.rgb, 0.0, 1.0));
		vec3 specLinear = toLinear(clamp(surface.specular, 0.0, 1.0));
		vec3 ambientLinear = toLinear(clamp(scene.ambient.xyz, 0.0, 1.0));
		float specLum = dot(surface.specular, vec3(0.2126, 0.7152, 0.0722));

		// Selective metallic & roughness mapping so matte/painted station hulls stay clean and readable,
		// while high-specular metal panels, struts, and cockpit trims show crisp metallic sheen
		float shininessNorm = clamp(log2(max(surface.shininess, 2.0)) / 7.5, 0.0, 1.0);
		float metallic = smoothstep(0.26, 0.78, specLum) * 0.78;
		float baseRoughness = clamp(1.0 - mix(shininessNorm * 0.58, clamp(specLum * 1.05, 0.0, 1.0), 0.55), 0.16, 0.86);

		// Subtle procedural micro-brushed roughness variation across large station/ship plates
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

		// World-locked analytical space environment reflection
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

		// Tone-map lit hull cleanly, then layer vivid incandescent station/ship emissive lights on top
		vec3 litSRGB = toSRGB(ACESFilm(ambientTerm + Lo));
		float emLum = dot(surface.emissive, vec3(0.2126, 0.7152, 0.0722));
		if (emLum > 0.015) {
			vec3 baseEmDir = surface.emissive / emLum;
			// Detect yellow exterior station windows on normalized hue so even dim glow-map pixels are caught
			float yellowWindow = smoothstep(0.20, 0.55, baseEmDir.r - baseEmDir.b) *
				smoothstep(0.15, 0.50, baseEmDir.g - baseEmDir.b);
			vec3 pureWhite = vec3(1.0, 0.99, 0.97);
			vec3 targetTint = mix(mix(baseEmDir, pureWhite, 0.55), pureWhite, yellowWindow * 0.96);
			float emStrength = clamp(emLum * mix(2.2, 3.1, yellowWindow), 0.0, 0.92);
			// Override yellow diffuse under windows with smooth tonal headroom so window panes don't clip
			vec3 windowLit = mix(litSRGB, targetTint * (0.42 + 0.48 * emStrength), emStrength * (0.45 + 0.55 * yellowWindow));
			final_color = clamp(windowLit + targetTint * (emLum * 0.72), 0.0, 0.96);
		} else {
			final_color = litSRGB;
		}
	} else {
		// Classic Pioneer Fallback: Exact original Blinn-Phong lighting
		vec3 diffuse = scene.ambient.xyz * surface.color.xyz;
		vec3 specular = vec3(0.0);

		for (int i=0; i<NUM_LIGHTS; ++i) {
			BlinnPhongDirectionalLight(uLight[i], intensity[i], surface, eyePos, diffuse, specular);
		}

		vec3 spotClassic = EvalShipSpotLights(eyePos, surface.normal, normalize(-eyePos), surface.color.rgb, 0.5, 0.0);
		final_color = diffuse * surface.ambientOcclusion + surface.emissive + specular + (1.0 - exp(-spotClassic * 0.85));
	}

	frag_color = vec4(final_color, surface.color.w);

#ifdef HEAT_COLOURING
	if (heatingNormal.a > 0.0)
	{
		float dphNn = clamp(dot(heatingNormal.xyz, surface.normal), 0.0, 1.0);
		float heatDot = heatingNormal.a * (dphNn * dphNn * dphNn);
		vec4 heatColour = texture(heatGradient, vec2(heatDot, 0.5)); //heat gradient blend
		frag_color.rgb = frag_color.rgb + heatColour.rgb; // override surface color based on heat color
	}
#endif // HEAT_COLOURING

#else
	frag_color = surface.color;
#endif
}

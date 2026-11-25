// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

uniform samplerCube texture0;

in vec3 v_texCoord;

out vec4 frag_color;

float skyHash31(vec3 p)
{
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float skyNoise3D(vec3 p)
{
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float n000 = skyHash31(i + vec3(0.0, 0.0, 0.0));
	float n100 = skyHash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = skyHash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = skyHash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = skyHash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = skyHash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = skyHash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = skyHash31(i + vec3(1.0, 1.0, 1.0));

	float nx00 = mix(n000, n100, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx11 = mix(n011, n111, f.x);

	return mix(mix(nx00, nx10, f.y), mix(nx01, nx11, f.y), f.z);
}

float skyFbm3D(vec3 p)
{
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; ++i) {
		sum += amp * skyNoise3D(p);
		p = p * 2.08 + vec3(7.1, 13.3, 5.7);
		amp *= 0.5;
	}
	return sum * (1.0 / 0.9375);
}

void main( void )
{
	vec3 dir = normalize(v_texCoord);
	vec3 planeNormal = normalize(vec3(0.052, 0.999, 0.0));
	float lat = abs(dot(dir, planeNormal));

	float bandTight = exp(-lat * 9.0);
	float bandWide = exp(-lat * 2.8);

	vec3 coreDir = normalize(vec3(0.985, 0.0, 0.161));
	vec3 eqDir = normalize(vec3(dir.x, 0.0, dir.z) + vec3(1e-5, 0.0, 0.0));
	float coreAlign = pow(max(dot(eqDir, coreDir) * 0.5 + 0.5, 0.0), 3.0);
	float coreBulge = exp(-lat * 4.8) * coreAlign;

	float rift = smoothstep(0.42, 0.72, skyFbm3D(dir * 5.5 + vec3(1.7, 0.0, -2.3))) * exp(-lat * 11.0);

	float nebWarm = smoothstep(0.56, 0.84, skyFbm3D(dir * 3.8 + vec3(4.1, 1.3, -2.7))) * exp(-lat * 5.2);
	float nebCool = smoothstep(0.58, 0.85, skyFbm3D(dir * 4.6 + vec3(-3.2, 2.4, 5.1))) * exp(-lat * 4.2);

	vec3 baseCol = texture(texture0, v_texCoord).xyz * (0.24 + 0.76 * bandWide);
	vec3 discGlow = vec3(0.055, 0.048, 0.052) * bandTight + vec3(0.11, 0.082, 0.048) * coreBulge;
	vec3 nebGlow = vec3(0.14, 0.055, 0.05) * nebWarm + vec3(0.04, 0.075, 0.13) * nebCool;

	vec3 sky = (baseCol + (discGlow + nebGlow) * (1.0 - rift * 0.72));
	frag_color = vec4(sky * material.emission.xyz * vec3(0.85), 1.0);
}

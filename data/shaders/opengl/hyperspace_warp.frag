// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

in vec2 screenUV;

uniform sampler2D texture0;
// exposureParams: x = prog [0..1], y = dopplerShift [-1..1] (+blueshift entry, -redshift exit), z = exposureGain, w = whiteout [0..1]
uniform vec4 exposureParams;

out vec4 frag_color;

void main(void)
{
	vec3 col = texture(texture0, screenUV).rgb;

	float prog = clamp(exposureParams.x, 0.0, 1.0);
	float doppler = clamp(exposureParams.y, -1.0, 1.0);
	float exposure = max(exposureParams.z, 1.0);
	float whiteout = clamp(exposureParams.w, 0.0, 1.0);

	float bgGather = pow(smoothstep(0.18, 0.96, prog), 2.0);
	vec3 bgTint;
	vec3 spillWeights;

	if (doppler >= 0.0) {
		// Entry surge: crisp relativistic blueshift into oncoming starlight (red -> green/cyan -> blue/violet)
		float bShift = doppler;
		vec3 shifted = vec3(
			col.r * (1.0 - 0.65 * bShift),
			col.g * (1.0 - 0.12 * bShift) + col.r * (0.38 * bShift),
			col.b * (1.0 + 0.60 * bShift) + col.g * (0.48 * bShift) + col.r * (0.20 * bShift)
		);
		col = mix(col, shifted, bShift);
		bgTint = mix(vec3(0.28, 0.58, 1.0), vec3(0.96, 0.98, 1.0), smoothstep(0.55, 0.96, prog));
		spillWeights = vec3(0.85, 0.72, 0.50);
	} else {
		// Destination arrival exit: crisp relativistic redshift as wide-angle decompression settles
		float rShift = -doppler;
		vec3 shifted = vec3(
			col.r * (1.0 + 0.55 * rShift) + col.g * (0.48 * rShift) + col.b * (0.18 * rShift),
			col.g * (1.0 - 0.22 * rShift) + col.b * (0.38 * rShift) + col.r * (0.06 * rShift),
			col.b * (1.0 - 0.72 * rShift)
		);
		col = mix(col, shifted, rShift);
		bgTint = mix(vec3(1.0, 0.46, 0.22), vec3(1.0, 0.98, 0.96), smoothstep(0.55, 0.96, prog));
		spillWeights = vec3(0.50, 0.65, 0.85);
	}

	// Background sky radiance gather + photographic exposure increase (no blur)
	vec3 exposed = col * exposure + bgTint * (bgGather * 1.35);

	// Smooth sensor full-well cross-channel saturation before whiteout
	float lum = dot(exposed, vec3(0.35, 0.45, 0.20));
	float spill = max(0.0, lum - 0.65);
	exposed += spillWeights * (spill * smoothstep(0.35, 0.95, prog));

	// Smooth filmic shoulder + final pure-white handoff
	vec3 mapped = 1.0 - exp(-exposed * (1.15 + 1.45 * prog));
	frag_color = vec4(clamp(mix(mapped, vec3(1.0), whiteout * whiteout), 0.0, 1.0), 1.0);
}

// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "attributes.glsl"
#include "lib.glsl"

uniform float enhancedGraphics;

out vec2 uv;

void main(void)
{
	gl_Position = matrixTransform();
	if (enhancedGraphics >= 0.5) {
		// Scale point size proportionally with camera zoom (projection Y-scale = 1/tan(fovY/2))
		// so station/ship lights grow and shrink 1:1 with their 3D lamp fixtures when zooming in/out
		mat4 proj = uViewProjectionMatrix * uViewMatrixInverse;
		float zoomScale = clamp(abs(proj[1][1]) / 1.57, 0.75, 4.0);
		gl_PointSize = a_normal.z * 1.42 * zoomScale;
	} else {
		gl_PointSize = a_normal.z;
	}
	uv = a_normal.xy;
}

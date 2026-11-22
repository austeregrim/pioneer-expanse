// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef _ORBITALDOCKINGGEOMETRY_H
#define _ORBITALDOCKINGGEOMETRY_H

#include "vector3.h"

/**
 * Compute a deterministic 2-stage detour in station-local coordinates if the
 * straight path from p0Local to p1Local intersects an orbital station's disc/ring
 * envelope, while leaving front approaches and open airlock cones unobstructed.
 */
bool ComputeOrbitalStationDetourLocal(
	const vector3d &p0Local,
	const vector3d &p1Local,
	const vector3d &portPos,
	const vector3d &corridorDir,
	const vector3d &fallbackRadialDir,
	double stationClipRadius,
	vector3d &outDetourLocal);

#endif /* _ORBITALDOCKINGGEOMETRY_H */

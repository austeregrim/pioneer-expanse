// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "OrbitalDockingGeometry.h"
#include "MathUtil.h"

#include <algorithm>
#include <cmath>
#include <utility>

bool ComputeOrbitalStationDetourLocal(
	const vector3d &p0Local,
	const vector3d &p1Local,
	const vector3d &portPos,
	const vector3d &corridorDir,
	const vector3d &fallbackRadialDir,
	double stationClipRadius,
	vector3d &outDetourLocal)
{
	const vector3d cDir = corridorDir.NormalizedSafe();
	if (cDir.LengthSqr() < 0.1)
		return false;

	const vector3d d0 = p0Local - portPos;
	const vector3d d1 = p1Local - portPos;
	const double z0 = d0.Dot(cDir);
	const double z1 = d1.Dot(cDir);
	const vector3d rVec0 = d0 - cDir * z0;
	const vector3d rVec1 = d1 - cDir * z1;
	const double r0 = rVec0.Length();
	const double r1 = rVec1.Length();

	const double zMin = -1200.0;
	const double zMax = 280.0;
	const double discRadius = std::max(400.0, stationClipRadius + 180.0);

	// Fast clear exits: open front side of station, open space behind station,
	// or already aligned inside the front central approach cone.
	if (z0 >= zMax && z1 >= zMax)
		return false;
	if (z0 <= zMin && z1 <= zMin)
		return false;
	if (z0 >= 25.0 && z1 >= 25.0 && r0 <= 320.0 && r1 <= 320.0)
		return false;

	// Clip segment t in [0, 1] to slab z(t) in [zMin, zMax].
	double tLo = 0.0;
	double tHi = 1.0;
	const double dz = z1 - z0;
	if (std::fabs(dz) < 1e-9) {
		if (z0 < zMin || z0 > zMax)
			return false;
	} else {
		double tz0 = (zMin - z0) / dz;
		double tz1 = (zMax - z0) / dz;
		if (tz0 > tz1) std::swap(tz0, tz1);
		tLo = std::max(tLo, tz0);
		tHi = std::min(tHi, tz1);
		if (tLo > tHi)
			return false;
	}

	const vector3d dR = rVec1 - rVec0;
	const double dRLenSqr = dR.LengthSqr();
	double tStar = tLo;
	if (dRLenSqr > 1e-12) {
		tStar = std::clamp(-rVec0.Dot(dR) / dRLenSqr, tLo, tHi);
	}
	const double rMin = (rVec0 + dR * tStar).Length();
	if (rMin >= discRadius)
		return false;

	// Segment enters the station disc envelope; produce a deterministic 2-stage rim detour.
	vector3d rDir(0.0);
	if (r0 > 20.0) {
		rDir = rVec0 / r0;
	} else if (r1 > 20.0) {
		rDir = rVec1 / r1;
	} else {
		rDir = fallbackRadialDir - cDir * fallbackRadialDir.Dot(cDir);
		if (rDir.LengthSqr() < 1e-6) {
			rDir = MathUtil::OrthogonalDirection(cDir);
		}
		rDir = rDir.NormalizedSafe();
	}
	rDir = (rDir - cDir * rDir.Dot(cDir)).NormalizedSafe();
	if (rDir.LengthSqr() < 1e-6) {
		rDir = MathUtil::OrthogonalDirection(cDir).NormalizedSafe();
	}

	const double detourRadius = discRadius + 220.0;
	if (z0 < zMax && r0 < discRadius) {
		outDetourLocal = portPos + rDir * detourRadius + cDir * std::min(z0, zMin - 150.0);
	} else {
		const double targetZ = (z1 >= zMax) ? (zMax + 300.0) : (zMin - 150.0);
		outDetourLocal = portPos + rDir * detourRadius + cDir * targetZ;
	}
	return true;
}

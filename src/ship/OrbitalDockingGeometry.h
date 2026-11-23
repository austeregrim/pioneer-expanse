// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef _ORBITALDOCKINGGEOMETRY_H
#define _ORBITALDOCKINGGEOMETRY_H

#include "matrix3x3.h"
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

/**
 * Determine whether a vessel is safely aligned inside the front corridor cone
 * with low lateral velocity so it may skip APPROACH1 and proceed directly to APPROACH2.
 */
bool CanSkipOrbitalApproach1(
	double axialDist,
	double lateralDist,
	double lateralSpeed,
	double relSpeed);

struct OrbitalCorridorGuidance {
	vector3d desiredVelInStation;
	double fwdSpeed;
	bool resetToApproach1;
	bool readyForDockingSequence;
};

/**
 * Compute alignment-gated, critically damped final corridor ingress guidance in
 * station-local coordinates for orbital starports.
 */
OrbitalCorridorGuidance ComputeOrbitalCorridorGuidance(
	const vector3d &shipPosInStation,
	const vector3d &portPos,
	const vector3d &corridorDir,
	const vector3d &desiredLateralOffset,
	double baseForwardSpeed,
	double trafficSpeedMult,
	double lateralAccel,
	double forwardDecel,
	double noseErrRad,
	double rollErrRad,
	bool manualDocking);

struct SupercruiseDropResult {
	vector3d position;
	matrix3x3d orient;
	bool preservedApproachVector;
};

/**
 * Construct an orthonormal orientation matrix facing forwardDir (-Z) while
 * preserving the caller's cockpit upHint as closely as possible.
 */
matrix3x3d BuildDropOrientPreservingUp(
	const vector3d &forwardDir,
	const vector3d &upHint);

/**
 * Compute orbital station Supercruise drop-in pose preserving the ship's exact
 * Supercruise approach vector and orientation whenever approaching within 60 degrees.
 */
SupercruiseDropResult ComputeOrbitalStationDropIn(
	const vector3d &stationPos,
	const vector3d &shipPos,
	const matrix3x3d &shipOrient,
	double safeDropDist,
	double minClearDist);

/**
 * Compute surface starport Supercruise drop-in pose preserving the ship's exact
 * Supercruise glide angle and roll, lifting only below minElevationSin if needed.
 */
SupercruiseDropResult ComputeSurfaceStationDropIn(
	const vector3d &stationPos,
	const vector3d &upDir,
	const vector3d &shipPos,
	const matrix3x3d &shipOrient,
	double safeDropDist,
	double minElevationSin = 0.25);

#endif /* _ORBITALDOCKINGGEOMETRY_H */

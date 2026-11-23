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
	const double zMax = 240.0;
	const double discRadius = std::max(400.0, stationClipRadius + 220.0);

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

	const double detourRadius = discRadius + 330.0;
	const double frontExitZ = std::max(z1, zMax + 360.0);
	const double rearExitZ = zMin - 200.0;

	if (r0 < discRadius && z0 > zMin && z0 < zMax) {
		// Inside the disc cylinder axially & radially:
		// Never cut diagonally across the spokes/ring. Exit straight along the axis
		// while keeping current radial offset.
		const double exitZ = (z0 >= -200.0) ? frontExitZ : rearExitZ;
		outDetourLocal = portPos + rVec0 + cDir * exitZ;
	} else if (z0 <= zMin && r0 < discRadius) {
		// Behind the station disc: step radially out past the ring rim at safe aft depth.
		outDetourLocal = portPos + rDir * detourRadius + cDir * std::min(z0, rearExitZ);
	} else if (z0 >= zMax && r0 < discRadius) {
		// In front of the station disc heading behind it: step radially out past the rim first.
		outDetourLocal = portPos + rDir * detourRadius + cDir * std::max(z0, zMax + 360.0);
	} else {
		// Outside the disc radially (r0 >= discRadius): advance axially past the rim.
		const double targetZ = (z1 >= zMax) ? frontExitZ : rearExitZ;
		outDetourLocal = portPos + rDir * detourRadius + cDir * targetZ;
	}
	return true;
}

bool CanSkipOrbitalApproach1(
	double axialDist,
	double lateralDist,
	double lateralSpeed,
	double relSpeed)
{
	if (axialDist < 120.0 || axialDist > 1000.0)
		return false;
	const double maxAllowedLat = std::min(50.0, axialDist * 0.12);
	return lateralDist <= maxAllowedLat && lateralSpeed <= 15.0 && relSpeed <= 60.0;
}

static inline double DegToRadLocal(double deg)
{
	return deg * (3.14159265358979323846 / 180.0);
}

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
	bool manualDocking)
{
	OrbitalCorridorGuidance out;
	out.desiredVelInStation = vector3d(0.0);
	out.fwdSpeed = 0.0;
	out.resetToApproach1 = false;
	out.readyForDockingSequence = false;

	const vector3d cDir = corridorDir.NormalizedSafe();
	if (cDir.LengthSqr() < 0.1)
		return out;

	const double axialDist = (shipPosInStation - portPos).Dot(cDir);
	const vector3d centerAxisPt = portPos + axialDist * cDir;
	const double centerOffAxisDist = (shipPosInStation - centerAxisPt).Length();

	const vector3d targetLanePos = portPos + std::max(0.0, axialDist) * cDir + desiredLateralOffset;
	vector3d offAxisVec = shipPosInStation - targetLanePos;
	offAxisVec -= cDir * offAxisVec.Dot(cDir);
	const double offAxisDist = offAxisVec.Length();

	// Safety bailout if ship ended up beside or behind the airlock face outside the doorway envelope
	if ((axialDist < 25.0 && centerOffAxisDist > 24.0) ||
		(axialDist < -10.0 && centerOffAxisDist > 18.0) ||
		(axialDist < 120.0 && offAxisDist > 140.0)) {
		out.resetToApproach1 = true;
		out.desiredVelInStation = cDir * 15.0;
		return out;
	}

	// Ready for interior docking animation only when aligned in position, nose, and roll
	if (!manualDocking &&
		axialDist <= 18.0 && axialDist >= -20.0 &&
		centerOffAxisDist < 18.0 &&
		noseErrRad < DegToRadLocal(12.0) &&
		rollErrRad < DegToRadLocal(20.0)) {
		out.readyForDockingSequence = true;
		out.fwdSpeed = 14.0 * std::max(0.0, trafficSpeedMult);
		out.desiredVelInStation = -cDir * out.fwdSpeed;
		return out;
	}

	// Lateral corridor alignment gate enforced at ALL distances
	double latScale = 1.0;
	if (axialDist <= 120.0) {
		if (offAxisDist > 8.0)
			latScale = std::clamp(1.0 - (offAxisDist - 8.0) / 14.0, 0.0, 1.0);
	} else {
		if (offAxisDist > 15.0)
			latScale = std::clamp(1.0 - (offAxisDist - 15.0) / 30.0, 0.0, 1.0);
	}

	// Attitude alignment gate: wait until facing corridor and roll-matched near slot
	double noseScale = 1.0;
	if (noseErrRad > DegToRadLocal(8.0)) {
		noseScale = std::clamp(1.0 - (noseErrRad - DegToRadLocal(8.0)) / DegToRadLocal(12.0), 0.0, 1.0);
	}

	double rollScale = 1.0;
	if (axialDist < 120.0 && rollErrRad > DegToRadLocal(10.0)) {
		rollScale = std::clamp(1.0 - (rollErrRad - DegToRadLocal(10.0)) / DegToRadLocal(15.0), 0.0, 1.0);
	}

	const double orientScale = noseScale * rollScale;
	const double safeFwdDecel = std::max(0.5, forwardDecel);
	const double brakingSpeedCap = 0.9 * std::sqrt(12.0 * 12.0 + 2.0 * safeFwdDecel * std::max(0.0, axialDist));
	const double tMult = std::max(0.0, trafficSpeedMult);

	double fwdSpeed = std::min(baseForwardSpeed, brakingSpeedCap) * tMult * latScale * orientScale;

	// Ensure steady ingress across the airlock threshold once tightly aligned
	if (tMult > 0.0 && latScale > 0.85 && orientScale > 0.85 && axialDist < 120.0 && centerOffAxisDist < 14.0) {
		fwdSpeed = std::max(fwdSpeed, 14.0 * tMult);
	}

	// Critically damped lateral centering (prevents overshoot oscillation on heavy ships)
	const double safeLatAccel = std::max(0.5, lateralAccel * 0.65);
	const double dampedLatSpeed = std::min(30.0, std::min(offAxisDist * 1.8, 0.9 * std::sqrt(2.0 * safeLatAccel * offAxisDist)));
	const vector3d lateralVel = -offAxisVec.NormalizedSafe() * dampedLatSpeed;

	out.fwdSpeed = fwdSpeed;
	out.desiredVelInStation = -cDir * fwdSpeed + lateralVel;
	return out;
}

matrix3x3d BuildDropOrientPreservingUp(
	const vector3d &forwardDir,
	const vector3d &upHint)
{
	vector3d fwd = forwardDir.NormalizedSafe();
	if (fwd.LengthSqr() < 0.1)
		fwd = vector3d(0.0, 0.0, -1.0);
	const vector3d z = -fwd;

	vector3d x = upHint.Cross(z).NormalizedSafe();
	if (x.LengthSqr() < 0.1)
		x = MathUtil::OrthogonalDirection(z).NormalizedSafe();
	const vector3d y = z.Cross(x).NormalizedSafe();
	return matrix3x3d::FromVectors(x, y, z);
}

SupercruiseDropResult ComputeOrbitalStationDropIn(
	const vector3d &stationPos,
	const vector3d &shipPos,
	const matrix3x3d &shipOrient,
	double safeDropDist,
	double minClearDist)
{
	SupercruiseDropResult res;
	const vector3d relToShip = shipPos - stationPos;
	const double currentDist = relToShip.Length();
	vector3d fromStation = relToShip.NormalizedSafe();
	if (fromStation.LengthSqr() < 0.1)
		fromStation = vector3d(0.0, 0.0, 1.0);

	const vector3d approachFwd = (-shipOrient.VectorZ()).NormalizedSafe();

	if (currentDist <= safeDropDist) {
		res.position = (currentDist < minClearDist) ? (stationPos + fromStation * minClearDist) : shipPos;
		res.orient = shipOrient;
		res.preservedApproachVector = true;
		return res;
	}

	// Preserve exact Supercruise approach vector & roll whenever approaching within 60 degrees
	if (approachFwd.LengthSqr() > 0.5 && approachFwd.Dot(-fromStation) > 0.5) {
		res.position = stationPos - approachFwd * safeDropDist;
		res.orient = shipOrient;
		res.preservedApproachVector = true;
		return res;
	}

	// Fallback if forced disengage while pointed > 60 deg away: drop on ship's current side
	res.position = stationPos + fromStation * safeDropDist;
	res.orient = BuildDropOrientPreservingUp(-fromStation, shipOrient.VectorY());
	res.preservedApproachVector = false;
	return res;
}

SupercruiseDropResult ComputeSurfaceStationDropIn(
	const vector3d &stationPos,
	const vector3d &upDir,
	const vector3d &shipPos,
	const matrix3x3d &shipOrient,
	double safeDropDist,
	double minElevationSin)
{
	SupercruiseDropResult res;
	vector3d up = upDir.NormalizedSafe();
	if (up.LengthSqr() < 0.1)
		up = vector3d(0.0, 1.0, 0.0);

	const vector3d shipRel = shipPos - stationPos;
	const double currentDist = shipRel.Length();
	vector3d fromStation = shipRel.NormalizedSafe();
	if (fromStation.LengthSqr() < 0.1)
		fromStation = up;

	const vector3d approachFwd = (-shipOrient.VectorZ()).NormalizedSafe();

	if (currentDist <= safeDropDist) {
		res.position = shipPos;
		res.orient = shipOrient;
		res.preservedApproachVector = true;
		return res;
	}

	const bool headingTowardStation = (approachFwd.LengthSqr() > 0.5 && approachFwd.Dot(-fromStation) > 0.5);
	vector3d dropDir = headingTowardStation ? (-approachFwd) : fromStation;

	const double elevSin = dropDir.Dot(up);
	bool clamped = false;
	if (elevSin < minElevationSin) {
		vector3d horiz = (dropDir - up * elevSin).NormalizedSafe();
		if (horiz.LengthSqr() < 0.1)
			horiz = (fromStation - up * fromStation.Dot(up)).NormalizedSafe();
		if (horiz.LengthSqr() < 0.1)
			horiz = MathUtil::OrthogonalDirection(up).NormalizedSafe();

		const double cosElev = std::sqrt(std::max(0.0, 1.0 - minElevationSin * minElevationSin));
		dropDir = (up * minElevationSin + horiz * cosElev).Normalized();
		clamped = true;
	}

	res.position = stationPos + dropDir * safeDropDist;
	if (headingTowardStation && !clamped) {
		res.orient = shipOrient;
		res.preservedApproachVector = true;
	} else {
		res.orient = BuildDropOrientPreservingUp(-dropDir, shipOrient.VectorY());
		res.preservedApproachVector = false;
	}
	return res;
}

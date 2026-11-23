// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "ship/Visibility.h"
#include "Body.h"
#include "Ship.h"
#include "Space.h"
#include "galaxy/SystemBody.h"
#include "ship/SupercruiseController.h"

#include <cmath>

namespace Visibility {

	bool IsOccludedInSpace(const Space *space, const Body *observer, const Body *target)
	{
		if (!space || !observer || !target || observer == target)
			return false;

		const FrameId rootFrame = space->GetRootFrame();
		if (!rootFrame.valid())
			return false;

		const vector3d from = observer->GetPositionRelTo(rootFrame);
		const vector3d to = target->GetPositionRelTo(rootFrame);
		const vector3d seg = to - from;
		const double segLenSq = seg.LengthSqr();
		if (segLenSq <= 1e-6)
			return false;
		const double targetDist = std::sqrt(segLenSq);

		for (const Body *b : space->GetBodies()) {
			if (!b || b == observer || b == target)
				continue;
			if (!b->IsType(ObjectType::TERRAINBODY))
				continue;

			const SystemBody *sb = b->GetSystemBody();
			const double radius = sb ? sb->GetRadius() : b->GetPhysRadius();
			if (radius <= 0.0)
				continue;

			const vector3d center = b->GetPositionRelTo(rootFrame);
			const double maxCheckDist = targetDist + radius;
			if ((center - from).LengthSqr() > maxCheckDist * maxCheckDist)
				continue;

			if (SegmentIntersectsSphere(from, to, center, radius))
				return true;
		}

		return false;
	}

	double GetDarkSensorRange(const Ship *observer)
	{
		if (!observer || observer->AreSensorsDisabled())
			return 0.0;
		return GetDarkSensorRangeForLevel(observer->GetStats().sublight_sensor_cap);
	}

	double GetRadarDisplayRange(const Ship *observer)
	{
		if (!observer || observer->AreSensorsDisabled())
			return 0.0;
		const shipstats_t &st = observer->GetStats();
		return GetBaseRadarRangeForLevel(st.radar_cap, st.sublight_sensor_cap);
	}

	bool CanReadShipIdentity(const Ship *observer, const Ship *target)
	{
		if (!observer || !target || target->IsDead())
			return false;
		if (observer == target)
			return true;
		const bool observerInSC = (observer->GetFlightState() == Ship::SUPERCRUISE);
		const bool targetInSC = (target->GetFlightState() == Ship::SUPERCRUISE);
		const double dist = observer->GetPositionRelTo(target).Length();
		return EvaluateIdentityReadable(target->IsTransponderActive(), observerInSC, targetInSC, dist);
	}

	bool CanWitnessDarkFTL(const Space *space, const Ship *observer, const Ship *target, double fovFullAngleDeg)
	{
		if (!space || !observer || !target || observer == target)
			return false;
		if (observer->IsDead() || !observer->IsInSpace() || observer->IsDocked())
			return false;
		if (target->IsDead() || !target->IsInSpace() || target->IsDocked())
			return false;
		if (!SupercruiseController::IsShipFTL(target))
			return false;
		if (target->IsTransponderActive())
			return false;
		if (IsOccludedInSpace(space, observer, target))
			return false;

		const FrameId rootFrame = space->GetRootFrame();
		if (!rootFrame.valid())
			return false;
		const vector3d obsFwd = (-observer->GetOrientRelTo(rootFrame).VectorZ()).NormalizedSafe();
		const vector3d toTarget = target->GetPositionRelTo(rootFrame) - observer->GetPositionRelTo(rootFrame);
		return IsWithinFieldOfView(obsFwd, toTarget, fovFullAngleDeg * 0.5);
	}

} // namespace Visibility

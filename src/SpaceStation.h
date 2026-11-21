// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef _SPACESTATION_H
#define _SPACESTATION_H

#include "ModelBody.h"
#include "Quaternion.h"
#include "SpaceStationType.h"

#define MAX_DOCKING_PORTS 240 //256-(0x10), 0x10 is used because the collision surfaces use it as an identifying flag
#define DOCKING_CLEARANCE_TIMEOUT (20.0 * 60.0)  // (20 min approach clearance window)

class Body;
class Camera;
class CityOnPlanet;
class Frame;
class NavLights;
class Ship;
class Space;
class SystemBody;

namespace Graphics {
	class Renderer;
}

namespace SceneGraph {
	class Animation;
}

class SpaceStation : public ModelBody {
public:
	OBJDEF(SpaceStation, ModelBody, SPACESTATION);
	static void Init();

	enum class DockingRefusedReason { // <enum scope='SpaceStation::DockingRefusedReason' name='DockingRefusedReason' public>
		ClearanceAlreadyGranted,
		TooFarFromStation,
		NoBaysAvailable
	};

	SpaceStation() = delete;
	// Should point to SystemBody in Pi::currentSystem
	SpaceStation(const SystemBody *);
	SpaceStation(const Json &jsonObj, Space *space);

	virtual ~SpaceStation();
	vector3d GetAngVelocity() const override { return vector3d(0, m_type->AngVel(), 0); }
	bool OnCollision(Body *b, Uint32 flags, double relVel) override;
	bool DoShipDamage(Ship *s, Uint32 flags, double relVel);
	void Render(Graphics::Renderer *r, const Camera *camera, const vector3d &viewCoords, const matrix4x4d &viewTransform) override;
	void StaticUpdate(const float timeStep) override;
	void TimeStepUpdate(const float timeStep) override;

	const SystemBody *GetSystemBody() const override { return m_sbody; }
	void PostLoadFixup(Space *space) override;
	void NotifyRemoved(const Body *const removedBody) override;

	void SetLabel(const std::string &label) override;

	// should call Ship::Undock and Ship::SetDockedWith instead
	// Returns true on success, false if permission denied
	bool LaunchShip(Ship *ship, const int port);
	bool CanLaunch(const Ship *ship) const;
	bool IsCorridorOccupied(const Ship *excludeShip = nullptr) const;
	bool ClaimCorridor(Ship *ship);
	double GetLaunchWaitTime() const;
	void NotifyCorridorCleared(const Ship *ship);
	void SetDocked(Ship *ship, const int port);
	void SwapDockedShipsPort(const int oldPort, const int newPort);

	// Multi-lane corridor traffic control and dynamic collision avoidance
	static bool IsLargeCorridorShip(const Ship *ship);
	bool GetCorridorGeometry(vector3d &outPortPos, vector3d &outCorridorDir, vector3d &outLaneDir) const;
	double GetCorridorLaneOffset(const Ship *ship, bool isInbound) const;
	double EvaluateCorridorTrafficAvoidance(Ship *ship, bool isInbound, const vector3d &corridorDir, const vector3d &laneDir, double axialDist, vector3d &outDesiredLateralOffset) const;
	bool BeginOrbitalDockingSequence(Ship *s);

	int GetNearbyTraffic(double radius);

	bool GetDockingClearance(Ship *s);
	int GetDockingPortCount() const { return m_type->NumDockingPorts(); }
	int GetFreeDockingPort(const Ship *s) const; // returns -1 if none free
	int GetFreeDockingPortCount() const;
	int GetMyDockingPort(const Ship *s) const;
	int NumShipsDocked() const;
	bool StowShipInHangar(Ship *ship);
	bool BeginUnstowFromHangar(Ship *ship, const int bay);
	void TakeoverUndock(Ship *ship);

	const SpaceStationType *GetStationType() const { return m_type; }
	bool IsGroundStation() const;
	bool IsInsideStation(const Body *b) const;

	bool AllocateStaticSlot(int &slot);

	// use docking bay position, if player has been granted permission
	vector3d GetTargetIndicatorPosition() const override;

	// need this now because stations rotate in their frame
	void UpdateInterpTransform(double alpha) override;

	// Return true if any lightning changes were applied, only do so if body is inside
	// or near enough to the station
	bool CalcInteriorLighting(const Body *b, Color4ub& sLight, double& sIntensity) const;


protected:
	void SaveToJson(Json &jsonObj, Space *space) override;

private:
	void DockingUpdate(const double timeStep);
	void PositionDockingShip(Ship *ship, int port) const;
	void PositionDockedShip(Ship *ship, int port) const;
	bool LevelShip(Ship *ship, int port, const float timeStep);
	void DoLawAndOrder(const double timeStep);
	bool IsPortLocked(const int bay) const;
	void LockPort(const int bay, const bool lockIt);
	double GetDockAnimStageDuration(const int bay, const DockStage stage) const;
	double GetUndockAnimStageDuration(const int bay, const DockStage stage) const;

	struct shipDocking_t {
		shipDocking_t() :
			ship(0),
			shipIndex(0),
			stage(DockStage::NONE),
			stagePos(0),
			fromPos(0.0),
			fromRot(1.0, 0.0, 0.0, 0.0),
			maxOffset(0)
		{}

		Ship *ship;
		int shipIndex; // deserialisation
		DockStage stage;
		double stagePos;  // 0 -> 1.0
		vector3d fromPos; // in station model coords
		Quaterniond fromRot;
		double maxOffset;
	};
	typedef std::vector<shipDocking_t>::const_iterator constShipDockingIter;
	typedef std::vector<shipDocking_t>::iterator shipDockingIter;
	std::vector<shipDocking_t> m_shipDocking;

	SpaceStationType::TPorts m_ports;

	double m_oldAngDisplacement;

	void SwitchToStage(Uint32 bay, DockStage stage);
	matrix4x4d GetBayTransform(Uint32 bay) const;

	void InitStation();
	const SpaceStationType *m_type;
	const SystemBody *m_sbody;
	CityOnPlanet *m_adjacentCity;
	enum { NUM_STATIC_SLOTS = 4 };
	bool m_staticSlot[NUM_STATIC_SLOTS];

	SceneGraph::Animation *m_doorAnimation;
	double m_doorAnimationStep;
	double m_doorAnimationState;

	std::unique_ptr<NavLights> m_navLights;

	// Station Air Traffic Control (ATC) clearance tracker
	Ship *m_corridorShip;
	double m_lastLaunchTime;
	static constexpr double MIN_LAUNCH_SEPARATION = 16.0;
	static constexpr double HANGAR_ELEVATOR_DURATION = 6.5;
};

#endif /* _SPACESTATION_H */

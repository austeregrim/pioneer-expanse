// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#pragma once

#include "FrameId.h"
#include "JsonFwd.h"
#include "vector3.h"
#include <algorithm>
#include <cmath>
#include <deque>
#include <string>

class Body;
class Planet;
class Ship;
class Space;

class SupercruiseController {
public:
	static constexpr double LIGHT_SPEED = 299792458.0;        // 1c in m/s
	static constexpr double MIN_SPEED = 30000.0;              // 30 km/s (0.0001c)
	static constexpr double MIN_ENGAGE_SPEED = 350.0;         // 350 m/s minimum sublight engagement speed
	static constexpr double MAX_SPEED = 2001.0 * LIGHT_SPEED; // 2,001c in m/s
	static constexpr double SAFE_DISENGAGE_DIST = 1000000.0;  // 1,000 km
	static constexpr double SAFE_DISENGAGE_SPEED = 1000000.0; // 1,000 km/s
	static constexpr double SUBLIGHT_AUTOPILOT_MAX_DIST = 2500000.0; // 2,500 km (covers safe drop-in envelope + approach buffer)
	static constexpr float CHARGE_DURATION = 5.0f;            // 5s FSD charge-up
	static constexpr float ENTRY_FLASH_DURATION = 0.75f;      // 0.75s FSD Supercruise entry optical flash
	static constexpr float NORMAL_COOLDOWN = 5.0f;            // 5s normal FSD cooldown
	static constexpr float HYPERJUMP_COOLDOWN = 12.0f;        // 12s post-hyperjump FSD cooldown
	static constexpr float EMERGENCY_COOLDOWN = 25.0f;        // 25s emergency FSD cooldown
	static constexpr double STATION_MASS_LOCK_DIST = 5000.0;  // 5 km station mass lock
	static constexpr double PLANET_MASS_LOCK_ALT = 5000.0;    // 5 km surface mass lock

	enum Status {
		SC_READY,
		SC_CHARGING,
		SC_ACTIVE,
		SC_COOLDOWN,
		SC_MASS_LOCKED,
		SC_GEAR_DOWN,
		SC_TOO_SLOW,
		SC_FSD_OFFLINE,
		SC_NOT_FLYING
	};

	enum InterdictionRole {
		INTERDICT_NONE = 0,
		INTERDICT_ATTACKER,
		INTERDICT_TARGET
	};

	enum AssistMode {
		ASSIST_APPROACH = 0,
		ASSIST_ORBIT_SCAN = 1
	};

	SupercruiseController(Ship *ship);
	~SupercruiseController() = default;

	void SaveToJson(Json &jsonObj, Space *space = nullptr) const;
	void LoadFromJson(const Json &jsonObj);
	void PostLoadFixup(Space *space);
	void OnDeleted(const Body *body);

	// AI target assignment (for non-player ships)
	void SetTarget(Body *target);
	void SetTargetPosition(FrameId frameId, const vector3d &offset);
	Body *GetTarget() const { return m_target; }
	bool AcquireSupercruiseLock(Ship *target);
	void ClearSupercruiseLock()
	{
		m_lockedShip = nullptr;
		m_lockedShipIndex = 0;
	}
	Ship *GetLockedShip() const { return m_lockedShip; }
	void ComputeAISteering(const vector3d &targetPosRelToShip, const Body *targetBody, vector3d &outAngInput, double &outThrottle) const;

	// State queries
	bool IsActive() const;
	bool IsFTL() const { return IsActive() && m_speed >= LIGHT_SPEED; }
	bool IsInterdictingPeer(const Ship *other) const { return other && m_interdictPeer == other && m_interdictRole != INTERDICT_NONE; }
	static bool IsShipFTL(const Ship *ship);
	static bool HasTrackedLock(const Ship *observer, const Ship *target);
	static bool IsShipVisibleToSensors(const Ship *observer, const Ship *target);
	float GetEntryFlashTimer() const { return m_entryFlashTimer; }
	const vector3d &GetEntryFlashRootPos() const { return m_entryFlashRootPos; }
	bool IsCharging() const { return m_charging; }
	float GetChargeProgress() const { return m_charging ? (1.0f - m_chargeCountdown / CHARGE_DURATION) : 0.0f; }
	float GetChargeCountdown() const { return m_chargeCountdown; }
	float GetCooldown() const { return m_cooldown; }
	bool IsMassLocked(std::string *outReason = nullptr) const;
	double GetShipMassLockFactor() const;
	bool IsFsdOffline() const { return m_fsdOffline; }
	void SetFsdOffline(bool offline);
	Status GetStatus(std::string *outReason = nullptr) const;

	// Speed & Throttle (0.0 to 1.0)
	double GetThrottle() const { return m_throttle; }
	void SetThrottle(double throttle);
	void ChangeThrottle(double delta);
	double GetSpeed() const { return m_speed; }
	void SetSpeed(double speed);
	double GetMaxEnvSpeed() const { return m_maxEnvSpeed; }
	double GetDesiredSpeed() const { return m_desiredSpeed; }
	double GetSpeedCap() const { return m_speedCap; }
	void SetSpeedCap(double maxSpeed) { m_speedCap = (maxSpeed > 0.0) ? maxSpeed : 0.0; }
	double GetGravityStrain() const { return m_gravityStrain; }

	// Target telemetry & Safe Disengage
	bool IsSafeDisengageReady() const { return m_safeDisengageReady; }
	bool IsSlowDownWarning() const { return m_slowDownWarning; }
	double GetTargetDistance() const { return m_targetDistance; }
	double GetTargetETA() const { return m_targetETA; }

	// Supercruise Assist (Autopilot Mk 2 / Mk 3 / Mk 4)
	int GetAssistLevel() const;
	bool HasAssistModule() const;
	bool IsAssistActive() const { return m_assistActive; }
	void SetAssistActive(bool active, bool dockOnArrival = false);
	void ToggleAssist();

	// Planetary Orbit & Autonomous Survey Orbit (Autopilot Mk 3 / Mk 4)
	bool IsOrbitHoldActive() const { return m_assistActive && m_orbitHoldActive; }
	bool IsSurveyOrbitActive() const { return m_assistActive && m_assistMode == ASSIST_ORBIT_SCAN; }
	Body *GetSurveyOrbitBody() const { return (m_assistMode == ASSIST_ORBIT_SCAN) ? m_surveyOrbitBody : nullptr; }
	double GetSurveyOrbitRadius() const { return m_orbitTargetRadius; }
	bool IsSurveyOrbitPolar() const { return m_orbitPolarPrecess; }
	bool SetSurveyOrbitTarget(Body *body, double requestedRadius, bool polarSweep);
	void ClearSurveyOrbit();

	// Actions
	bool Toggle();
	bool StartCharge();
	void AbortCharge(const std::string &reason = "");
	void EnterSupercruise();
	void EnterSupercruiseImmediate(double initialSpeed = MIN_SPEED);
	void EnterSupercruiseOnHyperspaceExit();
	void SafeDisengage();
	void NormalDrop(const std::string &reason = "");
	void EmergencyDrop(const std::string &reason = "");
	void Reset();
	void OnEnterHyperspace();

	// Per-frame updates
	void StaticUpdate(float timeStep);
	void TimeStepUpdate(float timeStep, const vector3d &desiredAngInput);

	// Heat spike from emergency drop / stellar corona scooping
	double GetHeatSpike() const { return m_heatSpike; }

	// Stellar fuel scooping telemetry (active in Supercruise near scoopable stars)
	bool IsFuelScoopActive() const { return m_fuelScoopActive; }
	bool IsFuelScoopUnscoopable() const { return m_fuelScoopUnscoopable; }
	double GetFuelScoopRate() const { return m_fuelScoopRate; }
	double GetFuelScoopProximity() const { return m_fuelScoopProximity; }

	// Recent root-frame trajectory samples for curved FTL motion-blur trails
	static constexpr size_t MAX_TRAIL_SAMPLES = 12;
	const std::deque<vector3d> &GetTrailPositions() const { return m_trailPositions; }

	// FSD Interdiction
	int GetInterdictorLevel() const;
	bool HasFSDInterdictor() const { return GetInterdictorLevel() > 0; }
	bool HasInterdictionNullifier() const;
	float GetNullifierCooldown() const { return m_nullifierCooldown; }
	bool CanInterdict(const Ship *target, std::string *outReason = nullptr) const;
	bool StartInterdiction(Ship *target);
	bool IsInterdicting() const { return m_interdictRole == INTERDICT_ATTACKER; }
	bool IsBeingInterdicted() const { return m_interdictRole == INTERDICT_TARGET; }
	Ship *GetInterdictionPeer() const { return m_interdictPeer; }
	double GetInterdictionCaptureProgress() const { return m_captureProgress; }
	double GetInterdictionEscapeProgress() const { return m_escapeProgress; }
	const vector3d &GetEscapeVectorWorld() const { return m_escapeDirWorld; }
	bool IsSubmittingToInterdiction() const { return m_submitting || (IsBeingInterdicted() && m_throttle <= 0.02); }
	void ClearInterdiction();

	// Status message for HUD
	const std::string &GetStatusMessage() const { return m_statusMessage; }
	float GetStatusMessageTimer() const { return m_statusMessageTimer; }
	void ShowStatusMessage(const std::string &msg, float duration = 4.0f);

	// Idle-command watchdog timer for NPC Supercruise traffic
	float GetIdleAITimer() const { return m_idleAITimer; }
	void ResetIdleAITimer() { m_idleAITimer = 0.0f; }
	void AdvanceIdleAITimer(float dt) { m_idleAITimer += dt; }

	// Compute exclusion zone radius (in meters) from body center
	static double GetExclusionZoneRadius(const Body *body);
	static double GetExclusionZoneRadiusAtDir(const Body *body, const vector3d &unitDirInBodyFrame);

	// Pure Supercruise Assist math helpers (inline so unit tests link without Pi/GuiApplication)
	static inline double ComputeSafeSurveyOrbitRadius(
		double exclR, double bodyRadius, bool isStar, bool hasRings,
		double ringInnerR, double ringOuterR, double maxScanDist,
		double requestedRadius, bool polarSweep)
	{
		double minSafeR = std::max(exclR * 1.28, 250000.0);
		if (isStar) {
			minSafeR = std::max(minSafeR, std::max(bodyRadius * 2.8, exclR * 2.4));
		}

		double safeR = (requestedRadius > 0.0)
			? std::max(requestedRadius, minSafeR)
			: std::max(minSafeR * 1.15, exclR + 400000.0);

		if (hasRings && ringOuterR > ringInnerR) {
			if (safeR >= ringInnerR * 0.88 && safeR <= ringOuterR * 1.16) {
				if (polarSweep && ringInnerR * 0.82 >= minSafeR) {
					safeR = ringInnerR * 0.82;
				} else {
					safeR = std::max(safeR, ringOuterR * 1.22);
				}
			}
		}

		if (maxScanDist > minSafeR) {
			const double upperCap = maxScanDist * 0.88;
			if (safeR > upperCap) {
				if (hasRings && ringInnerR * 0.82 >= minSafeR && upperCap < ringOuterR * 1.16) {
					safeR = ringInnerR * 0.82;
				} else {
					safeR = upperCap;
				}
			}
		}

		return std::max(safeR, minSafeR);
	}

	static inline double ComputeAssistApproachThrottle(
		double effectiveDist, double currentSpeed, double maxEnvSpeed,
		double closingDot, bool slowDownWarning, bool isOrbitMode, int assistLevel)
	{
		if (assistLevel <= 0)
			return 0.75;

		if (assistLevel == 1) {
			if (isOrbitMode && effectiveDist < 1500000.0 && currentSpeed > SAFE_DISENGAGE_SPEED * 1.05) {
				return 0.15;
			}
			return 0.75;
		}

		// Mk 3 / Mk 4 smart predictive braking & deep-space full cruise
		const double safeBrakeSpeed = std::max(MIN_SPEED, effectiveDist / 6.5);
		if (slowDownWarning || (effectiveDist < 120.0 * LIGHT_SPEED && currentSpeed > safeBrakeSpeed * 1.08)) {
			const double refSpeed = std::max(MIN_SPEED, std::min(safeBrakeSpeed, std::max(MIN_SPEED, maxEnvSpeed)));
			const double excess = std::max(0.0, (currentSpeed - refSpeed) / std::max(refSpeed, 1.0));
			return std::clamp(0.60 - excess * 0.90, 0.0, 0.60);
		}

		if (effectiveDist < 15.0 * LIGHT_SPEED && closingDot < 0.80) {
			const double turnCap = std::max(MIN_SPEED, effectiveDist * (closingDot > 0.25 ? 0.14 : 0.08));
			if (currentSpeed > turnCap * 1.05) {
				return std::clamp(0.50 * (turnCap / std::max(currentSpeed, 1.0)), 0.10, 0.55);
			}
			return 0.75;
		}

		const double cruiseDistThresh = isOrbitMode ? (20.0 * LIGHT_SPEED) : (15.0 * LIGHT_SPEED);
		const double cruiseSpeedMargin = isOrbitMode ? 0.78 : 0.80;
		if (effectiveDist > cruiseDistThresh && closingDot > 0.92 && currentSpeed < safeBrakeSpeed * cruiseSpeedMargin) {
			return 1.0;
		}

		return 0.75;
	}

	static inline vector3d ComputeOrbitSteeringDir(
		const vector3d &toBody, const vector3d &tangentDir,
		double orbitRadius, double exclRadius)
	{
		const double dist = toBody.Length();
		if (dist < 1.0) {
			return (tangentDir.LengthSqr() > 0.1) ? tangentDir.Normalized() : vector3d(0.0, 0.0, -1.0);
		}

		const vector3d uBS = -toBody / dist;
		vector3d tPerp = tangentDir - uBS * tangentDir.Dot(uBS);
		if (tPerp.LengthSqr() < 1e-6) {
			const vector3d refAxis = (std::abs(uBS.y) < 0.9) ? vector3d(0.0, 1.0, 0.0) : vector3d(1.0, 0.0, 0.0);
			tPerp = uBS.Cross(refAxis);
		}
		tPerp = tPerp.Normalized();

		if (dist > orbitRadius * 2.2) {
			const vector3d limbPoint = toBody + tPerp * orbitRadius;
			return limbPoint.NormalizedSafe();
		}

		double radBias = std::clamp(((orbitRadius - dist) / std::max(orbitRadius, 1.0)) * 1.8, -0.55, 0.70);
		if (exclRadius > 0.0 && dist < exclRadius * 1.18) {
			radBias = std::max(radBias, 0.75);
		}
		const double tangWeight = std::sqrt(std::max(0.05, 1.0 - radBias * radBias));
		return (tPerp * tangWeight + uBS * radBias).NormalizedSafe();
	}

	// Advance Supercruise speed for one timestep, smoothly ramping from sublight entry speed through MIN_SPEED
	static inline double StepSpeed(double currentSpeed, double desiredSpeed, double throttle, double gravityStrain, bool inBlueZoneOrAssist, float timeStep)
	{
		const double clampedDesired = std::clamp(desiredSpeed, MIN_SPEED, MAX_SPEED);
		const double clampedThrottle = std::clamp(throttle, 0.0, 1.0);
		double nextSpeed = currentSpeed;
		const double dt = std::max(0.0, double(timeStep));
		if (nextSpeed < clampedDesired) {
			const double baseAccel = (nextSpeed < MIN_SPEED)
				? std::max(6000.0, nextSpeed * 3.5)
				: std::max(45000.0, nextSpeed * 0.38);
			const double accel = baseAccel * (0.35 + 0.65 * clampedThrottle);
			nextSpeed = std::min(clampedDesired, nextSpeed + accel * dt);
		} else if (nextSpeed > clampedDesired) {
			const double speedDelta = nextSpeed - clampedDesired;
			const double decelFactor = inBlueZoneOrAssist
				? (0.85 + 2.0 * gravityStrain)
				: (0.45 + 1.25 * gravityStrain);
			const double decel = std::max(150000.0, nextSpeed * decelFactor + speedDelta * (1.5 + 2.5 * gravityStrain));
			nextSpeed = std::max(clampedDesired, nextSpeed - decel * dt);
		}
		const double minFloor = (currentSpeed >= MIN_SPEED) ? MIN_SPEED : 0.0;
		return std::clamp(nextSpeed, minFloor, MAX_SPEED);
	}

	// Planetary occlusion queries & great-circle bypass routing
	const Body *GetTargetObscuredBy(const vector3d &targetPosRelToShip, const Body *targetBody) const;
	bool IsTargetOccluded(Body **outBlocker = nullptr) const;

	// Pure FSD interdiction envelope & tug-of-war math helpers (inline for unit tests)
	enum InterdictFailCode {
		INTERDICT_OK = 0,
		INTERDICT_FAIL_RANGE = 1,
		INTERDICT_FAIL_TOO_FAST = 2,
		INTERDICT_FAIL_TOO_SLOW = 3,
		INTERDICT_FAIL_AIM = 4,
		INTERDICT_FAIL_NOT_BEHIND = 5,
		INTERDICT_FAIL_VECTOR_MISMATCH = 6
	};

	static inline double ComputeMaxInterdictionRange(double attackerSpeed, double targetSpeed, int level)
	{
		const double levelMult = 1.0 + 0.25 * double(std::max(1, level) - 1);
		const double refSpeed = std::min(attackerSpeed, targetSpeed);
		const double baseRange = std::clamp(refSpeed * 4.0, SAFE_DISENGAGE_DIST * 1.5, 20.0 * LIGHT_SPEED);
		return baseRange * levelMult;
	}

	static inline bool EvaluateInterdictionEnvelope(
		const vector3d &relToTarget,
		double attackerSpeed,
		double targetSpeed,
		const vector3d &attackerFwd,
		const vector3d &targetFwd,
		int level,
		int *outFailCode = nullptr)
	{
		const int lvl = std::max(1, level);
		const double dist = relToTarget.Length();
		const double maxRange = ComputeMaxInterdictionRange(attackerSpeed, targetSpeed, lvl);
		if (dist > maxRange) {
			if (outFailCode) *outFailCode = INTERDICT_FAIL_RANGE;
			return false;
		}

		const double maxMatchSpeed = targetSpeed * 1.35 + 150000.0;
		const double minMatchSpeed = std::max(0.0, targetSpeed * 0.75 - 150000.0);
		if (attackerSpeed > maxMatchSpeed) {
			if (outFailCode) *outFailCode = INTERDICT_FAIL_TOO_FAST;
			return false;
		}
		if (attackerSpeed < minMatchSpeed) {
			if (outFailCode) *outFailCode = INTERDICT_FAIL_TOO_SLOW;
			return false;
		}

		const vector3d toTargetDir = relToTarget.NormalizedSafe();
		const vector3d attFwdN = attackerFwd.NormalizedSafe();
		const vector3d tgtFwdN = targetFwd.NormalizedSafe();

		// Rear-hemisphere check: attacker must be behind target's tail (-targetFwd)
		const double rearCos = std::cos((32.0 + 4.0 * double(lvl - 1)) * (M_PI / 180.0));
		if (tgtFwdN.Dot(toTargetDir) < rearCos) {
			if (outFailCode) *outFailCode = INTERDICT_FAIL_NOT_BEHIND;
			return false;
		}

		const double aimCos = std::cos((22.0 + 3.0 * double(lvl - 1)) * (M_PI / 180.0));
		if (attFwdN.Dot(toTargetDir) < aimCos) {
			if (outFailCode) *outFailCode = INTERDICT_FAIL_AIM;
			return false;
		}

		// Flight vector matching with variance
		const double vecCos = std::cos((25.0 + 4.0 * double(lvl - 1)) * (M_PI / 180.0));
		if (attFwdN.Dot(tgtFwdN) < vecCos) {
			if (outFailCode) *outFailCode = INTERDICT_FAIL_VECTOR_MISMATCH;
			return false;
		}

		if (outFailCode) *outFailCode = INTERDICT_OK;
		return true;
	}

	static inline void ComputeEscapeWanderDeflection(
		double elapsed, double phaseSign, double &outYawDeflect, double &outPitchDeflect)
	{
		const double ramp = std::clamp(elapsed / 2.0, 0.0, 1.0);
		const double s = (phaseSign >= 0.0) ? 1.0 : -1.0;
		outYawDeflect = ramp * s * (0.24 * std::sin(elapsed * 0.52) + 0.07 * std::sin(elapsed * 1.15));
		outPitchDeflect = ramp * (0.20 * std::sin(elapsed * 0.44) + 0.06 * std::sin(elapsed * 1.05));
	}

	static inline void StepInterdictionTugOfWar(
		double &ioCapture,
		double &ioEscape,
		double evaderDot,
		double attackerDot,
		double targetMass,
		double attackerMass,
		int interdictorLevel,
		double elapsed,
		bool targetIsPlayer,
		bool attackerIsPlayer,
		double dt)
	{
		const double targetAgility = std::clamp(std::sqrt(70.0 / std::max(15.0, targetMass)), 0.72, 1.45);
		const double attackerAgility = std::clamp(std::sqrt(60.0 / std::max(15.0, attackerMass)), 0.70, 1.25);
		const double levelBonus = 1.0 + 0.15 * double(std::max(1, interdictorLevel) - 1);

		const double cosEvadeCenter = std::cos(7.0 * M_PI / 180.0);
		const double cosEvadeTight = std::cos(18.0 * M_PI / 180.0);
		const double cosEvadeLoose = std::cos(32.0 * M_PI / 180.0);

		if (evaderDot >= cosEvadeTight) {
			const double centerFrac = std::clamp((evaderDot - cosEvadeTight) / std::max(1e-6, cosEvadeCenter - cosEvadeTight), 0.0, 1.0);
			ioEscape += (0.115 + 0.030 * centerFrac) * targetAgility * dt;
		} else if (evaderDot >= cosEvadeLoose) {
			ioEscape += 0.045 * targetAgility * dt;
		} else {
			ioEscape -= 0.025 * dt;
		}

		const double cosAttTight = std::cos(14.0 * M_PI / 180.0);
		const double cosAttLoose = std::cos(24.0 * M_PI / 180.0);
		const double grace = targetIsPlayer ? std::clamp(elapsed / 1.2, 0.15, 1.0) : 1.0;

		if (!attackerIsPlayer && evaderDot >= cosEvadeTight) {
			ioCapture -= 0.020 * dt;
		} else if (attackerDot >= cosAttTight) {
			ioCapture += (attackerIsPlayer ? 0.115 : 0.075) * levelBonus * attackerAgility * grace * dt;
		} else if (attackerDot >= cosAttLoose) {
			ioCapture += 0.025 * levelBonus * grace * dt;
		} else {
			ioCapture -= 0.045 * dt;
		}

		ioCapture = std::clamp(ioCapture, 0.0, 1.0);
		ioEscape = std::clamp(ioEscape, 0.0, 1.0);
	}

private:
	void UpdateEnvironmentAndTarget(float timeStep, Body **outHitExclusionBody);
	void UpdateStellarFuelScoop(float timeStep);
	void ResetFuelScoopState();
	void UpdateInterdiction(float timeStep);
	static void DropPairFromInterdiction(Ship *attacker, Ship *target, bool submitted);
	void ClearStaleSupercruiseTarget();
	void EnsureShipAboveTerrainAndSyncFrame();
	void DropIntoRing(Planet *planet, const std::string &reason);
	Body *GetActiveTarget() const;
	bool GetActiveTargetPosRelToShip(vector3d &outPosRelToShip) const;

	Ship *m_ship;
	Body *m_target = nullptr;
	int m_targetIndex = 0;
	FrameId m_targetFrame;
	vector3d m_targetOffset = vector3d(0.0);
	Ship *m_lockedShip = nullptr;
	int m_lockedShipIndex = 0;
	bool m_charging = false;
	float m_chargeCountdown = 0.0f;
	float m_cooldown = 0.0f;
	double m_throttle = 0.75;
	double m_speed = 0.0;
	double m_maxEnvSpeed = MAX_SPEED;
	double m_desiredSpeed = MIN_SPEED;
	double m_speedCap = 0.0;
	double m_gravityStrain = 0.0;

	bool m_safeDisengageReady = false;
	bool m_slowDownWarning = false;
	double m_targetDistance = 0.0;
	double m_targetETA = 0.0;

	bool m_assistActive = false;
	bool m_dockOnArrival = false;
	AssistMode m_assistMode = ASSIST_APPROACH;
	bool m_orbitHoldActive = false;
	bool m_orbitPolarPrecess = false;
	double m_orbitTargetRadius = 0.0;
	double m_orbitPlaneAngle = 0.0;
	Body *m_surveyOrbitBody = nullptr;
	int m_surveyOrbitBodyIndex = 0;
	double GetActiveOrbitRadius(const Body *body) const;
	Planet *m_ringDropPlanet = nullptr;
	Planet *m_ringImmersionPlanet = nullptr;

	double m_heatSpike = 0.0;
	bool m_fsdOffline = false;
	std::deque<vector3d> m_trailPositions;
	float m_trailSampleTimer = 0.0f;
	float m_entryFlashTimer = 0.0f;
	vector3d m_entryFlashRootPos = vector3d(0.0);

	InterdictionRole m_interdictRole = INTERDICT_NONE;
	Ship *m_interdictPeer = nullptr;
	int m_interdictPeerIndex = 0;
	double m_captureProgress = 0.20;
	double m_escapeProgress = 0.20;
	double m_escapeWanderTime = 0.0;
	double m_interdictElapsed = 0.0;
	double m_escapeWanderPhase = 1.0;
	double m_submitTimer = 0.0;
	bool m_submitting = false;
	vector3d m_escapeBaseDir = vector3d(0.0, 0.0, -1.0);
	vector3d m_escapeDirWorld = vector3d(0.0, 0.0, -1.0);

	std::string m_statusMessage;
	float m_statusMessageTimer = 0.0f;
	float m_nullifierCooldown = 0.0f;

	bool m_fuelScoopActive = false;
	bool m_fuelScoopUnscoopable = false;
	double m_fuelScoopRate = 0.0;
	double m_fuelScoopProximity = 0.0;
	double m_fuelScoopAccum = 0.0;
	float m_fuelScoopDispatchTimer = 0.0f;
	float m_idleAITimer = 0.0f;
};


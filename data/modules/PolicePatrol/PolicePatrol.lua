-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Engine = require 'Engine'
local Equipment = require 'Equipment'
local Lang = require 'Lang'
local Game = require 'Game'
local Space = require 'Space'
local Comms = require 'Comms'
local Event = require 'Event'
local Legal = require 'Legal'
local Serializer = require 'Serializer'
local Timer = require 'Timer'
local Commodities = require 'Commodities'
local PlayerState = require 'PlayerState'
local FactionStanding = require 'FactionStanding'
local ui = require 'pigui'

local MissionUtils = require 'modules.MissionUtils'
local ShipBuilder  = require 'modules.MissionUtils.ShipBuilder'
local ShipRegistry = require 'modules.ShipRegistry.ShipRegistry'

local l = Lang.GetResource("module-policepatrol")
local l_ui_core = Lang.GetResource("ui-core")

local LIGHT_SPEED = 299792458.0
local AU_METERS = 149597870700.0
local maxFineTolerated = 5500
local lawEnforcedRange = 4000000
local SCAN_RANGE = 15000.0
local WARNING_WINDOW_SEC = 4.0
local SCAN_COOLDOWN_SEC = 180.0

local function hasIllegalGoods(cargo)
	for name in pairs(cargo) do
		if not Game.system:IsCommodityLegal(name) then
			return true
		end
	end
	return false
end

local patrol = {}
local patrolState = {}
local recentScans = {}
local showMercy = true
local piracy = false
local target = nil
local patrolTimerActive = false
local activeEscortShip = nil
local escortCooldownUntil = 0

local function installEquipment(ship, equipId, replaceSlotType)
	local equipSet = ship:GetComponent("EquipSet")
	local proto = Equipment.Get(equipId)
	if not equipSet or not proto then return false end
	if replaceSlotType then
		local existing = equipSet:GetInstalledOfType(replaceSlotType)
		for _, eq in ipairs(existing) do
			equipSet:Remove(eq)
		end
	end
	local inst = proto:Instance()
	local slot = equipSet:GetFreeSlotForEquip(inst)
	if slot then
		return equipSet:Install(inst, slot) ~= false
	end
	return false
end

local function equipPoliceLoadout(ship, system)
	if not ship or not ship:exists() then return end
	installEquipment(ship, "misc.fsd_interdictor_2")
	installEquipment(ship, "misc.target_scanner")
	local lawlessness = (system and system.lawlessness) or 0.5
	if lawlessness < 0.45 then
		installEquipment(ship, "sensor.sublight_array_1", "sensor.radar")
	end
	if ship.UpdateEquipStats then
		ship:UpdateEquipStats()
	end
end

local function getPatrolHubCandidates(ship, currentPort)
	local orbitalHubs = {}
	local surfacePorts = {}
	local allStations = Game.system and Game.system:GetStationPaths() or {}

	for _, path in ipairs(allStations) do
		local body = Space.GetBody(path.bodyIndex)
		if body and body:exists() and body ~= currentPort then
			local entry = {
				body = body,
				ndocks = body.numDocks or 4,
				isOrbital = (body.type == "STARPORT_ORBITAL"),
				tie = Engine.rand:Number(1),
			}
			if entry.isOrbital then
				table.insert(orbitalHubs, entry)
			else
				table.insert(surfacePorts, entry)
			end
		end
	end

	local pool = (#orbitalHubs > 0) and orbitalHubs or surfacePorts
	table.sort(pool, function(a, b)
		if a.ndocks ~= b.ndocks then return a.ndocks > b.ndocks end
		return a.tie < b.tie
	end)
	return pool
end

local function assignSupercruiseRoute(ship)
	if not Game.system or not ship or not ship:exists() then return end
	local st = patrolState[ship] or { mode = 'lane', lastPort = nil }
	patrolState[ship] = st

	local hubs = getPatrolHubCandidates(ship, st.lastPort)
	local stars = Game.system:GetStars()
	local primaryStar = stars and stars[1] and stars[1].body

	if st.mode == 'lane' and st.lastPort == nil and Engine.rand:Number(1) < 0.30 then
		for _, h in ipairs(hubs) do
			if h.isOrbital and (h.body.freeDocks or 0) >= 3 and ship:DistanceTo(h.body) < 3.0e9 then
				st.mode = 'docking'
				st.lastPort = h.body
				ship:AIDockWith(h.body)
				return
			end
		end
	end

	st.mode = 'lane'
	if #hubs > 0 then
		if primaryStar and ship:DistanceTo(primaryStar) > 6.0e9 and Engine.rand:Number(1) < 0.22 then
			st.lastPort = primaryStar
			ship:AIFlyTo(primaryStar)
			return
		end
		local chosen = hubs[Engine.rand:Integer(1, #hubs)]
		if chosen and chosen.body and ship:DistanceTo(chosen.body) > 500000 then
			st.lastPort = chosen.body
			ship:AIFlyTo(chosen.body)
			return
		end
		for _, h in ipairs(hubs) do
			if h.body and ship:DistanceTo(h.body) > 500000 then
				st.lastPort = h.body
				ship:AIFlyTo(h.body)
				return
			end
		end
	end

	local bodies = Game.system:GetBodyPaths()
	local planetCandidates = {}
	if bodies then
		for _, path in ipairs(bodies) do
			local sb = path:GetSystemBody()
			if sb and sb.body and (sb.superType == 'ROCKY_PLANET' or sb.superType == 'GAS_GIANT') then
				if ship:DistanceTo(sb.body) > 500000 then
					table.insert(planetCandidates, sb.body)
				end
			end
		end
	end
	if #planetCandidates > 0 then
		ship:AIFlyTo(planetCandidates[Engine.rand:Integer(1, #planetCandidates)])
		return
	end
	if primaryStar and ship:DistanceTo(primaryStar) > 5.0e8 then
		ship:AIFlyTo(primaryStar)
	end
end

local function clearOfficerState(p, st)
	if not st then return end
	if st.lockedTarget and st.lockedTarget == Game.player and st.warnStage and st.warnStage > 0 then
		Event.Queue("onPoliceTransponderWarningCleared")
	end
	if activeEscortShip == p then
		activeEscortShip = nil
		Event.Queue("onPoliceEscortStatus", false)
	end
	if p and p:exists() and p.ClearSupercruiseLock then
		p:ClearSupercruiseLock()
	end
	st.lockedTarget = nil
	st.pursuedTarget = nil
	st.targetScore = 0
	st.warnStage = 0
	st.warnDeadline = 0
	st.scanTarget = nil
	st.scanEndTime = 0
	st.actionKind = nil
end

local attackShip = function(ship)
	for i = 1, #patrol do
		if patrol[i]:exists() then
			patrol[i]:AIKill(ship)
		end
	end
	target = ship
end

local function getStandingScanChance(ship)
	local score = 0
	if ship:IsPlayer() and Game.system and Game.system.faction then
		score = FactionStanding.Get(Game.system.faction)
	end
	local baseChance
	if score < -14 then
		baseChance = 0.65
	elseif score < 15 then
		baseChance = 0.22
	elseif score < 40 then
		baseChance = 0.10
	else
		baseChance = 0.02
	end
	-- Small randomness ("boredom") factor so standing-based scans are never 100% deterministic
	local lawlessness = (Game.system and Game.system.lawlessness) or 0.5
	return math.min(0.85, baseChance * (0.75 + 0.50 * (1.0 - lawlessness)))
end

local function executeCargoScan(policeShip, suspect)
	if not policeShip or not policeShip:exists() or not suspect or not suspect:exists() then return end
	local cargoMgr = suspect:GetComponent('CargoManager')
	if not cargoMgr then return end

	local illegalCount = 0
	local illegalValue = 0
	local totalCargo = suspect.usedCargo or 0

	for name, count in cargoMgr:Commodities() do
		if not Game.system:IsCommodityLegal(name) then
			illegalCount = illegalCount + count
			local comm = Commodities[name]
			illegalValue = illegalValue + (comm and comm.price or 100) * count
		end
	end

	if suspect:hasprop("cargo_shield_cap") then
		local hidden = math.min(illegalCount, suspect["cargo_shield_cap"])
		illegalCount = math.max(0, illegalCount - hidden)
		totalCargo = math.max(0, totalCargo - hidden)
	end

	local proportion = illegalCount / math.max(totalCargo, 1)
	local detectionChance = math.min(0.45 + proportion, 1.0)
	local detected = illegalCount > 0 and Engine.rand:Number() < detectionChance

	if suspect:IsPlayer() then
		if detected then
			Comms.ImportantMessage(l.ILLEGAL_GOODS_DETECTED, policeShip.label)
			local newfine = Legal:fine("TRADING_ILLEGAL_GOODS", Game.system.lawlessness)
			newfine = math.floor((newfine * math.max(5000, illegalValue) / 5000) * Engine.rand:Normal(1.0, 0.2))
			Legal:recordPoliceCitation(suspect, "TRADING_ILLEGAL_GOODS", newfine)
			local _, totalFine = PlayerState.GetCrimeOutstanding()
			if totalFine > maxFineTolerated then
				attackShip(suspect)
				Comms.ImportantMessage(l["POLICE_TAUNT_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "POLICE_TAUNT"))], policeShip.label)
			end
		else
			Comms.ImportantMessage(l.NOTHING_DETECTED, policeShip.label)
		end
	elseif detected then
		local bounty = math.floor(1500 + illegalValue * 0.25)
		suspect:SetWanted(true, bounty)
		Comms.ImportantMessage(string.format("Contraband detected aboard %s. Engaging hostile.", suspect:GetLabel()), policeShip.label)
		piracy = true
		attackShip(suspect)
	end
end

local function evaluateCandidateForOfficer(officer, s, xpRequired, policeId, now)
	if not s or not s:exists() or s == officer or s.shipId == policeId then
		return nil, 0
	end
	local fs = s:GetFlightState()
	if fs == "DOCKED" or fs == "LANDED" or fs == "HYPERSPACE" then
		return nil, 0
	end

	local isSC = (fs == "SUPERCRUISE")
	local scSpeed = (isSC and s.GetSupercruiseSpeed) and s:GetSupercruiseSpeed() or 0
	local isFTL = isSC and (scSpeed >= LIGHT_SPEED)
	local xpOn = s.GetTransponder and s:GetTransponder() or true

	-- Perception check: dark FTL ships require forward 65 deg FOV + clear LOS;
	-- all other ships obey standard sensor visibility (LOS + transponder / dark sensor / lock).
	local visible
	if isFTL and not xpOn then
		visible = (officer.CanWitnessDarkFTL and officer:CanWitnessDarkFTL(s)) or (officer.GetLockedShip and officer:GetLockedShip() == s)
	else
		visible = officer.CanSeeShip and officer:CanSeeShip(s)
	end
	if not visible then
		return nil, 0
	end

	local dist = officer:DistanceTo(s)
	local distPenalty = 1.0 + (dist / AU_METERS) * 0.80
	local lawlessness = (Game.system and Game.system.lawlessness) or 0.5

	-- Check warrant when ship identity is readable (transponder ON or <= 1 km sublight)
	local warrantStatus, bounty = Legal.LookupWarrant(s, officer)
	local officerInSC = (officer:GetFlightState() == "SUPERCRUISE")

	-- 1. Active piracy / hostile combat in normal space
	if not officerInSC and not isSC and dist <= lawEnforcedRange and s.GetCurrentAICommand and s:GetCurrentAICommand() == "CMD_KILL" then
		return "wanted", 1000.0 / distPenalty
	end

	-- 2. Known wanted criminal (requires ID via transponder or 1 km hull read)
	if warrantStatus == "WANTED" then
		return "wanted", (600.0 + math.min(300.0, (bounty or 0) / 100.0)) / distPenalty
	end

	-- 3. Dark ship witnessed in a transponder-required system
	if xpRequired and not xpOn then
		local baseDark = 350.0 + (1.0 - lawlessness) * 150.0
		return "dark", baseDark / distPenalty
	end

	-- 4. Standing-based routine cargo scan (normal space, within scan range, scanner equipped)
	if not officerInSC and not isSC and dist <= SCAN_RANGE and (officer["target_scanner_level_cap"] or 0) > 0 then
		local label = s:GetLabel()
		if not recentScans[label] or now >= recentScans[label] then
			recentScans[label] = now + SCAN_COOLDOWN_SEC
			if Engine.rand:Number() < getStandingScanChance(s) then
				return "scan", 120.0 / distPenalty
			end
		end
	end

	return nil, 0
end

local function processOfficerTick(officer, xpRequired, policeId, now)
	if not officer or not officer:exists() then return end
	if officer:GetFlightState() == "DOCKED" or officer:GetFlightState() == "HYPERSPACE" then return end

	local st = patrolState[officer] or { mode = 'lane', lastPort = nil }
	patrolState[officer] = st

	-- Maintain active escort if assigned
	if st.mode == 'escort' then
		local player = Game.player
		if not player or not player:exists() or player:IsDocked() or player:IsLanded() or
			(player.GetTransponder and not player:GetTransponder()) or
			(player.IsWanted and player:IsWanted()) then
			clearOfficerState(officer, st)
			st.mode = 'lane'
			assignSupercruiseRoute(officer)
		elseif officer:DistanceTo(player) > 8000 then
			officer:AIFlyTo(player)
		end
		return
	end

	-- 1. Evaluate active cargo scan completion
	if st.mode == 'scan' and st.scanTarget then
		local t = st.scanTarget
		if not t:exists() or t:IsDocked() or t:GetFlightState() == "SUPERCRUISE" or officer:GetFlightState() == "SUPERCRUISE" then
			clearOfficerState(officer, st)
			st.mode = 'lane'
			assignSupercruiseRoute(officer)
			return
		end
		if officer:DistanceTo(t) <= SCAN_RANGE and now >= (st.scanEndTime or 0) then
			executeCargoScan(officer, t)
			clearOfficerState(officer, st)
			if not target then
				st.mode = 'lane'
				assignSupercruiseRoute(officer)
			end
			return
		elseif officer:DistanceTo(t) > SCAN_RANGE then
			officer:AIFlyTo(t)
		end
	end

	-- 2. Evaluate highest-value visible target across the system (per officer perception)
	local allShips = Space.GetBodies("Ship")
	local bestShip, bestKind, bestScore = nil, nil, 0
	local currentScore = 0

	for _, s in ipairs(allShips) do
		local kind, score = evaluateCandidateForOfficer(officer, s, xpRequired, policeId, now)
		if kind and score > 0 then
			if s == st.lockedTarget then
				currentScore = score
			end
			if score > bestScore then
				bestScore = score
				bestShip = s
				bestKind = kind
			end
		end
	end

	-- Drop old lock if current target became invalid/occluded, or a significantly higher-value target appeared (Scenario 5)
	if st.lockedTarget then
		local t = st.lockedTarget
		if not t:exists() or t:IsDocked() or t:GetFlightState() == "HYPERSPACE" or
			(officer.IsOccludedFrom and officer:IsOccludedFrom(t)) then
			clearOfficerState(officer, st)
			st.mode = 'lane'
			assignSupercruiseRoute(officer)
		elseif bestShip and bestShip ~= t and bestScore > math.max(1.0, currentScore) * 1.35 then
			clearOfficerState(officer, st)
		end
	end

	-- Acquire new target if none locked
	if not st.lockedTarget and bestShip then
		if officer.AcquireSupercruiseLock then
			officer:AcquireSupercruiseLock(bestShip)
		end
		st.lockedTarget = bestShip
		st.targetScore = bestScore
		st.actionKind = bestKind
		st.warnStage = 0
		st.warnDeadline = 0
	end

	-- 3. Act on current locked target
	if st.lockedTarget then
		local t = st.lockedTarget
		local tInSC = (t:GetFlightState() == "SUPERCRUISE")
		local oInSC = (officer:GetFlightState() == "SUPERCRUISE")
		local xpOn = t.GetTransponder and t:GetTransponder() or true

		if st.actionKind == "wanted" then
			if t:IsPlayer() and not piracy then
				Comms.ImportantMessage(string.interp(l["OUTLAW_DETECTED_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "OUTLAW_DETECTED"))], { ship_label = t.label }), officer.label)
			end
			piracy = true
			target = t
			st.mode = 'pursue_wanted'
			if st.pursuedTarget ~= t or (officer.GetCurrentAICommand and officer:GetCurrentAICommand() ~= "CMD_KILL") then
				st.pursuedTarget = t
				officer:AIKill(t)
			end
			return
		end

		if st.actionKind == "dark" and xpRequired then
			if xpOn then
				-- Pilot complied in time! Clear warning without penalty.
				if t:IsPlayer() then
					Event.Queue("onPoliceTransponderWarningCleared")
					Comms.Message("Transponder signal verified. Thank you for your cooperation, commander.", officer.label)
				end
				st.warnStage = 0
				st.warnDeadline = 0
				if not oInSC and not tInSC and (officer["target_scanner_level_cap"] or 0) > 0 then
					st.actionKind = "scan"
					st.mode = 'scan'
					st.scanTarget = t
					st.scanEndTime = now + 3.0
					if t:IsPlayer() then
						Comms.ImportantMessage(l["INITIATE_CARGO_SCAN_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "INITIATE_CARGO_SCAN"))], officer.label)
					end
					t:NotifyScanned(officer, "CARGO")
					officer:AIFlyTo(t)
				else
					clearOfficerState(officer, st)
					st.mode = 'lane'
					assignSupercruiseRoute(officer)
				end
				return
			end

			-- Dark ship still has transponder off: issue 2 warnings (4s each) before citation & interdiction
			if (st.warnStage or 0) == 0 then
				st.warnStage = 1
				st.warnDeadline = now + WARNING_WINDOW_SEC
				st.mode = 'pursue_dark'
				officer:AIFlyTo(t)
				if t:IsPlayer() then
					Comms.ImportantMessage(string.format("Security Patrol %s: Unidentified vessel, your transponder is offline! Activate your transponder immediately (Warning 1/2).", officer.label), officer.label)
					Event.Queue("onPoliceTransponderWarning", officer, 1, st.warnDeadline)
				end
				return
			elseif st.warnStage == 1 and now >= (st.warnDeadline or 0) then
				st.warnStage = 2
				st.warnDeadline = now + WARNING_WINDOW_SEC
				if t:IsPlayer() then
					Comms.ImportantMessage(string.format("Security Patrol %s: Final warning! Activate transponder within %.0f seconds or face interdiction and citation!", officer.label, WARNING_WINDOW_SEC), officer.label)
					Event.Queue("onPoliceTransponderWarning", officer, 2, st.warnDeadline)
				end
				return
			elseif st.warnStage == 2 and now >= (st.warnDeadline or 0) then
				if t:IsPlayer() then
					Event.Queue("onPoliceTransponderWarningCleared")
					local sec = 1.0 - ((Game.system and Game.system.lawlessness) or 0.5)
					Legal:recordPoliceCitation(t, "TRANSPONDER_OFF", nil, officer.label)
					if Game.system and Game.system.faction then
						FactionStanding.Adjust(Game.system.faction, -math.max(2, math.floor(2 + sec * 6)), "Transponder Violation")
					end
				end
				st.warnStage = 3
				if tInSC then
					st.mode = 'interdict_dark'
					st.pursuedTarget = t
					officer:AIKill(t)
				else
					-- Sub-light: close to <= 1 km to read painted hull ID & check warrants, then cargo scan
					if officer:DistanceTo(t) > 950.0 then
						officer:AIFlyTo(t)
					else
						local wStatus = Legal.LookupWarrant(t, officer)
						if wStatus == "WANTED" then
							st.actionKind = "wanted"
							piracy = true
							target = t
							st.pursuedTarget = t
							officer:AIKill(t)
						elseif (officer["target_scanner_level_cap"] or 0) > 0 then
							st.actionKind = "scan"
							st.mode = 'scan'
							st.scanTarget = t
							st.scanEndTime = now + 3.0
							if t:IsPlayer() then
								Comms.ImportantMessage(l["INITIATE_CARGO_SCAN_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "INITIATE_CARGO_SCAN"))], officer.label)
							end
							t:NotifyScanned(officer, "CARGO")
						end
					end
				end
				return
			elseif st.warnStage >= 3 then
				if tInSC then
					st.mode = 'interdict_dark'
					local cmd = officer.GetCurrentAICommand and officer:GetCurrentAICommand() or "CMD_NONE"
					local isInterdicting = officer.IsInterdicting and officer:IsInterdicting()
					if cmd ~= "CMD_KILL" and not isInterdicting then
						if officer.CanSeeShip and officer:CanSeeShip(t) then
							if officer.AcquireSupercruiseLock then officer:AcquireSupercruiseLock(t) end
							st.pursuedTarget = t
							officer:AIKill(t)
						else
							clearOfficerState(officer, st)
							st.mode = 'lane'
							assignSupercruiseRoute(officer)
						end
					end
				else
					if officer:DistanceTo(t) > 950.0 then
						if officer.GetCurrentAICommand and officer:GetCurrentAICommand() ~= "CMD_FLYTO" then
							officer:AIFlyTo(t)
						end
					else
						local wStatus = Legal.LookupWarrant(t, officer)
						if wStatus == "WANTED" then
							st.actionKind = "wanted"
							piracy = true
							target = t
							st.pursuedTarget = t
							officer:AIKill(t)
						elseif (officer["target_scanner_level_cap"] or 0) > 0 then
							st.actionKind = "scan"
							st.mode = 'scan'
							st.scanTarget = t
							st.scanEndTime = now + 3.0
							if t:IsPlayer() then
								Comms.ImportantMessage(l["INITIATE_CARGO_SCAN_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "INITIATE_CARGO_SCAN"))], officer.label)
							end
							t:NotifyScanned(officer, "CARGO")
						end
					end
				end
				return
			end
		end

		if st.actionKind == "scan" and not oInSC and not tInSC then
			st.mode = 'scan'
			st.scanTarget = t
			if (st.scanEndTime or 0) <= 0 then
				st.scanEndTime = now + 3.0
				if t:IsPlayer() then
					Comms.ImportantMessage(l["INITIATE_CARGO_SCAN_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "INITIATE_CARGO_SCAN"))], officer.label)
				end
				t:NotifyScanned(officer, "CARGO")
				officer:AIFlyTo(t)
			end
			return
		end
	end

	-- 4. Optional protective escort for high-standing transponder-on player
	local player = Game.player
	if not activeEscortShip and now >= escortCooldownUntil and player and player:exists() and
		player:GetFlightState() == "FLYING" and officer:GetFlightState() == "FLYING" and
		(not player.GetTransponder or player:GetTransponder()) and
		not (player.IsWanted and player:IsWanted()) and
		Game.system and Game.system.faction and FactionStanding.Get(Game.system.faction) >= 40 and
		officer:DistanceTo(player) <= 25000.0 and Engine.rand:Number() < 0.08 then
		st.mode = 'escort'
		activeEscortShip = officer
		escortCooldownUntil = now + 300.0
		officer:AIFlyTo(player)
		Comms.Message("System Security escort standing by on your wing, commander.", officer.label)
		Event.Queue("onPoliceEscortStatus", true, officer.label)
		return
	end

	-- 5. Resume normal patrol route if idle
	if officer:GetCurrentAICommand() == "CMD_NONE" then
		if st.mode == 'docking' and st.lastPort and st.lastPort:exists() and (st.lastPort.freeDocks or 0) >= 3 then
			officer:AIDockWith(st.lastPort)
		elseif st.lastPort and st.lastPort.type == "STARPORT_ORBITAL" and (st.lastPort.freeDocks or 0) >= 3 and Engine.rand:Number(1) < 0.30 then
			st.mode = 'docking'
			officer:AIDockWith(st.lastPort)
		else
			assignSupercruiseRoute(officer)
		end
	end
end

local function startPatrolHunterTimer()
	if patrolTimerActive then return end
	patrolTimerActive = true
	Timer:CallEvery(2, function ()
		if not Game.system or #patrol == 0 then
			patrolTimerActive = false
			return true
		end
		for i = #patrol, 1, -1 do
			if not patrol[i]:exists() then
				table.remove(patrol, i)
			end
		end
		if #patrol == 0 then
			patrolTimerActive = false
			return true
		end

		if target and (not target:exists() or target:IsDocked()) then
			target = nil
		end
		if target then
			local stillPursuing = false
			for i = 1, #patrol do
				if patrol[i]:GetCurrentAICommand() == "CMD_KILL" then
					stillPursuing = true
					break
				end
			end
			if not stillPursuing then
				target = nil
			end
		end

		local playerLabel = (Game.player and Game.player.label) or ""
		if piracy and not target then
			Comms.ImportantMessage(string.interp(l["RESTRICTIONS_ESTABLISHED_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "RESTRICTIONS_ESTABLISHED"))], { ship_label = playerLabel }), patrol[1].label)
			piracy = false
		end

		local xpRequired = Legal.IsTransponderRequired(Game.system)
		local policeId = Game.system.faction and Game.system.faction.policeShip
		local now = Game.time

		for i = 1, #patrol do
			processOfficerTick(patrol[i], xpRequired, policeId, now)
		end
		return false
	end)
end

local function schedulePatrolUndock(ship, station, delaySec)
	Timer:CallAt(Game.time + delaySec, function ()
		if not Game.system or not ship or not ship:exists() then return end
		if ship:GetFlightState() ~= "DOCKED" then return end
		if target then return end
		local port = ship:GetDockedWith() or station
		if port and port:exists() then
			if not port:CanLaunch(ship) or not ship:Undock() then
				schedulePatrolUndock(ship, port, Engine.rand:Number(8, 16))
				return
			end
			patrolState[ship] = patrolState[ship] or { mode = 'departing', lastPort = port }
			patrolState[ship].mode = 'departing'
			patrolState[ship].lastPort = port
			ship:AIDepart(port)
		end
	end)
end

local onAICompleted = function (ship, ai_error)
	if not ship or not ship:exists() or not patrolState[ship] then return end
	local st = patrolState[ship]
	if st.mode == 'escort' or st.mode == 'scan' or st.mode == 'pursue_dark' then
		return
	end
	if st.mode == 'departing' then
		st.mode = 'lane'
		assignSupercruiseRoute(ship)
	elseif st.mode == 'docking' and ai_error ~= 'NONE' then
		st.mode = 'lane'
		assignSupercruiseRoute(ship)
	elseif not target and ship:GetFlightState() ~= "DOCKED" then
		if st.lastPort and st.lastPort:exists() and st.lastPort.type == "STARPORT_ORBITAL"
			and (st.lastPort.freeDocks or 0) >= 3 and ship:DistanceTo(st.lastPort) < 500000 and Engine.rand:Number(1) < 0.32 then
			st.mode = 'docking'
			ship:AIDockWith(st.lastPort)
		else
			st.mode = 'lane'
			assignSupercruiseRoute(ship)
		end
	end
end

local onInterdictionDrop = function (attacker, victim, submitted)
	if not attacker or not attacker:exists() or not patrolState[attacker] then return end
	local st = patrolState[attacker]
	if st.mode == 'interdict_dark' and victim and victim:exists() then
		-- Police read hull ID within 1 km and scan cargo rather than blindly opening fire on a clean ship
		local wStatus = Legal.LookupWarrant(victim, attacker)
		if wStatus == "WANTED" then
			st.actionKind = "wanted"
			piracy = true
			target = victim
			attacker:AIKill(victim)
		elseif (attacker["target_scanner_level_cap"] or 0) > 0 then
			attacker:CancelAI()
			st.actionKind = "scan"
			st.mode = 'scan'
			st.scanTarget = victim
			st.scanEndTime = Game.time + 3.0
			if victim:IsPlayer() then
				Comms.ImportantMessage(l["INITIATE_CARGO_SCAN_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "INITIATE_CARGO_SCAN"))], attacker.label)
			end
			victim:NotifyScanned(attacker, "CARGO")
			attacker:AIFlyTo(victim)
		else
			attacker:CancelAI()
			clearOfficerState(attacker, st)
			st.mode = 'lane'
			assignSupercruiseRoute(attacker)
		end
	end
end

local onShipUndocked = function (ship, station)
	if not ship or not patrolState[ship] then return end
	if ship:GetCurrentAICommand() ~= "CMD_KILL" then
		patrolState[ship].mode = 'departing'
		patrolState[ship].lastPort = station
		ship:AIDepart(station)
	end
end

local onShipDestroyed = function (ship, attacker)
	if ship:IsPlayer() or attacker == nil then return end

	if ship == target then
		target = nil
	else
		for i = #patrol, 1, -1 do
			if patrol[i] == ship then
				clearOfficerState(ship, patrolState[ship])
				table.remove(patrol, i)
				patrolState[ship] = nil
				if attacker:isa("Ship") and attacker:IsPlayer() then
					showMercy = false
				end
				break
			elseif patrol[i] == attacker then
				Comms.ImportantMessage(l["TARGET_DESTROYED_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "TARGET_DESTROYED"))], attacker.label)
				break
			end
		end
	end
end

local onShipHit = function (ship, attacker)
	if attacker == nil then return end
	if not attacker:isa('Ship') then return end

	local policeId = Game.system.faction.policeShip
	if ship.shipId == policeId and attacker.shipId ~= policeId then
		piracy = true
		attackShip(attacker)
	end
end

local onShipInterdicted = function (ship, attacker)
	if #patrol == 0 or not attacker or not attacker:isa('Ship') then return end
	local policeId = Game.system and Game.system.faction.policeShip
	if attacker.shipId == policeId then return end
	if ship and not (ship.IsWanted and ship:IsWanted()) then
		piracy = true
		attackShip(attacker)
	end
end

local onShipFiring = function (ship)
	if piracy or target then return end
	if ship:IsPlayer() then return end

	local policeId = Game.system.faction.policeShip
	if ship.shipId ~= policeId then
		for i = 1, #patrol do
			if patrol[i]:exists() and patrol[i]:CanSeeShip(ship) and ship:DistanceTo(patrol[i]) <= lawEnforcedRange then
				Comms.ImportantMessage(string.interp(l_ui_core.X_CANNOT_BE_TOLERATED_HERE, { crime = l_ui_core.UNLAWFUL_WEAPONS_DISCHARGE }), patrol[i].label)
				attackShip(ship)
				break
			end
		end
	end
end

local onUnlawfulWeaponsDischarge = function (ship, station)
	if piracy or target then return end
	if not ship or not ship:IsPlayer() then return end

	for i = 1, #patrol do
		if patrol[i] and patrol[i]:exists() and patrol[i]:DistanceTo(ship) <= lawEnforcedRange then
			Comms.ImportantMessage(string.interp(l_ui_core.X_CANNOT_BE_TOLERATED_HERE, { crime = l_ui_core.UNLAWFUL_WEAPONS_DISCHARGE }), patrol[i].label)
			attackShip(ship)
			break
		end
	end
end

local onJettison = function (ship, cargo)
	if not ship:IsPlayer() or Game.system:IsCommodityLegal(cargo.name) then return end

	if #patrol > 0 and showMercy then
		local manifest = ship:GetComponent('CargoManager').commodities
		if not hasIllegalGoods(manifest) then
			Comms.ImportantMessage(l.TAKE_A_HIKE, patrol[1].label)
			for i = 1, #patrol do
				if patrol[i]:exists() then
					patrol[i]:CancelAI()
				end
			end
			target = nil
		end
	end
end

local function spawnAmbientPatrols(system)
	if not system then return end
	local policeId = system.faction and system.faction.policeShip
	if not policeId then return end

	if system.lawlessness < 0.75 and system.population > 0 then
		local stations = system:GetStationPaths()
		if stations and #stations > 0 then
			local desiredPatrols = math.min(10, math.max(3, math.floor((1.0 - system.lawlessness) * 4.5 + #stations * 0.30)))
			local needed = math.max(0, desiredPatrols - #patrol)
			if needed == 0 then return end

			local hubs = getPatrolHubCandidates(Game.player, nil)
			local threat = 20.0 + 30.0 * (1.0 - system.lawlessness)
			local stars = system:GetStars()
			local primaryStar = stars and stars[1]
			for i = 1, needed do
				local hubEntry = (#hubs > 0) and hubs[((i - 1) % #hubs) + 1] or nil
				local stBody = hubEntry and hubEntry.body or Space.GetBody(stations[((i - 1) % #stations) + 1].bodyIndex)
				local stBodyIdx = stBody and stBody.path and stBody.path.bodyIndex or nil
				local pShip
				if stBody and primaryStar and primaryStar.body and stBody ~= primaryStar.body then
					local rec = ShipRegistry.AcquireShipForSystem(system, "POLICE", policeId, { stationBodyIdx = stBodyIdx })
					local patrolTemplate = MissionUtils.ShipTemplates.PolicePatrol:clone {
						shipId = policeId,
						label = rec and rec.label or nil
					}
					local starRadius = math.max(primaryStar.radius or 7e8, 7e8)
					pShip = ShipBuilder.MakeShipOrbit(primaryStar.body, patrolTemplate, threat, starRadius * 3.5, starRadius * 4.5)
					if pShip then
						if rec then
							ShipRegistry.ApplyRecordToShip(pShip, rec)
						end
						local tRatio = 0.15 + 0.70 * ((i - 0.5) / needed)
						Space.PutShipOnRoute(pShip, stBody, tRatio)
						patrolState[pShip] = { mode = 'lane', lastPort = stBody }
						pShip:AIFlyTo(stBody)
					elseif rec then
						ShipRegistry.ReleaseLive(rec.label)
					end
				end
				if pShip then
					equipPoliceLoadout(pShip, system)
					table.insert(patrol, pShip)
				end
			end
			if #patrol > 0 then
				startPatrolHunterTimer()
			end
		end
	end
end

local onEnterSystem = function (player)
	local system = assert(Game.system)
	local policeId = system.faction and system.faction.policeShip
	if not policeId then return end

	spawnAmbientPatrols(system)

	-- Standing-based arrival inspection: high-standing ships are rarely/never scanned,
	-- and dark arrivals outside police sight are not magically scanned.
	if not hasIllegalGoods(Commodities) then return end
	if player.GetTransponder and not player:GetTransponder() then return end

	local scanChance = getStandingScanChance(player)
	if Engine.rand:Number() > scanChance then return end
	if (1 - system.lawlessness) < Engine.rand:Number(1) then return end

	local _, fine = PlayerState.GetCrimeOutstanding()
	local n = 1 + math.floor((1 - system.lawlessness) * (system.population / 3))
	local threat = 10.0 + Engine.rand:Number(10, 50) * system.lawlessness
	local template = MissionUtils.ShipTemplates.PolicePatrol:clone {
		shipId = policeId,
		label = system.faction.policeName
	}

	Timer:CallAt(Game.time + Engine.rand:Integer(5, 10), function ()
		if not Game.system or Game.system.path ~= system.path then return end
		if not player:exists() or (player.GetTransponder and not player:GetTransponder()) then return end

		local leadShip
		for i = 1, n do
			local rec = ShipRegistry.AcquireShipForSystem(system, "POLICE", policeId)
			local unitTemplate = template:clone {
				shipId = policeId,
				label = rec and rec.label or nil
			}
			local ship = ShipBuilder.MakeShipNear(player, unitTemplate, threat, 50, 100)
			assert(ship)
			if rec then
				ShipRegistry.ApplyRecordToShip(ship, rec)
			end
			equipPoliceLoadout(ship, system)
			table.insert(patrol, ship)
			if not leadShip then leadShip = ship end
		end

		if not leadShip then return end
		Timer:CallAt(Game.time + Engine.rand:Integer(4, 7), function ()
			if not Game.system or Game.system.path ~= system.path or not leadShip:exists() then return end
			if not leadShip:CanSeeShip(player) then return end
			if fine > maxFineTolerated then
				Comms.ImportantMessage(string.interp(l["OUTLAW_DETECTED_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "OUTLAW_DETECTED"))], { ship_label = player.label }), leadShip.label)
				showMercy = false
				attackShip(player)
				return
			end
			if player:GetFlightState() == "SUPERCRUISE" then return end
			Comms.ImportantMessage(l["INITIATE_CARGO_SCAN_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "INITIATE_CARGO_SCAN"))], leadShip.label)
			player:NotifyScanned(leadShip, "CARGO")
			Timer:CallAt(Game.time + 3.0, function ()
				if not Game.system or Game.system.path ~= system.path or not leadShip:exists() then return end
				if player:GetFlightState() == "SUPERCRUISE" or leadShip:DistanceTo(player) > SCAN_RANGE then return end
				executeCargoScan(leadShip, player)
			end)
		end)
	end)

	startPatrolHunterTimer()
end

local onLeaveSystem = function (ship)
	patrol = {}
	patrolState = {}
	recentScans = {}
	showMercy = true
	piracy = false
	target = nil
	patrolTimerActive = false
	activeEscortShip = nil
	Event.Queue("onPoliceTransponderWarningCleared")
	Event.Queue("onPoliceEscortStatus", false)
end

local onShipDocked = function (ship, station)
	if not ship or not ship:exists() then return end
	if not ship:IsPlayer() then
		if patrolState[ship] then
			patrolState[ship].mode = 'docked'
			patrolState[ship].lastPort = station
			ship:SetFuelPercent()
			ship:SetHullPercent()
			schedulePatrolUndock(ship, station, Engine.rand:Number(35, 85))
		end
		return
	end
	if activeEscortShip and patrolState[activeEscortShip] then
		clearOfficerState(activeEscortShip, patrolState[activeEscortShip])
		patrolState[activeEscortShip].mode = 'lane'
		assignSupercruiseRoute(activeEscortShip)
	end
	local _, fine = PlayerState.GetCrimeOutstanding()
	if fine > 0 then
		Comms.ImportantMessage("[" .. string.upper(Game.system.faction.policeName) .. " - " ..
			l_ui_core.AUTOMATED_MESSAGE .. "] " .. l_ui_core.OUTSTANDING_FINES .. ": " .. ui.Format.Money(fine))
	end
end

Event.Register("onPlayerDismissPoliceEscort", function()
	if activeEscortShip and patrolState[activeEscortShip] then
		local p = activeEscortShip
		local st = patrolState[p]
		clearOfficerState(p, st)
		st.mode = 'lane'
		assignSupercruiseRoute(p)
		Comms.Message("Understood, commander. Returning to system patrol.", p.label)
	end
	activeEscortShip = nil
	escortCooldownUntil = Game.time + 300.0
end)

local loaded_data

local onGameStart = function ()
	local wasLoaded = loaded_data ~= nil
	if loaded_data then
		patrol = loaded_data.patrol or {}
		patrolState = loaded_data.patrolState or {}
		recentScans = loaded_data.recentScans or {}
		showMercy = loaded_data.showMercy
		piracy = loaded_data.piracy
		target = loaded_data.target
		loaded_data = nil
	end
	for k, _ in pairs(patrolState) do
		if type(k) ~= 'userdata' or not k:exists() then
			patrolState[k] = nil
		end
	end
	for i = #patrol, 1, -1 do
		local p = patrol[i]
		if type(p) ~= 'userdata' or not p:exists() then
			table.remove(patrol, i)
		else
			patrolState[p] = patrolState[p] or { mode = 'lane', lastPort = nil }
			if p:GetFlightState() == "DOCKED" then
				schedulePatrolUndock(p, p:GetDockedWith(), Engine.rand:Number(15, 45))
			end
		end
	end
	if Game.system and ((not wasLoaded and #patrol == 0) or (wasLoaded and #patrol < 2)) then
		spawnAmbientPatrols(Game.system)
	end
	if #patrol > 0 then
		startPatrolHunterTimer()
	end
end

local onGameEnd = function ()
	patrol = {}
	patrolState = {}
	recentScans = {}
	showMercy = true
	piracy = false
	target = nil
	patrolTimerActive = false
	activeEscortShip = nil
end

local serialize = function ()
	return { patrol = patrol, patrolState = patrolState, recentScans = recentScans, showMercy = showMercy, piracy = piracy, target = target }
end

local unserialize = function (data)
	loaded_data = data
end

Event.Register("onEnterSystem", onEnterSystem)
Event.Register("onLeaveSystem", onLeaveSystem)
Event.Register("onShipDocked", onShipDocked)
Event.Register("onShipUndocked", onShipUndocked)
Event.Register("onAICompleted", onAICompleted)
Event.Register("onInterdictionDrop", onInterdictionDrop)
Event.Register("onShipDestroyed", onShipDestroyed)
Event.Register("onShipHit", onShipHit)
Event.Register("onShipInterdicted", onShipInterdicted)
Event.Register("onShipFiring", onShipFiring)
Event.Register("onUnlawfulWeaponsDischarge", onUnlawfulWeaponsDischarge)
Event.Register("onJettison", onJettison)
Event.Register("onGameStart", onGameStart)
Event.Register("onGameEnd", onGameEnd)

Serializer:Register("PolicePatrol", serialize, unserialize)

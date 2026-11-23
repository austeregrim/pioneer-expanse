-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Engine = require 'Engine'
local Equipment = require 'Equipment'
local Game = require 'Game'
local Event = require 'Event'
local Space = require 'Space'
local Commodities = require 'Commodities'
local utils = require 'utils'
local Timer = require 'Timer'
local Serializer = require 'Serializer'

local MissionUtils = require 'modules.MissionUtils'
local ShipBuilder  = require 'modules.MissionUtils.ShipBuilder'
local ShipRegistry = require 'modules.ShipRegistry.ShipRegistry'

local Comms = require 'Comms'

local LIGHT_SPEED = 299792458.0
local MAX_PLAYER_ATTACKERS = 2

local pirates = {}
local planets = {}
local playerSCStartTime = nil
local nextPlayerSCCheckTime = 0
local nextPlayerInterdictTime = 0
local systemBeyondInhabited = false

local function checkBeyondInhabitedSpace()
	if not Game.system then return false end
	local pop = Game.system.population or 0
	local stPaths = Game.system:GetStationPaths()
	if pop > 0 or (stPaths and #stPaths > 0) then
		return false
	end
	local ok, nearby = pcall(function()
		return Game.system:GetNearbySystems(5.0, function(s)
			return (s.population and s.population > 0) or (#s:GetStationPaths() > 0)
		end)
	end)
	if ok and nearby then
		return #nearby == 0
	end
	return false
end

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

local function equipPirateLoadout(ship, threat, isAmbush)
	local interdictorId = (threat >= 35) and "misc.fsd_interdictor_2" or "misc.fsd_interdictor_1"
	local hasInterdictor = installEquipment(ship, interdictorId)
	installEquipment(ship, "misc.target_scanner")
	if threat >= 55 and Engine.rand:Number() < 0.35 then
		installEquipment(ship, "misc.interdiction_nullifier")
	end
	if isAmbush then
		local sensorId = (threat >= 45) and "sensor.sublight_array_2" or "sensor.sublight_array_1"
		installEquipment(ship, sensorId, "sensor.radar")
	end
	if ship.UpdateEquipStats then
		ship:UpdateEquipStats()
	end
	return hasInterdictor
end

local function assignSupercruisePatrol(ship, currentBody)
	local stationCandidates = {}
	local bodyCandidates = {}
	if Game.system then
		local stPaths = Game.system:GetStationPaths()
		if stPaths then
			for _, sp in ipairs(stPaths) do
				local body = Space.GetBody(sp.bodyIndex)
				if body and body ~= currentBody and ship:DistanceTo(body) > 1000000 then
					table.insert(stationCandidates, body)
				end
			end
		end
	end
	for _, path in ipairs(planets) do
		local body = Space.GetBody(path.bodyIndex)
		if body and body ~= currentBody and ship:DistanceTo(body) > 1000000 then
			table.insert(bodyCandidates, body)
		end
	end
	local pool = (#stationCandidates > 0 and Engine.rand:Number(1) < 0.75) and stationCandidates or (#bodyCandidates > 0 and bodyCandidates or stationCandidates)
	if #pool > 0 then
		local dest = pool[Engine.rand:Integer(1, #pool)]
		ship:AIFlyTo(dest)
		return dest
	end
	if #planets > 0 then
		local dest = Space.GetBody(planets[Engine.rand:Integer(1, #planets)].bodyIndex)
		if dest then
			ship:AIFlyTo(dest)
			return dest
		end
	end
	if currentBody then
		ship:AIFlyTo(currentBody)
	end
	return currentBody
end

local function countPlayerHunters()
	local count = 0
	for p, s in pairs(pirates) do
		if p:exists() and s.target == Game.player and
			(s.status == 'ATTACK' or s.status == 'INTERDICT_PLAYER' or s.status == 'SCAN_CARGO' or s.status == 'DEMAND_CARGO') then
			count = count + 1
		end
	end
	return count
end

local pirateIsInterested = function (player)
	if not player or not player:exists() then return false end
	if systemBeyondInhabited then return false end
	local lawlessness = (Game.system and Game.system.lawlessness) or 0.0
	local cargoTons = player.usedCargo or 0
	if lawlessness < 0.15 then
		if cargoTons <= 0 then return false end
		return Engine.rand:Number(1) <= (lawlessness * 0.4 + math.min(0.08, cargoTons * 0.002))
	end
	local baseProb = (lawlessness - 0.10) * 0.65
	local cargoBonus = math.min(0.25, cargoTons * 0.008)
	return Engine.rand:Number(1) <= math.min(0.75, baseProb + cargoBonus)
end

local shouldInterdictPlayerInSC = function (player)
	if not player or not player:exists() then return false end
	if systemBeyondInhabited then return false end
	local lawlessness = (Game.system and Game.system.lawlessness) or 0.0
	local cargoTons = player.usedCargo or 0
	if lawlessness < 0.15 then
		if cargoTons <= 0 then return false end
		local prob = math.min(0.06, lawlessness * 0.25 + math.min(0.04, cargoTons * 0.002))
		return Engine.rand:Number(1) <= prob
	elseif lawlessness < 0.40 then
		local prob = 0.03 + (lawlessness - 0.15) * 0.35 + math.min(0.12, cargoTons * 0.005)
		return Engine.rand:Number(1) <= math.min(0.25, prob)
	else
		local prob = 0.14 + (lawlessness - 0.40) * 0.65 + math.min(0.25, cargoTons * 0.008)
		return Engine.rand:Number(1) <= math.min(0.65, prob)
	end
end

local calculateThreat = function (lawlessness)
	return 10.0 + Engine.rand:Number(100.0 * lawlessness)
end

local function evaluateTargetCargoValue(victim)
	if not victim or not victim:exists() then return 0, 0 end
	local cargoMgr = victim:GetComponent('CargoManager')
	if not cargoMgr then return 0, 0 end
	local totalUnits = 0
	local totalValue = 0
	for name, count in cargoMgr:Commodities() do
		totalUnits = totalUnits + count
		local comm = Commodities[name]
		totalValue = totalValue + (comm and comm.price or 50) * count
	end
	return totalUnits, totalValue
end

local function configurePirateState(ship, hostBody, threat, isAmbush)
	local hasInterdictor = equipPirateLoadout(ship, threat, isAmbush)
	if isAmbush then
		if ship.SetTransponder then ship:SetTransponder(false) end
		if ship.SetSupercruiseSpeedCap then ship:SetSupercruiseSpeedCap(0.60 * LIGHT_SPEED) end
	else
		-- Pirates in policed systems run dark when stalking or below c; otherwise follow normal transit
		if Game.system and Game.system.lawlessness >= 0.40 and ship.SetTransponder then
			ship:SetTransponder(false)
		end
	end
	pirates[ship] = {
		status = isAmbush and 'AMBUSH' or (pirateIsInterested(Game.player) and 'LURK' or 'ORBIT'),
		planet = hostBody,
		hasInterdictor = hasInterdictor,
		isAmbush = isAmbush,
		warned = false,
		target = nil,
		demandDeadline = 0,
		jettisonedUnits = 0,
		requiredJettison = 0,
		cooldownUntil = 0,
	}
end

local function spawnSystemPirates(player)
	if not Game.system then return end
	if systemBeyondInhabited then
		if Engine.rand:Number(1) > 0.002 then return end
	end
	local lawlessness = Game.system.lawlessness
	local population = Game.system.population
	local stationPaths = Game.system:GetStationPaths()

	planets = utils.filter_array(Game.system:GetBodyPaths(),
		function (p)
			local sb = p:GetSystemBody()
			return sb and (sb.superType == 'ROCKY_PLANET' or sb.superType == 'GAS_GIANT')
		end
	)
	if stationPaths then
		for _, sp in ipairs(stationPaths) do
			table.insert(planets, sp)
		end
	end
	if #planets == 0 then
		planets = utils.filter_array(Game.system:GetBodyPaths(),
			function (p)
				local sb = p:GetSystemBody()
				return sb and sb.superType == 'STAR'
			end
		)
	end
	if #planets == 0 then return end

	local orbitalHosts = utils.filter_array(planets, function (p)
		local b = Space.GetBody(p.bodyIndex)
		return b and b.type ~= "STARPORT_SURFACE"
	end)
	if #orbitalHosts == 0 then
		orbitalHosts = utils.filter_array(Game.system:GetBodyPaths(), function (p)
			local sb = p:GetSystemBody()
			return sb and sb.body ~= nil
		end)
	end
	if #orbitalHosts == 0 then return end

	local hasStations = stationPaths and #stationPaths > 0
	local max_pirates
	if lawlessness < 0.15 then
		max_pirates = 1
	elseif lawlessness < 0.40 then
		max_pirates = 2
	else
		max_pirates = math.min(6, 2 + math.floor(lawlessness * 4.0))
	end
	local stars = Game.system:GetStars()
	local primaryStar = stars and stars[1]

	for i = 1, max_pirates do
		local mustSpawn = (i == 1 and lawlessness >= 0.40 and population > 0 and hasStations)
		local spawnChance
		if lawlessness < 0.15 then
			spawnChance = lawlessness * 2.0
		elseif lawlessness < 0.40 then
			spawnChance = 0.20 + lawlessness * 0.70
		else
			spawnChance = math.min(0.90, 0.35 + lawlessness * 0.65)
		end
		if mustSpawn or Engine.rand:Number(1) <= spawnChance then
			local threat = calculateThreat(lawlessness)
			local hostSb = orbitalHosts[Engine.rand:Integer(1, #orbitalHosts)]:GetSystemBody()
			local ship
			local placedOnLane = false
			local isAmbush = hasStations and (lawlessness >= 0.25) and (Engine.rand:Number() < 0.35)
			local rec = ShipRegistry.AcquireShipForSystem(Game.system, "PIRATE")
			local pirateTemplate = MissionUtils.ShipTemplates.GenericPirate:clone {
				label = rec and rec.label or nil
			}
			if hasStations and isAmbush then
				local stPath = stationPaths[Engine.rand:Integer(1, #stationPaths)]
				local stBody = Space.GetBody(stPath.bodyIndex)
				if stBody then
					local minR = math.max((stBody:GetPhysicalRadius() or 1000) + 18000, 22000)
					local maxR = minR + 40000
					ship = ShipBuilder.MakeShipOrbit(stBody, pirateTemplate, threat, minR, maxR)
					if ship then
						ship:AIEnterLowOrbit(stBody)
						placedOnLane = true
					end
				end
			elseif hasStations and (i % 2 == 0) and primaryStar and primaryStar.body then
				local stPath = stationPaths[Engine.rand:Integer(1, #stationPaths)]
				local stBody = Space.GetBody(stPath.bodyIndex)
				if stBody and stBody ~= primaryStar.body then
					local starRadius = math.max(primaryStar.radius or 7e8, 7e8)
					ship = ShipBuilder.MakeShipOrbit(primaryStar.body, pirateTemplate, threat, starRadius * 4.0, starRadius * 8.0)
					if ship then
						Space.PutShipOnRoute(ship, stBody, Engine.rand:Number(0.15, 0.80))
						ship:AIFlyTo(stBody)
						placedOnLane = true
					end
				end
			end
			if not ship and hostSb and hostSb.body then
				local radius = math.max(hostSb.radius or hostSb.body:GetPhysicalRadius() or 6000000, 10000)
				ship = ShipBuilder.MakeShipOrbit(hostSb.body, pirateTemplate, threat, radius * 1.2, radius * 3.5)
			end
			if ship then
				if rec then
					ShipRegistry.ApplyRecordToShip(ship, rec)
				end
				ship:SetWanted(true, math.floor(1500 + threat * 150))
				configurePirateState(ship, hostSb and hostSb.body or nil, threat, isAmbush)
				if not placedOnLane then
					pirates[ship].planet = assignSupercruisePatrol(ship, pirates[ship].planet)
				end
			elseif rec then
				ShipRegistry.ReleaseLive(rec.label)
			end
		end
	end
end

local onEnterSystem = function (player)
	playerSCStartTime = nil
	nextPlayerSCCheckTime = 0
	nextPlayerInterdictTime = 0
	systemBeyondInhabited = checkBeyondInhabitedSpace()
	spawnSystemPirates(player)
end

local onLeaveSystem = function ()
	pirates = {}
	planets = {}
	playerSCStartTime = nil
	nextPlayerSCCheckTime = 0
	nextPlayerInterdictTime = 0
	systemBeyondInhabited = false
end

local onShipHit = function (ship, attacker)
	if pirates[ship] and attacker and attacker:isa('Ship') then
		if pirates[ship].status ~= 'ATTACK' then
			if ship.SetSupercruiseSpeedCap then ship:SetSupercruiseSpeedCap(0) end
			if ship.AcquireSupercruiseLock then ship:AcquireSupercruiseLock(attacker) end
			ship:AIKill(attacker)
			pirates[ship].status = 'ATTACK'
			pirates[ship].target = attacker
		end
	end
end

local onShipDestroyed = function (ship)
	if pirates[ship] then
		pirates[ship] = nil

		if #planets == 0 or not Game.system or systemBeyondInhabited then return end
		local threat = calculateThreat(Game.system.lawlessness)
		local planet = planets[Engine.rand:Integer(1, #planets)]:GetSystemBody()
		local star = planet and planet.nearestJumpable
		if not star or not star.body then return end
		local rec = ShipRegistry.AcquireShipForSystem(Game.system, "PIRATE")
		local pirateTemplate = MissionUtils.ShipTemplates.GenericPirate:clone {
			label = rec and rec.label or nil
		}
		local newPirate = ShipBuilder.MakeShipOrbit(star.body, pirateTemplate, threat, star.radius * 1.2, star.radius * 3.5)
		if newPirate then
			if rec then
				ShipRegistry.ApplyRecordToShip(newPirate, rec)
			end
			newPirate:SetWanted(true, math.floor(1500 + threat * 150))
			configurePirateState(newPirate, planet.body, threat, false)
			assignSupercruisePatrol(newPirate, planet.body)
		elseif rec then
			ShipRegistry.ReleaseLive(rec.label)
		end
	end
end

local onJettison = function (ship, cargo)
	if not ship or not ship:exists() then return end
	for p, s in pairs(pirates) do
		if p:exists() and s.status == 'DEMAND_CARGO' and s.target == ship then
			s.jettisonedUnits = (s.jettisonedUnits or 0) + 1
			if s.jettisonedUnits >= math.max(1, s.requiredJettison or 1) then
				if ship:IsPlayer() then
					Comms.ImportantMessage("Smart choice. Now clear out before I change my mind!", p.label or "Raider")
				end
				p:CancelAI()
				s.status = 'ORBIT'
				s.target = nil
				s.warned = false
				s.cooldownUntil = Game.time + 90.0
				s.planet = assignSupercruisePatrol(p, s.planet)
			end
		end
	end
end

local onInterdictionDrop = function (attacker, victim, submitted)
	if not attacker or not attacker:exists() or not pirates[attacker] then return end
	if not victim or not victim:exists() then return end
	local s = pirates[attacker]
	if attacker.SetSupercruiseSpeedCap then attacker:SetSupercruiseSpeedCap(0) end
	if attacker.AcquireSupercruiseLock then attacker:AcquireSupercruiseLock(victim) end
	attacker:CancelAI()
	s.status = 'SCAN_CARGO'
	s.target = victim
	s.warned = false
	s.demandDeadline = Game.time + 18.0
	s.jettisonedUnits = 0
	attacker:AIFlyTo(victim)
end

local onInterdictionNullified = function (attacker, victim)
	if not attacker or not attacker:exists() or not pirates[attacker] then return end
	local s = pirates[attacker]
	-- Countered attacker retains its target lock during FSD reboot; a second pirate can follow up (tag-team)!
	if attacker.AcquireSupercruiseLock and victim and victim:exists() then
		attacker:AcquireSupercruiseLock(victim)
	end
	if victim and victim:exists() and victim == Game.player and countPlayerHunters() < MAX_PLAYER_ATTACKERS then
		for p2, s2 in pairs(pirates) do
			if p2 ~= attacker and p2:exists() and s2.hasInterdictor and s2.status ~= 'ATTACK' and
				s2.status ~= 'INTERDICT_PLAYER' and p2:GetFlightState() == "SUPERCRUISE" and
				p2:CanSeeShip(victim) and p2:DistanceTo(victim) < 80 * LIGHT_SPEED then
				if p2.AcquireSupercruiseLock then p2:AcquireSupercruiseLock(victim) end
				if p2.SetSupercruiseSpeedCap then p2:SetSupercruiseSpeedCap(0) end
				s2.status = 'INTERDICT_PLAYER'
				s2.target = victim
				if not s2.warned then
					Comms.ImportantMessage("Nice countermeasure — won't save you from my wingmate!", p2.label or "Unknown Contact")
					s2.warned = true
				end
				p2:AIKill(victim)
				break
			end
		end
	end
end

local onPlayerDocked = function ()
	playerSCStartTime = nil
	nextPlayerSCCheckTime = 0
	for p, s in pairs(pirates) do
		if p:exists() and (s.status == 'ATTACK' or s.status == 'INTERDICT_PLAYER' or s.status == 'SCAN_CARGO' or s.status == 'DEMAND_CARGO') then
			if p.ClearSupercruiseLock then p:ClearSupercruiseLock() end
			s.planet = assignSupercruisePatrol(p, s.planet)
		end
		s.status = s.isAmbush and 'AMBUSH' or 'ORBIT'
		s.target = nil
		s.warned = false
	end
end

local onPlayerUndocked = function (player)
	for _, s in pairs(pirates) do
		if not s.isAmbush and pirateIsInterested(player) then
			s.status = 'LURK'
		end
	end
end

local onAICompleted = function (ship, error)
	if not pirates[ship] then return end
	local s = pirates[ship]
	if s.status == 'SCAN_CARGO' or s.status == 'DEMAND_CARGO' or s.status == 'AMBUSH' then
		return
	end
	if error == 'NONE' then
		ship:SetFuelPercent()
	end
	s.status = s.isAmbush and 'AMBUSH' or (pirateIsInterested(Game.player) and 'LURK' or 'ORBIT')
	s.target = nil
	s.warned = false
	s.planet = assignSupercruisePatrol(ship, s.planet)
end

local loaded_data

local onGameStart = function ()
	local wasLoaded = loaded_data ~= nil
	playerSCStartTime = nil
	nextPlayerSCCheckTime = 0
	nextPlayerInterdictTime = (loaded_data and loaded_data.nextPlayerInterdictTime) or 0
	if loaded_data and loaded_data.pirates and loaded_data.planets then
		pirates = loaded_data.pirates
		planets = loaded_data.planets
	end
	loaded_data = nil

	if not wasLoaded and Game.system then
		systemBeyondInhabited = checkBeyondInhabitedSpace()
		spawnSystemPirates(Game.player)
	end

	local threatMessages = {
		"FSD interdiction tether locking on! Cut your throttle and dump your hold!",
		"I've got a bead on your wake signature. Let's see what you're carrying!",
		"Don't bother running — my FSD interdictor is already spinning up!"
	}

	Timer:CallEvery(4, function ()
		if not Game.system or not Game.player or not Game.player:exists() or systemBeyondInhabited then return end
		local policeId = Game.system.faction and Game.system.faction.policeShip
		local allShips = Space.GetBodies("Ship")
		local playerInSC = Game.player:GetFlightState() == "SUPERCRUISE"
		local playerSCSpeed = (playerInSC and Game.player.GetSupercruiseSpeed) and Game.player:GetSupercruiseSpeed() or 0
		local playerIsFTL = playerInSC and (playerSCSpeed >= LIGHT_SPEED)
		local playerXpOn = Game.player.GetTransponder and Game.player:GetTransponder() or true

		if playerIsFTL then
			if not playerSCStartTime then
				playerSCStartTime = Game.time
				nextPlayerSCCheckTime = Game.time + 40.0
			end
		else
			playerSCStartTime = nil
			nextPlayerSCCheckTime = 0
		end
		local playerBusy = playerInSC and Game.player.IsBeingInterdicted and Game.player:IsBeingInterdicted()

		-- 1. Clean up stale hunts and drive sub-light cargo scan / demand state machine
		for p, s in pairs(pirates) do
			if p:exists() then
				if s.status == 'SCAN_CARGO' then
					local v = s.target
					if not v or not v:exists() or v:IsDocked() or v:GetFlightState() == "SUPERCRUISE" or p:GetFlightState() == "SUPERCRUISE" or Game.time > (s.demandDeadline or 0) then
						p:CancelAI()
						s.status = 'ORBIT'
						s.target = nil
						s.planet = assignSupercruisePatrol(p, s.planet)
					elseif p:DistanceTo(v) <= 10000 and (p["target_scanner_level_cap"] or 0) > 0 then
						v:NotifyScanned(p, "CARGO")
						local units, val = evaluateTargetCargoValue(v)
						if units <= 0 or val < 500 then
							if v:IsPlayer() then
								Comms.Message("Empty hold... waste of an FSD pulse. Get lost.", p.label or "Raider")
							end
							p:CancelAI()
							s.status = 'ORBIT'
							s.target = nil
							s.cooldownUntil = Game.time + 90.0
							s.planet = assignSupercruisePatrol(p, s.planet)
						else
							s.status = 'DEMAND_CARGO'
							s.demandDeadline = Game.time + 20.0
							s.jettisonedUnits = 0
							s.requiredJettison = math.max(1, math.min(6, math.floor(units * 0.25)))
							if v:IsPlayer() then
								Comms.ImportantMessage(string.format("Nice haul! Jettison %d tonnes of cargo within 20 seconds or I open fire!", s.requiredJettison), p.label or "Raider")
							end
							p:AIFlyTo(v)
						end
					elseif p:DistanceTo(v) > 10000 then
						p:AIFlyTo(v)
					end
				elseif s.status == 'DEMAND_CARGO' then
					local v = s.target
					if not v or not v:exists() or v:IsDocked() then
						s.status = 'ORBIT'
						s.target = nil
						s.planet = assignSupercruisePatrol(p, s.planet)
					elseif Game.time >= (s.demandDeadline or 0) or v:GetFlightState() == "SUPERCRUISE" then
						if v:IsPlayer() then
							Comms.ImportantMessage("Time's up! Weapons free!", p.label or "Raider")
						end
						s.status = 'ATTACK'
						p:AIKill(v)
					end
				elseif s.status == 'INTERDICT_PLAYER' then
					local tetheredToPlayer = p.GetInterdictionPeer and (p:GetInterdictionPeer() == Game.player)
					if not tetheredToPlayer and (not playerInSC or p:GetFlightState() ~= "SUPERCRUISE") then
						if playerInSC and p:GetFlightState() ~= "SUPERCRUISE" then
							nextPlayerInterdictTime = math.max(nextPlayerInterdictTime, Game.time + 180.0)
						end
						s.status = 'ORBIT'
						s.target = nil
						s.warned = false
						s.planet = assignSupercruisePatrol(p, s.planet)
					end
				elseif s.status == 'ATTACK' and s.target and s.target ~= Game.player and p:GetFlightState() == "SUPERCRUISE" then
					local victimValid = s.target:exists()
					local victimTethered = victimValid and p.GetInterdictionPeer and (p:GetInterdictionPeer() == s.target)
					local victimInSC = victimValid and (s.target:GetFlightState() == "SUPERCRUISE")
					if not victimValid or (not victimTethered and not victimInSC) then
						s.status = 'ORBIT'
						s.target = nil
						s.warned = false
						s.planet = assignSupercruisePatrol(p, s.planet)
					end
				end
			end
		end

		-- 2. Supercruise pursuit of visible FTL player (capped at 2 attackers; never sees dark < 1c player)
		local scGraceElapsed = playerSCStartTime and (Game.time - playerSCStartTime >= 40.0)
		local scCheckDue = Game.time >= nextPlayerSCCheckTime
		local cooldownElapsed = Game.time >= nextPlayerInterdictTime

		if (playerIsFTL or (playerInSC and playerXpOn)) and scGraceElapsed and scCheckDue and cooldownElapsed and
			not playerBusy and countPlayerHunters() < MAX_PLAYER_ATTACKERS then
			nextPlayerSCCheckTime = Game.time + 75.0
			if shouldInterdictPlayerInSC(Game.player) then
				for p, s in pairs(pirates) do
					if p:exists() and s.status ~= 'ATTACK' and s.status ~= 'INTERDICT_PLAYER' and
						s.status ~= 'SCAN_CARGO' and s.status ~= 'DEMAND_CARGO' and s.hasInterdictor ~= false and
						Game.time >= (s.cooldownUntil or 0) then
						local canDetect = p.CanSeeShip and p:CanSeeShip(Game.player)
						if canDetect and (p:GetFlightState() == "SUPERCRUISE" or p:GetFlightState() == "FLYING") then
							if p.SetSupercruiseSpeedCap then p:SetSupercruiseSpeedCap(0) end
							if p.AcquireSupercruiseLock then p:AcquireSupercruiseLock(Game.player) end
							if p:DistanceTo(Game.player) > 120 * LIGHT_SPEED or p:GetFlightState() ~= "SUPERCRUISE" then
								Space.PutShipInSupercruiseBehind(p, Game.player, 35, 65)
							end
							if not s.warned then
								Comms.ImportantMessage(threatMessages[Engine.rand:Integer(1, #threatMessages)], p.label or "Unknown Contact")
								s.warned = true
							end
							s.status = 'INTERDICT_PLAYER'
							s.target = Game.player
							nextPlayerInterdictTime = Game.time + 180.0
							p:AIKill(Game.player)
							break
						end
					end
				end
			end
		end

		-- 3. Sensor-based opportunistic hunting & ambush behavior (no omniscient perception)
		for p, s in pairs(pirates) do
			if p:exists() and (p:GetFlightState() == "SUPERCRUISE" or p:GetFlightState() == "FLYING") and
				Game.time >= (s.cooldownUntil or 0) then
				if s.status == 'AMBUSH' then
					-- Dark ambush near station/lane: wait for any visible victim (above c, transponder on, or inside dark-sensor array)
					for _, victim in ipairs(allShips) do
						if victim ~= p and not pirates[victim] and victim.shipId ~= policeId and
							not victim:IsDocked() and not victim:IsLanded() and not (victim.IsWanted and victim:IsWanted()) and
							(not victim:IsPlayer() or countPlayerHunters() < MAX_PLAYER_ATTACKERS) and
							(p.CanSeeShip and p:CanSeeShip(victim)) then
							local dist = p:DistanceTo(victim)
							if p:GetFlightState() == victim:GetFlightState() and dist < 120000 then
								if p.AcquireSupercruiseLock then p:AcquireSupercruiseLock(victim) end
								if victim:IsPlayer() then
									Comms.ImportantMessage("Ambush sprung! Cut engines and prepare to be scanned!", p.label or "Unknown Contact")
								end
								s.status = (p:GetFlightState() == "FLYING") and 'SCAN_CARGO' or 'ATTACK'
								s.target = victim
								s.demandDeadline = Game.time + 18.0
								if s.status == 'SCAN_CARGO' then
									p:AIFlyTo(victim)
								else
									p:AIKill(victim)
								end
								break
							end
						end
					end
				elseif s.status ~= 'ATTACK' and s.status ~= 'INTERDICT_PLAYER' and s.status ~= 'SCAN_CARGO' and s.status ~= 'DEMAND_CARGO' then
					if p.GetCurrentAICommand and p:GetCurrentAICommand() == "CMD_NONE" then
						s.status = pirateIsInterested(Game.player) and 'LURK' or 'ORBIT'
						s.target = nil
						s.planet = assignSupercruisePatrol(p, s.planet)
					elseif not playerInSC and s.status == 'LURK' and
						(p.CanSeeShip and p:CanSeeShip(Game.player)) and
						p:DistanceTo(Game.player) < 100000 and
						p:GetFlightState() == Game.player:GetFlightState() and
						countPlayerHunters() < MAX_PLAYER_ATTACKERS then
						if p.AcquireSupercruiseLock then p:AcquireSupercruiseLock(Game.player) end
						s.status = 'SCAN_CARGO'
						s.target = Game.player
						s.demandDeadline = Game.time + 18.0
						p:AIFlyTo(Game.player)
					elseif p:GetFlightState() == "SUPERCRUISE" then
						for _, victim in ipairs(allShips) do
							if victim ~= p and victim ~= Game.player and not pirates[victim] and victim.shipId ~= policeId and
								not (victim.IsWanted and victim:IsWanted()) and
								(p.CanSeeShip and p:CanSeeShip(victim)) then
								local victimSpeed = (victim.GetSupercruiseSpeed and victim:GetSupercruiseSpeed()) or 0
								if victim:GetFlightState() == "SUPERCRUISE" and (victimSpeed >= LIGHT_SPEED or (victim.GetTransponder and victim:GetTransponder())) then
									if p:DistanceTo(victim) < 1.8e10 then
										if p.AcquireSupercruiseLock then p:AcquireSupercruiseLock(victim) end
										p:AIKill(victim)
										s.status = 'ATTACK'
										s.target = victim
										break
									end
								end
							end
						end
					end
				end
			end
		end
	end)
end

local onGameEnd = function ()
	pirates = {}
	planets = {}
	playerSCStartTime = nil
	nextPlayerSCCheckTime = 0
	nextPlayerInterdictTime = 0
end

local serialize = function ()
	return { pirates = pirates, planets = planets, nextPlayerInterdictTime = nextPlayerInterdictTime }
end

local unserialize = function (data)
	loaded_data = data
end

Event.Register("onEnterSystem", onEnterSystem)
Event.Register("onLeaveSystem", onLeaveSystem)
Event.Register("onShipHit", onShipHit)
Event.Register("onShipDestroyed", onShipDestroyed)
Event.Register("onJettison", onJettison)
Event.Register("onInterdictionDrop", onInterdictionDrop)
Event.Register("onInterdictionNullified", onInterdictionNullified)
Event.Register("onPlayerDocked", onPlayerDocked)
Event.Register("onPlayerUndocked", onPlayerUndocked)
Event.Register("onAICompleted", onAICompleted)
Event.Register("onGameStart", onGameStart)
Event.Register("onGameEnd", onGameEnd)

Serializer:Register("Pirates", serialize, unserialize)

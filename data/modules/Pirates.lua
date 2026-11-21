-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Engine = require 'Engine'
local Equipment = require 'Equipment'
local Game = require 'Game'
local Event = require 'Event'
local ShipDef = require 'ShipDef'
local Space = require 'Space'
local utils = require 'utils'
local Timer = require 'Timer'
local Serializer = require 'Serializer'

local MissionUtils = require 'modules.MissionUtils'
local ShipBuilder  = require 'modules.MissionUtils.ShipBuilder'
local ShipRegistry = require 'modules.ShipRegistry.ShipRegistry'

local Comms = require 'Comms'

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

local function equipInterdictor(ship, threat)
	local equipSet = ship:GetComponent("EquipSet")
	local proto = (threat >= 35 and Equipment.Get("misc.fsd_interdictor_2")) or Equipment.Get("misc.fsd_interdictor_1")
	if not equipSet or not proto then return false end
	local inst = proto:Instance()
	local slot = equipSet:GetFreeSlotForEquip(inst)
	if slot then
		equipSet:Install(inst, slot)
		return true
	end
	return false
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
	-- Prefer stalking active station shipping lanes where trade traffic concentrates
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

local pirateIsInterested = function (player)
	if not player or not player:exists() then return false end
	if systemBeyondInhabited then return false end
	local lawlessness = (Game.system and Game.system.lawlessness) or 0.0
	local cargoTons = player.usedCargo or 0
	-- In high-security systems (lawlessness < 0.15), pirates rarely ambush in normal space
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
	-- Simple threat calculation based on lawlessness factor and independent of the player's current state.
	-- This will likely not produce an assailant larger than a Deneb.
	return 10.0 + Engine.rand:Number(100.0 * lawlessness)
end

local enterOrbit = function (ship, planet)
	local orbit = {
		function () ship:AIEnterLowOrbit(planet) end,
		function () ship:AIEnterMediumOrbit(planet) end,
		function () ship:AIEnterHighOrbit(planet) end,
	}
	orbit[Engine.rand:Integer(1,3)]()
end

local function spawnSystemPirates(player)
	if not Game.system then return end
	if systemBeyondInhabited then
		-- >5ly beyond inhabited space: malicious NPCs are virtually non-existent (0.2% rare chance)
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
			local rec = ShipRegistry.AcquireShipForSystem(Game.system, "PIRATE")
			local pirateTemplate = MissionUtils.ShipTemplates.GenericPirate:clone {
				label = rec and rec.label or nil
			}
			if hasStations and (i % 2 == 0) and primaryStar and primaryStar.body then
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
				local hasInterdictor = equipInterdictor(ship, threat)
				pirates[ship] = {
					status = pirateIsInterested(player) and 'LURK' or 'ORBIT',
					planet = hostSb and hostSb.body or nil,
					hasInterdictor = hasInterdictor,
					warned = false,
					target = nil
				}
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
			ship:AIKill(attacker)
			pirates[ship].status = 'ATTACK'
			pirates[ship].target = attacker
		end
	end
end

local onShipDestroyed = function (ship)
	if pirates[ship] then
		pirates[ship] = nil

		-- Spawn a new pirate
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
			local hasInterdictor = equipInterdictor(newPirate, threat)

			pirates[newPirate] = { status = 'ORBIT', planet = planet.body, hasInterdictor = hasInterdictor, warned = false, target = nil }
			assignSupercruisePatrol(newPirate, planet.body)
		elseif rec then
			ShipRegistry.ReleaseLive(rec.label)
		end
	end
end

local onPlayerDocked = function ()
	playerSCStartTime = nil
	nextPlayerSCCheckTime = 0
	for p, s in pairs(pirates) do
		if p:exists() and (s.status == 'ATTACK' or s.status == 'INTERDICT_PLAYER') then
			s.planet = assignSupercruisePatrol(p, s.planet)
		end
		s.status = 'ORBIT'
		s.target = nil
		s.warned = false
	end
end

local onPlayerUndocked = function (player)
	for _, s in pairs(pirates) do
		-- The player may have new cargo
		if pirateIsInterested(player) then
			s.status = 'LURK'
		end
	end
end

local onAICompleted = function (ship, error)
	if pirates[ship] and error == 'NONE' then
		ship:SetFuelPercent()
		pirates[ship].status = pirateIsInterested(Game.player) and 'LURK' or 'ORBIT'
		pirates[ship].target = nil
		pirates[ship].warned = false
		pirates[ship].planet = assignSupercruisePatrol(ship, pirates[ship].planet)
	elseif pirates[ship] and (pirates[ship].status == 'ATTACK' or pirates[ship].status == 'INTERDICT_PLAYER') then
		pirates[ship].status = 'ORBIT'
		pirates[ship].target = nil
		pirates[ship].warned = false
		pirates[ship].planet = assignSupercruisePatrol(ship, pirates[ship].planet)
	end
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

	local LIGHT_SPEED = 299792458.0
	local threatMessages = {
		"FSD interdiction tether locking on! Cut your throttle and dump your hold!",
		"I've got a bead on your wake signature. Let's see what you're carrying!",
		"Don't bother running — my FSD interdictor is already spinning up!"
	}

	Timer:CallEvery(8, function ()
		if not Game.system or not Game.player or not Game.player:exists() or systemBeyondInhabited then return end
		local policeId = Game.system.faction and Game.system.faction.policeShip
		local allShips = Space.GetBodies("Ship")
		local playerInSC = Game.player:GetFlightState() == "SUPERCRUISE"
		if playerInSC then
			if not playerSCStartTime then
				playerSCStartTime = Game.time
				nextPlayerSCCheckTime = Game.time + 40.0
			end
		else
			playerSCStartTime = nil
			nextPlayerSCCheckTime = 0
		end
		local playerBusy = playerInSC and Game.player.IsBeingInterdicted and Game.player:IsBeingInterdicted()

		-- Check if a pirate is already actively hunting/interdicting the player,
		-- and clean up any pirate whose interdiction attempt already ended
		local playerHunterActive = false
		for p, s in pairs(pirates) do
			if p:exists() and (s.status == 'INTERDICT_PLAYER' or s.status == 'ATTACK') then
				if s.status == 'INTERDICT_PLAYER' and playerInSC and p:GetFlightState() ~= "SUPERCRUISE" then
					-- Pirate dropped out of Supercruise (e.g. player evaded interdiction)
					s.status = 'ORBIT'
					s.target = nil
					s.warned = false
					nextPlayerInterdictTime = math.max(nextPlayerInterdictTime, Game.time + 180.0)
					s.planet = assignSupercruisePatrol(p, s.planet)
				elseif s.target == Game.player or (p.GetInterdictionPeer and p:GetInterdictionPeer() == Game.player) then
					playerHunterActive = true
				end
			end
		end

		-- Require at least 40s in Supercruise, evaluate at most once per 75s, and respect 180s post-interdiction cooldown
		local scGraceElapsed = playerSCStartTime and (Game.time - playerSCStartTime >= 40.0)
		local scCheckDue = Game.time >= nextPlayerSCCheckTime
		local cooldownElapsed = Game.time >= nextPlayerInterdictTime

		-- Actively pursue and interdict the player when flying in Supercruise
		if playerInSC and scGraceElapsed and scCheckDue and cooldownElapsed and not playerBusy and not playerHunterActive then
			nextPlayerSCCheckTime = Game.time + 75.0
			local wantPlayerAmbush = shouldInterdictPlayerInSC(Game.player)
			if wantPlayerAmbush then
				for p, s in pairs(pirates) do
					if p:exists() and s.status ~= 'ATTACK' and s.status ~= 'INTERDICT_PLAYER' and s.hasInterdictor ~= false then
						if p:GetFlightState() == "SUPERCRUISE" or p:GetFlightState() == "FLYING" then
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

		-- Stalk and interdict passing Supercruise trade traffic for remaining idle pirates
		for p, s in pairs(pirates) do
			if p:exists() and s.status ~= 'ATTACK' and s.status ~= 'INTERDICT_PLAYER' then
				if not playerInSC and s.status == 'LURK' and p:DistanceTo(Game.player) < 2.5e10 and p:GetFlightState() == Game.player:GetFlightState() then
					p:AIKill(Game.player)
					s.status = 'ATTACK'
					s.target = Game.player
				elseif p:GetFlightState() == "SUPERCRUISE" then
					for _, victim in ipairs(allShips) do
						if victim ~= p and victim ~= Game.player and not pirates[victim] and victim.shipId ~= policeId then
							if victim:GetFlightState() == "SUPERCRUISE" and not (victim.IsWanted and victim:IsWanted()) then
								if p:DistanceTo(victim) < 1.8e10 then
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
Event.Register("onPlayerDocked", onPlayerDocked)
Event.Register("onPlayerUndocked", onPlayerUndocked)
Event.Register("onAICompleted", onAICompleted)
Event.Register("onGameStart", onGameStart)
Event.Register("onGameEnd", onGameEnd)

Serializer:Register("Pirates", serialize, unserialize)


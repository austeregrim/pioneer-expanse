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

local pirates = {}
local planets = {}

local function equipInterdictor(ship, threat)
	local equipSet = ship:GetComponent("EquipSet")
	local proto = (threat >= 35 and Equipment.Get("misc.fsd_interdictor_2")) or Equipment.Get("misc.fsd_interdictor_1")
	if not equipSet or not proto then return end
	local inst = proto:Instance()
	local slot = equipSet:GetFreeSlotForEquip(inst)
	if slot then
		equipSet:Install(inst, slot)
	end
end

local function assignSupercruisePatrol(ship, currentPlanet)
	if #planets > 1 then
		local dest = planets[Engine.rand:Integer(1, #planets)]:GetSystemBody()
		if dest and dest.body and dest.body ~= currentPlanet then
			ship:AIFlyTo(dest.body)
			return dest.body
		end
	end
	if currentPlanet then
		ship:AIFlyTo(currentPlanet)
	end
	return currentPlanet
end

local pirateIsInterested = function (player)
	-- pirates know how big cargo hold the ship model has
	local playerCargoCapacity = ShipDef[player.shipId].equipCapacity

	-- Pirate attack probability proportional to how fully loaded cargo hold is.
	local discount = 2 		-- discount on 2t for small ships.
	return Engine.rand:Number(1) <= math.floor(player.usedCargo - discount) / math.max(1,  playerCargoCapacity - discount) and true or false
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

local onEnterSystem = function (player)
	local lawlessness = Game.system.lawlessness
	local population = Game.system.population

	planets = utils.filter_array(Game.system:GetBodyPaths(),
		function (p) return p:GetSystemBody().superType == 'ROCKY_PLANET' and p:GetSystemBody().population > 0 end
	)
	if #planets == 0 then
		planets = utils.filter_array(Game.system:GetBodyPaths(),
			function (p)
				local sb = p:GetSystemBody()
				return sb.superType == 'ROCKY_PLANET' or sb.superType == 'GAS_GIANT'
			end
		)
	end
	if #planets == 0 then return end

	local max_pirates = math.min(5, math.max(1, math.floor(1.0 + lawlessness * 4.0 + math.sqrt(population * #planets))))
	local spawnChance = math.min(0.95, 0.35 + lawlessness * 0.75)

	while max_pirates > 0 do
		max_pirates = max_pirates-1

		if Engine.rand:Number(1) < spawnChance then
			local threat = calculateThreat(lawlessness)
			local planet = planets[Engine.rand:Integer(1, #planets)]:GetSystemBody()
			if planet and planet.body then
				local ship = ShipBuilder.MakeShipOrbit(planet.body, MissionUtils.ShipTemplates.GenericPirate, threat, planet.radius * 1.2, planet.radius * 3.5)
				if ship then
					ship:SetWanted(true, math.floor(1500 + threat * 150))
					equipInterdictor(ship, threat)

					if pirateIsInterested(player) then
						pirates[ship] = { status = 'LURK', planet = planet.body }
					else
						pirates[ship] = { status = 'ORBIT', planet = planet.body }
					end
					assignSupercruisePatrol(ship, planet.body)
				end
			end
		end
	end
end

local onLeaveSystem = function ()
	pirates = {}
	planets = {}
end

local onShipHit = function (ship, attacker)
	if pirates[ship] and attacker and attacker:isa('Ship') then
		if pirates[ship].status ~= 'ATTACK' then
			ship:AIKill(attacker)
			pirates[ship].status = 'ATTACK'
		end
	end
end

local onShipDestroyed = function (ship)
	if pirates[ship] then
		pirates[ship] = nil

		-- Spawn a new pirate
		local threat = calculateThreat(Game.system.lawlessness)
		local planet = planets[Engine.rand:Integer(1, #planets)]:GetSystemBody()
		local star = planet.nearestJumpable
		local newPirate = ShipBuilder.MakeShipOrbit(star.body, MissionUtils.ShipTemplates.GenericPirate, threat, star.radius * 1.2, star.radius * 3.5)
		newPirate:SetWanted(true, math.floor(1500 + threat * 150))
		equipInterdictor(newPirate, threat)

		pirates[newPirate] = { status = 'ORBIT', planet = planet.body }
		assignSupercruisePatrol(newPirate, planet.body)
	end
end

local onPlayerDocked = function ()
	for p, s in pairs(pirates) do
		if s.status == 'ATTACK' then
			enterOrbit(p, s.planet)
		end
		s.status = 'ORBIT'
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
		pirates[ship].planet = assignSupercruisePatrol(ship, pirates[ship].planet)
	end
end

local loaded_data

local onGameStart = function ()
	if loaded_data and loaded_data.pirates and loaded_data.planets then
		pirates = loaded_data.pirates
		planets = loaded_data.planets
	end
	loaded_data = nil

	Timer:CallEvery(20, function ()
		if not Game.system then return end
		local policeId = Game.system.faction.policeShip
		local allShips = Space.GetBodies("Ship")
		for p, s in pairs(pirates) do
			if p:exists() and s.status ~= 'ATTACK' then
				if s.status == 'LURK' and p:DistanceTo(Game.player) < 2.5e10 then
					p:AIKill(Game.player)
					s.status = 'ATTACK'
				elseif p:GetFlightState() == "SUPERCRUISE" then
					-- Stalk and interdict passing Supercruise trade traffic
					for _, victim in ipairs(allShips) do
						if victim ~= p and victim ~= Game.player and not pirates[victim] and victim.shipId ~= policeId then
							if victim:GetFlightState() == "SUPERCRUISE" and not (victim.IsWanted and victim:IsWanted()) then
								if p:DistanceTo(victim) < 1.8e10 then
									p:AIKill(victim)
									s.status = 'ATTACK'
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
end

local serialize = function ()
	return { pirates = pirates, planets = planets }
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


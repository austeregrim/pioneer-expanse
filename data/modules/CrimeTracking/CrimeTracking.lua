-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event = require 'Event'
local Game = require 'Game'
local Engine = require 'Engine'
local Timer = require 'Timer'
local Serializer = require 'Serializer'
local Legal = require 'Legal'
local PlayerState = require 'PlayerState'
local Comms = require 'Comms'
local pigui = require 'pigui'

-- Fine at which police will launch and hunt down outlaw player
-- This is the level above which the player counts as a criminal
-- in data/libs/PlayerState.lua
local maxFineTolerated = 5500

-- store which station sent them out
local policeDispatched = false

-- Weapons discharge warning tracking
local weaponsWarningGiven = false
local weaponsWarningTime = 0
local lastDischargeReportTime = 0
local lastDischargeTime = 0
local WARNING_COOLDOWN_DURATION = 3.0 -- 3s grace cooldown allowing accidental shots
local SUBSEQUENT_REPORT_INTERVAL = 3.0 -- report subsequent discharges once every 3s
local WARNING_RESET_INTERVAL = 30.0 -- if player stops firing for 30s, reset warning status

-- check if we should dispatch police, or call them back
local function doLawAndOrder ()
	if Game.player.flightState == "HYPERSPACE" then return end

	local crimes, fine = PlayerState.GetCrimeOutstanding()
	if Game.player and Game.player.SetWanted then
		Game.player:SetWanted(fine > maxFineTolerated, fine)
	end
	if not policeDispatched then
		if fine > maxFineTolerated and
		Game.player.flightState == "FLYING" and
		Engine.rand:Integer(0,1) > Game.system.lawlessness then
			local station = Game.player:FindNearestTo("SPACESTATION")
			-- check that station exists, since apparently empty systems can have lawlessness > 0
			if station and station.lawEnforcedRange >= station:DistanceTo(Game.player) then
				station:LaunchPolice(Game.player)
				policeDispatched = station
			end
			return
		end
	end

	-- if police are out flying about, check if they should land
	-- Note: If player docks police will land.
	if policeDispatched then
		if fine < maxFineTolerated or
		Game.player.flightState == "DOCKED" or Game.player.flightState == "DOCKING" then
			policeDispatched:LandPolice()
			policeDispatched = false
		end
	end

end


local loaded_data

local onGameStart = function ()
	if (loaded_data) then
		policeDispatched = loaded_data.policeDispatched
	end
	loaded_data = nil
	Timer:CallEvery(5, doLawAndOrder)
end


local serialize = function ()
	local data = {
		policeDispatched = policeDispatched,
	}
	return data
end


local unserialize = function (data)
	loaded_data = data
end


local onJettison = function(ship, cargo)
	if ship:IsPlayer() then
		if cargo.price <= 0 or not Game.system:IsCommodityLegal(cargo.name) then
			Legal:notifyOfCrime(ship,"DUMPING")
		end
	end
end


local onShipHit = function(ship, attacker)
	if attacker and attacker:IsPlayer() then
		Legal:notifyOfCrime(attacker,"PIRACY")
	end
end

local onShipInterdicted = function(ship, attacker)
	if attacker and attacker:IsPlayer() and ship and not (ship.IsWanted and ship:IsWanted()) then
		local system = Game.system
		if system and system.population > 0 and system.lawlessness < 0.85 then
			local _, fineBefore = PlayerState.GetCrimeOutstanding()
			Legal:notifyOfCrime(attacker, "PIRACY")
			local _, fineAfter = PlayerState.GetCrimeOutstanding()
			if fineAfter == fineBefore then
				local newFine = Legal:fine("PIRACY", system.lawlessness)
				PlayerState.AddCrime("PIRACY", newFine)
				fineAfter = fineBefore + newFine
			end
			if Game.player and Game.player.SetWanted then
				Game.player:SetWanted(fineAfter > maxFineTolerated, fineAfter)
			end
		end
	end
end


local onShipDestroyed = function(ship, attacker)
	-- Note: crash issue #887, this _should_ no longer trigger crash.
	-- Also, attacker can be a body, which does not have an IsPlayer()
	if attacker and attacker:isa("Ship") and attacker:IsPlayer() then
		Legal:notifyOfCrime(attacker,"MURDER")
	end
end


local onShipFiring = function(ship)
	if not ship:IsPlayer() then return end

	local station = Game.player:FindNearestTo("SPACESTATION")
	if not station then return end
	if station.lawEnforcedRange < station:DistanceTo(Game.player) then return end

	local now = Game.time

	-- If ceasefire has lasted more than WARNING_RESET_INTERVAL, reset warning state
	if weaponsWarningGiven and (now - lastDischargeTime > WARNING_RESET_INTERVAL) then
		weaponsWarningGiven = false
		weaponsWarningTime = 0
		lastDischargeReportTime = 0
	end
	lastDischargeTime = now

	-- Case 1: First accidental fire / warning not yet given
	if not weaponsWarningGiven then
		weaponsWarningGiven = true
		weaponsWarningTime = now
		lastDischargeReportTime = now
		pigui.playSfx("notify_beep", 1.0, 1.0)
		Comms.ImportantMessage(
			string.format("Traffic Control: Vessel \"%s\", cease weapons discharge immediately within station control perimeter! Stand down.", ship:GetLabel()),
			station.label
		)
		return
	end

	-- Case 2: Within 3s grace cooldown window following the warning
	if (now - weaponsWarningTime) < WARNING_COOLDOWN_DURATION then
		-- Grace cooldown active: player is permitted a few accidental shots without fine or police attack
		return
	end

	-- Case 3: Past 3s grace cooldown - player continues firing!
	if (now - lastDischargeReportTime) >= SUBSEQUENT_REPORT_INTERVAL then
		lastDischargeReportTime = now
		pigui.playSfx("notify_beep", 1.0, 1.0)
		Legal:notifyOfCrime(ship, "WEAPONS_DISCHARGE")
		Event.Queue("onUnlawfulWeaponsDischarge", ship, station)
	end
end


local unlawfulDischargeECM = function(ship)
	if ship:IsPlayer() then
		Legal:notifyOfCrime(ship,"ECM_DISCHARGE")
	end
end


local onLeaveSystem = function(ship)
	-- if we leave the system, the space station object will be invalid
	policeDispatched = nil
	weaponsWarningGiven = false
	weaponsWarningTime = 0
	lastDischargeReportTime = 0
	lastDischargeTime = 0

	if not ship:IsHyperjumpAllowed() then
		Legal:notifyOfCrime(ship,"ILLEGAL_JUMP")
	end
end


local onGameEnd = function ()
	policeDispatched = nil
	weaponsWarningGiven = false
	weaponsWarningTime = 0
	lastDischargeReportTime = 0
	lastDischargeTime = 0
end


Event.Register("onShipHit", onShipHit)
Event.Register("onShipInterdicted", onShipInterdicted)
Event.Register("onShipDestroyed", onShipDestroyed)
Event.Register("onShipFiring", onShipFiring)
Event.Register("unlawfulDischargeECM", unlawfulDischargeECM)
Event.Register("onJettison", onJettison)
Event.Register("onGameStart", onGameStart)
Event.Register("onGameEnd", onGameEnd)
Event.Register("onLeaveSystem", onLeaveSystem)


Serializer:Register("CrimeTracking", serialize, unserialize)

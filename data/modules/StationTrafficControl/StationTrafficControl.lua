-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event = require 'Event'
local Game = require 'Game'
local Engine = require 'Engine'
local Timer = require 'Timer'
local Serializer = require 'Serializer'
local Comms = require 'Comms'
local Space = require 'Space'
local Lang = require 'Lang'

local l = Lang.GetResource("module-stationtrafficcontrol")
local ui = require 'pigui'

local MissionUtils = require 'modules.MissionUtils'

-- The game usually start at a station but may start in space by providing a system
-- path, either via the command line or in the game menu via a custom start option.
-- In the most common case in a new game, where we start at a station, we are in a
-- controlled space and this is set in the onGameStart() function.
-- In the case of a saved game, serialized data already has the value.
local playerInControlledSpace = false

local enteringFlavors = MissionUtils.getNumberOfFlavours(l, "YOU_ARE_ENTERING_STATION_SPACE")
local leavingFlavors = MissionUtils.getNumberOfFlavours(l, "YOU_ARE_LEAVING_STATION_SPACE")
local function notifyControlledSpace ()
	if Game.player.flightState == "HYPERSPACE" then
		playerInControlledSpace = false
		return
	end

	if Game.player.flightState == "FLYING" then
		local station = Game.player:FindNearestTo("SPACESTATION")
		if station then
			if station:DistanceTo(Game.player) < station.lawEnforcedRange then
				if not playerInControlledSpace then
					playerInControlledSpace = true
					local message = l["YOU_ARE_ENTERING_STATION_SPACE_" .. Engine.rand:Integer(1, enteringFlavors)]
					Comms.Message(string.interp(message, { station = station.label, playerShipLabel = Game.player:GetLabel() }))
				end
			else
				if playerInControlledSpace then
					playerInControlledSpace = false
					local message = l["YOU_ARE_LEAVING_STATION_SPACE_" .. Engine.rand:Integer(1, leavingFlavors)]
					Comms.Message(string.interp(message, { station = station.label, playerShipLabel = Game.player:GetLabel() }))
				end
			end
		end
	end

end

local function getAtmoState(station)
	local parent_systemBody = station.path:GetSystemBody().parent
	local parent_frameBody = Space.GetBody(parent_systemBody.index)
	local gravity, pressure = parent_systemBody.gravity, parent_systemBody.hasAtmosphere and parent_frameBody:GetAtmosphericState(station)
	return gravity / 9.8, parent_systemBody.hasAtmosphere, pressure
end

local function onDockingClearanceGranted(station, ship)
	if ship ~= Game.player then
		if Game.player:GetDockedWith() == station or (Game.player:exists() and station:exists() and Game.player:DistanceTo(station) < 25000) then
			local bayNum = station:GetAssignedBayNumber(ship)
			if bayNum >= 0 then
				Comms.Message(string.format("Traffic Control: Inbound vessel %s cleared for docking approach to Pad %d.", ship:GetLabel(), bayNum + 1), station.label)
			end
		end
		return
	end
	local bayNum = station:GetAssignedBayNumber(ship)
	local nearby = station:GetNearbyTraffic(50000) -- 50km
	local gravity, hasAtmo, pressure = getAtmoState(station)

	Comms.Message(l.CLEARANCE_GRANTED_BAY_N:interp({ bay = station:GetAssignedBayNumber(ship) + 1 }), station.label)

	local conditionMessage = ""
	if station.type == "STARPORT_SURFACE" then
		if hasAtmo and pressure > 0.01 then
			conditionMessage = l.STATION_GRAV_PRESS:interp({
				grav = ui.Format.Gravity(gravity),
				press = ui.Format.Pressure(pressure)})
		else
			conditionMessage = l.STATION_GRAV:interp({ grav = ui.Format.Gravity(gravity) })
		end
	end

	if nearby > 0 then conditionMessage = conditionMessage .. " " .. l.WATCH_FOR_TRAFFIC_ON_APPROACH end
	if #conditionMessage > 0 then Comms.Message(conditionMessage, station.label) end
end

local function onShipUndocked(ship, station)
	if not station or not ship or ship == Game.player then return end
	if Game.player:GetDockedWith() == station or (Game.player:exists() and station:exists() and Game.player:DistanceTo(station) < 25000) then
		local isSurface = (station.type == "STARPORT_SURFACE")
		local corridorName = isSurface and "Air space" or "Airlock corridor"
		Comms.Message(string.format("Traffic Control: Outbound vessel %s cleared for departure. %s active.", ship:GetLabel(), corridorName), station.label)
	end
end

local function onShipExploded(ship, cause, speed)
	if not ship then return end
	if not Engine.GetBlackBoxEnabled or not Engine.GetBlackBoxEnabled() then return end
	local label = ship:GetLabel()
	local model = ship:GetShipType()
	local msg = string.format("[BLACK BOX] Vessel \"%s\" (%s) EXPLODED! Cause: %s (%.1f m/s). Full flight path logged to blackbox_diagnostics.log",
		label, model, cause or "Collision", speed or 0.0)
	print(msg)
	Comms.ImportantMessage(msg, "Flight Safety ATC")
end

local function onDockingClearanceDenied(station, ship, reason)
	if ship ~= Game.player then return end
	print(reason)
	if reason == "ClearanceAlreadyGranted" then
		Comms.Message(l.CLEARANCE_ALREADY_GRANTED_BAY_N:interp({ bay = station:GetAssignedBayNumber(ship) + 1 }), station.label)
	elseif reason == "TooFarFromStation" then
		Comms.Message(l.CLEARANCE_DENIED_TOO_FAR, station.label)
	else
		Comms.Message(l.CLEARANCE_DENIED_NO_BAYS, station.label)
	end
end

local function onDockingClearanceExpired(station, ship)
	if ship ~= Game.player then return end
	Comms.ImportantMessage(l.DOCKING_CLEARANCE_EXPIRED, station.label)
end

local loiterTrack = {}

local function enforceStationSafetyZone()
	if not Game.player or not Game.player:exists() then return end
	if Game.player.flightState == "HYPERSPACE" then
		loiterTrack = {}
		return
	end

	local station = Game.player:FindNearestTo("SPACESTATION")
	if not station or not station:exists() then
		loiterTrack = {}
		return
	end

	-- Only monitor when player is within traffic area (40 km)
	if station:DistanceTo(Game.player) > 40000 and Game.player:GetDockedWith() ~= station then
		loiterTrack = {}
		return
	end

	local isSurface = (station.type == "STARPORT_SURFACE")
	local exclusionRadius = isSurface and 650.0 or (station:GetPhysicalRadius() * 1.25 + 300.0)

	local nearShips = Space.GetBodiesNear(station, exclusionRadius + 400.0, "Ship")
	local activeShips = {}
	local toExplode = {}

	for _, ship in ipairs(nearShips) do
		if ship and ship:exists() and ship ~= Game.player then
			local flightState = ship.flightState
			if flightState == "FLYING" then
				local dist = ship:DistanceTo(station)
				local vel = ship:GetVelocityRelTo(station)
				local speed = (vel and vel.length) and vel:length() or 0.0

				local isInside = (dist <= exclusionRadius)
				local hasClearance = (station:GetAssignedBayNumber(ship) >= 0)
				local aiCmd = (ship.GetCurrentAICommand and ship:GetCurrentAICommand()) or ""
				local isDeparting = (aiCmd == "CMD_DEPART")

				-- An unauthorized obstruction is a vessel inside the active exclusion zone that:
				-- 1. Does not have bay clearance (hasClearance == false)
				-- 2. Is not actively departing (aiCmd ~= "CMD_DEPART")
				-- 3. Is essentially motionless / stalled / derelict (speed < 2.5 m/s)
				-- Active ships departing or flying normally (speed >= 2.5 m/s) are NOT obstructions!
				local isObstructing = isInside and not isDeparting and not hasClearance and (speed < 2.5)

				if isObstructing then
					activeShips[ship] = true
					local rec = loiterTrack[ship] or { time = 0, warned1 = false, warned2 = false }
					rec.time = rec.time + 2.0
					loiterTrack[ship] = rec

					local label = ship:GetLabel()
					local zoneName = isSurface and "airspace" or "airlock corridor"

					if rec.time >= 15.0 and not rec.warned1 then
						rec.warned1 = true
						Comms.Message(string.format("Traffic Control: Vessel \"%s\", you are loitering in an active %s without authorization. Clear the area immediately.", label, zoneName), station.label)
					elseif rec.time >= 28.0 and not rec.warned2 then
						rec.warned2 = true
						Comms.ImportantMessage(string.format("Traffic Control: Vessel \"%s\", final warning! Unauthorized loitering infraction confirmed. Clear the %s or lethal force will be authorized.", label, zoneName), station.label)
					elseif rec.time >= 40.0 then
						Comms.ImportantMessage(string.format("Traffic Control: Lethal force authorized against unauthorized obstruction \"%s\". Starport defense grid engaging.", label), station.label)
						loiterTrack[ship] = nil
						table.insert(toExplode, ship)
					end
				end
			end
		end
	end

	for s, _ in pairs(loiterTrack) do
		if not activeShips[s] then
			loiterTrack[s] = nil
		end
	end

	for _, ship in ipairs(toExplode) do
		if ship and ship:exists() then
			ship:Explode("Starport Defense Grid (Unauthorized Loitering)")
		end
	end
end

local loaded_data

local onGameStart = function ()
	local station = Game.player:FindNearestTo("SPACESTATION")
	if (loaded_data) then
		playerInControlledSpace = loaded_data.playerInControlledSpace
	elseif Game.player.flightState == "DOCKED" or
			station and station:DistanceTo(Game.player) < station.lawEnforcedRange then
		playerInControlledSpace = true
	end
	loaded_data = nil
	Timer:CallEvery(5, notifyControlledSpace)
	Timer:CallEvery(2, enforceStationSafetyZone)
end


local serialize = function ()
	local data = {
		playerInControlledSpace = playerInControlledSpace,
	}
	return data
end


local unserialize = function (data)
	loaded_data = data
end

Event.Register("onGameStart", onGameStart)
Event.Register("onDockingClearanceGranted", onDockingClearanceGranted)
Event.Register("onDockingClearanceDenied", onDockingClearanceDenied)
Event.Register("onDockingClearanceExpired", onDockingClearanceExpired)
Event.Register("onShipUndocked", onShipUndocked)
Event.Register("onShipExploded", onShipExploded)

Serializer:Register("StationTrafficControl", serialize, unserialize)

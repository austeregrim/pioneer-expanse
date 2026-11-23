-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

-- Lightweight Smuggler NPCs (Plan I M9):
-- Carry illegal goods with transponder OFF and Supercruise speed capped below 1c
-- so they traverse policed systems unseen, turning transponder ON just before docking.

local Commodities = require 'Commodities'
local Engine = require 'Engine'
local Equipment = require 'Equipment'
local Event = require 'Event'
local Game = require 'Game'
local Legal = require 'Legal'
local Serializer = require 'Serializer'
local Space = require 'Space'
local Timer = require 'Timer'

local MissionUtils = require 'modules.MissionUtils'
local ShipBuilder  = require 'modules.MissionUtils.ShipBuilder'
local ShipRegistry = require 'modules.ShipRegistry.ShipRegistry'

local LIGHT_SPEED = 299792458.0
local SUB_LIGHT_SC_CAP = 0.85 * LIGHT_SPEED

local smugglers = {}
local loaded_data = nil

local function findIllegalCommodities(system)
	local illegal = {}
	if not system then return illegal end
	for name, comm in pairs(Commodities) do
		if type(comm) == "table" and comm.name and not system:IsCommodityLegal(name) then
			table.insert(illegal, comm)
		end
	end
	return illegal
end

local function installEquip(ship, equipId)
	local equipSet = ship:GetComponent("EquipSet")
	local proto = Equipment.Get(equipId)
	if not equipSet or not proto then return end
	local inst = proto:Instance()
	local slot = equipSet:GetFreeSlotForEquip(inst)
	if slot then
		equipSet:Install(inst, slot)
	end
end

local function spawnSmugglers(system)
	if not system or not Legal.IsTransponderRequired(system) then return end
	local stations = system:GetStationPaths()
	if not stations or #stations < 1 then return end

	local illegalList = findIllegalCommodities(system)
	if #illegalList == 0 then return end

	local stars = system:GetStars()
	local primaryStar = stars and stars[1]
	if not primaryStar or not primaryStar.body then return end

	local desired = (system.lawlessness > 0.25) and 2 or 1
	local template = MissionUtils.ShipTemplates.GenericMerchant or MissionUtils.ShipTemplates.GenericPirate

	for i = 1, desired do
		local stPath = stations[Engine.rand:Integer(1, #stations)]
		local destStation = Space.GetBody(stPath.bodyIndex)
		if destStation then
			local rec = ShipRegistry.AcquireShipForSystem(system, "COURIER")
			local tmpl = template:clone {
				shipId = "coronatrix",
				label = rec and rec.label or nil,
			}
			local starR = math.max(primaryStar.radius or 7e8, 7e8)
			local ship = ShipBuilder.MakeShipOrbit(primaryStar.body, tmpl, 25.0, starR * 4.5, starR * 7.5)
			if ship then
				if rec then
					ShipRegistry.ApplyRecordToShip(ship, rec)
				end
				installEquip(ship, "misc.scan_detector")
				if ship.UpdateEquipStats then ship:UpdateEquipStats() end

				local cargoMgr = ship:GetComponent("CargoManager")
				if cargoMgr then
					local comm = illegalList[Engine.rand:Integer(1, #illegalList)]
					local maxCount = math.floor(cargoMgr:GetFreeSpace() / (comm.mass or 1))
					local amt = math.min(maxCount, Engine.rand:Integer(2, 8))
					if amt > 0 then
						cargoMgr:AddCommodity(comm, amt)
					end
				end

				if ship.SetTransponder then ship:SetTransponder(false) end
				if ship.SetSupercruiseSpeedCap then ship:SetSupercruiseSpeedCap(SUB_LIGHT_SC_CAP) end
				Space.PutShipOnRoute(ship, destStation, Engine.rand:Number(0.15, 0.55))
				ship:AIDockWith(destStation)

				smugglers[ship] = {
					dest = destStation,
					dockingCleared = false,
				}
			elseif rec then
				ShipRegistry.ReleaseLive(rec.label)
			end
		end
	end
end

local function updateSmugglers()
	if not Game.system then return end
	local policeId = Game.system.faction and Game.system.faction.policeShip
	local allShips = Space.GetBodies("Ship")

	for ship, st in pairs(smugglers) do
		if not ship or not ship:exists() then
			smugglers[ship] = nil
		else
			local fs = ship:GetFlightState()
			if fs == "DOCKED" then
				-- Reload route to another station or depart dark
				local stations = Game.system:GetStationPaths()
				if stations and #stations > 0 then
					local nextPath = stations[Engine.rand:Integer(1, #stations)]
					local nextDest = Space.GetBody(nextPath.bodyIndex)
					if nextDest and nextDest ~= ship:GetDockedWith() then
						st.dest = nextDest
						st.dockingCleared = false
					end
				end
			elseif st.dest and st.dest:exists() then
				local distToDest = ship:DistanceTo(st.dest)
				if fs == "FLYING" and distToDest <= 25000.0 then
					-- Stations refuse dark ships: turn transponder ON right before final docking approach
					if ship.SetTransponder and not ship:GetTransponder() then
						ship:SetTransponder(true)
					end
					st.dockingCleared = true
				elseif fs == "SUPERCRUISE" then
					-- Check if any police ship has unoccluded line of sight; if completely clear, can briefly boost
					local policeLOS = false
					if policeId then
						for _, other in ipairs(allShips) do
							if other:exists() and other.shipId == policeId and ship.IsOccludedFrom and not ship:IsOccludedFrom(other) then
								policeLOS = true
								break
							end
						end
					end
					if ship.SetSupercruiseSpeedCap then
						ship:SetSupercruiseSpeedCap(policeLOS and SUB_LIGHT_SC_CAP or 0)
					end
					if ship.SetTransponder and ship:GetTransponder() then
						ship:SetTransponder(false)
					end
				end
			end
		end
	end
end

Event.Register("onEnterSystem", function()
	smugglers = {}
	spawnSmugglers(Game.system)
end)

Event.Register("onLeaveSystem", function()
	smugglers = {}
end)

Event.Register("onShipUndocked", function(ship, station)
	if smugglers[ship] then
		smugglers[ship].dockingCleared = false
		if ship.SetTransponder then ship:SetTransponder(false) end
		if ship.SetSupercruiseSpeedCap then ship:SetSupercruiseSpeedCap(SUB_LIGHT_SC_CAP) end
	end
end)

Event.Register("onShipDestroyed", function(ship)
	smugglers[ship] = nil
end)

Event.Register("onGameStart", function()
	if loaded_data then
		smugglers = loaded_data.smugglers or {}
		loaded_data = nil
		for k, _ in pairs(smugglers) do
			if type(k) ~= 'userdata' or not k:exists() then
				smugglers[k] = nil
			end
		end
	elseif Game.system then
		spawnSmugglers(Game.system)
	end
	Timer:CallEvery(5, updateSmugglers)
end)

Event.Register("onGameEnd", function()
	smugglers = {}
	loaded_data = nil
end)

Serializer:Register("Smugglers", function()
	return { smugglers = smugglers }
end, function(data)
	loaded_data = data
end)

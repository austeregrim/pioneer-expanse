-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Commodities = require 'Commodities'
local Game        = require 'Game'
local Engine      = require 'Engine'
local Event       = require 'Event'
local Space       = require 'Space'
local Timer       = require 'Timer'

local lc = require 'Lang'.GetResource("core")

local trackedShips = {}
local timerActive = false

local function hasPerishableCargo(ship)
	if not ship or not ship:exists() then return false end
	---@type CargoManager
	local cargoMgr = ship:GetComponent('CargoManager')
	if not cargoMgr then return false end
	return (cargoMgr:CountCommodity(Commodities.live_animals) or 0) > 0
		or (cargoMgr:CountCommodity(Commodities.slaves) or 0) > 0
end

local function refreshShipTracking(ship)
	if not ship or not ship:exists() or ship:GetDockedWith() then
		if ship then trackedShips[ship] = nil end
		return
	end
	if hasPerishableCargo(ship) then
		trackedShips[ship] = true
	else
		trackedShips[ship] = nil
	end
end

local function processLifeSupportForShip(ship)
	if not ship or not ship:exists() or ship:GetDockedWith() then
		trackedShips[ship] = nil
		return
	end

	---@type CargoManager
	local cargoMgr = ship:GetComponent('CargoManager')
	if not cargoMgr then
		trackedShips[ship] = nil
		return
	end

	local commodityName = cargoMgr:DoLifeSupportChecks(ship.cargo_life_support_cap or 0)
	if commodityName then
		cargoMgr:RemoveCommodity(Commodities[commodityName], 1)

		local dice = 0
		if commodityName == "live_animals" then
			dice = Engine.rand:Integer(0, 3)
		elseif commodityName == "slaves" then
			dice = Engine.rand:Integer(0, 2)
		end
		if dice == 3 then
			commodityName = "animal_meat"
		elseif dice == 2 then
			commodityName = "fertilizer"
		else
			commodityName = "rubbish"
		end
		cargoMgr:AddCommodity(Commodities[commodityName], 1)

		if ship == Game.player then
			Game.AddCommsLogLine(lc.CARGO_BAY_LIFE_SUPPORT_LOST)
		end
	end

	if not hasPerishableCargo(ship) then
		trackedShips[ship] = nil
	end
end

local function lifeSupportTick()
	if not Game.player then
		timerActive = false
		return true
	end

	if Game.player:exists() and not Game.player:GetDockedWith() then
		refreshShipTracking(Game.player)
	end

	if next(trackedShips) == nil then
		return false
	end

	local list = {}
	for ship in pairs(trackedShips) do
		table.insert(list, ship)
	end
	for _, ship in ipairs(list) do
		processLifeSupportForShip(ship)
	end

	return false
end

local function ensureTimer()
	if timerActive then return end
	timerActive = true
	Timer:CallEvery(5.0, lifeSupportTick)
end

Event.Register('onShipCreated', refreshShipTracking)
Event.Register('onShipUndocked', refreshShipTracking)
Event.Register('onShipDocked', function(ship)
	if ship then trackedShips[ship] = nil end
end)
Event.Register('onShipDestroyed', function(ship)
	if ship then trackedShips[ship] = nil end
end)

Event.Register('onEnterSystem', function()
	trackedShips = {}
	if Game.player and Game.player:exists() then
		refreshShipTracking(Game.player)
		local cargoMgr = Game.player:GetComponent('CargoManager')
		if cargoMgr then
			cargoMgr:AddListener('life-support', function()
				refreshShipTracking(Game.player)
			end)
		end
	end
end)

Event.Register('onLeaveSystem', function()
	trackedShips = {}
end)

Event.Register('onGameStart', function()
	trackedShips = {}
	for _, ship in ipairs(Space.GetBodies("Ship") or {}) do
		refreshShipTracking(ship)
	end
	if Game.player and Game.player:exists() then
		local cargoMgr = Game.player:GetComponent('CargoManager')
		if cargoMgr then
			cargoMgr:AddListener('life-support', function()
				refreshShipTracking(Game.player)
			end)
		end
	end
	ensureTimer()
end)

Event.Register('onGameEnd', function()
	trackedShips = {}
	timerActive = false
end)

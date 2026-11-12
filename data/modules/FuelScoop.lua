-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event       = require 'Event'
local Commodities = require 'Commodities'
local Game        = require 'Game'
local Lang        = require 'Lang'
local ShipDef     = require 'ShipDef'

local lc = Lang.GetResource("core")

-- Utility functions to handle fuel and cargo scooping.
-- These callbacks are triggered from C++ or Lua and are responsible for
-- providing UI feedback about the scooping process.

Event.Register("onShipScoopFuel", function(ship, body, amount)
	local sbody = body and body.GetSystemBody and body:GetSystemBody()
	if sbody and sbody.superType == "STAR" then
		local remaining = amount
		local scoopedAny = false

		-- 1. Refill hydrogen-fueled hyperdrive reservoir first (Elite Dangerous style)
		local hd = ship.GetInstalledHyperdrive and ship:GetInstalledHyperdrive()
		if hd and hd.fuel == Commodities.hydrogen then
			local maxFuel = hd:GetMaxFuel()
			if hd.storedFuel < maxFuel then
				local addHd = math.min(remaining, maxFuel - hd.storedFuel)
				hd:SetFuel(ship, hd.storedFuel + addHd)
				remaining = remaining - addHd
				scoopedAny = true
			end
		end

		-- 2. Refill main thruster hydrogen tank with remaining intake
		if remaining > 0 then
			local shipDef = ShipDef[ship.shipId]
			local tankMass = shipDef and shipDef.fuelTankMass or 0
			if tankMass > 0 and ship.fuel < 100 then
				local addPct = (remaining / tankMass) * 100
				ship:SetFuelPercent(math.min(100, ship.fuel + addPct))
				scoopedAny = true
			end
		end

		if ship == Game.player and scoopedAny then
			local now = Game.time
			local lastMsg = ship:hasprop('lastStellarScoopLog') and ship.lastStellarScoopLog or -999
			if now - lastMsg >= 8.0 then
				ship:setprop('lastStellarScoopLog', now)
				Game.AddCommsLogLine("Fuel scoop engaged: harvesting stellar hydrogen.")
			end
		end
		return
	end

	---@type CargoManager
	local cargoMgr = ship:GetComponent('CargoManager')

	cargoMgr:AddCommodity(Commodities.hydrogen, amount)

	if ship == Game.player then
		Game.AddCommsLogLine(lc.FUEL_SCOOP_ACTIVE_N_TONNES_H_COLLECTED:gsub('%%quantity',
			cargoMgr:CountCommodity(Commodities.hydrogen)))
	end
end)

Event.Register("onShipScoopCargo", function (ship, success, cargoType)
	if ship ~= Game.player then return end

	if success then
		Game.AddCommsLogLine(lc.CARGO_SCOOP_ACTIVE_1_TONNE_X_COLLECTED:gsub('%%item',
			cargoType:GetName()))
	else
		Game.AddCommsLogLine(lc.CARGO_SCOOP_ATTEMPTED)
	end
end)

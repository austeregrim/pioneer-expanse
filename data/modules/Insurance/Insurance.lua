-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event       = require 'Event'
local Game        = require 'Game'
local ShipDef     = require 'ShipDef'
local Equipment   = require 'Equipment'
local EquipSet    = require 'EquipSet'
local Commodities = require 'Commodities'
local PlayerState = require 'PlayerState'
local Serializer  = require 'Serializer'
local HullConfig  = require 'HullConfig'
local Character   = require 'Character'

local Insurance = {}

---@class InsuranceClaim
---@field pending boolean
---@field hullId string
---@field shipName string
---@field skin string?
---@field pattern integer?
---@field equipment { slot: string, id: string, name: string, price: number }[]
---@field totalValue number
---@field deductible number
---@field recoveryDays number?
---@field stationName string?
---@field wreckage { system: string, cargo: { name: string, count: number }[] }?
---@field resolved boolean

local activeClaim = nil
local openModalRequested = false

function Insurance.IsHardcore()
	if Game.IsHardcore then
		return Game.IsHardcore()
	end
	return false
end

function Insurance.GetActiveClaim()
	return activeClaim
end

function Insurance.HasPendingClaim()
	return activeClaim ~= nil and activeClaim.pending == true
end

function Insurance.ShouldOpenModal()
	local req = openModalRequested
	openModalRequested = false
	return req
end

function Insurance.OpenClaimModal()
	openModalRequested = true
end

function Insurance.GetPolicyInfo()
	local ship = Game.player
	if not ship then return nil end

	local shipDef = ShipDef[ship.shipId]
	local hullPrice = (shipDef and shipDef.baseprice) or 100000
	local equipValue = 0

	local equipSet = ship:GetComponent('EquipSet')
	if equipSet then
		for _, item in pairs(equipSet:GetInstalledEquipment()) do
			if item and item.price then
				equipValue = equipValue + item.price
			end
		end
	end

	local total = hullPrice + equipValue
	local deductibleRate = 5
	local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')
	if okTax and TaxAuthority and TaxAuthority.GetInsuranceDiscount then
		local discount = TaxAuthority.GetInsuranceDiscount()
		if discount > 0 then
			deductibleRate = 3 -- 40% subsidized discount for lawful registered residents
		end
	end
	local deductible = math.max(1000, math.floor(total * (deductibleRate / 100)))

	return {
		underwriter = "Solar Marine & Astral Underwriters",
		hullName = (shipDef and shipDef.name) or ship.shipId,
		shipLabel = ship.label,
		hullValue = hullPrice,
		equipValue = equipValue,
		totalValue = total,
		coverageRate = 100 - deductibleRate,
		deductibleRate = deductibleRate,
		deductible = deductible,
		beaconStatus = "ONLINE (121.5 MHz / 406.025 MHz COSPAS-SARSAT)",
	}
end

local function ensureMinimumCrew(player)
	if not player then return end
	if Character.persistent and Character.persistent.player then
		Character.persistent.player.dead = false
		Character.persistent.player.player = true
		player:Enroll(Character.persistent.player)
	end
	local def = ShipDef[player.shipId]
	local minCrew = (def and def.minCrew) or 1
	while player:CrewNumber() < minCrew do
		local newCrew = Character.New()
		newCrew:RollNew(true)
		if not player:Enroll(newCrew) then break end
	end
end

-- Rebuy option: Player pays 5% deductible to restore their exact ship and outfitting
function Insurance.RebuyShip()
	if not activeClaim or not activeClaim.pending then
		return false, "No active claim."
	end

	local playerMoney = PlayerState.GetMoney()
	if playerMoney < activeClaim.deductible then
		return false, "Insufficient funds to cover insurance deductible."
	end

	-- Deduct insurance deductible
	PlayerState.AddMoney(-activeClaim.deductible)

	local player = Game.player
	player:SetShipType(activeClaim.hullId)
	if activeClaim.shipName then player:SetLabel(activeClaim.shipName) end
	if activeClaim.skin then player:SetSkin(activeClaim.skin) end
	if activeClaim.pattern and player.model then player.model:SetPattern(activeClaim.pattern) end

	local equipSet = player:GetComponent('EquipSet')
	if equipSet and activeClaim.equipment then
		for _, eq in ipairs(activeClaim.equipment) do
			if eq.slot and eq.id then
				local proto = Equipment.Get(eq.id)
				if proto then
					local handle = equipSet:GetSlotHandle(eq.slot)
					if handle and equipSet:CanInstallInSlot(handle, proto) then
						pcall(function()
							equipSet:Install(proto:Instance(), handle)
						end)
					end
				end
			end
		end
	end

	player:SetFuelPercent(100)
	ensureMinimumCrew(player)

	activeClaim.pending = false
	activeClaim.resolved = true
	return true, "Replacement vessel fully restored, equipped, and fueled on Pad 1."
end

-- Claim cash settlement and starter loaner vessel
function Insurance.ClaimPayoutAndLoaner()
	if not activeClaim or not activeClaim.pending then
		return false, "No active claim."
	end

	local payout = math.max(0, activeClaim.totalValue - activeClaim.deductible)
	if payout > 0 then
		PlayerState.AddMoney(payout)
	end

	local player = Game.player
	player:SetShipType('coronatrix')
	player:SetLabel("Free Trader")

	local equipSet = player:GetComponent('EquipSet')
	if equipSet then
		local hullConfig = HullConfig.GetHullConfig('coronatrix')
		if hullConfig and hullConfig.slots then
			for slotId, slot in pairs(hullConfig.slots) do
				if slot.default then
					local proto = Equipment.Get(slot.default)
					if proto then
						local handle = equipSet:GetSlotHandle(slotId)
						if handle and equipSet:CanInstallInSlot(handle, proto) then
							pcall(function()
								equipSet:Install(proto:Instance(), handle)
							end)
						end
					end
				end
			end
		end
	end

	player:SetFuelPercent(100)
	ensureMinimumCrew(player)

	activeClaim.pending = false
	activeClaim.resolved = true
	return true, string.format("Settlement of %s CR deposited. Starter loaner craft prepared on Pad 1.", tostring(payout))
end

-- Event: Player ship was destroyed
local function onPlayerShipDestroyed(ship)
	if ship ~= Game.player then return end
	if Insurance.IsHardcore() then return end

	local equipSet = ship:GetComponent('EquipSet')
	local cargoMgr = ship:GetComponent('CargoManager')

	local savedEquip = {}
	local totalEquipValue = 0

	if equipSet then
		for slotId, item in pairs(equipSet:GetInstalledEquipment()) do
			if item then
				local price = item.price or 0
				totalEquipValue = totalEquipValue + price
				table.insert(savedEquip, {
					slot = tostring(slotId),
					id = item.id or (item.type and item.type.id),
					name = item.name or (item.type and item.type.name) or "Equipment Module",
					price = price
				})
			end
		end
	end

	local shipDef = ShipDef[ship.shipId]
	local hullPrice = (shipDef and shipDef.baseprice) or 100000
	local totalVal = hullPrice + totalEquipValue
	local deductibleRate = 5
	local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')
	if okTax and TaxAuthority and TaxAuthority.GetInsuranceDiscount then
		local discount = TaxAuthority.GetInsuranceDiscount()
		if discount > 0 then
			deductibleRate = 3 -- 40% subsidized discount for lawful registered residents
		end
	end
	local deductibleVal = math.max(1000, math.floor(totalVal * (deductibleRate / 100)))

	-- Jettison cargo as salvageable flotsam canisters into deep space
	local droppedCargoList = {}
	if cargoMgr and cargoMgr.commodities then
		for commName, data in pairs(cargoMgr.commodities) do
			if data.count and data.count > 0 then
				local comm = Commodities[commName]
				if comm then
					pcall(function()
						ship:SpawnCargo(comm, 86400 * 30, data.count)
					end)
					table.insert(droppedCargoList, {
						name = comm.name or commName,
						count = data.count
					})
				end
			end
		end
	end

	local sysName = (Game.system and Game.system.name) or "Deep Space Sector"

	activeClaim = {
		pending = true,
		hullId = ship.shipId,
		shipName = ship.label,
		skin = ship:GetSkin(),
		pattern = ship.model and ship.model.pattern or 0,
		equipment = savedEquip,
		totalValue = totalVal,
		deductible = deductibleVal,
		droppedCargo = droppedCargoList,
		systemName = sysName,
		resolved = false
	}
end

-- Event: Player was recovered by SAR and docked at station
local function onPlayerRescued(recoveryDays, station)
	if not activeClaim then return end
	activeClaim.recoveryDays = recoveryDays
	activeClaim.stationName = station and station.label or "Regional Starport Medical Bay"
	Insurance.OpenClaimModal()
end

Event.Register("onPlayerShipDestroyed", onPlayerShipDestroyed)
Event.Register("onPlayerRescued", onPlayerRescued)

local function serialize()
	return {
		activeClaim = activeClaim
	}
end

local function unserialize(data)
	if data and data.activeClaim then
		activeClaim = data.activeClaim
	end
end

Serializer:Register("InsuranceDB", serialize, unserialize)

return Insurance


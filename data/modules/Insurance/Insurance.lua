-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event       = require 'Event'
local Game        = require 'Game'
local Format      = require 'Format'
local ShipDef     = require 'ShipDef'
local Equipment   = require 'Equipment'
local EquipSet    = require 'EquipSet'
local Commodities = require 'Commodities'
local PlayerState = require 'PlayerState'
local Serializer  = require 'Serializer'
local HullConfig  = require 'HullConfig'
local Character   = require 'Character'
local Ship        = require 'Ship'

local Insurance = {}

local STARTER_SHIP_ID = "coronatrix"
Insurance.STARTER_SHIP_ID = STARTER_SHIP_ID

---@class InsuranceClaim
---@field pending boolean?
---@field hullId string
---@field shipName string
---@field customShipName string?
---@field skin string?
---@field pattern integer?
---@field equipment { slot: string?, id: string, name: string, count: integer?, price: number, subsidized: boolean? }[]
---@field hullValue number?
---@field equipValue number?
---@field totalValue number
---@field deductibleRate number?
---@field deductible number
---@field starterShipId string?
---@field starterShipCost number?
---@field wasSubsidized boolean?
---@field recoveryDays number?
---@field stationName string?
---@field droppedCargo { name: string, count: number }[]?
---@field wreckage { system: string, cargo: { name: string, count: number }[] }?
---@field resolved boolean

local activeClaim = nil
local openModalRequested = false
local incarcerationRecord = nil
local playerShipSubsidized = false

function Insurance.IsHardcore()
	if Game.IsHardcore then
		return Game.IsHardcore()
	end
	return false
end

function Insurance.GetActiveClaim()
	return activeClaim
end

function Insurance.HasClaim()
	return activeClaim ~= nil and not activeClaim.resolved
end

Insurance.HasPendingClaim = Insurance.HasClaim

function Insurance.HasImpoundedShip()
	return false
end

function Insurance.GetImpoundedShip()
	return nil
end

function Insurance.IsArrestClaim()
	return activeClaim ~= nil and activeClaim.isArrest == true
end

function Insurance.GetSentenceDays()
	return activeClaim and activeClaim.totalSentenceDays or (activeClaim and activeClaim.sentenceDays or 0)
end

function Insurance.GetFinePaid()
	return activeClaim and activeClaim.finePaid or (activeClaim and activeClaim.fineDue or 0)
end

function Insurance.HasIncarcerationRecord()
	return incarcerationRecord ~= nil
end

function Insurance.GetIncarcerationRecord()
	return incarcerationRecord
end

function Insurance.DismissIncarcerationRecord()
	incarcerationRecord = nil
end

function Insurance.ShouldOpenModal()
	local req = openModalRequested
	openModalRequested = false
	return req
end

function Insurance.OpenClaimModal()
	openModalRequested = true
end

function Insurance.IsPlayerShipSubsidized()
	return playerShipSubsidized == true
end

function Insurance.SetPlayerShipSubsidized(flag)
	playerShipSubsidized = (flag == true)
end

local function clearShipCargo(ship)
	if not ship then return end
	local cargoMgr = ship:GetComponent('CargoManager')
	if not cargoMgr then return end
	local toRemove = {}
	for name, count in cargoMgr:Commodities() do
		if count and count > 0 then
			toRemove[name] = count
		end
	end
	for name, count in pairs(toRemove) do
		local comm = Commodities[name]
		if comm then
			cargoMgr:RemoveCommodity(comm, count)
		end
	end
end

local function fillHyperdriveFuel(ship)
	if not ship or not ship.GetInstalledHyperdrive then return end
	local okD, drive = pcall(function() return ship:GetInstalledHyperdrive() end)
	if okD and drive and drive.SetFuel and drive.GetMaxFuel then
		local maxFuel = drive:GetMaxFuel() or 0
		if maxFuel > 0 then
			pcall(function() drive:SetFuel(ship, maxFuel) end)
		end
	end
end

local function sortEquipListParentFirst(list)
	table.sort(list, function(a, b)
		if a.slot and b.slot then
			if #a.slot ~= #b.slot then return #a.slot < #b.slot end
			return a.slot < b.slot
		end
		return a.slot ~= nil and b.slot == nil
	end)
	return list
end

local function getDeductibleRate()
	local deductibleRate = 5
	local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')
	if okTax and TaxAuthority and TaxAuthority.GetInsuranceDiscount then
		local discount = TaxAuthority.GetInsuranceDiscount()
		if discount and discount > 0 then
			deductibleRate = 3 -- 40% subsidized discount for lawful registered residents
		end
	end
	return deductibleRate
end

local function computeDeductible(total, rate)
	if total <= 0 then return 0 end
	return math.min(total, math.max(1000, math.floor(total * (rate / 100))))
end

function Insurance.GetStarterShipCost()
	local def = ShipDef[STARTER_SHIP_ID]
	local hullCost = (def and def.basePrice) or 0
	local equipCost = 0
	local hullConfig = HullConfig.GetHullConfig(STARTER_SHIP_ID)
	if hullConfig and hullConfig.slots then
		for _, slot in pairs(hullConfig.slots) do
			if slot.default then
				local proto = Equipment.Get(slot.default)
				if proto then
					local inst = proto:Instance()
					if inst.SpecializeForShip then
						inst:SpecializeForShip(hullConfig)
					end
					if slot.count and inst.SetCount then
						inst:SetCount(slot.count)
					end
					equipCost = equipCost + (inst.price or 0)
				end
			end
		end
	end
	return hullCost + equipCost, hullCost, equipCost
end

function Insurance.GetClaimPayoutBreakdown(claim)
	claim = claim or activeClaim
	if not claim then return nil end

	local totalValue = claim.totalValue or 0
	local deductible = claim.deductible or 0
	local deductibleRate = claim.deductibleRate or 5
	local netInsuredValue = math.max(0, totalValue - deductible)
	local starterCost = claim.starterShipCost or select(1, Insurance.GetStarterShipCost())
	local cashPayout = math.max(0, netInsuredValue - starterCost)
	local isSubsidizedStarter = (netInsuredValue < starterCost)
	local subsidyAmount = math.max(0, starterCost - netInsuredValue)

	return {
		totalValue = totalValue,
		deductible = deductible,
		deductibleRate = deductibleRate,
		netInsuredValue = netInsuredValue,
		starterCost = starterCost,
		cashPayout = cashPayout,
		isSubsidizedStarter = isSubsidizedStarter,
		subsidyAmount = subsidyAmount,
	}
end

function Insurance.GetPolicyInfo()
	local ship = Game.player
	if not ship then return nil end

	local shipDef = ShipDef[ship.shipId]
	local hullPrice = playerShipSubsidized and 0 or ((shipDef and shipDef.basePrice) or 0)
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
	local deductibleRate = getDeductibleRate()
	local deductible = computeDeductible(total, deductibleRate)

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
		hardcore = Insurance.IsHardcore(),
		isSubsidized = playerShipSubsidized,
		starterShipCost = select(1, Insurance.GetStarterShipCost()),
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

local function giveDefaultStarterShip(shipName)
	local player = Game.player
	if not player then return end

	clearShipCargo(player)
	player:SetShipType(STARTER_SHIP_ID)
	player:SetLabel(Ship.MakeRandomLabel(STARTER_SHIP_ID, "PLAYER"))
	if player.SetShipName then
		player:SetShipName(shipName or "Insurance Starter")
	end

	local equipSet = player:GetComponent('EquipSet')
	if equipSet then
		local hullConfig = HullConfig.GetHullConfig(STARTER_SHIP_ID)
		if hullConfig and hullConfig.slots then
			for slotId, slot in pairs(hullConfig.slots) do
				if slot.default then
					local proto = Equipment.Get(slot.default)
					if proto then
						local inst = proto:Instance()
						if inst.SpecializeForShip then
							inst:SpecializeForShip(hullConfig)
						end
						if slot.count and inst.SetCount then
							inst:SetCount(slot.count)
						end
						local handle = equipSet:GetSlotHandle(slotId)
						if handle and equipSet:CanInstallInSlot(handle, inst) then
							pcall(function() equipSet:Install(inst, handle) end)
						end
					end
				end
			end
		end
	end

	fillHyperdriveFuel(player)
	player:SetFuelPercent(100)
	if player.SetHullPercent then
		player:SetHullPercent(100)
	end
	ensureMinimumCrew(player)
end

-- Rebuy option: Player pays deductible to swap the Insurance Starter Ship for their destroyed ship and outfitting
function Insurance.RebuyShip()
	if not activeClaim or activeClaim.resolved then
		return false, "No active claim."
	end

	local playerMoney = PlayerState.GetMoney()
	if playerMoney < activeClaim.deductible then
		return false, "Insufficient funds to cover insurance deductible."
	end

	-- Deduct insurance deductible
	if activeClaim.deductible > 0 then
		PlayerState.AddMoney(-activeClaim.deductible)
	end

	local player = Game.player
	clearShipCargo(player)
	player:SetShipType(activeClaim.hullId)
	if activeClaim.shipName then player:SetLabel(activeClaim.shipName) end
	if player.SetShipName then
		player:SetShipName(activeClaim.customShipName or "")
	end
	if activeClaim.skin then player:SetSkin(activeClaim.skin) end
	if activeClaim.pattern and player.model then player.model:SetPattern(activeClaim.pattern) end

	local equipSet = player:GetComponent('EquipSet')
	local hullConfig = HullConfig.GetHullConfig(activeClaim.hullId)
	if equipSet and activeClaim.equipment then
		local ordered = {}
		for _, eq in ipairs(activeClaim.equipment) do
			table.insert(ordered, eq)
		end
		sortEquipListParentFirst(ordered)

		for _, eq in ipairs(ordered) do
			if eq.id then
				local proto = Equipment.Get(eq.id)
				if proto then
					local inst = proto:Instance()
					if inst.SpecializeForShip and hullConfig then
						inst:SpecializeForShip(hullConfig)
					end
					if eq.count and inst.SetCount then
						inst:SetCount(eq.count)
					end
					if eq.subsidized then
						inst.price = 0
						inst.insuranceSubsidized = true
					end
					if eq.slot then
						local handle = equipSet:GetSlotHandle(eq.slot)
						if handle and equipSet:CanInstallInSlot(handle, inst) then
							pcall(function() equipSet:Install(inst, handle) end)
						else
							local freeSlot = equipSet:GetFreeSlotForEquip(inst)
							if freeSlot and equipSet:CanInstallInSlot(freeSlot, inst) then
								pcall(function() equipSet:Install(inst, freeSlot) end)
							end
						end
					elseif equipSet:CanInstallLoose(inst) then
						pcall(function() equipSet:Install(inst, nil) end)
					end
				end
			end
		end
	end

	playerShipSubsidized = (activeClaim.wasSubsidized == true)
	fillHyperdriveFuel(player)
	player:SetFuelPercent(100)
	if player.SetHullPercent then
		player:SetHullPercent(100)
	end
	ensureMinimumCrew(player)

	activeClaim.pending = false
	activeClaim.isImpounded = false
	activeClaim.resolved = true

	local deductibleRate = activeClaim.deductibleRate or 5
	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		local def = ShipDef[activeClaim.hullId]
		FlightLog.RecordTransaction({
			category = "INSURANCE",
			title = string.format("Insurance Hull Rebuy: %s (%s)", def and def.name or activeClaim.hullId, Format.Money(-activeClaim.deductible)),
			amount = -activeClaim.deductible,
			details = {
				{ "Restored Vessel Hull", def and def.name or activeClaim.hullId },
				{ "Restored Vessel Registration", activeClaim.shipName or "Unnamed" },
				{ "Total Insured Valuation", Format.Money(activeClaim.totalValue) },
				{ string.format("Deductible Paid (%d%%)", deductibleRate), Format.Money(activeClaim.deductible) },
				{ "Restored Outfitting", string.format("%d modules restored to factory specification", #(activeClaim.equipment or {})) },
				{ "Restoration Bay", "Pad 1 (Insurance Starter Swapped for Replacement Vessel)" },
			},
			note = string.format("Exercised statutory underwriter hull rebuy option. %d%% deductible paid; temporary Insurance Starter Ship swapped for replacement vessel on Pad 1.", deductibleRate)
		})
	end

	return true, "Insurance starter ship swapped for factory-fresh replacement vessel on Pad 1."
end

-- Claim cash settlement (after deducting starter ship cost) and retain the Insurance Starter Ship
function Insurance.ClaimPayoutAndKeepStarter()
	if not activeClaim or activeClaim.resolved then
		return false, "No active claim."
	end

	local player = Game.player
	if not player then
		return false, "No active player vessel."
	end

	if player.shipId ~= STARTER_SHIP_ID then
		giveDefaultStarterShip("Insurance Starter")
	end

	local bd = Insurance.GetClaimPayoutBreakdown(activeClaim)
	if bd.cashPayout > 0 then
		PlayerState.AddMoney(bd.cashPayout)
	end

	playerShipSubsidized = bd.isSubsidizedStarter
	if bd.isSubsidizedStarter then
		local equipSet = player:GetComponent('EquipSet')
		if equipSet then
			for _, item in pairs(equipSet:GetInstalledEquipment()) do
				if item then
					item.price = 0
					item.insuranceSubsidized = true
				end
			end
		end
	end

	local starterDef = ShipDef[STARTER_SHIP_ID]
	local starterName = (starterDef and starterDef.name) or "Coronatrix"
	if player.SetShipName then
		player:SetShipName(starterName)
	end

	-- Dismiss any excess crew carried over from a multi-crew destroyed vessel
	local maxCrew = (starterDef and starterDef.maxCrew) or 1
	if player:CrewNumber() > maxCrew then
		local nonPlayer = {}
		for member in player:EachCrewMember() do
			if not member.player then
				table.insert(nonPlayer, member)
			end
		end
		for i = #nonPlayer, 1, -1 do
			if player:CrewNumber() <= maxCrew then break end
			player:Dismiss(nonPlayer[i])
		end
	end

	activeClaim.pending = false
	activeClaim.isImpounded = false
	activeClaim.resolved = true

	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		local def = ShipDef[activeClaim.hullId]
		local details = {
			{ "Liquidated Claim Vessel", def and def.name or activeClaim.hullId },
			{ "Total Claim Valuation", Format.Money(bd.totalValue) },
			{ string.format("Deductible Withheld (%d%%)", bd.deductibleRate), Format.Money(-bd.deductible) },
			{ string.format("Starter Ship Cost Deducted (%s)", starterName), Format.Money(-bd.starterCost) },
		}
		if bd.isSubsidizedStarter then
			table.insert(details, { "Charter Starter Subsidy Waived", Format.Money(bd.subsidyAmount) })
		end
		table.insert(details, { "Net Cash Settlement Deposited", Format.Money(bd.cashPayout) })
		table.insert(details, {
			"Active Vessel Retained",
			bd.isSubsidizedStarter
				and string.format("%s (Charter-Subsidized Starter — 0 Cr hull/stock resale)", starterName)
				or string.format("%s (Full Ownership)", starterName)
		})

		FlightLog.RecordTransaction({
			category = "INSURANCE",
			title = string.format("Insurance Settlement Payout: +%s", Format.Money(bd.cashPayout)),
			amount = bd.cashPayout,
			details = details,
			note = bd.isSubsidizedStarter
				and string.format("Settled claim under charter starter subsidy. Retained %s starter ship with 0.00 Cr net cash payout.", starterName)
				or string.format("Accepted underwriter cash settlement after deducting %s starter ship cost. Deposited %s and retained %s.", Format.Money(bd.starterCost), Format.Money(bd.cashPayout), starterName)
		})
	end

	if bd.isSubsidizedStarter then
		return true, string.format("Claim closed. Retaining Charter-Subsidized %s starter ship (0.00 Cr net payout; %s shortfall waived).", starterName, Format.Money(bd.subsidyAmount))
	else
		return true, string.format("Settlement of %s deposited (after %s %s starter ship deduction). Retaining %s.", Format.Money(bd.cashPayout), Format.Money(bd.starterCost), starterName, starterName)
	end
end

Insurance.ClaimPayoutAndLoaner = Insurance.ClaimPayoutAndKeepStarter

-- Event: Player ship was destroyed
local function onPlayerShipDestroyed(ship, cause, speed)
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
					slot = (type(slotId) == "string") and slotId or nil,
					id = item.id or (item.GetPrototype and item:GetPrototype().id) or (item.type and item.type.id),
					name = (item.GetName and item:GetName()) or item.name or (item.type and item.type.name) or "Equipment Module",
					count = item.count,
					price = price,
					subsidized = (rawget(item, "price") == 0) or (item.insuranceSubsidized == true) or nil,
				})
			end
		end
		sortEquipListParentFirst(savedEquip)
	end

	local shipDef = ShipDef[ship.shipId]
	local hullPrice = playerShipSubsidized and 0 or ((shipDef and shipDef.basePrice) or 0)
	local totalVal = hullPrice + totalEquipValue
	local deductibleRate = getDeductibleRate()
	local deductibleVal = computeDeductible(totalVal, deductibleRate)
	local starterCost = select(1, Insurance.GetStarterShipCost())

	-- Jettison cargo as salvageable flotsam canisters into deep space and clear hold
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
						name = (comm.GetName and comm:GetName()) or comm.name or commName,
						count = data.count
					})
				end
			end
		end
		clearShipCargo(ship)
	end

	local sysName = (Game.system and Game.system.name) or "Deep Space Sector"
	local flightState = (ship.GetFlightState and ship:GetFlightState()) or "FLYING"

	-- Judicial / Incarceration Check: Was player destroyed while carrying criminal warrants/fines?
	local fine = 0
	if PlayerState.GetTotalFinesOutstanding then
		fine = PlayerState.GetTotalFinesOutstanding()
	else
		local _, outFine = PlayerState.GetCrimeOutstanding()
		fine = outFine or 0
	end
	local isCriminal = (fine > 0)
	local isArrest = isCriminal
	local sentenceDays = isArrest and math.clamp(math.ceil(fine / 1000), 3, 60) or 0

	activeClaim = {
		isArrest = isArrest,
		fineDue = fine,
		sentenceDays = sentenceDays,
		hullId = ship.shipId,
		shipName = ship.label,
		customShipName = (ship.shipName and ship.shipName ~= "" and ship.shipName) or nil,
		skin = ship:GetSkin(),
		pattern = ship.model and ship.model.pattern or 0,
		equipment = savedEquip,
		hullValue = hullPrice,
		equipValue = totalEquipValue,
		totalValue = totalVal,
		deductibleRate = deductibleRate,
		deductible = deductibleVal,
		starterShipId = STARTER_SHIP_ID,
		starterShipCost = starterCost,
		wasSubsidized = playerShipSubsidized,
		droppedCargo = droppedCargoList,
		systemName = sysName,
		resolved = false
	}

	-- Record Catastrophic Vessel Loss with Black Box Telemetry in Commander's Log
	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		local details = {
			{ "Vessel Designation", string.format("%s (%s)", shipDef and shipDef.name or ship.shipId, ship.label or "Unnamed") },
			{ "Flight Regime", flightState },
			{ "Cause of Destruction", cause or "Hull Structural Failure / Catastrophic Explosive Decompression" },
		}
		if speed and speed > 0 then
			table.insert(details, { "Relative Impact Velocity", string.format("%.1f m/s (%.1f km/h)", speed, speed * 3.6) })
		end
		table.insert(details, { "Insured Hull Valuation", playerShipSubsidized and "0.00 Cr (Charter-Subsidized Starter)" or Format.Money(hullPrice) })
		table.insert(details, { "Insured Outfitting Total", Format.Money(totalEquipValue) })
		table.insert(details, { "Total Replacement Claim Value", Format.Money(totalVal) })
		table.insert(details, { string.format("Statutory Deductible (%d%%)", deductibleRate), Format.Money(deductibleVal) })
		if #droppedCargoList > 0 then
			local cargoDesc = {}
			for _, c in ipairs(droppedCargoList) do
				table.insert(cargoDesc, string.format("%s (%d units)", c.name, c.count))
			end
			table.insert(details, { "Jettisoned Cargo Flotsam", table.concat(cargoDesc, ", ") })
		end
		table.insert(details, { "Life Support Telemetry", "COSPAS-SARSAT Cryo-Stasis Escape Pod Deployed" })

		FlightLog.RecordTransaction({
			category = "SHIP_LOSS",
			title = string.format("Catastrophic Vessel Loss: %s", shipDef and shipDef.name or ship.shipId),
			amount = 0,
			details = details,
			note = string.format("Vessel was catastrophically destroyed in %s. Cryogenic escape pod transponder acquired by SAR transponders.", sysName)
		})
	end
end

-- Event: Player was recovered by SAR or remanded to starport correctional custody
local function onPlayerRescued(recoveryDays, station)
	if not activeClaim then return end
	activeClaim.recoveryDays = recoveryDays
	activeClaim.stationName = station and station.label or "Regional Starport Medical Bay"

	if activeClaim.isArrest then
		-- Advance time and process incarceration
		local totalFine = activeClaim.fineDue or 1500
		local currentCash = math.max(0, PlayerState.GetMoney())

		-- Fine is deducted ONLY up to available cash. Player cash NEVER becomes negative!
		local finePaid = math.min(currentCash, totalFine)
		local unpaidFine = totalFine - finePaid

		-- Base judicial sentence: 3 to 60 days
		local baseDays = math.clamp(math.ceil(totalFine / 1000), 3, 60)

		-- Unpaid fine commuted to hard-labor extension: 1 day per 150 CR unpaid
		local extraDays = unpaidFine > 0 and math.ceil(unpaidFine / 150) or 0
		local totalSentenceDays = baseDays + extraDays

		local startTime = Game.time
		local sentenceSeconds = totalSentenceDays * 86400.0
		Game.time = Game.time + sentenceSeconds
		local releaseTime = Game.time

		if finePaid > 0 then
			PlayerState.AddMoney(-finePaid)
		end
		-- Safety clamp to ensure zero debt
		if PlayerState.GetMoney() < 0 then
			PlayerState.AddMoney(-PlayerState.GetMoney())
		end

		-- Clear all outstanding criminal warrants and fines (time served)
		PlayerState.ClearCrimeFine(nil, false)

		activeClaim.finePaid = finePaid
		activeClaim.unpaidFine = unpaidFine
		activeClaim.baseDays = baseDays
		activeClaim.extraDays = extraDays
		activeClaim.totalSentenceDays = totalSentenceDays
		activeClaim.startTime = startTime
		activeClaim.releaseTime = releaseTime

		-- Issue baseline starter craft pending insurance settlement
		giveDefaultStarterShip("Insurance Starter")

		-- Record incarceration certificate for modal presentation
		incarcerationRecord = {
			stationName = activeClaim.stationName,
			shipName = activeClaim.shipName or "Unregistered",
			hullName = (ShipDef[activeClaim.hullId] and ShipDef[activeClaim.hullId].name) or activeClaim.hullId,
			deductible = activeClaim.deductible,
			totalFine = totalFine,
			finePaid = finePaid,
			unpaidFine = unpaidFine,
			baseDays = baseDays,
			extraDays = extraDays,
			totalDays = totalSentenceDays,
			startDateStr = Format.Date(startTime),
			releaseDateStr = Format.Date(releaseTime),
		}

		-- Record Judicial Remand and Sentence into Commander's Log
		local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
		if okFlightLog and FlightLog and FlightLog.RecordTransaction then
			local details = {
				{ "Correctional Facility", activeClaim.stationName },
				{ "Intake Date", Format.Date(startTime) },
				{ "Discharge Date", Format.Date(releaseTime) },
				{ "Statutory Custody Term", string.format("%d Standard Days", baseDays) },
			}
			if extraDays > 0 then
				table.insert(details, { "Commuted Labor Extension", string.format("%d Standard Days (commuted at 150 Cr/day)", extraDays) })
			end
			table.insert(details, { "Total Sentence Served", string.format("%d Standard Days", totalSentenceDays) })
			table.insert(details, { "Outstanding Fines Assessed", Format.Money(totalFine) })
			table.insert(details, { "Liquid Capital Garnished", Format.Money(finePaid) })
			table.insert(details, { "Unpaid Balance Remitted", Format.Money(unpaidFine) .. " (Discharged via Labor)" })
			table.insert(details, { "Criminal Record & Warrants", "CLEARED & EXPUNGED (TIME SERVED)" })
			table.insert(details, { "Current Assigned Vessel", "Insurance Starter Ship (Coronatrix — Claim Pending)" })

			FlightLog.RecordTransaction({
				category = "INCARCERATION",
				title = string.format("Judicial Incarceration: %s", activeClaim.stationName),
				amount = -finePaid,
				details = details,
				note = string.format("Remanded to judicial correctional custody at %s. Served %d standard days; criminal fines settled and legal status restored to Clean.", activeClaim.stationName, totalSentenceDays),
				stationName = activeClaim.stationName,
				systemp = station and station.path
			})
		end
	else
		-- Civilian SAR recovery: place pilot in Insurance Starter Ship pending claim choice
		giveDefaultStarterShip("Insurance Starter")
	end
end

Event.Register("onPlayerShipDestroyed", onPlayerShipDestroyed)
Event.Register("onPlayerRescued", onPlayerRescued)

-- Module state lives for the whole process lifetime, so it must be cleared
-- whenever a game ends. Otherwise a pending claim from a previous session
-- leaks into the next loaded save / new game and blocks launching.
local function resetState()
	activeClaim = nil
	openModalRequested = false
	incarcerationRecord = nil
	playerShipSubsidized = false
end

Event.Register("onGameEnd", resetState)

local function serialize()
	return {
		activeClaim = activeClaim,
		incarcerationRecord = incarcerationRecord,
		playerShipSubsidized = playerShipSubsidized,
	}
end

local function unserialize(data)
	-- Always replace state: a save without a claim must not inherit a stale one.
	resetState()
	if data and data.activeClaim then
		activeClaim = data.activeClaim
		if not activeClaim.starterShipId then
			activeClaim.starterShipId = STARTER_SHIP_ID
		end
		if not activeClaim.starterShipCost then
			activeClaim.starterShipCost = select(1, Insurance.GetStarterShipCost())
		end
		if not activeClaim.deductibleRate then
			activeClaim.deductibleRate = 5
		end
	end
	if data and data.incarcerationRecord then
		incarcerationRecord = data.incarcerationRecord
	end
	if data and data.playerShipSubsidized == true then
		playerShipSubsidized = true
	end
	-- Heal negative cash balance if present from previous fine deduction
	if PlayerState.GetMoney() < 0 then
		PlayerState.AddMoney(-PlayerState.GetMoney())
	end
end

Serializer:Register("InsuranceDB", serialize, unserialize)

return Insurance


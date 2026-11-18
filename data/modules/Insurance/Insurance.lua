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
local incarcerationRecord = nil

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

local function giveDefaultStarterShip(label)
	local player = Game.player
	if not player then return end

	player:SetShipType('coronatrix')
	player:SetLabel(label or "Free Trader")

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
							pcall(function() equipSet:Install(proto:Instance(), handle) end)
						end
					end
				end
			end
		end
	end

	player:SetFuelPercent(100)
	ensureMinimumCrew(player)
end

-- Rebuy option: Player pays 5% deductible to replace their destroyed ship and outfitting
function Insurance.RebuyShip()
	if not activeClaim or activeClaim.resolved then
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
	activeClaim.isImpounded = false
	activeClaim.resolved = true

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
				{ "Deductible Paid (5%)", Format.Money(activeClaim.deductible) },
				{ "Restored Outfitting", string.format("%d modules restored to factory specification", #(activeClaim.equipment or {})) },
				{ "Restoration Bay", "Pad 1 (Factory-Fresh Replacement Fully Restored & Fueled)" },
			},
			note = string.format("Exercised statutory underwriter hull rebuy option. 5%% deductible paid; destroyed vessel and outfitting restored on Pad 1.")
		})
	end

	return true, "Replacement vessel fully restored, equipped, and fueled on Pad 1."
end

-- Claim cash settlement and keep current default starter craft
function Insurance.ClaimPayoutAndLoaner()
	if not activeClaim or activeClaim.resolved then
		return false, "No active claim."
	end

	local payout = math.max(0, activeClaim.totalValue - activeClaim.deductible)
	if payout > 0 then
		PlayerState.AddMoney(payout)
	end

	activeClaim.pending = false
	activeClaim.isImpounded = false
	activeClaim.resolved = true

	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		local def = ShipDef[activeClaim.hullId]
		FlightLog.RecordTransaction({
			category = "INSURANCE",
			title = string.format("Insurance Settlement Payout: +%s", Format.Money(payout)),
			amount = payout,
			details = {
				{ "Liquidated Claim Vessel", def and def.name or activeClaim.hullId },
				{ "Total Claim Valuation", Format.Money(activeClaim.totalValue) },
				{ "Deductible Withheld (5%)", Format.Money(activeClaim.deductible) },
				{ "Net Cash Settlement Deposited", Format.Money(payout) },
				{ "Active Assigned Craft", "Starter Scout (Retained as Primary)" },
			},
			note = string.format("Accepted underwriter cash insurance settlement. Net equity proceeds deposited and starter craft retained.")
		})
	end

	return true, string.format("Settlement of %s deposited. Retaining current starter vessel.", Format.Money(payout))
end

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
		skin = ship:GetSkin(),
		pattern = ship.model and ship.model.pattern or 0,
		equipment = savedEquip,
		totalValue = totalVal,
		deductible = deductibleVal,
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
		table.insert(details, { "Insured Hull Valuation", Format.Money(hullPrice) })
		table.insert(details, { "Insured Outfitting Total", Format.Money(totalEquipValue) })
		table.insert(details, { "Total Replacement Claim Value", Format.Money(totalVal) })
		table.insert(details, { "Statutory Deductible (5%)", Format.Money(deductibleVal) })
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

		-- Issue baseline starter scout craft upon discharge
		giveDefaultStarterShip("Discharged Scout")

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
			table.insert(details, { "Current Assigned Vessel", "Discharged Starter Scout (Pad 1)" })

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
		-- Civilian SAR recovery: issue baseline starter loaner craft
		giveDefaultStarterShip("Loaner Scout")
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
end

Event.Register("onGameEnd", resetState)

local function serialize()
	return {
		activeClaim = activeClaim,
		incarcerationRecord = incarcerationRecord,
	}
end

local function unserialize(data)
	-- Always replace state: a save without a claim must not inherit a stale one.
	resetState()
	if data and data.activeClaim then
		activeClaim = data.activeClaim
	end
	if data and data.incarcerationRecord then
		incarcerationRecord = data.incarcerationRecord
	end
	-- Heal negative cash balance if present from previous fine deduction
	if PlayerState.GetMoney() < 0 then
		PlayerState.AddMoney(-PlayerState.GetMoney())
	end
end

Serializer:Register("InsuranceDB", serialize, unserialize)

return Insurance


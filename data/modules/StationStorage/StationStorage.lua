-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game         = require 'Game'
local Event        = require 'Event'
local Format       = require 'Format'
local Economy      = require 'Economy'
local Serializer   = require 'Serializer'
local Commodities  = require 'Commodities'
local Equipment    = require 'Equipment'
local HullConfig   = require 'HullConfig'
local PlayerState  = require 'PlayerState'
local TaxAuthority = require 'modules.Economy.TaxAuthority'

local StationStorage = {}

local MAX_CARGO_TONNES = 500
local MAX_MODULE_SLOTS = 50

local vaults = {}
local nextModuleUid = 1

local function getInsurance()
	local ok, mod = pcall(require, 'modules.Insurance.Insurance')
	return ok and mod or nil
end

local function getPenalSystem()
	local ok, mod = pcall(require, 'modules.Penal.PenalSystem')
	return ok and mod or nil
end

local function syncSubsystems(ship)
	local ok, mod = pcall(require, 'modules.ComponentIntegrity.ComponentIntegrity')
	if ok and mod and mod.SyncShipSubsystems then
		pcall(function() mod.SyncShipSubsystems(ship) end)
	end
end

local function makeVault(station)
	local sysName = (Game.system and Game.system.name) or "Unknown System"
	return {
		stationKey = tostring(station.path),
		stationPath = station.path,
		stationName = station.label or "Starport",
		systemName = sysName,
		cargo = {},
		cargoCostBasis = {},
		modules = {},
	}
end

local function getOrCreateVault(station)
	local key = tostring(station.path)
	local vault = vaults[key]
	if not vault then
		vault = makeVault(station)
		vaults[key] = vault
	else
		vault.stationName = station.label or vault.stationName
		vault.systemName = (Game.system and Game.system.name) or vault.systemName
		vault.stationPath = station.path or vault.stationPath
	end
	return vault
end

local function pruneIfEmpty(key)
	local vault = vaults[key]
	if vault and StationStorage.IsVaultEmpty(vault) then
		vaults[key] = nil
	end
end

function StationStorage.GetLimits()
	return MAX_CARGO_TONNES, MAX_MODULE_SLOTS
end

function StationStorage.GetStationKey(stationOrPath)
	if not stationOrPath then return nil end
	local path = stationOrPath.path or stationOrPath
	return path and tostring(path) or nil
end

function StationStorage.IsDepositAllowed(station)
	if not station then return false end
	local PenalSystem = getPenalSystem()
	if PenalSystem and PenalSystem.IsPrisonStation and PenalSystem.IsPrisonStation(station) then
		return false
	end
	return TaxAuthority.IsHomeStation(station) == true
end

function StationStorage.GetVault(stationOrPath)
	local key = StationStorage.GetStationKey(stationOrPath)
	if not key then return nil end
	return vaults[key]
end

function StationStorage.GetVaultCargoUsed(vault)
	if not vault or not vault.cargo then return 0 end
	local used = 0
	for cname, count in pairs(vault.cargo) do
		if count > 0 then
			local comm = Commodities[cname]
			local mass = (comm and comm.mass) or 1
			used = used + count * mass
		end
	end
	return used
end

function StationStorage.GetVaultModuleCount(vault)
	if not vault or not vault.modules then return 0 end
	return #vault.modules
end

function StationStorage.IsVaultEmpty(vault)
	if not vault then return true end
	if StationStorage.GetVaultModuleCount(vault) > 0 then
		return false
	end
	for _, count in pairs(vault.cargo or {}) do
		if count > 0 then
			return false
		end
	end
	return true
end

function StationStorage.GetAllNonEmptyVaults()
	local out = {}
	local emptyKeys = {}
	for key, vault in pairs(vaults) do
		if StationStorage.IsVaultEmpty(vault) then
			table.insert(emptyKeys, key)
		else
			table.insert(out, vault)
		end
	end
	for _, k in ipairs(emptyKeys) do
		vaults[k] = nil
	end
	table.sort(out, function(a, b)
		if (a.systemName or "") ~= (b.systemName or "") then
			return (a.systemName or "") < (b.systemName or "")
		end
		return (a.stationName or "") < (b.stationName or "")
	end)
	return out
end

-- ============================================================================
-- Shared Equipment Safety & Packing Helpers (used by Vault & PlayerFleet)
-- ============================================================================

function StationStorage.CanRemoveEquipmentFromShip(ship, equip)
	if not ship or not equip then
		return false, "Invalid ship or module."
	end
	if ship == Game.player then
		local Insurance = getInsurance()
		if Insurance and Insurance.HasClaim and Insurance.HasClaim() then
			return false, "Outfitting and transfers are locked while an insurance claim is pending."
		end
	end

	local equipSet = ship:GetComponent('EquipSet')
	local cacheKey = equipSet and equipSet.cache and equipSet.cache[equip]
	if not cacheKey then
		return false, "Equipment not installed on ship."
	end

	if type(cacheKey) == "string" then
		local slot = equipSet:GetSlotHandle(cacheKey)
		if slot and slot.required then
			return false, "Cannot remove a required hull slot module."
		end
		local prefix = cacheKey .. "##"
		for k, _ in pairs(equipSet.installed) do
			if type(k) == "string" and k:sub(1, #prefix) == prefix then
				return false, "Remove child sub-slot equipment first."
			end
		end
	end

	if equip.CanBeSold and not equip:CanBeSold(ship) then
		return false, "Module cannot be removed right now (occupied cabin or active constraint)."
	end

	local cargoGain = equip.capabilities and equip.capabilities.cargo_cap or 0
	if cargoGain > 0 then
		local capAfter = (ship.cargo_cap or 0) - cargoGain
		if capAfter < (ship.usedCargo or 0) then
			return false, "Unload cargo before removing a cargo rack."
		end
	end

	return true
end

function StationStorage.PackEquipmentRecord(equip)
	local isUsed = rawget(equip, "isUsed") == true
	local integrity = rawget(equip, "integrity")
	if integrity == nil then integrity = 1.0 end
	return {
		id = equip.id,
		count = equip.count,
		integrity = math.clamp(integrity, 0, 1),
		isUsed = isUsed or nil,
		usedPrice = isUsed and rawget(equip, "price") or nil,
		subsidized = (rawget(equip, "price") == 0) or (equip.insuranceSubsidized == true) or nil,
	}
end

function StationStorage.InstantiateRecordForConfig(rec, config)
	if not rec or not rec.id then return nil end
	local proto = Equipment.Get(rec.id)
	if not proto then return nil end
	local inst = proto:Instance()
	if inst.SpecializeForShip and config then
		inst:SpecializeForShip(config)
	end
	if rec.count and inst.SetCount then
		inst:SetCount(rec.count)
	end
	if rec.integrity ~= nil then
		inst.integrity = math.clamp(rec.integrity, 0, 1)
	end
	if rec.subsidized then
		inst.price = 0
		inst.insuranceSubsidized = true
	else
		if rec.isUsed then inst.isUsed = true end
		if rec.usedPrice ~= nil then inst.price = rec.usedPrice end
	end
	return inst
end

function StationStorage.CanInstallRecordOnShip(ship, rec)
	if not ship or not rec then
		return false, "Invalid ship or module record."
	end
	if ship == Game.player then
		local Insurance = getInsurance()
		if Insurance and Insurance.HasClaim and Insurance.HasClaim() then
			return false, "Outfitting locked while an insurance claim is pending."
		end
	end

	local equipSet = ship:GetComponent('EquipSet')
	local config = HullConfig.GetHullConfig(ship.shipId)
	if not equipSet or not config then
		return false, "Missing ship equipment configuration."
	end

	local inst = StationStorage.InstantiateRecordForConfig(rec, config)
	if not inst then
		return false, "Unknown module prototype."
	end

	if inst.slot then
		local slots = {}
		for id, slot in pairs(equipSet.slotCache) do
			if not equipSet.installed[id] then
				table.insert(slots, { id = id, slot = slot })
			end
		end
		table.sort(slots, function(a, b) return a.id < b.id end)

		for _, item in ipairs(slots) do
			local slot = item.slot
			local countOk = (slot.count == nil) or ((rec.count or 1) == slot.count)
			if countOk and slot.hardpoint == inst.slot.hardpoint and equipSet:CanInstallInSlot(slot, inst) then
				return true, slot, inst
			end
		end
		return false, "No compatible free slot or insufficient equipment volume."
	else
		if equipSet:CanInstallLoose(inst) then
			return true, nil, inst
		end
		return false, "Insufficient free equipment volume."
	end
end

function StationStorage.InstallRecordOnShip(ship, rec)
	local ok, slotOrErr, inst = StationStorage.CanInstallRecordOnShip(ship, rec)
	if not ok then
		return false, slotOrErr
	end
	local equipSet = ship:GetComponent('EquipSet')
	if not equipSet:Install(inst, slotOrErr) then
		return false, "Failed to install module."
	end
	syncSubsystems(ship)
	return true, inst
end

-- ============================================================================
-- Vault Cargo & Module Operations
-- ============================================================================

function StationStorage.DepositCargoFromFlagship(station, commodityName, amount)
	if not StationStorage.IsDepositAllowed(station) then
		return false, "Deposits are only permitted at your registered home residency station."
	end
	local comm = Commodities[commodityName]
	local qty = math.floor(tonumber(amount) or 0)
	if not comm or qty <= 0 then
		return false, "Invalid commodity or quantity."
	end

	local player = Game.player
	local cargoMgr = player and player:GetComponent('CargoManager')
	if not cargoMgr then return false, "No cargo manager available." end

	local vault = getOrCreateVault(station)
	local unitMass = comm.mass or 1
	local freeVault = math.max(0, MAX_CARGO_TONNES - StationStorage.GetVaultCargoUsed(vault))
	local maxBySpace = math.floor(freeVault / unitMass)
	local avail = cargoMgr:CountCommodity(comm)
	local moveCount = math.min(qty, avail, maxBySpace)
	if moveCount <= 0 then
		return false, (avail <= 0) and "No cargo to store." or "Resident vault cargo capacity reached (500t)."
	end

	local unitBasis = TaxAuthority.GetCommodityCostBasis(commodityName) or 0
	local removed = cargoMgr:RemoveCommodity(comm, moveCount)
	if removed > 0 then
		TaxAuthority.AdjustCommodityCostBasis(commodityName, -removed, unitBasis)
		local oldQty = vault.cargo[commodityName] or 0
		local oldBasis = (vault.cargoCostBasis and vault.cargoCostBasis[commodityName]) or 0
		local newQty = oldQty + removed
		vault.cargoCostBasis = vault.cargoCostBasis or {}
		vault.cargoCostBasis[commodityName] = ((oldQty * oldBasis) + (removed * unitBasis)) / newQty
		vault.cargo[commodityName] = newQty
		return true, string.format("Stored %dt %s in resident vault.", removed, comm:GetName())
	end
	return false, "Failed to store cargo."
end

function StationStorage.WithdrawCargoToFlagship(station, commodityName, amount)
	if not station then return false, "Must be docked at a station." end
	local key = tostring(station.path)
	local vault = vaults[key]
	if not vault then return false, "No storage vault at this station." end

	local comm = Commodities[commodityName]
	local qty = math.floor(tonumber(amount) or 0)
	if not comm or qty <= 0 then
		return false, "Invalid commodity or quantity."
	end

	local player = Game.player
	local cargoMgr = player and player:GetComponent('CargoManager')
	if not cargoMgr then return false, "No cargo manager available." end

	local avail = (vault.cargo and vault.cargo[commodityName]) or 0
	local unitMass = comm.mass or 1
	local maxBySpace = math.floor(cargoMgr:GetFreeSpace() / unitMass)
	local moveCount = math.min(qty, avail, maxBySpace)
	if moveCount <= 0 then
		return false, (avail <= 0) and "Commodity not in vault." or "Insufficient free space in flagship cargo hold."
	end

	if cargoMgr:AddCommodity(comm, moveCount) then
		local unitBasis = (vault.cargoCostBasis and vault.cargoCostBasis[commodityName]) or 0
		TaxAuthority.AdjustCommodityCostBasis(commodityName, moveCount, unitBasis)
		vault.cargo[commodityName] = avail - moveCount
		if vault.cargo[commodityName] <= 0 then
			vault.cargo[commodityName] = nil
			if vault.cargoCostBasis then
				vault.cargoCostBasis[commodityName] = nil
			end
		end
		pruneIfEmpty(key)
		return true, string.format("Withdrew %dt %s to Flagship.", moveCount, comm:GetName())
	end
	return false, "Failed to withdraw cargo."
end

function StationStorage.DepositModuleFromFlagship(station, equip)
	if not StationStorage.IsDepositAllowed(station) then
		return false, "Module storage is only permitted at your registered home residency station."
	end
	local vault = getOrCreateVault(station)
	if #vault.modules >= MAX_MODULE_SLOTS then
		return false, string.format("Resident module vault full (%d/%d).", #vault.modules, MAX_MODULE_SLOTS)
	end

	local player = Game.player
	local okRem, err = StationStorage.CanRemoveEquipmentFromShip(player, equip)
	if not okRem then
		return false, err
	end

	local rec = StationStorage.PackEquipmentRecord(equip)
	rec.uid = nextModuleUid
	nextModuleUid = nextModuleUid + 1

	local equipSet = player:GetComponent('EquipSet')
	if not equipSet:Remove(equip) then
		return false, "Failed to remove module from Flagship."
	end
	syncSubsystems(player)

	table.insert(vault.modules, rec)
	return true, string.format("Stored %s in resident vault.", equip:GetName())
end

function StationStorage.InstallModuleToFlagship(station, moduleUid)
	if not station then return false, "Must be docked at a station." end
	local key = tostring(station.path)
	local vault = vaults[key]
	if not vault or not vault.modules then
		return false, "No stored modules at this station."
	end

	local foundIdx, rec = nil, nil
	for i, m in ipairs(vault.modules) do
		if m.uid == moduleUid then
			foundIdx = i
			rec = m
			break
		end
	end
	if not rec then
		return false, "Stored module not found."
	end

	local okInst, instOrErr = StationStorage.InstallRecordOnShip(Game.player, rec)
	if not okInst then
		return false, instOrErr
	end

	table.remove(vault.modules, foundIdx)
	pruneIfEmpty(key)
	return true, string.format("Installed %s onto Flagship.", instOrErr:GetName())
end

function StationStorage.GetModuleResellPrice(station, rec)
	if not rec or rec.subsidized then return 0 end
	local proto = Equipment.Get(rec.id)
	if not proto then return 0 end
	local base = (rec.isUsed and rec.usedPrice)
		or (station and station:GetEquipmentPrice(proto))
		or proto.price
		or 0
	return math.max(0, math.floor(base * (Economy.BaseResellPriceModifier or 0.8) + 0.5))
end

function StationStorage.InstallModuleToSlot(station, moduleUid, ship, slotHandle)
	if not station or not ship then
		return false, "Must be docked at a station."
	end
	local Insurance = getInsurance()
	if ship == Game.player and Insurance and Insurance.HasClaim and Insurance.HasClaim() then
		return false, "Outfitting locked while an insurance claim is pending."
	end

	local key = tostring(station.path)
	local vault = vaults[key]
	if not vault or not vault.modules then
		return false, "No stored modules at this station."
	end

	local foundIdx, rec = nil, nil
	for i, m in ipairs(vault.modules) do
		if m.uid == moduleUid then
			foundIdx = i
			rec = m
			break
		end
	end
	if not rec then
		return false, "Stored module not found."
	end

	local equipSet = ship:GetComponent('EquipSet')
	local config = HullConfig.GetHullConfig(ship.shipId)
	if not equipSet or not config then
		return false, "Missing ship equipment configuration."
	end

	local inst = StationStorage.InstantiateRecordForConfig(rec, config)
	if not inst then
		return false, "Unknown module prototype."
	end

	if slotHandle then
		local countOk = (slotHandle.count == nil) or ((rec.count or 1) == slotHandle.count)
		if not countOk or not equipSet:CanInstallInSlot(slotHandle, inst) then
			return false, "Module does not fit in selected slot."
		end
		if not equipSet:Install(inst, slotHandle) then
			return false, "Failed to install module in slot."
		end
	else
		if not equipSet:CanInstallLoose(inst) then
			return false, "Insufficient free equipment volume."
		end
		if not equipSet:Install(inst, nil) then
			return false, "Failed to install module."
		end
	end

	syncSubsystems(ship)
	table.remove(vault.modules, foundIdx)
	pruneIfEmpty(key)
	return true, inst
end

function StationStorage.SellModuleFromVault(station, moduleUid)
	if not station then return false, "Must be docked at a station." end
	local Insurance = getInsurance()
	if Insurance and Insurance.HasClaim and Insurance.HasClaim() then
		return false, "Equipment sales are locked while an insurance claim is pending."
	end

	local key = tostring(station.path)
	local vault = vaults[key]
	if not vault or not vault.modules then
		return false, "No stored modules at this station."
	end

	local foundIdx, rec = nil, nil
	for i, m in ipairs(vault.modules) do
		if m.uid == moduleUid then
			foundIdx = i
			rec = m
			break
		end
	end
	if not rec then
		return false, "Stored module not found."
	end

	local proto = Equipment.Get(rec.id)
	local sellPrice = StationStorage.GetModuleResellPrice(station, rec)
	PlayerState.AddMoney(sellPrice)
	if proto and station.AddEquipmentStock then
		station:AddEquipmentStock(proto, 1)
	end

	local eqName = (proto and proto.name) or rec.id
	table.remove(vault.modules, foundIdx)
	pruneIfEmpty(key)

	local okLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okLog and FlightLog and FlightLog.RecordTransaction then
		FlightLog.RecordTransaction({
			category = "EQUIPMENT",
			title = string.format("Vault Module Sold: %s (+%s)", eqName, Format.Money(sellPrice)),
			amount = sellPrice,
			details = {
				{ "Equipment Module", eqName },
				{ "Order Action", "SELL FROM STORAGE" },
				{ "Refund Proceeds", Format.Money(sellPrice) },
			},
			note = string.format("Sold %s directly from station storage at %s.", eqName, station.label or "starport")
		})
	end

	return true, string.format("Sold %s from storage for %s.", eqName, Format.Money(sellPrice, false))
end

function StationStorage.GetCommoditySellPrice(station, commodityName)
	local comm = Commodities[commodityName]
	if not comm then return 0 end
	if not station or (station.exists and not station:exists()) then
		return comm.price or 0
	end
	local PenalSystem = getPenalSystem()
	if PenalSystem and PenalSystem.IsPrisonStation and PenalSystem.IsPrisonStation(station) then
		if PenalSystem.IsPrisonImport and PenalSystem.IsPrisonImport(commodityName) then
			return math.floor((comm.price or 0) * 1.05)
		end
		return math.floor((comm.price or 0) * 0.80)
	end
	local price = station:GetCommodityPrice(comm)
	local sign = price >= 0 and 1 or -1
	local baseCost = price * (1.0 - sign * (Economy.TradeFeeSplit or 0) * 0.01)
	local mult = 1.0
	if Game.system and Game.system.name then
		local okM, MacroEngine = pcall(require, 'modules.MacroGalaxy.MacroGalaxyEngine')
		if okM and MacroEngine and MacroEngine.GetCommodityMultiplier then
			mult = MacroEngine.GetCommodityMultiplier(Game.system.name, commodityName, false) or 1.0
		end
	end
	return math.floor(baseCost * mult * 100) / 100
end

function StationStorage.SellCargoFromVault(station, commodityName, amount)
	if not station then return false, "Must be docked at a station." end
	local key = tostring(station.path)
	local vault = vaults[key]
	if not vault or not vault.cargo then
		return false, "No stored cargo at this station."
	end

	local comm = Commodities[commodityName]
	local avail = vault.cargo[commodityName] or 0
	local qty = math.floor(tonumber(amount) or 0)
	if not comm or avail <= 0 or qty <= 0 then
		return false, "No stored cargo available to sell."
	end

	local sellQty = math.min(qty, avail)
	local unitPrice = StationStorage.GetCommoditySellPrice(station, commodityName)
	local proceeds = unitPrice * sellQty

	PlayerState.AddMoney(proceeds)
	if station.AddCommodityStock then
		station:AddCommodityStock(comm, sellQty)
	end

	local basis = (vault.cargoCostBasis and vault.cargoCostBasis[commodityName]) or 0
	if TaxAuthority.AdjustCommodityCostBasis and TaxAuthority.RecordCommoditySale then
		TaxAuthority.AdjustCommodityCostBasis(commodityName, sellQty, basis)
		TaxAuthority.RecordCommoditySale(commodityName, sellQty, unitPrice)
	end

	vault.cargo[commodityName] = avail - sellQty
	if vault.cargo[commodityName] <= 0 then
		vault.cargo[commodityName] = nil
		if vault.cargoCostBasis then
			vault.cargoCostBasis[commodityName] = nil
		end
	end
	pruneIfEmpty(key)

	local okLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okLog and FlightLog and FlightLog.RecordTransaction then
		FlightLog.RecordTransaction({
			category = "TRADE",
			title = string.format("Sold Stored %dt %s (+%s)", sellQty, comm:GetName(), Format.Money(proceeds)),
			amount = proceeds,
			details = {
				{ "Commodity Item", comm:GetName() },
				{ "Order Action", "SELL FROM STORAGE" },
				{ "Quantity", string.format("%d tons", sellQty) },
				{ "Unit Price", Format.Money(unitPrice) },
				{ "Gross Sale Proceeds", Format.Money(proceeds) },
			},
			note = string.format("Sold %dt %s from storage at %s.", sellQty, comm:GetName(), station.label or "starport")
		})
	end

	return true, string.format("Sold %dt %s from storage for %s.", sellQty, comm:GetName(), Format.Money(proceeds, false))
end

function StationStorage.EstimateCourierFee(fromStationKey, destStation)
	local fromVault = vaults[fromStationKey]
	if not fromVault or not destStation then return 0, 0, 0, 0 end

	local distLy = 10
	if fromVault.stationPath and destStation.path then
		local okDist, d = pcall(function()
			return fromVault.stationPath:SystemOnly():DistanceTo(destStation.path:SystemOnly())
		end)
		if okDist and type(d) == "number" then
			distLy = d
		end
	end

	local cargoTonnes = StationStorage.GetVaultCargoUsed(fromVault)
	local moduleCount = StationStorage.GetVaultModuleCount(fromVault)
	local fee = 500 + math.floor(distLy * 120) + cargoTonnes * 25 + moduleCount * 200
	return fee, distLy, cargoTonnes, moduleCount
end

function StationStorage.CourierTransferVault(fromStationKey, destStation)
	if not StationStorage.IsDepositAllowed(destStation) then
		return false, "You must be docked at your registered residency station to receive courier transfers."
	end
	local destKey = tostring(destStation.path)
	if fromStationKey == destKey then
		return false, "Source and destination vaults are identical."
	end

	local fromVault = vaults[fromStationKey]
	if not fromVault or StationStorage.IsVaultEmpty(fromVault) then
		return false, "Source vault is empty."
	end

	local destVault = getOrCreateVault(destStation)
	local srcCargo = StationStorage.GetVaultCargoUsed(fromVault)
	local dstCargo = StationStorage.GetVaultCargoUsed(destVault)
	if (dstCargo + srcCargo) > MAX_CARGO_TONNES then
		return false, string.format("Combined cargo (%dt) exceeds %dt vault limit.", dstCargo + srcCargo, MAX_CARGO_TONNES)
	end

	local srcMods = StationStorage.GetVaultModuleCount(fromVault)
	local dstMods = StationStorage.GetVaultModuleCount(destVault)
	if (dstMods + srcMods) > MAX_MODULE_SLOTS then
		return false, string.format("Combined modules (%d) exceed %d vault limit.", dstMods + srcMods, MAX_MODULE_SLOTS)
	end

	local fee = StationStorage.EstimateCourierFee(fromStationKey, destStation)
	if PlayerState.GetMoney() < fee then
		return false, string.format("Insufficient credits for courier haul (%s required).", Format.Money(fee, false))
	end

	PlayerState.AddMoney(-fee)
	TaxAuthority.RecordOperatingExpense(fee, "LOGISTICS", "Station Vault Courier")

	destVault.cargo = destVault.cargo or {}
	destVault.cargoCostBasis = destVault.cargoCostBasis or {}
	for cname, qty in pairs(fromVault.cargo or {}) do
		if qty > 0 then
			local oldQty = destVault.cargo[cname] or 0
			local oldBasis = destVault.cargoCostBasis[cname] or 0
			local srcBasis = (fromVault.cargoCostBasis and fromVault.cargoCostBasis[cname]) or 0
			local newQty = oldQty + qty
			destVault.cargoCostBasis[cname] = ((oldQty * oldBasis) + (qty * srcBasis)) / newQty
			destVault.cargo[cname] = newQty
		end
	end

	destVault.modules = destVault.modules or {}
	for _, m in ipairs(fromVault.modules or {}) do
		table.insert(destVault.modules, m)
	end

	local srcLabel = string.format("%s (%s)", fromVault.stationName or "Former Port", fromVault.systemName or "System")
	vaults[fromStationKey] = nil

	local okLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okLog and FlightLog and FlightLog.RecordTransaction then
		FlightLog.RecordTransaction({
			category = "LOGISTICS",
			title = string.format("Vault Courier Transfer from %s (-%s)", fromVault.stationName or "Former Port", Format.Money(fee, false)),
			amount = -fee,
			details = {
				{ "Origin Vault", srcLabel },
				{ "Destination", destStation.label or "Home Port" },
				{ "Cargo Relocated", string.format("%dt", srcCargo) },
				{ "Modules Relocated", tostring(srcMods) },
			},
			note = string.format("Transferred resident storage contents to %s.", destStation.label or "Home Port")
		})
	end

	return true, string.format("Transferred %dt cargo and %d modules from %s for %s.",
		srcCargo, srcMods, fromVault.stationName or "former vault", Format.Money(fee, false))
end

local function onGameEnd()
	vaults = {}
	nextModuleUid = 1
end

local function serialize()
	return {
		vaults = vaults,
		nextModuleUid = nextModuleUid,
	}
end

local function unserialize(data)
	vaults = (data and data.vaults) or {}
	nextModuleUid = (data and data.nextModuleUid) or 1
end

Event.Register("onGameEnd", onGameEnd)
Serializer:Register("StationStorage", serialize, unserialize)

return StationStorage

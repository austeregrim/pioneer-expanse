-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

--
-- Module: PlayerFleet
--
-- Plan A: Multi-Ship Ownership, Station Hangars, Crewed Fleet & X4-Style Autonomy.
-- Manages player-owned secondary ships, station hangar storage, crew/captain
-- assignment, skill progression, autonomous fleet orders (Follow, Dock,
-- Auto-Trade, Auto-Mine, Patrol), autonomous mission delegation, and
-- dual In-System (IS) / Out-of-System (OOS) simulation.
--

local Game            = require 'Game'
local Space           = require 'Space'
local Event           = require 'Event'
local Timer           = require 'Timer'
local Engine          = require 'Engine'
local Character       = require 'Character'
local ShipDef         = require 'ShipDef'
local HullConfig      = require 'HullConfig'
local Equipment       = require 'Equipment'
local EquipSet        = require 'EquipSet'
local Commodities     = require 'Commodities'
local Economy         = require 'Economy'
local Format          = require 'Format'
local Comms           = require 'Comms'
local Serializer      = require 'Serializer'
local PlayerState     = require 'PlayerState'
local Passengers      = require 'Passengers'
local FactionStanding = require 'FactionStanding'
local Ship            = require 'Ship'
local SystemPath      = package.core['SystemPath']

local CAPTAIN_SIGNING_BONUS = 1500
local FERRY_BASE_FEE        = 250
local FERRY_PER_LY_FEE      = 180
local MAX_LOG_ENTRIES       = 80
local TICK_INTERVAL_SEC     = 8

local SHIP_SELL_RATIO       = 0.65
local EQUIP_SELL_RATIO      = 0.80

---@class PlayerFleet
local PlayerFleet = {}

-- Persistent state serialized into savefiles
local fleetState = {
	ships = {},
	nextUid = 1,
	tradeBudget = 50000,
	totalProfit = 0,
	logs = {},
}

local tickTimerActive = false

-- ============================================================================
-- Helpers & Logging
-- ============================================================================

local function addLog(shipName, message, deltaCredits)
	table.insert(fleetState.logs, 1, {
		time = Game.time or 0,
		shipName = shipName or "Fleet Command",
		message = message,
		delta = deltaCredits or 0,
	})
	while #fleetState.logs > MAX_LOG_ENTRIES do
		table.remove(fleetState.logs)
	end
end

local function formatPathName(path)
	if not path then return "Unknown Location" end
	local okBody, sbody = pcall(function() return path:GetSystemBody() end)
	local okSys, sys = pcall(function() return path:GetStarSystem() end)
	if okBody and sbody and okSys and sys then
		return string.format("%s (%s)", sbody.name, sys.name)
	elseif okSys and sys then
		return sys.name
	end
	return "Deep Space"
end

local function samePath(a, b)
	if not a or not b then return false end
	return a == b
end

local function sameSystem(a, b)
	if not a or not b then return false end
	local ok, res = pcall(function() return a:IsSameSystem(b) end)
	return ok and res
end

local function findShipIndex(uid)
	for i, entry in ipairs(fleetState.ships) do
		if entry.uid == uid then
			return i, entry
		end
	end
	return nil, nil
end

function PlayerFleet.GetShipByUid(uid)
	local _, entry = findShipIndex(uid)
	return entry
end

function PlayerFleet.GetShips()
	return fleetState.ships
end

function PlayerFleet.GetLogs()
	return fleetState.logs
end

function PlayerFleet.GetTradeBudget()
	return fleetState.tradeBudget or 50000
end

function PlayerFleet.SetTradeBudget(amount)
	fleetState.tradeBudget = math.max(0, math.floor(amount or 0))
end

function PlayerFleet.GetTotalProfit()
	return fleetState.totalProfit or 0
end

function PlayerFleet.GetShipsAtStation(stationPath)
	local res = {}
	if not stationPath then return res end
	for _, entry in ipairs(fleetState.ships) do
		if entry.status == "DOCKED" and samePath(entry.locationPath, stationPath) then
			table.insert(res, entry)
		end
	end
	return res
end

function PlayerFleet.GetCargoUsed(entry)
	local used = 0
	for name, count in pairs(entry.cargo or {}) do
		local comm = Commodities[name]
		local unitMass = (comm and comm.mass) or 1
		used = used + unitMass * count
	end
	return used
end

function PlayerFleet.GetCargoFree(entry)
	local cap = entry.cargoCap or (ShipDef[entry.shipId] and ShipDef[entry.shipId].cargo) or 0
	return math.max(0, cap - PlayerFleet.GetCargoUsed(entry))
end

function PlayerFleet.HasHyperdrive(entry)
	for _, eq in ipairs(entry.equip or {}) do
		local proto = Equipment.Get(eq.id)
		if proto and proto.capabilities and proto.capabilities.hyperclass and proto.capabilities.hyperclass > 0 then
			return true, proto.capabilities.hyperclass
		end
	end
	return false, 0
end

function PlayerFleet.GetShipHyperspaceRange(entry)
	local hasDrive, hclass = PlayerFleet.HasHyperdrive(entry)
	if not hasDrive then return 0 end
	local def = ShipDef[entry.shipId]
	local fuel = math.max(0, (entry.fuel or 0) / 100)
	local baseRange = 6 + hclass * 4.5
	if def and def.hullMass and def.hullMass > 150 then
		baseRange = baseRange * 0.85
	end
	return math.floor(baseRange * (0.4 + 0.6 * fuel))
end

function PlayerFleet.GetShipCombatScore(entry)
	local weapons = 0
	local shields = 0
	for _, eq in ipairs(entry.equip or {}) do
		local proto = Equipment.Get(eq.id)
		if proto and proto.slot and proto.slot.type then
			if string.find(proto.slot.type, "weapon", 1, true) then
				weapons = weapons + 1
			elseif string.find(proto.slot.type, "shield", 1, true) then
				shields = shields + 1
			end
		end
	end
	local captainSkill = entry.captain and ((entry.captain.piloting or 15) / 20) or 0.5
	return weapons * 25 + shields * 15 + math.floor(captainSkill * 20)
end

-- ============================================================================
-- Serialization / Packing between Live Ships & Fleet Entries
-- ============================================================================

local function clearShipCargo(ship)
	local cargoMgr = ship:GetComponent('CargoManager')
	if not cargoMgr then return end
	local toRemove = {}
	for name, count in cargoMgr:Commodities() do
		if count > 0 then
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

local function packEquipFromShip(ship)
	local list = {}
	local equipSet = ship:GetComponent('EquipSet')
	if not equipSet then return list end
	for key, eq in pairs(equipSet.installed) do
		table.insert(list, {
			slotId = (type(key) == "string") and key or nil,
			id = eq.id,
			count = eq.count,
		})
	end
	-- Parent slots first (shortest slotId), loose items last
	table.sort(list, function(a, b)
		if a.slotId and b.slotId then
			if #a.slotId ~= #b.slotId then return #a.slotId < #b.slotId end
			return a.slotId < b.slotId
		end
		return a.slotId ~= nil and b.slotId == nil
	end)
	return list
end

local function applyEquipListToShip(ship, equipList)
	local equipSet = ship:GetComponent('EquipSet')
	local config = HullConfig.GetHullConfig(ship.shipId)
	if not equipSet or not config then return end

	local ordered = {}
	for _, item in ipairs(equipList or {}) do
		table.insert(ordered, item)
	end
	table.sort(ordered, function(a, b)
		if a.slotId and b.slotId then
			if #a.slotId ~= #b.slotId then return #a.slotId < #b.slotId end
			return a.slotId < b.slotId
		end
		return a.slotId ~= nil and b.slotId == nil
	end)

	for _, item in ipairs(ordered) do
		local proto = Equipment.Get(item.id)
		if proto then
			local inst = proto:Instance()
			if inst.SpecializeForShip then
				inst:SpecializeForShip(config)
			end
			if item.count and inst.SetCount then
				inst:SetCount(item.count)
			end

			if item.slotId then
				local handle = equipSet:GetSlotHandle(item.slotId)
				if handle and equipSet:CanInstallInSlot(handle, inst) then
					equipSet:Install(inst, handle)
				else
					local freeSlot = equipSet:GetFreeSlotForEquip(inst)
					if freeSlot and equipSet:CanInstallInSlot(freeSlot, inst) then
						equipSet:Install(inst, freeSlot)
					end
				end
			else
				if equipSet:CanInstallLoose(inst) then
					equipSet:Install(inst, nil)
				end
			end
		end
	end
end

local function packCargoFromShip(ship)
	local cargo = {}
	local cargoMgr = ship:GetComponent('CargoManager')
	if cargoMgr then
		for name, count in cargoMgr:Commodities() do
			if count > 0 then
				cargo[name] = count
			end
		end
	end
	return cargo
end

local function applyCargoToShip(ship, cargo)
	clearShipCargo(ship)
	local cargoMgr = ship:GetComponent('CargoManager')
	if not cargoMgr then return end
	for name, count in pairs(cargo or {}) do
		local comm = Commodities[name]
		if comm and count > 0 then
			cargoMgr:AddCommodity(comm, count)
		end
	end
end

local function buildDefaultEquipForAdvert(def, advertEquip)
	local list = {}
	for _, pair in ipairs(advertEquip or {}) do
		local slotId, inst = pair[1], pair[2]
		table.insert(list, {
			slotId = slotId,
			id = inst.id,
			count = inst.count,
		})
	end
	-- Ensure hyperdrive is included if chassis supports one
	local hasHyper = false
	for _, eq in ipairs(list) do
		local proto = Equipment.Get(eq.id)
		if proto and proto.capabilities and proto.capabilities.hyperclass then
			hasHyper = true
			break
		end
	end
	if not hasHyper and def.hyperdriveClass > 0 then
		local config = HullConfig.GetHullConfig(def.id)
		if config then
			for _, slot in pairs(config.slots) do
				if EquipSet.SlotTypeMatches("hyperdrive", slot.type) then
					local best = nil
					local bestClass = -1
					for _, eq in pairs(Equipment.new) do
						if EquipSet.CompatibleWithSlot(eq, slot) and eq.slot and eq.slot.type:match("%.civilian") then
							local hc = eq.capabilities and eq.capabilities.hyperclass or 0
							if hc > bestClass then
								bestClass = hc
								best = eq
							end
						end
					end
					if best then
						table.insert(list, { slotId = slot.id, id = best.id })
					end
					break
				end
			end
		end
	end
	return list
end

local function createFleetEntryFromShip(ship, stationPath, customName)
	local def = ShipDef[ship.shipId]
	local uid = fleetState.nextUid
	fleetState.nextUid = uid + 1

	local label = (ship.label and ship.label ~= "") and ship.label or Ship.MakeRandomLabel()
	local name = (customName and customName ~= "") and customName
		or (ship.shipName and ship.shipName ~= "" and ship.shipName)
		or string.format("%s [%s]", def.name, label)

	local entry = {
		uid = uid,
		shipName = name,
		label = label,
		shipId = ship.shipId,
		skin = ship:GetSkin(),
		pattern = ship.model and ship.model.pattern or 0,
		hullPercent = math.clamp(ship.hullPercent or 100, 1, 100),
		shieldPercent = 100,
		fuel = math.clamp(ship.fuel or 100, 0, 100),
		cargoCap = ship.cargo_cap or def.cargo,
		equip = packEquipFromShip(ship),
		cargo = packCargoFromShip(ship),
		locationPath = stationPath,
		locationName = formatPathName(stationPath),
		status = "DOCKED",
		captain = nil,
		crew = {},
		order = "IDLE",
		orderTargetPath = nil,
		orderTargetName = nil,
		orderParams = { maxJumps = 12, autoSell = true },
		orderProgress = 0,
		orderEta = 0,
		orderPhase = "Docked on standby",
		missionRef = nil,
		liveShip = nil,
		stats = {
			netProfit = 0,
			runsCompleted = 0,
			bountiesEarned = 0,
			missionsDone = 0,
			cargoHauled = 0,
		},
	}
	return entry
end

-- Sync hull, fuel, and cargo from an active liveShip back into its FleetEntry
local function syncFromLiveShip(entry)
	local s = entry.liveShip
	if not s or not s:exists() then
		entry.liveShip = nil
		return
	end
	entry.hullPercent = math.clamp(s.hullPercent or entry.hullPercent or 100, 1, 100)
	entry.fuel = math.clamp(s.fuel or entry.fuel or 100, 0, 100)
	entry.cargo = packCargoFromShip(s)
end

local function despawnLiveShip(entry)
	if entry.liveShip and entry.liveShip:exists() then
		syncFromLiveShip(entry)
		-- Remove cleanly by letting Pioneer clean docked/out-of-range bodies, or vanish if docked
	end
	entry.liveShip = nil
end

-- ============================================================================
-- Valuation & Ship Market Purchases
-- ============================================================================

function PlayerFleet.ComputeShipValue(entry)
	local def = ShipDef[entry.shipId]
	if not def then return 0 end

	local value = def.basePrice * SHIP_SELL_RATIO * ((entry.hullPercent or 100) / 100)
	for _, eq in ipairs(entry.equip or {}) do
		local proto = Equipment.Get(eq.id)
		if proto and proto.price then
			value = value + (proto.price * (eq.count or 1) * EQUIP_SELL_RATIO)
		end
	end
	for name, count in pairs(entry.cargo or {}) do
		local comm = Commodities[name]
		if comm and comm.price then
			value = value + (comm.price * count)
		end
	end
	return math.ceil(value)
end

-- Helper to move a crew member cleanly off Game.player without terminating their fleet employment
local function transferCrewFromPlayerInternal(crewMember)
	if not crewMember or crewMember.player then return nil end
	local savedContract = crewMember.contract and {
		wage = crewMember.contract.wage,
		payday = crewMember.contract.payday,
		outstanding = crewMember.contract.outstanding or 0,
	} or nil
	crewMember.fleetWage = savedContract and savedContract.wage or (crewMember.fleetWage or 50)
	crewMember.fleetPayday = savedContract and savedContract.payday or (Game.time + 604800)

	Game.player:Dismiss(crewMember)
	-- Undo Save()/availability release since they remain in player's fleet service
	crewMember:UnSave()
	crewMember.available = false
	if savedContract then
		-- Note: onLeaveCrew event clears crewMember.contract async; PlayerFleet keeps fleetWage/fleetPayday
		crewMember.contract = savedContract
	end
	return crewMember
end

local function enrollCrewBackOnPlayer(crewMember)
	if not crewMember or crewMember.player then return false end
	if not crewMember.contract then
		crewMember.contract = {
			wage = crewMember.fleetWage or 50,
			payday = crewMember.fleetPayday or (Game.time + 604800),
			outstanding = 0,
		}
	end
	crewMember.available = true
	local ok = Game.player:Enroll(crewMember)
	if not ok then
		crewMember.available = false
	end
	return ok
end

local function setupPlayerShipFromAdvert(player, sos, advertData)
	local def = sos.def
	clearShipCargo(player)
	player:SetShipType(def.id)
	player:SetSkin(sos.skin)
	if sos.pattern then player.model:SetPattern(sos.pattern) end
	player:SetLabel(sos.label)

	local equipSet = player:GetComponent('EquipSet')
	for _, pair in ipairs(advertData.equip or {}) do
		local handle = equipSet:GetSlotHandle(pair[1])
		if handle and equipSet:CanInstallInSlot(handle, pair[2]) then
			local copyInst = Equipment.Get(pair[2].id):Instance()
			local cfg = HullConfig.GetHullConfig(def.id)
			if copyInst.SpecializeForShip and cfg then copyInst:SpecializeForShip(cfg) end
			if pair[2].count and copyInst.SetCount then copyInst:SetCount(pair[2].count) end
			equipSet:Install(copyInst, handle)
		end
	end

	if def.hyperdriveClass > 0 and not player:GetInstalledHyperdrive() then
		local slot = equipSet:GetAllSlotsOfType('hyperdrive')[1]
		if slot then
			local hyperdrive = nil
			local bestScore = -1
			for _, equip in pairs(Equipment.new) do
				if EquipSet.CompatibleWithSlot(equip, slot) and equip.slot and equip.slot.type:match("%.civilian") then
					local hc = equip.capabilities and equip.capabilities.hyperclass or 0
					if hc > bestScore then
						bestScore = hc
						hyperdrive = equip
					end
				end
			end
			if hyperdrive then
				equipSet:Install(hyperdrive:Instance(), slot)
			end
		end
	end

	player:SetFuelPercent(100)
end

-- Buy a ship and store Game.player's current ship in the station's hangar (no trade-in)
function PlayerFleet.StorePlayerShipAndBuy(sos, advertData)
	local player = Game.player
	local station = player:GetDockedWith()
	if not station then
		return false, "Must be docked at a station."
	end
	local cost = advertData.price
	if PlayerState.GetMoney() < cost then
		return false, "Insufficient credits for outright purchase (" .. Format.Money(cost, false) .. ")."
	end
	if Passengers.CountOccupiedBerths(player) > 0 then
		return false, "Cannot store current ship while passengers are embarked."
	end

	local storedEntry = createFleetEntryFromShip(player, station.path)

	-- Offload any non-player crew exceeding new hull capacity onto the stored ship
	local newMax = sos.def.maxCrew or 1
	local currentCount = player:CrewNumber()
	if currentCount > newMax then
		local excess = currentCount - newMax
		local candidates = {}
		for member in player:EachCrewMember() do
			if not member.player then
				table.insert(candidates, member)
			end
		end
		table.sort(candidates, function(a, b)
			return (a.piloting or 0) > (b.piloting or 0)
		end)
		for i = 1, math.min(excess, #candidates) do
			local c = transferCrewFromPlayerInternal(candidates[i])
			if c then
				table.insert(storedEntry.crew, c)
				if not storedEntry.captain then
					storedEntry.captain = c
				end
			end
		end
	end

	PlayerState.AddMoney(-cost)
	station:RemoveShipOnSale(sos)
	setupPlayerShipFromAdvert(player, sos, advertData)

	table.insert(fleetState.ships, storedEntry)
	addLog(storedEntry.shipName, string.format("Stored flagship in hangar at %s upon purchasing %s.", station.label, sos.def.name), -cost)

	return true, string.format("%s stored in hangar at %s. Boarded new %s.", storedEntry.shipName, station.label, sos.def.name)
end

-- Buy a ship directly into the station hangar without changing the player's current flagship
function PlayerFleet.BuyShipToHangar(sos, advertData)
	local player = Game.player
	local station = player:GetDockedWith()
	if not station then
		return false, "Must be docked at a station."
	end
	local cost = advertData.price
	if PlayerState.GetMoney() < cost then
		return false, "Insufficient credits (" .. Format.Money(cost, false) .. " required)."
	end

	local def = sos.def
	local uid = fleetState.nextUid
	fleetState.nextUid = uid + 1

	local label = sos.label or Ship.MakeRandomLabel()
	local entry = {
		uid = uid,
		shipName = string.format("%s [%s]", def.name, label),
		label = label,
		shipId = def.id,
		skin = sos.skin,
		pattern = sos.pattern or 0,
		hullPercent = 100,
		shieldPercent = 100,
		fuel = 100,
		cargoCap = def.cargo,
		equip = buildDefaultEquipForAdvert(def, advertData.equip),
		cargo = {},
		locationPath = station.path,
		locationName = formatPathName(station.path),
		status = "DOCKED",
		captain = nil,
		crew = {},
		order = "IDLE",
		orderTargetPath = nil,
		orderTargetName = nil,
		orderParams = { maxJumps = 12, autoSell = true },
		orderProgress = 0,
		orderEta = 0,
		orderPhase = "Docked at " .. station.label,
		missionRef = nil,
		liveShip = nil,
		stats = {
			netProfit = 0,
			runsCompleted = 0,
			bountiesEarned = 0,
			missionsDone = 0,
			cargoHauled = 0,
		},
	}

	PlayerState.AddMoney(-cost)
	station:RemoveShipOnSale(sos)
	table.insert(fleetState.ships, entry)
	addLog(entry.shipName, string.format("Purchased into hangar at %s.", station.label), -cost)

	return true, string.format("Purchased %s into hangar at %s.", entry.shipName, station.label)
end

-- ============================================================================
-- Hangar Operations (Swap, Transfer, Repair, Refuel, Rename, Ferry, Sell)
-- ============================================================================

function PlayerFleet.SwapWithFlagship(uid)
	local player = Game.player
	local station = player:GetDockedWith()
	if not station then
		return false, "Must be docked at a station to swap ships."
	end
	local idx, entry = findShipIndex(uid)
	if not entry then
		return false, "Fleet vessel not found."
	end
	if entry.status ~= "DOCKED" or not samePath(entry.locationPath, station.path) then
		return false, "Selected vessel must be docked at this station to board."
	end
	if Passengers.CountOccupiedBerths(player) > 0 then
		return false, "Disembark passengers before swapping vessels."
	end

	local targetDef = ShipDef[entry.shipId]
	if not targetDef then
		return false, "Unknown target hull definition."
	end

	-- Pack current player ship
	local parkedOld = createFleetEntryFromShip(player, station.path)

	-- Move excess non-player crew to parkedOld if new ship has fewer berths
	local targetMaxCrew = targetDef.maxCrew or 1
	local nonPlayerCrew = {}
	for member in player:EachCrewMember() do
		if not member.player then
			table.insert(nonPlayerCrew, member)
		end
	end
	if (1 + #nonPlayerCrew) > targetMaxCrew then
		local needRemove = (1 + #nonPlayerCrew) - targetMaxCrew
		for i = 1, needRemove do
			local c = transferCrewFromPlayerInternal(nonPlayerCrew[i])
			if c then
				table.insert(parkedOld.crew, c)
				if not parkedOld.captain then parkedOld.captain = c end
			end
		end
	end

	-- Preserve the boarded ship's captain/crew onto parkedOld if it had a captain and parkedOld doesn't,
	-- so your parked ship remains crew-ready! Otherwise keep its crew or enroll on player if room.
	if entry.captain and not parkedOld.captain and (#parkedOld.crew < (ShipDef[parkedOld.shipId].maxCrew or 1)) then
		for _, c in ipairs(entry.crew or {}) do
			table.insert(parkedOld.crew, c)
		end
		parkedOld.captain = entry.captain
		parkedOld.orderPhase = "Docked with Captain " .. entry.captain.name
	elseif #(entry.crew or {}) > 0 then
		-- Keep crew with the parked old ship if there's room
		for _, c in ipairs(entry.crew) do
			if #parkedOld.crew < (ShipDef[parkedOld.shipId].maxCrew or 1) then
				table.insert(parkedOld.crew, c)
				if c == entry.captain then parkedOld.captain = c end
			else
				enrollCrewBackOnPlayer(c)
			end
		end
	end

	-- Apply target fleet ship onto Game.player
	clearShipCargo(player)
	player:SetShipType(entry.shipId)
	if entry.skin then pcall(function() player:SetSkin(entry.skin) end) end
	if entry.pattern and player.model and player.model.SetPattern then
		pcall(function() player.model:SetPattern(entry.pattern) end)
	end
	player:SetLabel(entry.label)
	if entry.shipName then player:SetShipName(entry.shipName) end

	applyEquipListToShip(player, entry.equip)
	applyCargoToShip(player, entry.cargo)
	player:SetHullPercent(math.clamp(entry.hullPercent or 100, 1, 100))
	player:SetFuelPercent(math.clamp(entry.fuel or 100, 0, 100))

	-- Replace entry in fleet with the parked old flagship
	fleetState.ships[idx] = parkedOld
	addLog(entry.shipName, string.format("Commander boarded at %s (%s stored in hangar).", station.label, parkedOld.shipName), 0)

	return true, string.format("Boarded %s. %s stored in hangar.", entry.shipName, parkedOld.shipName)
end

function PlayerFleet.SellShip(uid)
	local idx, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end
	if entry.status ~= "DOCKED" then
		return false, "Vessel must be docked to be sold."
	end

	local value = PlayerFleet.ComputeShipValue(entry)
	for _, c in ipairs(entry.crew or {}) do
		if not enrollCrewBackOnPlayer(c) then
			c:Save()
		end
	end

	despawnLiveShip(entry)
	table.remove(fleetState.ships, idx)
	PlayerState.AddMoney(value)
	addLog(entry.shipName, string.format("Vessel sold at %s.", entry.locationName or "station"), value)

	return true, string.format("Sold %s for %s.", entry.shipName, Format.Money(value, false))
end

function PlayerFleet.RepairShip(uid)
	local _, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end
	if entry.status ~= "DOCKED" then return false, "Vessel must be docked for hull repairs." end
	local hull = entry.hullPercent or 100
	if hull >= 100 then return false, "Hull is already at 100% integrity." end

	local def = ShipDef[entry.shipId]
	local cost = math.max(50, math.ceil((def and def.basePrice or 10000) * 0.003 * (100 - hull)))
	if PlayerState.GetMoney() < cost then
		return false, string.format("Insufficient credits (%s needed).", Format.Money(cost, false))
	end

	PlayerState.AddMoney(-cost)
	entry.hullPercent = 100
	addLog(entry.shipName, string.format("Hull repaired to 100%% at %s.", entry.locationName), -cost)
	return true, string.format("Repaired %s for %s.", entry.shipName, Format.Money(cost, false))
end

function PlayerFleet.RefuelShip(uid)
	local _, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end
	if entry.status ~= "DOCKED" then return false, "Vessel must be docked to refuel." end
	local fuel = entry.fuel or 0
	if fuel >= 100 then return false, "Fuel tanks are already full." end

	local cost = math.max(20, math.ceil((100 - fuel) * 2.5))
	if PlayerState.GetMoney() < cost then
		return false, string.format("Insufficient credits (%s needed).", Format.Money(cost, false))
	end

	PlayerState.AddMoney(-cost)
	entry.fuel = 100
	addLog(entry.shipName, "Refueled propellant tanks to 100%.", -cost)
	return true, string.format("Refueled %s for %s.", entry.shipName, Format.Money(cost, false))
end

function PlayerFleet.RenameShip(uid, newName)
	local _, entry = findShipIndex(uid)
	if not entry then return false end
	local trimmed = tostring(newName or ""):gsub("^%s*(.-)%s*$", "%1")
	if trimmed == "" then return false end
	entry.shipName = trimmed
	if entry.liveShip and entry.liveShip:exists() then
		entry.liveShip:SetShipName("[FLEET] " .. trimmed)
	end
	return true
end

function PlayerFleet.TransferCargo(uid, commodityName, amount, toFlagship)
	local player = Game.player
	local station = player:GetDockedWith()
	if not station then return false, "Must be docked to transfer cargo." end
	local _, entry = findShipIndex(uid)
	if not entry or entry.status ~= "DOCKED" or not samePath(entry.locationPath, station.path) then
		return false, "Target ship must be docked at the same station."
	end
	local comm = Commodities[commodityName]
	if not comm or amount <= 0 then return false, "Invalid commodity or amount." end

	local cargoMgr = player:GetComponent('CargoManager')
	local unitMass = comm.mass or 1

	if toFlagship then
		local avail = (entry.cargo and entry.cargo[commodityName]) or 0
		local maxBySpace = math.floor(cargoMgr:GetFreeSpace() / unitMass)
		local moveCount = math.min(amount, avail, maxBySpace)
		if moveCount <= 0 then return false, "No cargo or insufficient space on flagship." end

		if cargoMgr:AddCommodity(comm, moveCount) then
			entry.cargo[commodityName] = avail - moveCount
			if entry.cargo[commodityName] <= 0 then entry.cargo[commodityName] = nil end
			return true, string.format("Transferred %dt %s to Flagship.", moveCount, comm:GetName())
		end
	else
		local avail = cargoMgr:CountCommodity(comm)
		local freeDest = PlayerFleet.GetCargoFree(entry)
		local maxBySpace = math.floor(freeDest / unitMass)
		local moveCount = math.min(amount, avail, maxBySpace)
		if moveCount <= 0 then return false, "No cargo or insufficient space on hangar ship." end

		local removed = cargoMgr:RemoveCommodity(comm, moveCount)
		if removed > 0 then
			entry.cargo[commodityName] = (entry.cargo[commodityName] or 0) + removed
			return true, string.format("Transferred %dt %s to %s.", removed, comm:GetName(), entry.shipName)
		end
	end
	return false, "Cargo transfer failed."
end

-- ============================================================================
-- Crew, Captains & Skill Progression (Phase A2)
-- ============================================================================

function PlayerFleet.GetCaptainSkillScore(captain)
	if not captain then return 0 end
	return math.floor(((captain.piloting or 15) + (captain.navigation or 15) + (captain.engineering or 15) + (captain.sensors or 15)) / 4)
end

function PlayerFleet.AwardCaptainXP(entry, primarySkill)
	local cap = entry.captain
	if not cap then return end

	local skills = { "piloting", "navigation", "engineering", "sensors" }
	local chosen = primarySkill or skills[Engine.rand:Integer(1, #skills)]
	local cur = cap[chosen] or 15
	-- Diminishing returns past 65, mirroring Pioneer RPG attributes
	if cur < 65 and Engine.rand:Number(0, 1) < math.max(0.18, (70 - cur) / 80) then
		cap[chosen] = cur + 1
		addLog(entry.shipName, string.format("Captain %s improved %s skill to %d!", cap.name, chosen:gsub("^%l", string.upper), cap[chosen]), 0)
	end

	for _, member in ipairs(entry.crew or {}) do
		if member ~= cap and (member[chosen] or 15) < 60 and Engine.rand:Number(0, 1) < 0.25 then
			member[chosen] = (member[chosen] or 15) + 1
		end
	end
end

function PlayerFleet.AssignCrewFromPlayerShip(uid, crewMember, asCaptain)
	local _, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end
	local def = ShipDef[entry.shipId]
	local maxCrew = (def and def.maxCrew) or 1
	if #(entry.crew or {}) >= maxCrew then
		return false, string.format("%s crew quarters are full (%d/%d).", entry.shipName, #entry.crew, maxCrew)
	end
	if Game.player.flightState ~= "DOCKED" or entry.status ~= "DOCKED" or not samePath(entry.locationPath, Game.player:GetDockedWith().path) then
		return false, "Both ships must be docked at the same station to transfer crew."
	end

	local transferred = transferCrewFromPlayerInternal(crewMember)
	if not transferred then
		return false, "Cannot transfer player commander or invalid crew."
	end

	table.insert(entry.crew, transferred)
	if asCaptain or not entry.captain then
		entry.captain = transferred
		transferred.title = "Captain"
		addLog(entry.shipName, string.format("%s assigned as Captain.", transferred.name), 0)
	else
		addLog(entry.shipName, string.format("%s assigned to crew.", transferred.name), 0)
	end
	return true, string.format("Assigned %s to %s.", transferred.name, entry.shipName)
end

function PlayerFleet.TransferCrewToPlayerShip(uid, crewMember)
	local _, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end
	if Game.player.flightState ~= "DOCKED" or entry.status ~= "DOCKED" or not samePath(entry.locationPath, Game.player:GetDockedWith().path) then
		return false, "Both ships must be docked at the same station to transfer crew."
	end

	local foundIdx = nil
	for i, c in ipairs(entry.crew or {}) do
		if c == crewMember then
			foundIdx = i
			break
		end
	end
	if not foundIdx then return false, "Crew member not aboard this vessel." end

	if not enrollCrewBackOnPlayer(crewMember) then
		return false, "Flagship crew quarters are full."
	end

	table.remove(entry.crew, foundIdx)
	if entry.captain == crewMember then
		entry.captain = entry.crew[1] or nil
		if entry.order ~= "IDLE" and not entry.captain then
			entry.order = "IDLE"
			entry.orderPhase = "Standing down (no Captain aboard)"
		end
	end

	addLog(entry.shipName, string.format("%s transferred to Flagship.", crewMember.name), 0)
	return true, string.format("%s transferred to Flagship.", crewMember.name)
end

function PlayerFleet.SetCaptain(uid, crewMember)
	local _, entry = findShipIndex(uid)
	if not entry then return false end
	for _, c in ipairs(entry.crew or {}) do
		if c == crewMember then
			entry.captain = c
			c.title = "Captain"
			return true
		end
	end
	return false
end

function PlayerFleet.HireInstantCaptain(uid)
	local _, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end
	local def = ShipDef[entry.shipId]
	local maxCrew = (def and def.maxCrew) or 1
	if #(entry.crew or {}) >= maxCrew then
		return false, "Vessel crew quarters are full."
	end
	if entry.status ~= "DOCKED" then
		return false, "Ship must be docked at a station to recruit a Captain."
	end
	if PlayerState.GetMoney() < CAPTAIN_SIGNING_BONUS then
		return false, string.format("Signing bonus of %s required.", Format.Money(CAPTAIN_SIGNING_BONUS, false))
	end

	PlayerState.AddMoney(-CAPTAIN_SIGNING_BONUS)

	local cap = Character.New({
		title       = "Captain",
		engineering = Engine.rand:Integer(18, 38),
		piloting    = Engine.rand:Integer(22, 42),
		navigation  = Engine.rand:Integer(20, 40),
		sensors     = Engine.rand:Integer(18, 36),
		intelligence = Engine.rand:Integer(18, 32),
		available   = false,
	}, Engine.rand)
	cap.fleetWage = 65 + math.floor((cap.piloting + cap.navigation) * 0.5)

	table.insert(entry.crew, cap)
	entry.captain = cap
	addLog(entry.shipName, string.format("Recruited Captain %s at %s.", cap.name, entry.locationName), -CAPTAIN_SIGNING_BONUS)

	return true, string.format("Hired Captain %s for %s.", cap.name, entry.shipName)
end

-- ============================================================================
-- Trade Route, Ring Mining, Patrol & Transit Simulation Engines (Phases A3-A4)
-- ============================================================================

local function getSystemCommodityPrice(sys, comm)
	local ok, price = pcall(function()
		return Economy.GetMarketPrice(comm.price, sys:GetCommodityBasePriceAlterations(comm.name))
	end)
	if ok and price then return math.max(1, math.floor(price)) end
	return math.max(1, math.floor(comm.price or 10))
end

local function findBestTradeRoute(entry)
	local curPath = entry.locationPath
	local curSys = curPath and curPath:GetStarSystem() or Game.system
	if not curSys then return nil end

	local range = PlayerFleet.GetShipHyperspaceRange(entry)
	local searchRange = math.min(range, entry.orderParams.maxJumps or 12)

	local systems = { curSys }
	if searchRange > 1 then
		local ok, near = pcall(function()
			return curSys:GetNearbySystems(searchRange, function(s) return #s:GetStationPaths() > 0 end)
		end)
		if ok and near then
			for _, s in ipairs(near) do
				if s.path ~= curSys.path then
					table.insert(systems, s)
				end
			end
		end
	end

	-- Collect all reachable stations with their star systems
	local stationNodes = {}
	for _, sys in ipairs(systems) do
		local okSt, stPaths = pcall(function() return sys:GetStationPaths() end)
		if okSt and stPaths then
			for _, sp in ipairs(stPaths) do
				table.insert(stationNodes, { sys = sys, path = sp })
			end
		end
	end
	if #stationNodes < 2 then
		-- Fallback: use current station buy + simulated off-world export shuttle run if single-station system
		if #stationNodes == 1 then
			return {
				buyPath = stationNodes[1].path,
				sellPath = stationNodes[1].path,
				buySys = curSys,
				sellSys = curSys,
				comm = Commodities.metal_alloys or next(Commodities) and select(2, next(Commodities)),
				buyPrice = 200,
				sellPrice = 265,
				distLy = 0.2,
			}
		end
		return nil
	end

	local bestRoute = nil
	local bestMargin = 10 -- Minimum profit per ton

	local candidateComms = {
		"metal_alloys", "precious_metals", "computers", "robots", "medicines",
		"consumer_goods", "plastics", "grain", "fruit_and_veg", "textiles",
		"mining_machinery", "industrial_machinery", "liquor", "metal_ore"
	}

	-- Prefer buying at or near curPath to reduce deadhead flights
	local buyNode = stationNodes[1]
	for _, node in ipairs(stationNodes) do
		if samePath(node.path, curPath) then
			buyNode = node
			break
		end
	end

	for _, cname in ipairs(candidateComms) do
		local comm = Commodities[cname]
		if comm and comm.price and comm.price > 0 then
			local buyPrice = getSystemCommodityPrice(buyNode.sys, comm)
			for _, sellNode in ipairs(stationNodes) do
				if not sameSystem(buyNode.sys.path, sellNode.sys.path) or not samePath(buyNode.path, sellNode.path) then
					local sellPrice = getSystemCommodityPrice(sellNode.sys, comm)
					local margin = sellPrice - buyPrice
					if margin > bestMargin then
						local dist = buyNode.sys:DistanceTo(sellNode.sys)
						bestMargin = margin
						bestRoute = {
							buyPath = buyNode.path,
							sellPath = sellNode.path,
							buySys = buyNode.sys,
							sellSys = sellNode.sys,
							comm = comm,
							buyPrice = buyPrice,
							sellPrice = math.max(sellPrice, buyPrice + 15),
							distLy = dist,
						}
					end
				end
			end
		end
	end

	if not bestRoute then
		-- Pick any decent staple trade if local market spread is flat
		local destNode = stationNodes[#stationNodes]
		if samePath(destNode.path, buyNode.path) and #stationNodes > 1 then
			destNode = stationNodes[1]
		end
		local comm = Commodities.consumer_goods or Commodities.metal_alloys
		local buyP = getSystemCommodityPrice(buyNode.sys, comm)
		bestRoute = {
			buyPath = buyNode.path,
			sellPath = destNode.path,
			buySys = buyNode.sys,
			sellSys = destNode.sys,
			comm = comm,
			buyPrice = buyP,
			sellPrice = math.ceil(buyP * 1.18),
			distLy = buyNode.sys:DistanceTo(destNode.sys),
		}
	end

	return bestRoute
end

local function findNearestRingBody(curPath)
	local sys = curPath and curPath:GetStarSystem() or Game.system
	if not sys then return nil, nil end

	local function searchSys(s)
		local ok, paths = pcall(function() return s:GetBodyPaths() end)
		if not ok or not paths then return nil end
		for _, bp in ipairs(paths) do
			local okB, sbody = pcall(function() return bp:GetSystemBody() end)
			if okB and sbody and sbody.hasRings then
				return bp, sbody
			end
		end
		return nil
	end

	local bp, sb = searchSys(sys)
	if bp then return bp, sb end

	local okN, near = pcall(function() return sys:GetNearbySystems(15) end)
	if okN and near then
		for _, ns in ipairs(near) do
			bp, sb = searchSys(ns)
			if bp then return bp, sb end
		end
	end
	return nil, nil
end

local function selectMineCommodity(ringBody)
	local rtype = (ringBody and ringBody.ringType) or "ROCKY"
	local roll = Engine.rand:Number(0, 1)
	if rtype == "METALLIC" then
		if roll < 0.45 and Commodities.precious_metals then return Commodities.precious_metals end
		return Commodities.metal_ore or Commodities.carbon_ore
	elseif rtype == "ICY" then
		if roll < 0.65 and Commodities.water then return Commodities.water end
		return Commodities.hydrogen or Commodities.carbon_ore
	elseif rtype == "METAL_RICH" then
		if roll < 0.30 and Commodities.precious_metals then return Commodities.precious_metals end
		return Commodities.metal_ore or Commodities.carbon_ore
	end
	return (roll < 0.5 and Commodities.carbon_ore) or Commodities.metal_ore or Commodities.water
end

-- ============================================================================
-- In-System Live Ship Management (Dual Simulation IS Layer)
-- ============================================================================

local function spawnOrUpdateLiveFleetShip(entry, spawnNearPlayer)
	if not Game.system or Game.InHyperspace() then return nil end
	if entry.liveShip and entry.liveShip:exists() then
		return entry.liveShip
	end

	local ship = nil
	if spawnNearPlayer then
		local refBody = (Game.player.flightState == "FLYING") and Game.player or Game.player:GetDockedWith()
		if refBody and refBody:exists() then
			local ok, s = pcall(function() return Space.SpawnShipNear(entry.shipId, refBody, 4, 8) end)
			if ok and s then ship = s end
		end
	elseif entry.locationPath and sameSystem(entry.locationPath, Game.system.path) then
		local st = nil
		if entry.locationPath:IsBodyPath() then
			local okB, b = pcall(function() return Space.GetBody(entry.locationPath.bodyIndex) end)
			if okB and b and b:exists() and b:isa("SpaceStation") then
				st = b
			end
		end
		if st then
			local okS, s = pcall(function() return Space.SpawnShipDocked(entry.shipId, st) end)
			if okS and s then ship = s end
		end
	end

	if not ship then
		local okS, s = pcall(function() return Space.SpawnShipNear(entry.shipId, Game.player, 6, 12) end)
		if okS and s then ship = s end
	end

	if not ship then return nil end

	if entry.skin then pcall(function() ship:SetSkin(entry.skin) end) end
	if entry.pattern and ship.model and ship.model.SetPattern then
		pcall(function() ship.model:SetPattern(entry.pattern) end)
	end
	ship:SetLabel(entry.label)
	ship:SetShipName("[FLEET] " .. entry.shipName)
	applyEquipListToShip(ship, entry.equip)
	applyCargoToShip(ship, entry.cargo)
	ship:SetHullPercent(math.clamp(entry.hullPercent or 100, 1, 100))
	ship:SetFuelPercent(math.clamp(entry.fuel or 100, 0, 100))

	entry.liveShip = ship
	return ship
end

local function updateEscortAI(entry)
	if not Game.system or Game.InHyperspace() then return end
	if not entry.captain then return end

	-- Spawn escort only when player is undocked/flying or orbiting
	if Game.player.flightState == "FLYING" then
		local live = spawnOrUpdateLiveFleetShip(entry, true)
		if live and live:exists() then
			if live.flightState == "DOCKED" then
				live:Undock()
				return
			end
			entry.locationPath = Game.system.path
			entry.locationName = Game.system.name .. " (Escort)"
			entry.status = "ESCORTING"

			local target = Game.player:GetCombatTarget()
			if target and target:exists() and target:IsShip() and target ~= live then
				live:AIKill(target)
				entry.orderPhase = "Engaging " .. (target.shipName ~= "" and target.shipName or target.label)
				return
			end

			-- Look for nearby hostiles shooting or near player
			local nearShips = Space.GetBodiesNear(Game.player, 25000, "Ship")
			for _, other in ipairs(nearShips or {}) do
				if other ~= Game.player and other ~= live and other:exists() then
					local aiTarget = other.GetAITarget and other:GetAITarget() or nil
					if aiTarget == Game.player then
						live:AIKill(other)
						entry.orderPhase = "Defending Flagship vs " .. (other.shipName ~= "" and other.shipName or other.label)
						return
					end
				end
			end

			local dist = live:DistanceTo(Game.player)
			if dist > 4500 then
				live:AIFlyTo(Game.player)
				entry.orderPhase = "Closing formation (" .. string.format("%.1f km)", dist / 1000)
			else
				live:AIFlyTo(Game.player)
				entry.orderPhase = "Flying close escort near Flagship"
			end
			syncFromLiveShip(entry)
		end
	elseif Game.player.flightState == "DOCKED" then
		local station = Game.player:GetDockedWith()
		if station and entry.liveShip and entry.liveShip:exists() then
			if entry.liveShip.flightState == "FLYING" then
				entry.liveShip:AIDockWith(station)
				entry.orderPhase = "Docking at " .. station.label .. " with Flagship"
			elseif entry.liveShip.flightState == "DOCKED" then
				syncFromLiveShip(entry)
				entry.locationPath = station.path
				entry.locationName = formatPathName(station.path)
				entry.orderPhase = "Docked on escort standby at " .. station.label
			end
		else
			entry.orderPhase = "Escort docked alongside Flagship"
			if station then
				entry.locationPath = station.path
				entry.locationName = formatPathName(station.path)
			end
		end
	end
end

-- ============================================================================
-- Fleet Orders Dispatch (Phase A3)
-- ============================================================================

local function calcDuration(baseSeconds, captain, skillKey)
	local skill = (captain and captain[skillKey]) or 20
	local mult = math.clamp(1.25 - (skill / 100), 0.55, 1.2)
	return math.max(25, math.floor(baseSeconds * mult))
end

function PlayerFleet.OrderFerry(uid, destStationPath)
	local _, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end
	if not destStationPath then return false, "No destination station provided." end
	if samePath(entry.locationPath, destStationPath) and entry.status == "DOCKED" then
		return false, "Vessel is already docked at this station."
	end

	local dist = 0
	local s1 = entry.locationPath and entry.locationPath:GetStarSystem()
	local s2 = destStationPath:GetStarSystem()
	if s1 and s2 then dist = s1:DistanceTo(s2) end

	if not entry.captain then
		local fee = math.floor(FERRY_BASE_FEE + dist * FERRY_PER_LY_FEE)
		if PlayerState.GetMoney() < fee then
			return false, string.format("Remote ferry without a Captain requires %s courier pilot fee.", Format.Money(fee, false))
		end
		PlayerState.AddMoney(-fee)
		addLog(entry.shipName, string.format("Hired delivery courier (%s) to ferry ship to %s.", Format.Money(fee, false), formatPathName(destStationPath)), -fee)
	end

	local dur = calcDuration(dist > 0.1 and (65 + dist * 6) or 45, entry.captain, "navigation")
	entry.order = "DOCK"
	entry.status = "TRANSIT"
	entry.orderTargetPath = destStationPath
	entry.orderTargetName = formatPathName(destStationPath)
	entry.orderParams.startTime = Game.time
	entry.orderEta = Game.time + dur
	entry.orderProgress = 0
	entry.orderPhase = "In transit to " .. entry.orderTargetName

	return true, string.format("%s en route to %s (ETA %s).", entry.shipName, entry.orderTargetName, Format.Duration(dur))
end

function PlayerFleet.IssueOrder(uid, orderType, params)
	local _, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end

	params = params or {}

	if orderType == "IDLE" then
		entry.order = "IDLE"
		entry.orderTargetPath = nil
		entry.orderTargetName = nil
		entry.orderProgress = 0
		entry.orderEta = 0
		entry.missionRef = nil
		if entry.liveShip and entry.liveShip:exists() then
			syncFromLiveShip(entry)
			if entry.liveShip.flightState == "FLYING" and Game.system then
				local stPaths = Game.system:GetStationPaths()
				if stPaths[1] then
					local st = Space.GetBody(stPaths[1].bodyIndex)
					if st then
						entry.liveShip:AIDockWith(st)
						entry.status = "TRANSIT"
						entry.orderPhase = "Returning to dock at " .. st.label
						addLog(entry.shipName, "Ordered to stand down and dock.", 0)
						return true, "Standing down and docking at " .. st.label
					end
				end
			end
		end
		entry.status = "DOCKED"
		entry.orderPhase = "Docked on standby"
		addLog(entry.shipName, "Placed on standby.", 0)
		return true, entry.shipName .. " is now on standby."
	end

	-- Autonomous orders require an assigned Captain
	if not entry.captain then
		return false, "Assign or hire a Captain before issuing autonomous orders."
	end

	entry.missionRef = nil

	if orderType == "FOLLOW" then
		entry.order = "FOLLOW"
		entry.status = "ESCORTING"
		entry.orderProgress = 0
		entry.orderPhase = "Forming up as Wingman Escort"
		addLog(entry.shipName, "Assigned Wingman Escort (Follow Flagship).", 0)
		if Game.system and not Game.InHyperspace() and Game.player.flightState == "FLYING" then
			updateEscortAI(entry)
		end
		return true, string.format("%s is now escorting your Flagship.", entry.shipName)

	elseif orderType == "DOCK" then
		local dest = params.targetPath
		if not dest and Game.system then
			local stations = Game.system:GetStationPaths()
			dest = stations[1]
		end
		if not dest then return false, "No station found to dock with." end
		return PlayerFleet.OrderFerry(uid, dest)

	elseif orderType == "AUTO_TRADE" then
		if (entry.cargoCap or 0) <= 0 then
			return false, "Vessel has no cargo hold capacity for trading."
		end
		local route = findBestTradeRoute(entry)
		if not route then
			return false, "No reachable trade stations within hyperspace range."
		end
		entry.order = "AUTO_TRADE"
		entry.status = "TRADING"
		entry.orderParams.maxJumps = params.maxJumps or entry.orderParams.maxJumps or 12
		entry.orderParams.tradeState = "SEEKING"
		entry.orderParams.route = nil
		entry.orderProgress = 0
		entry.orderEta = Game.time + 5
		entry.orderPhase = "Analyzing sector commodities market..."
		addLog(entry.shipName, string.format("Started Autonomous Trading (Captain %s).", entry.captain.name), 0)
		return true, string.format("%s began Autonomous Trade operations.", entry.shipName)

	elseif orderType == "AUTO_MINE" then
		if (entry.cargoCap or 0) <= 0 then
			return false, "Vessel needs cargo hold capacity to mine rings."
		end
		local ringPath, ringBody = findNearestRingBody(entry.locationPath)
		if not ringPath then
			return false, "No planetary rings detected within operating range."
		end
		local dur = calcDuration(55, entry.captain, "sensors")
		entry.order = "AUTO_MINE"
		entry.status = "MINING"
		entry.orderTargetPath = ringPath
		entry.orderTargetName = ringBody.name .. " Rings"
		entry.orderParams.mineState = "TO_RING"
		entry.orderParams.ringType = ringBody.ringType
		entry.orderParams.ringReserve = ringBody.ringReserve
		entry.orderParams.ringBodyName = ringBody.name
		entry.orderParams.startTime = Game.time
		entry.orderEta = Game.time + dur
		entry.orderProgress = 0
		entry.orderPhase = "Supercruising to " .. ringBody.name .. " rings"
		addLog(entry.shipName, string.format("Dispatched to mine %s rings (%s).", ringBody.name, tostring(ringBody.ringType or "ROCKY")), 0)
		return true, string.format("%s dispatched to mine %s rings.", entry.shipName, ringBody.name)

	elseif orderType == "PATROL" then
		local dur = calcDuration(75, entry.captain, "piloting")
		entry.order = "PATROL"
		entry.status = "PATROLLING"
		entry.orderParams.startTime = Game.time
		entry.orderEta = Game.time + dur
		entry.orderProgress = 0
		entry.orderPhase = "Patrolling shipping lanes in " .. (entry.locationName or "sector")
		if Game.system and not Game.InHyperspace() and sameSystem(entry.locationPath, Game.system.path) then
			local live = spawnOrUpdateLiveFleetShip(entry, false)
			if live and live:exists() then
				if live.flightState == "DOCKED" then live:Undock() end
			end
		end
		addLog(entry.shipName, string.format("Initiated Sector Security Patrol (Combat Score %d).", PlayerFleet.GetShipCombatScore(entry)), 0)
		return true, string.format("%s began security patrol.", entry.shipName)
	end

	return false, "Unknown fleet order: " .. tostring(orderType)
end

-- ============================================================================
-- Autonomous Mission Delegation (Phase A4)
-- ============================================================================

local SUPPORTED_MISSION_TYPES = {
	Delivery = true,
	CargoRun = true,
	Combat = true,
	Scout = true,
	Assassination = true,
}

function PlayerFleet.IsMissionDelegatable(mission)
	if not mission then return false, "Invalid mission." end
	if not SUPPORTED_MISSION_TYPES[mission.type] then
		return false, "Mission type '" .. tostring(mission.type) .. "' requires Flagship handling."
	end
	if mission.fleetAssignedUid then
		return false, "Already assigned to a fleet ship."
	end
	if mission.status == "FAILED" or mission.status == "COMPLETED" then
		return false, "Mission is no longer active."
	end
	return true
end

function PlayerFleet.GetMissionAssignedShip(mission)
	if not mission or not mission.fleetAssignedUid then return nil end
	return PlayerFleet.GetShipByUid(mission.fleetAssignedUid)
end

function PlayerFleet.GetEligibleShipsForMission(mission)
	local ok, reason = PlayerFleet.IsMissionDelegatable(mission)
	if not ok then return {}, reason end

	local list = {}
	for _, entry in ipairs(fleetState.ships) do
		if entry.captain and entry.order ~= "MISSION" and entry.status ~= "DESTROYED" then
			local eligible = true
			local note = "Ready"
			if mission.type == "CargoRun" then
				local needed = mission.amount or 0
				local held = (mission.cargotype and entry.cargo and entry.cargo[mission.cargotype.name]) or 0
				local pHeld = 0
				if mission.cargotype and Game.player then
					pHeld = Game.player:GetComponent('CargoManager'):CountCommodity(mission.cargotype)
				end
				if not mission.pickup and (held + pHeld) < needed then
					eligible = false
					note = string.format("Needs %dt %s", needed, mission.cargotype and mission.cargotype:GetName() or "cargo")
				elseif (held + PlayerFleet.GetCargoFree(entry)) < needed then
					eligible = false
					note = string.format("Cargo cap too small (%dt needed)", needed)
				end
			elseif (mission.type == "Combat" or mission.type == "Assassination") then
				if PlayerFleet.GetShipCombatScore(entry) < 20 then
					note = "Low combat firepower (risky)"
				end
			end
			if eligible then
				table.insert(list, { entry = entry, note = note })
			end
		end
	end
	return list, (#list == 0 and "No crewed fleet ships available." or nil)
end

function PlayerFleet.AssignMission(uid, mission)
	local _, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end
	if not entry.captain then return false, "Vessel needs a Captain." end

	local ok, reason = PlayerFleet.IsMissionDelegatable(mission)
	if not ok then return false, reason end

	-- Transfer CargoRun cargo from Game.player if already aboard Flagship and not pickup
	if mission.type == "CargoRun" and mission.cargotype and not mission.pickup then
		local needed = mission.amount or 0
		local held = (entry.cargo and entry.cargo[mission.cargotype.name]) or 0
		if held < needed then
			local stillNeed = needed - held
			local pCargoMgr = Game.player:GetComponent('CargoManager')
			if pCargoMgr:CountCommodity(mission.cargotype) < stillNeed then
				return false, string.format("Ship or Flagship must hold %dt of %s.", needed, mission.cargotype:GetName())
			end
			if PlayerFleet.GetCargoFree(entry) < stillNeed then
				return false, "Insufficient cargo hold space on " .. entry.shipName
			end
			local moved = pCargoMgr:RemoveCommodity(mission.cargotype, stillNeed)
			entry.cargo[mission.cargotype.name] = held + moved
		end
	end

	local destPath = (type(mission.location) == "userdata" and mission.location)
		or (type(mission.destination) == "userdata" and mission.destination)
		or entry.locationPath

	local dist = 0
	local curSys = entry.locationPath and entry.locationPath:GetStarSystem()
	local destSys = destPath and destPath:GetStarSystem()
	if curSys and destSys then
		dist = curSys:DistanceTo(destSys)
	end

	local baseTime = 55 + math.min(25, dist) * 5
	if mission.type == "Combat" or mission.type == "Assassination" then
		baseTime = baseTime + 35
	elseif mission.type == "Scout" then
		baseTime = baseTime + 25
	end
	local dur = calcDuration(baseTime, entry.captain, "navigation")

	-- Clamp before mission.due if deadline is tight and ship has skilled captain
	if mission.due and (Game.time + dur) >= mission.due - 60 then
		if (mission.due - Game.time) > 30 then
			dur = math.max(20, math.floor((mission.due - Game.time) * 0.65))
		end
	end

	mission.fleetAssignedUid = entry.uid
	mission.fleetAssignedName = entry.shipName

	entry.order = "MISSION"
	entry.status = "MISSION"
	entry.orderTargetPath = destPath
	entry.orderTargetName = formatPathName(destPath)
	entry.orderParams.startTime = Game.time
	entry.orderEta = Game.time + dur
	entry.orderProgress = 0
	entry.orderPhase = string.format("Executing %s contract -> %s", mission:GetTypeDescription(), entry.orderTargetName)
	entry.missionRef = mission

	addLog(entry.shipName, string.format("Delegated '%s' contract (%s) -> %s.", mission:GetTypeDescription(), Format.Money(mission.reward or 0, false), entry.orderTargetName), 0)
	return true, string.format("%s dispatched on '%s' mission (ETA %s).", entry.shipName, mission:GetTypeDescription(), Format.Duration(dur))
end

local function completeFleetMission(entry)
	local mission = entry.missionRef
	if not mission then
		entry.order = "IDLE"
		entry.status = "DOCKED"
		return
	end

	-- Verify mission is still in player's active missions list
	local stillActive = false
	for _, m in pairs(Character.persistent.player.missions) do
		if m == mission then
			stillActive = true
			break
		end
	end

	local destPath = (type(mission.location) == "userdata" and mission.location)
		or (type(mission.domicile) == "userdata" and mission.domicile)
		or entry.locationPath

	entry.locationPath = destPath
	entry.locationName = formatPathName(destPath)
	entry.order = "IDLE"
	entry.status = "DOCKED"
	entry.orderProgress = 0
	entry.orderEta = 0
	entry.missionRef = nil

	if not stillActive or mission.status == "FAILED" then
		entry.orderPhase = "Docked (contract expired before completion)"
		addLog(entry.shipName, "Mission contract expired before completion.", 0)
		return
	end

	if mission.due and Game.time > mission.due then
		entry.orderPhase = "Docked (missed deadline)"
		addLog(entry.shipName, string.format("Missed deadline on %s contract.", mission:GetTypeDescription()), 0)
		Comms.ImportantMessage(string.format("%s: Missed contract deadline at %s.", entry.shipName, entry.locationName), entry.captain and entry.captain.name or entry.shipName)
		mission.status = "FAILED"
		mission:Remove()
		return
	end

	-- Handle cargo consumption if CargoRun
	if mission.type == "CargoRun" and mission.cargotype then
		local cname = mission.cargotype.name
		local held = entry.cargo[cname] or 0
		local take = math.min(held, mission.amount or 0)
		entry.cargo[cname] = held - take
		if entry.cargo[cname] <= 0 then entry.cargo[cname] = nil end
		entry.stats.cargoHauled = (entry.stats.cargoHauled or 0) + (mission.amount or 0)
	end

	-- Combat wear roll for Combat / Assassination contracts
	if mission.type == "Combat" or mission.type == "Assassination" then
		local dmg = math.max(0, Engine.rand:Integer(0, 14) - math.floor(PlayerFleet.GetShipCombatScore(entry) / 15))
		entry.hullPercent = math.max(25, (entry.hullPercent or 100) - dmg)
	end

	local reward = mission.reward or 0
	if reward > 0 then
		PlayerState.AddMoney(reward)
	end
	fleetState.totalProfit = (fleetState.totalProfit or 0) + reward
	entry.stats.netProfit = (entry.stats.netProfit or 0) + reward
	entry.stats.missionsDone = (entry.stats.missionsDone or 0) + 1
	entry.stats.runsCompleted = (entry.stats.runsCompleted or 0) + 1

	local oldRep = Character.persistent.player.reputation or 0
	Character.persistent.player.reputation = oldRep + 1.5
	Event.Queue("onReputationChanged", oldRep, Character.persistent.player.killcount, Character.persistent.player.reputation, Character.persistent.player.killcount)

	if mission.factionName then
		pcall(function()
			FactionStanding.ApplyMissionOutcome(mission.factionName, 2, mission.destFactionName, "Fleet autonomous contract completed")
		end)
	end

	-- Safely neutralize module-local references so original mission script won't double-pay on future dock
	local farOff = SystemPath.New(99999, 99999, 99999)
	mission.status = "COMPLETED"
	mission.complete = false
	mission.due = Game.time + 1e12
	mission.location = farOff
	if mission.domicile then mission.domicile = farOff end
	if mission.station then mission.station = farOff end
	if mission.backstation then mission.backstation = farOff end
	mission:Remove()

	local primarySkill = (mission.type == "Combat" or mission.type == "Assassination") and "piloting" or "navigation"
	PlayerFleet.AwardCaptainXP(entry, primarySkill)

	local msg = string.format("Completed '%s' at %s (+%s).", mission:GetTypeDescription(), entry.locationName, Format.Money(reward, false))
	entry.orderPhase = "Contract completed. Docked at " .. entry.locationName
	addLog(entry.shipName, msg, reward)
	Comms.ImportantMessage(entry.shipName .. ": " .. msg, entry.captain and entry.captain.name or "Fleet Command")
end

-- ============================================================================
-- Periodic Autonomous Simulation Loop (OOS & Background Cycles)
-- ============================================================================

local function tickAutoTrade(entry)
	local p = entry.orderParams
	local state = p.tradeState or "SEEKING"

	if state == "SEEKING" then
		local route = findBestTradeRoute(entry)
		if not route then
			entry.orderPhase = "No profitable route found; waiting"
			entry.orderEta = Game.time + 30
			return
		end
		local freeCap = PlayerFleet.GetCargoFree(entry)
		if freeCap < 1 then
			-- Sell whatever leftover cargo we already have at nearest market first
			local firstComm, firstQty = next(entry.cargo or {})
			if firstComm and Commodities[firstComm] then
				local sys = (entry.locationPath and entry.locationPath:GetStarSystem()) or Game.system
				local sellP = getSystemCommodityPrice(sys, Commodities[firstComm])
				local rev = sellP * firstQty
				entry.cargo[firstComm] = nil
				PlayerState.AddMoney(rev)
				entry.stats.netProfit = (entry.stats.netProfit or 0) + rev
				fleetState.totalProfit = (fleetState.totalProfit or 0) + rev
				addLog(entry.shipName, string.format("Liquidated %dt %s hold.", firstQty, Commodities[firstComm]:GetName()), rev)
			end
			return
		end

		local unitMass = (route.comm.mass or 1)
		local maxUnitsBySpace = math.floor(freeCap / unitMass)
		local budgetCap = math.min(fleetState.tradeBudget or 50000, PlayerState.GetMoney())
		-- Leave 500 Cr emergency reserve for player
		budgetCap = math.max(0, budgetCap - 500)
		local maxUnitsByCash = math.floor(budgetCap / math.max(1, route.buyPrice))
		local buyQty = math.min(maxUnitsBySpace, maxUnitsByCash)

		if buyQty < 1 then
			entry.orderPhase = "Awaiting trade capital (" .. Format.Money(route.buyPrice, false) .. "/t needed)"
			entry.orderEta = Game.time + 25
			return
		end

		local totalSpend = buyQty * route.buyPrice
		PlayerState.AddMoney(-totalSpend)
		local cname = route.comm.name
		entry.cargo[cname] = (entry.cargo[cname] or 0) + buyQty
		entry.stats.netProfit = (entry.stats.netProfit or 0) - totalSpend
		fleetState.totalProfit = (fleetState.totalProfit or 0) - totalSpend

		local legTime = calcDuration(45 + math.min(18, route.distLy or 1) * 5, entry.captain, "navigation")
		p.tradeState = "TRANSIT"
		p.activeTrade = {
			commName = cname,
			commDisplay = route.comm:GetName(),
			qty = buyQty,
			buyPrice = route.buyPrice,
			sellPrice = route.sellPrice,
			sellPath = route.sellPath,
			sellPathName = formatPathName(route.sellPath),
			spent = totalSpend,
		}
		p.startTime = Game.time
		entry.orderEta = Game.time + legTime
		entry.orderTargetPath = route.sellPath
		entry.orderTargetName = p.activeTrade.sellPathName
		entry.locationPath = route.buyPath
		entry.locationName = formatPathName(route.buyPath)
		entry.orderPhase = string.format("Hauling %dt %s -> %s", buyQty, p.activeTrade.commDisplay, p.activeTrade.sellPathName)
		addLog(entry.shipName, string.format("Bought %dt %s @ %s/t", buyQty, p.activeTrade.commDisplay, Format.Money(route.buyPrice, false)), -totalSpend)

	elseif state == "TRANSIT" then
		if Game.time < (entry.orderEta or 0) then
			local startT = p.startTime or (entry.orderEta - 60)
			entry.orderProgress = math.clamp((Game.time - startT) / math.max(1, entry.orderEta - startT), 0, 1)
			return
		end

		local tr = p.activeTrade
		if tr then
			local sellQty = math.min(tr.qty, entry.cargo[tr.commName] or tr.qty)
			local gross = sellQty * tr.sellPrice
			entry.cargo[tr.commName] = (entry.cargo[tr.commName] or sellQty) - sellQty
			if (entry.cargo[tr.commName] or 0) <= 0 then entry.cargo[tr.commName] = nil end

			PlayerState.AddMoney(gross)
			local legNet = gross - (tr.spent or 0)
			entry.stats.netProfit = (entry.stats.netProfit or 0) + gross
			fleetState.totalProfit = (fleetState.totalProfit or 0) + gross
			entry.stats.runsCompleted = (entry.stats.runsCompleted or 0) + 1
			entry.stats.cargoHauled = (entry.stats.cargoHauled or 0) + sellQty
			entry.locationPath = tr.sellPath
			entry.locationName = tr.sellPathName

			addLog(entry.shipName, string.format("Sold %dt %s at %s (Net +%s).", sellQty, tr.commDisplay, tr.sellPathName, Format.Money(legNet, false)), gross)
			if legNet >= 500 then
				Comms.Message(string.format("%s completed trade at %s (Net profit: %s)", entry.shipName, tr.sellPathName, Format.Money(legNet, false)), entry.captain and entry.captain.name or "Fleet Trade")
			end
			PlayerFleet.AwardCaptainXP(entry, "navigation")
		end

		p.tradeState = "SEEKING"
		p.activeTrade = nil
		entry.orderProgress = 0
		entry.orderEta = Game.time + 4
		entry.orderPhase = "Scanning next trade opportunity..."
	end
end

local function tickAutoMine(entry)
	local p = entry.orderParams
	local state = p.mineState or "TO_RING"
	local startT = p.startTime or Game.time

	if Game.time < (entry.orderEta or 0) then
		entry.orderProgress = math.clamp((Game.time - startT) / math.max(1, (entry.orderEta or startT + 1) - startT), 0, 1)
		return
	end

	if state == "TO_RING" then
		local dur = calcDuration(55, entry.captain, "sensors")
		p.mineState = "MINING"
		p.startTime = Game.time
		entry.orderEta = Game.time + dur
		entry.orderProgress = 0
		entry.orderPhase = string.format("Extracting ore in %s rings", p.ringBodyName or "planetary")

	elseif state == "MINING" then
		local freeCap = PlayerFleet.GetCargoFree(entry)
		local comm = selectMineCommodity({ ringType = p.ringType, ringReserve = p.ringReserve })
		local reserveMult = (p.ringReserve == "PRISTINE" and 1.35) or (p.ringReserve == "DEPLETED" and 0.65) or 1.0
		local engBonus = 1.0 + ((entry.captain and entry.captain.engineering or 15) / 80)
		local rawYield = math.floor(math.max(4, math.min(freeCap, Engine.rand:Integer(8, 20) * reserveMult * engBonus)))

		if comm and rawYield > 0 and freeCap >= (comm.mass or 1) then
			local units = math.min(rawYield, math.floor(freeCap / (comm.mass or 1)))
			entry.cargo[comm.name] = (entry.cargo[comm.name] or 0) + units
			p.minedComm = comm.name
			p.minedDisplay = comm:GetName()
			p.minedUnits = units
		end

		local sellStations = (entry.locationPath and entry.locationPath:GetStarSystem() and entry.locationPath:GetStarSystem():GetStationPaths()) or {}
		if #sellStations == 0 and Game.system then sellStations = Game.system:GetStationPaths() end
		local destSt = sellStations[1] or entry.locationPath

		local dur = calcDuration(45, entry.captain, "piloting")
		p.mineState = "RETURNING"
		p.sellStationPath = destSt
		p.startTime = Game.time
		entry.orderEta = Game.time + dur
		entry.orderProgress = 0
		entry.orderPhase = string.format("Hauling %dt %s to %s", p.minedUnits or 0, p.minedDisplay or "ore", formatPathName(destSt))

	elseif state == "RETURNING" then
		local stPath = p.sellStationPath or entry.locationPath
		local sys = (stPath and stPath:GetStarSystem()) or Game.system
		local totalSale = 0
		local totalTons = 0

		for cname, qty in pairs(entry.cargo or {}) do
			local comm = Commodities[cname]
			if comm and qty > 0 then
				local unitPrice = getSystemCommodityPrice(sys, comm)
				totalSale = totalSale + unitPrice * qty
				totalTons = totalTons + qty
				entry.cargo[cname] = nil
			end
		end

		if totalSale > 0 then
			PlayerState.AddMoney(totalSale)
			entry.stats.netProfit = (entry.stats.netProfit or 0) + totalSale
			fleetState.totalProfit = (fleetState.totalProfit or 0) + totalSale
			entry.stats.cargoHauled = (entry.stats.cargoHauled or 0) + totalTons
			entry.stats.runsCompleted = (entry.stats.runsCompleted or 0) + 1
			entry.locationPath = stPath
			entry.locationName = formatPathName(stPath)
			addLog(entry.shipName, string.format("Sold %dt ring ore at %s (+%s).", totalTons, entry.locationName, Format.Money(totalSale, false)), totalSale)
			Comms.Message(string.format("%s sold %dt mined ore (+%s)", entry.shipName, totalTons, Format.Money(totalSale, false)), entry.captain and entry.captain.name or "Fleet Mining")
			PlayerFleet.AwardCaptainXP(entry, "engineering")
		end

		local dur = calcDuration(55, entry.captain, "sensors")
		p.mineState = "TO_RING"
		p.startTime = Game.time
		entry.orderEta = Game.time + dur
		entry.orderProgress = 0
		entry.orderPhase = "Returning to " .. (p.ringBodyName or "planetary") .. " rings"
	end
end

local function tickPatrol(entry)
	local p = entry.orderParams
	local startT = p.startTime or Game.time

	-- If spawned live in Game.system, look for hostiles in space
	if entry.liveShip and entry.liveShip:exists() then
		syncFromLiveShip(entry)
		if entry.liveShip.flightState == "FLYING" then
			local near = Space.GetBodiesNear(entry.liveShip, 35000, "Ship")
			for _, other in ipairs(near or {}) do
				if other ~= Game.player and other ~= entry.liveShip and other:exists() then
					local isWanted = other.IsWanted and other:IsWanted()
					if isWanted then
						entry.liveShip:AIKill(other)
						entry.orderPhase = "Intercepting pirate " .. (other.label or "hostile")
						return
					end
				end
			end
		end
	end

	if Game.time < (entry.orderEta or 0) then
		entry.orderProgress = math.clamp((Game.time - startT) / math.max(1, (entry.orderEta or startT + 1) - startT), 0, 1)
		return
	end

	-- Resolve patrol sweep encounter
	local combat = PlayerFleet.GetShipCombatScore(entry)
	local successChance = math.clamp(0.45 + (combat / 140), 0.45, 0.94)
	if Engine.rand:Number(0, 1) < successChance then
		local bounty = Engine.rand:Integer(800, 2600) + combat * 18
		PlayerState.AddMoney(bounty)
		entry.stats.bountiesEarned = (entry.stats.bountiesEarned or 0) + bounty
		entry.stats.netProfit = (entry.stats.netProfit or 0) + bounty
		fleetState.totalProfit = (fleetState.totalProfit or 0) + bounty
		entry.stats.runsCompleted = (entry.stats.runsCompleted or 0) + 1
		if entry.captain then
			entry.captain.killcount = (entry.captain.killcount or 0) + 1
		end
		addLog(entry.shipName, string.format("Neutralized pirate contact; bounty awarded (+%s).", Format.Money(bounty, false)), bounty)
		Comms.Message(string.format("%s patrol bounty collected (+%s).", entry.shipName, Format.Money(bounty, false)), entry.captain and entry.captain.name or "Security Patrol")
		PlayerFleet.AwardCaptainXP(entry, "piloting")

		local hullChip = math.max(0, Engine.rand:Integer(0, 6) - math.floor(combat / 25))
		entry.hullPercent = math.max(30, (entry.hullPercent or 100) - hullChip)
	else
		entry.hullPercent = math.max(30, (entry.hullPercent or 100) - Engine.rand:Integer(2, 5))
		addLog(entry.shipName, "Completed shipping lane sweep — all sectors clear.", 0)
	end

	local nextDur = calcDuration(85, entry.captain, "piloting")
	p.startTime = Game.time
	entry.orderEta = Game.time + nextDur
	entry.orderProgress = 0
	entry.orderPhase = "Patrolling shipping lanes in " .. (entry.locationName or "system")
end

local function tickDockTransit(entry)
	local p = entry.orderParams
	local startT = p.startTime or Game.time
	if Game.time < (entry.orderEta or 0) then
		entry.orderProgress = math.clamp((Game.time - startT) / math.max(1, (entry.orderEta or startT + 1) - startT), 0, 1)
		return
	end

	despawnLiveShip(entry)
	entry.locationPath = entry.orderTargetPath or entry.locationPath
	entry.locationName = formatPathName(entry.locationPath)
	entry.order = "IDLE"
	entry.status = "DOCKED"
	entry.orderProgress = 0
	entry.orderEta = 0
	entry.orderPhase = "Docked at " .. entry.locationName
	entry.stats.runsCompleted = (entry.stats.runsCompleted or 0) + 1

	addLog(entry.shipName, string.format("Arrived and docked at %s.", entry.locationName), 0)
	Comms.ImportantMessage(string.format("%s arrived and docked at %s.", entry.shipName, entry.locationName), entry.captain and entry.captain.name or "Fleet Flight Control")
	PlayerFleet.AwardCaptainXP(entry, "navigation")
end

local function tickMissionOrder(entry)
	local p = entry.orderParams
	local startT = p.startTime or Game.time
	if Game.time < (entry.orderEta or 0) then
		entry.orderProgress = math.clamp((Game.time - startT) / math.max(1, (entry.orderEta or startT + 1) - startT), 0, 1)
		return
	end
	completeFleetMission(entry)
end

local function fleetSimulationStep()
	if not Game.system then return end

	for _, entry in ipairs(fleetState.ships) do
		if entry.status ~= "DESTROYED" then
			if entry.order == "FOLLOW" then
				updateEscortAI(entry)
			elseif entry.order == "DOCK" then
				tickDockTransit(entry)
			elseif entry.order == "AUTO_TRADE" then
				tickAutoTrade(entry)
			elseif entry.order == "AUTO_MINE" then
				tickAutoMine(entry)
			elseif entry.order == "PATROL" then
				tickPatrol(entry)
			elseif entry.order == "MISSION" then
				tickMissionOrder(entry)
			end
		end
	end
end

local function ensureTickLoop()
	if tickTimerActive then return end
	tickTimerActive = true
	Timer:CallEvery(TICK_INTERVAL_SEC, function()
		fleetSimulationStep()
		return false -- Keep repeating while game is running
	end)
end

-- ============================================================================
-- Game Lifecycle & Event Hooks
-- ============================================================================

local loaded_data = nil

Event.Register("onGameStart", function()
	if loaded_data then
		fleetState = loaded_data
		loaded_data = nil
		for _, entry in ipairs(fleetState.ships or {}) do
			entry.liveShip = nil
			if entry.crew then
				for _, member in ipairs(entry.crew) do
					member.available = false
				end
			end
		end
	else
		fleetState = {
			ships = {},
			nextUid = 1,
			tradeBudget = 50000,
			totalProfit = 0,
			logs = {},
		}
	end
	tickTimerActive = false
	ensureTickLoop()
end)

Event.Register("onGameEnd", function()
	fleetState = {
		ships = {},
		nextUid = 1,
		tradeBudget = 50000,
		totalProfit = 0,
		logs = {},
	}
	loaded_data = nil
	tickTimerActive = false
end)

Event.Register("onEnterSystem", function(player)
	if not player or not player:IsPlayer() then return end
	ensureTickLoop()

	for _, entry in ipairs(fleetState.ships) do
		entry.liveShip = nil
		if entry.order == "FOLLOW" and entry.captain then
			local hasDrive = PlayerFleet.HasHyperdrive(entry)
			if hasDrive then
				entry.fuel = math.max(10, (entry.fuel or 100) - 12)
				entry.locationPath = Game.system.path
				entry.locationName = Game.system.name .. " (Escort)"
				updateEscortAI(entry)
			else
				entry.order = "IDLE"
				entry.status = "DOCKED"
				entry.orderPhase = "Stranded without hyperdrive at " .. (entry.locationName or "previous system")
				Comms.ImportantMessage(entry.shipName .. " has no hyperdrive and could not follow across hyperspace!", entry.captain.name)
			end
		elseif entry.order == "PATROL" and sameSystem(entry.locationPath, Game.system.path) then
			spawnOrUpdateLiveFleetShip(entry, false)
		end
	end
end)

Event.Register("onLeaveSystem", function(ship)
	if ship and ship:IsPlayer() then
		for _, entry in ipairs(fleetState.ships) do
			if entry.liveShip and entry.liveShip:exists() then
				syncFromLiveShip(entry)
			end
			entry.liveShip = nil
		end
	end
end)

Event.Register("onShipDestroyed", function(ship, attacker)
	for i, entry in ipairs(fleetState.ships) do
		if entry.liveShip == ship then
			entry.liveShip = nil
			local salvagePayout = math.floor((ShipDef[entry.shipId] and ShipDef[entry.shipId].basePrice or 10000) * 0.5)
			PlayerState.AddMoney(salvagePayout)
			local killerName = (attacker and attacker.shipName ~= "" and attacker.shipName) or (attacker and attacker.label) or "hostile fire"
			addLog(entry.shipName, string.format("DESTROYED in action vs %s. Insurance payout +%s.", killerName, Format.Money(salvagePayout, false)), salvagePayout)
			Comms.ImportantMessage(string.format("MAYDAY: Fleet ship %s was destroyed by %s! Insurance settlement: +%s.", entry.shipName, killerName, Format.Money(salvagePayout, false)), "Fleet Command")
			table.remove(fleetState.ships, i)
			break
		end
	end
end)

Serializer:Register("PlayerFleet", function()
	for _, entry in ipairs(fleetState.ships) do
		if entry.liveShip and entry.liveShip:exists() then
			syncFromLiveShip(entry)
		end
	end
	return {
		ships = fleetState.ships,
		nextUid = fleetState.nextUid,
		tradeBudget = fleetState.tradeBudget,
		totalProfit = fleetState.totalProfit,
		logs = fleetState.logs,
	}
end, function(data)
	loaded_data = data
end)

return PlayerFleet

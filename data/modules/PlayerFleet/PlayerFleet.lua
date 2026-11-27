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
local CommodityType   = require 'CommodityType'
local Economy         = require 'Economy'
local Format          = require 'Format'
local Comms           = require 'Comms'
local Serializer      = require 'Serializer'
local PlayerState     = require 'PlayerState'
local Passengers      = require 'Passengers'
local FactionStanding = require 'FactionStanding'
local Ship            = require 'Ship'
local ShipDealerships = require 'ShipDealerships'
local Insurance       = require 'modules.Insurance.Insurance'
local ComponentIntegrity = require 'modules.ComponentIntegrity.ComponentIntegrity'
local TaxAuthority    = require 'modules.Economy.TaxAuthority'
local SystemPath      = package.core['SystemPath']

local CAPTAIN_SIGNING_BONUS        = 1500
local FERRY_BASE_FEE               = 250
local FERRY_PER_LY_FEE             = 180
local MAX_LOG_ENTRIES              = 80
local TICK_INTERVAL_SEC            = 2
local WAGE_PERIOD_SEC              = 604800 -- 7 days (matches CrewContracts)
local MAX_PAYROLL_PERIODS_PER_STEP = 12

local SHIP_SELL_RATIO       = 0.65
local EQUIP_SELL_RATIO      = 0.80
local AU_IN_METERS          = 1.495978707e11
local LIGHT_SPEED_MPS       = 299792458.0

-- Hyperdrive math constants matching data/modules/Equipment/Types.lua
local HYPER_RANGE_EXP    = 1.6
local HYPER_MASS_EXP     = 1.2
local HYPER_FUEL_EXP     = 0.9
local HYPER_FUEL_EXP_INV = 1.0 / 0.9

local MAINTENANCE_INTEGRITY_THRESHOLD = 0.80
local MAINTENANCE_HULL_THRESHOLD      = 80
local MAX_CATCHUP_PHASES              = 96

local DEFAULT_TRADE_RANGE_LY         = 20
local MAX_TRADE_RANGE_LY             = 40
local TRADE_SCAN_SLICE_MS            = 4.5
local TRADE_SCAN_MAX_CANDIDATES      = 200
local TRADE_SCAN_CATCHUP_CANDIDATES  = 64
local TRADE_SCAN_CATCHUP_MARKETS     = 14
local MARKET_CACHE_MAX_ENTRIES       = 1500
local SATURATION_HALF_LIFE_SEC       = 3.5 * 86400

local TRADE_CANDIDATE_COMMS = {
	"metal_alloys", "precious_metals", "computers", "robots", "medicines",
	"consumer_goods", "plastics", "grain", "fruit_and_veg", "textiles",
	"mining_machinery", "industrial_machinery", "liquor", "metal_ore"
}

---@class PlayerFleet
local PlayerFleet = {}

PlayerFleet.TRADE_RANGE_PRESETS = {
	{ label = "Local", rangeLy = 0 },
	{ label = "12 ly", rangeLy = 12 },
	{ label = "20 ly", rangeLy = 20 },
	{ label = "30 ly", rangeLy = 30 },
	{ label = "40 ly", rangeLy = 40 },
}

PlayerFleet.DEFENSE_ORDERS = {
	{ id = "SUBMIT", label = "Submit" },
	{ id = "FLEE",   label = "Flee" },
	{ id = "DEFEND", label = "Defend" },
}

-- Persistent state serialized into savefiles
local fleetState = {
	ships = {},
	nextUid = 1,
	tradeBudget = 50000,
	totalProfit = 0,
	logs = {},
	marketSaturation = {},
}

local tickTimerActive = false
local liveOrderRuntime = {}
local soldDepartingShips = {}
local lastPlayerJumpFrom = nil
local lastPlayerJumpStart = nil
local activeTradeScans = {}
local systemMarketCache = {}
local systemMarketCacheCount = 0
local systemMarketAccessSeq = 0
local nearbySystemPathsCache = {}
local nearbyPathsCacheCount = 0
local cachedMacroEngine = false

local function getMacroEngine()
	if cachedMacroEngine == false then
		local ok, mod = pcall(require, 'modules.MacroGalaxy.MacroGalaxyEngine')
		cachedMacroEngine = ok and mod or nil
	end
	return cachedMacroEngine
end

local function getCachedNearbySystemPaths(sys, rangeLy, inhabitableOnly, maxResults)
	if not sys or not sys.path then return nil, nil end
	local p = sys.path
	local rInt = math.floor((tonumber(rangeLy) or 0) + 0.5)
	local key = string.format("%d,%d,%d,%d:%d:%d:%d",
		p.sectorX or 0, p.sectorY or 0, p.sectorZ or 0, p.systemIndex or 0,
		rInt, inhabitableOnly and 1 or 0, tonumber(maxResults) or 0)
	local cached = nearbySystemPathsCache[key]
	if cached then
		return cached.paths, cached.dists
	end
	local okN, paths, dists = pcall(function()
		return sys:GetNearbySystemPaths(rangeLy, inhabitableOnly, maxResults)
	end)
	if not okN or not paths then
		return nil, nil
	end
	if nearbyPathsCacheCount >= 160 then
		nearbySystemPathsCache = {}
		nearbyPathsCacheCount = 0
	end
	nearbySystemPathsCache[key] = { paths = paths, dists = dists or {} }
	nearbyPathsCacheCount = nearbyPathsCacheCount + 1
	return paths, dists
end

-- Helper declaration for hyperdrive default lookup during normalization
local function getDefaultHyperFuelForEquip(equipList, fuelPercent)
	for _, eq in ipairs(equipList or {}) do
		local proto = Equipment.Get(eq.id)
		if proto and proto.capabilities and proto.capabilities.hyperclass and proto.capabilities.hyperclass > 0 then
			local resv = proto.fuel_resv_size or 1
			return resv * math.clamp((fuelPercent or 100) / 100, 0, 1)
		end
	end
	return 0
end

function PlayerFleet.ComputeTargetFleetWage(member, isCaptain)
	if not member then return isCaptain and 90 or 25 end
	local totalSkill = (member.piloting or 15) + (member.navigation or 15)
		+ (member.engineering or 15) + (member.sensors or 15)
	local skillAboveBase = math.max(0, totalSkill - 60)
	local skillPay = math.floor(skillAboveBase * 1.25 + (math.max(0, totalSkill - 100) ^ 2) / 160)
	local roleBase = isCaptain and 75 or 25
	local ops = math.max(0, math.floor(tonumber(member.completedOps) or 0))
	local activeWeeks = math.max(0, math.floor(tonumber(member.activeWeeks) or 0))
	local opsBonus = math.min(ops, 60) * 2 + math.floor(math.max(0, ops - 60) * 0.5)
	local tenureMult = 1.0 + math.min(0.50, math.floor(activeWeeks / 4) * 0.03)
	local target = math.floor((roleBase + skillPay + opsBonus) * tenureMult + 0.5)
	return math.max(isCaptain and 90 or 25, target)
end

local function normalizeFleetCrewForEntry(entry, anchorTime)
	if not entry then return end
	if type(entry.crew) ~= "table" then entry.crew = {} end

	-- Ensure entry.captain is included inside entry.crew (older saves could diverge)
	if type(entry.captain) == "table" and not entry.captain.player and not entry.captain.dead then
		local foundCap = false
		for _, m in ipairs(entry.crew) do
			if m == entry.captain then
				foundCap = true
				break
			end
		end
		if not foundCap then
			table.insert(entry.crew, 1, entry.captain)
		end
	end

	-- Deduplicate crew and strip invalid / dead / player characters
	local seen = {}
	local clean = {}
	for _, member in ipairs(entry.crew) do
		if type(member) == "table" and not member.player and not member.dead and not seen[member] then
			seen[member] = true
			table.insert(clean, member)
		end
	end
	entry.crew = clean

	-- Reconcile entry.captain against normalized entry.crew
	if entry.captain and not seen[entry.captain] then
		entry.captain = nil
	end
	if not entry.captain and #entry.crew > 0 then
		for _, member in ipairs(entry.crew) do
			if string.find(string.upper(tostring(member.title or "")), "CAPTAIN") then
				entry.captain = member
				break
			end
		end
		if not entry.captain and entry.order and entry.order ~= "IDLE" then
			entry.captain = entry.crew[1]
		end
	end

	for _, member in ipairs(entry.crew) do
		-- Restore Character metatable if deserialized from legacy plain tables
		local mt = getmetatable(member)
		if type(mt) ~= "table" or mt.class ~= "Character" then
			setmetatable(member, Character.meta)
		end

		member.name = (type(member.name) == "string" and member.name ~= "") and member.name or "Unknown Crew"
		member.seed = tonumber(member.seed) or 1
		member.piloting = tonumber(member.piloting) or 15
		member.navigation = tonumber(member.navigation) or 15
		member.engineering = tonumber(member.engineering) or 15
		member.sensors = tonumber(member.sensors) or 15
		member.killcount = tonumber(member.killcount) or 0
		member.reputation = tonumber(member.reputation) or 0
		member.playerRelationship = tonumber(member.playerRelationship) or 0
		member.lawfulness = tonumber(member.lawfulness) or 0
		member.available = false
		member.dead = false

		-- Migrate any stale Flagship contract left on old transferred crew
		if type(member.contract) == "table" then
			if type(member.fleetWage) ~= "number" or member.fleetWage <= 0 then
				member.fleetWage = tonumber(member.contract.wage)
			end
			if type(member.fleetOwed) ~= "number" then
				member.fleetOwed = tonumber(member.contract.outstanding) or 0
			end
			if type(member.fleetPayday) ~= "number" and type(member.contract.payday) == "number" then
				member.fleetPayday = member.contract.payday
			end
			member.contract = nil
		end

		local isCap = (member == entry.captain)
		if isCap then
			member.title = "Captain"
		elseif type(member.title) ~= "string" or member.title == "" or member.title == "Captain" then
			member.title = "Fleet Crew"
		end

		member.completedOps = math.max(0, math.floor(tonumber(member.completedOps) or 0))
		member.weeksServed = math.max(0, math.floor(tonumber(member.weeksServed) or 0))
		member.activeWeeks = math.max(0, math.floor(tonumber(member.activeWeeks) or 0))
		member.lastPayOps = math.max(0, math.floor(tonumber(member.lastPayOps) or member.completedOps))
		member.fleetOwed = math.max(0, math.floor(tonumber(member.fleetOwed) or 0))

		local targetWage = PlayerFleet.ComputeTargetFleetWage(member, isCap)
		if type(member.fleetWage) ~= "number" or member.fleetWage <= 0 then
			member.fleetWage = targetWage
		else
			member.fleetWage = math.max(math.floor(member.fleetWage), isCap and 75 or 20)
		end

		-- Anchor payday safely on pre-payroll saves so loading old saves does not charge retroactive arrears
		if type(anchorTime) == "number" and anchorTime > 0 then
			if not member.payrollInitialized then
				if type(member.fleetPayday) ~= "number" or member.fleetPayday <= anchorTime then
					member.fleetPayday = anchorTime + WAGE_PERIOD_SEC
				end
				member.fleetWage = math.max(member.fleetWage, targetWage)
				member.payrollInitialized = true
			elseif type(member.fleetPayday) ~= "number" or member.fleetPayday <= 0 then
				member.fleetPayday = anchorTime + WAGE_PERIOD_SEC
			end
		end
	end
end

local function normalizeFleetState(data)
	local s = (type(data) == "table") and data or {}
	if type(s.ships) ~= "table" then s.ships = {} end
	if type(s.nextUid) ~= "number" or s.nextUid < 1 then s.nextUid = #s.ships + 1 end
	if type(s.tradeBudget) ~= "number" then s.tradeBudget = 50000 end
	if type(s.totalProfit) ~= "number" then s.totalProfit = 0 end
	if type(s.logs) ~= "table" then s.logs = {} end
	if type(s.marketSaturation) ~= "table" then s.marketSaturation = {} end
	for _, entry in ipairs(s.ships) do
		if entry.liveShip and (type(entry.liveShip) ~= "userdata" or not entry.liveShip:exists()) then
			entry.liveShip = nil
		end
		if type(entry.cargo) ~= "table" then entry.cargo = {} end
		if type(entry.cargoCostBasis) ~= "table" then entry.cargoCostBasis = {} end
		if type(entry.equip) ~= "table" then entry.equip = {} end
		if type(entry.crew) ~= "table" then entry.crew = {} end
		if type(entry.orderParams) ~= "table" then
			entry.orderParams = { maxJumps = 12, autoSell = true, tradeRangeLy = DEFAULT_TRADE_RANGE_LY }
		else
			entry.orderParams.pendingRoute = nil
			entry.orderParams.isInitialAutoTradeStart = nil
			entry.orderParams.noStationsAbort = nil
			if type(entry.orderParams.tradeRangeLy) ~= "number" then
				entry.orderParams.tradeRangeLy = DEFAULT_TRADE_RANGE_LY
			else
				entry.orderParams.tradeRangeLy = math.clamp(entry.orderParams.tradeRangeLy, 0, MAX_TRADE_RANGE_LY)
			end
			if entry.order == "AUTO_TRADE" and entry.orderParams.tradeState == "SCANNING" then
				entry.orderParams.tradeState = "SEEKING"
				entry.orderParams.nextSeekTime = 0
				if entry.status == "SCANNING" then
					entry.status = "DOCKED"
				end
			end
		end
		if entry.transit ~= nil and type(entry.transit) ~= "table" then
			entry.transit = nil
		end
		if entry.defenseOrder ~= "SUBMIT" and entry.defenseOrder ~= "FLEE" and entry.defenseOrder ~= "DEFEND" then
			entry.defenseOrder = "FLEE"
		end
		if type(entry.stats) ~= "table" then
			entry.stats = {
				netProfit = 0, runsCompleted = 0, bountiesEarned = 0,
				missionsDone = 0, cargoHauled = 0, maintenancePaid = 0, taxesGenerated = 0, wagesPaid = 0,
				pirateEncounters = 0, piratesEvaded = 0, piratesDestroyed = 0, cargoLostToPirates = 0,
			}
		else
			entry.stats.netProfit = entry.stats.netProfit or 0
			entry.stats.runsCompleted = entry.stats.runsCompleted or 0
			entry.stats.bountiesEarned = entry.stats.bountiesEarned or 0
			entry.stats.missionsDone = entry.stats.missionsDone or 0
			entry.stats.cargoHauled = entry.stats.cargoHauled or 0
			entry.stats.maintenancePaid = entry.stats.maintenancePaid or 0
			entry.stats.taxesGenerated = entry.stats.taxesGenerated or 0
			entry.stats.wagesPaid = entry.stats.wagesPaid or 0
			entry.stats.pirateEncounters = entry.stats.pirateEncounters or 0
			entry.stats.piratesEvaded = entry.stats.piratesEvaded or 0
			entry.stats.piratesDestroyed = entry.stats.piratesDestroyed or 0
			entry.stats.cargoLostToPirates = entry.stats.cargoLostToPirates or 0
		end
		if type(entry.hyperFuel) ~= "number" then
			entry.hyperFuel = getDefaultHyperFuelForEquip(entry.equip, entry.fuel)
		end
		normalizeFleetCrewForEntry(entry, nil)
		if type(entry.uid) == "number" and entry.uid >= s.nextUid then
			s.nextUid = entry.uid + 1
		end
	end
	return s
end

-- Forward declarations for event hooks and state machine ticks
local applyShipConfig
local spawnOrUpdateLiveFleetShip
local updateFleetTransit
local tickDockTransit
local tickSellCargoTransit
local tickAutoTrade
local tickAutoMine
local tickPatrol
local tickMissionOrder
local getSystemCommodityPrice
local getOrScanSystemMarket
local maintainFleetShipAtStation
local applyOOSHyperjumpWear
local applyOperationalFlightWear
local resolveOOSPirateEncounter

-- ============================================================================
-- Helpers & Logging
-- ============================================================================

local function addLog(shipName, message, deltaCredits, eventTime)
	fleetState.logs = fleetState.logs or {}
	table.insert(fleetState.logs, 1, {
		time = eventTime or Game.time or 0,
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

local function formatSystemName(path)
	if not path then return "Unknown System" end
	local okSys, sys = pcall(function() return path:GetStarSystem() end)
	if okSys and sys then return sys.name end
	return "Unknown System"
end

local function formatDistanceMeters(distMeters)
	local d = math.max(0, tonumber(distMeters) or 0)
	if d < 1000 then
		return string.format("%.0f m", d)
	elseif d < 1e7 then
		return string.format("%.1f km", d / 1000)
	elseif d < 1.496e10 then
		return string.format("%.2f Mm", d / 1e6)
	else
		return string.format("%.2f AU (%.0f ls)", d / AU_IN_METERS, d / LIGHT_SPEED_MPS)
	end
end

local function getSkillMultiplier(entry, skillKey, weight)
	local val = (entry and entry.captain and entry.captain[skillKey]) or 18
	return 1.0 + math.clamp((val - 15) / 50, 0, 1.0) * (weight or 0.25)
end

local function estimateBodyOrbitalDistMeters(targetPath)
	if not targetPath then return 1.2e11 end
	local ok, sbody = pcall(function() return targetPath:GetSystemBody() end)
	if not ok or not sbody then return 1.2e11 end
	local totalDist = 0
	local cur = sbody
	local guard = 0
	while cur and guard < 8 do
		guard = guard + 1
		local parent = nil
		local okP, p = pcall(function() return cur.parent end)
		if okP then parent = p end
		if not parent then break end
		local okSma, sma = pcall(function() return cur.semiMajorAxis end)
		if okSma and sma and sma > 0 then
			totalDist = totalDist + sma
		end
		cur = parent
	end
	if totalDist < 1e8 then totalDist = 1.2e11 end
	return totalDist
end

local function findBestStationInSystem(sys, preferPath)
	if not sys then return nil end
	local ok, stPaths = pcall(function() return sys:GetStationPaths() end)
	if not ok or not stPaths or #stPaths == 0 then return nil end
	if preferPath then
		for _, sp in ipairs(stPaths) do
			if samePath(sp, preferPath) then return sp end
		end
	end
	return stPaths[1]
end

local function findNearestStationPath(refPath, preferPath)
	if preferPath and sameSystem(refPath, preferPath) then
		local ok, sb = pcall(function() return preferPath:GetSystemBody() end)
		if ok and sb and (sb.type == "STARPORT_ORBITAL" or sb.type == "STARPORT_SURFACE") then
			return preferPath
		end
	end
	local sys = refPath and refPath:GetStarSystem() or Game.system
	local st = findBestStationInSystem(sys, preferPath)
	if st then return st end
	if sys then
		local nearPaths = getCachedNearbySystemPaths(sys, 18, true, 32)
		if nearPaths then
			for _, np in ipairs(nearPaths) do
				local mkt = getOrScanSystemMarket(np)
				if mkt and mkt.hasStations and mkt.stationPaths and mkt.stationPaths[1] then
					return mkt.stationPaths[1]
				end
			end
		end
	end
	return nil
end

local function getShipAICommand(ship)
	if not ship or not ship:exists() or not ship.GetCurrentAICommand then
		return nil
	end
	local ok, cmd = pcall(function() return ship:GetCurrentAICommand() end)
	return ok and cmd or nil
end

local function isShipDeparting(ship)
	if not ship or not ship:exists() then return false end
	if ship.flightState == "UNDOCKING" then return true end
	return getShipAICommand(ship) == "CMD_DEPART"
end

local function tryUndockWithATC(ship)
	if not ship or not ship:exists() then return false, nil end
	local fs = ship.flightState
	if fs == "UNDOCKING" then
		return true, ship:GetDockedWith()
	elseif fs == "DOCKED" then
		local port = ship:GetDockedWith()
		if not port or not port:exists() then
			return false, nil
		end
		if port.CanLaunch and not port:CanLaunch(ship) then
			return false, port
		end
		local ok, launched = pcall(function() return ship:Undock() end)
		return (ok and launched == true), port
	elseif fs == "LANDED" then
		local ok = pcall(function() ship:BlastOff() end)
		return ok, nil
	end
	return false, nil
end

local function resolveStationByPath(path)
	if not path or not path:IsBodyPath() or not Game.system or Game.InHyperspace() then
		return nil
	end
	if not sameSystem(path, Game.system.path) then
		return nil
	end
	local okB, b = pcall(function() return Space.GetBody(path.bodyIndex) end)
	if okB and b and b:exists() and b:isa("SpaceStation") then
		return b
	end
	return nil
end

local function enterSafeHoldingOrbit(ship, stationBody)
	if not ship or not ship:exists() or not stationBody or not stationBody:exists() then
		return false
	end
	local okSb, sbody = pcall(function() return stationBody.path and stationBody.path:GetSystemBody() end)
	local parentBody = (okSb and sbody and sbody.parent) and Space.GetBody(sbody.parent.index) or nil
	if not parentBody or not parentBody:exists() then
		return false
	end
	local ok = pcall(function() ship:AIEnterLowOrbit(parentBody) end)
	return ok
end

local function getStationSafeSpawnKm(stationBody)
	local r = (stationBody and stationBody.GetPhysicalRadius and stationBody:GetPhysicalRadius()) or 2000
	return math.max(3.5, (r + 2500) / 1000)
end

local function getStationHyperjumpClearanceMeters(stationBody)
	local r = (stationBody and stationBody.GetPhysicalRadius and stationBody:GetPhysicalRadius()) or 1500
	return math.max(2200, r * 1.5 + 500)
end

local function findAlternativeOrbitalStation(sys, excludePath)
	if not sys then return nil end
	local ok, stPaths = pcall(function() return sys:GetStationPaths() end)
	if not ok or not stPaths then return nil end
	for _, sp in ipairs(stPaths) do
		if not excludePath or not samePath(sp, excludePath) then
			local okSb, sb = pcall(function() return sp:GetSystemBody() end)
			if okSb and sb and sb.type == "STARPORT_ORBITAL" then
				return sp
			end
		end
	end
	return nil
end

local function systemDistLy(a, b)
	if not a or not b then return 0 end
	local ok, d = pcall(function() return a:DistanceTo(b) end)
	if ok and d then return d end
	return 0
end

local function getEffectiveJumpRange(entry, liveShip)
	local maxRange, curRange = PlayerFleet.GetShipHyperspaceRangeExact(entry)
	local eff = math.max(curRange or 0, maxRange or 0)
	if liveShip and liveShip:exists() then
		local okD, drive = pcall(function() return liveShip:GetInstalledHyperdrive() end)
		if okD and drive and drive.GetRange then
			local okR, lCur, lMax = pcall(function() return drive:GetRange(liveShip) end)
			if okR and (lCur or lMax) then
				eff = math.max(lCur or 0, lMax or 0)
			end
		end
	end
	return math.max(1.0, eff * 0.96)
end

local function findJumpRoute(fromSysPath, destSysPath, maxRangeLy)
	if not fromSysPath or not destSysPath then return {}, {} end
	local srcSysOnly = fromSysPath:SystemOnly()
	local dstSysOnly = destSysPath:SystemOnly()
	if sameSystem(srcSysOnly, dstSysOnly) then
		return {}, {}
	end
	local effRange = math.max(1.5, tonumber(maxRangeLy) or 8.0)
	local directDist = systemDistLy(srcSysOnly, dstSysOnly)
	if directDist <= effRange then
		return { dstSysOnly }, { directDist }
	end

	local curSys = srcSysOnly:GetStarSystem()
	if curSys and curSys.FindJumpRoute then
		local okR, hops, hopDists = pcall(function()
			return curSys:FindJumpRoute(dstSysOnly, effRange)
		end)
		if okR and type(hops) == "table" and #hops > 0 then
			return hops, hopDists or {}
		end
	end

	return { dstSysOnly }, { directDist }
end

local function getInstalledHyperdriveInfo(entry)
	for _, eq in ipairs(entry.equip or {}) do
		local proto = Equipment.Get(eq.id)
		if proto and proto.capabilities and proto.capabilities.hyperclass and proto.capabilities.hyperclass > 0 then
			return proto, eq, proto.capabilities.hyperclass
		end
	end
	return nil, nil, 0
end

local function computeEntryMasses(entry, liveShip)
	if liveShip and liveShip:exists() then
		local sm = liveShip.staticMass or 0
		local fm = liveShip.fuelMassLeft or 0
		if sm > 0 then
			return sm, fm
		end
	end
	local def = ShipDef[entry.shipId]
	local hullMass = (def and def.hullMass) or 20
	local equipMass = 0
	local hyperFuelMass = 0
	for _, eq in ipairs(entry.equip or {}) do
		local proto = Equipment.Get(eq.id)
		if proto and proto.mass then
			equipMass = equipMass + (proto.mass * (eq.count or 1))
		end
	end
	local driveProto = getInstalledHyperdriveInfo(entry)
	if driveProto then
		local resv = driveProto.fuel_resv_size or 1
		local stored = (type(entry.hyperFuel) == "number") and entry.hyperFuel or resv
		hyperFuelMass = math.clamp(stored, 0, resv)
	end
	local cargoMass = PlayerFleet.GetCargoUsed(entry)
	local tankCap = (def and def.fuelTankMass) or 10
	local fuelMassLeft = tankCap * math.clamp((entry.fuel or 100) / 100, 0, 1)
	return (hullMass + equipMass + hyperFuelMass + cargoMass), fuelMassLeft
end

local function computeHyperdriveEfficiency(driveProto, totalMass)
	local hclass = (driveProto and driveProto.capabilities and driveProto.capabilities.hyperclass) or 1
	local factorEff = (driveProto and driveProto.factor_eff) or 55
	return factorEff / (math.max(1, totalMass) ^ (3 / 5)) * (1 + hclass) / hclass
end

local function computeJumpFuelUse(entry, distLy, liveShip)
	local d = math.max(0.01, tonumber(distLy) or 1.0)
	if liveShip and liveShip:exists() then
		local okD, drive = pcall(function() return liveShip:GetInstalledHyperdrive() end)
		if okD and drive and drive.GetFuelUse then
			local okF, fuelUse = pcall(function() return drive:GetFuelUse(liveShip, d) end)
			if okF and type(fuelUse) == "number" and fuelUse >= 0 then
				return fuelUse
			end
		end
	end
	local driveProto = getInstalledHyperdriveInfo(entry)
	if not driveProto then return 0 end
	local staticMass, fuelMassLeft = computeEntryMasses(entry, nil)
	local eff = computeHyperdriveEfficiency(driveProto, staticMass + fuelMassLeft)
	return (d ^ HYPER_FUEL_EXP) / eff
end

-- Exact parity with HyperdriveType:GetDuration in data/modules/Equipment/Types.lua
local function computeJumpDurationSec(entry, distLy, liveShip)
	local d = math.max(0.01, tonumber(distLy) or 1.0)
	if liveShip and liveShip:exists() then
		local okD, drive = pcall(function() return liveShip:GetInstalledHyperdrive() end)
		if okD and drive and drive.GetDuration then
			local okT, dur = pcall(function() return drive:GetDuration(liveShip, d) end)
			if okT and type(dur) == "number" and dur > 0 then
				return math.max(60, math.floor(dur))
			end
		end
	end
	local driveProto = getInstalledHyperdriveInfo(entry)
	local hclass = (driveProto and driveProto.capabilities and driveProto.capabilities.hyperclass) or 1
	local factorTime = (driveProto and driveProto.factor_time) or 1.0
	local staticMass, fuelMassLeft = computeEntryMasses(entry, nil)
	local totalMass = math.max(1, staticMass + fuelMassLeft)
	local dur = 86400 * 0.36 * ((d ^ HYPER_RANGE_EXP) * (totalMass ^ HYPER_MASS_EXP)) / (425 * (hclass ^ 2) * factorTime)
	return math.max(60, math.floor(dur))
end

local function computeOOSSupercruiseDurationSec(entry, destPath)
	local distMeters = estimateBodyOrbitalDistMeters(destPath)
	local distLs = distMeters / LIGHT_SPEED_MPS
	local scTransit = math.clamp(120.0 + distLs * 0.45, 120.0, 600.0)
	local undockAndDock = 180.0
	local dur = math.max(210, math.floor((scTransit + undockAndDock) / getSkillMultiplier(entry, "piloting", 0.20)))
	return dur, distMeters
end

local function findShipIndex(uid)
	for i, entry in ipairs(fleetState.ships or {}) do
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
	fleetState.ships = fleetState.ships or {}
	return fleetState.ships
end

function PlayerFleet.GetLogs()
	fleetState.logs = fleetState.logs or {}
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

function PlayerFleet.GetTradeRange(entry)
	if not entry or type(entry.orderParams) ~= "table" or type(entry.orderParams.tradeRangeLy) ~= "number" then
		return DEFAULT_TRADE_RANGE_LY
	end
	return math.clamp(entry.orderParams.tradeRangeLy, 0, MAX_TRADE_RANGE_LY)
end

function PlayerFleet.SetTradeRange(uid, rangeLy)
	local _, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end
	local clamped = math.clamp(math.floor((tonumber(rangeLy) or DEFAULT_TRADE_RANGE_LY) + 0.5), 0, MAX_TRADE_RANGE_LY)
	entry.orderParams = entry.orderParams or { maxJumps = 12, autoSell = true }
	entry.orderParams.tradeRangeLy = clamped
	activeTradeScans[uid] = nil
	if entry.order == "AUTO_TRADE" and (entry.orderParams.tradeState == "SCANNING" or entry.status == "SCANNING") then
		entry.orderParams.tradeState = "SEEKING"
		entry.orderParams.nextSeekTime = 0
		entry.status = "TRADING"
		entry.orderProgress = 0
		entry.orderPhase = string.format("[SCANNING] Re-plotting trade markets within %d ly...", clamped)
	end
	local label = (clamped == 0) and "Local System Only" or string.format("%d ly", clamped)
	return true, string.format("%s Auto-Trade radius set to %s.", entry.shipName, label)
end

function PlayerFleet.GetDefenseOrder(entry)
	if not entry then return "FLEE" end
	if entry.defenseOrder == "SUBMIT" or entry.defenseOrder == "FLEE" or entry.defenseOrder == "DEFEND" then
		return entry.defenseOrder
	end
	return "FLEE"
end

function PlayerFleet.SetDefenseOrder(uid, order)
	local _, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end
	if order ~= "SUBMIT" and order ~= "FLEE" and order ~= "DEFEND" then
		return false, "Invalid defense order."
	end
	entry.defenseOrder = order
	local label = (order == "SUBMIT" and "Submit (drop cargo)")
		or (order == "DEFEND" and "Defend (drop no cargo)")
		or "Flee (evade / partial drop)"
	addLog(entry.shipName, string.format("Pirate defense stance set to %s.", label), 0)
	return true, string.format("%s defense order set to %s.", entry.shipName, label)
end

function PlayerFleet.HasInterdictionNullifier(entry)
	if not entry or not entry.equip then return false end
	for _, eq in ipairs(entry.equip) do
		if (eq.integrity or 1.0) > 0.10 then
			if eq.id == "misc.interdiction_nullifier" then
				return true, eq
			end
			local proto = Equipment.Get(eq.id)
			if proto and proto.capabilities and (proto.capabilities.interdiction_nullifier or 0) > 0 then
				return true, eq
			end
		end
	end
	return false, nil
end

function PlayerFleet.GetShipsAtStation(stationPath)
	local res = {}
	if not stationPath then return res end
	for _, entry in ipairs(fleetState.ships or {}) do
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
	local driveProto, _, hclass = getInstalledHyperdriveInfo(entry)
	return driveProto ~= nil, hclass
end

function PlayerFleet.GetShipHyperspaceRangeExact(entry)
	if not entry then return 0, 0 end
	if entry.liveShip and entry.liveShip:exists() then
		local okD, drive = pcall(function() return entry.liveShip:GetInstalledHyperdrive() end)
		if okD and drive and drive.GetRange then
			local okR, curRange, maxRange = pcall(function() return drive:GetRange(entry.liveShip) end)
			if okR and (maxRange or curRange) then
				return math.max(0, maxRange or curRange or 0), math.max(0, curRange or 0)
			end
		end
	end
	local driveProto = getInstalledHyperdriveInfo(entry)
	if not driveProto then return 0, 0 end
	local resv = driveProto.fuel_resv_size or 1
	local stored = math.clamp((type(entry.hyperFuel) == "number") and entry.hyperFuel or resv, 0, resv)
	local staticMass, fuelMassLeft = computeEntryMasses(entry, nil)
	local effCur = computeHyperdriveEfficiency(driveProto, staticMass + fuelMassLeft)
	local effMax = computeHyperdriveEfficiency(driveProto, staticMass + fuelMassLeft + math.max(0, resv - stored))
	local curRange = (stored > 0) and ((stored * effCur) ^ HYPER_FUEL_EXP_INV) or 0
	local maxRange = (resv > 0) and ((resv * effMax) ^ HYPER_FUEL_EXP_INV) or 0
	return maxRange, curRange
end

function PlayerFleet.GetShipHyperspaceRange(entry)
	local maxRange, curRange = PlayerFleet.GetShipHyperspaceRangeExact(entry)
	return math.floor(maxRange), curRange
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

function PlayerFleet.GetPassengerCap(entry)
	if not entry then return 0 end
	if entry.liveShip and entry.liveShip:exists() then
		return math.max(0, (entry.liveShip["cabin_cap"] or 0) - (entry.liveShip["cabin_occupied_cap"] or 0))
	end
	local total = 0
	for _, eq in ipairs(entry.equip or {}) do
		local proto = Equipment.Get(eq.id)
		if proto and proto.capabilities and proto.capabilities.cabin then
			total = total + (proto.capabilities.cabin or 0)
		end
	end
	return total
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
		local isUsed = rawget(eq, "isUsed") == true
		table.insert(list, {
			slotId = (type(key) == "string") and key or nil,
			id = eq.id,
			count = eq.count,
			integrity = rawget(eq, "integrity"),
			isUsed = isUsed or nil,
			usedPrice = isUsed and rawget(eq, "price") or nil,
			subsidized = (rawget(eq, "price") == 0) or (eq.insuranceSubsidized == true) or nil,
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
			if item.integrity ~= nil then
				inst.integrity = math.clamp(item.integrity, 0, 1)
			end
			if item.subsidized then
				inst.price = 0
				inst.insuranceSubsidized = true
			else
				if item.isUsed then inst.isUsed = true end
				if item.usedPrice ~= nil then inst.price = item.usedPrice end
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
	pcall(function() ComponentIntegrity.SyncShipSubsystems(ship) end)
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

local function fillShipHyperdriveFuel(ship, entry)
	if not ship or not ship:exists() then return end
	local okD, drive = pcall(function() return ship:GetInstalledHyperdrive() end)
	if okD and drive and drive.SetFuel and drive.GetMaxFuel then
		local maxFuel = drive:GetMaxFuel() or 0
		if maxFuel > 0 then
			local stored = (entry and type(entry.hyperFuel) == "number") and entry.hyperFuel or maxFuel
			stored = math.clamp(stored, 0, maxFuel)
			pcall(function() drive:SetFuel(ship, stored) end)
		end
	end
end

applyShipConfig = function(ship, entry)
	if not ship or not ship:exists() or not entry then return end
	if entry.skin then pcall(function() ship:SetSkin(entry.skin) end) end
	if entry.pattern and ship.model and ship.model.SetPattern then
		pcall(function() ship.model:SetPattern(entry.pattern) end)
	end
	ship:SetLabel(entry.label)
	ship:SetShipName("[FLEET] " .. entry.shipName)
	applyEquipListToShip(ship, entry.equip)
	fillShipHyperdriveFuel(ship, entry)
	applyCargoToShip(ship, entry.cargo)
	ship:SetHullPercent(math.clamp(entry.hullPercent or 100, 1, 100))
	ship:SetFuelPercent(math.clamp(entry.fuel or 100, 0, 100))
end

local function buildDefaultEquipForAdvert(def, advertEquip)
	local list = {}
	for _, pair in ipairs(advertEquip or {}) do
		local slotId, inst = pair[1], pair[2]
		local isUsed = rawget(inst, "isUsed") == true
		table.insert(list, {
			slotId = slotId,
			id = inst.id,
			count = inst.count,
			integrity = rawget(inst, "integrity"),
			isUsed = isUsed or nil,
			usedPrice = isUsed and rawget(inst, "price") or nil,
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
	local uid = fleetState.nextUid or 1
	fleetState.nextUid = uid + 1

	local label = (ship.label and ship.label ~= "") and ship.label or Ship.MakeRandomLabel()
	local name = (customName and customName ~= "") and customName
		or (ship.shipName and ship.shipName ~= "" and ship.shipName)
		or string.format("%s [%s]", def.name, label)

	local equipList = packEquipFromShip(ship)
	local initHyperFuel = getDefaultHyperFuelForEquip(equipList, ship.fuel)
	local okD, drive = pcall(function() return ship:GetInstalledHyperdrive() end)
	if okD and drive and drive.GetFuel then
		local okF, df = pcall(function() return drive:GetFuel() end)
		if okF and type(df) == "number" then
			initHyperFuel = math.max(0, df)
		end
	end

	local entry = {
		uid = uid,
		shipName = name,
		label = label,
		shipId = ship.shipId,
		skin = ship:GetSkin(),
		pattern = ship.model and ship.model.pattern or 0,
		isCharterStarter = (ship == Game.player) and Insurance.IsPlayerShipSubsidized() or false,
		hullPercent = math.clamp(ship.hullPercent or 100, 1, 100),
		shieldPercent = 100,
		fuel = math.clamp(ship.fuel or 100, 0, 100),
		hyperFuel = initHyperFuel,
		cargoCap = ship.cargo_cap or def.cargo,
		equip = equipList,
		cargo = packCargoFromShip(ship),
		cargoCostBasis = {},
		locationPath = stationPath,
		locationName = formatPathName(stationPath),
		status = "DOCKED",
		captain = nil,
		crew = {},
		order = "IDLE",
		defenseOrder = "FLEE",
		orderTargetPath = nil,
		orderTargetName = nil,
		orderParams = { maxJumps = 12, autoSell = true, tradeRangeLy = DEFAULT_TRADE_RANGE_LY },
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
			maintenancePaid = 0,
			taxesGenerated = 0,
			wagesPaid = 0,
			pirateEncounters = 0,
			piratesEvaded = 0,
			piratesDestroyed = 0,
			cargoLostToPirates = 0,
		},
	}
	return entry
end

-- Sync hull, fuel, hyperdrive fuel, cargo, and equipment integrity from liveShip back into FleetEntry
local function syncFromLiveShip(entry)
	local s = entry.liveShip
	if not s or not s:exists() then
		entry.liveShip = nil
		return
	end
	entry.hullPercent = math.clamp(s.hullPercent or entry.hullPercent or 100, 1, 100)
	entry.fuel = math.clamp(s.fuel or entry.fuel or 100, 0, 100)
	entry.cargo = packCargoFromShip(s)
	entry.equip = packEquipFromShip(s)
	local okD, drive = pcall(function() return s:GetInstalledHyperdrive() end)
	if okD and drive and drive.GetFuel then
		local okF, f = pcall(function() return drive:GetFuel() end)
		if okF and type(f) == "number" then
			entry.hyperFuel = math.max(0, f)
		end
	end
end

local function despawnLiveShip(entry)
	if entry.liveShip and entry.liveShip:exists() then
		syncFromLiveShip(entry)
	end
	entry.liveShip = nil
end

local function adjustEntryCargoCostBasis(entry, commodityName, deltaCount, unitPrice)
	if not entry or not commodityName or not deltaCount or deltaCount == 0 then return 0 end
	entry.cargoCostBasis = entry.cargoCostBasis or {}
	local item = entry.cargoCostBasis[commodityName]
	if deltaCount > 0 then
		local p = tonumber(unitPrice) or 0
		if not item or (item.count or 0) <= 0 then
			entry.cargoCostBasis[commodityName] = { count = deltaCount, avgPrice = p }
		else
			local totalCost = (item.count * item.avgPrice) + (deltaCount * p)
			local newCount = item.count + deltaCount
			item.count = newCount
			item.avgPrice = totalCost / newCount
		end
		return p
	else
		local take = math.abs(deltaCount)
		local avg = (item and item.avgPrice) or 0
		if item then
			item.count = math.max(0, (item.count or 0) - take)
			if item.count <= 0 then
				entry.cargoCostBasis[commodityName] = nil
			end
		end
		return avg * take, avg
	end
end

function PlayerFleet.GetLowestEquipmentIntegrity(entry)
	local minInteg = 1.0
	local below80Count = 0
	local repairCostBelow80 = 0
	local repairCostAll = 0
	local repairThreshold = ComponentIntegrity.REPAIR_THRESHOLD or 0.90
	for _, eq in ipairs((entry and entry.equip) or {}) do
		local integ = math.clamp((type(eq.integrity) == "number") and eq.integrity or 1.0, 0.0, 1.0)
		if integ < minInteg then
			minInteg = integ
		end
		local proto = Equipment.Get(eq.id)
		local price = eq.usedPrice or (proto and proto.price) or 500
		if integ < repairThreshold then
			local cost = ComponentIntegrity.GetModuleRepairCost({ integrity = integ, price = price })
			repairCostAll = repairCostAll + cost
			if integ < MAINTENANCE_INTEGRITY_THRESHOLD then
				below80Count = below80Count + 1
				repairCostBelow80 = repairCostBelow80 + cost
			end
		end
	end
	return minInteg, below80Count, repairCostBelow80, repairCostAll
end

local function applyEquipmentWear(entry, wearFn)
	if not entry or not entry.equip or not wearFn then return end
	local changed = false
	for _, eq in ipairs(entry.equip) do
		local cur = math.clamp((type(eq.integrity) == "number") and eq.integrity or 1.0, 0.0, 1.0)
		if cur > ComponentIntegrity.PASSIVE_WEAR_FLOOR then
			local proto = Equipment.Get(eq.id)
			local loss = tonumber(wearFn(proto, eq)) or 0
			if loss > 0 then
				local nxt = math.max(ComponentIntegrity.PASSIVE_WEAR_FLOOR, cur - loss)
				if nxt ~= cur then
					eq.integrity = nxt
					changed = true
				end
			end
		end
	end
	if changed and entry.liveShip and entry.liveShip:exists() then
		local equipSet = entry.liveShip:GetComponent('EquipSet')
		if equipSet then
			for key, liveEq in pairs(equipSet:GetInstalledEquipment()) do
				local slotId = type(key) == "string" and key or nil
				for _, savedEq in ipairs(entry.equip) do
					if savedEq.id == liveEq.id and (not savedEq.slotId or savedEq.slotId == slotId) then
						liveEq.integrity = savedEq.integrity or 1.0
						equipSet:NotifyListeners('modify', liveEq)
						break
					end
				end
			end
			pcall(function() ComponentIntegrity.SyncShipSubsystems(entry.liveShip) end)
		end
	end
end

applyOOSHyperjumpWear = function(entry, jumpDurationSec)
	applyEquipmentWear(entry, function(proto, eq)
		local slotType = (proto and proto.slot and proto.slot.type) or ""
		local isHd = slotType:match("^hyperdrive") ~= nil
		return ComponentIntegrity.ComputeHyperjumpWear(jumpDurationSec or 3600, isHd, eq.id)
	end)
end

applyOperationalFlightWear = function(entry, destPath, legType)
	local engSkill = (entry and entry.captain and entry.captain.engineering) or 18
	local engFactor = math.clamp(1.15 - (engSkill / 100), 0.70, 1.10)
	local surfaceGEarth = 0
	if destPath then
		local okSb, sbody = pcall(function() return destPath:GetSystemBody() end)
		if okSb and sbody and sbody.type == "STARPORT_SURFACE" and sbody.parent and sbody.parent.gravity then
			surfaceGEarth = (sbody.parent.gravity or 0) / ComponentIntegrity.STANDARD_GRAVITY
		end
	end

	applyEquipmentWear(entry, function(proto, eq)
		local cat = ComponentIntegrity.ClassifyEquipment(proto or eq, eq.slotId)
		local baseLoss = 0.004
		if legType == "COMBAT" then
			if cat == "weapon" or cat == "shields" then
				baseLoss = Engine.rand:Number(0.035, 0.065)
			elseif cat == "thrusters" or cat == "sensors" then
				baseLoss = Engine.rand:Number(0.020, 0.030)
			else
				baseLoss = 0.012
			end
		elseif legType == "MINING" then
			if cat == "weapon" or cat == "utility" or cat == "scoop" then
				baseLoss = Engine.rand:Number(0.022, 0.032)
			elseif cat == "thrusters" or cat == "shields" then
				baseLoss = Engine.rand:Number(0.015, 0.022)
			else
				baseLoss = 0.008
			end
		else
			if cat == "thrusters" then
				baseLoss = 0.010
			elseif cat == "shields" or cat == "utility" or cat == "hyperdrive" then
				baseLoss = 0.005
			else
				baseLoss = 0.003
			end
		end
		local gravLoss = (surfaceGEarth >= 0.05) and ComponentIntegrity.ComputeGravityWear(surfaceGEarth, 300, cat, false) or 0
		return (baseLoss + gravLoss) * engFactor
	end)

	if legType == "MINING" then
		local chip = Engine.rand:Integer(0, 2)
		if chip > 0 then
			entry.hullPercent = math.max(30, (entry.hullPercent or 100) - chip)
		end
	end
end

-- ============================================================================
-- Valuation & Ship Market Purchases
-- ============================================================================

function PlayerFleet.ComputeShipValue(entry)
	local def = ShipDef[entry.shipId]
	if not def then return 0 end

	local hullBase = entry.isCharterStarter and 0 or def.basePrice
	local value = hullBase * SHIP_SELL_RATIO * ((entry.hullPercent or 100) / 100)
	for _, eq in ipairs(entry.equip or {}) do
		if not eq.subsidized then
			if eq.usedPrice ~= nil then
				value = value + (eq.usedPrice * EQUIP_SELL_RATIO)
			else
				local proto = Equipment.Get(eq.id)
				if proto and proto.price then
					value = value + (proto.price * (eq.count or 1) * EQUIP_SELL_RATIO)
				end
			end
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
	local now = Game.time or 0
	local oldWage = (savedContract and tonumber(savedContract.wage)) or tonumber(crewMember.fleetWage) or 50
	local oldPayday = (savedContract and tonumber(savedContract.payday)) or tonumber(crewMember.fleetPayday)
	local oldOwed = (savedContract and tonumber(savedContract.outstanding)) or tonumber(crewMember.fleetOwed) or 0

	Game.player:Dismiss(crewMember)
	-- Undo Save()/availability release since they remain in player's fleet service
	crewMember:UnSave()
	crewMember.available = false
	-- Leave contract nil so CrewContracts does not double-pay while assigned to fleet
	crewMember.contract = nil
	crewMember.fleetWage = math.max(25, math.floor(oldWage))
	crewMember.fleetOwed = math.max(0, math.floor(oldOwed))
	crewMember.fleetPayday = (type(oldPayday) == "number" and oldPayday > now) and oldPayday or (now + WAGE_PERIOD_SEC)
	crewMember.completedOps = math.max(0, math.floor(tonumber(crewMember.completedOps) or 0))
	crewMember.weeksServed = math.max(0, math.floor(tonumber(crewMember.weeksServed) or 0))
	crewMember.activeWeeks = math.max(0, math.floor(tonumber(crewMember.activeWeeks) or 0))
	crewMember.lastPayOps = math.max(0, math.floor(tonumber(crewMember.lastPayOps) or crewMember.completedOps))
	crewMember.payrollInitialized = true
	return crewMember
end

local function enrollCrewBackOnPlayer(crewMember)
	if not crewMember or crewMember.player then return false end
	local now = Game.time or 0
	crewMember.contract = {
		wage = math.max(10, math.floor(tonumber(crewMember.fleetWage) or 50)),
		payday = (type(crewMember.fleetPayday) == "number" and crewMember.fleetPayday > now) and crewMember.fleetPayday or (now + WAGE_PERIOD_SEC),
		outstanding = math.max(0, math.floor(tonumber(crewMember.fleetOwed) or 0)),
	}
	crewMember.available = true
	local ok = Game.player:Enroll(crewMember)
	if ok then
		crewMember.fleetOwed = 0
		if crewMember.title == "Captain" or crewMember.title == "Fleet Crew" then
			crewMember.title = nil
		end
	else
		crewMember.contract = nil
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
	if player.SetShipName then
		player:SetShipName(ShipDealerships.DefaultShipNameForListing(sos))
	end

	ShipDealerships.InstallListingEquipment(player, advertData, sos)
end

-- Buy a ship and store Game.player's current ship in the station's hangar (no trade-in)
function PlayerFleet.StorePlayerShipAndBuy(sos, advertData)
	if Insurance.HasClaim() then
		return false, "Settle your open insurance claim at the Insurance & SAR office before storing or purchasing ships."
	end
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
	local storedMax = (ShipDef[storedEntry.shipId] and ShipDef[storedEntry.shipId].maxCrew) or 1
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
			if #storedEntry.crew < storedMax then
				local c = transferCrewFromPlayerInternal(candidates[i])
				if c then
					table.insert(storedEntry.crew, c)
					if not storedEntry.captain then
						storedEntry.captain = c
					end
				end
			else
				Game.player:Dismiss(candidates[i])
				candidates[i]:Save()
			end
		end
	end
	normalizeFleetCrewForEntry(storedEntry, Game.time)

	PlayerState.AddMoney(-cost)
	station:RemoveShipOnSale(sos)
	setupPlayerShipFromAdvert(player, sos, advertData)
	Insurance.SetPlayerShipSubsidized(false)

	fleetState.ships = fleetState.ships or {}
	table.insert(fleetState.ships, storedEntry)
	spawnOrUpdateLiveFleetShip(storedEntry, false, false)
	addLog(storedEntry.shipName, string.format("Stored flagship in hangar at %s upon purchasing %s.", station.label, sos.def.name), -cost)

	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		FlightLog.RecordTransaction({
			category = "SHIP",
			title = string.format("Fleet Procurement: %s (%s)", sos.def.name, Format.Money(-cost)),
			amount = -cost,
			details = {
				{ "Procured Vessel Model", sos.def.name },
				{ "Procured Vessel Registration", sos.label or "Unnamed" },
				{ "Previous Flagship Stored", storedEntry.shipName },
				{ "Hangar Station", station.label or "Starport Hangar" },
				{ "Total Procurement Cost", Format.Money(cost) },
			},
			note = string.format("Purchased %s (%s) from shipyard and docked previous flagship in station hangar.", sos.def.name, sos.label or "Unnamed")
		})
	end

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
	local uid = fleetState.nextUid or 1
	fleetState.nextUid = uid + 1

	local equipList = buildDefaultEquipForAdvert(def, advertData.equip)
	local initHyperFuel = getDefaultHyperFuelForEquip(equipList, 100)
	local label = sos.label or Ship.MakeRandomLabel()
	local entry = {
		uid = uid,
		shipName = string.format("%s [%s]", def.name, label),
		label = label,
		shipId = def.id,
		skin = sos.skin,
		pattern = sos.pattern or 0,
		hullPercent = sos.hullPercent or 100,
		shieldPercent = 100,
		fuel = 100,
		hyperFuel = initHyperFuel,
		cargoCap = def.cargo,
		equip = equipList,
		cargo = {},
		cargoCostBasis = {},
		locationPath = station.path,
		locationName = formatPathName(station.path),
		status = "DOCKED",
		captain = nil,
		crew = {},
		order = "IDLE",
		defenseOrder = "FLEE",
		orderTargetPath = nil,
		orderTargetName = nil,
		orderParams = { maxJumps = 12, autoSell = true, tradeRangeLy = DEFAULT_TRADE_RANGE_LY },
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
			maintenancePaid = 0,
			taxesGenerated = 0,
			wagesPaid = 0,
			pirateEncounters = 0,
			piratesEvaded = 0,
			piratesDestroyed = 0,
			cargoLostToPirates = 0,
		},
	}

	PlayerState.AddMoney(-cost)
	station:RemoveShipOnSale(sos)
	fleetState.ships = fleetState.ships or {}
	table.insert(fleetState.ships, entry)
	spawnOrUpdateLiveFleetShip(entry, false, false)
	addLog(entry.shipName, string.format("Purchased into hangar at %s.", station.label), -cost)

	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		FlightLog.RecordTransaction({
			category = "SHIP",
			title = string.format("Fleet Hangar Acquisition: %s (%s)", def.name, Format.Money(-cost)),
			amount = -cost,
			details = {
				{ "Procured Vessel Model", def.name },
				{ "Procured Vessel Registration", label },
				{ "Assigned Hangar Location", station.label or "Starport Hangar" },
				{ "Cargo Capacity", string.format("%d t", def.cargo or 0) },
				{ "Total Acquisition Cost", Format.Money(cost) },
			},
			note = string.format("Purchased %s into fleet reserve hangar at %s.", entry.shipName, station.label)
		})
	end

	return true, string.format("Purchased %s into hangar at %s.", entry.shipName, station.label)
end

-- ============================================================================
-- Hangar Operations (Swap, Transfer, Repair, Refuel, Rename, Ferry, Sell)
-- ============================================================================

function PlayerFleet.SwapWithFlagship(uid)
	if Insurance.HasClaim() then
		return false, "Settle your open insurance claim at the Insurance & SAR office before swapping ships."
	end
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
	local parkedMaxCrew = (ShipDef[parkedOld.shipId] and ShipDef[parkedOld.shipId].maxCrew) or 1
	local nonPlayerCrew = {}
	for member in player:EachCrewMember() do
		if not member.player then
			table.insert(nonPlayerCrew, member)
		end
	end
	if (1 + #nonPlayerCrew) > targetMaxCrew then
		local needRemove = (1 + #nonPlayerCrew) - targetMaxCrew
		for i = 1, needRemove do
			if #parkedOld.crew < parkedMaxCrew then
				local c = transferCrewFromPlayerInternal(nonPlayerCrew[i])
				if c then
					table.insert(parkedOld.crew, c)
					if not parkedOld.captain then parkedOld.captain = c end
				end
			else
				Game.player:Dismiss(nonPlayerCrew[i])
				nonPlayerCrew[i]:Save()
			end
		end
	end

	-- Preserve the boarded ship's captain/crew onto parkedOld respecting berth capacity;
	-- overflow crew attempt to join the player's newly boarded flagship or enter station pool.
	if #(entry.crew or {}) > 0 then
		local ordered = {}
		if entry.captain then
			table.insert(ordered, entry.captain)
		end
		for _, c in ipairs(entry.crew) do
			if c ~= entry.captain then
				table.insert(ordered, c)
			end
		end
		for _, c in ipairs(ordered) do
			if #parkedOld.crew < parkedMaxCrew then
				table.insert(parkedOld.crew, c)
				if c == entry.captain and not parkedOld.captain then
					parkedOld.captain = c
				end
			else
				if not enrollCrewBackOnPlayer(c) then
					c:Save()
				end
			end
		end
	end
	normalizeFleetCrewForEntry(parkedOld, Game.time)
	if parkedOld.captain then
		parkedOld.orderPhase = "Docked with Captain " .. parkedOld.captain.name
	end

	local oldLive = (entry.liveShip and entry.liveShip:exists()) and entry.liveShip or nil
	entry.liveShip = nil
	activeTradeScans[uid] = nil

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
	fillShipHyperdriveFuel(player, entry)
	applyCargoToShip(player, entry.cargo)
	player:SetHullPercent(math.clamp(entry.hullPercent or 100, 1, 100))
	player:SetFuelPercent(math.clamp(entry.fuel or 100, 0, 100))
	Insurance.SetPlayerShipSubsidized(entry.isCharterStarter == true)

	-- Reuse old physical ship body in the bay for the newly parked old flagship
	if oldLive and oldLive:exists() then
		clearShipCargo(oldLive)
		oldLive:SetShipType(parkedOld.shipId)
		applyShipConfig(oldLive, parkedOld)
		parkedOld.liveShip = oldLive
	else
		spawnOrUpdateLiveFleetShip(parkedOld, false, false)
	end

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

	local soldLive = (entry.liveShip and entry.liveShip:exists()) and entry.liveShip or nil
	entry.liveShip = nil
	activeTradeScans[uid] = nil
	if soldLive then
		pcall(function()
			soldLive:SetShipName("Sold Vessel")
			if soldLive.flightState == "DOCKED" then
				local port = soldLive:GetDockedWith()
				local stowed = port and port:exists() and port.StowShipInHangar and port:StowShipInHangar(soldLive)
				if not stowed then
					soldDepartingShips[soldLive] = true
					tryUndockWithATC(soldLive)
					Timer:CallEvery(4, function()
						if not Game.system or Game.InHyperspace() or not soldLive or not soldLive:exists() then
							if soldLive then soldDepartingShips[soldLive] = nil end
							return true
						end
						if soldLive.flightState ~= "DOCKED" then
							return true
						end
						tryUndockWithATC(soldLive)
						return false
					end)
				end
			elseif Game.system then
				local stars = Game.system:GetStars()
				if stars and stars[1] and stars[1].body then
					soldLive:AIFlyTo(stars[1].body)
				end
			end
		end)
	end

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
	entry.stats.maintenancePaid = (entry.stats.maintenancePaid or 0) + cost
	if entry.liveShip and entry.liveShip:exists() then
		entry.liveShip:SetHullPercent(100)
	end
	TaxAuthority.RecordOperatingExpense(cost, "FLEET_MAINTENANCE", entry.shipName)
	addLog(entry.shipName, string.format("Hull repaired to 100%% at %s.", entry.locationName), -cost)
	return true, string.format("Repaired %s for %s.", entry.shipName, Format.Money(cost, false))
end

function PlayerFleet.ServiceEquipment(uid)
	local _, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end
	if entry.status ~= "DOCKED" then return false, "Vessel must be docked for component servicing." end

	local _, _, _, totalCost = PlayerFleet.GetLowestEquipmentIntegrity(entry)
	if totalCost <= 0 then
		return false, "All ship components are at nominal integrity (90%+)."
	end
	if PlayerState.GetMoney() < totalCost then
		return false, string.format("Insufficient credits (%s needed).", Format.Money(totalCost, false))
	end

	local repairThreshold = ComponentIntegrity.REPAIR_THRESHOLD or 0.90
	local repairedCount = 0
	for _, eq in ipairs(entry.equip or {}) do
		local integ = math.clamp((type(eq.integrity) == "number") and eq.integrity or 1.0, 0.0, 1.0)
		if integ < repairThreshold then
			eq.integrity = 1.0
			repairedCount = repairedCount + 1
		end
	end

	if entry.liveShip and entry.liveShip:exists() then
		local equipSet = entry.liveShip:GetComponent('EquipSet')
		if equipSet then
			for _, liveEq in pairs(equipSet:GetInstalledEquipment()) do
				local liveInteg = math.clamp((type(rawget(liveEq, "integrity")) == "number") and rawget(liveEq, "integrity") or 1.0, 0.0, 1.0)
				if liveInteg < repairThreshold then
					liveEq.integrity = 1.0
					equipSet:NotifyListeners('modify', liveEq)
				end
			end
		end
		pcall(function() ComponentIntegrity.SyncShipSubsystems(entry.liveShip) end)
	end

	PlayerState.AddMoney(-totalCost)
	entry.stats.maintenancePaid = (entry.stats.maintenancePaid or 0) + totalCost
	TaxAuthority.RecordOperatingExpense(totalCost, "FLEET_MAINTENANCE", entry.shipName)
	addLog(entry.shipName, string.format("Serviced %d worn component(s) to 100%% at %s.", repairedCount, entry.locationName or "station"), -totalCost)

	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		FlightLog.RecordTransaction({
			category = "MAINTENANCE",
			title = string.format("Fleet Component Overhaul: %s (%s)", entry.shipName, Format.Money(-totalCost)),
			amount = -totalCost,
			details = {
				{ "Vessel", entry.shipName },
				{ "Location", entry.locationName or "Starport Hangar" },
				{ "Components Restored", tostring(repairedCount) },
				{ "Service Fee", Format.Money(totalCost) },
			},
			note = string.format("Restored %d worn component(s) on %s to 100%% integrity.", repairedCount, entry.shipName),
		})
	end

	return true, string.format("Serviced %d component(s) on %s for %s.", repairedCount, entry.shipName, Format.Money(totalCost, false))
end

function PlayerFleet.RefuelShip(uid)
	local _, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end
	if entry.status ~= "DOCKED" then return false, "Vessel must be docked to refuel." end

	local fuel = entry.fuel or 0
	local driveProto = getInstalledHyperdriveInfo(entry)
	local maxHyper = driveProto and (driveProto.fuel_resv_size or 1) or 0
	local curHyper = driveProto and math.clamp((type(entry.hyperFuel) == "number") and entry.hyperFuel or maxHyper, 0, maxHyper) or 0
	local missingHyper = math.max(0, maxHyper - curHyper)

	if fuel >= 100 and missingHyper <= 0.05 then
		return false, "Fuel and hyperdrive tanks are already full."
	end

	local propCost = (fuel < 100) and math.ceil((100 - fuel) * 2.5) or 0
	local hyperCost = 0
	if missingHyper > 0.05 and driveProto and driveProto.fuel then
		local sys = (entry.locationPath and entry.locationPath:GetStarSystem()) or Game.system
		local unitP = sys and getSystemCommodityPrice(sys, driveProto.fuel) or (driveProto.fuel.price or 15)
		hyperCost = math.ceil(missingHyper * unitP)
	end
	local cost = math.max(20, propCost + hyperCost)

	if PlayerState.GetMoney() < cost then
		return false, string.format("Insufficient credits (%s needed).", Format.Money(cost, false))
	end

	PlayerState.AddMoney(-cost)
	entry.fuel = 100
	if driveProto then
		entry.hyperFuel = maxHyper
	end
	entry.stats.maintenancePaid = (entry.stats.maintenancePaid or 0) + cost
	if entry.liveShip and entry.liveShip:exists() then
		entry.liveShip:SetFuelPercent(100)
		fillShipHyperdriveFuel(entry.liveShip, entry)
	end
	TaxAuthority.RecordOperatingExpense(cost, "FLEET_FUEL", entry.shipName)
	addLog(entry.shipName, "Refueled propellant & hyperdrive tanks to 100%.", -cost)
	return true, string.format("Refueled %s for %s.", entry.shipName, Format.Money(cost, false))
end

function PlayerFleet.RenameShip(uid, newName)
	local _, entry = findShipIndex(uid)
	if not entry then return false end
	local cleaned = tostring(newName or ""):gsub("[%c]", "")
	local trimmed = cleaned:match("^%s*(.-)%s*$")
	if not trimmed or trimmed == "" then return false end
	if #trimmed > 48 then
		trimmed = trimmed:sub(1, 48):match("^%s*(.-)%s*$")
	end
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
			local _, unitBasis = adjustEntryCargoCostBasis(entry, commodityName, -moveCount)
			TaxAuthority.AdjustCommodityCostBasis(commodityName, moveCount, unitBasis or 0)
			entry.cargo[commodityName] = avail - moveCount
			if entry.cargo[commodityName] <= 0 then entry.cargo[commodityName] = nil end
			if entry.liveShip and entry.liveShip:exists() then applyCargoToShip(entry.liveShip, entry.cargo) end
			return true, string.format("Transferred %dt %s to Flagship.", moveCount, comm:GetName())
		end
	else
		local avail = cargoMgr:CountCommodity(comm)
		local freeDest = PlayerFleet.GetCargoFree(entry)
		local maxBySpace = math.floor(freeDest / unitMass)
		local moveCount = math.min(amount, avail, maxBySpace)
		if moveCount <= 0 then return false, "No cargo or insufficient space on hangar ship." end

		local unitBasis = TaxAuthority.GetCommodityCostBasis(commodityName) or 0
		local removed = cargoMgr:RemoveCommodity(comm, moveCount)
		if removed > 0 then
			TaxAuthority.AdjustCommodityCostBasis(commodityName, -removed, unitBasis)
			adjustEntryCargoCostBasis(entry, commodityName, removed, unitBasis)
			entry.cargo[commodityName] = (entry.cargo[commodityName] or 0) + removed
			if entry.liveShip and entry.liveShip:exists() then applyCargoToShip(entry.liveShip, entry.cargo) end
			return true, string.format("Transferred %dt %s to %s.", removed, comm:GetName(), entry.shipName)
		end
	end
	return false, "Cargo transfer failed."
end

-- ============================================================================
-- Direct Docked Ship-to-Ship Module Transfer (Plan A Polish)
-- ============================================================================

local function getStationStorageMod()
	return require 'modules.StationStorage.StationStorage'
end

local function buildEntrySlotTable(entry, config)
	local slots = {}
	if config and config.slots then
		for _, slot in pairs(config.slots) do
			slots[slot.id] = slot
		end
	end
	for _, rec in ipairs(entry.equip or {}) do
		if rec.slotId then
			local proto = Equipment.Get(rec.id)
			if proto and proto.provides_slots then
				for _, subSlot in pairs(proto.provides_slots) do
					slots[tostring(rec.slotId) .. "##" .. subSlot.id] = subSlot
				end
			end
		end
	end
	return slots
end

local function getEntryEquipUsedVolume(entry, config, StationStorage)
	local used = 0
	for _, rec in ipairs(entry.equip or {}) do
		local inst = StationStorage.InstantiateRecordForConfig(rec, config)
		if inst and inst.volume then
			used = used + inst.volume
		end
	end
	return used
end

local function canFitEquipmentInEntry(entry, rec, StationStorage)
	local config = HullConfig.GetHullConfig(entry.shipId)
	if not config then return false, "Unknown hull configuration." end

	local inst = StationStorage.InstantiateRecordForConfig(rec, config)
	if not inst then return false, "Unknown module prototype." end

	local usedVol = getEntryEquipUsedVolume(entry, config, StationStorage)
	local freeVol = (config.equipCapacity or 0) - usedVol
	if freeVol < (inst.volume or 0) then
		return false, "Insufficient free equipment volume on target ship."
	end

	if inst.slot then
		local occupied = {}
		for _, existing in ipairs(entry.equip or {}) do
			if existing.slotId then
				occupied[existing.slotId] = true
			end
		end

		local allSlots = buildEntrySlotTable(entry, config)
		local sortedIds = {}
		for slotId, _ in pairs(allSlots) do
			if not occupied[slotId] then
				table.insert(sortedIds, slotId)
			end
		end
		table.sort(sortedIds)

		for _, slotId in ipairs(sortedIds) do
			local slot = allSlots[slotId]
			local countOk = (slot.count == nil) or ((rec.count or 1) == slot.count)
			if countOk and slot.hardpoint == inst.slot.hardpoint and EquipSet.CompatibleWithSlot(inst, slot) then
				return true, slotId
			end
		end
		return false, "No compatible free slot on target ship."
	end

	return true, nil
end

function PlayerFleet.CanRemoveModuleFromEntry(entry, equipIndex)
	if not entry or not entry.equip or not entry.equip[equipIndex] then
		return false, "Module not found on hangar ship."
	end
	local rec = entry.equip[equipIndex]
	local config = HullConfig.GetHullConfig(entry.shipId)

	if rec.slotId and config and config.slots then
		for _, slot in pairs(config.slots) do
			if slot.id == rec.slotId and slot.required then
				return false, "Cannot remove a required hull slot module."
			end
		end
		local prefix = tostring(rec.slotId) .. "##"
		for idx, other in ipairs(entry.equip) do
			if idx ~= equipIndex and other.slotId and other.slotId:sub(1, #prefix) == prefix then
				return false, "Remove child sub-slot equipment first."
			end
		end
	end

	local proto = Equipment.Get(rec.id)
	local cargoBonus = proto and proto.capabilities and proto.capabilities.cargo_cap or 0
	if cargoBonus > 0 then
		local capAfter = (entry.cargoCap or 0) - cargoBonus
		if capAfter < PlayerFleet.GetCargoUsed(entry) then
			return false, "Unload cargo from hangar ship before removing cargo rack."
		end
	end

	return true
end

local function recalcEntryCargoCap(entry, StationStorage)
	local def = ShipDef[entry.shipId]
	local config = HullConfig.GetHullConfig(entry.shipId)
	local base = (def and def.cargo) or 0
	local bonus = 0
	for _, rec in ipairs(entry.equip or {}) do
		local inst = StationStorage.InstantiateRecordForConfig(rec, config)
		if inst and inst.capabilities and inst.capabilities.cargo_cap then
			bonus = bonus + inst.capabilities.cargo_cap
		end
	end
	entry.cargoCap = math.max(0, base + bonus)
end

local function resyncEntryLiveShip(entry)
	if entry.liveShip and entry.liveShip:exists() then
		clearShipCargo(entry.liveShip)
		entry.liveShip:SetShipType(entry.shipId)
		applyShipConfig(entry.liveShip, entry)
		pcall(function() ComponentIntegrity.SyncShipSubsystems(entry.liveShip) end)
	end
end

function PlayerFleet.TransferModule(uid, sourceRef, toFlagship)
	if Insurance.HasClaim() then
		return false, "Module transfers are locked while an open insurance claim is pending."
	end
	local player = Game.player
	local station = player and player:GetDockedWith()
	if not station then
		return false, "Must be docked at a station to transfer modules."
	end
	local _, entry = findShipIndex(uid)
	if not entry or entry.status ~= "DOCKED" or not samePath(entry.locationPath, station.path) then
		return false, "Target vessel must be docked at the same station."
	end

	local StationStorage = getStationStorageMod()

	if toFlagship then
		local equipIndex = tonumber(sourceRef)
		local okRem, errRem = PlayerFleet.CanRemoveModuleFromEntry(entry, equipIndex)
		if not okRem then
			return false, errRem
		end
		local rec = entry.equip[equipIndex]
		local okInst, instOrErr = StationStorage.InstallRecordOnShip(player, rec)
		if not okInst then
			return false, instOrErr
		end
		table.remove(entry.equip, equipIndex)
		recalcEntryCargoCap(entry, StationStorage)
		resyncEntryLiveShip(entry)
		return true, string.format("Installed %s onto Flagship.", instOrErr:GetName())
	else
		local equip = sourceRef
		local okRem, errRem = StationStorage.CanRemoveEquipmentFromShip(player, equip)
		if not okRem then
			return false, errRem
		end
		local rec = StationStorage.PackEquipmentRecord(equip)
		local okFit, slotIdOrErr = canFitEquipmentInEntry(entry, rec, StationStorage)
		if not okFit then
			return false, slotIdOrErr
		end

		local equipSet = player:GetComponent('EquipSet')
		if not equipSet:Remove(equip) then
			return false, "Failed to uninstall module from Flagship."
		end
		pcall(function() ComponentIntegrity.SyncShipSubsystems(player) end)

		rec.slotId = slotIdOrErr
		entry.equip = entry.equip or {}
		table.insert(entry.equip, rec)
		recalcEntryCargoCap(entry, StationStorage)
		resyncEntryLiveShip(entry)
		return true, string.format("Transferred %s to %s.", equip:GetName(), entry.shipName)
	end
end

-- ============================================================================
-- Crew, Captains, Salary Progression & Payroll (Phase A2+)
-- ============================================================================

function PlayerFleet.GetCaptainSkillScore(captain)
	if not captain then return 0 end
	return math.floor(((captain.piloting or 15) + (captain.navigation or 15) + (captain.engineering or 15) + (captain.sensors or 15)) / 4)
end

function PlayerFleet.FindCrewAssignment(crewMember)
	if not crewMember then return nil, false, nil end
	for _, entry in ipairs(fleetState.ships or {}) do
		if entry.status ~= "DESTROYED" then
			for idx, member in ipairs(entry.crew or {}) do
				if member == crewMember then
					return entry, (member == entry.captain), idx
				end
			end
		end
	end
	return nil, false, nil
end

local function recordFleetPayrollFlightLog(entry, amountPaid, note)
	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		FlightLog.RecordTransaction({
			category = "CREW",
			title = string.format("Fleet Payroll: %s (%s)", entry.shipName, Format.Money(-amountPaid)),
			amount = -amountPaid,
			details = {
				{ "Vessel", entry.shipName },
				{ "Location", entry.locationName or "Deep Space" },
				{ "Payroll Settled", Format.Money(amountPaid) },
			},
			note = note,
		})
	end
end

function PlayerFleet.PayCrewArrears(crewMember)
	local entry, _, _ = PlayerFleet.FindCrewAssignment(crewMember)
	if not entry then return false, "Crew member is not assigned to a fleet ship." end
	local owed = math.max(0, math.floor(tonumber(crewMember.fleetOwed) or 0))
	if owed <= 0 then return false, "No unpaid wages owed." end
	local available = math.max(0, math.floor(PlayerState.GetMoney()))
	if available <= 0 then return false, "Insufficient credits to settle arrears." end

	local paid = math.min(available, owed)
	PlayerState.AddMoney(-paid)
	crewMember.fleetOwed = owed - paid
	TaxAuthority.RecordOperatingExpense(paid, "FLEET_CREW", "[FLEET] " .. entry.shipName)
	entry.stats.wagesPaid = (entry.stats.wagesPaid or 0) + paid
	entry.stats.netProfit = (entry.stats.netProfit or 0) - paid
	fleetState.totalProfit = (fleetState.totalProfit or 0) - paid
	if crewMember.fleetOwed == 0 then
		crewMember.playerRelationship = (crewMember.playerRelationship or 0) + 1
	end
	local note = string.format("Settled wage arrears for %s aboard %s.", crewMember.name, entry.shipName)
	addLog(entry.shipName, note, -paid)
	recordFleetPayrollFlightLog(entry, paid, note)
	return true, string.format("Paid %s arrears to %s.", Format.Money(paid, false), crewMember.name)
end

function PlayerFleet.AwardCaptainXP(entry, primarySkill)
	if not entry then return end
	normalizeFleetCrewForEntry(entry, Game.time)
	local cap = entry.captain
	local skills = { "piloting", "navigation", "engineering", "sensors" }
	local chosen = primarySkill or skills[Engine.rand:Integer(1, #skills)]

	for _, member in ipairs(entry.crew or {}) do
		local isCap = (member == cap)
		member.completedOps = (member.completedOps or 0) + 1
		local skilledUp = false

		if isCap then
			local cur = member[chosen] or 15
			-- Diminishing returns past 65, mirroring Pioneer RPG attributes
			if cur < 65 and Engine.rand:Number(0, 1) < math.max(0.18, (70 - cur) / 80) then
				member[chosen] = cur + 1
				skilledUp = true
				addLog(entry.shipName, string.format("Captain %s improved %s skill to %d!", member.name, chosen:gsub("^%l", string.upper), member[chosen]), 0)
			end
		else
			local cur = member[chosen] or 15
			if cur < 60 and Engine.rand:Number(0, 1) < 0.25 then
				member[chosen] = cur + 1
				skilledUp = true
				addLog(entry.shipName, string.format("%s improved %s skill to %d!", member.name, chosen:gsub("^%l", string.upper), member[chosen]), 0)
			end
		end

		if skilledUp or (member.completedOps % 5 == 0) then
			local newWage = PlayerFleet.ComputeTargetFleetWage(member, isCap)
			if newWage > (member.fleetWage or 0) then
				member.fleetWage = newWage
				addLog(entry.shipName, string.format("%s %s earned a salary increase to %s/wk.",
					isCap and "Captain" or "Crew", member.name, Format.Money(newWage, false)), 0)
			end
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

	local makeCap = asCaptain or (entry.captain == nil)
	if makeCap and entry.captain and entry.captain ~= transferred then
		entry.captain.title = "Fleet Crew"
	end

	table.insert(entry.crew, transferred)
	if makeCap then
		entry.captain = transferred
		transferred.title = "Captain"
		transferred.fleetWage = math.max(transferred.fleetWage or 0, PlayerFleet.ComputeTargetFleetWage(transferred, true))
		addLog(entry.shipName, string.format("%s assigned as Captain (%s/wk).", transferred.name, Format.Money(transferred.fleetWage, false)), 0)
	else
		transferred.title = "Fleet Crew"
		transferred.fleetWage = math.max(transferred.fleetWage or 0, PlayerFleet.ComputeTargetFleetWage(transferred, false))
		addLog(entry.shipName, string.format("%s assigned to crew (%s/wk).", transferred.name, Format.Money(transferred.fleetWage, false)), 0)
	end
	return true, string.format("Assigned %s to %s (%s/wk).", transferred.name, entry.shipName, Format.Money(transferred.fleetWage, false))
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
		if entry.captain then
			entry.captain.title = "Captain"
			entry.captain.fleetWage = math.max(entry.captain.fleetWage or 0, PlayerFleet.ComputeTargetFleetWage(entry.captain, true))
		elseif entry.order ~= "IDLE" then
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
			if entry.captain and entry.captain ~= c then
				entry.captain.title = "Fleet Crew"
			end
			entry.captain = c
			c.title = "Captain"
			c.fleetWage = math.max(c.fleetWage or 0, PlayerFleet.ComputeTargetFleetWage(c, true))
			return true
		end
	end
	return false
end

function PlayerFleet.DismissFleetCrew(uid, crewMember)
	local _, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end
	if entry.status ~= "DOCKED" then
		return false, "Vessel must be docked to dismiss crew."
	end

	local foundIdx = nil
	for i, c in ipairs(entry.crew or {}) do
		if c == crewMember then
			foundIdx = i
			break
		end
	end
	if not foundIdx then return false, "Crew member not aboard this vessel." end

	table.remove(entry.crew, foundIdx)
	if entry.captain == crewMember then
		entry.captain = entry.crew[1] or nil
		if entry.captain then
			entry.captain.title = "Captain"
			entry.captain.fleetWage = math.max(entry.captain.fleetWage or 0, PlayerFleet.ComputeTargetFleetWage(entry.captain, true))
		elseif entry.order ~= "IDLE" then
			entry.order = "IDLE"
			entry.orderPhase = "Standing down (no Captain aboard)"
		end
	end

	local owed = math.max(0, math.floor(tonumber(crewMember.fleetOwed) or 0))
	if owed > 0 then
		Comms.Message("I'm tired of working for nothing. Don't you know what a contract is?", crewMember.name)
		crewMember.playerRelationship = (crewMember.playerRelationship or 0) - 5
		if owed > 500 then
			PlayerState.AddCrime("CONTRACT_FRAUD", owed * 1.1)
		end
	elseif crewMember:TestRoll('playerRelationship') then
		Comms.Message("It's been great working for you. Look me up if you need a skilled hand again.", crewMember.name)
	else
		Comms.Message("Fair winds, Commander. Contract terminated.", crewMember.name)
		crewMember.playerRelationship = (crewMember.playerRelationship or 0) - 1
	end

	crewMember.estimatedWage = (crewMember.fleetWage or 50) + 5
	crewMember.contract = nil
	crewMember.fleetOwed = nil
	crewMember.fleetPayday = nil
	crewMember.available = true
	crewMember:Save()

	addLog(entry.shipName, string.format("Dismissed %s at %s.", crewMember.name, entry.locationName or "station"), 0)
	return true, string.format("Dismissed %s from %s.", crewMember.name, entry.shipName)
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
	TaxAuthority.RecordOperatingExpense(CAPTAIN_SIGNING_BONUS, "FLEET_CREW", "[FLEET] " .. entry.shipName)
	entry.stats.wagesPaid = (entry.stats.wagesPaid or 0) + CAPTAIN_SIGNING_BONUS
	entry.stats.netProfit = (entry.stats.netProfit or 0) - CAPTAIN_SIGNING_BONUS
	fleetState.totalProfit = (fleetState.totalProfit or 0) - CAPTAIN_SIGNING_BONUS

	local cap = Character.New({
		title       = "Captain",
		engineering = Engine.rand:Integer(18, 38),
		piloting    = Engine.rand:Integer(22, 42),
		navigation  = Engine.rand:Integer(20, 40),
		sensors     = Engine.rand:Integer(18, 36),
		intelligence = Engine.rand:Integer(18, 32),
		available   = false,
	}, Engine.rand)
	local now = Game.time or 0
	cap.completedOps = 0
	cap.weeksServed = 0
	cap.activeWeeks = 0
	cap.lastPayOps = 0
	cap.fleetOwed = 0
	cap.fleetPayday = now + WAGE_PERIOD_SEC
	cap.payrollInitialized = true
	cap.fleetWage = PlayerFleet.ComputeTargetFleetWage(cap, true)

	if entry.captain and entry.captain ~= cap then
		entry.captain.title = "Fleet Crew"
	end
	table.insert(entry.crew, cap)
	entry.captain = cap
	addLog(entry.shipName, string.format("Recruited Captain %s at %s (%s/wk).", cap.name, entry.locationName, Format.Money(cap.fleetWage, false)), -CAPTAIN_SIGNING_BONUS)

	return true, string.format("Hired Captain %s for %s (%s/wk).", cap.name, entry.shipName, Format.Money(cap.fleetWage, false))
end

local function processFleetPayroll(now, silentComms)
	if type(now) ~= "number" or now <= 0 then return end
	local attrs = { "piloting", "navigation", "engineering", "sensors" }

	for _, entry in ipairs(fleetState.ships or {}) do
		if entry.status ~= "DESTROYED" and (#(entry.crew or {}) > 0 or entry.captain) then
			normalizeFleetCrewForEntry(entry, now)
			local shipPaid = 0
			local shipUnpaid = 0

			for _, member in ipairs(entry.crew) do
				local isCap = (member == entry.captain)
				local periods = 0
				while (member.fleetPayday or (now + WAGE_PERIOD_SEC)) <= now and periods < MAX_PAYROLL_PERIODS_PER_STEP do
					periods = periods + 1
					local payTime = member.fleetPayday or now
					local wage = math.max(1, math.floor(tonumber(member.fleetWage) or 50))

					if PlayerState.GetMoney() >= wage then
						PlayerState.AddMoney(-wage)
						TaxAuthority.RecordOperatingExpense(wage, "FLEET_CREW", "[FLEET] " .. entry.shipName)
						shipPaid = shipPaid + wage
						if not member:TestRoll('playerRelationship') then
							member.playerRelationship = (member.playerRelationship or 0) + 1
						end
					else
						member.fleetOwed = (member.fleetOwed or 0) + wage
						shipUnpaid = shipUnpaid + wage
						member.playerRelationship = (member.playerRelationship or 0) - 1
						if Character.persistent and Character.persistent.player then
							Character.persistent.player.reputation = (Character.persistent.player.reputation or 0) - 0.5
						end
					end

					local arrears = math.min(math.max(0, math.floor(PlayerState.GetMoney())), member.fleetOwed or 0)
					if arrears > 0 then
						PlayerState.AddMoney(-arrears)
						TaxAuthority.RecordOperatingExpense(arrears, "FLEET_CREW", "[FLEET] " .. entry.shipName)
						member.fleetOwed = (member.fleetOwed or 0) - arrears
						shipPaid = shipPaid + arrears
					end

					member.weeksServed = (member.weeksServed or 0) + 1
					local wasActive = (entry.order ~= "IDLE") or ((member.completedOps or 0) > (member.lastPayOps or 0))
					if wasActive then
						member.activeWeeks = (member.activeWeeks or 0) + 1
						local attr = attrs[Engine.rand:Integer(1, #attrs)]
						local curAttr = member[attr] or 15
						if curAttr < 65 and Engine.rand:Number(0, 1) < 0.25 then
							member[attr] = curAttr + 1
						end
						local targetWage = PlayerFleet.ComputeTargetFleetWage(member, isCap)
						if targetWage > (member.fleetWage or 0) then
							member.fleetWage = targetWage
							addLog(entry.shipName, string.format("%s %s promoted to %s/wk salary (%d wks active service).",
								isCap and "Captain" or "Crew", member.name, Format.Money(targetWage, false), member.activeWeeks), 0, payTime)
						end
					end
					member.lastPayOps = member.completedOps or 0
					member.fleetPayday = payTime + WAGE_PERIOD_SEC
				end

				if (member.fleetPayday or 0) <= now then
					member.fleetPayday = now + WAGE_PERIOD_SEC
				end
			end

			if shipPaid > 0 then
				entry.stats.wagesPaid = (entry.stats.wagesPaid or 0) + shipPaid
				entry.stats.netProfit = (entry.stats.netProfit or 0) - shipPaid
				fleetState.totalProfit = (fleetState.totalProfit or 0) - shipPaid
				local note = string.format("Paid weekly crew payroll (%d crew).", #entry.crew)
				addLog(entry.shipName, note, -shipPaid, now)
				recordFleetPayrollFlightLog(entry, shipPaid, note)
			end
			if shipUnpaid > 0 then
				addLog(entry.shipName, string.format("Insufficient funds for crew payroll (%s in arrears).", Format.Money(shipUnpaid, false)), 0, now)
				if not silentComms then
					Comms.ImportantMessage(string.format("Commander, crew wages on %s went unpaid (%s owed).", entry.shipName, Format.Money(shipUnpaid, false)), entry.captain and entry.captain.name or "Fleet Payroll")
				end
				if entry.captain and (entry.captain.fleetOwed or 0) >= (entry.captain.fleetWage or 50) * 3 and entry.status == "DOCKED" and entry.order ~= "IDLE" then
					entry.order = "IDLE"
					entry.orderPhase = "Standing down (unpaid crew arrears)"
					Comms.ImportantMessage(string.format("Captain %s has stood down %s until unpaid wage arrears (%s) are settled.",
						entry.captain.name, entry.shipName, Format.Money(entry.captain.fleetOwed, false)), entry.captain.name)
				end
			end
		end
	end
end

-- ============================================================================
-- Trade Route, Ring Mining, Patrol & Transit Simulation Engines (Phases A3-A4)
-- ============================================================================

getSystemCommodityPrice = function(sys, comm)
	local ok, price = pcall(function()
		return Economy.GetMarketPrice(comm.price, sys:GetCommodityBasePriceAlterations(comm.name))
	end)
	if ok and price then return math.max(1, math.floor(price)) end
	return math.max(1, math.floor(comm.price or 10))
end

maintainFleetShipAtStation = function(entry, stationPath, simTime, silentComms)
	if not entry or not stationPath then return 0 end
	local stSys = stationPath:GetStarSystem()
	local locName = formatPathName(stationPath)

	local damaged = {}
	for _, eq in ipairs(entry.equip or {}) do
		local integ = math.clamp((type(eq.integrity) == "number") and eq.integrity or 1.0, 0.0, 1.0)
		if integ < MAINTENANCE_INTEGRITY_THRESHOLD then
			local proto = Equipment.Get(eq.id)
			local price = eq.usedPrice or (proto and proto.price) or 500
			local cost = ComponentIntegrity.GetModuleRepairCost({ integrity = integ, price = price })
			if cost > 0 then
				table.insert(damaged, {
					eq = eq,
					integ = integ,
					cost = cost,
					name = (proto and proto.GetName and proto:GetName()) or eq.id,
				})
			end
		end
	end
	table.sort(damaged, function(a, b) return a.integ < b.integ end)

	local equipSpent = 0
	local repairedCount = 0
	local deferredCount = 0
	for _, item in ipairs(damaged) do
		if PlayerState.GetMoney() >= item.cost then
			PlayerState.AddMoney(-item.cost)
			item.eq.integrity = 1.0
			equipSpent = equipSpent + item.cost
			repairedCount = repairedCount + 1
		else
			deferredCount = deferredCount + 1
		end
	end

	local hullSpent = 0
	local hull = entry.hullPercent or 100
	if hull < MAINTENANCE_HULL_THRESHOLD then
		local def = ShipDef[entry.shipId]
		local hullCost = math.max(25, math.ceil(((def and def.basePrice) or 10000) * 0.001 * (100 - hull)))
		if PlayerState.GetMoney() >= hullCost then
			PlayerState.AddMoney(-hullCost)
			entry.hullPercent = 100
			hullSpent = hullCost
		else
			deferredCount = deferredCount + 1
		end
	end

	local fuelSpent = 0
	local fuelPct = entry.fuel or 100
	if fuelPct < 95 then
		local def = ShipDef[entry.shipId]
		local tankCap = (def and def.fuelTankMass) or 10
		local missingTons = math.max(0.5, tankCap * ((100 - fuelPct) / 100))
		local hydroPrice = (stSys and Commodities.hydrogen) and getSystemCommodityPrice(stSys, Commodities.hydrogen)
			or (Commodities.hydrogen and Commodities.hydrogen.price or 10)
		local fCost = math.max(10, math.ceil(missingTons * hydroPrice))
		if PlayerState.GetMoney() >= fCost then
			PlayerState.AddMoney(-fCost)
			entry.fuel = 100
			fuelSpent = fuelSpent + fCost
		else
			deferredCount = deferredCount + 1
		end
	end

	local driveProto = getInstalledHyperdriveInfo(entry)
	if driveProto then
		local maxHyper = driveProto.fuel_resv_size or 1
		local curHyper = math.clamp((type(entry.hyperFuel) == "number") and entry.hyperFuel or maxHyper, 0, maxHyper)
		local missingHyper = maxHyper - curHyper
		if missingHyper > 0.05 then
			local fComm = driveProto.fuel or Commodities.hydrogen
			local unitP = (stSys and fComm) and getSystemCommodityPrice(stSys, fComm) or (fComm and fComm.price or 15)
			local hCost = math.max(5, math.ceil(missingHyper * unitP))
			if PlayerState.GetMoney() >= hCost then
				PlayerState.AddMoney(-hCost)
				entry.hyperFuel = maxHyper
				fuelSpent = fuelSpent + hCost
			else
				deferredCount = deferredCount + 1
			end
		end
	end

	if entry.liveShip and entry.liveShip:exists() then
		if repairedCount > 0 then
			local equipSet = entry.liveShip:GetComponent('EquipSet')
			if equipSet then
				for key, liveEq in pairs(equipSet:GetInstalledEquipment()) do
					local slotId = type(key) == "string" and key or nil
					for _, savedEq in ipairs(entry.equip or {}) do
						if savedEq.id == liveEq.id and (not savedEq.slotId or savedEq.slotId == slotId) then
							liveEq.integrity = savedEq.integrity or 1.0
							equipSet:NotifyListeners('modify', liveEq)
							break
						end
					end
				end
			end
			pcall(function() ComponentIntegrity.SyncShipSubsystems(entry.liveShip) end)
		end
		if hullSpent > 0 then
			entry.liveShip:SetHullPercent(entry.hullPercent or 100)
		end
		if fuelSpent > 0 then
			entry.liveShip:SetFuelPercent(entry.fuel or 100)
			fillShipHyperdriveFuel(entry.liveShip, entry)
		end
	end

	local totalMaintCost = equipSpent + hullSpent + fuelSpent
	if totalMaintCost > 0 then
		entry.stats.netProfit = (entry.stats.netProfit or 0) - totalMaintCost
		fleetState.totalProfit = (fleetState.totalProfit or 0) - totalMaintCost
		entry.stats.maintenancePaid = (entry.stats.maintenancePaid or 0) + totalMaintCost
		local expCat = (equipSpent + hullSpent > 0) and "FLEET_MAINTENANCE" or "FLEET_FUEL"
		TaxAuthority.RecordOperatingExpense(totalMaintCost, expCat, "[FLEET] " .. entry.shipName)

		local parts = {}
		if repairedCount > 0 then
			table.insert(parts, string.format("%d component(s) <80%% serviced (%s)", repairedCount, Format.Money(equipSpent, false)))
		end
		if hullSpent > 0 then
			table.insert(parts, string.format("hull repaired (%s)", Format.Money(hullSpent, false)))
		end
		if fuelSpent > 0 then
			table.insert(parts, string.format("refueled (%s)", Format.Money(fuelSpent, false)))
		end
		local summaryMsg = string.format("Station maintenance at %s: %s.", locName, table.concat(parts, ", "))
		addLog(entry.shipName, summaryMsg, -totalMaintCost, simTime)

		if (equipSpent + hullSpent > 0) or totalMaintCost >= 50 then
			local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
			if okFlightLog and FlightLog and FlightLog.RecordTransaction then
				FlightLog.RecordTransaction({
					category = "MAINTENANCE",
					title = string.format("Fleet Service: %s (%s)", entry.shipName, Format.Money(-totalMaintCost)),
					amount = -totalMaintCost,
					details = {
						{ "Vessel", entry.shipName },
						{ "Service Port", locName },
						{ "Components Overhauled (<80%)", string.format("%d (%s)", repairedCount, Format.Money(equipSpent)) },
						{ "Hull Restoration", Format.Money(hullSpent) },
						{ "Propellant & Hyperfuel", Format.Money(fuelSpent) },
						{ "Total Service Cost", Format.Money(totalMaintCost) },
					},
					note = summaryMsg,
				})
			end
		end
		if not silentComms and (repairedCount > 0 or hullSpent > 0) then
			Comms.Message(string.format("%s: %s", entry.shipName, summaryMsg), entry.captain and entry.captain.name or "Fleet Engineering")
		end
	end

	if deferredCount > 0 then
		addLog(entry.shipName, string.format("Deferred %d maintenance item(s) at %s due to insufficient funds.", deferredCount, locName), 0, simTime)
	end
	return totalMaintCost
end

local function sysPathKey(path)
	if not path then return "" end
	return string.format("%d,%d,%d,%d", path.sectorX, path.sectorY, path.sectorZ, path.systemIndex or 0)
end

local function stationPathKey(path)
	if not path then return "" end
	return string.format("%d,%d,%d,%d,%d", path.sectorX, path.sectorY, path.sectorZ, path.systemIndex or 0, path.bodyIndex or 0)
end

local function getDecayedNetSupply(stationPath, commName, now, sysPop)
	if not stationPath or not commName then return 0 end
	fleetState.marketSaturation = fleetState.marketSaturation or {}
	local sKey = stationPathKey(stationPath)
	local stMap = fleetState.marketSaturation[sKey]
	if not stMap then return 0 end
	local rec = stMap[commName]
	if not rec or not rec.netSupply then return 0 end
	local tNow = now or Game.time or 0
	local dt = math.max(0, tNow - (rec.updatedAt or tNow))
	-- High population systems absorb inventory faster
	local popBonus = 1.0 + math.min(1.5, math.log(1 + (sysPop or 0.01) * 100.0) * 0.25)
	local halfLife = SATURATION_HALF_LIFE_SEC / popBonus
	local decayed = rec.netSupply * (0.5 ^ (dt / math.max(3600, halfLife)))
	if math.abs(decayed) < 0.25 then
		return 0
	end
	return decayed
end

local function recordFleetMarketImpact(stationPath, commName, deltaTons, now, stationName)
	if not stationPath or not commName or not deltaTons or deltaTons == 0 then return end
	local tNow = now or Game.time or 0
	local sysPop = nil
	local okS, sbody = pcall(function() return stationPath:GetSystemBody() end)
	if okS and sbody and sbody.system then
		sysPop = sbody.system.population
	end

	fleetState.marketSaturation = fleetState.marketSaturation or {}
	local sKey = stationPathKey(stationPath)
	fleetState.marketSaturation[sKey] = fleetState.marketSaturation[sKey] or {}
	local stMap = fleetState.marketSaturation[sKey]
	local cur = getDecayedNetSupply(stationPath, commName, tNow, sysPop)
	local nextVal = math.clamp(cur + deltaTons, -1200, 1200)
	if math.abs(nextVal) < 0.25 then
		stMap[commName] = nil
		if next(stMap) == nil then
			fleetState.marketSaturation[sKey] = nil
		end
	else
		stMap[commName] = {
			netSupply = nextVal,
			updatedAt = tNow,
			stationName = stationName or (sbody and sbody.name) or formatPathName(stationPath),
		}
	end

	-- Sync into Economy persistent market if this station has one active
	if Economy and Economy.GetStationMarket then
		local okM, mkt = pcall(function() return Economy.GetStationMarket(stationPath) end)
		if okM and mkt and mkt.stock and next(mkt.stock) ~= nil then
			mkt.stock[commName] = math.max(0, math.floor((mkt.stock[commName] or 0) + deltaTons))
			if mkt.history then
				mkt.history[commName] = (mkt.history[commName] or 0) + deltaTons
			end
		end
	end
end

local function getMacroCrisisCommodityMult(sysName, commName, isBuy)
	if not sysName or not commName then return 1.0 end
	local MacroEngine = getMacroEngine()
	if MacroEngine and MacroEngine.GetCommodityMultiplier then
		local m = MacroEngine.GetCommodityMultiplier(sysName, commName, isBuy)
		if type(m) == "number" and m > 0 then
			return m
		end
	end
	return 1.0
end

local function getEffectiveStationCommodityQuote(sysOrMeta, stationPath, comm, now, basePriceOverride, preFetchedMarket)
	if not comm then return 10, 10, 0 end
	local basePrice = basePriceOverride or (sysOrMeta and getSystemCommodityPrice(sysOrMeta, comm)) or math.max(1, math.floor(comm.price or 10))
	local sysName = (type(sysOrMeta) == "table" and sysOrMeta.sysName) or (sysOrMeta and sysOrMeta.name) or nil
	local sysPop = (type(sysOrMeta) == "table" and sysOrMeta.population) or (sysOrMeta and sysOrMeta.population) or 0.01

	local capScale = math.clamp(45.0 + math.log(1.0 + math.max(0.0, sysPop) * 1000000.0) * 26.0, 45.0, 420.0)
	local netSupply = getDecayedNetSupply(stationPath, comm.name, now, sysPop)
	local satRatio = netSupply / capScale

	local buySatMult = 1.0
	local sellSatMult = 1.0
	if satRatio > 0 then
		-- Station flooded by deliveries: sell price falls sharply, buy price eases slightly
		sellSatMult = math.max(0.45, 1.0 / (1.0 + satRatio * 0.55))
		buySatMult = math.max(0.75, 1.0 / (1.0 + satRatio * 0.20))
	elseif satRatio < 0 then
		-- Station drained by purchases: buy price rises and stock becomes scarce
		buySatMult = math.min(1.65, 1.0 + (-satRatio) * 0.45)
		sellSatMult = math.min(1.30, 1.0 + (-satRatio) * 0.20)
	end

	local crisisBuyMult = getMacroCrisisCommodityMult(sysName, comm.name, true)
	local crisisSellMult = getMacroCrisisCommodityMult(sysName, comm.name, false)

	local buyPrice = math.max(1, math.floor(basePrice * buySatMult * crisisBuyMult + 0.5))
	local sellPrice = math.max(1, math.floor(basePrice * sellSatMult * crisisSellMult + 0.5))
	local availStock = math.max(0, math.floor(capScale * 0.85 + netSupply))

	-- If live Economy persistent market exists for this station, use its actual stock count
	if preFetchedMarket ~= false then
		local mkt = preFetchedMarket
		if mkt == nil and Economy and Economy.GetStationMarket and stationPath then
			local okM, resM = pcall(function() return Economy.GetStationMarket(stationPath) end)
			if okM then mkt = resM end
		end
		if type(mkt) == "table" and mkt.stock and type(mkt.stock[comm.name]) == "number" then
			availStock = math.max(0, math.floor(mkt.stock[comm.name]))
		end
	end

	return buyPrice, sellPrice, availStock
end

function PlayerFleet.GetMarketSaturationSnapshot()
	local out = {}
	local now = Game.time or 0
	for sKey, stMap in pairs(fleetState.marketSaturation or {}) do
		for cname, rec in pairs(stMap) do
			if type(rec) == "table" and rec.netSupply then
				local dt = math.max(0, now - (rec.updatedAt or now))
				local decayed = rec.netSupply * (0.5 ^ (dt / SATURATION_HALF_LIFE_SEC))
				if math.abs(decayed) >= 1.0 then
					table.insert(out, {
						stationKey = sKey,
						stationName = rec.stationName or sKey,
						commodity = cname,
						netSupply = decayed,
					})
				end
			end
		end
	end
	table.sort(out, function(a, b) return math.abs(a.netSupply) > math.abs(b.netSupply) end)
	return out
end

getOrScanSystemMarket = function(sysPath)
	if not sysPath then return nil end
	local okSysOnly, sysOnly = pcall(function() return sysPath:SystemOnly() end)
	if not okSysOnly or not sysOnly then return nil end
	local key = sysPathKey(sysOnly)
	local cached = systemMarketCache[key]
	if cached ~= nil then
		systemMarketAccessSeq = systemMarketAccessSeq + 1
		cached.lastAccessSeq = systemMarketAccessSeq
		return cached
	end

	local okSys, sys = pcall(function() return sysOnly:GetStarSystem() end)
	if not okSys or not sys then return nil end

	-- Rolling LRU eviction instead of wiping the whole cache
	if systemMarketCacheCount >= MARKET_CACHE_MAX_ENTRIES then
		local entries = {}
		for k, v in pairs(systemMarketCache) do
			table.insert(entries, { key = k, seq = v.lastAccessSeq or 0 })
		end
		table.sort(entries, function(a, b) return a.seq < b.seq end)
		local evictCount = math.min(#entries, 300)
		for i = 1, evictCount do
			systemMarketCache[entries[i].key] = nil
			systemMarketCacheCount = math.max(0, systemMarketCacheCount - 1)
		end
	end

	local numStations = sys.numberOfStations or 0
	if numStations <= 0 then
		systemMarketAccessSeq = systemMarketAccessSeq + 1
		local rec = { hasStations = false, sysPath = sysOnly, lastAccessSeq = systemMarketAccessSeq }
		systemMarketCache[key] = rec
		systemMarketCacheCount = systemMarketCacheCount + 1
		return rec
	end

	local okSt, stPaths = pcall(function() return sys:GetStationPaths() end)
	if not okSt or not stPaths or #stPaths == 0 then
		systemMarketAccessSeq = systemMarketAccessSeq + 1
		local rec = { hasStations = false, sysPath = sysOnly, lastAccessSeq = systemMarketAccessSeq }
		systemMarketCache[key] = rec
		systemMarketCacheCount = systemMarketCacheCount + 1
		return rec
	end

	local prices = {}
	local legal = {}
	for _, cname in ipairs(TRADE_CANDIDATE_COMMS) do
		local comm = Commodities[cname]
		if comm and comm.price and comm.price > 0 then
			prices[cname] = getSystemCommodityPrice(sys, comm)
			local okL, isLeg = pcall(function() return sys:IsCommodityLegal(cname) end)
			legal[cname] = (not okL) or (isLeg ~= false)
		end
	end

	local stationOrbitalDist = {}
	for i = 1, math.min(#stPaths, 6) do
		local sp = stPaths[i]
		stationOrbitalDist[stationPathKey(sp)] = estimateBodyOrbitalDistMeters(sp)
	end

	systemMarketAccessSeq = systemMarketAccessSeq + 1
	local rec = {
		hasStations = true,
		sysPath = sysOnly,
		sysName = sys.name,
		population = sys.population or 0.01,
		lawlessness = sys.lawlessness or 0.15,
		stationPaths = stPaths,
		stationOrbitalDist = stationOrbitalDist,
		prices = prices,
		legal = legal,
		lastAccessSeq = systemMarketAccessSeq,
	}
	systemMarketCache[key] = rec
	systemMarketCacheCount = systemMarketCacheCount + 1
	return rec
end

local function computeAutoTradeSearchRange(entry)
	local shipRange = PlayerFleet.GetShipHyperspaceRange(entry)
	if shipRange <= 0 then
		return 0, 0
	end
	local configuredRange = PlayerFleet.GetTradeRange(entry)
	if configuredRange <= 0 then
		return 0, shipRange
	end
	local maxReach = math.min(MAX_TRADE_RANGE_LY, math.max(shipRange, math.min(configuredRange, shipRange * 2)))
	return math.min(configuredRange, maxReach), shipRange
end

local function estimateStationSCDurationSec(entry, marketMeta, stationPath)
	local distMeters = (marketMeta and marketMeta.stationOrbitalDist and marketMeta.stationOrbitalDist[stationPathKey(stationPath)])
		or estimateBodyOrbitalDistMeters(stationPath)
	local distLs = distMeters / LIGHT_SPEED_MPS
	local scTransit = math.clamp(120.0 + distLs * 0.45, 120.0, 600.0)
	local undockAndDock = 180.0
	return math.max(210, math.floor((scTransit + undockAndDock) / getSkillMultiplier(entry, "piloting", 0.20)))
end

local function buildBuyQuotesForScan(scan)
	scan.buyQuotes = {}
	if not scan.buyMarket or not scan.buyMarket.hasStations or not scan.buyPath then
		return
	end
	local buyMktObj = false
	if Economy and Economy.GetStationMarket then
		local okM, mkt = pcall(function() return Economy.GetStationMarket(scan.buyPath) end)
		if okM and mkt then
			buyMktObj = mkt
		end
	end
	local now = scan.now or Game.time or 0
	for _, cname in ipairs(TRADE_CANDIDATE_COMMS) do
		local comm = Commodities[cname]
		local baseBuyP = scan.buyMarket.prices[cname]
		local buyLegal = scan.buyMarket.legal[cname] ~= false
		if comm and baseBuyP and buyLegal then
			local buyPrice, _, buyStock = getEffectiveStationCommodityQuote(scan.buyMarket, scan.buyPath, comm, now, baseBuyP, buyMktObj)
			scan.buyQuotes[cname] = {
				buyPrice = buyPrice,
				buyStock = buyStock,
			}
		end
	end
end

local function evaluateSellMarket(scan, sellMarket, distLy)
	if not scan.buyMarket or not scan.buyMarket.hasStations then return end
	if not sellMarket or not sellMarket.hasStations then return end
	if not scan.buyQuotes then
		buildBuyQuotesForScan(scan)
	end

	local isLocalRoute = sameSystem(scan.buyMarket.sysPath, sellMarket.sysPath)
	if (not isLocalRoute) and scan.shipRange <= 0 then return end

	local jumpSec = 0
	local estFuelCost = 15
	if (not isLocalRoute) and distLy > 0.01 then
		local effHopRange = math.max(1.5, scan.shipRange * 0.96)
		local hops = math.max(1, math.ceil(distLy / effHopRange))
		local avgHop = distLy / hops
		local singleJumpSec = computeJumpDurationSec(scan.entry, avgHop)
		jumpSec = hops * (singleJumpSec + scan.jumpWarmupSec) + math.max(0, hops - 1) * 90
		estFuelCost = hops * computeJumpFuelUse(scan.entry, avgHop) * 18.0 + 20.0
	end

	local freeCap = math.max(1, scan.freeCap or 1)
	local now = scan.now or Game.time or 0
	local maxStations = math.min(#(sellMarket.stationPaths or {}), 6)

	for stIdx = 1, maxStations do
		local sellPath = sellMarket.stationPaths[stIdx]
		if not samePath(scan.buyPath, sellPath) then
			local scSec = estimateStationSCDurationSec(scan.entry, sellMarket, sellPath)
			local tripHours = math.max(0.12, (jumpSec + scSec + 180.0) / 3600.0)

			for _, cname in ipairs(TRADE_CANDIDATE_COMMS) do
				local comm = Commodities[cname]
				local bq = scan.buyQuotes[cname]
				local baseSellP = sellMarket.prices[cname]
				local sellLegal = sellMarket.legal[cname] ~= false
				if comm and bq and bq.buyStock >= 1 and baseSellP and sellLegal then
					local buyPrice = bq.buyPrice
					local buyStock = bq.buyStock
					local _, sellPrice, _ = getEffectiveStationCommodityQuote(sellMarket, sellPath, comm, now, baseSellP, false)
					local margin = sellPrice - buyPrice
					if margin > 8 and buyStock >= 1 then
						local unitMass = comm.mass or 1
						local maxBySpace = math.floor(freeCap / unitMass)
						local qtyAny = math.min(maxBySpace, buyStock)
						if qtyAny >= 1 then
							local netAny = (qtyAny * margin) - estFuelCost
							local scoreAny = netAny / tripHours
							if netAny > 150 and scoreAny > scan.bestAnyScore then
								scan.bestAnyScore = scoreAny
								scan.bestAny = {
									buyPath = scan.buyPath,
									sellPath = sellPath,
									buySysPath = scan.buyMarket.sysPath,
									sellSysPath = sellMarket.sysPath,
									comm = comm,
									buyPrice = buyPrice,
									sellPrice = sellPrice,
									buyStock = buyStock,
									distLy = distLy,
									scorePerHr = scoreAny,
								}
							end

							local maxByCash = math.floor(scan.budgetCap / math.max(1, buyPrice))
							local qtyAff = math.min(qtyAny, maxByCash)
							if qtyAff >= 1 then
								local netAff = (qtyAff * margin) - estFuelCost
								local scoreAff = netAff / tripHours
								if netAff > 150 and scoreAff > scan.bestAffordableScore then
									scan.bestAffordableScore = scoreAff
									scan.bestAffordable = {
										buyPath = scan.buyPath,
										sellPath = sellPath,
										buySysPath = scan.buyMarket.sysPath,
										sellSysPath = sellMarket.sysPath,
										comm = comm,
										buyPrice = buyPrice,
										sellPrice = sellPrice,
										buyStock = buyStock,
										distLy = distLy,
										scorePerHr = scoreAff,
									}
								end
							end
						end
					end
				end
			end
		end
	end
end

local function finalizeTradeScan(scan)
	local best = scan.bestAffordable or scan.bestAny
	if best then
		return best
	end

	if scan.buyMarket and scan.buyMarket.hasStations and scan.buyPath then
		local destPath = nil
		local destSysPath = nil
		local distLy = 0
		if scan.shipRange > 0 and scan.firstNeighborMarket and scan.firstNeighborMarket.stationPaths[1] then
			destPath = scan.firstNeighborMarket.stationPaths[1]
			destSysPath = scan.firstNeighborMarket.sysPath
			distLy = scan.firstNeighborDist or 0
		elseif #(scan.buyMarket.stationPaths or {}) >= 2 then
			for _, sp in ipairs(scan.buyMarket.stationPaths) do
				if not samePath(sp, scan.buyPath) then
					destPath = sp
					destSysPath = scan.buyMarket.sysPath
					break
				end
			end
		end
		if destPath then
			local comm = Commodities.consumer_goods or Commodities.metal_alloys
			if comm then
				local now = scan.now or Game.time or 0
				local buyP, _, buyStock = getEffectiveStationCommodityQuote(scan.buyMarket, scan.buyPath, comm, now, scan.buyMarket.prices[comm.name])
				return {
					buyPath = scan.buyPath,
					sellPath = destPath,
					buySysPath = scan.buyMarket.sysPath,
					sellSysPath = destSysPath,
					comm = comm,
					buyPrice = buyP,
					sellPrice = math.ceil(buyP * 1.18),
					buyStock = math.max(1, buyStock),
					distLy = distLy,
				}
			end
		end
	end
	return nil
end

local function createTradeScanState(entry, isCatchUp, silentComms, simNow)
	local curPath = entry.locationPath
	local curSys = curPath and curPath:GetStarSystem() or Game.system
	local searchRange, shipRange = computeAutoTradeSearchRange(entry)

	local buyMarket = curSys and getOrScanSystemMarket(curSys.path) or nil
	local buyPath = nil
	if buyMarket and buyMarket.hasStations and buyMarket.stationPaths then
		for _, sp in ipairs(buyMarket.stationPaths) do
			if samePath(sp, curPath) then
				buyPath = sp
				break
			end
		end
		if not buyPath then
			buyPath = buyMarket.stationPaths[1]
		end
	end

	local candPaths = {}
	local candDists = {}
	local maxCandidates = isCatchUp and TRADE_SCAN_CATCHUP_CANDIDATES or TRADE_SCAN_MAX_CANDIDATES
	if curSys and searchRange > 1 then
		local paths, dists = getCachedNearbySystemPaths(curSys, searchRange, true, maxCandidates)
		if paths then
			candPaths = paths
			candDists = dists or {}
		end
	end

	local _, _, hclass = getInstalledHyperdriveInfo(entry)
	local warmupSec = math.floor(5 + math.max(1, hclass) * 1.5)
	local maxMarkets = isCatchUp and TRADE_SCAN_CATCHUP_MARKETS or math.clamp(math.floor(14 + searchRange * 0.6), 16, 36)
	local scan = {
		entry = entry,
		uid = entry.uid,
		curPath = curPath,
		searchRange = searchRange,
		shipRange = shipRange,
		freeCap = math.max(1, PlayerFleet.GetCargoFree(entry)),
		jumpWarmupSec = warmupSec,
		now = simNow or Game.time or 0,
		buyMarket = buyMarket,
		buyPath = buyPath,
		candPaths = candPaths,
		candDists = candDists,
		index = 1,
		total = #candPaths,
		marketsFound = 0,
		maxMarkets = maxMarkets,
		budgetCap = math.max(0, PlayerState.GetMoney() - 1000),
		bestAny = nil,
		bestAnyScore = 0,
		bestAffordable = nil,
		bestAffordableScore = 0,
		firstNeighborMarket = nil,
		firstNeighborDist = 0,
		silentComms = silentComms,
	}

	-- Precompute buy quotes once, then evaluate intra-system stations before neighbor jumps
	buildBuyQuotesForScan(scan)
	if buyMarket and buyMarket.hasStations and #(buyMarket.stationPaths or {}) >= 2 then
		evaluateSellMarket(scan, buyMarket, 0)
	end

	return scan
end

local function stepTradeScanState(scan, budgetMs)
	local deadline = (budgetMs and budgetMs > 0) and (Engine.nowTime + budgetMs / 1000.0) or nil
	while scan.index <= scan.total and scan.marketsFound < scan.maxMarkets do
		local np = scan.candPaths[scan.index]
		local dist = scan.candDists[scan.index] or 0
		scan.index = scan.index + 1

		local mkt = getOrScanSystemMarket(np)
		if mkt and mkt.hasStations then
			if not scan.buyMarket or not scan.buyMarket.hasStations then
				scan.buyMarket = mkt
				scan.buyPath = mkt.stationPaths[1]
				buildBuyQuotesForScan(scan)
			else
				scan.marketsFound = scan.marketsFound + 1
				if not scan.firstNeighborMarket then
					scan.firstNeighborMarket = mkt
					scan.firstNeighborDist = dist
				end
				evaluateSellMarket(scan, mkt, dist)
			end
		end

		if deadline and Engine.nowTime >= deadline then
			return false, nil
		end
	end

	local route = finalizeTradeScan(scan)
	return true, route
end

local function updateScanProgressDisplay(entry, scan)
	entry.status = "SCANNING"
	local fracByIdx = (scan.total > 0) and ((scan.index - 1) / scan.total) or 1
	local fracByMkt = (scan.maxMarkets > 0) and (scan.marketsFound / scan.maxMarkets) or 1
	entry.orderProgress = math.clamp(math.max(fracByIdx, fracByMkt), 0.02, 0.99)
	entry.orderEta = 0
	entry.orderPhase = string.format(
		"[SCANNING] Evaluating Cr/hr markets within %d ly (%d/%d systems, %d markets)...",
		scan.searchRange, math.min(scan.index - 1, scan.total), scan.total, scan.marketsFound
	)
end

local function findBestTradeRouteSync(entry, isCatchUp, simNow)
	local scan = createTradeScanState(entry, isCatchUp, true, simNow)
	local _, route = stepTradeScanState(scan, nil)
	return route
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

	local nearPaths = getCachedNearbySystemPaths(sys, 15, false, 48)
	if nearPaths then
		for _, np in ipairs(nearPaths) do
			local okS, ns = pcall(function() return np:GetStarSystem() end)
			if okS and ns then
				bp, sb = searchSys(ns)
				if bp then return bp, sb end
			end
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

spawnOrUpdateLiveFleetShip = function(entry, spawnNearPlayer, forceLaunchSpace)
	if not Game.system or Game.InHyperspace() then return nil end
	if entry.liveShip and entry.liveShip:exists() then
		return entry.liveShip
	end

	local ship = nil
	if spawnNearPlayer then
		local refBody = (Game.player.flightState == "FLYING" or Game.player.flightState == "SUPERCRUISE") and Game.player or Game.player:GetDockedWith()
		if refBody and refBody:exists() then
			local minKm, maxKm = 4, 8
			if refBody:isa("SpaceStation") then
				minKm = math.max(4.0, getStationSafeSpawnKm(refBody))
				maxKm = minKm + 4.0
			end
			local ok, s = pcall(function() return Space.SpawnShipNear(entry.shipId, refBody, minKm, maxKm) end)
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
			if okS and s then
				ship = s
			elseif forceLaunchSpace then
				local okP, sp = pcall(function() return Space.SpawnShipParked(entry.shipId, st) end)
				if okP and sp then
					ship = sp
				else
					local safeKm = getStationSafeSpawnKm(st)
					local okN, sn = pcall(function() return Space.SpawnShipNear(entry.shipId, st, safeKm, safeKm + 2.0) end)
					if okN and sn then ship = sn end
				end
			end
		elseif forceLaunchSpace and entry.locationPath:IsBodyPath() then
			local okB, b = pcall(function() return Space.GetBody(entry.locationPath.bodyIndex) end)
			if okB and b and b:exists() then
				local okN, sn = pcall(function() return Space.SpawnShipNear(entry.shipId, b, 15, 30) end)
				if okN and sn then ship = sn end
			end
		end
	end

	if not ship and (spawnNearPlayer or forceLaunchSpace) then
		local okS, s = pcall(function() return Space.SpawnShipNear(entry.shipId, Game.player, 6, 12) end)
		if okS and s then ship = s end
	end

	if not ship then return nil end

	applyShipConfig(ship, entry)
	entry.liveShip = ship
	return ship
end

local function spawnShipOnRouteInSystem(entry, t)
	if not Game.system or Game.InHyperspace() or not t or not t.destPath then return nil end
	local destBody = (t.destPath:IsBodyPath() and Space.GetBody(t.destPath.bodyIndex)) or nil
	local stars = Game.system:GetStars()
	local starBody = stars and stars[1] and stars[1].body or nil
	if not destBody or not starBody then return nil end

	local dur = math.max(10, (t.phaseEndTime or (Game.time + 60)) - (t.phaseStartTime or Game.time))
	local t_ratio = math.clamp((Game.time - (t.phaseStartTime or Game.time)) / dur, 0.05, 0.90)

	local okS, ship = pcall(function() return Space.SpawnShip(entry.shipId, 1, 2) end)
	if not okS or not ship then return nil end

	applyShipConfig(ship, entry)
	local okOrbit = pcall(function()
		Space.PutShipIntoOrbit(ship, starBody)
		Space.PutShipOnRoute(ship, destBody, t_ratio)
	end)
	if not okOrbit then
		-- Fallback: spawn closer to destination along orbital zone
		pcall(function() Space.PutShipIntoOrbit(ship, starBody) end)
	end
	entry.liveShip = ship
	return ship
end

local function spawnShipInArrivalCloud(entry, fromSysPath)
	if not Game.system or Game.InHyperspace() then return nil end
	local stars = Game.system:GetStars()
	local starPath = (stars and stars[1] and stars[1].path) or Game.system.path
	local fromSys = (fromSysPath and fromSysPath:SystemOnly()) or Game.system.path:SystemOnly()
	local okS, ship = pcall(function()
		return Space.SpawnShip(entry.shipId, 9, 11, { fromSys, starPath, Game.time + 6 })
	end)
	if okS and ship then
		applyShipConfig(ship, entry)
		entry.liveShip = ship
		return ship
	end
	return nil
end

local function convertInSystemToOOS(entry, simNow)
	local t = entry and entry.transit
	if not t then return end
	local now = simNow or Game.time
	if t.state == "UNDOCKING" or t.state == "DEPARTING" or t.state == "IN_SYSTEM_FLIGHT" then
		local curSys = t.fromSysPath or entry.locationPath
		if curSys and sameSystem(t.destPath, curSys) then
			local scDur, distMeters = computeOOSSupercruiseDurationSec(entry, t.destPath)
			local doneFrac = math.clamp(entry.orderProgress or 0.1, 0.05, 0.92)
			t.state = "OOS_SUPERCRUISE"
			t.phaseStartTime = now - (scDur * doneFrac)
			t.phaseEndTime = now + (scDur * (1.0 - doneFrac))
			t.oosTotalDist = distMeters
			entry.status = (doneFrac > 0.88) and "DOCKING" or "SUPERCRUISE"
			entry.orderEta = t.phaseEndTime
		else
			local maxR = PlayerFleet.GetShipHyperspaceRangeExact(entry)
			local hops, hopDists = findJumpRoute(curSys, t.destPath, math.max(1.5, maxR * 0.96))
			t.jumpRoute = hops
			t.jumpDists = hopDists
			t.jumpIndex = 1
			t.fromSysPath = curSys and curSys:SystemOnly() or nil
			t.hopSysPath = hops[1] or (t.destPath and t.destPath:SystemOnly())
			t.hopDistLy = hopDists[1] or systemDistLy(t.fromSysPath, t.hopSysPath)
			local _, _, hclass = getInstalledHyperdriveInfo(entry)
			local warmup = math.floor(5 + math.max(1, hclass) * 1.5)
			local jDur = computeJumpDurationSec(entry, t.hopDistLy)
			t.state = "HYPERSPACE"
			t.phaseStartTime = now
			t.phaseEndTime = now + warmup + jDur
			t.actualJumpDuration = jDur
			t.actualJumpFuel = computeJumpFuelUse(entry, t.hopDistLy)
			t.wearAppliedForHop = false
			entry.status = "HYPERSPACE"
			entry.orderEta = t.phaseEndTime
		end
	elseif t.state == "CLEARING_MASS_LOCK" or t.state == "HYPERJUMP_COUNTDOWN" then
		local _, _, hclass = getInstalledHyperdriveInfo(entry)
		local warmup = math.floor(5 + math.max(1, hclass) * 1.5)
		local jDur = computeJumpDurationSec(entry, t.hopDistLy or 6)
		t.state = "HYPERSPACE"
		t.phaseStartTime = now
		t.phaseEndTime = now + warmup + jDur
		t.actualJumpDuration = jDur
		t.actualJumpFuel = computeJumpFuelUse(entry, t.hopDistLy or 6)
		t.wearAppliedForHop = false
		entry.status = "HYPERSPACE"
		entry.orderEta = t.phaseEndTime
	end
	t.cmdIssued = false
end

local function startFleetTransit(entry, destPath, destName, purpose, simNow, isCatchUp)
	if not entry or not destPath then return end
	local now = simNow or Game.time
	local cleanDestName = destName or formatPathName(destPath)
	local t = {
		destPath = destPath,
		destName = cleanDestName,
		purpose = purpose or "TRANSIT",
		state = "UNDOCKING",
		phaseStartTime = now,
		phaseEndTime = nil,
		jumpRoute = nil,
		jumpDists = nil,
		jumpIndex = 1,
		fromSysPath = entry.locationPath and entry.locationPath:SystemOnly() or (Game.system and Game.system.path:SystemOnly()) or nil,
		hopSysPath = nil,
		hopDistLy = nil,
		initialDist = nil,
		oosTotalDist = nil,
		cmdIssued = false,
		aiRetryAt = 0,
		departStationPath = nil,
		departCompleted = false,
		undockRetryAt = 0,
		refuelResume = nil,
	}
	entry.transit = t
	entry.orderTargetPath = destPath
	entry.orderTargetName = cleanDestName
	entry.orderProgress = 0
	entry.orderEta = 0

	local inPlayerSystem = (not isCatchUp) and Game.system and not Game.InHyperspace() and entry.locationPath and sameSystem(entry.locationPath, Game.system.path)
	if inPlayerSystem then
		local live = spawnOrUpdateLiveFleetShip(entry, false, true)
		if live and live:exists() then
			local fs = live.flightState
			if fs == "DOCKED" and destPath:IsBodyPath() and sameSystem(destPath, Game.system.path) then
				local destBody = Space.GetBody(destPath.bodyIndex)
				if destBody and live:GetDockedWith() == destBody then
					t.state = "IN_SYSTEM_FLIGHT"
					updateFleetTransit(entry, now, isCatchUp)
					return
				end
			end
			if fs == "DOCKED" or fs == "LANDED" then
				local launched, port = tryUndockWithATC(live)
				t.state = "UNDOCKING"
				t.departStationPath = (port and port.path) or nil
				entry.status = "UNDOCKING"
				if launched then
					entry.orderPhase = string.format("[UNDOCKING] Launching from %s -> %s", formatPathName(entry.locationPath), cleanDestName)
				else
					local waitSec = math.clamp((port and port.GetLaunchWaitTime and port:GetLaunchWaitTime()) or 4, 2, 6)
					t.undockRetryAt = now + waitSec
					entry.orderPhase = string.format("[ATC HOLD] Awaiting departure clearance at %s", formatPathName(entry.locationPath))
				end
			elseif fs == "UNDOCKING" then
				local port = live:GetDockedWith()
				t.state = "UNDOCKING"
				t.departStationPath = (port and port.path) or nil
				entry.status = "UNDOCKING"
				entry.orderPhase = string.format("[UNDOCKING] Clearing docking bay -> %s", cleanDestName)
			elseif isShipDeparting(live) then
				t.state = "DEPARTING"
				t.departCompleted = false
				t.cmdIssued = true
				entry.status = "DEPARTING"
				entry.orderPhase = string.format("[DEPARTING] Clearing station departure corridor -> %s", cleanDestName)
			else
				if sameSystem(destPath, Game.system.path) then
					t.state = "IN_SYSTEM_FLIGHT"
				else
					t.state = "CLEARING_MASS_LOCK"
				end
				updateFleetTransit(entry, now, isCatchUp)
			end
			return
		end
	end

	-- Out-of-System (OOS) departure or fallback when not live in current system
	if entry.locationPath and sameSystem(entry.locationPath, destPath) then
		local scDur, distMeters = computeOOSSupercruiseDurationSec(entry, destPath)
		t.state = "OOS_SUPERCRUISE"
		t.phaseStartTime = now
		t.phaseEndTime = now + scDur
		t.oosTotalDist = distMeters
		entry.status = "SUPERCRUISE"
		entry.orderEta = t.phaseEndTime
		entry.orderPhase = string.format("[SUPERCRUISE] %s -> %s | %s rem", formatSystemName(destPath), cleanDestName, formatDistanceMeters(distMeters))
	else
		local maxR = PlayerFleet.GetShipHyperspaceRangeExact(entry)
		local hops, hopDists = findJumpRoute(entry.locationPath, destPath, math.max(1.5, maxR * 0.96))
		t.jumpRoute = hops
		t.jumpDists = hopDists
		t.jumpIndex = 1
		t.fromSysPath = entry.locationPath and entry.locationPath:SystemOnly() or nil
		t.hopSysPath = hops[1] or destPath:SystemOnly()
		t.hopDistLy = hopDists[1] or systemDistLy(t.fromSysPath, t.hopSysPath)
		local _, _, hclass = getInstalledHyperdriveInfo(entry)
		local warmup = math.floor(5 + math.max(1, hclass) * 1.5)
		local jDur = computeJumpDurationSec(entry, t.hopDistLy)
		t.state = "HYPERSPACE"
		t.phaseStartTime = now
		t.phaseEndTime = now + warmup + jDur
		t.actualJumpDuration = jDur
		t.actualJumpFuel = computeJumpFuelUse(entry, t.hopDistLy)
		t.wearAppliedForHop = false
		entry.status = "HYPERSPACE"
		entry.orderEta = t.phaseEndTime
		entry.orderPhase = string.format("[HYPERSPACE] Departing -> %s (%.1f ly)", formatSystemName(t.hopSysPath), t.hopDistLy or 0)
	end
end

updateFleetTransit = function(entry, simNow, isCatchUp, silentComms)
	if not entry then return false end
	local now = simNow or Game.time
	local allowLive = (not isCatchUp) and Game.system and not Game.InHyperspace()
	local t = entry.transit
	if not t then
		-- Recover gracefully from old savefiles loaded mid-order
		local fallbackDest = entry.orderTargetPath or entry.locationPath
		if not fallbackDest then return false end
		startFleetTransit(entry, fallbackDest, entry.orderTargetName or formatPathName(fallbackDest), entry.order or "TRANSIT", now, isCatchUp)
		t = entry.transit
		if not t then return false end
	end

	local inCurrentSys = allowLive and t.destPath and sameSystem(t.destPath, Game.system.path)

	if t.state == "UNDOCKING" then
		local originInCurrentSys = allowLive and (
			(entry.liveShip and entry.liveShip:exists()) or
			(entry.locationPath and sameSystem(entry.locationPath, Game.system.path))
		)
		if not originInCurrentSys then
			convertInSystemToOOS(entry, now)
			return updateFleetTransit(entry, now, isCatchUp, silentComms)
		end

		local live = spawnOrUpdateLiveFleetShip(entry, false, true)
		if not live or not live:exists() then
			convertInSystemToOOS(entry, now)
			return false
		end

		local fs = live.flightState
		if fs == "DOCKED" or fs == "LANDED" then
			local port = live:GetDockedWith()
			if port and port.path then
				t.departStationPath = port.path
			end
			local launched = false
			if now >= (t.undockRetryAt or 0) then
				launched, port = tryUndockWithATC(live)
				if port and port.path then
					t.departStationPath = port.path
				end
				if not launched then
					local waitSec = math.clamp((port and port.GetLaunchWaitTime and port:GetLaunchWaitTime()) or 4, 2, 6)
					t.undockRetryAt = now + waitSec
				end
			end
			entry.status = "UNDOCKING"
			entry.orderProgress = 0.03
			if launched then
				entry.orderPhase = string.format("[UNDOCKING] Launching from %s -> %s", formatPathName(entry.locationPath), t.destName)
			else
				entry.orderPhase = string.format("[ATC HOLD] Awaiting departure clearance at %s", formatPathName(entry.locationPath))
			end
			return false
		elseif fs == "UNDOCKING" then
			entry.status = "UNDOCKING"
			entry.orderProgress = 0.05
			entry.orderPhase = string.format("[UNDOCKING] Exiting docking bay -> %s", t.destName)
			return false
		else
			-- Transition cleanly into departure corridor autopilot before issuing external flight orders
			t.state = "DEPARTING"
			t.departCompleted = false
			t.departTicks = 0
			t.cmdIssued = true
			t.phaseStartTime = now
			local departSt = resolveStationByPath(t.departStationPath) or resolveStationByPath(entry.locationPath)
			if departSt and departSt:exists() and getShipAICommand(live) ~= "CMD_DEPART" then
				pcall(function() live:AIDepart(departSt) end)
			end
			entry.status = "DEPARTING"
			entry.orderProgress = 0.08
			entry.orderPhase = string.format("[DEPARTING] Clearing station departure corridor -> %s", t.destName)
			return false
		end
	end

	if t.state == "DEPARTING" then
		t.departTicks = (t.departTicks or 0) + 1
		local originInCurrentSys = allowLive and (
			(entry.liveShip and entry.liveShip:exists()) or
			(entry.locationPath and sameSystem(entry.locationPath, Game.system.path))
		)
		if not originInCurrentSys then
			convertInSystemToOOS(entry, now)
			return updateFleetTransit(entry, now, isCatchUp, silentComms)
		end

		local live = entry.liveShip
		if not live or not live:exists() then
			convertInSystemToOOS(entry, now)
			return false
		end

		syncFromLiveShip(entry)

		local fs = live.flightState
		if fs == "DOCKED" or fs == "LANDED" or fs == "UNDOCKING" then
			t.state = "UNDOCKING"
			return false
		end

		local aiCmd = getShipAICommand(live)
		if aiCmd == "CMD_DEPART" then
			entry.status = "DEPARTING"
			entry.orderProgress = 0.08
			entry.orderPhase = string.format("[DEPARTING] Clearing station departure corridor -> %s", t.destName)
			return false
		end

		if not t.departCompleted then
			local departSt = resolveStationByPath(t.departStationPath) or resolveStationByPath(entry.locationPath)
			if departSt and departSt:exists() and live:DistanceTo(departSt) < 1200 and ((now - (t.phaseStartTime or now)) < 120 or (t.departTicks or 0) < 3) then
				pcall(function() live:AIDepart(departSt) end)
				entry.status = "DEPARTING"
				entry.orderProgress = 0.08
				entry.orderPhase = string.format("[DEPARTING] Clearing station departure corridor -> %s", t.destName)
				return false
			end
		end

		-- Departure corridor cleared; proceed with navigation
		t.cmdIssued = false
		t.departCompleted = false
		t.phaseStartTime = now
		t.initialDist = nil
		t.aiRetryAt = 0
		t.state = inCurrentSys and "IN_SYSTEM_FLIGHT" or "CLEARING_MASS_LOCK"
	end

	if t.state == "IN_SYSTEM_FLIGHT" then
		if not inCurrentSys then
			convertInSystemToOOS(entry, now)
			return updateFleetTransit(entry, now, isCatchUp, silentComms)
		end

		local live = entry.liveShip
		if not live or not live:exists() then
			live = spawnShipOnRouteInSystem(entry, t) or spawnOrUpdateLiveFleetShip(entry, false, true)
		end
		if not live or not live:exists() then
			convertInSystemToOOS(entry, now)
			return false
		end

		syncFromLiveShip(entry)

		if live.flightState == "HYPERSPACE" then
			entry.status = "HYPERSPACE"
			entry.orderProgress = 0.60
			entry.orderPhase = string.format("[ARRIVING] Emerging from hyperspace -> %s", t.destName)
			return false
		end

		if live.flightState == "UNDOCKING" then
			t.state = "UNDOCKING"
			return false
		end

		if getShipAICommand(live) == "CMD_DEPART" then
			t.state = "DEPARTING"
			t.departCompleted = false
			t.departTicks = 0
			entry.status = "DEPARTING"
			return false
		end

		local destBody = (t.destPath:IsBodyPath() and Space.GetBody(t.destPath.bodyIndex)) or nil
		if not destBody or not destBody:exists() then
			-- System-only target (arrival at star system completes)
			entry.locationPath = t.destPath
			entry.locationName = formatPathName(t.destPath)
			entry.orderProgress = 1.0
			return true
		end

		if live.flightState == "DOCKED" then
			local dockedAt = live:GetDockedWith()
			if dockedAt == destBody then
				entry.locationPath = t.destPath
				entry.locationName = formatPathName(t.destPath)
				applyOperationalFlightWear(entry, t.destPath, "TRANSIT")
				if t.purpose == "REFUEL_DIVERT" and t.refuelResume then
					maintainFleetShipAtStation(entry, t.destPath, now, silentComms)
					local res = t.refuelResume
					t.refuelResume = nil
					addLog(entry.shipName, string.format("Completed refuel stop at %s; resuming %s.", entry.locationName, res.destName or "route"), 0, now)
					startFleetTransit(entry, res.destPath, res.destName, res.purpose, now, isCatchUp)
					return false
				end
				entry.status = "DOCKED"
				entry.orderProgress = 1.0
				entry.orderPhase = "Docked at " .. t.destName
				return true
			else
				t.state = "UNDOCKING"
				t.departStationPath = dockedAt and dockedAt.path or nil
				t.cmdIssued = false
				local launched, port = tryUndockWithATC(live)
				entry.status = "UNDOCKING"
				if launched then
					entry.orderPhase = string.format("[UNDOCKING] Launching for %s", t.destName)
				else
					local waitSec = math.clamp((port and port.GetLaunchWaitTime and port:GetLaunchWaitTime()) or 4, 2, 6)
					t.undockRetryAt = now + waitSec
					entry.orderPhase = string.format("[ATC HOLD] Awaiting departure clearance for %s", t.destName)
				end
				return false
			end
		end

		if destBody:isa("SpaceStation") then
			local dist = live:DistanceTo(destBody)
			if not t.initialDist or dist > t.initialDist then
				t.initialDist = math.max(1000, dist)
			end
			local fs = live.flightState
			local aiCmd = getShipAICommand(live)
			if fs ~= "DOCKING" and aiCmd ~= "CMD_DOCK" and now >= (t.aiRetryAt or 0) then
				local okCmd = pcall(function() live:AIDockWith(destBody) end)
				if okCmd then
					t.cmdIssued = true
					t.holdReason = nil
				end
			end
			local okV, vel = pcall(function() return live:GetVelocity() end)
			local spd = (okV and vel and vel.length) and vel:length() or 0
			entry.status = (fs == "SUPERCRUISE" and "SUPERCRUISE") or (fs == "DOCKING" and "DOCKING") or "FLYING"
			entry.orderProgress = math.clamp(0.08 + 0.90 * (1.0 - (dist / math.max(1000, t.initialDist))), 0.08, 0.98)
			if now < (t.aiRetryAt or 0) and t.holdReason then
				entry.orderPhase = string.format("[HOLDING] %s at %s; holding orbit (%s)", t.holdReason, t.destName, formatDistanceMeters(dist))
			else
				entry.orderPhase = string.format("[%s] -> %s | %s rem (%.0f m/s)", entry.status, t.destName, formatDistanceMeters(dist), spd)
			end
			return false
		else
			-- Celestial body target (e.g. Ringed Planet for Auto-Mine or orbital Scout target)
			local dist = live:DistanceTo(destBody)
			local arriveRadius = math.max(85000, (destBody:GetPhysicalRadius() or 1e6) * 2.8)
			if dist <= arriveRadius then
				pcall(function() live:AIEnterLowOrbit(destBody) end)
				entry.locationPath = t.destPath
				entry.locationName = formatPathName(t.destPath)
				applyOperationalFlightWear(entry, t.destPath, "TRANSIT")
				entry.orderProgress = 1.0
				entry.orderPhase = "Arrived in orbit at " .. t.destName
				return true
			end
			if not t.initialDist or dist > t.initialDist then
				t.initialDist = math.max(arriveRadius + 1000, dist)
			end
			local aiCmd = getShipAICommand(live)
			if aiCmd ~= "CMD_FLYTO" and now >= (t.aiRetryAt or 0) then
				local okCmd = pcall(function() live:AIFlyTo(destBody) end)
				if okCmd then t.cmdIssued = true end
			end
			local okV, vel = pcall(function() return live:GetVelocity() end)
			local spd = (okV and vel and vel.length) and vel:length() or 0
			local fs = live.flightState
			entry.status = (fs == "SUPERCRUISE" and "SUPERCRUISE") or "FLYING"
			entry.orderProgress = math.clamp(0.08 + 0.90 * (1.0 - ((dist - arriveRadius) / math.max(1000, t.initialDist - arriveRadius))), 0.08, 0.98)
			entry.orderPhase = string.format("[%s] -> %s | %s rem (%.0f m/s)", entry.status, t.destName, formatDistanceMeters(math.max(0, dist - arriveRadius)), spd)
			return false
		end
	end

	if t.state == "CLEARING_MASS_LOCK" then
		if not allowLive then
			convertInSystemToOOS(entry, now)
			return false
		end
		local live = entry.liveShip
		if not live or not live:exists() then
			convertInSystemToOOS(entry, now)
			return false
		end

		if live.flightState == "HYPERSPACE" then
			entry.status = "HYPERSPACE"
			entry.orderPhase = string.format("[TRANSIT] Plotting jump -> %s", formatSystemName(t.destPath))
			return false
		end

		if live.flightState == "DOCKED" or live.flightState == "LANDED" or live.flightState == "UNDOCKING" then
			t.state = "UNDOCKING"
			t.cmdIssued = false
			return false
		end

		if getShipAICommand(live) == "CMD_DEPART" then
			t.state = "DEPARTING"
			t.departCompleted = false
			t.departTicks = 0
			return false
		end

		syncFromLiveShip(entry)
		local allowed = true
		pcall(function() allowed = live:IsHyperjumpAllowed() end)
		local fb = live.frameBody
		if fb and fb:exists() and fb:isa("SpaceStation") and live:DistanceTo(fb) < getStationHyperjumpClearanceMeters(fb) then
			allowed = false
		end
		local nearSt = live.FindNearestTo and live:FindNearestTo("SPACESTATION") or nil
		if nearSt and nearSt:exists() and live:DistanceTo(nearSt) < getStationHyperjumpClearanceMeters(nearSt) then
			allowed = false
		end
		if (now - (t.phaseStartTime or now)) < 3 then
			allowed = false
		end

		if not allowed then
			local aiCmd = getShipAICommand(live)
			if (aiCmd == nil or aiCmd == "CMD_NONE") and now >= (t.aiRetryAt or 0) then
				local stars = Game.system:GetStars()
				local starBody = stars and stars[1] and stars[1].body or nil
				local farTarget = nil
				if starBody and starBody:exists() and starBody ~= fb and live:DistanceTo(starBody) > 5e7 then
					farTarget = starBody
				else
					local stPaths = Game.system:GetStationPaths()
					for _, sp in ipairs(stPaths or {}) do
						local sb = resolveStationByPath(sp)
						if sb and sb ~= fb and live:DistanceTo(sb) > 5e7 then
							farTarget = sb
							break
						end
					end
				end
				if farTarget then
					pcall(function() live:AIFlyTo(farTarget) end)
				elseif fb and fb:exists() and not fb:isa("SpaceStation") then
					pcall(function() live:AIEnterLowOrbit(fb) end)
				elseif starBody and starBody:exists() then
					pcall(function() live:AIFlyTo(starBody) end)
				end
				t.cmdIssued = true
			end
			entry.status = "FLYING"
			entry.orderProgress = 0.09
			entry.orderPhase = string.format("[DEPARTING] Clearing mass lock -> %s", formatSystemName(t.destPath))
			return false
		end

		t.state = "HYPERJUMP_COUNTDOWN"
		t.cmdIssued = false
		t.phaseStartTime = now
		t.countdownTicks = 0
		t.jumpRetryAt = 0
		-- Fall through to charge hyperdrive immediately
	end

	if t.state == "HYPERJUMP_COUNTDOWN" then
		t.countdownTicks = (t.countdownTicks or 0) + 1
		if not allowLive then
			convertInSystemToOOS(entry, now)
			return false
		end
		local live = entry.liveShip
		if not live or not live:exists() then
			-- Ship finished countdown or entered hyperspace between ticks
			local jDur = (t.scheduledJumpDuration and t.scheduledJumpDuration > 0) and t.scheduledJumpDuration
				or computeJumpDurationSec(entry, t.hopDistLy or 6)
			t.state = "HYPERSPACE"
			t.phaseStartTime = now
			t.phaseEndTime = now + jDur
			t.actualJumpDuration = jDur
			t.actualJumpFuel = t.scheduledJumpFuel or computeJumpFuelUse(entry, t.hopDistLy or 6)
			t.wearAppliedForHop = false
			entry.liveShip = nil
			entry.status = "HYPERSPACE"
			entry.orderEta = t.phaseEndTime
			return false
		end

		if not t.hopSysPath then
			local effRange = getEffectiveJumpRange(entry, live)
			local hops, hopDists = findJumpRoute(Game.system.path:SystemOnly(), t.destPath:SystemOnly(), effRange)
			t.jumpRoute = hops
			t.jumpDists = hopDists
			t.jumpIndex = 1
			t.fromSysPath = Game.system.path:SystemOnly()
			t.hopSysPath = hops[1] or t.destPath:SystemOnly()
			t.hopDistLy = hopDists[1] or systemDistLy(t.fromSysPath, t.hopSysPath)
		end

		local _, _, hclass = getInstalledHyperdriveInfo(entry)
		local fs = live.flightState
		if fs == "HYPERSPACE" then
			local jDur = (t.scheduledJumpDuration and t.scheduledJumpDuration > 0) and t.scheduledJumpDuration
				or computeJumpDurationSec(entry, t.hopDistLy or 6, live)
			t.state = "HYPERSPACE"
			t.phaseStartTime = now
			t.phaseEndTime = now + jDur
			t.actualJumpDuration = jDur
			t.actualJumpFuel = t.scheduledJumpFuel or computeJumpFuelUse(entry, t.hopDistLy or 6, live)
			t.wearAppliedForHop = false
			entry.liveShip = nil
			entry.status = "HYPERSPACE"
			entry.orderEta = t.phaseEndTime
			return false
		end
		if fs == "JUMPING" or t.cmdIssued then
			entry.status = "JUMPING"
			entry.orderProgress = 0.13
			entry.orderPhase = string.format("[JUMPING] Charging FSD -> %s (%.1f ly)", formatSystemName(t.hopSysPath), t.hopDistLy or 0)
			-- If countdown finished/aborted without launching, re-attempt HyperjumpTo instead of stranding the live ship
			if fs ~= "JUMPING" and (t.countdownTicks or 0) >= 6 and (now - (t.phaseStartTime or now)) > math.max(35, 20 + hclass * 2) then
				t.cmdIssued = false
				t.phaseStartTime = now
				t.countdownTicks = 0
			end
			return false
		end

		local okD, drive = pcall(function() return live:GetInstalledHyperdrive() end)
		if not okD or not drive then
			addLog(entry.shipName, "Aborting jump: no hyperdrive installed.", 0, now)
			entry.transit = nil
			entry.order = "IDLE"
			entry.status = "FLYING"
			entry.orderPhase = "Jump aborted (no hyperdrive)"
			return false
		end

		local jDist, jFuelNeeded = drive:CheckDestination(live, t.hopSysPath)
		local curR, maxR = drive:GetRange(live)
		if jDist and (not jFuelNeeded or drive:GetFuel() < jFuelNeeded) then
			if maxR and jDist <= maxR * 0.99 then
				-- Try pulling hyperdrive propellant from cargo hold first
				local cargoMgr = live:GetComponent('CargoManager')
				if cargoMgr and drive.fuel then
					local availCargo = cargoMgr:CountCommodity(drive.fuel) or 0
					if availCargo > 0 then
						local needTons = math.min(availCargo, math.ceil(math.max(1, (drive:GetMaxFuel() or 0) - drive:GetFuel())))
						if needTons > 0 then
							cargoMgr:RemoveCommodity(drive.fuel, needTons)
							drive:SetFuel(live, math.min(drive:GetMaxFuel() or 0, drive:GetFuel() + needTons))
							syncFromLiveShip(entry)
							jDist, jFuelNeeded = drive:CheckDestination(live, t.hopSysPath)
						end
					end
				end
				-- If still insufficient fuel, divert to nearest station to refuel
				if not jFuelNeeded or drive:GetFuel() < jFuelNeeded then
					local divSt = findBestStationInSystem(Game.system, entry.locationPath)
					if divSt then
						t.refuelResume = t.refuelResume or { destPath = t.destPath, destName = t.destName, purpose = t.purpose }
						t.destPath = divSt
						t.destName = formatPathName(divSt) .. " [Refuel]"
						t.purpose = "REFUEL_DIVERT"
						t.state = "IN_SYSTEM_FLIGHT"
						t.cmdIssued = false
						t.initialDist = nil
						t.aiRetryAt = 0
						addLog(entry.shipName, string.format("Low hyperfuel: diverting to %s to refuel before jumping.", formatPathName(divSt)), 0, now)
						return false
					end
				end
			else
				-- Hop exceeds max capacity range: replot multi-hop route within maxR
				local hops, hopDists = findJumpRoute(Game.system.path:SystemOnly(), t.destPath:SystemOnly(), math.max(1.5, (maxR or 2) * 0.95))
				t.jumpRoute = hops
				t.jumpDists = hopDists
				t.jumpIndex = 1
				t.fromSysPath = Game.system.path:SystemOnly()
				t.hopSysPath = hops[1] or t.destPath:SystemOnly()
				t.hopDistLy = hopDists[1] or systemDistLy(t.fromSysPath, t.hopSysPath)
			end
		end

		local okJ, jStatus, jFuelUse, jDuration = pcall(function() return live:HyperjumpTo(t.hopSysPath, false) end)
		if okJ and (jStatus == "OK" or jStatus == "DRIVE_ACTIVE") then
			t.scheduledJumpDuration = jDuration
			t.scheduledJumpFuel = jFuelUse
			t.cmdIssued = true
			entry.status = "JUMPING"
			entry.orderProgress = 0.13
			entry.orderPhase = string.format("[JUMPING] Charging FSD -> %s (%.1f ly)", formatSystemName(t.hopSysPath), t.hopDistLy or 0)
			return false
		elseif okJ and (jStatus == "INSUFFICIENT_FUEL" or jStatus == "SAFETY_LOCKOUT") then
			local divSt = findBestStationInSystem(Game.system, entry.locationPath)
			if divSt then
				t.refuelResume = t.refuelResume or { destPath = t.destPath, destName = t.destName, purpose = t.purpose }
				t.destPath = divSt
				t.destName = formatPathName(divSt) .. (jStatus == "SAFETY_LOCKOUT" and " [Drive Service]" or " [Refuel]")
				t.purpose = "REFUEL_DIVERT"
				t.state = "IN_SYSTEM_FLIGHT"
				t.cmdIssued = false
				t.initialDist = nil
				t.aiRetryAt = 0
				addLog(entry.shipName, string.format("Diverting to %s (%s).", formatPathName(divSt), tostring(jStatus)), 0, now)
				return false
			end
		end

		-- If obstructed/aligning, wait before returning to mass-lock clearance or OOS fallback
		entry.status = "JUMPING"
		entry.orderProgress = 0.11
		entry.orderPhase = string.format("[JUMPING] Aligning FSD vector -> %s", formatSystemName(t.hopSysPath))
		if (t.countdownTicks or 0) >= 6 and (now - (t.phaseStartTime or now)) >= 12 then
			local jAllowed = true
			pcall(function() jAllowed = live:IsHyperjumpAllowed() end)
			if not jAllowed then
				t.state = "CLEARING_MASS_LOCK"
				t.cmdIssued = false
				t.countdownTicks = 0
				t.phaseStartTime = now
			else
				local jDur = (t.scheduledJumpDuration and t.scheduledJumpDuration > 0) and t.scheduledJumpDuration
					or computeJumpDurationSec(entry, t.hopDistLy or 6, live)
				t.state = "HYPERSPACE"
				t.phaseStartTime = now
				t.phaseEndTime = now + jDur
				t.actualJumpDuration = jDur
				t.actualJumpFuel = t.scheduledJumpFuel or computeJumpFuelUse(entry, t.hopDistLy or 6, live)
				t.wearAppliedForHop = false
				entry.liveShip = nil
				entry.status = "HYPERSPACE"
				entry.orderEta = t.phaseEndTime
			end
		end
		return false
	end

	if t.state == "HYPERSPACE" then
		local dur = math.max(10, (t.phaseEndTime or (now + 60)) - (t.phaseStartTime or now))
		local frac = math.clamp((now - (t.phaseStartTime or now)) / dur, 0.0, 1.0)
		local rem = math.max(0, (t.phaseEndTime or now) - now)
		local hopName = formatSystemName(t.hopSysPath or t.destPath)

		entry.status = "HYPERSPACE"
		entry.orderEta = t.phaseEndTime or now
		entry.orderProgress = math.clamp(0.15 + 0.45 * frac, 0.15, 0.60)
		entry.orderPhase = string.format("[HYPERSPACE] Jumping -> %s (%.1f ly) | %s rem", hopName, t.hopDistLy or 0, Format.Duration(rem))

		if now < (t.phaseEndTime or 0) then
			return false
		end

		-- Hop jump completed at exact phaseEndTime
		local hopEnd = t.phaseEndTime or now
		local _, _, hclass = getInstalledHyperdriveInfo(entry)
		local warmupSec = math.floor(5 + math.max(1, hclass) * 1.5)
		local actualDur = t.actualJumpDuration or math.max(60, (hopEnd - (t.phaseStartTime or hopEnd)) - warmupSec)
		local hopFuelUsed = t.actualJumpFuel or computeJumpFuelUse(entry, t.hopDistLy or 6)

		if not t.wearAppliedForHop then
			if type(entry.hyperFuel) == "number" then
				entry.hyperFuel = math.max(0, entry.hyperFuel - hopFuelUsed)
			end
			entry.fuel = math.max(5, (entry.fuel or 100) - 3)
			applyOOSHyperjumpWear(entry, actualDur)
		end
		t.actualJumpDuration = nil
		t.actualJumpFuel = nil
		t.wearAppliedForHop = nil
		t.scheduledJumpDuration = nil
		t.scheduledJumpFuel = nil

		entry.locationPath = t.hopSysPath or t.destPath:SystemOnly()
		entry.locationName = formatPathName(entry.locationPath)
		t.jumpIndex = (t.jumpIndex or 1) + 1

		if not sameSystem(entry.locationPath, t.destPath) then
			-- Multi-hop route: queue next jump hop toward t.destPath
			local nextHop = t.jumpRoute and t.jumpRoute[t.jumpIndex] or nil
			local nextDist = t.jumpDists and t.jumpDists[t.jumpIndex] or nil
			if not nextHop then
				local maxR = PlayerFleet.GetShipHyperspaceRangeExact(entry)
				local hops, hopDists = findJumpRoute(entry.locationPath, t.destPath, math.max(1.5, maxR * 0.96))
				t.jumpRoute = hops
				t.jumpDists = hopDists
				t.jumpIndex = 1
				nextHop = hops[1] or t.destPath:SystemOnly()
				nextDist = hopDists[1]
			end
			t.fromSysPath = entry.locationPath
			t.hopSysPath = nextHop
			t.hopDistLy = nextDist or systemDistLy(t.fromSysPath, nextHop)

			-- Check hyperfuel sufficiency for the next hop; scoop or pay intermediate station refuel if needed
			local stopoverDelay = 0
			local nextHopFuel = computeJumpFuelUse(entry, t.hopDistLy)
			local driveProto = getInstalledHyperdriveInfo(entry)
			local maxHyper = driveProto and (driveProto.fuel_resv_size or 1) or 0
			if driveProto and (entry.hyperFuel or 0) < nextHopFuel then
				local hasScoop = false
				for _, eq in ipairs(entry.equip or {}) do
					if eq.id and string.find(eq.id, "fuel_scoop", 1, true) then
						hasScoop = true
						break
					end
				end
				if hasScoop then
					entry.hyperFuel = maxHyper
					stopoverDelay = 90
					addLog(entry.shipName, string.format("Scooped hydrogen in %s en route to %s.", entry.locationName, formatSystemName(nextHop)), 0, hopEnd)
				else
					local midSys = entry.locationPath:GetStarSystem()
					local midStations = midSys and midSys:GetStationPaths() or nil
					local fComm = driveProto.fuel or Commodities.hydrogen
					local unitP = (midSys and fComm) and getSystemCommodityPrice(midSys, fComm) or (fComm and fComm.price or 15)
					local needTons = math.max(0.5, maxHyper - (entry.hyperFuel or 0))
					if midStations and #midStations > 0 then
						local fCost = math.max(10, math.ceil(needTons * unitP))
						if PlayerState.GetMoney() >= fCost then
							PlayerState.AddMoney(-fCost)
							entry.hyperFuel = maxHyper
							entry.fuel = 100
							entry.stats.maintenancePaid = (entry.stats.maintenancePaid or 0) + fCost
							entry.stats.netProfit = (entry.stats.netProfit or 0) - fCost
							fleetState.totalProfit = (fleetState.totalProfit or 0) - fCost
							TaxAuthority.RecordOperatingExpense(fCost, "FLEET_FUEL", "[FLEET] " .. entry.shipName)
							addLog(entry.shipName, string.format("Refueled hyperdrive at transit port in %s.", entry.locationName), -fCost, hopEnd)
						end
						stopoverDelay = 180
					else
						local emgCost = math.max(25, math.ceil(needTons * unitP * 2))
						if PlayerState.GetMoney() >= emgCost then
							PlayerState.AddMoney(-emgCost)
							entry.stats.maintenancePaid = (entry.stats.maintenancePaid or 0) + emgCost
							entry.stats.netProfit = (entry.stats.netProfit or 0) - emgCost
							fleetState.totalProfit = (fleetState.totalProfit or 0) - emgCost
							TaxAuthority.RecordOperatingExpense(emgCost, "FLEET_FUEL", "[FLEET] " .. entry.shipName)
						end
						entry.hyperFuel = maxHyper
						stopoverDelay = 300
						addLog(entry.shipName, string.format("Emergency reserve hyperfuel synth in uninhabited %s.", entry.locationName), -emgCost, hopEnd)
					end
				end
			end

			if allowLive and sameSystem(entry.locationPath, Game.system.path) then
				spawnShipInArrivalCloud(entry, t.fromSysPath)
				t.state = "CLEARING_MASS_LOCK"
				t.cmdIssued = false
				t.phaseStartTime = hopEnd
				entry.status = "HYPERSPACE"
				entry.orderPhase = string.format("[ARRIVING] Transit hop %s -> jumping to %s", entry.locationName, formatSystemName(nextHop))
				return false
			end

			local nextJumpDur = computeJumpDurationSec(entry, t.hopDistLy)
			t.phaseStartTime = hopEnd + stopoverDelay
			t.phaseEndTime = t.phaseStartTime + warmupSec + nextJumpDur
			t.actualJumpDuration = nextJumpDur
			t.actualJumpFuel = computeJumpFuelUse(entry, t.hopDistLy)
			t.wearAppliedForHop = false
			entry.orderEta = t.phaseEndTime
			return false
		end

		-- Arrived in final destination system!
		if allowLive and sameSystem(t.destPath, Game.system.path) then
			local arrivedShip = spawnShipInArrivalCloud(entry, t.fromSysPath)
			t.state = "IN_SYSTEM_FLIGHT"
			t.cmdIssued = false
			t.initialDist = nil
			t.phaseStartTime = hopEnd
			if arrivedShip then
				entry.status = "HYPERSPACE"
				entry.orderPhase = string.format("[ARRIVING] Emerging from hyperspace -> %s", t.destName)
			else
				entry.status = "SUPERCRUISE"
			end
			return false
		end

		-- Destination system is still OOS -> simulate in-system Supercruise across orbital distance
		local scDur, distMeters = computeOOSSupercruiseDurationSec(entry, t.destPath)
		t.state = "OOS_SUPERCRUISE"
		t.phaseStartTime = hopEnd
		t.phaseEndTime = hopEnd + scDur
		t.oosTotalDist = distMeters
		entry.status = "SUPERCRUISE"
		entry.orderEta = t.phaseEndTime
		return false
	end

	if t.state == "OOS_SUPERCRUISE" then
		-- If player is now live in the destination system mid-Supercruise, materialize ship on route!
		if inCurrentSys then
			local live = spawnShipOnRouteInSystem(entry, t) or spawnOrUpdateLiveFleetShip(entry, false, true)
			t.state = "IN_SYSTEM_FLIGHT"
			t.cmdIssued = false
			t.initialDist = nil
			if live and live:exists() then
				return updateFleetTransit(entry, now, isCatchUp, silentComms)
			end
		end

		local dur = math.max(10, (t.phaseEndTime or (now + 60)) - (t.phaseStartTime or now))
		local frac = math.clamp((now - (t.phaseStartTime or now)) / dur, 0.0, 1.0)
		local remDist = (t.oosTotalDist or 1.2e11) * (1.0 - frac)
		local remTime = math.max(0, (t.phaseEndTime or now) - now)

		entry.status = (frac > 0.88) and "DOCKING" or "SUPERCRUISE"
		entry.orderEta = t.phaseEndTime or now
		entry.orderProgress = math.clamp(0.60 + 0.39 * frac, 0.60, 0.99)
		entry.orderPhase = string.format("[%s] %s -> %s | %s rem (%s)",
			entry.status, formatSystemName(t.destPath), t.destName, formatDistanceMeters(remDist), Format.Duration(remTime))

		if now >= (t.phaseEndTime or 0) then
			local arrTime = t.phaseEndTime or now
			entry.locationPath = t.destPath
			entry.locationName = formatPathName(t.destPath)
			entry.fuel = math.max(5, (entry.fuel or 100) - 2)
			applyOperationalFlightWear(entry, t.destPath, "TRANSIT")
			if t.purpose == "REFUEL_DIVERT" and t.refuelResume then
				maintainFleetShipAtStation(entry, t.destPath, arrTime, silentComms)
				local res = t.refuelResume
				t.refuelResume = nil
				addLog(entry.shipName, string.format("Completed refuel stop at %s; resuming %s.", entry.locationName, res.destName or "route"), 0, arrTime)
				startFleetTransit(entry, res.destPath, res.destName, res.purpose, arrTime, isCatchUp)
				return false
			end
			if t.purpose == "TRADE_BUY" or t.purpose == "TRADE_SELL" or t.purpose == "MINE_OUT" or t.purpose == "MINE_RETURN" or t.purpose == "SELL_CARGO" then
				local pCtx = (t.purpose == "TRADE_BUY" or t.purpose == "TRADE_SELL") and "TRADE_TRANSIT" or "CARGO_TRANSIT"
				local outcome = resolveOOSPirateEncounter(entry, t.destPath, pCtx, arrTime, silentComms)
				if outcome == "SHIP_DESTROYED" then
					return false
				end
				if outcome == "RETREATED_DAMAGED" and t.purpose == "MINE_OUT" then
					local repairSt = findNearestStationPath(entry.locationPath, entry.orderParams and entry.orderParams.homePath)
					if repairSt then
						entry.orderParams.mineState = "RETURNING"
						entry.orderParams.sellStationPath = repairSt
						startFleetTransit(entry, repairSt, formatPathName(repairSt) .. " [Emergency Repair]", "MINE_RETURN", arrTime, isCatchUp)
						return false
					end
				end
			end
			entry.orderProgress = 1.0
			return true
		end
		return false
	end

	return false
end

local function getShipDefenseProfile(entry)
	local weaponCount = 0
	local shieldCount = 0
	local hasNullifier = false
	local nullifierEq = nil
	for _, eq in ipairs((entry and entry.equip) or {}) do
		if (eq.integrity or 1.0) > 0.10 then
			local proto = Equipment.Get(eq.id)
			local slotType = (proto and proto.slot and proto.slot.type) or ""
			if string.find(slotType, "weapon", 1, true) then
				weaponCount = weaponCount + 1
			elseif string.find(slotType, "shield", 1, true) then
				shieldCount = shieldCount + 1
			end
			if eq.id == "misc.interdiction_nullifier" or (proto and proto.capabilities and (proto.capabilities.interdiction_nullifier or 0) > 0) then
				hasNullifier = true
				nullifierEq = eq
			end
		end
	end
	local cap = entry and entry.captain
	return {
		weaponCount = weaponCount,
		shieldCount = shieldCount,
		hasNullifier = hasNullifier,
		nullifierEq = nullifierEq,
		piloting = (cap and cap.piloting) or 18,
		sensors = (cap and cap.sensors) or 18,
	}
end

local function dropFleetCargoFraction(entry, fraction)
	if not entry or not entry.cargo then return 0 end
	local f = math.clamp(fraction or 1.0, 0, 1.0)
	if f <= 0 then return 0 end
	local droppedTons = 0
	local toZero = {}
	for cname, qty in pairs(entry.cargo) do
		if (qty or 0) > 0 then
			local dropQty = (f >= 0.999) and qty or math.max(1, math.floor(qty * f + 0.5))
			dropQty = math.min(qty, dropQty)
			if dropQty > 0 then
				local comm = Commodities[cname]
				local unitMass = (comm and comm.mass) or 1
				droppedTons = droppedTons + dropQty * unitMass
				adjustEntryCargoCostBasis(entry, cname, -dropQty)
				local rem = qty - dropQty
				if rem <= 0 then
					table.insert(toZero, cname)
				else
					entry.cargo[cname] = rem
				end
			end
		end
	end
	for _, cname in ipairs(toZero) do
		entry.cargo[cname] = nil
	end
	if droppedTons > 0 then
		entry.stats = entry.stats or {}
		entry.stats.cargoLostToPirates = (entry.stats.cargoLostToPirates or 0) + droppedTons
		if entry.orderParams and entry.orderParams.activeTrade then
			local at = entry.orderParams.activeTrade
			at.qty = math.max(0, entry.cargo[at.commName] or 0)
		end
		if entry.liveShip and entry.liveShip:exists() then
			applyCargoToShip(entry.liveShip, entry.cargo)
		end
	end
	return droppedTons
end

resolveOOSPirateEncounter = function(entry, sysPath, context, simTime, silentComms)
	if not entry or entry.status == "DESTROYED" then return "NONE" end
	local sys = sysPath and sysPath:GetStarSystem() or nil
	local sysName = (sys and sys.name) or formatSystemName(sysPath)
	local lawlessness = (sys and sys.lawlessness) or 0.15

	local MacroEngine = getMacroEngine()
	if MacroEngine and MacroEngine.GetCrisisForSystem then
		local crisis = MacroEngine.GetCrisisForSystem(sysName)
		if crisis and (crisis.type == "INSURGENCY" or crisis.type == "BLOCKADE") then
			lawlessness = math.min(1.0, lawlessness + 0.06)
		end
	end

	local baseChance
	if lawlessness <= 0.15 then
		baseChance = 0.008 + lawlessness * 0.08
	elseif lawlessness <= 0.50 then
		baseChance = 0.020 + (lawlessness - 0.15) * 0.22
	else
		baseChance = 0.097 + (lawlessness - 0.50) * 0.36
	end

	local cargoUnits = 0
	local cargoValue = 0
	for cname, qty in pairs(entry.cargo or {}) do
		if (qty or 0) > 0 then
			cargoUnits = cargoUnits + qty
			local comm = Commodities[cname]
			cargoValue = cargoValue + qty * ((comm and comm.price) or 50)
		end
	end

	local valueMult = 0.35
	if cargoUnits > 0 then
		valueMult = math.clamp(0.85 + (cargoValue / 10000.0) * 0.60, 0.85, 1.45)
	end
	if context == "MINE_RING" then
		valueMult = math.max(valueMult, 1.15)
	end

	local finalChance = math.min(0.42, baseChance * valueMult)
	if Engine.rand:Number(0, 1) >= finalChance then
		return "NONE"
	end

	local profile = getShipDefenseProfile(entry)
	local stance = PlayerFleet.GetDefenseOrder(entry)
	local capName = (entry.captain and entry.captain.name) or "Fleet Captain"
	local pirateThreat = math.clamp(24 + lawlessness * 58 + Engine.rand:Integer(-10, 18), 18, 100)

	entry.stats = entry.stats or {}
	entry.stats.pirateEncounters = (entry.stats.pirateEncounters or 0) + 1

	-- 1. Interdiction Nullifier Check
	local nullifierTriggerChance = (context == "MINE_RING") and 0.35 or 0.78
	if profile.hasNullifier then
		local evadeChance = math.clamp(nullifierTriggerChance + profile.piloting * 0.003, 0.35, 0.94)
		if Engine.rand:Number(0, 1) < evadeChance then
			entry.stats.piratesEvaded = (entry.stats.piratesEvaded or 0) + 1
			if profile.nullifierEq then
				local curInt = profile.nullifierEq.integrity or 1.0
				profile.nullifierEq.integrity = math.max(ComponentIntegrity.PASSIVE_WEAR_FLOOR or 0.15, curInt - 0.015)
			end
			PlayerFleet.AwardCaptainXP(entry, "sensors")
			local msg = string.format("Pirate interdiction evaded via Nullifier pulse in %s.", sysName)
			addLog(entry.shipName, msg, 0, simTime)
			if not silentComms then
				Comms.Message(string.format("%s: %s", entry.shipName, msg), capName)
			end
			return "EVADED"
		end
	end

	-- 2. Defense Order: SUBMIT (always drop cargo to avoid combat & hull damage)
	if stance == "SUBMIT" then
		local dropped = dropFleetCargoFraction(entry, 1.0)
		local msg = (dropped > 0)
			and string.format("Interdicted by pirates in %s [SUBMIT]: jettisoned all %dt cargo to avoid combat.", sysName, dropped)
			or string.format("Interdicted by pirates in %s [SUBMIT]: empty hold scanned; raiders departed.", sysName)
		addLog(entry.shipName, msg, 0, simTime)
		if (not silentComms) and dropped > 0 then
			Comms.ImportantMessage(string.format("%s: %s", entry.shipName, msg), capName)
		end
		return "SUBMITTED"
	end

	-- 3. Defense Order: FLEE (evade cleanly or partial/full cargo drop)
	if stance == "FLEE" then
		local escapeScore = 30 + profile.piloting * 0.85 + profile.shieldCount * 14 + (profile.hasNullifier and 12 or 0)
		local cleanChance = math.clamp(0.32 + (escapeScore - pirateThreat) * 0.007, 0.15, 0.72)
		if Engine.rand:Number(0, 1) < cleanChance then
			entry.stats.piratesEvaded = (entry.stats.piratesEvaded or 0) + 1
			local chip = Engine.rand:Integer(0, 5)
			if chip > 0 then
				entry.hullPercent = math.max(20, (entry.hullPercent or 100) - chip)
			end
			PlayerFleet.AwardCaptainXP(entry, "piloting")
			local msg = string.format("Interdicted in %s [FLEE]: broke pirate lock and escaped cleanly (Hull %.0f%%).", sysName, entry.hullPercent or 100)
			addLog(entry.shipName, msg, 0, simTime)
			if not silentComms then
				Comms.Message(string.format("%s: %s", entry.shipName, msg), capName)
			end
			return "EVADED"
		end

		local fullLossChance = math.clamp(0.06 + (pirateThreat - escapeScore) * 0.004, 0.04, 0.22)
		if cargoUnits > 0 and Engine.rand:Number(0, 1) < fullLossChance then
			local dropped = dropFleetCargoFraction(entry, 1.0)
			local dmg = Engine.rand:Integer(8, 18)
			entry.hullPercent = math.max(15, (entry.hullPercent or 100) - dmg)
			applyOperationalFlightWear(entry, sysPath, "COMBAT")
			local msg = string.format("Interdicted in %s [FLEE]: overwhelmed — jettisoned all %dt cargo to escape (Hull %.0f%%).", sysName, dropped, entry.hullPercent)
			addLog(entry.shipName, msg, 0, simTime)
			if not silentComms then
				Comms.ImportantMessage(string.format("%s: %s", entry.shipName, msg), capName)
			end
			return "DROPPED_ALL"
		else
			local dropped = (cargoUnits > 0) and dropFleetCargoFraction(entry, Engine.rand:Number(0.25, 0.55)) or 0
			local dmg = Engine.rand:Integer(3, 10)
			entry.hullPercent = math.max(15, (entry.hullPercent or 100) - dmg)
			applyOperationalFlightWear(entry, sysPath, "COMBAT")
			PlayerFleet.AwardCaptainXP(entry, "piloting")
			local msg = (dropped > 0)
				and string.format("Interdicted in %s [FLEE]: jettisoned %dt partial cargo to shake pursuit (Hull %.0f%%).", sysName, dropped, entry.hullPercent)
				or string.format("Interdicted in %s [FLEE]: escaped pursuit under fire (Hull %.0f%%).", sysName, entry.hullPercent)
			addLog(entry.shipName, msg, 0, simTime)
			if not silentComms then
				Comms.ImportantMessage(string.format("%s: %s", entry.shipName, msg), capName)
			end
			return (dropped > 0) and "DROPPED_PARTIAL" or "EVADED"
		end
	end

	-- 4. Defense Order: DEFEND (never drop cargo; fight or emergency retreat at ~15% hull)
	local defensePower = profile.weaponCount * 28 + profile.shieldCount * 16 + profile.piloting * 0.9 + ((entry.hullPercent or 100) / 100.0) * 15
	if profile.weaponCount >= 1 and defensePower >= pirateThreat * Engine.rand:Number(0.78, 1.15) then
		local bounty = Engine.rand:Integer(900, 3200) + math.floor(pirateThreat * 25)
		PlayerState.AddMoney(bounty)
		local _, tax = TaxAuthority.RecordOperationsIncome("FLEET_PATROL", bounty, 0, "[FLEET] " .. entry.shipName, simTime)
		entry.stats.taxesGenerated = (entry.stats.taxesGenerated or 0) + (tax or 0)
		entry.stats.bountiesEarned = (entry.stats.bountiesEarned or 0) + bounty
		entry.stats.netProfit = (entry.stats.netProfit or 0) + bounty
		fleetState.totalProfit = (fleetState.totalProfit or 0) + bounty
		entry.stats.piratesDestroyed = (entry.stats.piratesDestroyed or 0) + 1
		if entry.captain then
			entry.captain.killcount = (entry.captain.killcount or 0) + 1
		end
		PlayerFleet.AwardCaptainXP(entry, "piloting")
		local hullChip = math.max(1, Engine.rand:Integer(2, 11) - profile.shieldCount * 3)
		entry.hullPercent = math.max(18, (entry.hullPercent or 100) - hullChip)
		applyOperationalFlightWear(entry, sysPath, "COMBAT")
		local taxNote = (tax and tax > 0) and string.format(", Tax %s", Format.Money(tax, false)) or ""
		local msg = string.format("Interdicted in %s [DEFEND]: destroyed pirate raider (+%s bounty%s, Hull %.0f%%).", sysName, Format.Money(bounty, false), taxNote, entry.hullPercent)
		addLog(entry.shipName, msg, bounty, simTime)
		if not silentComms then
			Comms.Message(string.format("%s: %s", entry.shipName, msg), capName)
		end
		return "DESTROYED_PIRATE"
	end

	-- Outgunned on DEFEND: emergency retreat at ~15% hull with cargo intact
	local dmg = (profile.weaponCount == 0) and Engine.rand:Integer(22, 46) or Engine.rand:Integer(16, 34)
	applyOperationalFlightWear(entry, sysPath, "COMBAT")
	if lawlessness >= 0.80 and profile.weaponCount == 0 and ((entry.hullPercent or 100) - dmg) <= 0 and Engine.rand:Number(0, 1) < 0.25 then
		local salvagePayout = entry.isCharterStarter and 0 or math.floor((ShipDef[entry.shipId] and ShipDef[entry.shipId].basePrice or 10000) * 0.5)
		PlayerState.AddMoney(salvagePayout)
		entry.status = "DESTROYED"
		entry.transit = nil
		activeTradeScans[entry.uid] = nil
		local idx = findShipIndex(entry.uid)
		if idx then
			table.remove(fleetState.ships, idx)
		end
		local msg = string.format("DESTROYED by pirates in %s [DEFEND] (Hull breached). Insurance settlement +%s.", sysName, Format.Money(salvagePayout, false))
		addLog(entry.shipName, msg, salvagePayout, simTime)
		if not silentComms then
			Comms.ImportantMessage(string.format("MAYDAY: Fleet ship %s was destroyed by pirates in %s! Insurance: +%s.", entry.shipName, sysName, Format.Money(salvagePayout, false)), "Fleet Command")
		end
		return "SHIP_DESTROYED"
	end

	entry.hullPercent = math.max(15, (entry.hullPercent or 100) - dmg)
	local msg = string.format("Interdicted in %s [DEFEND]: outgunned! Emergency retreat at %.0f%% hull with cargo intact — returning for repairs.", sysName, entry.hullPercent)
	addLog(entry.shipName, msg, 0, simTime)
	if not silentComms then
		Comms.ImportantMessage(string.format("%s: %s", entry.shipName, msg), capName)
	end
	return "RETREATED_DAMAGED"
end

local function updateEscortAI(entry)
	if not Game.system or Game.InHyperspace() then return end
	if not entry.captain then return end

	local rt = liveOrderRuntime[entry.uid] or {}
	liveOrderRuntime[entry.uid] = rt

	-- Spawn escort only when player is undocked/flying or orbiting
	if Game.player.flightState == "FLYING" or Game.player.flightState == "SUPERCRUISE" then
		local live = spawnOrUpdateLiveFleetShip(entry, true, true)
		if live and live:exists() then
			local fs = live.flightState
			if fs == "DOCKED" or fs == "LANDED" then
				local launched = tryUndockWithATC(live)
				entry.status = "UNDOCKING"
				entry.orderPhase = launched and "[UNDOCKING] Escort launching from station" or "[ATC HOLD] Escort awaiting departure clearance"
				rt.escortCmd = nil
				rt.escortTarget = nil
				return
			elseif fs == "UNDOCKING" then
				entry.status = "UNDOCKING"
				entry.orderPhase = "[UNDOCKING] Escort clearing docking bay"
				return
			elseif fs == "HYPERSPACE" or fs == "JUMPING" then
				return
			elseif getShipAICommand(live) == "CMD_DEPART" then
				entry.status = "DEPARTING"
				entry.orderPhase = "[DEPARTING] Escort clearing station departure corridor"
				syncFromLiveShip(entry)
				return
			end

			entry.locationPath = Game.system.path
			entry.locationName = Game.system.name .. " (Escort)"
			entry.status = "ESCORTING"

			local aiCmd = getShipAICommand(live)
			local target = Game.player:GetCombatTarget()
			if target and target:exists() and target:IsShip() and target ~= live then
				if aiCmd ~= "CMD_KILL" or rt.escortTarget ~= target then
					live:AIKill(target)
					rt.escortCmd = "KILL"
					rt.escortTarget = target
				end
				entry.orderPhase = "Engaging " .. (target.shipName ~= "" and target.shipName or target.label)
				return
			end

			-- Look for nearby hostiles shooting or near player
			local nearShips = Space.GetBodiesNear(Game.player, 25000, "Ship")
			for _, other in ipairs(nearShips or {}) do
				if other ~= Game.player and other ~= live and other:exists() then
					local aiTarget = other.GetAITarget and other:GetAITarget() or nil
					if aiTarget == Game.player then
						if aiCmd ~= "CMD_KILL" or rt.escortTarget ~= other then
							live:AIKill(other)
							rt.escortCmd = "KILL"
							rt.escortTarget = other
						end
						entry.orderPhase = "Defending Flagship vs " .. (other.shipName ~= "" and other.shipName or other.label)
						return
					end
				end
			end

			local dist = live:DistanceTo(Game.player)
			if (aiCmd ~= "CMD_FORMATION" and aiCmd ~= "CMD_FLYTO") or rt.escortCmd ~= "FOLLOW" then
				live:AIFlyTo(Game.player)
				rt.escortCmd = "FOLLOW"
				rt.escortTarget = nil
			end
			if dist > 4500 then
				entry.orderPhase = "Closing formation (" .. string.format("%.1f km)", dist / 1000)
			else
				entry.orderPhase = "Flying close escort near Flagship"
			end
			syncFromLiveShip(entry)
		end
	elseif Game.player.flightState == "DOCKED" then
		local station = Game.player:GetDockedWith()
		if station and entry.liveShip and entry.liveShip:exists() then
			local live = entry.liveShip
			local fs = live.flightState
			local aiCmd = getShipAICommand(live)
			if fs == "DOCKED" then
				if live:GetDockedWith() == station then
					syncFromLiveShip(entry)
					entry.locationPath = station.path
					entry.locationName = formatPathName(station.path)
					entry.status = "DOCKED"
					entry.orderPhase = "Docked on escort standby at " .. station.label
					rt.escortCmd = nil
					rt.escortTarget = nil
				else
					local launched = tryUndockWithATC(live)
					entry.status = "UNDOCKING"
					entry.orderPhase = launched and "[UNDOCKING] Escort launching to join Flagship" or "[ATC HOLD] Escort awaiting departure clearance"
					rt.escortCmd = nil
					rt.escortTarget = nil
				end
			elseif fs == "LANDED" then
				tryUndockWithATC(live)
				entry.status = "UNDOCKING"
				entry.orderPhase = "[UNDOCKING] Escort lifting off to join Flagship"
				rt.escortCmd = nil
				rt.escortTarget = nil
			elseif fs == "UNDOCKING" then
				entry.status = "UNDOCKING"
				entry.orderPhase = "[UNDOCKING] Escort clearing docking bay"
			elseif aiCmd == "CMD_DEPART" then
				entry.status = "DEPARTING"
				entry.orderPhase = "[DEPARTING] Escort clearing departure corridor"
			elseif fs == "DOCKING" then
				entry.status = "DOCKING"
				entry.orderPhase = "Docking at " .. station.label .. " with Flagship"
			elseif fs == "FLYING" or fs == "SUPERCRUISE" then
				if (aiCmd ~= "CMD_DOCK" or rt.escortTarget ~= station) and Game.time >= (rt.escortDockRetryAt or 0) then
					live:AIDockWith(station)
					rt.escortCmd = "DOCK"
					rt.escortTarget = station
				end
				entry.status = (fs == "SUPERCRUISE" and "SUPERCRUISE") or "DOCKING"
				if Game.time < (rt.escortDockRetryAt or 0) then
					entry.orderPhase = "[HOLDING] Awaiting free bay at " .. station.label
				else
					entry.orderPhase = "Docking at " .. station.label .. " with Flagship"
				end
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
	if samePath(entry.locationPath, destStationPath) and entry.status == "DOCKED" and (not entry.liveShip or not entry.liveShip:exists() or entry.liveShip.flightState == "DOCKED") then
		return false, "Vessel is already docked at this station."
	end

	local crossSys = not sameSystem(entry.locationPath, destStationPath)
	if crossSys and not PlayerFleet.HasHyperdrive(entry) then
		return false, "Vessel has no hyperdrive installed for cross-system transit."
	end

	local dist = systemDistLy(entry.locationPath and entry.locationPath:SystemOnly(), destStationPath:SystemOnly())

	if not entry.captain then
		local fee = math.floor(FERRY_BASE_FEE + dist * FERRY_PER_LY_FEE)
		if PlayerState.GetMoney() < fee then
			return false, string.format("Remote ferry without a Captain requires %s courier pilot fee.", Format.Money(fee, false))
		end
		PlayerState.AddMoney(-fee)
		TaxAuthority.RecordOperatingExpense(fee, "FLEET_FEES", "[FLEET] " .. entry.shipName)
		addLog(entry.shipName, string.format("Hired delivery courier (%s) to ferry ship to %s.", Format.Money(fee, false), formatPathName(destStationPath)), -fee)
	end

	entry.order = "DOCK"
	entry.missionRef = nil
	activeTradeScans[uid] = nil
	startFleetTransit(entry, destStationPath, formatPathName(destStationPath), "DOCK")

	return true, string.format("%s launching for %s.", entry.shipName, entry.orderTargetName)
end

local function liquidateCargoAtCurrentStation(entry, simNow, silentComms)
	local now = simNow or Game.time
	local stPath = entry.locationPath
	local sys = (stPath and stPath:GetStarSystem()) or Game.system
	local totalSale = 0
	local totalCostBasis = 0
	local totalTons = 0

	for cname, qty in pairs(entry.cargo or {}) do
		if qty and qty > 0 then
			local comm = Commodities[cname] or (CommodityType and CommodityType.GetCommodity(cname))
			local unitPrice = 10
			if comm and sys then
				unitPrice = getSystemCommodityPrice(sys, comm)
			elseif comm and comm.price then
				unitPrice = comm.price
			end
			local legBasis = adjustEntryCargoCostBasis(entry, cname, -qty)
			totalCostBasis = totalCostBasis + legBasis
			totalSale = totalSale + unitPrice * qty
			totalTons = totalTons + qty
			entry.cargo[cname] = nil
		end
	end
	if entry.liveShip and entry.liveShip:exists() then
		applyCargoToShip(entry.liveShip, entry.cargo)
	end

	if totalSale > 0 then
		PlayerState.AddMoney(totalSale)
		local _, tax = TaxAuthority.RecordOperationsIncome("FLEET_CARGO", totalSale, totalCostBasis, "[FLEET] " .. entry.shipName, now)
		entry.stats.taxesGenerated = (entry.stats.taxesGenerated or 0) + (tax or 0)
		fleetState.totalProfit = (fleetState.totalProfit or 0) + totalSale
		entry.stats.netProfit = (entry.stats.netProfit or 0) + totalSale
		entry.stats.cargoHauled = (entry.stats.cargoHauled or 0) + totalTons
		entry.stats.runsCompleted = (entry.stats.runsCompleted or 0) + 1
		local locStr = entry.locationName or (stPath and formatPathName(stPath)) or "Station"
		local taxNote = (tax and tax > 0) and string.format(" | Tax %s", Format.Money(tax, false)) or ""
		addLog(entry.shipName, string.format("Liquidated %dt cargo hold at %s (+%s%s).", totalTons, locStr, Format.Money(totalSale, false), taxNote), totalSale, now)
		if not silentComms then
			Comms.ImportantMessage(string.format("%s liquidated %dt cargo hold at %s (+%s)", entry.shipName, totalTons, locStr, Format.Money(totalSale, false)), entry.captain and entry.captain.name or "Fleet Operations")
		end
		PlayerFleet.AwardCaptainXP(entry, "navigation")
	end

	if stPath then
		maintainFleetShipAtStation(entry, stPath, now, silentComms)
	end

	entry.order = "IDLE"
	entry.status = "DOCKED"
	entry.orderProgress = 0
	entry.orderEta = 0
	entry.orderPhase = "Docked on standby"
	return totalSale, totalTons
end

function PlayerFleet.OrderSellCargo(uid)
	local _, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end

	local cargoUsed = PlayerFleet.GetCargoUsed(entry)
	if cargoUsed <= 0 then
		return false, "No cargo in hold to liquidate."
	end

	-- If currently docked at a station, sell immediately
	if entry.status == "DOCKED" then
		local totalSale, totalTons = liquidateCargoAtCurrentStation(entry)
		return true, string.format("Sold %dt of cargo for %s (credited directly to your bank).", totalTons, Format.Money(totalSale, false))
	end

	-- If in space or at a non-station body, fly to the nearest station to sell
	local destStation = nil
	local sys = (entry.locationPath and entry.locationPath:GetStarSystem()) or Game.system
	if sys then
		destStation = findBestStationInSystem(sys, entry.locationPath)
	end
	if not destStation and Game.system then
		destStation = findBestStationInSystem(Game.system, nil)
	end
	if not destStation then
		return false, "No station with a commodity market found in system."
	end

	entry.order = "SELL_CARGO"
	entry.status = "TRANSIT"
	activeTradeScans[uid] = nil
	entry.orderTargetPath = destStation
	entry.orderTargetName = formatPathName(destStation)
	entry.orderPhase = "Flying to " .. entry.orderTargetName .. " to liquidate cargo"
	addLog(entry.shipName, string.format("Ordered to fly to %s and liquidate %dt cargo hold.", entry.orderTargetName, cargoUsed), 0)
	startFleetTransit(entry, destStation, formatPathName(destStation) .. " [Liquidate Cargo]", "SELL_CARGO")
	return true, string.format("%s en route to %s to liquidate %dt of cargo.", entry.shipName, entry.orderTargetName, cargoUsed)
end

function PlayerFleet.IssueOrder(uid, orderType, params)
	local _, entry = findShipIndex(uid)
	if not entry then return false, "Vessel not found." end

	params = params or {}
	activeTradeScans[uid] = nil

	if orderType == "IDLE" then
		entry.order = "IDLE"
		entry.orderTargetPath = nil
		entry.orderTargetName = nil
		entry.orderProgress = 0
		entry.orderEta = 0
		entry.missionRef = nil
		entry.transit = nil
		if entry.liveShip and entry.liveShip:exists() then
			syncFromLiveShip(entry)
			local fs = entry.liveShip.flightState
			if fs ~= "DOCKED" and fs ~= "HYPERSPACE" and Game.system then
				local dockSt = findBestStationInSystem(Game.system, entry.locationPath)
				if dockSt then
					entry.order = "DOCK"
					startFleetTransit(entry, dockSt, formatPathName(dockSt), "DOCK")
					addLog(entry.shipName, "Ordered to stand down and return to station.", 0)
					return true, "Standing down and flying to dock at " .. formatPathName(dockSt)
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
	entry.transit = nil

	if orderType == "FOLLOW" then
		entry.order = "FOLLOW"
		entry.status = "ESCORTING"
		entry.orderProgress = 0
		entry.orderEta = 0
		entry.orderPhase = "Forming up as Wingman Escort"
		addLog(entry.shipName, "Assigned Wingman Escort (Follow Flagship).", 0)
		if Game.system and not Game.InHyperspace() and (Game.player.flightState == "FLYING" or Game.player.flightState == "SUPERCRUISE") then
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
		entry.order = "AUTO_TRADE"
		entry.status = "SCANNING"
		entry.orderParams.maxJumps = params.maxJumps or entry.orderParams.maxJumps or 12
		if params.tradeRangeLy ~= nil then
			entry.orderParams.tradeRangeLy = math.clamp(math.floor(params.tradeRangeLy + 0.5), 0, MAX_TRADE_RANGE_LY)
		else
			entry.orderParams.tradeRangeLy = PlayerFleet.GetTradeRange(entry)
		end
		entry.orderParams.tradeState = "SEEKING"
		entry.orderParams.pendingBuyPath = nil
		entry.orderParams.pendingRoute = nil
		entry.orderParams.activeTrade = nil
		entry.orderParams.nextSeekTime = 0
		entry.orderParams.isInitialAutoTradeStart = true
		entry.orderParams.noStationsAbort = nil
		entry.orderProgress = 0
		entry.orderEta = 0
		entry.orderPhase = "[SCANNING] Initializing market scan..."
		tickAutoTrade(entry)
		entry.orderParams.isInitialAutoTradeStart = nil
		if entry.orderParams.noStationsAbort then
			entry.orderParams.noStationsAbort = nil
			entry.order = "IDLE"
			entry.status = "DOCKED"
			entry.orderProgress = 0
			entry.orderEta = 0
			entry.orderPhase = "Docked on standby"
			return false, "No reachable trade stations within operating range."
		end
		addLog(entry.shipName, string.format("Started Autonomous Trading (Captain %s).", entry.captain.name), 0)
		if activeTradeScans[entry.uid] then
			return true, string.format("%s scanning sector trade markets (within %d ly)...", entry.shipName, PlayerFleet.GetTradeRange(entry))
		end
		return true, string.format("%s began Autonomous Trade operations.", entry.shipName)

	elseif orderType == "AUTO_MINE" then
		if (entry.cargoCap or 0) <= 0 then
			return false, "Vessel needs cargo hold capacity to mine rings."
		end
		local ringPath, ringBody = findNearestRingBody(entry.locationPath)
		if not ringPath then
			return false, "No planetary rings detected within operating range."
		end
		if not sameSystem(entry.locationPath, ringPath) and not PlayerFleet.HasHyperdrive(entry) then
			return false, "No hyperdrive installed to reach planetary rings in neighboring systems."
		end
		entry.order = "AUTO_MINE"
		entry.status = "MINING"
		entry.orderTargetPath = ringPath
		entry.orderTargetName = ringBody.name .. " Rings"
		entry.orderParams.homePath = entry.locationPath
		entry.orderParams.mineState = "TO_RING"
		entry.orderParams.ringPath = ringPath
		entry.orderParams.ringType = ringBody.ringType
		entry.orderParams.ringReserve = ringBody.ringReserve
		entry.orderParams.ringBodyName = ringBody.name
		addLog(entry.shipName, string.format("Dispatched to mine %s rings (%s).", ringBody.name, tostring(ringBody.ringType or "ROCKY")), 0)
		startFleetTransit(entry, ringPath, ringBody.name .. " Rings", "MINE_OUT")
		return true, string.format("%s launching to mine %s rings.", entry.shipName, ringBody.name)

	elseif orderType == "PATROL" then
		local dur = calcDuration(1800, entry.captain, "piloting")
		liveOrderRuntime[entry.uid] = {}
		entry.order = "PATROL"
		entry.status = "PATROLLING"
		entry.orderParams.patrolState = "PATROLLING"
		entry.orderParams.startTime = Game.time
		entry.orderParams.patrolWaypointAt = 0
		entry.orderEta = Game.time + dur
		entry.orderProgress = 0
		entry.orderPhase = "Undocking for security patrol in " .. formatSystemName(entry.locationPath)
		if Game.system and not Game.InHyperspace() and sameSystem(entry.locationPath, Game.system.path) then
			local live = spawnOrUpdateLiveFleetShip(entry, false, true)
			if live and live:exists() then
				if live.flightState == "DOCKED" or live.flightState == "LANDED" then
					local launched = tryUndockWithATC(live)
					entry.status = "UNDOCKING"
					entry.orderPhase = launched and "[UNDOCKING] Launching on security patrol" or "[ATC HOLD] Awaiting patrol launch clearance"
				end
			end
		end
		addLog(entry.shipName, string.format("Initiated Sector Security Patrol (Combat Score %d).", PlayerFleet.GetShipCombatScore(entry)), 0)
		return true, string.format("%s launching on security patrol.", entry.shipName)

	elseif orderType == "SELL_CARGO" then
		return PlayerFleet.OrderSellCargo(uid)
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
	FrontlineSupply = true,
	FrontlineExtraction = true,
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
	if mission.type == "FrontlineExtraction" and mission.pickupDone then
		return false, "Evacuees are already embarked on the Flagship."
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
	for _, entry in ipairs(fleetState.ships or {}) do
		if entry.captain and entry.order ~= "MISSION" and entry.status ~= "DESTROYED" then
			local eligible = true
			local note = "Ready"
			if mission.type == "CargoRun" or mission.type == "FrontlineSupply" then
				local needed = mission.amount or 0
				local held = (mission.cargotype and entry.cargo and entry.cargo[mission.cargotype.name]) or 0
				local pHeld = 0
				if mission.cargotype and Game.player then
					pHeld = Game.player:GetComponent('CargoManager'):CountCommodity(mission.cargotype)
				end
				local needsPickup = (mission.pickup == true) and (not mission.cargo_picked_up)
				if not needsPickup and (held + pHeld) < needed then
					eligible = false
					note = string.format("Needs %dt %s", needed, mission.cargotype and mission.cargotype:GetName() or "cargo")
				elseif (held + PlayerFleet.GetCargoFree(entry)) < needed then
					eligible = false
					note = string.format("Cargo cap too small (%dt needed)", needed)
				end
			elseif mission.type == "FrontlineExtraction" then
				local neededBerths = mission.passengers or 1
				local cap = PlayerFleet.GetPassengerCap(entry)
				if cap < neededBerths then
					eligible = false
					note = string.format("Needs %d passenger berths (%d installed)", neededBerths, cap)
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

	local destPath = nil
	local retPath = nil

	if mission.type == "FrontlineExtraction" then
		destPath = (type(mission.originStation) == "userdata" and mission.originStation)
			or (type(mission.destination) == "userdata" and mission.destination)
			or entry.locationPath
		retPath = (type(mission.location) == "userdata" and mission.location)
			or (type(mission.domicile) == "userdata" and mission.domicile)
			or entry.locationPath
	elseif mission.type == "FrontlineSupply" then
		local needsPickup = (mission.pickup == true) and (not mission.cargo_picked_up)
		if needsPickup then
			destPath = (type(mission.location) == "userdata" and mission.location) or entry.locationPath
			retPath = (type(mission.domicile) == "userdata" and mission.domicile)
				or (type(mission.station) == "userdata" and mission.station)
				or entry.locationPath
		else
			destPath = (mission.pickup and type(mission.domicile) == "userdata" and mission.domicile)
				or (type(mission.location) == "userdata" and mission.location)
				or (type(mission.destination) == "userdata" and mission.destination)
				or entry.locationPath
			retPath = nil
		end
	else
		destPath = (type(mission.location) == "userdata" and mission.location)
			or (type(mission.destination) == "userdata" and mission.destination)
			or entry.locationPath
		if mission.type == "Scout" or mission.type == "Combat" or (mission.type == "CargoRun" and mission.pickup) then
			retPath = (type(mission.backstation) == "userdata" and mission.backstation)
				or (type(mission.station) == "userdata" and mission.station)
				or (type(mission.domicile) == "userdata" and mission.domicile)
				or entry.locationPath
		end
	end

	if destPath and (not destPath:IsBodyPath()) and (mission.type == "Delivery" or mission.type == "CargoRun" or mission.type == "Assassination" or mission.type == "FrontlineSupply" or mission.type == "FrontlineExtraction") then
		destPath = findNearestStationPath(destPath) or destPath
	end
	if retPath and not retPath:IsBodyPath() then
		retPath = findNearestStationPath(retPath) or retPath
	end

	local crossSys = (not sameSystem(entry.locationPath, destPath))
		or (retPath ~= nil and not sameSystem(destPath, retPath))
	if crossSys and not PlayerFleet.HasHyperdrive(entry) then
		return false, "Vessel has no hyperdrive installed for cross-system missions."
	end

	-- Transfer CargoRun / FrontlineSupply cargo from Game.player if already aboard Flagship and not awaiting pickup
	if (mission.type == "CargoRun" or mission.type == "FrontlineSupply") and mission.cargotype and not (mission.pickup and not mission.cargo_picked_up) then
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
			if entry.liveShip and entry.liveShip:exists() then
				applyCargoToShip(entry.liveShip, entry.cargo)
			end
		end
	end

	mission.fleetAssignedUid = entry.uid
	mission.fleetAssignedName = entry.shipName

	entry.order = "MISSION"
	entry.status = "MISSION"
	entry.missionRef = mission
	activeTradeScans[uid] = nil
	entry.orderParams.missionStage = "OUTBOUND"
	entry.orderParams.missionDestPath = destPath
	entry.orderParams.missionReturnPath = retPath
	entry.orderParams.siteEndTime = nil

	addLog(entry.shipName, string.format("Delegated '%s' contract (%s) -> %s.", mission:GetTypeDescription(), Format.Money(mission.reward or 0, false), formatPathName(destPath)), 0)
	startFleetTransit(entry, destPath, formatPathName(destPath) .. " [" .. mission:GetTypeDescription() .. "]", "MISSION_OUT")
	return true, string.format("%s launching for '%s' mission -> %s.", entry.shipName, mission:GetTypeDescription(), formatPathName(destPath))
end

local function completeFleetMission(entry, simNow, silentComms)
	local now = simNow or Game.time
	entry.transit = nil
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

	local dockedPath = entry.locationPath
		or (entry.orderParams and (entry.orderParams.missionReturnPath or entry.orderParams.missionDestPath))
		or (type(mission.location) == "userdata" and mission.location)
		or (type(mission.domicile) == "userdata" and mission.domicile)

	entry.locationPath = dockedPath
	entry.locationName = formatPathName(dockedPath)
	entry.order = "IDLE"
	entry.status = "DOCKED"
	entry.orderProgress = 0
	entry.orderEta = 0
	entry.missionRef = nil

	if not stillActive or mission.status == "FAILED" or mission.status == "COMPLETED" then
		entry.orderPhase = "Docked (contract expired before completion)"
		addLog(entry.shipName, "Mission contract expired before completion.", 0, now)
		if dockedPath then maintainFleetShipAtStation(entry, dockedPath, now, silentComms) end
		return
	end

	if mission.due and now > mission.due then
		entry.orderPhase = "Docked (missed deadline)"
		addLog(entry.shipName, string.format("Missed deadline on %s contract.", mission:GetTypeDescription()), 0, now)
		if not silentComms then
			Comms.ImportantMessage(string.format("%s: Missed contract deadline at %s.", entry.shipName, entry.locationName), entry.captain and entry.captain.name or entry.shipName)
		end
		mission.status = "FAILED"
		mission:Remove()
		if dockedPath then maintainFleetShipAtStation(entry, dockedPath, now, silentComms) end
		return
	end

	-- Handle cargo consumption if CargoRun or FrontlineSupply
	if (mission.type == "CargoRun" or mission.type == "FrontlineSupply") and mission.cargotype then
		local cname = mission.cargotype.name
		local held = entry.cargo[cname] or 0
		local take = math.min(held, mission.amount or 0)
		entry.cargo[cname] = held - take
		if entry.cargo[cname] <= 0 then entry.cargo[cname] = nil end
		if entry.liveShip and entry.liveShip:exists() then
			applyCargoToShip(entry.liveShip, entry.cargo)
		end
		entry.stats.cargoHauled = (entry.stats.cargoHauled or 0) + (mission.amount or 0)
	end

	-- Combat wear roll for Combat / Assassination contracts
	if mission.type == "Combat" or mission.type == "Assassination" then
		local dmg = math.max(0, Engine.rand:Integer(0, 14) - math.floor(PlayerFleet.GetShipCombatScore(entry) / 15))
		entry.hullPercent = math.max(25, (entry.hullPercent or 100) - dmg)
		applyOperationalFlightWear(entry, dockedPath, "COMBAT")
	end

	local reward = mission.reward or 0
	local tax = 0
	if reward > 0 then
		PlayerState.AddMoney(reward)
		local _, assessed = TaxAuthority.RecordOperationsIncome("FLEET_MISSION", reward, 0, "[FLEET] " .. entry.shipName, now)
		tax = assessed or 0
		entry.stats.taxesGenerated = (entry.stats.taxesGenerated or 0) + tax
	end
	fleetState.totalProfit = (fleetState.totalProfit or 0) + reward
	entry.stats.netProfit = (entry.stats.netProfit or 0) + reward
	entry.stats.missionsDone = (entry.stats.missionsDone or 0) + 1
	entry.stats.runsCompleted = (entry.stats.runsCompleted or 0) + 1

	local oldRep = Character.persistent.player.reputation or 0
	Character.persistent.player.reputation = oldRep + 1.5
	Event.Queue("onReputationChanged", oldRep, Character.persistent.player.killcount, Character.persistent.player.reputation, Character.persistent.player.killcount)

	if mission.type == "FrontlineSupply" or mission.type == "FrontlineExtraction" then
		local okFC, FrontlineCommon = pcall(require, 'modules.FrontlineSupport.FrontlineCommon')
		if okFC and FrontlineCommon and FrontlineCommon.RecordFrontlineContribution then
			local mTypeLabel = (mission.type == "FrontlineSupply") and "frontline supply" or "frontline extraction"
			FrontlineCommon.RecordFrontlineContribution({
				systemName    = mission.crisisSystemName,
				factionName   = mission.factionName,
				crisisDelta   = mission.crisisDelta,
				militaryXP    = math.floor((mission.militaryXP or 30) * 0.65 + 0.5),
				commendations = 1,
				standingDelta = 3,
				reason        = "Fleet autonomous " .. mTypeLabel .. " completed",
				reward        = 0,
			})
		end
	elseif mission.factionName then
		pcall(function()
			FactionStanding.ApplyMissionOutcome(mission.factionName, 2, mission.destFactionName, "Fleet autonomous contract completed")
		end)
	end

	-- Safely neutralize module-local references so original mission script won't double-pay on future dock
	local farOff = SystemPath.New(99999, 99999, 99999)
	mission.status = "COMPLETED"
	mission.complete = false
	mission.due = now + 1e12
	mission.location = farOff
	if mission.originStation then mission.originStation = farOff end
	if mission.domicile then mission.domicile = farOff end
	if mission.station then mission.station = farOff end
	if mission.backstation then mission.backstation = farOff end
	mission:Remove()

	if dockedPath then
		maintainFleetShipAtStation(entry, dockedPath, now, silentComms)
	end

	local primarySkill = (mission.type == "Combat" or mission.type == "Assassination") and "piloting" or "navigation"
	PlayerFleet.AwardCaptainXP(entry, primarySkill)

	local taxNote = (tax > 0) and string.format(" | Tax %s", Format.Money(tax, false)) or ""
	local msg = string.format("Completed '%s' at %s (+%s%s).", mission:GetTypeDescription(), entry.locationName, Format.Money(reward, false), taxNote)
	entry.orderPhase = "Contract completed. Docked at " .. entry.locationName
	addLog(entry.shipName, msg, reward, now)
	if not silentComms then
		Comms.ImportantMessage(entry.shipName .. ": " .. msg, entry.captain and entry.captain.name or "Fleet Command")
	end
end

-- ============================================================================
-- Periodic Autonomous Simulation Loop (OOS & Background Cycles)
-- ============================================================================

local function applyTradeRouteDecision(entry, route, now, isCatchUp, silentComms)
	local p = entry.orderParams
	if not route then
		entry.status = "DOCKED"
		entry.orderProgress = 0
		entry.orderEta = 0
		entry.orderPhase = "No profitable route found; waiting"
		p.tradeState = "SEEKING"
		p.nextSeekTime = now + (isCatchUp and 120 or 20)
		return
	end

	-- If ship is not currently docked at route.buyPath, fly there first
	if not samePath(entry.locationPath, route.buyPath) then
		p.tradeState = "TO_BUY"
		p.pendingBuyPath = route.buyPath
		startFleetTransit(entry, route.buyPath, formatPathName(route.buyPath) .. " [Buy " .. route.comm:GetName() .. "]", "TRADE_BUY", now, isCatchUp)
		return
	end

	local freeCap = PlayerFleet.GetCargoFree(entry)
	local unitMass = (route.comm.mass or 1)
	local maxUnitsBySpace = math.floor(freeCap / unitMass)
	local budgetCap = math.max(0, PlayerState.GetMoney() - 1000)
	local maxUnitsByCash = math.floor(budgetCap / math.max(1, route.buyPrice))
	local maxUnitsByStock = (route.buyStock and route.buyStock > 0) and route.buyStock or maxUnitsBySpace
	local buyQty = math.min(maxUnitsBySpace, maxUnitsByCash, maxUnitsByStock)

	if buyQty < 1 then
		entry.status = "DOCKED"
		entry.orderProgress = 0
		entry.orderEta = 0
		entry.orderPhase = (maxUnitsByStock < 1)
			and "Station stock depleted; waiting for restock"
			or ("Awaiting trade capital (" .. Format.Money(route.buyPrice, false) .. "/t needed)")
		p.tradeState = "SEEKING"
		p.nextSeekTime = now + (isCatchUp and 120 or 15)
		return
	end

	local totalSpend = buyQty * route.buyPrice
	PlayerState.AddMoney(-totalSpend)
	local cname = route.comm.name
	entry.cargo[cname] = (entry.cargo[cname] or 0) + buyQty
	adjustEntryCargoCostBasis(entry, cname, buyQty, route.buyPrice)
	recordFleetMarketImpact(route.buyPath, cname, -buyQty, now, formatPathName(route.buyPath))
	if entry.liveShip and entry.liveShip:exists() then
		applyCargoToShip(entry.liveShip, entry.cargo)
	end
	entry.stats.netProfit = (entry.stats.netProfit or 0) - totalSpend
	fleetState.totalProfit = (fleetState.totalProfit or 0) - totalSpend

	p.tradeState = "TO_SELL"
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
	addLog(entry.shipName, string.format("Bought %dt %s @ %s/t at %s", buyQty, p.activeTrade.commDisplay, Format.Money(route.buyPrice, false), formatPathName(route.buyPath)), -totalSpend, now)
	startFleetTransit(entry, route.sellPath, p.activeTrade.sellPathName .. " [Sell " .. p.activeTrade.commDisplay .. "]", "TRADE_SELL", now, isCatchUp)
end

function PlayerFleet.HasActiveScans()
	return next(activeTradeScans) ~= nil
end

function PlayerFleet.GetActiveScanCount()
	local count = 0
	for _ in pairs(activeTradeScans) do
		count = count + 1
	end
	return count
end

function PlayerFleet.StepBackgroundScans(budgetMs)
	if not Game.player or next(activeTradeScans) == nil then return end
	local totalBudget = math.max(1.0, tonumber(budgetMs) or TRADE_SCAN_SLICE_MS)
	local uids = {}
	for uid in pairs(activeTradeScans) do
		table.insert(uids, uid)
	end
	local perScanBudget = totalBudget / math.max(1, #uids)
	local now = Game.time
	for _, uid in ipairs(uids) do
		local scan = activeTradeScans[uid]
		local entry = PlayerFleet.GetShipByUid(uid)
		if not scan or not entry or entry.status == "DESTROYED" or entry.order ~= "AUTO_TRADE" or (entry.orderParams and entry.orderParams.tradeState ~= "SCANNING") then
			activeTradeScans[uid] = nil
		else
			local done, route = stepTradeScanState(scan, perScanBudget)
			if done then
				activeTradeScans[uid] = nil
				applyTradeRouteDecision(entry, route, now, false, scan.silentComms)
			else
				updateScanProgressDisplay(entry, scan)
			end
		end
	end
end

local function recordFleetFrontlineActivity(entry, sysPath, activityType, simTime, silentComms)
	if not entry or not sysPath then return end
	local now = simTime or Game.time or 0
	local cooldown = (activityType == "PATROL") and 600 or 900
	if (now - (entry.lastFrontlineTickTime or 0)) < cooldown then return end

	local okSys, sys = pcall(function() return sysPath:GetStarSystem() end)
	if not okSys or not sys or not sys.name then return end

	local okFC, FrontlineCommon = pcall(require, 'modules.FrontlineSupport.FrontlineCommon')
	if not (okFC and FrontlineCommon and FrontlineCommon.GetCrisisForSystem and FrontlineCommon.RecordFrontlineContribution) then
		return
	end

	local crisis = FrontlineCommon.GetCrisisForSystem(sys.name)
	if not crisis then return end

	entry.lastFrontlineTickTime = now
	local sysFaction = (sys.faction and sys.faction.name) or nil
	if activityType == "PATROL" then
		FrontlineCommon.RecordFrontlineContribution({
			systemName    = sys.name,
			factionName   = sysFaction,
			crisisDelta   = 1.5,
			militaryXP    = 10,
			commendations = 0,
			standingDelta = 1,
			reason        = "Fleet frontline security patrol",
			reward        = 0,
		})
		addLog(entry.shipName, string.format("Frontline security patrol stabilized %s (+1.5%% warfront relief).", sys.name), 0, now)
	else
		FrontlineCommon.RecordFrontlineContribution({
			systemName    = sys.name,
			factionName   = sysFaction,
			crisisDelta   = 1.0,
			militaryXP    = 5,
			commendations = 0,
			standingDelta = 1,
			reason        = "Fleet frontline supply relief",
			reward        = 0,
		})
		addLog(entry.shipName, string.format("Frontline trade delivery relieved %s (+1.0%% warfront relief).", sys.name), 0, now)
	end
end

tickAutoTrade = function(entry, simNow, isCatchUp, silentComms)
	local now = simNow or Game.time
	local p = entry.orderParams
	local state = p.tradeState or "SEEKING"

	if state == "SCANNING" then
		if isCatchUp then
			activeTradeScans[entry.uid] = nil
			state = "SEEKING"
			p.tradeState = "SEEKING"
		else
			local scan = activeTradeScans[entry.uid]
			if scan then
				local done, route = stepTradeScanState(scan, TRADE_SCAN_SLICE_MS)
				if done then
					activeTradeScans[entry.uid] = nil
					applyTradeRouteDecision(entry, route, now, false, silentComms)
				else
					updateScanProgressDisplay(entry, scan)
				end
				return
			else
				state = "SEEKING"
				p.tradeState = "SEEKING"
			end
		end
	end

	if state == "SEEKING" then
		if p.nextSeekTime and p.nextSeekTime > 0 and now < p.nextSeekTime then
			entry.status = "DOCKED"
			entry.orderProgress = 0
			return
		end

		local freeCap = PlayerFleet.GetCargoFree(entry)
		if freeCap < 1 then
			-- Sell whatever leftover cargo we already have at current market first
			local firstComm, firstQty = next(entry.cargo or {})
			if firstComm and Commodities[firstComm] then
				local sys = (entry.locationPath and entry.locationPath:GetStarSystem()) or Game.system
				local _, sellP = getEffectiveStationCommodityQuote(sys, entry.locationPath, Commodities[firstComm], now)
				local rev = sellP * firstQty
				local basis = adjustEntryCargoCostBasis(entry, firstComm, -firstQty)
				entry.cargo[firstComm] = nil
				if entry.liveShip and entry.liveShip:exists() then
					applyCargoToShip(entry.liveShip, entry.cargo)
				end
				PlayerState.AddMoney(rev)
				local _, tax = TaxAuthority.RecordOperationsIncome("FLEET_CARGO", rev, basis, "[FLEET] " .. entry.shipName, now)
				entry.stats.taxesGenerated = (entry.stats.taxesGenerated or 0) + (tax or 0)
				entry.stats.netProfit = (entry.stats.netProfit or 0) + rev
				fleetState.totalProfit = (fleetState.totalProfit or 0) + rev
				recordFleetMarketImpact(entry.locationPath, firstComm, firstQty, now, entry.locationName)
				local taxNote = (tax and tax > 0) and string.format(" (Tax %s)", Format.Money(tax, false)) or ""
				addLog(entry.shipName, string.format("Liquidated %dt %s hold%s.", firstQty, Commodities[firstComm]:GetName(), taxNote), rev, now)
				if entry.locationPath then
					maintainFleetShipAtStation(entry, entry.locationPath, now, silentComms)
				end
			end
			return
		end

		if isCatchUp then
			local route = findBestTradeRouteSync(entry, true, now)
			applyTradeRouteDecision(entry, route, now, true, silentComms)
			return
		end

		local scan = createTradeScanState(entry, false, silentComms, now)
		activeTradeScans[entry.uid] = scan
		p.tradeState = "SCANNING"
		local done, route = stepTradeScanState(scan, TRADE_SCAN_SLICE_MS)
		if done then
			activeTradeScans[entry.uid] = nil
			if not route and scan.marketsFound == 0 and (not scan.buyMarket or #(scan.buyMarket.stationPaths or {}) < 2) and p.isInitialAutoTradeStart then
				p.noStationsAbort = true
				return
			end
			applyTradeRouteDecision(entry, route, now, false, silentComms)
		else
			updateScanProgressDisplay(entry, scan)
		end

	elseif state == "TO_BUY" then
		local arrived = updateFleetTransit(entry, now, isCatchUp, silentComms)
		if arrived then
			entry.transit = nil
			entry.status = "DOCKED"
			if p.pendingBuyPath then
				entry.locationPath = p.pendingBuyPath
				entry.locationName = formatPathName(entry.locationPath)
			end
			if entry.locationPath then
				maintainFleetShipAtStation(entry, entry.locationPath, now, silentComms)
			end
			p.pendingBuyPath = nil
			p.tradeState = "SEEKING"
			p.nextSeekTime = 0
			tickAutoTrade(entry, now, isCatchUp, silentComms)
		end

	elseif state == "TO_SELL" or state == "TRANSIT" then
		local arrived = updateFleetTransit(entry, now, isCatchUp, silentComms)
		if not arrived then return end

		entry.transit = nil
		entry.status = "DOCKED"

		local tr = p.activeTrade
		if tr then
			local sellQty = math.min(tr.qty or 0, entry.cargo[tr.commName] or 0)
			if sellQty > 0 then
				local sellSys = (tr.sellPath and tr.sellPath:GetStarSystem()) or Game.system
				local _, curSellP = getEffectiveStationCommodityQuote(sellSys, tr.sellPath, Commodities[tr.commName], now, tr.sellPrice)
				local gross = sellQty * curSellP
				local basisSum = adjustEntryCargoCostBasis(entry, tr.commName, -sellQty)
				local unitBasis = (tr.spent and tr.qty and tr.qty > 0) and (tr.spent / tr.qty) or tr.buyPrice
				local costBasis = (sellQty == tr.qty and tr.spent and tr.spent > 0) and tr.spent or (basisSum > 0 and basisSum or (sellQty * (unitBasis or 0)))
				entry.cargo[tr.commName] = (entry.cargo[tr.commName] or sellQty) - sellQty
				if (entry.cargo[tr.commName] or 0) <= 0 then entry.cargo[tr.commName] = nil end
				if entry.liveShip and entry.liveShip:exists() then
					applyCargoToShip(entry.liveShip, entry.cargo)
				end

				PlayerState.AddMoney(gross)
				local _, tax = TaxAuthority.RecordOperationsIncome("FLEET_TRADE", gross, costBasis, "[FLEET] " .. entry.shipName, now)
				entry.stats.taxesGenerated = (entry.stats.taxesGenerated or 0) + (tax or 0)

				local legNet = gross - costBasis
				entry.stats.netProfit = (entry.stats.netProfit or 0) + gross
				fleetState.totalProfit = (fleetState.totalProfit or 0) + gross
				entry.stats.runsCompleted = (entry.stats.runsCompleted or 0) + 1
				entry.stats.cargoHauled = (entry.stats.cargoHauled or 0) + sellQty
				entry.locationPath = tr.sellPath
				entry.locationName = tr.sellPathName
				recordFleetMarketImpact(tr.sellPath, tr.commName, sellQty, now, tr.sellPathName)

				local taxNote = (tax and tax > 0) and string.format(", Tax %s", Format.Money(tax, false)) or ""
				addLog(entry.shipName, string.format("Sold %dt %s at %s (Net %s%s).", sellQty, tr.commDisplay, tr.sellPathName, Format.Money(legNet, false), taxNote), gross, now)
				if not silentComms and legNet >= 500 then
					Comms.Message(string.format("%s completed trade at %s (Net profit: %s)", entry.shipName, tr.sellPathName, Format.Money(legNet, false)), entry.captain and entry.captain.name or "Fleet Trade")
				end
				PlayerFleet.AwardCaptainXP(entry, "navigation")
				recordFleetFrontlineActivity(entry, tr.sellPath, "AUTO_TRADE", now, silentComms)
			else
				entry.locationPath = tr.sellPath
				entry.locationName = tr.sellPathName
				addLog(entry.shipName, string.format("Arrived at %s with empty hold (cargo lost en route).", tr.sellPathName), 0, now)
			end

			maintainFleetShipAtStation(entry, tr.sellPath, now, silentComms)
		elseif entry.locationPath then
			maintainFleetShipAtStation(entry, entry.locationPath, now, silentComms)
		end

		local inLiveSys = (not isCatchUp) and Game.system and not Game.InHyperspace() and entry.locationPath and sameSystem(entry.locationPath, Game.system.path)
		p.tradeState = "SEEKING"
		p.activeTrade = nil
		p.nextSeekTime = now + (inLiveSys and 20 or 90)
		entry.orderProgress = 0
		entry.orderEta = 0
		entry.orderPhase = "Unloaded at " .. (entry.locationName or "station") .. "; plotting next trade route..."
	end
end

tickAutoMine = function(entry, simNow, isCatchUp, silentComms)
	local now = simNow or Game.time
	local p = entry.orderParams
	local state = p.mineState or "TO_RING"

	if state == "TO_RING" then
		local arrived = updateFleetTransit(entry, now, isCatchUp, silentComms)
		if not arrived then return end

		entry.transit = nil
		local dur = calcDuration(1200, entry.captain, "sensors")
		p.mineState = "MINING"
		p.startTime = now
		entry.orderEta = now + dur
		entry.status = "MINING"
		entry.orderProgress = 0
		entry.orderPhase = string.format("[MINING] Extracting ore in %s rings", p.ringBodyName or "planetary")

	elseif state == "MINING" then
		if (not isCatchUp) and entry.liveShip and entry.liveShip:exists() then
			syncFromLiveShip(entry)
		end
		local startT = p.startTime or now
		local endT = entry.orderEta or (startT + 1200)
		local frac = math.clamp((now - startT) / math.max(1, endT - startT), 0, 1)
		entry.status = "MINING"
		entry.orderProgress = frac
		entry.orderPhase = string.format("[MINING] Extracting ore in %s rings (%d%%)", p.ringBodyName or "planetary", math.floor(frac * 100))
		if now < endT then return end

		local freeCap = PlayerFleet.GetCargoFree(entry)
		local comm = selectMineCommodity({ ringType = p.ringType, ringReserve = p.ringReserve })
		local reserveMult = (p.ringReserve == "PRISTINE" and 1.35) or (p.ringReserve == "DEPLETED" and 0.65) or 1.0
		local engBonus = 1.0 + ((entry.captain and entry.captain.engineering or 15) / 80)
		local rawYield = math.floor(math.max(4, math.min(freeCap, Engine.rand:Integer(8, 20) * reserveMult * engBonus)))

		if comm and rawYield > 0 and freeCap >= (comm.mass or 1) then
			local units = math.min(rawYield, math.floor(freeCap / (comm.mass or 1)))
			entry.cargo[comm.name] = (entry.cargo[comm.name] or 0) + units
			adjustEntryCargoCostBasis(entry, comm.name, units, 0)
			if (not isCatchUp) and entry.liveShip and entry.liveShip:exists() then
				applyCargoToShip(entry.liveShip, entry.cargo)
			end
			p.minedComm = comm.name
			p.minedDisplay = comm:GetName()
			p.minedUnits = units
		end

		applyOperationalFlightWear(entry, p.ringPath or entry.locationPath, "MINING")

		local ringOutcome = resolveOOSPirateEncounter(entry, p.ringPath or entry.locationPath, "MINE_RING", endT, silentComms)
		if ringOutcome == "SHIP_DESTROYED" then
			return
		end

		local destSt = findNearestStationPath(p.ringPath or entry.locationPath, p.homePath or entry.locationPath)
		if not destSt then
			entry.orderPhase = "Hold full; no nearby ore refinery station found"
			p.mineState = "RESUPPLY_PAUSE"
			p.pauseUntil = now + (isCatchUp and 120 or 20)
			return
		end

		p.mineState = "RETURNING"
		p.sellStationPath = destSt
		local retLabel = (ringOutcome == "RETREATED_DAMAGED") and " [Emergency Repair]" or " [Sell Ore]"
		startFleetTransit(entry, destSt, formatPathName(destSt) .. retLabel, "MINE_RETURN", now, isCatchUp)

	elseif state == "RETURNING" then
		local arrived = updateFleetTransit(entry, now, isCatchUp, silentComms)
		if not arrived then return end

		entry.transit = nil
		entry.status = "DOCKED"

		local stPath = p.sellStationPath or entry.locationPath
		local sys = (stPath and stPath:GetStarSystem()) or Game.system
		local totalSale = 0
		local totalTons = 0

		for cname, qty in pairs(entry.cargo or {}) do
			local comm = Commodities[cname]
			if comm and qty > 0 then
				local _, unitPrice = getEffectiveStationCommodityQuote(sys, stPath, comm, now)
				adjustEntryCargoCostBasis(entry, cname, -qty)
				totalSale = totalSale + unitPrice * qty
				totalTons = totalTons + qty
				entry.cargo[cname] = nil
				recordFleetMarketImpact(stPath, cname, qty, now, formatPathName(stPath))
			end
		end
		if entry.liveShip and entry.liveShip:exists() then
			applyCargoToShip(entry.liveShip, entry.cargo)
		end

		if totalSale > 0 then
			PlayerState.AddMoney(totalSale)
			local _, tax = TaxAuthority.RecordOperationsIncome("FLEET_MINE", totalSale, 0, "[FLEET] " .. entry.shipName, now)
			entry.stats.taxesGenerated = (entry.stats.taxesGenerated or 0) + (tax or 0)
			entry.stats.netProfit = (entry.stats.netProfit or 0) + totalSale
			fleetState.totalProfit = (fleetState.totalProfit or 0) + totalSale
			entry.stats.cargoHauled = (entry.stats.cargoHauled or 0) + totalTons
			entry.stats.runsCompleted = (entry.stats.runsCompleted or 0) + 1
			entry.locationPath = stPath
			entry.locationName = formatPathName(stPath)
			local taxNote = (tax and tax > 0) and string.format(", Tax %s", Format.Money(tax, false)) or ""
			addLog(entry.shipName, string.format("Sold %dt ring ore at %s (+%s%s).", totalTons, entry.locationName, Format.Money(totalSale, false), taxNote), totalSale, now)
			if not silentComms then
				Comms.Message(string.format("%s sold %dt mined ore (+%s)", entry.shipName, totalTons, Format.Money(totalSale, false)), entry.captain and entry.captain.name or "Fleet Mining")
			end
			PlayerFleet.AwardCaptainXP(entry, "engineering")
		end

		if stPath then
			maintainFleetShipAtStation(entry, stPath, now, silentComms)
		end

		local inLiveSys = (not isCatchUp) and Game.system and not Game.InHyperspace() and stPath and sameSystem(stPath, Game.system.path)
		p.mineState = "RESUPPLY_PAUSE"
		p.pauseUntil = now + (inLiveSys and 12 or 60)
		entry.orderProgress = 0
		entry.orderEta = 0
		entry.orderPhase = "Refueling at " .. (entry.locationName or "station") .. " before next mining sortie"

	elseif state == "RESUPPLY_PAUSE" then
		if now >= (p.pauseUntil or 0) then
			p.mineState = "TO_RING"
			if p.ringPath then
				startFleetTransit(entry, p.ringPath, (p.ringBodyName or "Planetary") .. " Rings", "MINE_OUT", now, isCatchUp)
			end
		end
	end
end

tickPatrol = function(entry, simNow, isCatchUp, silentComms)
	local now = simNow or Game.time
	local p = entry.orderParams
	local startT = p.startTime or now
	local rt = liveOrderRuntime[entry.uid] or {}
	liveOrderRuntime[entry.uid] = rt

	if p.patrolState == "MAINTENANCE_DOCK" then
		local arrived = updateFleetTransit(entry, now, isCatchUp, silentComms)
		if not arrived then return end

		entry.transit = nil
		entry.status = "DOCKED"
		if entry.locationPath then
			maintainFleetShipAtStation(entry, entry.locationPath, now, silentComms)
		end
		p.patrolState = "PATROLLING"
		local nextDur = calcDuration(1800, entry.captain, "piloting")
		p.startTime = now
		entry.orderEta = now + nextDur
		entry.orderProgress = 0
		entry.orderPhase = "Resuming security patrol in " .. formatSystemName(entry.locationPath)
		return
	end

	if (not isCatchUp) and Game.system and not Game.InHyperspace() and sameSystem(entry.locationPath, Game.system.path) then
		local live = spawnOrUpdateLiveFleetShip(entry, false, true)
		if live and live:exists() then
			syncFromLiveShip(entry)
			local fs = live.flightState
			local aiCmd = getShipAICommand(live)
			if fs == "DOCKED" or fs == "LANDED" then
				local launched = tryUndockWithATC(live)
				entry.status = "UNDOCKING"
				entry.orderPhase = launched and "[UNDOCKING] Launching on security patrol" or "[ATC HOLD] Awaiting patrol launch clearance"
				rt.patrolTarget = nil
				return
			elseif fs == "UNDOCKING" then
				entry.status = "UNDOCKING"
				entry.orderPhase = "[UNDOCKING] Clearing docking bay for security patrol"
				return
			elseif aiCmd == "CMD_DEPART" then
				entry.status = "DEPARTING"
				entry.orderPhase = "[DEPARTING] Clearing station corridor for security patrol"
				return
			elseif fs == "FLYING" or fs == "SUPERCRUISE" then
				entry.status = "PATROLLING"
				local near = Space.GetBodiesNear(live, 40000, "Ship")
				for _, other in ipairs(near or {}) do
					if other ~= Game.player and other ~= live and other:exists() then
						local otherFs = other:GetFlightState()
						local visibleToPatrol = false
						if fs == "SUPERCRUISE" then
							local otherSpeed = (other.GetSupercruiseSpeed and other:GetSupercruiseSpeed()) or 0
							visibleToPatrol = (otherFs == "SUPERCRUISE") and (otherSpeed >= 299792458.0)
						else
							visibleToPatrol = (otherFs == "FLYING")
						end
						local isWanted = visibleToPatrol and other.IsWanted and other:IsWanted()
						if isWanted then
							if aiCmd ~= "CMD_KILL" or rt.patrolTarget ~= other then
								live:AIKill(other)
								rt.patrolTarget = other
							end
							entry.orderPhase = "[COMBAT] Intercepting pirate " .. (other.label or "hostile")
							return
						end
					end
				end
				-- Keep moving between system patrol points so patrol ships fly shipping lanes
				if now >= (p.patrolWaypointAt or 0) or aiCmd == nil or aiCmd == "CMD_NONE" then
					local stPaths = Game.system:GetStationPaths()
					local farStations = {}
					for _, sp in ipairs(stPaths or {}) do
						local b = sp and Space.GetBody(sp.bodyIndex)
						if b and b:exists() and live:DistanceTo(b) > 25000 then
							table.insert(farStations, b)
						end
					end
					if #farStations > 0 then
						local pick = farStations[Engine.rand:Integer(1, #farStations)]
						pcall(function() live:AIFlyTo(pick) end)
						p.patrolWaypointName = pick.label
					else
						local stars = Game.system:GetStars()
						if stars and stars[1] and stars[1].body then
							pcall(function() live:AIEnterLowOrbit(stars[1].body) end)
							p.patrolWaypointName = stars[1].name
						end
					end
					rt.patrolTarget = nil
					p.patrolWaypointAt = now + 35
				end
				entry.orderPhase = "[PATROLLING] Sweeping shipping lanes near " .. (p.patrolWaypointName or Game.system.name)
			end
		end
	end

	if now < (entry.orderEta or 0) then
		entry.orderProgress = math.clamp((now - startT) / math.max(1, (entry.orderEta or startT + 1) - startT), 0, 1)
		entry.status = "PATROLLING"
		entry.orderPhase = "Patrolling shipping lanes in " .. formatSystemName(entry.locationPath)
		return
	end

	-- Resolve patrol sweep encounter
	local sweepEnd = entry.orderEta or now
	local combat = PlayerFleet.GetShipCombatScore(entry)
	local successChance = math.clamp(0.45 + (combat / 140), 0.45, 0.94)
	if Engine.rand:Number(0, 1) < successChance then
		local bounty = Engine.rand:Integer(800, 2600) + combat * 18
		PlayerState.AddMoney(bounty)
		local _, tax = TaxAuthority.RecordOperationsIncome("FLEET_PATROL", bounty, 0, "[FLEET] " .. entry.shipName, sweepEnd)
		entry.stats.taxesGenerated = (entry.stats.taxesGenerated or 0) + (tax or 0)
		entry.stats.bountiesEarned = (entry.stats.bountiesEarned or 0) + bounty
		entry.stats.netProfit = (entry.stats.netProfit or 0) + bounty
		fleetState.totalProfit = (fleetState.totalProfit or 0) + bounty
		entry.stats.runsCompleted = (entry.stats.runsCompleted or 0) + 1
		if entry.captain then
			entry.captain.killcount = (entry.captain.killcount or 0) + 1
		end
		local taxNote = (tax and tax > 0) and string.format(" | Tax %s", Format.Money(tax, false)) or ""
		addLog(entry.shipName, string.format("Neutralized pirate contact; bounty awarded (+%s%s).", Format.Money(bounty, false), taxNote), bounty, sweepEnd)
		if not silentComms then
			Comms.Message(string.format("%s patrol bounty collected (+%s).", entry.shipName, Format.Money(bounty, false)), entry.captain and entry.captain.name or "Security Patrol")
		end
		PlayerFleet.AwardCaptainXP(entry, "piloting")

		local hullChip = math.max(0, Engine.rand:Integer(0, 6) - math.floor(combat / 25))
		entry.hullPercent = math.max(30, (entry.hullPercent or 100) - hullChip)
		applyOperationalFlightWear(entry, entry.locationPath, "COMBAT")
		recordFleetFrontlineActivity(entry, entry.locationPath, "PATROL", sweepEnd, silentComms)
	else
		entry.hullPercent = math.max(30, (entry.hullPercent or 100) - Engine.rand:Integer(2, 5))
		applyOperationalFlightWear(entry, entry.locationPath, "TRANSIT")
		addLog(entry.shipName, "Completed shipping lane sweep — all sectors clear.", 0, sweepEnd)
	end
	entry.fuel = math.max(10, (entry.fuel or 100) - 4)

	-- Return to nearest station for service when hull < 80%, fuel < 30%, or any equipment < 80%
	local minEquipInteg = PlayerFleet.GetLowestEquipmentIntegrity(entry)
	if (entry.hullPercent or 100) < MAINTENANCE_HULL_THRESHOLD or (entry.fuel or 100) < 30 or minEquipInteg < MAINTENANCE_INTEGRITY_THRESHOLD then
		local maintSt = findNearestStationPath(entry.locationPath, nil)
		if maintSt then
			p.patrolState = "MAINTENANCE_DOCK"
			addLog(entry.shipName, string.format("Returning to %s for scheduled patrol maintenance.", formatPathName(maintSt)), 0, sweepEnd)
			startFleetTransit(entry, maintSt, formatPathName(maintSt) .. " [Maintenance]", "PATROL_MAINT", sweepEnd, isCatchUp)
			return
		end
	end

	local nextDur = calcDuration(1800, entry.captain, "piloting")
	p.startTime = sweepEnd
	entry.orderEta = sweepEnd + nextDur
	entry.orderProgress = 0
	entry.orderPhase = "Patrolling shipping lanes in " .. formatSystemName(entry.locationPath)
end

tickDockTransit = function(entry, simNow, isCatchUp, silentComms)
	local now = simNow or Game.time
	local arrived = updateFleetTransit(entry, now, isCatchUp, silentComms)
	if not arrived then return end

	local destPath = (entry.transit and entry.transit.destPath) or entry.orderTargetPath or entry.locationPath
	entry.transit = nil
	entry.locationPath = destPath
	entry.locationName = formatPathName(destPath)
	if destPath then
		maintainFleetShipAtStation(entry, destPath, now, silentComms)
	end
	entry.order = "IDLE"
	entry.status = "DOCKED"
	entry.orderProgress = 0
	entry.orderEta = 0
	entry.orderPhase = "Docked at " .. entry.locationName
	entry.stats.runsCompleted = (entry.stats.runsCompleted or 0) + 1

	addLog(entry.shipName, string.format("Arrived and docked at %s.", entry.locationName), 0, now)
	if not silentComms then
		Comms.ImportantMessage(string.format("%s arrived and docked at %s.", entry.shipName, entry.locationName), entry.captain and entry.captain.name or "Fleet Flight Control")
	end
	PlayerFleet.AwardCaptainXP(entry, "navigation")
end

tickSellCargoTransit = function(entry, simNow, isCatchUp, silentComms)
	local now = simNow or Game.time
	local arrived = updateFleetTransit(entry, now, isCatchUp, silentComms)
	if not arrived then return end

	local destPath = (entry.transit and entry.transit.destPath) or entry.orderTargetPath or entry.locationPath
	entry.transit = nil
	entry.locationPath = destPath
	entry.locationName = formatPathName(destPath)
	liquidateCargoAtCurrentStation(entry, now, silentComms)
end

tickMissionOrder = function(entry, simNow, isCatchUp, silentComms)
	local now = simNow or Game.time
	local p = entry.orderParams
	local stage = p.missionStage or "OUTBOUND"

	if stage == "OUTBOUND" then
		local arrived = updateFleetTransit(entry, now, isCatchUp, silentComms)
		if not arrived then return end

		local m = entry.missionRef
		local retPath = p.missionReturnPath
		if m and retPath and (m.type == "Scout" or m.type == "Combat" or ((m.type == "CargoRun" or m.type == "FrontlineSupply") and m.pickup and not m.cargo_picked_up) or m.type == "FrontlineExtraction") then
			if (m.type == "CargoRun" or m.type == "FrontlineSupply") and m.pickup and not m.cargo_picked_up and m.cargotype and (m.amount or 0) > 0 then
				local cname = m.cargotype.name
				entry.cargo[cname] = (entry.cargo[cname] or 0) + (m.amount or 0)
				if (not isCatchUp) and entry.liveShip and entry.liveShip:exists() then
					applyCargoToShip(entry.liveShip, entry.cargo)
				end
				m.cargo_picked_up = true
			elseif m.type == "FrontlineExtraction" then
				m.pickupDone = true
			end
			local siteDur = 60
			p.missionStage = "ON_SITE"
			p.siteStartTime = now
			p.siteEndTime = now + siteDur
			entry.transit = nil
			entry.orderProgress = 0
			entry.orderEta = p.siteEndTime
			entry.orderPhase = string.format("[ON STATION] Executing %s objective at %s", m:GetTypeDescription(), formatPathName(entry.locationPath))
			return
		end

		completeFleetMission(entry, now, silentComms)

	elseif stage == "ON_SITE" then
		local startT = p.siteStartTime or now
		local endT = p.siteEndTime or (startT + 60)
		local frac = math.clamp((now - startT) / math.max(1, endT - startT), 0, 1)
		entry.orderProgress = frac
		if now < endT then return end

		local m = entry.missionRef
		if m and (m.type == "Combat" or m.type == "Assassination") then
			applyOperationalFlightWear(entry, entry.locationPath, "COMBAT")
		elseif m and m.type == "Scout" then
			applyOperationalFlightWear(entry, entry.locationPath, "TRANSIT")
		end

		local retPath = p.missionReturnPath
		if retPath then
			p.missionStage = "RETURN"
			startFleetTransit(entry, retPath, formatPathName(retPath) .. " [Mission Return]", "MISSION_RETURN", endT, isCatchUp)
		else
			completeFleetMission(entry, endT, silentComms)
		end

	elseif stage == "RETURN" then
		local arrived = updateFleetTransit(entry, now, isCatchUp, silentComms)
		if not arrived then return end
		completeFleetMission(entry, now, silentComms)
	end
end

local function findEntryByLiveShip(ship)
	if not ship then return nil end
	for _, entry in ipairs(fleetState.ships or {}) do
		if entry.liveShip == ship then
			return entry
		end
	end
	return nil
end

local function findEntryByShipOrLabel(ship)
	if not ship then return nil end
	local byPtr = findEntryByLiveShip(ship)
	if byPtr then return byPtr end
	local sLabel = ship.label
	local sName = ship.shipName
	for _, entry in ipairs(fleetState.ships or {}) do
		if entry.status ~= "DESTROYED" and entry.label == sLabel and sName == ("[FLEET] " .. entry.shipName) then
			return entry
		end
	end
	return nil
end

local function advanceFleetEntryAtTime(entry, simNow, isCatchUp, silentComms)
	if entry.order == "FOLLOW" then
		if not isCatchUp then
			updateEscortAI(entry)
		end
	elseif entry.order == "DOCK" then
		tickDockTransit(entry, simNow, isCatchUp, silentComms)
	elseif entry.order == "SELL_CARGO" then
		tickSellCargoTransit(entry, simNow, isCatchUp, silentComms)
	elseif entry.order == "AUTO_TRADE" then
		tickAutoTrade(entry, simNow, isCatchUp, silentComms)
	elseif entry.order == "AUTO_MINE" then
		tickAutoMine(entry, simNow, isCatchUp, silentComms)
	elseif entry.order == "PATROL" then
		tickPatrol(entry, simNow, isCatchUp, silentComms)
	elseif entry.order == "MISSION" then
		tickMissionOrder(entry, simNow, isCatchUp, silentComms)
	elseif (not isCatchUp) and entry.order == "IDLE" and entry.status == "DOCKED" then
		-- Ensure docked ships in the player's system physically sit in a free bay if available
		if Game.system and not Game.InHyperspace() and entry.locationPath and sameSystem(entry.locationPath, Game.system.path) and (not entry.liveShip or not entry.liveShip:exists()) then
			spawnOrUpdateLiveFleetShip(entry, false, false)
		end
	end
end

local function getNextOOSEventTime(entry)
	if not entry or entry.status == "DESTROYED" then return nil end
	if entry.liveShip and entry.liveShip:exists() then return nil end
	if (not entry.transit) and Game.system and not Game.InHyperspace() and entry.locationPath and sameSystem(entry.locationPath, Game.system.path) then
		return nil
	end
	local t = entry.transit
	if t then
		if t.state == "HYPERSPACE" or t.state == "OOS_SUPERCRUISE" then
			return t.phaseEndTime
		end
		return nil
	end
	local ord = entry.order
	local p = entry.orderParams or {}
	if ord == "AUTO_TRADE" then
		if (p.tradeState or "SEEKING") == "SEEKING" and p.nextSeekTime and p.nextSeekTime > 0 then
			return p.nextSeekTime
		end
	elseif ord == "AUTO_MINE" then
		if p.mineState == "MINING" then
			return entry.orderEta
		elseif p.mineState == "RESUPPLY_PAUSE" then
			return p.pauseUntil
		end
	elseif ord == "PATROL" then
		if p.patrolState ~= "MAINTENANCE_DOCK" then
			return entry.orderEta
		end
	elseif ord == "MISSION" then
		if p.missionStage == "ON_SITE" then
			return p.siteEndTime
		end
	end
	return nil
end

local function reanchorFutureTimers(entry, shiftSec)
	if not shiftSec or shiftSec <= 0 then return end
	local t = entry.transit
	if t then
		if t.phaseStartTime then t.phaseStartTime = t.phaseStartTime + shiftSec end
		if t.phaseEndTime then t.phaseEndTime = t.phaseEndTime + shiftSec end
	end
	if entry.orderEta and entry.orderEta > 0 then entry.orderEta = entry.orderEta + shiftSec end
	local p = entry.orderParams
	if p then
		if p.nextSeekTime and p.nextSeekTime > 0 then p.nextSeekTime = p.nextSeekTime + shiftSec end
		if p.startTime and p.startTime > 0 then p.startTime = p.startTime + shiftSec end
		if p.pauseUntil and p.pauseUntil > 0 then p.pauseUntil = p.pauseUntil + shiftSec end
		if p.siteStartTime and p.siteStartTime > 0 then p.siteStartTime = p.siteStartTime + shiftSec end
		if p.siteEndTime and p.siteEndTime > 0 then p.siteEndTime = p.siteEndTime + shiftSec end
	end
end

local function catchUpEntryToTime(entry, targetTime, silentComms)
	if not entry or entry.status == "DESTROYED" then return end
	local lastT = -1
	local lastProcessed = nil
	local steps = 0
	while steps < MAX_CATCHUP_PHASES do
		local nextT = getNextOOSEventTime(entry)
		if not nextT or nextT <= 0 or nextT > targetTime or nextT <= lastT then
			break
		end
		lastT = nextT
		lastProcessed = nextT
		steps = steps + 1
		local useSilent = silentComms or ((targetTime - nextT) > 30)
		advanceFleetEntryAtTime(entry, nextT, true, useSilent)
	end
	if steps >= MAX_CATCHUP_PHASES and lastProcessed and lastProcessed < targetTime then
		local rem = getNextOOSEventTime(entry)
		if rem and rem < targetTime then
			reanchorFutureTimers(entry, targetTime - rem)
		end
	end
end

local function fleetSimulationStep()
	if not Game.system or Game.InHyperspace() then return end

	for _, entry in ipairs(fleetState.ships or {}) do
		if entry.status ~= "DESTROYED" then
			advanceFleetEntryAtTime(entry, Game.time, false, false)
		end
	end
	processFleetPayroll(Game.time, false)
end

local function ensureTickLoop()
	if tickTimerActive then return end
	tickTimerActive = true
	Timer:CallEvery(TICK_INTERVAL_SEC, function()
		if not Game.player then
			tickTimerActive = false
			return true
		end
		fleetSimulationStep()
		return false -- Keep repeating while game is running
	end)
end

-- ============================================================================
-- Game Lifecycle & Event Hooks
-- ============================================================================

local loaded_data = nil

Event.Register("onGameStart", function()
	fleetState = normalizeFleetState(loaded_data)
	loaded_data = nil
	for _, entry in ipairs(fleetState.ships or {}) do
		if entry.status ~= "DESTROYED" then
			normalizeFleetCrewForEntry(entry, Game.time)
		end
	end
	tickTimerActive = false
	liveOrderRuntime = {}
	soldDepartingShips = {}
	lastPlayerJumpFrom = nil
	lastPlayerJumpStart = nil
	activeTradeScans = {}
	systemMarketCache = {}
	systemMarketCacheCount = 0
	systemMarketAccessSeq = 0
	nearbySystemPathsCache = {}
	nearbyPathsCacheCount = 0
	ensureTickLoop()
	if Game.system and not Game.InHyperspace() then
		for _, entry in ipairs(fleetState.ships or {}) do
			if entry.status == "DOCKED" and entry.locationPath and sameSystem(entry.locationPath, Game.system.path) then
				spawnOrUpdateLiveFleetShip(entry, false, false)
			elseif entry.transit then
				updateFleetTransit(entry)
			end
		end
	end
end)

Event.Register("onGameEnd", function()
	fleetState = normalizeFleetState(nil)
	loaded_data = nil
	tickTimerActive = false
	liveOrderRuntime = {}
	soldDepartingShips = {}
	lastPlayerJumpFrom = nil
	lastPlayerJumpStart = nil
	activeTradeScans = {}
	systemMarketCache = {}
	systemMarketCacheCount = 0
	systemMarketAccessSeq = 0
	nearbySystemPathsCache = {}
	nearbyPathsCacheCount = 0
end)

local function collectFleetTotalsSnapshot()
	local runs, missions, net, tax, maint = 0, 0, 0, 0, 0
	for _, entry in ipairs(fleetState.ships or {}) do
		local st = entry.stats or {}
		runs = runs + (st.runsCompleted or 0)
		missions = missions + (st.missionsDone or 0)
		net = net + (st.netProfit or 0)
		tax = tax + (st.taxesGenerated or 0)
		maint = maint + (st.maintenancePaid or 0)
	end
	return runs, missions, net, tax, maint
end

Event.Register("onEnterSystem", function(player)
	if not player or not player:IsPlayer() then return end
	ensureTickLoop()

	local elapsedJumpSec = lastPlayerJumpStart and math.max(0, Game.time - lastPlayerJumpStart) or 0
	local jumpDistLy = lastPlayerJumpFrom and systemDistLy(lastPlayerJumpFrom, Game.system.path) or 5.0
	local r0, m0, n0, t0, maint0 = collectFleetTotalsSnapshot()

	for _, entry in ipairs(fleetState.ships or {}) do
		if entry.status ~= "DESTROYED" then
			-- Preserve an already-attached cloud ship if onShipEnterSystem fired immediately prior
			if entry.liveShip and not entry.liveShip:exists() then
				entry.liveShip = nil
			end

			if entry.order == "FOLLOW" and entry.captain then
				local hasDrive = PlayerFleet.HasHyperdrive(entry)
				if hasDrive then
					local jumpFuel = computeJumpFuelUse(entry, jumpDistLy)
					if type(entry.hyperFuel) == "number" then
						entry.hyperFuel = math.max(0, entry.hyperFuel - jumpFuel)
					end
					entry.fuel = math.max(8, (entry.fuel or 100) - 4)
					local escortDur = math.max(60, (elapsedJumpSec > 0) and elapsedJumpSec or computeJumpDurationSec(entry, jumpDistLy))
					applyOOSHyperjumpWear(entry, escortDur)
					entry.locationPath = Game.system.path
					entry.locationName = Game.system.name .. " (Escort)"
					updateEscortAI(entry)
				else
					entry.order = "IDLE"
					entry.status = "DOCKED"
					entry.orderPhase = "Stranded without hyperdrive at " .. (entry.locationName or "previous system")
					Comms.ImportantMessage(entry.shipName .. " has no hyperdrive and could not follow across hyperspace!", entry.captain.name)
				end
			else
				if entry.liveShip and entry.liveShip:exists() then
					syncFromLiveShip(entry)
				else
					catchUpEntryToTime(entry, Game.time, true)
				end

				if entry.order == "PATROL" and entry.locationPath and sameSystem(entry.locationPath, Game.system.path) and (not entry.transit) then
					spawnOrUpdateLiveFleetShip(entry, false, true)
				elseif entry.transit then
					updateFleetTransit(entry, Game.time, false, true)
				elseif entry.status == "DOCKED" and entry.locationPath and sameSystem(entry.locationPath, Game.system.path) then
					spawnOrUpdateLiveFleetShip(entry, false, false)
				end
			end
		end
	end

	processFleetPayroll(Game.time, elapsedJumpSec >= 300)

	local r1, m1, n1, t1, maint1 = collectFleetTotalsSnapshot()
	local dRuns = (r1 - r0) + (m1 - m0)
	local dNet = n1 - n0
	local dTax = t1 - t0
	local dMaint = maint1 - maint0
	if elapsedJumpSec >= 300 and (dRuns > 0 or dMaint > 0 or dTax > 0) then
		Comms.ImportantMessage(string.format(
			"Fleet Ops Digest (%s): %d completed ops | Net %s | Maint %s | Tax +%s",
			Format.Duration(elapsedJumpSec), dRuns, Format.Money(dNet, false), Format.Money(dMaint, false), Format.Money(dTax, false)
		), "Fleet Operations")
	end

	lastPlayerJumpFrom = nil
	lastPlayerJumpStart = nil
end)

Event.Register("onLeaveSystem", function(ship)
	if ship and ship:IsPlayer() then
		lastPlayerJumpFrom = Game.system and Game.system.path and Game.system.path:SystemOnly() or nil
		lastPlayerJumpStart = Game.time
		liveOrderRuntime = {}
		soldDepartingShips = {}
		for _, entry in ipairs(fleetState.ships or {}) do
			if entry.liveShip and entry.liveShip:exists() then
				syncFromLiveShip(entry)
			end
			if entry.transit then
				convertInSystemToOOS(entry, Game.time)
			end
			entry.liveShip = nil
		end
	end
end)

Event.Register("onShipUndocked", function(ship, starport)
	if soldDepartingShips[ship] then
		if starport and starport:exists() then
			pcall(function() ship:AIDepart(starport) end)
		end
		return
	end
	local entry = findEntryByLiveShip(ship)
	if not entry then return end
	if starport and starport:exists() then
		pcall(function() ship:AIDepart(starport) end)
	end
	if entry.transit then
		local t = entry.transit
		if t.state == "UNDOCKING" or t.state == "IN_SYSTEM_FLIGHT" or t.state == "CLEARING_MASS_LOCK" then
			t.state = "DEPARTING"
			t.departStationPath = (starport and starport.path) or t.departStationPath
			t.departCompleted = false
			t.departTicks = 0
			t.cmdIssued = true
			t.phaseStartTime = Game.time
			entry.status = "DEPARTING"
			entry.orderProgress = 0.08
			entry.orderPhase = string.format("[DEPARTING] Clearing station departure corridor -> %s", t.destName or "space")
		end
	elseif entry.order == "FOLLOW" then
		local rt = liveOrderRuntime[entry.uid]
		if rt then
			rt.escortCmd = nil
			rt.escortTarget = nil
		end
		entry.status = "DEPARTING"
		entry.orderPhase = "[DEPARTING] Escort clearing station departure corridor"
	elseif entry.order == "PATROL" then
		local rt = liveOrderRuntime[entry.uid]
		if rt then
			rt.patrolTarget = nil
		end
		entry.orderParams.patrolWaypointAt = 0
		entry.status = "DEPARTING"
		entry.orderPhase = "[DEPARTING] Clearing station corridor for security patrol"
	end
end)

Event.Register("onShipDocked", function(ship, starport)
	local entry = findEntryByLiveShip(ship)
	if not entry then return end
	liveOrderRuntime[entry.uid] = nil
	-- Guard against free NPC propellant reset in StationRefuelling before fleet accounting syncs
	local preDockFuel = entry.fuel
	if preDockFuel and preDockFuel < 95 and (ship.fuel or 100) >= 99.9 then
		pcall(function() ship:SetFuelPercent(preDockFuel) end)
	end
	syncFromLiveShip(entry)
	if starport and starport.path then
		entry.locationPath = starport.path
		entry.locationName = formatPathName(starport.path)
	end
	entry.status = "DOCKED"
	if entry.order == "AUTO_TRADE" then
		tickAutoTrade(entry)
	elseif entry.order == "AUTO_MINE" then
		tickAutoMine(entry)
	elseif entry.order == "PATROL" then
		tickPatrol(entry)
	elseif entry.order == "MISSION" then
		tickMissionOrder(entry)
	elseif entry.order == "DOCK" then
		tickDockTransit(entry)
	elseif entry.order == "SELL_CARGO" then
		tickSellCargoTransit(entry)
	elseif entry.order == "FOLLOW" then
		if starport and starport.path then
			maintainFleetShipAtStation(entry, starport.path, Game.time, false)
		end
		entry.orderPhase = "Docked on escort standby at " .. (starport and starport.label or "station")
	elseif entry.order == "IDLE" then
		if starport and starport.path then
			maintainFleetShipAtStation(entry, starport.path, Game.time, false)
		end
	end
end)

Event.Register("onShipLeaveSystem", function(ship)
	local entry = findEntryByLiveShip(ship)
	if not entry then return end
	syncFromLiveShip(entry)
	entry.liveShip = nil
	if entry.transit and (entry.transit.state == "HYPERJUMP_COUNTDOWN" or entry.transit.state == "CLEARING_MASS_LOCK") then
		local t = entry.transit
		local jDur = (t.scheduledJumpDuration and t.scheduledJumpDuration > 0) and t.scheduledJumpDuration
			or computeJumpDurationSec(entry, t.hopDistLy or 6, ship)
		t.state = "HYPERSPACE"
		t.cmdIssued = false
		t.phaseStartTime = Game.time
		t.phaseEndTime = Game.time + jDur
		t.actualJumpDuration = jDur
		t.actualJumpFuel = t.scheduledJumpFuel or computeJumpFuelUse(entry, t.hopDistLy or 6, ship)
		t.wearAppliedForHop = false
		entry.status = "HYPERSPACE"
		entry.orderEta = t.phaseEndTime
	end
end)

Event.Register("onShipEnterSystem", function(ship)
	local entry = findEntryByShipOrLabel(ship)
	if not entry then return end
	entry.liveShip = ship
	if Game.system and Game.system.path then
		entry.locationPath = Game.system.path
		entry.locationName = formatPathName(Game.system.path)
	end
	if not ship:hasprop('nextJumpDuration') then
		syncFromLiveShip(entry)
	end
	if entry.transit then
		local t = entry.transit
		t.cmdIssued = false
		t.wearAppliedForHop = true
		if t.destPath and Game.system and sameSystem(t.destPath, Game.system.path) then
			t.state = "IN_SYSTEM_FLIGHT"
		else
			t.state = "CLEARING_MASS_LOCK"
		end
		updateFleetTransit(entry, Game.time, false, true)
	end
end)

Event.Register("onAICompleted", function(ship, ai_error)
	if soldDepartingShips[ship] then
		soldDepartingShips[ship] = nil
		if ship:exists() and Game.system then
			local stars = Game.system:GetStars()
			if stars and stars[1] and stars[1].body then
				pcall(function() ship:AIFlyTo(stars[1].body) end)
			end
		end
		return
	end
	local entry = findEntryByLiveShip(ship)
	if not entry then return end
	if entry.transit then
		local t = entry.transit
		if t.state == "DEPARTING" then
			t.departCompleted = true
			t.cmdIssued = false
			t.aiRetryAt = 0
			updateFleetTransit(entry)
		elseif t.state == "IN_SYSTEM_FLIGHT" then
			if ai_error == "REFUSED_PERM" then
				t.cmdIssued = false
				t.aiRetryAt = Game.time + 15
				t.holdReason = "Bays full"
				local destBody = (t.destPath and t.destPath:IsBodyPath() and Space.GetBody(t.destPath.bodyIndex)) or nil
				enterSafeHoldingOrbit(ship, destBody)
				entry.orderPhase = "[HOLDING] Docking bays full at " .. (t.destName or "station") .. "; holding orbit"
			elseif ai_error == "PRESS_TOO_HIGH" or ai_error == "GRAV_TOO_HIGH" then
				local reasonStr = (ai_error == "PRESS_TOO_HIGH") and "atmospheric pressure exceeds hull limit" or "surface gravity exceeds thruster lift"
				addLog(entry.shipName, string.format("Cannot land at %s (%s).", t.destName or "surface port", reasonStr), 0)
				Comms.ImportantMessage(string.format("%s cannot land at %s: %s.", entry.shipName, t.destName or "surface port", reasonStr), entry.captain and entry.captain.name or "Fleet Operations")
				local altPath = nil
				if entry.order == "DOCK" or entry.order == "SELL_CARGO" or t.purpose == "MINE_RETURN" then
					altPath = findAlternativeOrbitalStation(Game.system, t.destPath)
				end
				if altPath then
					t.destPath = altPath
					t.destName = formatPathName(altPath)
					entry.orderTargetPath = altPath
					entry.orderTargetName = t.destName
					if entry.orderParams then
						if entry.orderParams.sellStationPath then
							entry.orderParams.sellStationPath = altPath
						end
						if entry.orderParams.activeTrade then
							entry.orderParams.activeTrade.sellPath = altPath
							entry.orderParams.activeTrade.sellPathName = t.destName
						end
					end
					t.cmdIssued = false
					t.aiRetryAt = Game.time + 1
					t.initialDist = nil
					addLog(entry.shipName, string.format("Diverting to orbital port %s.", t.destName), 0)
				else
					local destBody = (t.destPath and t.destPath:IsBodyPath() and Space.GetBody(t.destPath.bodyIndex)) or nil
					enterSafeHoldingOrbit(ship, destBody)
					entry.transit = nil
					entry.order = "IDLE"
					entry.status = "FLYING"
					entry.orderProgress = 0
					entry.orderEta = 0
					entry.orderPhase = "Holding orbit (unable to land at " .. (t.destName or "surface port") .. ")"
				end
			elseif ai_error and ai_error ~= "NONE" then
				t.cmdIssued = false
				t.aiRetryAt = Game.time + 5
			else
				t.cmdIssued = false
				t.aiRetryAt = Game.time + 1
			end
		elseif t.state == "CLEARING_MASS_LOCK" then
			t.cmdIssued = false
			t.aiRetryAt = Game.time + 2
			updateFleetTransit(entry)
		end
	elseif entry.order == "FOLLOW" then
		local rt = liveOrderRuntime[entry.uid]
		if ai_error == "REFUSED_PERM" and rt and rt.escortCmd == "DOCK" then
			rt.escortDockRetryAt = Game.time + 15
			rt.escortCmd = nil
			rt.escortTarget = nil
			local st = Game.player and Game.player:GetDockedWith()
			if st then
				enterSafeHoldingOrbit(ship, st)
			end
		else
			if rt then
				rt.escortCmd = nil
				rt.escortTarget = nil
			end
			updateEscortAI(entry)
		end
	elseif entry.order == "PATROL" then
		if liveOrderRuntime[entry.uid] then
			liveOrderRuntime[entry.uid].patrolTarget = nil
		end
		entry.orderParams.patrolWaypointAt = 0
		tickPatrol(entry)
	end
end)

Event.Register("onInterdictionDrop", function(attacker, victim, submitted)
	local entry = findEntryByLiveShip(victim)
	if not entry or entry.status == "DESTROYED" then return end
	if not attacker or not attacker:exists() or attacker == Game.player then return end
	local stance = PlayerFleet.GetDefenseOrder(entry)
	entry.stats = entry.stats or {}
	entry.stats.pirateEncounters = (entry.stats.pirateEncounters or 0) + 1
	local sysName = (Game.system and Game.system.name) or "local space"

	if stance == "SUBMIT" then
		local dropped = dropFleetCargoFraction(entry, 1.0)
		if victim.CancelAI then victim:CancelAI() end
		local msg = (dropped > 0)
			and string.format("Interdicted in %s [SUBMIT]: jettisoned %dt cargo.", sysName, dropped)
			or string.format("Interdicted in %s [SUBMIT]: complied with scan.", sysName)
		addLog(entry.shipName, msg, 0)
		Comms.ImportantMessage(string.format("%s: %s", entry.shipName, msg), entry.captain and entry.captain.name or "Fleet Captain")
	elseif stance == "DEFEND" then
		local prof = getShipDefenseProfile(entry)
		if prof.weaponCount > 0 and (entry.hullPercent or 100) > 18 then
			pcall(function() victim:AIKill(attacker) end)
			addLog(entry.shipName, string.format("Interdicted in %s [DEFEND]: engaging hostile %s.", sysName, attacker.label or "raider"), 0)
		else
			local st = findBestStationInSystem(Game.system, entry.locationPath)
			if st then
				local body = Space.GetBody(st.bodyIndex)
				if body then pcall(function() victim:AIDockWith(body) end) end
			end
		end
	else
		local dropped = dropFleetCargoFraction(entry, Engine.rand:Number(0.25, 0.50))
		local st = findBestStationInSystem(Game.system, entry.locationPath)
		if st then
			local body = Space.GetBody(st.bodyIndex)
			if body then pcall(function() victim:AIDockWith(body) end) end
		end
		if dropped > 0 then
			addLog(entry.shipName, string.format("Interdicted in %s [FLEE]: dropped %dt cargo while breaking away.", sysName, dropped), 0)
		end
	end
end)

Event.Register("onShipHit", function(ship, attacker)
	local entry = findEntryByLiveShip(ship)
	if not entry or entry.status == "DESTROYED" then return end
	if not attacker or not attacker:exists() or attacker == Game.player then return end
	if entry.order == "FOLLOW" or entry.order == "PATROL" then return end
	local stance = PlayerFleet.GetDefenseOrder(entry)
	if stance == "DEFEND" then
		local prof = getShipDefenseProfile(entry)
		if prof.weaponCount > 0 and (ship.hullPercent or 100) > 18 then
			if getShipAICommand(ship) ~= "CMD_KILL" then
				pcall(function() ship:AIKill(attacker) end)
			end
		end
	elseif stance == "FLEE" and (ship.hullPercent or 100) < 60 then
		if PlayerFleet.GetCargoUsed(entry) > 0 and Engine.rand:Number(0, 1) < 0.35 then
			dropFleetCargoFraction(entry, 0.35)
		end
	end
end)

Event.Register("onShipDestroyed", function(ship, attacker)
	for i, entry in ipairs(fleetState.ships or {}) do
		if entry.liveShip == ship then
			activeTradeScans[entry.uid] = nil
			entry.liveShip = nil
			entry.transit = nil
			local salvagePayout = entry.isCharterStarter and 0 or math.floor((ShipDef[entry.shipId] and ShipDef[entry.shipId].basePrice or 10000) * 0.5)
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
	fleetState = normalizeFleetState(fleetState)
	for _, entry in ipairs(fleetState.ships) do
		if entry.liveShip and type(entry.liveShip) == "userdata" and entry.liveShip:exists() then
			syncFromLiveShip(entry)
		else
			entry.liveShip = nil
		end
	end
	local now = Game.time or 0
	local cleanedSat = {}
	for sKey, stMap in pairs(fleetState.marketSaturation or {}) do
		if type(stMap) == "table" then
			local kept = {}
			for cname, rec in pairs(stMap) do
				if type(rec) == "table" and rec.netSupply then
					local dt = math.max(0, now - (rec.updatedAt or now))
					local decayed = rec.netSupply * (0.5 ^ (dt / SATURATION_HALF_LIFE_SEC))
					if math.abs(decayed) >= 1.0 then
						kept[cname] = { netSupply = decayed, updatedAt = now, stationName = rec.stationName }
					end
				end
			end
			if next(kept) ~= nil then
				cleanedSat[sKey] = kept
			end
		end
	end
	fleetState.marketSaturation = cleanedSat
	return {
		ships = fleetState.ships,
		nextUid = fleetState.nextUid,
		tradeBudget = fleetState.tradeBudget,
		totalProfit = fleetState.totalProfit,
		logs = fleetState.logs,
		marketSaturation = fleetState.marketSaturation,
	}
end, function(data)
	loaded_data = normalizeFleetState(data)
	fleetState = loaded_data
end)

return PlayerFleet

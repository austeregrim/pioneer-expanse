-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game = require 'Game'
local Space = require 'Space'
local Event = require 'Event'
local Timer = require 'Timer'
local Comms = require 'Comms'
local Serializer = require 'Serializer'
local PlayerState = require 'PlayerState'
local Lang = require 'Lang'

local l = Lang.GetResource("module-system")

---@class Cartography
local Cartography = {}

Cartography.MIN_SALE_DISTANCE_LY = 10.0

local DISCOVERY_CHARGE_TIME = 3.0

-- Persistent state (saved with game)
local state = {
	originallyUnexplored = {}, -- [systemKey] = true
	unsoldSystems = {},        -- [systemKey] = SystemRecord
	soldKeys = {},             -- [systemKey] = { discovery = bool, bodies = { [bodyKey] = { orbital = bool, surface = bool } } }
	stats = {
		systemsDiscovered = 0,
		orbitalScans = 0,
		surfaceScans = 0,
		totalEarned = 0,
	},
}

-- Transient scan charge state
local activeDiscovery = nil -- { systemKey, startTime, duration }

function Cartography.GetSystemKey(path)
	if not path then return nil end
	return string.format("%d,%d,%d,%d", path.sectorX, path.sectorY, path.sectorZ, path.systemIndex)
end

function Cartography.GetBodyKey(path)
	if not path then return nil end
	return string.format("%d,%d,%d,%d,%d", path.sectorX, path.sectorY, path.sectorZ, path.systemIndex, path.bodyIndex or 0)
end

function Cartography.HasDiscoveryScanner(ship)
	ship = ship or Game.player
	if not ship then return false end
	local equipSet = ship:GetComponent("EquipSet")
	if not equipSet then return false end
	local scanners = equipSet:GetInstalledOfType("sensor.discovery_scanner")
	return scanners and #scanners > 0
end

function Cartography.IsSystemOriginallyUnexplored(system)
	system = system or Game.system
	if not system then return false end
	local key = Cartography.GetSystemKey(system.path)
	if state.originallyUnexplored[key] then
		return true
	end
	return not system.explored
end

local function ensureSystemRecord(system)
	local key = Cartography.GetSystemKey(system.path)
	local rec = state.unsoldSystems[key]
	if not rec then
		local bodies = Space.GetBodies()
		local scannableCount = 0
		for _, b in ipairs(bodies) do
			local sb = b:GetSystemBody()
			if sb and sb.superType ~= "STARPORT" then
				scannableCount = scannableCount + 1
			end
		end
		rec = {
			key = key,
			systemPath = system.path,
			name = system.name,
			scannableCount = scannableCount,
			discovered = false,
			originallyUnexplored = Cartography.IsSystemOriginallyUnexplored(system),
			bodies = {},
		}
		state.unsoldSystems[key] = rec
	end
	return rec, key
end

local function getSoldRecord(key)
	local s = state.soldKeys[key]
	if not s then
		s = { discovery = false, bodies = {} }
		state.soldKeys[key] = s
	end
	return s
end

-- Base value by SystemBody properties (tiered: Earth-like/Life > Water/Terrestrial > Gas Giant > Rocky/Ice/Asteroid)
function Cartography.GetBodyBaseValue(sbody)
	if not sbody then return 500 end
	local t = sbody.type
	if t == "PLANET_TERRESTRIAL" then
		local life = sbody.life or 0
		local atmos = sbody.volatileGas or 0
		local water = sbody.volatileLiquid or 0
		if life > 0.1 then
			return 4500
		elseif water > 0.1 and atmos > 0.1 then
			return 2800
		elseif atmos > 0.05 then
			return 1800
		else
			return 950
		end
	elseif t == "PLANET_GAS_GIANT" then
		return 1100
	elseif t == "PLANET_ASTEROID" then
		return 400
	elseif sbody.superType == "STAR" then
		return 600
	end
	return 750
end

function Cartography.IsDiscoveryScanActive()
	return activeDiscovery ~= nil
end

function Cartography.GetDiscoveryScanProgress()
	if not activeDiscovery then return 0 end
	local elapsed = Game.time - activeDiscovery.startTime
	return math.min(1.0, math.max(0.0, elapsed / activeDiscovery.duration))
end

function Cartography.CanStartDiscoveryScan()
	if not Game.system or Game.InHyperspace() then return false, "HYPERSPACE" end
	if not Cartography.HasDiscoveryScanner(Game.player) then return false, "NO_SCANNER" end
	if Game.system.explored then return false, "ALREADY_EXPLORED" end
	if activeDiscovery then return false, "SCANNING" end
	return true
end

function Cartography.StartDiscoveryScan()
	local ok, reason = Cartography.CanStartDiscoveryScan()
	if not ok then return false, reason end

	local system = Game.system
	local key = Cartography.GetSystemKey(system.path)
	state.originallyUnexplored[key] = true

	activeDiscovery = {
		systemKey = key,
		system = system,
		startTime = Game.time,
		duration = DISCOVERY_CHARGE_TIME,
	}

	Comms.Message(l.GETTING_SENSOR_DATA)

	Timer:CallAt(Game.time + DISCOVERY_CHARGE_TIME, function()
		if not activeDiscovery or activeDiscovery.systemKey ~= key then
			return
		end
		activeDiscovery = nil
		if not Game.system or Cartography.GetSystemKey(Game.system.path) ~= key then
			return
		end

		local majorBodies = #Space.GetBodies("TerrainBody")
		local starports = #Space.GetBodies("SpaceStation")

		system:Explore()

		local sold = getSoldRecord(key)
		if not sold.discovery then
			local rec = ensureSystemRecord(system)
			rec.discovered = true
			state.stats.systemsDiscovered = state.stats.systemsDiscovered + 1
		end

		local bodiesLabel = (majorBodies == 1) and l.BODY or l.BODIES
		Comms.ImportantMessage(l.EXPLORED_SYSTEM:interp({ bodycount = majorBodies, bodies = bodiesLabel }))

		if starports > 0 then
			local basesLabel = (starports == 1) and l.BASE or l.BASES
			Comms.ImportantMessage(l.DISCOVERED_HIDDEN_BASES:interp({ portcount = starports, bases = basesLabel }))
		end

		Event.Queue("onSystemDiscovered", system)
	end)

	return true
end

local KNOWN_SYSTEM_PAYOUT_MULT = 0.20 -- 80% heavily reduced payout if system is already known to Universal Cartographics
local RESCAN_PAYOUT_MULT = 0.10       -- 90% reduced payout for routine update rescan of an already-sold body

function Cartography.RecordBodyScan(body, isOrbital)
	if not body or not Game.system then return false end

	local sbody = (body.GetSystemBody and body:GetSystemBody()) or (body.isa and body:isa("SystemBody") and body) or body
	if not sbody or not sbody.path then return false end

	local sysKey = Cartography.GetSystemKey(Game.system.path)
	local bodyKey = Cartography.GetBodyKey(sbody.path)

	local sold = getSoldRecord(sysKey)
	local soldBody = sold.bodies[bodyKey]
	local isRescan = false
	if soldBody then
		if (isOrbital and soldBody.orbital) or ((not isOrbital) and soldBody.surface) then
			isRescan = true
		end
	end

	local rec = ensureSystemRecord(Game.system)
	local isKnownSystem = not Cartography.IsSystemOriginallyUnexplored(Game.system)

	local bRec = rec.bodies[bodyKey]
	if not bRec then
		bRec = {
			key = bodyKey,
			name = body.label or sbody.name or "Unknown Body",
			baseValue = Cartography.GetBodyBaseValue(sbody),
			bodyType = sbody.type,
			orbital = false,
			surface = false,
			isKnownSystem = isKnownSystem,
			isRescan = isRescan,
		}
		rec.bodies[bodyKey] = bRec
	end

	if isKnownSystem then
		bRec.isKnownSystem = true
	end
	if isRescan then
		bRec.isRescan = true
	end

	if isOrbital and not bRec.orbital then
		bRec.orbital = true
		state.stats.orbitalScans = state.stats.orbitalScans + 1
	elseif (not isOrbital) and not bRec.surface then
		bRec.surface = true
		state.stats.surfaceScans = state.stats.surfaceScans + 1
	end

	Event.Queue("onCartographyScanRecorded", Game.system, body, isOrbital)
	return true
end

function Cartography.HasUnsoldScan(body, isOrbital)
	if not body or not Game.system then return false end
	local sbody = (body.GetSystemBody and body:GetSystemBody()) or (body.isa and body:isa("SystemBody") and body) or body
	if not sbody or not sbody.path then return false end
	local sysKey = Cartography.GetSystemKey(Game.system.path)
	local bodyKey = Cartography.GetBodyKey(sbody.path)

	local rec = state.unsoldSystems[sysKey]
	if rec and rec.bodies[bodyKey] then
		if isOrbital and rec.bodies[bodyKey].orbital then return true end
		if (not isOrbital) and rec.bodies[bodyKey].surface then return true end
	end
	return false
end

function Cartography.HasSoldScan(body, isOrbital)
	if not body or not Game.system then return false end
	local sbody = (body.GetSystemBody and body:GetSystemBody()) or (body.isa and body:isa("SystemBody") and body) or body
	if not sbody or not sbody.path then return false end
	local sysKey = Cartography.GetSystemKey(Game.system.path)
	local bodyKey = Cartography.GetBodyKey(sbody.path)

	local sold = state.soldKeys[sysKey]
	if sold and sold.bodies[bodyKey] then
		if isOrbital and sold.bodies[bodyKey].orbital then return true end
		if (not isOrbital) and sold.bodies[bodyKey].surface then return true end
	end
	return false
end

function Cartography.HasScannedBody(body, isOrbital)
	return Cartography.HasUnsoldScan(body, isOrbital) or Cartography.HasSoldScan(body, isOrbital)
end

local function computeSystemPayout(rec)
	local isKnownSys = not rec.originallyUnexplored
	local discoveryPay = (not isKnownSys and rec.discovered) and (250 + 120 * (rec.scannableCount or 0)) or 0
	local bodyTotal = 0
	local scannedBodies = 0
	local bodyList = {}

	for _, b in pairs(rec.bodies) do
		local mult = 1.0
		if b.isRescan then
			mult = RESCAN_PAYOUT_MULT
		elseif b.isKnownSystem or isKnownSys then
			mult = KNOWN_SYSTEM_PAYOUT_MULT
		end

		local effectiveBase = math.max(50, math.floor(b.baseValue * mult))
		local orbPay = b.orbital and (effectiveBase * 2) or 0
		local surfPay = b.surface and (effectiveBase * 5) or 0
		local sub = orbPay + surfPay
		if sub > 0 then
			scannedBodies = scannedBodies + 1
			bodyTotal = bodyTotal + sub
			table.insert(bodyList, {
				key = b.key,
				name = b.name,
				bodyType = b.bodyType,
				orbital = b.orbital,
				surface = b.surface,
				orbitalPay = orbPay,
				surfacePay = surfPay,
				totalPay = sub,
				isKnownSystem = b.isKnownSystem or isKnownSys,
				isRescan = b.isRescan,
			})
		end
	end

	table.sort(bodyList, function(a, b) return a.totalPay > b.totalPay end)

	local fullSystemBonus = 0
	local isFullSystem = (not isKnownSys) and (rec.scannableCount or 0) > 0 and scannedBodies >= rec.scannableCount
	if isFullSystem then
		fullSystemBonus = math.floor((discoveryPay + bodyTotal) * 0.25)
	end

	local currentSys = Game.system
	local dist = 0.0
	if currentSys and rec.systemPath then
		dist = currentSys:DistanceTo(rec.systemPath)
	end
	local isEligibleDistance = (dist >= Cartography.MIN_SALE_DISTANCE_LY)

	local total = discoveryPay + bodyTotal + fullSystemBonus
	return {
		key = rec.key,
		name = rec.name,
		systemPath = rec.systemPath,
		discovered = rec.discovered and not isKnownSys,
		discoveryPay = discoveryPay,
		scannableCount = rec.scannableCount or 0,
		scannedCount = scannedBodies,
		isFullSystem = isFullSystem,
		fullSystemBonus = fullSystemBonus,
		isKnownSystem = isKnownSys,
		bodies = bodyList,
		totalPay = total,
		distance = dist,
		isEligibleDistance = isEligibleDistance,
	}
end

function Cartography.GetUnsoldList()
	local list = {}
	for _, rec in pairs(state.unsoldSystems) do
		local item = computeSystemPayout(rec)
		if item.totalPay > 0 then
			table.insert(list, item)
		end
	end
	table.sort(list, function(a, b) return a.totalPay > b.totalPay end)
	return list
end

function Cartography.GetTotalUnsoldValue()
	local total = 0
	local eligibleTotal = 0
	for _, rec in pairs(state.unsoldSystems) do
		local item = computeSystemPayout(rec)
		total = total + item.totalPay
		if item.isEligibleDistance then
			eligibleTotal = eligibleTotal + item.totalPay
		end
	end
	return total, eligibleTotal
end

function Cartography.SellSystem(sysKey)
	local rec = state.unsoldSystems[sysKey]
	if not rec then return 0, "No data found" end

	local payout = computeSystemPayout(rec)
	if payout.totalPay <= 0 then return 0, "No survey value" end
	if not payout.isEligibleDistance then
		return 0, string.format("Too close to station (%.1f ly / min %.1f ly required)", payout.distance, Cartography.MIN_SALE_DISTANCE_LY)
	end

	local sold = getSoldRecord(sysKey)
	if rec.discovered then
		sold.discovery = true
	end
	for bKey, b in pairs(rec.bodies) do
		local sb = sold.bodies[bKey]
		if not sb then
			sb = { orbital = false, surface = false }
			sold.bodies[bKey] = sb
		end
		if b.orbital then sb.orbital = true end
		if b.surface then sb.surface = true end
	end

	local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')
	local isHomeStation = false
	local currentStation = Game.player and Game.player:GetDockedWith()
	if okTax and TaxAuthority and TaxAuthority.IsHomeStation then
		isHomeStation = TaxAuthority.IsHomeStation(currentStation)
	end

	local actualPayout = payout.totalPay
	if isHomeStation then
		-- Home University Grant: +10% academic research bonus!
		actualPayout = math.floor(actualPayout * 1.10)
	end

	state.unsoldSystems[sysKey] = nil
	state.stats.totalEarned = state.stats.totalEarned + actualPayout
	PlayerState.AddMoney(actualPayout)

	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	local okFormat, Format = pcall(require, 'Format')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		local formatMoney = (okFormat and Format and Format.Money) or function(v) return tostring(v) .. " Cr" end
		FlightLog.RecordTransaction({
			category = "CARTOGRAPHY",
			title = string.format("Cartographic Survey Sale: %s (+%s)", payout.systemName, formatMoney(actualPayout)),
			amount = actualPayout,
			details = {
				{ "Surveyed Star System", payout.systemName },
				{ "Bodies Scanned", string.format("%d bodies", payout.bodyCount or 0) },
				{ "Distance from Target", string.format("%.1f ly", payout.distanceLy or 0) },
				{ "Gross Sale Proceeds", formatMoney(actualPayout) },
			},
			note = string.format("Transferred orbital scan data for %s to Universal Cartographics.", payout.systemName)
		})
	end

	if okTax and TaxAuthority and TaxAuthority.RecordCartographyIncome then
		TaxAuthority.RecordCartographyIncome(actualPayout, isHomeStation)
	end

	Event.Queue("onCartographyDataSold", actualPayout, { payout })
	return actualPayout
end

function Cartography.SellAll()
	local total = 0
	local soldItems = {}
	local keys = {}
	for k, rec in pairs(state.unsoldSystems) do
		local item = computeSystemPayout(rec)
		if item.isEligibleDistance and item.totalPay > 0 then
			table.insert(keys, k)
		end
	end
	for _, k in ipairs(keys) do
		local rec = state.unsoldSystems[k]
		local item = computeSystemPayout(rec)
		local earned = Cartography.SellSystem(k)
		if earned > 0 then
			total = total + earned
			table.insert(soldItems, item)
		end
	end
	return total, soldItems
end

function Cartography.GetStats()
	return state.stats
end

local function onEnterSystem()
	activeDiscovery = nil
	if Game.system and not Game.system.explored then
		local key = Cartography.GetSystemKey(Game.system.path)
		state.originallyUnexplored[key] = true
	end
end

local function onLeaveSystem()
	activeDiscovery = nil
end

local function onGameStart()
	activeDiscovery = nil
	if Game.system and not Game.system.explored then
		local key = Cartography.GetSystemKey(Game.system.path)
		state.originallyUnexplored[key] = true
	end
end

Event.Register("onEnterSystem", onEnterSystem)
Event.Register("onLeaveSystem", onLeaveSystem)
Event.Register("onGameStart", onGameStart)
Event.Register("onDiscoveryScanRequested", function()
	local ok, reason = Cartography.StartDiscoveryScan()
	if not ok then
		if reason == "NO_SCANNER" then
			Comms.Message("System Discovery Scanner not equipped.")
		elseif reason == "ALREADY_EXPLORED" then
			Comms.Message("Star system is already charted.")
		end
	end
end)

Serializer:Register("Cartography",
	function() return state end,
	function(data)
		if data then
			state = data
			state.originallyUnexplored = state.originallyUnexplored or {}
			state.unsoldSystems = state.unsoldSystems or {}
			state.soldKeys = state.soldKeys or {}
			state.stats = state.stats or { systemsDiscovered = 0, orbitalScans = 0, surfaceScans = 0, totalEarned = 0 }
		end
	end
)

return Cartography

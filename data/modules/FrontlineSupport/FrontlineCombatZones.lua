-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Comms           = require 'Comms'
local Engine          = require 'Engine'
local Event           = require 'Event'
local FactionRoles    = require 'FactionRoles'
local Format          = require 'Format'
local Game            = require 'Game'
local PlayerState     = require 'PlayerState'
local Serializer      = require 'Serializer'
local Space           = require 'Space'
local Timer           = require 'Timer'

local MissionUtils    = require 'modules.MissionUtils'
local ShipBuilder     = require 'modules.MissionUtils.ShipBuilder'

local FrontlineCombatZones = {}

local MAX_FRIENDLIES = 4
local MAX_HOSTILES = 4
local MAX_WAVES = 2
local MAX_CRISIS_PROGRESS_PER_SORTIE = 15.0
local ENGAGE_SURFACE_DIST = 150000 -- 150 km from anchor body surface
local MIN_STATION_SAFE_DIST = 20000 -- 20 km clear of stations

-- Serialized state (never store live Ship userdata here)
local pendingBonds = {}
local loaded_data = nil

-- Transient system-local state
local activeZone = nil
local czHostiles = {}
local czFriendlies = {}
local pollerActive = false
local lastZoneCheckTime = 0

local function countLiveEntries(tbl)
	local count = 0
	local list = {}
	for ship, val in pairs(tbl) do
		if ship and type(ship) == "userdata" and ship:exists() then
			count = count + 1
			table.insert(list, ship)
		else
			tbl[ship] = nil
		end
	end
	return count, list
end

local function clearTransientZoneShips()
	czHostiles = {}
	czFriendlies = {}
	if activeZone then
		activeZone.spawned = false
	end
end

local function clearAllTransientState()
	activeZone = nil
	czHostiles = {}
	czFriendlies = {}
	pollerActive = false
	lastZoneCheckTime = 0
end

local function getMacroCrisis(systemName)
	if not systemName then return nil end
	local okMacro, MacroGalaxyEngine = pcall(require, 'modules.MacroGalaxy.MacroGalaxyEngine')
	if okMacro and MacroGalaxyEngine and MacroGalaxyEngine.GetCrisisForSystem then
		return MacroGalaxyEngine.GetCrisisForSystem(systemName)
	end
	return nil
end

local function contributeMacroCrisis(systemName, delta)
	if not systemName or not delta or delta <= 0 then return false end
	local okMacro, MacroGalaxyEngine = pcall(require, 'modules.MacroGalaxy.MacroGalaxyEngine')
	if okMacro and MacroGalaxyEngine and MacroGalaxyEngine.ContributeToCrisis then
		return MacroGalaxyEngine.ContributeToCrisis(systemName, delta)
	end
	return false
end

local function pickCombatZoneAnchor()
	local planets = Space.GetBodies("Planet")
	if not planets or #planets == 0 then return nil, nil end

	local stations = Space.GetBodies("SpaceStation") or {}
	local preferred = {}
	local fallback = {}

	for _, body in ipairs(planets) do
		if body and body:exists() then
			local safeFromStations = true
			for _, st in ipairs(stations) do
				if st and st:exists() and body:DistanceTo(st) <= MIN_STATION_SAFE_DIST then
					safeFromStations = false
					break
				end
			end
			if safeFromStations then
				table.insert(preferred, body)
			else
				table.insert(fallback, body)
			end
		end
	end

	local pool = (#preferred > 0) and preferred or fallback
	if #pool == 0 then return nil, nil end

	-- Prefer an outer/secondary body when multiple safe bodies exist so arrival lanes stay clear
	local chosen = (#pool > 1) and pool[math.min(#pool, 2)] or pool[1]
	return chosen, chosen.label or "Contested Planet"
end

local function evaluateSystemZone()
	if activeZone then return end
	if not Game.system or Game.InHyperspace() then return end

	local sysName = Game.system.name
	local crisis = getMacroCrisis(sysName)
	if not crisis then return end
	if crisis.category ~= "FRONTLINE" then return end
	if crisis.type ~= "INSURGENCY" and crisis.type ~= "BLOCKADE" then return end
	if (crisis.severity or 1) < 2 then return end

	local sysFaction = (Game.system.faction and Game.system.faction.name) or nil
	if not sysFaction or FactionRoles.IsStatelessFaction(sysFaction) then return end

	local anchorBody, anchorName = pickCombatZoneAnchor()
	if not anchorBody then return end

	activeZone = {
		systemName = sysName,
		factionName = sysFaction,
		crisisType = crisis.type,
		severity = crisis.severity or 2,
		anchorBody = anchorBody,
		anchorName = anchorName,
		spawned = false,
		wavesSpawned = 0,
		killsThisSortie = 0,
		crisisProgressThisSortie = 0,
		advised = true,
	}

	Comms.Message(
		string.format("TACTICAL ADVISORY: Contested Naval Zone detected near %s. Combat participation optional.", anchorName),
		sysFaction .. " Naval Command"
	)
end

local function assignSkirmishTargets(friendliesList, hostilesList)
	if #hostilesList == 0 then return end
	for i, fShip in ipairs(friendliesList) do
		if fShip and fShip:exists() then
			local target = hostilesList[((i - 1) % #hostilesList) + 1]
			if target and target:exists() then
				pcall(function() fShip:AIKill(target) end)
			end
		end
	end
	for i, hShip in ipairs(hostilesList) do
		if hShip and hShip:exists() then
			local target = (#friendliesList > 0)
				and friendliesList[((i - 1) % #friendliesList) + 1]
				or Game.player
			if target and target:exists() then
				pcall(function() hShip:AIKill(target) end)
			end
		end
	end
end

local function trySpawnOrReinforceWave()
	if not activeZone then return end
	if not Game.system or Game.InHyperspace() then return end
	if not Game.player or not Game.player:exists() then return end
	if Game.player:GetFlightState() ~= "FLYING" then return end
	if Game.player.IsSupercruiseActive and Game.player:IsSupercruiseActive() then return end
	if not activeZone.anchorBody or not activeZone.anchorBody:exists() then return end

	local radius = activeZone.anchorBody:GetPhysicalRadius() or 0
	local surfDist = Game.player:DistanceTo(activeZone.anchorBody) - radius
	if surfDist > ENGAGE_SURFACE_DIST then return end

	local nearestStation = Game.player:FindNearestTo("SPACESTATION")
	if nearestStation and nearestStation:exists() and Game.player:DistanceTo(nearestStation) <= MIN_STATION_SAFE_DIST then
		return
	end

	local friendlyCount, friendliesList = countLiveEntries(czFriendlies)
	local hostileCount, hostilesList = countLiveEntries(czHostiles)

	local waves = activeZone.wavesSpawned or 0
	if waves >= MAX_WAVES then
		assignSkirmishTargets(friendliesList, hostilesList)
		return
	end
	if waves == 1 and hostileCount > 1 then
		return
	end

	local wantFriendlies = math.max(0, math.min(MAX_FRIENDLIES - friendlyCount, (waves == 0) and 3 or 2))
	local wantHostiles = math.max(0, math.min(MAX_HOSTILES - hostileCount, (waves == 0) and 3 or 3))
	if wantFriendlies == 0 and wantHostiles == 0 then return end

	local baseThreat = (activeZone.severity >= 3) and 38.0 or 26.0
	local policeShipId = Game.system.faction and Game.system.faction.policeShip or nil

	local friendlyTemplate = MissionUtils.ShipTemplates.PolicePatrol:clone {
		shipId = policeShipId,
		label = activeZone.factionName .. " Defense Wing",
	}
	local hostileLabel = (activeZone.crisisType == "BLOCKADE") and "Blockade Enforcer" or "Insurgent Raider"
	local hostileTemplate = MissionUtils.ShipTemplates.GenericPirate:clone {
		label = hostileLabel,
	}

	for _ = 1, wantFriendlies do
		local threat = math.clamp(baseThreat + Engine.rand:Number(-6, 8), 15, 60)
		local okSpawn, ship = pcall(ShipBuilder.MakeShipNear, Game.player, friendlyTemplate, threat, 6, 14)
		if (not okSpawn or not ship) and policeShipId then
			local fallbackTpl = MissionUtils.ShipTemplates.PolicePatrol:clone {
				label = activeZone.factionName .. " Defense Wing",
			}
			okSpawn, ship = pcall(ShipBuilder.MakeShipNear, Game.player, fallbackTpl, threat, 6, 14)
		end
		if okSpawn and ship and ship:exists() then
			czFriendlies[ship] = true
			table.insert(friendliesList, ship)
		end
	end

	for _ = 1, wantHostiles do
		local threat = math.clamp(baseThreat + Engine.rand:Number(-5, 12), 16, 65)
		local okSpawn, ship = pcall(ShipBuilder.MakeShipNear, Game.player, hostileTemplate, threat, 8, 15)
		if okSpawn and ship and ship:exists() then
			local bondVal = math.clamp(math.floor(3500 + threat * 170 + 0.5), 3500, 12000)
			czHostiles[ship] = {
				factionName = activeZone.factionName,
				bondValue   = bondVal,
				crisisType  = activeZone.crisisType,
			}
			table.insert(hostilesList, ship)
		end
	end

	activeZone.wavesSpawned = waves + 1
	activeZone.spawned = true
	assignSkirmishTargets(friendliesList, hostilesList)
end

local function ensureZonePoller()
	if pollerActive then return end
	if not Game.system or Game.InHyperspace() then return end

	pollerActive = true
	lastZoneCheckTime = Game.time or 0
	Timer:CallEvery(5, function()
		if not Game.system or Game.InHyperspace() or not Game.player or not Game.player:exists() then
			pollerActive = false
			return true
		end

		local now = Game.time or 0
		if not activeZone and (now - lastZoneCheckTime) >= 10 then
			lastZoneCheckTime = now
			evaluateSystemZone()
		end

		if activeZone then
			trySpawnOrReinforceWave()
		end

		return false
	end)
end

local function isPlayerOrAlliedEscort(attacker)
	if not attacker or type(attacker) ~= "userdata" then return false end
	if attacker:isa("Ship") and attacker:IsPlayer() then
		return true
	end
	local okPF, PlayerFleet = pcall(require, 'modules.PlayerFleet.PlayerFleet')
	if okPF and PlayerFleet and PlayerFleet.GetShips then
		for _, entry in ipairs(PlayerFleet.GetShips()) do
			if entry.liveShip and entry.liveShip == attacker then
				return true
			end
		end
	end
	return false
end

local function onShipDestroyed(ship, attacker)
	if not ship then return end
	if czFriendlies[ship] then
		czFriendlies[ship] = nil
	end

	local info = czHostiles[ship]
	if not info then return end
	czHostiles[ship] = nil

	if isPlayerOrAlliedEscort(attacker) then
		local factionName = info.factionName
		local bondValue = info.bondValue or 3500
		if factionName then
			pendingBonds[factionName] = (pendingBonds[factionName] or 0) + bondValue
		end

		if activeZone then
			activeZone.killsThisSortie = (activeZone.killsThisSortie or 0) + 1
			local remCap = math.max(0, MAX_CRISIS_PROGRESS_PER_SORTIE - (activeZone.crisisProgressThisSortie or 0))
			local delta = math.min(2.5, remCap)
			if delta > 0 then
				contributeMacroCrisis(activeZone.systemName, delta)
				activeZone.crisisProgressThisSortie = (activeZone.crisisProgressThisSortie or 0) + delta
			end
		end

		if factionName and FactionRoles.IsEnlisted(factionName) then
			pcall(FactionRoles.AddMilitaryXP, factionName, 15, 0, "Combat Zone victory")
		end

		Comms.Message(
			string.format("+%s Combat Bond awarded (Redeem at any %s station).",
				Format.Money(bondValue, false), factionName or "Faction"),
			"Naval Command"
		)
	end
end

local function onEnterSystem()
	clearAllTransientState()
	evaluateSystemZone()
	ensureZonePoller()
end

local function onLeaveSystem()
	clearAllTransientState()
end

local function onPlayerDocked(player)
	if player and player:IsPlayer() then
		clearTransientZoneShips()
	end
end

local function onGameStart()
	clearAllTransientState()
	if loaded_data then
		pendingBonds = loaded_data.pendingBonds or {}
		loaded_data = nil
	end
	evaluateSystemZone()
	ensureZonePoller()
end

local function onGameEnd()
	clearAllTransientState()
	pendingBonds = {}
	loaded_data = nil
end

-- Public API

function FrontlineCombatZones.IsHostileTarget(ship)
	if not ship then return false, nil end
	local info = czHostiles[ship]
	if not info then return false, nil end
	if type(ship) ~= "userdata" or not ship:exists() then
		czHostiles[ship] = nil
		return false, nil
	end
	return true, info.factionName
end

function FrontlineCombatZones.GetZoneSummary()
	if not activeZone then
		return {
			active = false,
			systemName = Game.system and Game.system.name or nil,
			factionName = nil,
			crisisType = nil,
			friendlyCount = 0,
			hostileCount = 0,
			killsThisSortie = 0,
		}
	end
	local friendlyCount = countLiveEntries(czFriendlies)
	local hostileCount = countLiveEntries(czHostiles)
	return {
		active = true,
		systemName = activeZone.systemName,
		factionName = activeZone.factionName,
		crisisType = activeZone.crisisType,
		friendlyCount = friendlyCount,
		hostileCount = hostileCount,
		killsThisSortie = activeZone.killsThisSortie or 0,
	}
end

function FrontlineCombatZones.GetPendingBonds(factionName)
	if not factionName then return 0 end
	return pendingBonds[factionName] or 0
end

function FrontlineCombatZones.GetAllPendingBonds()
	local list = {}
	for factionName, amount in pairs(pendingBonds) do
		if (amount or 0) > 0 then
			table.insert(list, { factionName = factionName, amount = amount })
		end
	end
	table.sort(list, function(a, b) return a.factionName < b.factionName end)
	return list
end

function FrontlineCombatZones.RedeemBonds(factionName)
	if not factionName then
		return 0, "Invalid faction."
	end
	local amount = pendingBonds[factionName] or 0
	if amount <= 0 then
		return 0, "No pending Combat Bonds for " .. factionName .. "."
	end

	PlayerState.AddMoney(amount)
	pendingBonds[factionName] = nil

	local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')
	if okTax and TaxAuthority and TaxAuthority.RecordOperationsIncome then
		pcall(TaxAuthority.RecordOperationsIncome, "COMBAT_BOND", amount, 0, factionName .. " Combat Bonds", Game.time)
	end

	local okLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okLog and FlightLog and FlightLog.RecordTransaction then
		pcall(FlightLog.RecordTransaction, {
			category = "BOUNTY",
			title = "Combat Bonds (" .. factionName .. ")",
			amount = amount,
			details = { { "Faction", factionName } },
			note = "Naval Combat Zone bonds redeemed",
		})
	end

	return amount, nil
end

Event.Register("onEnterSystem", onEnterSystem)
Event.Register("onLeaveSystem", onLeaveSystem)
Event.Register("onShipDestroyed", onShipDestroyed)
Event.Register("onPlayerDocked", onPlayerDocked)
Event.Register("onGameStart", onGameStart)
Event.Register("onGameEnd", onGameEnd)

Serializer:Register("FrontlineCombatZonesDB", function()
	return { pendingBonds = pendingBonds }
end, function(data)
	loaded_data = data
end)

return FrontlineCombatZones

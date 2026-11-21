-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

-- Persistent regional vessel, registration ID, commander, and casualty registry.
-- Ensures globally unique non-reusable extended registration IDs (e.g. GR-48291K),
-- keeps local & regional vessels coherent within ~32 ly corridors of their home port,
-- tracks hangar residents across time advancement, and logs permanent vessel losses.

local Engine     = require 'Engine'
local Event      = require 'Event'
local Game       = require 'Game'
local NameGen    = require 'NameGen'
local Serializer = require 'Serializer'
local Ship       = require 'Ship'
local ShipDef    = require 'ShipDef'
local Space      = require 'Space'
local ModelSkin  = require 'SceneGraph.ModelSkin'

local ShipRegistry = {}

local SERIAL_SUFFIX_LETTERS = "ABCDEFGHJKLMNPQRSTUVWXYZ"
local MAX_CASUALTIES = 500
local CORRIDOR_RANGE_LY = 32.0

local VESSEL_PREFIXES = {
	TRADER    = { "MSV", "CSV", "FTV", "GCV" },
	FREIGHT   = { "FTV", "CSV", "MSV" },
	PASSENGER = { "PTV", "SLV", "CSV" },
	COURIER   = { "CDV", "FDT", "MSV" },
	MINER     = { "OSV", "MRV", "ISV" },
	POLICE    = { "Patrol Unit", "Interceptor", "Warden", "Aegis" },
}

local COMMERCIAL_NAMES = {
	"Alderney", "Meridian", "Borealis", "Caldera", "Valiant", "Tamarack",
	"Bellwether", "Kepler", "Solstice", "Pelagic", "Magellan", "Venture",
	"Coriolis", "Halcyon", "Caspian", "Vanguard", "Antares", "Sovereign",
	"Caledonia", "Arcturus", "Caravel", "Triton", "Atlas", "Polaris",
	"Orion", "Endurance", "Argonaut", "Concordia", "Adriatic", "Albatross",
	"Osprey", "Horizon", "Alcyone", "Kestrel", "Archimedes", "Kuroshio",
	"Corsica", "Tycho", "Copernicus", "Vega Star", "Nordic", "Baffin",
	"Cordillera", "Ceres Run", "Rigel Dawn", "Calypso", "Zephyrus", "Astrolabe",
	"Bering", "Erebus", "Helios", "Hyperion", "Iberia", "Juno",
}

local PASSENGER_NAMES = {
	"Grandeur", "Olympia", "Celestia", "Elysium", "Majestic", "Aurora",
	"Constellation", "Aurelia", "Odyssey", "Clarion", "Sterling", "Pacific",
	"Serenity", "Solarium", "Monarch", "Crown Meridian", "Vespera", "Lumina",
}

local MINER_NAMES = {
	"Basalt", "Deepcore", "Prospector", "Brimstone", "Silica", "Ferrous",
	"Cairn", "Bedrock", "Cobalt", "Calcite", "Granite", "Dredger",
	"Excavator", "Sluice", "Anvil", "Quarry", "Tellurium", "Orehound",
}

local COURIER_NAMES = {
	"Swift", "Arrow", "Mercury", "Dart", "Falcon", "Relay",
	"Quicksilver", "Viper", "Zephyr", "Clipper", "Kite", "Peregrine",
}

local PIRATE_NAMES = {
	"Blackwake", "Crimson Jackal", "Voidrunner", "Redwake", "Ironclad",
	"Razorback", "Nightjar", "Gallowglass", "Ashwinder", "Manticore",
	"Cutlass", "Scythe", "Shrike", "Marauder", "Harpy", "Deadlight",
	"Corsair", "Banshee", "Vulture", "Bloodhound", "Grimalkin", "Skua",
}

local state = nil
local liveLabels = {}
local loaded_data = nil

local function ensureState()
	if not state then
		state = {
			usedLabels = {},
			ships = {},
			systemRosters = {},
			casualties = {},
			lastReplacementCheck = 0,
		}
	end
	state.usedLabels = state.usedLabels or {}
	state.ships = state.ships or {}
	state.systemRosters = state.systemRosters or {}
	state.casualties = state.casualties or {}
	return state
end

function ShipRegistry.SystemKey(path)
	if not path then return nil end
	if type(path) == "string" then return path end
	return string.format("%d,%d,%d,%d", path.sectorX or 0, path.sectorY or 0, path.sectorZ or 0, path.systemIndex or 0)
end

function ShipRegistry.RegisterUsedLabel(label)
	if not label or label == "" then return end
	local s = ensureState()
	s.usedLabels[label] = true
end

function ShipRegistry.AllocateUniqueLabel(shipId, role)
	local s = ensureState()
	local prefix = Ship.GetRegistrationPrefix(shipId, role)
	for _ = 1, 128 do
		local num = Engine.rand:Integer(0, 99999)
		local idx = Engine.rand:Integer(1, #SERIAL_SUFFIX_LETTERS)
		local candidate = string.format("%s-%05d%s", prefix, num, SERIAL_SUFFIX_LETTERS:sub(idx, idx))
		if not s.usedLabels[candidate] then
			s.usedLabels[candidate] = true
			return candidate
		end
	end
	for _ = 1, 128 do
		local num = Engine.rand:Integer(0, 999999)
		local i1 = Engine.rand:Integer(1, #SERIAL_SUFFIX_LETTERS)
		local i2 = Engine.rand:Integer(1, #SERIAL_SUFFIX_LETTERS)
		local candidate = string.format("%s-%06d%s%s", prefix, num, SERIAL_SUFFIX_LETTERS:sub(i1, i1), SERIAL_SUFFIX_LETTERS:sub(i2, i2))
		if not s.usedLabels[candidate] then
			s.usedLabels[candidate] = true
			return candidate
		end
	end
	return string.format("%s-%06dX", prefix, Engine.rand:Integer(0, 999999))
end

Ship.SetLabelAllocator(function(shipId, role)
	return ShipRegistry.AllocateUniqueLabel(shipId, role)
end)

local function rollCommander(role)
	local isFemale = Engine.rand:Integer(0, 1) == 1
	local ok, fn, sn = pcall(NameGen.Names, isFemale, Engine.rand)
	local baseName = (ok and fn and sn) and (fn .. " " .. sn) or "Alex Mercer"

	local title = "Capt."
	if role == "POLICE" then
		local ranks = { "Lt.", "Sgt.", "Insp.", "Off." }
		title = ranks[Engine.rand:Integer(1, #ranks)]
	elseif role == "COURIER" then
		title = "Cmdr."
	elseif role == "PIRATE" then
		title = (Engine.rand:Number(1) < 0.4) and "Capt." or ""
	else
		title = (Engine.rand:Number(1) < 0.55) and "Capt." or "Cmdr."
	end

	local fullName = (title ~= "") and (title .. " " .. baseName) or baseName
	return fullName, title
end

local function isShipNameUsed(candidate)
	local s = ensureState()
	for _, rec in pairs(s.ships) do
		if rec.shipName == candidate and rec.status ~= "DESTROYED" then
			return true
		end
	end
	return false
end

local function rollVesselName(role)
	local name
	if role == "POLICE" then
		local prefixes = VESSEL_PREFIXES.POLICE
		name = string.format("%s %02d", prefixes[Engine.rand:Integer(1, #prefixes)], Engine.rand:Integer(1, 99))
	elseif role == "PIRATE" then
		name = PIRATE_NAMES[Engine.rand:Integer(1, #PIRATE_NAMES)]
	elseif role == "MINER" then
		local p = VESSEL_PREFIXES.MINER
		name = p[Engine.rand:Integer(1, #p)] .. " " .. MINER_NAMES[Engine.rand:Integer(1, #MINER_NAMES)]
	elseif role == "PASSENGER" then
		local p = VESSEL_PREFIXES.PASSENGER
		name = p[Engine.rand:Integer(1, #p)] .. " " .. PASSENGER_NAMES[Engine.rand:Integer(1, #PASSENGER_NAMES)]
	elseif role == "COURIER" then
		local p = VESSEL_PREFIXES.COURIER
		name = p[Engine.rand:Integer(1, #p)] .. " " .. COURIER_NAMES[Engine.rand:Integer(1, #COURIER_NAMES)]
	else
		local p = VESSEL_PREFIXES.TRADER
		name = p[Engine.rand:Integer(1, #p)] .. " " .. COMMERCIAL_NAMES[Engine.rand:Integer(1, #COMMERCIAL_NAMES)]
	end

	if isShipNameUsed(name) then
		local numerals = { "II", "III", "IV", "V", "VI" }
		for _, n in ipairs(numerals) do
			local candidate = name .. " " .. n
			if not isShipNameUsed(candidate) then
				return candidate
			end
		end
		return string.format("%s-%02d", name, Engine.rand:Integer(10, 99))
	end
	return name
end

local function rollSkinAndPattern(shipId, role)
	if role == "POLICE" then
		return {
			{ 24, 38, 68, 255 },
			{ 225, 232, 240, 255 },
			{ 45, 130, 220, 255 },
		}, 0
	end

	local packed = nil
	local skin = ModelSkin.New():SetRandomColors(Engine.rand)
	local cols = skin and skin:GetColors()
	if cols and #cols >= 3 then
		packed = {}
		for i = 1, 3 do
			local c = cols[i]
			packed[i] = { c.r or 180, c.g or 180, c.b or 180, c.a or 255 }
		end
	end

	local pattern = 0
	local def = shipId and ShipDef[shipId]
	if def and def.modelName then
		local ok, model = pcall(Engine.GetModel, def.modelName)
		if ok and model and (model.numPatterns or 0) > 0 then
			pattern = Engine.rand:Integer(0, model.numPatterns - 1)
		end
	end

	return packed, pattern
end

local function classifyRoleFromShipId(shipId, defaultRole)
	if defaultRole then return defaultRole end
	local def = shipId and ShipDef[shipId]
	local sc = def and def.shipClass or ""
	if shipId == "dsminer" then return "MINER" end
	if shipId and string.find(shipId, "_police$") then return "POLICE" end
	if string.find(sc, "passenger") then return "PASSENGER" end
	if string.find(sc, "courier") then return "COURIER" end
	return "TRADER"
end

local function collectRouteSystems(system)
	local sKey = ShipRegistry.SystemKey(system.path)
	local keys = { sKey }
	local ok, nearby = pcall(function()
		return system:GetNearbySystems(CORRIDOR_RANGE_LY, function(s)
			return (s.population or 0) > 0 and #(s:GetStationPaths() or {}) > 0
		end)
	end)
	if ok and nearby and #nearby > 0 then
		local count = math.min(#nearby, Engine.rand:Integer(2, 4))
		local picked = {}
		for _ = 1, count * 2 do
			if #keys >= 1 + count then break end
			local idx = Engine.rand:Integer(1, #nearby)
			if not picked[idx] then
				picked[idx] = true
				local nKey = ShipRegistry.SystemKey(nearby[idx].path)
				if nKey and nKey ~= sKey then
					table.insert(keys, nKey)
				end
			end
		end
	end
	return keys
end

local function commissionShip(system, shipId, role, homeStationBodyIdx, homeStationName)
	local s = ensureState()
	role = classifyRoleFromShipId(shipId, role)
	local label = ShipRegistry.AllocateUniqueLabel(shipId, role)
	local shipName = rollVesselName(role)
	local commanderName, commanderTitle = rollCommander(role)
	local skinColors, pattern = rollSkinAndPattern(shipId, role)
	local sysKey = system and ShipRegistry.SystemKey(system.path) or nil
	local sysName = system and system.name or "Unknown Sector"
	local routeKeys = system and collectRouteSystems(system) or {}

	local rec = {
		label = label,
		shipName = shipName,
		shipId = shipId,
		role = role,
		commanderName = commanderName,
		commanderTitle = commanderTitle,
		homeSystemKey = sysKey,
		homeSystemName = sysName,
		homeStationBodyIdx = homeStationBodyIdx,
		homeStationName = homeStationName,
		routeSystemKeys = routeKeys,
		skinColors = skinColors,
		pattern = pattern,
		status = "ACTIVE",
		locationSystemKey = sysKey,
		locationStationBodyIdx = homeStationBodyIdx,
		hangarUntil = 0,
		lastSeenTime = Game.time or 0,
	}

	s.ships[label] = rec
	if sysKey then
		s.systemRosters[sysKey] = s.systemRosters[sysKey] or {}
		table.insert(s.systemRosters[sysKey], label)
	end
	return rec
end

local function pickShipIdForRole(role, acceptableShipIds)
	if acceptableShipIds and #acceptableShipIds > 0 then
		local matching = {}
		for _, id in ipairs(acceptableShipIds) do
			if classifyRoleFromShipId(id) == role then
				table.insert(matching, id)
			end
		end
		if #matching > 0 then
			return matching[Engine.rand:Integer(1, #matching)]
		end
		return acceptableShipIds[Engine.rand:Integer(1, #acceptableShipIds)]
	end

	local fallbackPool = {}
	for id, def in pairs(ShipDef) do
		if def.tag == 'SHIP' and (def.hyperdriveClass or 0) > 0 then
			if role == "PIRATE" and def.roles and def.roles.pirate then
				table.insert(fallbackPool, id)
			elseif role == "MINER" and (id == "dsminer" or id == "kanara") then
				table.insert(fallbackPool, id)
			elseif role ~= "PIRATE" and role ~= "POLICE" and (def.cargo or 0) > 0 then
				table.insert(fallbackPool, id)
			end
		end
	end
	if #fallbackPool > 0 then
		return fallbackPool[Engine.rand:Integer(1, #fallbackPool)]
	end
	return "coronatrix"
end

local function countLivingForSystem(sysKey)
	local s = ensureState()
	local list = s.systemRosters[sysKey] or {}
	local living, destroyed = 0, 0
	for _, label in ipairs(list) do
		local rec = s.ships[label]
		if rec then
			if rec.status == "DESTROYED" then
				destroyed = destroyed + 1
			elseif rec.role ~= "POLICE" and rec.role ~= "PIRATE" then
				living = living + 1
			end
		end
	end
	return living, destroyed
end

function ShipRegistry.GetSystemRoster(system)
	if not system then return {} end
	local s = ensureState()
	local sysKey = ShipRegistry.SystemKey(system.path)
	return s.systemRosters[sysKey] or {}
end

function ShipRegistry.EnsureSystemRoster(system, acceptableShipIds, ports)
	if not system then return {} end
	local s = ensureState()
	local sysKey = ShipRegistry.SystemKey(system.path)
	if not sysKey then return {} end

	ports = ports or Space.GetBodies("SpaceStation") or {}
	local pop = system.population or 0
	if pop <= 0 and #ports == 0 then
		return {}
	end

	if not acceptableShipIds or #acceptableShipIds == 0 then
		acceptableShipIds = {}
		for id, def in pairs(ShipDef) do
			if def.tag == 'SHIP' and (def.hyperdriveClass or 0) > 0 and (def.cargo or 0) > 0 then
				table.insert(acceptableShipIds, id)
			end
		end
	end

	s.systemRosters[sysKey] = s.systemRosters[sysKey] or {}
	local targetCount = math.clamp(8 + #ports * 2 + math.floor(math.min(pop, 20) * 0.5), 14, 36)
	local living = countLivingForSystem(sysKey)

	-- Allow regional attrition recovery only gradually or when roster is significantly depleted
	local needCommission = 0
	if #s.systemRosters[sysKey] == 0 then
		needCommission = targetCount
	elseif living < math.floor(targetCount * 0.70) then
		needCommission = math.min(targetCount - living, 4)
	end

	for i = 1, needCommission do
		local port = (#ports > 0) and ports[Engine.rand:Integer(1, #ports)] or nil
		local stBodyIdx = port and port.path and port.path.bodyIndex or nil
		local stName = port and port.label or nil

		local roll = Engine.rand:Number(1)
		local role = "TRADER"
		if roll < 0.14 then
			role = "MINER"
		elseif roll < 0.28 then
			role = "PASSENGER"
		elseif roll < 0.40 then
			role = "COURIER"
		end

		local hullId = pickShipIdForRole(role, acceptableShipIds)
		local rec = commissionShip(system, hullId, role, stBodyIdx, stName)
		-- Seed new vessels as active or hangar-resident based on home port assignment
		if stBodyIdx then
			rec.status = (i % 2 == 0) and "HANGAR" or "ACTIVE"
			if rec.status == "HANGAR" then
				rec.hangarUntil = (Game.time or 0) + Engine.rand:Number(180, 28800)
			end
		end
	end

	return s.systemRosters[sysKey]
end

local function matchesRole(recRole, reqRole)
	if not reqRole then return true end
	if recRole == reqRole then return true end
	if reqRole == "COMMERCIAL" or reqRole == "TRADER" then
		return recRole == "TRADER" or recRole == "PASSENGER" or recRole == "COURIER" or recRole == "MINER"
	end
	return false
end

local function isSystemOnRoute(rec, sysKey)
	if rec.homeSystemKey == sysKey then return true end
	for _, k in ipairs(rec.routeSystemKeys or {}) do
		if k == sysKey then return true end
	end
	return false
end

function ShipRegistry.AcquireShipForSystem(system, role, preferredShipId, opts)
	if not system then return nil end
	opts = opts or {}
	local s = ensureState()
	local sysKey = ShipRegistry.SystemKey(system.path)
	if not sysKey then return nil end

	local candidates = {}
	local fallbackCandidates = {}

	for label, rec in pairs(s.ships) do
		if rec.status ~= "DESTROYED" and not liveLabels[label] then
			local shipMatches = (not preferredShipId) or (rec.shipId == preferredShipId)
			local roleMatches = matchesRole(rec.role, role)
			local inRegion = (rec.locationSystemKey == sysKey) or isSystemOnRoute(rec, sysKey)

			if shipMatches and roleMatches and inRegion then
				if (opts.stationBodyIdx and rec.locationStationBodyIdx == opts.stationBodyIdx)
					or (opts.fromSystemKey and (rec.homeSystemKey == opts.fromSystemKey or rec.locationSystemKey == opts.fromSystemKey)) then
					table.insert(candidates, rec)
				else
					table.insert(fallbackCandidates, rec)
				end
			end
		end
	end

	local chosen = nil
	if #candidates > 0 then
		chosen = candidates[Engine.rand:Integer(1, #candidates)]
	elseif #fallbackCandidates > 0 then
		chosen = fallbackCandidates[Engine.rand:Integer(1, #fallbackCandidates)]
	end

	if chosen then
		liveLabels[chosen.label] = true
		chosen.status = "ACTIVE"
		chosen.locationSystemKey = sysKey
		chosen.locationStationBodyIdx = opts.stationBodyIdx
		chosen.lastSeenTime = Game.time or 0
		return chosen
	end

	if opts.allowNew == false then
		return nil
	end

	local hullId = preferredShipId or pickShipIdForRole(role, nil)
	local homePortIdx = opts.stationBodyIdx
	local homePortName = nil
	if homePortIdx then
		local ok, b = pcall(Space.GetBody, homePortIdx)
		if ok and b and b:exists() then homePortName = b.label end
	end
	local rec = commissionShip(system, hullId, role, homePortIdx, homePortName)
	liveLabels[rec.label] = true
	rec.status = "ACTIVE"
	rec.locationSystemKey = sysKey
	rec.locationStationBodyIdx = opts.stationBodyIdx
	rec.lastSeenTime = Game.time or 0
	return rec
end

function ShipRegistry.ReleaseLive(label)
	if not label then return end
	liveLabels[label] = nil
	local rec = state and state.ships and state.ships[label]
	if rec and rec.status == "ACTIVE" then
		rec.lastSeenTime = Game.time or 0
	end
end

function ShipRegistry.MarkActive(label, systemPath, stationBodyIdx)
	if not label then return end
	local s = ensureState()
	liveLabels[label] = true
	local rec = s.ships[label]
	if rec and rec.status ~= "DESTROYED" then
		rec.status = "ACTIVE"
		if systemPath then
			rec.locationSystemKey = ShipRegistry.SystemKey(systemPath)
		end
		rec.locationStationBodyIdx = stationBodyIdx
		rec.hangarUntil = 0
		rec.lastSeenTime = Game.time or 0
	end
end

function ShipRegistry.MarkStowed(label, systemPath, stationBodyIdx, wakeTime)
	if not label then return end
	local s = ensureState()
	local rec = s.ships[label]
	if rec and rec.status ~= "DESTROYED" then
		rec.status = "HANGAR"
		if systemPath then
			rec.locationSystemKey = ShipRegistry.SystemKey(systemPath)
		end
		rec.locationStationBodyIdx = stationBodyIdx
		rec.hangarUntil = wakeTime or ((Game.time or 0) + 21600)
		rec.lastSeenTime = Game.time or 0
	end
end

function ShipRegistry.MarkInTransit(label, destSystemPath)
	if not label then return end
	liveLabels[label] = nil
	local s = ensureState()
	local rec = s.ships[label]
	if rec and rec.status ~= "DESTROYED" then
		rec.status = "IN_TRANSIT"
		if destSystemPath then
			rec.locationSystemKey = ShipRegistry.SystemKey(destSystemPath)
		end
		rec.locationStationBodyIdx = nil
		rec.lastSeenTime = Game.time or 0
	end
end

function ShipRegistry.GetHangarReadyShips(system, stationBodyIdx, now)
	if not system or not stationBodyIdx then return {} end
	local s = ensureState()
	local sysKey = ShipRegistry.SystemKey(system.path)
	now = now or Game.time or 0
	local ready = {}
	for label, rec in pairs(s.ships) do
		if rec.status == "HANGAR"
			and not liveLabels[label]
			and rec.locationSystemKey == sysKey
			and rec.locationStationBodyIdx == stationBodyIdx
			and (rec.hangarUntil or 0) <= now then
			table.insert(ready, rec)
		end
	end
	table.sort(ready, function(a, b)
		return (a.hangarUntil or 0) < (b.hangarUntil or 0)
	end)
	return ready
end

function ShipRegistry.GetHangarCountAtStation(system, stationBodyIdx)
	if not system or not stationBodyIdx then return 0 end
	local s = ensureState()
	local sysKey = ShipRegistry.SystemKey(system.path)
	local count = 0
	for _, rec in pairs(s.ships) do
		if rec.status == "HANGAR"
			and rec.locationSystemKey == sysKey
			and rec.locationStationBodyIdx == stationBodyIdx then
			count = count + 1
		end
	end
	return count
end

function ShipRegistry.ApplyRecordToShip(ship, rec)
	if not ship or not ship:exists() or not rec then return end
	liveLabels[rec.label] = true
	ship:SetLabel(rec.label)
	if rec.shipName and rec.shipName ~= "" then
		ship:SetShipName(rec.shipName)
	end
	local def = ShipDef[ship.shipId]
	if rec.skinColors and #rec.skinColors >= 3 and def then
		local c1, c2, c3 = rec.skinColors[1], rec.skinColors[2], rec.skinColors[3]
		if c1 and c2 and c3 then
			local skin = ModelSkin.New()
				:SetColors({
					primary   = Color(c1[1], c1[2], c1[3], c1[4] or 255),
					secondary = Color(c2[1], c2[2], c2[3], c2[4] or 255),
					trim      = Color(c3[1], c3[2], c3[3], c3[4] or 255),
				})
				:SetDecal(def.manufacturer or "pioneer")
				:SetLabel(rec.label)
			ship:SetSkin(skin)
		end
	end
	if rec.pattern and def and def.modelName then
		local okM, model = pcall(Engine.GetModel, def.modelName)
		if okM and model and (model.numPatterns or 0) > 0 then
			ship:SetPattern(rec.pattern % model.numPatterns)
		end
	end
end

function ShipRegistry.GetRecord(label)
	if not label or not state then return nil end
	return state.ships[label]
end

function ShipRegistry.GetCasualties()
	local s = ensureState()
	return s.casualties
end

local function classifyDestruction(attacker, cause)
	if not attacker then
		return "ACCIDENT", cause or "Collision / Operational Loss"
	end
	if attacker.IsPlayer and attacker:IsPlayer() then
		return "PLAYER", "Destroyed by Player (" .. (attacker:GetLabel() or "PLAYER") .. ")"
	end
	local aLabel = attacker.GetLabel and attacker:GetLabel() or nil
	local aRec = aLabel and state and state.ships[aLabel]
	local policeId = Game.system and Game.system.faction and Game.system.faction.policeShip
	if (policeId and attacker.shipId == policeId)
		or (aRec and aRec.role == "POLICE")
		or (aLabel and string.match(aLabel, "^PD%-")) then
		return "POLICE", "Destroyed by System Security (" .. (aLabel or "Police") .. ")"
	end
	if (attacker.IsWanted and attacker:IsWanted())
		or (aRec and aRec.role == "PIRATE") then
		return "PIRATE", "Destroyed by Pirates (" .. (aLabel or "Hostile") .. ")"
	end
	return "COMBAT", "Destroyed in Combat (" .. (aLabel or "Unknown") .. ")"
end

local function recordCasualty(ship, attacker, explicitCause, speed)
	if not ship or (ship.IsPlayer and ship:IsPlayer()) then return end
	local s = ensureState()
	local label = ship:GetLabel()
	if not label or label == "" then return end

	liveLabels[label] = nil
	s.usedLabels[label] = true

	local rec = s.ships[label]
	local category, defaultCause = classifyDestruction(attacker, explicitCause)
	local finalCause = explicitCause or defaultCause

	if rec and rec.status == "DESTROYED" then
		-- Update cause if a more specific collision/explosion detail arrives right after onShipDestroyed
		if explicitCause and rec.destroyedCategory == "ACCIDENT" then
			rec.destroyedCause = explicitCause
		end
		return
	end

	local now = Game.time or 0
	local sysName = (Game.system and Game.system.name) or "Deep Space"
	local killerLabel = (attacker and attacker.GetLabel) and attacker:GetLabel() or nil

	if rec then
		rec.status = "DESTROYED"
		rec.destroyedAt = now
		rec.destroyedSystem = sysName
		rec.destroyedCategory = category
		rec.destroyedCause = finalCause
		rec.killerLabel = killerLabel
	end

	table.insert(s.casualties, {
		label = label,
		shipName = rec and rec.shipName or (ship.shipName ~= "" and ship.shipName or nil),
		shipId = ship.shipId,
		role = rec and rec.role or "UNKNOWN",
		commanderName = rec and rec.commanderName or nil,
		category = category,
		cause = finalCause,
		killerLabel = killerLabel,
		systemName = sysName,
		time = now,
		speed = speed or 0.0,
	})
	while #s.casualties > MAX_CASUALTIES do
		table.remove(s.casualties, 1)
	end
end

Event.Register("onShipStowedInHangar", function(station, ship)
	if not ship then return end
	local label = ship.GetLabel and ship:GetLabel() or nil
	if label then
		liveLabels[label] = nil
	end
end)

Event.Register("onShipDestroyed", function(ship, attacker)
	recordCasualty(ship, attacker, nil, 0.0)
end)

Event.Register("onShipExploded", function(ship, cause, speed)
	recordCasualty(ship, nil, cause, speed)
end)

Event.Register("onLeaveSystem", function()
	liveLabels = {}
end)

Event.Register("onShipLeaveSystem", function(ship)
	if ship and not (ship.IsPlayer and ship:IsPlayer()) then
		local label = ship:GetLabel()
		if label then
			liveLabels[label] = nil
		end
	end
end)

Event.Register("onGameStart", function()
	if loaded_data then
		state = loaded_data
		loaded_data = nil
	else
		state = nil
	end
	local s = ensureState()
	liveLabels = {}

	if Game.player and Game.player:exists() then
		ShipRegistry.RegisterUsedLabel(Game.player:GetLabel())
		liveLabels[Game.player:GetLabel()] = true
	end

	-- Rebuild active live label tracking for ships restored from savegame
	local ok, allShips = pcall(Space.GetBodies, "Ship")
	if ok and allShips then
		for _, ship in ipairs(allShips) do
			if ship and ship:exists() then
				local lbl = ship:GetLabel()
				if lbl and lbl ~= "" then
					ShipRegistry.RegisterUsedLabel(lbl)
					liveLabels[lbl] = true
				end
			end
		end
	end
end)

Event.Register("onGameEnd", function()
	state = nil
	liveLabels = {}
	loaded_data = nil
end)

Serializer:Register("ShipRegistry", function()
	return ensureState()
end, function(data)
	loaded_data = data
end)

return ShipRegistry

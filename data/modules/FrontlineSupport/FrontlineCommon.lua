-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event           = require 'Event'
local FactionRoles    = require 'FactionRoles'
local FactionStanding = require 'FactionStanding'
local Game            = require 'Game'

local FrontlineCommon = {}

FrontlineCommon.FRONTLINE_CRISIS_TYPES = {
	BLOCKADE = true,
	INSURGENCY = true,
	INDUSTRIAL_DISASTER = true,
}

-- Cache of lowercased system name -> SystemPath (SystemOnly)
local systemPathCache = {}

local function getMacroEngine()
	local ok, engine = pcall(require, 'modules.MacroGalaxy.MacroGalaxyEngine')
	if ok and engine then
		return engine
	end
	return nil
end

local function isPrisonBodyOrName(sbody, label)
	if sbody and sbody.spaceStationType == "orbital_station_penal" then
		return true
	end
	local name = label or (sbody and sbody.name) or ""
	return name:find("Prison") ~= nil
		or name:find("Penal") ~= nil
		or name:find("Correctional") ~= nil
		or name:find("Penitentiary") ~= nil
		or name:find("Detention") ~= nil
end

function FrontlineCommon.IsPrisonStationPath(stationPath)
	if not stationPath or not stationPath.GetSystemBody then
		return false
	end
	local ok, sbody = pcall(function() return stationPath:GetSystemBody() end)
	if not ok or not sbody then
		return false
	end
	return isPrisonBodyOrName(sbody, sbody.name)
end

function FrontlineCommon.IsFrontlineCrisis(crisis)
	if not crisis then return false end
	return crisis.category == "FRONTLINE"
		or FrontlineCommon.FRONTLINE_CRISIS_TYPES[crisis.type] == true
end

function FrontlineCommon.ResolveSystemByName(systemName, maxRangeLy)
	if not systemName or systemName == "" then
		return nil, nil
	end
	local lower = string.lower(systemName)

	local cachedPath = systemPathCache[lower]
	if cachedPath then
		local ok, starSys = pcall(function() return cachedPath:GetStarSystem() end)
		if ok and starSys then
			return cachedPath, starSys
		end
		systemPathCache[lower] = nil
	end

	local curSys = Game.system
	if curSys then
		if curSys.name and string.lower(curSys.name) == lower then
			local path = curSys.path:SystemOnly()
			systemPathCache[lower] = path
			return path, curSys
		end

		local range = maxRangeLy or 60
		local ok, nearby = pcall(function() return curSys:GetNearbySystems(range) end)
		if ok and nearby then
			for _, s in ipairs(nearby) do
				if s.name and string.lower(s.name) == lower then
					local path = s.path:SystemOnly()
					systemPathCache[lower] = path
					return path, s
				end
			end
		end
	end

	return nil, nil
end

function FrontlineCommon.GetCrisisForSystem(systemName)
	if not systemName or systemName == "" then return nil end
	local macro = getMacroEngine()
	if not macro or not macro.GetCrisisForSystem then return nil end
	local crisis = macro.GetCrisisForSystem(systemName)
	if FrontlineCommon.IsFrontlineCrisis(crisis) then
		return crisis
	end
	return nil
end

function FrontlineCommon.GetActiveFrontlines(factionFilter, maxRangeLy)
	local macro = getMacroEngine()
	if not macro or not macro.GetActiveCrises then return {} end

	local crises = macro.GetActiveCrises() or {}
	local results = {}
	for _, c in ipairs(crises) do
		if FrontlineCommon.IsFrontlineCrisis(c) and c.system then
			local systemPath, starSystem = FrontlineCommon.ResolveSystemByName(c.system, maxRangeLy or 60)
			if systemPath and starSystem then
				local factionName = (starSystem.faction and starSystem.faction.name) or "Independent"
				if not factionFilter or factionName == factionFilter then
					table.insert(results, {
						crisis = c,
						systemName = c.system,
						systemPath = systemPath,
						starSystem = starSystem,
						factionName = factionName,
						severity = c.severity or 1,
					})
				end
			end
		end
	end
	return results
end

function FrontlineCommon.FindRearLineStations(targetSystemPath, factionName, maxRangeLy)
	local originSys = nil
	if targetSystemPath and targetSystemPath.GetStarSystem then
		local ok, s = pcall(function() return targetSystemPath:GetStarSystem() end)
		if ok then originSys = s end
	end
	originSys = originSys or Game.system
	if not originSys then return {} end

	local range = maxRangeLy or 35
	local ok, nearby = pcall(function()
		return originSys:GetNearbySystems(range, function(s)
			return #s:GetStationPaths() > 0
		end)
	end)
	if not ok or not nearby then return {} end

	local targetFactionStateless = FactionRoles.IsStatelessFaction(factionName)
	local candidates = {}

	for _, s in ipairs(nearby) do
		if s.name and not FrontlineCommon.GetCrisisForSystem(s.name) then
			local sfName = (s.faction and s.faction.name) or "Independent"
			local hostile = false
			if not targetFactionStateless and not FactionRoles.IsStatelessFaction(sfName) and sfName ~= factionName then
				if FactionStanding.Get(sfName) <= -60 then
					hostile = true
				end
			end
			if not hostile then
				local dist = originSys:DistanceTo(s)
				for _, stPath in ipairs(s:GetStationPaths()) do
					if not FrontlineCommon.IsPrisonStationPath(stPath) then
						table.insert(candidates, {
							stationPath = stPath,
							systemPath = s.path:SystemOnly(),
							starSystem = s,
							factionName = sfName,
							distance = dist,
						})
					end
				end
			end
		end
	end

	table.sort(candidates, function(a, b)
		local aSame = (not targetFactionStateless and a.factionName == factionName)
		local bSame = (not targetFactionStateless and b.factionName == factionName)
		if aSame ~= bSame then
			return aSame
		end
		return a.distance < b.distance
	end)

	return candidates
end

function FrontlineCommon.IsEnlistedInFaction(factionName)
	if not factionName or FactionRoles.IsStatelessFaction(factionName) then
		return false
	end
	local info = FactionRoles.GetMilitaryInfo(factionName)
	return info and info.enlisted == true or false
end

function FrontlineCommon.ComputeReward(baseReward, factionName, isEnlistedBonus, crisisSeverity)
	local base = math.max(0, tonumber(baseReward) or 0)
	local isStateless = (not factionName) or FactionRoles.IsStatelessFaction(factionName)
	local standingMult = (not isStateless) and (FactionStanding.GetRewardMultiplier(factionName) or 1.0) or 1.0
	local hazardMult = (isEnlistedBonus and not isStateless) and (FactionRoles.GetHazardPayMultiplier(factionName) or 1.0) or 1.0
	local sev = math.max(1, tonumber(crisisSeverity) or 1)
	local sevMult = 1.0 + 0.15 * (sev - 1)
	return math.floor(base * standingMult * hazardMult * sevMult + 0.5)
end

-- crisisDelta uses MacroGalaxyEngine crisis progress points (0..100 scale, ~6-14/day baseline)
function FrontlineCommon.RecordFrontlineContribution(opts)
	if not opts then return end

	if opts.systemName and (opts.crisisDelta or 0) > 0 then
		local macro = getMacroEngine()
		if macro and macro.ContributeToCrisis then
			macro.ContributeToCrisis(opts.systemName, opts.crisisDelta)
		end
	end

	local factionName = opts.factionName
	if factionName and not FactionRoles.IsStatelessFaction(factionName) then
		if (opts.standingDelta or 0) ~= 0 then
			FactionStanding.ApplyMissionOutcome(
				factionName,
				opts.standingDelta,
				nil,
				opts.reason or "Frontline support operation"
			)
		end
		if FrontlineCommon.IsEnlistedInFaction(factionName) and (opts.militaryXP or 0) > 0 then
			FactionRoles.AddMilitaryXP(
				factionName,
				opts.militaryXP,
				opts.commendations or 1,
				opts.reason or "Frontline support operation"
			)
		end
	end

	if (opts.reward and opts.reward ~= 0) or opts.logTitle then
		local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
		if okFlightLog and FlightLog and FlightLog.RecordTransaction then
			local details = {}
			if opts.systemName then
				table.insert(details, { "Frontline System", opts.systemName })
			end
			if factionName then
				table.insert(details, { "Faction", factionName })
			end
			if opts.crisisDelta and opts.crisisDelta > 0 then
				table.insert(details, { "Crisis Relief", string.format("+%.1f%%", opts.crisisDelta) })
			end
			FlightLog.RecordTransaction({
				category = "MISSION",
				title = opts.logTitle or "Frontline Support Operation",
				amount = opts.reward or 0,
				details = details,
				note = opts.reason or "",
			})
		end
	end
end

local function clearCache()
	systemPathCache = {}
end

Event.Register("onGameStart", clearCache)
Event.Register("onGameEnd", clearCache)

return FrontlineCommon

-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game   = require "Game"
local Engine = require "Engine"
local Timer  = require "Timer"
local utils  = require "utils"
local FactionStanding = require "FactionStanding"

local AU = 149598000000
local AU_sqrt = math.sqrt(AU)

local Hours = 60*60
local Days = 24*Hours
local Weeks = 7*Days

local MissionUtils = {
	AU = AU,
	Days = Days,
	Hours = Hours,
	Weeks = Weeks,
}

MissionUtils.ShipTemplates = require 'modules.MissionUtils.ShipTemplates'

---@class MissionUtils.Calculator
---@field New fun(): MissionUtils.Calculator
local Calculator = utils.class("MissionUtils.Calculator")

MissionUtils.Calculator = Calculator

-- Default starting parameters (calibrated for Supercruise + real-time play)
Calculator.baseDuration = 6 * Hours
Calculator.baseReward = 0

Calculator.inSystemTime = 4 * Hours
Calculator.travelTimeAU = 0.5 * Hours
Calculator.typHyperTime = 5 * Days
Calculator.typHyperDist = 15

Calculator.inSystemReward = 200
Calculator.hyperspaceReward = 1500

-- Setup per-mission parameters in the mission calculator
function Calculator:SetParams(args)
	self.baseDuration = args.baseDuration
	self.baseReward = args.baseReward

	self.inSystemTime = args.inSystemTime
	self.travelTimeAU = args.travelTimeAU
	self.typHyperTime = args.hyperspaceTime
	self.typHyperDist = args.hyperspaceDist

	self.inSystemReward = args.inSystemReward
	self.hyperspaceReward = args.hyperspaceReward
end

-- Calculate the expected time for a transfer between the given station and the destination
---@param station SpaceStation
---@param location SystemPath
---@param urgency number scalar between 0..1 determining how urgent the mission is
---@param random number? optional scalar between 0..1 determining the random deviation of the result
function Calculator:CalcTravelTime(station, location, urgency, random)
	local distDur

	if station.path:IsSameSystem(location) then
		local dist = math.sqrt(station:DistanceTo(location:GetSystemBody().body))
		distDur = math.max((dist / AU_sqrt) * self.travelTimeAU, self.inSystemTime)
	else
		distDur = (location:DistanceTo(Game.system) / self.typHyperDist) * self.typHyperTime
	end

	local dur = self.baseDuration + distDur
		* (1.5 - urgency)
		* (random and Engine.rand:Number(1.0 - random, 1.0 + random) or 1.0)

	return dur
end

-- Calculate the adjusted reward for a mission between the given station and the destination
---@param station SpaceStation
---@param location SystemPath
---@param urgency number scalar between 0..1 determining how urgent the mission is
---@param difficulty number? optional scalar between 0..1 determining the difficulty involved in the mission
---@param random number? optional scalar between 0..1 determining the random deviation of the result
function Calculator:CalcReward(station, location, urgency, difficulty, random)
	difficulty = difficulty or 0

	local distReward

	if station.path:IsSameSystem(location) then
		local dist = math.sqrt(station:DistanceTo(location:GetSystemBody().body))
		distReward = math.max(dist / 15000, self.inSystemReward)
	else
		distReward = (location:DistanceTo(Game.system) / self.typHyperDist) * self.hyperspaceReward
	end

	local reward = self.baseReward + distReward
		* (0.5 + urgency)
		* (1 + difficulty)
		* (random and Engine.rand:Number(1.0 - random, 1.0 + random) or 1.0)

	return reward
end

-- Calculate the distance between the station and the given system path
---@param station SpaceStation
---@param location SystemPath
---@return number distance in meters or lightyears
---@return boolean isLocal whether the distance is measured in meters or ly
function Calculator:CalcDistance(station, location)
	if station.path:IsSameSystem(location) then
		return station:DistanceTo(location:GetSystemBody().body), true
	else
		return location:DistanceTo(Game.system), false
	end
end

--=============================================================================


--
-- Function: GetNearbyStationPaths
--
-- Gets a list of stations in nearby systems that match some criteria.
--
-- Example:
--
-- >  local orbital_ports = MissionUtils.GetNearbyStationPaths(Game.system,
-- >      30, nil, function (station) return station.type == 'STARPORT_ORBITAL' end, true)
-- >
-- >  for i = 1, #orbital_ports do
-- >      local path = orbital_ports[i]
-- >      print(path, ' -- ', path:GetSystemBody().name, ' in system ', path:GetStarSystem().name)
-- >  end
--
-- Parameters:
--
--   range_ly        Range limit for nearby systems to search.
--   system_filter   [optional] function, taking a StarSystem object, used to filter systems.
--   station_filter  [optional] function, taking a SystemBody object, used to filter stations.
--   include_local   [optional] if this is true, then stations in the origin system will be included.--
--
-- Author: John Bartholomew
--
---@param system StarSystem
---@param range_ly number
---@param system_filter? fun(s: StarSystem): boolean
---@param station_filter? fun(s: SystemBody): boolean
---@param include_local? boolean
function MissionUtils.GetNearbyStationPaths(system, range_ly, system_filter, station_filter, include_local)
	local full_system_filter ---@type fun(sys: StarSystem): boolean

	if system_filter then
		full_system_filter = function(sys) return (sys.numberOfStations > 0) and system_filter(sys) end
	else
		full_system_filter = function(sys) return (sys.numberOfStations > 0) end
	end

	local function filter_and_add_stations(output_table, sys)
		local station_paths = sys:GetStationPaths()
		for j = 1, #station_paths do
			local station_path = station_paths[j]
			local station = station_path:GetSystemBody()
			if station_filter == nil or station_filter(station) then
				table.insert(output_table, station_path)
			end
		end
	end

	local nearby_systems = Game.system:GetNearbySystems(range_ly, full_system_filter)
	local nearby_stations = {}

	if include_local == true then
		filter_and_add_stations(nearby_stations, system)
	end
	for i = 1, #nearby_systems do
		filter_and_add_stations(nearby_stations, nearby_systems[i])
	end

	return nearby_stations
end

-- Function: TravelTimeLocal
--
-- Returns a standardized travel time to a local target
--
-- Example:
--
-- > travel_time = MissionUtils.TravelTimeLocal(distance)
--
-- Parameters:
--
--   distance - the distance to the target in meters
--
-- Returns:
--
--   the travel time in seconds
--
function MissionUtils.TravelTimeLocal(distance)
	return math.min(6 * Hours, (distance / AU) * 0.5 * Hours)
end

--
-- Function: TravelTime
--
-- Returns a standardized hyperspace travel time
--
-- Example:
--
-- > travel_time = MissionUtils.TravelTime(distance, location)
--
-- Parameters:
--
--   distance - the distance to the target system in light years
--
--   location - optional, the location in the target system
--              must be a station or planet
--
-- Returns:
--
--   the travel time in seconds
--
function MissionUtils.TravelTime(distance, location)
	local ltt

	if location then
		local sbody = location:GetSystemBody()
		-- find the primary planet orbiting the star or gravpoint to calculate the local travel time
		while sbody and sbody.parent and sbody.parent.superType ~= 'STAR' do sbody = sbody.parent end
		ltt = sbody and MissionUtils.TravelTimeLocal(((sbody.periapsis or 0) + (sbody.apoapsis or 0)) / 2) or MissionUtils.TravelTimeLocal(AU)
	else
		ltt = MissionUtils.TravelTimeLocal(AU)
	end

	return 12 * Hours + distance * 0.45 * Days + ltt
end

function MissionUtils.CountStationAds(adsTable, station)
	if not adsTable or not station then return 0 end
	local count = 0
	for _, ad in pairs(adsTable) do
		if ad.station == station or (station.path and ad.station_local == station.path) then
			count = count + 1
		end
	end
	return count
end

function MissionUtils.CalcBoardTimeout(now, dueDurationSec, maxBoardHours)
	local tNow = now or Game.time or 0
	local maxSec = (maxBoardHours or 36) * Hours
	local dur = math.max(0, tonumber(dueDurationSec) or 0)
	return tNow + math.max(15 * 60, math.min(maxSec, dur * 0.45))
end

function MissionUtils.IsAdExpired(ad, now)
	if not ad then return true end
	local tNow = now or Game.time or 0
	if type(ad.due) == "number" and ad.due <= tNow then
		return true
	end
	if type(ad.timeout) == "number" and ad.timeout <= tNow then
		return true
	end
	return false
end

function MissionUtils.SetupOverdueTimer(mission)
	if Game.time < mission.due then
		Timer:CallAt(mission.due, function ()
			if mission and mission.status then
				mission.status = 'FAILED'
			end
		end)
	end
end

--
-- Function: getNumberOfFlavours
--
-- Returns the number of flavours of the given string from the language module.
-- Assuming first flavour has suffix '_1'.
--
-- Example:
--
-- > local Lang = require 'Lang'
-- > local l = Lang.GetResource("module-sayings")
-- > local n = MissionUtils.getNumberOfFlavours(l, "WISDOM")
--
function MissionUtils.getNumberOfFlavours(l, str)
	local num = 1
	while l:get(str .. "_" .. num) do
		num = num + 1
	end
	return num - 1
end

--- Returns the governing faction name for a StarSystem, SystemPath, or the current system.
---@param sysOrPath StarSystem|SystemPath|nil
---@return string|nil
function MissionUtils.GetSystemFactionName(sysOrPath)
	local sys = nil
	if sysOrPath == nil then
		sys = Game.system
	elseif type(sysOrPath.GetStarSystem) == "function" then
		sys = sysOrPath:GetStarSystem()
	else
		sys = sysOrPath
	end
	if sys and sys.faction and type(sys.faction.name) == "string" and sys.faction.name ~= "" then
		return sys.faction.name
	end
	return nil
end

--- Checks whether the given system (or current system) belongs to `factionName`.
---@param factionName string
---@param sysOrPath StarSystem|SystemPath|nil
---@return boolean
function MissionUtils.IsSystemFaction(factionName, sysOrPath)
	return MissionUtils.GetSystemFactionName(sysOrPath) == factionName
end

--- Scales a base mission payout by the player's standing with `factionOrName`, rounded to $5 or $1.
---@param baseReward number
---@param factionOrName Faction|string|nil
---@return number
function MissionUtils.ApplyFactionReward(baseReward, factionOrName)
	local mult = FactionStanding.GetRewardMultiplier(factionOrName)
	local scaled = baseReward * mult
	if scaled >= 50 then
		return math.max(10, math.floor(scaled / 5 + 0.5) * 5)
	end
	return math.max(1, math.floor(scaled + 0.5))
end

return MissionUtils

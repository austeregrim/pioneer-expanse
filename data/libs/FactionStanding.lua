-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event = require 'Event'
local Game = require 'Game'
local Serializer = require 'Serializer'

local FactionStanding = {}

local MIN_STANDING = -100
local MAX_STANDING = 100

local standings = {}

local TIERS = {
	{ min = 75,   id = "ALLIED",     label = "Allied",     mult = 1.25 },
	{ min = 40,   id = "FRIENDLY",   label = "Friendly",   mult = 1.15 },
	{ min = 15,   id = "CORDIAL",    label = "Cordial",    mult = 1.07 },
	{ min = -14,  id = "NEUTRAL",    label = "Neutral",    mult = 1.00 },
	{ min = -59,  id = "UNFRIENDLY", label = "Unfriendly", mult = 0.90 },
	{ min = -100, id = "HOSTILE",    label = "Hostile",    mult = 0.75 },
}

local function resolveFactionName(factionOrName)
	if type(factionOrName) == "string" then
		return (factionOrName ~= "") and factionOrName or nil
	elseif factionOrName ~= nil then
		local ok, name = pcall(function() return factionOrName.name end)
		if ok and type(name) == "string" and name ~= "" then
			return name
		end
	elseif Game.system and Game.system.faction then
		local name = Game.system.faction.name
		if type(name) == "string" and name ~= "" then
			return name
		end
	end
	return nil
end

local function tierForScore(score)
	for _, tier in ipairs(TIERS) do
		if score >= tier.min then
			return tier
		end
	end
	return TIERS[#TIERS]
end

--- Returns the player's current standing with the given faction (-100..100, default 0).
---@param factionOrName Faction|string|nil
---@return number
function FactionStanding.Get(factionOrName)
	local name = resolveFactionName(factionOrName)
	if not name then return 0 end
	return standings[name] or 0
end

--- Returns tier metadata (id, label, mult, score) for a faction or score.
---@param factionOrName Faction|string|nil
---@return table
function FactionStanding.GetInfo(factionOrName)
	local score = type(factionOrName) == "number" and factionOrName or FactionStanding.Get(factionOrName)
	local tier = tierForScore(score)
	return {
		score = score,
		id = tier.id,
		label = tier.label,
		mult = tier.mult,
	}
end

--- Returns the mission reward payout multiplier for the given faction.
---@param factionOrName Faction|string|nil
---@return number
function FactionStanding.GetRewardMultiplier(factionOrName)
	return FactionStanding.GetInfo(factionOrName).mult
end

--- Checks whether the player meets a minimum standing threshold with a faction.
---@param factionOrName Faction|string|nil
---@param minStanding number?
---@return boolean
function FactionStanding.MeetsMinimum(factionOrName, minStanding)
	return FactionStanding.Get(factionOrName) >= (minStanding or -59)
end

--- Adjusts the player's standing with a faction, clamped to [-100, 100].
---@param factionOrName Faction|string|nil
---@param delta number
---@param reason string?
function FactionStanding.Adjust(factionOrName, delta, reason)
	local name = resolveFactionName(factionOrName)
	if not name or not delta or delta == 0 then return end

	local oldScore = standings[name] or 0
	local newScore = math.max(MIN_STANDING, math.min(MAX_STANDING, oldScore + delta))
	if newScore == oldScore then return end

	standings[name] = newScore
	Event.Queue("onFactionStandingChanged", name, oldScore, newScore, reason)
end

--- Helper for missions: adjusts standing for the issuing faction (and optional destination faction).
---@param issuingFaction Faction|string|nil
---@param delta number
---@param destFaction Faction|string|nil
---@param reason string?
function FactionStanding.ApplyMissionOutcome(issuingFaction, delta, destFaction, reason)
	local issueName = resolveFactionName(issuingFaction)
	if issueName then
		FactionStanding.Adjust(issueName, delta, reason)
	end
	local destName = resolveFactionName(destFaction)
	if destName and destName ~= issueName and delta > 0 then
		FactionStanding.Adjust(destName, math.max(1, math.floor(delta * 0.5)), reason)
	end
end

--- Returns a sorted list of { name, score, label, id, mult } for all known factions.
---@param includeCurrent boolean?
---@return table[]
function FactionStanding.GetAll(includeCurrent)
	local seen = {}
	local list = {}

	for name, score in pairs(standings) do
		seen[name] = true
		local info = FactionStanding.GetInfo(score)
		list[#list + 1] = {
			name = name,
			score = score,
			id = info.id,
			label = info.label,
			mult = info.mult,
		}
	end

	if includeCurrent and Game.system and Game.system.faction then
		local curName = Game.system.faction.name
		if curName and curName ~= "" and not seen[curName] then
			local info = FactionStanding.GetInfo(0)
			list[#list + 1] = {
				name = curName,
				score = 0,
				id = info.id,
				label = info.label,
				mult = info.mult,
			}
		end
	end

	table.sort(list, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.name < b.name
	end)

	return list
end

local function onGameEnd()
	standings = {}
end

local function serialize()
	return { standings = standings }
end

local function unserialize(data)
	standings = (data and data.standings) or {}
end

Event.Register("onGameEnd", onGameEnd)
Serializer:Register("FactionStandingDB", serialize, unserialize)

return FactionStanding


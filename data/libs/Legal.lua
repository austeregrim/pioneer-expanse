-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt
local Comms = require 'Comms'
local FactionRoles = require 'FactionRoles'
local Game = require 'Game'
local PlayerState = require 'PlayerState'

local Lang = require 'Lang'
local l = Lang.GetResource("ui-core")


--
-- Namespace: Legal
--

--
-- Constants: CrimeType
--
-- Different types of crimes and law offences
--
-- DUMPING - jettison of hazardous rubble/waste
-- ILLEGAL_JUMP - jumping into hyperspace too close to station
-- MURDER - destruction of ship
-- PIRACY - fired on ship
-- TRADING_ILLEGAL_GOODS - attempted to sell illegal goods
-- WEAPONS_DISCHARGE - weapons discharged too close to station
-- ECM_DISCHARGE - ECM discharged too close to station
-- CONTRACT_FRAUD - crime committed by intentionally breaking a contract
--

local Legal = {}
Legal.CrimeType = {}

Legal.CrimeType["DUMPING"] = {basefine = 1e4, name = l.DUMPING}
Legal.CrimeType["ILLEGAL_JUMP"] = {basefine = 5e2, name = l.ILLEGAL_JUMP}
Legal.CrimeType["MURDER"] = {basefine = 1.5e6, name = l.MURDER}
Legal.CrimeType["PIRACY"] = {basefine = 1e5, name = l.PIRACY}
Legal.CrimeType["TRADING_ILLEGAL_GOODS"] = {basefine = 5e3, name = l.TRADING_ILLEGAL_GOODS}
Legal.CrimeType["WEAPONS_DISCHARGE"] = {basefine = 5e2, name = l.UNLAWFUL_WEAPONS_DISCHARGE}
Legal.CrimeType["ECM_DISCHARGE"] = {basefine = 7.5e2, name = l.UNLAWFUL_ECM_DISCHARGE}
Legal.CrimeType["CONTRACT_FRAUD"] = {basefine = 5e2, name = l.CONTRACT_FRAUD}
Legal.CrimeType["TRANSPONDER_OFF"] = {basefine = 1.5e3, name = l.TRANSPONDER_OFF or "Transponder Offline"}

-- Returns true if the given (or current) star system requires transponders in open space and at stations.
function Legal.IsTransponderRequired(system)
	local sys = system or Game.system
	if not sys then return false end
	local pop = sys.population or 0
	local lawlessness = sys.lawlessness or 1.0
	local gov = sys.govtype
	if pop <= 0 or lawlessness >= 0.75 then
		return false
	end
	if gov == "NONE" or gov == "DISORDER" then
		return false
	end
	return true
end

-- Checks warrant status of `target` from `observer`'s perspective per Plan I §3b.
-- Returns: status ("UNKNOWN" | "NO_SCANNER" | "NO_ACCESS" | "WANTED" | "CLEAN"), bounty, factionName
function Legal.LookupWarrant(target, observer)
	if not target or not target:exists() then
		return "UNKNOWN", 0, nil
	end
	local obs = observer or Game.player
	if obs and obs.CanIdentify and not obs:CanIdentify(target) then
		return "UNKNOWN", 0, nil
	end

	local sys = Game.system
	local factionName = (sys and sys.faction and sys.faction.name) or nil
	local isWanted = target.IsWanted and target:IsWanted() or false
	local bounty = (isWanted and target.GetBounty) and target:GetBounty() or 0

	if obs and obs.IsPlayer and obs:IsPlayer() then
		local hasWarrantScanner = (obs["warrant_scanner_cap"] or 0) > 0
		if not hasWarrantScanner then
			return "NO_SCANNER", 0, factionName
		end
		if factionName and not FactionRoles.HasBountyLicence(factionName) then
			return "NO_ACCESS", 0, factionName
		end
	else
		local policeId = sys and sys.faction and sys.faction.policeShip
		local isPolice = (policeId and obs and obs.shipId == policeId)
		if not isPolice then
			local hasWarrantScanner = obs and ((obs["warrant_scanner_cap"] or 0) > 0)
			if not hasWarrantScanner then
				return "NO_SCANNER", 0, factionName
			end
		end
	end

	return (isWanted and "WANTED" or "CLEAN"), bounty, factionName
end

-- Returns true if `ship` is the player operating inside a faction system where they hold active Deputy status.
function Legal.IsAuthorizedDeputy(ship, system)
	if not ship or not (ship.IsPlayer and ship:IsPlayer()) then
		return false
	end
	local sys = system or Game.system
	local factionName = sys and sys.faction and sys.faction.name
	if not factionName or FactionRoles.IsStatelessFaction(factionName) then
		return false
	end
	return FactionRoles.HasActiveRole(factionName, "deputy")
end

-- Returns true if an authorized Deputy may legally interdict/engage `target` under `system`'s faction warrant.
function Legal.CanDeputyExecuteWarrant(attacker, target, system)
	local sys = system or Game.system
	if not Legal.IsAuthorizedDeputy(attacker, sys) then
		return false
	end
	if not target or (target.exists and not target:exists()) or not (target.IsWanted and target:IsWanted()) then
		return false
	end
	if Game.system and sys ~= Game.system then
		local curFactionName = Game.system.faction and Game.system.faction.name
		if not curFactionName or not sys.faction or curFactionName ~= sys.faction.name then
			return false
		end
	end
	if target.GetWantedFaction then
		local ok, wantedFaction = pcall(function() return target:GetWantedFaction() end)
		if ok and wantedFaction and sys and sys.faction and wantedFaction ~= sys.faction.name then
			return false
		end
	elseif type(target.wantedFaction) == "string" then
		if sys and sys.faction and target.wantedFaction ~= sys.faction.name then
			return false
		end
	else
		local _, _, warrantFaction = Legal.LookupWarrant(target, attacker)
		if warrantFaction and sys and sys.faction and warrantFaction ~= sys.faction.name then
			return false
		end
	end
	return true
end

local function handleDeputyAndMilitaryCrimeConsequences(ship, crime, system)
	if not ship or not (ship.IsPlayer and ship:IsPlayer()) then return end
	local sys = system or Game.system
	local factionName = sys and sys.faction and sys.faction.name
	if not factionName or FactionRoles.IsStatelessFaction(factionName) then
		return
	end

	local okFine, _, totalFine = pcall(PlayerState.GetCrimeOutstanding)
	totalFine = (okFine and type(totalFine) == "number") and totalFine or 0
	local isWanted = (ship.IsWanted and ship:IsWanted()) or (totalFine > 5500)
	local isSevere = (crime == "MURDER" or crime == "PIRACY")

	if FactionRoles.HasActiveRole(factionName, "deputy") then
		if isSevere or crime == "TRADING_ILLEGAL_GOODS" or isWanted then
			local reason = string.format("Criminal offence in jurisdiction (%s)", crime or "OFFENCE")
			if FactionRoles.RevokeDeputyCharter(factionName, reason, true) then
				Comms.ImportantMessage(
					string.format("%s Authority: Your Deputy Charter has been REVOKED due to %s in jurisdiction.", factionName, crime or "criminal conduct"),
					factionName .. " Authority"
				)
			end
		end
	end

	if FactionRoles.IsEnlisted(factionName) then
		if isSevere or isWanted then
			local reason = string.format("Criminal offence in faction jurisdiction (%s)", crime or "OFFENCE")
			local okDis, msg = FactionRoles.ResignMilitary(true, reason)
			if okDis then
				Comms.ImportantMessage(
					string.format("%s Military Command: %s", factionName, msg),
					factionName .. " Command"
				)
			end
		end
	end
end

function Legal.OnCrimeRecorded(ship, crime, system)
	handleDeputyAndMilitaryCrimeConsequences(ship, crime, system)
end

-- Records a police-witnessed crime citation anywhere in a policed system (including open space).
function Legal:recordPoliceCitation(ship, crime, fineOverride, sourceLabel)
	if not ship or not ship:IsPlayer() then return 0 end
	if not self.CrimeType[crime] then return 0 end
	local sys = Game.system
	local lawlessness = (sys and sys.lawlessness) or 0.0
	local fine = fineOverride or self:fine(crime, lawlessness)
	if sourceLabel then
		Comms.ImportantMessage(string.interp(l.X_CANNOT_BE_TOLERATED_HERE, { crime = self.CrimeType[crime].name }), sourceLabel)
	end
	PlayerState.AddCrime(crime, fine)
	local _, totalFine = PlayerState.GetCrimeOutstanding()
	if Game.player and Game.player.SetWanted then
		Game.player:SetWanted(totalFine > 5500, totalFine)
	end
	handleDeputyAndMilitaryCrimeConsequences(ship, crime, sys)
	return fine
end


function Legal:fine (crime, lawlessness)
	return math.max(1, 1+math.floor(self.CrimeType[crime].basefine * (1.0-lawlessness)))
end

function Legal:notifyOfCrime (ship, crime)
	if not ship:IsPlayer() then return end
	-- TODO: can this be called in hyperspace?

	-- find closest law enforcing station
	local station = Game.player:FindNearestTo("SPACESTATION")

	-- no plaintiff no judgement
	if station == nil then return end

	-- too far away for crime to be noticed
	if station.lawEnforcedRange < station:DistanceTo(Game.player) then
		return
	end

	Comms.ImportantMessage(string.interp(l.X_CANNOT_BE_TOLERATED_HERE, {crime=self.CrimeType[crime].name}),
						   station.label)

	local lawlessness = Game.system.lawlessness
	local _, outstandingfines = PlayerState.GetCrimeOutstanding()
	local newFine = self:fine(crime, lawlessness)

	-- don't keep compounding fines, except for murder
	if crime ~= "MURDER" and newFine < outstandingfines then newFine = 0 end
	PlayerState.AddCrime(crime, newFine)
	handleDeputyAndMilitaryCrimeConsequences(ship, crime, Game.system)
end


return Legal

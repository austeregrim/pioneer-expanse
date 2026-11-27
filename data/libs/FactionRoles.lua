-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

-- Per-faction role, licence, citizenship, military enlistment, and deputy registry.

local Event = require 'Event'
local FactionStanding = require 'FactionStanding'
local Game = require 'Game'
local PlayerState = require 'PlayerState'
local Serializer = require 'Serializer'

local FactionRoles = {}

local DAY_SECONDS = 86400.0
local RESIGN_COOLDOWN_DAYS = 14
local DISCHARGE_COOLDOWN_DAYS = 30
local DEPUTY_RECLAIM_COOLDOWN_DAYS = 30
local RESIGN_STANDING_PENALTY = -5
local DISCHARGE_STANDING_PENALTY = -15

local rolesByFaction = {}
local citizenship = nil
local activeEnlistment = nil
local serviceHistory = {}
local dynamicRivalries = {}
local deputyCooldownUntil = {}
local loaded_data = nil

local STATELESS_FACTIONS = {
	["Independent"] = true,
	["Independent Systems"] = true,
	["Stateless / Independent"] = true,
	["Local Authority"] = true,
}

local FACTION_RIVALRIES = {
	["Solar Federation"] = {
		["Commonwealth of Independent Worlds"] = true,
		["Haber Corporation"] = true,
	},
	["Commonwealth of Independent Worlds"] = {
		["Solar Federation"] = true,
		["Haber Corporation"] = true,
	},
	["Haber Corporation"] = {
		["Solar Federation"] = true,
		["Commonwealth of Independent Worlds"] = true,
	},
}

FactionRoles.MILITARY_RANKS = {
	{ rank = 1, title = "Auxiliary",  minXP = 0,    hazardBonus = 0.05, serviceDiscount = 0.02 },
	{ rank = 2, title = "Ensign",     minXP = 150,  hazardBonus = 0.10, serviceDiscount = 0.05 },
	{ rank = 3, title = "Lieutenant", minXP = 450,  hazardBonus = 0.15, serviceDiscount = 0.08 },
	{ rank = 4, title = "Commander",  minXP = 1000, hazardBonus = 0.20, serviceDiscount = 0.12 },
	{ rank = 5, title = "Captain",    minXP = 2000, hazardBonus = 0.25, serviceDiscount = 0.15 },
	{ rank = 6, title = "Commodore",  minXP = 3500, hazardBonus = 0.30, serviceDiscount = 0.20 },
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

function FactionRoles.IsStatelessFaction(factionOrName)
	if factionOrName == nil or factionOrName == "" then
		return true
	end
	local name = resolveFactionName(factionOrName)
	if not name or name == "" then
		return true
	end
	return STATELESS_FACTIONS[name] == true
end

local function ensureFactionRecord(factionName)
	if not factionName then return nil end
	rolesByFaction[factionName] = rolesByFaction[factionName] or {
		bounty_hunter = nil,
		deputy = nil,
		enlisted = nil,
	}
	return rolesByFaction[factionName]
end

local function isRecordActive(rec, now)
	if not rec then return false end
	if rec.perpetual then return true end
	if not rec.expiresAt then return false end
	return (now or Game.time or 0) < rec.expiresAt
end

local function recordFlightLog(category, title, amount, details, note)
	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		FlightLog.RecordTransaction({
			category = category,
			title = title,
			amount = amount or 0,
			details = details,
			note = note,
		})
	end
end

local function getRankForXP(xp)
	local current = FactionRoles.MILITARY_RANKS[1]
	local nextXP = FactionRoles.MILITARY_RANKS[2] and FactionRoles.MILITARY_RANKS[2].minXP or nil
	local val = xp or 0
	for i, r in ipairs(FactionRoles.MILITARY_RANKS) do
		if val >= r.minXP then
			current = r
			nextXP = FactionRoles.MILITARY_RANKS[i + 1] and FactionRoles.MILITARY_RANKS[i + 1].minXP or nil
		else
			break
		end
	end
	return current, nextXP
end

local function getFactionOutstandingFine(factionName)
	if not Game.system or not Game.system.faction or Game.system.faction.name ~= factionName then
		return 0
	end
	local ok, _, fine = pcall(PlayerState.GetCrimeOutstanding)
	if ok and type(fine) == "number" then
		return fine
	end
	return 0
end

local function isPlayerWanted()
	if Game.player and Game.player.IsWanted then
		local ok, wanted = pcall(function() return Game.player:IsWanted() end)
		if ok then return wanted == true end
	end
	return false
end

local function isDockedAtPrisonStation()
	local station = Game.player and Game.player.GetDockedWith and Game.player:GetDockedWith()
	if not station then return false end
	local okPenal, PenalSystem = pcall(require, 'modules.Penal.PenalSystem')
	return okPenal and PenalSystem and PenalSystem.IsPrisonStation and PenalSystem.IsPrisonStation(station) == true
end

function FactionRoles.GetRecord(factionOrName)
	local name = resolveFactionName(factionOrName)
	if not name then return nil end
	return rolesByFaction[name]
end

function FactionRoles.HasActiveRole(factionOrName, roleKey)
	local name = resolveFactionName(factionOrName)
	if not name or not roleKey then return false end
	local rec = rolesByFaction[name]
	if not rec then return false end
	return isRecordActive(rec[roleKey], Game.time or 0)
end

-- Returns true if the player holds a current bounty hunter licence or deputy status for this faction.
function FactionRoles.HasBountyLicence(factionOrName)
	local name = resolveFactionName(factionOrName)
	if not name then return false end
	return FactionRoles.HasActiveRole(name, "deputy") or FactionRoles.HasActiveRole(name, "bounty_hunter")
end

function FactionRoles.GetBountyLicenceInfo(factionOrName)
	local name = resolveFactionName(factionOrName)
	if not name then return nil end
	local rec = rolesByFaction[name]
	local bh = rec and rec.bounty_hunter
	local dep = rec and rec.deputy
	local now = Game.time or 0
	if isRecordActive(dep, now) then
		return {
			factionName = name,
			active = true,
			perpetual = true,
			deputy = true,
			purchasedAt = dep.purchasedAt or dep.grantedAt or 0,
			expiresAt = nil,
			remainingDays = nil,
		}
	end
	if not bh then
		return {
			factionName = name,
			active = false,
			expired = false,
			perpetual = false,
			deputy = false,
		}
	end
	local active = isRecordActive(bh, now)
	local remDays = (not bh.perpetual and bh.expiresAt) and math.max(0, (bh.expiresAt - now) / DAY_SECONDS) or nil
	return {
		factionName = name,
		active = active,
		expired = (not active),
		perpetual = (bh.perpetual == true),
		deputy = false,
		purchasedAt = bh.purchasedAt or 0,
		expiresAt = bh.expiresAt,
		remainingDays = remDays,
		feePaid = bh.feePaid or 0,
	}
end

-- Computes per-faction bounty hunter licence fee & term based on faction crime/need and player standing.
-- High-crime/unrest factions charge less and offer longer or perpetual licences; fee never exceeds 300 cr.
function FactionRoles.GetBountyLicenceTerms(factionOrName, system)
	local sys = system or Game.system
	local name = resolveFactionName(factionOrName)
	local lawlessness = (sys and sys.lawlessness) or 0.25
	local need = math.max(0.0, math.min(1.0, lawlessness))
	local standing = name and FactionStanding.Get(name) or 0

	local fee
	local termDays
	local perpetual = false

	if need >= 0.50 then
		fee = math.max(50, math.floor(150 - (need - 0.50) * 200))
		termDays = nil
		perpetual = true
	elseif need >= 0.20 then
		fee = math.floor(300 - (need - 0.20) * 500)
		termDays = 540
	else
		fee = 300
		termDays = 365
	end

	if standing >= 75 then
		fee = math.max(0, math.floor(fee * 0.5))
		perpetual = true
		termDays = nil
	elseif standing >= 40 then
		fee = math.max(25, math.floor(fee * 0.75))
	end

	fee = math.min(300, math.max(0, fee))
	return {
		factionName = name,
		fee = fee,
		termDays = termDays,
		perpetual = perpetual,
		need = need,
	}
end

function FactionRoles.PurchaseBountyLicence(factionOrName, system)
	local name = resolveFactionName(factionOrName)
	if not name then return false, "UNKNOWN_FACTION" end

	local terms = FactionRoles.GetBountyLicenceTerms(name, system)
	if PlayerState.GetMoney() < terms.fee then
		return false, "INSUFFICIENT_FUNDS", terms
	end

	if terms.fee > 0 then
		PlayerState.AddMoney(-terms.fee)
	end

	local now = Game.time or 0
	local rec = ensureFactionRecord(name)
	local expiresAt = nil
	if not terms.perpetual and terms.termDays then
		expiresAt = now + terms.termDays * DAY_SECONDS
	end
	rec.bounty_hunter = {
		purchasedAt = now,
		expiresAt = expiresAt,
		perpetual = terms.perpetual,
		feePaid = terms.fee,
	}

	recordFlightLog(
		"SERVICE",
		string.format("Bounty Hunter Licence (%s)", name),
		-terms.fee,
		{
			{ "Issuing Faction", name },
			{ "Term", terms.perpetual and "Perpetual" or string.format("%d days", terms.termDays) },
		},
		string.format("Registered active Bounty Hunter Licence with %s.", name)
	)

	Event.Queue("onFactionRoleChanged", name, "bounty_hunter", rec.bounty_hunter)
	return true, nil, terms
end

function FactionRoles.GetAllLicences()
	local now = Game.time or 0
	local list = {}
	for name, rec in pairs(rolesByFaction) do
		if rec.bounty_hunter or rec.deputy then
			local info = FactionRoles.GetBountyLicenceInfo(name)
			if info then
				info.active = isRecordActive(rec.deputy, now) or isRecordActive(rec.bounty_hunter, now)
				table.insert(list, info)
			end
		end
	end
	table.sort(list, function(a, b)
		if a.active ~= b.active then return a.active end
		return (a.factionName or "") < (b.factionName or "")
	end)
	return list
end

-- ============================================================================
-- Citizenship & Residency Lock (Plan J Batch 1)
-- ============================================================================

function FactionRoles.GetCitizenship()
	if not citizenship or not citizenship.factionName then
		return nil
	end
	return {
		factionName = citizenship.factionName,
		grantedAt = citizenship.grantedAt or 0,
		lockedByMilitary = (activeEnlistment ~= nil),
	}
end

function FactionRoles.ClaimCitizenship(factionOrName)
	local name = resolveFactionName(factionOrName)
	if isDockedAtPrisonStation() then
		return false, "Citizenship cannot be registered at penal or correctional facilities."
	end
	if FactionRoles.IsStatelessFaction(name) then
		return false, "Citizenship cannot be claimed in independent or uncontrolled systems."
	end
	if activeEnlistment then
		return false, string.format("Cannot alter citizenship while actively serving in the %s military.", activeEnlistment)
	end
	if citizenship and citizenship.factionName == name then
		return false, string.format("You already hold citizenship in %s.", name)
	end

	local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')
	if not okTax or not TaxAuthority or not TaxAuthority.GetResidencyInfo then
		return false, "Civil residency authority unavailable."
	end
	local res = TaxAuthority.GetResidencyInfo()
	if not res or not res.isResident then
		return false, string.format("Active civil residency in %s is required before claiming citizenship.", name)
	end
	if res.homeFaction ~= name then
		return false, string.format("Your registered civil residency is in %s; transfer residency to %s first.", res.homeFaction or "another jurisdiction", name)
	end

	local oldFaction = citizenship and citizenship.factionName or nil
	local now = Game.time or 0
	citizenship = {
		factionName = name,
		grantedAt = now,
	}

	recordFlightLog(
		"SERVICE",
		string.format("Citizenship Granted (%s)", name),
		0,
		{
			{ "Faction", name },
			{ "Home Station", res.homeStationName or "Registered Port" },
		},
		string.format("Registered full civil citizenship with %s.", name)
	)

	Event.Queue("onCitizenshipChanged", name, oldFaction)
	return true, string.format("Citizenship granted by %s.", name)
end

function FactionRoles.RenounceCitizenship()
	if not citizenship or not citizenship.factionName then
		return false, "You do not currently hold citizenship in any faction."
	end
	if activeEnlistment then
		return false, string.format("Cannot renounce citizenship while actively enlisted in %s.", activeEnlistment)
	end

	local oldName = citizenship.factionName
	if FactionRoles.HasActiveRole(oldName, "deputy") then
		FactionRoles.RevokeDeputyCharter(oldName, "Citizenship renounced", false)
	end

	citizenship = nil

	recordFlightLog(
		"SERVICE",
		string.format("Citizenship Renounced (%s)", oldName),
		0,
		{ { "Former Faction", oldName } },
		string.format("Voluntarily renounced citizenship in %s.", oldName)
	)

	Event.Queue("onCitizenshipChanged", nil, oldName)
	return true, string.format("Renounced citizenship in %s.", oldName)
end

function FactionRoles.CanChangeResidencyToFaction(targetFactionName)
	if activeEnlistment then
		local allowedFaction = (citizenship and citizenship.factionName) or activeEnlistment
		if targetFactionName ~= allowedFaction then
			return false, string.format(
				"Active military service with %s restricts residency transfers to %s stations until you resign.",
				activeEnlistment, allowedFaction
			)
		end
	end
	return true, nil
end

function FactionRoles.OnResidencyChanged(newFactionName)
	if citizenship and not activeEnlistment and citizenship.factionName ~= newFactionName then
		local oldName = citizenship.factionName
		citizenship = nil
		if FactionRoles.HasActiveRole(oldName, "deputy") then
			FactionRoles.RevokeDeputyCharter(oldName, "Residency transferred outside jurisdiction", false)
		end
		Event.Queue("onCitizenshipChanged", nil, oldName)
	end
end

-- ============================================================================
-- Rivalries, Military Enlistment & Rank Ladder (Plan J Batch 1)
-- ============================================================================

function FactionRoles.RecordFactionConflict(factionA, factionB)
	local a = resolveFactionName(factionA)
	local b = resolveFactionName(factionB)
	if not a or not b or a == b then return end
	if FactionRoles.IsStatelessFaction(a) or FactionRoles.IsStatelessFaction(b) then return end

	dynamicRivalries[a] = dynamicRivalries[a] or {}
	dynamicRivalries[b] = dynamicRivalries[b] or {}
	dynamicRivalries[a][b] = true
	dynamicRivalries[b][a] = true
end

local function areFactionsRivals(factionA, factionB)
	if not factionA or not factionB or factionA == factionB then
		return false
	end
	if FACTION_RIVALRIES[factionA] and FACTION_RIVALRIES[factionA][factionB] then
		return true
	end
	if FACTION_RIVALRIES[factionB] and FACTION_RIVALRIES[factionB][factionA] then
		return true
	end
	if dynamicRivalries[factionA] and dynamicRivalries[factionA][factionB] then
		return true
	end
	if dynamicRivalries[factionB] and dynamicRivalries[factionB][factionA] then
		return true
	end
	return false
end

function FactionRoles.IsEnlistmentBlacklisted(factionOrName)
	local name = resolveFactionName(factionOrName)
	if not name or FactionRoles.IsStatelessFaction(name) then
		return false, nil
	end
	for servedFaction, hist in pairs(serviceHistory) do
		local hasServed = (hist == true) or (type(hist) == "table" and hist.firstEnlistedAt ~= nil)
		if hasServed and servedFaction ~= name and areFactionsRivals(servedFaction, name) then
			return true, servedFaction
		end
	end
	return false, nil
end

function FactionRoles.GetActiveEnlistment()
	return activeEnlistment
end

function FactionRoles.IsEnlisted(factionOrName)
	if factionOrName == nil then
		return activeEnlistment ~= nil
	end
	local name = resolveFactionName(factionOrName)
	if not name then return false end
	return activeEnlistment == name
end

function FactionRoles.CanEnlist(factionOrName)
	local name = resolveFactionName(factionOrName)
	if isDockedAtPrisonStation() then
		return false, "Military enlistment is unavailable at penal or correctional facilities.", { prisonStation = true }
	end
	if FactionRoles.IsStatelessFaction(name) then
		return false, "Independent or uncontrolled systems do not maintain a regular military."
	end
	if activeEnlistment == name then
		return false, string.format("Already actively enlisted with %s.", name)
	end
	if activeEnlistment ~= nil then
		return false, string.format("Currently enlisted with %s. Resign your active commission first.", activeEnlistment), { activeFaction = activeEnlistment }
	end

	local blacklisted, rival = FactionRoles.IsEnlistmentBlacklisted(name)
	if blacklisted then
		return false, string.format("PERMANENTLY BARRED: Prior military service with rival %s.", rival), { blacklisted = true, rivalFaction = rival }
	end

	if not citizenship or citizenship.factionName ~= name then
		return false, string.format("Citizenship in %s is required to enlist. Claim citizenship in the station Lobby.", name), { missingCitizenship = true }
	end

	local standing = FactionStanding.Get(name)
	if standing < 0 then
		return false, string.format("Neutral or better standing (>= 0) with %s is required to enlist (current: %d).", name, standing), { standing = standing }
	end

	local fine = getFactionOutstandingFine(name)
	if fine > 0 or isPlayerWanted() then
		return false, string.format("Clear all outstanding fines and warrants in %s before enlisting.", name), { fine = fine }
	end

	local hist = serviceHistory[name]
	local now = Game.time or 0
	if type(hist) == "table" and hist.reenlistCooldownUntil and now < hist.reenlistCooldownUntil then
		local remDays = math.max(1, math.ceil((hist.reenlistCooldownUntil - now) / DAY_SECONDS))
		return false, string.format("Re-enlistment cooldown active (%d days remaining).", remDays), { cooldownDays = remDays }
	end

	return true, nil, {}
end

function FactionRoles.Enlist(factionOrName)
	local name = resolveFactionName(factionOrName)
	local ok, reason, details = FactionRoles.CanEnlist(name)
	if not ok then
		return false, reason, details
	end

	-- Snapshot hostile standings at the moment of enlistment as permanent dynamic rivalries
	for _, entry in ipairs(FactionStanding.GetAll(true)) do
		if entry.name and entry.name ~= name and not FactionRoles.IsStatelessFaction(entry.name) and (entry.score or 0) <= -60 then
			FactionRoles.RecordFactionConflict(name, entry.name)
		end
	end

	local now = Game.time or 0
	local rec = ensureFactionRecord(name)
	local prev = rec.enlisted or {}
	local hist = type(serviceHistory[name]) == "table" and serviceHistory[name] or {
		firstEnlistedAt = now,
		totalXP = prev.xp or 0,
		commendations = prev.commendations or 0,
	}
	if not hist.firstEnlistedAt then hist.firstEnlistedAt = now end
	hist.reenlistCooldownUntil = nil
	serviceHistory[name] = hist

	local xp = math.max(prev.xp or 0, hist.totalXP or 0)
	local comm = math.max(prev.commendations or 0, hist.commendations or 0)
	local rankDef = getRankForXP(xp)

	activeEnlistment = name
	rec.enlisted = {
		perpetual = true,
		enlistedAt = now,
		xp = xp,
		commendations = comm,
		rank = rankDef.rank,
	}

	recordFlightLog(
		"SERVICE",
		string.format("Military Enlistment (%s)", name),
		0,
		{
			{ "Faction", name },
			{ "Rank", rankDef.title },
			{ "Hazard Bonus", string.format("+%d%%", math.floor(rankDef.hazardBonus * 100)) },
		},
		string.format("Enlisted in %s military service as %s.", name, rankDef.title)
	)

	Event.Queue("onEnlistmentChanged", name, true, "ENLISTED")
	Event.Queue("onFactionRoleChanged", name, "enlisted", rec.enlisted)
	return true, string.format("Commissioned into %s military service at rank %s.", name, rankDef.title)
end

function FactionRoles.ResignMilitary(isDishonourable, reason)
	if not activeEnlistment then
		return false, "You are not currently enlisted in any military."
	end

	local name = activeEnlistment
	local now = Game.time or 0
	activeEnlistment = nil

	local rec = ensureFactionRecord(name)
	if rec and rec.enlisted then
		rec.enlisted.perpetual = false
		rec.enlisted.expiresAt = nil
		rec.enlisted.resignedAt = now
	end

	local hist = type(serviceHistory[name]) == "table" and serviceHistory[name] or {
		firstEnlistedAt = (rec and rec.enlisted and rec.enlisted.enlistedAt) or now,
		totalXP = (rec and rec.enlisted and rec.enlisted.xp) or 0,
		commendations = (rec and rec.enlisted and rec.enlisted.commendations) or 0,
	}
	hist.resignedAt = now
	local cooldownDays = isDishonourable and DISCHARGE_COOLDOWN_DAYS or RESIGN_COOLDOWN_DAYS
	hist.reenlistCooldownUntil = now + cooldownDays * DAY_SECONDS
	serviceHistory[name] = hist

	local standingDelta = isDishonourable and DISCHARGE_STANDING_PENALTY or RESIGN_STANDING_PENALTY
	local penaltyReason = reason or (isDishonourable and "Dishonourable military discharge" or "Military commission resigned")
	FactionStanding.Adjust(name, standingDelta, penaltyReason)

	recordFlightLog(
		"SERVICE",
		string.format(isDishonourable and "Dishonourable Discharge (%s)" or "Commission Resigned (%s)", name),
		0,
		{
			{ "Faction", name },
			{ "Standing Impact", string.format("%+d", standingDelta) },
			{ "Re-enlistment Cooldown", string.format("%d days", cooldownDays) },
		},
		isDishonourable
			and string.format("Discharged from %s military service: %s.", name, penaltyReason)
			or string.format("Resigned commission from %s military service. Service rank preserved.", name)
	)

	Event.Queue("onEnlistmentChanged", name, false, isDishonourable and "DISHONOURABLE_DISCHARGE" or "RESIGNED")
	Event.Queue("onFactionRoleChanged", name, "enlisted", nil)

	if isDishonourable then
		return true, string.format("Dishonourably discharged from %s (%d standing, %d-day re-enlistment lock).", name, standingDelta, cooldownDays)
	end
	return true, string.format("Resigned commission from %s (%d standing, %d-day re-enlistment cooldown). Prior rival lockouts remain permanent.", name, standingDelta, cooldownDays)
end

function FactionRoles.GetMilitaryInfo(factionOrName)
	local name = resolveFactionName(factionOrName)
	local rec = name and rolesByFaction[name] or nil
	local enl = rec and rec.enlisted or nil
	local hist = name and type(serviceHistory[name]) == "table" and serviceHistory[name] or nil
	local xp = math.max((enl and enl.xp) or 0, (hist and hist.totalXP) or 0)
	local comm = math.max((enl and enl.commendations) or 0, (hist and hist.commendations) or 0)
	local rankDef, nextRankXP = getRankForXP(xp)
	local blacklisted, rivalFaction = FactionRoles.IsEnlistmentBlacklisted(name)
	local now = Game.time or 0
	local cooldownDays = 0
	if hist and hist.reenlistCooldownUntil and now < hist.reenlistCooldownUntil then
		cooldownDays = math.max(1, math.ceil((hist.reenlistCooldownUntil - now) / DAY_SECONDS))
	end

	return {
		factionName = name,
		enlisted = (name ~= nil and activeEnlistment == name),
		activeFaction = activeEnlistment,
		rank = rankDef.rank,
		rankTitle = rankDef.title,
		xp = xp,
		nextRankXP = nextRankXP,
		hazardBonus = rankDef.hazardBonus,
		serviceDiscount = rankDef.serviceDiscount,
		commendations = comm,
		blacklisted = blacklisted,
		rivalFaction = rivalFaction,
		reenlistCooldownDays = cooldownDays,
	}
end

function FactionRoles.AddMilitaryXP(factionOrName, xpDelta, commendationDelta, reason)
	local name = resolveFactionName(factionOrName)
	if not name or FactionRoles.IsStatelessFaction(name) then
		return false, nil
	end
	local rec = rolesByFaction[name]
	if activeEnlistment ~= name and not (rec and rec.enlisted) then
		return false, nil
	end

	rec = ensureFactionRecord(name)
	local now = Game.time or 0
	local enl = rec.enlisted or {
		perpetual = (activeEnlistment == name),
		enlistedAt = now,
		xp = 0,
		commendations = 0,
		rank = 1,
	}
	rec.enlisted = enl

	local oldRankDef = getRankForXP(enl.xp or 0)
	enl.xp = math.max(0, (enl.xp or 0) + (xpDelta or 0))
	enl.commendations = math.max(0, (enl.commendations or 0) + (commendationDelta or 0))

	local hist = type(serviceHistory[name]) == "table" and serviceHistory[name] or {
		firstEnlistedAt = enl.enlistedAt or now,
		totalXP = 0,
		commendations = 0,
	}
	hist.totalXP = enl.xp
	hist.commendations = enl.commendations
	serviceHistory[name] = hist

	local newRankDef = getRankForXP(enl.xp)
	enl.rank = newRankDef.rank
	local promoted = newRankDef.rank > oldRankDef.rank

	if promoted then
		recordFlightLog(
			"SERVICE",
			string.format("Military Promotion: %s (%s)", newRankDef.title, name),
			0,
			{
				{ "Faction", name },
				{ "New Rank", string.format("%s (Rank %d)", newRankDef.title, newRankDef.rank) },
				{ "Hazard Bonus", string.format("+%d%%", math.floor(newRankDef.hazardBonus * 100)) },
				{ "Reason", reason or "Frontline service" },
			},
			string.format("Promoted to %s in %s military service.", newRankDef.title, name)
		)
		Event.Queue("onMilitaryRankChanged", name, newRankDef.rank, newRankDef.title, enl.xp)
	end

	return promoted, newRankDef
end

function FactionRoles.GetHazardPayMultiplier(factionOrName)
	local name = resolveFactionName(factionOrName)
	if not name or activeEnlistment ~= name then
		return 1.0
	end
	local info = FactionRoles.GetMilitaryInfo(name)
	return 1.0 + (info.hazardBonus or 0)
end

-- ============================================================================
-- Faction Deputy Charter (Plan J Batch 1)
-- ============================================================================

function FactionRoles.GetDeputyEligibility(factionOrName)
	local name = resolveFactionName(factionOrName)
	local isStateless = FactionRoles.IsStatelessFaction(name)
	local isDeputy = (name ~= nil) and FactionRoles.HasActiveRole(name, "deputy")
	local citizenshipOk = (not isStateless) and citizenship ~= nil and citizenship.factionName == name
	local standing = (name and not isStateless) and FactionStanding.Get(name) or 0
	local standingOk = (not isStateless) and standing >= 75

	local fine = (name and not isStateless) and getFactionOutstandingFine(name) or 0
	local wanted = isPlayerWanted()
	local cleanRecordOk = (fine == 0) and (not wanted)

	local rec = name and rolesByFaction[name] or nil
	local hist = name and type(serviceHistory[name]) == "table" and serviceHistory[name] or nil
	local hasLicenceHistory = (rec ~= nil and rec.bounty_hunter ~= nil)
	local commendations = math.max((rec and rec.enlisted and rec.enlisted.commendations) or 0, (hist and hist.commendations) or 0)
	local credentialOk = hasLicenceHistory or (commendations >= 3) or (name ~= nil and activeEnlistment == name)

	local now = Game.time or 0
	local cdUntil = name and deputyCooldownUntil[name] or nil
	local cooldownOk = (not cdUntil) or (now >= cdUntil)
	local cooldownRemDays = (cdUntil and now < cdUntil) and math.max(1, math.ceil((cdUntil - now) / DAY_SECONDS)) or 0

	local reasons = {}
	if isStateless then
		table.insert(reasons, "Independent or uncontrolled systems do not issue Deputy Charters.")
	else
		if not citizenshipOk then
			table.insert(reasons, string.format("Citizenship in %s is required.", name))
		end
		if not standingOk then
			table.insert(reasons, string.format("Allied standing (>= 75) required (current: %d).", standing))
		end
		if not cleanRecordOk then
			table.insert(reasons, "Clean criminal record required (0 Cr fine, not wanted).")
		end
		if not credentialOk then
			table.insert(reasons, "Requires a Bounty Hunter Licence, active military service, or 3+ commendations.")
		end
		if not cooldownOk then
			table.insert(reasons, string.format("Deputy reclaim cooldown active (%d days remaining).", cooldownRemDays))
		end
	end

	local eligible = (not isStateless) and (not isDeputy) and citizenshipOk and standingOk and cleanRecordOk and credentialOk and cooldownOk

	return {
		eligible = eligible,
		isDeputy = isDeputy,
		citizenshipOk = citizenshipOk,
		standingOk = standingOk,
		cleanRecordOk = cleanRecordOk,
		credentialOk = credentialOk,
		cooldownOk = cooldownOk,
		cooldownRemDays = cooldownRemDays,
		standing = standing,
		fine = fine,
		commendations = commendations,
		reasons = reasons,
	}
end

function FactionRoles.ClaimDeputyCharter(factionOrName)
	local name = resolveFactionName(factionOrName)
	if isDockedAtPrisonStation() then
		return false, "Deputy Charters cannot be claimed at penal or correctional facilities."
	end
	if FactionRoles.IsStatelessFaction(name) then
		return false, "Deputy Charters cannot be issued in independent systems."
	end
	local elig = FactionRoles.GetDeputyEligibility(name)
	if elig.isDeputy then
		return false, string.format("You already hold an active Deputy Charter in %s.", name)
	end
	if not elig.eligible then
		return false, elig.reasons[1] or "Deputy Charter requirements not met."
	end

	local now = Game.time or 0
	local rec = ensureFactionRecord(name)
	rec.deputy = {
		perpetual = true,
		grantedAt = now,
		purchasedAt = now,
	}

	recordFlightLog(
		"SERVICE",
		string.format("Deputy Charter Granted (%s)", name),
		0,
		{
			{ "Jurisdiction", name },
			{ "Standing", tostring(elig.standing) },
			{ "Status", "Perpetual (Licence Fees Waived)" },
		},
		string.format("Commissioned as an authorized Deputy of %s.", name)
	)

	Event.Queue("onFactionRoleChanged", name, "deputy", rec.deputy)
	return true, string.format("Deputy Charter granted by %s. Bounty licence fees waived and warrant execution authorized.", name)
end

function FactionRoles.RevokeDeputyCharter(factionOrName, reason, applyCooldown)
	local name = resolveFactionName(factionOrName)
	if not name then return false end
	local rec = rolesByFaction[name]
	if not rec or not rec.deputy then
		return false
	end

	rec.deputy = nil
	local now = Game.time or 0
	if applyCooldown ~= false then
		deputyCooldownUntil[name] = now + DEPUTY_RECLAIM_COOLDOWN_DAYS * DAY_SECONDS
	end

	recordFlightLog(
		"SERVICE",
		string.format("Deputy Charter Revoked (%s)", name),
		0,
		{
			{ "Jurisdiction", name },
			{ "Reason", reason or "Charter conditions violated" },
		},
		string.format("Deputy Charter revoked by %s: %s.", name, reason or "Charter conditions violated")
	)

	Event.Queue("onFactionRoleChanged", name, "deputy", nil)
	return true
end

-- ============================================================================
-- Events & Serialization
-- ============================================================================

Event.Register("onFactionStandingChanged", function(name, oldScore, newScore, reason)
	if not name or type(newScore) ~= "number" then return end
	if FactionRoles.HasActiveRole(name, "deputy") and newScore < 40 then
		FactionRoles.RevokeDeputyCharter(name, "Standing fell below Friendly threshold (< 40)", true)
		local okComms, Comms = pcall(require, 'Comms')
		if okComms and Comms and Comms.ImportantMessage then
			Comms.ImportantMessage(
				string.format("%s Authority: Your Deputy Charter has been revoked due to deteriorated standing (%d).", name, newScore),
				name .. " Authority"
			)
		end
	end
end)

Event.Register("onGameStart", function()
	if loaded_data then
		rolesByFaction = loaded_data.rolesByFaction or {}
		citizenship = loaded_data.citizenship
		activeEnlistment = loaded_data.activeEnlistment
		serviceHistory = loaded_data.serviceHistory or {}
		dynamicRivalries = loaded_data.dynamicRivalries or {}
		deputyCooldownUntil = loaded_data.deputyCooldownUntil or {}
		loaded_data = nil

		-- Normalize legacy enlisted records so HasActiveRole matches activeEnlistment
		for fname, rec in pairs(rolesByFaction) do
			if type(rec) == "table" and rec.enlisted then
				rec.enlisted.perpetual = (activeEnlistment == fname)
			end
		end
	else
		rolesByFaction = {}
		citizenship = nil
		activeEnlistment = nil
		serviceHistory = {}
		dynamicRivalries = {}
		deputyCooldownUntil = {}
	end
end)

Event.Register("onGameEnd", function()
	rolesByFaction = {}
	citizenship = nil
	activeEnlistment = nil
	serviceHistory = {}
	dynamicRivalries = {}
	deputyCooldownUntil = {}
	loaded_data = nil
end)

Serializer:Register("FactionRolesDB", function()
	return {
		rolesByFaction = rolesByFaction,
		citizenship = citizenship,
		activeEnlistment = activeEnlistment,
		serviceHistory = serviceHistory,
		dynamicRivalries = dynamicRivalries,
		deputyCooldownUntil = deputyCooldownUntil,
	}
end, function(data)
	loaded_data = data
end)

return FactionRoles

-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

-- Per-faction role, licence, and authorization registry.
-- Generic structure so future Deputy and Military Enlistment roles share the
-- same per-faction storage without breaking saves.

local Event = require 'Event'
local FactionStanding = require 'FactionStanding'
local Game = require 'Game'
local PlayerState = require 'PlayerState'
local Serializer = require 'Serializer'

local FactionRoles = {}

local DAY_SECONDS = 86400.0
local rolesByFaction = {}
local loaded_data = nil

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
			purchasedAt = dep.purchasedAt or 0,
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
	rec.bounty_hunter = {
		purchasedAt = now,
		expiresAt = terms.perpetual and nil or (now + terms.termDays * DAY_SECONDS),
		perpetual = terms.perpetual,
		feePaid = terms.fee,
	}

	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		FlightLog.RecordTransaction({
			category = "SERVICE",
			title = string.format("Bounty Hunter Licence (%s)", name),
			amount = -terms.fee,
			details = {
				{ "Issuing Faction", name },
				{ "Term", terms.perpetual and "Perpetual" or string.format("%d days", terms.termDays) },
			},
			note = string.format("Registered active Bounty Hunter Licence with %s.", name),
		})
	end

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

Event.Register("onGameStart", function()
	if loaded_data then
		rolesByFaction = loaded_data.rolesByFaction or {}
		loaded_data = nil
	else
		rolesByFaction = {}
	end
end)

Event.Register("onGameEnd", function()
	rolesByFaction = {}
	loaded_data = nil
end)

Serializer:Register("FactionRolesDB", function()
	return { rolesByFaction = rolesByFaction }
end, function(data)
	loaded_data = data
end)

return FactionRoles

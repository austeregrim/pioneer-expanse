-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event        = require 'Event'
local Game         = require 'Game'
local Comms        = require 'Comms'
local Legal        = require 'Legal'
local PlayerState  = require 'PlayerState'
local Commodities  = require 'Commodities'
local Format       = require 'Format'

local PenalSystem = {}

local PRISON_IMPORTS = {
	water           = true,
	grain           = true,
	fruit_and_veg   = true,
	animal_meat     = true,
	hydrogen        = true,
	liquid_oxygen   = true,
	medicines       = true,
}

local PRISON_EXPORTS = {
	metal_ore       = true,
	carbon_ore      = true,
	radioactives    = true,
	rubbish         = true,
}

local CONTRABAND_ITEMS = {
	hand_weapons    = true,
	battle_weapons  = true,
	liquor          = true,
	narcotics       = true,
	nerve_gas       = true,
}

function PenalSystem.IsPrisonStation(station)
	if not station then return false end
	local ok, isPrison = pcall(function()
		if station.exists and not station:exists() then return false end
		local sbody = station.GetSystemBody and station:GetSystemBody()
		local stType = sbody and sbody.spaceStationType or ""
		if stType == "orbital_station_penal" then return true end

		local label = station.label or (station.GetLabel and station:GetLabel()) or (sbody and sbody.name) or ""
		return label:find("Prison") ~= nil or
		       label:find("Penal") ~= nil or
		       label:find("Correctional") ~= nil or
		       label:find("Penitentiary") ~= nil or
		       label:find("Detention") ~= nil
	end)
	return ok and (isPrison == true)
end

function PenalSystem.IsPrisonCommodity(name)
	if not name then return false end
	return PRISON_IMPORTS[name] == true or PRISON_EXPORTS[name] == true
end

function PenalSystem.IsPrisonImport(name)
	return PRISON_IMPORTS[name] == true
end

function PenalSystem.IsPrisonExport(name)
	return PRISON_EXPORTS[name] == true
end

function PenalSystem.IsContraband(name)
	return CONTRABAND_ITEMS[name] == true
end

-- Customs inspection upon docking at a high-security prison station
function PenalSystem.CheckAndSeizeContraband(player, station)
	if not player or not player:IsPlayer() then return end
	if not PenalSystem.IsPrisonStation(station) then return end

	local cargoMgr = player:GetComponent('CargoManager')
	if not cargoMgr or not cargoMgr.commodities then return end

	local shieldedCap = player:hasprop("cargo_shield_cap") and (player["cargo_shield_cap"] or 0) or 0
	local totalContraband = 0
	local contrabandList = {}

	for commName, data in pairs(cargoMgr.commodities) do
		if PenalSystem.IsContraband(commName) and data.count and data.count > 0 then
			totalContraband = totalContraband + data.count
			table.insert(contrabandList, { name = commName, count = data.count })
		end
	end

	if totalContraband <= 0 then return end

	if totalContraband <= shieldedCap then
		-- Completely protected by shielded/concealed cargo racks!
		Comms.Message("PRISON CUSTOMS: Automated bio-magnetic contraband scan passed. Cargo hold clear.", station.label)
		return
	end

	-- Unshielded contraband detected and seized by prison authorities
	local unshieldedTons = totalContraband - shieldedCap
	local remainingToSeize = unshieldedTons
	local seizedItems = {}

	for _, item in ipairs(contrabandList) do
		if remainingToSeize <= 0 then break end
		local seizeFromItem = math.min(item.count, remainingToSeize)
		local comm = Commodities[item.name]
		if comm then
			cargoMgr:RemoveCommodity(comm, seizeFromItem)
			remainingToSeize = remainingToSeize - seizeFromItem
			table.insert(seizedItems, string.format("%d t %s", seizeFromItem, comm.name or item.name))
		end
	end

	-- Fine: 5,000 CR per ton of unshielded contraband
	local fineAmount = unshieldedTons * 5000
	PlayerState.AddCrime("TRADING_ILLEGAL_GOODS", fineAmount)

	local detailStr = table.concat(seizedItems, ", ")
	local msg = string.format("CONTRABAND SEIZED: Starport security confiscated %s. Infraction fine of %s CR assessed to your record.",
		detailStr, Format.Money(fineAmount))
	local senderName = (station.GetLabel and station:GetLabel()) or station.label or "Starport Authority"
	Comms.ImportantMessage(msg, senderName)
end

Event.Register("onShipDocked", function(ship, station)
	if ship and ship:exists() and ship:IsPlayer() then
		PenalSystem.CheckAndSeizeContraband(ship, station)
	end
end)

return PenalSystem


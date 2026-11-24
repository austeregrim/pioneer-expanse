-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Engine = require 'Engine'
local Game = require 'Game'
local Event = require 'Event'
local Mission = require 'Mission'
local Character = require 'Character'
local Format = require 'Format'
local Comms = require 'Comms'
local PlayerState = require 'PlayerState'
local Serializer = require 'Serializer'
local Cartography = require 'modules.Cartography.Cartography'
local MissionUtils = require 'modules.MissionUtils'

local ui = require 'pigui'

local ads = {}
local missions = {}

local function getMissionDescription(m)
	local distLy = string.format("%.1f ly", m.dist)
	if m.requireBodyScan then
		return string.format(
			"Universal Cartographics Priority Survey: Travel to %s (%s), execute a System Discovery Scan, and complete at least one Orbital or Surface scan of a planetary body in the system. Return to %s to claim your %s bonus on top of normal cartographic data payouts.",
			m.targetName, distLy, m.returnStationName, Format.Money(m.reward)
		)
	else
		return string.format(
			"Universal Cartographics Discovery Contract: Travel to the uncharted system %s (%s) and run a System Discovery Scan. Return to %s to claim your %s bonus on top of normal cartographic data payouts.",
			m.targetName, distLy, m.returnStationName, Format.Money(m.reward)
		)
	end
end

local function onChat(form, ref, option)
	local ad = ads[ref]
	if not ad then return end

	form:Clear()

	if option == -1 then
		form:Close()
		return
	end

	if MissionUtils.IsAdExpired(ad, Game.time) then
		form:RemoveAdvertOnClose()
		form:SetMessage("This survey contract has expired.")
		return
	end

	if option == 0 then
		form:SetMessage(ad.intro)
		form:AddOption("Accept survey contract", 1)
		form:AddOption("What equipment is required?", 2)
		form:AddOption("No, thank you.", -1)
	elseif option == 2 then
		if ad.requireBodyScan then
			form:SetMessage("You will need a System Discovery Scanner to map the star system upon arrival, plus an Orbital or Surface Scanner to survey a planetary body. Both can be purchased at the Equipment Market.")
		else
			form:SetMessage("You will need a System Discovery Scanner installed in your ship's discovery slot. Once you arrive in " .. ad.targetName .. ", trigger the Discovery Scan from the Scanner panel.")
		end
		form:AddOption("Accept survey contract", 1)
		form:AddOption("Decline", -1)
	elseif option == 1 then
		local station = Game.player:GetDockedWith()
		if not station then
			form:Close()
			return
		end

		local mission = {
			type = "Cartography",
			client = ad.client,
			location = ad.targetPath,
			targetKey = ad.targetKey,
			targetName = ad.targetName,
			dist = ad.dist,
			requireBodyScan = ad.requireBodyScan,
			discoveredDone = false,
			bodyScanDone = false,
			returnStation = station.path,
			returnStationName = station.label,
			reward = ad.reward,
			due = ad.due or (Game.time + 7 * 24 * 3600),
			status = "ACTIVE",
		}
		mission = Mission.New(mission)
		table.insert(missions, mission)
		MissionUtils.SetupOverdueTimer(mission)

		form:RemoveAdvertOnClose()
		ads[ref] = nil
		form:SetMessage("Contract registered. Safe travels, Commander. Return here once your survey data is collected.")
		form:AddOption("Understood.", -1)
	end
end

local function onDelete(ref)
	ads[ref] = nil
end

local function makeAdvert(station)
	if not Game.system then return end
	local nearby = Game.system:GetNearbySystems(35, function(s)
		return not s.explored
	end)
	if not nearby or #nearby == 0 then return end

	local targetSys = nearby[Engine.rand:Integer(1, #nearby)]
	local dist = Game.system:DistanceTo(targetSys)
	local requireBodyScan = Engine.rand:Integer(1, 2) == 2
	local reward = requireBodyScan
		and (math.floor((8000 + dist * 250) / 100) * 100)
		or (math.floor((3500 + dist * 150) / 100) * 100)
	local dueDur = MissionUtils.TravelTime(dist) * 1.8 + (requireBodyScan and 3 or 2) * 86400
	local due = math.floor((Game.time + dueDur) / 900 + 0.5) * 900
	local timeout = MissionUtils.CalcBoardTimeout(Game.time, dueDur, 48)

	local client = Character.New({
		title = "CARTOGRAPHIC SURVEY DIRECTOR",
		org = "UNIVERSAL CARTOGRAPHICS",
		role = "cartography",
	})

	local ad = {
		station = station,
		client = client,
		targetPath = targetSys.path,
		targetKey = Cartography.GetSystemKey(targetSys.path),
		targetName = targetSys.name,
		dist = dist,
		due = due,
		timeout = timeout,
		requireBodyScan = requireBodyScan,
		reward = reward,
		icon = requireBodyScan and "scout_surface" or "scout_orbital",
		intro = string.format(
			"Universal Cartographics is offering a %s bonus for survey telemetry from the uncharted system %s (%.1f ly away). %s",
			Format.Money(reward),
			targetSys.name,
			dist,
			requireBodyScan
				and "Complete a System Discovery Scan and at least one Orbital or Surface planetary scan, then return here."
				or "Complete a System Discovery Scan upon arrival, then return here."
		),
		desc = string.format(
			"%s: %s (%.1f ly) — Bonus %s",
			requireBodyScan and "Priority Planetary Survey" or "System Discovery Contract",
			targetSys.name,
			dist,
			Format.Money(reward)
		),
	}

	local ref = station:AddAdvert({
		title = ad.desc,
		description = ad.desc,
		icon = ad.icon,
		due = ad.due,
		reward = ad.reward,
		location = ad.targetPath,
		onChat = onChat,
		onDelete = onDelete,
	})
	if ref then
		ads[ref] = ad
	end
end

local function onCreateBB(station)
	if MissionUtils.CountStationAds(ads, station) < 2 and Engine.rand:Integer(1, 100) <= 75 then
		makeAdvert(station)
	end
end

local function onUpdateBB(station)
	for ref, ad in pairs(ads) do
		if ad.station == station and MissionUtils.IsAdExpired(ad, Game.time) then
			ad.station:RemoveAdvert(ref)
		end
	end
	if MissionUtils.CountStationAds(ads, station) < 1 and Engine.rand:Integer(1, 100) <= 35 then
		makeAdvert(station)
	end
end

local function updateMissionStatus(m)
	if m.status == "COMPLETED" then return end
	if m.discoveredDone and (not m.requireBodyScan or m.bodyScanDone) then
		m.status = "COMPLETED"
		Comms.ImportantMessage(string.format(
			"Universal Cartographics contract for %s complete! Return to %s to claim your %s bonus.",
			m.targetName, m.returnStationName, Format.Money(m.reward)
		))
	end
end

local function onSystemDiscovered(system)
	if not system then return end
	local key = Cartography.GetSystemKey(system.path)
	for _, m in ipairs(missions) do
		if m.status == "ACTIVE" and m.targetKey == key then
			m.discoveredDone = true
			updateMissionStatus(m)
		end
	end
end

local function onCartographyScanRecorded(system, body, isOrbital)
	if not system then return end
	local key = Cartography.GetSystemKey(system.path)
	for _, m in ipairs(missions) do
		if m.status == "ACTIVE" and m.targetKey == key then
			m.discoveredDone = true
			m.bodyScanDone = true
			updateMissionStatus(m)
		end
	end
end

local function onShipDocked(player, station)
	if not player:IsPlayer() or not station then return end
	for i = #missions, 1, -1 do
		local m = missions[i]
		if m.status == "COMPLETED" and m.returnStation == station.path then
			PlayerState.AddMoney(m.reward)
			local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')
			if okTax and TaxAuthority and TaxAuthority.RecordCartographyIncome then
				local isHome = TaxAuthority.IsHomeStation and TaxAuthority.IsHomeStation(station) or false
				TaxAuthority.RecordCartographyIncome(m.reward, isHome)
			end
			Comms.ImportantMessage(string.format(
				"Universal Cartographics: %s survey bonus of %s credited! Visit the Universal Cartographics tab to sell your collected system data.",
				m.targetName, Format.Money(m.reward)
			))
			m:Remove()
			table.remove(missions, i)
		end
	end
end

local function onClick(mission)
	return ui.Table({
		{ "Client:", mission.client.name .. " (Universal Cartographics)" },
		{ "Target System:", mission.targetName .. string.format(" (%.1f ly)", mission.dist) },
		{ "Return Station:", mission.returnStationName },
		{ "Bonus Payout:", Format.Money(mission.reward) },
		{ "Objectives:", getMissionDescription(mission) },
	})
end

Mission.RegisterType("Cartography", "Universal Cartographics", onClick)

Event.Register("onCreateBB", onCreateBB)
Event.Register("onUpdateBB", onUpdateBB)
Event.Register("onSystemDiscovered", onSystemDiscovered)
Event.Register("onCartographyScanRecorded", onCartographyScanRecorded)
Event.Register("onShipDocked", onShipDocked)

Serializer:Register("CartographyMissions",
	function() return missions end,
	function(data)
		missions = data or {}
	end
)


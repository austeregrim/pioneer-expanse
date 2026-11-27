-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Character       = require 'Character'
local Comms           = require 'Comms'
local Engine          = require 'Engine'
local Event           = require 'Event'
local FactionRoles    = require 'FactionRoles'
local FactionStanding = require 'FactionStanding'
local Format          = require 'Format'
local Game            = require 'Game'
local Mission         = require 'Mission'
local Passengers      = require 'Passengers'
local PlayerState     = require 'PlayerState'
local Serializer      = require 'Serializer'

local MissionUtils    = require 'modules.MissionUtils'
local FrontlineCommon = require 'modules.FrontlineSupport.FrontlineCommon'

local MAX_STATION_ADS = 3
local MAX_RANGE_LY = 35
local Hours = 3600

local EVACUEE_PROFILES = {
	{ label = "Wounded Military Personnel", role = "Military Personnel" },
	{ label = "Frontline Medical Staff",    role = "Medical Officer" },
	{ label = "Diplomatic Envoys",          role = "Diplomatic Envoy" },
	{ label = "Displaced Civilians",        role = "Civilian Evacuee" },
}

local ads = {}
local missions = {}
local loaded_data = nil

local function isPrisonStation(station)
	if not station then return false end
	local okPenal, PenalSystem = pcall(require, 'modules.Penal.PenalSystem')
	if okPenal and PenalSystem and PenalSystem.IsPrisonStation and PenalSystem.IsPrisonStation(station) then
		return true
	end
	return station.path and FrontlineCommon.IsPrisonStationPath(station.path) or false
end

local function makeClient(factionName, isDispatch)
	local isStateless = (not factionName) or FactionRoles.IsStatelessFaction(factionName)
	local title
	if isDispatch then
		title = isStateless and "Regional Relief Coordinator" or (factionName .. " Evacuation Dispatch")
	else
		title = isStateless and "Civilian Evacuation Marshal" or (factionName .. " Medical & Evac Command")
	end
	return Character.New({ title = title })
end

local function embarkPassengers(ship, list)
	if not ship or not list then return 0 end
	local count = 0
	for _, char in ipairs(list) do
		if Passengers.EmbarkPassenger(ship, char) then
			count = count + 1
		end
	end
	return count
end

local function disembarkPassengers(ship, list)
	if not ship or not list then return end
	for _, char in ipairs(list) do
		pcall(Passengers.DisembarkPassenger, ship, char)
	end
end

local function createEvacueeCharacters(count, role, factionName)
	local list = {}
	for _ = 1, count do
		table.insert(list, Character.New({ role = role, org = factionName }))
	end
	return list
end

local function postAdvert(station, ad)
	local destSys = ad.location:GetStarSystem()
	local destBody = ad.location:GetSystemBody()
	local originBody = ad.originStation:GetSystemBody()
	local originSys = ad.originStation:GetStarSystem()

	local prefix = ad.isDispatch and "[MERCY DISPATCH]" or "[FRONTLINE EVAC]"
	local title = string.format("%s %d %s -> %s",
		prefix, ad.passengers, ad.passengerLabel,
		destSys and destSys.name or "Rear Sector"
	)

	local desc
	if ad.isDispatch then
		desc = string.format(
			"%s Extract %d %s from %s (%s) to %s. Payout: %s.",
			prefix, ad.passengers, ad.passengerLabel,
			originBody and originBody.name or "Frontline Port",
			originSys and originSys.name or ad.crisisSystemName,
			destBody and destBody.name or "Safe Port",
			Format.Money(ad.reward, false)
		)
	else
		desc = string.format(
			"%s Evacuate %d %s to %s (%s). Payout: %s.",
			prefix, ad.passengers, ad.passengerLabel,
			destBody and destBody.name or "Safe Port",
			destSys and destSys.name or "Rear Sector",
			Format.Money(ad.reward, false)
		)
	end

	local onChat
	onChat = function(form, ref, option)
		local curAd = ads[ref]
		form:Clear()

		if option == -1 then
			form:Close()
			return
		end

		if not curAd or MissionUtils.IsAdExpired(curAd, Game.time) then
			form:RemoveAdvertOnClose()
			form:SetMessage("This evacuation posting has expired.")
			return
		end

		form:SetFace(curAd.client)
		form:AddNavButton(curAd.isDispatch and curAd.originStation or curAd.location)

		local enlisted = FrontlineCommon.IsEnlistedInFaction(curAd.factionName)
		local displayReward = FrontlineCommon.ComputeReward(curAd.baseReward, curAd.factionName, enlisted, curAd.crisisSeverity)
		curAd.reward = displayReward

		if option == 0 then
			local destName = (destBody and destBody.name) or "Safe Port"
			local destSysName = (destSys and destSys.name) or "Rear Sector"
			local originName = (originBody and originBody.name) or "Contested Port"
			local originSysName = (originSys and originSys.name) or curAd.crisisSystemName
			local freeBerths = Passengers.CountFreeBerths(Game.player)

			local bonusNote = enlisted
				and string.format("Enlisted Rank Hazard Bonus ACTIVE (%s): payout boosted to %s.", curAd.factionName, Format.Money(displayReward, false))
				or string.format("Independent contractor rate: %s. (Enlisted %s personnel receive rank hazard pay & military XP.)", Format.Money(displayReward, false), curAd.factionName)

			local berthNote = string.format("\nPassenger Berths Required: %d (Your ship currently has %d free).", curAd.passengers, freeBerths)

			local msg
			if curAd.isDispatch then
				msg = string.format(
					"%s requests mercy extraction of %d %s trapped in %s (%s, Severity %d).\n\nProceed to %s in %s (%.1f ly), embark evacuees, and return them to %s in %s before %s.\n\n%s%s",
					curAd.factionName, curAd.passengers, curAd.passengerLabel,
					curAd.crisisSystemName, curAd.crisisType, curAd.crisisSeverity,
					originName, originSysName, curAd.dist,
					destName, destSysName, Format.Date(curAd.due),
					bonusNote, berthNote
				)
			else
				msg = string.format(
					"Emergency evacuation from %s (%s, Severity %d): %d %s require immediate transport out of the conflict zone.\n\nEmbark at %s and deliver safely to %s in %s (%.1f ly) before %s.\n\n%s%s",
					curAd.crisisSystemName, curAd.crisisType, curAd.crisisSeverity,
					curAd.passengers, curAd.passengerLabel,
					originName, destName, destSysName, curAd.dist,
					Format.Date(curAd.due),
					bonusNote, berthNote
				)
			end
			form:SetMessage(msg)
			form:AddOption("Accept evacuation contract", 1)

		elseif option == 1 then
			local passengerList = {}
			local pickupDone = false

			if not curAd.isDispatch then
				local freeBerths = Passengers.CountFreeBerths(Game.player)
				if freeBerths < curAd.passengers then
					form:SetMessage(string.format(
						"Insufficient passenger berths (%d free berths required, %d available).",
						curAd.passengers, freeBerths
					))
					form:RemoveNavButton()
					return
				end

				passengerList = createEvacueeCharacters(curAd.passengers, curAd.passengerRole, curAd.factionName)
				local embarked = embarkPassengers(Game.player, passengerList)
				if embarked < curAd.passengers then
					disembarkPassengers(Game.player, passengerList)
					form:SetMessage(string.format("Unable to embark all %d evacuees. Check cabin availability.", curAd.passengers))
					form:RemoveNavButton()
					return
				end
				pickupDone = true
			end

			form:RemoveAdvertOnClose()
			ads[ref] = nil

			local mission = Mission.New({
				type             = "FrontlineExtraction",
				client           = curAd.client,
				domicile         = curAd.domicile,
				station          = curAd.domicile,
				originStation    = curAd.originStation,
				location         = curAd.location,
				destination      = pickupDone and curAd.location or curAd.originStation,
				passengers       = curAd.passengers,
				passengerRole    = curAd.passengerRole,
				passengerLabel   = curAd.passengerLabel,
				passengerList    = passengerList,
				pickupDone       = pickupDone,
				isDispatch       = curAd.isDispatch,
				factionName      = curAd.factionName,
				crisisSystemName = curAd.crisisSystemName,
				crisisType       = curAd.crisisType,
				crisisSeverity   = curAd.crisisSeverity,
				crisisDelta      = curAd.crisisDelta,
				militaryXP       = curAd.militaryXP,
				reward           = displayReward,
				due              = curAd.due,
				dist             = curAd.dist,
				status           = pickupDone and "ACTIVE" or "TO_PICK_UP",
				fleetAssignedUid = nil,
			})

			table.insert(missions, mission)
			MissionUtils.SetupOverdueTimer(mission)

			if pickupDone then
				form:SetMessage(string.format(
					"All %d %s embarked. Transport safely to %s (%s) before %s.",
					curAd.passengers, curAd.passengerLabel,
					destBody and destBody.name or "safe port",
					destSys and destSys.name or "destination",
					Format.Date(curAd.due)
				))
			else
				form:SetMessage(string.format(
					"Mercy dispatch logged. Proceed to %s (%s) to embark %d %s and return here before %s.",
					originBody and originBody.name or "frontline port",
					originSys and originSys.name or curAd.crisisSystemName,
					curAd.passengers, curAd.passengerLabel,
					Format.Date(curAd.due)
				))
			end
		end
	end

	local ref = station:AddAdvert({
		title       = title,
		description = desc,
		icon        = ad.isDispatch and "taxi" or "taxi_urgent",
		due         = ad.due,
		reward      = ad.reward,
		location    = ad.isDispatch and ad.originStation or ad.location,
		onChat      = onChat,
		onDelete    = function(r) ads[r] = nil end,
		isEnabled   = function(r) return ads[r] ~= nil end,
	})
	ads[ref] = ad
end

local function createFrontlineEvacAd(station, localCrisis)
	local sys = Game.system
	local sysFaction = (sys and sys.faction and sys.faction.name) or "Independent"
	local rearStations = FrontlineCommon.FindRearLineStations(sys.path, sysFaction, MAX_RANGE_LY)
	if #rearStations == 0 then return false end

	local chosen = rearStations[Engine.rand:Integer(1, math.min(#rearStations, 4))]
	local profile = EVACUEE_PROFILES[Engine.rand:Integer(1, #EVACUEE_PROFILES)]
	local severity = localCrisis.severity or 1
	local passengers = Engine.rand:Integer(2, 8)
	local dist = math.max(1.0, chosen.distance or 5.0)
	local travelTime = MissionUtils.TravelTime(dist, chosen.stationPath)
	local dueDur = math.max(14 * Hours, travelTime * Engine.rand:Number(1.4, 1.8))
	local now = Game.time or 0
	local due = now + dueDur
	local timeout = MissionUtils.CalcBoardTimeout(now, dueDur, 24)

	local baseReward = 2000 + dist * 190 + passengers * 420
	local enlisted = FrontlineCommon.IsEnlistedInFaction(sysFaction)
	local reward = FrontlineCommon.ComputeReward(baseReward, sysFaction, enlisted, severity)
	local crisisDelta = math.min(9.0, math.max(3.5, 3.0 + passengers * 0.45 + severity * 0.7))
	local militaryXP = math.min(70, math.max(25, math.floor(20 + passengers * 4 + severity * 5)))

	local ad = {
		station          = station,
		domicile         = station.path,
		originStation    = station.path,
		location         = chosen.stationPath,
		client           = makeClient(sysFaction, false),
		passengers       = passengers,
		passengerRole    = profile.role,
		passengerLabel   = profile.label,
		isDispatch       = false,
		factionName      = sysFaction,
		crisisSystemName = sys.name,
		crisisType       = localCrisis.type or "FRONTLINE",
		crisisSeverity   = severity,
		crisisDelta      = crisisDelta,
		militaryXP       = militaryXP,
		baseReward       = baseReward,
		reward           = reward,
		due              = due,
		timeout          = timeout,
		dist             = dist,
	}
	postAdvert(station, ad)
	return true
end

local function createMercyDispatchAd(station, frontlines)
	local originSys = Game.system
	if not originSys or #frontlines == 0 then return false end

	local originFaction = (originSys.faction and originSys.faction.name) or "Independent"
	local candidates = {}
	for _, fl in ipairs(frontlines) do
		local dist = originSys:DistanceTo(fl.starSystem)
		if dist > 0.01 and dist <= MAX_RANGE_LY then
			local friendly = FactionRoles.IsStatelessFaction(fl.factionName)
				or fl.factionName == originFaction
				or FactionStanding.Get(fl.factionName) > -60
			if friendly then
				for _, stPath in ipairs(fl.starSystem:GetStationPaths()) do
					if not FrontlineCommon.IsPrisonStationPath(stPath) then
						table.insert(candidates, { fl = fl, stationPath = stPath, dist = dist })
					end
				end
			end
		end
	end
	if #candidates == 0 then return false end

	local pick = candidates[Engine.rand:Integer(1, #candidates)]
	local fl = pick.fl
	local profile = EVACUEE_PROFILES[Engine.rand:Integer(1, #EVACUEE_PROFILES)]
	local severity = fl.severity or 1
	local passengers = Engine.rand:Integer(2, 6)
	local dist = math.max(1.0, pick.dist)
	local travelTime = MissionUtils.TravelTime(dist, pick.stationPath) * 2.0
	local dueDur = math.max(18 * Hours, travelTime * Engine.rand:Number(1.5, 1.9))
	local now = Game.time or 0
	local due = now + dueDur
	local timeout = MissionUtils.CalcBoardTimeout(now, dueDur, 24)

	local baseReward = 2400 + dist * 215 + passengers * 460
	local enlisted = FrontlineCommon.IsEnlistedInFaction(fl.factionName)
	local reward = FrontlineCommon.ComputeReward(baseReward, fl.factionName, enlisted, severity)
	local crisisDelta = math.min(9.5, math.max(4.0, 3.5 + passengers * 0.5 + severity * 0.8))
	local militaryXP = math.min(75, math.max(28, math.floor(22 + passengers * 4.5 + severity * 5)))

	local ad = {
		station          = station,
		domicile         = station.path,
		originStation    = pick.stationPath,
		location         = station.path,
		client           = makeClient(fl.factionName, true),
		passengers       = passengers,
		passengerRole    = profile.role,
		passengerLabel   = profile.label,
		isDispatch       = true,
		factionName      = fl.factionName,
		crisisSystemName = fl.systemName,
		crisisType       = fl.crisis and fl.crisis.type or "FRONTLINE",
		crisisSeverity   = severity,
		crisisDelta      = crisisDelta,
		militaryXP       = militaryXP,
		baseReward       = baseReward,
		reward           = reward,
		due              = due,
		timeout          = timeout,
		dist             = dist,
	}
	postAdvert(station, ad)
	return true
end

local function populateStationAds(station, isInitial)
	if not station or not Game.system or isPrisonStation(station) then return end
	if MissionUtils.CountStationAds(ads, station) >= MAX_STATION_ADS then return end

	local localCrisis = FrontlineCommon.GetCrisisForSystem(Game.system.name)
	if localCrisis then
		local targetCount = isInitial and Engine.rand:Integer(1, 2) or 1
		for _ = 1, targetCount do
			if MissionUtils.CountStationAds(ads, station) >= MAX_STATION_ADS then break end
			if not createFrontlineEvacAd(station, localCrisis) then break end
		end
	else
		local frontlines = FrontlineCommon.GetActiveFrontlines(nil, MAX_RANGE_LY)
		if #frontlines == 0 then return end
		if isInitial then
			if Engine.rand:Integer(1, 2) == 1 then
				createMercyDispatchAd(station, frontlines)
			end
		else
			createMercyDispatchAd(station, frontlines)
		end
	end
end

local function onCreateBB(station)
	populateStationAds(station, true)
end

local function onUpdateBB(station)
	local toRefresh = {}
	for ref, ad in pairs(ads) do
		if ad.station == station then
			if MissionUtils.IsAdExpired(ad, Game.time) then
				ad.station:RemoveAdvert(ref)
			else
				local enlisted = FrontlineCommon.IsEnlistedInFaction(ad.factionName)
				local newReward = FrontlineCommon.ComputeReward(ad.baseReward, ad.factionName, enlisted, ad.crisisSeverity)
				if newReward ~= ad.reward then
					ad.reward = newReward
					table.insert(toRefresh, { ref = ref, ad = ad })
				end
			end
		end
	end
	for _, entry in ipairs(toRefresh) do
		station:RemoveAdvert(entry.ref)
		postAdvert(station, entry.ad)
	end
	if MissionUtils.CountStationAds(ads, station) < MAX_STATION_ADS and Engine.rand:Integer(1, 4) == 1 then
		populateStationAds(station, false)
	end
end

local function tryEmbarkDispatchPassengers(mission, player)
	local freeBerths = Passengers.CountFreeBerths(player)
	local clientName = (mission.client and mission.client.name) or "Evacuation Command"
	if freeBerths < mission.passengers then
		Comms.ImportantMessage(
			string.format("Insufficient passenger berths (%d required, %d free) to embark evacuees.", mission.passengers, freeBerths),
			clientName
		)
		return false
	end

	local list = createEvacueeCharacters(mission.passengers, mission.passengerRole, mission.factionName)
	local embarked = embarkPassengers(player, list)
	if embarked < mission.passengers then
		disembarkPassengers(player, list)
		Comms.ImportantMessage("Unable to embark all evacuees. Verify passenger cabin availability.", clientName)
		return false
	end

	mission.passengerList = list
	mission.pickupDone = true
	mission.status = "ACTIVE"
	mission.destination = mission.location

	local destBody = mission.location:GetSystemBody()
	Comms.ImportantMessage(
		string.format("Embarked %d %s. Transport safely to %s immediately.",
			mission.passengers, mission.passengerLabel or "evacuees",
			destBody and destBody.name or "safe port"),
		clientName
	)
	return true
end

local function onPlayerDocked(player, station)
	if not player or not player:IsPlayer() or not station then return end

	-- Pass 1: Expire overdue/failed missions at any port, or complete active evacuations at destination
	for ref, mission in pairs(missions) do
		if not mission.fleetAssignedUid then
			local clientName = (mission.client and mission.client.name) or "Evacuation Command"
			if Game.time > mission.due or mission.status == "FAILED" then
				if mission.pickupDone and mission.passengerList then
					disembarkPassengers(player, mission.passengerList)
				end
				Comms.ImportantMessage("Your frontline extraction deadline has expired. The evacuation window closed.", clientName)
				if mission.factionName and not FactionRoles.IsStatelessFaction(mission.factionName) then
					FactionStanding.ApplyMissionOutcome(mission.factionName, -2, nil, "Frontline extraction expired")
				end
				mission.status = "FAILED"
				mission:Remove()
				missions[ref] = nil
			elseif mission.pickupDone and station.path == mission.location then
				local list = mission.passengerList or {}
				local embarked = Passengers.CheckEmbarked(player, list)
				if embarked < #list then
					disembarkPassengers(player, list)
					Comms.ImportantMessage("Evacuees are missing from your ship manifest. Extraction contract voided.", clientName)
					if mission.factionName and not FactionRoles.IsStatelessFaction(mission.factionName) then
						FactionStanding.ApplyMissionOutcome(mission.factionName, -3, nil, "Frontline evacuees lost in transit")
					end
					mission.status = "FAILED"
					mission:Remove()
					missions[ref] = nil
				else
					disembarkPassengers(player, list)
					PlayerState.AddMoney(mission.reward)

					local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')
					if okTax and TaxAuthority and TaxAuthority.RecordBBSIncome then
						TaxAuthority.RecordBBSIncome(mission.reward, false)
					end

					FrontlineCommon.RecordFrontlineContribution({
						systemName    = mission.crisisSystemName,
						factionName   = mission.factionName,
						crisisDelta   = mission.crisisDelta,
						militaryXP    = mission.militaryXP,
						commendations = 1,
						standingDelta = 4,
						reason        = "Frontline evacuation completed",
						logTitle      = "Frontline Extraction (" .. (mission.crisisSystemName or "Frontline") .. ")",
						reward        = mission.reward,
					})

					Comms.ImportantMessage(
						string.format("Evacuees disembarked safely (%d %s). %s transferred to your account.",
							mission.passengers, mission.passengerLabel or "personnel", Format.Money(mission.reward, false)),
						clientName
					)
					mission.status = "COMPLETED"
					mission:Remove()
					missions[ref] = nil
				end
			end
		end
	end

	-- Pass 2: Pick up Mercy Dispatch evacuees at frontline port
	for _, mission in pairs(missions) do
		if not mission.fleetAssignedUid and not mission.pickupDone
			and station.path == mission.originStation and Game.time <= mission.due and mission.status ~= "FAILED" then
			tryEmbarkDispatchPassengers(mission, player)
		end
	end
end

local function onPlayerUndocked(player, station)
	if not player or not player:IsPlayer() then return end
	for ref, mission in pairs(missions) do
		if not mission.fleetAssignedUid and mission.pickupDone and mission.passengerList and #mission.passengerList > 0 then
			local embarked = Passengers.CheckEmbarked(player, mission.passengerList)
			if embarked < #mission.passengerList then
				disembarkPassengers(player, mission.passengerList)
				local clientName = (mission.client and mission.client.name) or "Evacuation Command"
				Comms.ImportantMessage("Evacuees are no longer aboard! Extraction contract terminated.", clientName)
				if mission.factionName and not FactionRoles.IsStatelessFaction(mission.factionName) then
					FactionStanding.ApplyMissionOutcome(mission.factionName, -3, nil, "Frontline evacuees lost")
				end
				mission.status = "FAILED"
				mission:Remove()
				missions[ref] = nil
			end
		end
	end
end

local function buildMissionDescription(mission)
	local ui = require 'pigui'
	local desc = {}
	local targetPath = mission.pickupDone and mission.location or mission.originStation
	local dist = Game.system and targetPath and string.format("%.2f", Game.system:DistanceTo(targetPath)) or "???"

	local originBody = mission.originStation and mission.originStation:GetSystemBody()
	local destBody = mission.location and mission.location:GetSystemBody()
	local evacLabel = mission.passengerLabel or "Evacuees"

	if mission.isDispatch then
		desc.description = string.format(
			"Mercy Extraction Dispatch for %s (%s): embark %d %s at %s and evacuate to %s for %s.",
			mission.factionName or "Local Authority",
			mission.crisisSystemName or "Frontline",
			mission.passengers, evacLabel,
			originBody and originBody.name or "frontline port",
			destBody and destBody.name or "safe port",
			ui.Format.Money(mission.reward, false)
		)
		desc.location = mission.pickupDone and mission.location or mission.originStation
		desc.returnLocation = mission.location
		desc.details = {
			"Evacuation Pickup",
			{ "Spaceport", originBody and originBody.name or "Unknown" },
			{ "System", ui.Format.SystemPath(mission.originStation) },
			"Safe Destination",
			{ "Spaceport", destBody and destBody.name or "Unknown" },
			{ "System", ui.Format.SystemPath(mission.location) },
			false,
			{ "Evacuees", string.format("%d %s (%s)", mission.passengers, evacLabel, mission.pickupDone and "Aboard" or "Awaiting Pickup") },
			{ "Deadline", ui.Format.Date(mission.due) },
			{ "Payout", ui.Format.Money(mission.reward, false) },
		}
		desc.customActions = {{
			id = "frontline_embark_evacuees",
			label = "Embark Evacuees",
			enabled = function()
				local st = Game.player and Game.player:GetDockedWith()
				return st and not mission.pickupDone
					and not mission.fleetAssignedUid
					and Game.time <= mission.due
					and st.path == mission.originStation
			end,
			onClick = function()
				return tryEmbarkDispatchPassengers(mission, Game.player)
			end,
		}}
	else
		desc.description = string.format(
			"Frontline Extraction for %s (%s): evacuate %d %s to %s for %s.",
			mission.factionName or "Local Authority",
			mission.crisisSystemName or "Frontline",
			mission.passengers, evacLabel,
			destBody and destBody.name or "safe port",
			ui.Format.Money(mission.reward, false)
		)
		desc.location = mission.location
		desc.details = {
			"Safe Destination",
			{ "Spaceport", destBody and destBody.name or "Unknown" },
			{ "System", ui.Format.SystemPath(mission.location) },
			{ "Distance", dist .. " ly" },
			false,
			{ "Evacuees", string.format("%d %s", mission.passengers, evacLabel) },
			{ "Deadline", ui.Format.Date(mission.due) },
			{ "Payout", ui.Format.Money(mission.reward, false) },
		}
	end

	desc.client = mission.client
	return desc
end

local function onGameStart()
	if loaded_data then
		ads = {}
		missions = {}

		if loaded_data.ads then
			for _, ad in pairs(loaded_data.ads) do
				if ad.station and ad.station.exists and ad.station:exists() and not MissionUtils.IsAdExpired(ad, Game.time) then
					if MissionUtils.CountStationAds(ads, ad.station) < MAX_STATION_ADS then
						postAdvert(ad.station, ad)
					end
				end
			end
		end

		missions = loaded_data.missions or {}
		for _, m in pairs(missions) do
			if m.status == "ACTIVE" or m.status == "TO_PICK_UP" then
				if Game.time >= m.due then
					m.status = "FAILED"
				else
					MissionUtils.SetupOverdueTimer(m)
				end
			end
		end
		loaded_data = nil
	end
end

local function onGameEnd()
	ads = {}
	missions = {}
	loaded_data = nil
end

Event.Register("onCreateBB", onCreateBB)
Event.Register("onUpdateBB", onUpdateBB)
Event.Register("onPlayerDocked", onPlayerDocked)
Event.Register("onPlayerUndocked", onPlayerUndocked)
Event.Register("onGameStart", onGameStart)
Event.Register("onGameEnd", onGameEnd)

Mission.RegisterType("FrontlineExtraction", "Frontline Extraction", buildMissionDescription)

Serializer:Register("FrontlineExtraction", function()
	return { ads = ads, missions = missions }
end, function(data)
	loaded_data = data
end)

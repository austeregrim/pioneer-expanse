-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Character       = require 'Character'
local Commodities     = require 'Commodities'
local Comms           = require 'Comms'
local Engine          = require 'Engine'
local Event           = require 'Event'
local FactionRoles    = require 'FactionRoles'
local FactionStanding = require 'FactionStanding'
local Format          = require 'Format'
local Game            = require 'Game'
local Mission         = require 'Mission'
local PlayerState     = require 'PlayerState'
local Serializer      = require 'Serializer'

local MissionUtils    = require 'modules.MissionUtils'
local FrontlineCommon = require 'modules.FrontlineSupport.FrontlineCommon'

local MAX_STATION_ADS = 3
local MAX_RANGE_LY = 35
local Hours = 3600

local LAWFUL_COMMODITIES = {
	"medicines",
	"metal_alloys",
	"air_processors",
	"hydrogen",
	"liquid_oxygen",
	"industrial_machinery",
}

local BLOCKADE_COMMODITIES = {
	"medicines",
	"air_processors",
	"metal_alloys",
	"hand_weapons",
	"battle_weapons",
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

local function getLegalCommodities(pool, originSys, destSys, allowIllegal)
	local valid = {}
	for _, cname in ipairs(pool) do
		local comm = Commodities[cname]
		if comm then
			local originLegal = (not originSys) or originSys:IsCommodityLegal(cname)
			local destLegal = (not destSys) or destSys:IsCommodityLegal(cname)
			if allowIllegal or (originLegal and destLegal) then
				table.insert(valid, {
					name = cname,
					comm = comm,
					illegal = not (originLegal and destLegal),
				})
			end
		end
	end
	return valid
end

local function makeClient(factionName, isBlockade)
	local isStateless = (not factionName) or FactionRoles.IsStatelessFaction(factionName)
	local title
	if isBlockade then
		title = isStateless and "Contested Port Quartermaster" or (factionName .. " Defense Logistics")
	else
		title = isStateless and "Regional Relief Coordinator" or (factionName .. " Fleet Logistics")
	end
	return Character.New({ title = title })
end

local function postAdvert(station, ad)
	local destSys = ad.location:GetStarSystem()
	local destBody = ad.location:GetSystemBody()
	local prefix = ad.isBlockadeRun and "[BLOCKADE RUN]" or "[FRONTLINE CONVOY]"
	local title = string.format("%s %dt %s -> %s", prefix, ad.amount, ad.cargotype:GetName(), ad.crisisSystemName)
	local desc
	if ad.isBlockadeRun then
		desc = string.format(
			"%s Fetch %dt of %s from %s (%s) to %s. Payout: %s.",
			prefix, ad.amount, ad.cargotype:GetName(),
			destBody and destBody.name or "Station",
			destSys and destSys.name or "Nearby",
			ad.crisisSystemName,
			Format.Money(ad.reward, false)
		)
	else
		desc = string.format(
			"%s Deliver %dt of %s to %s (%s). Payout: %s.",
			prefix, ad.amount, ad.cargotype:GetName(),
			destBody and destBody.name or "Station",
			destSys and destSys.name or ad.crisisSystemName,
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
			form:SetMessage("This frontline logistics posting has expired.")
			return
		end

		form:SetFace(curAd.client)
		form:AddNavButton(curAd.location)

		local enlisted = FrontlineCommon.IsEnlistedInFaction(curAd.factionName)
		local displayReward = FrontlineCommon.ComputeReward(curAd.baseReward, curAd.factionName, enlisted, curAd.crisisSeverity)
		curAd.reward = displayReward

		if option == 0 then
			local destName = (destBody and destBody.name) or "Target Port"
			local destSysName = (destSys and destSys.name) or curAd.crisisSystemName
			local domBody = curAd.domicile:GetSystemBody()
			local domName = (domBody and domBody.name) or "this station"
			local bonusNote = enlisted
				and string.format("Enlisted Rank Hazard Bonus ACTIVE (%s): payout boosted to %s.", curAd.factionName, Format.Money(displayReward, false))
				or string.format("Independent contractor rate: %s. (Enlisted %s personnel receive rank hazard pay & military XP.)", Format.Money(displayReward, false), curAd.factionName)
			local contrabandNote = curAd.isCovertContraband
				and "\n\nWARNING: This blockade manifest includes restricted armaments. Expect customs scrutiny and heightened hostile interdiction."
				or ""

			local msg
			if curAd.isBlockadeRun then
				msg = string.format(
					"Contested system %s (%s, Severity %d) urgently needs %dt of %s.\n\nCollect the shipment from %s in %s (%.1f ly) and run the blockade back to %s before %s.\n\n%s%s",
					curAd.crisisSystemName, curAd.crisisType, curAd.crisisSeverity,
					curAd.amount, curAd.cargotype:GetName(),
					destName, destSysName, curAd.dist, domName,
					Format.Date(curAd.due),
					bonusNote, contrabandNote
				)
			else
				msg = string.format(
					"%s is requesting %dt of %s to reinforce %s (%s, Severity %d).\n\nLoad at %s and deliver to %s in %s (%.1f ly) before %s.\n\n%s",
					curAd.factionName, curAd.amount, curAd.cargotype:GetName(),
					curAd.crisisSystemName, curAd.crisisType, curAd.crisisSeverity,
					domName, destName, destSysName, curAd.dist,
					Format.Date(curAd.due),
					bonusNote
				)
			end
			form:SetMessage(msg)
			form:AddOption("Accept frontline logistics contract", 1)

		elseif option == 1 then
			local cargoMgr = Game.player:GetComponent('CargoManager')
			if not curAd.pickup then
				if cargoMgr:GetFreeSpace() < curAd.amount then
					form:SetMessage(string.format("Insufficient free cargo space (%dt required).", curAd.amount))
					form:RemoveNavButton()
					return
				end
				cargoMgr:AddCommodity(curAd.cargotype, curAd.amount)
			end

			form:RemoveAdvertOnClose()
			ads[ref] = nil

			local mission = Mission.New({
				type               = "FrontlineSupply",
				client             = curAd.client,
				domicile           = curAd.domicile,
				station            = curAd.domicile,
				location           = curAd.location,
				destination        = curAd.location,
				cargotype          = curAd.cargotype,
				cargoName          = curAd.cargoName,
				amount             = curAd.amount,
				pickup             = curAd.pickup,
				cargo_picked_up    = (not curAd.pickup),
				isBlockadeRun      = curAd.isBlockadeRun,
				isCovertContraband = curAd.isCovertContraband,
				factionName        = curAd.factionName,
				crisisSystemName   = curAd.crisisSystemName,
				crisisType         = curAd.crisisType,
				crisisSeverity     = curAd.crisisSeverity,
				crisisDelta        = curAd.crisisDelta,
				militaryXP         = curAd.militaryXP,
				reward             = displayReward,
				due                = curAd.due,
				dist               = curAd.dist,
				status             = curAd.pickup and "TO_PICK_UP" or "ACTIVE",
				fleetAssignedUid   = nil,
			})

			table.insert(missions, mission)
			MissionUtils.SetupOverdueTimer(mission)

			if curAd.pickup then
				form:SetMessage(string.format(
					"Contract logged. Proceed to %s (%s) to load %dt of %s and return here before %s.",
					destBody and destBody.name or "the supplier port",
					destSys and destSys.name or "the supply system",
					curAd.amount, curAd.cargotype:GetName(), Format.Date(curAd.due)
				))
			else
				form:SetMessage(string.format(
					"Manifest confirmed: %dt of %s loaded. Deliver to %s (%s) before %s.",
					curAd.amount, curAd.cargotype:GetName(),
					destBody and destBody.name or "destination",
					destSys and destSys.name or curAd.crisisSystemName,
					Format.Date(curAd.due)
				))
			end
		end
	end

	local ref = station:AddAdvert({
		title       = title,
		description = desc,
		icon        = ad.isBlockadeRun and "haul_fast" or "haul",
		due         = ad.due,
		reward      = ad.reward,
		location    = ad.location,
		onChat      = onChat,
		onDelete    = function(r) ads[r] = nil end,
		isEnabled   = function(r) return ads[r] ~= nil end,
	})
	ads[ref] = ad
end

local function createBlockadeRunAd(station, localCrisis)
	local sys = Game.system
	local sysFaction = (sys and sys.faction and sys.faction.name) or "Independent"
	local rearStations = FrontlineCommon.FindRearLineStations(sys.path, sysFaction, MAX_RANGE_LY)
	if #rearStations == 0 then return false end

	local chosen = rearStations[Engine.rand:Integer(1, math.min(#rearStations, 4))]
	local destSys = chosen.starSystem
	local commList = getLegalCommodities(BLOCKADE_COMMODITIES, destSys, sys, true)
	if #commList == 0 then return false end

	local commEntry = commList[Engine.rand:Integer(1, #commList)]
	local severity = localCrisis.severity or 1
	local amount = Engine.rand:Integer(10, 35) + severity * 5
	local dist = math.max(1.0, chosen.distance or 5.0)
	local travelTime = MissionUtils.TravelTime(dist, chosen.stationPath) * 2.0
	local dueDur = math.max(18 * Hours, travelTime * Engine.rand:Number(1.5, 1.8))
	local now = Game.time or 0
	local due = now + dueDur
	local timeout = MissionUtils.CalcBoardTimeout(now, dueDur, 24)

	local baseReward = (2400 + dist * 210 + amount * 85) * (commEntry.illegal and 1.35 or 1.15)
	local enlisted = FrontlineCommon.IsEnlistedInFaction(sysFaction)
	local reward = FrontlineCommon.ComputeReward(baseReward, sysFaction, enlisted, severity)
	local crisisDelta = math.min(10.0, math.max(4.5, 4.0 + amount * 0.08 + severity * 0.8))
	local militaryXP = math.min(75, math.max(30, math.floor(28 + amount * 0.6 + severity * 6)))

	local ad = {
		station            = station,
		domicile           = station.path,
		location           = chosen.stationPath,
		client             = makeClient(sysFaction, true),
		cargotype          = commEntry.comm,
		cargoName          = commEntry.name,
		amount             = amount,
		pickup             = true,
		isBlockadeRun      = true,
		isCovertContraband = commEntry.illegal,
		factionName        = sysFaction,
		crisisSystemName   = sys.name,
		crisisType         = localCrisis.type or "BLOCKADE",
		crisisSeverity     = severity,
		crisisDelta        = crisisDelta,
		militaryXP         = militaryXP,
		baseReward         = baseReward,
		reward             = reward,
		due                = due,
		timeout            = timeout,
		dist               = dist,
	}
	postAdvert(station, ad)
	return true
end

local function createSupplyConvoyAd(station, frontlines)
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
				local stPaths = fl.starSystem:GetStationPaths()
				for _, stPath in ipairs(stPaths) do
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
	local commList = getLegalCommodities(LAWFUL_COMMODITIES, originSys, fl.starSystem, false)
	if #commList == 0 then return false end

	local commEntry = commList[Engine.rand:Integer(1, #commList)]
	local severity = fl.severity or 1
	local amount = Engine.rand:Integer(12, 40) + severity * 5
	local dist = math.max(1.0, pick.dist)
	local travelTime = MissionUtils.TravelTime(dist, pick.stationPath)
	local dueDur = math.max(12 * Hours, travelTime * Engine.rand:Number(1.5, 1.8))
	local now = Game.time or 0
	local due = now + dueDur
	local timeout = MissionUtils.CalcBoardTimeout(now, dueDur, 24)

	local baseReward = 1800 + dist * 175 + amount * 70
	local enlisted = FrontlineCommon.IsEnlistedInFaction(fl.factionName)
	local reward = FrontlineCommon.ComputeReward(baseReward, fl.factionName, enlisted, severity)
	local crisisDelta = math.min(10.0, math.max(4.0, 3.5 + amount * 0.07 + severity * 0.7))
	local militaryXP = math.min(75, math.max(25, math.floor(22 + amount * 0.5 + severity * 5)))

	local ad = {
		station            = station,
		domicile           = station.path,
		location           = pick.stationPath,
		client             = makeClient(fl.factionName, false),
		cargotype          = commEntry.comm,
		cargoName          = commEntry.name,
		amount             = amount,
		pickup             = false,
		isBlockadeRun      = false,
		isCovertContraband = false,
		factionName        = fl.factionName,
		crisisSystemName   = fl.systemName,
		crisisType         = fl.crisis and fl.crisis.type or "FRONTLINE",
		crisisSeverity     = severity,
		crisisDelta        = crisisDelta,
		militaryXP         = militaryXP,
		baseReward         = baseReward,
		reward             = reward,
		due                = due,
		timeout            = timeout,
		dist               = dist,
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
			if not createBlockadeRunAd(station, localCrisis) then break end
		end
	else
		local frontlines = FrontlineCommon.GetActiveFrontlines(nil, MAX_RANGE_LY)
		if #frontlines == 0 then return end
		local targetCount = isInitial and Engine.rand:Integer(1, 3) or 1
		for _ = 1, targetCount do
			if MissionUtils.CountStationAds(ads, station) >= MAX_STATION_ADS then break end
			if not createSupplyConvoyAd(station, frontlines) then break end
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

local function tryLoadPickupCargo(mission, player)
	local cargoMgr = player:GetComponent('CargoManager')
	local comm = mission.cargotype or (mission.cargoName and Commodities[mission.cargoName])
	if not comm then return false end

	if cargoMgr:GetFreeSpace() < mission.amount then
		Comms.ImportantMessage(
			string.format("Insufficient free cargo space (%dt required) to load frontline shipment.", mission.amount),
			mission.client and mission.client.name or "Frontline Logistics"
		)
		return false
	end

	cargoMgr:AddCommodity(comm, mission.amount)
	mission.cargotype = comm
	mission.cargo_picked_up = true
	mission.status = "ACTIVE"
	mission.destination = mission.domicile
	Comms.ImportantMessage(
		string.format("Loaded %dt of %s. Return to %s (%s) immediately.", mission.amount, comm:GetName(), mission.domicile:GetSystemBody().name, mission.crisisSystemName),
		mission.client and mission.client.name or "Frontline Logistics"
	)
	return true
end

local function onPlayerDocked(player, station)
	if not player or not player:IsPlayer() or not station then return end
	local cargoMgr = player:GetComponent('CargoManager')

	-- Pass 1: Expire overdue/failed missions at any port, or complete deliveries at target port
	for ref, mission in pairs(missions) do
		if not mission.fleetAssignedUid then
			local clientName = (mission.client and mission.client.name) or "Frontline Command"
			if Game.time > mission.due or mission.status == "FAILED" then
				Comms.ImportantMessage("Your frontline logistics deadline has expired. The relief window closed.", clientName)
				if mission.factionName and not FactionRoles.IsStatelessFaction(mission.factionName) then
					FactionStanding.ApplyMissionOutcome(mission.factionName, -2, nil, "Frontline supply contract expired")
				end
				mission.status = "FAILED"
				mission:Remove()
				missions[ref] = nil
			else
				local deliveryTarget = mission.pickup and mission.domicile or mission.location
				local readyForDelivery = (station.path == deliveryTarget) and (not mission.pickup or mission.cargo_picked_up)

				if readyForDelivery then
					local comm = mission.cargotype or (mission.cargoName and Commodities[mission.cargoName])
					local aboard = comm and cargoMgr:CountCommodity(comm) or 0
					if aboard < mission.amount then
						Comms.ImportantMessage(
							string.format("Cannot finalize delivery: %dt of %s required, %dt aboard.", mission.amount, comm and comm:GetName() or "cargo", aboard),
							clientName
						)
					else
						cargoMgr:RemoveCommodity(comm, mission.amount)
						PlayerState.AddMoney(mission.reward)

						local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')
						if okTax and TaxAuthority and TaxAuthority.RecordBBSIncome then
							TaxAuthority.RecordBBSIncome(mission.reward, false)
						end

						-- Honors full payout and military XP even if the crisis resolved while en route
						FrontlineCommon.RecordFrontlineContribution({
							systemName    = mission.crisisSystemName,
							factionName   = mission.factionName,
							crisisDelta   = mission.crisisDelta,
							militaryXP    = mission.militaryXP,
							commendations = 1,
							standingDelta = mission.isBlockadeRun and 4 or 3,
							reason        = mission.isBlockadeRun and "Blockade run completed" or "Frontline supply convoy delivered",
							logTitle      = mission.isBlockadeRun and ("Blockade Run (" .. mission.crisisSystemName .. ")") or ("Frontline Convoy (" .. mission.crisisSystemName .. ")"),
							reward        = mission.reward,
						})

						Comms.ImportantMessage(
							string.format("Shipment verified and unloaded (%dt %s). %s transferred to your account.",
								mission.amount, comm:GetName(), Format.Money(mission.reward, false)),
							clientName
						)
						mission.status = "COMPLETED"
						mission:Remove()
						missions[ref] = nil
					end
				end
			end
		end
	end

	-- Pass 2: Pick up Blockade Run cargo at supplier station
	for _, mission in pairs(missions) do
		if not mission.fleetAssignedUid and mission.pickup and not mission.cargo_picked_up
			and station.path == mission.location and Game.time <= mission.due and mission.status ~= "FAILED" then
			tryLoadPickupCargo(mission, player)
		end
	end
end

local function buildMissionDescription(mission)
	local ui = require 'pigui'
	local comm = mission.cargotype or (mission.cargoName and Commodities[mission.cargoName])
	local commName = comm and comm:GetName():scase() or (mission.cargoName or "Supplies")
	local desc = {}

	local targetPath = mission.pickup and mission.domicile or mission.location
	local dist = Game.system and targetPath and string.format("%.2f", Game.system:DistanceTo(targetPath)) or "???"

	if mission.pickup then
		local pickupBody = mission.location:GetSystemBody()
		local delivBody = mission.domicile:GetSystemBody()
		desc.description = string.format(
			"Blockade Runner contract for %s (%s): collect %dt of %s from %s and deliver to %s (%s) for %s.",
			mission.factionName or "Local Authority",
			mission.crisisSystemName or "Frontline",
			mission.amount, commName,
			pickupBody and pickupBody.name or "supplier port",
			delivBody and delivBody.name or "contested port",
			mission.crisisSystemName or "Frontline",
			ui.Format.Money(mission.reward, false)
		)
		desc.location = mission.cargo_picked_up and mission.domicile or mission.location
		desc.returnLocation = mission.domicile
		desc.details = {
			"Pickup Port",
			{ "Spaceport", pickupBody and pickupBody.name or "Unknown" },
			{ "System", ui.Format.SystemPath(mission.location) },
			"Delivery Port",
			{ "Spaceport", delivBody and delivBody.name or "Unknown" },
			{ "System", ui.Format.SystemPath(mission.domicile) },
			false,
			{ "Cargo", commName },
			{ "Amount", string.format("%dt (%s)", mission.amount, mission.cargo_picked_up and "Loaded" or "Awaiting Pickup") },
			{ "Deadline", ui.Format.Date(mission.due) },
			{ "Payout", ui.Format.Money(mission.reward, false) },
		}
		desc.customActions = {{
			id = "frontline_load_cargo",
			label = "Load Blockade Cargo",
			enabled = function()
				local st = Game.player and Game.player:GetDockedWith()
				return st and mission.pickup and not mission.cargo_picked_up
					and not mission.fleetAssignedUid
					and Game.time <= mission.due
					and st.path == mission.location
			end,
			onClick = function()
				return tryLoadPickupCargo(mission, Game.player)
			end,
		}}
	else
		local delivBody = mission.location:GetSystemBody()
		desc.description = string.format(
			"Frontline Supply Convoy for %s (%s): deliver %dt of %s to %s for %s.",
			mission.factionName or "Local Authority",
			mission.crisisSystemName or "Frontline",
			mission.amount, commName,
			delivBody and delivBody.name or "destination port",
			ui.Format.Money(mission.reward, false)
		)
		desc.location = mission.location
		desc.details = {
			"Delivery Port",
			{ "Spaceport", delivBody and delivBody.name or "Unknown" },
			{ "System", ui.Format.SystemPath(mission.location) },
			{ "Distance", dist .. " ly" },
			false,
			{ "Cargo", commName },
			{ "Amount", string.format("%dt", mission.amount) },
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
						ad.cargotype = ad.cargotype or (ad.cargoName and Commodities[ad.cargoName])
						if ad.cargotype then
							postAdvert(ad.station, ad)
						end
					end
				end
			end
		end

		missions = loaded_data.missions or {}
		for _, m in pairs(missions) do
			m.cargotype = m.cargotype or (m.cargoName and Commodities[m.cargoName])
			if (m.status == "ACTIVE" or m.status == "TO_PICK_UP") then
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
Event.Register("onGameStart", onGameStart)
Event.Register("onGameEnd", onGameEnd)

Mission.RegisterType("FrontlineSupply", "Frontline Supply", buildMissionDescription)

Serializer:Register("FrontlineLogistics", function()
	return { ads = ads, missions = missions }
end, function(data)
	loaded_data = data
end)

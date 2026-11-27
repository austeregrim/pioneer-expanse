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
local PlayerState     = require 'PlayerState'
local Serializer      = require 'Serializer'
local Timer           = require 'Timer'
local utils           = require 'utils'

local MissionUtils    = require 'modules.MissionUtils'
local ScanManager     = require 'modules.Scout.ScanManager'
local FrontlineCommon = require 'modules.FrontlineSupport.FrontlineCommon'

local MAX_STATION_ADS = 2
local MAX_RANGE_LY = 35
local Hours = 3600
local LIGHT_SPEED = 299792458.0
local STEALTH_BONUS_MULT = 0.25
local STEALTH_BONUS_XP = 15

local ads = {}
local missions = {}
local missionKey = {}
local loaded_data = nil
local stealthTimerActive = false

local function isPrisonStation(station)
	if not station then return false end
	local okPenal, PenalSystem = pcall(require, 'modules.Penal.PenalSystem')
	if okPenal and PenalSystem and PenalSystem.IsPrisonStation and PenalSystem.IsPrisonStation(station) then
		return true
	end
	return station.path and FrontlineCommon.IsPrisonStationPath(station.path) or false
end

local function makeClient(factionName)
	local isStateless = (not factionName) or FactionRoles.IsStatelessFaction(factionName)
	local title = isStateless and "Sector Telemetry Broker" or (factionName .. " Tactical Reconnaissance")
	return Character.New({ title = title })
end

local function ensureScanManager(player)
	if not player then return nil end
	local mgr = player:GetComponent("ScanManager")
	if not mgr then
		mgr = ScanManager.New(player)
		player:SetComponent("ScanManager", mgr)
	end
	return mgr
end

local function isPlayerDarkRunning(player)
	if not player or not player:exists() then return false end
	local transponderOn = (player.GetTransponder and player:GetTransponder()) or false
	local speed
	if player.IsSupercruiseActive and player:IsSupercruiseActive() and player.GetSupercruiseSpeed then
		speed = player:GetSupercruiseSpeed()
	else
		speed = player:GetVelocity():length()
	end
	return (not transponderOn) and (speed < LIGHT_SPEED)
end

local function hasActiveReconInCurrentSystem()
	if not Game.system or Game.InHyperspace() then return false end
	local curPath = Game.system.path
	for _, m in pairs(missions) do
		if not m.fleetAssignedUid and not m.scanComplete and m.status == "ACTIVE"
			and m.location and m.location:IsSameSystem(curPath) then
			return true
		end
	end
	return false
end

local function ensureStealthPoller()
	if stealthTimerActive then return end
	if not hasActiveReconInCurrentSystem() then return end

	stealthTimerActive = true
	Timer:CallEvery(2, function()
		if not Game.player or not Game.player:exists() or not hasActiveReconInCurrentSystem() then
			stealthTimerActive = false
			return true
		end

		local scanMgr = Game.player:GetComponent("ScanManager")
		local _, curFine = PlayerState.GetCrimeOutstanding()
		local fineVal = curFine or 0
		local darkNow = isPlayerDarkRunning(Game.player)
		local curPath = Game.system.path

		for _, m in pairs(missions) do
			if not m.fleetAssignedUid and not m.scanComplete and m.status == "ACTIVE"
				and m.location and m.location:IsSameSystem(curPath) then
				if fineVal > (m.baselineFine or 0) then
					m.stealthMaintained = false
				end
				local scan = scanMgr and m.scanId and scanMgr.scanMap and scanMgr.scanMap[m.scanId]
				if scan and scan.coverage > (m.lastScanCoverage or 0) + 1e-6 then
					m.lastScanCoverage = scan.coverage
					m.stealthSampleCount = (m.stealthSampleCount or 0) + 1
					if not darkNow then
						m.stealthMaintained = false
					end
				end
			end
		end

		return false
	end)
end

local function pickTargetBody(starSystem, excludeParentBody)
	if not starSystem then return nil, nil end
	local bodyPaths = starSystem:GetBodyPaths()
	if not bodyPaths or #bodyPaths == 0 then return nil, nil end

	local preferred = {}
	local fallback = {}
	for _, bPath in ipairs(bodyPaths) do
		local ok, sBody = pcall(function() return bPath:GetSystemBody() end)
		if ok and sBody and (sBody.superType == "ROCKY_PLANET" or sBody.superType == "GAS_GIANT")
			and sBody.type ~= "PLANET_ASTEROID" and (sBody.radius or 0) >= 150000 then
			if excludeParentBody and sBody == excludeParentBody then
				table.insert(fallback, { path = bPath, body = sBody })
			else
				table.insert(preferred, { path = bPath, body = sBody })
			end
		end
	end

	local pool = (#preferred > 0) and preferred or fallback
	if #pool == 0 then return nil, nil end
	local pick = pool[Engine.rand:Integer(1, #pool)]
	return pick.path, pick.body
end

local function calcTacticalOrbitalScan(sBody, severity)
	local nominalRadius = 2500.0
	local radiusKm = math.max(150.0, (sBody.radius or 2500000) / 1000.0)
	local radiusScalar = nominalRadius / radiusKm

	local baseFrac = Engine.rand:Number(0.006, 0.018)
	local bodyCoverage
	if radiusScalar > 1.0 then
		bodyCoverage = math.min(baseFrac, 1.0) * (radiusScalar ^ 0.9)
	else
		bodyCoverage = math.min(baseFrac, 1.0) * radiusScalar
	end

	local sevFactor = 1.0 + math.max(0, (severity or 1) - 1) * 0.15
	bodyCoverage = math.clamp(bodyCoverage * sevFactor, 0.002, 0.35)

	local bodyArea = 4.0 * math.pi * (radiusKm ^ 2)
	local coverageKm2 = math.max(50.0, utils.round(bodyArea * bodyCoverage, 0.0001))

	local resolution = Engine.rand:Number(45, 110)
	if radiusScalar < 1.0 then
		resolution = resolution * (1.0 + math.log(radiusKm / nominalRadius, 10))
	end
	resolution = utils.round(math.max(25.0, resolution), 0.1)

	return coverageKm2, resolution
end

local function postAdvert(station, ad)
	local targetBody = ad.location:GetSystemBody()
	local targetSys = ad.location:GetStarSystem()
	local bodyName = (targetBody and targetBody.name) or "Target Body"
	local sysName = (targetSys and targetSys.name) or ad.crisisSystemName

	local title = string.format("[FRONTLINE RECON] %s (%s)", bodyName, sysName)
	local desc = string.format(
		"[FRONTLINE RECON] Orbital telemetry sweep of %s (%s). Payout: %s (+25%% dark-running bonus).",
		bodyName, sysName, Format.Money(ad.reward, false)
	)

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
			form:SetMessage("This tactical reconnaissance posting has expired.")
			return
		end

		form:SetFace(curAd.client)
		form:AddNavButton(curAd.location)

		local enlisted = FrontlineCommon.IsEnlistedInFaction(curAd.factionName)
		local displayReward = FrontlineCommon.ComputeReward(curAd.baseReward, curAd.factionName, enlisted, curAd.crisisSeverity)
		curAd.reward = displayReward

		if option == 0 then
			local ui = require 'pigui'
			local bonusNote = enlisted
				and string.format("Enlisted Rank Hazard Bonus ACTIVE (%s): base payout boosted to %s.", curAd.factionName, Format.Money(displayReward, false))
				or string.format("Independent contractor rate: %s. (Enlisted %s personnel receive rank hazard pay & military XP.)", Format.Money(displayReward, false), curAd.factionName)

			local stealthNote = "[OPTIONAL STEALTH BONUS] Run dark (<1c, transponder OFF, no citations) during telemetry sweep for +25% hazard pay and +15 military XP."

			local msg = string.format(
				"%s requires orbital telemetry over %s in contested system %s (%s, Severity %d; %.1f ly).\n\nRequired Coverage: %s | Min Resolution: %s\nReturn encrypted data before %s.\n\n%s\n\n%s",
				curAd.factionName, bodyName, curAd.crisisSystemName, curAd.crisisType, curAd.crisisSeverity, curAd.dist,
				ui.Format.Area(curAd.coverage * 1e6), ui.Format.Distance(curAd.resolution, "%.1f"),
				Format.Date(curAd.due),
				bonusNote, stealthNote
			)
			form:SetMessage(msg)
			form:AddOption("Accept frontline recon contract", 1)

		elseif option == 1 then
			local scanMgr = ensureScanManager(Game.player)
			if not scanMgr or not scanMgr:HasSensorOfType(true) then
				form:SetMessage("An Orbital Scanner module is required to accept frontline reconnaissance contracts.")
				form:RemoveNavButton()
				return
			end

			local scanId = scanMgr:AddNewOrbitalScan(curAd.location, curAd.resolution, curAd.coverage)
			local _, curFine = PlayerState.GetCrimeOutstanding()

			form:RemoveAdvertOnClose()
			ads[ref] = nil

			local mission = Mission.New({
				type               = "FrontlineRecon",
				client             = curAd.client,
				station            = curAd.domicile,
				backstation        = curAd.domicile,
				domicile           = curAd.domicile,
				location           = curAd.location,
				destination        = curAd.location,
				scanId             = scanId,
				coverage           = curAd.coverage,
				resolution         = curAd.resolution,
				orbital            = true,
				scanComplete       = false,
				stealthMaintained  = true,
				stealthSampleCount = 0,
				lastScanCoverage   = 0.0,
				baselineFine       = curFine or 0,
				factionName        = curAd.factionName,
				crisisSystemName   = curAd.crisisSystemName,
				crisisType         = curAd.crisisType,
				crisisSeverity     = curAd.crisisSeverity,
				crisisDelta        = curAd.crisisDelta,
				militaryXP         = curAd.militaryXP,
				reward             = displayReward,
				due                = curAd.due,
				dist               = curAd.dist,
				status             = "ACTIVE",
				fleetAssignedUid   = nil,
			})

			table.insert(missions, mission)
			missionKey[scanId] = mission
			MissionUtils.SetupOverdueTimer(mission)
			ensureStealthPoller()

			form:SetMessage(string.format(
				"Telemetry parameters uploaded for %s (%s). Complete the orbital sweep and return data before %s.",
				bodyName, curAd.crisisSystemName, Format.Date(curAd.due)
			))
		end
	end

	local ref = station:AddAdvert({
		title       = title,
		description = desc,
		icon        = "scout_orbital",
		due         = ad.due,
		reward      = ad.reward,
		location    = ad.location,
		onChat      = onChat,
		onDelete    = function(r) ads[r] = nil end,
		isEnabled   = function(r) return ads[r] ~= nil end,
	})
	ads[ref] = ad
end

local function createReconAdForCrisis(station, crisisInfo, distLy)
	local stationBody = station:GetSystemBody()
	local excludeBody = (stationBody and stationBody.parent) or nil
	local bodyPath, sBody = pickTargetBody(crisisInfo.starSystem, excludeBody)
	if not bodyPath or not sBody then return false end

	local severity = crisisInfo.severity or 1
	local coverageKm2, resolution = calcTacticalOrbitalScan(sBody, severity)
	local dist = math.max(0.5, distLy or 0.5)
	local isLocal = (distLy or 0) < 0.01

	local travelTime = isLocal and (4 * Hours) or (MissionUtils.TravelTime(dist, bodyPath) * 2.0)
	local dueDur = math.max(isLocal and (10 * Hours) or (16 * Hours), travelTime * Engine.rand:Number(1.4, 1.8))
	local now = Game.time or 0
	local due = now + dueDur
	local timeout = MissionUtils.CalcBoardTimeout(now, dueDur, 24)

	local baseReward = (isLocal and 1600 or 2200) + dist * 165 + math.sqrt(coverageKm2) * 14
	local enlisted = FrontlineCommon.IsEnlistedInFaction(crisisInfo.factionName)
	local reward = FrontlineCommon.ComputeReward(baseReward, crisisInfo.factionName, enlisted, severity)
	local crisisDelta = math.min(9.0, math.max(3.5, 3.5 + severity * 1.1))
	local militaryXP = math.min(70, math.max(25, math.floor(24 + severity * 7)))

	local ad = {
		station          = station,
		domicile         = station.path,
		location         = bodyPath,
		client           = makeClient(crisisInfo.factionName),
		coverage         = coverageKm2,
		resolution       = resolution,
		factionName      = crisisInfo.factionName,
		crisisSystemName = crisisInfo.systemName,
		crisisType       = crisisInfo.crisis and crisisInfo.crisis.type or "FRONTLINE",
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
		local sysFaction = (Game.system.faction and Game.system.faction.name) or "Independent"
		local crisisInfo = {
			crisis      = localCrisis,
			systemName  = Game.system.name,
			systemPath  = Game.system.path:SystemOnly(),
			starSystem  = Game.system,
			factionName = sysFaction,
			severity    = localCrisis.severity or 1,
		}
		createReconAdForCrisis(station, crisisInfo, 0)
		return
	end

	local frontlines = FrontlineCommon.GetActiveFrontlines(nil, MAX_RANGE_LY)
	if #frontlines == 0 then return end

	local originFaction = (Game.system.faction and Game.system.faction.name) or "Independent"
	local candidates = {}
	for _, fl in ipairs(frontlines) do
		local dist = Game.system:DistanceTo(fl.starSystem)
		if dist > 0.01 and dist <= MAX_RANGE_LY then
			local friendly = FactionRoles.IsStatelessFaction(fl.factionName)
				or fl.factionName == originFaction
				or FactionStanding.Get(fl.factionName) > -60
			if friendly then
				table.insert(candidates, { fl = fl, dist = dist })
			end
		end
	end
	if #candidates == 0 then return end

	local targetCount = isInitial and Engine.rand:Integer(1, MAX_STATION_ADS) or 1
	for _ = 1, targetCount do
		if MissionUtils.CountStationAds(ads, station) >= MAX_STATION_ADS then break end
		local pick = candidates[Engine.rand:Integer(1, #candidates)]
		if not createReconAdForCrisis(station, pick.fl, pick.dist) then break end
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

local function onScanComplete(player, scanId)
	local mission = missionKey[scanId]
	if not mission then return end

	local _, curFine = PlayerState.GetCrimeOutstanding()
	if (curFine or 0) > (mission.baselineFine or 0) then
		mission.stealthMaintained = false
	end
	if (mission.stealthSampleCount or 0) == 0 then
		if not isPlayerDarkRunning(player) then
			mission.stealthMaintained = false
		end
	end

	mission.scanComplete = true
	mission.destination = mission.backstation

	local clientName = (mission.client and mission.client.name) or "Tactical Recon"
	local retBody = mission.backstation and mission.backstation:GetSystemBody()
	local retSys = mission.backstation and mission.backstation:GetStarSystem()
	local stealthMsg = mission.stealthMaintained
		and "Dark-running telemetry verified (+25% Stealth Recon Bonus secured)."
		or "Standard telemetry captured (stealth parameters were broken)."

	Comms.ImportantMessage(
		string.format("Orbital sweep complete. %s Return to %s (%s) to transmit encrypted telemetry.",
			stealthMsg,
			retBody and retBody.name or "command station",
			retSys and retSys.name or "sector"),
		clientName
	)
end

local function cleanupScan(scanMgr, scanId)
	if not scanMgr or not scanId then return end
	local scan = scanMgr:AcceptScanComplete(scanId)
	if not scan then
		scanMgr:CancelScan(scanId)
	end
end

local function isValidTurnInStation(mission, station)
	if station.path == mission.backstation then
		return true
	end
	if Game.system and Game.system.faction and mission.factionName
		and not FactionRoles.IsStatelessFaction(mission.factionName) then
		return Game.system.faction.name == mission.factionName
	end
	return false
end

local function onPlayerDocked(player, station)
	if not player or not player:IsPlayer() or not station then return end
	local scanMgr = player:GetComponent("ScanManager")

	for ref, mission in pairs(missions) do
		if not mission.fleetAssignedUid then
			local clientName = (mission.client and mission.client.name) or "Tactical Recon"
			if Game.time > mission.due or mission.status == "FAILED" then
				cleanupScan(scanMgr, mission.scanId)
				Comms.ImportantMessage("Your frontline reconnaissance window has expired. Telemetry discarded.", clientName)
				if mission.factionName and not FactionRoles.IsStatelessFaction(mission.factionName) then
					FactionStanding.ApplyMissionOutcome(mission.factionName, -2, nil, "Frontline recon contract expired")
				end
				mission.status = "FAILED"
				mission:Remove()
				missions[ref] = nil
				if mission.scanId then missionKey[mission.scanId] = nil end
			elseif mission.scanComplete and isValidTurnInStation(mission, station) then
				if scanMgr and mission.scanId then
					scanMgr:AcceptScanComplete(mission.scanId)
				end

				local stealthEarned = (mission.stealthMaintained == true)
				local bonusPay = stealthEarned and math.floor(mission.reward * STEALTH_BONUS_MULT + 0.5) or 0
				local totalReward = mission.reward + bonusPay
				local totalXP = (mission.militaryXP or 30) + (stealthEarned and STEALTH_BONUS_XP or 0)

				PlayerState.AddMoney(totalReward)
				local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')
				if okTax and TaxAuthority and TaxAuthority.RecordBBSIncome then
					TaxAuthority.RecordBBSIncome(totalReward, false)
				end

				FrontlineCommon.RecordFrontlineContribution({
					systemName    = mission.crisisSystemName,
					factionName   = mission.factionName,
					crisisDelta   = mission.crisisDelta,
					militaryXP    = totalXP,
					commendations = stealthEarned and 2 or 1,
					standingDelta = stealthEarned and 4 or 3,
					reason        = stealthEarned and "Covert dark-running frontline recon completed" or "Frontline orbital recon completed",
					logTitle      = "Frontline Recon (" .. (mission.crisisSystemName or "Frontline") .. ")",
					reward        = totalReward,
				})

				local msg = stealthEarned
					and string.format("Encrypted telemetry verified with Dark-Running Stealth Bonus (+%s). Total %s transferred.",
						Format.Money(bonusPay, false), Format.Money(totalReward, false))
					or string.format("Encrypted telemetry verified and uploaded. %s transferred to your account.",
						Format.Money(totalReward, false))
				Comms.ImportantMessage(msg, clientName)

				mission.status = "COMPLETED"
				mission:Remove()
				missions[ref] = nil
				if mission.scanId then missionKey[mission.scanId] = nil end
			end
		end
	end
end

local function buildMissionDescription(mission)
	local ui = require 'pigui'
	local desc = {}
	local targetPath = mission.scanComplete and mission.backstation or mission.location
	local dist = Game.system and targetPath and string.format("%.2f", Game.system:DistanceTo(targetPath)) or "???"

	local targetBody = mission.location and mission.location:GetSystemBody()
	local retBody = mission.backstation and mission.backstation:GetSystemBody()

	desc.description = string.format(
		"Frontline Orbital Recon for %s (%s): sweep %s and return encrypted telemetry to %s for %s (+25%% dark-running bonus).",
		mission.factionName or "Local Authority",
		mission.crisisSystemName or "Frontline",
		targetBody and targetBody.name or "target body",
		retBody and retBody.name or "command station",
		ui.Format.Money(mission.reward, false)
	)

	if mission.scanComplete then
		desc.returnLocation = mission.backstation
	else
		desc.location = mission.location
	end

	local stealthText = mission.stealthMaintained
		and "INTACT (+25% bonus)"
		or "COMPROMISED (standard rate)"

	desc.details = {
		"Recon Target",
		{ "System", ui.Format.SystemPath(mission.location) },
		{ "Target Body", targetBody and targetBody.name or "Unknown" },
		{ "Coverage", ui.Format.Area((mission.coverage or 0) * 1e6) },
		{ "Min Resolution", ui.Format.Distance(mission.resolution or 50, "%.1f") },
		{ "Distance", dist .. " ly" },
		false,
		"Return Port",
		{ "Spaceport", retBody and retBody.name or "Unknown" },
		{ "System", ui.Format.SystemPath(mission.backstation) },
		false,
		{ "Telemetry", mission.scanComplete and "Sweep Complete (Return Data)" or "Orbital Sweep Pending" },
		{ "Dark-Running", stealthText },
		{ "Deadline", ui.Format.Date(mission.due) },
		{ "Base Payout", ui.Format.Money(mission.reward, false) },
	}

	desc.client = mission.client
	return desc
end

local function onEnterSystem()
	ensureStealthPoller()
end

local function onGameStart()
	ensureScanManager(Game.player)
	stealthTimerActive = false

	if loaded_data then
		ads = {}
		missions = {}
		missionKey = {}

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
			if m.scanId then
				missionKey[m.scanId] = m
			end
			if m.status == "ACTIVE" then
				if Game.time >= m.due then
					m.status = "FAILED"
				else
					MissionUtils.SetupOverdueTimer(m)
				end
			end
		end
		loaded_data = nil
	end

	ensureStealthPoller()
end

local function onGameEnd()
	ads = {}
	missions = {}
	missionKey = {}
	loaded_data = nil
	stealthTimerActive = false
end

Event.Register("onCreateBB", onCreateBB)
Event.Register("onUpdateBB", onUpdateBB)
Event.Register("onScanComplete", onScanComplete)
Event.Register("onPlayerDocked", onPlayerDocked)
Event.Register("onEnterSystem", onEnterSystem)
Event.Register("onGameStart", onGameStart)
Event.Register("onGameEnd", onGameEnd)

Mission.RegisterType("FrontlineRecon", "Frontline Recon", buildMissionDescription)

Serializer:Register("FrontlineRecon", function()
	return { ads = ads, missions = missions }
end, function(data)
	loaded_data = data
end)

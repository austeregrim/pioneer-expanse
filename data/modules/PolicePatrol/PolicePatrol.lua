-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Engine = require 'Engine'
local Equipment = require 'Equipment'
local Lang = require 'Lang'
local Game = require 'Game'
local Space = require 'Space'
local Comms = require 'Comms'
local Event = require 'Event'
local Legal = require 'Legal'
local Serializer = require 'Serializer'
local Timer = require 'Timer'
local Commodities = require 'Commodities'
local PlayerState = require 'PlayerState'
local ui = require 'pigui'

local MissionUtils = require 'modules.MissionUtils'
local ShipBuilder  = require 'modules.MissionUtils.ShipBuilder'
local ShipRegistry = require 'modules.ShipRegistry.ShipRegistry'

local l = Lang.GetResource("module-policepatrol")
local l_ui_core = Lang.GetResource("ui-core")

-- Fine at which police will hunt down outlaw player
-- This is a copy from CrimeTracking.lua.
local maxFineTolerated = 5500
--   The distance, in meters, at which the police patrol upholds the law
local lawEnforcedRange = 4000000

local hasIllegalGoods = function (cargo)
	local illegal = false

	for name in pairs(cargo) do
		if not Game.system:IsCommodityLegal(name) then
			illegal = true
			break
		end
	end
	return illegal
end

local patrol = {}
local patrolState = {}
local showMercy = true
local piracy = false
local target = nil
local patrolTimerActive = false

local function equipInterdictor(ship)
	local equipSet = ship:GetComponent("EquipSet")
	local proto = Equipment.Get("misc.fsd_interdictor_2")
	if not equipSet or not proto then return end
	local inst = proto:Instance()
	local slot = equipSet:GetFreeSlotForEquip(inst)
	if slot then
		equipSet:Install(inst, slot)
	end
end

local function getPatrolHubCandidates(ship, currentPort)
	local orbitalHubs = {}
	local surfacePorts = {}
	local allStations = Game.system and Game.system:GetStationPaths() or {}
	local nearestPlayerPort = (Game.player and Game.player:exists()) and Game.player:FindNearestTo("SPACESTATION") or nil
	local playerParentIdx = nil
	if nearestPlayerPort and nearestPlayerPort:exists() then
		local psb = nearestPlayerPort:GetSystemBody()
		playerParentIdx = psb and psb.parent and psb.parent.index or nil
	end

	for _, path in ipairs(allStations) do
		local body = Space.GetBody(path.bodyIndex)
		if body and body:exists() and body ~= currentPort then
			local entry = {
				body = body,
				ndocks = body.numDocks or 4,
				isOrbital = (body.type == "STARPORT_ORBITAL"),
				nearPlayerHub = false,
			}
			local sb = body:GetSystemBody()
			if playerParentIdx and sb and sb.parent and sb.parent.index == playerParentIdx then
				entry.nearPlayerHub = true
			end
			if entry.isOrbital then
				table.insert(orbitalHubs, entry)
			else
				table.insert(surfacePorts, entry)
			end
		end
	end

	local pool = (#orbitalHubs > 0) and orbitalHubs or surfacePorts
	table.sort(pool, function(a, b)
		if a.nearPlayerHub ~= b.nearPlayerHub then return a.nearPlayerHub end
		return a.ndocks > b.ndocks
	end)
	return pool
end

local function assignSupercruiseRoute(ship)
	if not Game.system or not ship or not ship:exists() then return end
	local st = patrolState[ship] or { mode = 'lane', lastPort = nil }
	patrolState[ship] = st

	local hubs = getPatrolHubCandidates(ship, st.lastPort)
	local stars = Game.system:GetStars()
	local primaryStar = stars and stars[1] and stars[1].body

	-- 30% chance when arriving near an orbital hub with open pads: dock for brief patrol shift resupply
	if st.mode == 'lane' and st.lastPort == nil and Engine.rand:Number(1) < 0.30 then
		for _, h in ipairs(hubs) do
			if h.isOrbital and (h.body.freeDocks or 0) >= 3 and ship:DistanceTo(h.body) < 3.0e9 then
				st.mode = 'docking'
				st.lastPort = h.body
				ship:AIDockWith(h.body)
				return
			end
		end
	end

	st.mode = 'lane'
	-- Bias 70% toward top busy/local hubs, 20% toward star-to-hub corridor, 10% wider patrol
	if #hubs > 0 then
		if primaryStar and ship:DistanceTo(primaryStar) > 6.0e9 and Engine.rand:Number(1) < 0.22 then
			st.lastPort = primaryStar
			ship:AIFlyTo(primaryStar)
			return
		end
		local topCount = math.min(#hubs, math.max(2, math.ceil(#hubs * 0.45)))
		local chosen = hubs[Engine.rand:Integer(1, topCount)]
		if chosen and chosen.body and ship:DistanceTo(chosen.body) > 500000 then
			st.lastPort = chosen.body
			ship:AIFlyTo(chosen.body)
			return
		end
		for _, h in ipairs(hubs) do
			if h.body and ship:DistanceTo(h.body) > 500000 then
				st.lastPort = h.body
				ship:AIFlyTo(h.body)
				return
			end
		end
	end

	local bodies = Game.system:GetBodyPaths()
	local planetCandidates = {}
	if bodies then
		for _, path in ipairs(bodies) do
			local sb = path:GetSystemBody()
			if sb and sb.body and (sb.superType == 'ROCKY_PLANET' or sb.superType == 'GAS_GIANT') then
				if ship:DistanceTo(sb.body) > 500000 then
					table.insert(planetCandidates, sb.body)
				end
			end
		end
	end
	if #planetCandidates > 0 then
		ship:AIFlyTo(planetCandidates[Engine.rand:Integer(1, #planetCandidates)])
		return
	end
	if primaryStar and ship:DistanceTo(primaryStar) > 5.0e8 then
		ship:AIFlyTo(primaryStar)
	end
end

local attackShip = function (ship)
	for i = 1, #patrol do
		patrol[i]:AIKill(ship)
	end
	target = ship
end

local function startPatrolHunterTimer()
	if patrolTimerActive then return end
	patrolTimerActive = true
	Timer:CallEvery(15, function ()
		if not Game.system or #patrol == 0 then
			patrolTimerActive = false
			return true
		end
		for i = #patrol, 1, -1 do
			if not patrol[i]:exists() then
				table.remove(patrol, i)
			end
		end
		if #patrol == 0 then
			patrolTimerActive = false
			return true
		end

		if target and not target:exists() then
			target = nil
		end
		if target then return false end

		local policeId = Game.system.faction.policeShip
		local playerLabel = (Game.player and Game.player.label) or ""

		local ships = Space.GetBodiesNear(patrol[1], lawEnforcedRange, "Ship")
		for _, enemy in ipairs(ships) do
			if enemy.shipId ~= policeId and enemy:GetCurrentAICommand() == "CMD_KILL" then
				if not piracy then
					Comms.ImportantMessage(string.interp(l_ui_core.X_CANNOT_BE_TOLERATED_HERE, { crime = l_ui_core.PIRACY }), patrol[1].label)
					Comms.ImportantMessage(string.interp(l["RESTRICTIONS_WITHDRAWN_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "RESTRICTIONS_WITHDRAWN"))], { ship_label = playerLabel }), patrol[1].label)
					piracy = true
				end
				attackShip(enemy)
				return false
			end
		end

		-- Supercruise patrol scan for WANTED criminals (NPC pirates or wanted player)
		local allShips = Space.GetBodies("Ship")
		for _, enemy in ipairs(allShips) do
			local fs = enemy:GetFlightState()
			if enemy ~= patrol[1] and enemy.shipId ~= policeId and enemy.IsWanted and enemy:IsWanted() and (fs == "SUPERCRUISE" or fs == "FLYING") then
				if patrol[1]:DistanceTo(enemy) < 3.0e10 then
					piracy = true
					attackShip(enemy)
					return false
				end
			end
		end

		if piracy and not target then
			Comms.ImportantMessage(string.interp(l["RESTRICTIONS_ESTABLISHED_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "RESTRICTIONS_ESTABLISHED"))], { ship_label = playerLabel }), patrol[1].label)
			piracy = false
		end
		for i = 1, #patrol do
			local p = patrol[i]
			if p:exists() and p:GetFlightState() ~= "DOCKED" and p:GetCurrentAICommand() == "CMD_NONE" then
				local st = patrolState[p]
				if st and st.mode == 'docking' and st.lastPort and st.lastPort:exists() and (st.lastPort.freeDocks or 0) >= 3 then
					p:AIDockWith(st.lastPort)
				else
					-- Periodically dock at an orbital hub for patrol shift turnaround when completing a lane leg
					if st and st.lastPort and st.lastPort.type == "STARPORT_ORBITAL" and (st.lastPort.freeDocks or 0) >= 3 and Engine.rand:Number(1) < 0.30 then
						st.mode = 'docking'
						p:AIDockWith(st.lastPort)
					else
						assignSupercruiseRoute(p)
					end
				end
			end
		end
		return false
	end)
end

local function schedulePatrolUndock(ship, station, delaySec)
	Timer:CallAt(Game.time + delaySec, function ()
		if not Game.system or not ship or not ship:exists() then return end
		if ship:GetFlightState() ~= "DOCKED" then return end
		if target then return end
		local port = ship:GetDockedWith() or station
		if port and port:exists() then
			if not port:CanLaunch(ship) or not ship:Undock() then
				schedulePatrolUndock(ship, port, Engine.rand:Number(8, 16))
				return
			end
			patrolState[ship] = patrolState[ship] or { mode = 'departing', lastPort = port }
			patrolState[ship].mode = 'departing'
			patrolState[ship].lastPort = port
			ship:AIDepart(port)
		end
	end)
end

local onAICompleted = function (ship, ai_error)
	if not ship or not ship:exists() or not patrolState[ship] then return end
	local st = patrolState[ship]
	if st.mode == 'departing' then
		st.mode = 'lane'
		assignSupercruiseRoute(ship)
	elseif st.mode == 'docking' and ai_error ~= 'NONE' then
		st.mode = 'lane'
		assignSupercruiseRoute(ship)
	elseif not target and ship:GetFlightState() ~= "DOCKED" then
		if st.lastPort and st.lastPort:exists() and st.lastPort.type == "STARPORT_ORBITAL"
			and (st.lastPort.freeDocks or 0) >= 3 and ship:DistanceTo(st.lastPort) < 500000 and Engine.rand:Number(1) < 0.32 then
			st.mode = 'docking'
			ship:AIDockWith(st.lastPort)
		else
			st.mode = 'lane'
			assignSupercruiseRoute(ship)
		end
	end
end

local onShipUndocked = function (ship, station)
	if not ship or not patrolState[ship] then return end
	if ship:GetCurrentAICommand() ~= "CMD_KILL" then
		patrolState[ship].mode = 'departing'
		patrolState[ship].lastPort = station
		ship:AIDepart(station)
	end
end

local onShipDestroyed = function (ship, attacker)
	if ship:IsPlayer() or attacker == nil then return end

	if ship == target then
		target = nil
	else
		for i = #patrol, 1, -1 do
			if patrol[i] == ship then
				table.remove(patrol, i)
				patrolState[ship] = nil
				if attacker:isa("Ship") and attacker:IsPlayer() then
					showMercy = false
				end
				break
			elseif patrol[i] == attacker then
				Comms.ImportantMessage(l["TARGET_DESTROYED_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "TARGET_DESTROYED"))], attacker.label)
				break
			end
		end
	end
end

local onShipHit = function (ship, attacker)
	if attacker == nil then return end
	if not attacker:isa('Ship') then return end

	-- Support all police, not only the patrol
	-- TODO: this should use a property set on the ship rather than checking for the shipid
	-- (what happens if the player is committing piracy in a police hull?)
	local policeId = Game.system.faction.policeShip
	if ship.shipId == policeId and attacker.shipId ~= policeId then
		piracy = true
		attackShip(attacker)
	end
end

local onShipInterdicted = function (ship, attacker)
	if #patrol == 0 or not attacker or not attacker:isa('Ship') then return end
	if ship and not (ship.IsWanted and ship:IsWanted()) then
		local policeId = Game.system and Game.system.faction.policeShip
		if attacker.shipId ~= policeId then
			piracy = true
			attackShip(attacker)
		end
	end
end

local onShipFiring = function (ship)
	if piracy or target then return end
	if ship:IsPlayer() then return end -- Handled via onUnlawfulWeaponsDischarge with grace warning cooldown in CrimeTracking

	local policeId = Game.system.faction.policeShip
	if ship.shipId ~= policeId then
		for i = 1, #patrol do
			if ship:DistanceTo(patrol[i]) <= lawEnforcedRange then
				Comms.ImportantMessage(string.interp(l_ui_core.X_CANNOT_BE_TOLERATED_HERE, { crime = l_ui_core.UNLAWFUL_WEAPONS_DISCHARGE }), patrol[i].label)
				attackShip(ship)
				break
			end
		end
	end
end

local onUnlawfulWeaponsDischarge = function (ship, station)
	if piracy or target then return end
	if not ship or not ship:IsPlayer() then return end

	for i = 1, #patrol do
		if patrol[i] and patrol[i]:DistanceTo(ship) <= lawEnforcedRange then
			Comms.ImportantMessage(string.interp(l_ui_core.X_CANNOT_BE_TOLERATED_HERE, { crime = l_ui_core.UNLAWFUL_WEAPONS_DISCHARGE }), patrol[i].label)
			attackShip(ship)
			break
		end
	end
end

local onJettison = function (ship, cargo)
	if not ship:IsPlayer() or Game.system:IsCommodityLegal(cargo.name) then return end

	if #patrol > 0 and showMercy then
		local manifest = ship:GetComponent('CargoManager').commodities
		if not hasIllegalGoods(manifest) then
			Comms.ImportantMessage(l.TAKE_A_HIKE, patrol[1].label)
			for i = 1, #patrol do
				patrol[i]:CancelAI()
			end
			target = nil
		end
	end
end

---@param player Player
local function spawnAmbientPatrols(system)
	if not system then return end
	local policeId = system.faction and system.faction.policeShip
	if not policeId then return end

	-- Spawn ambient Supercruise police patrols in policed systems
	if system.lawlessness < 0.75 and system.population > 0 then
		local stations = system:GetStationPaths()
		if stations and #stations > 0 then
			local desiredPatrols = math.min(7, math.max(2, math.floor((1.0 - system.lawlessness) * 3.5 + #stations * 0.25)))
			local needed = math.max(0, desiredPatrols - #patrol)
			if needed == 0 then return end

			local hubs = getPatrolHubCandidates(Game.player, nil)
			local threat = 20.0 + 30.0 * (1.0 - system.lawlessness)
			local stars = system:GetStars()
			local primaryStar = stars and stars[1]
			for i = 1, needed do
				local hubEntry = (#hubs > 0) and hubs[((i - 1) % #hubs) + 1] or nil
				local stBody = hubEntry and hubEntry.body or Space.GetBody(stations[((i - 1) % #stations) + 1].bodyIndex)
				local stBodyIdx = stBody and stBody.path and stBody.path.bodyIndex or nil
				local pShip
				if stBody and primaryStar and primaryStar.body and stBody ~= primaryStar.body then
					local rec = ShipRegistry.AcquireShipForSystem(system, "POLICE", policeId, { stationBodyIdx = stBodyIdx })
					local patrolTemplate = MissionUtils.ShipTemplates.PolicePatrol:clone {
						shipId = policeId,
						label = rec and rec.label or nil
					}
					-- Place patrols along active Supercruise shipping lanes heading toward major orbital hubs
					local starRadius = math.max(primaryStar.radius or 7e8, 7e8)
					pShip = ShipBuilder.MakeShipOrbit(primaryStar.body, patrolTemplate, threat, starRadius * 3.5, starRadius * 4.5)
					if pShip then
						if rec then
							ShipRegistry.ApplyRecordToShip(pShip, rec)
						end
						local tRatio = 0.15 + 0.70 * ((i - 0.5) / needed)
						Space.PutShipOnRoute(pShip, stBody, tRatio)
						patrolState[pShip] = { mode = 'lane', lastPort = stBody }
						pShip:AIFlyTo(stBody)
					elseif rec then
						ShipRegistry.ReleaseLive(rec.label)
					end
				end
				if pShip then
					equipInterdictor(pShip)
					table.insert(patrol, pShip)
				end
			end
			if #patrol > 0 then
				startPatrolHunterTimer()
			end
		end
	end
end

local onEnterSystem = function (player)
	local system = assert(Game.system)
	local policeId = system.faction and system.faction.policeShip
	if not policeId then return end

	spawnAmbientPatrols(system)

	if not hasIllegalGoods(Commodities) then return end

	local cargoMgr = player:GetComponent('CargoManager')

	local illegalCount = 0
	local illegalValue = 0

	local totalCargo = player.usedCargo

	for name, count in cargoMgr:Commodities() do
		if not Game.system:IsCommodityLegal(name) then
			illegalCount = illegalCount + count
			illegalValue = illegalValue + Commodities[name].price * count
		end
	end

	local scanChance = Engine.rand:Number(4)

	if illegalCount > 0 then
		-- 25% chance of a scan in 1.0-sec worlds... let's bump that number up a bit
		-- Narratively, it's more interesting to be scanned when carrying illegal goods
		-- than when not...
		scanChance = scanChance * 0.75
	end

	if (1 - system.lawlessness) < scanChance then return end

	local crimes, fine = PlayerState.GetCrimeOutstanding()
	local ship
	local n = 1 + math.floor((1 - system.lawlessness) * (system.population / 3))

	local threat = 10.0 + Engine.rand:Number(10, 50) * system.lawlessness
	local template = MissionUtils.ShipTemplates.PolicePatrol:clone {
		shipId = policeId,
		label = system.faction.policeName
	}

	-- The scene is set for a police patrol, just wait!
	Timer:CallAt(Game.time + Engine.rand:Integer(5, 10), function ()
		if not Game.system then return end -- Shut up when the player is already in hyperspace

		for i = 1, n do
			local rec = ShipRegistry.AcquireShipForSystem(system, "POLICE", policeId)
			local unitTemplate = template:clone {
				shipId = policeId,
				label = rec and rec.label or nil
			}
			ship = ShipBuilder.MakeShipNear(player, unitTemplate, threat, 50, 100) -- "Ship detected nearby"
			assert(ship)
			if rec then
				ShipRegistry.ApplyRecordToShip(ship, rec)
			end
			equipInterdictor(ship)

			table.insert(patrol, ship)
		end

		Timer:CallAt(Game.time + Engine.rand:Integer(5, 10), function () -- Oh crap, it's the police!
			if not Game.system or Game.system.path ~= system.path then return end -- Shut up if the player has jumped away

			if Engine.rand:Number(1) < system.lawlessness then
				-- You are lucky. They are busy, eating donuts ;-)
				Comms.ImportantMessage(string.interp(l["RESPECT_THE_LAW_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "RESPECT_THE_LAW"))], { system = system.name }), ship.label)
			else
				if fine > maxFineTolerated then
					Comms.ImportantMessage(string.interp(l["OUTLAW_DETECTED_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "OUTLAW_DETECTED"))], { ship_label = player.label }), ship.label)
					showMercy = false
					attackShip(player)

					return
				end

				Comms.ImportantMessage(l["INITIATE_CARGO_SCAN_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "INITIATE_CARGO_SCAN"))], ship.label)

				Timer:CallAt(Game.time + Engine.rand:Integer(3, 9), function ()

					if not Game.system or Game.system.path ~= system.path then return end -- Shut up when the player is already in hyperspace

					if player:hasprop("cargo_shield_cap") then
						local hiddenGoods = math.min(illegalCount, player["cargo_shield_cap"])
						illegalCount = illegalCount - hiddenGoods
						totalCargo = totalCargo - hiddenGoods
					end

					local proportion = illegalCount / math.max(totalCargo, 1)
					local detection_chance = math.min(0.45 + proportion, 1.0)

					if illegalCount > 0 and Engine.rand:Number() < detection_chance then
						Comms.ImportantMessage(l.ILLEGAL_GOODS_DETECTED, ship.label)

						-- $5000 in fines for every $5000 in goods in a high-sec system
						-- This includes goods in shielded holds for simplicity (they look closer after finding evidence of wrongdoing...)
						local newfine = Legal:fine("TRADING_ILLEGAL_GOODS", Game.system.lawlessness)
						newfine = (newfine * illegalValue / 5000) * Engine.rand:Normal(1.0, 0.2)

						PlayerState.AddCrime("TRADING_ILLEGAL_GOODS", newfine)

						if fine + newfine > maxFineTolerated then
							attackShip(player)
							Comms.ImportantMessage(l["POLICE_TAUNT_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "POLICE_TAUNT"))], ship.label)

							return
						end
					else
						-- Got away clean... this time.
						Comms.ImportantMessage(l.NOTHING_DETECTED, ship.label)
					end

					if fine > 100 then
						local message = l["FINES_INTRO_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "FINES_INTRO"))]
						message = message .. " " .. l["FINES_MESSAGE_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "FINES_MESSAGE"))]
						if fine > 1000 then
							message = message .. " " .. l["FINES_ADMONISHING_HARSH_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "FINES_ADMONISHING_HARSH"))]
						else
							message = message .. " " .. l["FINES_ADMONISHING_" .. Engine.rand:Integer(1, MissionUtils.getNumberOfFlavours(l, "FINES_ADMONISHING"))]
						end
						local policeforce = Game.system.faction.policeName
						local ship_label = player.label
						Comms.ImportantMessage(string.interp(message, {policeforce = policeforce, ship_label = ship_label, fine = ui.Format.Money(fine)}), ship.label)
					end
				end)
			end
		end)
	end)

	startPatrolHunterTimer()
end

local onLeaveSystem = function (ship)
	patrol = {}
	patrolState = {}
	showMercy = true
	piracy = false
	target = nil
	patrolTimerActive = false
end

local onShipDocked = function (ship, station)
	if not ship or not ship:exists() then return end
	if not ship:IsPlayer() then
		if patrolState[ship] then
			patrolState[ship].mode = 'docked'
			patrolState[ship].lastPort = station
			ship:SetFuelPercent()
			ship:SetHullPercent()
			schedulePatrolUndock(ship, station, Engine.rand:Number(75, 180))
		end
		return
	end
	local crimes, fine = PlayerState.GetCrimeOutstanding()
	if fine > 0 then
		Comms.ImportantMessage("[" .. string.upper(Game.system.faction.policeName) .. " - " ..
			l_ui_core.AUTOMATED_MESSAGE .. "] " .. l_ui_core.OUTSTANDING_FINES .. ": " .. ui.Format.Money(fine))
	end
end

local loaded_data

local onGameStart = function ()
	local wasLoaded = loaded_data ~= nil
	if loaded_data then
		patrol = loaded_data.patrol or {}
		patrolState = loaded_data.patrolState or {}
		showMercy = loaded_data.showMercy
		piracy = loaded_data.piracy
		target = loaded_data.target
		loaded_data = nil
	end
	for k, _ in pairs(patrolState) do
		if type(k) ~= 'userdata' or not k:exists() then
			patrolState[k] = nil
		end
	end
	for i = #patrol, 1, -1 do
		local p = patrol[i]
		if type(p) ~= 'userdata' or not p:exists() then
			table.remove(patrol, i)
		else
			patrolState[p] = patrolState[p] or { mode = 'lane', lastPort = nil }
			if p:GetFlightState() == "DOCKED" then
				schedulePatrolUndock(p, p:GetDockedWith(), Engine.rand:Number(25, 90))
			end
		end
	end
	if Game.system and ((not wasLoaded and #patrol == 0) or (wasLoaded and #patrol < 2)) then
		spawnAmbientPatrols(Game.system)
	end
	if #patrol > 0 then
		startPatrolHunterTimer()
	end
end

local onGameEnd = function ()
	patrol = {}
	patrolState = {}
	showMercy = true
	piracy = false
	target = nil
	patrolTimerActive = false
end

local serialize = function ()
	return { patrol = patrol, patrolState = patrolState, showMercy = showMercy, piracy = piracy, target = target }
end

local unserialize = function (data)
	loaded_data = data
end

Event.Register("onEnterSystem", onEnterSystem)
Event.Register("onLeaveSystem", onLeaveSystem)
Event.Register("onShipDocked", onShipDocked)
Event.Register("onShipUndocked", onShipUndocked)
Event.Register("onAICompleted", onAICompleted)
Event.Register("onShipDestroyed", onShipDestroyed)
Event.Register("onShipHit", onShipHit)
Event.Register("onShipInterdicted", onShipInterdicted)
Event.Register("onShipFiring", onShipFiring)
Event.Register("onUnlawfulWeaponsDischarge", onUnlawfulWeaponsDischarge)
Event.Register("onJettison", onJettison)
Event.Register("onGameStart", onGameStart)
Event.Register("onGameEnd", onGameEnd)

Serializer:Register("PolicePatrol", serialize, unserialize)

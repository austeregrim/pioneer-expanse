-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Comms = require 'Comms'
local Engine = require 'Engine'
local Event = require 'Event'
local Game = require 'Game'
local ShipDef = require 'ShipDef'
local utils = require 'utils'
local CommodityType = require 'CommodityType'

local Core         = require 'modules.TradeShips.Core'
local Flow         = require 'modules.TradeShips.Flow'
local Trader       = require 'modules.TradeShips.Trader'
local ShipRegistry = require 'modules.ShipRegistry.ShipRegistry'

-- this module contains all events affecting tradeships

local onGameStart = function ()
	if Flow.calculateSystemParams() then
		if Core.ships == nil then -- new game
			Flow.spawnInitialShips()
			Flow.run()
		else -- deserialization
			Flow.reconcileTrafficOnLoad()
			Flow.run()
		end
	else
		-- Failed to init parameters for this system, just make a table to prevent further errors
		Core.ships = Core.ships or {}
	end
end
Event.Register("onGameStart", onGameStart)

local function divertOutbound(ship, trader)
	if not ship or not ship:exists() or not trader then return end
	trader.status = 'outbound'
	trader.starport = nil
	trader.assignment = nil
	local stars = Game.system and Game.system:GetStars()
	local primaryStar = stars and stars[1] and stars[1].body
	if primaryStar and primaryStar:exists() and ship:DistanceTo(primaryStar) > 1.0e8 then
		ship:AIFlyTo(primaryStar)
	else
		ship:CancelAI()
	end
	Trader.assignTask(ship, Game.time + Engine.rand:Number(12, 24), 'hyperjumpAtDistance')
end

local onShipEnterSystem = function (ship)
	-- clearing the cache of ships that attacked traders, but are no longer relevant
	Core.attackers.clean()

	-- dont crash when entering unexplored systems
	if Game.system.explored == false then
		if ship:IsPlayer() then
			Core.params = nil
			Flow.updateTradeShipsTable()
		end
		return
	end

	-- if the player is following a ship through hyperspace that ship may enter first
	-- so update the system when the first ship enters (see Space::DoHyperspaceTo)
	if ship:IsPlayer() then
		Flow.updateTradeShipsTable()
		if Flow.calculateSystemParams() then
			Flow.spawnInitialShips()
			Flow.run()
		end
	elseif Core.ships[ship] ~= nil then
		local trader = Core.ships[ship]
		Core.log:add(ship, 'Entered '..Game.system.name..' from '..trader.from_path:GetStarSystem().name)
		local destPort = trader.route and trader.route.to
		if destPort and destPort:exists() and Trader.isStarportAcceptableForShip(destPort, ship) then
			ship:AIDockWith(destPort)
			Core.ships[ship]['starport'] = destPort
			Core.ships[ship]['status'] = 'inbound'
		else
			local altPort = Core.params and Trader.getNearestStarport(ship, nil)
			if altPort and altPort:exists() and Trader.isStarportAcceptableForShip(altPort, ship) then
				ship:AIDockWith(altPort)
				Core.ships[ship]['starport'] = altPort
				Core.ships[ship]['status'] = 'inbound'
			elseif Trader.getSystemAndJump(ship) ~= 'OK' then
				divertOutbound(ship, trader)
			end
		end
	end
end
Event.Register("onShipEnterSystem", onShipEnterSystem)

local onShipDocked

local onShipLeaveSystem = function (ship)
	if ship:IsPlayer() then
		Core.params = nil
		-- the next onEnterSystem will be in a new system
		local total, removed = 0, 0
		for t_ship, trader in pairs(Core.ships) do
			total = total + 1
			if trader.status == 'hyperspace' then
				if trader.dest_path:IsSameSystem(Game.system.path) then
					-- remove ships that are in hyperspace to here
					Core.ships[t_ship] = nil
					removed = removed + 1
				end
			else
				-- remove all ships that are not in hyperspace
				Core.ships[t_ship] = nil
				removed = removed + 1
			end
		end
		Core.log:add(nil, 'onLeaveSystem:total:'..total..',removed:'..removed)
	elseif Core.ships[ship] ~= nil then
		local system = Core.ships[ship]['dest_path']:GetStarSystem()
		Core.log:add(ship, 'Left '..Game.system.name..' for '.. system.name)
		ShipRegistry.MarkInTransit(ship:GetLabel(), Core.ships[ship]['dest_path'])
		Flow.cleanTradeShipsTable()
	elseif Core.attackers.check(ship) then
		for t_ship, trader in pairs(Core.ships) do
			if trader.attacker and trader.attacker.ref == ship then
				trader.attacker = nil
				if trader.status == 'fleeing' then
					trader['status'] = 'inbound'
				elseif trader.status == 'cowering' then
					onShipDocked(t_ship, trader.starport)
				end
			end
		end
	end
end
Event.Register("onShipLeaveSystem", onShipLeaveSystem)

onShipDocked = function (ship, starport)
	if Core.ships[ship] == nil then return end
	local trader = Core.ships[ship]

	trader.route = nil
	Core.log:add(ship, 'Docked with '..starport.label)

	if trader.status == 'fleeing' then
		trader['status'] = 'cowering'
	else
		trader['status'] = 'docked'
	end
	if trader.chance then
		trader['chance'] = trader.chance / 2
		trader['last_flee'], trader['no_jump'] = nil, nil
	end

	-- 'sell' trade cargo
	local unloadedTons = ship.usedCargo or 0
	---@type CargoManager
	local cargoMgr = ship:GetComponent('CargoManager')

	for name, info in pairs(cargoMgr.commodities) do
		local commodity = CommodityType.GetCommodity(name)
		cargoMgr:RemoveCommodity(commodity, info.count)
	end

	local hullMax = (ShipDef[trader.ship_name] and ShipDef[trader.ship_name].hullMass) or ship.hullMassLeft or 1
	local damage = hullMax - ship.hullMassLeft
	local damageFrac = math.max(0.0, damage / math.max(1.0, hullMax))
	if damage > 0 then
		ship:SetHullPercent()
		Trader.addEquip(ship)
	end
	Trader.addHyperdriveFuel(ship)
	ship:SetFuelPercent()

	if trader.status == 'docked' then
		local rec = ShipRegistry.GetRecord(ship:GetLabel())
		local plan = Trader.computeStationDwellPlan(ship, starport, unloadedTons, damageFrac, rec, false)
		if plan.action == 'hangar' then
			trader.hangarDuration = plan.hangarDuration
			Trader.assignTask(ship, Game.time + plan.padDuration, 'doStowHangar')
		else
			Trader.assignTask(ship, Game.time + plan.padDuration, 'doUndock')
		end
	end
end
Event.Register("onShipDocked", onShipDocked)

local onShipStowedInHangar = function (station, ship)
	if not ship or Core.ships == nil or Core.ships[ship] == nil then return end
	Core.log:add(ship, 'Stowed in hangar bay at ' .. (station and station.label or 'station'))
	Core.ships[ship] = nil
end
Event.Register("onShipStowedInHangar", onShipStowedInHangar)

local onShipUnstowedFromHangar = function (station, ship)
	if not ship or Core.ships == nil or Core.ships[ship] == nil then return end
	local trader = Core.ships[ship]
	trader.status = 'docked'
	Trader.addHyperdriveFuel(ship)
	ship:SetFuelPercent()
	Core.log:add(ship, 'Emerged onto pad from hangar at ' .. (station and station.label or 'station'))
	Trader.assignTask(ship, Game.time + Engine.rand:Number(15, 38), 'doUndock')
end
Event.Register("onShipUnstowedFromHangar", onShipUnstowedFromHangar)

local onShipUndocked = function (ship, starport)
	if Core.ships[ship] == nil then return end
	local trader = Core.ships[ship]

	-- Ensure departing ship has full hyperdrive fuel and export cargo before leaving station
	Trader.addHyperdriveFuel(ship)
	ship:SetFuelPercent()
	Trader.addCargo(ship, 'export')

	-- Set departure status and engage station departure corridor autopilot
	trader['status'] = 'departing'
	ship:AIDepart(starport)

	-- Find if system has mining sites (planetary rings or asteroids)
	local miningSites = {}
	if Game.system then
		for _, path in ipairs(Game.system:GetBodyPaths()) do
			local sb = path:GetSystemBody()
			if sb and (sb.hasRings or sb.type == "PLANET_ASTEROID") and sb.body then
				table.insert(miningSites, sb.body)
			end
		end
	end

	-- 1. Mining extraction runs for dedicated mining hulls or 20% of vessels in systems with ring/asteroid sites
	local isMinerHull = (trader.ship_name == 'dsminer' or trader.ship_name == 'kanara')
	if #miningSites > 0 and (isMinerHull or Engine.rand:Number(1) < 0.20) then
		local site = miningSites[Engine.rand:Integer(1, #miningSites)]
		trader.assignment = { type = 'mining', site = site, refinery = starport }
		return
	end

	-- 2. In-system inter-station transport lanes (70% of departing traders in multi-station systems)
	local otherPorts = {}
	if Core.params and Core.params.ports then
		for _, port in ipairs(Core.params.ports) do
			if port ~= starport and port:exists() and ship:DistanceTo(port) > 300000 and Trader.isStarportAcceptableForShip(port, ship) then
				table.insert(otherPorts, port)
			end
		end
	end
	if #otherPorts > 0 and Engine.rand:Number(1) < 0.70 then
		local destPort = otherPorts[Engine.rand:Integer(1, #otherPorts)]
		trader.assignment = { type = 'interstation', to = destPort }
		return
	end

	-- 3. Outbound interstellar export along primary star / outer transport corridor
	local primaryStar = (Game.system and Game.system:GetStars() and Game.system:GetStars()[1] and Game.system:GetStars()[1].body)
		or trader.starport:GetSystemBody().system:GetStars()[1].body
	local farBody = primaryStar
	if not farBody or ship:DistanceTo(farBody) < 5e7 then
		if otherPorts[1] then
			farBody = otherPorts[1]
		end
	end

	trader.assignment = { type = 'export', farBody = farBody }
end
Event.Register("onShipUndocked", onShipUndocked)

local onAICompleted = function (ship, ai_error)
	if Core.ships[ship] == nil then return end
	local trader = Core.ships[ship]
	if ai_error ~= 'NONE' then
		Core.log:add(ship, 'AICompleted: Error: '..ai_error..' Status: '..trader.status)
	end
	if trader.status == 'departing' then
		-- Vessel has safely cleared the airlock/mail slot and APPROACH1 in open space!
		if trader.assignment and trader.assignment.type == 'mining' and trader.assignment.site and trader.assignment.site:exists() then
			trader.status = 'inbound'
			ship:AIFlyTo(trader.assignment.site)
			Trader.assignTask(ship, Game.time + Engine.rand:Number(90, 150), 'doReturnFromMining')
		elseif trader.assignment and trader.assignment.type == 'interstation' and trader.assignment.to and trader.assignment.to:exists() then
			trader.status = 'inbound'
			trader.starport = trader.assignment.to
			ship:AIDockWith(trader.assignment.to)
		else
			local farBody = (trader.assignment and trader.assignment.farBody)
				or trader.starport:GetSystemBody().system:GetStars()[1].body
			trader.status = 'outbound'
			ship:AIFlyTo(farBody)
			Trader.assignTask(ship, Game.time + Engine.rand:Number(30, 55), 'hyperjumpAtDistance')
		end
	elseif trader.status == 'outbound' then
		if ai_error == 'NONE' then
			Trader.assignTask(ship, Game.time + 2, 'hyperjumpAtDistance')
		end
	elseif trader.status == 'orbit' then
		trader.ts_error = "wait_redock"
		Trader.assignTask(ship, Game.time + Engine.rand:Number(45, 75), 'doRedock')
	elseif trader.status == 'inbound' then
		if trader.assignment and trader.assignment.type == 'mining' then
			if trader.fnc ~= 'doReturnFromMining' then
				Trader.assignTask(ship, Game.time + Engine.rand:Number(30, 60), 'doReturnFromMining')
			end
		elseif ai_error == 'REFUSED_PERM' or ai_error == 'GRAV_TOO_HIGH' or ai_error == 'PRESS_TOO_HIGH' or ai_error == 'ORBIT_IMPOSSIBLE' then
			local altPort = Trader.getNearestStarport(ship, trader.starport)
			if altPort and altPort ~= trader.starport and altPort:exists() and Trader.isStarportAcceptableForShip(altPort, ship) then
				trader.starport = altPort
				ship:AIDockWith(altPort)
			elseif ai_error == 'REFUSED_PERM' and trader.starport and trader.starport:exists() then
				Trader.doOrbit(ship)
				trader.ts_error = "refused_perm"
				Trader.assignTask(ship, Game.time + Engine.rand:Number(45, 75), 'doRedock')
			else
				divertOutbound(ship, trader)
			end
		elseif not ship:GetDockedWith() and ship:GetFlightState() ~= 'DOCKED' and ship:GetFlightState() ~= 'DOCKING' then
			if trader.starport and trader.starport:exists() and Trader.isStarportAcceptableForShip(trader.starport, ship) then
				ship:AIDockWith(trader.starport)
			else
				local altPort = Trader.getNearestStarport(ship, trader.starport)
				if altPort and altPort ~= trader.starport and altPort:exists() and Trader.isStarportAcceptableForShip(altPort, ship) then
					trader.starport = altPort
					ship:AIDockWith(altPort)
				else
					divertOutbound(ship, trader)
				end
			end
		end
	end
end
Event.Register("onAICompleted", onAICompleted)

local onShipLanded = function (ship, _)
	if Core.ships[ship] == nil then return end
	Core.log:add(ship, 'Landed: '..Core.ships[ship].starport.label)
	Trader.doOrbit(ship)
end
Event.Register("onShipLanded", onShipLanded)

local onShipAlertChanged = function (ship, alert)
	if Core.ships[ship] == nil then return end
	if alert == 'SHIP_FIRING' then
		Core.log:add(ship, 'Alert changed to '..alert) end
	local trader = Core.ships[ship]
	if trader.attacker == nil then return end

	if alert == 'NONE' or not trader.attacker.ref or not trader.attacker.ref:exists() or
		(alert == 'SHIP_NEARBY' and ship:DistanceTo(trader.attacker.ref) > 100) then
		if trader.status == 'fleeing' then
			-- had not reached starport yet
			trader['status'] = 'inbound'
			trader.ts_error = "alert!"
		elseif trader.status == 'cowering' then
			-- already reached starport and docked
			-- we need to do everything that the ship does after docking
			onShipDocked(ship, trader.starport)
		end
	end
end
Event.Register("onShipAlertChanged", onShipAlertChanged)

local onShipExploded = function (ship, cause, speed)
	if Core.ships and Core.ships[ship] then
		local trader = Core.ships[ship]
		local info = string.format("[TRADER POST-MORTEM] Ship: %s (%s) | Status: %s | Target: %s | Assignment: %s | Cause: %s (%.1f m/s)",
			ship:GetLabel(), trader.ship_name or "unknown",
			trader.status or "unknown",
			(trader.starport and trader.starport:exists() and trader.starport:GetLabel()) or "none",
			(trader.assignment and trader.assignment.type) or "none",
			cause or "collision", speed or 0.0)
		Core.log:add(ship, info)
		print(info)
	end
end
Event.Register("onShipExploded", onShipExploded)

local onShipHit = function (ship, attacker)
	if attacker == nil then return end-- XX

	-- XXX this whole thing might be better if based on amount of damage sustained
	if Core.ships[ship] == nil then return end
	local trader = Core.ships[ship]
	trader.ts_error = "HIT"

	trader['chance'] = trader.chance or 0
	trader['chance'] = trader.chance + 0.1

	-- don't spam actions
	if trader.last_flee and Game.time - trader.last_flee < Engine.rand:Integer(5, 7) then return end

	-- if outbound jump now
	if trader.status == 'outbound' then
		if Trader.getSystemAndJump(ship) == 'OK' then
			return
		end
	end

	trader['status'] = 'fleeing'
	Core.attackers.add(trader, attacker)

	-- update last_flee
	trader['last_flee'] = Game.time

	-- if distance to starport is far attempt to hyperspace
	if trader.no_jump ~= true then
		local starports = Core.params.local_routes
		if #starports == 0 then
			trader['no_jump'] = true -- it already tried in onEnterSystem
		elseif trader.starport and Engine.rand:Number(1) < trader.chance then
			local distance = ship:DistanceTo(trader.starport)
			if distance > Core.AU * (2 - trader.chance) then
				if Trader.getSystemAndJump(ship) == 'OK' then
					return
				else
					trader['no_jump'] = true
					trader['chance'] = trader.chance + 0.3
				end
			end
		end
	end

	-- maybe jettison a bit of cargo
	if Engine.rand:Number(1) < trader.chance then
		local cargo_type = nil
		local max_cap = ShipDef[ship.shipId].equipCapacity

		---@type CargoManager
		local cargoMgr = ship:GetComponent('CargoManager')

		for name, info in pairs(cargoMgr.commodities) do
			if info.count > 1 and Engine.rand:Number(1) < (info.count / max_cap) then
				cargo_type = CommodityType.GetCommodity(name)
				break
			end
		end

		if cargo_type and ship:Jettison(cargo_type) then
			Comms.ImportantMessage(attacker.label..', take this and leave us be, you filthy pirate!', ship.label)
			trader['chance'] = trader.chance - 0.1
		end
	end
end
Event.Register("onShipHit", onShipHit)

local onShipCollided = function (ship, other)
	if Core.ships[ship] == nil then return end
	if other:isa('CargoBody') then return end
	Core.ships[ship].ts_error = "collided"

	if other:isa('Ship') and other:IsPlayer() then
		onShipHit(ship, other)
		return
	end
end
Event.Register("onShipCollided", onShipCollided)

local onShipDestroyed = function (ship, attacker)
	if Core.ships[ship] ~= nil then
		local trader = Core.ships[ship]
		local killer = attacker and attacker.label or 'accident/hazard'
		Core.log:add(ship, 'Destroyed by '..killer..', status:'..trader.status..' starport:'..(trader.starport and trader.starport.label or 'N/A'))
		Core.ships[ship] = nil
		-- XXX consider spawning some CargoBodies if killed by a ship
	elseif attacker ~= nil and Core.attackers.check(ship) then
		for t_ship, trader in pairs(Core.ships) do
			if trader.attacker and trader.attacker.ref == ship then
				trader.attacker = nil
				if trader.status == 'fleeing' then
					-- had not reached starport yet
					trader['status'] = 'inbound'
					trader.ts_error = "attack!"
				elseif trader.status == 'cowering' then
					-- already reached starport and docked
					-- we need to do everything that the ship does after docking
					onShipDocked(t_ship, trader.starport)
				end
			end
		end
	end
end
Event.Register("onShipDestroyed", onShipDestroyed)

local onShipOutOfFuel = function (ship)
	if not Core.ships[ship] then return end
	-- we don't want to bother yet
	Core.ships[ship] = nil
	ship:Explode()
end
Event.Register("onShipOutOfFuel", onShipOutOfFuel)

local onGameEnd = function ()
	-- drop the references for our data so Lua can free them
	-- and so we can start fresh if the player starts another game
	Core.ships, Core.params = nil, nil
	Core.log:clear()
end
Event.Register("onGameEnd", onGameEnd)

-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Engine = require 'Engine'
local Game = require 'Game'
local Ship = require 'Ship'
local ShipDef = require 'ShipDef'
local Space = require 'Space'
local utils = require 'utils'
local Commodities = require 'Commodities'

local Core         = require 'modules.TradeShips.Core'
local Trader       = require 'modules.TradeShips.Trader'
local ShipRegistry = require 'modules.ShipRegistry.ShipRegistry'

local Flow = {}
-- this module creates all tradeships, and ensures the flow of new ships into the system

-- UTILS

-- Inbound cloud lifetime for real-time Supercruise pacing (15-90s so arrivals visibly materialize)
local function inboundCloudDuration(route_duration)
	local scaled = utils.asymptote(route_duration * 0.1, 75.0, 0.0)
	return math.clamp(15.0 + scaled, 15.0, 90.0)
end

-- change of the standard parameter depending on local factors
local function localFactors(param, system)
	-- we only take into account the criminal situation
	return param * math.max(0.1, 1 - system.lawlessness)
end

-- return an array of names of ships that (at first sight) can be traders
local getAcceptableShips = function ()
	-- accept all ships with the hyperdrive, in fact
	---@param def ShipDef
	local filter_function = function(_,def)
		-- XXX should limit to ships large enough to carry significant
		--     cargo, but we don't have enough ships yet
		return def.tag == 'SHIP' and def.hyperdriveClass > 0 and def.cargo > 0 -- and def.roles.merchant
	end
	return utils.build_array(
		utils.map(function (k,def)
			return k,def.id
		end,
		utils.filter(filter_function,
			pairs(ShipDef)
		)))
end

-- expand the search radius until we find a sufficient number of nearby systems
local function getNearSystems()
	local from_systems, dist = {}, 10
	while #from_systems < Core.MINIMUM_NEAR_SYSTEMS do
		from_systems = Game.system:GetNearbySystems(dist)
		dist = dist + 5
	end
	local paths = {}
	for _, from_system in ipairs(from_systems) do
		table.insert(paths, from_system.path)
	end
	return paths
end

-- get a measure of the market size and build lists of imports and exports
local function getImportsExports(system)
	local import_score, export_score = 0, 0
	local imports, exports = {}, {}

	for key, commodity in pairs(Commodities) do
		local v = system:GetCommodityBasePriceAlterations(key)
		local isTransportable =
			commodity.price > 0 and
			commodity.purchasable and
			system:IsCommodityLegal(key)

		if isTransportable then
			-- values from SystemInfoView::UpdateEconomyTab

			if v > 2 then
				import_score = import_score + (v > 10 and 2 or 1)
				table.insert(imports, commodity)
			end

			if v < -4 then
				export_score = export_score + (v < -10 and 2 or 1)
				table.insert(exports, commodity)
			end
		end
	end
	return imports, exports
end

-- we collect all the information necessary for the module to work in this system:
-- valid ship models
-- import / export goods
-- hyperspace routes (from other stars to the star(s) of this system)
-- local routes (from the star(s) to the trade ports)
-- trade ports parameters
-- flow rate required to maintain the required number of trade ships
Flow.calculateSystemParams = function()
	-- delete the old value if it was, all calculation results will be written here
	Core.params = nil

	local system = Game.system

	-- dont spawn tradeships in unpopulated systems
	if system.population == 0 then return nil end

	-- all ports in the system
	local ports = Space.GetBodies("SpaceStation")
	-- check if the current system can be traded in
	if #ports == 0 then return nil end

	-- all routes in the system
	-- routes are laid from the nearest star
	local routes = {}
	for _,port in ipairs(ports) do
		local from = port:GetSystemBody().nearestJumpable.body
		local distance = from:DistanceTo(port)
		table.insert(routes, {
			from = from,
			to = port,
			distance = distance,
			weight = port.numDocks / distance * Core.AU
		})
	end

	-- get ships listed as tradeships, if none - give up
	local ship_names = getAcceptableShips()
	if #ship_names == 0 then return nil end

	local imports, exports = getImportsExports(system)

	-- if there is no market then there is no trade
	if #imports == 0 or #exports == 0 then return nil end

	-- all tradeship models array
	-- these are real ship objects, they are needed for calculations
	-- but at the same time they will not be inserted into space, so as not to generate events, etc.
	-- after this function completes, they should be eaten by the garbage collector
	local dummies = {}
	for _, ship_name in ipairs(ship_names) do
		local dummy = Ship.Create(ship_name)
		Trader.addEquip(dummy)

		---@type CargoManager
		local cargoMgr = dummy:GetComponent('CargoManager')

		-- just fill it with hydrogen to the brim
		cargoMgr:AddCommodity(Commodities.hydrogen, cargoMgr:GetFreeSpace())
		dummies[ship_name] = dummy
	end

	-- build all hyperspace inbound routes for all ships
	local near_systems = getNearSystems()
	local hyper_routes = {}
	for i = #ship_names, 1, -1 do
		local id = ship_names[i]
		local this_ship_routes = {}
		for _, path in ipairs(near_systems) do
			local status, distance, fuel, duration = dummies[id]:GetHyperspaceDetails(path, system.path)
			if status == "OK" then
				table.insert(this_ship_routes, {from = path, distance = distance, fuel = fuel, duration = duration})
			end
		end
		if #this_ship_routes > 0 then
			hyper_routes[id] = this_ship_routes
		else
			print("WARNING: ship " .. id .. " discarded, because there are no hyperspace routes available for it")
			table.remove(ship_names, i)
		end
	end

	-- build all suitable local routes for all ships
	local local_routes = {}
	for i = #ship_names, 1, -1 do
		local id = ship_names[i]
		local this_ship_routes = {}
		for _,route in ipairs(routes) do
			-- discard route if ship can't dock/land there
			if Trader.isStarportAcceptableForShip(route.to, dummies[id]) then
				-- Estimate Supercruise real-time transit duration (~1.5 to 10 minutes) instead of multi-day sublight travel
				local distLs = route.distance / 299792458.0
				local duration = math.max(90.0, math.min(600.0, 60.0 + distLs * 0.25))
				-- Balance traffic across all system starports instead of piling onto one hub
				local weight = math.pow(route.to.numDocks, 1.2) / math.pow(duration, 1.0)
				table.insert(this_ship_routes, {
					from = route.from,
					to = route.to,
					distance = route.distance,
					ndocks = route.to.numDocks,
					duration = duration,
					weight = weight,
				})
			end
		end
		if #this_ship_routes == 0 then
			-- no suitable local routes for this ship
			print("WARNING: ship " .. id .. " discarded, because there are no local routes available for it")
			table.remove(ship_names, i)
			-- also erasing this ship from hyperspace routes
			hyper_routes[id] = nil
		else
			utils.normWeights(this_ship_routes)
			local_routes[id] = this_ship_routes
		end
	end

	-- as a result, not a single ship might remain
	if #ship_names == 0 then return nil end

	-- now we have only those ships that can jump from somewhere and land somewhere
	-- now set the flow on the most popular route to MAX_ROUTE_FLOW
	-- let's collect all data on routes and calculate the most popular route weight
	local local_routes_map = {}
	for _,routes_for_ship in pairs(local_routes) do
		for _, route_for_ship in ipairs(routes_for_ship) do
			local current = local_routes_map[route_for_ship.to] or 0
			local_routes_map[route_for_ship.to] = current + route_for_ship.weight
		end
	end
	local max_route_weight = 0
	for _, weight in pairs(local_routes_map) do
		max_route_weight = math.max(max_route_weight, weight)
	end

	-- weight to flow conversion factor
	local flow_per_ship = localFactors(Core.MAX_ROUTE_FLOW, system) / max_route_weight
	-- we will reduce it, depending on the legal status of the system

	local total_flow
	-- calculate flow for local routes
	-- and total count of ships in space
	-- it may be necessary to recalculate the flow if the required number of
	-- ships turns out to be too large
	do
		local ships_in_space
		local function calculateFlowForLocalRoutes()
			ships_in_space = 0
			total_flow = 0
			for _, ship_routes in pairs(local_routes) do
				for _, ship_route in ipairs(ship_routes) do
					ship_route.flow = flow_per_ship * ship_route.weight
					total_flow = total_flow + ship_route.flow
					ship_route.amount = ship_route.flow * ship_route.duration / 3600
					ships_in_space = ships_in_space + ship_route.amount
				end
			end
		end
		calculateFlowForLocalRoutes()
		-- checking if we shouldn't reduce the number of ships
		local allowed_ships = utils.asymptote(ships_in_space, Core.MAX_SHIPS, 0.6)
		if ships_in_space > allowed_ships then
			print(string.format("WARNING: lowering ships flow by %.2f for performance reasons", allowed_ships / ships_in_space))
			-- the required amount is too large
			-- lowering the flow for performance purposes
			flow_per_ship = flow_per_ship * allowed_ships / ships_in_space
			-- recalculate for new conditions
			calculateFlowForLocalRoutes()
		end
	end

	-- calculate station's parameters:
	-- summarize the flow to the station from all suitable ships
	local port_params = {}
	for _, ship_routes in pairs(local_routes) do
		for _, ship_route in ipairs(ship_routes) do
			local to = ship_route.to
			if not port_params[to] then port_params[to] = {flow = 0} end
			port_params[to].flow = port_params[to].flow + ship_route.flow
		end
	end

	local old_total_flow = total_flow
	-- now we need to prevent too much flow to the station
	for port, params in pairs(port_params) do
		local max_flow = port.numDocks * localFactors(Core.MAX_BUSY, system) / Core.MIN_STATION_DOCKING_TIME
		if params.flow > max_flow then
			local k = max_flow / params.flow
			params.flow = max_flow
			for _, ship_routes in pairs(local_routes) do
				for _, ship_route in ipairs(ship_routes) do
					if ship_route.to == port then
						local old_flow = ship_route.flow
						ship_route.flow = ship_route.flow * k
						ship_route.weight = ship_route.weight * k
						total_flow = total_flow - old_flow + ship_route.flow
					end
				end
			end
			print(port:GetLabel() .. ": the flow has been reduced so that the stay at the station is not too short")
		end
	end

	if old_total_flow ~= total_flow then
		print("old total flow: " .. old_total_flow .. " new total flow: " .. total_flow)
		for _, ship_routes in pairs(local_routes) do
			utils.normWeights(ship_routes)
		end
	end

	-- now we know the total flow, we can calculate the flow and the number of ships in hyperspace
	-- adding flow information to hyper_routes
	for _, id in ipairs(ship_names) do
		-- the probabilities are the same for all hyper-routes of a given ship
		local p = 1 / #ship_names / #hyper_routes[id]
		for _, row in ipairs(hyper_routes[id]) do
			row.cloud_duration = inboundCloudDuration(row.duration)
			row.flow = p * total_flow
			row.ships = row.flow * row.cloud_duration / 3600
		end
	end

	-- calculate station parking times
	-- calculate the maximum flow to the station
	local max_station_flow = 0
	for _, row in pairs(port_params) do
		if row.flow > max_station_flow then
			max_station_flow = row.flow
		end
	end

	-- conversion factor flow -> station_load
	-- this is quite artifical calculation
	-- we want the maximum station load (occupied pads/all pads) to be <MAX_BUSY>
	-- and we also want ships to stay longer at less popular stations
	-- to have some kind of presence
	-- therefore, we make the dependence of the load on the flow not linear but radical
	local flow_to_busy = localFactors(Core.MAX_BUSY, system) / math.sqrt(max_station_flow) -- conversion factor
	-- we also reduce the workload of stations, depending on the criminal situation
	for port, params in pairs(port_params) do
		params.ndocks = port.numDocks
		-- parking time cannot be less than the specified minimum
		params.landed = math.max(math.sqrt(params.flow) * flow_to_busy  * params.ndocks, Core.MIN_STATION_DOCKING_TIME * params.flow)
		params.busy = params.landed / params.ndocks
		params.time = params.landed / params.flow
	end

	Core.params = {
		-- list of ship names that can actually trade in this system
		ship_names = ship_names,
		-- market parameters
		imports = imports,
		exports = exports,
		-- ship flow
		total_flow = total_flow,
		-- available routes lookup table by ship name
		local_routes = local_routes,
		-- available hyperspace routes lookup table by ship name
		hyper_routes = hyper_routes,
		-- station parameters lookup table by it's path
		port_params = port_params,
		-- all ports in the system
		ports = ports
	}
	return true
end

-- run this function at the start of the game or when jumped to another system
Flow.spawnInitialShips = function()

	if not Core.params then return nil end

	local hyper_routes = Core.params.hyper_routes
	local local_routes = Core.params.local_routes
	local port_params = Core.params.port_params

	-- we want to calculate how many ships of each model are in space, hyperspace
	-- and stations on average
	-- it is needed for initial spawn

	-- create tables for all possible ship placement options
	-- table for ships flying in space
	local routes_variants = {}
	-- table for ships docked at station
	local docked_variants = {}
	-- amount of ships in space at start
	local ships_in_space = 0
	for id, ship_routes in pairs(local_routes) do
		for _, ship_route in ipairs(ship_routes) do
			table.insert(
				routes_variants, {
					id = id,
					from = ship_route.from,
					to = ship_route.to,
					weight = ship_route.amount
				})
			table.insert(
				docked_variants, {
					id = id,
					port = ship_route.to,
					weight = ship_route.flow
				})
			ships_in_space = ships_in_space + ship_route.amount
		end
	end
	local port_summary = {}
	for k, v in pairs(port_params) do
		v.port = k
		table.insert(port_summary, v)
	end
	utils.normWeights(routes_variants)
	utils.normWeights(docked_variants)

	-- amount of ships docked at start
	local ships_docked = 0
	for _, params in pairs(port_params) do
		ships_docked = ships_docked + params.landed
	end

	-- table for ships in inbound hyperspace cloud
	local cloud_variants = {}
	-- amount of ships in cloud at start
	local ships_in_cloud = 0
	for id, ship_routes in pairs(hyper_routes) do
		for _, ship_route in ipairs(ship_routes) do
			ships_in_cloud = ships_in_cloud + ship_route.ships
			table.insert(cloud_variants, {
				ship = id,
				from = ship_route.from,
				cloud_duration = ship_route.cloud_duration,
				weight = ship_route.ships
			})
		end
	end
	utils.normWeights(cloud_variants)

	-- if we generate ships after jumping into the system, and not when starting a new game,
	-- count the number of ships that were transferred to this system from the
	-- source system, and reduce the need for generation by this amount
	if Core.ships == nil then Core.ships = {} end
	for ship, trader in pairs(Core.ships) do
		if trader.status == 'hyperspace' then
			ships_in_cloud = math.max(0, ships_in_cloud - 1)
			-- and also assign a random port for this ship, if there are any ports for it at all
			local routes_for_ship = Core.params.local_routes[ship.shipId]
			if routes_for_ship then
				trader.route = utils.chooseNormalized(routes_for_ship)
			else
				-- TODO but what if there are no ports for it?
			end
		end
	end

	-- selection table where the ship will be at the start
	local spawn_in = {
		{place = "inbound", weight = ships_in_space},
		{place = "hyperspace", weight = ships_in_cloud},
		{place = "docked", weight = ships_docked}
	}
	-- we remember this data for output to the debug table
	Core.params.spawn_in = {{"inbound", ships_in_space}, {"hyperspace", ships_in_cloud}, {"docked", ships_docked}}
	utils.normWeights(spawn_in)

	-- generating ships (guarantee docked presence, active Supercruise lane traffic, and arrival clouds)
	Core.log:add(nil, string.format('spawnInitialShips: %d ports, %d routes, %d clouds', #port_summary, #routes_variants, #cloud_variants))

	-- Ensure persistent regional vessel roster exists for this system
	if Game.system then
		ShipRegistry.EnsureSystemRoster(Game.system, Core.params.ship_names, Core.params.ports)
	end

	-- 1. Docked Ships at Stations (occupy pads while capping per-station and system-wide totals for multi-station hubs like Sol)
	local dockedVariantsByPort = {}
	for _, dv in ipairs(docked_variants) do
		dockedVariantsByPort[dv.port] = dockedVariantsByPort[dv.port] or {}
		table.insert(dockedVariantsByPort[dv.port], dv)
	end
	local totalDockedSpawned = 0
	local maxSystemDocked = 24
	local perPortCap = (#port_summary >= 10) and 1 or ((#port_summary >= 5) and 2 or 3)
	for portIdx, portParam in ipairs(port_summary) do
		if totalDockedSpawned >= maxSystemDocked then
			break
		end
		local portBody = portParam.port
		local portBodyIdx = portBody.path and portBody.path.bodyIndex or nil
		local candidates = dockedVariantsByPort[portBody]
		local ndocks = portParam.ndocks or portBody.numDocks or 0
		if candidates and #candidates > 0 and ndocks > 1 then
			utils.normWeights(candidates)
			local minLeaveFree = (ndocks >= 4) and 2 or 1
			local maxAllowed = math.max(1, math.min(ndocks - minLeaveFree, perPortCap, maxSystemDocked - totalDockedSpawned))
			local targetDocked = math.clamp(math.ceil(ndocks * 0.25), 1, maxAllowed)
			if ndocks <= 2 then
				targetDocked = 1
			end
			for i = 1, targetDocked do
				local pick = utils.chooseNormalized(candidates)
				local rec = pick and Game.system and ShipRegistry.AcquireShipForSystem(Game.system, nil, pick.id, { stationBodyIdx = portBodyIdx })
				local ship = pick and Space.SpawnShipDocked(pick.id, portBody)
				if ship then
					totalDockedSpawned = totalDockedSpawned + 1
					Core.ships[ship] = { ts_error = "OK", status = 'docked', starport = portBody, ship_name = pick.id }
					if rec then
						ShipRegistry.ApplyRecordToShip(ship, rec)
					else
						ship:SetLabel(Ship.MakeRandomLabel(pick.id, "TRADER"))
					end
					Trader.addEquip(ship)
					Trader.addHyperdriveFuel(ship)
					Trader.addCargo(ship, 'export')
					local plan = Trader.computeStationDwellPlan(ship, portBody, ship.usedCargo or 0, 0, rec, true)
					local stagger = (portIdx - 1) * 12 + (i - 1) * 35
					if plan.action == 'hangar' then
						Core.ships[ship].hangarDuration = plan.hangarDuration
						Trader.assignTask(ship, Game.time + plan.padDuration + (portIdx - 1) * 6, 'doStowHangar')
					else
						Trader.assignTask(ship, Game.time + plan.padDuration + stagger, 'doUndock')
					end
				elseif rec then
					ShipRegistry.ReleaseLive(rec.label)
				end
			end
		end
	end

	-- 2. Active Supercruise Ships Along Shipping Lanes (Star->Station & Station<->Station Transport Corridors)
	if #routes_variants > 0 then
		local interStationCorridors = {}
		if #port_summary >= 2 then
			for i = 1, #port_summary do
				for j = 1, #port_summary do
					if i ~= j then
						local pA = port_summary[i].port
						local pB = port_summary[j].port
						if pA and pB and pA:DistanceTo(pB) > 300000 then
							table.insert(interStationCorridors, { from = pA, to = pB })
						end
					end
				end
			end
		end

		local targetInbound = math.clamp(#port_summary * 2 + 4, 8, 16)
		for idx = 1, targetInbound do
			local params = utils.chooseNormalized(routes_variants)
			local hj_route = params and hyper_routes[params.id] and utils.chooseEqual(hyper_routes[params.id])

			if params and hj_route then
				local fromBody = params.from
				local toBody = params.to
				local useInterStation = (#interStationCorridors > 0) and (idx % 2 == 0)
				if useInterStation then
					local corr = interStationCorridors[((idx - 1) % #interStationCorridors) + 1]
					local canLand = false
					for _, r in ipairs(local_routes[params.id] or {}) do
						if r.to == corr.to then
							canLand = true
							break
						end
					end
					if canLand then
						fromBody = corr.from
						toBody = corr.to
					else
						useInterStation = false
					end
				end

				local rec = Game.system and ShipRegistry.AcquireShipForSystem(Game.system, nil, params.id, { stationBodyIdx = toBody.path and toBody.path.bodyIndex or nil })
				local ship
				if useInterStation then
					local startDist = math.max((fromBody:GetPhysicalRadius() or 1000) + 15000, 20000)
					ship = Space.SpawnShipOrbit(params.id, fromBody, startDist, startDist * 1.2)
				else
					local starBody = fromBody
					local starRad = math.max((starBody:GetSystemBody() and starBody:GetSystemBody().radius) or 7e8, 7e8)
					ship = Space.SpawnShipOrbit(params.id, starBody, starRad * 3.5, starRad * 4.2)
				end

				if ship then
					if rec then
						ShipRegistry.ApplyRecordToShip(ship, rec)
					else
						ship:SetLabel(Ship.MakeRandomLabel(params.id, "TRADER"))
					end
					Core.ships[ship] = { ts_error = "OK", status = 'inbound', starport = toBody, ship_name = params.id }

					Trader.addEquip(ship)
					Trader.addHyperdriveFuel(ship, hj_route.fuel)
					Trader.addCargo(ship, 'import')

					-- Stratify t_ratio evenly across [0.12, 0.88] so traffic forms continuous streams along the transport lanes
					local baseFrac = 0.12 + 0.76 * ((idx - 0.5) / targetInbound)
					local jitter = Engine.rand:Number(-0.04, 0.04)
					local tRatio = math.clamp(baseFrac + jitter, 0.10, 0.88)
					Space.PutShipOnRoute(ship, toBody, tRatio)
					ship:AIDockWith(toBody)
				elseif rec then
					ShipRegistry.ReleaseLive(rec.label)
				end
			end
		end
	end

	-- 3. Short-Fuse Arrival Hyperspace Clouds
	if #cloud_variants > 0 then
		local numClouds = Engine.rand:Integer(4, 6)
		for _ = 1, numClouds do
			local cloud = utils.chooseNormalized(cloud_variants)
			local routesForShip = cloud and Core.params.local_routes[cloud.ship]
			local route = routesForShip and #routesForShip > 0 and utils.chooseNormalized(routesForShip)
			if cloud and route then
				local dest_time = Game.time + Engine.rand:Number(12, 75)
				Trader.spawnInCloud(cloud.ship, cloud, route, dest_time)
			end
		end
	end

	-- 4. Initial Planetary Ring & Asteroid Mining Supply Lines
	local miningSites = {}
	if Game.system then
		for _, path in ipairs(Game.system:GetBodyPaths()) do
			local sb = path:GetSystemBody()
			if sb and (sb.hasRings or sb.type == "PLANET_ASTEROID") and sb.body then
				table.insert(miningSites, sb.body)
			end
		end
	end
	if #miningSites > 0 and #port_summary > 0 then
		local numMiners = math.clamp(#miningSites * 2, 2, 6)
		local minerHulls = { "dsminer", "kanara" }
		for _ = 1, numMiners do
			local hull = minerHulls[Engine.rand:Integer(1, #minerHulls)]
			local site = miningSites[Engine.rand:Integer(1, #miningSites)]
			local port = port_summary[Engine.rand:Integer(1, #port_summary)].port
			local rec = Game.system and ShipRegistry.AcquireShipForSystem(Game.system, "MINER", hull, { stationBodyIdx = port.path and port.path.bodyIndex or nil })
			local minerShip = Space.SpawnShip(hull, 5, 8)
			if minerShip then
				if rec then
					ShipRegistry.ApplyRecordToShip(minerShip, rec)
				else
					minerShip:SetLabel(Ship.MakeRandomLabel(hull, "MINER"))
				end
				Core.ships[minerShip] = {
					ts_error = "OK",
					status = 'inbound',
					starport = port,
					ship_name = hull,
					assignment = { type = 'mining', site = site, refinery = port }
				}
				Trader.addEquip(minerShip)
				Space.PutShipOnRoute(minerShip, site, Engine.rand:Number(0.2, 0.8))
				minerShip:AIFlyTo(site)
				Trader.assignTask(minerShip, Game.time + Engine.rand:Number(70, 140), 'doReturnFromMining')
			elseif rec then
				ShipRegistry.ReleaseLive(rec.label)
			end
		end
	end

	return ships_in_space
end

Flow.setPlayerAsTraderDocked = function()
	local ship = Game.player
	--if player is not a trader
	if Core.ships[ship] then
		print("Flow.setPlayerAsTraderDocked: player is already a trader")
		return
	end
	--if player is currently docked
	if ship.flightState ~= 'DOCKED' then
		print("Flow.setPlayerAsTraderDocked: can't set player as docked trader when player is not currently docked")
		return
	end
	local dockedStation = ship:GetDockedWith()
	Core.ships[ship] = { ts_error = "OK", status = 'docked', starport = dockedStation, ship_name = Game.player.shipId }
	Trader.assignTask(ship, Game.time + utils.deviation(Core.params.port_params[Core.ships[ship].starport].time * 3600, 0.8), 'doUndock')
end

Flow.setPlayerAsTraderInbound = function()
	local ship = Game.player
	--if player is not a trader
	if Core.ships[ship] then
		print("Flow.setPlayerAsTraderInbound: player is already a trader")
		return
	end
	-- Space.PutShipOnRoute will teleport player to star's surface when player is docked. We don't want that
	if ship.flightState ~= 'FLYING' then
		print("Flow.setPlayerAsTraderInbound: can't set player as inbound trader when player is not currently flying")
		return
	end
	-- if there's any station in the system
	local nearestStation = ship:FindNearestTo("SPACESTATION")
	if not nearestStation then
		print("Flow.setPlayerAsTraderInbound: no nearby station is found to set player as inbound trader")
		return
	end
	Core.ships[ship] = { ts_error = "OK", status = 'inbound', starport = nearestStation, ship_name = Game.player.shipId }
	Space.PutShipIntoOrbit(ship, Game.system:GetStars()[1].body)
	Space.PutShipOnRoute(ship, Core.ships[ship].starport, Engine.rand:Number(0.0, 0.999))-- don't generate at the destination
	ship:AIDockWith(Core.ships[ship].starport)
end

Flow.processHangars = function()
	if not Game.system or not Core.params or not Core.params.ports then return end
	local activeCount = 0
	for _ in pairs(Core.ships or {}) do activeCount = activeCount + 1 end
	if activeCount >= Core.MAX_SHIPS then return end

	local ports = Core.params.ports
	if #ports == 0 then return end

	local launched = 0
	local startIdx = Engine.rand:Integer(1, #ports)
	for offset = 0, #ports - 1 do
		if activeCount >= Core.MAX_SHIPS or launched >= 2 then break end
		local port = ports[((startIdx + offset - 1) % #ports) + 1]
		if port and port:exists() and (port.freeDocks or 0) >= 2 and port.path then
			local readyList = ShipRegistry.GetHangarReadyShips(Game.system, port.path.bodyIndex, Game.time)
			if #readyList > 0 then
				local rec = readyList[1]
				if ShipDef[rec.shipId] then
					local ship = Space.SpawnShipFromHangar(rec.shipId, port)
					if ship then
						ShipRegistry.ApplyRecordToShip(ship, rec)
						Core.ships[ship] = { ts_error = "OK", status = 'unstowing', starport = port, ship_name = rec.shipId }
						Trader.addEquip(ship)
						Trader.addHyperdriveFuel(ship)
						Trader.addCargo(ship, 'export')
						ShipRegistry.MarkActive(rec.label, Game.system.path, port.path.bodyIndex)
						Core.log:add(ship, 'Elevating from hangar bay at ' .. port.label)
						activeCount = activeCount + 1
						launched = launched + 1
					else
						rec.hangarUntil = Game.time + 120
					end
				end
			end
		end
	end
end

Flow.run = function()
	if not Core.params or not Core.params.ship_names or #Core.params.ship_names == 0 then return end
	Flow.processHangars()
	local activeCount = 0
	for _ in pairs(Core.ships) do activeCount = activeCount + 1 end
	if activeCount < Core.MAX_SHIPS then
		local ship_name = utils.chooseEqual(Core.params.ship_names)
		local hyperRoutes = ship_name and Core.params.hyper_routes[ship_name]
		local localRoutes = ship_name and Core.params.local_routes[ship_name]
		local cloud = hyperRoutes and #hyperRoutes > 0 and utils.chooseEqual(hyperRoutes)
		-- we immediately choose the local route, because it depends on which star to
		-- jump to in the multiple system
		local route = localRoutes and #localRoutes > 0 and utils.chooseNormalized(localRoutes)
		if ship_name and cloud and route then
			Trader.spawnInCloud(ship_name, cloud, route, Game.time + Engine.rand:Number(15, 45))
		end
	end
	Core.last_spawn_interval = Engine.rand:Number(20, 45) -- steady real-time arrival cadence
	Trader.callInThisSystem(Game.time + Core.last_spawn_interval, Flow.run)
end

Flow.cleanTradeShipsTable = function()
	local HYPERCLOUD_DURATION = 172800 -- 2 days
	local total, hyperspace, removed = 0, 0, 0
	for ship, trader in pairs(Core.ships) do
		total = total + 1
		if trader.status == 'hyperspace_out' then
			hyperspace = hyperspace + 1
			-- remove well past due ships as the player can not catch them
			if trader.jump_time + HYPERCLOUD_DURATION < Game.time then
				Core.ships[ship] = nil
				removed = removed + 1
			end
		end
	end
	-- print('cleanTSTable:total:'..total..',active:'..total - hyperspace..',removed:'..removed)
end

-- we leave only those ships that flew into this system
Flow.updateTradeShipsTable = function()
	local total, removed = 0, 0
	for ship, trader in pairs(Core.ships) do
		total = total + 1
		if trader.status ~= 'hyperspace_out' or not trader.dest_path:IsSameSystem(Game.system.path) then
			Core.ships[ship] = nil
			removed = removed + 1
		else
			trader.status = 'hyperspace'
		end
	end
	-- print('updateTSTable:total:'..total..',removed:'..removed)
end

return Flow

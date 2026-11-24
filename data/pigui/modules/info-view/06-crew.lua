-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Comms		= require 'Comms'
local Game		= require 'Game'
local Lang		= require 'Lang'
local ShipDef	= require 'ShipDef'
local InfoView	= require 'pigui.views.info-view'
local PiGuiFace = require 'pigui.libs.face'
local Commodities = require 'Commodities'
local PlayerState = require 'PlayerState'
local PlayerFleet = require 'modules.PlayerFleet.PlayerFleet'

local ui = require 'pigui'
local textTable = require 'pigui.libs.text-table'

local l = Lang.GetResource("ui-core")
local lcrew = Lang.GetResource("module-crewcontracts")
local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local colors = ui.theme.colors

local itemSpacing = ui.rescaleUI(Vector2(5, 8), Vector2(1920, 1080))
local childFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders' }

-- Anti-abuse feature - this locks out the piloting commands based on a timer.
-- It knows when the crew were last checked for a piloting skill, and prevents
-- the player drumming the button until it works.
local pilotLockoutTimer = 0
local pilotLockoutTimeout = 30 -- Half a minute (in seconds)

-- Cached state about the UI screen
local lastTaskResult = ""
local cachedCrewList = nil
local inspectingCrewMember = nil

local checkPilotLockout = function ()
	return Game.time > pilotLockoutTimer + pilotLockoutTimeout
end

local pilotLockout = function ()
	pilotLockoutTimer = Game.time
end

-- Very local function used by functions in crewTasks
local testCrewMember = function (attribute,playerOK)
	for crewMember in Game.player:EachCrewMember() do
		local result = crewMember:TestRoll(attribute)
		if (playerOK or not crewMember.player) and result then
			return crewMember,result
		end
	end
	return false
end

-- A table of task functions, keyed by their description, which will set feedback.
-- They take no arguments, and are connected to buttons.
local crewTasks = {
	ATTEMPT_TO_REPAIR_HULL = function ()
		-- Convoluted...
		local hullMass = ShipDef[Game.player.shipId].hullMass
		local hullMassLeft = Game.player.hullMassLeft
		local hullDamage = hullMass - hullMassLeft
		if hullDamage > 0 then
			---@type CargoManager
			local cargoMgr = Game.player:GetComponent('CargoManager')
			local num_metal_alloys = cargoMgr:CountCommodity(Commodities.metal_alloys)

			if num_metal_alloys <= 0 then
				return l.NOT_ENOUGH_ALLOY_TO_ATTEMPT_A_REPAIR:interp({alloy = l.METAL_ALLOYS})
			end

			local crewMember, result = testCrewMember('engineering',true)
			if crewMember then
				local repair = math.min(
					-- Need metal alloys for repair. Check amount.
					math.ceil(hullDamage/(64 - result)), -- 65 > result > 3
					num_metal_alloys
				)
				cargoMgr:RemoveCommodity(Commodities.metal_alloys, repair) -- These will now be part of the hull.
				local repairPercent = math.min(math.ceil(100 * (repair + hullMassLeft) / hullMass), 100) -- Get new hull percentage...
				Game.player:SetHullPercent(repairPercent)   -- ...and set it.
				return l.HULL_REPAIRED_BY_NAME_NOW_AT_N_PERCENT:interp({name = crewMember.name,repairPercent = repairPercent})
			else
				local repairPercent = math.max(math.floor(100 * (hullMassLeft - 1) / hullMass), 1) -- Get new hull percentage...
				Game.player:SetHullPercent(repairPercent)   -- ...and set it.
				return l.HULL_REPAIR_ATTEMPT_FAILED_HULL_SUFFERED_MINOR_DAMAGE
			end
		else
			return l.HULL_DOES_NOT_REQUIRE_REPAIR
		end
	end,

	DESTROY_ENEMY_SHIP = function ()
		local crewMember = checkPilotLockout() and testCrewMember('piloting')
		if not crewMember then
			pilotLockout()
			return (l.THERE_IS_NOBODY_ELSE_ON_BOARD_ABLE_TO_FLY_THIS_SHIP)
		end
		if Game.player.flightState ~= 'FLYING'
		then
			return (({
				DOCKED = l.YOU_MUST_REQUEST_LAUNCH_CLEARANCE_FIRST_COMMANDER,
				LANDED = l.YOU_MUST_LAUNCH_FIRST_COMMANDER,
				JUMPING = l.WE_ARE_IN_HYPERSPACE_COMMANDER,
				HYPERSPACE = l.WE_ARE_IN_HYPERSPACE_COMMANDER,
				DOCKING = l.THE_SHIP_IS_UNDER_STATION_CONTROL_COMMANDER,
				UNDOCKING = l.THE_SHIP_IS_UNDER_STATION_CONTROL_COMMANDER,
			})[Game.player.flightState])
		elseif not Game.player:GetCombatTarget() then
			return (l.YOU_MUST_FIRST_SELECT_A_COMBAT_TARGET_COMMANDER)
		else
			Game.player:AIKill(Game.player:GetCombatTarget())
			return (l.PILOT_SEAT_IS_NOW_OCCUPIED_BY_NAME:interp({name = crewMember.name}))
		end
	end,

	DOCK_AT_CURRENT_TARGET = function ()
		local crewMember = checkPilotLockout() and testCrewMember('piloting')
		if not crewMember then
			pilotLockout()
			return (l.THERE_IS_NOBODY_ELSE_ON_BOARD_ABLE_TO_FLY_THIS_SHIP)
		end
		local target = Game.player:GetNavTarget()
		if Game.player.flightState ~= 'FLYING'
		then
			return (({
				DOCKED = l.YOU_MUST_REQUEST_LAUNCH_CLEARANCE_FIRST_COMMANDER,
				LANDED = l.YOU_MUST_LAUNCH_FIRST_COMMANDER,
				JUMPING = l.WE_ARE_IN_HYPERSPACE_COMMANDER,
				HYPERSPACE = l.WE_ARE_IN_HYPERSPACE_COMMANDER,
				DOCKING = l.THE_SHIP_IS_UNDER_STATION_CONTROL_COMMANDER,
				UNDOCKING = l.THE_SHIP_IS_UNDER_STATION_CONTROL_COMMANDER
			})[Game.player.flightState])
		elseif not (target and target:isa('SpaceStation')) then
			return (l.YOU_MUST_FIRST_SELECT_A_SUITABLE_NAVIGATION_TARGET_COMMANDER)
		else
			Game.player:SetFlightControlState("CONTROL_AUTOPILOT")
			Game.player:AIDockWith(target)
			return (l.PILOT_SEAT_IS_NOW_OCCUPIED_BY_NAME:interp({name = crewMember.name}))
		end
	end
}

local dismissButton = function(crewMember)
	if Game.player:Dismiss(crewMember) then
		crewMember:Save() -- Save to persistent characters list

		if crewMember.contract then
			if crewMember.contract.outstanding > 0 then
				Comms.Message(l.IM_TIRED_OF_WORKING_FOR_NOTHING_DONT_YOU_KNOW_WHAT_A_CONTRACT_IS,crewMember.name)
				crewMember.playerRelationship = crewMember.playerRelationship - 5 -- Hate!
				if crewMember.contract.outstanding > 5e2 then
					-- there are consequences for defaulting on a big enough payment!
					PlayerState.AddCrime("CONTRACT_FRAUD", crewMember.contract.outstanding * 1.1)
				end
			elseif crewMember:TestRoll('playerRelationship') then
				Comms.Message(l.ITS_BEEN_GREAT_WORKING_FOR_YOU_IF_YOU_NEED_ME_AGAIN_ILL_BE_HERE_A_WHILE,crewMember.name)
			elseif not crewMember:TestRoll('lawfulness') then
				Comms.Message(l.YOURE_GOING_TO_REGRET_SACKING_ME,crewMember.name)
				crewMember.playerRelationship = crewMember.playerRelationship - 1
			else
				Comms.Message(l.GOOD_RIDDANCE_TO_YOU_TOO,crewMember.name)
				crewMember.playerRelationship = crewMember.playerRelationship - 1
			end
		end

		cachedCrewList = nil
		inspectingCrewMember = nil
	end
end

local function isCrewActive(crew)
	if not crew then return false end
	for member in Game.player:EachCrewMember() do
		if member == crew then
			return true
		end
	end
	return PlayerFleet.FindCrewAssignment(crew) ~= nil
end

-- Function that creates the crew list (Flagship + Fleet ships)
local function makeCrewList()
	local t = {
		separated = true, headerOnly = true,
		{ l.NAME_PERSON, l.POSITION, l.WAGE, l.OWED, l.NEXT_PAID, "", font = orbiteer.heading }
	}

	local wageTotal = 0
	local owedTotal = 0

	-- 1. Flagship crew (including Player Commander)
	local flagshipLabel = (Game.player.shipName and Game.player.shipName ~= "") and Game.player.shipName or "Flagship"
	for crewMember in Game.player:EachCrewMember() do
		local crewWage = (crewMember.contract and crewMember.contract.wage or 0)
		local crewOwed = (crewMember.contract and crewMember.contract.outstanding or 0)
		wageTotal = wageTotal + crewWage
		owedTotal = owedTotal + crewOwed

		local posText
		if crewMember.player then
			posText = crewMember.title or l.COMMANDER
		else
			posText = string.format("%s (%s)", crewMember.title or l.GENERAL_CREW, flagshipLabel)
		end

		table.insert(t, {
			crewMember.name,
			posText,
			{ ui.Format.Money(crewWage), color = colors.econProfit },
			{ ui.Format.Money(crewOwed), color = colors.econLoss },
			crewMember.contract and ui.Format.Date(crewMember.contract.payday) or "",
			function()
				if ui.button(l.MORE_INFO .. '##' .. crewMember.name, Vector2(-1, 0)) then
					inspectingCrewMember = crewMember
				end
			end
		})
	end

	-- 2. Fleet Captains & Fleet Crew across player-owned vessels
	for _, entry in ipairs(PlayerFleet.GetShips() or {}) do
		if entry.status ~= "DESTROYED" then
			for idx, member in ipairs(entry.crew or {}) do
				local isCap = (member == entry.captain)
				local crewWage = tonumber(member.fleetWage) or 0
				local crewOwed = tonumber(member.fleetOwed) or 0
				wageTotal = wageTotal + crewWage
				owedTotal = owedTotal + crewOwed

				local roleLabel = isCap and "Captain" or (member.title or l.GENERAL_CREW)
				local posText = string.format("%s (%s)", roleLabel, entry.shipName or "Fleet Vessel")

				table.insert(t, {
					member.name,
					posText,
					{ ui.Format.Money(crewWage), color = colors.econProfit },
					{ ui.Format.Money(crewOwed), color = colors.econLoss },
					member.fleetPayday and ui.Format.Date(member.fleetPayday) or "",
					function()
						if ui.button(l.MORE_INFO .. '##fleet_' .. tostring(entry.uid) .. '_' .. tostring(idx), Vector2(-1, 0)) then
							inspectingCrewMember = member
						end
					end
				})
			end
		end
	end

	table.insert(t, {
		false,
		{ l.TOTAL .. " (Tax-Deductible)", color = colors.alertYellow },
		{ ui.Format.Money(wageTotal),	color = colors.econProfit },
		{ ui.Format.Money(owedTotal),	color = colors.econLoss },
		false,
		false
	})

	return t
end

local function drawCrewList(crewList)
	ui.child("CrewListPane", Vector2(0, 0), nil, childFlags, function()
		textTable.drawTable(6, nil, crewList)

		ui.newLine()
		ui.withFont(orbiteer.heading, function() ui.text(l.GIVE_ORDERS_TO_CREW .. ":") end)
		for label, task in pairs(crewTasks) do
			if ui.button(l[label], Vector2(0, 0)) then lastTaskResult = task() end
			ui.sameLine()
		end
		ui.newLine()
		ui.text(lastTaskResult)
	end)
end

local crewFace = nil
local function drawCrewInfo(crew)
	if not crewFace or crewFace.character ~= crew then
		crewFace = PiGuiFace.New(crew)
	end

	local fleetEntry, isFleetCaptain = PlayerFleet.FindCrewAssignment(crew)

	local region = ui.getContentRegion()
	local leftWidth = math.floor(region.x * 0.50)
	ui.child("PlayerInfoDetails", Vector2(leftWidth, 0), nil, childFlags, function()
		ui.withFont(orbiteer.heading, function() ui.text(crew.name) end)
		ui.newLine()

		textTable.withHeading(l.QUALIFICATION_SCORES, orbiteer.body, {
			{ l.ENGINEERING,	crew.engineering },
			{ l.PILOTING,		crew.piloting },
			{ l.NAVIGATION,		crew.navigation },
			{ l.SENSORS,		crew.sensors },
		})
		ui.newLine()
		textTable.withHeading(l.REPUTATION, orbiteer.body, {
			{ l.RATING,			l[crew:GetCombatRating()] },
			{ l.KILLS,			ui.Format.Number(crew.killcount) },
			{ l.REPUTATION..":",l[crew:GetReputationRating()] },
		})

		if not crew.player then
			ui.newLine()
			if fleetEntry then
				textTable.withHeading(l.EMPLOYMENT, orbiteer.body, {
					{ "Assigned Vessel",	fleetEntry.shipName or "Fleet Vessel" },
					{ l.POSITION,			isFleetCaptain and "Captain" or (crew.title or "Fleet Crew") },
					{ "Vessel Status",		string.format("%s — %s", fleetEntry.status or "DOCKED", fleetEntry.locationName or "Unknown") },
					{ l.WAGE,				ui.Format.Money(crew.fleetWage or 0) .. " / wk" },
					{ l.OWED,				ui.Format.Money(crew.fleetOwed or 0) },
					{ l.NEXT_PAID,			crew.fleetPayday and ui.Format.Date(crew.fleetPayday) or "—" },
					{ "Completed Ops",		tostring(crew.completedOps or 0) },
					{ "Active Service",		string.format("%d wk", crew.activeWeeks or crew.weeksServed or 0) },
				})

				ui.spacing()
				if (crew.fleetOwed or 0) > 0 and PlayerState.GetMoney() > 0 then
					local settleAmt = math.min(PlayerState.GetMoney(), crew.fleetOwed)
					if ui.button("Settle Arrears (" .. ui.Format.Money(settleAmt) .. ")##pay_arrears", Vector2(0, 0)) then
						local _, msg = PlayerFleet.PayCrewArrears(crew)
						lastTaskResult = msg or ""
					end
					ui.sameLine()
				end

				if fleetEntry.status == "DOCKED" then
					if not isFleetCaptain then
						if ui.button("Promote to Captain##prom_cap", Vector2(0, 0)) then
							PlayerFleet.SetCaptain(fleetEntry.uid, crew)
							lastTaskResult = crew.name .. " promoted to Captain."
						end
						ui.sameLine()
					end
					if Game.player.flightState == 'DOCKED' then
						local station = Game.player:GetDockedWith()
						if station and fleetEntry.locationPath == station.path then
							if ui.button("Transfer to Flagship##xfer_flag", Vector2(0, 0)) then
								local ok, msg = PlayerFleet.TransferCrewToPlayerShip(fleetEntry.uid, crew)
								lastTaskResult = msg or ""
								if ok then
									cachedCrewList = nil
									inspectingCrewMember = nil
								end
							end
							ui.sameLine()
						end
					end
					if ui.button(l.DISMISS .. "##dismiss_fleet", Vector2(0, 0)) then
						local ok, msg = PlayerFleet.DismissFleetCrew(fleetEntry.uid, crew)
						lastTaskResult = msg or ""
						if ok then
							cachedCrewList = nil
							inspectingCrewMember = nil
						end
					end
				end
			else
				local flagshipName = (Game.player.shipName and Game.player.shipName ~= "") and Game.player.shipName or (Game.player.label or "Flagship")
				textTable.withHeading(l.EMPLOYMENT, orbiteer.body, {
					{ "Assigned Vessel",	flagshipName },
					{ l.WAGE,				ui.Format.Money((crew.contract and crew.contract.wage) or 0) .. " / wk" },
					{ l.OWED,				ui.Format.Money((crew.contract and crew.contract.outstanding) or 0) },
					{ l.NEXT_PAID,			(crew.contract and crew.contract.payday) and ui.Format.Date(crew.contract.payday) or "—" },
				})

				ui.spacing()
				if Game.player.flightState == 'DOCKED' then
					if ui.button(l.DISMISS, Vector2(0, 0)) then dismissButton(crew) end

					local station = Game.player:GetDockedWith()
					local dockedShips = station and PlayerFleet.GetShipsAtStation(station.path) or {}
					if #dockedShips > 0 then
						ui.newLine()
						ui.withFont(orbiteer.body, function() ui.textColored(colors.uiPrimaryLight, "TRANSFER TO DOCKED FLEET VESSEL") end)
						for _, shipEntry in ipairs(dockedShips) do
							if ui.button("Assign as Captain -> " .. shipEntry.shipName .. "##cap_" .. shipEntry.uid, Vector2(0, 0)) then
								local ok, msg = PlayerFleet.AssignCrewFromPlayerShip(shipEntry.uid, crew, true)
								lastTaskResult = msg or ""
								if ok then
									cachedCrewList = nil
									inspectingCrewMember = nil
								end
							end
							local shipDef = ShipDef[shipEntry.shipId]
							if shipDef and (shipDef.maxCrew or 1) > 1 and shipEntry.captain ~= nil then
								ui.sameLine()
								if ui.button("Assign as Crew -> " .. shipEntry.shipName .. "##crew_" .. shipEntry.uid, Vector2(0, 0)) then
									local ok, msg = PlayerFleet.AssignCrewFromPlayerShip(shipEntry.uid, crew, false)
									lastTaskResult = msg or ""
									if ok then
										cachedCrewList = nil
										inspectingCrewMember = nil
									end
								end
							end
						end
					end
				end
			end

			if false then -- TODO: implement me!
				ui.sameLine()
				if ui.button(l.NEGOTIATE, Vector2(0, 0)) then openNegotiateWindow() end
			end
		end

		ui.newLine()
		if ui.button(lcrew.GO_BACK, Vector2(0, 0)) then inspectingCrewMember = nil end
	end)

	ui.sameLine()

	ui.child("PlayerView", Vector2(0, 0), nil, childFlags, function()
		crewFace:render()
	end)
end

require 'Event'.Register('onGameEnd', function()
	cachedCrewList = nil
	inspectingCrewMember = nil
	lastTaskResult = ""
end)

InfoView:registerView({
    id = "crew",
    name = l.CREW_ROSTER,
    icon = ui.theme.icons.roster,
    showView = true,
	draw = function()
		ui.withStyleVars({ItemSpacing = itemSpacing}, function()
			ui.withFont(pionillium.body, function()
				if inspectingCrewMember and not isCrewActive(inspectingCrewMember) then
					inspectingCrewMember = nil
				end
				if inspectingCrewMember then
					drawCrewInfo(inspectingCrewMember)
				else
					drawCrewList(makeCrewList())
				end
			end)
		end)
	end,
	refresh = function()
		cachedCrewList = makeCrewList()
		inspectingCrewMember = nil
		lastTaskResult = ""
	end,
	debugReload = function()
		package.reimport()
	end
})

-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui          = require 'pigui'
local Game        = require 'Game'
local Lang        = require 'Lang'
local Format      = require 'Format'
local ShipDef     = require 'ShipDef'
local Commodities = require 'Commodities'
local InfoView    = require 'pigui.views.info-view'
local PlayerState = require 'PlayerState'
local PlayerFleet = require 'modules.PlayerFleet.PlayerFleet'

local l = Lang.GetResource("ui-core")
local colors = ui.theme.colors
local icons = ui.theme.icons
local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local Vector2 = _G.Vector2

local childFlags = ui.ChildFlags { 'Borders' }
local spacing = ui.rescaleUI(Vector2(10, 8), Vector2(1920, 1080))
local rosterWidth = ui.rescaleUI(460, Vector2(1920, 1080))

local selectedUid = nil
local statusMsg = nil

local ORDER_COLOR_MAP = {
	IDLE       = colors.fontDim,
	FOLLOW     = colors.hyperspaceInfo,
	DOCK       = colors.alertYellow,
	SELL_CARGO = colors.econProfit,
	AUTO_TRADE = colors.econProfit,
	AUTO_MINE  = colors.uiPrimaryLight,
	PATROL     = colors.combatTarget,
	MISSION    = colors.navTarget,
}

local STATUS_COLOR_MAP = {
	DOCKED      = colors.econProfit,
	UNDOCKING   = colors.alertYellow,
	FLYING      = colors.uiPrimaryLight,
	SUPERCRUISE = colors.hyperspaceInfo,
	DOCKING     = colors.alertYellow,
	JUMPING     = colors.alertYellow,
	HYPERSPACE  = colors.hyperspaceInfo,
	MINING      = colors.uiPrimaryLight,
	PATROLLING  = colors.combatTarget,
	ESCORTING   = colors.hyperspaceInfo,
}

local function formatTelemetryDist(d)
	if not d or d < 0 then return "--" end
	if d < 1000 then
		return string.format("%.0f m", d)
	elseif d < 1e7 then
		return string.format("%.1f km", d / 1000)
	elseif d < 1.496e10 then
		return string.format("%.2f Mm", d / 1e6)
	else
		return string.format("%.2f AU", d / 1.495978707e11)
	end
end

local function formatTelemetrySpeed(v)
	if not v or v < 0 then return "0 m/s" end
	if v >= 299792458 * 0.05 then
		return string.format("%.2fc", v / 299792458)
	elseif v >= 10000 then
		return string.format("%.1f km/s", v / 1000)
	else
		return string.format("%.0f m/s", v)
	end
end

local function drawFleetHeaderBar(ships)
	local activeCount = 0
	for _, s in ipairs(ships) do
		if s.order ~= "IDLE" and s.status ~= "DESTROYED" then
			activeCount = activeCount + 1
		end
	end

	local totalProfit = PlayerFleet.GetTotalProfit()

	ui.child("##FleetCommandTopBar", Vector2(-1, ui.rescaleUI(66, Vector2(1920, 1080))), nil, childFlags, function()
		ui.withFont(orbiteer.heading, function()
			ui.textColored(colors.uiPrimaryLight, "FLEET COMMAND & AUTONOMOUS OPERATIONS")
		end)
		ui.withFont(pionillium.body, function()
			ui.text(string.format("Owned Fleet Ships: %d   |   Active Orders: %d   |   Cumulative Fleet Net Profit: ", #ships, activeCount))
			ui.sameLine(0, 0)
			ui.textColored(totalProfit >= 0 and colors.econProfit or colors.econLoss, Format.Money(totalProfit, false))
			ui.sameLine(0, ui.rescaleUI(24, Vector2(1920, 1080)))
			ui.text("Fleet Operating Account: Player Bank (" .. Format.Money(PlayerState.GetMoney(), false) .. ")")
		end)
	end)
end

local function drawFleetRoster(ships)
	ui.child("##FleetRosterPane", Vector2(rosterWidth, -1), nil, childFlags, function()
		ui.withFont(orbiteer.heading, function()
			ui.textColored(colors.uiPrimaryLight, "COMMISSIONED VESSELS")
		end)
		ui.separator()
		ui.spacing()

		if #ships == 0 then
			ui.textWrapped("You currently command only your Flagship.\n\nVisit any Starport's Ship Market and purchase additional hulls ('Buy into Hangar' or 'Buy & Store Current') to organize an autonomous fleet.")
			return
		end

		for _, entry in ipairs(ships) do
			if not selectedUid then selectedUid = entry.uid end
			local isSelected = (selectedUid == entry.uid)
			local orderCol = ORDER_COLOR_MAP[entry.order or "IDLE"] or colors.fontDim
			local def = ShipDef[entry.shipId]

			local cardBtn = string.format("[%s] %s##fleet_%d", entry.order or "IDLE", entry.shipName or (def and def.name or entry.shipId), entry.uid)
			if ui.button(cardBtn, Vector2(-1, ui.rescaleUI(36, Vector2(1920, 1080))), isSelected and ui.theme.buttonColors.selected or ui.theme.buttonColors.card) then
				selectedUid = entry.uid
			end

			ui.textColored(orderCol, string.format("  %s | %s | Hull %.0f%% | Capt: %s",
				def and def.name or entry.shipId,
				entry.locationName or "Unknown",
				entry.hullPercent or 100,
				entry.captain and entry.captain.name or "Uncrewed"
			))
			if entry.order ~= "IDLE" and (entry.orderProgress or 0) > 0 then
				ui.progressBar(entry.orderProgress, Vector2(-1, ui.rescaleUI(10, Vector2(1920, 1080))), "")
			end
			ui.spacing()
		end
	end)
end

local function drawSkillBar(label, value)
	ui.text(string.format("%-12s %2d", label .. ":", value))
	ui.sameLine()
	ui.progressBar(math.clamp(value / 65, 0, 1), Vector2(ui.rescaleUI(130, Vector2(1920, 1080)), ui.rescaleUI(14, Vector2(1920, 1080))), "")
end

local function drawCommandDeck(entry)
	ui.child("##FleetCommandDeck", Vector2(-1, -1), nil, childFlags, function()
		if not entry then
			ui.withFont(orbiteer.heading, function()
				ui.textColored(colors.uiPrimaryLight, "RECENT FLEET OPERATIONS LOG")
			end)
			ui.separator()
			local logs = PlayerFleet.GetLogs() or {}
			if #logs == 0 then
				ui.textColored(colors.fontDim, "No fleet operations recorded yet.")
			else
				for i = 1, math.min(25, #logs) do
					local item = logs[i]
					local deltaCol = (item.delta or 0) > 0 and colors.econProfit or ((item.delta or 0) < 0 and colors.econLoss or colors.fontDim)
					ui.textColored(colors.uiPrimaryLight, "[" .. item.shipName .. "]")
					ui.sameLine()
					ui.textWrapped(item.message)
					if (item.delta or 0) ~= 0 then
						ui.sameLine()
						ui.textColored(deltaCol, string.format("(%s)", Format.Money(item.delta, false)))
					end
				end
			end
			return
		end

		local def = ShipDef[entry.shipId]
		ui.withFont(orbiteer.title, function()
			ui.text(entry.shipName or (def and def.name or entry.shipId))
		end)
		ui.textColored(colors.fontDim, string.format("Hull: %s   |   Callsign: %s   |   Location: %s   |   Jump Range: %d ly   |   Combat Score: %d",
			def and def.name or entry.shipId,
			entry.label or "----",
			entry.locationName or "Unknown",
			PlayerFleet.GetShipHyperspaceRange(entry),
			PlayerFleet.GetShipCombatScore(entry)
		))
		ui.separator()
		ui.spacing()

		-- Autonomous Order Command Console
		ui.withFont(orbiteer.heading, function()
			ui.textColored(colors.uiPrimaryLight, "STANDING AUTONOMOUS ORDERS")
		end)
		local directiveCol = STATUS_COLOR_MAP[entry.status or ""] or ORDER_COLOR_MAP[entry.order or "IDLE"] or colors.font
		ui.textColored(directiveCol, "Current Directive: " .. (entry.orderPhase or "Standby"))
		if entry.liveShip and entry.liveShip:exists() then
			local live = entry.liveShip
			local okV, vel = pcall(function() return live:GetVelocity() end)
			local spd = (okV and vel and vel.length) and vel:length() or 0
			local distPlayer = (Game.player and live ~= Game.player) and live:DistanceTo(Game.player) or 0
			ui.textColored(colors.hyperspaceInfo, string.format("Live In-System Telemetry: State=%s  |  Speed=%s  |  Range to Flagship=%s",
				tostring(live.flightState or entry.status or "UNKNOWN"),
				formatTelemetrySpeed(spd),
				formatTelemetryDist(distPlayer)
			))
		elseif entry.transit and entry.transit.state then
			ui.textColored(colors.fontDim, string.format("Remote Transit State: %s", tostring(entry.transit.state)))
		end
		if entry.order ~= "IDLE" then
			local etaRem = math.max(0, (entry.orderEta or 0) - Game.time)
			local barText = (etaRem > 0 and ("ETA: " .. Format.Duration(etaRem)))
				or tostring(entry.status or "IN FLIGHT")
			ui.progressBar(entry.orderProgress or 0, Vector2(-1, ui.rescaleUI(18, Vector2(1920, 1080))), barText)
		end

		ui.spacing()
		local hasCaptain = entry.captain ~= nil
		local btnDisabled = (not hasCaptain) and ui.theme.buttonColors.disabled or nil

		if ui.button("Standby / Recall Dock##cmd_idle", Vector2(0, 0), entry.order == "IDLE" and ui.theme.buttonColors.selected or nil) then
			local _, msg = PlayerFleet.IssueOrder(entry.uid, "IDLE")
			statusMsg = msg
		end
		ui.sameLine()
		if ui.button("Wingman Escort (Follow Me)##cmd_follow", Vector2(0, 0), entry.order == "FOLLOW" and ui.theme.buttonColors.selected or btnDisabled) then
			local _, msg = PlayerFleet.IssueOrder(entry.uid, "FOLLOW")
			statusMsg = msg
		end
		ui.sameLine()
		if ui.button("Auto-Trade Sector##cmd_trade", Vector2(0, 0), entry.order == "AUTO_TRADE" and ui.theme.buttonColors.selected or btnDisabled) then
			local _, msg = PlayerFleet.IssueOrder(entry.uid, "AUTO_TRADE")
			statusMsg = msg
		end
		ui.sameLine()
		if ui.button("Auto-Mine Rings##cmd_mine", Vector2(0, 0), entry.order == "AUTO_MINE" and ui.theme.buttonColors.selected or btnDisabled) then
			local _, msg = PlayerFleet.IssueOrder(entry.uid, "AUTO_MINE")
			statusMsg = msg
		end
		ui.sameLine()
		if ui.button("Security Patrol##cmd_patrol", Vector2(0, 0), entry.order == "PATROL" and ui.theme.buttonColors.selected or btnDisabled) then
			local _, msg = PlayerFleet.IssueOrder(entry.uid, "PATROL")
			statusMsg = msg
		end

		local cargoHeld = PlayerFleet.GetCargoUsed(entry)
		if cargoHeld > 0 then
			ui.sameLine()
			local sellBtnText = (entry.status == "DOCKED") and "Liquidate Cargo Hold##cmd_sell_cargo" or "Fly & Sell Cargo##cmd_sell_cargo"
			if ui.button(sellBtnText, Vector2(0, 0), entry.order == "SELL_CARGO" and ui.theme.buttonColors.selected or nil) then
				local _, msg = PlayerFleet.OrderSellCargo(entry.uid)
				statusMsg = msg
			end
		end

		if not hasCaptain then
			ui.textColored(colors.alertYellow, "Note: Assign or recruit a Captain (below or at any Station Hangar) to enable autonomous orders.")
		end

		-- Quick Dock / Recall to Flagship's Current Station if docked
		if Game.player.flightState == "DOCKED" then
			local curSt = Game.player:GetDockedWith()
			if curSt and entry.locationPath ~= curSt.path then
				if ui.button("Ferry / Recall to Current Station (" .. curSt.label .. ")", Vector2(0, 0)) then
					local _, msg = PlayerFleet.OrderFerry(entry.uid, curSt.path)
					statusMsg = msg
				end
			end
		end

		ui.spacing()
		ui.separator()
		ui.spacing()

		-- Two columns: Left = Captain & Crew Skills + Telemetry; Right = Cargo Hold + Vessel Ops Log
		ui.columns(2, "##FleetDeckLowerCols", false)

		ui.withFont(orbiteer.body, function()
			ui.textColored(colors.uiPrimaryLight, "CAPTAIN & CREW TELEMETRY")
		end)
		if entry.captain then
			local cap = entry.captain
			ui.text(string.format("Captain: %s   (Kills: %d)", cap.name, cap.killcount or 0))
			drawSkillBar("Piloting", cap.piloting or 15)
			drawSkillBar("Navigation", cap.navigation or 15)
			drawSkillBar("Engineering", cap.engineering or 15)
			drawSkillBar("Sensors", cap.sensors or 15)
		else
			ui.textColored(colors.fontDim, "No Captain assigned.")
			if entry.status == "DOCKED" then
				if ui.button("Recruit Station Captain (1,500 Cr)##hire_cap", Vector2(0, 0)) then
					local _, msg = PlayerFleet.HireInstantCaptain(entry.uid)
					statusMsg = msg
				end
			end
		end

		if Game.player.flightState == "DOCKED" and entry.status == "DOCKED" then
			local curSt = Game.player:GetDockedWith()
			if curSt and entry.locationPath == curSt.path then
				for member in Game.player:EachCrewMember() do
					if not member.player then
						if ui.button("Transfer " .. member.name .. " from Flagship", Vector2(0, 0)) then
							local _, msg = PlayerFleet.AssignCrewFromPlayerShip(entry.uid, member, entry.captain == nil)
							statusMsg = msg
						end
					end
				end
			end
		end

		ui.spacing()
		ui.text(string.format("Ship Condition: Hull %.0f%%  |  Fuel %.0f%%", entry.hullPercent or 100, entry.fuel or 100))
		ui.text(string.format("Stats: %d Runs  |  %d Missions  |  %dt Hauled",
			(entry.stats and entry.stats.runsCompleted) or 0,
			(entry.stats and entry.stats.missionsDone) or 0,
			(entry.stats and entry.stats.cargoHauled) or 0
		))
		local shipNet = (entry.stats and entry.stats.netProfit) or 0
		ui.text("Vessel Lifetime Net: ")
		ui.sameLine(0, 0)
		ui.textColored(shipNet >= 0 and colors.econProfit or colors.econLoss, Format.Money(shipNet, false))

		ui.nextColumn()

		ui.withFont(orbiteer.body, function()
			ui.textColored(colors.uiPrimaryLight, string.format("CARGO HOLD (%dt / %dt)", PlayerFleet.GetCargoUsed(entry), entry.cargoCap or 0))
		end)
		local hasCargo = false
		for cname, qty in pairs(entry.cargo or {}) do
			if qty > 0 then
				hasCargo = true
				local comm = Commodities[cname]
				ui.text(string.format("  • %s: %dt", comm and comm:GetName() or cname, qty))
			end
		end
		if not hasCargo then
			ui.textColored(colors.fontDim, "  (Empty)")
		else
			ui.spacing()
			local sellLabel = (entry.status == "DOCKED") and "Liquidate / Sell All Cargo to Market"
				or "Order Pilot to Fly to Station & Sell Cargo"
			if ui.button(sellLabel .. "##liquidate_cargo_btn", Vector2(-1, 0), ui.theme.buttonColors.selected) then
				local _, msg = PlayerFleet.OrderSellCargo(entry.uid)
				statusMsg = msg
			end
		end

		ui.spacing()
		ui.withFont(orbiteer.body, function()
			ui.textColored(colors.uiPrimaryLight, "RECENT FLEET OPERATIONS LOG")
		end)
		ui.child("##FleetLogMini", Vector2(-1, ui.rescaleUI(220, Vector2(1920, 1080))), nil, childFlags, function()
			local logs = PlayerFleet.GetLogs() or {}
			if #logs == 0 then
				ui.textColored(colors.fontDim, "No operations logged yet.")
			else
				for i = 1, math.min(20, #logs) do
					local item = logs[i]
					local isThisShip = (item.shipName == entry.shipName)
					ui.textColored(isThisShip and colors.uiPrimaryLight or colors.fontDim, "[" .. item.shipName .. "]")
					ui.sameLine()
					ui.textWrapped(item.message)
				end
			end
		end)

		ui.columns(1)
	end)
end

InfoView:registerView({
	id = "fleet",
	name = "Fleet Command",
	icon = icons.heavy_cargo_shuttle or icons.ship,
	showView = true,
	draw = function()
		local ships = PlayerFleet.GetShips() or {}
		if selectedUid and not PlayerFleet.GetShipByUid(selectedUid) then
			selectedUid = ships[1] and ships[1].uid or nil
		end

		ui.withFont(pionillium.body, function()
			drawFleetHeaderBar(ships)
			if statusMsg then
				ui.textColored(colors.econProfit, statusMsg)
			end
			ui.spacing()

			drawFleetRoster(ships)
			ui.sameLine(0, spacing.x)
			local selectedEntry = selectedUid and PlayerFleet.GetShipByUid(selectedUid) or nil
			drawCommandDeck(selectedEntry)
		end)
	end,
	refresh = function()
		statusMsg = nil
	end,
	debugReload = function()
		package.reimport()
	end
})

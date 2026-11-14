-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui          = require 'pigui'
local Game        = require 'Game'
local Lang        = require 'Lang'
local Format      = require 'Format'
local ShipDef     = require 'ShipDef'
local Commodities = require 'Commodities'
local StationView = require 'pigui.views.station-view'
local PlayerFleet = require 'modules.PlayerFleet.PlayerFleet'

local l = Lang.GetResource("ui-core")
local colors = ui.theme.colors
local icons = ui.theme.icons
local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local Vector2 = _G.Vector2

local childFlags = ui.ChildFlags { 'Borders' }
local spacing = ui.rescaleUI(Vector2(10, 8), Vector2(1920, 1080))
local listWidth = ui.rescaleUI(460, Vector2(1920, 1080))

local selectedUid = nil
local statusMsg = nil
local confirmSellUid = nil
local renameBuffer = ""
local renameUid = nil

local function setStatus(msg)
	statusMsg = msg
end

local function isDockedHere(entry, station)
	return station and entry.status == "DOCKED" and entry.locationPath == station.path
end

local function drawFlagshipBanner(station)
	local player = Game.player
	local def = ShipDef[player.shipId]
	ui.child("##HangarFlagshipHeader", Vector2(-1, ui.rescaleUI(68, Vector2(1920, 1080))), nil, childFlags, function()
		ui.withFont(orbiteer.heading, function()
			ui.textColored(colors.uiPrimaryLight, string.format("ACTIVE FLAGSHIP: %s [%s]", def and def.name or player.shipId, player.label or ""))
		end)
		ui.withFont(pionillium.body, function()
			ui.text(string.format("Docked at: %s   |   Hull: %.0f%%   |   Fuel: %.0f%%   |   Cargo: %dt / %dt   |   Crew: %d / %d",
				station and station.label or "Deep Space",
				player.hullPercent or 100,
				player.fuel or 100,
				player.usedCargo or 0,
				player.cargo_cap or (def and def.cargo or 0),
				player:CrewNumber(),
				def and def.maxCrew or 1
			))
		end)
	end)
end

local function drawFleetShipList(ships, station)
	ui.child("##HangarShipList", Vector2(listWidth, -1), nil, childFlags, function()
		ui.withFont(orbiteer.heading, function()
			ui.textColored(colors.uiPrimaryLight, string.format("OWNED FLEET (%d SHIPS)", #ships))
		end)
		ui.separator()
		ui.spacing()

		if #ships == 0 then
			ui.textWrapped("No secondary ships owned yet.\n\nVisit the Ship Market tab to 'Buy & Store Current' or 'Buy into Hangar' to begin building your fleet.")
			return
		end

		for _, entry in ipairs(ships) do
			if not selectedUid then
				selectedUid = entry.uid
			end

			local here = isDockedHere(entry, station)
			local isSelected = (selectedUid == entry.uid)
			local st = entry.status or "REMOTE"
			local badge = here and "[HERE]" or ("[" .. st .. "]")
			local badgeCol = here and colors.econProfit
				or ((st == "HYPERSPACE" or st == "SUPERCRUISE") and colors.hyperspaceInfo)
				or (entry.order ~= "IDLE" and colors.alertYellow or colors.fontDim)
			local def = ShipDef[entry.shipId]

			local cardLabel = string.format("%s  %s##hangar_%d", badge, entry.shipName or (def and def.name or entry.shipId), entry.uid)
			local btnStyle = isSelected and ui.theme.buttonColors.selected or ui.theme.buttonColors.card
			if ui.button(cardLabel, Vector2(-1, ui.rescaleUI(46, Vector2(1920, 1080))), btnStyle) then
				selectedUid = entry.uid
				confirmSellUid = nil
				renameUid = entry.uid
				renameBuffer = entry.shipName or ""
			end
			ui.textColored(badgeCol, string.format("  %s | %s | Hull %.0f%% | Capt: %s",
				def and def.name or entry.shipId,
				entry.locationName or "Unknown",
				entry.hullPercent or 100,
				entry.captain and entry.captain.name or "Uncrewed"
			))
			ui.spacing()
		end
	end)
end

local function drawCargoTransferPane(entry, station)
	local player = Game.player
	local playerCargoMgr = player:GetComponent('CargoManager')
	local pUsed = player.usedCargo or 0
	local pCap = player.cargo_cap or 0
	local fUsed = PlayerFleet.GetCargoUsed(entry)
	local fCap = entry.cargoCap or 0

	ui.withFont(orbiteer.body, function()
		ui.textColored(colors.uiPrimaryLight, string.format("CARGO TRANSFER   |   Flagship: %dt/%dt   <->   %s: %dt/%dt", pUsed, pCap, entry.shipName, fUsed, fCap))
	end)
	ui.separator()

	ui.columns(2, "##CargoXferCols", false)

	-- Left: Flagship -> Hangar Ship
	ui.textColored(colors.fontDim, "Flagship Hold -> Hangar Ship")
	local hasPlayerCargo = false
	for cname, qty in playerCargoMgr:Commodities() do
		if qty > 0 then
			hasPlayerCargo = true
			local comm = Commodities[cname]
			local display = comm and comm:GetName() or cname
			ui.text(string.format("%s: %dt", display, qty))
			ui.sameLine()
			if ui.button("1t >##p2f_1_" .. cname, Vector2(0, 0)) then
				local _, msg = PlayerFleet.TransferCargo(entry.uid, cname, 1, false)
				setStatus(msg)
			end
			ui.sameLine()
			if ui.button("10t >##p2f_10_" .. cname, Vector2(0, 0)) then
				local _, msg = PlayerFleet.TransferCargo(entry.uid, cname, 10, false)
				setStatus(msg)
			end
			ui.sameLine()
			if ui.button("All >##p2f_all_" .. cname, Vector2(0, 0)) then
				local _, msg = PlayerFleet.TransferCargo(entry.uid, cname, qty, false)
				setStatus(msg)
			end
		end
	end
	if not hasPlayerCargo then
		ui.textColored(colors.fontDim, "  (Flagship cargo hold empty)")
	end

	ui.nextColumn()

	-- Right: Hangar Ship -> Flagship
	ui.textColored(colors.fontDim, "Hangar Ship -> Flagship Hold")
	local hasFleetCargo = false
	for cname, qty in pairs(entry.cargo or {}) do
		if qty > 0 then
			hasFleetCargo = true
			local comm = Commodities[cname]
			local display = comm and comm:GetName() or cname
			if ui.button("< All##f2p_all_" .. cname, Vector2(0, 0)) then
				local _, msg = PlayerFleet.TransferCargo(entry.uid, cname, qty, true)
				setStatus(msg)
			end
			ui.sameLine()
			if ui.button("< 10t##f2p_10_" .. cname, Vector2(0, 0)) then
				local _, msg = PlayerFleet.TransferCargo(entry.uid, cname, 10, true)
				setStatus(msg)
			end
			ui.sameLine()
			if ui.button("< 1t##f2p_1_" .. cname, Vector2(0, 0)) then
				local _, msg = PlayerFleet.TransferCargo(entry.uid, cname, 1, true)
				setStatus(msg)
			end
			ui.sameLine()
			ui.text(string.format("%s: %dt", display, qty))
		end
	end
	if not hasFleetCargo then
		ui.textColored(colors.fontDim, "  (Hangar vessel cargo hold empty)")
	else
		ui.spacing()
		if ui.button("Liquidate / Sell All Cargo to Station Market##sell_hangar_cargo", Vector2(-1, 0), ui.theme.buttonColors.selected) then
			local _, msg = PlayerFleet.OrderSellCargo(entry.uid)
			setStatus(msg)
		end
	end

	ui.columns(1)
end

local function drawFleetShipDetail(entry, station)
	ui.child("##HangarShipDetails", Vector2(-1, -1), nil, childFlags, function()
		if not entry then
			ui.textColored(colors.fontDim, "Select a vessel from the fleet roster to inspect hangared telemetry, transfer cargo, or swap ship.")
			return
		end

		local here = isDockedHere(entry, station)
		local def = ShipDef[entry.shipId]

		ui.withFont(orbiteer.title, function()
			ui.text(entry.shipName or (def and def.name or entry.shipId))
		end)
		ui.textColored(colors.fontDim, string.format("%s   |   Callsign: %s   |   Location: %s",
			def and def.name or entry.shipId, entry.label or "----", entry.locationName or "Unknown"
		))

		if renameUid ~= entry.uid then
			renameUid = entry.uid
			renameBuffer = entry.shipName or ""
		end
		ui.text("Rename:")
		ui.sameLine()
		ui.pushItemWidth(ui.rescaleUI(220, Vector2(1920, 1080)))
		local newText, changed = ui.inputText("##RenameHangarShip", renameBuffer, {})
		if changed then renameBuffer = newText end
		ui.popItemWidth()
		ui.sameLine()
		if ui.button("Apply Name", Vector2(0, 0)) then
			if PlayerFleet.RenameShip(entry.uid, renameBuffer) then
				setStatus("Vessel renamed to " .. renameBuffer)
			end
		end

		ui.separator()
		ui.spacing()

		-- Telemetry specs grid
		local hyperRange = PlayerFleet.GetShipHyperspaceRange(entry)
		local combatScore = PlayerFleet.GetShipCombatScore(entry)
		local sellVal = PlayerFleet.ComputeShipValue(entry)
		local curOrder = entry.order or "IDLE"

		ui.columns(2, "##HangarSpecs", false)
		ui.text(string.format("Hull Integrity: %.0f%%", entry.hullPercent or 100))
		ui.text(string.format("Propellant Fuel: %.0f%%", entry.fuel or 100))
		ui.text(string.format("Cargo Hold: %dt / %dt", PlayerFleet.GetCargoUsed(entry), entry.cargoCap or 0))
		ui.text(string.format("Hyperdrive Range: %s", hyperRange > 0 and (hyperRange .. " ly") or "None"))
		ui.nextColumn()
		ui.text(string.format("Status: %s (%s)", entry.status or "DOCKED", curOrder))
		ui.text(string.format("Captain: %s", entry.captain and string.format("%s (Avg Skill %d)", entry.captain.name, PlayerFleet.GetCaptainSkillScore(entry.captain)) or "None Assigned"))
		ui.text(string.format("Combat Rating Score: %d   |   Completed Runs: %d", combatScore, (entry.stats and entry.stats.runsCompleted) or 0))
		ui.text(string.format("Est. Liquidation Value: %s   |   Net Earnings: %s",
			Format.Money(sellVal, false), Format.Money((entry.stats and entry.stats.netProfit) or 0, false)))
		ui.columns(1)

		ui.textColored(colors.alertYellow, "Order Status: " .. (entry.orderPhase or "Standby"))
		ui.spacing()
		ui.separator()
		ui.spacing()

		-- Action buttons
		if here then
			if ui.button("Board / Make Active Flagship", Vector2(0, 0), ui.theme.buttonColors.selected) then
				local ok, msg = PlayerFleet.SwapWithFlagship(entry.uid)
				setStatus(msg)
				if ok then selectedUid = nil end
			end
			ui.sameLine()
			if ui.button("Repair Hull", Vector2(0, 0)) then
				local _, msg = PlayerFleet.RepairShip(entry.uid)
				setStatus(msg)
			end
			ui.sameLine()
			if ui.button("Refuel 100%", Vector2(0, 0)) then
				local _, msg = PlayerFleet.RefuelShip(entry.uid)
				setStatus(msg)
			end
			if PlayerFleet.GetCargoUsed(entry) > 0 then
				ui.sameLine()
				if ui.button("Sell Cargo Hold", Vector2(0, 0)) then
					local _, msg = PlayerFleet.OrderSellCargo(entry.uid)
					setStatus(msg)
				end
			end
			ui.sameLine()
			if confirmSellUid == entry.uid then
				if ui.button("CONFIRM SELL (" .. Format.Money(sellVal, false) .. ")", Vector2(0, 0), ui.theme.buttonColors.danger) then
					local ok, msg = PlayerFleet.SellShip(entry.uid)
					setStatus(msg)
					if ok then
						confirmSellUid = nil
						selectedUid = nil
					end
				end
				ui.sameLine()
				if ui.button("Cancel", Vector2(0, 0)) then
					confirmSellUid = nil
				end
			else
				if ui.button("Sell Ship", Vector2(0, 0), ui.theme.buttonColors.danger) then
					confirmSellUid = entry.uid
				end
			end
		elseif station then
			if entry.order == "DOCK" then
				ui.textColored(colors.alertYellow, "Vessel is currently in transit to: " .. (entry.orderTargetName or "destination"))
			else
				local hasCap = entry.captain ~= nil
				local label = hasCap and "Recall / Ferry to This Station (Captain Free)" or "Recall / Ferry to This Station (Hire Courier)"
				if ui.button(label, Vector2(0, 0), ui.theme.buttonColors.selected) then
					local _, msg = PlayerFleet.OrderFerry(entry.uid, station.path)
					setStatus(msg)
				end
			end
		end

		ui.spacing()
		ui.separator()
		ui.spacing()

		-- Crew & Captain Quick Panel
		ui.withFont(orbiteer.body, function()
			ui.textColored(colors.uiPrimaryLight, string.format("CREW & CAPTAIN QUARTERS (%d / %d BERTHS)", #(entry.crew or {}), def and def.maxCrew or 1))
		end)
		if entry.status == "DOCKED" and not entry.captain then
			if ui.button("Hire Captain (1,500 Cr Signing Bonus)", Vector2(0, 0)) then
				local _, msg = PlayerFleet.HireInstantCaptain(entry.uid)
				setStatus(msg)
			end
		end

		if here then
			-- Allow transferring non-player crew between Flagship and this docked Hangar ship
			for member in Game.player:EachCrewMember() do
				if not member.player then
					ui.sameLine()
					if ui.button("Assign " .. member.name .. " -> Ship", Vector2(0, 0)) then
						local _, msg = PlayerFleet.AssignCrewFromPlayerShip(entry.uid, member, entry.captain == nil)
						setStatus(msg)
					end
				end
			end
		end

		for _, member in ipairs(entry.crew or {}) do
			local role = (member == entry.captain) and "[CAPTAIN]" or "[CREW]"
			ui.text(string.format("  %s %s — Pil:%d  Nav:%d  Eng:%d  Sen:%d",
				role, member.name, member.piloting or 15, member.navigation or 15, member.engineering or 15, member.sensors or 15))
			if here then
				if member ~= entry.captain then
					ui.sameLine()
					if ui.button("Promote Captain##prom_" .. member.name, Vector2(0, 0)) then
						PlayerFleet.SetCaptain(entry.uid, member)
						setStatus(member.name .. " promoted to Captain.")
					end
				end
				ui.sameLine()
				if ui.button("Move to Flagship##ret_" .. member.name, Vector2(0, 0)) then
					local _, msg = PlayerFleet.TransferCrewToPlayerShip(entry.uid, member)
					setStatus(msg)
				end
			end
		end

		if here then
			ui.spacing()
			ui.separator()
			ui.spacing()
			drawCargoTransferPane(entry, station)
		end
	end)
end

local function drawHangarView()
	local station = Game.player:GetDockedWith()
	local ships = PlayerFleet.GetShips() or {}

	if selectedUid and not PlayerFleet.GetShipByUid(selectedUid) then
		selectedUid = ships[1] and ships[1].uid or nil
	end

	ui.withFont(pionillium.body, function()
		drawFlagshipBanner(station)

		if statusMsg then
			ui.textColored(colors.econProfit, statusMsg)
		end

		ui.spacing()
		local selectedEntry = selectedUid and PlayerFleet.GetShipByUid(selectedUid) or nil
		drawFleetShipList(ships, station)
		ui.sameLine(0, spacing.x)
		drawFleetShipDetail(selectedEntry, station)
	end)
end

StationView:registerView({
	id = "hangarView",
	name = "Hangar & Fleet",
	icon = icons.heavy_cargo_shuttle or icons.ship,
	showView = true,
	draw = drawHangarView,
	refresh = function()
		confirmSellUid = nil
		statusMsg = nil
	end,
	debugReload = function()
		package.reimport()
	end
})

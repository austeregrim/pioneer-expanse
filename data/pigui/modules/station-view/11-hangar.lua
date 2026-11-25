-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui             = require 'pigui'
local Game           = require 'Game'
local Lang           = require 'Lang'
local Format         = require 'Format'
local ShipDef        = require 'ShipDef'
local Equipment      = require 'Equipment'
local Commodities    = require 'Commodities'
local StationView    = require 'pigui.views.station-view'
local PiImage        = require 'pigui.libs.image'
local EquipCard      = require 'pigui.libs.equip-card'
local PlayerState    = require 'PlayerState'
local PlayerFleet    = require 'modules.PlayerFleet.PlayerFleet'
local StationStorage = require 'modules.StationStorage.StationStorage'
local TaxAuthority   = require 'modules.Economy.TaxAuthority'

local l = Lang.GetResource("ui-core")
local colors = ui.theme.colors
local icons = ui.theme.icons
local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local Vector2 = _G.Vector2

local childFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders' }
local spacing = ui.rescaleUI(Vector2(10, 8), Vector2(1920, 1080))
local listWidth = ui.rescaleUI(460, Vector2(1920, 1080))
local commodityIconSize = Vector2(24.0, 20.0)

local VaultEquipCard = EquipCard.New()
VaultEquipCard.tooltipStats = false

local vaultCommIcons = {}

local activeViewMode = "FLEET"      -- "FLEET" | "VAULT"
local activeHangarXfer = "CARGO"    -- "CARGO" | "MODULES"
local activeVaultTab = "MODULES"    -- "MODULES" | "CARGO"
local selectedUid = nil
local selectedVaultModuleUid = nil
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

local function getSortedInstalledModules(ship)
	local list = {}
	local equipSet = ship and ship:GetComponent('EquipSet')
	if not equipSet or not equipSet.installed then return list end
	for key, equip in pairs(equipSet.installed) do
		table.insert(list, {
			key = key,
			slotLabel = (type(key) == "string") and key or "Internal",
			equip = equip,
			name = equip:GetName() or equip.id,
			integPct = math.floor(((rawget(equip, "integrity") or 1.0) * 100) + 0.5),
		})
	end
	table.sort(list, function(a, b)
		if a.slotLabel ~= b.slotLabel then return a.slotLabel < b.slotLabel end
		return a.name < b.name
	end)
	return list
end

local function drawFlagshipBanner(station)
	local player = Game.player
	local def = ShipDef[player.shipId]
	local hullName = def and def.name or player.shipId
	local reg = player.label or ""
	local defaultName = (reg ~= "") and string.format("%s [%s]", hullName, reg) or hullName
	local customName = (player.shipName and player.shipName ~= "" and player.shipName ~= defaultName) and player.shipName or nil
	local bannerTitle = customName
		and string.format("ACTIVE FLAGSHIP: %s — %s [%s]", customName, hullName, reg)
		or string.format("ACTIVE FLAGSHIP: %s [%s]", hullName, reg)
	ui.child("##HangarFlagshipHeader", Vector2(-1, ui.rescaleUI(68, Vector2(1920, 1080))), nil, childFlags, function()
		ui.withFont(orbiteer.heading, function()
			ui.textColored(colors.uiPrimaryLight, bannerTitle)
			if statusMsg then
				ui.sameLine(0, ui.rescaleUI(24, Vector2(1920, 1080)))
				ui.withFont(pionillium.body, function()
					ui.textColored(colors.econProfit, "• " .. statusMsg)
				end)
			end
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

local function drawFleetShipList(ships, station, customListWidth)
	ui.child("##HangarShipList", Vector2(customListWidth or listWidth, -1), nil, childFlags, function()
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

local function drawModuleTransferPane(entry, station)
	local player = Game.player
	local pMods = getSortedInstalledModules(player)
	local fMods = entry.equip or {}

	ui.withFont(orbiteer.body, function()
		ui.textColored(colors.uiPrimaryLight, string.format("MODULE TRANSFER   |   Flagship (%d)   <->   %s (%d)", #pMods, entry.shipName, #fMods))
	end)
	ui.separator()

	ui.columns(2, "##ModuleXferCols", false)

	-- Left: Flagship -> Hangar Ship
	ui.textColored(colors.fontDim, "Flagship Installed -> Hangar Ship")
	if #pMods == 0 then
		ui.textColored(colors.fontDim, "  (No modules installed)")
	else
		for i, item in ipairs(pMods) do
			local okRem, remReason = StationStorage.CanRemoveEquipmentFromShip(player, item.equip)
			ui.text(string.format("%s (%d%%) [%s]", item.name, item.integPct, item.slotLabel))
			ui.sameLine()
			if okRem then
				if ui.button("Transfer >##p2f_m_" .. tostring(i), Vector2(0, 0)) then
					local _, msg = PlayerFleet.TransferModule(entry.uid, item.equip, false)
					setStatus(msg)
				end
			else
				ui.button("Locked##p2f_m_l_" .. tostring(i), Vector2(0, 0), ui.theme.buttonColors.disabled)
				ui.setItemTooltip(remReason or "Module cannot be removed.")
			end
		end
	end

	ui.nextColumn()

	-- Right: Hangar Ship -> Flagship
	ui.textColored(colors.fontDim, "Hangar Ship Installed -> Flagship")
	if #fMods == 0 then
		ui.textColored(colors.fontDim, "  (No modules installed on hangar vessel)")
	else
		for idx, rec in ipairs(fMods) do
			local proto = Equipment.Get(rec.id)
			local modName = (proto and proto.name) or rec.id
			local integPct = math.floor(((rec.integrity or 1.0) * 100) + 0.5)
			local okRem, remReason = PlayerFleet.CanRemoveModuleFromEntry(entry, idx)
			local okFit, fitReason = false, nil
			if okRem then
				okFit, fitReason = StationStorage.CanInstallRecordOnShip(player, rec)
			end
			if okRem and okFit then
				if ui.button("< Install##f2p_m_" .. tostring(idx), Vector2(0, 0)) then
					local _, msg = PlayerFleet.TransferModule(entry.uid, idx, true)
					setStatus(msg)
				end
			else
				ui.button("Locked##f2p_m_l_" .. tostring(idx), Vector2(0, 0), ui.theme.buttonColors.disabled)
				ui.setItemTooltip((not okRem and remReason) or fitReason or "Incompatible with Flagship.")
			end
			ui.sameLine()
			ui.text(string.format("%s (%d%%) [%s]", modName, integPct, rec.slotId or "Internal"))
		end
	end

	ui.columns(1)
end

local function sanitizeShipName(raw)
	if not raw then return nil end
	local cleaned = tostring(raw):gsub("[%c]", "")
	cleaned = cleaned:match("^%s*(.-)%s*$")
	if not cleaned or cleaned == "" then return nil end
	if #cleaned > 48 then
		cleaned = cleaned:sub(1, 48):match("^%s*(.-)%s*$")
	end
	return cleaned
end

local function drawFleetShipDetail(entry, station)
	ui.child("##HangarShipDetails", Vector2(-1, -1), nil, childFlags, function()
		if not entry then
			ui.textColored(colors.fontDim, "Select a vessel from the fleet roster to inspect hangared telemetry, transfer cargo/modules, or swap ship.")
			return
		end

		local here = isDockedHere(entry, station)
		local def = ShipDef[entry.shipId]

		ui.withFont(orbiteer.title, function()
			ui.text(entry.shipName or (def and def.name or entry.shipId))
			ui.sameLine()
			local btnSz = Vector2(ui.getTextLineHeight())
			if ui.iconButton("##editShipNameHangar", icons.pencil, "Rename Vessel", nil, btnSz) then
				renameUid = entry.uid
				renameBuffer = entry.shipName or ""
				ui.openPopup("rename_ship_popup_hangar")
			end
		end)

		ui.popup("rename_ship_popup_hangar", function()
			ui.text("Rename Vessel:")
			ui.spacing()
			ui.pushItemWidth(ui.rescaleUI(260, Vector2(1920, 1080)))
			local newText, entered = ui.inputText("##RenameHangarShipInput", renameBuffer, "Enter vessel name...", {"EnterReturnsTrue"})
			ui.popItemWidth()
			renameBuffer = newText
			ui.spacing()
			if ui.button("Save", Vector2(0, 0)) or entered then
				local sanitized = sanitizeShipName(renameBuffer)
				if sanitized then
					if PlayerFleet.RenameShip(entry.uid, sanitized) then
						setStatus("Vessel renamed to " .. sanitized)
					end
				end
				ui.closeCurrentPopup()
			end
			ui.sameLine()
			if ui.button("Cancel", Vector2(0, 0)) then
				ui.closeCurrentPopup()
			end
		end)

		ui.textColored(colors.fontDim, string.format("%s   |   Callsign: %s   |   Location: %s",
			def and def.name or entry.shipId, entry.label or "----", entry.locationName or "Unknown"
		))

		ui.separator()
		ui.spacing()

		-- Telemetry specs grid
		local hyperRange = PlayerFleet.GetShipHyperspaceRange(entry)
		local combatScore = PlayerFleet.GetShipCombatScore(entry)
		local sellVal = PlayerFleet.ComputeShipValue(entry)
		local curOrder = entry.order or "IDLE"
		local minEquipInteg, below80Count, _, repairCostAll = PlayerFleet.GetLowestEquipmentIntegrity(entry)
		local equipPct = math.floor((minEquipInteg or 1.0) * 100 + 0.5)

		ui.columns(2, "##HangarSpecs", false)
		ui.text(string.format("Hull Integrity: %.0f%%", entry.hullPercent or 100))
		local eqCol = (equipPct < 40 and colors.alertRed) or (equipPct < 80 and colors.alertYellow) or colors.font
		ui.textColored(eqCol, string.format("Components Integrity: %d%%%s", equipPct, (below80Count > 0) and (" (" .. below80Count .. " <80%)") or ""))
		ui.text(string.format("Propellant Fuel: %.0f%%", entry.fuel or 100))
		ui.text(string.format("Cargo Hold: %dt / %dt", PlayerFleet.GetCargoUsed(entry), entry.cargoCap or 0))
		ui.text(string.format("Hyperdrive Range: %s", hyperRange > 0 and (hyperRange .. " ly") or "None"))
		ui.nextColumn()
		ui.text(string.format("Status: %s (%s)", entry.status or "DOCKED", curOrder))
		ui.text(string.format("Captain: %s", entry.captain and string.format("%s (Avg Skill %d)", entry.captain.name, PlayerFleet.GetCaptainSkillScore(entry.captain)) or "None Assigned"))
		ui.text(string.format("Combat Rating Score: %d   |   Completed Runs: %d", combatScore, (entry.stats and entry.stats.runsCompleted) or 0))
		ui.text(string.format("Est. Liquidation Value: %s   |   Net Earnings: %s",
			Format.Money(sellVal, false), Format.Money((entry.stats and entry.stats.netProfit) or 0, false)))
		ui.text(string.format("Lifetime Maintenance: %s   |   Tax Accrued: %s",
			Format.Money((entry.stats and entry.stats.maintenancePaid) or 0, false),
			Format.Money((entry.stats and entry.stats.taxesGenerated) or 0, false)))
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
			if (repairCostAll or 0) > 0 then
				ui.sameLine()
				if ui.button("Service Equip (" .. Format.Money(repairCostAll, false) .. ")", Vector2(0, 0)) then
					local _, msg = PlayerFleet.ServiceEquipment(entry.uid)
					setStatus(msg)
				end
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
			if ui.button("Hire Captain (1,500 Cr Signing Bonus + Weekly Wage)", Vector2(0, 0)) then
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
			ui.text(string.format("  %s %s — %s/wk | Ops:%d | Pil:%d  Nav:%d  Eng:%d  Sen:%d",
				role, member.name, Format.Money(member.fleetWage or 0, false), member.completedOps or 0,
				member.piloting or 15, member.navigation or 15, member.engineering or 15, member.sensors or 15))
			if (member.fleetOwed or 0) > 0 then
				ui.sameLine()
				ui.textColored(colors.alertRed, string.format("Owed: %s", Format.Money(member.fleetOwed, false)))
				if PlayerState.GetMoney() > 0 then
					ui.sameLine()
					if ui.button("Pay Arrears##hangar_arr_" .. member.name, Vector2(0, 0)) then
						local _, msg = PlayerFleet.PayCrewArrears(member)
						setStatus(msg)
					end
				end
			end
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
			if ui.button("Cargo Transfer##xfer_mode_cargo", Vector2(0, 0), activeHangarXfer == "CARGO" and ui.theme.buttonColors.selected or ui.theme.buttonColors.card) then
				activeHangarXfer = "CARGO"
			end
			ui.sameLine()
			if ui.button("Module Transfer##xfer_mode_mod", Vector2(0, 0), activeHangarXfer == "MODULES" and ui.theme.buttonColors.selected or ui.theme.buttonColors.card) then
				activeHangarXfer = "MODULES"
			end
			ui.spacing()

			if activeHangarXfer == "MODULES" then
				drawModuleTransferPane(entry, station)
			else
				drawCargoTransferPane(entry, station)
			end
		end
	end)
end

-- Styled like Equipment Market (EquipCard list + Detail & Sell pane)
local function drawVaultModulesTab(station, vault)
	local vMods = (vault and vault.modules) or {}
	local _, maxMods = StationStorage.GetLimits()

	if #vMods == 0 then
		selectedVaultModuleUid = nil
		ui.textColored(colors.fontDim, "No ship modules are currently stored in this station vault.\n\nVisit the Equipment Market to store modules from your Flagship or install stored modules.")
		return
	end

	local selectedCard = nil
	local cards = {}
	for _, rec in ipairs(vMods) do
		local inst = StationStorage.InstantiateRecordForConfig(rec, nil)
		if inst then
			local data = EquipCard.getDataForEquip(inst)
			local sellPrice = StationStorage.GetModuleResellPrice(station, rec)
			local integPct = math.floor(((rec.integrity or 1.0) * 100) + 0.5)
			data.uid = rec.uid
			data.rec = rec
			data.sellPrice = sellPrice
			data.integPct = integPct
			data[#data] = { nil, Format.Money(sellPrice, false) }
			table.insert(cards, data)
			if selectedVaultModuleUid == rec.uid then
				selectedCard = data
			end
		end
	end
	if not selectedCard and #cards > 0 then
		selectedCard = cards[1]
		selectedVaultModuleUid = selectedCard.uid
	end

	local region = ui.getContentRegion()
	local leftW = math.floor(region.x * 0.48)

	ui.child("##VaultModulesListPane", Vector2(leftW, -1), function()
		ui.textColored(colors.fontDim, string.format("Stored Modules (%d / %d) — Select a module to inspect or sell:", #vMods, maxMods))
		ui.spacing()
		for _, data in ipairs(cards) do
			ui.withID("vmod_" .. tostring(data.uid), function()
				local clicked = VaultEquipCard:draw(data, data.uid == selectedVaultModuleUid)
				if clicked then
					selectedVaultModuleUid = data.uid
					selectedCard = data
				end
			end)
		end
	end)

	ui.sameLine(0, spacing.x * 2)

	ui.child("##VaultModuleDetailPane", Vector2(-1, -1), nil, childFlags, function()
		if not selectedCard or not selectedCard.equip then
			ui.textColored(colors.fontDim, "Select a stored module to inspect details or sell to the station.")
			return
		end

		local equip = selectedCard.equip
		ui.withFont(orbiteer.heading, function()
			ui.textColored(colors.uiPrimaryLight, selectedCard.name or equip.id)
		end)
		ui.textColored(colors.fontDim, string.format("Condition: %d%%   |   Resale Value: %s",
			selectedCard.integPct, Format.Money(selectedCard.sellPrice, false)))
		ui.separator()
		ui.spacing()

		ui.textWrapped(equip:GetDescription())
		local flavour = equip:GetFlavourText()
		if flavour and flavour ~= "" then
			ui.spacing()
			ui.textWrapped(flavour)
		end

		if selectedCard.stats and #selectedCard.stats > 0 then
			ui.spacing()
			ui.separator()
			ui.spacing()
			EquipCard.drawEquipStats(selectedCard)
		end

		ui.spacing()
		ui.separator()
		ui.spacing()
		if ui.button(string.format("SELL FROM STORAGE (%s)##vault_sell_mod_%d", Format.Money(selectedCard.sellPrice, false), selectedCard.uid), Vector2(-1, ui.rescaleUI(38, Vector2(1920, 1080))), ui.theme.buttonColors.default) then
			local ok, msg = StationStorage.SellModuleFromVault(station, selectedCard.uid)
			setStatus(msg)
			if ok then
				selectedVaultModuleUid = nil
			end
		end
		ui.spacing()
		ui.textColored(colors.fontDim, "To install onto your Flagship or store equipped modules, use the Equipment Market.")
	end)
end

-- Styled like Commodity Market (Icon | Commodity | Stored | Sell Price | Total Value | Sell Action)
local function drawVaultCargoTab(station, vault)
	local rows = {}
	for cname, qty in pairs((vault and vault.cargo) or {}) do
		if qty > 0 then
			local comm = Commodities[cname]
			local display = comm and comm:GetProperName() or cname
			local unitPrice = StationStorage.GetCommoditySellPrice(station, cname)
			table.insert(rows, {
				cname = cname,
				comm = comm,
				display = display,
				qty = qty,
				unitPrice = unitPrice,
				totalVal = unitPrice * qty,
			})
		end
	end
	table.sort(rows, function(a, b) return a.display < b.display end)

	if #rows == 0 then
		ui.textColored(colors.fontDim, "No commodities are currently stored in this station vault.\n\nVisit the Commodity Market to store cargo from your Flagship hold or withdraw stored goods.")
		return
	end

	ui.textColored(colors.fontDim, "Stored commodities can be liquidated directly here or transferred to/from your ship in the Commodity Market.")
	ui.spacing()

	if ui.beginTable("##VaultCommoditiesTable", 6, { "BordersInnerH", "RowBg", "ScrollY" }) then
		ui.tableSetupColumn("##v_icon", { "WidthFixed" }, commodityIconSize.x + 8)
		ui.tableSetupColumn(l.COMMODITY or "Commodity", { "WidthStretch" })
		ui.tableSetupColumn("Stored", { "WidthFixed" }, ui.rescaleUI(90, Vector2(1920, 1080)))
		ui.tableSetupColumn(l.SELL_PRICE or "Sell Price", { "WidthFixed" }, ui.rescaleUI(110, Vector2(1920, 1080)))
		ui.tableSetupColumn("Total Value", { "WidthFixed" }, ui.rescaleUI(120, Vector2(1920, 1080)))
		ui.tableSetupColumn("Action", { "WidthFixed" }, ui.rescaleUI(240, Vector2(1920, 1080)))
		ui.tableHeadersRow()

		for _, r in ipairs(rows) do
			ui.tableNextRow()

			ui.tableSetColumnIndex(0)
			if r.comm and r.comm.icon_name then
				if vaultCommIcons[r.comm.icon_name] == nil then
					vaultCommIcons[r.comm.icon_name] = PiImage.New("icons/goods/" .. r.comm.icon_name .. ".png")
				end
				vaultCommIcons[r.comm.icon_name]:Draw(commodityIconSize)
			end

			ui.tableSetColumnIndex(1)
			ui.text(r.display)

			ui.tableSetColumnIndex(2)
			ui.text(string.format("%dt", r.qty))

			ui.tableSetColumnIndex(3)
			ui.text(Format.Money(r.unitPrice, false))

			ui.tableSetColumnIndex(4)
			ui.textColored(colors.econProfit, Format.Money(r.totalVal, false))

			ui.tableSetColumnIndex(5)
			if r.qty > 10 then
				if ui.button("Sell 10t##vs10_" .. r.cname, Vector2(0, 0)) then
					local _, msg = StationStorage.SellCargoFromVault(station, r.cname, 10)
					setStatus(msg)
				end
				ui.sameLine()
			end
			if ui.button(string.format("Sell All (%dt)##vsall_%s", r.qty, r.cname), Vector2(0, 0), ui.theme.buttonColors.default) then
				local _, msg = StationStorage.SellCargoFromVault(station, r.cname, r.qty)
				setStatus(msg)
			end
		end

		ui.endTable()
	end
end

local function drawResidentVaultView(station)
	local resInfo = TaxAuthority.GetResidencyInfo()
	local depositAllowed = StationStorage.IsDepositAllowed(station)
	local localVault = station and StationStorage.GetVault(station)
	local localHasItems = localVault and not StationStorage.IsVaultEmpty(localVault)
	local maxCargo, maxMods = StationStorage.GetLimits()
	local usedCargo = StationStorage.GetVaultCargoUsed(localVault)
	local usedMods = StationStorage.GetVaultModuleCount(localVault)
	local allVaults = StationStorage.GetAllNonEmptyVaults()
	local localKey = StationStorage.GetStationKey(station)
	local remoteVaults = {}
	for _, v in ipairs(allVaults) do
		if v.stationKey ~= localKey then
			table.insert(remoteVaults, v)
		end
	end

	-- Residency / Vault Header Card
	ui.child("##VaultHeaderCard", Vector2(-1, ui.rescaleUI(132, Vector2(1920, 1080))), nil, childFlags, function()
		if depositAllowed then
			ui.withFont(orbiteer.heading, function()
				ui.textColored(colors.econProfit, string.format("ACTIVE RESIDENT STORAGE VAULT — %s", station.label))
			end)
			ui.text(string.format("Cargo Vault: %dt / %dt   |   Module Locker: %d / %d   |   Civil Residency Perk (Free)", usedCargo, maxCargo, usedMods, maxMods))
			ui.textColored(colors.fontDim, "Store or install modules from the Equipment Market, transfer cargo from the Commodity Market, or liquidate stored items below.")
		elseif localHasItems then
			ui.withFont(orbiteer.heading, function()
				ui.textColored(colors.alertYellow, string.format("FORMER RESIDENCY VAULT (WITHDRAW / SELL ONLY) — %s", station.label))
			end)
			ui.text(string.format("Stored Here: %dt Cargo, %d Modules   |   Registered Home: %s (%s)",
				usedCargo, usedMods, resInfo.isResident and resInfo.homeStationName or "None", resInfo.isResident and resInfo.homeSystemName or "-"))
			ui.textColored(colors.fontDim, "Deposits are locked because this is no longer your registered home station. Install/withdraw via Markets, sell below, or courier from your home port.")
		else
			ui.withFont(orbiteer.heading, function()
				ui.textColored(colors.fontDim, "RESIDENT STATION STORAGE VAULT (LOCKED)")
			end)
			if resInfo.isResident then
				ui.textWrapped(string.format("Your registered Civil Residency is at %s (%s). Dock at your home starport to store up to %dt cargo and %d modules, or register residency here in the Lobby once eligible.",
					resInfo.homeStationName, resInfo.homeSystemName, maxCargo, maxMods))
			else
				ui.textWrapped(string.format("Station Storage Vaults (%dt cargo + %d modules) are an exclusive perk of Starport Civil Residency. Register residency in the Station Lobby to unlock your home vault.",
					maxCargo, maxMods))
			end
		end

		ui.spacing()
		if depositAllowed or localHasItems then
			if ui.button("Equipment Market (Store / Install Modules)##vault_to_equip", Vector2(0, 0), ui.theme.buttonColors.dark) then
				StationView:SwitchTo("equipmentMarketView")
			end
			ui.sameLine()
			if ui.button("Commodity Market (Transfer Cargo)##vault_to_comm", Vector2(0, 0), ui.theme.buttonColors.dark) then
				StationView:SwitchTo("commodityMarket")
			end
		else
			if ui.button("Open Station Lobby to Manage Residency##vault_to_lobby", Vector2(0, 0), ui.theme.buttonColors.default) then
				StationView:SwitchTo("lobby")
			end
		end
	end)

	ui.spacing()

	-- Local Vault Viewer & Direct Sale Pane
	if depositAllowed or localHasItems then
		local localH = (#remoteVaults > 0) and ui.rescaleUI(360, Vector2(1920, 1080)) or -1
		ui.child("##LocalVaultPane", Vector2(-1, localH), nil, childFlags, function()
			if ui.button("Stored Modules (" .. usedMods .. "/" .. maxMods .. ")##vault_tab_mod", Vector2(0, 0), activeVaultTab == "MODULES" and ui.theme.buttonColors.selected or ui.theme.buttonColors.card) then
				activeVaultTab = "MODULES"
			end
			ui.sameLine()
			if ui.button("Stored Commodities (" .. usedCargo .. "t/" .. maxCargo .. "t)##vault_tab_cargo", Vector2(0, 0), activeVaultTab == "CARGO" and ui.theme.buttonColors.selected or ui.theme.buttonColors.card) then
				activeVaultTab = "CARGO"
			end
			ui.separator()
			ui.spacing()

			if activeVaultTab == "MODULES" then
				drawVaultModulesTab(station, localVault)
			else
				drawVaultCargoTab(station, localVault)
			end
		end)
		ui.spacing()
	end

	-- Remote / Former Residency Vaults
	if #remoteVaults > 0 then
		ui.child("##RemoteVaultsPane", Vector2(-1, -1), nil, childFlags, function()
			ui.withFont(orbiteer.heading, function()
				ui.textColored(colors.uiPrimaryLight, string.format("REMOTE / FORMER RESIDENCY VAULTS (%d)", #remoteVaults))
			end)
			ui.separator()
			ui.spacing()
			for _, rv in ipairs(remoteVaults) do
				local rCargo = StationStorage.GetVaultCargoUsed(rv)
				local rMods = StationStorage.GetVaultModuleCount(rv)
				ui.text(string.format("%s (%s) — %dt Cargo, %d Modules",
					rv.stationName or "Starport", rv.systemName or "System", rCargo, rMods))
				if depositAllowed then
					local fee = StationStorage.EstimateCourierFee(rv.stationKey, station)
					ui.sameLine()
					if ui.button(string.format("Courier All to Home Vault (%s)##courier_%s", Format.Money(fee, false), rv.stationKey), Vector2(0, 0), ui.theme.buttonColors.selected) then
						local _, msg = StationStorage.CourierTransferVault(rv.stationKey, station)
						setStatus(msg)
					end
				end
			end
		end)
	end
end

local function drawHangarView()
	local station = Game.player:GetDockedWith()
	local ships = PlayerFleet.GetShips() or {}

	if selectedUid and not PlayerFleet.GetShipByUid(selectedUid) then
		selectedUid = ships[1] and ships[1].uid or nil
	end

	ui.withFont(pionillium.body, function()
		drawFlagshipBanner(station)
		ui.spacing()

		local depositAllowed = StationStorage.IsDepositAllowed(station)
		local localVault = station and StationStorage.GetVault(station)
		local vaultBadge = depositAllowed and " [HOME]"
			or ((localVault and not StationStorage.IsVaultEmpty(localVault)) and " [WITHDRAW]" or "")

		if ui.button("FLEET HANGAR (" .. #ships .. ")##mode_fleet", Vector2(0, 0), activeViewMode == "FLEET" and ui.theme.buttonColors.selected or ui.theme.buttonColors.card) then
			activeViewMode = "FLEET"
		end
		ui.sameLine()
		if ui.button("RESIDENT STORAGE VAULT" .. vaultBadge .. "##mode_vault", Vector2(0, 0), activeViewMode == "VAULT" and ui.theme.buttonColors.selected or ui.theme.buttonColors.card) then
			activeViewMode = "VAULT"
		end
		ui.spacing()

		if activeViewMode == "VAULT" then
			drawResidentVaultView(station)
		else
			local region = ui.getContentRegion()
			local listW = math.floor(region.x * 0.45)
			local selectedEntry = selectedUid and PlayerFleet.GetShipByUid(selectedUid) or nil
			drawFleetShipList(ships, station, listW)
			ui.sameLine(0, spacing.x)
			drawFleetShipDetail(selectedEntry, station)
		end
	end)
end

StationView:registerView({
	id = "hangarView",
	name = "Hangar & Fleet",
	icon = icons.heavy_cargo_shuttle or icons.ship,
	securityMode = "encryption",
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

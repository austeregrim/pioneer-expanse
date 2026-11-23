-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui = require 'pigui'
local StationView = require 'pigui.views.station-view'
local ShipDef = require "ShipDef"
local Game = require "Game"
local Engine = require 'Engine'
local Rand = require "Rand"
local PiGuiFace = require 'pigui.libs.face'
local Format = require "Format"
local Character = require "Character"
local ModalWindow = require 'pigui.libs.modal-win'
local EncryptedText = require 'pigui.libs.encrypted-text'
local ModelSpinner = require 'PiGui.Modules.ModelSpinner'
local ModelSkin = require 'SceneGraph.ModelSkin'
local Commodities = require 'Commodities'
local PiImage = require 'pigui.libs.image'
local Lang = require 'Lang'
local PlayerState = require 'PlayerState'
local l = Lang.GetResource("ui-core")

local rescaleVector = ui.rescaleUI(Vector2(1, 1), Vector2(1920, 1080), true)

local commsChildFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders' }

local colors = ui.theme.colors
local icons = ui.theme.icons

local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local gaugeSpacing = ui.getTextLineHeight() * 0.8

local face = nil
local stationSeed = false
local damageToRepair = nil
local repair_cost = 0

local hyperdrive ---@type Equipment.HyperdriveType?
local hyperdrive_fuel
local hydrogenIcon = PiImage.New("icons/goods/Hydrogen.png")
local hyperdriveIcon = PiImage.New("icons/goods/Hydrogen.png")

local Color = _G.Color
local Vector2 = _G.Vector2
local NUM_WELCOME_MESSAGES = 5
local modelSpinner = ModelSpinner()
local previewPattern
local previewSkin
local previewColors
local changesMade = false
local price = 0.0
local textColorDefault = Color(255, 255, 255)
local textColorWarning = Color(255, 255, 0)

local activeTab = 0
local repairsCommsText = EncryptedText.New("Starport engineering drydock uplink active. Diagnostic telemetry online. Structural hull reinforcement, pressure seal maintenance, and precision shipyard outfitting ready for deployment.", 0.50)

local widgetSizes = ui.rescaleUI({
	itemSpacing = Vector2(4, 7),
	faceSize = Vector2(460, 440),
	buttonSize = Vector2(90, 0),
	buttonSizeBase = Vector2(64, 40),
	verticalDummy = Vector2(0, 36),
	gaugeWidth = 520,
}, Vector2(1920, 1080))

widgetSizes.itemSpacing = Vector2(math.ceil(widgetSizes.itemSpacing.x), math.ceil(widgetSizes.itemSpacing.y))
widgetSizes.buttonFullRefuelSize = Vector2(widgetSizes.buttonSizeBase.x * 2 + widgetSizes.itemSpacing.x, widgetSizes.buttonSizeBase.y)
widgetSizes.iconSize = Vector2(0, widgetSizes.buttonSizeBase.y)

local popupMsg = l.YOU_DONT_HAVE_ENOUGH_MONEY_FOR_THAT_OPTION
local popup = ModalWindow.New('ChiefMechanicPopup', function(self)
	ui.text(popupMsg)
	ui.dummy(Vector2((ui.getContentRegion().x - 100*rescaleVector.x) / 2, 0))
	ui.sameLine()
	if ui.button(l.OK, Vector2(100*rescaleVector.x, 0)) then
		self:close()
	end
end)

local function recordTaxOperatingExpense(amount, category)
	if not amount or amount <= 0 then return end
	local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')
	if okTax and TaxAuthority and TaxAuthority.RecordOperatingExpense then
		TaxAuthority.RecordOperatingExpense(amount, category, "Flagship")
	end
end

local tryRepair = function (damage, price)
	if PlayerState.GetMoney() >= price then
		PlayerState.AddMoney(-price)
		recordTaxOperatingExpense(price, "MAINTENANCE")
		Game.player:SetHullPercent(Game.player:GetHullPercent() + damage)
		ui.playSfx("Repairing_Ship")

		local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
		if okFlightLog and FlightLog and FlightLog.RecordTransaction then
			FlightLog.RecordTransaction({
				category = "MAINTENANCE",
				title = string.format("Hull Restoration (%s)", Format.Money(-price)),
				amount = -price,
				details = {
					{ "Service Type", "Structural Hull Repair" },
					{ "Integrity Restored", string.format("+%.1f%%", damage) },
					{ "Service Fee", Format.Money(price) },
				},
				note = string.format("Restored %.1f%% vessel hull integrity at starport repair yard.", damage)
			})
		end
	else
		popupMsg = l.YOU_DONT_HAVE_ENOUGH_MONEY_FOR_THAT_OPTION
		popup:open()
	end
end

local refuelInternalTank = function (delta)
	local station = Game.player:GetDockedWith()
	if not station then return end
	local stock = station:GetCommodityStock(Commodities.hydrogen)
	local price = station:GetCommodityPrice(Commodities.hydrogen)

	if delta > 0 then
		if stock == 0 then
			popupMsg = l.ITEM_IS_OUT_OF_STOCK
			popup:open()
			return
		end

		delta = math.clamp(delta, 0, 100 - Game.player.fuel)
	else
		delta = math.clamp(delta, -Game.player.fuel, 0)
	end

	local shipDef = ShipDef[Game.player.shipId]
	local fuel = Game.player.fuel + delta
	local mass = shipDef.fuelTankMass / 100 * delta
	local total = price * mass

	if total > PlayerState.GetMoney() then
		total = PlayerState.GetMoney()
		mass = total / price
		fuel = Game.player.fuel + mass * 100 / shipDef.fuelTankMass
	end

	if stock < mass then
		mass = stock
		total = price * mass
		fuel = Game.player.fuel + mass * 100 / shipDef.fuelTankMass
	end

	PlayerState.AddMoney(-total)
	local commodityChangeAmount = mass < 0 and math.floor(mass) or math.ceil(mass)
	station:AddCommodityStock(Commodities.hydrogen, -commodityChangeAmount)
	Game.player:SetFuelPercent(fuel)

	if total > 0 then
		recordTaxOperatingExpense(total, "FUEL")
		local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
		if okFlightLog and FlightLog and FlightLog.RecordTransaction then
			FlightLog.RecordTransaction({
				category = "MAINTENANCE",
				title = string.format("Thruster Refueling (%s)", Format.Money(-total)),
				amount = -total,
				details = {
					{ "Propellant Fuel", "Liquid Hydrogen (H2)" },
					{ "Quantity Refueled", string.format("%.2f tons", mass) },
					{ "Unit Price", Format.Money(price) },
					{ "Total Cost", Format.Money(total) },
				},
				note = string.format("Replenished %.2f tons liquid hydrogen thruster propellant.", mass)
			})
		end
	end
end

local refuelHyperdrive = function (mass)
	if not hyperdrive then return end
	local station = Game.player:GetDockedWith()
	if not station then return end
	local stock = station:GetCommodityStock(hyperdrive_fuel)
	local price = station:GetCommodityPrice(hyperdrive_fuel)

	if mass > 0 then
		if stock == 0 then
			popupMsg = l.ITEM_IS_OUT_OF_STOCK
			popup:open()
			return
		end
	end

	mass = math.clamp(mass, -hyperdrive.storedFuel, hyperdrive:GetMaxFuel() - hyperdrive.storedFuel)

	-- Can't buy any more than the station has in stock or we have money for
	mass = math.min(mass, math.min(stock, PlayerState.GetMoney() / price))
	local total = price * mass
	PlayerState.AddMoney(-total)

	hyperdrive:SetFuel(Game.player, hyperdrive.storedFuel + mass)
	station:AddCommodityStock(hyperdrive_fuel, -math.round(mass))

	if total > 0 then
		recordTaxOperatingExpense(total, "FUEL")
		local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
		if okFlightLog and FlightLog and FlightLog.RecordTransaction then
			FlightLog.RecordTransaction({
				category = "MAINTENANCE",
				title = string.format("Hyperspace Refueling (%s)", Format.Money(-total)),
				amount = -total,
				details = {
					{ "Hyperdrive Fuel", "Enriched Hyperfuel" },
					{ "Quantity Refueled", string.format("%.2f tons", mass) },
					{ "Unit Price", Format.Money(price) },
					{ "Total Cost", Format.Money(total) },
				},
				note = string.format("Replenished %.2f tons hyperspace jump fuel.", mass)
			})
		end
	end
end


local getRepairCost = function (percent, shipDef)
	-- repairing 1% hull damage costs 0.1% of ship price
	shipDef = shipDef or ShipDef[Game.player.shipId]
	return math.ceil(shipDef.basePrice * (percent * 0.1)) * 0.01
end


local getRepairMessage = function (damage, price)
	return string.interp(
		l.REPAIR_X_HULL_DAMAGE_FOR_X, {
			damage = string.format('%.1f', damage),
			price = Format.Money(price)
		})
end


local function round(num, numDecimalPlaces)
	local mult = 10^(numDecimalPlaces or 0)
	return math.floor(num * mult + 0.5) / mult
end

local function determinePaintshopAvailability()
	local player = Game.player
	local station = player:GetDockedWith()

	-- faction homeworlds always have paintshops
	if Game.system.faction ~= nil and Game.system.faction.hasHomeworld and Game.system.faction.homeworld == station.path:GetSystemBody().parent.path then
		return true
	end

	-- high population stations often have them
	local pop = station:GetSystemBody().population
	if pop > 0.00005 then -- Mars is about 0.0002
		local rand = Rand.New(station.seed .. '-paintshop')
		if rand:Number(0,1) < 0.75 then
			return true
		else
			return false
		end
	else
		return false
	end
end

local function refreshModelSpinner()
	local player = Game.player
	local shipDef = ShipDef[player.shipId]
	modelSpinner:setModel(shipDef.modelName, previewSkin, previewPattern)
	modelSpinner.spinning = false
end

local popupChangesApplied = ModalWindow.New('paintshopPopupChangesApplied', function(self)
	ui.text(l.NEW_PAINTJOB_APPLIED)
	ui.dummy(Vector2((ui.getContentRegion().x - 100*rescaleVector.x) / 2, 0))
	ui.sameLine()
	if ui.button(l.OK, Vector2(100*rescaleVector.x, 0)) then
		self:close()
	end
end)

-- prepares color for use on the ship model
local function reformatColor(colors)
	return { primary = colors[1], secondary = colors[2], trim = colors[3] }
end

local function changeColor()
	local player = Game.player
	local shipDef = ShipDef[player.shipId]
	local newColor = reformatColor(previewColors)
	previewSkin = ModelSkin.New():SetColors(newColor):SetDecal(shipDef.manufacturer):SetLabel(player.label)
	refreshModelSpinner()
end

local function changePattern(increment)
	local player = Game.player
	local patterns = player.model.numPatterns

	previewPattern = 1 + ((previewPattern - 1 + increment) % patterns)

	refreshModelSpinner()
	changesMade = true
end

local function updatePrice()
	local player = Game.player
	local shipDef = ShipDef[player.shipId]

	local approxSurfaceArea = (shipDef.frontCrossSec + shipDef.sideCrossSec + shipDef.topCrossSec) * 2
	-- round to 10
	price = math.floor(approxSurfaceArea / 10 + 0.5) * 10
end

local function applyChanges()
	local player = Game.player
	if not changesMade then return end
	if price < PlayerState.GetMoney() then
		player.model:SetPattern(previewPattern)
		player:SetSkin(previewSkin)
		PlayerState.AddMoney(-price)
		ui.playSfx("Painting_Ship")
		popupChangesApplied:open()
		changesMade = false
	else
		popup:open()
	end
end

local function resetPreview()
	local player = Game.player
	previewPattern = player.model.pattern
	previewSkin = player:GetSkin()
	previewColors = previewSkin:GetColors()
	refreshModelSpinner()
	updatePrice()
	changesMade = false
end

local function drawShipRepair()

	local hullPercent = round(Game.player:GetHullPercent())
	local damage = 100 - hullPercent
	local shipDef = ShipDef[Game.player.shipId]
	local station = Game.player:GetDockedWith()

	ui.withStyleVars({ItemSpacing = widgetSizes.itemSpacing}, function ()
		local infoColumnWidth = ui.getContentRegion().x - widgetSizes.faceSize.x - widgetSizes.itemSpacing.x

		ui.child("ShipStatus", Vector2(infoColumnWidth, 0), nil, commsChildFlags, function ()

			-- SECTION 1: HULL STRUCTURAL REPAIR
			ui.withFont(orbiteer.medlarge, function()
				ui.textColored(colors.uiPrimaryLight, "HULL STRUCTURAL INTEGRITY & REPAIRS")
			end)
			ui.spacing()

			local gaugePos = ui.getCursorScreenPos()
			gaugePos.y = gaugePos.y + ui.getTextLineHeightWithSpacing() * 0.5
			ui.dummy(Vector2(widgetSizes.gaugeWidth, ui.getTextLineHeightWithSpacing()))
			ui.gauge(gaugePos, hullPercent, '', l.HULL_INTEGRITY, 0, 100, icons.hull, true, colors.gaugeEquipmentMarket, l.HUD_HULL_STRENGTH, widgetSizes.gaugeWidth, ui.getTextLineHeightWithSpacing())

			ui.spacing()

			ui.withFont(pionillium.body, function ()
				if hullPercent > 99.9 then
					ui.text(l.SHIP_IS_ALREADY_FULLY_REPAIRED)
				else
					ui.text(getRepairMessage(damageToRepair, repair_cost))
					ui.pushItemWidth(widgetSizes.gaugeWidth)
					damageToRepair = ui.sliderInt("##damageToRepair", damageToRepair, 1, damage, "%d%%")
					repair_cost = getRepairCost(damageToRepair, shipDef)

					if ui.button(l.PAY, widgetSizes.buttonSize) then
						tryRepair(damageToRepair, repair_cost)
						-- If we repaired more than 50% of the damage, reset
						if damageToRepair > damage / 2 then
							damageToRepair = damage - damageToRepair
						end
					end
					ui.sameLine()
					local fullRepairCost = getRepairCost(damage, shipDef)
					if ui.button("REPAIR FULL (" .. Format.Money(fullRepairCost) .. ")", Vector2(widgetSizes.buttonSize.x * 2.2, widgetSizes.buttonSize.y)) then
						tryRepair(damage, fullRepairCost)
						damageToRepair = 0
					end
				end
			end)

			ui.spacing()
			ui.separator()
			ui.spacing()

			-- SECTION 2: COMPONENT & SUBSYSTEM MAINTENANCE
			ui.withFont(orbiteer.medlarge, function()
				ui.textColored(colors.uiPrimaryLight, "COMPONENT & SUBSYSTEM MAINTENANCE")
			end)
			ui.spacing()

			local okCI, ComponentIntegrity = pcall(require, 'modules.ComponentIntegrity.ComponentIntegrity')
			local damagedMods = (okCI and ComponentIntegrity and ComponentIntegrity.GetDamagedModules)
				and ComponentIntegrity.GetDamagedModules(Game.player)
				or {}

			ui.withFont(pionillium.body, function()
				if #damagedMods == 0 then
					ui.textColored(colors.fontDim, "All ship components operating at nominal integrity (90%+ — servicing available below 90%).")
				else
					local totalModCost = 0
					for _, mod in ipairs(damagedMods) do
						totalModCost = totalModCost + mod.cost
					end
					if ui.button("REPAIR ALL COMPONENTS (" .. Format.Money(totalModCost) .. ")", Vector2(310 * rescaleVector.x, 30 * rescaleVector.y)) then
						if PlayerState.GetMoney() >= totalModCost then
							PlayerState.AddMoney(-totalModCost)
							recordTaxOperatingExpense(totalModCost, "MAINTENANCE")
							local equipSet = Game.player:GetComponent("EquipSet")
							local servicedHD = false
							for _, mod in ipairs(damagedMods) do
								mod.equip.integrity = 1.0
								if mod.category == "hyperdrive" then servicedHD = true end
								if equipSet then equipSet:NotifyListeners("modify", mod.equip) end
							end
							ComponentIntegrity.SyncShipSubsystems(Game.player)
							ui.playSfx("Repairing_Ship")
							if servicedHD then
								local okBS, BreakdownServicing = pcall(require, 'modules.BreakdownServicing.BreakdownServicing')
								if okBS and BreakdownServicing and BreakdownServicing.NotifyDriveServiced then
									BreakdownServicing.NotifyDriveServiced()
								end
							end
							local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
							if okFlightLog and FlightLog and FlightLog.RecordTransaction then
								FlightLog.RecordTransaction({
									category = "MAINTENANCE",
									title = string.format("Component Overhaul (%s)", Format.Money(-totalModCost)),
									amount = -totalModCost,
									details = {
										{ "Service Type", "Full Component & Subsystem Overhaul" },
										{ "Modules Serviced", tostring(#damagedMods) },
										{ "Total Fee", Format.Money(totalModCost) },
									},
									note = string.format("Restored %d worn/damaged components to 100%% integrity.", #damagedMods)
								})
							end
						else
							popupMsg = l.YOU_DONT_HAVE_ENOUGH_MONEY_FOR_THAT_OPTION
							popup:open()
						end
					end
					ui.spacing()

					if ui.beginTable("ComponentRepairsTbl", 3) then
						ui.tableSetupColumn("Component", { "WidthStretch" })
						ui.tableSetupColumn("Integrity", { "WidthFixed" }, 110 * rescaleVector.x)
						ui.tableSetupColumn("Action", { "WidthFixed" }, 140 * rescaleVector.x)
						for idx, mod in ipairs(damagedMods) do
							ui.tableNextRow()
							ui.tableNextColumn()
							ui.text(mod.name)
							ui.tableNextColumn()
							local pct = math.floor(mod.integrity * 100)
							local statusCol = mod.disabled and Color(255, 75, 65, 255)
								or (mod.integrity < 0.75 and Color(255, 190, 50, 255) or colors.white)
							local statusText = mod.disabled and "0% OFFLINE" or string.format("%d%%", pct)
							ui.textColored(statusCol, statusText)
							ui.tableNextColumn()
							if ui.button("REPAIR " .. Format.Money(mod.cost) .. "##repair_mod_" .. idx, Vector2(132 * rescaleVector.x, 24 * rescaleVector.y)) then
								if PlayerState.GetMoney() >= mod.cost then
									PlayerState.AddMoney(-mod.cost)
									recordTaxOperatingExpense(mod.cost, "MAINTENANCE")
									mod.equip.integrity = 1.0
									local equipSet = Game.player:GetComponent("EquipSet")
									if equipSet then equipSet:NotifyListeners("modify", mod.equip) end
									ComponentIntegrity.SyncShipSubsystems(Game.player)
									ui.playSfx("Repairing_Ship")
									if mod.category == "hyperdrive" then
										local okBS, BreakdownServicing = pcall(require, 'modules.BreakdownServicing.BreakdownServicing')
										if okBS and BreakdownServicing and BreakdownServicing.NotifyDriveServiced then
											BreakdownServicing.NotifyDriveServiced()
										end
									end
								else
									popupMsg = l.YOU_DONT_HAVE_ENOUGH_MONEY_FOR_THAT_OPTION
									popup:open()
								end
							end
						end
						ui.endTable()
					end
				end
			end)

			ui.spacing()
			ui.separator()
			ui.spacing()

			-- SECTION 3: PROPELLANT & HYPERDRIVE FUEL SERVICING
			ui.withFont(orbiteer.medlarge, function()
				ui.textColored(colors.uiPrimaryLight, "PROPELLANT & HYPERDRIVE FUEL SERVICING")
			end)
			ui.spacing()

			if station then
				-- Setup columns: icon | costs | buttons | fuel gauge
				ui.columns(4, 'maintenanceFuelCols', false)
				ui.setColumnWidth(0, widgetSizes.buttonSizeBase.x + widgetSizes.itemSpacing.x)
				ui.setColumnWidth(1, widgetSizes.buttonSizeBase.x * 2 + widgetSizes.itemSpacing.x)
				ui.setColumnWidth(2, (widgetSizes.buttonSizeBase.x + widgetSizes.itemSpacing.x) * 6)

				-- Internal tank fuel
				hydrogenIcon:Draw(widgetSizes.iconSize)
				ui.nextColumn()

				-- Internal tank refill costs
				local hPrice = station:GetCommodityPrice(Commodities.hydrogen)
				local currentFuelMass = shipDef.fuelTankMass / 100 * Game.player.fuel
				ui.withFont(pionillium.body, function()
					ui.text(Format.Money(hPrice) .. "/t")
					ui.text(Format.Money(hPrice * currentFuelMass))
				end)
				ui.nextColumn()

				-- Internal tank refill buttons
				if ui.button(l.REFUEL_FULL .. "##internal", widgetSizes.buttonFullRefuelSize) then refuelInternalTank(100) end
				ui.sameLine()
				if ui.button("-10%", widgetSizes.buttonSizeBase) then refuelInternalTank(-10) end
				ui.sameLine()
				if ui.button("+10%", widgetSizes.buttonSizeBase) then refuelInternalTank(10) end
				ui.nextColumn()

				-- Internal tank fuel gauge
				local fuelGaugePos = ui.getCursorScreenPos()
				local fuelGaugeHeight = widgetSizes.buttonSizeBase.y
				fuelGaugePos.x = fuelGaugePos.x + gaugeSpacing
				fuelGaugePos.y = fuelGaugePos.y + widgetSizes.buttonSizeBase.y / 2
				local fuelGaugeWidth = ui.getContentRegion().x
				ui.gauge(fuelGaugePos, Game.player.fuel, '', string.format(l.FUEL .. ": %0.1f t \t" .. l.DELTA_V .. ": %d km/s",
					currentFuelMass, Game.player:GetRemainingDeltaV() / 1000),
					0, 100, icons.fuel, true,
					colors.gaugeEquipmentMarket, '', fuelGaugeWidth, fuelGaugeHeight, pionillium.body)

				-- Hyperspace fuel row
				ui.nextColumn()

				if hyperdrive then
					hyperdriveIcon:Draw(widgetSizes.iconSize)
					ui.nextColumn()

					local stored_hyperfuel = hyperdrive.storedFuel
					local hfPrice = station:GetCommodityPrice(hyperdrive_fuel)

					-- Hyperspace fuel prices
					ui.withFont(pionillium.body, function()
						ui.text(Format.Money(hfPrice) .. "/t")
						ui.text(Format.Money(hfPrice * stored_hyperfuel))
					end)
					ui.nextColumn()

					-- Hyperspace fuel refill buttons
					if ui.button(l.REFUEL_FULL .. "##hyperdrive", widgetSizes.buttonFullRefuelSize) then refuelHyperdrive(hyperdrive:GetMaxFuel()) end
					ui.sameLine()
					if ui.button("-10t", widgetSizes.buttonSizeBase) then refuelHyperdrive(-10) end
					ui.sameLine()
					if ui.button("-1t", widgetSizes.buttonSizeBase) then refuelHyperdrive(-1) end
					ui.sameLine()
					if ui.button("+1t", widgetSizes.buttonSizeBase) then refuelHyperdrive(1) end
					ui.sameLine()
					if ui.button("+10t", widgetSizes.buttonSizeBase) then refuelHyperdrive(10) end
					ui.nextColumn()

					-- Hyperspace fuel gauge
					fuelGaugePos = ui.getCursorScreenPos()
					fuelGaugePos.x = fuelGaugePos.x + gaugeSpacing
					fuelGaugePos.y = fuelGaugePos.y + widgetSizes.buttonSizeBase.y / 2
					ui.gauge(fuelGaugePos, stored_hyperfuel, '', string.format(l.FUEL .. ": %0.1f t \t" .. l.HYPERSPACE_RANGE .. ": %d " .. l.LY,
						stored_hyperfuel, Game.player:GetHyperspaceRange()),
						0, hyperdrive:GetMaxFuel(),
						icons.hyperspace, true, colors.gaugeEquipmentMarket, '',
						fuelGaugeWidth, fuelGaugeHeight, pionillium.body)
				else
					ui.textColored(colors.fontDim, "—")
					ui.nextColumn()
					ui.textColored(colors.fontDim, "No Drive")
					ui.nextColumn()
					ui.textColored(colors.fontDim, "Hyperspace drive not installed on this vessel.")
				end

				ui.columns(1, '', false)
			end

			ui.spacing()
			ui.separator()
			ui.spacing()

			-- SECTION 3: LIVERY & PAINTSHOP
			ui.withFont(orbiteer.medlarge, function()
				ui.textColored(colors.uiPrimaryLight, "CUSTOM LIVERY & PAINTSHOP")
			end)
			ui.spacing()

			ui.withFont(pionillium.heading, function()
				local paintshopAvailable = determinePaintshopAvailability()

				if (paintshopAvailable) then
					if ui.button(l.VISIT_PAINTSHOP, Vector2(280 * rescaleVector.x, 36 * rescaleVector.y)) then
						activeTab = 1
					end
				else
					ui.text(l.PAINTSHOP_NOT_AVAILABLE)
				end
			end)
		end)

		ui.sameLine()

		ui.child("RepairsContactPane", Vector2(0, 0), nil, commsChildFlags, function()
			if(face ~= nil) then
				face:render()
			end

			local now = ui.getTime()
			ui.spacing()
			ui.separator()
			ui.spacing()
			repairsCommsText:renderCommsHeader(now, "DRYDOCK-DIAG // ISO-9001")
			ui.withFont(orbiteer.medlarge, function()
				ui.textColored(colors.uiPrimaryLight, "YARDMASTER DIRECTIVE")
			end)
			ui.spacing()
			repairsCommsText:renderTextWrapped(now, pionillium.body)
		end)
	end)
end

local function drawPaintshop()

	ui.withFont(pionillium.heading, function()
		if ui.button("RETURN TO MAINTENANCE SERVICES", Vector2(320 * rescaleVector.x, 36 * rescaleVector.y)) then
			activeTab = 0
			return
		end
	end)

	local player = Game.player
	local shipDef = ShipDef[player.shipId]
	local station = player:GetDockedWith()

	local available = determinePaintshopAvailability()
	if not available then
		ui.text(l.PAINTSHOP_NOT_AVAILABLE)
		return
	end

	local rand = Rand.New(station.seed)

	local priceColor = textColorDefault
	if price > PlayerState.GetMoney() then
		priceColor = textColorWarning
	end

	local itemSpacing = Vector2(8, 6)
	local columnWidth = math.floor((ui.getContentRegion().x - itemSpacing.x) / 2)
	local verticalDummy = Vector2(0, 50)
	ui.withStyleVars({ ItemSpacing = itemSpacing }, function ()
		ui.child("PaintshopModelSpinner", Vector2(columnWidth, 0), nil, commsChildFlags, function()
			modelSpinner:setSize(ui.getContentRegion())
			modelSpinner:draw()
		end)

		ui.sameLine()

		ui.child("PaintshopControls", Vector2(0, 0), nil, commsChildFlags, function ()
			ui.text(l["PAINTSHOP_WELCOME_" .. rand:Integer(NUM_WELCOME_MESSAGES - 1)])
			ui.dummy(verticalDummy)
			ui.text(l.PLEASE_DESIGN_NEW_PAINTJOB)
			local priChanged, secChanged, triChanged
			priChanged, previewColors[1] = ui.colorEdit((l.COLOR.." 1"), previewColors[1], { "NoAlpha" })
			secChanged, previewColors[2] = ui.colorEdit((l.COLOR.." 2"), previewColors[2], { "NoAlpha" })
			triChanged, previewColors[3] = ui.colorEdit((l.COLOR.." 3"), previewColors[3], { "NoAlpha" })

			ui.withFont(pionillium.body, function()

				if ui.button("<", Vector2(20, 36)) then
					changePattern(-1)
				end
				ui.sameLine()
				ui.text(l.PATTERN.. " " ..previewPattern)
				ui.sameLine()
				if ui.button(">", Vector2(20, 36)) then
					changePattern(1)
				end

				ui.sameLine()
				if ui.button(l.RESET_PREVIEW, Vector2(columnWidth/4, 36)) then
					resetPreview()
				end

				ui.sameLine()
				if ui.button(l.RANDOM_COLORS, Vector2(columnWidth/4, 36)) then

					local function randomColor()
						return Color(Engine.rand:Integer(0,255), Engine.rand:Integer(0,255), Engine.rand:Integer(0,255))
					end

					previewColors[1] = randomColor()
					previewColors[2] = randomColor()
					previewColors[3] = randomColor()

					-- preview colors may be the same
					if Engine.rand:Integer(0,2) < 1 then
						local color = Engine.rand:Integer(1,4)
						if color == 1 then
							previewColors[2] = previewColors[1]
						elseif color == 2 then
							previewColors[3] = previewColors[1]
						elseif color == 3 then
							previewColors[3] = previewColors[2]
						else -- All colors the same
							previewColors[2] = previewColors[1]
							previewColors[3] = previewColors[1]
						end
					end
					priChanged = true -- All colors changed but we only need to hint one
				end

				local colorChanged = (priChanged or secChanged or triChanged)
				if colorChanged then
					changesMade = true
				end

				if colorChanged then
					changeColor()
				end

				ui.dummy(verticalDummy)

				ui.withStyleColors({Text = priceColor }, function()
					ui.text(l.PRICE.. ": " ..Format.Money(price, false))
				end)
				if ui.button(l.PURCHASE_PAINTJOB, Vector2(200, 36)) then
					applyChanges()
				end
			end)
		end)
	end)
end


StationView:registerView({
	id = "shipRepairs",
	name = "Ship Maintenance",
	icon = ui.theme.icons.repairs,
	securityMode = "encryption",
	showView = true,
	draw = function()
		ui.withFont(pionillium.body, function()
			if (activeTab == 0) then
				drawShipRepair()
			else
				drawPaintshop()
			end
		end)
	end,
	refresh = function ()
		repairsCommsText:reset()
		if not determinePaintshopAvailability() then
			activeTab = 0
		end

		local station = Game.player:GetDockedWith()
		-- Don't reset player's choice if temporarily leaving ship repair screen
		if not damageToRepair then
			damageToRepair = 1
		end
		if (station) then
			if (stationSeed ~= station.seed) then
				stationSeed = station.seed
				local rand = Rand.New(station.seed .. '-repair-guy')
				face = PiGuiFace.New(Character.New({ title = l.CHIEF_MECHANIC }, rand),
							{itemSpacing = widgetSizes.itemSpacing})
			end

			hyperdrive = Game.player:GetInstalledHyperdrive()
			hyperdrive_fuel = hyperdrive and hyperdrive.fuel or Commodities.hydrogen
			hyperdriveIcon = PiImage.New("icons/goods/" .. hyperdrive_fuel.icon_name .. ".png")
		end
		resetPreview()
	end,
	debugReload = function()
		package.reimport()
	end
})

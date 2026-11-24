-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Lang = require 'Lang'
local Game = require 'Game'
local Format = require 'Format'
local ShipDef = require 'ShipDef'
local Equipment = require 'Equipment'
local StationView = require 'pigui.views.station-view'
local Table = require 'pigui.libs.table'
local SortBar = require 'pigui.libs.sort-bar'
local PiImage = require 'pigui.libs.image'
local ModelSpinner = require 'PiGui.Modules.ModelSpinner'
local EquipSet = require 'EquipSet'
local HullConfig = require 'HullConfig'
local PlayerState= require 'PlayerState'
local Passengers = require 'Passengers'
local PlayerFleet = require 'modules.PlayerFleet.PlayerFleet'
local Insurance = require 'modules.Insurance.Insurance'
local ShipDealerships = require 'ShipDealerships'

local ui = require 'pigui'

local utils = require 'utils'

local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local colors = ui.theme.colors
local l = Lang.GetResource("ui-core")
local ls = Lang.GetResource("ships")
local Vector2 = _G.Vector2

local commsChildFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders' }

local vZero = Vector2(0,0)
local widgetSizes = ui.rescaleUI({
	iconSize = Vector2(34, 34),
	dealerIconSize = Vector2(40, 40),
	buyButton = Vector2(88, 32),
	confirmButtonSize = Vector2(320, 40),
	itemSpacing = Vector2(10, 4),
	headerHeight = 68,
}, Vector2(1920, 1080))
widgetSizes.iconSpacer = (widgetSizes.buyButton - widgetSizes.iconSize)/2

local shipMarket
---@type table<table, table>
local advertDataCache = {}
local icons = {}
local manufacturerIcons = {}
local selectedItem
local dealership
local filterMode = "ALL"
local sortId = "condition"
local sortDir = 1
local counts = { total = 0, newCount = 0, usedCount = 0 }

local SHIP_SORT_KEYS = {
	{ id = "name",      label = l.SHIP,      defaultDir = 1 },
	{ id = "condition", label = "Condition", defaultDir = 1 },
	{ id = "price",     label = l.PRICE,     defaultDir = 1 },
	{ id = "capacity",  label = l.CAPACITY,  defaultDir = -1 },
}

local shipSellPriceReduction = 0.65
local equipSellPriceReduction = 0.8

local modelSpinner = ModelSpinner()
local cachedShip = nil
local cachedPattern = nil

local shipClassString = {
	light_cargo_shuttle        = l.LIGHT_CARGO_SHUTTLE,
	light_courier              = l.LIGHT_COURIER,
	light_fighter              = l.LIGHT_FIGHTER,
	light_freighter            = l.LIGHT_FREIGHTER,
	light_passenger_shuttle    = l.LIGHT_PASSENGER_SHUTTLE,
	light_passenger_transport  = l.LIGHT_PASSENGER_TRANSPORT,
	medium_cargo_shuttle       = l.MEDIUM_CARGO_SHUTTLE,
	medium_courier             = l.MEDIUM_COURIER,
	medium_fighter             = l.MEDIUM_FIGHTER,
	medium_freighter           = l.MEDIUM_FREIGHTER,
	medium_passenger_shuttle   = l.MEDIUM_PASSENGER_SHUTTLE,
	medium_passenger_transport = l.MEDIUM_PASSENGER_TRANSPORT,
	heavy_cargo_shuttle        = l.HEAVY_CARGO_SHUTTLE,
	heavy_courier              = l.HEAVY_COURIER,
	heavy_fighter              = l.HEAVY_FIGHTER,
	heavy_freighter            = l.HEAVY_FREIGHTER,
	heavy_passenger_shuttle    = l.HEAVY_PASSENGER_SHUTTLE,
	heavy_passenger_transport  = l.HEAVY_PASSENGER_TRANSPORT,

	unknown                    = "",
}

local function makeAdvertDataCacheEntry(shipOnSale)
	return ShipDealerships.ComputeListingOffer(shipOnSale)
end

local function refreshModelSpinner()
	if not selectedItem then return end
	cachedShip = selectedItem.def.modelName
	cachedPattern = selectedItem.pattern
	modelSpinner:setModel(cachedShip, selectedItem.skin, cachedPattern)
end

local function applyFilter()
	local station = Game.player:GetDockedWith()
	local rawList = station and station:GetShipsOnSale() or {}

	local sorted = {}
	counts.total = 0
	counts.newCount = 0
	counts.usedCount = 0

	for _, sos in ipairs(rawList) do
		if not advertDataCache[sos] then
			advertDataCache[sos] = makeAdvertDataCacheEntry(sos)
		end
		table.insert(sorted, sos)
		counts.total = counts.total + 1
		if sos.condition == "USED" then
			counts.usedCount = counts.usedCount + 1
		else
			counts.newCount = counts.newCount + 1
		end
	end

	table.sort(sorted, function(a, b)
		local pa = advertDataCache[a] and advertDataCache[a].price or 0
		local pb = advertDataCache[b] and advertDataCache[b].price or 0
		local na = ls[a.def.i18n_key] or a.def.name or ""
		local nb = ls[b.def.i18n_key] or b.def.name or ""
		local cmp

		if sortId == "name" then
			cmp = SortBar.compareValues(na, nb, sortDir)
		elseif sortId == "price" then
			cmp = SortBar.compareValues(pa, pb, sortDir)
		elseif sortId == "capacity" then
			cmp = SortBar.compareValues(a.def.cargo or 0, b.def.cargo or 0, sortDir)
		else -- "condition"
			local aUsed = (a.condition == "USED") and 1 or 0
			local bUsed = (b.condition == "USED") and 1 or 0
			cmp = SortBar.compareValues(aUsed, bUsed, sortDir)
		end
		if cmp ~= nil then return cmp end

		if sortId ~= "price" then
			local cmpPrice = SortBar.compareValues(pa, pb, 1)
			if cmpPrice ~= nil then return cmpPrice end
		end
		if sortId ~= "name" then
			local cmpName = SortBar.compareValues(na, nb, 1)
			if cmpName ~= nil then return cmpName end
		end
		local cmpLabel = SortBar.compareValues(a.label or "", b.label or "", 1)
		if cmpLabel ~= nil then return cmpLabel end
		return false
	end)

	local filtered = {}
	for _, sos in ipairs(sorted) do
		local isUsed = (sos.condition == "USED")
		if filterMode == "ALL"
			or (filterMode == "NEW" and not isUsed)
			or (filterMode == "USED" and isUsed)
		then
			table.insert(filtered, sos)
		end
	end

	shipMarket.items = filtered

	local foundSelected = false
	if selectedItem then
		for _, sos in ipairs(filtered) do
			if sos == selectedItem then
				foundSelected = true
				break
			end
		end
	end

	if not foundSelected then
		selectedItem = filtered[1]
		shipMarket.selectedItem = selectedItem
		refreshModelSpinner()
	end
end

local function refreshShipMarket()
	widgetSizes.rowVerticalSpacing = Vector2(0, math.max(0, (widgetSizes.iconSize.y + widgetSizes.itemSpacing.y - pionillium.body.size * 1.9) / 2))

	local station = Game.player:GetDockedWith()
	if station then
		dealership = station.GetDealership and station:GetDealership() or ShipDealerships.GetDealership(station)
		local rawList = station:GetShipsOnSale()
		advertDataCache = {}
		for _, sos in ipairs(rawList) do
			advertDataCache[sos] = makeAdvertDataCacheEntry(sos)
		end
	else
		dealership = nil
		shipMarket.items = {}
		advertDataCache = {}
	end

	selectedItem = nil
	shipMarket.selectedItem = nil
	applyFilter()
end

local function manufacturerIcon (manufacturer, sz)
	if(manufacturer ~= "unknown" and manufacturer ~= nil) then
		if manufacturerIcons[manufacturer] == nil then
			manufacturerIcons[manufacturer] = PiImage.New("icons/manufacturer/".. manufacturer ..".png")
		end
		manufacturerIcons[manufacturer]:Draw(sz or widgetSizes.iconSize)
	end
end

---@param ship Ship
local tradeInValue = function(ship)
	local shipDef = ShipDef[ship.shipId]
	local hullBase = Insurance.IsPlayerShipSubsidized() and 0 or shipDef.basePrice
	local value = hullBase * shipSellPriceReduction * ship.hullPercent/100

	-- We don't need to remove the hyperdrive from the value of the ship since the player is charged for it when buying the ship
	local equipment = ship:GetComponent("EquipSet"):GetInstalledEquipment()
	for _, e in pairs(equipment) do
		value = value + (e.price or 0) * equipSellPriceReduction
	end

	return math.ceil(value)
end

local function buyShip (mkt, sos)
	if Insurance.HasClaim() then
		mkt.popup.msg = "Please settle your open insurance claim at the Insurance & SAR office before purchasing or trading in a ship."
		mkt.popup:open()
		return
	end

	local player = Game.player
	local station = assert(player:GetDockedWith())
	local def = sos.def

	local shipData = advertDataCache[sos]
	local tradeIn = tradeInValue(Game.player)

	local cost = shipData.price - tradeIn
	if math.floor(cost) ~= cost then
		error("Ship price non-integer value.")
	end
	if PlayerState.GetMoney() < cost then
		mkt.popup.msg = l.YOU_NOT_ENOUGH_MONEY
		mkt.popup:open()
		return
	end

	if player:CrewNumber() > def.maxCrew then
		mkt.popup.msg = l.TOO_SMALL_FOR_CURRENT_CREW
		mkt.popup:open()
		return
	end

	-- Not enough room to put all of the player's current cargo
	if def.cargo < player.usedCargo then
		mkt.popup.msg = l.TOO_SMALL_TO_TRANSSHIP
		mkt.popup:open()
		return
	end

	PlayerState.AddMoney(-cost)

	local condLabel = (sos.condition == "USED") and "Pre-Owned" or "Factory New"
	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		FlightLog.RecordTransaction({
			category = "SHIP",
			title = string.format("Vessel Acquisition (%s): %s (%s)", condLabel, def.name, Format.Money(-cost)),
			amount = -cost,
			details = {
				{ "Vessel Model", def.name },
				{ "Condition", condLabel },
				{ "Seller", dealership and dealership.name or "Starport Yard" },
				{ "Vessel Registration", sos.label or "Unnamed" },
				{ "Trade-in Deducted", Format.Money(tradeIn or 0) },
				{ "Net Cost Paid", Format.Money(cost) },
			},
			note = string.format("Acquired %s %s (%s) from %s.", condLabel, def.name, sos.label or "Unnamed", dealership and dealership.name or "shipyard")
		})
	end

	local tradeInListing = ShipDealerships.BuildTradeInListing(player)
	station:ReplaceShipOnSale(sos, tradeInListing)

	player:SetShipType(def.id)
	Insurance.SetPlayerShipSubsidized(false)
	player:SetSkin(sos.skin)
	if sos.pattern then player.model:SetPattern(sos.pattern) end
	player:SetLabel(sos.label)
	if player.SetShipName then
		player:SetShipName(ShipDealerships.DefaultShipNameForListing(sos))
	end

	ShipDealerships.InstallListingEquipment(player, shipData, sos)
	refreshShipMarket()

	mkt.popup.msg = l.THANKS_AND_REMEMBER_TO_BUY_FUEL
	mkt.popup:open()
end

local FormatAndCompareShips = utils.class("ui.ShipMarket.FormatAndCompareShips")

function FormatAndCompareShips:beginTable()
	if not ui.beginTable("specs", 7 ) then
		return false
	end

	ui.tableSetupColumn("name1")
	ui.tableSetupColumn("body1")
	ui.tableSetupColumn("indicator1", {"WidthFixed"})
	ui.tableSetupColumn("gap", {"WidthFixed"})
	ui.tableSetupColumn("name2")
	ui.tableSetupColumn("body2")
	ui.tableSetupColumn("indicator2", {"WidthFixed"})

	return true
end

---@param desc       string        Description of the item being drawn
---@param a	         number        The value for the new ship
---@param b          number        The value for the old shio
---@param fmt_a      function|nil  A function that takes a and formats it to a string, if required
---@param fmt_b      function|nil  A function that takes b and formats it to a string, if nil then fmt_a is used
function FormatAndCompareShips:compare_and_draw_column(desc, a, b, fmt_a, fmt_b)
	local compare = a-b

	if self.column == 0 then
		ui.tableNextRow()
	end

	fmt_b = fmt_b and fmt_b or fmt_a

	ui.tableSetColumnIndex(0 + self.column)
	ui.textColored(ui.theme.colors.fontDim, desc)

	ui.tableSetColumnIndex(1 + self.column)

	local new_str = fmt_a and fmt_a( a ) or a

	if compare < 0 then
		local old_str = fmt_b and fmt_b( b ) or b
		ui.withTooltip( l.CURRENT_SHIP .. ": " .. old_str, function ()
			ui.textAlignedColored(new_str, 1.0, ui.theme.colors.compareWorse)
			ui.tableSetColumnIndex(2 + self.column)
			ui.icon( ui.theme.icons.shipmarket_compare_worse, Vector2(ui.getTextLineHeight()), ui.theme.colors.compareWorse)
		end )
	elseif compare > 0 then
		local old_str = fmt_b and fmt_b( b ) or b
		ui.withTooltip( l.CURRENT_SHIP .. ": " .. old_str, function ()
			ui.textAlignedColored(new_str, 1.0,  ui.theme.colors.compareBetter)
			ui.tableSetColumnIndex(2 + self.column)
			ui.icon( ui.theme.icons.shipmarket_compare_better, Vector2(ui.getTextLineHeight()), ui.theme.colors.compareBetter)
		end )
	else
		ui.textAligned(new_str, 1.0)
		ui.tableSetColumnIndex(2 + self.column)
		ui.dummy( Vector2(ui.getTextLineHeight()) )
	end

	if self.column == 0 then
		self.column = 4
	else
		self.column = 0
	end
end

function FormatAndCompareShips:draw_hyperdrive_cell(desc)
	local function fmt( v )
		return v > 0 and v < 8 and
			Equipment.new["hyperspace.hyperdrive_" .. v]:GetName() or l.NONE
	end

	self:compare_and_draw_column( desc, self.def.hyperdriveClass, self.b.def.hyperdriveClass, fmt )
end

function FormatAndCompareShips:get_value(key)
	local v = self[key]
	if nil == v then
		v = self.def[key]
	end
	return v
end

function FormatAndCompareShips:draw_tonnage_cell(desc, key)
	self:compare_and_draw_column( desc, self:get_value(key), self.b:get_value(key), Format.MassTonnes )
end

function FormatAndCompareShips:draw_cargo_cell(desc, key)
	self:compare_and_draw_column( desc, self:get_value(key), self.b:get_value(key), ui.Format.Cargo )
end

function FormatAndCompareShips:draw_volume_cell(desc, key)
	self:compare_and_draw_column( desc, self:get_value(key), self.b:get_value(key), ui.Format.Volume )
end

function FormatAndCompareShips:draw_accel_cell(desc, thrustKey, massKey )
	local accelA = self.def.linearThrust[thrustKey] / (9.8106*1000*(self:get_value(massKey)))
	local accelB = self.b.def.linearThrust[thrustKey] / (9.8106*1000*(self.b:get_value(massKey)))
	self:compare_and_draw_column( desc, accelA, accelB, Format.AccelG )
end

function FormatAndCompareShips:draw_deltav_cell(desc, massNumeratorKey, massDenominatorKey)
	local deltavA = self.def.effectiveExhaustVelocity * math.log( self:get_value(massNumeratorKey) / self:get_value(massDenominatorKey) )
	local deltavB = self.b.def.effectiveExhaustVelocity * math.log( self.b:get_value(massNumeratorKey) / self.b:get_value(massDenominatorKey) )

	local function fmt( v )
		return string.format("%d km/s", v / 1000)
	end

	self:compare_and_draw_column( desc, deltavA, deltavB, fmt )
end

function FormatAndCompareShips:draw_unformated_cell(desc, key)
	self:compare_and_draw_column( desc, self:get_value(key),  self.b:get_value(key) )
end

local function getNumSlotsCompatibleWithType(def, type)
	local config = HullConfig.GetHullConfig(def.id)
	local count = 0

	for _, slot in pairs(config.slots) do
		if EquipSet.SlotTypeMatches(type, slot.type) then
			count = count + (slot.count or 1)
		end
	end

	return count
end

local function getBestSlotSizeOfType(def, type)
	local config = HullConfig.GetHullConfig(def.id)
	local slot, size = utils.best_score(config.slots, function(_, slot)
		return EquipSet.SlotTypeMatches(type, slot.type) and slot.size or nil
	end)

	return slot and size or 0
end

function FormatAndCompareShips:draw_equip_slot_cell(desc, key)
	self:compare_and_draw_column( desc, getNumSlotsCompatibleWithType(self.def, key), getNumSlotsCompatibleWithType(self.b.def, key) )
end

function FormatAndCompareShips:draw_berths_slot_cell(desc)
	local a_hull = HullConfig.GetHullConfig(self.def.id)
	local b_hull = (self.b and self.b.def) and HullConfig.GetHullConfig(self.b.def.id) or nil
	self:compare_and_draw_column( desc, Passengers.GetMaxPassengersForHull(a_hull), Passengers.GetMaxPassengersForHull(b_hull) )
end

function FormatAndCompareShips:draw_yes_no_equip_slot_cell(desc, key)
	local function fmt( v ) return v==1 and l.YES or l.NO end
	self:compare_and_draw_column( desc, getNumSlotsCompatibleWithType(self.def, key), getNumSlotsCompatibleWithType(self.b.def, key), fmt )
end

function FormatAndCompareShips:draw_atmos_pressure_limit_cell(desc)
	local a_shield = getBestSlotSizeOfType(self.def, "hull.atmo_shield")
	local b_shield = getBestSlotSizeOfType(self.b.def, "hull.atmo_shield")

	local function fmt( def, has_shield )
		local atmoSlot
		if has_shield > 1 then
			atmoSlot = string.format("%d(+%d/+%d) atm", def.atmosphericPressureLimit,
			def.atmosphericPressureLimit * (Equipment.new["hull.atmospheric_shielding_s2"].capabilities.atmo_shield - 1),
			def.atmosphericPressureLimit * (Equipment.new["hull.heavy_atmospheric_shielding_s2"].capabilities.atmo_shield - 1) )
		elseif has_shield > 0 then
			atmoSlot = string.format("%d(+%d) atm", def.atmosphericPressureLimit,
			def.atmosphericPressureLimit * (Equipment.new["hull.atmospheric_shielding_s2"].capabilities.atmo_shield - 1) )
		else
			atmoSlot = string.format("%d atm", def.atmosphericPressureLimit)
		end
		return atmoSlot
	end

	local function fmt_a( v ) return fmt( self.def, a_shield ) end
	local function fmt_b( v ) return fmt( self.b.def, b_shield ) end

	self:compare_and_draw_column( desc, self.def.atmosphericPressureLimit*1000+a_shield, self.b.def.atmosphericPressureLimit*1000+b_shield, fmt_a, fmt_b )
end

function FormatAndCompareShips:Constructor(def, b)
	self.column = 0
	self.emptyMass = def.hullMass + def.fuelTankMass
	self.cargoCapacity = def.cargo
	self.def = def
	self.b = b
end

local function drawDealershipHeader()
	if not dealership then return end

	ui.child("DealershipHeader", Vector2(0, widgetSizes.headerHeight), nil, commsChildFlags, function()
		if dealership.kind == "FRANCHISE" and dealership.manufacturerId then
			manufacturerIcon(dealership.manufacturerId, widgetSizes.dealerIconSize)
		else
			ui.icon(ui.theme.icons.ship, widgetSizes.dealerIconSize, colors.alertYellow)
		end

		ui.sameLine(0, widgetSizes.itemSpacing.x)

		ui.group(function()
			ui.withFont(orbiteer.heading, function()
				local titleColor = (dealership.kind == "INDEPENDENT_USED") and colors.alertYellow or colors.uiPrimaryLight
				ui.textColored(titleColor, dealership.name)
			end)
			ui.withFont(pionillium.details, function()
				ui.textColored(colors.fontDim, dealership.subtitle)
			end)
		end)

		local filterDefs = {
			{ id = "ALL",  label = string.format("All (%d)", counts.total) },
			{ id = "NEW",  label = string.format("New Factory (%d)", counts.newCount) },
			{ id = "USED", label = string.format("Pre-Owned (%d)", counts.usedCount) },
		}

		local btnSpacing = 6
		local btnPadX = ui.theme.styles.ButtonPadding.x * 2
		local totalBtnW = 0
		ui.withFont(pionillium.body, function()
			for i, f in ipairs(filterDefs) do
				totalBtnW = totalBtnW + ui.calcTextSize(f.label).x + btnPadX
				if i > 1 then totalBtnW = totalBtnW + btnSpacing end
			end
		end)

		local availW = ui.getContentRegion().x
		local curX = ui.getCursorPos().x
		local targetX = math.max(curX, availW - totalBtnW)
		ui.sameLine(targetX)

		ui.withFont(pionillium.body, function()
			for i, f in ipairs(filterDefs) do
				if i > 1 then ui.sameLine(nil, btnSpacing) end
				local active = (filterMode == f.id)
				local style = active and ui.theme.buttonColors.selected or ui.theme.buttonColors.default
				if ui.button(f.label .. "##shipFilter_" .. f.id, Vector2(0, 0), style) then
					if filterMode ~= f.id then
						filterMode = f.id
						applyFilter()
					end
				end
			end
		end)
	end)
end

local function drawPreinstalledEquipment(shipData, isUsed)
	if not shipData or not shipData.equip or #shipData.equip == 0 then return end

	ui.spacing()
	ui.withFont(orbiteer.body, function()
		ui.textColored(colors.uiPrimaryLight, string.format("PRE-INSTALLED EQUIPMENT (%d MODULES)", #shipData.equip))
	end)
	ui.separator()

	for _, pair in ipairs(shipData.equip) do
		local slotId, inst, isAftermarket = pair[1], pair[2], pair[3]
		local name = inst:GetName()
		local rawInteg = rawget(inst, "integrity") or 1
		local integPct = math.floor((rawInteg * 100) + 0.5)
		local isModuleNew = (rawInteg >= 0.999) and (rawget(inst, "isUsed") ~= true)
		local slotTag = slotId and ("[" .. slotId .. "]") or "[LOOSE]"
		local badge = isAftermarket and "[AFTERMARKET]" or "[STOCK]"
		local col = isAftermarket and (colors.econProfit or colors.compareBetter) or colors.font

		ui.withFont(pionillium.details, function()
			ui.textColored(col, string.format("• %s  %s", badge, name))
			ui.sameLine()
			if isUsed then
				local condStr = isModuleNew and "New - 100%" or string.format("%d%% cond.", integPct)
				ui.textColored(colors.fontDim, string.format("%s  (%s)", slotTag, condStr))
			else
				ui.textColored(colors.fontDim, slotTag)
			end
		end)
	end
end

local tradeMenu = function()
	if not selectedItem then
		ui.withStyleVars({ ItemSpacing = shipMarket.style.itemSpacing }, function()
			ui.child("TradeMenuEmpty", Vector2(0, 0), nil, commsChildFlags, function()
				ui.withFont(orbiteer.heading, function()
					ui.textColored(colors.fontDim, "NO VESSELS MATCH CURRENT FILTER")
				end)
				ui.spacing()
				ui.withFont(pionillium.body, function()
					if dealership and dealership.kind == "INDEPENDENT_USED" and filterMode == "NEW" then
						ui.textWrapped("This independent brokerage deals exclusively in pre-owned and aftermarket-refitted spacecraft. Switch the filter to Pre-Owned or All to inspect available inventory.")
					else
						ui.textWrapped("No vessels are currently displayed under this category filter.")
					end
				end)
				ui.spacing()
				if filterMode ~= "ALL" then
					if ui.button("SHOW ALL LISTINGS##resetShipFilter", Vector2(220, 34)) then
						filterMode = "ALL"
						applyFilter()
					end
				end
			end)
		end)
		return
	end

	ui.withStyleVars({ ItemSpacing = shipMarket.style.itemSpacing }, function()
		ui.child("TradeMenu", Vector2(0,0), nil, commsChildFlags, function()
			local colHeadingWidth = ui.getContentRegion().x - widgetSizes.buyButton.x
			local def = selectedItem.def
			local isUsed = (selectedItem.condition == "USED")
			local offer = advertDataCache[selectedItem]
			local mfrInfo = ShipDealerships.Manufacturers[def.manufacturer]
			local mfrName = mfrInfo and mfrInfo.name or string.upper(def.manufacturer or "Unknown")

			ui.columns(2, "shipMarketInfo")
			ui.setColumnWidth(0, colHeadingWidth)

			ui.withFont(orbiteer.title, function()
				ui.text(ls[def.i18n_key])
			end)
			ui.withFont(orbiteer.body, function()
				local condText = isUsed and "PRE-OWNED" or "FACTORY NEW"
				local condCol = isUsed and colors.alertYellow or (colors.econProfit or colors.compareBetter)
				ui.textColored(condCol, condText)
				ui.sameLine()
				ui.textColored(colors.fontDim, string.format("•  %s  •  %s  •  Reg: %s", shipClassString[def.shipClass] or "", mfrName, selectedItem.label or ""))
			end)

			ui.withFont(pionillium.details, function()
				if isUsed then
					ui.textColored(colors.fontDim, string.format("Provenance: %s  |  Hull Integrity: %d%%  |  Flight Log: %s hrs",
						selectedItem.provenance or "Pre-Owned Vessel",
						selectedItem.hullPercent or 90,
						ui.Format.Number(selectedItem.flightHours or 0, 0)))
				else
					ui.textColored(colors.fontDim, string.format("Provenance: %s  |  Hull Integrity: 100%% (Full Manufacturer Warranty)",
						selectedItem.provenance or "Factory Direct Delivery"))
				end
			end)

			local cost = offer.price

			ui.withFont(pionillium.heading, function()
				ui.text(l.PRICE..": "..Format.Money(cost, false))
				ui.sameLine()
				ui.text(l.AFTER_TRADE_IN..": "..Format.Money(cost - tradeInValue(Game.player), false))
				if isUsed and offer.savings and offer.savings > 0 then
					ui.sameLine()
					ui.textColored(colors.econProfit or colors.compareBetter, string.format("(Save %s vs MSRP)", Format.Money(offer.savings, false)))
				end
			end)
			if Insurance.IsPlayerShipSubsidized() then
				ui.withFont(pionillium.body, function()
					ui.textColored(colors.fontDim, "(Charter-Subsidized Starter: 0 Cr hull trade-in)")
				end)
			end

			ui.nextColumn()
			ui.dummy(widgetSizes.iconSpacer)
			ui.sameLine()
			manufacturerIcon(def.manufacturer)
			local shipBought = false
			local shipStoredAndBought = false
			local shipBoughtToHangar = false
			ui.withFont(pionillium.body, function()
				shipBought = ui.button(l.BUY_SHIP, widgetSizes.buyButton)
			end)
			ui.columns(1, "")

			ui.withFont(pionillium.body, function()
				local actBtnW = math.floor((ui.getContentRegion().x - 8) / 2)
				shipStoredAndBought = ui.button("Buy & Store Current (" .. Format.Money(cost, false) .. ")", Vector2(actBtnW, 32))
				ui.sameLine(nil, 8)
				shipBoughtToHangar = ui.button("Buy into Hangar (" .. Format.Money(cost, false) .. ")", Vector2(actBtnW, 32))
			end)

			if shipBought then
				buyShip(shipMarket, selectedItem)
				return
			elseif shipStoredAndBought then
				local ok, msg = PlayerFleet.StorePlayerShipAndBuy(selectedItem, offer)
				if ok then refreshShipMarket() end
				shipMarket.popup.msg = msg
				shipMarket.popup:open()
				return
			elseif shipBoughtToHangar then
				local ok, msg = PlayerFleet.BuyShipToHangar(selectedItem, offer)
				if ok then refreshShipMarket() end
				shipMarket.popup.msg = msg
				shipMarket.popup:open()
				return
			end

			local spinnerWidth = ui.getContentRegion().x
			modelSpinner:setSize(Vector2(spinnerWidth, spinnerWidth / 2.8))
			modelSpinner:draw()

			local currentShip = FormatAndCompareShips.New( ShipDef[Game.player.shipId], nil )
			local shipFormatAndCompare = FormatAndCompareShips.New( def, currentShip )

			ui.child("ShipSpecs", Vector2(0, 0), function()
				ui.withStyleVars({ CellPadding = Vector2(3,4) }, function()

					if shipFormatAndCompare:beginTable() then
						shipFormatAndCompare:draw_hyperdrive_cell( l.HYPERDRIVE_FITTED )
						shipFormatAndCompare:draw_tonnage_cell( l.WEIGHT_EMPTY, "hullMass" )
						shipFormatAndCompare:draw_accel_cell( l.FORWARD_ACCEL_EMPTY, "FORWARD", "emptyMass" )
						shipFormatAndCompare:draw_tonnage_cell( l.FUEL_WEIGHT, "fuelTankMass" )
						shipFormatAndCompare:draw_accel_cell( l.REVERSE_ACCEL_EMPTY, "REVERSE", "emptyMass" )
						shipFormatAndCompare:draw_cargo_cell( l.CARGO_SPACE, "cargoCapacity" )
						shipFormatAndCompare:draw_accel_cell( l.UP_ACCEL_EMPTY, "UP", "emptyMass" )
						shipFormatAndCompare:draw_volume_cell( l.EQUIPMENT_CAPACITY, "equipCapacity" )
						shipFormatAndCompare:draw_deltav_cell( l.DELTA_V_EMPTY, "emptyMass", "hullMass")
						shipFormatAndCompare:draw_yes_no_equip_slot_cell( l.ATMOSPHERIC_SHIELDING, "hull.atmo_shield" )
						shipFormatAndCompare:draw_unformated_cell( l.MINIMUM_CREW, "minCrew" )
						shipFormatAndCompare:draw_atmos_pressure_limit_cell( l.ATMO_PRESS_LIMIT )
						shipFormatAndCompare:draw_unformated_cell( l.MAXIMUM_CREW, "maxCrew" )
						shipFormatAndCompare:draw_equip_slot_cell( l.MISSILE_MOUNTS, "missile" )
						shipFormatAndCompare:draw_berths_slot_cell( l.PASSENGER_CABIN_CAPACITY )
						shipFormatAndCompare:draw_equip_slot_cell( l.SCOOP_MOUNTS, "scoop" )

						ui.endTable()
					end

					drawPreinstalledEquipment(offer, isUsed)
				end)
			end)

		end)
	end)
end

shipMarket = Table.New("shipMarketWidget", false, {
	borders = true,
	columnCount = 4,
	iterator = ipairs,
	initTable = function(self)
		local scrollPad = 16
		local availableW = self.style.size.x - scrollPad
		local col0W = widgetSizes.iconSize.x + widgetSizes.itemSpacing.x
		local remainingW = availableW - col0W - 1
		local col1W = math.floor(remainingW * 0.44)
		local col2W = math.floor(remainingW * 0.34)
		local col3W = remainingW - col1W - col2W
		ui.setColumnWidth(0, col0W)
		ui.setColumnWidth(1, col1W)
		ui.setColumnWidth(2, col2W)
		ui.setColumnWidth(3, col3W)
		ui.setColumnWidth(4, 1)
	end,
	renderHeaderRow = function(_)
		ui.withFont(pionillium.body, function()
			ui.text('')
			ui.nextColumn()
			ui.text(l.SHIP)
			ui.nextColumn()
			ui.text(l.PRICE)
			ui.nextColumn()
			ui.text(l.CAPACITY)
			ui.nextColumn()
		end)
	end,
	renderItem = function(_, item)
		if(icons[item.def.shipClass] == nil) then
			icons[item.def.shipClass] = PiImage.New("icons/shipclass/".. item.def.shipClass ..".png")
		end

		if not selectedItem then
			selectedItem = item
			shipMarket.selectedItem = item
			refreshModelSpinner()
		end

		if not advertDataCache[item] then
			advertDataCache[item] = makeAdvertDataCacheEntry(item)
		end

		local isUsed = (item.condition == "USED")
		local offer = advertDataCache[item]
		local mfr = ShipDealerships.Manufacturers[item.def.manufacturer]
		local mfrTag = mfr and mfr.shortName or string.upper(item.def.manufacturer or "")

		icons[item.def.shipClass]:Draw(widgetSizes.iconSize)
		ui.nextColumn()
		ui.withStyleVars({ItemSpacing = vZero}, function()
			ui.text(ls[item.def.i18n_key])
			ui.withFont(pionillium.details, function()
				local badge = isUsed and "[USED]" or "[NEW]"
				local badgeCol = isUsed and colors.alertYellow or (colors.econProfit or colors.compareBetter)
				ui.textColored(badgeCol, badge)
				ui.sameLine(nil, 6)
				if isUsed then
					ui.textColored(colors.fontDim, string.format("%s • %d%% • %d mods", mfrTag, item.hullPercent or 90, #(offer.aftermarketItems or {})))
				else
					ui.textColored(colors.fontDim, string.format("%s • Factory", mfrTag))
				end
			end)
			ui.nextColumn()
			ui.dummy(widgetSizes.rowVerticalSpacing)
			ui.text(Format.Money(offer.price, false))
			ui.nextColumn()
			ui.dummy(widgetSizes.rowVerticalSpacing)
			ui.text(item.def.cargo.." cu")
			ui.nextColumn()
		end)
	end,
	onClickItem = function(_,e)
		selectedItem = e
		shipMarket.selectedItem = e
		refreshModelSpinner()
	end,
})

StationView:registerView({
	id = "shipMarketView",
	name = l.SHIP_MARKET,
	icon = ui.theme.icons.ship,
	securityMode = "encryption",
	showView = true,
	draw = function()
		drawDealershipHeader()
		local region = ui.getContentRegion()
		local leftWidth = math.floor(region.x * 0.45)

		ui.child("ShipMarketLeftPane", Vector2(leftWidth, region.y), ui.WindowFlags { 'NoScrollbar', 'NoScrollWithMouse' }, nil, function()
			local newId, newDir, changed = SortBar.draw("ShipMarketSort", SHIP_SORT_KEYS, sortId, sortDir)
			if changed then
				sortId = newId
				sortDir = newDir
				applyFilter()
			end
			ui.spacing()
			shipMarket.style.size = Vector2(ui.getContentRegion().x, math.max(100, ui.getContentRegion().y))

			ui.withFont(pionillium.body, function()
				shipMarket:render()
			end)
		end)

		ui.sameLine(0, widgetSizes.itemSpacing.x)
		tradeMenu()
	end,
	refresh = function()
		filterMode = "ALL"
		refreshShipMarket()
		shipMarket.scrollReset = true
	end,
	debugReload = function()
		package.reimport()
	end
})

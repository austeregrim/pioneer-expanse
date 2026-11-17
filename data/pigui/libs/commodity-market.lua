-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game = require 'Game'
local Lang = require 'Lang'
local Format = require 'Format'
local Commodities = require 'Commodities'
local Economy     = require 'Economy'
local PlayerState = require 'PlayerState'

local ui = require 'pigui'
local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local PiImage = require 'pigui.libs.image'

local ModalWindow = require 'pigui.libs.modal-win'
local TableWidget = require 'pigui.libs.table'
local EconView = require 'pigui.modules.system-econ-view'

local l = Lang.GetResource("ui-core")

local Vector2 = _G.Vector2
local Color = _G.Color

local baseWidgetSizes = {
	rescaleVector = Vector2(1, 1),
	buySellSize = Vector2(160, 36),
	fontSizeLarge = 22.5, -- pionillium.large.size,
	fontSizeXLarge = 27, -- pionillium.xlarge.size,
	iconSize = Vector2(0, 22.5 * 1.5),
	smallButton = Vector2(80, 44),
	bigButton = Vector2(100, 44),
	confirmButtonSize = Vector2(384, 48),
	windowGutter = 16
}

local commodityIconSize = Vector2(24.0, 20.0)

local vZero = Vector2(0, 0)
local textColorDefault = Color(255, 255, 255)
local textColorWarning = Color(255, 255, 0)
local textColorError = Color(255, 0, 0)

local colorVariant = {
	[true] = ui.theme.buttonColors.selected,
	[false] = ui.theme.buttonColors.default
}

local function get_pricemod(itemType, price)
	return (price / itemType.price - 1) * 100
end

local function getCrisisCommodityMultiplier(commodityName, isBuy)
	if not Game.system or not Game.system.name then return 1.0, nil end
	local okMacro, MacroEngine = pcall(require, 'modules.MacroGalaxy.MacroGalaxyEngine')
	if not okMacro or not MacroEngine then return 1.0, nil end
	local crisis = MacroEngine.GetCrisisForSystem(Game.system.name)
	if not crisis then return 1.0, nil end

	local cType = crisis.type
	local sev = crisis.severity or 1
	local isRes = (sev >= 3)
	local cName = string.upper(commodityName or "")

	if cType == "TARIFF_WAR" then
		if cName:find("MACHINERY") or cName:find("COMPUTER") or cName:find("ROBOT") or cName:find("CONSUMER") or cName:find("PLASTIC") then
			local tariffMult = (sev >= 2) and 1.40 or 1.25
			local note = string.format("CUSTOMS TARIFF: +%.0f%% Import Surcharge", (tariffMult - 1.0) * 100)
			return isBuy and tariffMult or (1.0 / tariffMult), note
		end
	elseif cType == "BLOCKADE" then
		if cName:find("WEAPON") or cName:find("MEDICINE") or cName:find("GRAIN") or cName:find("MEAT") or cName:find("AIR") or cName:find("FUEL") then
			local mult = (sev >= 2) and 2.10 or 1.65
			local note = string.format("BLOCKADE SHORTAGE: +%.0f%% Runner Relief Premium", (mult - 1.0) * 100)
			return mult, note
		end
	elseif cType == "SUPPLY_GLUT" then
		if cName:find("ORE") or cName:find("METAL") or cName:find("ALLOY") or cName:find("MINERAL") then
			local mult = isRes and 0.85 or 0.45
			local note = "SUPPLY OVERHANG: -55% Smelting Glut Spot Crash"
			return mult, note
		end
	elseif cType == "OUTBREAK" then
		if cName:find("MEDICINE") or cName:find("AIR") or cName:find("WATER") then
			local mult = isRes and 0.80 or (1.80 + sev * 0.40)
			local note = string.format("OUTBREAK EPIDEMIC: +%.0f%% Vaccine & Medical Premium", (mult - 1.0) * 100)
			return mult, note
		end
	elseif cType == "FAMINE" then
		if cName:find("GRAIN") or cName:find("MEAT") or cName:find("FRUIT") or cName:find("FERTILIZER") or cName:find("ANIMAL") then
			local mult = isRes and 0.85 or (1.80 + sev * 0.40)
			local note = string.format("FAMINE RELIEF: +%.0f%% Emergency Caloric Subsidy", (mult - 1.0) * 100)
			return mult, note
		end
	elseif cType == "MINERAL_RUSH" then
		if cName:find("MINING_MACHINERY") or cName:find("PRECIOUS_METALS") then
			local mult = isRes and 0.70 or (1.50 + sev * 0.30)
			local note = string.format("MINERAL RUSH: +%.0f%% Extraction Speculation Surge", (mult - 1.0) * 100)
			return mult, note
		end
	end

	return 1.0, nil
end

local CommodityMarketWidget = {}

function CommodityMarketWidget.New(id, title, config)
	config = config or {}
	config.style = config.style or {}
	config.style.size = config.style.size or Vector2(0,0)
	config.itemTypes = config.itemTypes or { Commodities }
	config.columnCount = config.columnCount or 6

	config.initTable = config.initTable or function(self)
		local scrollbarPad = 16
		local tableW = self.style.size.x - scrollbarPad
		local col0W = math.floor(commodityIconSize.x + 8)
		local col2W = 100
		local col3W = 100
		local col4W = 75
		local col5W = 85
		local col6W = 1
		local col1W = math.max(120, tableW - (col0W + col2W + col3W + col4W + col5W + col6W))

		ui.setColumnWidth(0, col0W)
		ui.setColumnWidth(1, col1W)
		ui.setColumnWidth(2, col2W)
		ui.setColumnWidth(3, col3W)
		ui.setColumnWidth(4, col4W)
		ui.setColumnWidth(5, col5W)
		ui.setColumnWidth(6, col6W)
	end

	-- Adds a text column to the UI table with the given alignment
	--  - txt - the text to display
	--  - align - the horizontal alignment the text should have:
	--          - "LEFT" (default if not specified)
	--          - "MIDDLE", useful for table heading row
	--          - "RIGHT", best for numbers
	config.columnText = config.columnText or function(txt, align)
		local posX = 0
		txt = txt or ''
		align = align or "LEFT"

		if align == "RIGHT" then
			posX = ui.getColumnWidth() - ui.calcTextSize(txt).x - ui.getItemSpacing().x
		elseif align == "MIDDLE" then
			posX = (ui.getColumnWidth() - ui.calcTextSize(txt).x - ui.getItemSpacing().x) / 2
		else -- default alignment is "LEFT"
			-- no need to adjust the position
		end
		ui.addCursorPos(Vector2(posX, 0))
		ui.text(txt)
		ui.nextColumn()
	end

	config.renderHeaderRow = config.renderHeaderRow or function(_)
		config.columnText('')
		config.columnText(l.COMMODITY, "MIDDLE")
		config.columnText(l.BUY_PRICE, "MIDDLE")
		config.columnText(l.SELL_PRICE, "MIDDLE")
		config.columnText(l.IN_STOCK, "MIDDLE")
		config.columnText(l.IN_HOLD, "MIDDLE")
	end

	config.renderItem = config.renderItem or function(self, item)
		if(self.icons[item.icon_name] == nil) then
			self.icons[item.icon_name] = PiImage.New("icons/goods/".. item.icon_name ..".png")
		end
		self.icons[item.icon_name]:Draw(commodityIconSize)
		ui.nextColumn()

		ui.withStyleVars({ItemSpacing = (self.style.itemSpacing / 2)}, function()
			local market = self.station:GetCommodityMarket()
			local pricemod = Economy.GetCommodityPriceMod(self.station.path, item.name, market)

			ui.text(item:GetProperName())

			local cls = EconView.ClassifyPrice(pricemod)

			if cls then
				ui.sameLine()
				ui.addCursorPos(Vector2(ui.getContentRegion().x - ui.getTextLineHeightWithSpacing(), 0))

				ui.icon(cls[1], Vector2(ui.getTextLineHeight()), cls[2])
				ui.setItemTooltip(string.format("%s (%+.1f%% avg)", cls[3], pricemod))
			end

			ui.nextColumn()

			config.columnText(Format.Money(config.getBuyPrice(self, item)), "RIGHT")
			config.columnText(Format.Money(config.getSellPrice(self, item)), "RIGHT")
			config.columnText(config.getStock(self, item), "RIGHT")
			local n = self.cargoMgr:CountCommodity(item)
			config.columnText(n > 0 and n or '', "RIGHT")
		end)
	end

	config.canDisplayItem = config.canDisplayItem or function (self, commodity)
		return commodity.purchasable and Game.system:IsCommodityLegal(commodity.name)
	end
	config.borders = true

	-- how much of this item do we have in stock?
    config.getStock = config.getStock or function (self, commodity)
        return self.station:GetCommodityStock(commodity)
    end

    -- what do we charge for this item if we are buying
    config.getBuyPrice = config.getBuyPrice or function (self, commodity)
		local price = self.station:GetCommodityPrice(commodity)
		local baseCost = price * (1.0 + math.sign(price) * Economy.TradeFeeSplit * 0.01)
		local mult = getCrisisCommodityMultiplier(commodity.name, true)
		return math.floor(baseCost * mult * 100) / 100
    end

    -- what do we get for this item if we are selling
    config.getSellPrice = config.getSellPrice or function (self, commodity)
        local price = self.station:GetCommodityPrice(commodity)
		local baseCost = price * (1.0 - math.sign(price) * Economy.TradeFeeSplit * 0.01)
		local mult = getCrisisCommodityMultiplier(commodity.name, false)
		return math.floor(baseCost * mult * 100) / 100
    end

	config.onClickBuy = config.onClickBuy or function(self, commodity) return true end
	config.onClickSell = config.onClickSell or function(self, commodity) return true end

	config.bought = config.bought or function (self, commodity, tradeamount)
		local count = tradeamount or 1
        self.station:AddCommodityStock(commodity, -count)
    end

    config.sold = config.sold or function (self, commodity, tradeamount)
		local count = tradeamount or 1
        self.station:AddCommodityStock(commodity, count)
    end

	config.onClickItem = config.onClickItem or function(s,e,_)
		s.selectedItem = e
		s.tradeModeBuy = true
		s:ChangeTradeAmount(-s.tradeAmount)
		s:Refresh()
	end

	config.sortingFunction = config.sortingFunction or function (c1, c2)
		return c1:GetName() < c2:GetName()
	end

	local self = TableWidget.New(id, title, config)

	self.popup = config.popup or ModalWindow.New('popupMsg' .. id, function()
        ui.text(self.popup.msg)
        ui.dummy(Vector2((ui.getContentRegion().x - 100) / 2, 0))
        ui.sameLine()
        if ui.button("OK", Vector2(100, 0)) then
            self.popup:close()
        end
    end)

	self.icons = {}
	self.tradeModeBuy = true
	self.selectedItem = nil
	self.tradeAmount = 0
	self.tradeText = ''
	self.textColorDefault = Color(255, 255, 255)
	self.textColorWarning = Color(255, 255, 0)
	self.textColorError = Color(255, 0, 0)
	self.tradeTextColor = textColorDefault

	self.cargoMgr = nil
	self.station = nil

	self.funcs.getStock = config.getStock
	self.funcs.getBuyPrice = config.getBuyPrice
	self.funcs.getSellPrice = config.getSellPrice
	self.funcs.onClickBuy = config.onClickBuy
	self.funcs.onClickSell = config.onClickSell
	self.funcs.bought = config.bought
	self.funcs.sold = config.sold

	self.style.defaults = {
		itemSpacing = self.itemSpacing
	}

	setmetatable(self, {
		__index = CommodityMarketWidget,
		class = "UI.CommodityMarketWidget",
	})

	self:SetSize(self.style.size)
	return self
end

function CommodityMarketWidget:ChangeTradeAmount(delta)
	if self.selectedItem == nil then
		return
	end

	--get price of commodity after applying local effects of import/export modifiers
	local price = 0

	--do you have any money?
	local playerCash = PlayerState.GetMoney()

	--blank value, needs to be initialized or later on lua will complain
	local stock

	if self.tradeModeBuy then
		price = self.funcs.getBuyPrice(self, self.selectedItem)
		stock = self.funcs.getStock(self, self.selectedItem)

		if stock == 0 then
			self.tradeText = l.NONE_FOR_SALE_IN_THIS_STATION
			self.tradeTextColor = textColorError
			return
		end

		if price > playerCash then
			self.tradeText = l.INSUFFICIENT_FUNDS
			self.tradeTextColor = textColorWarning
			return
		end
	else
		price = self.funcs.getSellPrice(self, self.selectedItem)
		stock = self.cargoMgr:CountCommodity(self.selectedItem)
	end

	--we cant trade more units than we have in stock
	--we dont trade in negative quantities
	local wantamount = math.clamp(self.tradeAmount + delta, 0, stock)

	--how much would the desired amount of merchandise cost?
	local tradecost = wantamount * price

	--another empty initialized
	self.tradeText = ''
	if self.tradeModeBuy then
		-- TODO: use a volume-based metric rather than a mass-based metric
		local playerfreecargo = self.cargoMgr:GetFreeSpace()

		if tradecost > playerCash then
			wantamount =  math.min(wantamount, math.floor(playerCash / price))
		end

		local tradecargo = (self.selectedItem.mass or 1) * wantamount
		if playerfreecargo < tradecargo then
			wantamount = math.min(wantamount, math.floor(playerfreecargo / self.selectedItem.mass))
		end
		self.tradeText = l.MARKET_BUYLINE
	else --mode = sell
		--if market price is negative make sure player wont go below zero credits after the deal
		if (playerCash + tradecost) < 0 then
			wantamount = self.tradeAmount --kludge, ignore the delta unless player has finances to cover the deal
			--if player starts at 0 quantity, presses +100 to "sell" radioactives but only has
			--enough credits to sell 5, this kludge will ignore the +100 completely
			--todo: change amount to 5 instead
		end

		self.tradeText = l.MARKET_SELLINE
	end
	--wantamount is now checked and modified to a safe bounded amount
	self.tradeAmount = wantamount

	--current cost of market order if user confirms the deal
	tradecost = self.tradeAmount * price

	--its possible to get to this line without tradetext being initialized unless done 30 rows up
	self.tradeText = string.interp(self.tradeText,{ amount = string.format("%d", self.tradeAmount), price = Format.Money(tradecost)})
	self.tradeTextColor = self.textColorDefault
end

-- Player confirmed purchase order
function CommodityMarketWidget:DoBuy(customQty)
	local qty = customQty or self.tradeAmount
	if qty <= 0 then return end
	local price = self.funcs.getBuyPrice(self, self.selectedItem)
	local stock = self.funcs.getStock(self, self.selectedItem)
	local playerfreecargo = self.cargoMgr:GetFreeSpace()
	local orderAmount = price * qty

	if orderAmount > PlayerState.GetMoney() then
		self.popup.msg = l.YOU_NOT_ENOUGH_MONEY
		self.popup:open()
		return
	end

	if qty > stock then
		self.popup.msg = l.ITEM_IS_OUT_OF_STOCK
		self.popup:open()
		return
	end

	local tradecargo = (self.selectedItem.mass or 1) * qty
	if playerfreecargo < tradecargo then
		self.popup.msg = l.SHIP_IS_FULLY_LADEN
		self.popup:open()
		return
	end

	if not self.funcs.onClickBuy(self, self.selectedItem) then
		return
	end

	assert(self.cargoMgr:AddCommodity(self.selectedItem, qty))
	PlayerState.AddMoney(-orderAmount)

	local cName = self.selectedItem.name or tostring(self.selectedItem)
	local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')
	if okTax and TaxAuthority and TaxAuthority.RecordCommodityPurchase then
		TaxAuthority.RecordCommodityPurchase(cName, qty, price)
	end

	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		FlightLog.RecordTransaction({
			category = "TRADE",
			title = string.format("Procured %dt %s (%s)", qty, cName, Format.Money(-orderAmount)),
			amount = -orderAmount,
			details = {
				{ "Commodity Item", cName },
				{ "Order Action", "BUY" },
				{ "Quantity", string.format("%d tons", qty) },
				{ "Unit Price", Format.Money(price) },
				{ "Total Consideration", Format.Money(orderAmount) },
			},
			note = string.format("Purchased %dt %s at %s/ton from starport market.", qty, cName, Format.Money(price))
		})
	end

	self.funcs.bought(self, self.selectedItem, qty)
	self.tradeAmount = 0
	self:Refresh()
end

-- Player confirmed sale order
function CommodityMarketWidget:DoSell(customQty)
	local qty = customQty or self.tradeAmount
	if qty <= 0 then return end
	local owned = self.cargoMgr:CountCommodity(self.selectedItem)
	qty = math.min(qty, owned)
	if qty <= 0 then return end

	local price = self.funcs.getSellPrice(self, self.selectedItem)
	local orderamount = price * qty

	if not self.funcs.onClickSell(self, self.selectedItem) then
		return
	end

	assert(self.cargoMgr:RemoveCommodity(self.selectedItem, qty) == qty)
	PlayerState.AddMoney(orderamount)

	local cName = self.selectedItem.name or tostring(self.selectedItem)
	local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')
	if okTax and TaxAuthority and TaxAuthority.RecordCommoditySale then
		TaxAuthority.RecordCommoditySale(cName, qty, price)
	end

	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		FlightLog.RecordTransaction({
			category = "TRADE",
			title = string.format("Sold %dt %s (+%s)", qty, cName, Format.Money(orderamount)),
			amount = orderamount,
			details = {
				{ "Commodity Item", cName },
				{ "Order Action", "SELL" },
				{ "Quantity", string.format("%d tons", qty) },
				{ "Unit Price", Format.Money(price) },
				{ "Gross Sale Proceeds", Format.Money(orderamount) },
			},
			note = string.format("Sold %dt %s at %s/ton to starport market.", qty, cName, Format.Money(price))
		})
	end

	self.funcs.sold(self, self.selectedItem, qty)
	self.tradeAmount = 0
	self:Refresh()
end

function CommodityMarketWidget:TradeMenu()
	local commsChildFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders' }
	if not self.selectedItem then
		ui.child(self.id .. "TradeMenu", vZero, nil, commsChildFlags, function()
			ui.withFont(orbiteer.heading, function()
				ui.textColored(ui.theme.colors.uiPrimaryLight, "COMMODITY TRANSACTION DESK")
			end)
			ui.separator()
			ui.spacing()
			ui.textColored(ui.theme.colors.fontDim, "Select a commodity from the market exchange list to inspect local demand, unit pricing, and execute trade orders.")
		end)
		return
	end

	ui.child(self.id .. "TradeMenu", vZero, nil, commsChildFlags, function()
		local panelW = ui.getContentRegion().x
		local item = self.selectedItem
		local stock = self.funcs.getStock(self, item)
		local owned = self.cargoMgr:CountCommodity(item)
		local buyPrice = self.funcs.getBuyPrice(self, item)
		local sellPrice = self.funcs.getSellPrice(self, item)
		local playerMoney = PlayerState.GetMoney()
		local freeCargo = self.cargoMgr:GetFreeSpace()

		-- 1. Commodity Title Header Row
		if self.icons[item.icon_name] == nil then
			self.icons[item.icon_name] = PiImage.New("icons/goods/" .. item.icon_name .. ".png")
		end

		ui.columns(2, "tradeMenuItemTitle", false)
		ui.setColumnWidth(0, commodityIconSize.x + 12)
		self.icons[item.icon_name]:Draw(commodityIconSize)
		ui.nextColumn()
		ui.withFont(orbiteer.heading, function()
			ui.textColored(ui.theme.colors.uiPrimaryLight, item:GetProperName())
		end)
		ui.columns(1, "", false)
		ui.spacing()

		-- Crisis / Price Trend alerts
		local price = self.station:GetCommodityPrice(item)
		local pricemod = get_pricemod(item, price)
		local cls = EconView.ClassifyPrice(pricemod)
		if cls and self.tradeComputer > 0 then
			ui.textColored(ui.theme.colors.fontDim, l.INTERSTELLAR_TRADE_AVG .. ": ")
			ui.sameLine()
			ui.icon(cls[1], Vector2(ui.getTextLineHeight()), cls[2])
			ui.sameLine()
			ui.textColored(cls[2], string.format("%s (%+.1f%% avg)", cls[3], pricemod))
		end

		local mult, cNote = getCrisisCommodityMultiplier(item.name, true)
		if cNote then
			ui.textColored(ui.theme.colors.alertYellow, cNote)
		end

		ui.spacing()
		ui.withFont(pionillium.body, function()
			ui.textWrapped(item:GetDescription())
		end)

		ui.spacing()
		ui.separator()
		ui.spacing()

		-- 2. Market Inventory & Cargo Summary
		ui.textColored(ui.theme.colors.uiPrimaryLight, "MARKET INVENTORY & CARGO HOLD STATUS:")
		ui.columns(2, "##commStatusCols", false)
		ui.textColored(ui.theme.colors.fontDim, "Station Market Stock:")
		ui.text(string.format("%d tons in stock @ %s / ton", stock, Format.Money(buyPrice)))
		ui.nextColumn()

		ui.textColored(ui.theme.colors.fontDim, "In Your Cargo Hold:")
		if owned > 0 then
			local totalVal = owned * sellPrice
			ui.textColored(ui.theme.colors.econProfit, string.format("%d tons owned (@ %s = %s)", owned, Format.Money(sellPrice), Format.Money(totalVal)))
		else
			ui.textColored(ui.theme.colors.fontDim, string.format("0 tons (Hold Free: %d tons)", freeCargo))
		end
		ui.columns(1)

		ui.spacing()
		ui.separator()
		ui.spacing()

		-- 3. Dedicated Owned Cargo Liquidation (Quick Sell)
		if owned > 0 then
			ui.textColored(Color(255, 170, 50, 255), "OWNED CARGO LIQUIDATION:")
			ui.textColored(ui.theme.colors.fontDim, "Instant liquidation of cargo currently loaded in your vessel's hold:")

			local qSellBtns = {
				{ frac = 0.25, label = "25%" },
				{ frac = 0.50, label = "50%" },
				{ frac = 1.00, label = string.format("SELL ALL (%d TONS)", owned) },
			}
			local qSp = 6
			local qW = math.floor((panelW - (#qSellBtns - 1) * qSp) / #qSellBtns)
			for i, sb in ipairs(qSellBtns) do
				local sQty = math.max(1, math.floor(owned * sb.frac + 0.0001))
				if sb.frac >= 0.99 then sQty = owned end
				local sProceeds = sQty * sellPrice
				local bLabel = string.format("%s (%s)##qSell%d", sb.label, Format.Money(sProceeds), i)
				if ui.button(bLabel, Vector2(qW, 28)) then
					self:DoSell(sQty)
				end
				if i < #qSellBtns then ui.sameLine(nil, qSp) end
			end
			ui.newLine()
			ui.spacing()
			ui.separator()
			ui.spacing()
		end

		-- 4. Order Quantity Counter
		ui.textColored(ui.theme.colors.uiPrimaryLight, "CUSTOM TRANSACTION ORDER DESK:")
		local maxBuy = math.max(0, math.min(stock, freeCargo, buyPrice > 0 and math.floor(playerMoney / buyPrice) or stock))
		local maxLimit = math.max(maxBuy, owned)
		if maxLimit <= 0 then maxLimit = 1 end

		local qSp = 6
		local qNudge = { -100, -10, -1, 0, 1, 10, 100 }
		local qBtnW = math.floor((panelW - (#qNudge - 1) * qSp) / #qNudge)
		for i, nVal in ipairs(qNudge) do
			if nVal == 0 then
				if ui.button(l.RESET .. "##CommReset", Vector2(qBtnW, 26)) then
					self.tradeAmount = 0
				end
			else
				local signStr = nVal > 0 and "+" or ""
				if ui.button(signStr .. tostring(nVal) .. "##CommNudge", Vector2(qBtnW, 26)) then
					self.tradeAmount = math.clamp(self.tradeAmount + nVal, 0, maxLimit)
				end
			end
			if i < #qNudge then ui.sameLine(nil, qSp) end
		end
		ui.newLine()

		ui.spacing()
		local buyTotal = self.tradeAmount * buyPrice
		local sellTotal = self.tradeAmount * sellPrice
		ui.text(string.format("Order Quantity: %d tons  |  Purchase Cost: %s  |  Sale Proceeds: %s",
			self.tradeAmount, Format.Money(buyTotal), Format.Money(sellTotal)))
		ui.spacing()

		-- 5. Direct Action Buttons
		if owned > 0 then
			local actW = math.floor((panelW - 12) / 2)
			local canBuy = (self.tradeAmount > 0 and self.tradeAmount <= maxBuy and buyTotal <= playerMoney)
			local buyText = string.format("BUY %d TONS (%s)##DoBuyBtn", self.tradeAmount, Format.Money(buyTotal))
			if not canBuy and self.tradeAmount > 0 then
				if buyTotal > playerMoney then buyText = "INSUFFICIENT FUNDS"
				elseif self.tradeAmount > freeCargo then buyText = "HOLD FULL"
				elseif self.tradeAmount > stock then buyText = "OUT OF STOCK" end
			end

			if ui.button(buyText, Vector2(actW, 36)) then
				if canBuy then self:DoBuy(self.tradeAmount) end
			end
			ui.sameLine(nil, 12)

			local canSell = (self.tradeAmount > 0 and self.tradeAmount <= owned)
			local sellText = string.format("SELL %d TONS (%s)##DoSellBtn", self.tradeAmount, Format.Money(sellTotal))
			if not canSell and self.tradeAmount > 0 then
				sellText = "EXCEEDS HOLD QUANTITY"
			end
			if ui.button(sellText, Vector2(actW, 36)) then
				if canSell then self:DoSell(self.tradeAmount) end
			end
		else
			local canBuy = (self.tradeAmount > 0 and self.tradeAmount <= maxBuy and buyTotal <= playerMoney)
			local buyText = string.format("BUY %d TONS (%s)##DoBuyBtn", self.tradeAmount, Format.Money(buyTotal))
			if self.tradeAmount == 0 then
				buyText = "SELECT QUANTITY ABOVE TO PURCHASE"
			elseif not canBuy then
				if buyTotal > playerMoney then buyText = "INSUFFICIENT FUNDS"
				elseif self.tradeAmount > freeCargo then buyText = "CARGO HOLD FULL"
				elseif self.tradeAmount > stock then buyText = "STATION OUT OF STOCK" end
			end

			if ui.button(buyText, Vector2(panelW, 36)) then
				if canBuy then self:DoBuy(self.tradeAmount) end
			end
		end
	end)
end

function CommodityMarketWidget:SetSize(size)
	size = Vector2(math.max(size.x, 100), math.max(size.y, 100))
	if self.style.widgetSize ~= size then
		self.style.widgetSize = size
		self.style.size = Vector2(math.floor(size.x * 0.45), size.y)

		self.style.widgetSizes = ui.rescaleUI(
			baseWidgetSizes,
			Vector2(1592, 654), --Size the Commodity Market was scaled to during design
			true,
			size
		)

		self.itemSpacing = ui.rescaleUI(
			self.style.defaults.itemSpacing,
			Vector2(1592, 654), --Size the Commodity Market was scaled to during design
			true,
			size
		)
	end
end

function CommodityMarketWidget:Refresh()
	self.items = {}

	for k, comm in pairs(Commodities) do
		if self.funcs.canDisplayItem(self, comm) then
			table.insert(self.items, comm)
		end
	end

	table.sort(self.items, self.funcs.sortingFunction)

	---@type CargoManager
	self.cargoMgr = Game.player:GetComponent('CargoManager')
	self.station = Game.player:GetDockedWith()
	self.tradeComputer = Game.player["trade_computer_cap"] or 0
end

function CommodityMarketWidget:DrawMarketKey()
	ui.withFont(pionillium.details, function()
		local iconSize = Vector2(ui.getTextLineHeight())
		ui.textColored(ui.theme.colors.fontDim, "MARKET DEMAND KEY:")
		ui.sameLine(0, 10)

		ui.icon(ui.theme.icons.econ_major_import, iconSize, ui.theme.colors.econMajorImport)
		ui.sameLine(0, 4)
		ui.textColored(ui.theme.colors.econMajorImport, "Major Import (High Demand)")
		ui.setItemTooltip("High Demand: Station critically needs this good; pays premium buy price (+10% or more)")
		ui.sameLine(0, 14)

		ui.icon(ui.theme.icons.econ_minor_import, iconSize, ui.theme.colors.econMinorImport)
		ui.sameLine(0, 4)
		ui.textColored(ui.theme.colors.econMinorImport, "Minor Import (In Demand)")
		ui.setItemTooltip("In Demand: Station consumes this good; above-average buy price (+4% to +10%)")
		ui.sameLine(0, 14)

		ui.icon(ui.theme.icons.econ_minor_export, iconSize, ui.theme.colors.econMinorExport)
		ui.sameLine(0, 4)
		ui.textColored(ui.theme.colors.econMinorExport, "Minor Export (Surplus)")
		ui.setItemTooltip("Surplus / Production: Station produces this good in volume; below-average sale price (-4% to -10%)")
		ui.sameLine(0, 14)

		ui.icon(ui.theme.icons.econ_major_export, iconSize, ui.theme.colors.econMajorExport)
		ui.sameLine(0, 4)
		ui.textColored(ui.theme.colors.econMajorExport, "Major Export (High Production)")
		ui.setItemTooltip("High Production: Station primary export output; discount buy price for haulers (-10% or lower)")
	end)
end

function CommodityMarketWidget:Render(size)
	local fullSize = size or ui.getContentRegion()
	self:DrawMarketKey()
	ui.spacing()

	local remainingHeight = ui.getContentRegion().y
	self:SetSize(Vector2(fullSize.x, remainingHeight))

	ui.withStyleVars({ItemSpacing = self.style.itemSpacing}, function()
		ui.withFont(pionillium.body, function()
			TableWidget.render(self)
		end)
		ui.sameLine(0, self.style.widgetSizes.windowGutter)
		self:TradeMenu()
	end)
end

return CommodityMarketWidget

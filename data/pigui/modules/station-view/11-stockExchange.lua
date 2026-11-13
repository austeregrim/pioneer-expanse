-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui            = require 'pigui'
local StationView   = require 'pigui.views.station-view'
local StockExchange = require 'modules.Economy.StockExchange'
local PlayerState   = require 'PlayerState'
local Game          = require 'Game'
local Format        = require 'Format'

local colors = ui.theme.colors
local icons = ui.theme.icons
local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local Vector2 = _G.Vector2

local currentTab = "MEGACORPS"
local selectedTicker = "SIRIUS"
local tradeCount = 10
local statusMessage = nil
local statusTime = 0
local childFlags = ui.ChildFlags { 'Borders' }

local function formatMoney(val)
	return string.format("%.2f Cr", val)
end

local function drawStockExchange()
	ui.withFont(orbiteer.title, function()
		ui.textColored(colors.uiPrimaryLight, "INTERSTELLAR STOCK & COMMODITY EXCHANGE (ISX)")
	end)
	ui.textColored(colors.fontDim, "Pan-Galactic Equity Clearinghouse & Regional Enterprise Trading Floor")
	ui.separator()
	ui.spacing()

	-- Top Bar Market Indices & Portfolio Header
	local indices = StockExchange.GetFactionIndices()
	ui.group(function()
		for _, idx in ipairs(indices) do
			local chgCol = (idx.change >= 0) and colors.econProfit or colors.econLoss
			local chgSign = (idx.change >= 0) and "+" or ""
			ui.text(string.format("%s: %.2f", idx.ticker, idx.price))
			ui.sameLine()
			ui.textColored(chgCol, string.format("(%s%.2f)", chgSign, idx.change))
			ui.sameLine(nil, 24)
		end
		ui.newLine()
	end)

	ui.spacing()

	-- Financial Summary Pill Bar
	local playerCash = PlayerState.GetMoney()
	local portfolioVal = StockExchange.GetPortfolioNetWorth()
	local profitLoss = StockExchange.GetTotalUnrealizedProfit()
	local plCol = (profitLoss >= 0) and colors.econProfit or colors.econLoss
	local plSign = (profitLoss >= 0) and "+" or ""

	ui.child("##financialSummary", Vector2(ui.getContentRegion().x, 38), function()
		ui.text(string.format("CASH ON HAND: %s", formatMoney(playerCash)))
		ui.sameLine(nil, 32)
		ui.text(string.format("PORTFOLIO VALUE: %s", formatMoney(portfolioVal)))
		ui.sameLine(nil, 32)
		ui.text("UNREALIZED P/L: ")
		ui.sameLine()
		ui.textColored(plCol, string.format("%s%s", plSign, formatMoney(profitLoss)))
		ui.sameLine(nil, 32)
		ui.text(string.format("DIVIDENDS COLLECTED: %s", formatMoney(StockExchange.GetTotalDividends())))
	end)

	ui.separator()
	ui.spacing()

	-- Tab Bar
	ui.group(function()
		local tabs = {
			{ id = "MEGACORPS", label = "GALACTIC MEGACORPORATIONS" },
			{ id = "LOCAL", label = "LOCAL SYSTEM ENTERPRISES" },
			{ id = "PORTFOLIO", label = "MY PORTFOLIO & HOLDINGS" },
		}
		for _, t in ipairs(tabs) do
			local isSel = (currentTab == t.id)
			local tabStyle = isSel and { Button = colors.uiPrimary or colors.white, Text = colors.black } or {}
			ui.withStyleColors(tabStyle, function()
				if ui.button(t.label .. "##Tab", Vector2(230, 32)) then
					currentTab = t.id
				end
			end)
			ui.sameLine(nil, 8)
		end
		ui.newLine()
	end)

	ui.spacing()

	if statusMessage and (ui.getTime() - statusTime < 6.0) then
		ui.textColored(colors.alertYellow, statusMessage)
		ui.spacing()
	end

	-- Tab 1: Galactic Megacorporations
	if currentTab == "MEGACORPS" then
		local megacorps = StockExchange.GetMegacorps()
		local availW = ui.getContentRegion().x
		local leftW = math.floor(availW * 0.58)
		local rightW = availW - leftW - 16

		-- Left list
		ui.child("##megacorpList", Vector2(leftW, -1), nil, childFlags, function()
			ui.columns(4, "##megacorpCols", true)
			ui.text("TICKER") ui.nextColumn()
			ui.text("CONGLOMERATE") ui.nextColumn()
			ui.text("PRICE") ui.nextColumn()
			ui.text("YIELD") ui.nextColumn()
			ui.separator()

			for _, corp in ipairs(megacorps) do
				local isSel = (selectedTicker == corp.ticker)
				if ui.selectable(corp.ticker .. "##row", isSel, { "SpanAllColumns" }) then
					selectedTicker = corp.ticker
				end
				ui.nextColumn()
				ui.text(corp.name) ui.nextColumn()
				ui.text(formatMoney(corp.price)) ui.nextColumn()
				ui.text(string.format("%.1f%%", (corp.dividendYield or 0) * 100)) ui.nextColumn()
			end
			ui.columns(1)
		end)

		ui.sameLine(nil, 16)

		-- Right detail & trade box
		local corp = StockExchange.GetStock(selectedTicker)
		ui.child("##megacorpDetail", Vector2(rightW, -1), nil, childFlags, function()
			if corp then
				ui.withFont(orbiteer.heading, function()
					ui.textColored(colors.uiPrimaryLight, corp.name)
				end)
				ui.textColored(colors.fontDim, string.format("Ticker: %s  |  Sector: %s", corp.ticker, corp.sector or "Industrial"))
				ui.separator()
				ui.spacing()

				ui.textWrapped(corp.description or "Major interstellar conglomerate with extensive commercial operations across multiple sectors.")
				ui.spacing()

				ui.text(string.format("Current Share Price: %s", formatMoney(corp.price)))
				ui.text(string.format("Quarterly Dividend Yield: %.1f%%", (corp.dividendYield or 0) * 100))
				ui.spacing()

				-- Price History Sparkline
				local hist = StockExchange.GetPriceHistory(corp.ticker)
				if hist and #hist > 1 then
					ui.textColored(colors.fontDim, "Recent Price History (Last 10 Macro Cycles):")
					local histStr = ""
					for i, p in ipairs(hist) do
						histStr = histStr .. string.format("%.1f", p) .. ((i < #hist) and " → " or "")
					end
					ui.text(histStr)
					ui.spacing()
				end

				-- Holdings of this stock
				local portfolio = StockExchange.GetPlayerPortfolio()
				local h = portfolio[corp.ticker]
				if h and h.shares > 0 then
					local currentVal = h.shares * corp.price
					local pnl = currentVal - h.totalInvested
					local pnlCol = (pnl >= 0) and colors.econProfit or colors.econLoss
					local pnlSign = (pnl >= 0) and "+" or ""
					ui.separator()
					ui.textColored(colors.uiPrimaryLight, "Your Position:")
					ui.text(string.format("  Owned: %d shares (Avg Buy: %s)", h.shares, formatMoney(h.avgBuyPrice)))
					ui.text(string.format("  Current Value: %s", formatMoney(currentVal)))
					ui.text("  Profit/Loss: ")
					ui.sameLine()
					ui.textColored(pnlCol, string.format("%s%s", pnlSign, formatMoney(pnl)))
					ui.spacing()
				end

				ui.separator()
				ui.text("Order Quantity:")
				local batchSizes = { 1, 10, 100, 1000 }
				for _, sz in ipairs(batchSizes) do
					local isSel = (tradeCount == sz)
					local bStyle = isSel and { Button = colors.uiPrimaryLight, Text = colors.black } or {}
					ui.withStyleColors(bStyle, function()
						if ui.button(tostring(sz) .. "##Batch", Vector2(50, 28)) then
							tradeCount = sz
						end
					end)
					ui.sameLine(nil, 6)
				end
				ui.newLine()
				ui.spacing()

				local totalOrderCost = corp.price * tradeCount
				ui.text(string.format("Total Order Value: %s", formatMoney(totalOrderCost)))
				ui.spacing()

				if ui.button(string.format("BUY %d SHARES##BuyBtn", tradeCount), Vector2(160, 36)) then
					local ok, msg = StockExchange.BuyShares(corp, tradeCount)
					statusMessage = msg
					statusTime = ui.getTime()
				end
				ui.sameLine(nil, 12)
				if h and h.shares > 0 then
					local sellAmount = math.min(h.shares, tradeCount)
					if ui.button(string.format("SELL %d SHARES##SellBtn", sellAmount), Vector2(160, 36)) then
						local ok, msg = StockExchange.SellShares(corp, sellAmount)
						statusMessage = msg
						statusTime = ui.getTime()
					end
				end
			end
		end)

	-- Tab 2: Local System Enterprises
	elseif currentTab == "LOCAL" then
		local sysName = Game.system and Game.system.name or "Sol"
		local localCompanies = StockExchange.GetLocalEnterprises(sysName)
		local availW = ui.getContentRegion().x
		local leftW = math.floor(availW * 0.60)
		local rightW = availW - leftW - 16

		ui.child("##localCompanyList", Vector2(leftW, -1), nil, childFlags, function()
			ui.textColored(colors.uiPrimaryLight, string.format("Local Enterprises in %s System:", string.upper(sysName)))
			ui.separator()
			ui.spacing()

			ui.columns(4, "##localCols", true)
			ui.text("TICKER") ui.nextColumn()
			ui.text("ENTERPRISE") ui.nextColumn()
			ui.text("PRICE") ui.nextColumn()
			ui.text("PARENT CORP") ui.nextColumn()
			ui.separator()

			for _, c in ipairs(localCompanies) do
				local isSel = (selectedTicker == c.ticker)
				if ui.selectable(c.ticker .. "##localRow", isSel, { "SpanAllColumns" }) then
					selectedTicker = c.ticker
				end
				ui.nextColumn()
				ui.text(c.name)
				if c.crisisNote then
					ui.textColored(colors.alertYellow, "  " .. c.crisisNote)
				end
				ui.nextColumn()
				ui.text(formatMoney(c.price)) ui.nextColumn()
				ui.text(c.parent) ui.nextColumn()
			end
			ui.columns(1)
		end)

		ui.sameLine(nil, 16)

		-- Right detail for local stock
		local selectedLocal = nil
		for _, c in ipairs(localCompanies) do
			if c.ticker == selectedTicker then selectedLocal = c; break end
		end
		if not selectedLocal and #localCompanies > 0 then
			selectedLocal = localCompanies[1]
			selectedTicker = selectedLocal.ticker
		end

		ui.child("##localDetail", Vector2(rightW, -1), nil, childFlags, function()
			if selectedLocal then
				ui.withFont(orbiteer.heading, function()
					ui.textColored(colors.uiPrimaryLight, selectedLocal.name)
				end)
				ui.textColored(colors.fontDim, string.format("Ticker: %s  |  Sector: %s", selectedLocal.ticker, selectedLocal.sector))
				ui.textColored(colors.fontDim, string.format("Parent Conglomerate: %s", selectedLocal.parentName))
				ui.separator()
				ui.spacing()

				if selectedLocal.crisisNote then
					ui.textColored(colors.alertYellow, "CRISIS IMPACT ALERT:")
					ui.textWrapped(selectedLocal.crisisNote)
					ui.spacing()
				end

				ui.text(string.format("Local Share Price: %s", formatMoney(selectedLocal.price)))
				ui.spacing()

				-- Holdings
				local portfolio = StockExchange.GetPlayerPortfolio()
				local h = portfolio[selectedLocal.ticker]
				if h and h.shares > 0 then
					local currentVal = h.shares * selectedLocal.price
					local pnl = currentVal - h.totalInvested
					local pnlCol = (pnl >= 0) and colors.econProfit or colors.econLoss
					local pnlSign = (pnl >= 0) and "+" or ""
					ui.separator()
					ui.textColored(colors.uiPrimaryLight, "Your Position:")
					ui.text(string.format("  Owned: %d shares (Avg Buy: %s)", h.shares, formatMoney(h.avgBuyPrice)))
					ui.text(string.format("  Current Value: %s", formatMoney(currentVal)))
					ui.text("  Profit/Loss: ")
					ui.sameLine()
					ui.textColored(pnlCol, string.format("%s%s", pnlSign, formatMoney(pnl)))
					ui.spacing()
				end

				ui.separator()
				ui.text("Order Quantity:")
				local batchSizes = { 1, 10, 100, 1000 }
				for _, sz in ipairs(batchSizes) do
					local isSel = (tradeCount == sz)
					local bStyle = isSel and { Button = colors.uiPrimaryLight, Text = colors.black } or {}
					ui.withStyleColors(bStyle, function()
						if ui.button(tostring(sz) .. "##LocalBatch", Vector2(50, 28)) then tradeCount = sz end
					end)
					ui.sameLine(nil, 6)
				end
				ui.newLine()
				ui.spacing()

				local totalOrderCost = selectedLocal.price * tradeCount
				ui.text(string.format("Total Order Value: %s", formatMoney(totalOrderCost)))
				ui.spacing()

				if ui.button(string.format("BUY %d SHARES##BuyLocalBtn", tradeCount), Vector2(160, 36)) then
					local ok, msg = StockExchange.BuyShares(selectedLocal, tradeCount)
					statusMessage = msg
					statusTime = ui.getTime()
				end
				ui.sameLine(nil, 12)
				if h and h.shares > 0 then
					local sellAmount = math.min(h.shares, tradeCount)
					if ui.button(string.format("SELL %d SHARES##SellLocalBtn", sellAmount), Vector2(160, 36)) then
						local ok, msg = StockExchange.SellShares(selectedLocal, sellAmount)
						statusMessage = msg
						statusTime = ui.getTime()
					end
				end
			end
		end)

	-- Tab 3: Player Portfolio & Holdings
	elseif currentTab == "PORTFOLIO" then
		local portfolio = StockExchange.GetPlayerPortfolio()
		local hasHoldings = false
		for _, _ in pairs(portfolio) do hasHoldings = true; break end

		if not hasHoldings then
			ui.child("##emptyPortfolio", Vector2(-1, -1), nil, childFlags, function()
				ui.textColored(colors.fontDim, "You do not currently own any shares or equity holdings.")
				ui.textWrapped("Browse Galactic Megacorporations or Local System Enterprises to invest your commercial profits.")
			end)
		else
			ui.child("##fullPortfolio", Vector2(-1, -1), nil, childFlags, function()
				ui.columns(7, "##portfolioCols", true)
				ui.text("TICKER") ui.nextColumn()
				ui.text("COMPANY") ui.nextColumn()
				ui.text("SHARES") ui.nextColumn()
				ui.text("AVG BUY") ui.nextColumn()
				ui.text("CURRENT") ui.nextColumn()
				ui.text("VALUE") ui.nextColumn()
				ui.text("PROFIT / LOSS") ui.nextColumn()
				ui.separator()

				for ticker, h in pairs(portfolio) do
					local stock = StockExchange.GetStock(ticker)
					local curPrice = stock and stock.price or h.avgBuyPrice
					local curVal = h.shares * curPrice
					local pnl = curVal - h.totalInvested
					local pnlCol = (pnl >= 0) and colors.econProfit or colors.econLoss
					local pnlSign = (pnl >= 0) and "+" or ""

					ui.text(ticker) ui.nextColumn()
					ui.text(h.name or ticker) ui.nextColumn()
					ui.text(tostring(h.shares)) ui.nextColumn()
					ui.text(formatMoney(h.avgBuyPrice)) ui.nextColumn()
					ui.text(formatMoney(curPrice)) ui.nextColumn()
					ui.text(formatMoney(curVal)) ui.nextColumn()
					ui.textColored(pnlCol, string.format("%s%s", pnlSign, formatMoney(pnl))) ui.nextColumn()
				end
				ui.columns(1)
			end)
		end
	end
end

StationView:registerView({
	id = "stockExchange",
	name = "ISX Stock Exchange",
	icon = icons.money or icons.bbs,
	showView = true,
	draw = drawStockExchange,
	refresh = function(self) end,
	debugReload = function()
		package.reimport()
	end
})


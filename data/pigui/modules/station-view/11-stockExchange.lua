-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui            = require 'pigui'
local StationView   = require 'pigui.views.station-view'
local StockExchange = require 'modules.Economy.StockExchange'
local PlayerState   = require 'PlayerState'
local Game          = require 'Game'
local Color         = _G.Color
local Vector2       = _G.Vector2

local colors = ui.theme.colors
local icons = ui.theme.icons
local orbiteer = ui.fonts.orbiteer

local currentTab = "MEGACORPS"
local selectedTicker = "SIRIUS"
local tradeCount = 1.0
local investCreditAmount = 20.0
local selectedTimeframe = "30D" -- "7D", "14D", "30D", "ALL"
local chartMode = "AREA"        -- "AREA" or "CANDLES"
local statusMessage = nil
local statusTime = 0
local childFlags = ui.ChildFlags { 'Borders' }

local function formatCr(val)
	val = math.floor(val)
	local str = tostring(math.abs(val))
	local formatted = str:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	if val < 0 then formatted = "-" .. formatted end
	return formatted
end

local function formatMoney(val)
	return string.format("%.2f Cr", val)
end

local function formatVol(vol)
	if vol >= 1000000 then
		return string.format("%.2fM", vol / 1000000)
	elseif vol >= 1000 then
		return string.format("%.1fK", vol / 1000)
	else
		return tostring(vol)
	end
end

-- Render mini sparkline trendline for table rows
local function drawMiniSparkline(pos, width, height, history)
	if not history or #history < 2 then
		ui.addLine(Vector2(pos.x, pos.y + height * 0.5), Vector2(pos.x + width, pos.y + height * 0.5), Color(70, 80, 95, 120), 1.0)
		return
	end

	-- Extract last 15-20 data points
	local sliceCount = math.min(#history, 15)
	local minP, maxP = history[#history - sliceCount + 1].close, history[#history - sliceCount + 1].close
	for i = #history - sliceCount + 1, #history do
		local p = history[i].close
		if p < minP then minP = p end
		if p > maxP then maxP = p end
	end
	local rangeP = math.max(1.0, maxP - minP)

	local firstP = history[#history - sliceCount + 1].close
	local lastP = history[#history].close
	local isUp = (lastP >= firstP)
	local lineColor = isUp and Color(65, 235, 140, 230) or Color(255, 95, 95, 230)
	local fillColor = isUp and Color(40, 180, 100, 35) or Color(180, 50, 50, 35)

	-- Subtle sparkline background box
	ui.addRectFilled(pos, Vector2(pos.x + width, pos.y + height), Color(20, 25, 35, 140), 2.0, ui.RoundCornersAll)

	local stepX = width / (sliceCount - 1)
	local prevPt = nil
	for idx = 1, sliceCount do
		local rec = history[#history - sliceCount + idx]
		local normY = 1.0 - ((rec.close - minP) / rangeP)
		local pt = Vector2(pos.x + (idx - 1) * stepX, pos.y + 2 + normY * (height - 4))
		if prevPt then
			ui.addLine(prevPt, pt, lineColor, 1.4)
		end
		prevPt = pt
	end
end

-- Render interactive Bloomberg-grade canvas chart with price curve / candles + volume histogram
local function drawInteractiveStockChart(canvasPos, width, height, history, timeframe, mode)
	-- Determine timeframe window
	local windowCount = #history
	if timeframe == "7D" then windowCount = math.min(7, #history)
	elseif timeframe == "14D" then windowCount = math.min(14, #history)
	elseif timeframe == "30D" then windowCount = math.min(30, #history)
	end
	if windowCount < 2 then
		ui.addRectFilled(canvasPos, Vector2(canvasPos.x + width, canvasPos.y + height), Color(15, 18, 26, 255), 4.0, ui.RoundCornersAll)
		ui.addText(Vector2(canvasPos.x + 20, canvasPos.y + 40), colors.fontDim, "Insufficient market history for selected interval.")
		return
	end

	local startIndex = #history - windowCount + 1
	local minP, maxP = history[startIndex].low, history[startIndex].high
	local maxVol = 1
	for i = startIndex, #history do
		local r = history[i]
		if r.low < minP then minP = r.low end
		if r.high > maxP then maxP = r.high end
		if r.volume > maxVol then maxVol = r.volume end
	end
	local rangeP = math.max(1.0, maxP - minP)

	-- Geometry partitioning:
	-- Price chart: Top 72%
	-- Volume chart: Bottom 25%
	local chartW = width - 75 -- Leave 75px for price axis labels on right
	local priceH = height * 0.70
	local volH = height * 0.23
	local volBaseY = canvasPos.y + height - 12
	local volTopY = volBaseY - volH

	-- Background plate & grid
	ui.addRectFilled(canvasPos, Vector2(canvasPos.x + width, canvasPos.y + height), Color(12, 15, 22, 255), 4.0, ui.RoundCornersAll)
	ui.addRect(canvasPos, Vector2(canvasPos.x + width, canvasPos.y + height), Color(40, 50, 70, 160), 4.0, ui.RoundCornersAll, 1.0)

	-- Price Horizontal Gridlines (4 levels)
	for lvl = 0, 3 do
		local normLvl = lvl / 3.0
		local yLine = canvasPos.y + 12 + normLvl * (priceH - 24)
		local pVal = maxP - normLvl * rangeP
		ui.addLine(Vector2(canvasPos.x, yLine), Vector2(canvasPos.x + chartW, yLine), Color(40, 50, 70, 75), 1.0)
		ui.addText(Vector2(canvasPos.x + chartW + 6, yLine - 6), Color(130, 155, 180, 200), string.format("%.0f Cr", pVal))
	end

	-- Volume separator baseline
	ui.addLine(Vector2(canvasPos.x, volTopY - 4), Vector2(canvasPos.x + chartW, volTopY - 4), Color(50, 65, 90, 120), 1.0)
	ui.addText(Vector2(canvasPos.x + chartW + 6, volTopY - 4), Color(110, 130, 160, 180), formatVol(maxVol))

	local stepX = chartW / math.max(1, (windowCount - 1))
	local barWidth = math.max(2.0, (stepX * 0.65))

	-- 1. Draw Volume Bars
	for i = 1, windowCount do
		local rec = history[startIndex + i - 1]
		local barX = canvasPos.x + (i - 1) * stepX
		local vRatio = math.clamp(rec.volume / maxVol, 0.0, 1.0)
		local barH = vRatio * volH
		local isGreen = (rec.close >= rec.open)
		local vCol = isGreen and Color(65, 225, 130, 160) or Color(245, 80, 80, 160)
		ui.addRectFilled(Vector2(barX - barWidth * 0.5, volBaseY - barH), Vector2(barX + barWidth * 0.5, volBaseY), vCol, 1.0, ui.RoundCornersAll)
	end

	-- 2. Draw Price Representation (Area Curve or Candlestick)
	if mode == "CANDLES" then
		for i = 1, windowCount do
			local rec = history[startIndex + i - 1]
			local barX = canvasPos.x + (i - 1) * stepX
			local isGreen = (rec.close >= rec.open)
			local bodyCol = isGreen and Color(65, 235, 140, 240) or Color(255, 85, 85, 240)

			local yOpen = canvasPos.y + 12 + (1.0 - (rec.open - minP) / rangeP) * (priceH - 24)
			local yClose = canvasPos.y + 12 + (1.0 - (rec.close - minP) / rangeP) * (priceH - 24)
			local yHigh = canvasPos.y + 12 + (1.0 - (rec.high - minP) / rangeP) * (priceH - 24)
			local yLow = canvasPos.y + 12 + (1.0 - (rec.low - minP) / rangeP) * (priceH - 24)

			-- Upper & Lower Wick
			ui.addLine(Vector2(barX, yHigh), Vector2(barX, yLow), bodyCol, 1.2)
			-- Candle Body
			local topY = math.min(yOpen, yClose)
			local botY = math.max(yOpen, yClose)
			if (botY - topY) < 2.0 then botY = topY + 2.0 end
			ui.addRectFilled(Vector2(barX - barWidth * 0.5, topY), Vector2(barX + barWidth * 0.5, botY), bodyCol, 1.0, ui.RoundCornersAll)
		end
	else
		-- Smooth Area Curve with Shaded Fill
		local prevPt = nil
		local isOverallUp = (history[#history].close >= history[startIndex].close)
		local curveColor = isOverallUp and Color(65, 235, 140, 255) or Color(255, 90, 90, 255)

		for i = 1, windowCount do
			local rec = history[startIndex + i - 1]
			local curX = canvasPos.x + (i - 1) * stepX
			local curY = canvasPos.y + 12 + (1.0 - (rec.close - minP) / rangeP) * (priceH - 24)
			local pt = Vector2(curX, curY)

			if prevPt then
				-- Draw line segment
				ui.addLine(prevPt, pt, curveColor, 2.0)
				-- Draw shaded drop column under curve
				local shadeCol = isOverallUp and Color(40, 190, 110, 22) or Color(190, 45, 45, 22)
				ui.addRectFilled(Vector2(prevPt.x, prevPt.y), Vector2(pt.x, volTopY - 4), shadeCol, 0, ui.RoundCornersNone)
			end
			prevPt = pt
		end
	end

	-- 3. Interactive Mouse Hover Crosshair & Tooltip
	local mousePos = ui.getMousePos()
	if mousePos.x >= canvasPos.x and mousePos.x <= (canvasPos.x + chartW) and
	   mousePos.y >= canvasPos.y and mousePos.y <= (canvasPos.y + height) then
		local relX = mousePos.x - canvasPos.x
		local hoverIdx = math.clamp(math.floor((relX / stepX) + 0.5) + 1, 1, windowCount)
		local rec = history[startIndex + hoverIdx - 1]
		local snapX = canvasPos.x + (hoverIdx - 1) * stepX
		local snapY = canvasPos.y + 12 + (1.0 - (rec.close - minP) / rangeP) * (priceH - 24)

		-- Vertical cursor crosshair
		ui.addLine(Vector2(snapX, canvasPos.y), Vector2(snapX, canvasPos.y + height), Color(160, 200, 255, 140), 1.0)
		ui.addCircleFilled(Vector2(snapX, snapY), 4.0, Color(255, 255, 255, 255), 12)
		ui.addCircle(Vector2(snapX, snapY), 6.5, Color(65, 235, 255, 255), 12, 1.5)

		-- Floating Inspection HUD Box
		local hudW, hudH = 175, 78
		local hudX = (snapX + hudW + 16 < canvasPos.x + chartW) and (snapX + 12) or (snapX - hudW - 12)
		local hudY = math.clamp(snapY - 35, canvasPos.y + 8, canvasPos.y + height - hudH - 8)
		ui.addRectFilled(Vector2(hudX, hudY), Vector2(hudX + hudW, hudY + hudH), Color(10, 14, 20, 240), 3.0, ui.RoundCornersAll)
		ui.addRect(Vector2(hudX, hudY), Vector2(hudX + hudW, hudY + hudH), Color(65, 160, 220, 180), 3.0, ui.RoundCornersAll, 1.0)

		ui.addText(Vector2(hudX + 8, hudY + 6), Color(255, 215, 60, 255), string.format("Session Day %d", rec.day or 0))
		ui.addText(Vector2(hudX + 8, hudY + 22), colors.white, string.format("Close: %.2f Cr", rec.close))
		ui.addText(Vector2(hudX + 8, hudY + 38), colors.fontDim, string.format("H: %.1f  L: %.1f", rec.high, rec.low))
		ui.addText(Vector2(hudX + 8, hudY + 54), Color(65, 235, 255, 240), string.format("Vol: %s shares", formatVol(rec.volume)))
	end
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

	ui.child("##financialSummary", Vector2(ui.getContentRegion().x, 38), nil, childFlags, function()
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

	-- Tab 1: Galactic Megacorporations (Super High Value & Fractional Shares)
	if currentTab == "MEGACORPS" then
		local megacorps = StockExchange.GetMegacorps()
		local availW = ui.getContentRegion().x
		local leftW = math.floor(availW * 0.44)
		local rightW = availW - leftW - 16

		-- Left list with mini sparklines
		ui.child("##megacorpList", Vector2(leftW, -1), nil, childFlags, function()
			ui.columns(5, "##megacorpCols", true)
			ui.text("TICKER") ui.nextColumn()
			ui.text("CONGLOMERATE") ui.nextColumn()
			ui.text("TREND (30D)") ui.nextColumn()
			ui.text("PRICE") ui.nextColumn()
			ui.text("24H CHG") ui.nextColumn()
			ui.separator()

			for _, corp in ipairs(megacorps) do
				local isSel = (selectedTicker == corp.ticker)
				if ui.selectable(corp.ticker .. "##row", isSel, { "SpanAllColumns" }) then
					selectedTicker = corp.ticker
				end
				ui.nextColumn()

				ui.text(corp.name)
				ui.nextColumn()

				-- Mini Sparkline Trendline
				local sparkPos = ui.getCursorScreenPos()
				local sparkW, sparkH = 75, 18
				ui.dummy(Vector2(sparkW, sparkH))
				local hist = StockExchange.GetStockHistory(corp.ticker)
				drawMiniSparkline(sparkPos, sparkW, sparkH, hist)
				ui.nextColumn()

				ui.text(formatMoney(corp.price))
				ui.nextColumn()

				local stats = StockExchange.Get24hStats(corp.ticker)
				local chgCol = (stats.changeCr >= 0) and colors.econProfit or colors.econLoss
				local chgSign = (stats.changeCr >= 0) and "+" or ""
				ui.textColored(chgCol, string.format("%s%.1f%%", chgSign, stats.changePct))
				ui.nextColumn()
			end
			ui.columns(1)
		end)

		ui.sameLine(nil, 16)

		-- Right detail & interactive Bloomberg chart
		local corp = StockExchange.GetStock(selectedTicker)
		if not corp and #megacorps > 0 then
			corp = megacorps[1]
			selectedTicker = corp.ticker
		end

		ui.child("##megacorpDetail", Vector2(rightW, -1), nil, childFlags, function()
			if corp then
				local stats = StockExchange.Get24hStats(corp.ticker)
				local chgCol = (stats.changeCr >= 0) and colors.econProfit or colors.econLoss
				local chgSign = (stats.changeCr >= 0) and "+" or ""

				ui.withFont(orbiteer.heading, function()
					ui.textColored(colors.uiPrimaryLight, corp.name)
				end)
				ui.sameLine(rightW - 130)
				ui.textColored(Color(255, 215, 60, 255), "[ MEGACORP ]")

				ui.textColored(colors.fontDim, string.format("Ticker: %s  |  Sector: %s  |  Dividend Yield: %.1f%%",
					corp.ticker, corp.sector or "Industrial", (corp.dividendYield or 0) * 100))
				ui.separator()

				-- Header Price & 24h Stats Row
				ui.text(string.format("Current Price: %s", formatMoney(corp.price)))
				ui.sameLine()
				ui.textColored(chgCol, string.format("(%s%s / %s%.2f%%)", chgSign, formatMoney(stats.changeCr), chgSign, stats.changePct))
				ui.sameLine(nil, 24)
				ui.textColored(colors.fontDim, string.format("24h Vol: %s shares", formatVol(stats.volume24h)))
				ui.sameLine(nil, 20)
				ui.textColored(colors.fontDim, string.format("52W: %s - %s", formatMoney(stats.low52w), formatMoney(stats.high52w)))

				ui.spacing()

				-- Chart Controls (Timeframe & Mode)
				local timeframes = { "7D", "14D", "30D", "ALL" }
				for _, tf in ipairs(timeframes) do
					local isSel = (selectedTimeframe == tf)
					local bStyle = isSel and { Button = colors.uiPrimaryLight, Text = colors.black } or {}
					ui.withStyleColors(bStyle, function()
						if ui.button(tf .. "##Tf", Vector2(48, 22)) then selectedTimeframe = tf end
					end)
					ui.sameLine(nil, 4)
				end

				ui.sameLine(rightW - 165)
				local isArea = (chartMode == "AREA")
				if ui.button((isArea and "MODE: AREA" or "MODE: CANDLES") .. "##ModeBtn", Vector2(145, 22)) then
					chartMode = isArea and "CANDLES" or "AREA"
				end

				ui.spacing()

				-- Main Interactive Financial Chart Canvas
				local chartPos = ui.getCursorScreenPos()
				local chartW = rightW - 24
				local chartH = 200
				ui.dummy(Vector2(chartW, chartH))
				local history = StockExchange.GetStockHistory(corp.ticker)
				drawInteractiveStockChart(chartPos, chartW, chartH, history, selectedTimeframe, chartMode)

				ui.spacing()

				-- Holdings of this stock
				local portfolio = StockExchange.GetPlayerPortfolio()
				local h = portfolio[corp.ticker]
				if h and h.shares > 0 then
					local currentVal = h.shares * corp.price
					local pnl = currentVal - h.totalInvested
					local pnlCol = (pnl >= 0) and colors.econProfit or colors.econLoss
					local pnlSign = (pnl >= 0) and "+" or ""
					ui.separator()
					ui.textColored(colors.uiPrimaryLight, "Your Active Position:")
					ui.text(string.format("  Owned: %.3f shares (Avg Price: %s)", h.shares, formatMoney(h.avgBuyPrice)))
					ui.sameLine(nil, 24)
					ui.text(string.format("Current Value: %s", formatMoney(currentVal)))
					ui.sameLine(nil, 24)
					ui.text("P/L: ")
					ui.sameLine()
					ui.textColored(pnlCol, string.format("%s%s", pnlSign, formatMoney(pnl)))
				end

				ui.separator()
				ui.textColored(Color(65, 235, 255, 255), "CREDIT-BASED FRACTIONAL INVESTING DESK:")
				ui.textColored(colors.fontDim, "Invest any credit amount to purchase exact fractional micro-shares of this megacorp:")

				-- Credit Amount Presets
				local creditPresets = { 20, 50, 100, 250, 500, 1000, 5000, 25000 }
				for _, cp in ipairs(creditPresets) do
					local isSel = (math.abs(investCreditAmount - cp) < 0.5)
					local bStyle = isSel and { Button = colors.uiPrimaryLight, Text = colors.black } or {}
					ui.withStyleColors(bStyle, function()
						if ui.button(formatCr(cp) .. " Cr##CValBtn", Vector2(72, 26)) then
							investCreditAmount = cp
						end
					end)
					ui.sameLine(nil, 6)
				end
				ui.newLine()

				-- Slider & Fine Adjustment Nudge Buttons
				ui.nextItemWidth(200)
				local newAmt, amtChanged = ui.sliderFloat("##InvestCreditsSlider", investCreditAmount, 5.0, 50000.0, "%.0f Cr")
				if amtChanged then investCreditAmount = math.floor(newAmt * 100) / 100 end
				ui.sameLine(nil, 6)
				if ui.button("-50##N50", Vector2(36, 22)) then investCreditAmount = math.max(5.0, investCreditAmount - 50.0) end
				ui.sameLine(nil, 4)
				if ui.button("-10##N10", Vector2(34, 22)) then investCreditAmount = math.max(5.0, investCreditAmount - 10.0) end
				ui.sameLine(nil, 4)
				if ui.button("+10##N10P", Vector2(34, 22)) then investCreditAmount = investCreditAmount + 10.0 end
				ui.sameLine(nil, 4)
				if ui.button("+50##N50P", Vector2(36, 22)) then investCreditAmount = investCreditAmount + 50.0 end
				ui.sameLine(nil, 4)
				if ui.button("+500##N500P", Vector2(44, 22)) then investCreditAmount = investCreditAmount + 500.0 end

				ui.spacing()

				local calcShares = investCreditAmount / corp.price
				local shareCalcStr
				if calcShares < 0.001 then
					shareCalcStr = string.format("%.6f", calcShares)
				elseif calcShares < 0.1 then
					shareCalcStr = string.format("%.4f", calcShares)
				else
					shareCalcStr = string.format("%.3f", calcShares)
				end

				ui.text(string.format("Order: %s buys %s fractional shares (@ %s/share)",
					formatMoney(investCreditAmount), shareCalcStr, formatMoney(corp.price)))
				ui.spacing()

				local buyLabel = string.format("BUY %s OF %s (%s SHARES)##BuyCreditBtn",
					formatMoney(investCreditAmount), corp.ticker, shareCalcStr)
				if ui.button(buyLabel, Vector2(math.min(rightW - 24, 380), 34)) then
					local ok, msg = StockExchange.BuySharesByCredits(corp, investCreditAmount)
					statusMessage = msg
					statusTime = ui.getTime()
				end

				if h and h.shares > 0 then
					local positionVal = h.shares * corp.price
					local sellCredit = math.min(positionVal, investCreditAmount)
					local sellShares = math.min(h.shares, sellCredit / corp.price)
					local sellShareStr = (sellShares < 0.001) and string.format("%.6f", sellShares) or string.format("%.4f", sellShares)

					ui.sameLine(nil, 12)
					local sellLabel = string.format("LIQUIDATE %s (%s SHARES)##SellCreditBtn",
						formatMoney(sellCredit), sellShareStr)
					if ui.button(sellLabel, Vector2(math.min(rightW - 24, 380), 34)) then
						local ok, msg = StockExchange.SellSharesByCredits(corp, sellCredit)
						statusMessage = msg
						statusTime = ui.getTime()
					end

					-- Quick percentage liquidation bar
					ui.spacing()
					ui.textColored(colors.fontDim, "Quick Position Liquidation:")
					ui.sameLine()
					local pctButtons = { { 0.25, "25%" }, { 0.50, "50%" }, { 0.75, "75%" }, { 1.00, "100% (ALL)" } }
					for _, pb in ipairs(pctButtons) do
						local pFrac, pName = pb[1], pb[2]
						if ui.button(pName .. "##SellPct", Vector2(75, 24)) then
							local sellQty = h.shares * pFrac
							local ok, msg = StockExchange.SellShares(corp, sellQty)
							statusMessage = msg
							statusTime = ui.getTime()
						end
						ui.sameLine(nil, 6)
					end
					ui.newLine()
				end
			end
		end)

	-- Tab 2: Local System Enterprises (Whole Shares Only, Lower Values)
	elseif currentTab == "LOCAL" then
		local sysName = Game.system and Game.system.name or "Sol"
		local localCompanies = StockExchange.GetLocalEnterprises(sysName)
		local availW = ui.getContentRegion().x
		local leftW = math.floor(availW * 0.44)
		local rightW = availW - leftW - 16

		ui.child("##localCompanyList", Vector2(leftW, -1), nil, childFlags, function()
			ui.textColored(colors.uiPrimaryLight, string.format("Local Enterprises in %s System:", string.upper(sysName)))
			ui.separator()

			ui.columns(5, "##localCols", true)
			ui.text("TICKER") ui.nextColumn()
			ui.text("ENTERPRISE") ui.nextColumn()
			ui.text("TREND (30D)") ui.nextColumn()
			ui.text("PRICE") ui.nextColumn()
			ui.text("PARENT") ui.nextColumn()
			ui.separator()

			for _, c in ipairs(localCompanies) do
				local isSel = (selectedTicker == c.ticker)
				if ui.selectable(c.ticker .. "##localRow", isSel, { "SpanAllColumns" }) then
					selectedTicker = c.ticker
				end
				ui.nextColumn()

				ui.text(c.name)
				if c.crisisNote then
					ui.textColored(colors.alertYellow, " " .. c.crisisNote)
				end
				ui.nextColumn()

				-- Sparkline
				local sparkPos = ui.getCursorScreenPos()
				local sparkW, sparkH = 75, 18
				ui.dummy(Vector2(sparkW, sparkH))
				local hist = StockExchange.GetStockHistory(c.ticker)
				drawMiniSparkline(sparkPos, sparkW, sparkH, hist)
				ui.nextColumn()

				ui.text(formatMoney(c.price))
				ui.nextColumn()

				ui.text(c.parent)
				ui.nextColumn()
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
				local stats = StockExchange.Get24hStats(selectedLocal.ticker)
				local chgCol = (stats.changeCr >= 0) and colors.econProfit or colors.econLoss
				local chgSign = (stats.changeCr >= 0) and "+" or ""

				ui.withFont(orbiteer.heading, function()
					ui.textColored(colors.uiPrimaryLight, selectedLocal.name)
				end)
				ui.sameLine(rightW - 145)
				ui.textColored(Color(120, 240, 160, 255), "[ WHOLE SHARE ]")

				ui.textColored(colors.fontDim, string.format("Ticker: %s  |  Sector: %s  |  Parent: %s",
					selectedLocal.ticker, selectedLocal.sector, selectedLocal.parentName))
				ui.separator()

				if selectedLocal.crisisNote then
					ui.textColored(colors.alertYellow, "CRISIS IMPACT ALERT: " .. selectedLocal.crisisNote)
				end

				-- Header Price & 24h Stats Row
				ui.text(string.format("Current Price: %s", formatMoney(selectedLocal.price)))
				ui.sameLine()
				ui.textColored(chgCol, string.format("(%s%s / %s%.2f%%)", chgSign, formatMoney(stats.changeCr), chgSign, stats.changePct))
				ui.sameLine(nil, 24)
				ui.textColored(colors.fontDim, string.format("24h Vol: %s shares", formatVol(stats.volume24h)))

				ui.spacing()

				-- Chart Controls (Timeframe & Mode)
				local timeframes = { "7D", "14D", "30D", "ALL" }
				for _, tf in ipairs(timeframes) do
					local isSel = (selectedTimeframe == tf)
					local bStyle = isSel and { Button = colors.uiPrimaryLight, Text = colors.black } or {}
					ui.withStyleColors(bStyle, function()
						if ui.button(tf .. "##LocalTf", Vector2(48, 22)) then selectedTimeframe = tf end
					end)
					ui.sameLine(nil, 4)
				end

				ui.sameLine(rightW - 165)
				local isArea = (chartMode == "AREA")
				if ui.button((isArea and "MODE: AREA" or "MODE: CANDLES") .. "##LocalModeBtn", Vector2(145, 22)) then
					chartMode = isArea and "CANDLES" or "AREA"
				end

				ui.spacing()

				-- Main Interactive Financial Chart Canvas
				local chartPos = ui.getCursorScreenPos()
				local chartW = rightW - 24
				local chartH = 200
				ui.dummy(Vector2(chartW, chartH))
				local history = StockExchange.GetStockHistory(selectedLocal.ticker)
				drawInteractiveStockChart(chartPos, chartW, chartH, history, selectedTimeframe, chartMode)

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
					ui.textColored(colors.uiPrimaryLight, "Your Active Position:")
					ui.text(string.format("  Owned: %d shares (Avg Price: %s)", math.floor(h.shares), formatMoney(h.avgBuyPrice)))
					ui.sameLine(nil, 24)
					ui.text(string.format("Current Value: %s", formatMoney(currentVal)))
					ui.sameLine(nil, 24)
					ui.text("P/L: ")
					ui.sameLine()
					ui.textColored(pnlCol, string.format("%s%s", pnlSign, formatMoney(pnl)))
				end

				ui.separator()
				ui.textColored(Color(255, 215, 60, 255), "WHOLE SHARE TRANSACTION DESK:")
				ui.textColored(colors.fontDim, "Local system enterprise shares must be transacted in whole integer units (minimum 1 share):")

				-- Whole Share Presets
				local localPresets = { 1, 5, 10, 50, 100, 500 }
				for _, sz in ipairs(localPresets) do
					local isSel = (math.floor(tradeCount) == sz)
					local bStyle = isSel and { Button = colors.uiPrimaryLight, Text = colors.black } or {}
					ui.withStyleColors(bStyle, function()
						if ui.button(tostring(sz) .. "##LocalBatch", Vector2(50, 26)) then tradeCount = sz end
					end)
					ui.sameLine(nil, 6)
				end
				ui.newLine()

				ui.spacing()
				local intTradeCount = math.max(1, math.floor(tradeCount))
				local totalOrderCost = selectedLocal.price * intTradeCount
				ui.text(string.format("Order: %d whole shares @ %s = %s", intTradeCount, formatMoney(selectedLocal.price), formatMoney(totalOrderCost)))
				ui.spacing()

				if ui.button(string.format("BUY %d SHARES##BuyLocalBtn", intTradeCount), Vector2(185, 34)) then
					local ok, msg = StockExchange.BuyShares(selectedLocal, intTradeCount)
					statusMessage = msg
					statusTime = ui.getTime()
				end
				ui.sameLine(nil, 12)
				if h and h.shares > 0 then
					local sellAmount = math.min(math.floor(h.shares), intTradeCount)
					if ui.button(string.format("SELL %d SHARES##SellLocalBtn", sellAmount), Vector2(185, 34)) then
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
		local holdingsList = {}
		for ticker, h in pairs(portfolio) do
			if h.shares and h.shares > 0.000001 then
				table.insert(holdingsList, h)
			end
		end

		-- Sort holdings by total market value descending
		table.sort(holdingsList, function(a, b)
			local stockA = StockExchange.GetStock(a.ticker)
			local valA = (stockA and stockA.price or a.avgBuyPrice) * a.shares
			local stockB = StockExchange.GetStock(b.ticker)
			local valB = (stockB and stockB.price or b.avgBuyPrice) * b.shares
			return valA > valB
		end)

		if #holdingsList == 0 then
			ui.child("##emptyPortfolio", Vector2(-1, -1), nil, childFlags, function()
				ui.withFont(orbiteer.heading, function()
					ui.textColored(colors.uiPrimaryLight, "NO ACTIVE HOLDINGS IN PORTFOLIO")
				end)
				ui.spacing()
				ui.textColored(colors.fontDim, "You do not currently own any shares or equity holdings.")
				ui.textWrapped("Browse Galactic Megacorporations or Local System Enterprises on the exchange to invest your commercial profits and earn quarterly dividends.")
			end)
		else
			local availW = ui.getContentRegion().x
			local leftW = math.floor(availW * 0.44)
			local rightW = availW - leftW - 16

			-- Ensure selectedTicker points to an owned holding
			local selectedHolding = nil
			for _, h in ipairs(holdingsList) do
				if h.ticker == selectedTicker then
					selectedHolding = h
					break
				end
			end
			if not selectedHolding then
				selectedHolding = holdingsList[1]
				selectedTicker = selectedHolding.ticker
			end

			-- Left holdings list with sparklines
			ui.child("##portfolioList", Vector2(leftW, -1), nil, childFlags, function()
				ui.textColored(colors.uiPrimaryLight, string.format("Securities & Holdings (%d Positions):", #holdingsList))
				ui.separator()

				ui.columns(6, "##portfolioCols", true)
				ui.text("TICKER") ui.nextColumn()
				ui.text("HOLDING") ui.nextColumn()
				ui.text("TREND (30D)") ui.nextColumn()
				ui.text("SHARES") ui.nextColumn()
				ui.text("MKT VALUE") ui.nextColumn()
				ui.text("PROFIT/LOSS") ui.nextColumn()
				ui.separator()

				for _, h in ipairs(holdingsList) do
					local isSel = (selectedTicker == h.ticker)
					if ui.selectable(h.ticker .. "##portRow", isSel, { "SpanAllColumns" }) then
						selectedTicker = h.ticker
					end
					ui.nextColumn()

					ui.text(h.name or h.ticker)
					ui.nextColumn()

					-- Mini Sparkline Trendline
					local sparkPos = ui.getCursorScreenPos()
					local sparkW, sparkH = 75, 18
					ui.dummy(Vector2(sparkW, sparkH))
					local hist = StockExchange.GetStockHistory(h.ticker)
					drawMiniSparkline(sparkPos, sparkW, sparkH, hist)
					ui.nextColumn()

					local shareStr = h.isMegacorp and string.format("%.3f", h.shares) or string.format("%d", math.floor(h.shares))
					ui.text(shareStr)
					ui.nextColumn()

					local stock = StockExchange.GetStock(h.ticker)
					local curPrice = stock and stock.price or h.avgBuyPrice
					local curVal = h.shares * curPrice
					ui.text(formatMoney(curVal))
					ui.nextColumn()

					local pnl = curVal - h.totalInvested
					local pnlCol = (pnl >= 0) and colors.econProfit or colors.econLoss
					local pnlSign = (pnl >= 0) and "+" or ""
					local pnlPct = (h.totalInvested > 0) and ((pnl / h.totalInvested) * 100) or 0.0
					ui.textColored(pnlCol, string.format("%s%.1f%%", pnlSign, pnlPct))
					ui.nextColumn()
				end
				ui.columns(1)
			end)

			ui.sameLine(nil, 16)

			-- Right Detail Panel for Selected Holding
			local stock = StockExchange.GetStock(selectedHolding.ticker)
			local curPrice = stock and stock.price or selectedHolding.avgBuyPrice
			local curSys = Game.system and Game.system.name or "Sol"
			local isRemote = (not selectedHolding.isMegacorp) and (stock and stock.system and stock.system ~= curSys)
			local canBuy, buyReason = StockExchange.CanBuyStock(stock)

			ui.child("##portfolioDetail", Vector2(rightW, -1), nil, childFlags, function()
				local stats = StockExchange.Get24hStats(selectedHolding.ticker)
				local chgCol = (stats.changeCr >= 0) and colors.econProfit or colors.econLoss
				local chgSign = (stats.changeCr >= 0) and "+" or ""

				ui.withFont(orbiteer.heading, function()
					ui.textColored(colors.uiPrimaryLight, selectedHolding.name or selectedHolding.ticker)
				end)

				ui.sameLine(rightW - 220)
				if selectedHolding.isMegacorp then
					ui.textColored(Color(255, 215, 60, 255), "[ MEGACORP ]")
				elseif isRemote then
					ui.textColored(Color(255, 170, 50, 255), "[ REMOTE — SELL ONLY ]")
				else
					ui.textColored(Color(120, 240, 160, 255), "[ LOCAL ENTERPRISE ]")
				end

				local sectorStr = stock and stock.sector or "Commercial Enterprise"
				local divYield = (stock and stock.dividendYield) and string.format("  |  Dividend Yield: %.1f%%", stock.dividendYield * 100) or ""
				local systemStr = ""
				if not selectedHolding.isMegacorp then
					local originSys = (stock and stock.system) or selectedHolding.system or "Chartered System"
					systemStr = string.format("  |  Origin: %s System", originSys)
				end

				ui.textColored(colors.fontDim, string.format("Ticker: %s  |  Sector: %s%s%s",
					selectedHolding.ticker, sectorStr, divYield, systemStr))
				ui.separator()

				if stock and stock.crisisNote then
					ui.textColored(colors.alertYellow, "CRISIS IMPACT ALERT: " .. stock.crisisNote)
				end

				-- Header Price & 24h Stats Row
				ui.text(string.format("Current Price: %s", formatMoney(curPrice)))
				ui.sameLine()
				ui.textColored(chgCol, string.format("(%s%s / %s%.2f%%)", chgSign, formatMoney(stats.changeCr), chgSign, stats.changePct))
				ui.sameLine(nil, 24)
				ui.textColored(colors.fontDim, string.format("24h Vol: %s shares", formatVol(stats.volume24h)))
				ui.sameLine(nil, 20)
				ui.textColored(colors.fontDim, string.format("52W: %s - %s", formatMoney(stats.low52w), formatMoney(stats.high52w)))

				ui.spacing()

				-- Chart Controls (Timeframe & Mode)
				local timeframes = { "7D", "14D", "30D", "ALL" }
				for _, tf in ipairs(timeframes) do
					local isSel = (selectedTimeframe == tf)
					local bStyle = isSel and { Button = colors.uiPrimaryLight, Text = colors.black } or {}
					ui.withStyleColors(bStyle, function()
						if ui.button(tf .. "##PortTf", Vector2(48, 22)) then selectedTimeframe = tf end
					end)
					ui.sameLine(nil, 4)
				end

				ui.sameLine(rightW - 165)
				local isArea = (chartMode == "AREA")
				if ui.button((isArea and "MODE: AREA" or "MODE: CANDLES") .. "##PortModeBtn", Vector2(145, 22)) then
					chartMode = isArea and "CANDLES" or "AREA"
				end

				ui.spacing()

				-- Main Interactive Financial Chart Canvas
				local chartPos = ui.getCursorScreenPos()
				local chartW = rightW - 24
				local chartH = 200
				ui.dummy(Vector2(chartW, chartH))
				local history = StockExchange.GetStockHistory(selectedHolding.ticker)
				drawInteractiveStockChart(chartPos, chartW, chartH, history, selectedTimeframe, chartMode)

				ui.spacing()

				-- Detailed Position Summary Card
				local curVal = selectedHolding.shares * curPrice
				local pnl = curVal - selectedHolding.totalInvested
				local pnlCol = (pnl >= 0) and colors.econProfit or colors.econLoss
				local pnlSign = (pnl >= 0) and "+" or ""
				local pnlPct = (selectedHolding.totalInvested > 0) and ((pnl / selectedHolding.totalInvested) * 100) or 0.0

				local shareDisplay = selectedHolding.isMegacorp and string.format("%.3f", selectedHolding.shares) or string.format("%d", math.floor(selectedHolding.shares))

				ui.separator()
				ui.textColored(colors.uiPrimaryLight, "ACTIVE HOLDING DETAILS & RETURN ON INVESTMENT:")
				ui.group(function()
					ui.columns(4, "##holdingStatsCols", false)
					ui.textColored(colors.fontDim, "Shares Owned:")
					ui.text(shareDisplay)
					ui.nextColumn()

					ui.textColored(colors.fontDim, "Avg Cost Basis:")
					ui.text(formatMoney(selectedHolding.avgBuyPrice))
					ui.nextColumn()

					ui.textColored(colors.fontDim, "Total Market Value:")
					ui.text(formatMoney(curVal))
					ui.nextColumn()

					ui.textColored(colors.fontDim, "Unrealized P/L:")
					ui.textColored(pnlCol, string.format("%s%s (%s%.1f%%)", pnlSign, formatMoney(pnl), pnlSign, pnlPct))
					ui.nextColumn()
					ui.columns(1)
				end)
				ui.separator()

				-- Liquidation / Exit Desk (Always Available)
				ui.textColored(Color(255, 95, 95, 255), "LIQUIDATION & EXIT DESK:")
				ui.textColored(colors.fontDim, "Execute sell order via GalNet clearinghouse (accessible across all civilized space):")

				-- Quick percentage liquidation bar
				local pctButtons = { { 0.25, "25%" }, { 0.50, "50%" }, { 0.75, "75%" }, { 1.00, "100% (ALL)" } }
				for _, pb in ipairs(pctButtons) do
					local pFrac, pName = pb[1], pb[2]
					local estProceeds = curVal * pFrac
					if ui.button(string.format("SELL %s (%s)##PortSellPct", pName, formatMoney(estProceeds)), Vector2(170, 28)) then
						local sellQty
						if selectedHolding.isMegacorp then
							sellQty = selectedHolding.shares * pFrac
						else
							sellQty = math.max(1, math.floor(selectedHolding.shares * pFrac + 0.0001))
							if pFrac >= 0.99 then sellQty = math.floor(selectedHolding.shares) end
						end
						if stock then
							local ok, msg = StockExchange.SellShares(stock, sellQty)
							statusMessage = msg
							statusTime = ui.getTime()
						end
					end
					ui.sameLine(nil, 8)
				end
				ui.newLine()

				if selectedHolding.isMegacorp then
					ui.spacing()
					ui.nextItemWidth(200)
					local maxSellCred = curVal
					local sellCreditAmt = math.min(investCreditAmount, maxSellCred)
					local newAmt, amtChanged = ui.sliderFloat("##PortSellCreditsSlider", sellCreditAmt, 5.0, math.max(5.0, maxSellCred), "%.0f Cr")
					if amtChanged then investCreditAmount = math.floor(newAmt * 100) / 100 end

					ui.sameLine(nil, 8)
					local sellShares = math.min(selectedHolding.shares, investCreditAmount / curPrice)
					local sellShareStr = (sellShares < 0.001) and string.format("%.6f", sellShares) or string.format("%.3f", sellShares)
					if ui.button(string.format("LIQUIDATE %s (%s SHARES)##PortSellCustom", formatMoney(investCreditAmount), sellShareStr), Vector2(300, 26)) then
						if stock then
							local ok, msg = StockExchange.SellSharesByCredits(stock, investCreditAmount)
							statusMessage = msg
							statusTime = ui.getTime()
						end
					end
				else
					ui.spacing()
					local localSellBatches = { 1, 5, 10, 25, 50, 100 }
					for _, sz in ipairs(localSellBatches) do
						if sz <= math.floor(selectedHolding.shares) then
							if ui.button(string.format("SELL %d##PortSellBatch", sz), Vector2(75, 24)) then
								if stock then
									local ok, msg = StockExchange.SellShares(stock, sz)
									statusMessage = msg
									statusTime = ui.getTime()
								end
							end
							ui.sameLine(nil, 6)
						end
					end
					ui.newLine()
				end

				-- Purchasing Desk (Purchase More Shares)
				ui.separator()
				if canBuy then
					ui.textColored(Color(65, 235, 255, 255), "PURCHASE ADDITIONAL SHARES:")
					if selectedHolding.isMegacorp then
						ui.textColored(colors.fontDim, "Acquire additional fractional shares of this megaconglomerate:")
						local creditPresets = { 20, 50, 100, 250, 500, 1000, 5000, 25000 }
						for _, cp in ipairs(creditPresets) do
							local isSel = (math.abs(investCreditAmount - cp) < 0.5)
							local bStyle = isSel and { Button = colors.uiPrimaryLight, Text = colors.black } or {}
							ui.withStyleColors(bStyle, function()
								if ui.button(formatCr(cp) .. " Cr##PortBuyPre", Vector2(72, 26)) then
									investCreditAmount = cp
								end
							end)
							ui.sameLine(nil, 6)
						end
						ui.newLine()

						ui.nextItemWidth(200)
						local newAmt, amtChanged = ui.sliderFloat("##PortBuyCreditsSlider", investCreditAmount, 5.0, 50000.0, "%.0f Cr")
						if amtChanged then investCreditAmount = math.floor(newAmt * 100) / 100 end
						ui.sameLine(nil, 8)

						local calcShares = investCreditAmount / curPrice
						local shareCalcStr = (calcShares < 0.001) and string.format("%.6f", calcShares) or string.format("%.3f", calcShares)
						local buyLabel = string.format("BUY %s (%s SHARES)##PortBuyCreditBtn", formatMoney(investCreditAmount), shareCalcStr)
						if ui.button(buyLabel, Vector2(320, 28)) then
							if stock then
								local ok, msg = StockExchange.BuySharesByCredits(stock, investCreditAmount)
								statusMessage = msg
								statusTime = ui.getTime()
							end
						end
					else
						-- Local Enterprise in current system
						ui.textColored(colors.fontDim, "Acquire additional whole shares in local municipal enterprise:")
						local localBuyBatches = { 1, 5, 10, 50, 100, 500 }
						for _, sz in ipairs(localBuyBatches) do
							local isSel = (math.floor(tradeCount) == sz)
							local bStyle = isSel and { Button = colors.uiPrimaryLight, Text = colors.black } or {}
							ui.withStyleColors(bStyle, function()
								if ui.button(tostring(sz) .. "##PortLocalBatch", Vector2(50, 26)) then tradeCount = sz end
							end)
							ui.sameLine(nil, 6)
						end
						ui.newLine()

						local intTradeCount = math.max(1, math.floor(tradeCount))
						local totalOrderCost = curPrice * intTradeCount
						ui.text(string.format("Order: %d whole shares @ %s = %s", intTradeCount, formatMoney(curPrice), formatMoney(totalOrderCost)))
						ui.spacing()

						if ui.button(string.format("BUY %d SHARES##PortBuyLocalBtn", intTradeCount), Vector2(220, 32)) then
							if stock then
								local ok, msg = StockExchange.BuyShares(stock, intTradeCount)
								statusMessage = msg
								statusTime = ui.getTime()
							end
						end
					end
				else
					-- Remote Local Enterprise: Sell Only!
					local originSys = (stock and stock.system) or selectedHolding.system or "its home"
					ui.textColored(Color(255, 170, 50, 255), "REMOTE ENTERPRISE — SELL / LIQUIDATION ONLY:")
					ui.textWrapped(string.format(
						"This enterprise is registered and chartered within the %s star system. Under interstellar securities regulations, buying additional shares requires physical docking within %s. Remote liquidation orders are cleared across GalNet from any star system.",
						originSys, originSys))
				end
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

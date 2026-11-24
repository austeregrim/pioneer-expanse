-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui            = require 'pigui'
local StationView   = require 'pigui.views.station-view'
local StockExchange = require 'modules.Economy.StockExchange'
local PlayerState   = require 'PlayerState'
local Game          = require 'Game'
local SortBar       = require 'pigui.libs.sort-bar'
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
local childFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders' }
local summaryChildFlags = ui.ChildFlags { 'AlwaysUseWindowPadding', 'Borders', 'AutoResizeY' }
local noScrollWinFlags = ui.WindowFlags { 'NoScrollbar', 'NoScrollWithMouse' }

local MEGACORP_SORT_KEYS = {
	{ id = "ticker", label = "Ticker",  defaultDir = 1 },
	{ id = "name",   label = "Name",    defaultDir = 1 },
	{ id = "trend",  label = "30D",     defaultDir = -1 },
	{ id = "price",  label = "Price",   defaultDir = -1 },
	{ id = "change", label = "24h Chg", defaultDir = -1 },
}

local LOCAL_SORT_KEYS = {
	{ id = "ticker", label = "Ticker",     defaultDir = 1 },
	{ id = "name",   label = "Enterprise", defaultDir = 1 },
	{ id = "trend",  label = "30D",        defaultDir = -1 },
	{ id = "price",  label = "Price",      defaultDir = -1 },
	{ id = "parent", label = "Parent",     defaultDir = 1 },
}

local PORTFOLIO_SORT_KEYS = {
	{ id = "ticker", label = "Ticker",  defaultDir = 1 },
	{ id = "name",   label = "Holding", defaultDir = 1 },
	{ id = "trend",  label = "30D",     defaultDir = -1 },
	{ id = "shares", label = "Shares",  defaultDir = -1 },
	{ id = "value",  label = "Value",   defaultDir = -1 },
	{ id = "pnl",    label = "P/L",     defaultDir = -1 },
}

local megacorpSort  = { id = "ticker", dir = 1 }
local localSort     = { id = "ticker", dir = 1 }
local portfolioSort = { id = "value",  dir = -1 }

local function getHistoryWindow(history, timeframe)
	if not history then return 1, 0 end
	local n = #history
	local windowCount = n
	if timeframe == "7D" then windowCount = math.min(7, n)
	elseif timeframe == "14D" then windowCount = math.min(14, n)
	elseif timeframe == "30D" then windowCount = math.min(30, n)
	end
	local startIndex = math.max(1, n - windowCount + 1)
	return startIndex, windowCount
end

local function getTrendPct(history, timeframe)
	local startIndex, windowCount = getHistoryWindow(history, timeframe or selectedTimeframe)
	if windowCount < 2 then return 0 end
	local firstP = history[startIndex].close
	local lastP = history[#history].close
	if not firstP or firstP <= 0 then return 0 end
	return ((lastP - firstP) / firstP) * 100.0
end

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
local function drawMiniSparkline(pos, width, height, history, timeframe)
	local startIndex, windowCount = getHistoryWindow(history, timeframe or selectedTimeframe)
	if windowCount < 2 then
		ui.addLine(Vector2(pos.x, pos.y + height * 0.5), Vector2(pos.x + width, pos.y + height * 0.5), Color(70, 80, 95, 120), 1.0)
		return
	end

	local firstRec = history[startIndex]
	local minP = firstRec.low or firstRec.close
	local maxP = firstRec.high or firstRec.close
	for i = startIndex, #history do
		local r = history[i]
		local lo = r.low or r.close
		local hi = r.high or r.close
		if lo < minP then minP = lo end
		if hi > maxP then maxP = hi end
	end
	local rangeP = math.max(0.01, maxP - minP)

	local firstP = firstRec.close
	local lastP = history[#history].close
	local isUp = (lastP >= firstP)
	local lineColor = isUp and Color(65, 235, 140, 230) or Color(255, 95, 95, 230)

	-- Subtle sparkline background box
	ui.addRectFilled(pos, Vector2(pos.x + width, pos.y + height), Color(20, 25, 35, 140), 2.0, ui.RoundCornersAll)

	local padX = 2.0
	local plotW = math.max(1.0, width - padX * 2.0)
	local stepX = plotW / math.max(1, windowCount - 1)
	local prevPt = nil
	for idx = 1, windowCount do
		local rec = history[startIndex + idx - 1]
		local normY = 1.0 - ((rec.close - minP) / rangeP)
		local pt = Vector2(pos.x + padX + (idx - 1) * stepX, pos.y + 2 + normY * (height - 4))
		if prevPt then
			ui.addLine(prevPt, pt, lineColor, 1.4)
		end
		prevPt = pt
	end
end

-- Render interactive Bloomberg-grade canvas chart with price curve / candles + volume histogram
local function drawInteractiveStockChart(canvasPos, width, height, history, timeframe, mode)
	-- Determine timeframe window
	local startIndex, windowCount = getHistoryWindow(history, timeframe)
	if windowCount < 2 then
		ui.addRectFilled(canvasPos, Vector2(canvasPos.x + width, canvasPos.y + height), Color(15, 18, 26, 255), 4.0, ui.RoundCornersAll)
		ui.addText(Vector2(canvasPos.x + 20, canvasPos.y + 40), colors.fontDim, "Insufficient market history for selected interval.")
		return
	end

	local firstRec = history[startIndex]
	local minP = firstRec.low or firstRec.close
	local maxP = firstRec.high or firstRec.close
	local maxVol = 1
	for i = startIndex, #history do
		local r = history[i]
		local lo = r.low or r.close
		local hi = r.high or r.close
		if lo < minP then minP = lo end
		if hi > maxP then maxP = hi end
		if (r.volume or 0) > maxVol then maxVol = r.volume end
	end
	local rangeP = math.max(0.01, maxP - minP)

	-- Strict plot boundaries inside the chart border
	local axisLabelW = 75
	local plotLeft = canvasPos.x + 4
	local plotRight = canvasPos.x + math.max(44, width - axisLabelW - 4)
	local plotW = math.max(1.0, plotRight - plotLeft)
	local priceTop = canvasPos.y + 12
	local priceBot = canvasPos.y + math.floor(height * 0.68)
	local priceSpan = math.max(10.0, priceBot - priceTop)
	local volSepY = priceBot + 8
	local volTopY = volSepY + 4
	local volBaseY = canvasPos.y + height - 6
	local volH = math.max(8.0, volBaseY - volTopY)

	-- Background plate & grid
	ui.addRectFilled(canvasPos, Vector2(canvasPos.x + width, canvasPos.y + height), Color(12, 15, 22, 255), 4.0, ui.RoundCornersAll)
	ui.addRect(canvasPos, Vector2(canvasPos.x + width, canvasPos.y + height), Color(40, 50, 70, 160), 4.0, ui.RoundCornersAll, 1.0)

	-- Price Horizontal Gridlines (4 levels)
	for lvl = 0, 3 do
		local normLvl = lvl / 3.0
		local yLine = priceTop + normLvl * priceSpan
		local pVal = maxP - normLvl * rangeP
		ui.addLine(Vector2(plotLeft, yLine), Vector2(plotRight, yLine), Color(40, 50, 70, 75), 1.0)
		ui.addText(Vector2(plotRight + 6, yLine - 6), Color(130, 155, 180, 200), string.format("%.0f Cr", pVal))
	end

	-- Volume separator baseline
	ui.addLine(Vector2(plotLeft, volSepY), Vector2(plotRight, volSepY), Color(50, 65, 90, 120), 1.0)
	ui.addText(Vector2(plotRight + 6, volTopY - 2), Color(110, 130, 160, 180), formatVol(maxVol))

	local slotW = plotW / math.max(1, windowCount)
	local barWidth = math.clamp(slotW * 0.65, 2.0, 28.0)

	-- 1. Draw Volume Bars (strictly contained inside [plotLeft, plotRight] and [volTopY, volBaseY])
	for i = 1, windowCount do
		local rec = history[startIndex + i - 1]
		local barX = plotLeft + (i - 0.5) * slotW
		local vRatio = math.clamp((rec.volume or 0) / maxVol, 0.0, 1.0)
		local barH = vRatio * volH
		local isGreen = (rec.close >= rec.open)
		local vCol = isGreen and Color(65, 225, 130, 160) or Color(245, 80, 80, 160)
		local x0 = math.max(plotLeft, barX - barWidth * 0.5)
		local x1 = math.min(plotRight, barX + barWidth * 0.5)
		local y0 = math.max(volTopY, volBaseY - barH)
		if (volBaseY - y0) >= 1.0 and x1 > x0 then
			ui.addRectFilled(Vector2(x0, y0), Vector2(x1, volBaseY), vCol, 1.0, ui.RoundCornersTop)
		end
	end

	-- 2. Draw Price Representation (Area Curve or Candlestick)
	if mode == "CANDLES" then
		for i = 1, windowCount do
			local rec = history[startIndex + i - 1]
			local barX = plotLeft + (i - 0.5) * slotW
			local isGreen = (rec.close >= rec.open)
			local bodyCol = isGreen and Color(65, 235, 140, 240) or Color(255, 85, 85, 240)

			local yOpen = priceTop + (1.0 - (rec.open - minP) / rangeP) * priceSpan
			local yClose = priceTop + (1.0 - (rec.close - minP) / rangeP) * priceSpan
			local yHigh = priceTop + (1.0 - (rec.high - minP) / rangeP) * priceSpan
			local yLow = priceTop + (1.0 - (rec.low - minP) / rangeP) * priceSpan

			-- Upper & Lower Wick
			ui.addLine(Vector2(barX, yHigh), Vector2(barX, yLow), bodyCol, 1.2)
			-- Candle Body
			local topY = math.min(yOpen, yClose)
			local botY = math.max(yOpen, yClose)
			if (botY - topY) < 2.0 then botY = topY + 2.0 end
			local x0 = math.max(plotLeft, barX - barWidth * 0.5)
			local x1 = math.min(plotRight, barX + barWidth * 0.5)
			ui.addRectFilled(Vector2(x0, topY), Vector2(x1, botY), bodyCol, 1.0, ui.RoundCornersAll)
		end
	else
		-- Smooth Area Curve with Shaded Fill
		local prevPt = nil
		local isOverallUp = (history[#history].close >= history[startIndex].close)
		local curveColor = isOverallUp and Color(65, 235, 140, 255) or Color(255, 90, 90, 255)

		for i = 1, windowCount do
			local rec = history[startIndex + i - 1]
			local curX = plotLeft + (i - 0.5) * slotW
			local curY = priceTop + (1.0 - (rec.close - minP) / rangeP) * priceSpan
			local pt = Vector2(curX, curY)

			if prevPt then
				-- Draw line segment
				ui.addLine(prevPt, pt, curveColor, 2.0)
				-- Draw shaded drop column under curve
				local shadeCol = isOverallUp and Color(40, 190, 110, 22) or Color(190, 45, 45, 22)
				ui.addRectFilled(Vector2(prevPt.x, prevPt.y), Vector2(pt.x, volSepY), shadeCol, 0, ui.RoundCornersNone)
			end
			prevPt = pt
		end
	end

	-- 3. Interactive Mouse Hover Crosshair & Tooltip
	local mousePos = ui.getMousePos()
	if mousePos.x >= plotLeft and mousePos.x <= plotRight and
	   mousePos.y >= canvasPos.y and mousePos.y <= (canvasPos.y + height) then
		local relX = mousePos.x - plotLeft
		local hoverIdx = math.clamp(math.floor(relX / slotW) + 1, 1, windowCount)
		local rec = history[startIndex + hoverIdx - 1]
		local snapX = plotLeft + (hoverIdx - 0.5) * slotW
		local snapY = priceTop + (1.0 - (rec.close - minP) / rangeP) * priceSpan

		-- Vertical cursor crosshair
		ui.addLine(Vector2(snapX, canvasPos.y), Vector2(snapX, canvasPos.y + height), Color(160, 200, 255, 140), 1.0)
		ui.addCircleFilled(Vector2(snapX, snapY), 4.0, Color(255, 255, 255, 255), 12)
		ui.addCircle(Vector2(snapX, snapY), 6.5, Color(65, 235, 255, 255), 12, 1.5)

		-- Floating Inspection HUD Box
		local hudW, hudH = 175, 78
		local hudX = (snapX + hudW + 16 < plotRight) and (snapX + 12) or (snapX - hudW - 12)
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

	ui.child("##financialSummary", Vector2(ui.getContentRegion().x, 0), noScrollWinFlags, summaryChildFlags, function()
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
		local totalTabW = ui.getContentRegion().x
		local tabSp = 8
		local tabW = math.floor((totalTabW - (#tabs - 1) * tabSp) / #tabs)
		for i, t in ipairs(tabs) do
			local isSel = (currentTab == t.id)
			local tabStyle = isSel and { Button = colors.uiPrimary or colors.white, Text = colors.black } or {}
			ui.withStyleColors(tabStyle, function()
				if ui.button(t.label .. "##Tab", Vector2(tabW, 32)) then
					currentTab = t.id
				end
			end)
			if i < #tabs then ui.sameLine(nil, tabSp) end
		end
		ui.newLine()
	end)

	ui.spacing()

	-- Tab 1: Galactic Megacorporations (Super High Value & Fractional Shares)
	if currentTab == "MEGACORPS" then
		local megacorps = StockExchange.GetMegacorps()
		local megacorpRows = {}
		for _, corp in ipairs(megacorps) do
			local hist = StockExchange.GetStockHistory(corp.ticker)
			local stats = StockExchange.Get24hStats(corp.ticker)
			table.insert(megacorpRows, {
				corp = corp,
				hist = hist,
				stats = stats,
				trendPct = getTrendPct(hist, selectedTimeframe),
			})
		end
		table.sort(megacorpRows, function(a, b)
			local sid, sdir = megacorpSort.id, megacorpSort.dir
			local cmp
			if sid == "name" then
				cmp = SortBar.compareValues(a.corp.name, b.corp.name, sdir)
			elseif sid == "trend" then
				cmp = SortBar.compareValues(a.trendPct, b.trendPct, sdir)
			elseif sid == "price" then
				cmp = SortBar.compareValues(a.corp.price, b.corp.price, sdir)
			elseif sid == "change" then
				cmp = SortBar.compareValues(a.stats.changePct, b.stats.changePct, sdir)
			else
				cmp = SortBar.compareValues(a.corp.ticker, b.corp.ticker, sdir)
			end
			if cmp ~= nil then return cmp end
			local tie = SortBar.compareValues(a.corp.ticker, b.corp.ticker, 1)
			if tie ~= nil then return tie end
			return false
		end)

		local availW = ui.getContentRegion().x
		local leftW = math.floor(availW * 0.44)
		local rightW = availW - leftW - 16

		-- Left list with mini sparklines
		ui.child("##megacorpList", Vector2(leftW, -1), noScrollWinFlags, childFlags, function()
			local newId, newDir, changed = SortBar.draw("SortMegacorps", MEGACORP_SORT_KEYS, megacorpSort.id, megacorpSort.dir)
			if changed then
				megacorpSort.id = newId
				megacorpSort.dir = newDir
			end
			ui.separator()

			ui.child("##megacorpRows", Vector2(0, 0), nil, nil, function()
				ui.columns(5, "##megacorpCols", true)
				ui.text("TICKER") ui.nextColumn()
				ui.text("CONGLOMERATE") ui.nextColumn()
				ui.text("TREND (" .. selectedTimeframe .. ")") ui.nextColumn()
				ui.text("PRICE") ui.nextColumn()
				ui.text("24H CHG") ui.nextColumn()
				ui.separator()

				for _, row in ipairs(megacorpRows) do
					local corp = row.corp
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
					drawMiniSparkline(sparkPos, sparkW, sparkH, row.hist, selectedTimeframe)
					ui.nextColumn()

					ui.text(formatMoney(corp.price))
					ui.nextColumn()

					local stats = row.stats
					local chgCol = (stats.changeCr >= 0) and colors.econProfit or colors.econLoss
					local chgSign = (stats.changeCr >= 0) and "+" or ""
					ui.textColored(chgCol, string.format("%s%.1f%%", chgSign, stats.changePct))
					ui.nextColumn()
				end
				ui.columns(1)
			end)
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
				local chartW = math.max(200, math.floor(ui.getContentRegion().x))
				local chartH = math.clamp(math.floor(ui.getContentRegion().y - 220), 130, 220)
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

				local panelW = ui.getContentRegion().x

				-- Credit Amount Presets (Distributed evenly across panel)
				local creditPresets = { 20, 50, 100, 250, 500, 1000, 5000, 25000 }
				local numPresets = #creditPresets
				local preSp = 6
				local preW = math.floor((panelW - (numPresets - 1) * preSp) / numPresets)
				for i, cp in ipairs(creditPresets) do
					local isSel = (math.abs(investCreditAmount - cp) < 0.5)
					local bStyle = isSel and { Button = colors.uiPrimaryLight, Text = colors.black } or {}
					ui.withStyleColors(bStyle, function()
						if ui.button(formatCr(cp) .. " Cr##CValBtn", Vector2(preW, 26)) then
							investCreditAmount = cp
						end
					end)
					if i < numPresets then ui.sameLine(nil, preSp) end
				end
				ui.newLine()

				-- Slider & Fine Adjustment Nudge Buttons (Decreases on Left, Slider in Middle, Increases on Right)
				local nudgeSp = 6
				local decBtnW = math.max(48, math.floor(panelW * 0.08))
				local incBtnW1 = math.max(48, math.floor(panelW * 0.08))
				local incBtnW2 = math.max(48, math.floor(panelW * 0.08))
				local incBtnW3 = math.max(56, math.floor(panelW * 0.09))
				local fixedBtnsW = decBtnW * 2 + incBtnW1 + incBtnW2 + incBtnW3 + 5 * nudgeSp
				local sliderW = math.max(160, panelW - fixedBtnsW)

				if ui.button("-50##N50", Vector2(decBtnW, 24)) then investCreditAmount = math.max(5.0, investCreditAmount - 50.0) end
				ui.sameLine(nil, nudgeSp)
				if ui.button("-10##N10", Vector2(decBtnW, 24)) then investCreditAmount = math.max(5.0, investCreditAmount - 10.0) end
				ui.sameLine(nil, nudgeSp)

				ui.nextItemWidth(sliderW)
				local newAmt, amtChanged = ui.sliderFloat("##InvestCreditsSlider", investCreditAmount, 5.0, 50000.0, "%.0f Cr")
				if amtChanged then investCreditAmount = math.floor(newAmt * 100) / 100 end
				ui.sameLine(nil, nudgeSp)

				if ui.button("+10##N10P", Vector2(incBtnW1, 24)) then investCreditAmount = investCreditAmount + 10.0 end
				ui.sameLine(nil, nudgeSp)
				if ui.button("+50##N50P", Vector2(incBtnW2, 24)) then investCreditAmount = investCreditAmount + 50.0 end
				ui.sameLine(nil, nudgeSp)
				if ui.button("+500##N500P", Vector2(incBtnW3, 24)) then investCreditAmount = investCreditAmount + 500.0 end
				ui.newLine()

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

				if h and h.shares > 0 then
					local positionVal = h.shares * corp.price
					local sellCredit = math.min(positionVal, investCreditAmount)
					local sellShares = math.min(h.shares, sellCredit / corp.price)
					local sellShareStr = (sellShares < 0.001) and string.format("%.6f", sellShares) or string.format("%.4f", sellShares)

					local actionBtnW = math.floor((panelW - 12) / 2)
					if ui.button(buyLabel, Vector2(actionBtnW, 36)) then
						local ok, msg = StockExchange.BuySharesByCredits(corp, investCreditAmount)
						statusMessage = msg
						statusTime = ui.getTime()
					end
					ui.sameLine(nil, 12)
					local sellLabel = string.format("LIQUIDATE %s (%s SHARES)##SellCreditBtn",
						formatMoney(sellCredit), sellShareStr)
					if ui.button(sellLabel, Vector2(actionBtnW, 36)) then
						local ok, msg = StockExchange.SellSharesByCredits(corp, sellCredit)
						statusMessage = msg
						statusTime = ui.getTime()
					end

					-- Quick percentage liquidation bar (Distributed evenly across panel)
					ui.spacing()
					ui.textColored(colors.fontDim, "Quick Position Liquidation:")
					local pctButtons = { { 0.25, "25%" }, { 0.50, "50%" }, { 0.75, "75%" }, { 1.00, "100% (ALL)" } }
					local numPct = #pctButtons
					local pctSp = 6
					local pctW = math.floor((panelW - (numPct - 1) * pctSp) / numPct)
					for i, pb in ipairs(pctButtons) do
						local pFrac, pName = pb[1], pb[2]
						if ui.button(pName .. "##SellPct", Vector2(pctW, 26)) then
							local sellQty = h.shares * pFrac
							local ok, msg = StockExchange.SellShares(corp, sellQty)
							statusMessage = msg
							statusTime = ui.getTime()
						end
						if i < numPct then ui.sameLine(nil, pctSp) end
					end
					ui.newLine()
				else
					if ui.button(buyLabel, Vector2(panelW, 36)) then
						local ok, msg = StockExchange.BuySharesByCredits(corp, investCreditAmount)
						statusMessage = msg
						statusTime = ui.getTime()
					end
				end

				-- Order confirmation displayed under buttons so panels never shift
				if statusMessage and (ui.getTime() - statusTime < 6.0) then
					ui.spacing()
					ui.textColored(colors.alertYellow, statusMessage)
				end
			end
		end)

	-- Tab 2: Local System Enterprises (Whole Shares Only, Lower Values)
	elseif currentTab == "LOCAL" then
		local sysName = Game.system and Game.system.name or "Sol"
		local localCompanies = StockExchange.GetLocalEnterprises(sysName)
		local localRows = {}
		for _, c in ipairs(localCompanies) do
			local hist = StockExchange.GetStockHistory(c.ticker)
			table.insert(localRows, {
				corp = c,
				hist = hist,
				trendPct = getTrendPct(hist, selectedTimeframe),
			})
		end
		table.sort(localRows, function(a, b)
			local sid, sdir = localSort.id, localSort.dir
			local cmp
			if sid == "name" then
				cmp = SortBar.compareValues(a.corp.name, b.corp.name, sdir)
			elseif sid == "trend" then
				cmp = SortBar.compareValues(a.trendPct, b.trendPct, sdir)
			elseif sid == "price" then
				cmp = SortBar.compareValues(a.corp.price, b.corp.price, sdir)
			elseif sid == "parent" then
				cmp = SortBar.compareValues(a.corp.parent, b.corp.parent, sdir)
			else
				cmp = SortBar.compareValues(a.corp.ticker, b.corp.ticker, sdir)
			end
			if cmp ~= nil then return cmp end
			local tie = SortBar.compareValues(a.corp.ticker, b.corp.ticker, 1)
			if tie ~= nil then return tie end
			return false
		end)

		local availW = ui.getContentRegion().x
		local leftW = math.floor(availW * 0.44)
		local rightW = availW - leftW - 16

		ui.child("##localCompanyList", Vector2(leftW, -1), noScrollWinFlags, childFlags, function()
			ui.textColored(colors.uiPrimaryLight, string.format("Local Enterprises in %s System:", string.upper(sysName)))
			local newId, newDir, changed = SortBar.draw("SortLocal", LOCAL_SORT_KEYS, localSort.id, localSort.dir)
			if changed then
				localSort.id = newId
				localSort.dir = newDir
			end
			ui.separator()

			ui.child("##localRows", Vector2(0, 0), nil, nil, function()
				ui.columns(5, "##localCols", true)
				ui.text("TICKER") ui.nextColumn()
				ui.text("ENTERPRISE") ui.nextColumn()
				ui.text("TREND (" .. selectedTimeframe .. ")") ui.nextColumn()
				ui.text("PRICE") ui.nextColumn()
				ui.text("PARENT") ui.nextColumn()
				ui.separator()

				for _, row in ipairs(localRows) do
					local c = row.corp
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
					drawMiniSparkline(sparkPos, sparkW, sparkH, row.hist, selectedTimeframe)
					ui.nextColumn()

					ui.text(formatMoney(c.price))
					ui.nextColumn()

					ui.text(c.parent)
					ui.nextColumn()
				end
				ui.columns(1)
			end)
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
				local chartW = math.max(200, math.floor(ui.getContentRegion().x))
				local chartH = math.clamp(math.floor(ui.getContentRegion().y - 190), 130, 220)
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

				local panelW = ui.getContentRegion().x

				-- Whole Share Presets (Distributed evenly across panel)
				local localPresets = { 1, 5, 10, 50, 100, 500 }
				local numLPre = #localPresets
				local lPreSp = 6
				local lPreW = math.floor((panelW - (numLPre - 1) * lPreSp) / numLPre)
				for i, sz in ipairs(localPresets) do
					local isSel = (math.floor(tradeCount) == sz)
					local bStyle = isSel and { Button = colors.uiPrimaryLight, Text = colors.black } or {}
					ui.withStyleColors(bStyle, function()
						if ui.button(tostring(sz) .. "##LocalBatch", Vector2(lPreW, 26)) then tradeCount = sz end
					end)
					if i < numLPre then ui.sameLine(nil, lPreSp) end
				end
				ui.newLine()

				ui.spacing()
				local intTradeCount = math.max(1, math.floor(tradeCount))
				local totalOrderCost = selectedLocal.price * intTradeCount
				ui.text(string.format("Order: %d whole shares @ %s = %s", intTradeCount, formatMoney(selectedLocal.price), formatMoney(totalOrderCost)))
				ui.spacing()

				if h and h.shares > 0 then
					local btnW = math.floor((panelW - 12) / 2)
					if ui.button(string.format("BUY %d SHARES##BuyLocalBtn", intTradeCount), Vector2(btnW, 36)) then
						local ok, msg = StockExchange.BuyShares(selectedLocal, intTradeCount)
						statusMessage = msg
						statusTime = ui.getTime()
					end
					ui.sameLine(nil, 12)
					local sellAmount = math.min(math.floor(h.shares), intTradeCount)
					if ui.button(string.format("SELL %d SHARES##SellLocalBtn", sellAmount), Vector2(btnW, 36)) then
						local ok, msg = StockExchange.SellShares(selectedLocal, sellAmount)
						statusMessage = msg
						statusTime = ui.getTime()
					end
				else
					if ui.button(string.format("BUY %d SHARES##BuyLocalBtn", intTradeCount), Vector2(panelW, 36)) then
						local ok, msg = StockExchange.BuyShares(selectedLocal, intTradeCount)
						statusMessage = msg
						statusTime = ui.getTime()
					end
				end

				-- Order confirmation displayed under buttons so panels never shift
				if statusMessage and (ui.getTime() - statusTime < 6.0) then
					ui.spacing()
					ui.textColored(colors.alertYellow, statusMessage)
				end
			end
		end)

	-- Tab 3: Player Portfolio & Holdings
	elseif currentTab == "PORTFOLIO" then
		local portfolio = StockExchange.GetPlayerPortfolio()
		local holdingRows = {}
		for ticker, h in pairs(portfolio) do
			if h.shares and h.shares > 0.000001 then
				local stock = StockExchange.GetStock(h.ticker)
				local curPrice = stock and stock.price or h.avgBuyPrice
				local curVal = h.shares * curPrice
				local pnl = curVal - h.totalInvested
				local pnlPct = (h.totalInvested > 0) and ((pnl / h.totalInvested) * 100) or 0.0
				local hist = StockExchange.GetStockHistory(h.ticker)
				table.insert(holdingRows, {
					holding = h,
					stock = stock,
					hist = hist,
					trendPct = getTrendPct(hist, selectedTimeframe),
					curVal = curVal,
					pnl = pnl,
					pnlPct = pnlPct,
					name = h.name or h.ticker,
				})
			end
		end

		table.sort(holdingRows, function(a, b)
			local sid, sdir = portfolioSort.id, portfolioSort.dir
			local cmp
			if sid == "ticker" then
				cmp = SortBar.compareValues(a.holding.ticker, b.holding.ticker, sdir)
			elseif sid == "name" then
				cmp = SortBar.compareValues(a.name, b.name, sdir)
			elseif sid == "trend" then
				cmp = SortBar.compareValues(a.trendPct, b.trendPct, sdir)
			elseif sid == "shares" then
				cmp = SortBar.compareValues(a.holding.shares, b.holding.shares, sdir)
			elseif sid == "pnl" then
				cmp = SortBar.compareValues(a.pnlPct, b.pnlPct, sdir)
				if cmp == nil then
					cmp = SortBar.compareValues(a.pnl, b.pnl, sdir)
				end
			else
				cmp = SortBar.compareValues(a.curVal, b.curVal, sdir)
			end
			if cmp ~= nil then return cmp end
			local tie = SortBar.compareValues(a.holding.ticker, b.holding.ticker, 1)
			if tie ~= nil then return tie end
			return false
		end)

		if #holdingRows == 0 then
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
			for _, row in ipairs(holdingRows) do
				if row.holding.ticker == selectedTicker then
					selectedHolding = row.holding
					break
				end
			end
			if not selectedHolding then
				selectedHolding = holdingRows[1].holding
				selectedTicker = selectedHolding.ticker
			end

			-- Left holdings list with sparklines
			ui.child("##portfolioList", Vector2(leftW, -1), noScrollWinFlags, childFlags, function()
				ui.textColored(colors.uiPrimaryLight, string.format("Securities & Holdings (%d Positions):", #holdingRows))
				local newId, newDir, changed = SortBar.draw("SortPortfolio", PORTFOLIO_SORT_KEYS, portfolioSort.id, portfolioSort.dir)
				if changed then
					portfolioSort.id = newId
					portfolioSort.dir = newDir
				end
				ui.separator()

				ui.child("##portfolioRows", Vector2(0, 0), nil, nil, function()
					ui.columns(6, "##portfolioCols", true)
					ui.text("TICKER") ui.nextColumn()
					ui.text("HOLDING") ui.nextColumn()
					ui.text("TREND (" .. selectedTimeframe .. ")") ui.nextColumn()
					ui.text("SHARES") ui.nextColumn()
					ui.text("MKT VALUE") ui.nextColumn()
					ui.text("PROFIT/LOSS") ui.nextColumn()
					ui.separator()

					for _, row in ipairs(holdingRows) do
						local h = row.holding
						local isSel = (selectedTicker == h.ticker)
						if ui.selectable(h.ticker .. "##portRow", isSel, { "SpanAllColumns" }) then
							selectedTicker = h.ticker
						end
						ui.nextColumn()

						ui.text(row.name)
						ui.nextColumn()

						-- Mini Sparkline Trendline
						local sparkPos = ui.getCursorScreenPos()
						local sparkW, sparkH = 75, 18
						ui.dummy(Vector2(sparkW, sparkH))
						drawMiniSparkline(sparkPos, sparkW, sparkH, row.hist, selectedTimeframe)
						ui.nextColumn()

						local shareStr = h.isMegacorp and string.format("%.3f", h.shares) or string.format("%d", math.floor(h.shares))
						ui.text(shareStr)
						ui.nextColumn()

						ui.text(formatMoney(row.curVal))
						ui.nextColumn()

						local pnlCol = (row.pnl >= 0) and colors.econProfit or colors.econLoss
						local pnlSign = (row.pnl >= 0) and "+" or ""
						ui.textColored(pnlCol, string.format("%s%.1f%%", pnlSign, row.pnlPct))
						ui.nextColumn()
					end
					ui.columns(1)
				end)
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
				local chartW = math.max(200, math.floor(ui.getContentRegion().x))
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

				local panelW = ui.getContentRegion().x

				-- Quick percentage liquidation bar (Distributed evenly across panel)
				local pctButtons = { { 0.25, "25%" }, { 0.50, "50%" }, { 0.75, "75%" }, { 1.00, "100% (ALL)" } }
				local numPct = #pctButtons
				local pctSp = 6
				local pctW = math.floor((panelW - (numPct - 1) * pctSp) / numPct)
				for i, pb in ipairs(pctButtons) do
					local pFrac, pName = pb[1], pb[2]
					local estProceeds = curVal * pFrac
					if ui.button(string.format("SELL %s (%s)##PortSellPct", pName, formatMoney(estProceeds)), Vector2(pctW, 28)) then
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
					if i < numPct then ui.sameLine(nil, pctSp) end
				end
				ui.newLine()

				if selectedHolding.isMegacorp then
					ui.spacing()
					local sliderW = math.floor(panelW * 0.45)
					local btnW = panelW - sliderW - 8
					ui.nextItemWidth(sliderW)
					local maxSellCred = curVal
					local sellCreditAmt = math.min(investCreditAmount, maxSellCred)
					local newAmt, amtChanged = ui.sliderFloat("##PortSellCreditsSlider", sellCreditAmt, 5.0, math.max(5.0, maxSellCred), "%.0f Cr")
					if amtChanged then investCreditAmount = math.floor(newAmt * 100) / 100 end

					ui.sameLine(nil, 8)
					local sellShares = math.min(selectedHolding.shares, investCreditAmount / curPrice)
					local sellShareStr = (sellShares < 0.001) and string.format("%.6f", sellShares) or string.format("%.3f", sellShares)
					if ui.button(string.format("LIQUIDATE %s (%s SHARES)##PortSellCustom", formatMoney(investCreditAmount), sellShareStr), Vector2(btnW, 26)) then
						if stock then
							local ok, msg = StockExchange.SellSharesByCredits(stock, investCreditAmount)
							statusMessage = msg
							statusTime = ui.getTime()
						end
					end
				else
					ui.spacing()
					local localSellBatches = { 1, 5, 10, 25, 50, 100 }
					local activeBatches = {}
					for _, sz in ipairs(localSellBatches) do
						if sz <= math.floor(selectedHolding.shares) then
							table.insert(activeBatches, sz)
						end
					end
					if #activeBatches > 0 then
						local bSp = 6
						local bW = math.floor((panelW - (#activeBatches - 1) * bSp) / #activeBatches)
						for i, sz in ipairs(activeBatches) do
							if ui.button(string.format("SELL %d##PortSellBatch", sz), Vector2(bW, 26)) then
								if stock then
									local ok, msg = StockExchange.SellShares(stock, sz)
									statusMessage = msg
									statusTime = ui.getTime()
								end
							end
							if i < #activeBatches then ui.sameLine(nil, bSp) end
						end
						ui.newLine()
					end
				end

				-- Purchasing Desk (Purchase More Shares)
				ui.separator()
				if canBuy then
					ui.textColored(Color(65, 235, 255, 255), "PURCHASE ADDITIONAL SHARES:")
					if selectedHolding.isMegacorp then
						ui.textColored(colors.fontDim, "Acquire additional fractional shares of this megaconglomerate:")
						local creditPresets = { 20, 50, 100, 250, 500, 1000, 5000, 25000 }
						local numPresets = #creditPresets
						local preSp = 6
						local preW = math.floor((panelW - (numPresets - 1) * preSp) / numPresets)
						for i, cp in ipairs(creditPresets) do
							local isSel = (math.abs(investCreditAmount - cp) < 0.5)
							local bStyle = isSel and { Button = colors.uiPrimaryLight, Text = colors.black } or {}
							ui.withStyleColors(bStyle, function()
								if ui.button(formatCr(cp) .. " Cr##PortBuyPre", Vector2(preW, 26)) then
									investCreditAmount = cp
								end
							end)
							if i < numPresets then ui.sameLine(nil, preSp) end
						end
						ui.newLine()

						-- Slider & Fine Adjustment Nudge Buttons (Decreases on Left, Slider in Middle, Increases on Right)
						local nudgeSp = 6
						local decBtnW = math.max(48, math.floor(panelW * 0.08))
						local incBtnW1 = math.max(48, math.floor(panelW * 0.08))
						local incBtnW2 = math.max(48, math.floor(panelW * 0.08))
						local incBtnW3 = math.max(56, math.floor(panelW * 0.09))
						local fixedBtnsW = decBtnW * 2 + incBtnW1 + incBtnW2 + incBtnW3 + 5 * nudgeSp
						local sliderW = math.max(160, panelW - fixedBtnsW)

						if ui.button("-50##PortN50", Vector2(decBtnW, 24)) then investCreditAmount = math.max(5.0, investCreditAmount - 50.0) end
						ui.sameLine(nil, nudgeSp)
						if ui.button("-10##PortN10", Vector2(decBtnW, 24)) then investCreditAmount = math.max(5.0, investCreditAmount - 10.0) end
						ui.sameLine(nil, nudgeSp)

						ui.nextItemWidth(sliderW)
						local newAmt, amtChanged = ui.sliderFloat("##PortBuyCreditsSlider", investCreditAmount, 5.0, 50000.0, "%.0f Cr")
						if amtChanged then investCreditAmount = math.floor(newAmt * 100) / 100 end
						ui.sameLine(nil, nudgeSp)

						if ui.button("+10##PortN10P", Vector2(incBtnW1, 24)) then investCreditAmount = investCreditAmount + 10.0 end
						ui.sameLine(nil, nudgeSp)
						if ui.button("+50##PortN50P", Vector2(incBtnW2, 24)) then investCreditAmount = investCreditAmount + 50.0 end
						ui.sameLine(nil, nudgeSp)
						if ui.button("+500##PortN500P", Vector2(incBtnW3, 24)) then investCreditAmount = investCreditAmount + 500.0 end
						ui.newLine()

						ui.spacing()
						local calcShares = investCreditAmount / curPrice
						local shareCalcStr = (calcShares < 0.001) and string.format("%.6f", calcShares) or string.format("%.3f", calcShares)
						local buyLabel = string.format("BUY %s (%s SHARES)##PortBuyCreditBtn", formatMoney(investCreditAmount), shareCalcStr)
						if ui.button(buyLabel, Vector2(panelW, 34)) then
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
						local numLBuy = #localBuyBatches
						local lBuySp = 6
						local lBuyW = math.floor((panelW - (numLBuy - 1) * lBuySp) / numLBuy)
						for i, sz in ipairs(localBuyBatches) do
							local isSel = (math.floor(tradeCount) == sz)
							local bStyle = isSel and { Button = colors.uiPrimaryLight, Text = colors.black } or {}
							ui.withStyleColors(bStyle, function()
								if ui.button(tostring(sz) .. "##PortLocalBatch", Vector2(lBuyW, 26)) then tradeCount = sz end
							end)
							if i < numLBuy then ui.sameLine(nil, lBuySp) end
						end
						ui.newLine()

						local intTradeCount = math.max(1, math.floor(tradeCount))
						local totalOrderCost = curPrice * intTradeCount
						ui.text(string.format("Order: %d whole shares @ %s = %s", intTradeCount, formatMoney(curPrice), formatMoney(totalOrderCost)))
						ui.spacing()

						if ui.button(string.format("BUY %d SHARES##PortBuyLocalBtn", intTradeCount), Vector2(panelW, 34)) then
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

				-- Order confirmation displayed under buttons so panels never shift
				if statusMessage and (ui.getTime() - statusTime < 6.0) then
					ui.spacing()
					ui.textColored(colors.alertYellow, statusMessage)
				end
			end)
		end
	end
end

StationView:registerView({
	id = "stockExchange",
	name = "ISX Stock Exchange",
	icon = icons.money or icons.bbs,
	securityMode = "encryption",
	showView = true,
	draw = drawStockExchange,
	refresh = function(self) end,
	debugReload = function()
		package.reimport()
	end
})

-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Engine    = require 'Engine'
local Game      = require 'Game'
local ui        = require 'pigui'
local debugView = require 'pigui.views.debug'

local colors = ui.theme.colors
local icons  = ui.theme.icons
local Vector2 = _G.Vector2

local DebugGalaxySim = {
	flags = {
		showNewsEffects  = false,
		showStockDrivers = false,
		showFleetDebug   = false,
	}
}

local function drawDebugGalaxySim()
	ui.textColored(colors.uiPrimaryLight, "GALAXY, NEWS & STOCK SIMULATION DEBUGGER")
	ui.separator()
	ui.spacing()

	-- 1. Toggleable Hidden-Detail Overlays
	ui.textColored(colors.alertYellow, "In-Game Hidden Debug Overlays:")
	local changedNews, valNews = ui.checkbox("Show Hidden News Effects in InterCast (Stocks, Commodities, Tax, Piracy)", DebugGalaxySim.flags.showNewsEffects)
	if changedNews then DebugGalaxySim.flags.showNewsEffects = valNews end

	local changedStock, valStock = ui.checkbox("Show Stock Price Driver Breakdown in Stock Exchange", DebugGalaxySim.flags.showStockDrivers)
	if changedStock then DebugGalaxySim.flags.showStockDrivers = valStock end

	local changedFleet, valFleet = ui.checkbox("Show Fleet Market Saturation Details in Fleet Command", DebugGalaxySim.flags.showFleetDebug)
	if changedFleet then DebugGalaxySim.flags.showFleetDebug = valFleet end

	local showAllShips = Engine.GetDebugShowAllShips and Engine.GetDebugShowAllShips() or false
	local changedShips, valShips = ui.checkbox("Show All Ships as Targets (Invisible ships shown in italics)", showAllShips)
	if changedShips and Engine.SetDebugShowAllShips then
		Engine.SetDebugShowAllShips(valShips)
	end

	ui.spacing()
	local okInterCast, InterCast = pcall(require, 'modules.InterCast.InterCast')
	local okMacro, MacroEngine = pcall(require, 'modules.MacroGalaxy.MacroGalaxyEngine')
	local okStock, StockExchange = pcall(require, 'modules.Economy.StockExchange')
	local okFleet, PlayerFleet = pcall(require, 'modules.PlayerFleet.PlayerFleet')

	-- 2. Quick Actions
	if okInterCast and InterCast and InterCast.ForceGenerateBatch then
		if ui.button("Generate +15 Wire Articles", Vector2(210, 0)) then
			InterCast.ForceGenerateBatch(15)
		end
	end
	if okMacro and MacroEngine and MacroEngine.AdvanceMacroTick then
		ui.sameLine()
		if ui.button("Advance Macro Tick (+1 Day)", Vector2(220, 0)) then
			MacroEngine.AdvanceMacroTick(1.0)
		end
	end

	ui.spacing()
	ui.separator()
	ui.spacing()

	-- 3. Active Macro Crises & Exact Effects
	local crises = (okMacro and MacroEngine and MacroEngine.GetActiveCrises) and MacroEngine.GetActiveCrises() or {}
	if ui.collapsingHeader(string.format("Active Macro Crises (%d)##dbg_crises", #crises)) then
		for idx, c in ipairs(crises) do
			local header = string.format("%s — %s (Stage %d, %.1f%%, +%.1f%%/day)##dbg_c_%d",
				c.system or "?", c.type or "?", c.severity or 1, c.progress or 0, c.progressRate or 0, idx)
			if ui.treeNode(header) then
				local stockFx = (okStock and StockExchange and StockExchange.GetCrisisStockImpacts) and StockExchange.GetCrisisStockImpacts(c) or {}
				if #stockFx > 0 then
					ui.textColored(colors.uiPrimaryLight, "Affected Stocks:")
					for _, sf in ipairs(stockFx) do
						local col = (sf.dailyDriftPct >= 0) and colors.econProfit or colors.econLoss
						ui.textColored(col, string.format("  %s (%s): %+.2f%%/day | Price %.2f (Base %.2f)",
							sf.ticker, sf.name, sf.dailyDriftPct or 0, sf.currentPrice or 0, sf.basePrice or 0))
					end
				end

				local commFx = (MacroEngine.GetCommodityEffectsForCrisis) and MacroEngine.GetCommodityEffectsForCrisis(c) or {}
				if #commFx > 0 then
					ui.textColored(colors.uiPrimaryLight, "Commodity Multipliers:")
					for _, cf in ipairs(commFx) do
						ui.textWrapped(string.format("  %s -> Buy %.2fx / Sell %.2fx (%s)",
							cf.label or "Commodities", cf.buyMult or 1.0, cf.sellMult or 1.0, cf.note or ""))
					end
				end

				local taxFx = MacroEngine.GetTaxEffectForCrisis and MacroEngine.GetTaxEffectForCrisis(c) or nil
				if taxFx then
					ui.textColored(colors.alertYellow, "Tax Impact: " .. (taxFx.note or ""))
				end
				local piracyFx = MacroEngine.GetPiracyEffectForCrisis and MacroEngine.GetPiracyEffectForCrisis(c) or nil
				if piracyFx then
					ui.textColored(colors.alertRed, "Piracy / Risk Impact: " .. (piracyFx.note or ""))
				end
				ui.treePop()
			end
		end
	end

	-- 4. Stock Market Live Drivers
	if okStock and StockExchange and StockExchange.GetStockDebugBreakdown then
		if ui.collapsingHeader("Stock Market Live Drivers (Megacorps & Local Enterprises)##dbg_stocks") then
			local list = {}
			for _, corp in ipairs(StockExchange.GetMegacorps() or {}) do
				table.insert(list, corp)
			end
			if Game.system and Game.system.name and StockExchange.GetLocalEnterprises then
				for _, ent in ipairs(StockExchange.GetLocalEnterprises(Game.system.name) or {}) do
					table.insert(list, ent)
				end
			end

			if ui.beginTable("##DbgStockDrivers", 6) then
				ui.tableSetupColumn("Ticker")
				ui.tableSetupColumn("Price")
				ui.tableSetupColumn("vs Base")
				ui.tableSetupColumn("Crisis/d")
				ui.tableSetupColumn("News/d")
				ui.tableSetupColumn("Active Drivers")
				ui.tableHeadersRow()

				for _, st in ipairs(list) do
					local bd = StockExchange.GetStockDebugBreakdown(st.ticker, crises)
					if bd then
						ui.tableNextRow()
						ui.tableNextColumn()
						ui.text(bd.ticker)
						ui.tableNextColumn()
						ui.text(string.format("%.2f", bd.price or 0))
						ui.tableNextColumn()
						ui.textColored((bd.pctVsBase >= 0) and colors.econProfit or colors.econLoss, string.format("%+.1f%%", bd.pctVsBase or 0))
						ui.tableNextColumn()
						ui.textColored((bd.crisisDriftPct >= 0) and colors.econProfit or colors.econLoss, string.format("%+.2f%%", bd.crisisDriftPct or 0))
						ui.tableNextColumn()
						ui.textColored((bd.newsDriftPct >= 0) and colors.econProfit or colors.econLoss, string.format("%+.2f%%", bd.newsDriftPct or 0))
						ui.tableNextColumn()
						ui.textWrapped(#bd.drivers > 0 and table.concat(bd.drivers, " | ") or "Baseline random walk")
					end
				end
				ui.endTable()
			end
		end
	end

	-- 5. Fleet Market Saturation Ledger
	if okFleet and PlayerFleet and PlayerFleet.GetMarketSaturationSnapshot then
		local satList = PlayerFleet.GetMarketSaturationSnapshot()
		if ui.collapsingHeader(string.format("Fleet Market Saturation Ledger (%d)##dbg_sat", #satList)) then
			if #satList == 0 then
				ui.textColored(colors.fontDim, "No active station saturation imbalances.")
			else
				if ui.beginTable("##DbgSatTable", 3) then
					ui.tableSetupColumn("Station")
					ui.tableSetupColumn("Commodity")
					ui.tableSetupColumn("Net Supply Delta")
					ui.tableHeadersRow()
					for i = 1, math.min(40, #satList) do
						local rec = satList[i]
						ui.tableNextRow()
						ui.tableNextColumn()
						ui.text(rec.stationName or rec.stationKey)
						ui.tableNextColumn()
						ui.text(rec.commodity or "?")
						ui.tableNextColumn()
						ui.textColored((rec.netSupply >= 0) and colors.alertYellow or colors.uiPrimaryLight, string.format("%+.1f t", rec.netSupply or 0))
					end
					ui.endTable()
				end
			end
		end
	end
end

debugView.registerTab("debug-galaxy-sim", {
	label = "News & Galaxy Sim",
	icon = icons.comms or icons.info,
	show = function() return Game.player ~= nil end,
	draw = function()
		drawDebugGalaxySim()
	end
})

return DebugGalaxySim

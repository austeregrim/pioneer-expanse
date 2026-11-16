-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event       = require 'Event'
local Game        = require 'Game'
local PlayerState = require 'PlayerState'
local Serializer  = require 'Serializer'
local Rand        = require 'Rand'

local StockExchange = {}

-- Tier 1: Interstellar Megaconglomerates (Super High Value & Partial/Fractional Share Trading)
local MEGACORPS = {
	{
		ticker = "SIRIUS",
		name = "Sirius Heavy Industrial",
		sector = "Mining & Metallurgy",
		basePrice = 24500.00,
		price = 24500.00,
		dividendYield = 0.035, -- 3.5%
		isMegacorp = true,
		baseDailyVolume = 2850000,
		description = "The galaxy's primary mineral extraction and refining cartel, operating automated strip-mining dredgers across deep asteroid belts.",
		crisisSensitivity = { MINERAL_RUSH = 0.45, SUPPLY_GLUT = -0.65, ANTITRUST_PROBE = -0.30, BLOCKADE = -0.15, OUTBREAK = -0.08 },
	},
	{
		ticker = "COREDYN",
		name = "Core Dynamics Aerospace",
		sector = "Naval Defense & Shipframes",
		basePrice = 58200.00,
		price = 58200.00,
		dividendYield = 0.028,
		isMegacorp = true,
		baseDailyVolume = 1950000,
		description = "Premier military contractor supplying heavy battlecruiser chassis, point-defense turrets, and naval ordnance across civilized space.",
		crisisSensitivity = { BLOCKADE = 0.55, INSURGENCY = 0.40, INDUSTRIAL_DISASTER = -0.60, PEACE_SUMMIT = -0.35, ANTITRUST_PROBE = -0.25 },
	},
	{
		ticker = "CETIBIO",
		name = "Ceti BioPharm & GeneTech",
		sector = "Pharmaceuticals & Genomics",
		basePrice = 18400.00,
		price = 18400.00,
		dividendYield = 0.042,
		isMegacorp = true,
		baseDailyVolume = 3200000,
		description = "Leading developer of synthetic antigens, broad-spectrum antiviral agents, cryogenic preservation matrices, and regenerative medicine.",
		crisisSensitivity = { OUTBREAK = 0.80, FAMINE = 0.15, ANTITRUST_PROBE = -0.50, INDUSTRIAL_DISASTER = -0.30 },
	},
	{
		ticker = "AGRICORE",
		name = "AgriCore Pan-Galactic",
		sector = "Agriculture & Hydroponics",
		basePrice = 9850.00,
		price = 9850.00,
		dividendYield = 0.048,
		isMegacorp = true,
		baseDailyVolume = 4800000,
		description = "Massive food consortium operating planetary biosphere domes, algae bioreactors, and synthesized protein nutrient facilities.",
		crisisSensitivity = { FAMINE = 0.70, SUPPLY_GLUT = -0.55, TARIFF_WAR = -0.35, OUTBREAK = -0.10 },
	},
	{
		ticker = "UNITRANS",
		name = "Universal Transit & Freight",
		sector = "Hyperlane Logistics",
		basePrice = 32600.00,
		price = 32600.00,
		dividendYield = 0.032,
		isMegacorp = true,
		baseDailyVolume = 2400000,
		description = "Operates the largest commercial freighter network in the galaxy, securing bulk cargo transport between core worlds and frontier outposts.",
		crisisSensitivity = { MINERAL_RUSH = 0.30, BLOCKADE = -0.45, TARIFF_WAR = -0.60, LABOR_STRIKE = -0.40 },
	},
	{
		ticker = "GUTAMAYA",
		name = "Gutamaya Advanced Technologies",
		sector = "Luxury Starships & Avionics",
		basePrice = 74200.00,
		price = 74200.00,
		dividendYield = 0.022,
		isMegacorp = true,
		baseDailyVolume = 1100000,
		description = "Elite aerospace engineering house renowned for sleek high-performance hulls, harmonic shield emitters, and bespoke cockpit systems.",
		crisisSensitivity = { PEACE_SUMMIT = 0.30, TARIFF_WAR = -0.55, INDUSTRIAL_DISASTER = -0.45, BLOCKADE = -0.20 },
	},
	{
		ticker = "ACHILLES",
		name = "Achilles Orbital Robotics",
		sector = "Precision Robotics & AI",
		basePrice = 21900.00,
		price = 21900.00,
		dividendYield = 0.038,
		isMegacorp = true,
		baseDailyVolume = 2150000,
		description = "Supplies automated cargo handling gantries, sub-surface drill rigs, and industrial drone swarms for orbital stations.",
		crisisSensitivity = { LABOR_STRIKE = 0.35, MINERAL_RUSH = 0.30, INDUSTRIAL_DISASTER = -0.50, ANTITRUST_PROBE = -0.35 },
	},
	{
		ticker = "HELIOS",
		name = "Helios Fusion & Energy Cartel",
		sector = "Hydrogen Fuel & Fusion Cells",
		basePrice = 15300.00,
		price = 15300.00,
		dividendYield = 0.045,
		isMegacorp = true,
		baseDailyVolume = 3900000,
		description = "Monopolizes atmospheric gas giant scooping platforms and orbital deuterium distillation plants, powering civil starship drives.",
		crisisSensitivity = { BLOCKADE = 0.25, INSURGENCY = 0.20, INDUSTRIAL_DISASTER = -0.70, SUPPLY_GLUT = -0.40 },
	},
}

-- Tier 2: Faction Regional Composite Indices
local FACTION_INDICES = {
	{ ticker = "FII", name = "Federal Industrial Index", price = 42500.00, basePrice = 42500.00, change = 0.0, isIndex = true, baseDailyVolume = 8500000 },
	{ ticker = "CMI", name = "Commonwealth Market Index", price = 36800.00, basePrice = 36800.00, change = 0.0, isIndex = true, baseDailyVolume = 7200000 },
	{ ticker = "AAC", name = "Ares Alliance Composite", price = 51200.00, basePrice = 51200.00, change = 0.0, isIndex = true, baseDailyVolume = 9100000 },
	{ ticker = "ORIA", name = "Outer Rim Independent Average", price = 18400.00, basePrice = 18400.00, change = 0.0, isIndex = true, baseDailyVolume = 3400000 },
}

-- Comprehensive Daily Close-of-Day History & Volume Database
-- ticker -> array of { day = N, open = O, high = H, low = L, close = C, volume = V }
local stockHistory = {}
local localEnterprisesCache = {} -- sysName -> list of enterprises
local playerPortfolio = {} -- ticker -> { ticker, name, shares, avgBuyPrice, totalInvested, isMegacorp }
local totalDividendsCollected = 0
local daysSinceLastDividend = 0
local lastProcessedDay = 0

-- Station Market Volume Boost Calculation
function StockExchange.GetStationMarketVolumeMultiplier(sector, ticker)
	local mult = 1.0
	local station = Game.player and Game.player:GetDockedWith()
	if not station then return mult end

	-- Check station commodity market activity
	local okMkt, mkt = pcall(function() return station:GetCommodityMarket() end)
	if okMkt and mkt and mkt.stock then
		local s = mkt.stock
		if sector == "Agriculture & Hydroponics" or sector == "Food Production" or sector == "Agriculture" then
			local foodVol = (s["grain"] or 0) + (s["food"] or 0) + (s["animal_meat"] or 0) + (s["fertilizer"] or 0)
			if foodVol > 200 then mult = mult * 2.8
			elseif foodVol > 50 then mult = mult * 1.8 end
		elseif sector == "Mining & Metallurgy" or sector == "Asteroid Mining" or sector == "Mining" then
			local oreVol = (s["minerals"] or 0) + (s["precious_metals"] or 0) + (s["metals"] or 0)
			if oreVol > 200 then mult = mult * 3.2
			elseif oreVol > 50 then mult = mult * 1.9 end
		elseif sector == "Naval Defense & Shipframes" or sector == "Luxury Starships & Avionics" or sector == "Precision Robotics & AI" then
			local indVol = (s["machinery"] or 0) + (s["computers"] or 0) + (s["robotics"] or 0) + (s["plastics"] or 0)
			if indVol > 150 then mult = mult * 2.6
			elseif indVol > 40 then mult = mult * 1.7 end
		elseif sector == "Hydrogen Fuel & Fusion Cells" or sector == "Energy Storage" then
			local fuelVol = (s["hydrogen"] or 0) + (s["liquid_oxygen"] or 0) + (s["water"] or 0)
			if fuelVol > 300 then mult = mult * 3.0
			elseif fuelVol > 80 then mult = mult * 1.8 end
		elseif sector == "Hyperlane Logistics" or sector == "Orbital Logistics" then
			mult = mult * 2.2 -- Stations are freight hubs
		end
	end

	return mult
end

-- Pre-seed realistic 35-day historical candlestick & volume data for a stock
local function seedStockHistory(stock, basePrice, baseVol, seedKey)
	if stockHistory[stock.ticker] and #stockHistory[stock.ticker] > 0 then return end
	local rand = Rand.New(seedKey)
	local hist = {}
	local curPrice = basePrice * rand:Number(0.92, 1.08)
	local numDays = 35

	for d = -numDays, 0 do
		-- Valuation mean reversion: pull back toward fundamental basePrice
		local ratio = (curPrice - basePrice) / basePrice
		local meanRev = -0.024 * ratio * (1.0 + math.abs(ratio) * 0.5)

		-- Occasional small market correction / rally impulse
		local shock = 0.0
		local roll = rand:Number(0, 1)
		if roll < 0.04 then
			shock = rand:Number(-0.06, -0.03)
		elseif roll > 0.96 then
			shock = rand:Number(0.03, 0.06)
		end

		local drift = rand:Number(-0.032, 0.032) + meanRev + shock
		local openP = curPrice
		local closeP = math.max(basePrice * 0.35, math.min(basePrice * 2.8, openP * (1.0 + drift)))
		local wickHigh = rand:Number(0.005, 0.032)
		local wickLow = rand:Number(0.005, 0.032)
		local highP = math.max(openP, closeP) * (1.0 + wickHigh)
		local lowP = math.min(openP, closeP) * (1.0 - wickLow)

		-- Volume generation with random spikes
		local volFactor = rand:Number(0.65, 1.45)
		if math.abs(drift) > 0.025 then volFactor = volFactor * 1.8 end -- Volume surges on big moves
		local dailyVol = math.floor(baseVol * volFactor)

		table.insert(hist, {
			day = d,
			open = math.floor(openP * 100) / 100,
			high = math.floor(highP * 100) / 100,
			low = math.floor(lowP * 100) / 100,
			close = math.floor(closeP * 100) / 100,
			volume = dailyVol,
		})
		curPrice = closeP
	end

	stock.price = hist[#hist].close
	stockHistory[stock.ticker] = hist
end

-- Initialize base megacorps and indices
for _, corp in ipairs(MEGACORPS) do
	seedStockHistory(corp, corp.basePrice, corp.baseDailyVolume, "megacorp-" .. corp.ticker .. "-v2")
end
for _, idx in ipairs(FACTION_INDICES) do
	seedStockHistory(idx, idx.basePrice, idx.baseDailyVolume, "index-" .. idx.ticker .. "-v2")
end

function StockExchange.GetMegacorps()
	return MEGACORPS
end

function StockExchange.GetFactionIndices()
	return FACTION_INDICES
end

function StockExchange.GetStock(ticker)
	for _, corp in ipairs(MEGACORPS) do
		if corp.ticker == ticker then return corp end
	end
	for _, idx in ipairs(FACTION_INDICES) do
		if idx.ticker == ticker then return idx end
	end
	-- Check cached local enterprises
	for _, sysList in pairs(localEnterprisesCache) do
		for _, ent in ipairs(sysList) do
			if ent.ticker == ticker then return ent end
		end
	end
	-- If not found in cache, check if it's in playerPortfolio with a known system
	if playerPortfolio[ticker] and playerPortfolio[ticker].system then
		local sysList = StockExchange.GetLocalEnterprises(playerPortfolio[ticker].system)
		for _, ent in ipairs(sysList) do
			if ent.ticker == ticker then return ent end
		end
	end
	return nil
end

function StockExchange.GetStockHistory(ticker)
	return stockHistory[ticker] or {}
end

-- Backwards compatibility helper returning array of close prices
function StockExchange.GetPriceHistory(ticker)
	local hist = stockHistory[ticker]
	if not hist then return {} end
	local prices = {}
	for _, rec in ipairs(hist) do
		table.insert(prices, rec.close)
	end
	return prices
end

-- Get comprehensive 24h & 52-week summary statistics for charts
function StockExchange.Get24hStats(ticker)
	local hist = stockHistory[ticker]
	local stock = StockExchange.GetStock(ticker)
	local curP = stock and stock.price or 100.0
	if not hist or #hist == 0 then
		return {
			currentPrice = curP,
			openPrice = curP,
			high24h = curP * 1.02,
			low24h = curP * 0.98,
			changeCr = 0.0,
			changePct = 0.0,
			volume24h = 100000,
			high52w = curP * 1.25,
			low52w = curP * 0.75,
		}
	end

	local latest = hist[#hist]
	local prev = hist[#hist - 1] or latest
	local changeCr = math.floor((latest.close - prev.close) * 100) / 100
	local changePct = (prev.close > 0) and math.floor(((changeCr / prev.close) * 100) * 100) / 100 or 0.0

	local high52w = latest.high
	local low52w = latest.low
	for _, r in ipairs(hist) do
		if r.high > high52w then high52w = r.high end
		if r.low < low52w then low52w = r.low end
	end

	return {
		currentPrice = latest.close,
		openPrice = latest.open,
		high24h = latest.high,
		low24h = latest.low,
		changeCr = changeCr,
		changePct = changePct,
		volume24h = latest.volume,
		high52w = high52w,
		low52w = low52w,
	}
end

-- Procedural Tier 3: Local System Enterprises (Whole Shares Only, Lower Values)
function StockExchange.GetLocalEnterprises(sysName)
	if not sysName or sysName == "" then sysName = "Sol" end
	if localEnterprisesCache[sysName] then
		return localEnterprisesCache[sysName]
	end

	local rand = Rand.New(sysName .. "-stocks-v2")

	local templates = {
		{ suffix = "Primary Bio-Labs", parent = "CETIBIO", sector = "Pharmaceuticals", base = 125.0, mult = 0.95 },
		{ suffix = "Orbital Belter Dredging", parent = "SIRIUS", sector = "Asteroid Mining", base = 180.0, mult = 1.10 },
		{ suffix = "Planetary Agro-Synthetics", parent = "AGRICORE", sector = "Food Production", base = 65.0, mult = 0.85 },
		{ suffix = "Transit & Port Authority", parent = "UNITRANS", sector = "Orbital Logistics", base = 210.0, mult = 1.05 },
		{ suffix = "System Defense Auxiliary", parent = "COREDYN", sector = "Private Security", base = 340.0, mult = 1.30 },
		{ suffix = "Atmospheric Fuel Refining", parent = "HELIOS", sector = "Energy Storage", base = 95.0, mult = 0.90 },
	}

	-- Check if system has an active crisis from MacroGalaxyEngine
	local okMacro, MacroEngine = pcall(require, 'modules.MacroGalaxy.MacroGalaxyEngine')
	local activeCrisis = okMacro and MacroEngine and MacroEngine.GetCrisisForSystem(sysName)

	local enterprises = {}
	for i, t in ipairs(templates) do
		local parentCorp = StockExchange.GetStock(t.parent)
		local localBase = t.base * t.mult * rand:Number(0.85, 1.25)

		-- Apply local crisis multiplier if relevant
		local crisisImpactNote = nil
		if activeCrisis then
			local sev = activeCrisis.severity or 1
			local isResolution = (sev >= 3)

			if activeCrisis.type == "OUTBREAK" and t.parent == "CETIBIO" then
				if isResolution then
					localBase = localBase * 0.70
					crisisImpactNote = "SLUMPING: Post-Epidemic Vaccine Contract Expiration"
				else
					localBase = localBase * (2.4 + (sev * 0.6))
					crisisImpactNote = "SURGING: Outbreak Vaccine Contract Demand"
				end
			elseif activeCrisis.type == "FAMINE" and t.parent == "AGRICORE" then
				if isResolution then
					localBase = localBase * 0.75
					crisisImpactNote = "NORMALIZING: Caloric Aid Convoys Completed"
				else
					localBase = localBase * (2.2 + (sev * 0.5))
					crisisImpactNote = "SURGING: Emergency Caloric Relief Subsidy"
				end
			elseif (activeCrisis.type == "BLOCKADE" or activeCrisis.type == "INSURGENCY") and t.parent == "COREDYN" then
				if isResolution then
					localBase = localBase * 0.80
					crisisImpactNote = "COOLING: Armistice Declared; Ordnance Orders Halting"
				else
					localBase = localBase * (2.0 + (sev * 0.4))
					crisisImpactNote = "SURGING: Military Defense Procurement"
				end
			elseif (activeCrisis.type == "BLOCKADE" or activeCrisis.type == "INSURGENCY") and t.parent == "UNITRANS" then
				if isResolution then
					localBase = localBase * 1.35
					crisisImpactNote = "REBOUNDING: Jump Corridors Reopened Post-Armistice"
				else
					localBase = localBase * 0.45
					crisisImpactNote = "PLUNGING: Orbital Blockade Freight Interdiction"
				end
			elseif activeCrisis.type == "MINERAL_RUSH" and t.parent == "SIRIUS" then
				if isResolution then
					localBase = localBase * 0.65
					crisisImpactNote = "PLUNGING: Asteroid Vein Assay Depleted"
				else
					localBase = localBase * (2.2 + (sev * 0.5))
					crisisImpactNote = "SURGING: High-Yield Asteroid Assay Strike"
				end
			elseif activeCrisis.type == "SUPPLY_GLUT" and (t.parent == "SIRIUS" or t.parent == "HELIOS") then
				localBase = localBase * 0.40
				crisisImpactNote = "CRASHING: Extreme Smelting & Fuel Inventory Glut"
			elseif activeCrisis.type == "ANTITRUST_PROBE" and (t.parent == "CETIBIO" or t.parent == "COREDYN") then
				localBase = localBase * 0.50
				crisisImpactNote = "PLUNGING: Punitive Regulatory Antitrust Sanctions"
			elseif activeCrisis.type == "INDUSTRIAL_DISASTER" and (t.parent == "COREDYN" or t.parent == "HELIOS") then
				localBase = localBase * 0.35
				crisisImpactNote = "COLLAPSING: Critical Refinery Core Breach & Grounding"
			elseif activeCrisis.type == "TARIFF_WAR" and (t.parent == "UNITRANS" or t.parent == "AGRICORE") then
				localBase = localBase * 0.45
				crisisImpactNote = "SLUMPING: Retaliatory Customs Embargo & Freight Voiding"
			elseif activeCrisis.type == "LABOR_STRIKE" and (t.parent == "UNITRANS" or t.parent == "SIRIUS") then
				localBase = localBase * 0.55
				crisisImpactNote = "HALTED: General Dockworkers & Gantry Strike"
			end
		end

		local ticker = string.upper(string.sub(sysName, 1, 3)) .. "_" .. string.sub(t.parent, 1, 3) .. tostring(i)
		local baseVol = math.floor(rand:Number(18000, 65000))

		local ent = {
			ticker = ticker,
			name = string.format("%s %s", sysName, t.suffix),
			parent = t.parent,
			parentName = parentCorp and parentCorp.name or "Interstellar Holding",
			sector = t.sector,
			system = sysName,
			basePrice = math.floor(localBase * 100) / 100,
			price = math.floor(localBase * 100) / 100,
			crisisNote = crisisImpactNote,
			dividendYield = 0.030,
			isMegacorp = false, -- Whole shares strictly enforced
			baseDailyVolume = baseVol,
			description = string.format("Local chartered system enterprise operating out of %s under corporate charter from %s.", sysName, parentCorp and parentCorp.name or "holding authority"),
		}

		-- Pre-seed historical candlesticks for this local stock
		seedStockHistory(ent, ent.basePrice, ent.baseDailyVolume, sysName .. "-" .. ticker)

		table.insert(enterprises, ent)
	end

	localEnterprisesCache[sysName] = enterprises
	return enterprises
end

function StockExchange.GetPlayerPortfolio()
	return playerPortfolio
end

function StockExchange.GetTotalDividends()
	return totalDividendsCollected
end

function StockExchange.GetPortfolioNetWorth()
	local total = 0
	for ticker, holding in pairs(playerPortfolio) do
		local stock = StockExchange.GetStock(ticker)
		local currentPrice = stock and stock.price or holding.avgBuyPrice
		total = total + (holding.shares * currentPrice)
	end
	return total
end

function StockExchange.GetTotalUnrealizedProfit()
	local profit = 0
	for ticker, holding in pairs(playerPortfolio) do
		local stock = StockExchange.GetStock(ticker)
		local currentPrice = stock and stock.price or holding.avgBuyPrice
		local currentVal = holding.shares * currentPrice
		profit = profit + (currentVal - holding.totalInvested)
	end
	return profit
end

function StockExchange.CanBuyStock(stock)
	if not stock then return false, "Invalid equity" end
	if stock.isMegacorp then return true end
	local currentSys = Game.system and Game.system.name or "Sol"
	local stockSys = stock.system or (playerPortfolio[stock.ticker] and playerPortfolio[stock.ticker].system)
	if stockSys and stockSys ~= currentSys then
		return false, string.format("Physical presence in the %s system required to purchase new shares. Remote liquidation is permitted.", stockSys)
	end
	return true
end

-- Buy Shares:
-- Megacorps: partial/fractional shares permitted down to 0.000001 (micro-shares)
-- Local System Enterprises: whole shares strictly enforced (count integer >= 1)
function StockExchange.BuyShares(stock, count)
	if not stock or not count or count <= 0 then return false, "Invalid order" end

	local canBuy, buyReason = StockExchange.CanBuyStock(stock)
	if not canBuy then
		return false, buyReason
	end

	-- Check whole share enforcement
	if not stock.isMegacorp then
		count = math.floor(count)
		if count < 1 then
			return false, "Local system enterprise stocks require whole share transactions (minimum 1 share)"
		end
	else
		-- Megacorp fractional rounding to 6 decimals
		count = math.floor(count * 1000000 + 0.5) / 1000000
		if count < 0.000001 then
			return false, "Minimum fractional order for Megacorps is 0.000001 shares"
		end
	end

	local cost = math.floor(stock.price * count * 100) / 100
	if cost < 0.01 then cost = 0.01 end

	if PlayerState.GetMoney() < cost then
		return false, "Insufficient funds"
	end

	PlayerState.AddMoney(-cost)

	local h = playerPortfolio[stock.ticker]
	if not h then
		h = {
			ticker = stock.ticker,
			name = stock.name,
			shares = 0.0,
			avgBuyPrice = stock.price,
			totalInvested = 0.0,
			isMegacorp = stock.isMegacorp or false,
			system = stock.system or (not stock.isMegacorp and Game.system and Game.system.name),
		}
		playerPortfolio[stock.ticker] = h
	else
		if not h.system and stock.system then
			h.system = stock.system
		end
	end

	h.totalInvested = h.totalInvested + cost
	h.shares = h.shares + count
	h.avgBuyPrice = h.totalInvested / h.shares
	h.name = stock.name

	-- Add to today's trade volume on exchange
	local hist = stockHistory[stock.ticker]
	if hist and #hist > 0 then
		hist[#hist].volume = hist[#hist].volume + math.max(1, math.floor(count))
	end

	local shareStr
	if not stock.isMegacorp then
		shareStr = string.format("%d", count)
	elseif count < 0.01 then
		shareStr = string.format("%.6f", count)
	elseif count < 1.0 then
		shareStr = string.format("%.4f", count)
	else
		shareStr = string.format("%.3f", count)
	end

	return true, string.format("Purchased %s shares of %s for %.2f Cr", shareStr, stock.ticker, cost)
end

-- Buy Shares by Credit Value (e.g. "Buy 20 Cr of Sirius" -> calculates exact fractional share)
function StockExchange.BuySharesByCredits(stock, creditAmount)
	if not stock or not creditAmount or creditAmount <= 0 then return false, "Invalid credit amount" end

	local canBuy, buyReason = StockExchange.CanBuyStock(stock)
	if not canBuy then
		return false, buyReason
	end

	creditAmount = math.floor(creditAmount * 100) / 100
	if creditAmount < 0.01 then return false, "Minimum investment amount is 0.01 Cr" end

	if PlayerState.GetMoney() < creditAmount then
		return false, "Insufficient funds"
	end

	if not stock.isMegacorp then
		local wholeShares = math.floor(creditAmount / stock.price)
		if wholeShares < 1 then
			return false, string.format("Local enterprise stocks require whole share purchases. 1 share of %s costs %.2f Cr.", stock.ticker, stock.price)
		end
		return StockExchange.BuyShares(stock, wholeShares)
	else
		local shares = creditAmount / stock.price
		shares = math.floor(shares * 1000000 + 0.5) / 1000000
		if shares < 0.000001 then
			return false, "Credit amount too small for minimum 0.000001 share transaction"
		end
		return StockExchange.BuyShares(stock, shares)
	end
end

-- Sell Shares:
-- Megacorps: fractional sale supported
-- Local Enterprises: whole share sale enforced
function StockExchange.SellShares(stock, count)
	if not stock or not count or count <= 0 then return false, "Invalid order" end
	local h = playerPortfolio[stock.ticker]
	if not h or h.shares <= 0.000001 then
		return false, "You do not own any shares of this equity"
	end

	if not stock.isMegacorp then
		count = math.floor(count)
		if count < 1 then
			return false, "Local system enterprise stocks require whole share transactions (minimum 1 share)"
		end
	else
		count = math.floor(count * 1000000 + 0.5) / 1000000
		if count < 0.000001 then
			return false, "Minimum fractional order is 0.000001 shares"
		end
	end

	if count > (h.shares + 0.000001) then
		return false, "Insufficient shares owned for this order"
	end

	-- Cap count to exact holding to avoid infinitesimal floats
	if count > h.shares then count = h.shares end

	local proceeds = math.floor(stock.price * count * 100) / 100
	PlayerState.AddMoney(proceeds)

	local fractionSold = math.min(1.0, count / h.shares)
	h.totalInvested = math.max(0.0, h.totalInvested * (1.0 - fractionSold))
	h.shares = h.shares - count

	if h.shares < 0.000001 then
		playerPortfolio[stock.ticker] = nil
	end

	-- Add to today's trade volume on exchange
	local hist = stockHistory[stock.ticker]
	if hist and #hist > 0 then
		hist[#hist].volume = hist[#hist].volume + math.max(1, math.floor(count))
	end

	local shareStr
	if not stock.isMegacorp then
		shareStr = string.format("%d", count)
	elseif count < 0.01 then
		shareStr = string.format("%.6f", count)
	elseif count < 1.0 then
		shareStr = string.format("%.4f", count)
	else
		shareStr = string.format("%.3f", count)
	end

	return true, string.format("Sold %s shares of %s for %.2f Cr", shareStr, stock.ticker, proceeds)
end

-- Sell Shares by Credit Value
function StockExchange.SellSharesByCredits(stock, creditAmount)
	if not stock or not creditAmount or creditAmount <= 0 then return false, "Invalid credit amount" end
	local h = playerPortfolio[stock.ticker]
	if not h or h.shares <= 0.000001 then
		return false, "You do not own any shares of this equity"
	end

	if not stock.isMegacorp then
		local wholeShares = math.min(math.floor(h.shares), math.max(1, math.floor(creditAmount / stock.price + 0.5)))
		return StockExchange.SellShares(stock, wholeShares)
	else
		local sharesToSell = math.min(h.shares, creditAmount / stock.price)
		sharesToSell = math.floor(sharesToSell * 1000000 + 0.5) / 1000000
		return StockExchange.SellShares(stock, sharesToSell)
	end
end

-- Advance a single stock by 1 daily close-of-day step
local function advanceStockDay(stock, dayNum, rand, activeCrises)
	local hist = stockHistory[stock.ticker]
	if not hist or #hist == 0 then return end
	local prev = hist[#hist]

	-- 1. Emergent GalNet Crisis Impact with Stage Progression Dynamics
	local crisisImpact = 0.0
	if activeCrises then
		for _, c in ipairs(activeCrises) do
			if stock.crisisSensitivity and stock.crisisSensitivity[c.type] then
				local sens = stock.crisisSensitivity[c.type]
				local sev = c.severity or 1

				-- Stage progression factor:
				-- Stage 1: Incipient / Escalating (+75% impact)
				-- Stage 2: Peak Crisis Emergency (+130% impact)
				-- Stage 3+: Resolution / Hangover (-55% impact: boom turns to contraction, penalties turn to relief rally)
				local stageFactor = 1.0
				if sev == 1 then
					stageFactor = 0.75
				elseif sev == 2 then
					stageFactor = 1.30
				else
					stageFactor = -0.55
				end

				crisisImpact = crisisImpact + (sens * stageFactor * 0.026)
			end
		end
	end

	-- 2. Valuation Mean Reversion (Valuation Gravity & Value Bargain Hunting)
	local priceRatio = (prev.close - stock.basePrice) / stock.basePrice
	-- Ornstein-Uhlenbeck gravitational pull accelerating when overextended:
	local meanReversion = -0.022 * priceRatio * (1.0 + math.abs(priceRatio) * 0.5)

	-- 3. Symmetric Daily Noise (Zero-mean baseline)
	local noise = rand:Number(-0.032, 0.032)

	-- 4. Corporate Micro-Shocks (3% chance of negative shock, 3% chance of positive beat)
	local shock = 0.0
	local shockRoll = rand:Number(0, 1)
	if shockRoll < 0.035 then
		shock = rand:Number(-0.065, -0.03) -- Negative surprise / recall / earnings miss
	elseif shockRoll > 0.965 then
		shock = rand:Number(0.03, 0.065)  -- Positive beat / patent / export contract
	end

	local totalDrift = noise + meanReversion + crisisImpact + shock
	local openP = prev.close
	local newClose = math.max(stock.basePrice * 0.30, math.min(stock.basePrice * 3.0, openP * (1.0 + totalDrift)))
	newClose = math.floor(newClose * 100) / 100
	stock.price = newClose

	local wickH = rand:Number(0.005, 0.032)
	local wickL = rand:Number(0.005, 0.032)
	local highP = math.floor(math.max(openP, newClose) * (1.0 + wickH) * 100) / 100
	local lowP = math.floor(math.min(openP, newClose) * (1.0 - wickL) * 100) / 100

	-- Daily volume calculation tied into market ties
	local volMult = StockExchange.GetStationMarketVolumeMultiplier(stock.sector, stock.ticker)
	local volRand = rand:Number(0.70, 1.40)
	if math.abs(totalDrift) > 0.025 then volRand = volRand * 1.8 end
	local dailyVol = math.floor((stock.baseDailyVolume or 100000) * volRand * volMult)

	table.insert(hist, {
		day = dayNum,
		open = openP,
		high = highP,
		low = lowP,
		close = newClose,
		volume = dailyVol,
	})

	-- Retain last 90 daily records
	if #hist > 90 then table.remove(hist, 1) end
end

-- Daily close-of-day simulation step triggered on calendar day change or macro tick
function StockExchange.OnMacroTick(deltaDays, activeCrises)
	if deltaDays <= 0 then return end
	local currentDay = math.floor((Game.time or 0) / 86400)
	local randSeed = math.floor((Game.time or 0) * 1000)
	if randSeed == 0 then randSeed = 1234567 end
	local rand = Rand.New(randSeed)

	-- Process all elapsed days
	local daysToStep = math.min(10, math.max(1, math.floor(deltaDays)))
	for step = 1, daysToStep do
		local dayNum = currentDay - (daysToStep - step)

		for _, corp in ipairs(MEGACORPS) do
			advanceStockDay(corp, dayNum, rand, activeCrises)
		end

		for _, idx in ipairs(FACTION_INDICES) do
			advanceStockDay(idx, dayNum, rand, nil)
			local h = stockHistory[idx.ticker]
			if h and #h >= 2 then
				idx.change = math.floor((h[#h].close - h[#h - 1].close) * 100) / 100
			end
		end

		for _, sysList in pairs(localEnterprisesCache) do
			for _, ent in ipairs(sysList) do
				advanceStockDay(ent, dayNum, rand, activeCrises)
			end
		end
	end

	-- Quarterly Dividend evaluation (every 30 calendar days)
	daysSinceLastDividend = daysSinceLastDividend + deltaDays
	if daysSinceLastDividend >= 30.0 then
		daysSinceLastDividend = 0.0
		local dividendPayout = 0
		for ticker, h in pairs(playerPortfolio) do
			local corp = StockExchange.GetStock(ticker)
			if corp and corp.dividendYield then
				local divPerShare = (corp.price * corp.dividendYield) / 4.0 -- Quarterly
				local corpTotal = divPerShare * h.shares
				dividendPayout = dividendPayout + corpTotal
			end
		end
		if dividendPayout > 0 then
			PlayerState.AddMoney(dividendPayout)
			totalDividendsCollected = totalDividendsCollected + dividendPayout
		end
	end
end

-- Check day transitions during normal play
Event.Register("onGameUpdate", function()
	local currentDay = math.floor((Game.time or 0) / 86400)
	if lastProcessedDay == 0 then
		lastProcessedDay = currentDay
		return
	end
	if currentDay > lastProcessedDay then
		local daysDiff = currentDay - lastProcessedDay
		lastProcessedDay = currentDay
		StockExchange.OnMacroTick(daysDiff, nil)
	end
end)

local function serialize()
	local corpPrices = {}
	for _, c in ipairs(MEGACORPS) do
		corpPrices[c.ticker] = c.price
	end
	return {
		corpPrices = corpPrices,
		playerPortfolio = playerPortfolio,
		totalDividendsCollected = totalDividendsCollected,
		daysSinceLastDividend = daysSinceLastDividend,
		stockHistory = stockHistory,
		lastProcessedDay = lastProcessedDay,
	}
end

local function unserialize(data)
	if data then
		if data.corpPrices then
			for _, c in ipairs(MEGACORPS) do
				if data.corpPrices[c.ticker] then
					c.price = data.corpPrices[c.ticker]
				end
			end
		end
		playerPortfolio = data.playerPortfolio or {}
		-- Pre-cache local enterprises for any holdings the player owns
		for ticker, h in pairs(playerPortfolio) do
			if not h.isMegacorp then
				if not h.system and h.name then
					h.system = h.name:match("^(.-)%s+")
				end
				if h.system then
					StockExchange.GetLocalEnterprises(h.system)
				end
			end
		end
		totalDividendsCollected = data.totalDividendsCollected or 0
		daysSinceLastDividend = data.daysSinceLastDividend or 0
		if data.stockHistory then
			stockHistory = data.stockHistory
		end
		lastProcessedDay = data.lastProcessedDay or 0
	end
end

Serializer:Register("StockExchangeDB", serialize, unserialize)

return StockExchange

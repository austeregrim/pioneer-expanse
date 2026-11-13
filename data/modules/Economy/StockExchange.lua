-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event       = require 'Event'
local Game        = require 'Game'
local PlayerState = require 'PlayerState'
local Serializer  = require 'Serializer'
local Rand       = require 'Rand'

local StockExchange = {}

-- Tier 1: Interstellar Megaconglomerates
local MEGACORPS = {
	{
		ticker = "SIRIUS",
		name = "Sirius Heavy Industrial",
		sector = "Mining & Metallurgy",
		basePrice = 142.50,
		price = 142.50,
		dividendYield = 0.035, -- 3.5%
		description = "The galaxy's primary mineral extraction and refining cartel, operating automated strip-mining dredgers across deep asteroid belts.",
		crisisSensitivity = { MINERAL_RUSH = 0.45, BLOCKADE = -0.15, OUTBREAK = -0.05 },
	},
	{
		ticker = "COREDYN",
		name = "Core Dynamics Aerospace",
		sector = "Naval Defense & Shipframes",
		basePrice = 310.00,
		price = 310.00,
		dividendYield = 0.028,
		description = "Premier military contractor supplying heavy battlecruiser chassis, point-defense turrets, and naval ordnance across civilized space.",
		crisisSensitivity = { BLOCKADE = 0.55, INSURGENCY = 0.40, PEACE_SUMMIT = -0.20 },
	},
	{
		ticker = "CETIBIO",
		name = "Ceti BioPharm & GeneTech",
		sector = "Pharmaceuticals & Genomics",
		basePrice = 88.20,
		price = 88.20,
		dividendYield = 0.042,
		description = "Leading developer of synthetic antigens, broad-spectrum antiviral agents, cryogenic preservation matrices, and regenerative medicine.",
		crisisSensitivity = { OUTBREAK = 0.85, FAMINE = 0.15 },
	},
	{
		ticker = "AGRICORE",
		name = "AgriCore Pan-Galactic",
		sector = "Agriculture & Hydroponics",
		basePrice = 45.60,
		price = 45.60,
		dividendYield = 0.048,
		description = "Massive food consortium operating planetary biosphere domes, algae bioreactors, and synthesized protein nutrient facilities.",
		crisisSensitivity = { FAMINE = 0.70, OUTBREAK = -0.10 },
	},
	{
		ticker = "UNITRANS",
		name = "Universal Transit & Freight",
		sector = "Hyperlane Logistics",
		basePrice = 195.40,
		price = 195.40,
		dividendYield = 0.032,
		description = "Operates the largest commercial freighter network in the galaxy, securing bulk cargo transport between core worlds and frontier outposts.",
		crisisSensitivity = { BLOCKADE = -0.35, LABOR_STRIKE = -0.25, MINERAL_RUSH = 0.30 },
	},
	{
		ticker = "GUTAMAYA",
		name = "Gutamaya Advanced Technologies",
		sector = "Luxury Starships & Avionics",
		basePrice = 420.00,
		price = 420.00,
		dividendYield = 0.022,
		description = "Elite aerospace engineering house renowned for sleek high-performance hulls, harmonic shield emitters, and bespoke cockpit systems.",
		crisisSensitivity = { PEACE_SUMMIT = 0.20, BLOCKADE = -0.15 },
	},
	{
		ticker = "ACHILLES",
		name = "Achilles Orbital Robotics",
		sector = "Precision Robotics & AI",
		basePrice = 115.80,
		price = 115.80,
		dividendYield = 0.038,
		description = "Supplies automated cargo handling gantries, sub-surface drill rigs, and industrial drone swarms for orbital stations.",
		crisisSensitivity = { LABOR_STRIKE = 0.35, MINERAL_RUSH = 0.30 },
	},
	{
		ticker = "HELIOS",
		name = "Helios Fusion & Energy Cartel",
		sector = "Hydrogen Fuel & Fusion Cells",
		basePrice = 76.40,
		price = 76.40,
		dividendYield = 0.045,
		description = "Monopolizes atmospheric gas giant scooping platforms and orbital deuterium distillation plants, powering civil starship drives.",
		crisisSensitivity = { BLOCKADE = 0.25, INSURGENCY = 0.20 },
	},
}

-- Tier 2: Faction Regional Composite Indices
local FACTION_INDICES = {
	{ ticker = "FII", name = "Federal Industrial Index", price = 1250.00, change = 0.0 },
	{ ticker = "CMI", name = "Commonwealth Market Index", price = 980.00, change = 0.0 },
	{ ticker = "AAC", name = "Ares Alliance Composite", price = 1420.00, change = 0.0 },
	{ ticker = "ORIA", name = "Outer Rim Independent Average", price = 640.00, change = 0.0 },
}

local priceHistory = {} -- ticker -> table of last 10 prices
local playerPortfolio = {} -- ticker -> { shares = N, avgBuyPrice = X, totalInvested = Y }
local totalDividendsCollected = 0
local daysSinceLastDividend = 0

-- Initialize price histories
for _, corp in ipairs(MEGACORPS) do
	priceHistory[corp.ticker] = { corp.price, corp.price, corp.price, corp.price, corp.price }
end
for _, idx in ipairs(FACTION_INDICES) do
	priceHistory[idx.ticker] = { idx.price, idx.price, idx.price, idx.price, idx.price }
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
	return nil
end

function StockExchange.GetPriceHistory(ticker)
	return priceHistory[ticker] or {}
end

-- Procedural Tier 3: Local System Enterprises generated on demand when docked
function StockExchange.GetLocalEnterprises(sysName)
	if not sysName or sysName == "" then sysName = "Local" end
	local rand = Rand.New(sysName .. "-stocks-v1")

	local templates = {
		{ suffix = "Primary Bio-Labs", parent = "CETIBIO", sector = "Pharmaceuticals", mult = 0.95 },
		{ suffix = "Orbital Belter Dredging", parent = "SIRIUS", sector = "Asteroid Mining", mult = 1.10 },
		{ suffix = "Planetary Agro-Synthetics", parent = "AGRICORE", sector = "Food Production", mult = 0.85 },
		{ suffix = "Transit & Port Authority", parent = "UNITRANS", sector = "Orbital Logistics", mult = 1.05 },
		{ suffix = "System Defense Auxiliary", parent = "COREDYN", sector = "Private Security", mult = 1.30 },
		{ suffix = "Atmospheric Fuel Refining", parent = "HELIOS", sector = "Energy Storage", mult = 0.90 },
	}

	-- Check if system has an active crisis from MacroGalaxyEngine
	local okMacro, MacroEngine = pcall(require, 'modules.MacroGalaxy.MacroGalaxyEngine')
	local activeCrisis = okMacro and MacroEngine and MacroEngine.GetCrisisForSystem(sysName)

	local enterprises = {}
	for i, t in ipairs(templates) do
		local parentCorp = StockExchange.GetStock(t.parent)
		local base = parentCorp and parentCorp.price or 100.0
		local localPrice = base * t.mult * rand:Number(0.85, 1.15)

		-- Apply massive local crisis multiplier if relevant
		local crisisImpactNote = nil
		if activeCrisis then
			if activeCrisis.type == "OUTBREAK" and t.parent == "CETIBIO" then
				localPrice = localPrice * (2.8 + (activeCrisis.severity * 0.7)) -- Up to +500%
				crisisImpactNote = "SURGING: Outbreak Vaccine Contract Demand"
			elseif activeCrisis.type == "FAMINE" and t.parent == "AGRICORE" then
				localPrice = localPrice * (2.5 + (activeCrisis.severity * 0.5))
				crisisImpactNote = "SURGING: Emergency Caloric Relief Subsidy"
			elseif (activeCrisis.type == "BLOCKADE" or activeCrisis.type == "INSURGENCY") and t.parent == "COREDYN" then
				localPrice = localPrice * (2.2 + (activeCrisis.severity * 0.4))
				crisisImpactNote = "SURGING: Military Defense Procurement"
			elseif (activeCrisis.type == "BLOCKADE" or activeCrisis.type == "INSURGENCY") and t.parent == "UNITRANS" then
				localPrice = localPrice * 0.45 -- Plunges -55%
				crisisImpactNote = "PLUNGING: Orbital Blockade Freight Interdiction"
			elseif activeCrisis.type == "MINERAL_RUSH" and t.parent == "SIRIUS" then
				localPrice = localPrice * (2.4 + (activeCrisis.severity * 0.6))
				crisisImpactNote = "SURGING: High-Yield Asteroid Assay Strike"
			end
		end

		local ticker = string.upper(string.sub(sysName, 1, 3)) .. "_" .. string.sub(t.parent, 1, 3) .. tostring(i)

		table.insert(enterprises, {
			ticker = ticker,
			name = string.format("%s %s", sysName, t.suffix),
			parent = t.parent,
			parentName = parentCorp and parentCorp.name or "Interstellar Holding",
			sector = t.sector,
			price = math.floor(localPrice * 100) / 100,
			crisisNote = crisisImpactNote,
			dividendYield = 0.030,
		})
	end

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

function StockExchange.BuyShares(stock, count)
	if not stock or count <= 0 then return false, "Invalid order" end
	local cost = stock.price * count
	if PlayerState.GetMoney() < cost then
		return false, "Insufficient funds"
	end

	PlayerState.AddMoney(-cost)

	local h = playerPortfolio[stock.ticker]
	if not h then
		h = {
			ticker = stock.ticker,
			name = stock.name,
			shares = 0,
			avgBuyPrice = stock.price,
			totalInvested = 0,
		}
		playerPortfolio[stock.ticker] = h
	end

	h.totalInvested = h.totalInvested + cost
	h.shares = h.shares + count
	h.avgBuyPrice = h.totalInvested / h.shares
	h.name = stock.name

	return true, string.format("Purchased %d shares of %s for %s Cr", count, stock.ticker, string.format("%.2f", cost))
end

function StockExchange.SellShares(stock, count)
	if not stock or count <= 0 then return false, "Invalid order" end
	local h = playerPortfolio[stock.ticker]
	if not h or h.shares < count then
		return false, "Insufficient shares owned"
	end

	local proceeds = stock.price * count
	PlayerState.AddMoney(proceeds)

	local fractionSold = count / h.shares
	h.totalInvested = h.totalInvested * (1.0 - fractionSold)
	h.shares = h.shares - count

	if h.shares <= 0 then
		playerPortfolio[stock.ticker] = nil
	end

	return true, string.format("Sold %d shares of %s for %s Cr", count, stock.ticker, string.format("%.2f", proceeds))
end

-- Called by MacroGalaxyEngine during macro simulation ticks
function StockExchange.OnMacroTick(deltaDays, activeCrises)
	if deltaDays <= 0 then return end
	local rand = Rand.New(math.floor(Game.time or os.time()))

	-- Update Megacorporation prices
	for _, corp in ipairs(MEGACORPS) do
		local crisisImpact = 0.0
		if activeCrises then
			for _, c in ipairs(activeCrises) do
				if corp.crisisSensitivity and corp.crisisSensitivity[c.type] then
					crisisImpact = crisisImpact + (corp.crisisSensitivity[c.type] * 0.04 * (c.severity or 1))
				end
			end
		end

		-- Natural drift + random walk volatility
		local volatility = rand:Number(-0.04, 0.04) * deltaDays
		local totalFactor = 1.0 + crisisImpact + volatility
		-- Keep within reasonable bounds (between 0.35x and 4.0x baseline)
		local newPrice = math.max(corp.basePrice * 0.35, math.min(corp.basePrice * 4.0, corp.price * totalFactor))
		corp.price = math.floor(newPrice * 100) / 100

		-- Record price history
		local hist = priceHistory[corp.ticker]
		if hist then
			table.insert(hist, corp.price)
			if #hist > 10 then table.remove(hist, 1) end
		end
	end

	-- Update Faction Indices
	for _, idx in ipairs(FACTION_INDICES) do
		local drift = rand:Number(-0.025, 0.025) * deltaDays
		local oldPrice = idx.price
		idx.price = math.floor((idx.price * (1.0 + drift)) * 100) / 100
		idx.change = math.floor((idx.price - oldPrice) * 100) / 100

		local hist = priceHistory[idx.ticker]
		if hist then
			table.insert(hist, idx.price)
			if #hist > 10 then table.remove(hist, 1) end
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
		priceHistory = priceHistory,
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
		totalDividendsCollected = data.totalDividendsCollected or 0
		daysSinceLastDividend = data.daysSinceLastDividend or 0
		priceHistory = data.priceHistory or priceHistory
	end
end

Serializer:Register("StockExchangeDB", serialize, unserialize)

return StockExchange


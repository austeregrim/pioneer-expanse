-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game = require 'Game'
local PlayerState = require 'PlayerState'
local Serializer = require 'Serializer'
local Event = require 'Event'

local SECONDS_PER_DAY = 24 * 60 * 60
local RESIDENCY_TERM_DAYS = 90
local FILING_PERIOD_DAYS = 30
local DELINQUENCY_PENALTY_RATE = 0.05
local WINDFALL_TAX_RATE = 0.30

local TaxAuthority = {}

local state = {
	isResident = false,
	homeStationName = "None",
	homeSystemName = "None",
	homeFaction = "Stateless / Independent",
	homeStationPath = nil,
	residencyTimestamp = 0,

	accruedTax = 0,
	filingDueDate = 0,
	isDelinquent = false,
	penaltyApplied = false,

	breakdown = {
		tradeProfitTax = 0,
		bbsJobsTax = 0,
		cartographyTax = 0,
		exemptIncome = 0,
		windfallTaxWithheld = 0,
	},

	stats = {
		totalTaxPaid = 0,
		totalTradeProfitTax = 0,
		totalBBSJobsTax = 0,
		totalCartographyTax = 0,
		totalExemptIncome = 0,
		totalWindfallTaxWithheld = 0,
	},

	cargoCostBasis = {} -- commodityName -> { count = N, avgPrice = X }
}

-- Faction baseline income tax rates
local FACTION_BASELINE_RATES = {
	["Sol Federation"]       = 0.12,
	["Earth Federation"]     = 0.12,
	["Sol Alliance"]         = 0.12,
	["Commonwealth"]         = 0.10,
	["CIW"]                  = 0.10,
	["United Earth"]         = 0.12,
	["Ares Corporation"]     = 0.06,
	["Sirius Mining"]        = 0.06,
	["Corporate Combine"]    = 0.06,
	["Independent Systems"]  = 0.04,
	["Free Worlds Council"]  = 0.04,
	["Anarchy"]              = 0.00,
	["Pirate Clan"]          = 0.00,
}

local function getFactionBaseline(factionName)
	if not factionName or factionName == "" then return 0.04 end
	local lower = string.lower(factionName)
	if string.find(lower, "anarch") or string.find(lower, "pirate") or string.find(lower, "lawless") then
		return 0.00
	elseif string.find(lower, "sol") or string.find(lower, "earth") or string.find(lower, "federation") then
		return 0.12
	elseif string.find(lower, "commonwealth") or string.find(lower, "ciw") or string.find(lower, "alliance") then
		return 0.10
	elseif string.find(lower, "corp") or string.find(lower, "mining") or string.find(lower, "syndicate") then
		return 0.06
	elseif string.find(lower, "independent") or string.find(lower, "free") or string.find(lower, "frontier") then
		return 0.04
	end
	return FACTION_BASELINE_RATES[factionName] or 0.08
end

local function getSystemModifier(systemName)
	if not systemName or systemName == "" or systemName == "None" then return 0 end
	-- Pseudo-deterministic modifier between -0.02 and +0.02 based on system name hash
	local hash = 0
	for i = 1, #systemName do
		hash = (hash * 31 + string.byte(systemName, i)) % 1000
	end
	local mod = ((hash % 41) - 20) / 1000 -- range -0.020 to +0.020

	-- Check for active systemic crises / tariffs / embargoes from MacroGalaxyEngine
	local okMacro, MacroEngine = pcall(require, 'modules.MacroGalaxy.MacroGalaxyEngine')
	local crisis = okMacro and MacroEngine and MacroEngine.GetCrisisForSystem(systemName)
	if crisis then
		if crisis.type == "TARIFF_WAR" then
			-- Retaliatory customs duty / import tariff surcharge (+5% in Stage 1, +10% at peak embargo in Stage 2)
			local tariffSurcharge = ((crisis.severity or 1) >= 2) and 0.10 or 0.05
			mod = mod + tariffSurcharge
		elseif crisis.type == "BLOCKADE" then
			-- Emergency blockade defense tax (+5%)
			mod = mod + 0.05
		elseif crisis.type == "SUPPLY_GLUT" then
			-- Emergency market stimulus rebate (-2% tax relief)
			mod = mod - 0.02
		end
	end

	return mod
end

function TaxAuthority.GetResidencyInfo()
	local curTime = Game.time or 0
	local remainingDays = 0
	local canChange = true
	local progress = 1.0

	if state.isResident and state.residencyTimestamp > 0 then
		local elapsed = curTime - state.residencyTimestamp
		local termSeconds = RESIDENCY_TERM_DAYS * SECONDS_PER_DAY
		if elapsed < termSeconds then
			remainingDays = math.ceil((termSeconds - elapsed) / SECONDS_PER_DAY)
			canChange = false
			progress = math.clamp(elapsed / termSeconds, 0, 1)
		else
			canChange = true
			remainingDays = 0
			progress = 1.0
		end
	end

	local baseline = getFactionBaseline(state.homeFaction)
	local mod = getSystemModifier(state.homeSystemName)
	local effectiveRate = math.max(0, baseline + mod)
	if baseline == 0 then effectiveRate = 0 end

	return {
		isResident = state.isResident,
		homeStationName = state.homeStationName,
		homeSystemName = state.homeSystemName,
		homeFaction = state.homeFaction,
		residencyTimestamp = state.residencyTimestamp,
		termDaysTotal = RESIDENCY_TERM_DAYS,
		remainingDays = remainingDays,
		canChange = canChange,
		progress = progress,
		baselineRate = baseline,
		systemModifier = mod,
		effectiveRate = effectiveRate,
	}
end

function TaxAuthority.GetEffectiveTaxRate()
	local info = TaxAuthority.GetResidencyInfo()
	return info.effectiveRate, info.baselineRate, info.systemModifier
end

function TaxAuthority.CanChangeResidency()
	local info = TaxAuthority.GetResidencyInfo()
	return info.canChange, info.remainingDays
end

function TaxAuthority.RegisterResidency(station)
	if not station then return false, "No station specified." end
	local canChange, remainingDays = TaxAuthority.CanChangeResidency()
	if not canChange then
		return false, string.format("Current residency term active. %d days remaining before re-registration permitted.", remainingDays)
	end

	local sys = Game.system
	local factionName = (sys and sys.faction and sys.faction.name) or "Independent Systems"
	local sysName = (sys and sys.name) or "Unknown System"
	local stationName = station.label or "Orbital Station"

	state.isResident = true
	state.homeStationName = stationName
	state.homeSystemName = sysName
	state.homeFaction = factionName
	state.homeStationPath = station.path and tostring(station.path) or nil
	state.residencyTimestamp = Game.time or 0

	Event.Queue("onResidencyRegistered", stationName, sysName, factionName)
	return true, string.format("Successfully registered residency at %s (%s, %s). Term: 90 days.", stationName, sysName, factionName)
end

function TaxAuthority.GetInsuranceDiscount()
	if not state.isResident then return 0.0 end
	local baseline = getFactionBaseline(state.homeFaction)
	if baseline <= 0 then
		return 0.0 -- Anarchy/pirate residents receive no state rebuy subsidy
	end
	return 0.40 -- 40% discount on insurance deductible for lawful residents!
end

function TaxAuthority.CheckDelinquency()
	local curTime = Game.time or 0
	if state.accruedTax > 0 and state.filingDueDate > 0 and curTime > state.filingDueDate then
		if not state.isDelinquent then
			state.isDelinquent = true
			if not state.penaltyApplied then
				local penalty = math.floor(state.accruedTax * DELINQUENCY_PENALTY_RATE)
				state.accruedTax = state.accruedTax + penalty
				state.penaltyApplied = true
			end
		end
	end
	return state.isDelinquent
end

function TaxAuthority.GetTaxAssessment()
	TaxAuthority.CheckDelinquency()
	local curTime = Game.time or 0
	local daysUntilDue = 0
	if state.filingDueDate > 0 and state.filingDueDate > curTime then
		daysUntilDue = math.ceil((state.filingDueDate - curTime) / SECONDS_PER_DAY)
	end

	local effRate = TaxAuthority.GetEffectiveTaxRate()

	return {
		accruedTax = state.accruedTax,
		isDelinquent = state.isDelinquent,
		daysUntilDue = daysUntilDue,
		effectiveRate = effRate,
		breakdown = {
			tradeProfitTax = state.breakdown.tradeProfitTax,
			bbsJobsTax = state.breakdown.bbsJobsTax,
			cartographyTax = state.breakdown.cartographyTax,
			exemptIncome = state.breakdown.exemptIncome,
			windfallTaxWithheld = state.breakdown.windfallTaxWithheld,
		},
		stats = state.stats,
	}
end

function TaxAuthority.PayTaxes()
	TaxAuthority.CheckDelinquency()
	if state.accruedTax <= 0 then
		return false, "No outstanding taxes due."
	end

	local playerCash = PlayerState.GetMoney()
	if playerCash < state.accruedTax then
		return false, string.format("Insufficient funds to settle tax assessment (Requires %d Cr, account has %d Cr).", state.accruedTax, playerCash)
	end

	local paid = state.accruedTax
	local tradeTax = state.breakdown.tradeProfitTax
	local bbsTax = state.breakdown.bbsJobsTax
	local cartoTax = state.breakdown.cartographyTax
	local penaltyTax = (state.isDelinquent and state.penaltyApplied) and math.floor(paid * DELINQUENCY_PENALTY_RATE) or 0

	PlayerState.AddMoney(-paid)

	state.stats.totalTaxPaid = state.stats.totalTaxPaid + paid
	state.stats.totalTradeProfitTax = state.stats.totalTradeProfitTax + state.breakdown.tradeProfitTax
	state.stats.totalBBSJobsTax = state.stats.totalBBSJobsTax + state.breakdown.bbsJobsTax
	state.stats.totalCartographyTax = state.stats.totalCartographyTax + state.breakdown.cartographyTax

	state.accruedTax = 0
	state.isDelinquent = false
	state.penaltyApplied = false
	state.filingDueDate = 0

	state.breakdown.tradeProfitTax = 0
	state.breakdown.bbsJobsTax = 0
	state.breakdown.cartographyTax = 0

	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	local okFormat, Format = pcall(require, 'Format')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		local formatMoney = (okFormat and Format and Format.Money) or function(v) return tostring(v) .. " Cr" end
		local details = {
			{ "Settlement Type", "Consolidated Tax Assessment" },
			{ "Trade Net Capital Gains Tax", formatMoney(tradeTax) },
			{ "Civilian BBS Contracts Tax", formatMoney(bbsTax) },
			{ "Cartographic Survey Data Tax", formatMoney(cartoTax) },
		}
		if penaltyTax > 0 then
			table.insert(details, { "Late Delinquency Penalty (5%)", formatMoney(penaltyTax) })
		end
		table.insert(details, { "Tax Jurisdiction Faction", state.homeFaction or "Independent Systems" })
		table.insert(details, { "Registered Home Port", state.homeStationName or "Unregistered" })
		table.insert(details, { "Total Assessment Settled", formatMoney(paid) })

		FlightLog.RecordTransaction({
			category = "TAX",
			title = string.format("Tax Settlement (%s)", formatMoney(-paid)),
			amount = -paid,
			details = details,
			note = string.format("Settled %s in outstanding tax liabilities with civil revenue authority.", formatMoney(paid))
		})
	end

	Event.Queue("onTaxesPaid", paid)
	return true, string.format("Settled %d Cr in outstanding taxes. Account in good standing.", paid)
end

-- Cost basis tracking for commodities
function TaxAuthority.RecordCommodityPurchase(commodityName, count, unitPrice)
	if not commodityName or count <= 0 then return end
	local item = state.cargoCostBasis[commodityName]
	if not item or item.count <= 0 then
		state.cargoCostBasis[commodityName] = { count = count, avgPrice = unitPrice }
	else
		local totalCost = (item.count * item.avgPrice) + (count * unitPrice)
		local newCount = item.count + count
		item.count = newCount
		item.avgPrice = totalCost / newCount
	end
end

function TaxAuthority.RecordCommoditySale(commodityName, count, sellPrice)
	if not commodityName or count <= 0 then return 0, 0 end
	local item = state.cargoCostBasis[commodityName]
	local costBasis = (item and item.avgPrice) or 0
	local netProfit = (sellPrice - costBasis) * count

	if item then
		item.count = math.max(0, item.count - count)
		if item.count == 0 then
			state.cargoCostBasis[commodityName] = nil
		end
	end

	local tax = 0
	if netProfit > 0 then
		local effRate = TaxAuthority.GetEffectiveTaxRate()
		tax = math.floor(netProfit * effRate)
		if tax > 0 then
			state.breakdown.tradeProfitTax = state.breakdown.tradeProfitTax + tax
			state.accruedTax = state.accruedTax + tax
			if state.filingDueDate == 0 then
				state.filingDueDate = (Game.time or 0) + (FILING_PERIOD_DAYS * SECONDS_PER_DAY)
			end
		end
	end

	return netProfit, tax
end

function TaxAuthority.GetCommodityCostBasis(commodityName)
	local item = state.cargoCostBasis[commodityName]
	return (item and item.avgPrice) or 0
end

-- BBS civilian contracts
function TaxAuthority.RecordBBSIncome(reward, isMilitaryOrBounty)
	if reward <= 0 then return 0 end
	if isMilitaryOrBounty then
		state.breakdown.exemptIncome = state.breakdown.exemptIncome + reward
		state.stats.totalExemptIncome = state.stats.totalExemptIncome + reward
		return 0
	end

	local effRate = TaxAuthority.GetEffectiveTaxRate()
	local tax = math.floor(reward * effRate)
	if tax > 0 then
		state.breakdown.bbsJobsTax = state.breakdown.bbsJobsTax + tax
		state.accruedTax = state.accruedTax + tax
		if state.filingDueDate == 0 then
			state.filingDueDate = (Game.time or 0) + (FILING_PERIOD_DAYS * SECONDS_PER_DAY)
		end
	end
	return tax
end

-- Cartography survey data sales
function TaxAuthority.RecordCartographyIncome(earned, isHomeStation)
	if earned <= 0 then return 0 end
	local effRate = TaxAuthority.GetEffectiveTaxRate()
	if isHomeStation then
		-- Academic Research Tax Credit: 25% discount on cartography tax
		effRate = effRate * 0.75
	end

	local tax = math.floor(earned * effRate)
	if tax > 0 then
		state.breakdown.cartographyTax = state.breakdown.cartographyTax + tax
		state.accruedTax = state.accruedTax + tax
		if state.filingDueDate == 0 then
			state.filingDueDate = (Game.time or 0) + (FILING_PERIOD_DAYS * SECONDS_PER_DAY)
		end
	end
	return tax
end

-- Lottery / windfall 30% tax
function TaxAuthority.RecordWindfall(grossWon, taxWithheld)
	state.breakdown.windfallTaxWithheld = state.breakdown.windfallTaxWithheld + taxWithheld
	state.stats.totalWindfallTaxWithheld = state.stats.totalWindfallTaxWithheld + taxWithheld
end

function TaxAuthority.IsHomeStation(station)
	if not station or not state.isResident then return false end
	local label = station.label
	local sys = Game.system and Game.system.name
	return (label == state.homeStationName and sys == state.homeSystemName)
end

-- Serialization
local function serialize()
	return {
		state = state
	}
end

local function unserialize(saved)
	if saved and saved.state then
		state = saved.state
		-- Ensure default fields if loading older save
		state.breakdown = state.breakdown or {}
		state.breakdown.tradeProfitTax = state.breakdown.tradeProfitTax or 0
		state.breakdown.bbsJobsTax = state.breakdown.bbsJobsTax or 0
		state.breakdown.cartographyTax = state.breakdown.cartographyTax or 0
		state.breakdown.exemptIncome = state.breakdown.exemptIncome or 0
		state.breakdown.windfallTaxWithheld = state.breakdown.windfallTaxWithheld or 0

		state.stats = state.stats or {}
		state.stats.totalTaxPaid = state.stats.totalTaxPaid or 0
		state.stats.totalTradeProfitTax = state.stats.totalTradeProfitTax or 0
		state.stats.totalBBSJobsTax = state.stats.totalBBSJobsTax or 0
		state.stats.totalCartographyTax = state.stats.totalCartographyTax or 0
		state.stats.totalExemptIncome = state.stats.totalExemptIncome or 0
		state.stats.totalWindfallTaxWithheld = state.stats.totalWindfallTaxWithheld or 0

		state.cargoCostBasis = state.cargoCostBasis or {}
	end
end

Serializer:Register("TaxAuthorityDB", serialize, unserialize)

return TaxAuthority


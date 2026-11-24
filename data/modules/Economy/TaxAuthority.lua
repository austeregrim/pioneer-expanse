-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game = require 'Game'
local PlayerState = require 'PlayerState'
local Serializer = require 'Serializer'
local Event = require 'Event'
local Timer = require 'Timer'
local Comms = require 'Comms'
local SystemPath = require 'SystemPath'

local SECONDS_PER_DAY = 24 * 60 * 60
local RESIDENCY_TERM_DAYS = 90
local DELINQUENCY_PENALTY_RATE = 0.05
local WINDFALL_TAX_RATE = 0.30

local MANAGER_HIRE_FEE = 2500
local MANAGER_HOME_DISCOUNT = 0.20 -- 20% onboarding discount at registered home station
local MANAGER_QUARTERLY_FEE = 1500

local MONTH_ABBR = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local QUARTER_END_MONTHS = { 3, 6, 9, 12 }

local TaxAuthority = {}

local cachedEpochOffsetSec = nil

local function makeEmptyBreakdown()
	return {
		tradeProfitTax = 0,
		fleetOperationsTax = 0,
		stationOperationsTax = 0,
		bbsJobsTax = 0,
		cartographyTax = 0,
		investmentTax = 0,
		exemptIncome = 0,
		windfallTaxWithheld = 0,
		operatingExpensesDeducted = 0,
		crewPayrollDeducted = 0,
	}
end

local function makeDefaultState()
	return {
		isResident = false,
		homeStationName = "None",
		homeSystemName = "None",
		homeFaction = "Stateless / Independent",
		homeStationPath = nil,
		homeStationSystemPath = nil,
		homeSystemPath = nil,
		residencyTimestamp = 0,

		accruedTax = 0,
		filingDueDate = 0,
		isDelinquent = false,
		penaltyApplied = false,

		deductibleExpensePool = 0,
		deductibleCrewPool = 0,
		fractionalTaxCarry = 0,

		currentQuarter = {
			qIndex = nil,
			year = nil,
			quarter = nil,
			tax = 0,
			breakdown = makeEmptyBreakdown(),
		},
		reportedStatements = {},

		manager = {
			hired = false,
			name = nil,
			title = nil,
			hiredAt = 0,
			hiredStation = nil,
			quarterlyFee = MANAGER_QUARTERLY_FEE,
			lastFeeQIndex = nil,
			totalTaxesSettled = 0,
			statementsSettled = 0,
			lastPaymentNote = nil,
		},

		breakdown = makeEmptyBreakdown(),

		stats = {
			totalTaxPaid = 0,
			totalTradeProfitTax = 0,
			totalFleetOperationsTax = 0,
			totalStationOperationsTax = 0,
			totalBBSJobsTax = 0,
			totalCartographyTax = 0,
			totalInvestmentTax = 0,
			totalExemptIncome = 0,
			totalWindfallTaxWithheld = 0,
			totalOperatingExpenses = 0,
			totalCrewPayrollExpenses = 0,
			totalTaxSavedByDeductions = 0,
		},

		entityLedger = {}, -- domainKey -> { revenue = 0, directCost = 0, expenses = 0, taxAccrued = 0 }
		cargoCostBasis = {} -- commodityName -> { count = N, avgPrice = X }
	}
end

local state = makeDefaultState()

-- Civil Gregorian calendar helpers synchronized to Game.GetPartsFromDateTime
local function daysFromCivil(y, m, d)
	if m <= 2 then
		y = y - 1
	end
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local mAdj = (m > 2) and (m - 3) or (m + 9)
	local doy = math.floor((153 * mAdj + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe
end

local function ensureEpochOffsetSec()
	if cachedEpochOffsetSec then return cachedEpochOffsetSec end
	if Game.GetPartsFromDateTime then
		local ok, es, emin, eh, ed, em, ey = pcall(Game.GetPartsFromDateTime, 0)
		if ok and ey and em and ed then
			cachedEpochOffsetSec = (daysFromCivil(ey, em, ed) * SECONDS_PER_DAY) - ((eh or 0) * 3600 + (emin or 0) * 60 + (es or 0))
			return cachedEpochOffsetSec
		end
	end
	return nil
end

local function getTimestampFromDate(y, m, d)
	local offset = ensureEpochOffsetSec()
	if not offset then
		return ((y - 3200) * 365 + (m - 1) * 30 + (d - 1)) * SECONDS_PER_DAY
	end
	return (daysFromCivil(y, m, d) * SECONDS_PER_DAY) - offset
end

local function qIndexToYearQuarter(qIndex)
	local year = math.floor(qIndex / 4)
	local quarter = (qIndex % 4) + 1
	return year, quarter
end

local function getQuarterStartTime(qIndex)
	local year, quarter = qIndexToYearQuarter(qIndex)
	local startMonth = (quarter - 1) * 3 + 1
	return getTimestampFromDate(year, startMonth, 1)
end

local function getQuarterFromTime(t)
	local ts = t or Game.time or 0
	if Game.GetPartsFromDateTime then
		local ok, _, _, _, _, month, year = pcall(Game.GetPartsFromDateTime, ts)
		if ok and month and year then
			local q = math.floor((month - 1) / 3) + 1
			local qIndex = year * 4 + (q - 1)
			return year, q, qIndex
		end
	end
	local approxDay = math.floor(math.max(0, ts) / SECONDS_PER_DAY)
	local qIndex = 3200 * 4 + math.floor(approxDay / 91)
	local y, q = qIndexToYearQuarter(qIndex)
	return y, q, qIndex
end

local function formatQuarterLabel(qIndex)
	local y, q = qIndexToYearQuarter(qIndex)
	return string.format("Q%d %d", q, y)
end

local function formatQuarterEndLabel(qIndex)
	local y, q = qIndexToYearQuarter(qIndex)
	local mName = MONTH_ABBR[QUARTER_END_MONTHS[q]] or "Dec"
	return string.format("End of %s %d", mName, y)
end

local function copyBreakdown(src)
	local dst = makeEmptyBreakdown()
	if not src then return dst end
	for k, _ in pairs(dst) do
		dst[k] = src[k] or 0
	end
	return dst
end

local function addBreakdownInto(dst, src)
	if not src then return end
	for k, _ in pairs(makeEmptyBreakdown()) do
		dst[k] = (dst[k] or 0) + (src[k] or 0)
	end
end

local function ensureStatementForQuarter(qIndex)
	state.reportedStatements = state.reportedStatements or {}
	for _, stmt in ipairs(state.reportedStatements) do
		if stmt.qIndex == qIndex then
			return stmt
		end
	end
	local y, q = qIndexToYearQuarter(qIndex)
	local stmt = {
		qIndex = qIndex,
		year = y,
		quarter = q,
		label = formatQuarterLabel(qIndex),
		reportLabel = formatQuarterEndLabel(qIndex),
		dueLabel = formatQuarterEndLabel(qIndex + 1),
		reportTime = getQuarterStartTime(qIndex + 1),
		dueTime = getQuarterStartTime(qIndex + 2),
		tax = 0,
		penalty = 0,
		isDelinquent = false,
		breakdown = makeEmptyBreakdown(),
	}
	table.insert(state.reportedStatements, stmt)
	table.sort(state.reportedStatements, function(a, b) return (a.qIndex or 0) < (b.qIndex or 0) end)
	return stmt
end

local function ensureCurrentQuarter(curYear, curQ, curQIdx)
	if not state.currentQuarter then
		state.currentQuarter = {
			qIndex = curQIdx,
			year = curYear,
			quarter = curQ,
			tax = 0,
			breakdown = makeEmptyBreakdown(),
		}
	elseif not state.currentQuarter.qIndex then
		state.currentQuarter.qIndex = curQIdx
		state.currentQuarter.year = curYear
		state.currentQuarter.quarter = curQ
		state.currentQuarter.tax = state.currentQuarter.tax or 0
		state.currentQuarter.breakdown = state.currentQuarter.breakdown or makeEmptyBreakdown()
	end
end

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
	local hash = 0
	for i = 1, #systemName do
		hash = (hash * 31 + string.byte(systemName, i)) % 1000
	end
	local mod = ((hash % 41) - 20) / 1000

	local okMacro, MacroEngine = pcall(require, 'modules.MacroGalaxy.MacroGalaxyEngine')
	local crisis = okMacro and MacroEngine and MacroEngine.GetCrisisForSystem(systemName)
	if crisis then
		if crisis.type == "TARIFF_WAR" then
			local tariffSurcharge = ((crisis.severity or 1) >= 2) and 0.10 or 0.05
			mod = mod + tariffSurcharge
		elseif crisis.type == "BLOCKADE" then
			mod = mod + 0.05
		elseif crisis.type == "SUPPLY_GLUT" then
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
	local okPenal, PenalSystem = pcall(require, 'modules.Penal.PenalSystem')
	if okPenal and PenalSystem and PenalSystem.IsPrisonStation(station) then
		return false, "Civil residency and home-port registration are prohibited at penal facilities."
	end
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
	state.homeStationSystemPath = station.path
	state.homeSystemPath = station.path and station.path:SystemOnly() or (sys and sys.path and sys.path:SystemOnly()) or nil
	state.residencyTimestamp = Game.time or 0

	TaxAuthority.SyncHomeBookmark()
	Event.Queue("onResidencyRegistered", stationName, sysName, factionName)
	return true, string.format("Successfully registered residency at %s (%s, %s). Term: 90 days.", stationName, sysName, factionName)
end

function TaxAuthority.GetInsuranceDiscount()
	if not state.isResident then return 0.0 end
	local baseline = getFactionBaseline(state.homeFaction)
	if baseline <= 0 then
		return 0.0
	end
	return 0.40
end

local function ensureLedgerBucket(domainKey)
	state.entityLedger = state.entityLedger or {}
	local key = domainKey or "FLAGSHIP"
	local bucket = state.entityLedger[key]
	if not bucket then
		bucket = { revenue = 0, directCost = 0, expenses = 0, taxAccrued = 0 }
		state.entityLedger[key] = bucket
	end
	return bucket
end

local function syncSummaryTotals()
	local totalDue = 0
	local anyDelinquent = false
	local earliestDue = 0
	for _, stmt in ipairs(state.reportedStatements or {}) do
		totalDue = totalDue + (stmt.tax or 0)
		if stmt.isDelinquent then
			anyDelinquent = true
		end
		if earliestDue == 0 or (stmt.dueTime and stmt.dueTime < earliestDue) then
			earliestDue = stmt.dueTime
		end
	end
	state.accruedTax = totalDue
	state.isDelinquent = anyDelinquent
	state.penaltyApplied = anyDelinquent
	state.filingDueDate = earliestDue

	local combined = makeEmptyBreakdown()
	for _, stmt in ipairs(state.reportedStatements or {}) do
		addBreakdownInto(combined, stmt.breakdown)
	end
	if state.currentQuarter then
		addBreakdownInto(combined, state.currentQuarter.breakdown)
	end
	state.breakdown = combined
end

local function recordTaxPaymentStatsAndLog(paidAmount, breakdown, penaltyAmount, periodLabel, handledByManager)
	local tradeTax = breakdown.tradeProfitTax or 0
	local fleetTax = breakdown.fleetOperationsTax or 0
	local stationTax = breakdown.stationOperationsTax or 0
	local bbsTax = breakdown.bbsJobsTax or 0
	local cartoTax = breakdown.cartographyTax or 0
	local investTax = breakdown.investmentTax or 0
	local deductedOps = breakdown.operatingExpensesDeducted or 0
	local deductedCrew = breakdown.crewPayrollDeducted or 0

	state.stats.totalTaxPaid = (state.stats.totalTaxPaid or 0) + paidAmount
	state.stats.totalTradeProfitTax = (state.stats.totalTradeProfitTax or 0) + tradeTax
	state.stats.totalFleetOperationsTax = (state.stats.totalFleetOperationsTax or 0) + fleetTax
	state.stats.totalStationOperationsTax = (state.stats.totalStationOperationsTax or 0) + stationTax
	state.stats.totalBBSJobsTax = (state.stats.totalBBSJobsTax or 0) + bbsTax
	state.stats.totalCartographyTax = (state.stats.totalCartographyTax or 0) + cartoTax
	state.stats.totalInvestmentTax = (state.stats.totalInvestmentTax or 0) + investTax

	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	local okFormat, Format = pcall(require, 'Format')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		local formatMoney = (okFormat and Format and Format.Money) or function(v) return tostring(v) .. " Cr" end
		local details = {
			{ "Settlement Period", periodLabel or "Quarterly Assessment" },
			{ "Filing Channel", handledByManager and ("Financial Manager: " .. handledByManager) or "Manual Commander Settlement" },
			{ "Flagship Trade Net Profit Tax", formatMoney(tradeTax) },
			{ "Contracts, Missions & Bounties Tax", formatMoney(bbsTax) },
			{ "Cartographic Survey Data Tax", formatMoney(cartoTax) },
		}
		if fleetTax > 0 then
			table.insert(details, { "Autonomous Fleet Operations Tax", formatMoney(fleetTax) })
		end
		if stationTax > 0 then
			table.insert(details, { "Station & Industrial Ops Tax", formatMoney(stationTax) })
		end
		if investTax > 0 then
			table.insert(details, { "Equities & Dividends Tax", formatMoney(investTax) })
		end
		if deductedCrew > 0 then
			table.insert(details, { "Crew & Captain Salaries Deducted", formatMoney(deductedCrew) })
		end
		if deductedOps > 0 then
			table.insert(details, { "Deductible Operating Expenses Applied", formatMoney(deductedOps) })
		end
		if penaltyAmount and penaltyAmount > 0 then
			table.insert(details, { "Late Delinquency Penalty (5%)", formatMoney(penaltyAmount) })
		end
		table.insert(details, { "Tax Jurisdiction Faction", state.homeFaction or "Independent Systems" })
		table.insert(details, { "Registered Home Port", state.homeStationName or "Unregistered" })
		table.insert(details, { "Total Assessment Settled", formatMoney(paidAmount) })

		local titlePrefix = handledByManager and "Auto-Tax Settlement" or "Tax Settlement"
		local note = handledByManager
			and string.format("Financial Manager %s automatically settled %s for %s.", handledByManager, formatMoney(paidAmount), periodLabel or "quarterly taxes")
			or string.format("Settled %s in reported quarterly taxes (%s).", formatMoney(paidAmount), periodLabel or "quarterly taxes")

		FlightLog.RecordTransaction({
			category = "TAX",
			title = string.format("%s: %s (%s)", titlePrefix, periodLabel or "Quarterly", formatMoney(-paidAmount)),
			amount = -paidAmount,
			details = details,
			note = note,
		})
	end
end

local isProcessingRollover = false

local function isCrewExpenseCategory(cat)
	local c = tostring(cat or "")
	return c == "CREW_WAGES" or c == "FLEET_CREW" or string.find(c, "CREW", 1, true) ~= nil
end

local function applyExpensePoolAgainstCurrentQuarter(preferLedgerDomain)
	local curTime = Game.time or 0
	local curYear, curQ, curQIdx = getQuarterFromTime(curTime)
	ensureCurrentQuarter(curYear, curQ, curQIdx)

	local pool = state.deductibleExpensePool or 0
	local curTax = state.currentQuarter.tax or 0
	if pool <= 0 or curTax <= 0 then
		return 0, 0
	end

	local effRate = TaxAuthority.GetEffectiveTaxRate()
	if effRate <= 0 then
		return 0, 0
	end

	local maxProfitOffset = math.ceil(curTax / effRate)
	local deductNow = math.min(pool, maxProfitOffset)
	if deductNow <= 0 then
		return 0, 0
	end

	local rawTaxOffset = deductNow * effRate
	local newCarry = (state.fractionalTaxCarry or 0) - rawTaxOffset
	local taxReduction = 0
	if newCarry < 0 then
		taxReduction = math.min(curTax, math.ceil(-newCarry - 1e-9))
		newCarry = newCarry + taxReduction
	end
	state.fractionalTaxCarry = math.clamp(newCarry, 0, 0.999999)

	local bd = state.currentQuarter.breakdown
	if taxReduction > 0 then
		state.currentQuarter.tax = math.max(0, curTax - taxReduction)

		local domainKeyMap = {
			FLEET = "fleetOperationsTax",
			STATION = "stationOperationsTax",
			FLAGSHIP = "tradeProfitTax",
			INVESTMENTS = "investmentTax",
		}
		local keyOrder = {}
		local preferredKey = domainKeyMap[preferLedgerDomain]
		if preferredKey then
			table.insert(keyOrder, preferredKey)
		end
		for _, k in ipairs({ "fleetOperationsTax", "tradeProfitTax", "bbsJobsTax", "stationOperationsTax", "cartographyTax", "investmentTax" }) do
			if k ~= preferredKey then
				table.insert(keyOrder, k)
			end
		end

		local rem = taxReduction
		for _, k in ipairs(keyOrder) do
			if rem <= 0 then break end
			local avail = bd[k] or 0
			if avail > 0 then
				local take = math.min(avail, rem)
				bd[k] = avail - take
				rem = rem - take
			end
		end

		if preferLedgerDomain then
			local bucket = ensureLedgerBucket(preferLedgerDomain)
			bucket.taxAccrued = math.max(0, (bucket.taxAccrued or 0) - taxReduction)
		end
	end

	state.deductibleExpensePool = math.max(0, pool - deductNow)
	local crewUsed = math.min(deductNow, state.deductibleCrewPool or 0)
	if crewUsed > 0 then
		state.deductibleCrewPool = math.max(0, (state.deductibleCrewPool or 0) - crewUsed)
		bd.crewPayrollDeducted = (bd.crewPayrollDeducted or 0) + crewUsed
	end
	bd.operatingExpensesDeducted = (bd.operatingExpensesDeducted or 0) + deductNow
	state.stats.totalTaxSavedByDeductions = (state.stats.totalTaxSavedByDeductions or 0) + taxReduction
	syncSummaryTotals()
	return taxReduction, deductNow
end

function TaxAuthority.ProcessQuarterlyRollover()
	if not Game.player or isProcessingRollover then return end
	isProcessingRollover = true

	local curTime = Game.time or 0
	local curYear, curQ, curQIdx = getQuarterFromTime(curTime)
	ensureCurrentQuarter(curYear, curQ, curQIdx)

	-- Apply any remaining deductible expenses against current quarter accruals before closing it
	applyExpensePoolAgainstCurrentQuarter(nil)

	-- 1. Close out current quarter if calendar moved into a newer quarter
	if state.currentQuarter.qIndex < curQIdx then
		local prevTax = state.currentQuarter.tax or 0
		if prevTax > 0 then
			local stmt = ensureStatementForQuarter(state.currentQuarter.qIndex)
			stmt.tax = (stmt.tax or 0) + prevTax
			addBreakdownInto(stmt.breakdown, state.currentQuarter.breakdown)
		else
			-- Keep operating expense deductions noted in aggregate stats only when zero tax due
		end
		state.currentQuarter = {
			qIndex = curQIdx,
			year = curYear,
			quarter = curQ,
			tax = 0,
			breakdown = makeEmptyBreakdown(),
		}
	end

	-- 2. If a Financial Manager is hired, charge any elapsed quarterly retainers
	--    and note coverage before delinquency checks run
	local mgr = state.manager
	local managerCoveredDelinquencyAt = (mgr and mgr.hired) and (mgr.hiredAt or 0) or nil
	if mgr and mgr.hired then
		mgr.quarterlyFee = mgr.quarterlyFee or MANAGER_QUARTERLY_FEE
		if not mgr.lastFeeQIndex then
			mgr.lastFeeQIndex = curQIdx
		end
		local quartersOwed = curQIdx - mgr.lastFeeQIndex
		if quartersOwed > 0 then
			local paidQuarters = 0
			for q = mgr.lastFeeQIndex, curQIdx - 1 do
				if PlayerState.GetMoney() >= mgr.quarterlyFee then
					PlayerState.AddMoney(-mgr.quarterlyFee)
					TaxAuthority.RecordOperatingExpense(mgr.quarterlyFee, "MANAGER_FEE", mgr.name or "Financial Manager")
					paidQuarters = paidQuarters + 1
					local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
					local okFormat, Format = pcall(require, 'Format')
					if okFlightLog and FlightLog and FlightLog.RecordTransaction then
						local fmtMoney = (okFormat and Format and Format.Money) or function(v) return tostring(v) .. " Cr" end
						FlightLog.RecordTransaction({
							category = "TAX",
							title = string.format("Financial Manager Retainer: %s (%s)", formatQuarterLabel(q), fmtMoney(-mgr.quarterlyFee)),
							amount = -mgr.quarterlyFee,
							details = {
								{ "Accountant", mgr.name or "Financial Manager" },
								{ "Billing Period", formatQuarterLabel(q) },
								{ "Retainer Fee", fmtMoney(mgr.quarterlyFee) },
								{ "Tax Treatment", "Added to Deductible Expense Pool" },
							},
							note = string.format("Quarterly financial management retainer paid to %s.", mgr.name or "Financial Manager"),
						})
					end
				end
			end
			mgr.lastFeeQIndex = curQIdx
			if paidQuarters > 0 then
				mgr.lastPaymentNote = string.format("Charged %d quarterly retainer(s); auto-settlement active.", paidQuarters)
			end
		end
	end

	-- 3. Apply 5% late delinquency penalty ONLY after the grace quarter closes AND only if no manager covered that deadline
	state.reportedStatements = state.reportedStatements or {}
	table.sort(state.reportedStatements, function(a, b) return (a.qIndex or 0) < (b.qIndex or 0) end)

	for _, stmt in ipairs(state.reportedStatements) do
		local coveredByManager = managerCoveredDelinquencyAt and (managerCoveredDelinquencyAt <= (stmt.dueTime or 0))
		if not coveredByManager and not stmt.isDelinquent and stmt.dueTime and curTime > stmt.dueTime then
			local pen = math.max(1, math.floor((stmt.tax or 0) * DELINQUENCY_PENALTY_RATE))
			stmt.penalty = (stmt.penalty or 0) + pen
			stmt.tax = (stmt.tax or 0) + pen
			stmt.isDelinquent = true
		end
	end

	-- 4. Financial Manager automatically settles any reported statements that are currently payable
	if mgr and mgr.hired and #state.reportedStatements > 0 then
		local remaining = {}
		for _, stmt in ipairs(state.reportedStatements) do
			if (stmt.tax or 0) > 0 and curTime >= (stmt.reportTime or 0) then
				local cash = PlayerState.GetMoney()
				if cash >= stmt.tax then
					local paid = stmt.tax
					PlayerState.AddMoney(-paid)
					mgr.totalTaxesSettled = (mgr.totalTaxesSettled or 0) + paid
					mgr.statementsSettled = (mgr.statementsSettled or 0) + 1
					mgr.lastPaymentNote = string.format("Auto-settled %s tax assessment (%d Cr).", stmt.label or "Quarterly", paid)
					recordTaxPaymentStatsAndLog(paid, stmt.breakdown or {}, stmt.penalty or 0, stmt.label, mgr.name or "Financial Manager")
					local okFormat, Format = pcall(require, 'Format')
					local fmtMoney = (okFormat and Format and Format.Money) or function(v) return tostring(v) .. " Cr" end
					pcall(function()
						Comms.Message(string.format("%s (%s) automatically settled %s tax assessment: %s.",
							mgr.name or "Financial Manager", mgr.title or "Fiduciary Officer", stmt.label or "Quarterly", fmtMoney(paid, false)),
							"Financial Management")
					end)
					Event.Queue("onTaxesPaid", paid)
				else
					mgr.lastPaymentNote = string.format("Awaiting %d Cr to settle %s tax (%d Cr short).",
						stmt.tax, stmt.label or "Quarterly", stmt.tax - cash)
					table.insert(remaining, stmt)
				end
			elseif (stmt.tax or 0) > 0 then
				table.insert(remaining, stmt)
			end
		end
		state.reportedStatements = remaining
	end

	syncSummaryTotals()
	isProcessingRollover = false
end

local function assessTaxableProfit(grossProfit, breakdownKey, ledgerDomain, rateMultiplier, eventTime)
	if not grossProfit or grossProfit <= 0 then
		return 0, 0
	end

	TaxAuthority.ProcessQuarterlyRollover()

	local effRate = TaxAuthority.GetEffectiveTaxRate() * (rateMultiplier or 1.0)
	local maxDeduction = math.floor(grossProfit)
	local deductionApplied = math.min(state.deductibleExpensePool or 0, maxDeduction)
	local crewDeductionApplied = 0
	if deductionApplied > 0 then
		state.deductibleExpensePool = math.max(0, (state.deductibleExpensePool or 0) - deductionApplied)
		crewDeductionApplied = math.min(deductionApplied, state.deductibleCrewPool or 0)
		if crewDeductionApplied > 0 then
			state.deductibleCrewPool = math.max(0, (state.deductibleCrewPool or 0) - crewDeductionApplied)
		end
		state.stats.totalTaxSavedByDeductions = (state.stats.totalTaxSavedByDeductions or 0) + math.floor(deductionApplied * effRate)
	end

	local taxableProfit = math.max(0, grossProfit - deductionApplied)
	local rawTax = taxableProfit * effRate + (state.fractionalTaxCarry or 0)
	local tax = math.floor(rawTax)
	state.fractionalTaxCarry = (effRate > 0) and (rawTax - tax) or 0

	local curTime = Game.time or 0
	local _, _, curQIdx = getQuarterFromTime(curTime)
	local evTime = eventTime or curTime
	local _, _, evQIdx = getQuarterFromTime(evTime)

	if deductionApplied > 0 then
		if evQIdx < curQIdx then
			local stmt = ensureStatementForQuarter(evQIdx)
			stmt.breakdown.operatingExpensesDeducted = (stmt.breakdown.operatingExpensesDeducted or 0) + deductionApplied
			stmt.breakdown.crewPayrollDeducted = (stmt.breakdown.crewPayrollDeducted or 0) + crewDeductionApplied
		else
			state.currentQuarter.breakdown.operatingExpensesDeducted = (state.currentQuarter.breakdown.operatingExpensesDeducted or 0) + deductionApplied
			state.currentQuarter.breakdown.crewPayrollDeducted = (state.currentQuarter.breakdown.crewPayrollDeducted or 0) + crewDeductionApplied
		end
	end

	if tax > 0 then
		if evQIdx < curQIdx then
			local stmt = ensureStatementForQuarter(evQIdx)
			stmt.tax = (stmt.tax or 0) + tax
			stmt.breakdown[breakdownKey] = (stmt.breakdown[breakdownKey] or 0) + tax
		else
			state.currentQuarter.tax = (state.currentQuarter.tax or 0) + tax
			state.currentQuarter.breakdown[breakdownKey] = (state.currentQuarter.breakdown[breakdownKey] or 0) + tax
		end

		local bucket = ensureLedgerBucket(ledgerDomain)
		bucket.taxAccrued = (bucket.taxAccrued or 0) + tax
	end

	TaxAuthority.ProcessQuarterlyRollover()
	return tax, deductionApplied
end

function TaxAuthority.CheckDelinquency()
	TaxAuthority.ProcessQuarterlyRollover()
	return state.isDelinquent
end

local function generateCandidateProfile(station)
	local titles = {
		"Senior Tax & Fiduciary Officer",
		"Certified Interstellar CPA",
		"Corporate Compliance Director",
		"Chartered Revenue Broker",
	}
	local seedStr = (station and tostring(station.seed or station.label)) or tostring(Game.system and Game.system.name or "IRS")
	local okRand, Rand = pcall(require, 'Rand')
	local okNameGen, NameGen = pcall(require, 'NameGen')
	local name = "Elena Vance"
	local title = titles[1]
	if okRand and Rand then
		local r = Rand.New("taxmgr-" .. seedStr)
		local isFemale = (r:Integer(0, 1) == 1)
		if okNameGen and NameGen and NameGen.Names then
			local okN, first, sur = pcall(NameGen.Names, isFemale, r)
			if okN and first and sur then
				name = first .. " " .. sur
			end
		end
		title = titles[r:Integer(1, #titles)]
	end
	return name, title
end

local function getEffectiveManagerHireFee(station)
	local isHome = (station ~= nil) and TaxAuthority.IsHomeStation(station) or false
	local discount = isHome and MANAGER_HOME_DISCOUNT or 0.0
	local fee = math.floor(MANAGER_HIRE_FEE * (1.0 - discount) + 0.5)
	return fee, isHome, discount
end

function TaxAuthority.GetManagerInfo(station)
	local mgr = state.manager or makeDefaultState().manager
	local candName, candTitle = generateCandidateProfile(station)
	local hireFee, isHomeDiscount, discountRate = getEffectiveManagerHireFee(station)
	return {
		hired = mgr.hired == true,
		name = mgr.name,
		title = mgr.title,
		hiredAt = mgr.hiredAt or 0,
		hiredStation = mgr.hiredStation,
		quarterlyFee = mgr.quarterlyFee or MANAGER_QUARTERLY_FEE,
		hireFee = hireFee,
		baseHireFee = MANAGER_HIRE_FEE,
		isHomeStationDiscount = isHomeDiscount,
		homeDiscountPct = math.floor(discountRate * 100 + 0.5),
		totalTaxesSettled = mgr.totalTaxesSettled or 0,
		statementsSettled = mgr.statementsSettled or 0,
		lastPaymentNote = mgr.lastPaymentNote,
		candidateName = candName,
		candidateTitle = candTitle,
	}
end

function TaxAuthority.HireManager(station)
	if state.manager and state.manager.hired then
		return false, string.format("%s is already retained as your Financial Manager.", state.manager.name or "Manager")
	end
	local okPenal, PenalSystem = pcall(require, 'modules.Penal.PenalSystem')
	if station and okPenal and PenalSystem and PenalSystem.IsPrisonStation(station) then
		return false, "Licensed fiduciary agents cannot be contracted at penal facilities."
	end
	local hireFee, isHomeDiscount, discountRate = getEffectiveManagerHireFee(station)
	local cash = PlayerState.GetMoney()
	if cash < hireFee then
		return false, string.format("Insufficient funds to retain a Financial Manager (Requires %d Cr).", hireFee)
	end

	local candName, candTitle = generateCandidateProfile(station)
	local _, _, curQIdx = getQuarterFromTime(Game.time or 0)

	PlayerState.AddMoney(-hireFee)
	TaxAuthority.RecordOperatingExpense(hireFee, "MANAGER_HIRE", candName)

	state.manager = {
		hired = true,
		name = candName,
		title = candTitle,
		hiredAt = Game.time or 0,
		hiredStation = (station and station.label) or "Orbital Office",
		quarterlyFee = MANAGER_QUARTERLY_FEE,
		lastFeeQIndex = curQIdx,
		totalTaxesSettled = 0,
		statementsSettled = 0,
		lastPaymentNote = "Retainer active; monitoring quarterly tax assessments.",
	}

	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	local okFormat, Format = pcall(require, 'Format')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		local fmtMoney = (okFormat and Format and Format.Money) or function(v) return tostring(v) .. " Cr" end
		local details = {
			{ "Officer", string.format("%s (%s)", candName, candTitle) },
			{ "Station Office", state.manager.hiredStation },
			{ "Signing Retainer", fmtMoney(hireFee) },
			{ "Quarterly Fee", fmtMoney(MANAGER_QUARTERLY_FEE) .. " / quarter" },
			{ "Mandate", "Automated settlement of reported quarterly taxes" },
		}
		if isHomeDiscount then
			table.insert(details, 4, { "Home Station Discount", string.format("-%d%% (Standard %s)", math.floor(discountRate * 100 + 0.5), fmtMoney(MANAGER_HIRE_FEE)) })
		end
		FlightLog.RecordTransaction({
			category = "TAX",
			title = string.format("Retained Financial Manager: %s (%s)", candName, fmtMoney(-hireFee)),
			amount = -hireFee,
			details = details,
			note = string.format("Hired Financial Manager %s (%s) to automate quarterly tax payments.", candName, candTitle),
		})
	end

	local prevSettled = state.manager.statementsSettled
	TaxAuthority.ProcessQuarterlyRollover()
	local justPaid = (state.manager.statementsSettled or 0) - prevSettled
	if justPaid > 0 then
		return true, string.format("Retained %s (%s) and automatically settled %d pending quarterly tax statement(s).", candName, candTitle, justPaid)
	end
	return true, string.format("Retained %s (%s). Reported quarterly taxes will be auto-paid before deadline.", candName, candTitle)
end

function TaxAuthority.DismissManager()
	if not state.manager or not state.manager.hired then
		return false, "No Financial Manager is currently retained."
	end
	local prevName = state.manager.name or "Financial Manager"
	state.manager.hired = false
	state.manager.lastPaymentNote = "Contract terminated by Commander."
	return true, string.format("Dismissed Financial Manager %s. Manual tax settlement is now required.", prevName)
end

function TaxAuthority.GetTaxAssessment()
	TaxAuthority.ProcessQuarterlyRollover()
	local curTime = Game.time or 0
	local curYear, curQ, curQIdx = getQuarterFromTime(curTime)
	ensureCurrentQuarter(curYear, curQ, curQIdx)

	local daysUntilDue = 0
	if state.filingDueDate > 0 and state.filingDueDate > curTime then
		daysUntilDue = math.ceil((state.filingDueDate - curTime) / SECONDS_PER_DAY)
	end

	local effRate = TaxAuthority.GetEffectiveTaxRate()

	local reportedTaxDue = 0
	local reportedBreakdown = makeEmptyBreakdown()
	local statementViews = {}
	for _, stmt in ipairs(state.reportedStatements or {}) do
		reportedTaxDue = reportedTaxDue + (stmt.tax or 0)
		addBreakdownInto(reportedBreakdown, stmt.breakdown)
		local stmtDays = 0
		if stmt.dueTime and stmt.dueTime > curTime then
			stmtDays = math.ceil((stmt.dueTime - curTime) / SECONDS_PER_DAY)
		end
		table.insert(statementViews, {
			qIndex = stmt.qIndex,
			year = stmt.year,
			quarter = stmt.quarter,
			label = stmt.label or formatQuarterLabel(stmt.qIndex),
			reportLabel = stmt.reportLabel or formatQuarterEndLabel(stmt.qIndex),
			dueLabel = stmt.dueLabel or formatQuarterEndLabel(stmt.qIndex + 1),
			tax = stmt.tax or 0,
			penalty = stmt.penalty or 0,
			isDelinquent = stmt.isDelinquent == true,
			daysUntilDue = stmtDays,
		})
	end

	local earliestDueLabel = (#statementViews > 0) and statementViews[1].dueLabel or nil

	return {
		accruedTax = reportedTaxDue,
		reportedTaxDue = reportedTaxDue,
		isDelinquent = state.isDelinquent,
		daysUntilDue = daysUntilDue,
		earliestDueLabel = earliestDueLabel,
		effectiveRate = effRate,
		deductibleExpensePool = state.deductibleExpensePool or 0,
		entityLedger = state.entityLedger or {},
		statements = statementViews,
		reportedBreakdown = reportedBreakdown,
		currentQuarterTax = state.currentQuarter.tax or 0,
		currentQuarterLabel = formatQuarterLabel(curQIdx),
		currentQuarterReportLabel = formatQuarterEndLabel(curQIdx),
		currentQuarterDueLabel = formatQuarterEndLabel(curQIdx + 1),
		currentQuarterBreakdown = copyBreakdown(state.currentQuarter.breakdown),
		breakdown = copyBreakdown(state.breakdown),
		stats = state.stats,
		manager = TaxAuthority.GetManagerInfo(nil),
	}
end

function TaxAuthority.PayTaxes()
	TaxAuthority.ProcessQuarterlyRollover()
	local totalDue = state.accruedTax or 0
	if totalDue <= 0 or #(state.reportedStatements or {}) == 0 then
		return false, "No reported quarterly taxes currently due."
	end

	local playerCash = PlayerState.GetMoney()
	if playerCash < totalDue then
		return false, string.format("Insufficient funds to settle reported quarterly taxes (Requires %d Cr, account has %d Cr).", totalDue, playerCash)
	end

	local combinedBreakdown = makeEmptyBreakdown()
	local totalPenalty = 0
	local labels = {}
	for _, stmt in ipairs(state.reportedStatements) do
		addBreakdownInto(combinedBreakdown, stmt.breakdown)
		totalPenalty = totalPenalty + (stmt.penalty or 0)
		table.insert(labels, stmt.label or formatQuarterLabel(stmt.qIndex))
	end

	PlayerState.AddMoney(-totalDue)
	recordTaxPaymentStatsAndLog(totalDue, combinedBreakdown, totalPenalty, table.concat(labels, ", "), nil)

	state.reportedStatements = {}
	syncSummaryTotals()

	Event.Queue("onTaxesPaid", totalDue)
	return true, string.format("Settled %d Cr in reported quarterly taxes (%s). Account in good standing.", totalDue, table.concat(labels, ", "))
end

function TaxAuthority.RecordOperatingExpense(amount, expenseCategory, sourceLabel)
	local spend = math.floor(tonumber(amount) or 0)
	if spend <= 0 then return 0 end

	local cat = tostring(expenseCategory or "MAINTENANCE")
	local src = tostring(sourceLabel or "")

	state.deductibleExpensePool = (state.deductibleExpensePool or 0) + spend
	state.stats.totalOperatingExpenses = (state.stats.totalOperatingExpenses or 0) + spend
	if isCrewExpenseCategory(cat) then
		state.deductibleCrewPool = (state.deductibleCrewPool or 0) + spend
		state.stats.totalCrewPayrollExpenses = (state.stats.totalCrewPayrollExpenses or 0) + spend
	end

	local ledgerDomain = "FLAGSHIP"
	if cat:match("^STATION") or src:match("^STATION") then
		ledgerDomain = "STATION"
	elseif cat:match("^FLEET") or src:find("[FLEET]", 1, true) then
		ledgerDomain = "FLEET"
	end

	local bucket = ensureLedgerBucket(ledgerDomain)
	bucket.expenses = (bucket.expenses or 0) + spend

	if Game.player and not isProcessingRollover then
		applyExpensePoolAgainstCurrentQuarter(ledgerDomain)
	end
	return spend
end

function TaxAuthority.RecordOperationsIncome(domain, grossRevenue, directCostBasis, sourceLabel, eventTime)
	local gross = tonumber(grossRevenue) or 0
	local cost = tonumber(directCostBasis) or 0
	local d = tostring(domain or "FLEET_TRADE")

	local breakdownKey = "fleetOperationsTax"
	local ledgerDomain = "FLEET"
	if d == "STATION" or d:match("^STATION") then
		breakdownKey = "stationOperationsTax"
		ledgerDomain = "STATION"
	elseif d == "INVESTMENT_GAINS" or d == "INVESTMENT_DIVIDEND" then
		breakdownKey = "investmentTax"
		ledgerDomain = "INVESTMENTS"
	end

	local bucket = ensureLedgerBucket(ledgerDomain)
	if gross > 0 then
		bucket.revenue = (bucket.revenue or 0) + gross
	end
	if cost > 0 then
		bucket.directCost = (bucket.directCost or 0) + cost
	end

	local netProfit = gross - cost
	local tax, deductionApplied = assessTaxableProfit(netProfit, breakdownKey, ledgerDomain, 1.0, eventTime)
	return netProfit, tax, deductionApplied
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

function TaxAuthority.AdjustCommodityCostBasis(commodityName, deltaCount, unitPrice)
	if not commodityName or not deltaCount or deltaCount == 0 then return end
	if deltaCount > 0 then
		TaxAuthority.RecordCommodityPurchase(commodityName, deltaCount, unitPrice or 0)
	else
		local item = state.cargoCostBasis[commodityName]
		if item then
			item.count = math.max(0, (item.count or 0) + deltaCount)
			if item.count <= 0 then
				state.cargoCostBasis[commodityName] = nil
			end
		end
	end
end

function TaxAuthority.RecordCommoditySale(commodityName, count, sellPrice)
	if not commodityName or count <= 0 then return 0, 0 end
	local item = state.cargoCostBasis[commodityName]
	local costBasis = (item and item.avgPrice) or 0
	local grossRevenue = (sellPrice or 0) * count
	local directCost = costBasis * count
	local netProfit = grossRevenue - directCost

	if item then
		item.count = math.max(0, item.count - count)
		if item.count == 0 then
			state.cargoCostBasis[commodityName] = nil
		end
	end

	local bucket = ensureLedgerBucket("FLAGSHIP")
	bucket.revenue = (bucket.revenue or 0) + grossRevenue
	bucket.directCost = (bucket.directCost or 0) + directCost

	local tax = 0
	if netProfit > 0 then
		tax = assessTaxableProfit(netProfit, "tradeProfitTax", "FLAGSHIP", 1.0, Game.time)
	end

	return netProfit, tax
end

function TaxAuthority.GetCommodityCostBasis(commodityName)
	local item = state.cargoCostBasis[commodityName]
	return (item and item.avgPrice) or 0
end

-- BBS contracts, missions & bounties (all profit sources taxable)
function TaxAuthority.RecordBBSIncome(reward, isMilitaryOrBounty)
	if not reward or reward <= 0 then return 0 end
	local bucket = ensureLedgerBucket("FLAGSHIP")
	bucket.revenue = (bucket.revenue or 0) + reward
	local tax = assessTaxableProfit(reward, "bbsJobsTax", "FLAGSHIP", 1.0, Game.time)
	return tax
end

-- Cartography survey data sales
function TaxAuthority.RecordCartographyIncome(earned, isHomeStation)
	if not earned or earned <= 0 then return 0 end
	local bucket = ensureLedgerBucket("FLAGSHIP")
	bucket.revenue = (bucket.revenue or 0) + earned
	local mult = isHomeStation and 0.75 or 1.0
	local tax = assessTaxableProfit(earned, "cartographyTax", "FLAGSHIP", mult, Game.time)
	return tax
end

-- Lottery / windfall 30% tax
function TaxAuthority.RecordWindfall(grossWon, taxWithheld)
	local withheld = taxWithheld or 0
	local _, _, curQIdx = getQuarterFromTime(Game.time or 0)
	local curY, curQ = qIndexToYearQuarter(curQIdx)
	ensureCurrentQuarter(curY, curQ, curQIdx)
	state.currentQuarter.breakdown.windfallTaxWithheld = (state.currentQuarter.breakdown.windfallTaxWithheld or 0) + withheld
	state.stats.totalWindfallTaxWithheld = (state.stats.totalWindfallTaxWithheld or 0) + withheld
	syncSummaryTotals()
end

local function parseLegacySystemPath(pathStr)
	if type(pathStr) ~= "string" or pathStr == "" then return nil end
	local sx, sy, sz, sysIdx, bodyIdx = string.match(pathStr, "^<%s*(-?%d+)%s*,%s*(-?%d+)%s*,%s*(-?%d+)%s*:%s*(%d+)%s*,%s*(%d+)%s*>$")
	if sx then
		local ok, p = pcall(SystemPath.New, tonumber(sx), tonumber(sy), tonumber(sz), tonumber(sysIdx), tonumber(bodyIdx))
		return ok and p or nil
	end
	sx, sy, sz, sysIdx = string.match(pathStr, "^<%s*(-?%d+)%s*,%s*(-?%d+)%s*,%s*(-?%d+)%s*:%s*(%d+)%s*>$")
	if sx then
		local ok, p = pcall(SystemPath.New, tonumber(sx), tonumber(sy), tonumber(sz), tonumber(sysIdx))
		return ok and p or nil
	end
	return nil
end

function TaxAuthority.GetHomeStationPath()
	if not state.isResident then return nil end
	if not state.homeStationSystemPath and state.homeStationPath then
		state.homeStationSystemPath = parseLegacySystemPath(state.homeStationPath)
		if state.homeStationSystemPath and not state.homeSystemPath then
			state.homeSystemPath = state.homeStationSystemPath:SystemOnly()
		end
	end
	return state.homeStationSystemPath
end

function TaxAuthority.GetHomeSystemPath()
	if not state.isResident then return nil end
	local stPath = TaxAuthority.GetHomeStationPath()
	if not state.homeSystemPath and stPath then
		state.homeSystemPath = stPath:SystemOnly()
	end
	return state.homeSystemPath
end

function TaxAuthority.IsHomePath(path)
	if not path or not state.isResident then return false end
	local homeStation = TaxAuthority.GetHomeStationPath()
	local homeSys = TaxAuthority.GetHomeSystemPath()
	if homeStation and path == homeStation then
		return true
	end
	if homeSys and path:IsSameSystem(homeSys) then
		return true
	end
	return false
end

function TaxAuthority.SyncHomeBookmark()
	local bookmarks = PlayerState.GetBookmarks()
	if not state.isResident then
		for id, b in pairs(bookmarks) do
			if b and b.isHome then
				PlayerState.RemoveBookmark(id, true)
			end
		end
		return
	end

	-- Backfill native SystemPath if currently docked at the registered home station
	if not state.homeStationSystemPath and Game.player then
		local docked = Game.player:GetDockedWith()
		if docked and docked.label == state.homeStationName and Game.system and Game.system.name == state.homeSystemName then
			state.homeStationSystemPath = docked.path
			state.homeSystemPath = docked.path and docked.path:SystemOnly() or nil
		end
	end

	local targetPath = TaxAuthority.GetHomeStationPath() or TaxAuthority.GetHomeSystemPath()
	if not targetPath then return end

	local hasMatchingHome = false
	local matchingRegularId = nil
	local staleHomeIds = {}

	for id, b in pairs(bookmarks) do
		if b and b.isHome then
			if b.path == targetPath then
				hasMatchingHome = true
			else
				table.insert(staleHomeIds, id)
			end
		elseif b and b.path == targetPath then
			matchingRegularId = id
		end
	end

	for _, id in ipairs(staleHomeIds) do
		PlayerState.RemoveBookmark(id, true)
	end

	if hasMatchingHome then
		return
	end

	if matchingRegularId then
		local b = bookmarks[matchingRegularId]
		b.isHome = true
		if not b.note or b.note == "" then
			b.note = string.format("Registered Home Station — %s (%s)", state.homeSystemName or "Home", state.homeFaction or "Independent")
		end
		PlayerState.UpdateBookmark(matchingRegularId, b)
	else
		PlayerState.AddBookmark(targetPath, {
			isHome = true,
			note = string.format("Registered Home Station — %s (%s)", state.homeSystemName or "Home", state.homeFaction or "Independent"),
		})
	end
end

function TaxAuthority.IsHomeStation(station)
	if not station or not state.isResident then return false end
	local homePath = TaxAuthority.GetHomeStationPath()
	if homePath and station.path then
		return station.path == homePath
	end
	local label = station.label
	local sys = Game.system and Game.system.name
	local matched = (label == state.homeStationName and sys == state.homeSystemName)
	if matched and station.path and not state.homeStationSystemPath then
		state.homeStationSystemPath = station.path
		state.homeSystemPath = station.path:SystemOnly()
		TaxAuthority.SyncHomeBookmark()
	end
	return matched
end

-- Serialization
local function serialize()
	return {
		state = state
	}
end

local function unserialize(saved)
	local defaults = makeDefaultState()
	local _, _, curQIdx = getQuarterFromTime(Game.time or 0)
	local curY, curQ = qIndexToYearQuarter(curQIdx)

	if saved and saved.state then
		state = saved.state
		state.deductibleExpensePool = state.deductibleExpensePool or defaults.deductibleExpensePool
		state.deductibleCrewPool = math.min(state.deductibleExpensePool, state.deductibleCrewPool or 0)
		state.fractionalTaxCarry = state.fractionalTaxCarry or defaults.fractionalTaxCarry

		local legacyBreakdown = copyBreakdown(state.breakdown)

		state.stats = state.stats or {}
		for k, v in pairs(defaults.stats) do
			state.stats[k] = state.stats[k] or v
		end

		state.entityLedger = state.entityLedger or {}
		state.cargoCostBasis = state.cargoCostBasis or {}
		state.reportedStatements = state.reportedStatements or {}

		-- Migrate pre-quarterly save balance cleanly into current/prior quarter model
		if not state.currentQuarter then
			state.currentQuarter = {
				qIndex = curQIdx,
				year = curY,
				quarter = curQ,
				tax = 0,
				breakdown = makeEmptyBreakdown(),
			}
			local legacyAccrued = state.accruedTax or 0
			if legacyAccrued > 0 and #state.reportedStatements == 0 then
				if state.isDelinquent then
					local stmt = ensureStatementForQuarter(curQIdx - 1)
					stmt.tax = legacyAccrued
					stmt.isDelinquent = true
					stmt.breakdown = legacyBreakdown
				else
					state.currentQuarter.tax = legacyAccrued
					state.currentQuarter.breakdown = legacyBreakdown
				end
			end
		else
			state.currentQuarter.breakdown = copyBreakdown(state.currentQuarter.breakdown)
			state.currentQuarter.tax = state.currentQuarter.tax or 0
		end

		for _, stmt in ipairs(state.reportedStatements) do
			stmt.breakdown = copyBreakdown(stmt.breakdown)
			stmt.tax = stmt.tax or 0
			stmt.penalty = stmt.penalty or 0
			if not stmt.label and stmt.qIndex then stmt.label = formatQuarterLabel(stmt.qIndex) end
			if not stmt.reportLabel and stmt.qIndex then stmt.reportLabel = formatQuarterEndLabel(stmt.qIndex) end
			if not stmt.dueLabel and stmt.qIndex then stmt.dueLabel = formatQuarterEndLabel(stmt.qIndex + 1) end
			if not stmt.reportTime and stmt.qIndex then stmt.reportTime = getQuarterStartTime(stmt.qIndex + 1) end
			if not stmt.dueTime and stmt.qIndex then stmt.dueTime = getQuarterStartTime(stmt.qIndex + 2) end
		end

		if not state.manager then
			state.manager = defaults.manager
		else
			state.manager.quarterlyFee = state.manager.quarterlyFee or MANAGER_QUARTERLY_FEE
			state.manager.totalTaxesSettled = state.manager.totalTaxesSettled or 0
			state.manager.statementsSettled = state.manager.statementsSettled or 0
		end

		syncSummaryTotals()
	else
		state = defaults
		ensureCurrentQuarter(curY, curQ, curQIdx)
	end
end

Event.Register("onGameStart", function()
	cachedEpochOffsetSec = nil
	TaxAuthority.ProcessQuarterlyRollover()
	TaxAuthority.SyncHomeBookmark()
	Timer:CallEvery(15, function()
		if not Game.player then return true end
		TaxAuthority.ProcessQuarterlyRollover()
		return false
	end)
end)

Event.Register("onEnterSystem", function()
	TaxAuthority.ProcessQuarterlyRollover()
end)

Event.Register("onShipDocked", function(ship)
	if ship and ship:IsPlayer() then
		TaxAuthority.ProcessQuarterlyRollover()
		TaxAuthority.SyncHomeBookmark()
	end
end)

Event.Register("onGameEnd", function()
	cachedEpochOffsetSec = nil
	state = makeDefaultState()
end)

Serializer:Register("TaxAuthorityDB", serialize, unserialize)

return TaxAuthority

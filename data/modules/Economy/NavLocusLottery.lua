-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event       = require 'Event'
local Game        = require 'Game'
local PlayerState = require 'PlayerState'
local Serializer  = require 'Serializer'
local Rand       = require 'Rand'
local InterCast  = require 'modules.InterCast.InterCast'

local NavLocusLottery = {}

local STELLAR_CLASSES = { "O", "B", "A", "F", "G", "K", "M", "L", "T", "Y", "W", "D", "N", "X" }

-- Schedule Constants: Drawing occurs every Tuesday at 18:00:00 Galactic Standard Time (GST)
-- Pioneer Game.time epoch is 3200-01-01 00:00:00, which was a Saturday (Day 0).
-- Saturday 0d, Sunday 1d, Monday 2d, Tuesday 3d + 18h = 3 * 86400 + 18 * 3600 = 324,000s
local SECONDS_PER_WEEK = 7 * 86400
local DRAW_DAY_OFFSET = (3 * 86400) + (18 * 3600) -- Tuesday 18:00:00

local NPC_NAMES = {
	"Commander Elena Vance", "Chief Navigator Torin Voss", "Miner Jaxen Cruz",
	"Captain Mira Sterling", "Dr. Aris Thorne", "Free Trader Kaelen Ward",
	"Prospector Silas Drake", "Navigator Anya Chen", "Captain Donald Novak",
	"Surveyor Tessa Cole", "Belter Corin Vane", "Captain Sean Bennett",
	"Commander Varis O'Neill", "Navigator Lyra Kincaid", "Prospector Bram Reyes"
}

local NPC_FACTIONS = {
	"Sirius Mining Syndicate", "Core Systems Cooperative", "Independent Belters Union",
	"Lave Spaceways Trust", "Achenar Royal Cartel", "Sol Astrogation Guild",
	"Alioth Trade Combine", "Outer Rim Prospectors Consortium", "Free Colonies League"
}

local NPC_SYSTEMS = {
	"Sol", "Barnard's Star", "Ross 128", "Lave", "Delta Pavonis",
	"Epsilon Eridani", "Sirius", "Achenar", "Alioth", "Procyon", "Altair", "Vega", "Tau Ceti"
}

local TOTAL_COMBINATIONS = 90720000000000.0 -- 100 * 14 * 3600 * 1800 * 10000 (90.72 Trillion)
local TICKET_PRICE = 10.0

local drawNumber = 1420
local lastDrawTime = 0
local nextDrawTime = 0
-- Scaled to real-world Powerball odds-to-jackpot ratio:
-- Real Powerball: 1 in 292.2M odds at $2 ticket ($584.4M EV scale), $20M baseline (~3.42%), $300M-$2B+ jackpots.
-- Nav-Locus: 1 in 90.72T odds at 10 Cr ticket (907.2T Cr EV scale) -> 30 Trillion Cr baseline (~3.31%).
local baselineJackpot = 30000000000000.0
local jackpotPool = 42500000000000.0 -- Starts mid-rollover at 42.5 Trillion Credits

local winningLocus = {
	ring = 42,
	class = "G",
	ra = 284.5,
	dec = 14.2,
	epoch = 8092,
}

local lastWinner = nil -- Stores info on previous grand jackpot winner
local playerTickets = {} -- List of active tickets/batches
local ticketHistory = {} -- Settled tickets
local totalWinningsCollected = 0
local lotteryTimerActive = false

local function formatCount(val)
	val = math.floor((tonumber(val) or 0) + 0.5)
	local str = string.format("%.0f", math.abs(val))
	local formatted = str:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	if val < 0 then formatted = "-" .. formatted end
	return formatted
end

local function formatCr(val)
	return formatCount(val) .. " Cr"
end

local function formatCompactCr(val)
	val = tonumber(val) or 0
	local absVal = math.abs(val)
	local sign = (val < 0) and "-" or ""
	if absVal >= 1e15 then
		return string.format("%s%.2f Quadrillion Cr", sign, absVal / 1e15)
	elseif absVal >= 1e12 then
		return string.format("%s%.2f Trillion Cr", sign, absVal / 1e12)
	elseif absVal >= 1e9 then
		return string.format("%s%.2f Billion Cr", sign, absVal / 1e9)
	elseif absVal >= 1e6 then
		return string.format("%s%.2f Million Cr", sign, absVal / 1e6)
	end
	return formatCr(val)
end

local function formatTicketVolume(count)
	count = tonumber(count) or 0
	if count >= 1e12 then
		return string.format("%.2fT", count / 1e12)
	elseif count >= 1e9 then
		return string.format("%.1fB", count / 1e9)
	elseif count >= 1e6 then
		return string.format("%.0fM", count / 1e6)
	end
	return formatCount(count)
end

-- Calculates the upcoming Tuesday 18:00:00 GST timestamp relative to time `t`
local function getNextDrawTimestamp(t)
	if t < DRAW_DAY_OFFSET then
		return DRAW_DAY_OFFSET
	end
	local elapsed = t - DRAW_DAY_OFFSET
	local cycles = math.floor(elapsed / SECONDS_PER_WEEK)
	return DRAW_DAY_OFFSET + (cycles + 1) * SECONDS_PER_WEEK
end

local function generateRandomLocus(rand)
	return {
		ring = rand:Integer(0, 99),
		class = STELLAR_CLASSES[rand:Integer(1, #STELLAR_CLASSES)],
		ra = math.floor(rand:Number(0.0, 359.9) * 10) / 10,
		dec = math.floor(rand:Number(-90.0, 90.0) * 10) / 10,
		epoch = rand:Integer(0, 9999),
	}
end

function NavLocusLottery.GetStellarClasses()
	return STELLAR_CLASSES
end

function NavLocusLottery.GetPlayerTickets()
	return playerTickets
end

function NavLocusLottery.GetTicketHistory()
	return ticketHistory
end

function NavLocusLottery.GetTotalWinnings()
	return totalWinningsCollected
end

function NavLocusLottery.GetLastWinner()
	return lastWinner
end

function NavLocusLottery.GetConfig()
	return {
		baselineJackpot = baselineJackpot,
		totalCombinations = TOTAL_COMBINATIONS,
		ticketPrice = TICKET_PRICE,
		tier2Payout = 3000000000.0,
		tier3Payout = 500000.0,
		tier4Payout = 1500.0,
		tier5Payout = 40.0,
	}
end

-- Evaluates a single coordinate vector against winning locus
function NavLocusLottery.EvaluateSingleLocus(locus, targetWinning)
	local matches = 0
	local matchedFields = {}

	if locus.ring == targetWinning.ring then
		matches = matches + 1
		matchedFields.ring = true
	end
	if locus.class == targetWinning.class then
		matches = matches + 1
		matchedFields.class = true
	end
	if math.abs(locus.ra - targetWinning.ra) < 0.05 then
		matches = matches + 1
		matchedFields.ra = true
	end
	if math.abs(locus.dec - targetWinning.dec) < 0.05 then
		matches = matches + 1
		matchedFields.dec = true
	end
	if locus.epoch == targetWinning.epoch then
		matches = matches + 1
		matchedFields.epoch = true
	end

	local payout = 0
	local tierName = "No Match"

	if matches == 5 then
		tierName = "TIER 1: GRAND PROGRESSIVE JACKPOT"
		payout = jackpotPool
	elseif matches == 4 then
		tierName = "TIER 2: 4-VECTOR ALIGNMENT"
		payout = 3000000000.0
	elseif matches == 3 then
		tierName = "TIER 3: 3-VECTOR ALIGNMENT"
		payout = 500000.0
	elseif matches == 2 then
		tierName = "TIER 4: 2-VECTOR ALIGNMENT"
		payout = 1500.0
	elseif matches == 1 and matchedFields.ring then
		tierName = "TIER 5: SECTOR RING MATCH"
		payout = 40.0
	end

	return payout, tierName, matches, matchedFields
end

-- Evaluates a batch ticket against winning locus
local function evaluateBatch(batch, targetWinning)
	local rand = Rand.New(batch.seed)
	local totalPayout = 0
	local tierCounts = { [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0 }

	for i = 1, batch.count do
		local locus = generateRandomLocus(rand)
		local payout, tierName, matches, fields = NavLocusLottery.EvaluateSingleLocus(locus, targetWinning)
		if matches == 5 then
			tierCounts[1] = tierCounts[1] + 1
			totalPayout = totalPayout + payout
		elseif matches == 4 then
			tierCounts[2] = tierCounts[2] + 1
			totalPayout = totalPayout + payout
		elseif matches == 3 then
			tierCounts[3] = tierCounts[3] + 1
			totalPayout = totalPayout + payout
		elseif matches == 2 then
			tierCounts[4] = tierCounts[4] + 1
			totalPayout = totalPayout + payout
		elseif matches == 1 and fields.ring then
			tierCounts[5] = tierCounts[5] + 1
			totalPayout = totalPayout + payout
		end
	end

	return totalPayout, tierCounts, batch.samplePoints
end

function NavLocusLottery.BuySingleTicket(customLocus)
	local cost = 10.0
	if PlayerState.GetMoney() < cost then
		return false, "Insufficient credits (10 Cr required)"
	end

	PlayerState.AddMoney(-cost)
	local randSeed = math.floor((Game.time or 12345) + #playerTickets * 17)
	local rand = Rand.New(randSeed)
	local locus = customLocus or generateRandomLocus(rand)

	local ticket = {
		id = "TKT_" .. tostring(drawNumber) .. "_" .. tostring(#playerTickets + 1),
		drawTarget = drawNumber,
		type = "SINGLE",
		locus = locus,
		cost = cost,
		purchaseTime = Game.time or 0,
	}

	table.insert(playerTickets, ticket)

	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	local okFormat, Format = pcall(require, 'Format')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		local formatMoney = (okFormat and Format and Format.Money) or function(v) return tostring(v) .. " Cr" end
		local locusCoord = string.format("RING %02d | CLASS %s | RA %05.1f° | DEC %+05.1f° | EPOCH #%04d",
			locus.ring, locus.class, locus.ra, locus.dec, locus.epoch)
		FlightLog.RecordTransaction({
			category = "LOTTERY",
			title = string.format("Nav-Locus Lottery Ticket (%s)", formatMoney(-cost)),
			amount = -cost,
			details = {
				{ "Sweepstakes", "Nav-Locus Astrogation Lottery" },
				{ "Draw Target", string.format("Draw Cycle #%d", drawNumber) },
				{ "Ticket Type", "Single Coordinate Entry" },
				{ "Selected Coordinate", locusCoord },
				{ "Wager Cost", formatMoney(cost) },
			},
			note = string.format("Registered lottery ticket coordinate [%s] for Draw #%d.", locusCoord, drawNumber)
		})
	end

	return true, "Nav-Locus Ticket Registered: [" .. tostring(locus.ring) .. " | " .. locus.class .. " | " .. tostring(locus.ra) .. "° | " .. tostring(locus.dec) .. "° | #" .. tostring(locus.epoch) .. "]"
end

function NavLocusLottery.BuyBatchTickets(count)
	if count < 10 then count = 10 end
	local cost = count * 10.0
	if PlayerState.GetMoney() < cost then
		return false, string.format("Insufficient credits (%.0f Cr required)", cost)
	end

	PlayerState.AddMoney(-cost)
	local seed = math.floor((Game.time or 54321) + #playerTickets * 31)

	-- Pre-sample points for instantaneous 3D star-cloud visualization.
	-- Batches of 100 or 1,000 render 100% of loci. Mega-batches (10k-100k) sample 1,500 points
	-- to ensure butter-smooth 60+ FPS in Lua while displaying a dense, vibrant volumetric star cloud.
	local sampleLimit = math.min(1500, count)
	local samplePoints = {}
	local sampleRand = Rand.New(seed)
	for i = 1, sampleLimit do
		table.insert(samplePoints, generateRandomLocus(sampleRand))
	end

	local batch = {
		id = "BATCH_" .. tostring(drawNumber) .. "_" .. tostring(count) .. "_" .. tostring(#playerTickets + 1),
		drawTarget = drawNumber,
		type = "BATCH",
		count = count,
		cost = cost,
		seed = seed,
		samplePoints = samplePoints,
		purchaseTime = Game.time or 0,
	}

	table.insert(playerTickets, batch)

	local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
	local okFormat, Format = pcall(require, 'Format')
	if okFlightLog and FlightLog and FlightLog.RecordTransaction then
		local formatMoney = (okFormat and Format and Format.Money) or function(v) return tostring(v) .. " Cr" end
		FlightLog.RecordTransaction({
			category = "LOTTERY",
			title = string.format("Nav-Locus Batch Purchase: %s Entries (%s)", string.format("%.0f", count), formatMoney(-cost)),
			amount = -cost,
			details = {
				{ "Sweepstakes", "Nav-Locus Astrogation Lottery" },
				{ "Draw Target", string.format("Draw Cycle #%d", drawNumber) },
				{ "Ticket Type", "Batch Coordinate Array" },
				{ "Total Array Entries", string.format("%.0f coordinates", count) },
				{ "Total Wager Cost", formatMoney(cost) },
			},
			note = string.format("Registered batch array of %.0f astrogation coordinates for Draw #%d.", count, drawNumber)
		})
	end

	return true, string.format("Registered Batch of %s Nav-Locus Coordinates (Total Cost: %s Cr)", string.format("%.0f", count), string.format("%.0f", cost))
end

-- Returns all active coordinates owned by player for 3D visualization
function NavLocusLottery.GetAllActivePoints()
	local points = {}
	local maxDisplayPoints = 2500 -- Global visual limit across all tickets to maintain 60+ FPS
	for _, t in ipairs(playerTickets) do
		if t.type == "SINGLE" and t.locus then
			table.insert(points, {
				id = t.id,
				type = "SINGLE",
				locus = t.locus,
			})
		elseif t.type == "BATCH" then
			-- If batch had legacy 60-point cap, expand up to min(1500, t.count) using its deterministic seed
			local targetCount = math.min(1500, t.count or 100)
			if (not t.samplePoints or #t.samplePoints < targetCount) and t.seed then
				t.samplePoints = {}
				local sampleRand = Rand.New(t.seed)
				for i = 1, targetCount do
					table.insert(t.samplePoints, generateRandomLocus(sampleRand))
				end
			end
			if t.samplePoints then
				for _, pt in ipairs(t.samplePoints) do
					if #points >= maxDisplayPoints then break end
					table.insert(points, {
						id = t.id,
						type = "BATCH",
						locus = pt,
					})
				end
			end
		end
	end
	return points
end

-- Executes the scheduled draw at a given cycle timestamp
local function executeScheduledDraw(drawTimestamp)
	local rand = Rand.New(math.floor(drawTimestamp))
	drawNumber = drawNumber + 1

	local newWinningLocus = generateRandomLocus(rand)
	winningLocus = newWinningLocus

	local locusStr = string.format("RING %02d | CLASS %s | RA %05.1f° | DEC %+05.1f° | EPOCH #%04d",
		winningLocus.ring, winningLocus.class, winningLocus.ra, winningLocus.dec, winningLocus.epoch)

	-- Settle player tickets
	local playerTotalWon = 0
	local playerWonGrandJackpot = false
	local settledTickets = {}
	local remainingTickets = {}
	local hadActiveTickets = (#playerTickets > 0)

	for _, t in ipairs(playerTickets) do
		if t.drawTarget <= drawNumber then
			if t.type == "SINGLE" then
				local payout, tierName, matches, fields = NavLocusLottery.EvaluateSingleLocus(t.locus, winningLocus)
				t.payout = payout
				t.tierName = tierName
				t.settledDraw = drawNumber
				playerTotalWon = playerTotalWon + payout
				if matches == 5 then
					playerWonGrandJackpot = true
				end
				table.insert(settledTickets, t)
			elseif t.type == "BATCH" then
				local payout, tierCounts, samplePoints = evaluateBatch(t, winningLocus)
				t.payout = payout
				t.tierCounts = tierCounts
				t.settledDraw = drawNumber
				playerTotalWon = playerTotalWon + payout
				if tierCounts[1] and tierCounts[1] > 0 then
					playerWonGrandJackpot = true
				end
				table.insert(settledTickets, t)
			end
		else
			table.insert(remainingTickets, t)
		end
	end

	-- Move settled tickets to history
	for _, st in ipairs(settledTickets) do
		table.insert(ticketHistory, 1, st)
	end
	playerTickets = remainingTickets

	-- Credit player winnings (with 30% interstellar windfall tax withholding)
	if playerTotalWon > 0 then
		local windfallTax = math.floor(playerTotalWon * 0.30)
		local netWon = playerTotalWon - windfallTax
		PlayerState.AddMoney(netWon)
		totalWinningsCollected = totalWinningsCollected + netWon
		local okTax, TaxAuthority = pcall(require, 'modules.Economy.TaxAuthority')
		if okTax and TaxAuthority and TaxAuthority.RecordWindfall then
			TaxAuthority.RecordWindfall(playerTotalWon, windfallTax)
		end

		local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
		local okFormat, Format = pcall(require, 'Format')
		if okFlightLog and FlightLog and FlightLog.RecordTransaction then
			local formatMoney = (okFormat and Format and Format.Money) or function(v) return tostring(v) .. " Cr" end
			FlightLog.RecordTransaction({
				category = "LOTTERY",
				title = string.format("Nav-Locus Prize Payout (+%s)", formatMoney(netWon)),
				amount = netWon,
				details = {
					{ "Sweepstakes", "Nav-Locus Astrogation Lottery" },
					{ "Draw Cycle", string.format("Draw Cycle #%d", drawNumber) },
					{ "Winning Coordinate Vector", locusStr },
					{ "Gross Prize Won", formatMoney(playerTotalWon) },
					{ "Windfall Tax Withheld (30%)", formatMoney(windfallTax) },
					{ "Net Payout Disbursed", formatMoney(netWon) },
				},
				note = string.format("Claimed %s in lottery winnings for Draw #%d (Winning Vector: %s).", formatMoney(netWon), drawNumber, locusStr)
			})
		end
	end

	local dateStr = InterCast.FormatDate and InterCast.FormatDate() or "3200-01-01"

	-- Handle Grand Jackpot resolution (Player vs NPC vs Rollover)
	if playerWonGrandJackpot then
		-- Player hit the Grand Progressive Jackpot!
		local playerName = (Game.player and Game.player:GetLabel()) or "Pilot"
		local currentSys = (Game.system and Game.system.name) or "Sol"
		lastWinner = {
			name = "Commander " .. playerName,
			faction = "Independent Pilot",
			system = currentSys,
			amount = jackpotPool,
			isPlayer = true,
			drawNumber = drawNumber,
		}

		InterCast.AddArticle({
			id = "art_lotto_draw_" .. tostring(drawNumber),
			category = "MARKET",
			headline = string.format("COMMANDER %s CLAIMS %s NAV-LOCUS GRAND JACKPOT!", string.upper(playerName), string.upper(formatCompactCr(jackpotPool))),
			system = currentSys,
			date = dateStr,
			bureau = "Interstellar Sweepstakes Authority",
			summary = string.format("Commander %s has aligned all 5 astrogation vectors in %s, claiming the historic %s grand jackpot!", playerName, currentSys, formatCompactCr(jackpotPool)),
			body = string.format("In a historic galactic astrogation event, Commander %s operating in the %s system has successfully verified winning coordinate vector [%s] for Cycle #%d! The entire grand progressive pool of %s (%s) has been credited. The baseline progressive jackpot resets to %s (%s) for next Tuesday's drawing.", playerName, currentSys, locusStr, drawNumber, formatCompactCr(jackpotPool), formatCr(jackpotPool), formatCompactCr(baselineJackpot), formatCr(baselineJackpot)),
			urgent = true,
		})

		jackpotPool = baselineJackpot
	else
		-- Real-World Dynamic Lottery Economics (scaled to 1 in 90.72 Trillion galactic odds & Powerball EV ratio):
		-- 1. Base ticket sales scale with the size of the progressive jackpot pool (jackpot frenzy).
		--    At baseline 30T Cr: ~1.4T to 2.2T tickets sold across settled space (~5% -> ~2% win probability).
		--    At 150T+ Cr: ~15T+ tickets sold (~16% win probability).
		local poolRatio = math.max(1.0, jackpotPool / baselineJackpot)
		local baseSales = rand:Number(1400000000000.0, 2200000000000.0)
		local salesMultiplier = poolRatio ^ 1.35
		local simulatedTicketsSold = math.floor(baseSales * salesMultiplier)

		-- 2. Real-world mechanics: 50% of gross ticket sales (10 Cr/ticket) are contributed to the progressive pool
		local ticketPrice = TICKET_PRICE
		local poolContributionPercent = 0.50
		local poolContribution = simulatedTicketsSold * ticketPrice * poolContributionPercent

		-- 3. Exact 5-vector combinatorial probability: 1 in 90,720,000,000,000 (90.72 Trillion)
		local singleTicketWinProb = 1.0 / TOTAL_COMBINATIONS
		local expectedWinners = simulatedTicketsSold * singleTicketWinProb

		-- Determine number of NPC winners (multiple winners possible when jackpot is massive)
		local numWinners = 0
		-- Poisson approximation using binomial trials for small expected values
		local pNoWin = math.exp(-expectedWinners)
		local roll = rand:Number(0, 1)
		if roll > pNoWin then
			-- At least 1 winner.
			numWinners = 1
			-- Check for multiple winners (shares)
			local pMoreWinners = 1 - math.exp(-expectedWinners * 0.45)
			while (numWinners < 5) and (rand:Number(0, 1) < pMoreWinners) do
				numWinners = numWinners + 1
				pMoreWinners = pMoreWinners * 0.4
			end
		end

		if numWinners > 0 then
			-- An NPC consortium, pilot, or multiple winners won and split the Grand Jackpot!
			local splitAmount = jackpotPool / numWinners
			local winnerNames = {}
			local winnerSummaries = {}

			for w = 1, numWinners do
				local npcName = NPC_NAMES[rand:Integer(1, #NPC_NAMES)]
				local npcFaction = NPC_FACTIONS[rand:Integer(1, #NPC_FACTIONS)]
				local sysName = NPC_SYSTEMS[rand:Integer(1, #NPC_SYSTEMS)]
				table.insert(winnerNames, string.format("%s (%s, %s)", npcName, npcFaction, sysName))
				table.insert(winnerSummaries, npcName)

				if w == 1 then
					lastWinner = {
						name = npcName,
						faction = npcFaction,
						system = sysName,
						amount = splitAmount,
						isPlayer = false,
						drawNumber = drawNumber,
						sharedCount = numWinners,
					}
				end
			end

			local winnerHeadline
			local winnerSummaryText
			local winnerBodyText
			local ticketVolStr = formatTicketVolume(simulatedTicketsSold)
			if numWinners == 1 then
				winnerHeadline = string.format("NAV-LOCUS CYCLE #%d GRAND JACKPOT CLAIMED: %s", drawNumber, string.upper(formatCompactCr(jackpotPool)))
				winnerSummaryText = string.format("Grand jackpot of %s claimed by %s. Pool resets to 30.00 Trillion Cr.", formatCompactCr(jackpotPool), winnerNames[1])
				winnerBodyText = string.format("The Interstellar Sweepstakes Authority confirms that the Cycle #%d Grand Progressive Jackpot of %s (%s) was officially claimed by a single winning chit: %s. An estimated %s tickets were purchased pan-galactic. With winning coordinate vector [%s] ratified, the pool resets to %s (%s) for next Tuesday's drawing.",
					drawNumber, formatCompactCr(jackpotPool), formatCr(jackpotPool), winnerNames[1], ticketVolStr, locusStr, formatCompactCr(baselineJackpot), formatCr(baselineJackpot))
			else
				winnerHeadline = string.format("NAV-LOCUS CYCLE #%d: %s JACKPOT SPLIT AMONG %d WINNERS", drawNumber, string.upper(formatCompactCr(jackpotPool)), numWinners)
				winnerSummaryText = string.format("Grand jackpot of %s split across %d winning chits (%s each). Pool resets to 30.00 Trillion Cr.",
					formatCompactCr(jackpotPool), numWinners, formatCompactCr(splitAmount))
				winnerBodyText = string.format("The Interstellar Sweepstakes Authority confirms that unprecedented ticket volume (%s tickets sold) yielded %d separate grand winning chits for Cycle #%d. Each winner receives an equal share of %s (%s): %s. Coordinate vector [%s] has been ratified, and the jackpot resets to %s (%s).",
					ticketVolStr, numWinners, drawNumber, formatCompactCr(splitAmount), formatCr(splitAmount), table.concat(winnerNames, "; "), locusStr, formatCompactCr(baselineJackpot), formatCr(baselineJackpot))
			end

			InterCast.AddArticle({
				id = "art_lotto_draw_" .. tostring(drawNumber),
				category = "MARKET",
				headline = winnerHeadline,
				system = lastWinner.system or "Pan-Galactic Relay",
				date = dateStr,
				bureau = "Interstellar Sweepstakes Authority",
				summary = winnerSummaryText,
				body = winnerBodyText,
				urgent = true,
			})

			jackpotPool = baselineJackpot
		else
			-- No Grand Winner — Real-world dynamic progressive rollover:
			-- Pool increases by 50% of the simulated ticket revenue plus base carryover
			jackpotPool = jackpotPool + poolContribution
			local ticketVolStr = formatTicketVolume(simulatedTicketsSold)

			InterCast.AddArticle({
				id = "art_lotto_draw_" .. tostring(drawNumber),
				category = "MARKET",
				headline = string.format("GALACTIC NAV-LOCUS DRAW #%d WINNING VECTOR BROADCAST", drawNumber),
				system = "Pan-Galactic Relay",
				date = dateStr,
				bureau = "Interstellar Sweepstakes Authority",
				summary = string.format("Winning Locus: [%s]. %s tickets sold, no grand match verified — pool rolls over to %s!",
					locusStr, ticketVolStr, formatCompactCr(jackpotPool)),
				body = string.format("The Interstellar Sweepstakes Authority has ratified winning coordinate vector [%s] for Cycle #%d. With %s tickets entered pan-galactic and no grand 5-vector match verified, 50%% of gross sales (%s) has been added to the progressive reserve. The jackpot has rolled over to %s (%s) for next Tuesday's drawing at 18:00:00 GST.",
					locusStr, drawNumber, ticketVolStr, formatCompactCr(poolContribution), formatCompactCr(jackpotPool), formatCr(jackpotPool)),
				urgent = (jackpotPool >= 150000000000000.0),
			})
		end
	end

	-- Ship Cockpit Comms Transmission
	local okComms, Comms = pcall(require, 'Comms')
	if okComms and Comms and Comms.Message then
		if playerTotalWon > 0 then
			Comms.Message(
				string.format("NAV-LOCUS CYCLE #%d: Winning Vector [%s]. Prize: %s credited to your account!",
					drawNumber, locusStr, formatCr(playerTotalWon)),
				"Sweepstakes Authority"
			)
		elseif hadActiveTickets then
			Comms.Message(
				string.format("NAV-LOCUS CYCLE #%d: Winning Vector [%s]. No matching vectors on active chits. Next draw: Tuesday 18:00 GST.",
					drawNumber, locusStr),
				"Sweepstakes Authority"
			)
		end
	end
end

-- Master function that verifies if the draw is due and advances it
function NavLocusLottery.CheckDraw(curTime)
	curTime = curTime or (Game.time or 0)
	if curTime <= 0 then return end

	if nextDrawTime == 0 then
		nextDrawTime = getNextDrawTimestamp(curTime)
		lastDrawTime = nextDrawTime - SECONDS_PER_WEEK
	end

	-- If scheduled draw time is reached or surpassed (in real-time or macro jump)
	local catchupCount = 0
	while (curTime >= nextDrawTime) and (catchupCount < 5) do
		executeScheduledDraw(nextDrawTime)
		lastDrawTime = nextDrawTime
		nextDrawTime = lastDrawTime + SECONDS_PER_WEEK
		catchupCount = catchupCount + 1
	end

	-- Snap if elapsed jump was unusually massive (> 5 weeks)
	if curTime >= nextDrawTime then
		nextDrawTime = getNextDrawTimestamp(curTime)
		lastDrawTime = nextDrawTime - SECONDS_PER_WEEK
	end
end

-- Advances draw on Macro Galaxy simulation ticks (e.g. hyperspace jumps)
function NavLocusLottery.OnMacroTick(curTime)
	NavLocusLottery.CheckDraw(curTime or (Game.time or 0))
end

function NavLocusLottery.GetDrawState()
	local curTime = Game.time or 0
	NavLocusLottery.CheckDraw(curTime)

	if nextDrawTime == 0 then
		nextDrawTime = getNextDrawTimestamp(curTime)
		lastDrawTime = nextDrawTime - SECONDS_PER_WEEK
	end

	local timeRemaining = math.max(0, nextDrawTime - curTime)
	return {
		drawNumber = drawNumber,
		jackpotPool = jackpotPool,
		winningLocus = winningLocus,
		timeRemaining = timeRemaining,
		daysRemaining = math.floor(timeRemaining / 86400),
		hoursRemaining = math.floor((timeRemaining % 86400) / 3600),
		minutesRemaining = math.floor((timeRemaining % 3600) / 60),
		secondsRemaining = math.floor(timeRemaining % 60),
		nextDrawTime = nextDrawTime,
		lastWinner = lastWinner,
	}
end

-- Hook game events to verify draw timing continuously
local function checkDrawTick()
	if Game.time then
		NavLocusLottery.CheckDraw(Game.time)
	end
end

Event.Register("onGameStart", function()
	if lotteryTimerActive then return end
	local okTimer, Timer = pcall(require, 'Timer')
	if okTimer and Timer and Timer.CallEvery then
		lotteryTimerActive = true
		-- Check hourly in game time; UI & MacroGalaxyEngine catch up on demand
		Timer:CallEvery(3600, checkDrawTick)
	end
end)

Event.Register("onGameEnd", function()
	lotteryTimerActive = false
end)

Event.Register("onEnterSystem", checkDrawTick)

local function serialize()
	return {
		drawNumber = drawNumber,
		lastDrawTime = lastDrawTime,
		nextDrawTime = nextDrawTime,
		jackpotPool = jackpotPool,
		winningLocus = winningLocus,
		lastWinner = lastWinner,
		playerTickets = playerTickets,
		ticketHistory = ticketHistory,
		totalWinningsCollected = totalWinningsCollected,
	}
end

local function unserialize(data)
	if data then
		drawNumber = data.drawNumber or 1420
		lastDrawTime = data.lastDrawTime or 0
		nextDrawTime = data.nextDrawTime or 0
		jackpotPool = data.jackpotPool or 42500000000000.0
		-- Smoothly migrate legacy pre-rebalance saves (500M-2B scale) up to Powerball-scaled 30T+ scale
		if jackpotPool < baselineJackpot then
			local extra = math.max(0.0, jackpotPool - 500000000.0) * 60000.0
			jackpotPool = math.min(120000000000000.0, baselineJackpot + extra)
		end
		winningLocus = data.winningLocus or winningLocus
		lastWinner = data.lastWinner
		playerTickets = data.playerTickets or {}
		ticketHistory = data.ticketHistory or {}
		totalWinningsCollected = data.totalWinningsCollected or 0
	end
end

Serializer:Register("NavLocusLotteryDB", serialize, unserialize)

return NavLocusLottery

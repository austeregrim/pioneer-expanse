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

local drawNumber = 1420
local lastDrawTime = 0
local nextDrawTime = 0
local jackpotPool = 684500000.0 -- Starts at ~684.5 Million Credits
local baselineJackpot = 500000000.0

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

local function formatCr(val)
	return string.format("%.0f Cr", val)
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
		payout = 2500000.0
	elseif matches == 3 then
		tierName = "TIER 3: 3-VECTOR ALIGNMENT"
		payout = 75000.0
	elseif matches == 2 then
		tierName = "TIER 4: 2-VECTOR ALIGNMENT"
		payout = 1500.0
	elseif matches == 1 and (matchedFields.ring or matchedFields.class) then
		tierName = "TIER 5: SECTOR/CLASS RECOVERY"
		payout = 15.0
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
		elseif matches == 1 and (fields.ring or fields.class) then
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
	local rand = Rand.New(math.floor((Game.time or os.time()) + #playerTickets * 17))
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
	return true, "Nav-Locus Ticket Registered: [" .. tostring(locus.ring) .. " | " .. locus.class .. " | " .. tostring(locus.ra) .. "° | " .. tostring(locus.dec) .. "° | #" .. tostring(locus.epoch) .. "]"
end

function NavLocusLottery.BuyBatchTickets(count)
	if count < 10 then count = 10 end
	local cost = count * 10.0
	if PlayerState.GetMoney() < cost then
		return false, string.format("Insufficient credits (%.0f Cr required)", cost)
	end

	PlayerState.AddMoney(-cost)
	local seed = math.floor((Game.time or os.time()) + #playerTickets * 31)

	-- Pre-sample 60 points for instantaneous 3D star-cloud visualization
	local samplePoints = {}
	local sampleRand = Rand.New(seed)
	for i = 1, math.min(60, count) do
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
	return true, string.format("Registered Batch of %s Nav-Locus Coordinates (Total Cost: %s Cr)", string.format("%.0f", count), string.format("%.0f", cost))
end

-- Returns all active coordinates owned by player for 3D visualization
function NavLocusLottery.GetAllActivePoints()
	local points = {}
	for _, t in ipairs(playerTickets) do
		if t.type == "SINGLE" and t.locus then
			table.insert(points, {
				id = t.id,
				type = "SINGLE",
				locus = t.locus,
			})
		elseif t.type == "BATCH" and t.samplePoints then
			for _, pt in ipairs(t.samplePoints) do
				table.insert(points, {
					id = t.id,
					type = "BATCH",
					locus = pt,
				})
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

	-- Credit player winnings
	if playerTotalWon > 0 then
		PlayerState.AddMoney(playerTotalWon)
		totalWinningsCollected = totalWinningsCollected + playerTotalWon
	end

	local dateStr = string.format("CYCLE %d", drawNumber)

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
			headline = string.format("COMMANDER %s CLAIMS %s CR NAV-LOCUS GRAND JACKPOT!", string.upper(playerName), formatCr(jackpotPool)),
			system = currentSys,
			date = dateStr,
			bureau = "Interstellar Sweepstakes Authority",
			summary = string.format("Commander %s has aligned all 5 astrogation vectors in %s, claiming the historic %s Credits grand jackpot!", playerName, currentSys, formatCr(jackpotPool)),
			body = string.format("In a historic galactic astrogation event, Commander %s operating in the %s system has successfully verified winning coordinate vector [%s] for Cycle #%d! The entire grand progressive pool of %s Credits has been credited. The baseline progressive jackpot resets to 500,000,000 Credits for next Tuesday's drawing.", playerName, currentSys, locusStr, drawNumber, formatCr(jackpotPool)),
			urgent = true,
		})

		jackpotPool = baselineJackpot
	else
		-- Check NPC Winner chance (Base ~4.5%, scaling up slightly with multi-billion pools)
		local npcWinChance = 4.5
		if jackpotPool > 1200000000.0 then
			npcWinChance = math.min(12.0, 4.5 + (jackpotPool - 1200000000.0) / 200000000.0)
		end

		if rand:Number(0, 100) < npcWinChance then
			-- An NPC consortium or pilot won the Grand Jackpot!
			local npcName = NPC_NAMES[rand:Integer(1, #NPC_NAMES)]
			local npcFaction = NPC_FACTIONS[rand:Integer(1, #NPC_FACTIONS)]
			local sysName = NPC_SYSTEMS[rand:Integer(1, #NPC_SYSTEMS)]
			local wonAmount = jackpotPool

			lastWinner = {
				name = npcName,
				faction = npcFaction,
				system = sysName,
				amount = wonAmount,
				isPlayer = false,
				drawNumber = drawNumber,
			}

			InterCast.AddArticle({
				id = "art_lotto_draw_" .. tostring(drawNumber),
				category = "MARKET",
				headline = string.format("NAV-LOCUS CYCLE #%d GRAND JACKPOT CLAIMED: %s CR", drawNumber, formatCr(wonAmount)),
				system = sysName,
				date = dateStr,
				bureau = "Interstellar Sweepstakes Authority",
				summary = string.format("Grand jackpot of %s Cr claimed in %s by %s (%s). Pool resets to 500M Cr.", formatCr(wonAmount), sysName, npcName, npcFaction),
				body = string.format("The Interstellar Sweepstakes Authority confirms that the Cycle #%d Grand Progressive Jackpot of %s Credits was officially claimed by %s representing the %s, registered via transponder relay in the %s system. With winning coordinate vector [%s] ratified, the pan-galactic pool resets to 500,000,000 Credits for next Tuesday's drawing.", drawNumber, formatCr(wonAmount), npcName, npcFaction, sysName, locusStr),
				urgent = true,
			})

			jackpotPool = baselineJackpot
		else
			-- No Grand Winner — Progressive Rollover (+75M to +150M Cr)
			local rollover = rand:Number(75000000.0, 150000000.0)
			jackpotPool = jackpotPool + rollover

			InterCast.AddArticle({
				id = "art_lotto_draw_" .. tostring(drawNumber),
				category = "MARKET",
				headline = string.format("GALACTIC NAV-LOCUS DRAW #%d WINNING VECTOR BROADCAST", drawNumber),
				system = "Pan-Galactic Relay",
				date = dateStr,
				bureau = "Interstellar Sweepstakes Authority",
				summary = string.format("Winning Locus: [%s]. No grand match verified — pool rolls over to %s Cr!", locusStr, formatCr(jackpotPool)),
				body = string.format("The Interstellar Sweepstakes Authority has ratified winning coordinate vector [%s] for Cycle #%d across all synchronized subspace transponders. With no grand vector match verified across pan-galactic registries, the progressive pool has rolled over to %s Credits for next Tuesday's drawing at 18:00:00 GST.", locusStr, drawNumber, formatCr(jackpotPool)),
				urgent = (jackpotPool > 1000000000.0),
			})
		end
	end

	-- Ship Cockpit Comms Transmission
	local okComms, Comms = pcall(require, 'Comms')
	if okComms and Comms and Comms.Message then
		if playerTotalWon > 0 then
			Comms.Message(
				string.format("NAV-LOCUS CYCLE #%d: Winning Vector [%s]. Prize: %s Cr credited to your account!",
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
	local okTimer, Timer = pcall(require, 'Timer')
	if okTimer and Timer and Timer.CallEvery then
		-- Check every 2 seconds of game flight time in real-time
		Timer:CallEvery(2, checkDrawTick)
	end
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
		jackpotPool = data.jackpotPool or 684500000.0
		winningLocus = data.winningLocus or winningLocus
		lastWinner = data.lastWinner
		playerTickets = data.playerTickets or {}
		ticketHistory = data.ticketHistory or {}
		totalWinningsCollected = data.totalWinningsCollected or 0
	end
end

Serializer:Register("NavLocusLotteryDB", serialize, unserialize)

return NavLocusLottery

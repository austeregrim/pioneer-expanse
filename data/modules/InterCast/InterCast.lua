-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event      = require 'Event'
local Game       = require 'Game'
local Format     = require 'Format'
local Serializer = require 'Serializer'

local SystemPath = require 'SystemPath'

local InterCast = {}

---@class InterCastArticle
---@field id string
---@field category "FRONTLINE"|"HUMANITARIAN"|"MARKET"|"POLITICS"
---@field headline string
---@field system string
---@field systemPath any
---@field date string
---@field bureau string
---@field summary string
---@field body string
---@field urgent boolean

local articles = {}
local readArticles = {}
local flaggedArticles = {}
local currentHeadlineIndex = 1
local lastHeadlineSwitchTime = 0
local TICKER_CYCLE_INTERVAL = 14.0 -- Cycle headline every 14 seconds

local STORY_TEMPLATES = {
	FRONTLINE = {
		{
			headline = "SOL ALLIANCE NAVAL CONTINGENT MOBILIZES NEAR VEGA SECTOR",
			system = "Vega",
			systemPath = SystemPath.New(-3, -1, 1, 0),
			bureau = "InterCast Sol Core Bureau",
			summary = "Alliance naval commanders confirmed high-readiness deployment along the border following reported radar anomalies.",
			body = "In an emergency communique issued from Alliance High Command at Earth, naval forces have mobilized battlegroups to secure perimeter transit lanes bordering Independent space. Civilians and commercial freighters traversing regional hyperlanes are advised to submit flight logs to military checkpoints upon arrival. Border patrols have reported sporadic skirmishes with unidentified strike wings.",
			urgent = true,
		},
		{
			headline = "FEDERATION FORCES IMPOSE NAVAL BLOCKADE ON TAU CETI TRANSIT CORRIDOR",
			system = "Tau Ceti",
			systemPath = SystemPath.New(0, -2, -1, 0),
			bureau = "InterCast Federation Bureau",
			summary = "Federal customs and defense gunships have restricted orbital starport access citing contraband weapon shipments.",
			body = "Federal authorities have established an orbital exclusion zone around major starports in the Tau Ceti system. Commercial transports carrying military ordinance or unregistered commodities are subject to interdiction and impoundment. Independent merchant syndicates have condemned the blockade as an economic strangulation of free trade.",
			urgent = true,
		},
		{
			headline = "CEASEFIRE ACCORD BROKERED BETWEEN COLONIAL FACTIONS IN ROSS 128",
			system = "Ross 128",
			systemPath = SystemPath.New(0, 1, 0, 0),
			bureau = "InterCast Frontier Desk",
			summary = "Diplomatic envoys have signed an interim armistice following three weeks of intensive skirmishing over asteroid claim rights.",
			body = "Following weeks of attrition over contested mining rights in the inner belt, colonial representatives have ratified an initial ceasefire. Demilitarized orbital corridors have been established under mutual supervision, though local commanders warn that underlying treaty disputes remain unresolved.",
			urgent = false,
		},
		{
			headline = "HIGH-INTENSITY COMBAT ZONES DETECTED NEAR EPSILON ERIDANI INNER BELT",
			system = "Epsilon Eridani",
			systemPath = SystemPath.New(1, -1, -1, 0),
			bureau = "InterCast Tactical Recon",
			summary = "Mercenary fleets and syndicate gunships have engaged heavy corporate defense patrols across prime extraction sectors.",
			body = "Tactical telemetry confirms heavy exchanges of thermal beam fire across mining claims near Epsilon Eridani IV. Station traffic control has issued an active hazard notice, warning unarmed haulers to route around orbital insertion lanes until perimeter security is re-established.",
			urgent = true,
		},
	},

	HUMANITARIAN = {
		{
			headline = "OUTBREAK: EMERGENCY MEDICAL QUARANTINE IMPOSED IN BARNARD'S STAR",
			system = "Barnard's Star",
			systemPath = SystemPath.New(-1, 0, 0, 0),
			bureau = "InterCast Medical Wire",
			summary = "Starport health authorities have declared a planetary quarantine following widespread spread of an airborne respiratory strain.",
			body = "Medical authorities have placed planetary surface outposts and orbital colonies under severe medical containment. Local pharmaceutical supplies are critically exhausted, and starport directors are offering premium bounties for urgent shipments of medicines and vaccines. Pilots arriving with medical aid are granted immediate priority docking clearance.",
			urgent = true,
		},
		{
			headline = "SEVERE FAMINE DECLARED IN LALANDE 21185 COLONIES; RELIEF HAULERS DESPERATELY NEEDED",
			system = "Lalande 21185",
			systemPath = SystemPath.New(0, 0, 0, 0),
			bureau = "InterCast Colonial Relief Desk",
			summary = "Hydroponic failure has triggered widespread food shortages, sparking urgent distress calls across neighboring sectors.",
			body = "A cascade failure across atmospheric greenhouse domes has wiped out over 80% of local grain and vegetable harvests in the Lalande 21185 system. Starport governors have released emergency reserve funds to purchase grain, livestock, and synthesized food rations at multiple times standard market value.",
			urgent = true,
		},
		{
			headline = "REFUGEE CONVOYS EVACUATE BORDER MINING OUTPOSTS AMID ESCALATING CRISIS",
			system = "Tau Ceti",
			systemPath = SystemPath.New(0, -2, -1, 0),
			bureau = "InterCast Humanitarian Watch",
			summary = "Hundreds of civilian workers and dependents have boarded evacuation transports bound for central core systems.",
			body = "With regional infrastructure failing and security guarantees collapsing along the outer rim, charter transports have begun evacuating non-combatant populations. Station berths are overwhelmed, and volunteer pilots are assisting in passenger ferrying operations.",
			urgent = false,
		},
	},

	MARKET = {
		{
			headline = "MINING STRIKE TRIGGERS MASSIVE PRECIOUS METALS DEFICIT IN WOLF 359",
			system = "Wolf 359",
			systemPath = SystemPath.New(0, 0, 0, 0),
			bureau = "InterCast Commodities Exchange",
			summary = "A labor dispute across orbital refineries has frozen shipments of titanium, platinum, and industrial alloys.",
			body = "Industrial production lines across the sector face immediate shortages as refinery workers in Wolf 359 halt operations. Commodity brokers report metal prices surging over 300% on regional exchanges, creating unprecedented margins for independent haulers willing to run replacement shipments.",
			urgent = false,
		},
		{
			headline = "HYDROGEN FUEL EXPORT TARIFFS ENACTED ACROSS FEDERATION PORTS",
			system = "Sol",
			systemPath = SystemPath.New(0, 0, 0, 0),
			bureau = "InterCast Economic Analysis",
			summary = "New regional export taxes on liquid hydrogen and military fuel have disrupted long-distance trade routes.",
			body = "Federal trade commissioners have ratified new tariff levies on interstellar fuel exports, citing strategic stockpile preservation. Long-haul freighters and expedition vessels are stockpiling hydrogen at unaligned stations before regional price increases take full effect.",
			urgent = false,
		},
		{
			headline = "BLACK MARKET WEAPONS BOOM EXPANDS IN UNGOVERNED ANARCHY BORDERS",
			system = "Barnard's Star",
			systemPath = SystemPath.New(-1, 0, 0, 0),
			bureau = "InterCast Underworld Syndicate",
			summary = "Lax customs enforcement in unaligned systems has drawn high-stakes weapons cartels and smugglers.",
			body = "Independent investigators report record volumes of military-grade laser components and combat electronics passing through frontier relay stations. Local security forces lack the patrol tonnage to inspect deep-space transfers, leaving corridors wide open for illicit commerce.",
			urgent = false,
		},
	},

	POLITICS = {
		{
			headline = "INTERSTELLAR SUMMIT OPENS: SUPERPOWERS CONVENE OVER HYPERSPACE TRANSIT RIGHTS",
			system = "Sol",
			systemPath = SystemPath.New(0, 0, 0, 0),
			bureau = "InterCast Political Bureau",
			summary = "Diplomats from Earth, the Federation, and Independent leagues have gathered to debate hyperlane navigation treaties.",
			body = "Representatives from major spacefaring civilizations have assembled for a high-stakes legislative session. Key agenda items include the standardization of beacon transponder frequencies, universal search-and-rescue covenants, and freedom-of-navigation guarantees for unarmed commercial shipping.",
			urgent = false,
		},
		{
			headline = "HIGH-VALUE SYNDICATE BOUNTY POSTED FOR CAPTURE OF NOTORIOUS CORSAIR LEADER",
			system = "Tau Ceti",
			systemPath = SystemPath.New(0, -2, -1, 0),
			bureau = "InterCast Security Digest",
			summary = "Regional starport authorities have authorized an unprecedented 250,000 CR bounty for the capture of pirate warlords.",
			body = "Following coordinated raids on commercial fuel convoys, starport security commissioners have authorized lethal interdiction warrants. Licensed bounty hunters and combat-rated mercenaries are mobilizing across neighboring frontier starports.",
			urgent = false,
		},
		{
			headline = "COLONIAL LEAGUE ANNOUNCES SOVEREIGN EXPANSION CHARTER FOR OUTER STARS",
			system = "Vega",
			systemPath = SystemPath.New(-3, -1, 1, 0),
			bureau = "InterCast Frontier Governance",
			summary = "Pioneer exploratory fleets prepare to claim unchartered systems along the Orion-Cygnus arm.",
			body = "Spurred by high mineral yields and new scientific discoveries, colonial authorities have granted land and mineral charters for newly surveyed star systems. Surveyors and explorer vessels are commanding record bounties for planetary cartography data.",
			urgent = false,
		},
	},
}

function InterCast.FormatDate(t)
	t = t or Game.time or 0
	if Game.GetPartsFromDateTime then
		local second, minute, hour, day, month, year = Game.GetPartsFromDateTime(t)
		if year then
			return string.format("%04d-%02d-%02d", year, month, day)
		end
	end
	local totalDays = math.floor(t / 86400)
	local year = 3200 + math.floor(totalDays / 365)
	local dayOfYear = (totalDays % 365) + 1
	local month = math.min(12, math.floor(dayOfYear / 30) + 1)
	local day = (dayOfYear % 30) + 1
	return string.format("%04d-%02d-%02d", year, month, day)
end

function InterCast.NormalizeDate(rawDate)
	if not rawDate or rawDate == "" then
		return InterCast.FormatDate()
	end
	-- Convert YYYY.MM.DD (dots) to YYYY-MM-DD (dashes)
	local y, m, d = tostring(rawDate):match("^(%d%d%d%d)%.(%d%d)%.(%d%d)$")
	if y and m and d then
		return string.format("%s-%s-%s", y, m, d)
	end
	-- Already YYYY-MM-DD
	if tostring(rawDate):match("^%d%d%d%d%-%d%d%-%d%d$") then
		return tostring(rawDate)
	end
	-- If it's "CYCLE %d" or non-standard format, fallback to current calendar date
	return InterCast.FormatDate()
end

local function generateSeedArticles()
	articles = {}
	local articleIdCounter = 1

	for categoryName, templateList in pairs(STORY_TEMPLATES) do
		for _, t in ipairs(templateList) do
			table.insert(articles, {
				id = "art_" .. tostring(articleIdCounter),
				category = categoryName,
				headline = t.headline,
				system = t.system or (t.headline:match("IN ([%a%s%d']+)") or t.headline:match("ON ([%a%s%d']+)") or "Sol"),
				systemPath = t.systemPath,
				date = InterCast.FormatDate(),
				bureau = t.bureau,
				summary = t.summary,
				body = t.body,
				urgent = t.urgent or false,
			})
			articleIdCounter = articleIdCounter + 1
		end
	end
end

function InterCast.GetArticles(categoryFilter)
	if #articles == 0 then
		generateSeedArticles()
	end

	if not categoryFilter or categoryFilter == "ALL" then
		return articles
	end

	local filtered = {}
	for _, art in ipairs(articles) do
		if art.category == categoryFilter then
			table.insert(filtered, art)
		end
	end
	return filtered
end

function InterCast.GetLatestHeadline(uiTime)
	if #articles == 0 then
		generateSeedArticles()
	end

	if uiTime and (uiTime - lastHeadlineSwitchTime >= TICKER_CYCLE_INTERVAL) then
		currentHeadlineIndex = currentHeadlineIndex + 1
		if currentHeadlineIndex > #articles then
			currentHeadlineIndex = 1
		end
		lastHeadlineSwitchTime = uiTime
	end

	return articles[currentHeadlineIndex]
end

function InterCast.CycleNextHeadline()
	if #articles == 0 then
		generateSeedArticles()
	end
	currentHeadlineIndex = currentHeadlineIndex + 1
	if currentHeadlineIndex > #articles then
		currentHeadlineIndex = 1
	end
	return articles[currentHeadlineIndex]
end

function InterCast.AddArticle(art)
	if not art then return end
	art.date = InterCast.NormalizeDate(art.date)
	table.insert(articles, 1, art)
	-- Keep list bounded to last 120 stories for historical day navigation
	if #articles > 120 then
		table.remove(articles)
	end
end

function InterCast.IsRead(artId)
	if not artId then return false end
	return readArticles[artId] == true
end

function InterCast.MarkRead(artId)
	if artId and not readArticles[artId] then
		readArticles[artId] = true
	end
end

function InterCast.IsFlagged(artId)
	if not artId then return false end
	return flaggedArticles[artId] == true
end

function InterCast.ToggleFlagged(artId)
	if not artId then return false end
	if flaggedArticles[artId] then
		flaggedArticles[artId] = nil
		return false
	else
		flaggedArticles[artId] = true
		return true
	end
end

function InterCast.GetFlaggedCount()
	local count = 0
	for _, _ in pairs(flaggedArticles) do count = count + 1 end
	return count
end

function InterCast.GetUniqueDates()
	local dates = {}
	local seen = {}
	for _, art in ipairs(articles) do
		if art.date and not seen[art.date] then
			seen[art.date] = true
			table.insert(dates, art.date)
		end
	end
	return dates
end

local function onEnterSystem()
	-- On entering a new system, check if an urgent localized report should be added
	if Game.system and #articles > 0 then
		local sysName = Game.system.name
		-- Chance to add localized headline
		local dateStr = InterCast.FormatDate()
		local localArticle = {
			id = "art_local_" .. tostring(Game.time or 0),
			category = "MARKET",
			headline = string.format("LOCAL WIRE: COMMERCE AND TRADE DISPATCH FROM %s", string.upper(sysName)),
			system = sysName,
			systemPath = Game.system.path,
			date = dateStr,
			bureau = string.format("InterCast %s Bureau", sysName),
			summary = string.format("Station authorities in %s report steady starport traffic and active bulletin board commercial contracts.", sysName),
			body = string.format("Vessels arriving in the %s system are reminded to comply with starport speed limitations within 5 km of docking bays. Starport commodity exchanges are actively quoting bulk trades across industrial, agricultural, and mineral markets.", sysName),
			urgent = false,
		}
		InterCast.AddArticle(localArticle)
	end
end

Event.Register("onGameStart", function()
	if #articles == 0 then
		generateSeedArticles()
	end
end)

Event.Register("onEnterSystem", onEnterSystem)

local function serialize()
	return {
		articles = articles,
		currentIndex = currentHeadlineIndex,
		readArticles = readArticles,
		flaggedArticles = flaggedArticles,
	}
end

local function unserialize(data)
	if data and data.articles and #data.articles > 0 then
		articles = data.articles
		for _, art in ipairs(articles) do
			art.date = InterCast.NormalizeDate(art.date)
		end
		currentHeadlineIndex = data.currentIndex or 1
		readArticles = data.readArticles or {}
		flaggedArticles = data.flaggedArticles or {}
	else
		generateSeedArticles()
	end
end

Serializer:Register("InterCastDB", serialize, unserialize)

return InterCast


-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event      = require 'Event'
local Game       = require 'Game'
local Engine     = require 'Engine'
local Timer      = require 'Timer'
local Serializer = require 'Serializer'
local Rand       = require 'Rand'

local SystemPath = require 'SystemPath'

local InterCast = {}

---@class InterCastArticle
---@field id string
---@field category "FRONTLINE"|"HUMANITARIAN"|"MARKET"|"POLITICS"
---@field headline string
---@field system string
---@field systemPath any
---@field date string
---@field timeStr string
---@field timestamp number
---@field bureau string
---@field summary string
---@field body string
---@field urgent boolean
---@field effects table?

local MAX_ARTICLES = 320
local WIRE_MIN_STEP_SEC = 180   -- ~20/hr max cadence
local WIRE_MAX_STEP_SEC = 280   -- ~13/hr min cadence (avg ~16/hr)
local WIRE_CATCHUP_WINDOW_SEC = 7200 -- Cap backfill to latest 2 game hours on huge skips
local WIRE_MAX_BATCH_PER_TICK = 36

local articles = {}
local readArticles = {}
local flaggedArticles = {}
local currentHeadlineIndex = 1
local lastHeadlineSwitchTime = 0
local lastWireGenTime = 0
local nextWireAt = 0
local wireSeqCounter = 1
local wireTimerActive = false
local isUpdatingWire = false
local TICKER_CYCLE_INTERVAL = 14.0 -- Cycle headline every 14 seconds

local cachedMacroEngine = false
local cachedStockExchange = false

local function getMacroEngine()
	if cachedMacroEngine == false then
		local ok, mod = pcall(require, 'modules.MacroGalaxy.MacroGalaxyEngine')
		cachedMacroEngine = ok and mod or nil
	end
	return cachedMacroEngine
end

local function getStockExchange()
	if cachedStockExchange == false then
		local ok, mod = pcall(require, 'modules.Economy.StockExchange')
		cachedStockExchange = ok and mod or nil
	end
	return cachedStockExchange
end

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

local CORP_NEWS_EVENTS = {
	{
		ticker = "SIRIUS", system = "Sirius", category = "MARKET",
		posHead = "SIRIUS HEAVY INDUSTRIAL REPORTS RECORD BELT SMELTING YIELDS",
		posSum = "Automated platinum-group ore dredgers outperform quarterly extraction targets across inner-ring claims.",
		posBody = "Sirius Heavy Industrial engineers confirmed a surge in refined metal throughput following deployment of upgraded plasma kilns. Institutional desks raised near-term margin guidance across metallurgical equities.",
		negHead = "ORE DREDGER POWER COUPLING RECALL HITS SIRIUS HEAVY INDUSTRIAL",
		negSum = "Unplanned maintenance halts 14% of deep-belt extraction barges pending thermal shielding inspection.",
		negBody = "Safety inspectors ordered temporary stand-downs for heavy mineral barges operated by Sirius Heavy Industrial after thruster manifold anomalies surfaced during routine assays. Analysts trimmed near-term output forecasts.",
		instMag = 0.018, driftMag = 0.012,
	},
	{
		ticker = "COREDYN", system = "Sol", category = "FRONTLINE",
		posHead = "CORE DYNAMICS AEROSPACE SECURES MULTI-SECTOR PATROL CORVETTE ORDER",
		posSum = "Federal defense procurement board ratifies expanded escort hull and turret delivery schedule.",
		posBody = "Core Dynamics Aerospace orbital yards locked in an accelerated production tranche for system defense patrol hulls and heavy thermal beam arrays. Defense sector analysts projected stronger quarterly backlog conversion.",
		negHead = "NAVAL ACCEPTANCE TRIALS DELAY COREDYN FRIGATE DELIVERIES",
		negSum = "Fire-control calibration discrepancies push back scheduled fleet handovers at Sol orbital drydocks.",
		negBody = "Core Dynamics Aerospace acknowledged minor telemetry calibration delays during live-fire acceptance trials on its latest cruiser avionics suite, triggering short-term profit-taking among aerospace investors.",
		instMag = 0.020, driftMag = 0.014,
	},
	{
		ticker = "CETIBIO", system = "Tau Ceti", category = "HUMANITARIAN",
		posHead = "CETI BIOPHARM RECEIVES FAST-TRACK CLEARANCE FOR BROAD-SPECTRUM ANTIVIRAL",
		posSum = "Colonial health ministries place bulk reserve orders for cold-chain vaccine canisters.",
		posBody = "Ceti BioPharm & GeneTech announced full regulatory certification for its rapid-synthesis pathogen stabilizer. Starport medical depots across frontier sectors have begun pre-positioning emergency stock.",
		negHead = "PHARMA PRICING AUDIT PRESSURES CETI BIOPHARM MARGINS",
		negSum = "Interstellar medical oversight committee reviews wholesale vaccine contract markups.",
		negBody = "Regulatory auditors issued formal pricing inquiries targeting Ceti BioPharm's emergency distribution contracts, prompting cautious repositioning on pharmaceutical exchanges.",
		instMag = 0.022, driftMag = 0.015,
	},
	{
		ticker = "AGRICORE", system = "Alpha Centauri", category = "HUMANITARIAN",
		posHead = "AGRICORE PAN-GALACTIC EXPANDS HIGH-YIELD HYDROPONIC BIOSPHERES",
		posSum = "Next-generation nutrient synthesis domes boost caloric export capacity by 18%.",
		posBody = "AgriCore Pan-Galactic commissioned six orbital biosphere arrays designed to stabilize grain and synthetic protein reserves for outer colonies. Commodity desks welcomed the additional supply buffer.",
		negHead = "NUTRIENT ALGAE CONTAMINATION FORCES AGRICORE DOME SCRUBBING",
		negSum = "Production yields dip temporarily at major hydroponic hubs during biological filter replacement.",
		negBody = "AgriCore technicians initiated precautionary sterilization across two orbital agro-complexes following trace spore detection. Near-term agricultural export volumes are expected to tighten slightly.",
		instMag = 0.019, driftMag = 0.012,
	},
	{
		ticker = "UNITRANS", system = "Epsilon Eridani", category = "MARKET",
		posHead = "UNIVERSAL TRANSIT & FREIGHT POSTS SURGING HYPERLANE VOLUME",
		posSum = "Automated bulk convoy scheduling cuts orbital turnaround times across core trade corridors.",
		posBody = "Universal Transit & Freight reported strong freight-tonnage growth as independent and corporate haulers increased jump frequency between industrial hubs. Logistics equities rallied on improved utilization.",
		negHead = "HYPERLANE CONGESTION & FUEL SURCHARGES SQUEEZE UNITRANS MARGINS",
		negSum = "Port queuing delays across busy core relays dampen quarterly freight profitability.",
		negBody = "Universal Transit & Freight warned shareholders that heightened customs inspections and hydrogen spot volatility weighed on short-haul corridor margins over the past trading cycle.",
		instMag = 0.017, driftMag = 0.011,
	},
	{
		ticker = "GUTAMAYA", system = "Vega", category = "POLITICS",
		posHead = "GUTAMAYA UNVEILS HARMONIC SHIELD EMITTER UPGRADE FOR LUXURY HULLS",
		posSum = "Strong pre-orders from wealthy private commanders bolster aerospace order books.",
		posBody = "Gutamaya Advanced Technologies showcased next-generation low-signature shield matrices at its Vega showroom, drawing brisk reservation deposits from corporate executives and private fleet owners.",
		negHead = "CUSTOMS EXPORT QUOTAS SLOW GUTAMAYA LUXURY CHASSIS DELIVERIES",
		negSum = "Cross-border tariff paperwork delays high-end avionics shipments to outer markets.",
		negBody = "Gutamaya Advanced Technologies flagged longer customs clearance windows on bespoke shipframe exports, weighing modestly on near-term delivery guidance.",
		instMag = 0.016, driftMag = 0.010,
	},
	{
		ticker = "ACHILLES", system = "Procyon", category = "MARKET",
		posHead = "ACHILLES ORBITAL ROBOTICS WINS STATION GANTRY AUTOMATION CONTRACT",
		posSum = "Twelve regional starports adopt autonomous cargo-handling and repair drone suites.",
		posBody = "Achilles Orbital Robotics finalized a broad infrastructure modernization agreement to install automated cargo cranes and hull-welders across Procyon and neighboring hubs.",
		negHead = "FIRMWARE PATCH MANDATED FOR ACHILLES MINING DRONE CONTROLLERS",
		negSum = "Routine telemetry fix temporarily slows autonomous belt-drone deployment rates.",
		negBody = "Achilles Orbital Robotics issued a mandatory safety patch for industrial drone swarms after minor pathfinding faults were logged in dense asteroid fields.",
		instMag = 0.018, driftMag = 0.011,
	},
	{
		ticker = "HELIOS", system = "Barnard's Star", category = "MARKET",
		posHead = "HELIOS FUSION CARTEL OPENS HIGH-EFFICIENCY DEUTERIUM SKIMMER ARRAY",
		posSum = "Gas-giant atmospheric harvesting expansion lowers internal refining costs.",
		posBody = "Helios Fusion & Energy Cartel brought a new orbital deuterium distillation platform online, strengthening propellant distribution capacity for long-range hyperdrive vessels.",
		negHead = "GAS GIANT STORM DISRUPTS HELIOS ATMOSPHERIC SCOOPING RIGS",
		negSum = "Severe magnetospheric shear forces temporary retraction of hydrogen harvesting tethers.",
		negBody = "Helios Fusion & Energy Cartel suspended atmospheric skimming operations for 36 hours amid intense upper-atmosphere turbulence, tightening local hydrogen spot reserves.",
		instMag = 0.020, driftMag = 0.013,
	},
}

local SECURITY_DISPATCHES = {
	{
		cat = "FRONTLINE", urgent = true,
		head = "CORSAIR WING DETECTED RAIDING HYPERLANE LANES NEAR %s",
		sum = "System traffic control reports heightened FSD interdiction signatures along outer transit corridors.",
		body = "Port telemetry in %s recorded multiple distress beacons from commercial freighters targeted by pirate raiders. Haulers without interdiction nullifiers or defensive escorts are urged to remain vigilant when running distant orbital stations.",
		piracyDelta = 4.0, corpTicker = "COREDYN", corpInst = 0.008, corpDrift = 0.005,
	},
	{
		cat = "FRONTLINE", urgent = false,
		head = "SYSTEM SECURITY LAUNCHES ANTI-PIRACY SWEEP IN %s SECTOR",
		sum = "Patrol wings establish sensor pickets across primary shipping lanes and mining rings.",
		body = "Authorities in %s have stepped up supercruise interdiction patrols following recent freighter harassment reports. Bounty hunters operating in the sector report brisk pirate interdiction activity around planetary rings.",
		piracyDelta = -2.0, corpTicker = "COREDYN", corpInst = 0.005, corpDrift = 0.003,
	},
	{
		cat = "POLITICS", urgent = false,
		head = "CUSTOMS AUTHORITIES TIGHTEN TRANSPONDER COMPLIANCE IN %s",
		sum = "Patrol cruisers conduct random dark-running scans across inbound orbital approaches.",
		body = "Customs officials in %s reminded visiting pilots that active transponder beacons are mandatory inside controlled starport corridors. Unregistered vessels face immediate citation and inspection.",
		piracyDelta = 0.0, corpTicker = nil,
	},
}

local CIVIC_DISPATCHES = {
	{
		cat = "MARKET",
		head = "FREIGHT BROKERS REPORT BRISK ARBITRAGE TRAFFIC THROUGH %s EXCHANGE",
		sum = "Independent haulers and corporate fleets rebalance regional commodity stockpiles.",
		body = "Starport logistics desks in %s logged steady two-way cargo tonnage across alloy, electronics, and agricultural markets. Brokers note that sustained deliveries rapidly compress spot arbitrage spreads.",
		ticker = "UNITRANS", inst = 0.006, drift = 0.004,
	},
	{
		cat = "HUMANITARIAN",
		head = "COLONIAL HABITAT UPGRADES EXPAND HYDRO-RECYCLING CAPACITY IN %s",
		sum = "Orbital life-support engineers complete quarterly atmospheric scrubber overhauls.",
		body = "Civic authorities in %s announced successful commissioning of auxiliary water and air-processing modules across surface domes, improving resilience against supply chain delays.",
		ticker = "CETIBIO", inst = 0.005, drift = 0.003,
	},
	{
		cat = "POLITICS",
		head = "PORT AUTHORITY PUBLISHES QUARTERLY TAX & INFRASTRUCTURE LEDGER IN %s",
		sum = "Commercial docking fees and trade levies support local starport defense grids.",
		body = "The %s Station Treasury released routine quarterly accounting figures, citing healthy commercial trade compliance and continued funding for orbital traffic control.",
		ticker = nil,
	},
	{
		cat = "MARKET",
		head = "BELTER ASSAY OFFICE LOGS STEADY RING EXTRACTION ACTIVITY IN %s",
		sum = "Refinery tenders continue absorbing metallic and rocky asteroid ore deliveries.",
		body = "Mineral brokers at %s report consistent incoming ore shipments from automated and independent mining craft operating in nearby planetary ring systems.",
		ticker = "SIRIUS", inst = 0.006, drift = 0.004,
	},
}

function InterCast.FormatDate(t)
	t = t or Game.time or 0
	if Game.GetPartsFromDateTime then
		local _, _, _, day, month, year = Game.GetPartsFromDateTime(t)
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

function InterCast.FormatTime(t)
	t = t or Game.time or 0
	if Game.GetPartsFromDateTime then
		local _, minute, hour = Game.GetPartsFromDateTime(t)
		if hour ~= nil and minute ~= nil then
			return string.format("%02d:%02d", hour, minute)
		end
	end
	local secInDay = math.floor(t) % 86400
	local hour = math.floor(secInDay / 3600)
	local minute = math.floor((secInDay % 3600) / 60)
	return string.format("%02d:%02d", hour, minute)
end

function InterCast.NormalizeDate(rawDate, ts)
	if not rawDate or rawDate == "" then
		return InterCast.FormatDate(ts)
	end
	local y, m, d = tostring(rawDate):match("^(%d%d%d%d)%.(%d%d)%.(%d%d)$")
	if y and m and d then
		return string.format("%s-%s-%s", y, m, d)
	end
	if tostring(rawDate):match("^%d%d%d%d%-%d%d%-%d%d$") then
		return tostring(rawDate)
	end
	return InterCast.FormatDate(ts)
end

local function generateSeedArticles()
	articles = {}
	local articleIdCounter = 1
	local baseTs = Game.time or 0

	for categoryName, templateList in pairs(STORY_TEMPLATES) do
		for _, t in ipairs(templateList) do
			local ts = math.max(0, baseTs - articleIdCounter * 240)
			table.insert(articles, {
				id = "art_" .. tostring(articleIdCounter),
				category = categoryName,
				headline = t.headline,
				system = t.system or (t.headline:match("IN ([%a%s%d']+)") or t.headline:match("ON ([%a%s%d']+)") or "Sol"),
				systemPath = t.systemPath,
				timestamp = ts,
				date = InterCast.FormatDate(ts),
				timeStr = InterCast.FormatTime(ts),
				bureau = t.bureau,
				summary = t.summary,
				body = t.body,
				urgent = t.urgent or false,
			})
			articleIdCounter = articleIdCounter + 1
		end
	end
end

local function generateSingleWireArticle(ts, rand)
	wireSeqCounter = wireSeqCounter + 1
	local MacroEngine = getMacroEngine()
	local StockExchange = getStockExchange()
	local okMacro = MacroEngine ~= nil
	local okStock = StockExchange ~= nil
	local crises = (MacroEngine and MacroEngine.GetActiveCrises) and MacroEngine.GetActiveCrises() or {}
	local systems = (okMacro and MacroEngine and MacroEngine.GetRegionalSystems) and MacroEngine.GetRegionalSystems()
		or { "Sol", "Tau Ceti", "Alpha Centauri", "Barnard's Star", "Sirius", "Vega", "Epsilon Eridani", "Procyon" }

	local dateStr = InterCast.FormatDate(ts)
	local timeStr = InterCast.FormatTime(ts)
	local roll = rand:Number(0, 1)

	-- 1. Corporate / Stock Market Dispatch (35%)
	if roll < 0.35 then
		local tmpl = CORP_NEWS_EVENTS[rand:Integer(1, #CORP_NEWS_EVENTS)]
		local isPositive = rand:Number(0, 1) < 0.52
		local sign = isPositive and 1 or -1
		local instPct = sign * tmpl.instMag * rand:Number(0.65, 1.35)
		local driftPct = sign * tmpl.driftMag * rand:Number(0.65, 1.35)
		local headline = isPositive and tmpl.posHead or tmpl.negHead
		local summary = isPositive and tmpl.posSum or tmpl.negSum
		local body = isPositive and tmpl.posBody or tmpl.negBody

		local stockEffects = {}
		if okStock and StockExchange and StockExchange.ApplyNewsShock then
			StockExchange.ApplyNewsShock(tmpl.ticker, instPct, driftPct, 24, headline)
			local stObj = StockExchange.GetStock(tmpl.ticker)
			if stObj then
				table.insert(stockEffects, {
					ticker = stObj.ticker,
					name = stObj.name,
					instantPct = instPct * 100.0,
					dailyDriftPct = driftPct * 100.0,
					currentPrice = stObj.price,
					basePrice = stObj.basePrice,
					note = string.format("Direct Wire Shock (%+.2f%% instant, %+.2f%%/day for 24h)", instPct * 100.0, driftPct * 100.0),
				})
			end
		end

		return {
			id = string.format("art_wire_%d_%d", math.floor(ts), wireSeqCounter),
			category = tmpl.category,
			headline = headline,
			system = tmpl.system,
			timestamp = ts,
			date = dateStr,
			timeStr = timeStr,
			bureau = "InterCast Financial Wire",
			summary = summary,
			body = body,
			urgent = math.abs(instPct) >= 0.022,
			effects = {
				source = "Corporate Equity Wire",
				stocks = stockEffects,
				commodities = {},
			},
		}

	-- 2. Active Macro Crisis Follow-up Dispatch (25%)
	elseif roll < 0.60 and #crises > 0 then
		local c = crises[rand:Integer(1, #crises)]
		local cSysUpper = string.upper(c.system or "CORE")
		local followHeads = {
			OUTBREAK = {
				"MEDICAL LOGISTICS UPDATE: QUARANTINE CHECKPOINTS ACTIVE IN " .. cSysUpper,
				"Cold-chain pharma transports receive priority docking lanes across affected orbital stations.",
				"Health coordinators in " .. c.system .. " report ongoing demand for vaccines, broad-spectrum medicines, and atmospheric scrubbers as containment protocols continue."
			},
			FAMINE = {
				"CALORIC RELIEF DISPATCH: GRAIN TENDERS REMAIN ELEVATED IN " .. cSysUpper,
				"Starport agricultural directors renew emergency import subsidies for food freighters.",
				"Relief convoys arriving in " .. c.system .. " continue discharging grain and synthesized rations while damaged greenhouse sectors undergo reconstruction."
			},
			BLOCKADE = {
				"BLOCKADE WATCH: PATROL CORRIDORS ENFORCED AROUND " .. cSysUpper .. " PORTS",
				"Customs cutters continue intercepting contraband freighters near orbital exclusion buoys.",
				"Naval task forces stationed in " .. c.system .. " maintain strict cargo manifests and heightened tax surcharges on military and strategic commodities."
			},
			INSURGENCY = {
				"TACTICAL WIRE: SKIRMISHES CONTINUE ALONG " .. cSysUpper .. " OUTER LANES",
				"Mercenary and defense patrols clash with insurgent raiders near orbital installations.",
				"Security advisories remain in force across " .. c.system .. ", with freight captains warned of elevated pirate and insurgent interdiction activity."
			},
			MINERAL_RUSH = {
				"MINING EXCHANGE: SPECULATIVE ORE BIDS HOLD STRONG IN " .. cSysUpper,
				"Belter syndicates expand extraction claims across rich planetary ring belts.",
				"Refineries in " .. c.system .. " report heavy traffic from automated mining barges and mining machinery haulers capitalizing on the assay boom."
			},
			SUPPLY_GLUT = {
				"WAREHOUSE OVERHANG: SMELTING STOCKPILES WEIGH ON " .. cSysUpper .. " QUOTES",
				"Commodity depots struggle to clear surplus raw metals and industrial ores.",
				"Spot prices for ores and refined metals remain deeply discounted in " .. c.system .. " while export freighters gradually draw down excess warehouse stock."
			},
			TARIFF_WAR = {
				"CUSTOMS ALERT: BORDER SURCHARGES SLOW TECH IMPORTS INTO " .. cSysUpper,
				"Commercial haulers absorb higher import levies on machinery and avionics.",
				"Customs inspectors in " .. c.system .. " continue enforcing retaliatory tariff schedules on high-tech cargo, boosting local system tax assessments."
			},
			LABOR_STRIKE = {
				"PORT DISPATCH: DOCKING GANTRIES OPERATE ON SKELETON CREWS IN " .. cSysUpper,
				"Freight turnaround queues persist across major orbital terminals.",
				"Union pickets remain active at starport cargo bays in " .. c.system .. ", tightening local availability of industrial machinery and alloys."
			},
			ANTITRUST_PROBE = {
				"REGULATORY WIRE: TRADE TRIBUNAL CONTINUES HEARINGS IN " .. cSysUpper,
				"Corporate compliance auditors review regional freight and pharma pricing records.",
				"Antitrust investigators in " .. c.system .. " released interim subpoena schedules, keeping aerospace and pharmaceutical equities under pressure."
			},
			INDUSTRIAL_DISASTER = {
				"SAFETY BULLETIN: ORBITAL REPAIR CREWS REBUILD RING PLANTS IN " .. cSysUpper,
				"Propellant and industrial parts remain constrained during containment work.",
				"Engineering salvage barges in " .. c.system .. " continue clearing orbital debris around damaged manufacturing docks."
			},
		}
		local tpl = followHeads[c.type] or {
			"REGIONAL UPDATE: ONGOING SITUATION MONITORED IN " .. cSysUpper,
			c.summary or "Regional authorities continue active response operations.",
			c.body or ("Station authorities in " .. c.system .. " continue monitoring regional developments."),
		}

		local stockFx = (okStock and StockExchange and StockExchange.GetCrisisStockImpacts) and StockExchange.GetCrisisStockImpacts(c) or {}
		local commFx = (okMacro and MacroEngine and MacroEngine.GetCommodityEffectsForCrisis) and MacroEngine.GetCommodityEffectsForCrisis(c) or {}
		local taxFx = (okMacro and MacroEngine and MacroEngine.GetTaxEffectForCrisis) and MacroEngine.GetTaxEffectForCrisis(c) or nil
		local piracyFx = (okMacro and MacroEngine and MacroEngine.GetPiracyEffectForCrisis) and MacroEngine.GetPiracyEffectForCrisis(c) or nil

		return {
			id = string.format("art_wire_%d_%d", math.floor(ts), wireSeqCounter),
			category = c.category or "MARKET",
			headline = tpl[1],
			system = c.system,
			timestamp = ts,
			date = dateStr,
			timeStr = timeStr,
			bureau = string.format("InterCast %s Bureau", c.system),
			summary = tpl[2],
			body = tpl[3],
			urgent = (c.severity or 1) >= 2,
			effects = {
				source = "MacroGalaxy Crisis Follow-Up",
				crisis = {
					id = c.id,
					system = c.system,
					type = c.type,
					severity = c.severity,
					progress = c.progress,
					progressRate = c.progressRate,
				},
				stocks = stockFx,
				commodities = commFx,
				tax = taxFx,
				piracy = piracyFx,
			},
		}

	-- 3. Security / Piracy Dispatch (20%)
	elseif roll < 0.80 then
		local sysName = systems[rand:Integer(1, #systems)]
		local sec = SECURITY_DISPATCHES[rand:Integer(1, #SECURITY_DISPATCHES)]
		local stockEffects = {}
		if sec.corpTicker and okStock and StockExchange and StockExchange.ApplyNewsShock then
			StockExchange.ApplyNewsShock(sec.corpTicker, sec.corpInst, sec.corpDrift, 12, string.format(sec.head, string.upper(sysName)))
			local stObj = StockExchange.GetStock(sec.corpTicker)
			if stObj then
				table.insert(stockEffects, {
					ticker = stObj.ticker,
					name = stObj.name,
					instantPct = sec.corpInst * 100.0,
					dailyDriftPct = sec.corpDrift * 100.0,
					currentPrice = stObj.price,
					basePrice = stObj.basePrice,
					note = string.format("Security Wire Reaction (%+.2f%% instant, %+.2f%%/day)", sec.corpInst * 100.0, sec.corpDrift * 100.0),
				})
			end
		end
		return {
			id = string.format("art_wire_%d_%d", math.floor(ts), wireSeqCounter),
			category = sec.cat,
			headline = string.format(sec.head, string.upper(sysName)),
			system = sysName,
			timestamp = ts,
			date = dateStr,
			timeStr = timeStr,
			bureau = "InterCast Security Wire",
			summary = sec.sum,
			body = string.format(sec.body, sysName),
			urgent = sec.urgent,
			effects = {
				source = "Regional Security Wire",
				stocks = stockEffects,
				commodities = {},
				piracy = (sec.piracyDelta ~= 0) and {
					threatDeltaPct = sec.piracyDelta,
					note = string.format("Reported corridor hazard shift (%+.1f%% regional threat)", sec.piracyDelta)
				} or nil,
			},
		}

	-- 4. Civic / Trade / Infrastructure Dispatch (20%)
	else
		local sysName = (Game.system and rand:Number(0, 1) < 0.25) and Game.system.name or systems[rand:Integer(1, #systems)]
		local civ = CIVIC_DISPATCHES[rand:Integer(1, #CIVIC_DISPATCHES)]
		local stockEffects = {}
		if civ.ticker and okStock and StockExchange and StockExchange.ApplyNewsShock then
			local dir = (rand:Number(0, 1) < 0.65) and 1 or -1
			local inst = dir * civ.inst
			local drift = dir * civ.drift
			StockExchange.ApplyNewsShock(civ.ticker, inst, drift, 12, string.format(civ.head, string.upper(sysName)))
			local stObj = StockExchange.GetStock(civ.ticker)
			if stObj then
				table.insert(stockEffects, {
					ticker = stObj.ticker,
					name = stObj.name,
					instantPct = inst * 100.0,
					dailyDriftPct = drift * 100.0,
					currentPrice = stObj.price,
					basePrice = stObj.basePrice,
					note = string.format("Sector Wire Drift (%+.2f%% instant, %+.2f%%/day)", inst * 100.0, drift * 100.0),
				})
			end
		end
		return {
			id = string.format("art_wire_%d_%d", math.floor(ts), wireSeqCounter),
			category = civ.cat,
			headline = string.format(civ.head, string.upper(sysName)),
			system = sysName,
			timestamp = ts,
			date = dateStr,
			timeStr = timeStr,
			bureau = string.format("InterCast %s Desk", sysName),
			summary = civ.sum,
			body = string.format(civ.body, sysName),
			urgent = false,
			effects = {
				source = "Regional Commerce Wire",
				stocks = stockEffects,
				commodities = {},
			},
		}
	end
end

function InterCast.UpdateWireToTime(curTime, maxBatch)
	if isUpdatingWire then return 0 end
	curTime = curTime or (Game.time or 0)
	if curTime <= 0 then return 0 end

	if #articles == 0 then
		generateSeedArticles()
	end

	if lastWireGenTime <= 0 or curTime < lastWireGenTime then
		lastWireGenTime = math.max(0, curTime - 3600)
		nextWireAt = lastWireGenTime + WIRE_MIN_STEP_SEC
	end

	if curTime < nextWireAt then
		return 0
	end

	isUpdatingWire = true
	-- Never backfill years of discarded stories on huge time jumps: jump to the latest 2h window
	if (curTime - lastWireGenTime) > WIRE_CATCHUP_WINDOW_SEC then
		lastWireGenTime = curTime - WIRE_CATCHUP_WINDOW_SEC
		nextWireAt = lastWireGenTime + WIRE_MIN_STEP_SEC
	end

	local limit = maxBatch or WIRE_MAX_BATCH_PER_TICK
	local generated = 0
	local rand = Rand.New(math.floor(curTime) + #articles * 31 + wireSeqCounter)

	while nextWireAt <= curTime and generated < limit do
		local artTs = nextWireAt
		local art = generateSingleWireArticle(artTs, rand)
		if art then
			InterCast.AddArticle(art)
			generated = generated + 1
		end
		lastWireGenTime = artTs
		nextWireAt = artTs + rand:Integer(WIRE_MIN_STEP_SEC, WIRE_MAX_STEP_SEC)
	end

	if nextWireAt <= curTime then
		lastWireGenTime = curTime
		nextWireAt = curTime + WIRE_MIN_STEP_SEC
	end

	isUpdatingWire = false
	return generated
end

function InterCast.ForceGenerateBatch(count)
	local n = math.clamp(tonumber(count) or 12, 1, 40)
	local curTime = Game.time or 0
	local rand = Rand.New(math.floor(curTime) + wireSeqCounter * 17 + 77)
	for i = 1, n do
		local ts = math.max(0, curTime - (n - i) * 180)
		local art = generateSingleWireArticle(ts, rand)
		if art then
			InterCast.AddArticle(art)
		end
	end
	lastWireGenTime = curTime
	nextWireAt = curTime + WIRE_MIN_STEP_SEC
	return n
end

function InterCast.GetArticleDebugEffects(art)
	if not art then return nil end
	local fx = art.effects and {
		source = art.effects.source,
		crisis = art.effects.crisis,
		stocks = art.effects.stocks or {},
		commodities = art.effects.commodities or {},
		tax = art.effects.tax,
		piracy = art.effects.piracy,
	} or {
		source = "Static / Local Wire",
		stocks = {},
		commodities = {},
	}

	-- Enrich with live crisis state if article references a system with an active crisis and fx has no crisis block
	if (not fx.crisis) and art.system then
		local MacroEngine = getMacroEngine()
		if MacroEngine and MacroEngine.GetCrisisForSystem then
			local c = MacroEngine.GetCrisisForSystem(art.system)
			if c then
				fx.crisis = {
					id = c.id,
					system = c.system,
					type = c.type,
					severity = c.severity,
					progress = c.progress,
					progressRate = c.progressRate,
				}
				if #fx.stocks == 0 then
					local StockExchange = getStockExchange()
					if StockExchange and StockExchange.GetCrisisStockImpacts then
						fx.stocks = StockExchange.GetCrisisStockImpacts(c)
					end
				end
				if #fx.commodities == 0 and MacroEngine.GetCommodityEffectsForCrisis then
					fx.commodities = MacroEngine.GetCommodityEffectsForCrisis(c)
				end
				if not fx.tax and MacroEngine.GetTaxEffectForCrisis then
					fx.tax = MacroEngine.GetTaxEffectForCrisis(c)
				end
				if not fx.piracy and MacroEngine.GetPiracyEffectForCrisis then
					fx.piracy = MacroEngine.GetPiracyEffectForCrisis(c)
				end
			end
		end
	end

	return fx
end

function InterCast.GetArticles(categoryFilter)
	if #articles == 0 then
		generateSeedArticles()
	end
	if Game.player and (Game.time or 0) >= nextWireAt then
		InterCast.UpdateWireToTime(Game.time)
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
	art.timestamp = art.timestamp or (Game.time or 0)
	art.date = InterCast.NormalizeDate(art.date, art.timestamp)
	art.timeStr = art.timeStr or InterCast.FormatTime(art.timestamp)
	table.insert(articles, 1, art)
	while #articles > MAX_ARTICLES do
		local removed = false
		for i = #articles, 1, -1 do
			if not flaggedArticles[articles[i].id] then
				table.remove(articles, i)
				removed = true
				break
			end
		end
		if not removed then
			table.remove(articles)
		end
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
	if Game.system and #articles > 0 then
		local sysName = Game.system.name
		local ts = Game.time or 0
		local dateStr = InterCast.FormatDate(ts)
		local localArticle = {
			id = "art_local_" .. tostring(math.floor(ts)),
			category = "MARKET",
			headline = string.format("LOCAL WIRE: COMMERCE AND TRADE DISPATCH FROM %s", string.upper(sysName)),
			system = sysName,
			systemPath = Game.system.path,
			timestamp = ts,
			date = dateStr,
			timeStr = InterCast.FormatTime(ts),
			bureau = string.format("InterCast %s Bureau", sysName),
			summary = string.format("Station authorities in %s report steady starport traffic and active bulletin board commercial contracts.", sysName),
			body = string.format("Vessels arriving in the %s system are reminded to comply with starport speed limitations within 5 km of docking bays. Starport commodity exchanges are actively quoting bulk trades across industrial, agricultural, and mineral markets.", sysName),
			urgent = false,
		}
		InterCast.AddArticle(localArticle)
		InterCast.UpdateWireToTime(ts)
	end
end

Event.Register("onGameStart", function()
	if #articles == 0 then
		generateSeedArticles()
	end
	InterCast.UpdateWireToTime(Game.time or 0)
	if not wireTimerActive then
		wireTimerActive = true
		Timer:CallEvery(300, function()
			if not Game.player then
				wireTimerActive = false
				return true
			end
			InterCast.UpdateWireToTime(Game.time or 0)
			return false
		end)
	end
end)

Event.Register("onGameEnd", function()
	wireTimerActive = false
	lastWireGenTime = 0
	nextWireAt = 0
	articles = {}
	readArticles = {}
	flaggedArticles = {}
	currentHeadlineIndex = 1
end)

Event.Register("onEnterSystem", onEnterSystem)

local function serialize()
	return {
		articles = articles,
		currentIndex = currentHeadlineIndex,
		readArticles = readArticles,
		flaggedArticles = flaggedArticles,
		lastWireGenTime = lastWireGenTime,
		nextWireAt = nextWireAt,
		wireSeqCounter = wireSeqCounter,
	}
end

local function unserialize(data)
	if data and data.articles and #data.articles > 0 then
		articles = data.articles
		for _, art in ipairs(articles) do
			art.timestamp = art.timestamp or (Game.time or 0)
			art.date = InterCast.NormalizeDate(art.date, art.timestamp)
			art.timeStr = art.timeStr or InterCast.FormatTime(art.timestamp)
		end
		currentHeadlineIndex = data.currentIndex or 1
		readArticles = data.readArticles or {}
		flaggedArticles = data.flaggedArticles or {}
		lastWireGenTime = data.lastWireGenTime or 0
		nextWireAt = data.nextWireAt or 0
		wireSeqCounter = data.wireSeqCounter or 1
	else
		generateSeedArticles()
	end
end

Serializer:Register("InterCastDB", serialize, unserialize)

return InterCast

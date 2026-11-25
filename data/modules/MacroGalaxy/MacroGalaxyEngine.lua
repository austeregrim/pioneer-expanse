-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event      = require 'Event'
local Game       = require 'Game'
local Timer      = require 'Timer'
local Format     = require 'Format'
local Serializer = require 'Serializer'
local Rand       = require 'Rand'
local InterCast  = require 'modules.InterCast.InterCast'

local MacroGalaxyEngine = {}
local macroTimerActive = false

---@class MacroCrisis
---@field id string
---@field system string
---@field category "FRONTLINE"|"HUMANITARIAN"|"MARKET"|"POLITICS"
---@field type "OUTBREAK"|"FAMINE"|"BLOCKADE"|"INSURGENCY"|"MINERAL_RUSH"|"EMBARGO"|"LABOR_STRIKE"|"PEACE_SUMMIT"
---@field severity integer 1 to 4
---@field progress number 0 to 100
---@field progressRate number progress per calendar day
---@field headline string
---@field summary string
---@field body string
---@field urgent boolean
---@field daysActive number

local activeCrises = {}
local lastSimulationTime = 0
local SECONDS_PER_DAY = 86400
local LOTTERY_CYCLE_INTERVAL = 7 * SECONDS_PER_DAY -- 7 days per draw

-- Core systems in the inhabited bubble that experience dynamic events
local REGIONAL_SYSTEMS = {
	"Sol", "Tau Ceti", "Alpha Centauri", "Barnard's Star", "Sirius",
	"Ross 128", "Lalande 21185", "Procyon", "Epsilon Eridani", "61 Cygni",
	"Groombridge 34", "Wolf 359", "Luyten 726-8", "Kapteyn's Star", "Vega",
	"Altair", "Fomalhaut", "Sigma Draconis", "Delta Pavonis", "Beta Hydri",
	"Epsilon Indi", "Gliese 581", "Ross 154", "Ross 248", "Van Maanen's Star",
	"Groombridge 1618", "HD 219134", "Lacaille 9352", "EZ Aquarii", "Struve 2398",
	"Gliese 876", "Gliese 667", "GJ 1214", "TRAPPIST-1", "Teegarden's Star"
}

local CRISIS_DEFINITIONS = {
	OUTBREAK = {
		category = "HUMANITARIAN",
		stages = {
			[1] = {
				name = "Incipient Outbreak Detected",
				headline = "HEALTH ALERT: UNIDENTIFIED RESPIRATORY STRAIN REPORTED IN %s",
				summary = "Starport medical clinics report an influx of cases presenting with severe pulmonary distress.",
				body = "Planetary health authorities in %s have issued preliminary biosafety guidelines following an elevated cluster of respiratory infections. Epidemiologists are sequencing viral cultures while starport administration stockpiles air scrubbers and broad-spectrum antibiotics.",
				urgent = false,
			},
			[2] = {
				name = "Widespread Epidemic",
				headline = "EPIDEMIC ESCALATION: QUARANTINE PROTOCOLS INITIATED IN %s",
				summary = "Starport authorities declare level 2 medical emergency as local clinics reach capacity.",
				body = "The pathogen in %s has breached initial containment. Commercial docking is restricted to essential transports, and starport directors are offering premium subsidies for bulk shipments of vaccines, synthetic blood, and medical diagnostics.",
				urgent = true,
			},
			[3] = {
				name = "Severe Biosafety Lockdown",
				headline = "CRITICAL BIO-HAZARD: SYSTEM-WIDE CONTAINMENT CORDON IMPOSED ON %s",
				summary = "Naval gunships enforce orbital quarantine; unauthorized departure will be met with lethal interdiction.",
				body = "System traffic control in %s has instituted a complete biosafety blockade. Surface colonies face critical shortages of pharmaceutical supplies. Volunteer relief pilots who break through with relief canisters are granted immediate priority clearance.",
				urgent = true,
			},
			[4] = {
				name = "Containment & Convalescence",
				headline = "OUTBREAK ARRESTED: MEDICAL TEAMS REPORT VIRAL TRANSMISSION HALTED IN %s",
				summary = "Emergency vaccine distribution successfully stems transmission rate; quarantine cordons lifted.",
				body = "Coordinated relief shipments and newly synthesized antigen batches have successfully contained the epidemic in %s. Station traffic control has rescinded orbital quarantine restrictions, and commerce is returning to normal operations.",
				urgent = false,
			},
		}
	},

	FAMINE = {
		category = "HUMANITARIAN",
		stages = {
			[1] = {
				name = "Agricultural Crop Failure",
				headline = "AGRI-CRISIS: GREENHOUSE BLIGHT WIKES OUT HYDRO-YIELDS IN %s",
				summary = "Atmospheric fungal mold destroys prime synthetic harvest domes, triggering early food rationing.",
				body = "Station agricultural monitors in %s confirm a catastrophic loss of grain and legume hydroponic cultures. Colonial authorities have begun drawing upon emergency grain silos and issued urgent tender requests for interstellar food shipments.",
				urgent = false,
			},
			[2] = {
				name = "Severe Food Shortage",
				headline = "FAMINE EMERGENCY DECLARED IN %s; BULK GRAIN AND LIVESTOCK SOUGHT",
				summary = "Starport markets run dry of essential foodstuffs; commodity exchanges quote triple baseline prices.",
				body = "Caloric rationing has failed to prevent widespread food deficits across surface and orbital settlements in %s. Independent haulers carrying synthesized protein, grain, and water are being offered massive purchase premiums at all major docking berths.",
				urgent = true,
			},
			[3] = {
				name = "Relief Mobilization",
				headline = "CONVOYS ARRIVE IN %s AS STARPORT FOOD RESERVES STABILIZE",
				summary = "Interstellar aid convoys replenish orbital granaries, mitigating starvation threat across mining outposts.",
				body = "A coordinated influx of commercial freighters has successfully alleviated the acute caloric crisis in %s. Local agricultural engineers report new bio-resistant seed cultures have been planted in scrubbed greenhouse sectors.",
				urgent = false,
			},
		}
	},

	BLOCKADE = {
		category = "FRONTLINE",
		stages = {
			[1] = {
				name = "Border Tensions Escalate",
				headline = "MILITARY MOBILIZATION: DEFENSE CONTINGENTS MASS ALONG %s BORDER",
				summary = "Naval task forces assemble at outer hyper-relays following disputed territorial claims.",
				body = "Diplomatic breakdown has triggered military posturing near the jump corridors of %s. Patrol gunships are conducting aggressive scans of inbound commercial shipping, searching for unauthorized munitions.",
				urgent = false,
			},
			[2] = {
				name = "Orbital Blockade Imposed",
				headline = "NAVAL BLOCKADE: HEAVY CRUISERS SEAL ORBITAL LANES AROUND %s",
				summary = "All non-military transit interdicted; commercial vessels ordered to clear local space immediately.",
				body = "A naval battle group has declared an exclusion perimeter around all starports in %s. Civilian freight has ground to a halt, with blockade runners risking severe laser fire to deliver high-value contraband and industrial parts.",
				urgent = true,
			},
			[3] = {
				name = "Armistice Accord",
				headline = "CEASEFIRE RATIFIED: NAVAL SQUADRONS STAND DOWN IN %s",
				summary = "Diplomatic envoys broker an interim transit treaty; orbital embargoes dismantled.",
				body = "Following intense diplomatic negotiations at the neutral relay, naval commanders in %s have agreed to withdraw strike wings to pre-crisis borders. Commercial jump routes have officially reopened.",
				urgent = false,
			},
		}
	},

	INSURGENCY = {
		category = "FRONTLINE",
		stages = {
			[1] = {
				name = "Civil Unrest & Sabotage",
				headline = "SECURITY ALERT: DOCKING BAY EXPLOSIONS BLAMED ON INSURGENTS IN %s",
				summary = "Separatist cells claim responsibility for coordinated strikes on orbital fuel conduits.",
				body = "Paramilitary factions in %s have launched an insurgent campaign targeting corporate infrastructure. Starport security has mobilized tactical units to safeguard reactor cores and customs terminals.",
				urgent = false,
			},
			[2] = {
				name = "Full Combat Zone",
				headline = "COMBAT ZONE ACTIVE: HEAVY DOGFIGHTING REPORTED IN %s ORBIT",
				summary = "Security forces and rebel gunships engage in fierce close-quarters skirmishes near orbital rings.",
				body = "Tactical sensors confirm sustained missile and plasma fire across extraction sectors in %s. Station traffic control warns unarmed haulers to steer clear of contested navigation buoys until sector defense prevails.",
				urgent = true,
			},
			[3] = {
				name = "Insurgency Quelled",
				headline = "MARTIAL PACIFICATION: REBEL STRONGHOLDS SECURED IN %s",
				summary = "Defense forces neutralize insurgent command bunkers; curfew restrictions relaxed.",
				body = "Government defense contingents have re-established complete administrative control across the %s system. Starport commercial operations have resumed under enhanced surveillance protocols.",
				urgent = false,
			},
		}
	},

	MINERAL_RUSH = {
		category = "MARKET",
		stages = {
			[1] = {
				name = "Rare Vein Discovery",
				headline = "MINERAL STRIKE: PROSPECTORS UNCOVER ULTRA-PURE PLATINUM VEINS IN %s",
				summary = "Deep space scout drones locate rich asteroid anomalies containing unmined precious metals.",
				body = "An independent exploration vessel in %s has filed assay claims on an asteroid belt fragment yielding unprecedented concentrations of heavy metals. Corporate mining cartels have begun redirecting automated extraction platforms.",
				urgent = false,
			},
			[2] = {
				name = "Mining Rush Peak",
				headline = "ASTRO-RUSH: THOUSANDS OF BELTER DREDGERS FLOOD %s ASTEROID FIELDS",
				summary = "Industrial demand surges as miners compete fiercely for prime claim stakes.",
				body = "A massive gold rush has transformed the outer belt of %s into a bustling hive of dredgers, smelting barges, and mercenary escorts. Starport refiners are purchasing raw ore at record-breaking margins.",
				urgent = false,
			},
			[3] = {
				name = "Claim Exhaustion",
				headline = "VEINS DEPLETED: HEAVY MINING RIGS BEGIN DEPARTING %s AS BOOM COOLS",
				summary = "Strip-mining operations conclude; local market prices stabilize back to galactic baselines.",
				body = "The high-yield veins in %s have been largely extracted by automated factory ships. Belter flotillas are dispersing to survey fresh sectors, leaving established refining stations in steady equilibrium.",
				urgent = false,
			},
		}
	},

	LABOR_STRIKE = {
		category = "POLITICS",
		stages = {
			[1] = {
				name = "General Labor Strike",
				headline = "WALKOUT: ORBITAL DOCKWORKERS GUILD DECLARES GENERAL STRIKE IN %s",
				summary = "Cargo gantries idle and fuel pipelines shut as labor unions protest working hazard quotas.",
				body = "Thousands of maintenance technicians and cargo handlers in %s have laid down tools following a breakdown in collective bargaining. Freighters are facing multi-day docking queues and demurrage fines.",
				urgent = false,
			},
			[2] = {
				name = "Strike Settlement",
				headline = "LABOR ACCORD: DOCKWORKERS RATIFY NEW CHARTER; %s PORT FULLY OPERATIONAL",
				summary = "Corporate directors concede hazard allowances; cargo handling resumes around the clock.",
				body = "A landmark agreement between station governance and the labor syndicate has brought the stoppage in %s to a peaceful end. Gantries are operating at maximum throughput to clear freight backlogs.",
				urgent = false,
			},
		}
	},

	SUPPLY_GLUT = {
		category = "MARKET",
		stages = {
			[1] = {
				name = "Commodity Overproduction",
				headline = "MARKET SLUMP: RUNAWAY SMELTING SURPLUS FLOODS STORAGE DEPOTS IN %s",
				summary = "Automated refining surges produce record commodity stockpiles; spot prices collapse under inventory gluts.",
				body = "A severe supply overhang has struck the industrial commodity exchanges in %s. Automated dredging fleets have oversupplied raw metals and rare ores, leaving commercial warehouses at 120%% capacity. Refiners and mining conglomerates are idling operations as ore prices crater.",
				urgent = false,
			},
			[2] = {
				name = "Production Halts & Price Plunge",
				headline = "COMMODITY CRASH: MINING CONGLOMERATES IDLE DRILL FLOTILLAS IN %s",
				summary = "Industrial cartels enact emergency output quotas as mining and refining margins turn negative.",
				body = "Ore refining facilities across %s have entered an emergency shutdown cycle. With global storage depots saturated, spot prices for titanium, platinum, and minerals have plunged 40%% below extraction costs. Corporate equities in the extraction sector face steep quarterly write-downs.",
				urgent = true,
			},
			[3] = {
				name = "Inventory Rebalance",
				headline = "MARKET EQUILIBRIUM: WAREHOUSE DRAWDOWN STABILIZES COMMODITY FLOWS IN %s",
				summary = "Interstellar freight absorbing excess mineral stock; market spot quotes return to baseline.",
				body = "A sustained drawdown by interstellar manufacturing hubs has finally cleared the severe inventory glut in %s. Spot ore prices have leveled out, and extraction cartels are tentatively re-firing automated drill dredgers.",
				urgent = false,
			},
		}
	},

	ANTITRUST_PROBE = {
		category = "POLITICS",
		stages = {
			[1] = {
				name = "Monopoly Investigation Launched",
				headline = "REGULATORY PROBE: COMMERCE TRIBUNAL INVESTIGATES CARTEL PRICE-FIXING IN %s",
				summary = "Interstellar regulatory authorities subpoena corporate communications following price-gouging complaints.",
				body = "The Pan-Galactic Trade Oversight Bureau in %s has launched a formal antitrust inquiry into dominant aerospace and industrial cartels. Whistleblower dossiers allege collusive margin inflation and predatory hyperlane freight tariffs.",
				urgent = false,
			},
			[2] = {
				name = "Punitive Sanctions & Fines",
				headline = "PUNITIVE BILLIONS: COMMERCE COURT LEVIES MASSIVE ANTITRUST FINES IN %s",
				summary = "Judicial decree orders multi-billion credit restitution and structural breakups of regional subsidiaries.",
				body = "Following an emergency evidentiary ruling, antitrust judges in %s have imposed unprecedented regulatory penalties on dominant market leaders. In addition to stiff monetary fines, court orders mandate open hyperlane access and license forfeiture, wiping out corporate operating margins.",
				urgent = true,
			},
			[3] = {
				name = "Regulatory Settlement",
				headline = "REGULATORY SETTLEMENT: ACCUSED CONGLOMERATES RATIFY REFORM ACCORD IN %s",
				summary = "Restructured compliance charters adopted; antitrust scrutiny shifts to monitor status.",
				body = "Corporate defense counsels in %s have finalized settlement terms with federal trade commissioners. Fines have been placed in escrow and compliance officers installed, bringing an end to the judicial selloff across regional exchanges.",
				urgent = false,
			},
		}
	},

	INDUSTRIAL_DISASTER = {
		category = "FRONTLINE",
		stages = {
			[1] = {
				name = "Catastrophic Facility Rupture",
				headline = "DISASTER ALERT: REFINERY CORE BREACH TRIGGERS ORBITAL LOCKDOWN IN %s",
				summary = "Severe explosion and toxic fuel venting cripple prime fuel and propulsion fabrication plants.",
				body = "An industrial catastrophe has rocked the orbital manufacturing ring in %s. A high-energy reactor coolant explosion has damaged propulsion assembly lines and caused major orbital debris hazards. Station safety directors have declared a level-1 industrial hazard perimeter.",
				urgent = true,
			},
			[2] = {
				name = "Fleet Grounding & Massive Recall",
				headline = "MASS RECALL: AVIONICS DEFECT GROUNDS COMMERCIAL STARSHIPS IN %s",
				summary = "Safety inspectors order immediate inspections after propulsion failures linked to tainted fuel and avionics.",
				body = "A galaxy-wide grounding bulletin has been issued for starship chassis manufactured with components from %s. Millions in warranty claims and forensic investigation costs have sparked emergency board meetings and plummeting stock valuations for aerospace and fuel suppliers.",
				urgent = true,
			},
			[3] = {
				name = "Restoration & Safety Certification",
				headline = "FACILITIES CLEARED: RECONSTRUCTED RING RE-CERTIFIED FOR SERVICE IN %s",
				summary = "Industrial scrubbers complete decontamination; flight authorities re-authorize commercial vessel operations.",
				body = "Rigorous recertification protocols have concluded at the damaged manufacturing berths in %s. New fail-safe containment matrices have been brought online, and aerospace supply chains are slowly returning to scheduled throughput.",
				urgent = false,
			},
		}
	},

	TARIFF_WAR = {
		category = "POLITICS",
		stages = {
			[1] = {
				name = "Trade Sanctions Imposed",
				headline = "TRADE FRICTION: RETALIATORY TARIFFS SLAPPED ON INTERSTELLAR FREIGHT IN %s",
				summary = "Escalating diplomatic disputes prompt customs borders to enact 25% import surcharges.",
				body = "Protectionist factions in %s have instituted punitive customs levies targeting foreign starship hulls, heavy machinery, and luxury avionics. Commercial haulers report gridlocked customs checkpoints and surging border tariff bills.",
				urgent = false,
			},
			[2] = {
				name = "Full Trade Embargo",
				headline = "EMBARGO CRACKDOWN: COMMERCIAL BORDERS CLOSED AS TARIFF WAR PEAKS IN %s",
				summary = "Tit-for-tat sanctions result in total commercial embargo; cross-border freight contracts cancelled.",
				body = "The escalating tariff dispute in %s has culminated in a complete commercial embargo. Billions of credits in pending export shipments have been voided, with freight carriers and luxury manufacturers taking severe balance sheet hits.",
				urgent = true,
			},
			[3] = {
				name = "Free-Trade Accords",
				headline = "TARIFF TRUCE: INTER-SYSTEM SUMMIT RATIFIES FREE-TRADE TREATY IN %s",
				summary = "Diplomats repeal punitive tariffs; customs duties normalized across interstellar lanes.",
				body = "A landmark bilateral trade pact signed in %s has dismantled all emergency border tariffs and restored reciprocal most-favored-nation trading status. Commercial shipping schedules are rapidly realigning to clear border backlogs.",
				urgent = false,
			},
		}
	},
}

local function formatCurrentDate()
	local t = Game.time or 0
	if Game.GetPartsFromDateTime then
		local second, minute, hour, day, month, year = Game.GetPartsFromDateTime(t)
		if year then
			return string.format("%04d-%02d-%02d", year, month, day)
		end
	end
	local totalDays = math.floor(t / SECONDS_PER_DAY)
	local year = 3200 + math.floor(totalDays / 365)
	local dayOfYear = (totalDays % 365) + 1
	local month = math.min(12, math.floor(dayOfYear / 30) + 1)
	local day = (dayOfYear % 30) + 1
	return string.format("%04d-%02d-%02d", year, month, day)
end

local function formatSystemText(template, sysName)
	if not template then return "" end
	if string.find(template, "%%s") then
		return (template:gsub("%%s", function() return tostring(sysName) end))
	end
	return template
end

function MacroGalaxyEngine.GetRegionalSystems()
	return REGIONAL_SYSTEMS
end

function MacroGalaxyEngine.GetCommodityEffectsForCrisis(crisis)
	if not crisis then return {} end
	local cType = crisis.type
	local sev = crisis.severity or 1
	local isRes = (sev >= 3)

	if cType == "TARIFF_WAR" then
		local tariffMult = (sev >= 2) and 1.40 or 1.25
		return {
			{
				label = "Machinery, Computers, Robotics, Consumer Goods, Plastics",
				patterns = { "MACHINERY", "COMPUTER", "ROBOT", "CONSUMER", "PLASTIC" },
				buyMult = tariffMult,
				sellMult = 1.0 / tariffMult,
				note = string.format("CUSTOMS TARIFF: +%.0f%% Import Buy Surcharge / -%.0f%% Sell Margin", (tariffMult - 1.0) * 100, (1.0 - 1.0 / tariffMult) * 100),
			}
		}
	elseif cType == "BLOCKADE" then
		local mult = (sev >= 2) and 2.10 or 1.65
		return {
			{
				label = "Weapons, Medicines, Grain, Meat, Air Processors, Fuel",
				patterns = { "WEAPON", "MEDICINE", "GRAIN", "MEAT", "AIR", "FUEL" },
				buyMult = mult,
				sellMult = mult,
				note = string.format("BLOCKADE SHORTAGE: +%.0f%% Runner Relief Premium", (mult - 1.0) * 100),
			}
		}
	elseif cType == "SUPPLY_GLUT" then
		local mult = isRes and 0.85 or 0.45
		return {
			{
				label = "Ores, Metals, Metal Alloys, Minerals",
				patterns = { "ORE", "METAL", "ALLOY", "MINERAL" },
				buyMult = mult,
				sellMult = mult,
				note = isRes and "INVENTORY REBALANCE: -15% Residual Overhang" or "SUPPLY OVERHANG: -55% Smelting Glut Spot Crash",
			}
		}
	elseif cType == "OUTBREAK" then
		local mult = isRes and 0.80 or (1.80 + sev * 0.40)
		return {
			{
				label = "Medicines, Air Processors, Water",
				patterns = { "MEDICINE", "AIR", "WATER" },
				buyMult = mult,
				sellMult = mult,
				note = isRes and "POST-EPIDEMIC COOLING: -20% Medical Stockpile Surfeit" or string.format("OUTBREAK EPIDEMIC: +%.0f%% Vaccine & Medical Premium", (mult - 1.0) * 100),
			}
		}
	elseif cType == "FAMINE" then
		local mult = isRes and 0.85 or (1.80 + sev * 0.40)
		return {
			{
				label = "Grain, Animal Meat, Fruit & Veg, Fertilizer, Live Animals",
				patterns = { "GRAIN", "MEAT", "FRUIT", "FERTILIZER", "ANIMAL" },
				buyMult = mult,
				sellMult = mult,
				note = isRes and "RELIEF STABILIZING: -15% Grain Reserve Normalization" or string.format("FAMINE RELIEF: +%.0f%% Emergency Caloric Subsidy", (mult - 1.0) * 100),
			}
		}
	elseif cType == "MINERAL_RUSH" then
		local mult = isRes and 0.70 or (1.50 + sev * 0.30)
		return {
			{
				label = "Mining Machinery, Precious Metals",
				patterns = { "MINING_MACHINERY", "PRECIOUS_METALS" },
				buyMult = mult,
				sellMult = mult,
				note = isRes and "VEINS DEPLETED: -30% Speculation Retraction" or string.format("MINERAL RUSH: +%.0f%% Extraction Speculation Surge", (mult - 1.0) * 100),
			}
		}
	elseif cType == "LABOR_STRIKE" then
		return {
			{
				label = "Industrial Machinery, Consumer Goods, Metal Alloys",
				patterns = { "INDUSTRIAL_MACHINERY", "CONSUMER", "ALLOY" },
				buyMult = 1.18,
				sellMult = 1.18,
				note = "DOCKWORKERS STRIKE: +18% Port Throughput Bottleneck",
			}
		}
	elseif cType == "INDUSTRIAL_DISASTER" then
		return {
			{
				label = "Hydrogen, Liquid Oxygen, Industrial Machinery",
				patterns = { "HYDROGEN", "OXYGEN", "INDUSTRIAL_MACHINERY" },
				buyMult = isRes and 1.10 or 1.45,
				sellMult = isRes and 1.10 or 1.45,
				note = isRes and "RECERTIFICATION RECOVERY: +10% Supply Tightness" or "REFINERY CORE BREACH: +45% Propellant & Parts Shortage",
			}
		}
	end
	return {}
end

function MacroGalaxyEngine.GetCommodityMultiplier(systemName, commodityName, isBuy)
	if not systemName or not commodityName then return 1.0, nil end
	local crisis = MacroGalaxyEngine.GetCrisisForSystem(systemName)
	if not crisis then return 1.0, nil end
	local cName = string.upper(commodityName)
	local effects = MacroGalaxyEngine.GetCommodityEffectsForCrisis(crisis)
	for _, eff in ipairs(effects) do
		for _, pat in ipairs(eff.patterns or {}) do
			if cName:find(pat, 1, true) then
				return (isBuy and eff.buyMult or eff.sellMult) or 1.0, eff.note
			end
		end
	end
	return 1.0, nil
end

function MacroGalaxyEngine.GetTaxEffectForCrisis(crisis)
	if not crisis then return nil end
	if crisis.type == "TARIFF_WAR" then
		return { rateDeltaPct = 10.0, note = "Retaliatory Import Customs Surcharge (+10.0% system tax)" }
	elseif crisis.type == "BLOCKADE" then
		return { rateDeltaPct = 5.0, note = "Emergency Naval Blockade Defense Levy (+5.0% system tax)" }
	elseif crisis.type == "SUPPLY_GLUT" then
		return { rateDeltaPct = -2.0, note = "Emergency Trade Stimulus Tax Rebate (-2.0% system tax)" }
	end
	return nil
end

function MacroGalaxyEngine.GetPiracyEffectForCrisis(crisis)
	if not crisis then return nil end
	if crisis.type == "INSURGENCY" then
		return { threatDeltaPct = 6.0, note = "Insurgent Raiding Activity (+6% effective lawlessness / interdiction risk)" }
	elseif crisis.type == "BLOCKADE" then
		return { threatDeltaPct = 6.0, note = "Contested Exclusion Zone (+6% interdiction & hostile patrol risk)" }
	end
	return nil
end

local function buildCrisisArticleEffects(crisis)
	if not crisis then return nil end
	local stocks = {}
	local okStock, StockExchange = pcall(require, 'modules.Economy.StockExchange')
	if okStock and StockExchange and StockExchange.GetCrisisStockImpacts then
		stocks = StockExchange.GetCrisisStockImpacts(crisis)
	end
	return {
		source = "MacroGalaxy Crisis Engine",
		crisis = {
			id = crisis.id,
			system = crisis.system,
			type = crisis.type,
			severity = crisis.severity,
			progress = crisis.progress,
			progressRate = crisis.progressRate,
		},
		stocks = stocks,
		commodities = MacroGalaxyEngine.GetCommodityEffectsForCrisis(crisis),
		tax = MacroGalaxyEngine.GetTaxEffectForCrisis(crisis),
		piracy = MacroGalaxyEngine.GetPiracyEffectForCrisis(crisis),
	}
end

local function seedEmergentCrisis(preferredSystem)
	local usedSystems = {}
	for _, c in ipairs(activeCrises) do
		usedSystems[c.system] = true
	end

	local eligible = {}
	for _, sys in ipairs(REGIONAL_SYSTEMS) do
		if not usedSystems[sys] then
			table.insert(eligible, sys)
		end
	end

	if #eligible == 0 then return nil end

	local seed = math.floor(Game.time or 98765) + #activeCrises
	local rand = Rand.New(seed)
	local targetSys = preferredSystem or eligible[rand:Integer(1, #eligible)]

	local typeKeys = {
		"OUTBREAK", "FAMINE", "BLOCKADE", "INSURGENCY", "MINERAL_RUSH", "LABOR_STRIKE",
		"SUPPLY_GLUT", "ANTITRUST_PROBE", "INDUSTRIAL_DISASTER", "TARIFF_WAR"
	}
	local chosenType = typeKeys[rand:Integer(1, #typeKeys)]
	local def = CRISIS_DEFINITIONS[chosenType]
	if not def then return nil end

	local stage1 = def.stages[1]
	local dateStr = formatCurrentDate()

	local crisis = {
		id = "crisis_" .. tostring(math.floor(Game.time or 0)) .. "_" .. targetSys,
		system = targetSys,
		category = def.category,
		type = chosenType,
		severity = 1,
		progress = 0.0,
		progressRate = rand:Number(6.0, 14.0), -- 6% to 14% per day
		headline = formatSystemText(stage1.headline, string.upper(targetSys)),
		summary = formatSystemText(stage1.summary, targetSys),
		body = formatSystemText(stage1.body, targetSys),
		urgent = stage1.urgent or false,
		daysActive = 0,
	}

	table.insert(activeCrises, crisis)

	-- Publish launch article in InterCast
	InterCast.AddArticle({
		id = "art_" .. crisis.id,
		category = crisis.category,
		headline = crisis.headline,
		system = crisis.system,
		date = dateStr,
		bureau = string.format("InterCast %s Bureau", crisis.system),
		summary = crisis.summary,
		body = crisis.body,
		urgent = crisis.urgent,
		effects = buildCrisisArticleEffects(crisis),
	})

	return crisis
end

function MacroGalaxyEngine.GetActiveCrises()
	return activeCrises
end

function MacroGalaxyEngine.GetCrisisForSystem(sysName)
	if not sysName then return nil end
	local lower = string.lower(sysName)
	for _, c in ipairs(activeCrises) do
		if string.lower(c.system) == lower then
			return c
		end
	end
	return nil
end

function MacroGalaxyEngine.AdvanceMacroTick(deltaDays)
	if deltaDays <= 0 then return end

	local dateStr = formatCurrentDate()
	local toRemove = {}

	for idx, crisis in ipairs(activeCrises) do
		crisis.daysActive = (crisis.daysActive or 0) + deltaDays
		crisis.progress = crisis.progress + (crisis.progressRate * deltaDays)

		local def = CRISIS_DEFINITIONS[crisis.type]
		if def and def.stages then
			local numStages = #def.stages
			local stageProgressThreshold = 100.0 / numStages
			local expectedStage = math.min(numStages, math.floor(crisis.progress / stageProgressThreshold) + 1)

			if expectedStage > crisis.severity and expectedStage <= numStages then
				crisis.severity = expectedStage
				local nextStage = def.stages[crisis.severity]
				if nextStage then
					crisis.headline = formatSystemText(nextStage.headline, string.upper(crisis.system))
					crisis.summary = formatSystemText(nextStage.summary, crisis.system)
					crisis.body = formatSystemText(nextStage.body, crisis.system)
					crisis.urgent = nextStage.urgent or false

					-- Emit InterCast update bulletin
					InterCast.AddArticle({
						id = "art_" .. crisis.id .. "_st" .. tostring(crisis.severity),
						category = crisis.category,
						headline = crisis.headline,
						system = crisis.system,
						date = dateStr,
						bureau = string.format("InterCast %s Bureau", crisis.system),
						summary = crisis.summary,
						body = crisis.body,
						urgent = crisis.urgent,
						effects = buildCrisisArticleEffects(crisis),
					})
				end
			end

			-- Crisis has reached 100% completion
			if crisis.progress >= 100.0 then
				table.insert(toRemove, idx)
			end
		end
	end

	-- Remove completed crises in reverse
	for i = #toRemove, 1, -1 do
		table.remove(activeCrises, toRemove[i])
	end

	-- Maintain 12 to 18 active crises across the galaxy
	while #activeCrises < 14 do
		local newC = seedEmergentCrisis()
		if not newC then break end
	end

	-- Inform Economy & Stock Market of the macro tick
	local okStock, StockExchange = pcall(require, 'modules.Economy.StockExchange')
	if okStock and StockExchange and StockExchange.OnMacroTick then
		StockExchange.OnMacroTick(deltaDays, activeCrises)
	end

	-- Inform Nav-Locus 3D Lottery of the macro tick
	local okLotto, NavLocusLottery = pcall(require, 'modules.Economy.NavLocusLottery')
	if okLotto and NavLocusLottery and NavLocusLottery.OnMacroTick then
		NavLocusLottery.OnMacroTick(Game.time or 0)
	end
end

-- "Player as Catalyst": Player actions (delivering supplies or destroying hostile ships) boost resolution
function MacroGalaxyEngine.ContributeToCrisis(systemName, amount)
	local crisis = MacroGalaxyEngine.GetCrisisForSystem(systemName)
	if crisis then
		crisis.progress = crisis.progress + (amount or 20.0)
		return true
	end
	return false
end

local function checkMacroSimulation(forceAnyElapsed)
	local curTime = Game.time or 0
	if #activeCrises == 0 then
		while #activeCrises < 14 do
			if not seedEmergentCrisis() then break end
		end
	end
	if lastSimulationTime <= 0 or curTime < lastSimulationTime then
		lastSimulationTime = curTime
		return
	end

	local elapsedSeconds = curTime - lastSimulationTime
	local minInterval = forceAnyElapsed and 1 or 3600
	if elapsedSeconds >= minInterval then
		lastSimulationTime = curTime
		MacroGalaxyEngine.AdvanceMacroTick(elapsedSeconds / SECONDS_PER_DAY)
	end
end

local function onEnterSystem()
	checkMacroSimulation(true)
end

Event.Register("onGameStart", function()
	if lastSimulationTime == 0 then
		lastSimulationTime = Game.time or 0
	end
	if #activeCrises == 0 then
		while #activeCrises < 14 do
			if not seedEmergentCrisis() then break end
		end
	end
	if not macroTimerActive then
		macroTimerActive = true
		Timer:CallEvery(300, function()
			if not Game.player then return false end
			checkMacroSimulation(false)
			return false
		end)
	end
end)

Event.Register("onEnterSystem", onEnterSystem)

Event.Register("onGameEnd", function()
	macroTimerActive = false
	activeCrises = {}
	lastSimulationTime = 0
end)

local function serialize()
	return {
		activeCrises = activeCrises,
		lastSimulationTime = lastSimulationTime,
	}
end

local function unserialize(data)
	if data and data.activeCrises then
		activeCrises = data.activeCrises
		lastSimulationTime = data.lastSimulationTime or (Game.time or 0)
	else
		activeCrises = {}
		lastSimulationTime = Game.time or 0
		while #activeCrises < 14 do
			seedEmergentCrisis()
		end
	end
end

Serializer:Register("MacroGalaxyEngine", serialize, unserialize)

return MacroGalaxyEngine


-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Economy = require 'Economy'
local Game    = require 'Game'
local Rand    = require 'Rand'

local StationProfiles = {}

StationProfiles.PURPOSES = {
	PENAL        = "PENAL",
	MILITARY     = "MILITARY",
	INDUSTRIAL   = "INDUSTRIAL",
	FUEL_DEPOT   = "FUEL_DEPOT",
	SCIENCE      = "SCIENCE",
	AGRICULTURAL = "AGRICULTURAL",
	FRONTIER     = "FRONTIER",
	COMMERCIAL   = "COMMERCIAL",
}

local PURPOSE_META = {
	PENAL = {
		label = "Correctional Facility",
		shortLabel = "CORRECTIONAL",
		minTechLevel = 4,
		equipFocus = "High-security detention complex; civilian shipyards and outfitting are suspended.",
		priceHint = "Restricted",
	},
	MILITARY = {
		label = "Military & Security Dock",
		shortLabel = "MILITARY / SEC",
		minTechLevel = 8,
		equipFocus = "Weapons, shields, ECM, tactical scanners, naval thrusters, and military drives.",
		priceHint = "Tactical surplus",
	},
	INDUSTRIAL = {
		label = "Industrial & Mining Hub",
		shortLabel = "INDUSTRIAL / MINING",
		minTechLevel = 5,
		equipFocus = "Mining lasers, cargo racks, cargo scoops, reinforced hulls, and heavy drives.",
		priceHint = "Discounted industrial & mining gear",
	},
	FUEL_DEPOT = {
		label = "Gas Siphon & Propellant Depot",
		shortLabel = "FUEL / SIPHON",
		minTechLevel = 4,
		equipFocus = "Fuel scoops, atmospheric shielding, upgraded hyperdrives, and long-range avionics.",
		priceHint = "Discounted scoops & atmo shielding",
	},
	SCIENCE = {
		label = "Research & Survey Observatory",
		shortLabel = "SCIENCE / SURVEY",
		minTechLevel = 7,
		equipFocus = "Planetary/orbit scanners, discovery arrays, upgraded hyperdrives, beam lasers, and boosters.",
		priceHint = "Discounted scanners & high-tech avionics",
	},
	AGRICULTURAL = {
		label = "Agricultural & Habitat Platform",
		shortLabel = "AGRICULTURAL",
		minTechLevel = 4,
		equipFocus = "Cargo bay life support, passenger cabins, auxiliary cargo holds, and trade computers.",
		priceHint = "Discounted cabins & life support",
	},
	FRONTIER = {
		label = "Frontier & Freeport Outpost",
		shortLabel = "FRONTIER",
		minTechLevel = 3,
		equipFocus = "Concealed cargo holds, FSD interdictors, nullifiers, fuel scoops, and light armaments.",
		priceHint = "Black-market / frontier markups",
	},
	COMMERCIAL = {
		label = "Commercial Trade Starport",
		shortLabel = "COMMERCIAL HUB",
		minTechLevel = 4,
		equipFocus = "Broad civilian outfitting: cargo racks, passenger cabins, hyperdrives, shields, and defense gear.",
		priceHint = "Standard market rates",
	},
}

local INDUSTRY_ROLES = {
	military_industry     = "military",
	mil_refinery          = "military",
	ore_mine              = "industrial",
	carbon_mine           = "industrial",
	ice_mine              = "industrial",
	ore_refinery          = "industrial",
	telluric_ore_refinery = "industrial",
	heavy_industry        = "industrial",
	plastics_refinery     = "industrial",
	chemical_refinery     = "industrial",
	recycling             = "industrial",
	gas_giant_extraction  = "fuel",
	orbital_gas_refining  = "fuel",
	circuit_fabrication   = "science",
	orbital_assembly      = "science",
	pharmaceutical_complex = "science",
	orbital_lab           = "science",
	drug_lab              = "science",
	station_aquaponics    = "agri",
	surface_aquaponics    = "agri",
	outdoor_farm          = "agri",
	civil_industry        = "commercial",
	consumer_industry     = "commercial",
	textile_mill          = "commercial",
	distillery            = "commercial",
}

local CORE_BASELINE_IDS = {
	["thruster.default_s1"]          = true,
	["thruster.default_s2"]          = true,
	["thruster.default_s3"]          = true,
	["thruster.default_s4"]          = true,
	["thruster.default_s5"]          = true,
	["hyperspace.hyperdrive_1"]      = true,
	["hyperspace.hyperdrive_2"]      = true,
	["hyperspace.hyperdrive_3"]      = true,
	["misc.autopilot"]               = true,
	["sensor.radar"]                 = true,
	["sensor.discovery_scanner"]     = true,
	["misc.cabin_s1"]                = true,
	["misc.cabin_s2"]                = true,
	["misc.cabin_s3"]                = true,
	["misc.cabin_hold_s1"]           = true,
	["misc.cabin_hold_s2"]           = true,
	["misc.cabin_hold_s3"]           = true,
	["hull.atmospheric_shielding_s0"] = true,
	["hull.atmospheric_shielding_s1"] = true,
	["hull.atmospheric_shielding_s2"] = true,
	["shield.basic_s1"]              = true,
	["laser.pulsecannon_1mw"]        = true,
	["missile.unguided_s1"]          = true,
	["missile_rack.111"]             = true,
	["missile_bay.opli_internal_s2"] = true,
	["missile_bay.bowfin_internal"]  = true,
}

local function safeField(obj, key)
	if not obj then return nil end
	local ok, val = pcall(function() return obj[key] end)
	if ok then return val end
	return nil
end

function StationProfiles.GetSystemBody(stationOrSbody)
	if not stationOrSbody then return nil end

	local okGet, sbody = pcall(function()
		if stationOrSbody.GetSystemBody then
			return stationOrSbody:GetSystemBody()
		end
		return nil
	end)
	if okGet and sbody then
		return sbody
	end

	local superType = safeField(stationOrSbody, "superType")
	if superType ~= nil then
		return stationOrSbody
	end

	local okPath, pathSbody = pcall(function()
		if stationOrSbody.path and stationOrSbody.path.GetSystemBody then
			return stationOrSbody.path:GetSystemBody()
		end
		return nil
	end)
	if okPath and pathSbody then
		return pathSbody
	end

	return nil
end

local function getSystemForBody(sbody)
	if not sbody then return Game.system end
	local sys = safeField(sbody, "system")
	if sys then return sys end

	local okPath, pathSys = pcall(function()
		if sbody.path and sbody.path.GetStarSystem then
			return sbody.path:GetStarSystem()
		end
		return nil
	end)
	if okPath and pathSys then return pathSys end

	return Game.system
end

function StationProfiles.Classify(stationOrSbody)
	local sbody = StationProfiles.GetSystemBody(stationOrSbody)
	local label = ""
	if type(stationOrSbody) == "table" or type(stationOrSbody) == "userdata" then
		label = safeField(stationOrSbody, "label") or ""
	end
	if label == "" and sbody then
		label = safeField(sbody, "name") or ""
	end

	local stType = (sbody and safeField(sbody, "spaceStationType")) or ""
	local parent = sbody and safeField(sbody, "parent")
	local parentType = (parent and safeField(parent, "type")) or ""
	local hasRings = (parent and safeField(parent, "hasRings")) or false
	local sys = getSystemForBody(sbody)
	local lawlessness = (sys and safeField(sys, "lawlessness")) or 0
	local faction = sys and safeField(sys, "faction")
	local factionName = faction and safeField(faction, "name") or nil
	local stationType = (sbody and safeField(sbody, "type")) or safeField(stationOrSbody, "type") or ""
	local pop = ((sbody and safeField(sbody, "population")) or 0) + ((parent and safeField(parent, "population")) or 0)

	local scores = {
		military = 0,
		industrial = 0,
		fuel = 0,
		science = 0,
		agri = 0,
		commercial = 0,
	}
	local econTags = {}
	if sbody and safeField(sbody, "superType") == "STARPORT" then
		local okEcon, econ = pcall(Economy.GetStationEconomy, sbody)
		if okEcon and econ then
			econTags = econ.tags or {}
			for _, indId in ipairs(econ.industries or {}) do
				local role = INDUSTRY_ROLES[indId]
				if role and scores[role] ~= nil then
					scores[role] = scores[role] + 1
				end
			end
		end
	end

	local lowerLabel = string.lower(label)
	local isStrictMilitary = lowerLabel:find("military") ~= nil
		or lowerLabel:find("naval") ~= nil
		or stType:find("police") ~= nil
		or lowerLabel:find("police") ~= nil
		or lowerLabel:find("constabulary") ~= nil
		or lowerLabel:find("enforcement") ~= nil
		or lowerLabel:find("garrison") ~= nil
		or lowerLabel:find("fortress") ~= nil
		or lowerLabel:match("^fort%s") ~= nil
		or lowerLabel:find("security") ~= nil

	local isPenal = (stType == "orbital_station_penal")
		or lowerLabel:find("prison") ~= nil
		or lowerLabel:find("penal") ~= nil
		or lowerLabel:find("correctional") ~= nil
		or lowerLabel:find("penitentiary") ~= nil
		or lowerLabel:find("detention") ~= nil

	local isSiphon = (stType == "orbital_station_siphon")
		or (parentType == "PLANET_GAS_GIANT" and stType ~= "orbital_station_industrial" and stType ~= "orbital_station_science")
		or lowerLabel:find("siphon") ~= nil
		or lowerLabel:find("fuel depot") ~= nil
		or lowerLabel:find("propellant") ~= nil
		or lowerLabel:find("gas processing") ~= nil
		or lowerLabel:find("energy station") ~= nil

	local isIndustrial = (stType == "orbital_station_industrial")
		or (parentType == "PLANET_ASTEROID")
		or (hasRings and stType ~= "orbital_station_siphon" and stType ~= "orbital_station_science" and stType ~= "orbital_station_agri")
		or lowerLabel:find("smelting") ~= nil
		or lowerLabel:find("refinery") ~= nil
		or lowerLabel:find("foundry") ~= nil
		or lowerLabel:find("extraction") ~= nil
		or lowerLabel:find("drilling") ~= nil
		or lowerLabel:find("industrial") ~= nil
		or lowerLabel:find("ore terminal") ~= nil
		or lowerLabel:find("processing") ~= nil
		or lowerLabel:match("%smine$") ~= nil

	local isScience = (stType == "orbital_station_science")
		or lowerLabel:find("research") ~= nil
		or lowerLabel:find("observatory") ~= nil
		or lowerLabel:find("science") ~= nil
		or lowerLabel:find("bio%-labs") ~= nil
		or lowerLabel:find("laboratories") ~= nil
		or lowerLabel:find("development center") ~= nil

	local isAgri = (stType == "orbital_station_agri")
		or lowerLabel:find("hydroponics") ~= nil
		or lowerLabel:find("agri") ~= nil
		or lowerLabel:find("biosphere") ~= nil
		or lowerLabel:find("aquaponics") ~= nil
		or lowerLabel:find("cultivation") ~= nil
		or lowerLabel:find("orbital farm") ~= nil
		or lowerLabel:find("habitat ring") ~= nil

	local purpose = StationProfiles.PURPOSES.COMMERCIAL
	local minTechLevel = (stType == "orbital_station_2-10k" or stType == "orbital_station_2-5k10k") and 6 or 4

	if isPenal then
		purpose = StationProfiles.PURPOSES.PENAL
		minTechLevel = PURPOSE_META.PENAL.minTechLevel
	elseif isStrictMilitary or (scores.military >= 2 and lawlessness < 0.5) then
		purpose = StationProfiles.PURPOSES.MILITARY
		if lowerLabel:find("military") or lowerLabel:find("naval") or scores.military >= 2 then
			minTechLevel = 11
		else
			minTechLevel = 8
		end
	elseif isSiphon then
		purpose = StationProfiles.PURPOSES.FUEL_DEPOT
		minTechLevel = PURPOSE_META.FUEL_DEPOT.minTechLevel
	elseif isIndustrial then
		purpose = StationProfiles.PURPOSES.INDUSTRIAL
		minTechLevel = PURPOSE_META.INDUSTRIAL.minTechLevel
	elseif isScience then
		purpose = StationProfiles.PURPOSES.SCIENCE
		minTechLevel = PURPOSE_META.SCIENCE.minTechLevel
	elseif isAgri then
		purpose = StationProfiles.PURPOSES.AGRICULTURAL
		minTechLevel = PURPOSE_META.AGRICULTURAL.minTechLevel
	elseif scores.science >= 2 and scores.science >= scores.industrial and scores.science >= scores.agri then
		purpose = StationProfiles.PURPOSES.SCIENCE
		minTechLevel = PURPOSE_META.SCIENCE.minTechLevel
	elseif scores.industrial >= 2 and scores.industrial >= scores.agri then
		purpose = StationProfiles.PURPOSES.INDUSTRIAL
		minTechLevel = PURPOSE_META.INDUSTRIAL.minTechLevel
	elseif scores.agri >= 1 and scores.agri >= scores.industrial and scores.agri >= scores.science and pop < 2.0 then
		purpose = StationProfiles.PURPOSES.AGRICULTURAL
		minTechLevel = PURPOSE_META.AGRICULTURAL.minTechLevel
	elseif lawlessness >= 0.45 then
		purpose = StationProfiles.PURPOSES.FRONTIER
		minTechLevel = PURPOSE_META.FRONTIER.minTechLevel
	elseif scores.military >= 1 and sbody then
		local milRand = Rand.New(tostring(safeField(sbody, "seed") or 0) .. "-mil")
		if milRand:Number() < 0.25 then
			purpose = StationProfiles.PURPOSES.MILITARY
			minTechLevel = 11
		end
	end

	local secondary = {}
	if lawlessness >= 0.40 then secondary.FRONTIER = true end
	if scores.military >= 1 or isStrictMilitary then secondary.MILITARY = true end
	if scores.industrial >= 1 or isIndustrial then secondary.INDUSTRIAL = true end
	if scores.science >= 1 or isScience or econTags.tech_high then secondary.SCIENCE = true end
	if scores.fuel >= 1 or isSiphon then secondary.FUEL_DEPOT = true end
	if scores.agri >= 1 or isAgri then secondary.AGRICULTURAL = true end

	local meta = PURPOSE_META[purpose] or PURPOSE_META.COMMERCIAL

	return {
		purpose = purpose,
		secondary = secondary,
		label = meta.label,
		shortLabel = meta.shortLabel,
		minTechLevel = minTechLevel,
		equipFocus = meta.equipFocus,
		priceHint = meta.priceHint,
		stationType = stationType,
		spaceStationType = stType,
		lawlessness = lawlessness,
		factionName = factionName,
		population = pop,
		sbody = sbody,
	}
end

function StationProfiles.GetMinTechLevel(systemBody)
	local profile = StationProfiles.Classify(systemBody)
	return profile.minTechLevel or 4
end

function StationProfiles.CategorizeEquipment(equip)
	local id = (equip and equip.id) or ""
	local slotType = (equip and equip.slot and equip.slot.type) or ""

	local mining = slotType:match("^weapon%.mining") ~= nil
	local heavyWeapon = slotType:match("^weapon%.energy%.plasma_acc") ~= nil
		or id == "laser.pulsecannon_20mw"
		or id == "laser.pulsecannon_10mw"
	local combatWeapon = (slotType:match("^weapon") ~= nil) and not mining
	local missile = (slotType:match("^missile") ~= nil) or (slotType:match("^pylon") ~= nil)
	local ecm = slotType:match("^utility%.ecm") ~= nil
	local combatScanner = slotType:match("^utility%.scanner%.combat_scanner") ~= nil
		or slotType:match("^utility%.scanner%.hypercloud") ~= nil
	local surveyScanner = slotType:match("^sensor%.discovery_scanner") ~= nil
		or slotType:match("^utility%.scanner%.planet") ~= nil
	local scanner = (slotType:match("^sensor") ~= nil) or (slotType:match("^utility%.scanner") ~= nil)
	local interdiction = slotType:match("^computer%.interdictor") ~= nil
		or slotType:match("^computer%.countermeasure") ~= nil
	local computer = (slotType:match("^computer") ~= nil) and not interdiction
	local fuelScoop = slotType:match("^fuel_scoop") ~= nil
	local cargoScoop = (id == "misc.cargo_scoop")
	local smuggler = id:find("smuggler", 1, true) ~= nil
	local cargo = (id:find("cabin_hold", 1, true) ~= nil) or cargoScoop
	local cabin = (slotType:match("^cabin") ~= nil) and (id:find("cabin_hold", 1, true) == nil) and not smuggler
	local atmoShield = slotType:match("^hull%.atmo_shield") ~= nil
	local autorepair = slotType:match("^hull%.autorepair") ~= nil
	local structure = slotType:match("^structure") ~= nil
	local shield = slotType:match("^shield") ~= nil
	local thrusterNaval = id:match("^thruster%.naval") ~= nil
	local thrusterPerf = (id:match("^thruster%.improved") ~= nil) or (id:match("^thruster%.optimised") ~= nil)
	local thruster = slotType:match("^thruster") ~= nil
	local hyperdriveMil = slotType:match("^hyperdrive%.military") ~= nil
	local hyperdriveUpgraded = (slotType:match("^hyperdrive%.civilian") ~= nil) and (id:match("_[abc]$") ~= nil)
	local hyperdriveCiv = (slotType:match("^hyperdrive%.civilian") ~= nil) and not hyperdriveUpgraded
	local lifeSupport = (id == "misc.cargo_life_support")
	local booster = (id == "misc.laser_cooling_booster") or (id == "misc.shield_energy_booster")

	return {
		mining = mining,
		heavyWeapon = heavyWeapon,
		combatWeapon = combatWeapon,
		missile = missile,
		ecm = ecm,
		combatScanner = combatScanner,
		surveyScanner = surveyScanner,
		scanner = scanner,
		interdiction = interdiction,
		computer = computer,
		fuelScoop = fuelScoop,
		cargoScoop = cargoScoop,
		smuggler = smuggler,
		cargo = cargo,
		cabin = cabin,
		atmoShield = atmoShield,
		autorepair = autorepair,
		structure = structure,
		shield = shield,
		thruster = thruster,
		thrusterPerf = thrusterPerf,
		thrusterNaval = thrusterNaval,
		hyperdriveMil = hyperdriveMil,
		hyperdriveUpgraded = hyperdriveUpgraded,
		hyperdriveCiv = hyperdriveCiv,
		lifeSupport = lifeSupport,
		booster = booster,
	}
end

local function isSpecialtyForPurpose(purpose, secondary, tags, equip)
	local id = equip.id or ""
	local slotSize = (equip.slot and equip.slot.size) or 1

	if purpose == StationProfiles.PURPOSES.INDUSTRIAL then
		return tags.mining or tags.cargo or tags.structure or tags.atmoShield or tags.thrusterPerf
			or (tags.fuelScoop and slotSize <= 3) or tags.hyperdriveCiv
	elseif purpose == StationProfiles.PURPOSES.FUEL_DEPOT then
		return tags.fuelScoop or tags.atmoShield or tags.hyperdriveCiv or tags.hyperdriveUpgraded
			or tags.cargoScoop or tags.thruster or id == "misc.autopilot_mk2"
	elseif purpose == StationProfiles.PURPOSES.SCIENCE then
		return tags.surveyScanner or tags.scanner or tags.computer or tags.hyperdriveUpgraded
			or id:match("^laser%.beamlaser") ~= nil or tags.booster or tags.shield
			or id:match("^thruster%.optimised") ~= nil or id == "misc.subsystem_targeting_computer"
	elseif purpose == StationProfiles.PURPOSES.AGRICULTURAL then
		return tags.lifeSupport or tags.cabin or tags.cargo or tags.atmoShield
			or id == "misc.trade_computer" or id == "misc.autopilot_mk2" or tags.hyperdriveCiv
	elseif purpose == StationProfiles.PURPOSES.MILITARY then
		return tags.combatWeapon or tags.heavyWeapon or tags.missile or tags.ecm
			or tags.interdiction or tags.combatScanner or tags.shield or tags.autorepair
			or tags.thrusterNaval or tags.hyperdriveMil or id == "misc.subsystem_targeting_computer"
	elseif purpose == StationProfiles.PURPOSES.FRONTIER then
		return tags.smuggler or tags.interdiction or id == "misc.ecm_basic"
			or (tags.combatWeapon and not tags.heavyWeapon) or tags.missile
			or tags.fuelScoop or tags.cargoScoop or id == "misc.subsystem_targeting_computer"
	elseif purpose == StationProfiles.PURPOSES.COMMERCIAL then
		return tags.cargo or tags.cabin or tags.hyperdriveCiv
			or (tags.hyperdriveUpgraded and id:match("_c$") ~= nil)
			or tags.computer or (tags.shield and slotSize <= 3)
	end

	return false
end

function StationProfiles.EvaluateEquipment(station, equip, cachedProfile)
	if not equip or not equip.purchasable then
		return { allowed = false }
	end

	local profile = cachedProfile or StationProfiles.Classify(station)
	if profile.purpose == StationProfiles.PURPOSES.PENAL then
		return { allowed = false, profile = profile }
	end

	local lawlessness = profile.lawlessness or 0
	if equip.lawlessness and lawlessness < equip.lawlessness then
		return { allowed = false, profile = profile }
	end
	if equip.min_security and lawlessness >= (1 - equip.min_security) then
		return { allowed = false, profile = profile }
	end

	local stationTL = tonumber(safeField(station, "techLevel")) or profile.minTechLevel or 5
	local rawTL = equip.tech_level
	local isMilTech = (rawTL == "MILITARY")
	local equipTL = isMilTech and 11 or (tonumber(rawTL) or 1)
	local id = equip.id or ""
	local tags = StationProfiles.CategorizeEquipment(equip)
	local purpose = profile.purpose
	local secondary = profile.secondary or {}

	-- Off-purpose restrictions for agricultural & fuel stations (not armed arsenals)
	if (purpose == StationProfiles.PURPOSES.AGRICULTURAL or purpose == StationProfiles.PURPOSES.FUEL_DEPOT)
		and not secondary.MILITARY and stationTL < 11
	then
		if isMilTech or tags.heavyWeapon or id == "misc.fsd_interdictor_2" or id == "misc.fsd_interdictor_3" then
			return { allowed = false, profile = profile }
		end
	end

	-- Core universal baseline ensures every non-penal station can perform essential outfitting
	local isCore = CORE_BASELINE_IDS[id] == true
		or (id == "shield.basic_s2" and (stationTL >= 5 or purpose == "COMMERCIAL" or purpose == "INDUSTRIAL" or purpose == "MILITARY"))

	local isSpecialty = isSpecialtyForPurpose(purpose, secondary, tags, equip)
	if not isSpecialty then
		if secondary.FRONTIER and (tags.smuggler or tags.interdiction or id == "misc.ecm_basic") then
			isSpecialty = true
		elseif secondary.MILITARY and (tags.combatWeapon or tags.missile or tags.combatScanner or tags.ecm) then
			isSpecialty = true
		elseif secondary.INDUSTRIAL and (tags.mining or tags.structure or tags.cargo) then
			isSpecialty = true
		elseif secondary.SCIENCE and (tags.surveyScanner or tags.computer) then
			isSpecialty = true
		end
	end

	local tlBonus = 0
	if isSpecialty then
		tlBonus = (purpose == StationProfiles.PURPOSES.MILITARY and isMilTech) and 3 or 3
		if (purpose == StationProfiles.PURPOSES.INDUSTRIAL and tags.mining)
			or (purpose == StationProfiles.PURPOSES.FUEL_DEPOT and tags.fuelScoop)
			or (purpose == StationProfiles.PURPOSES.SCIENCE and tags.surveyScanner)
		then
			tlBonus = 4
		end
	end

	local effectiveTL = stationTL + tlBonus
	local tlDelta = effectiveTL - equipTL

	-- Military TL 11 items still require true Military/TL11 clearance unless explicitly unlocked by MILITARY purpose
	if isMilTech and stationTL < 11 and purpose ~= StationProfiles.PURPOSES.MILITARY then
		return { allowed = false, profile = profile }
	end

	local allowed = isCore or isSpecialty or (tlDelta >= 0)
	if not allowed then
		return { allowed = false, profile = profile }
	end

	-- Compute guaranteed minimum stock & specialty pricing
	local minStock = 0
	local maxStock = 45
	local priceMod = 1.0

	if isSpecialty then
		minStock = isMilTech and 2 or 4
		maxStock = isMilTech and 16 or 75
		if purpose == StationProfiles.PURPOSES.FRONTIER then
			priceMod = 1.02
		elseif purpose == StationProfiles.PURPOSES.MILITARY then
			priceMod = 0.94
		else
			priceMod = 0.90
		end
	elseif isCore then
		minStock = 3
		maxStock = 65
		priceMod = (purpose == StationProfiles.PURPOSES.FRONTIER) and 1.05 or 1.0
	else
		if tlDelta >= 3 then
			minStock = 2
			maxStock = 60
		elseif tlDelta >= 1 then
			minStock = 1
			maxStock = 40
		else
			minStock = 0
			maxStock = 25
		end
		if purpose == StationProfiles.PURPOSES.FRONTIER then
			priceMod = 1.06
		elseif purpose == StationProfiles.PURPOSES.AGRICULTURAL or purpose == StationProfiles.PURPOSES.FUEL_DEPOT then
			priceMod = 1.03
		end
	end

	-- High-population hubs stock deeper inventories
	local pop = profile.population or 0
	if pop >= 1.0 then
		minStock = minStock + 1
		maxStock = math.floor(maxStock * 1.3)
	end

	return {
		allowed = true,
		isSpecialty = isSpecialty,
		isCore = isCore,
		effectiveTL = effectiveTL,
		tlDelta = tlDelta,
		priceMod = priceMod,
		minStock = minStock,
		maxStock = maxStock,
		profile = profile,
	}
end

function StationProfiles.GetRecommendedPurposeForSlot(slot)
	if not slot then
		return "Slotless cargo, life-support, and booster gear is available at Industrial, Agricultural, and Science stations."
	end

	local st = slot.type or ""
	if st:match("^turret") or st:match("^vehicle_bay") then
		return "No compatible hardware is currently available for this mount class (reserved for future fleet & surface systems)."
	elseif st:match("^weapon%.mining") then
		return "Blast-mining cannons are stocked primarily at Industrial & Mining hubs."
	elseif st:match("^fuel_scoop") then
		return "Fuel Scoops are stocked at Gas Giant Fuel Depots, Industrial hubs, and Frontier outposts."
	elseif st:match("^hyperdrive%.military") then
		return "Military hyperdrives are restricted to Military & Tech Level 11 facilities."
	elseif st:match("^utility%.scanner") or st:match("^sensor") then
		return "Advanced planetary and hypercloud scanners are stocked at Science Observatories and High-Tech starports."
	elseif st:match("^utility%.ecm") or st:match("^computer%.interdictor") then
		return "Tactical countermeasures and interdictors are stocked at Military docks, Frontier outposts, and high-tech hubs."
	elseif st:match("^hull%.autorepair") then
		return "Hull auto-repair systems are stocked exclusively at Military (Tech Level 11) facilities."
	elseif st:match("^structure") then
		return "Reinforced hull structures are stocked at Industrial & Mining stations and major commercial shipyards."
	end

	return "This station does not currently stock equipment matching this slot size/class. Check major Commercial hubs or check the BBS Used Market."
end

return StationProfiles

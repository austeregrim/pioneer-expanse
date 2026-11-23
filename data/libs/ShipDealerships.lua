-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Engine          = require 'Engine'
local Equipment       = require 'Equipment'
local EquipSet        = require 'EquipSet'
local HullConfig      = require 'HullConfig'
local ModelSkin       = require 'SceneGraph.ModelSkin'
local Rand            = require 'Rand'
local Ship            = require 'Ship'
local ShipDef         = require 'ShipDef'
local StationProfiles = require 'StationProfiles'
local utils           = require 'utils'

local ShipDealerships = {}

ShipDealerships.Manufacturers = {
	opli = {
		id = "opli",
		name = "OPLI Orbital Yards",
		shortName = "OPLI",
		planFGroup = "Frontier Voidcraft Heritage",
		logoSvg = "corp_opli",
		iconPng = "icons/manufacturer/opli.png",
		roleKey = "opli",
		factionAffinities = {
			["Solar Federation"] = 1.6,
			["Independent"] = 2.0,
		},
		purposeAffinities = {
			COMMERCIAL = 1.7,
			FRONTIER = 2.1,
			INDUSTRIAL = 1.2,
			FUEL_DEPOT = 1.4,
		},
		dealershipNames = {
			"OPLI Certified Showroom",
			"OPLI Frontier Motorworks",
			"Omni-Product Vessel Exchange",
		},
		factoryPalettes = {
			{ { 34, 92, 168 }, { 226, 232, 240 }, { 245, 158, 11 } },
			{ { 28, 58, 95 },  { 190, 210, 230 }, { 56, 189, 248 } },
			{ { 72, 85, 99 },  { 229, 231, 235 }, { 234, 88, 12 } },
		},
	},
	kaluri = {
		id = "kaluri",
		name = "Kaluri Heavy Industries",
		shortName = "Kaluri",
		planFGroup = "Commonwealth Yard Group",
		logoSvg = "corp_kaluri",
		iconPng = "icons/manufacturer/kaluri.png",
		roleKey = "kaluri",
		factionAffinities = {
			["Commonwealth of Independent Worlds"] = 2.5,
			["Independent"] = 1.5,
		},
		purposeAffinities = {
			COMMERCIAL = 1.5,
			AGRICULTURAL = 2.2,
			INDUSTRIAL = 1.6,
			FUEL_DEPOT = 1.4,
		},
		dealershipNames = {
			"Kaluri Marine & Void Showroom",
			"Kaluri Authorized Dealership",
			"Kaluri Fleet Outfitter & Yard",
		},
		factoryPalettes = {
			{ { 22, 101, 74 }, { 235, 244, 240 }, { 16, 185, 129 } },
			{ { 30, 72, 96 },  { 214, 228, 236 }, { 52, 211, 153 } },
			{ { 55, 65, 81 },  { 209, 213, 219 }, { 34, 197, 94 } },
		},
	},
	["mandarava-csepel"] = {
		id = "mandarava-csepel",
		name = "Mandarava-Csepel Aero",
		shortName = "M-Csepel",
		planFGroup = "Sol-Dynamics Partner",
		logoSvg = "corp_mandarava",
		iconPng = "icons/manufacturer/mandarava-csepel.png",
		roleKey = "mandarava",
		factionAffinities = {
			["Solar Federation"] = 2.0,
			["Independent"] = 1.3,
		},
		purposeAffinities = {
			COMMERCIAL = 1.8,
			AGRICULTURAL = 1.5,
			MILITARY = 1.8,
		},
		dealershipNames = {
			"Mandarava-Csepel Direct",
			"M-Csepel Starport Franchise",
			"Mandarava Executive & Fleet Yard",
		},
		factoryPalettes = {
			{ { 180, 83, 9 }, { 241, 245, 249 }, { 251, 191, 36 } },
			{ { 127, 29, 29 }, { 226, 232, 240 }, { 245, 158, 11 } },
			{ { 30, 41, 59 }, { 248, 250, 252 }, { 217, 119, 6 } },
		},
	},
	albr = {
		id = "albr",
		name = "ALBR Aerospace",
		shortName = "ALBR",
		planFGroup = "Sol-Dynamics Partner",
		logoSvg = "corp_albr",
		iconPng = "icons/manufacturer/albr.png",
		roleKey = "albr",
		factionAffinities = {
			["Solar Federation"] = 2.2,
			["Commonwealth of Independent Worlds"] = 1.4,
		},
		purposeAffinities = {
			MILITARY = 2.2,
			SCIENCE = 2.0,
			COMMERCIAL = 1.3,
		},
		dealershipNames = {
			"ALBR Aerospace Showroom",
			"ALBR Tactical & Transit Yard",
			"ALBR Certified Flight Center",
		},
		factoryPalettes = {
			{ { 194, 65, 12 }, { 241, 245, 249 }, { 251, 146, 60 } },
			{ { 49, 46, 129 }, { 224, 231, 255 }, { 249, 115, 22 } },
			{ { 51, 65, 85 },  { 226, 232, 240 }, { 239, 68, 68 } },
		},
	},
	haber = {
		id = "haber",
		name = "Haber Industrial Works",
		shortName = "Haber",
		planFGroup = "Guan-Haber Heavyworks",
		logoSvg = "faction_haber",
		iconPng = "icons/manufacturer/haber.png",
		roleKey = "haber",
		factionAffinities = {
			["Haber Corporation"] = 4.0,
			["Independent"] = 1.1,
		},
		purposeAffinities = {
			INDUSTRIAL = 2.8,
			FUEL_DEPOT = 2.2,
			COMMERCIAL = 1.0,
		},
		dealershipNames = {
			"Haber Extraction & Transit Yard",
			"Haber Corporate Fleet Depot",
			"Haber Heavyworks Dealership",
		},
		factoryPalettes = {
			{ { 153, 27, 27 }, { 229, 231, 235 }, { 239, 68, 68 } },
			{ { 68, 64, 60 },  { 214, 211, 209 }, { 220, 38, 38 } },
			{ { 39, 39, 42 },  { 228, 228, 231 }, { 245, 158, 11 } },
		},
	},
	auronox = {
		id = "auronox",
		name = "Auronox Corporation",
		shortName = "Auronox",
		planFGroup = "Aethelgard Partner",
		logoSvg = "corp_auronox",
		iconPng = "icons/manufacturer/auronox.png",
		roleKey = "auronox",
		factionAffinities = {
			["Commonwealth of Independent Worlds"] = 1.8,
			["Solar Federation"] = 1.4,
		},
		purposeAffinities = {
			SCIENCE = 1.9,
			COMMERCIAL = 1.6,
			MILITARY = 1.7,
		},
		dealershipNames = {
			"Auronox Precision Showroom",
			"Auronox Select Motorworks",
			"Auronox Orbital Dealership",
		},
		factoryPalettes = {
			{ { 180, 120, 20 }, { 248, 250, 252 }, { 250, 204, 21 } },
			{ { 17, 24, 39 },   { 229, 231, 235 }, { 234, 179, 8 } },
			{ { 30, 58, 138 },  { 239, 246, 255 }, { 251, 191, 36 } },
		},
	},
}

local MANUFACTURER_ORDER = { "opli", "kaluri", "mandarava-csepel", "albr", "haber", "auronox" }

local INDEPENDENT_YARD_NAMES = {
	"Rimward Used Ship Brokers",
	"Freeport Pre-Owned Hulls & Salvage",
	"Second-Orbit Certified Vessels",
	"Frontier Fleet Liquidation Yard",
	"Independent Spacecraft Brokerage",
}

local function isPlayerShip(def)
	return def and def.tag == "SHIP" and (def.basePrice or 0) > 0
end

local function collectEligibleShips(station, mfrFilter, excludeMfr)
	local list = {}
	for _, def in pairs(ShipDef) do
		if isPlayerShip(def) then
			local cfg = HullConfig.GetHullConfig(def.id)
			if cfg and cfg.slots then
				local okMfr = (not mfrFilter or def.manufacturer == mfrFilter)
					and (not excludeMfr or def.manufacturer ~= excludeMfr)
				if okMfr then
					table.insert(list, def)
				end
			end
		end
	end
	table.sort(list, function(a, b)
		if (a.basePrice or 0) ~= (b.basePrice or 0) then
			return (a.basePrice or 0) < (b.basePrice or 0)
		end
		return (a.id or "") < (b.id or "")
	end)
	return list
end

local function makeFactorySkin(mfrId, label, rand)
	local mfr = ShipDealerships.Manufacturers[mfrId]
	local palettes = mfr and mfr.factoryPalettes
	if palettes and #palettes > 0 then
		local p = palettes[rand:Integer(1, #palettes)]
		local c1, c2, c3 = p[1], p[2], p[3]
		return ModelSkin.New()
			:SetColors({
				primary   = Color(c1[1], c1[2], c1[3], 255),
				secondary = Color(c2[1], c2[2], c2[3], 255),
				trim      = Color(c3[1], c3[2], c3[3], 255),
			})
			:SetDecal(mfrId)
			:SetLabel(label)
	end
	return ModelSkin.New():SetRandomColors(rand):SetDecal(mfrId):SetLabel(label)
end

local function pickWeightedManufacturer(profile, rand)
	local totalWeight = 0
	local weights = {}
	for _, id in ipairs(MANUFACTURER_ORDER) do
		local mfr = ShipDealerships.Manufacturers[id]
		local w = 1.0
		if profile.factionName and mfr.factionAffinities[profile.factionName] then
			w = w * mfr.factionAffinities[profile.factionName]
		end
		if profile.purpose and mfr.purposeAffinities[profile.purpose] then
			w = w * mfr.purposeAffinities[profile.purpose]
		end
		weights[#weights + 1] = { id = id, weight = w }
		totalWeight = totalWeight + w
	end

	local roll = rand:Number(0, totalWeight)
	local acc = 0
	for _, entry in ipairs(weights) do
		acc = acc + entry.weight
		if roll <= acc then
			return entry.id
		end
	end
	return MANUFACTURER_ORDER[1]
end

function ShipDealerships.GetDealership(stationOrSbody)
	local profile = StationProfiles.Classify(stationOrSbody)
	local sbody = profile.sbody
	local seed = (sbody and sbody.seed) or (stationOrSbody and stationOrSbody.seed) or 12345
	local rand = Rand.New(tostring(seed) .. "-dealership-v1")

	if profile.purpose == StationProfiles.PURPOSES.PENAL then
		return {
			kind = "NONE",
			isIndependent = false,
			manufacturerId = nil,
			manufacturer = nil,
			name = "Restricted Correctional Dock",
			subtitle = "Civilian ship brokerage suspended under penal charter",
			purposeProfile = profile,
		}
	end

	local indepChance = 0.18
	if profile.purpose == StationProfiles.PURPOSES.FRONTIER then
		indepChance = 0.42
	elseif (profile.population or 0) < 0.05 then
		indepChance = 0.30
	elseif profile.purpose == StationProfiles.PURPOSES.COMMERCIAL then
		indepChance = 0.14
	end

	local isIndependent = rand:Number() < indepChance
	if isIndependent then
		local yardName = INDEPENDENT_YARD_NAMES[rand:Integer(1, #INDEPENDENT_YARD_NAMES)]
		return {
			kind = "INDEPENDENT_USED",
			isIndependent = true,
			manufacturerId = nil,
			manufacturer = nil,
			name = yardName,
			subtitle = "Independent Pre-Owned Brokerage // Aftermarket-Outfitted Vessels",
			purposeProfile = profile,
		}
	end

	local mfrId = pickWeightedManufacturer(profile, rand)
	local mfr = ShipDealerships.Manufacturers[mfrId]
	local dealerName = mfr.dealershipNames[rand:Integer(1, #mfr.dealershipNames)]
	return {
		kind = "FRANCHISE",
		isIndependent = false,
		manufacturerId = mfrId,
		manufacturer = mfr,
		name = dealerName,
		subtitle = string.format("%s (%s) // Factory Showroom & Cross-Brand Trade-Ins", mfr.name, mfr.planFGroup),
		purposeProfile = profile,
	}
end

-- Helper to instantiate a prototype cleanly for a ship slot and compute its exact volume & price
local function buildSpecializedEquip(equipId, config, slotCount)
	local proto = Equipment.Get(equipId)
	if not proto then return nil end
	local inst = proto:Instance()
	if inst.SpecializeForShip then
		inst:SpecializeForShip(config)
	end
	if slotCount then
		inst:SetCount(slotCount)
	end
	return inst, proto
end

local function pickArchetypeForShip(def, profile, rand)
	local cls = def.shipClass or ""
	if profile and (profile.purpose == StationProfiles.PURPOSES.FRONTIER or (profile.secondary and profile.secondary.FRONTIER)) then
		if rand:Number() < 0.35 then
			return "SMUGGLER", "Independent Frontier Runner"
		end
	end
	if def.id == "dsminer" then
		return "MINER", "Ex-Ring Extraction Rig"
	elseif cls:find("fighter") then
		return "INTERCEPTOR", "Retired Bounty Interceptor"
	elseif cls:find("courier") then
		return "COURIER", "Former Express Courier"
	elseif cls:find("passenger") then
		return "PASSENGER", "Decommissioned Charter Liner"
	elseif cls:find("freighter") or cls:find("cargo") then
		if profile and profile.purpose == StationProfiles.PURPOSES.INDUSTRIAL and rand:Number() < 0.45 then
			return "MINER", "Refitted Ore Hauler"
		end
		return "FREIGHTER", "Commercial Trade-In"
	end
	return "EXPLORER", "Deep-Space Survey Refit"
end

local function getAftermarketPoolForSlot(slot, archetype, hullPercent)
	local st = slot.type or ""
	local sz = slot.size or 1
	local smin = slot.size_min or sz
	local candidates = {}

	local function add(id)
		local proto = Equipment.Get(id)
		if proto and EquipSet.CompatibleWithSlot(proto, slot) then
			table.insert(candidates, id)
		end
	end

	if st:match("^thruster") then
		if archetype == "INTERCEPTOR" or archetype == "COURIER" or archetype == "SMUGGLER" then
			add("thruster.optimised_s" .. sz)
			add("thruster.improved_s" .. sz)
		else
			add("thruster.improved_s" .. sz)
			add("thruster.optimised_s" .. sz)
		end
	elseif st:match("^hyperdrive%.civilian") or st == "hyperdrive" then
		add(string.format("hyperspace.hyperdrive_%d_c", sz))
		if sz <= 5 then
			add(string.format("hyperspace.hyperdrive_%d_b", sz))
		end
	elseif st:match("^shield") then
		for s = sz, smin, -1 do
			add("shield.basic_s" .. s)
		end
	elseif st:match("^weapon%.mining") then
		add("laser.miningcannon_17mw")
		add("laser.miningcannon_5mw")
	elseif st:match("^weapon") then
		if archetype == "MINER" then
			add("laser.miningcannon_5mw")
			add("laser.miningcannon_17mw")
		end
		if sz >= 4 then add("laser.pulsecannon_10mw") end
		if sz >= 3 then add("laser.pulsecannon_4mw"); add("laser.pulsecannon_rapid_2mw") end
		if sz >= 2 then add("laser.beamlaser_2mw"); add("laser.beamlaser_dual_1mw"); add("laser.pulsecannon_2mw"); add("laser.pulsecannon_dual_1mw") end
		add("laser.beamlaser_1mw")
		add("laser.pulsecannon_1mw")
	elseif st:match("^computer") then
		if archetype == "SMUGGLER" or archetype == "INTERCEPTOR" then
			add("misc.interdiction_nullifier")
			add("misc.fsd_interdictor_1")
		end
		add("misc.autopilot_mk2")
		add("misc.trade_computer")
		add("misc.autopilot")
	elseif st:match("^sensor") then
		add("sensor.radar")
		add("sensor.discovery_scanner")
	elseif st:match("^fuel_scoop") then
		for s = sz, smin, -1 do
			add("misc.fuel_scoop_s" .. s)
		end
	elseif st:match("^hull%.atmo_shield") or st == "hull" then
		for s = sz, smin, -1 do
			add("hull.heavy_atmospheric_shielding_s" .. s)
			add("hull.atmospheric_shielding_s" .. s)
		end
	elseif st:match("^structure") then
		for s = sz, smin, -1 do
			add("struct.reinforced_structure_s" .. s)
		end
	elseif st:match("^utility") then
		if archetype == "EXPLORER" or archetype == "MINER" then
			add("misc.orbitscanner")
			add("misc.planetscanner")
			add("misc.planetscanner_good")
		elseif archetype == "INTERCEPTOR" or archetype == "SMUGGLER" then
			add("misc.ecm_basic")
			add("misc.target_scanner")
		else
			add("misc.planetscanner")
			add("misc.target_scanner")
			add("misc.ecm_basic")
		end
	elseif st:match("^cabin") then
		if archetype == "SMUGGLER" then
			for s = sz, smin, -1 do add("misc.cabin_smuggler_hold_s" .. s) end
		elseif archetype == "PASSENGER" then
			for s = sz, smin, -1 do add("misc.cabin_s" .. s) end
		else
			for s = sz, smin, -1 do add("misc.cabin_hold_s" .. s) end
			for s = sz, smin, -1 do add("misc.cabin_s" .. s) end
		end
	elseif st:match("^missile") then
		add("missile.guided_s" .. sz)
		add("missile.unguided_s" .. sz)
		if sz >= 3 then add("missile.smart_s" .. sz) end
	end

	return candidates
end

-- Build a deterministic-or-random aftermarket loadout for a used ship
local function buildUsedShipEquipment(def, config, profile, hullPercent, rand)
	local archetype, provenance = pickArchetypeForShip(def, profile, rand)
	local freeVol = config.equipCapacity or 0
	local bySlotId = {}
	local looseItems = {}

	-- 1. Seed default items from HullConfig
	local slotIds = {}
	for slotId, _ in pairs(config.slots or {}) do
		table.insert(slotIds, slotId)
	end
	table.sort(slotIds)

	for _, slotId in ipairs(slotIds) do
		local slot = config.slots[slotId]
		if slot.default then
			local inst = buildSpecializedEquip(slot.default, config, slot.count)
			if inst and freeVol >= inst.volume then
				freeVol = freeVol - inst.volume
				bySlotId[slotId] = {
					slotId = slotId,
					id = slot.default,
					count = slot.count,
					aftermarket = false,
					volume = inst.volume,
					retailPrice = inst.price or 0,
				}
			end
		end
	end

	-- 2. Shuffle candidate slots and install 2-5 aftermarket upgrades / additions
	local upgradeTargets = {}
	for _, slotId in ipairs(slotIds) do
		local slot = config.slots[slotId]
		local st = slot.type or ""
		if not st:match("^pylon") and not st:match("^missile_bay") and not st:match("^turret") and not st:match("^vehicle_bay") then
			table.insert(upgradeTargets, slot)
		end
	end
	for i = #upgradeTargets, 2, -1 do
		local j = rand:Integer(1, i)
		upgradeTargets[i], upgradeTargets[j] = upgradeTargets[j], upgradeTargets[i]
	end

	-- Prioritize key systems first by moving thruster/shield/weapon/hyperdrive near front when desired
	local targetCount = rand:Integer(2, 5)
	local installedCount = 0

	for _, slot in ipairs(upgradeTargets) do
		if installedCount >= targetCount then break end

		local pool = getAftermarketPoolForSlot(slot, archetype, hullPercent)
		if #pool > 0 then
			local oldEntry = bySlotId[slot.id]
			local availVol = freeVol + (oldEntry and oldEntry.volume or 0)

			-- Pick first or random compatible option that fits volume
			local startIdx = rand:Integer(1, #pool)
			for offset = 0, #pool - 1 do
				local idx = ((startIdx - 1 + offset) % #pool) + 1
				local eqId = pool[idx]
				if not oldEntry or oldEntry.id ~= eqId then
					local inst = buildSpecializedEquip(eqId, config, slot.count)
					if inst and availVol >= inst.volume then
						freeVol = availVol - inst.volume
						bySlotId[slot.id] = {
							slotId = slot.id,
							id = eqId,
							count = slot.count,
							aftermarket = true,
							volume = inst.volume,
							retailPrice = inst.price or 0,
						}
						installedCount = installedCount + 1
						break
					end
				end
			end
		end
	end

	-- 3. Optionally install 1 slotless aftermarket accessory (cargo scoop / life support / laser cooler)
	local loosePool = { "misc.cargo_scoop", "misc.cargo_life_support", "misc.laser_cooling_booster" }
	if rand:Number() < 0.45 then
		local eqId = loosePool[rand:Integer(1, #loosePool)]
		local inst = buildSpecializedEquip(eqId, config, nil)
		if inst and freeVol >= inst.volume then
			freeVol = freeVol - inst.volume
			table.insert(looseItems, {
				slotId = nil,
				id = eqId,
				count = nil,
				aftermarket = true,
				volume = inst.volume,
				retailPrice = inst.price or 0,
			})
		end
	end

	-- 4. Convert to plain serializable list with used valuation & integrity (new or 90%-100%)
	local equipList = {}

	local function finalizeItem(entry)
		local newChance = entry.aftermarket and 0.45 or 0.30
		local isNewModule = rand:Number() < newChance
		local integ = isNewModule and 1.0 or utils.round(rand:Number(0.90, 1.00), 0.01)
		local discount = isNewModule
			and (entry.aftermarket and rand:Number(0.88, 0.96) or rand:Number(0.90, 0.98))
			or  (entry.aftermarket and rand:Number(0.70, 0.86) or rand:Number(0.76, 0.92))
		local usedPrice = math.max(10, math.floor((entry.retailPrice or 0) * discount))
		table.insert(equipList, {
			slotId = entry.slotId,
			id = entry.id,
			count = entry.count,
			aftermarket = entry.aftermarket,
			isNew = isNewModule,
			integrity = integ,
			usedPrice = usedPrice,
		})
	end

	for _, slotId in ipairs(slotIds) do
		if bySlotId[slotId] then
			finalizeItem(bySlotId[slotId])
		end
	end
	for _, entry in ipairs(looseItems) do
		finalizeItem(entry)
	end

	return equipList, provenance
end

function ShipDealerships.CreateNewListing(def, station, rand)
	rand = rand or Engine.rand
	local label = Ship.MakeRandomLabel(def.id, "PLAYER")
	local model = Engine.GetModel(def.modelName)
	local pattern = (model and model.numPatterns ~= 0) and rand:Integer(1, model.numPatterns) or nil
	local profile = StationProfiles.Classify(station)
	local mfr = ShipDealerships.Manufacturers[def.manufacturer]
	local hullMod = 1.0
	if mfr and profile.factionName and mfr.factionAffinities[profile.factionName] then
		hullMod = 0.97
	end

	return {
		def = def,
		skin = makeFactorySkin(def.manufacturer, label, rand),
		pattern = pattern,
		label = label,
		condition = "NEW",
		sellerType = "DEALERSHIP",
		hullPercent = 100,
		flightHours = 0,
		hullPriceMod = hullMod,
		provenance = "Factory Direct Delivery",
		equipList = nil,
	}
end

function ShipDealerships.CreateUsedListing(def, station, sellerType, rand)
	rand = rand or Engine.rand
	sellerType = sellerType or "DEALERSHIP_USED"
	local label = Ship.MakeRandomLabel(def.id, "PLAYER")
	local model = Engine.GetModel(def.modelName)
	local pattern = (model and model.numPatterns ~= 0) and rand:Integer(1, model.numPatterns) or nil
	local config = HullConfig.GetHullConfig(def.id)
	local profile = StationProfiles.Classify(station)

	local isDealerUsed = (sellerType == "DEALERSHIP_USED")
	local hullPercent = isDealerUsed and rand:Integer(80, 97) or rand:Integer(66, 94)
	local flightHours = isDealerUsed and rand:Integer(220, 2600) or rand:Integer(650, 5800)
	local hullFrac = hullPercent / 100
	local hullPriceMod = isDealerUsed
		and math.clamp(0.56 + hullFrac * 0.28 + rand:Number(-0.03, 0.03), 0.64, 0.85)
		or  math.clamp(0.46 + hullFrac * 0.30 + rand:Number(-0.04, 0.04), 0.56, 0.80)

	local equipList, provenance = buildUsedShipEquipment(def, config, profile, hullPercent, rand)

	return {
		def = def,
		skin = ModelSkin.New():SetRandomColors(rand):SetDecal(def.manufacturer):SetLabel(label),
		pattern = pattern,
		label = label,
		condition = "USED",
		sellerType = sellerType,
		hullPercent = hullPercent,
		flightHours = flightHours,
		hullPriceMod = utils.round(hullPriceMod, 0.001),
		provenance = provenance,
		equipList = equipList,
	}
end

function ShipDealerships.GenerateInitialInventory(station)
	local dealership = ShipDealerships.GetDealership(station)
	if dealership.kind == "NONE" then
		return {}
	end

	local sbody = StationProfiles.GetSystemBody(station)
	local seed = (sbody and sbody.seed) or (station and station.seed) or 12345
	local rand = Rand.New(tostring(seed) .. "-shipinv-v1")
	local pop = dealership.purposeProfile.population or 0
	local listings = {}

	if dealership.kind == "FRANCHISE" then
		local brandHulls = collectEligibleShips(station, dealership.manufacturerId, nil)
		local otherHulls = collectEligibleShips(station, nil, dealership.manufacturerId)

		-- Factory-new showroom exclusively from dealership's brand
		local newTarget = math.clamp(3 + math.floor(math.log(pop * 10 + 1)), 3, 7)
		if #brandHulls > 0 then
			-- Ensure every model in the brand's lineup appears at least once when feasible
			for i = 1, math.min(#brandHulls, newTarget) do
				table.insert(listings, ShipDealerships.CreateNewListing(brandHulls[i], station, rand))
			end
			-- Fill remaining showroom slots with distinct factory trims/liveries of core brand hulls
			while #listings < newTarget do
				local def = brandHulls[rand:Integer(1, #brandHulls)]
				table.insert(listings, ShipDealerships.CreateNewListing(def, station, rand))
			end
		end

		-- Pre-owned trade-in lot (~80% cross-brand: "Honda dealer selling used Fords")
		local usedTarget = math.clamp(2 + math.floor(math.log(pop * 5 + 1)), 2, 5)
		for _ = 1, usedTarget do
			local useOther = (#otherHulls > 0) and (rand:Number() < 0.80 or #brandHulls == 0)
			local pool = useOther and otherHulls or brandHulls
			if #pool > 0 then
				local def = pool[rand:Integer(1, #pool)]
				table.insert(listings, ShipDealerships.CreateUsedListing(def, station, "DEALERSHIP_USED", rand))
			end
		end
	else
		-- Independent Used Ship Brokerage: 100% pre-owned, all manufacturers, tiered affordability
		local allHulls = collectEligibleShips(station, nil, nil)
		local totalTarget = math.clamp(5 + math.floor(math.log(pop * 8 + 1)), 5, 10)

		local lightHulls, midHulls, heavyHulls = {}, {}, {}
		for _, def in ipairs(allHulls) do
			if (def.basePrice or 0) <= 100000 then
				table.insert(lightHulls, def)
			elseif (def.basePrice or 0) <= 950000 then
				table.insert(midHulls, def)
			else
				table.insert(heavyHulls, def)
			end
		end

		-- Guarantee tier representation
		if #lightHulls > 0 then
			table.insert(listings, ShipDealerships.CreateUsedListing(lightHulls[rand:Integer(1, #lightHulls)], station, "INDEPENDENT_USED", rand))
		end
		for _ = 1, math.min(2, #midHulls) do
			if #listings < totalTarget then
				table.insert(listings, ShipDealerships.CreateUsedListing(midHulls[rand:Integer(1, #midHulls)], station, "INDEPENDENT_USED", rand))
			end
		end
		if #heavyHulls > 0 and #listings < totalTarget then
			table.insert(listings, ShipDealerships.CreateUsedListing(heavyHulls[rand:Integer(1, #heavyHulls)], station, "INDEPENDENT_USED", rand))
		end

		while #listings < totalTarget and #allHulls > 0 do
			local def = allHulls[rand:Integer(1, #allHulls)]
			table.insert(listings, ShipDealerships.CreateUsedListing(def, station, "INDEPENDENT_USED", rand))
		end
	end

	return listings
end

function ShipDealerships.ReplenishListing(station, currentListings)
	local dealership = ShipDealerships.GetDealership(station)
	if dealership.kind == "NONE" then return nil end

	local newCount, usedCount = 0, 0
	for _, entry in ipairs(currentListings or {}) do
		if entry.condition == "USED" then
			usedCount = usedCount + 1
		else
			newCount = newCount + 1
		end
	end

	if dealership.kind == "FRANCHISE" then
		local brandHulls = collectEligibleShips(station, dealership.manufacturerId, nil)
		local otherHulls = collectEligibleShips(station, nil, dealership.manufacturerId)

		if newCount < 2 or (newCount < 4 and Engine.rand:Number() < 0.55) then
			if #brandHulls > 0 then
				local def = brandHulls[Engine.rand:Integer(1, #brandHulls)]
				return ShipDealerships.CreateNewListing(def, station, Engine.rand)
			end
		end

		local useOther = (#otherHulls > 0) and (Engine.rand:Number() < 0.80 or #brandHulls == 0)
		local pool = useOther and otherHulls or brandHulls
		if #pool > 0 then
			local def = pool[Engine.rand:Integer(1, #pool)]
			return ShipDealerships.CreateUsedListing(def, station, "DEALERSHIP_USED", Engine.rand)
		end
	else
		local allHulls = collectEligibleShips(station, nil, nil)
		if #allHulls > 0 then
			local def = allHulls[Engine.rand:Integer(1, #allHulls)]
			return ShipDealerships.CreateUsedListing(def, station, "INDEPENDENT_USED", Engine.rand)
		end
	end

	return nil
end

function ShipDealerships.ComputeListingOffer(sos)
	local def = assert(sos.def)
	local config = assert(HullConfig.GetHullConfig(def.id))
	local isUsed = (sos.condition == "USED")

	local hullBase = def.basePrice or 0
	local hullPrice = math.floor(hullBase * (sos.hullPriceMod or 1.0))
	local equipPrice = 0
	local retailEquipPrice = 0
	local equip = {}
	local aftermarketItems = {}

	if sos.equipList and #sos.equipList > 0 then
		for _, item in ipairs(sos.equipList) do
			local inst, proto = buildSpecializedEquip(item.id, config, item.count)
			if inst and proto then
				local retailP = math.floor(inst.price or 0)
				local itemPrice = retailP
				if isUsed then
					local integ = (type(item.integrity) == "number") and item.integrity or 0.95
					itemPrice = math.floor(item.usedPrice or (retailP * 0.78))
					inst.price = itemPrice
					inst.integrity = integ
					inst.isUsed = not (item.isNew or (integ >= 0.999))
				end

				table.insert(equip, { item.slotId, inst, item.aftermarket == true })
				equipPrice = equipPrice + itemPrice
				retailEquipPrice = retailEquipPrice + retailP

				if item.aftermarket then
					table.insert(aftermarketItems, {
						name = inst:GetName(),
						slotId = item.slotId,
						integrity = (type(item.integrity) == "number") and item.integrity or 0.95,
						price = itemPrice,
					})
				end
			end
		end
	else
		-- Factory default configuration from HullConfig
		local slotIds = {}
		for slotId, _ in pairs(config.slots or {}) do
			table.insert(slotIds, slotId)
		end
		table.sort(slotIds)

		for _, slotId in ipairs(slotIds) do
			local slot = config.slots[slotId]
			if slot.default then
				local inst = buildSpecializedEquip(slot.default, config, slot.count)
				if inst then
					local p = math.floor(inst.price or 0)
					inst.price = p
					table.insert(equip, { slot.id, inst, false })
					equipPrice = equipPrice + p
					retailEquipPrice = retailEquipPrice + p
				end
			end
		end
	end

	local totalPrice = math.floor(hullPrice + equipPrice)
	local retailTotal = math.floor(hullBase + retailEquipPrice)
	local savings = math.max(0, retailTotal - totalPrice)

	return {
		price = totalPrice,
		hullPrice = hullPrice,
		equipPrice = equipPrice,
		retailTotal = retailTotal,
		savings = savings,
		equip = equip,
		aftermarketItems = aftermarketItems,
	}
end

function ShipDealerships.InstallListingEquipment(ship, offer, sos)
	local equipSet = ship:GetComponent('EquipSet')
	local def = ShipDef[ship.shipId] or (sos and sos.def)
	local config = HullConfig.GetHullConfig(ship.shipId)

	local ordered = {}
	for _, pair in ipairs((offer and offer.equip) or {}) do
		table.insert(ordered, pair)
	end
	table.sort(ordered, function(a, b)
		local sa, sb = a[1], b[1]
		if sa and sb then
			if #sa ~= #sb then return #sa < #sb end
			return sa < sb
		end
		return sa ~= nil and sb == nil
	end)

	for _, pair in ipairs(ordered) do
		local slotId = pair[1]
		local srcInst = pair[2]
		if srcInst and srcInst.id then
			local proto = Equipment.Get(srcInst.id)
			if proto then
				local inst = proto:Instance()
				if inst.SpecializeForShip and config then
					inst:SpecializeForShip(config)
				end
				if srcInst.count and inst.SetCount then
					inst:SetCount(srcInst.count)
				end
				if rawget(srcInst, "price") ~= nil then
					inst.price = rawget(srcInst, "price")
				end
				if rawget(srcInst, "integrity") ~= nil then
					inst.integrity = rawget(srcInst, "integrity")
				end
				if rawget(srcInst, "isUsed") then
					inst.isUsed = true
				end

				if slotId then
					local handle = equipSet:GetSlotHandle(slotId)
					if handle and equipSet:CanInstallInSlot(handle, inst) then
						equipSet:Install(inst, handle)
					else
						local freeSlot = equipSet:GetFreeSlotForEquip(inst)
						if freeSlot and equipSet:CanInstallInSlot(freeSlot, inst) then
							equipSet:Install(inst, freeSlot)
						end
					end
				elseif equipSet:CanInstallLoose(inst) then
					equipSet:Install(inst, nil)
				end
			end
		end
	end

	-- Fallback hyperdrive guarantee
	if def and (def.hyperdriveClass or 0) > 0 and not ship:GetInstalledHyperdrive() then
		local slot = equipSet:GetAllSlotsOfType('hyperdrive')[1]
		if slot then
			local hyperdrive = utils.best_score(Equipment.new, function(_, equip)
				return EquipSet.CompatibleWithSlot(equip, slot)
					and equip.slot and equip.slot.type:match("%.civilian")
					and equip.capabilities and equip.capabilities.hyperclass or nil
			end)
			if hyperdrive then
				equipSet:Install(hyperdrive:Instance(), slot)
			end
		end
	end

	if sos and sos.hullPercent then
		ship:SetHullPercent(math.clamp(sos.hullPercent, 1, 100))
	end
	ship:SetFuelPercent(100)
end

function ShipDealerships.BuildTradeInListing(playerShip)
	local def = ShipDef[playerShip.shipId]
	local equipSet = playerShip:GetComponent('EquipSet')
	local installed = equipSet and equipSet:GetInstalledEquipment() or {}
	local equipList = {}

	local hullPct = math.clamp(math.floor(playerShip.hullPercent or 100), 10, 100)

	for key, eq in pairs(installed) do
		local slotId = (type(key) == "string") and key or nil
		local isDefault = false
		if slotId and equipSet.config and equipSet.config.slots and equipSet.config.slots[slotId] then
			isDefault = (equipSet.config.slots[slotId].default == eq.id)
		end
		table.insert(equipList, {
			slotId = slotId,
			id = eq.id,
			count = eq.count,
			aftermarket = not isDefault,
			integrity = rawget(eq, "integrity") or 0.90,
			usedPrice = math.max(10, math.floor((eq.price or 0) * 0.80)),
		})
	end

	table.sort(equipList, function(a, b)
		if a.slotId and b.slotId then
			if #a.slotId ~= #b.slotId then return #a.slotId < #b.slotId end
			return a.slotId < b.slotId
		end
		return a.slotId ~= nil and b.slotId == nil
	end)

	local hullPriceMod = math.clamp(0.65 + (hullPct / 100) * 0.20, 0.55, 0.85)

	return {
		def = def,
		skin = playerShip:GetSkin(),
		pattern = playerShip.model and playerShip.model.pattern or nil,
		label = playerShip.label,
		condition = "USED",
		sellerType = "PLAYER_TRADE_IN",
		hullPercent = hullPct,
		flightHours = Engine.rand:Integer(40, 480),
		hullPriceMod = utils.round(hullPriceMod, 0.001),
		provenance = "Recent Pilot Trade-In",
		equipList = equipList,
	}
end

return ShipDealerships

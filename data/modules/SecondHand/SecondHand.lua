-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Engine          = require 'Engine'
local Lang            = require 'Lang'
local Game            = require 'Game'
local Event           = require 'Event'
local Format          = require 'Format'
local Serializer      = require 'Serializer'
local Equipment       = require 'Equipment'
local EquipSet        = require 'EquipSet'
local Economy         = require 'Economy'
local HullConfig      = require 'HullConfig'
local Character       = require 'Character'
local PlayerState     = require 'PlayerState'
local StationProfiles = require 'StationProfiles'
local PenalSystem     = require 'modules.Penal.PenalSystem'

local utils = require 'utils'

local l = Lang.GetResource("module-secondhand")

local CORP_SELLERS = {
	{ role = "opli",      org = "OPLI Refurbishment Division",       title = "Surplus Broker" },
	{ role = "kaluri",    org = "Kaluri Fleet Surplus",              title = "Depot Quartermaster" },
	{ role = "haber",     org = "Haber Industrial Salvage",          title = "Asset Liquidator" },
	{ role = "albr",      org = "ALBR Test-Range Decommission",      title = "Ordnance Factor" },
	{ role = "auronox",   org = "Auronox Charter Excess",            title = "Fleet Procurement" },
	{ role = "mandarava", org = "Mandarava-Csepel Depot",            title = "Parts Liquidator" },
	{ role = "mining",    org = "Deep Core Extraction Surplus",      title = "Supply Officer" },
	{ role = "logistics", org = "Astra Logistics Liquidation",       title = "Cargo & Bay Surplus" },
	{ role = "science",   org = "Universal Cartographics Surplus",   title = "Instrument Broker" },
}

local INDIVIDUAL_ROLES = {
	{ role = "civilian",    title = "Independent Captain" },
	{ role = "crew",        title = "Freelance Courier" },
	{ role = "engineering", title = "Dockside Machinist" },
	{ role = "civilian",    title = "Retired Prospector" },
	{ role = "engineering", title = "Salvage Operator" },
}

local PROVENANCE_INDIVIDUAL = {
	"pulled from an older freighter during an engine refit",
	"stripped from a decommissioned courier hull before drydock scrap",
	"barely used spare kept in my locker across three frontier runs",
	"tested on the bench this morning after an owner upgrade",
	"salvaged intact from an abandoned claim tender and re-calibrated",
}

local PROVENANCE_CORP = {
	"fleet-rotation overstock cleared by corporate maintenance",
	"certified refurbished depot surplus carrying bench verification",
	"insurance-recovery hardware recertified for commercial sale",
	"decommissioned test-bed component cleared for immediate fitment",
}

local ads = {}

local onDelete = function(ref)
	ads[ref] = nil
end

local function conditionLabelForIntegrity(integrity)
	if integrity >= 0.90 then
		return "Like New"
	elseif integrity >= 0.80 then
		return "Good Refurbished"
	else
		return "Service-Worn"
	end
end

local function specializePreviewForPlayer(equip)
	local player = Game.player
	if not player or not equip then return equip end
	if equip.SpecializeForShip then
		local inst = equip:GetPrototype():Instance()
		local cfg = HullConfig.GetHullConfig(player.shipId)
		if cfg then
			inst:SpecializeForShip(cfg)
		end
		return inst
	end
	return equip
end

-- Normalize legacy save adverts so they cleanly participate in the haggling marketplace
local function normalizeAd(ad)
	if not ad then return ad end
	local proto = ad.equipment and ad.equipment:GetPrototype() or nil
	local retail = ad.retailPrice or (proto and proto.price) or ad.price or 100
	ad.retailPrice = math.max(50, math.floor(retail))
	ad.askingPrice = math.max(25, math.floor(ad.askingPrice or ad.price or ad.retailPrice))
	ad.initialPrice = math.max(ad.askingPrice, math.floor(ad.initialPrice or ad.askingPrice))
	ad.reservePrice = math.max(25, math.floor(ad.reservePrice or math.floor(ad.askingPrice * 0.80)))
	ad.integrity = ad.integrity or 0.84
	ad.conditionLabel = ad.conditionLabel or conditionLabelForIntegrity(ad.integrity)
	ad.sellerType = ad.sellerType or "INDIVIDUAL"
	ad.provenance = ad.provenance or "bench-checked pre-owned module"
	ad.patience = ad.patience or 2
	ad.haggleRounds = ad.haggleRounds or 0
	ad.haggleState = ad.haggleState or "OPEN"
	if ad.equipment then
		ad.equipment.integrity = ad.integrity
		ad.equipment.isUsed = true
	end
	return ad
end

-- Check direct fit or compatible slot replacement on player's ship
local function evaluateFit(equip)
	local player = Game.player
	local equipSet = player:GetComponent("EquipSet")
	local checkEquip = specializePreviewForPlayer(equip)
	local freeVol = equipSet:GetFreeVolume()

	if not checkEquip.slot then
		if freeVol >= checkEquip.volume then
			return { ok = true, mode = "LOOSE", slot = nil, replaceItem = nil, refund = 0 }
		end
		return { ok = false, reason = l.EQUIPMENT_NO_SPACE }
	end

	if not equipSet:HasCompatibleSlotForEquipment(checkEquip) then
		return { ok = false, reason = l.EQUIPMENT_NO_COMPATIBLE_SLOT }
	end

	local freeSlot = equipSet:GetFreeSlotForEquip(checkEquip)
	if freeSlot and equipSet:CanInstallInSlot(freeSlot, checkEquip) then
		return { ok = true, mode = "FREE_SLOT", slot = freeSlot, replaceItem = nil, refund = 0 }
	end

	-- Look for an occupied compatible slot whose current item can be sold/swapped out
	local bestSwap = nil
	for _, slot in pairs(equipSet.slotCache or {}) do
		if slot.hardpoint == checkEquip.slot.hardpoint and EquipSet.CompatibleWithSlot(checkEquip, slot) and not slot.required then
			local existing = equipSet:GetItemInSlot(slot)
			if existing and existing:CanBeSold(player) and (freeVol + (existing.volume or 0) >= checkEquip.volume) then
				local refund = math.floor((rawget(existing, "price") or existing.price or 0) * Economy.BaseResellPriceModifier)
				bestSwap = {
					ok = true,
					mode = "SWAP_SLOT",
					slot = slot,
					replaceItem = existing,
					refund = refund,
				}
				break
			end
		end
	end

	if bestSwap then
		return bestSwap
	end

	if freeVol < checkEquip.volume then
		return { ok = false, reason = l.EQUIPMENT_SLOT_NO_SPACE }
	end
	return { ok = false, reason = l.EQUIPMENT_NO_FREE_SLOT }
end

local isEnabled = function(ref)
	return ads[ref] ~= nil
end

local function computeHaggleOffer(askingPrice, factor)
	local raw = math.floor(askingPrice * factor)
	if raw >= 1000 then
		raw = math.floor(raw / 50) * 50
	elseif raw >= 200 then
		raw = math.floor(raw / 10) * 10
	end
	return math.max(25, math.min(askingPrice - 5, raw))
end

local function resolveHaggle(ad, option)
	local factorMap = {
		[10] = 0.90, -- Polite -10%
		[11] = 0.82, -- Firm -18%
		[12] = 0.72, -- Hardball -28%
	}
	local factor = factorMap[option]
	if not factor then return false end

	local offer = computeHaggleOffer(ad.askingPrice, factor)
	ad.haggleRounds = (ad.haggleRounds or 0) + 1

	local pChar = Character.persistent and Character.persistent.player
	local charisma = (pChar and pChar.charisma) or 34
	local reputation = (pChar and pChar.reputation) or 0
	local charismaBonus = math.clamp((charisma - 34) / 100, -0.15, 0.25)
	local repBonus = math.clamp(reputation / 500, 0, 0.08)

	local acceptFloor = math.floor(ad.reservePrice * (1.0 - charismaBonus * 0.45 - repBonus * 0.30))
	if offer >= acceptFloor or (offer >= ad.reservePrice * 0.96 and Engine.rand:Number() < (0.45 + charismaBonus)) then
		ad.askingPrice = offer
		ad.price = offer
		ad.haggleState = "AGREED"
		ad.patience = 0
		ad.lastReply = string.format(
			"Alright, you drive a fair bargain. %s works for me — I'll fit it at %s right now.",
			Format.Money(offer, false), Format.Money(offer, false)
		)
		return false
	end

	local walkChance = (option == 12) and (0.55 - charismaBonus * 0.50) or (0.18 - charismaBonus * 0.25)
	if (option == 12 and offer < ad.reservePrice * 0.72 and Engine.rand:Number() < walkChance)
		or (ad.patience <= 0 and option == 12)
	then
		ad.haggleState = "WALKED_AWAY"
		ad.lastReply = "Are you serious with that lowball? Forget it — the deal is off. Look elsewhere."
		return true
	end

	if ad.patience > 1 and offer >= ad.reservePrice * 0.68 then
		local target = math.max(offer, ad.reservePrice)
		local stepFrac = Engine.rand:Number(0.42, 0.62) + charismaBonus * 0.25
		stepFrac = math.clamp(stepFrac, 0.25, 0.80)
		local newAsk = math.floor(ad.askingPrice - (ad.askingPrice - target) * stepFrac)
		newAsk = math.max(ad.reservePrice, math.min(ad.askingPrice - 5, newAsk))

		ad.askingPrice = newAsk
		ad.price = newAsk
		ad.patience = ad.patience - 1
		ad.haggleState = "COUNTERED"
		ad.lastReply = string.format(
			"I can't drop all the way to %s, %s. Meet me partway at %s and we're closer to a deal.",
			Format.Money(offer, false),
			(ad.sellerType == "CORPORATE") and "commander" or "friend",
			Format.Money(newAsk, false)
		)
		return false
	end

	local finalAsk = math.max(offer, math.min(ad.askingPrice, math.ceil(ad.reservePrice * (1.03 - charismaBonus * 0.10))))
	ad.askingPrice = finalAsk
	ad.price = finalAsk
	ad.patience = 0
	ad.haggleState = "FINAL"
	ad.lastReply = string.format(
		"Look, %s is below my margin. Rock-bottom final price is %s — take it or leave it.",
		Format.Money(offer, false), Format.Money(finalAsk, false)
	)
	return false
end

local onChat = function(form, ref, option)
	local ad = normalizeAd(ads[ref])

	form:Clear()

	if option == -1 or not ad then
		form:Close()
		return
	end

	form:SetFace(ad.character)

	if ad.haggleState == "WALKED_AWAY" then
		form:SetMessage(ad.lastReply or "The seller closed the channel.")
		return
	end

	if option == 10 or option == 11 or option == 12 then
		local walked = resolveHaggle(ad, option)
		if walked then
			form:SetMessage(ad.lastReply)
			form:RemoveAdvertOnClose()
			ads[ref] = nil
			return
		end
	end

	local fit = evaluateFit(ad.equipment)

	if option == 2 then
		if not fit.ok then
			form:SetMessage(fit.reason or l.EQUIPMENT_NO_SPACE)
			return
		end

		local netCost = ad.askingPrice - (fit.refund or 0)
		if PlayerState.GetMoney() < netCost then
			form:SetMessage(l["NOT_ENOUGH_MONEY_" .. Engine.rand:Integer(0, 3)])
			return
		end

		local player = Game.player
		local equipSet = player:GetComponent("EquipSet")
		local station = player:GetDockedWith()

		if fit.mode == "SWAP_SLOT" and fit.replaceItem then
			assert(equipSet:Remove(fit.replaceItem))
			if station and station:exists() then
				station:AddEquipmentStock(fit.replaceItem:GetPrototype(), 1)
			end
		end

		local proto = ad.equipment:GetPrototype()
		local inst = proto:Instance()
		if inst.SpecializeForShip then
			local cfg = HullConfig.GetHullConfig(player.shipId)
			if cfg then inst:SpecializeForShip(cfg) end
		end
		inst.price = ad.askingPrice
		inst.integrity = ad.integrity
		inst.isUsed = true

		assert(equipSet:Install(inst, fit.slot))
		PlayerState.AddMoney(-netCost)

		local sizePrefix = (inst.slot and ("S" .. inst.slot.size .. " ") or "")
		local equipDisplay = sizePrefix .. inst:GetName()

		local okFlightLog, FlightLog = pcall(require, 'modules.FlightLog.FlightLog')
		if okFlightLog and FlightLog and FlightLog.RecordTransaction then
			FlightLog.RecordTransaction({
				category = "EQUIPMENT",
				title = string.format("Used Market: %s (%s)", inst:GetName(), Format.Money(-netCost)),
				amount = -netCost,
				details = {
					{ "Equipment Module", equipDisplay },
					{ "Seller", string.format("%s (%s)", ad.character.name, ad.character.org or ad.sellerType) },
					{ "Condition", string.format("%s (%d%%)", ad.conditionLabel, math.floor(ad.integrity * 100 + 0.5)) },
					{ "Negotiated Price", Format.Money(ad.askingPrice, false) },
					{ "Trade-In Credit", Format.Money(fit.refund or 0, false) },
					{ "Net Paid", Format.Money(netCost, false) },
				},
				note = string.format("Purchased pre-owned %s via BBS surplus exchange.", equipDisplay)
			})
		end

		local buyMsg = string.interp(l.HAS_BEEN_FITTED_TO_YOUR_SHIP, { equipment = equipDisplay })
		if fit.mode == "SWAP_SLOT" and fit.replaceItem then
			buyMsg = buyMsg .. string.format("\n\nRemoved %s and credited %s trade-in toward installation.",
				fit.replaceItem:GetName(), Format.Money(fit.refund, false))
		end

		form:SetMessage(buyMsg)
		form:RemoveAdvertOnClose()
		ads[ref] = nil
		return
	end

	local equipSizeStr = (ad.equipment.slot and ("S" .. ad.equipment.slot.size .. " ") or "[Slotless] ")
	local equipFull = equipSizeStr .. ad.equipment:GetName()
	local integPct = math.floor((ad.integrity or 0.85) * 100 + 0.5)
	local discountPct = math.max(0, math.floor((1 - (ad.askingPrice / math.max(1, ad.retailPrice))) * 100 + 0.5))
	local netCost = ad.askingPrice - (fit.refund or 0)
	local canAfford = PlayerState.GetMoney() >= netCost

	local lines = {}
	if ad.lastReply then
		table.insert(lines, "\"" .. ad.lastReply .. "\"")
		table.insert(lines, "")
	else
		local greeting = (ad.sellerType == "CORPORATE")
			and string.format("Greetings, commander. %s has a surplus %s cleared for immediate transfer.", ad.character.org or "Our depot", equipFull)
			or string.format("Hi there — I'm %s. Looking to move a pre-owned %s while I'm docked here.", ad.character.name, equipFull)
		table.insert(lines, greeting)
		table.insert(lines, "")
	end

	table.insert(lines, string.format("Item: %s", equipFull))
	table.insert(lines, string.format("Condition: %s (%d%% integrity)", ad.conditionLabel, integPct))
	table.insert(lines, string.format("Asking Price: %s  (Retail MSRP: %s — %d%% off)",
		Format.Money(ad.askingPrice, false), Format.Money(ad.retailPrice, false), discountPct))

	if option == 1 then
		table.insert(lines, string.format("History: %s. Fitting & calibration are included.", ad.provenance))
		local flexHint = (ad.patience <= 0)
			and "Seller demeanor: Firm — final price on the table."
			or ((ad.sellerType == "CORPORATE") and "Seller demeanor: Corporate liquidation — modest room to negotiate." or "Seller demeanor: Private seller — open to reasonable offers.")
		table.insert(lines, flexHint)
	end

	table.insert(lines, "")
	if not fit.ok then
		table.insert(lines, "Fitment Check: " .. (fit.reason or l.EQUIPMENT_NO_SPACE))
	elseif fit.mode == "SWAP_SLOT" and fit.replaceItem then
		table.insert(lines, string.format("Fitment Check: Replaces installed %s (Trade-in credit: +%s, Net due: %s).",
			fit.replaceItem:GetName(), Format.Money(fit.refund, false), Format.Money(netCost, false)))
	else
		table.insert(lines, "Fitment Check: Compatible free bay available — ready for immediate installation.")
	end

	if not canAfford then
		table.insert(lines, string.format("Funds Status: Short by %s at current asking price.", Format.Money(netCost - PlayerState.GetMoney(), false)))
	end

	form:SetMessage(table.concat(lines, "\n"))

	if option ~= 1 then
		form:AddOption("Ask about condition & provenance", 1)
	else
		form:AddOption("Back to offer summary", 0)
	end

	if (ad.haggleState == "OPEN" or ad.haggleState == "COUNTERED") and ad.patience > 0 then
		local politeOffer = computeHaggleOffer(ad.askingPrice, 0.90)
		local firmOffer = computeHaggleOffer(ad.askingPrice, 0.82)
		local hardOffer = computeHaggleOffer(ad.askingPrice, 0.72)
		form:AddOption(string.format("Polite counter-offer: %s (-10%%)", Format.Money(politeOffer, false)), 10)
		form:AddOption(string.format("Firm bargain: %s (-18%%)", Format.Money(firmOffer, false)), 11)
		form:AddOption(string.format("Hardball lowball: %s (-28%%)", Format.Money(hardOffer, false)), 12)
	end

	if fit.ok and canAfford then
		if fit.mode == "SWAP_SLOT" then
			form:AddOption(string.format("Swap & Buy (%s net)", Format.Money(netCost, false)), 2)
		else
			form:AddOption(string.format("Buy & Install (%s)", Format.Money(ad.askingPrice, false)), 2)
		end
	end
end

local postAdvert = function(station, ad)
	normalizeAd(ad)
	local equipName = (ad.equipment.slot and "S" .. ad.equipment.slot.size .. " " or "") .. ad.equipment:GetName()
	local sellerTag = (ad.sellerType == "CORPORATE") and "[Corp Surplus]" or "[Private]"
	local integPct = math.floor((ad.integrity or 0.85) * 100 + 0.5)

	ad.desc = string.format("%s %s (%d%% cond.) — %s",
		sellerTag, equipName, integPct, Format.Money(ad.askingPrice, false))

	local title = (ad.sellerType == "CORPORATE") and "SURPLUS HARDWARE" or "USED EQUIPMENT"
	local ref = station:AddAdvert({
		title       = title,
		description = ad.desc,
		icon        = "second_hand",
		onChat      = onChat,
		onDelete    = onDelete,
		isEnabled   = isEnabled
	})
	ads[ref] = ad
end

local function buildEquipmentPool(station, isCorporate)
	local profile = StationProfiles.Classify(station)
	local lawlessness = (Game.system and Game.system.lawlessness) or 0
	local weighted = {}

	for _, equip in pairs(Equipment.new) do
		local st = (equip.slot and equip.slot.type) or ""
		local eligible = equip.purchasable
			and not st:match("^thruster")
			and not st:match("^hyperdrive%.military")

		if eligible then
			if equip.lawlessness and lawlessness < equip.lawlessness then
				eligible = false
			elseif equip.min_security and lawlessness >= (1 - equip.min_security) then
				eligible = false
			end
		end

		if eligible then
			local eval = StationProfiles.EvaluateEquipment(station, equip, profile)
			local weight = 0
			if eval.isSpecialty then
				weight = 4
			elseif eval.allowed then
				weight = 2
			elseif isCorporate and equip.tech_level ~= "MILITARY" and Engine.rand:Number() < 0.25 then
				-- Corporate liquidation occasionally brings cross-sector surplus
				weight = 1
			elseif not isCorporate and equip.tech_level ~= "MILITARY" and (tonumber(equip.tech_level) or 1) <= 7 then
				weight = 1
			end

			for _ = 1, weight do
				table.insert(weighted, equip)
			end
		end
	end

	return weighted
end

local makeAdvert = function(station)
	local isCorporate = (Engine.rand:Number() < 0.45)
	local pool = buildEquipmentPool(station, isCorporate)
	if #pool == 0 then return end

	local equipType = pool[Engine.rand:Integer(1, #pool)]
	local equipment = equipType:Instance()

	local character
	local sellerType
	local provenance
	local initialDiscount
	local reserveMult
	local patience

	if isCorporate then
		sellerType = "CORPORATE"
		local corp = CORP_SELLERS[Engine.rand:Integer(1, #CORP_SELLERS)]
		character = Character.New({
			role = corp.role,
			org = corp.org,
			title = corp.title,
		})
		provenance = PROVENANCE_CORP[Engine.rand:Integer(1, #PROVENANCE_CORP)]
		initialDiscount = Engine.rand:Number(0.70, 0.85)
		reserveMult = Engine.rand:Number(0.80, 0.90)
		patience = 2
	else
		sellerType = "INDIVIDUAL"
		local ind = INDIVIDUAL_ROLES[Engine.rand:Integer(1, #INDIVIDUAL_ROLES)]
		character = Character.New({
			role = ind.role,
			org = "Private Seller",
			title = ind.title,
		})
		provenance = PROVENANCE_INDIVIDUAL[Engine.rand:Integer(1, #PROVENANCE_INDIVIDUAL)]
		initialDiscount = Engine.rand:Number(0.62, 0.80)
		reserveMult = Engine.rand:Number(0.72, 0.84)
		patience = Engine.rand:Integer(2, 3)
	end

	local retailPrice = math.max(100, math.floor(station:GetEquipmentPrice(equipType) or equipType.price or 100))
	local initialPrice = math.max(50, math.floor(retailPrice * initialDiscount))
	local reservePrice = math.max(40, math.floor(initialPrice * reserveMult))
	local integrity = utils.round(Engine.rand:Number(0.70, 0.96), 0.01)

	equipment.integrity = integrity
	equipment.isUsed = true
	equipment.price = initialPrice

	local ad = {
		character = character,
		sellerType = sellerType,
		retailPrice = retailPrice,
		initialPrice = initialPrice,
		askingPrice = initialPrice,
		price = initialPrice,
		reservePrice = reservePrice,
		integrity = integrity,
		conditionLabel = conditionLabelForIntegrity(integrity),
		provenance = provenance,
		patience = patience,
		haggleRounds = 0,
		haggleState = "OPEN",
		equipment = equipment,
		station = station,
	}

	postAdvert(station, ad)
end

local function targetAdsForStation()
	local pop = (Game.system and Game.system.population) or 0
	return math.clamp(2 + math.floor(math.log(pop * 4 + 1)), 2, 5)
end

local onCreateBB = function(station)
	if PenalSystem.IsPrisonStation(station) then return end

	local target = targetAdsForStation()
	for _ = 1, target do
		makeAdvert(station)
	end
end

local onUpdateBB = function(station)
	if PenalSystem.IsPrisonStation(station) then return end

	local stationRefs = {}
	for ref, ad in pairs(ads) do
		if ad.station == station then
			table.insert(stationRefs, ref)
		end
	end

	local lambda = 0.693147 / (4 * 24)
	local remaining = #stationRefs
	for _, ref in ipairs(stationRefs) do
		if remaining > 2 and Engine.rand:Number(0, 1) < lambda then
			station:RemoveAdvert(ref)
			remaining = remaining - 1
		end
	end

	local currentCount = 0
	for _, ad in pairs(ads) do
		if ad.station == station then
			currentCount = currentCount + 1
		end
	end

	local target = targetAdsForStation()
	if currentCount < 2 or (currentCount < target and Engine.rand:Number(0, 1) < 0.15) then
		makeAdvert(station)
	end
end

local loaded_data

local onGameStart = function()
	ads = {}

	if not loaded_data or not loaded_data.ads then return end

	for _, ad in pairs(loaded_data.ads) do
		if ad.station and ad.station:exists() and ad.equipment then
			postAdvert(ad.station, ad)
		end
	end

	loaded_data = nil
end

local serialize = function()
	return { ads = ads }
end

local unserialize = function(data)
	loaded_data = data
end

Event.Register("onCreateBB", onCreateBB)
Event.Register("onGameStart", onGameStart)
Event.Register("onUpdateBB", onUpdateBB)

Serializer:Register("SecondHand", serialize, unserialize)

-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Engine     = require 'Engine'
local Event      = require 'Event'
local Game       = require 'Game'
local Serializer = require 'Serializer'
local Timer      = require 'Timer'
local Comms      = require 'Comms'

local ComponentIntegrity = {}
local integrityTimerActive = false

-- Very gradual environmental wear constants:
-- 1.0% integrity loss per 100 hours of continuous 1G flight (~2.778e-8 per second at 1G)
ComponentIntegrity.STANDARD_GRAVITY = 9.80665
ComponentIntegrity.GRAVITY_BASE_RATE = 0.01 / (100.0 * 3600.0)
ComponentIntegrity.PASSIVE_WEAR_FLOOR = 0.15
ComponentIntegrity.REPAIR_THRESHOLD = 0.90

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local CATEGORY_GRAVITY_MULT = {
	thrusters  = 1.25,
	hull       = 1.00,
	structure  = 1.00,
	cabin      = 0.65,
	scoop      = 0.65,
	hyperdrive = 0.55,
	shields    = 0.55,
	weapon     = 0.45,
	missile    = 0.45,
	utility    = 0.45,
	sensors    = 0.30,
	computer   = 0.30,
}

--- Classify an equipment instance/prototype into a subsystem/wear category and nice label.
---@param equip EquipType
---@param slotId string?
---@return string category, string displayName, boolean targetable
function ComponentIntegrity.ClassifyEquipment(equip, slotId)
	local slotType = (equip and equip.slot and equip.slot.type) or ""
	local id = (equip and equip.id) or ""
	local name = (equip and equip.GetName and equip:GetName()) or id or "Module"

	if slotType:match("^thruster") then
		return "thrusters", "Thrusters", true
	elseif slotType:match("^hyperdrive") then
		return "hyperdrive", "Hyperdrive", true
	elseif slotType:match("^shield") then
		return "shields", "Shield Generator", true
	elseif slotType:match("^weapon") then
		return "weapon", name, true
	elseif slotType:match("^sensor") or slotType:match("^utility%.scanner") then
		return "sensors", name, true
	elseif slotType:match("^utility%.ecm") or slotType:match("^fuel_scoop") or id == "misc.cargo_scoop" then
		return "utility", name, true
	elseif slotType:match("^structure") then
		return "structure", name, false
	elseif slotType:match("^hull") then
		return "hull", name, false
	elseif slotType:match("^computer") then
		return "computer", name, false
	elseif slotType:match("^cabin") then
		return "cabin", name, false
	elseif slotType:match("^missile") or slotType:match("^pylon") then
		return "missile", name, false
	end

	return "utility", name, (slotId ~= nil and type(slotId) == "string")
end

--- Compute gravity strength scaling factor (0 below 0.05G, linear up to 1G, g^1.35 above 1G).
function ComponentIntegrity.ComputeGravityFactor(gEarth)
	if not gEarth or gEarth < 0.05 then
		return 0.0
	end
	if gEarth <= 1.0 then
		return gEarth
	end
	return math.pow(gEarth, 1.35)
end

--- Compute integrity loss delta over dtSeconds under gEarth Gs.
function ComponentIntegrity.ComputeGravityWear(gEarth, dtSeconds, category, isStaticSurface)
	if not dtSeconds or dtSeconds <= 0 then
		return 0.0
	end
	local gFactor = ComponentIntegrity.ComputeGravityFactor(gEarth)
	if gFactor <= 0 then
		return 0.0
	end
	local catMult = CATEGORY_GRAVITY_MULT[category or "utility"] or 0.5
	local stateMult = isStaticSurface and 0.25 or 1.0
	return ComponentIntegrity.GRAVITY_BASE_RATE * gFactor * catMult * stateMult * dtSeconds
end

--- Compute hyperjump integrity wear per transit (very slight: ~0.18% to ~0.75% on drive; 15% of that on other gear).
function ComponentIntegrity.ComputeHyperjumpWear(durationSeconds, isHyperdrive, driveId)
	local jumpHours = math.max(0.0, (durationSeconds or 0.0) / 3600.0)
	local base = math.min(0.015, 0.0008 + 0.00004 * jumpHours)

	if not isHyperdrive then
		return base * 0.15
	end

	local gradeMult = 1.0
	local id = driveId or ""
	if id:match("_c$") then
		gradeMult = 0.90
	elseif id:match("_b$") then
		gradeMult = 0.82
	elseif id:match("_a$") then
		gradeMult = 0.75
	elseif id:match("mil") then
		gradeMult = 0.70
	end

	return base * gradeMult
end

--- Compute station drydock repair cost for an installed module.
--- Servicing is only available once integrity drops below REPAIR_THRESHOLD (90%).
function ComponentIntegrity.GetModuleRepairCost(equip)
	if not equip then return 0 end
	local integrity = clamp(rawget(equip, "integrity") or 1.0, 0.0, 1.0)
	if integrity >= ComponentIntegrity.REPAIR_THRESHOLD then
		return 0
	end
	local missing = 1.0 - integrity
	local basePrice = equip.price or 500
	return math.max(10, math.ceil(basePrice * missing * 0.35))
end

local function ensureIntegrityField(equip)
	local cur = rawget(equip, "integrity")
	if type(cur) ~= "number" then
		equip.integrity = 1.0
	else
		equip.integrity = clamp(cur, 0.0, 1.0)
	end
	return equip.integrity
end

--- Synchronize installed EquipSet module integrity into C++ Ship & GunManager hit-zones.
function ComponentIntegrity.SyncShipSubsystems(ship)
	if not ship or not ship:exists() then return end
	local equipSet = ship:GetComponent("EquipSet")
	if not equipSet then return end

	local gunManager = ship:GetComponent("GunManager")
	local curThruster, curHyper, curShield, curSensor = 1.0, 1.0, 1.0, 1.0
	if ship.GetSubsystemHealthSummary then
		curThruster, curHyper, curShield, curSensor = ship:GetSubsystemHealthSummary()
	end

	local thrustersSum, thrustersCount = 0.0, 0
	local hyperMin, hyperCount = 1.0, 0
	local shieldMin, shieldCount = 1.0, 0
	local sensorMin, sensorCount = 1.0, 0

	local nodes = {}
	local hasThrusterNode, hasHyperNode, hasShieldNode, hasSensorNode = false, false, false, false

	for key, equip in pairs(equipSet:GetInstalledEquipment()) do
		local integ = ensureIntegrityField(equip)
		local slotId = type(key) == "string" and key or ""
		local category, displayName, targetable = ComponentIntegrity.ClassifyEquipment(equip, slotId)
		local slot = (slotId ~= "" and equipSet.GetSlotHandle) and equipSet:GetSlotHandle(slotId) or nil
		local tag = (slot and slot.tag) or ""

		if category == "thrusters" then
			thrustersSum = thrustersSum + integ
			thrustersCount = thrustersCount + 1
			if not hasThrusterNode then
				hasThrusterNode = true
				table.insert(nodes, {
					id = "thrusters",
					name = "Thrusters",
					slotId = slotId,
					category = "thrusters",
					integrity = integ,
					tag = tag,
				})
			end
		elseif category == "hyperdrive" then
			hyperMin = math.min(hyperMin, integ)
			hyperCount = hyperCount + 1
			if not hasHyperNode then
				hasHyperNode = true
				table.insert(nodes, {
					id = "hyperdrive",
					name = "Hyperdrive",
					slotId = slotId,
					category = "hyperdrive",
					integrity = integ,
					tag = tag,
				})
			end
		elseif category == "shields" then
			shieldMin = math.min(shieldMin, integ)
			shieldCount = shieldCount + 1
			if not hasShieldNode then
				hasShieldNode = true
				table.insert(nodes, {
					id = "shields",
					name = "Shield Generator",
					slotId = slotId,
					category = "shields",
					integrity = integ,
					tag = tag,
				})
			end
		elseif category == "sensors" then
			sensorMin = math.min(sensorMin, integ)
			sensorCount = sensorCount + 1
			if not hasSensorNode then
				hasSensorNode = true
				table.insert(nodes, {
					id = "sensors",
					name = "Sensors",
					slotId = slotId,
					category = "sensors",
					integrity = integ,
					tag = tag,
				})
			end
		elseif category == "weapon" and slotId ~= "" then
			if gunManager and gunManager.SetWeaponHealth then
				gunManager:SetWeaponHealth(slotId, integ)
			end
			table.insert(nodes, {
				id = "weapon:" .. slotId,
				name = displayName,
				slotId = slotId,
				category = "weapon",
				integrity = integ,
				tag = tag,
			})
		elseif targetable and slotId ~= "" then
			table.insert(nodes, {
				id = "utility:" .. slotId,
				name = displayName,
				slotId = slotId,
				category = "utility",
				integrity = integ,
				tag = tag,
			})
		end
	end

	-- Keep averaged/synthetic nodes coherent with C++ health summary when a ship lacks explicit modules
	local thrusterH = thrustersCount > 0 and (thrustersSum / thrustersCount) or curThruster
	local hyperH = hyperCount > 0 and hyperMin or curHyper
	local shieldH = shieldCount > 0 and shieldMin or curShield
	local sensorH = sensorCount > 0 and sensorMin or curSensor

	if not hasThrusterNode then
		table.insert(nodes, 1, { id = "thrusters", name = "Thrusters", slotId = "", category = "thrusters", integrity = thrusterH, tag = "" })
	end
	if not hasSensorNode then
		table.insert(nodes, { id = "sensors", name = "Sensors", slotId = "", category = "sensors", integrity = sensorH, tag = "" })
	end

	-- Deterministic order for smooth '[' / ']' cycling: thrusters, hyperdrive, shields, weapons..., sensors, utility...
	local catRank = { thrusters = 1, hyperdrive = 2, shields = 3, weapon = 4, sensors = 5, utility = 6 }
	table.sort(nodes, function(a, b)
		local ra, rb = catRank[a.category] or 9, catRank[b.category] or 9
		if ra ~= rb then return ra < rb end
		return a.id < b.id
	end)

	if ship.SyncSubsystems then
		ship:SyncSubsystems(nodes)
	end
	if ship.SetSubsystemHealthSummary then
		ship:SetSubsystemHealthSummary(thrusterH, hyperH, shieldH, sensorH)
	end
end

local function updateHealthSummaryOnly(ship)
	if not ship or not ship:exists() then return end
	local equipSet = ship:GetComponent("EquipSet")
	if not equipSet then return end

	local curThruster, curHyper, curShield, curSensor = 1.0, 1.0, 1.0, 1.0
	if ship.GetSubsystemHealthSummary then
		curThruster, curHyper, curShield, curSensor = ship:GetSubsystemHealthSummary()
	end

	local thrustersSum, thrustersCount = 0.0, 0
	local hyperMin, hyperCount = 1.0, 0
	local shieldMin, shieldCount = 1.0, 0
	local sensorMin, sensorCount = 1.0, 0

	for _, equip in pairs(equipSet:GetInstalledEquipment()) do
		local integ = ensureIntegrityField(equip)
		local category = ComponentIntegrity.ClassifyEquipment(equip)
		if category == "thrusters" then
			thrustersSum = thrustersSum + integ
			thrustersCount = thrustersCount + 1
		elseif category == "hyperdrive" then
			hyperMin = math.min(hyperMin, integ)
			hyperCount = hyperCount + 1
		elseif category == "shields" then
			shieldMin = math.min(shieldMin, integ)
			shieldCount = shieldCount + 1
		elseif category == "sensors" then
			sensorMin = math.min(sensorMin, integ)
			sensorCount = sensorCount + 1
		end
	end

	if ship.SetSubsystemHealthSummary then
		ship:SetSubsystemHealthSummary(
			thrustersCount > 0 and (thrustersSum / thrustersCount) or curThruster,
			hyperCount > 0 and hyperMin or curHyper,
			shieldCount > 0 and shieldMin or curShield,
			sensorCount > 0 and sensorMin or curSensor
		)
	end
end

--- Apply subtle wear on hyperspace exit.
function ComponentIntegrity.ApplyHyperjumpWear(ship, durationSeconds)
	if not ship or not ship:exists() then return end
	local equipSet = ship:GetComponent("EquipSet")
	if not equipSet then return end

	for _, equip in pairs(equipSet:GetInstalledEquipment()) do
		local cur = ensureIntegrityField(equip)
		if cur > ComponentIntegrity.PASSIVE_WEAR_FLOOR then
			local slotType = (equip.slot and equip.slot.type) or ""
			local isHd = slotType:match("^hyperdrive") ~= nil
			local loss = ComponentIntegrity.ComputeHyperjumpWear(durationSeconds, isHd, equip.id)
			equip.integrity = math.max(ComponentIntegrity.PASSIVE_WEAR_FLOOR, cur - loss)
		end
	end

	ComponentIntegrity.SyncShipSubsystems(ship)
end

--- Return list of damaged installed modules on ship.
function ComponentIntegrity.GetDamagedModules(ship)
	local out = {}
	if not ship or not ship:exists() then return out end
	local equipSet = ship:GetComponent("EquipSet")
	if not equipSet then return out end

	for key, equip in pairs(equipSet:GetInstalledEquipment()) do
		local integ = clamp(rawget(equip, "integrity") or 1.0, 0.0, 1.0)
		local cost = ComponentIntegrity.GetModuleRepairCost(equip)
		if cost > 0 then
			local slotId = type(key) == "string" and key or nil
			local category, displayName = ComponentIntegrity.ClassifyEquipment(equip, slotId)
			table.insert(out, {
				equip = equip,
				slotId = slotId,
				category = category,
				name = (equip.GetName and equip:GetName()) or displayName,
				integrity = integ,
				disabled = integ <= 0.001,
				cost = cost,
			})
		end
	end

	table.sort(out, function(a, b)
		if a.integrity ~= b.integrity then return a.integrity < b.integrity end
		return (a.name or "") < (b.name or "")
	end)
	return out
end

--- Count how many installed modules (or C++ subsystems) are currently 0% offline.
function ComponentIntegrity.GetDisabledSubsystems(ship)
	local disabled = {}
	if not ship or not ship:exists() then return disabled end

	local equipSet = ship:GetComponent("EquipSet")
	local seen = {}
	if equipSet then
		for key, equip in pairs(equipSet:GetInstalledEquipment()) do
			local integ = clamp(rawget(equip, "integrity") or 1.0, 0.0, 1.0)
			if integ <= 0.001 then
				local name = (equip.GetName and equip:GetName()) or key
				table.insert(disabled, { equip = equip, name = name })
				seen[equip] = true
			end
		end
	end

	if ship.GetSubsystemHealthSummary then
		local tH, hH, sH, snH = ship:GetSubsystemHealthSummary()
		if #disabled == 0 then
			if tH <= 0.001 then table.insert(disabled, { synthetic = "thrusters", name = "Thrusters" }) end
			if hH <= 0.001 then table.insert(disabled, { synthetic = "hyperdrive", name = "Hyperdrive" }) end
			if sH <= 0.001 then table.insert(disabled, { synthetic = "shields", name = "Shield Generator" }) end
			if snH <= 0.001 then table.insert(disabled, { synthetic = "sensors", name = "Sensors" }) end
		end
	end
	return disabled
end

--==============================================================================
-- Gravity Exposure Tick & Emergency Field Reboot State
--==============================================================================

local attachedShips = setmetatable({}, { __mode = "k" })
local lastGravityTickTime = nil
local rebootActive = false
local rebootRemaining = 0.0
local REBOOT_DURATION = 10.0

function ComponentIntegrity.IsRebootActive()
	return rebootActive
end

function ComponentIntegrity.GetRebootRemaining()
	return rebootRemaining
end

function ComponentIntegrity.StartFieldReboot(player)
	player = player or Game.player
	if not player or not player:exists() or rebootActive then
		return false
	end
	if player:GetFlightState() ~= "FLYING" then
		return false
	end
	if #ComponentIntegrity.GetDisabledSubsystems(player) == 0 then
		return false
	end

	rebootActive = true
	rebootRemaining = REBOOT_DURATION
	Comms.ImportantMessage("Initiating emergency subsystem field reboot (10s). Bypassing damaged buses...", "Engineering")
	return true
end

local function finishFieldReboot(player)
	rebootActive = false
	rebootRemaining = 0.0
	if not player or not player:exists() or player:GetHullPercent() <= 0 then return end

	local equipSet = player:GetComponent("EquipSet")
	local repairedNames = {}
	if equipSet then
		for _, equip in pairs(equipSet:GetInstalledEquipment()) do
			local integ = rawget(equip, "integrity") or 1.0
			if integ <= 0.001 then
				equip.integrity = 0.15
				table.insert(repairedNames, (equip.GetName and equip:GetName()) or "Module")
			end
		end
	end

	if player.GetSubsystemHealthSummary and player.SetSubsystemHealthSummary then
		local tH, hH, sH, snH = player:GetSubsystemHealthSummary()
		player:SetSubsystemHealthSummary(
			tH <= 0.001 and 0.15 or tH,
			hH <= 0.001 and 0.15 or hH,
			sH <= 0.001 and 0.15 or sH,
			snH <= 0.001 and 0.15 or snH
		)
	end

	local hullPct = player:GetHullPercent()
	if hullPct > 5.0 then
		player:SetHullPercent(math.max(1.0, hullPct - 2.0))
	end

	ComponentIntegrity.SyncShipSubsystems(player)
	Comms.ImportantMessage("Emergency reboot complete (" .. table.concat(repairedNames, ", ") .. " restored to 15%). Seek station Drydock for full repair.", "Engineering")
end

local function attachEquipListener(ship)
	if not ship or attachedShips[ship] then return end
	local equipSet = ship:GetComponent("EquipSet")
	if not equipSet then return end

	attachedShips[ship] = true
	equipSet:AddListener(function(op, equip, slot)
		if equip and op == "install" then
			ensureIntegrityField(equip)
		end
		ComponentIntegrity.SyncShipSubsystems(ship)
	end)
end

local function getPlayerGravityG(player)
	if Game.InHyperspace() then
		return 0.0, false
	end

	local flightState = player:GetFlightState()
	if flightState == "SUPERCRUISE" or flightState == "HYPERSPACE" or flightState == "JUMPING" then
		return 0.0, false
	end

	if player:IsDocked() then
		local st = player:GetDockedWith()
		if not st or not st:IsGroundStation() then
			return 0.0, false -- Orbital station: freefall microgravity
		end
		local sbody = st:GetSystemBody()
		local parent = sbody and sbody.parent
		local g = parent and parent.gravity or 0.0
		return g / ComponentIntegrity.STANDARD_GRAVITY, true
	end

	if player:IsLanded() then
		local fb = player.frameBody
		local sbody = fb and fb:GetSystemBody()
		local g = sbody and sbody.gravity or 0.0
		return g / ComponentIntegrity.STANDARD_GRAVITY, true
	end

	if not player:IsDynamic() then
		return 0.0, false
	end

	local mass = player:GetMass() or 0
	if mass > 0 then
		local gForce = player:GetGravityForce()
		if gForce then
			local gAccel = gForce:length() / mass
			return gAccel / ComponentIntegrity.STANDARD_GRAVITY, false
		end
	end

	return 0.0, false
end

local function tickWearAndReboot()
	local player = Game.player
	if not player or not player:exists() or player:GetHullPercent() <= 0 then
		rebootActive = false
		rebootRemaining = 0.0
		return
	end

	local now = Game.time
	if not lastGravityTickTime then
		lastGravityTickTime = now
		return
	end

	local dt = now - lastGravityTickTime
	lastGravityTickTime = now
	if dt <= 0 then return end

	if player:IsDocked() and not rebootActive then
		return
	end

	-- Field reboot countdown runs over active gameplay intervals
	if rebootActive then
		if player:GetFlightState() ~= "FLYING" then
			rebootActive = false
			rebootRemaining = 0.0
		else
			rebootRemaining = rebootRemaining - math.min(dt, 5.0)
			if rebootRemaining <= 0.0 then
				finishFieldReboot(player)
			end
		end
	end

	-- Clamp huge non-flight time jumps (e.g. station Wait / Pass Time) unless statically parked on surface
	local gEarth, isStaticSurface = getPlayerGravityG(player)
	if gEarth < 0.05 then return end

	local equipSet = player:GetComponent("EquipSet")
	if not equipSet then return end

	local changed = false
	for key, equip in pairs(equipSet:GetInstalledEquipment()) do
		local cur = ensureIntegrityField(equip)
		if cur > ComponentIntegrity.PASSIVE_WEAR_FLOOR then
			local cat = ComponentIntegrity.ClassifyEquipment(equip, type(key) == "string" and key or nil)
			local loss = ComponentIntegrity.ComputeGravityWear(gEarth, dt, cat, isStaticSurface)
			if loss > 0 then
				local nextVal = math.max(ComponentIntegrity.PASSIVE_WEAR_FLOOR, cur - loss)
				if nextVal ~= cur then
					equip.integrity = nextVal
					changed = true
				end
			end
		end
	end

	if changed then
		updateHealthSummaryOnly(player)
	end
end

local function onShipSubsystemHit(ship, attacker, subId, slotId, newIntegrity, justDisabled)
	if not ship or not ship:exists() then return end

	local equipSet = ship:GetComponent("EquipSet")
	local subDisplayName = subId or "Subsystem"
	local integ = clamp(newIntegrity or 1.0, 0.0, 1.0)

	if equipSet then
		for key, equip in pairs(equipSet:GetInstalledEquipment()) do
			local eqSlotId = type(key) == "string" and key or ""
			local cat, displayName = ComponentIntegrity.ClassifyEquipment(equip, eqSlotId)
			local matched = false
			if slotId and slotId ~= "" and eqSlotId == slotId then
				matched = true
			elseif subId == "thrusters" and cat == "thrusters" then
				matched = true
			elseif subId == "hyperdrive" and cat == "hyperdrive" then
				matched = true
			elseif subId == "shields" and cat == "shields" then
				matched = true
			elseif subId == "sensors" and cat == "sensors" then
				matched = true
			end
			if matched then
				equip.integrity = integ
				subDisplayName = displayName
			end
		end
	end

	updateHealthSummaryOnly(ship)

	local player = Game.player
	if justDisabled and player then
		if ship == player then
			Comms.ImportantMessage(string.format("CRITICAL: %s OFFLINE (0%% integrity)! Field reboot available on HUD.", subDisplayName), "Ship Systems")
		elseif attacker == player then
			Comms.ImportantMessage(string.format("Target %s disabled!", subDisplayName), "Tactical Computer")
		end
	end
end

local function onShipCreated(ship)
	attachEquipListener(ship)
	ComponentIntegrity.SyncShipSubsystems(ship)
end

local function onShipTypeChanged(ship)
	attachedShips[ship] = nil
	attachEquipListener(ship)
	ComponentIntegrity.SyncShipSubsystems(ship)
end

local function onGameStart()
	rebootActive = false
	rebootRemaining = 0.0
	lastGravityTickTime = Game.time

	if Game.player then
		attachEquipListener(Game.player)
		ComponentIntegrity.SyncShipSubsystems(Game.player)
	end

	if not integrityTimerActive then
		integrityTimerActive = true
		Timer:CallEvery(2, function()
			if not Game.player then
				integrityTimerActive = false
				return true
			end
			tickWearAndReboot()
			return false
		end)
	end
end

local function onGameEnd()
	integrityTimerActive = false
	rebootActive = false
	rebootRemaining = 0.0
	lastGravityTickTime = nil
end

Event.Register("onShipCreated", onShipCreated)
Event.Register("onShipTypeChanged", onShipTypeChanged)
Event.Register("onShipSubsystemHit", onShipSubsystemHit)
Event.Register("onGameStart", onGameStart)
Event.Register("onGameEnd", onGameEnd)

Serializer:Register("ComponentIntegrity",
	function()
		return { lastGravityTickTime = lastGravityTickTime }
	end,
	function(data)
		lastGravityTickTime = data and data.lastGravityTickTime or nil
	end
)

return ComponentIntegrity

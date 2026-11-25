-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

---@class SpaceStation : ModelBody
---@field techLevel integer
local SpaceStation = package.core['SpaceStation']

local Economy     = require 'Economy'
local Event       = require 'Event'
local Rand        = require 'Rand'
local Space       = require 'Space'
local utils       = require 'utils'
local ShipDef     = require 'ShipDef'
local Engine      = require 'Engine'
local Timer       = require 'Timer'
local Game        = require 'Game'
local Ship        = require 'Ship'
local ModelSkin   = require 'SceneGraph.ModelSkin'
local Serializer  = require 'Serializer'
local Equipment   = require 'Equipment'
local Lang        = require 'Lang'
local HullConfig  = require 'HullConfig'
local StationProfiles = require 'StationProfiles'
local ShipDealerships = require 'ShipDealerships'

local ShipBuilder = require 'modules.MissionUtils.ShipBuilder'
local ShipTemplates = require 'modules.MissionUtils.ShipTemplates'

local l = Lang.GetResource("ui-core")

--
-- Class: SpaceStation
--

function SpaceStation.GetTechLevel(systemBody)

	local rand = Rand.New(systemBody.seed .. '-techLevel')
	local techLevel = rand:Integer(1, 6) + rand:Integer(0,6)
	local system = systemBody.path:GetStarSystem()

	if system.faction ~= nil and system.faction.hasHomeworld and system.faction.homeworld == systemBody.parent.path then
		techLevel = math.max(techLevel, 6) -- bump it upto at least 6 if it's a homeworld like Earth
	end
	-- cap the techlevel lower end based on the planets population
	techLevel = math.max(techLevel, math.min(math.floor(systemBody.parent.population * 0.5), 11))
	techLevel = math.max(techLevel, StationProfiles.GetMinTechLevel(systemBody))
	return techLevel;
end

function SpaceStation:Constructor()
	local techLevel = SpaceStation.GetTechLevel(self.path:GetSystemBody())

	self:setprop("techLevel", techLevel)
end

-- visited keeps track of which stations we have docked with and have had
-- extended info (BBS adverts, ship ads, equipment stock info) generated for
local visited = {}
local equipmentStock = {}

-- transientMarket is a cache for commodity markets associated with the current stations
-- It's used to handle market queries to non-visited stations without causing crashes...
local marketCache = {}

local ensureStationData

local equipmentPrice = {}

-- create a transient entry for this station's equipment stock
---@param station SpaceStation
local function createEquipmentStock (station)
	assert(station and station:exists())
	if equipmentStock[station] then error("Attempt to create station equipment stock twice!") end

	local stock = {}
	local prices = {}
	local profile = StationProfiles.Classify(station)

	for id, e in pairs(Equipment.new) do
		local eval = StationProfiles.EvaluateEquipment(station, e, profile)
		if eval.allowed then
			if eval.minStock > 0 then
				stock[id] = math.max(eval.minStock, Engine.rand:Integer(eval.minStock, eval.maxStock))
			else
				stock[id] = math.max(0, Engine.rand:Integer(-8, eval.maxStock))
			end
			if eval.priceMod and eval.priceMod ~= 1.0 then
				prices[id] = math.max(1, math.floor((e.price or 0) * eval.priceMod + 0.5))
			end
		end
	end

	equipmentStock[station] = stock
	equipmentPrice[station] = prices
end

local function restockEquipment (station)
	if not equipmentStock[station] then return end
	local stock = equipmentStock[station]
	local profile = StationProfiles.Classify(station)

	for id, e in pairs(Equipment.new) do
		local eval = StationProfiles.EvaluateEquipment(station, e, profile)
		if eval.allowed then
			local cur = stock[id]
			if cur == nil then
				stock[id] = (eval.minStock > 0) and eval.minStock or 0
			elseif cur < eval.minStock then
				stock[id] = cur + Engine.rand:Integer(1, math.max(2, eval.minStock - cur))
			elseif cur < eval.maxStock and Engine.rand:Number() < 0.12 then
				stock[id] = cur + Engine.rand:Integer(1, 3)
			end
		end
	end
end

-- Create a transient entry for this station's commodity stocks and seed it with
-- commodity stock information from persistent data
---@param station SpaceStation
local function createCommodityStock (station)
	local market = Economy.InitPersistentMarket(assert(station:GetSystemBody()))
	marketCache[station.path] = market
end

-- ============================================================================

--
-- Method: GetEquipmentPrice
--
-- Get the price of an equipment item traded at this station
--
-- > price = station:GetEquipmentPrice(equip)
--
-- Parameters:
--
--   equip - the <Constants.EquipType> string for the equipment item
--
-- Returns:
--
--   price - the price of the equipment item
--
function SpaceStation:GetEquipmentPrice (e)
	assert(self:exists())
	ensureStationData(self)

	if equipmentPrice[self] then
		return equipmentPrice[self][e.id] or e.price
	end

	return e.price
end

--
-- Method: SetEquipmentPrice
--
-- Set the price of an equipment item traded at this station
--
-- > station:SetEquipmentPrice(equip, price)
--
-- Parameters:
--
--   equip - the <Constants.EquipType> string for the equipment item
--
--   price - the new price of the equipment item
--
function SpaceStation:SetEquipmentPrice (e, price)
	assert(self:exists())
	ensureStationData(self)
	if not equipmentPrice[self] then equipmentPrice[self] = {} end
	equipmentPrice[self][e.id] = price
end

--
-- Method: GetEquipmentStock
--
-- Get the quantity of an equipment item this station has available for trade
--
-- > stock = station:GetEquipmentStock(equip)
--
-- Parameters:
--
--   equip - the <Constants.EquipType> string for the equipment item
--
-- Returns:
--
--   stock? - the amount available for trade, or nil if the item is not possible to be stocked
--
function SpaceStation:GetEquipmentStock (e)
	assert(self:exists())
	ensureStationData(self)
	return equipmentStock[self] and equipmentStock[self][e.id]
end

--
-- Method: AddEquipmentStock
--
-- Modify the quantity of an equipment item this station has available for trade
--
-- > station:AddEquipmentStock(equip, amount)
--
-- Parameters:
--
--   equip - the <Constants.EquipType> string for the equipment item
--
--   amount - the amount of the item to add (or subtract) from the station stock
--
function SpaceStation:AddEquipmentStock (e, stock)
	assert(self:exists())
	ensureStationData(self)
	assert(equipmentStock[self])

	equipmentStock[self][e.id] = (equipmentStock[self][e.id] or 0) + stock
end

-- ============================================================================

-- track commodity prices for stations present in the current system
local commodityPrice = utils.automagic()

--
-- Method: GetCommodityMarket
--
-- Get commodity market data for a commodity traded at this station.
--
-- > price = station:GetCommodityMarket(itemType)
--
-- Returns:
--
--   market - the <Economy.StationMarket> for this station
--
---@return table market
function SpaceStation:GetCommodityMarket()
	assert(self:exists())

	if not marketCache[self.path] then
		marketCache[self.path] = Economy.CreateStationMarket(assert(self:GetSystemBody()), Game.time)
		logWarning("Creating transient station market for station {}; any changes to the market will not persist!" % { self.label })
		logWarning(debug.dumpstack())
	end

	return marketCache[self.path]
end

--
-- Method: GetCommodityPrice
--
-- Get the price of a commodity item traded at this station
--
-- > price = station:GetCommodityPrice(itemType)
--
-- Parameters:
--
--   itemType - the <CommodityType> of the commodity item in question
--
-- Returns:
--
--   price - the price of the commodity item
--
---@param itemType CommodityType
---@return number price
function SpaceStation:GetCommodityPrice(itemType)
	assert(self:exists())

	-- TODO: this cache exists to allow special-case pricing for commodities from events
	-- This should ideally be handled with a queue of temporary modifiers which
	-- adjust supply/demand/pricemod and avoid this cache entirely
	local price = commodityPrice[self][itemType.name]
	if price then return price end

	-- determine the commodity price modifier for the current market conditions
	local pricemod = Economy.GetCommodityPriceMod(self.path, itemType.name, self:GetCommodityMarket())
	pricemod = pricemod + Game.system:GetCommodityBasePriceAlterations(itemType.name)

	return Economy.GetMarketPrice(itemType.price, pricemod)
end

--
-- Method: SetCommodityPrice
--
-- Set the price of a commodity item traded at this station
--
-- > station:SetCommodityPrice(itemType, price)
--
-- Parameters:
--
--   itemType - the <CommodityType> of the commodity item in question
--
--   price - the new price of the commodity item
--
---@param itemType CommodityType
---@param price number
function SpaceStation:SetCommodityPrice(itemType, price)
	assert(self:exists())

	commodityPrice[self][itemType.name] = price
end

--
-- Method: GetCommodityStock
--
-- Get the quantity of a cargo item this station has available for trade
--
-- > stock = station:GetCommodityStock(itemType)
--
-- Parameters:
--
--   itemType - the <CommodityType> of the commodity item in question
--
-- Returns:
--
--   stock - the amount available for trade
--
---@param itemType CommodityType
---@return integer stock
function SpaceStation:GetCommodityStock(itemType)
	return self:GetCommodityMarket().stock[itemType.name]
end

--
-- Method: AddCommodityStock
--
-- Modify the quantity of a cargo item this station has available for trade.
-- This function assumes this is taking place as part of a gameplay action,
-- so it modifies stock + demand levels based on the `amount` parameter.
--
-- > station:AddCommodityStock(itemType, amount)
--
-- Parameters:
--
--   itemType - a <CommodityType> cargo item
--
--   amount - the amount of the item to add (or subtract) from the station stock
--
---@param itemType CommodityType
---@param amount integer
function SpaceStation:AddCommodityStock(itemType, amount)
	assert(self:exists())
	ensureStationData(self)

	local market = self:GetCommodityMarket()
	local id = itemType.name

	local stock = market.stock[id]
	local delta = math.max(stock + amount, 0) - stock

	market.stock[id] = stock + delta
	market.history[id] = (market.history[id] or 0) + delta
end

--
-- Method: SetCommodityStock
--
-- Modify the stock and demand values of a cargo item this station has
-- available for trade. This function does not update the commodity price
-- or history values.
--
-- > station:SetCommodityStock(itemType, newStock, newSupply, newDemand)
--
-- Parameters:
--
--   itemType - a <CommodityType> cargo item
--
--   stock - optional, the new stock number for the commodity type
--   supply - optional, the new supply number for the commodity type
--   demand - optional, the new demand number for the commodity type
--
---@param itemType CommodityType
---@param stock integer? new commodity stock number
---@param supply integer? new commodity supply number
---@param demand integer? new commodity demand number
function SpaceStation:SetCommodityStock(itemType, stock, supply, demand)
	assert(self:exists())
	ensureStationData(self)

	local market = self:GetCommodityMarket()
	local id = itemType.name

	market.stock[id] = stock or market.stock[id]
	market.supply[id] = supply or market.supply[id]
	market.demand[id] = demand or market.demand[id]
end

-- ============================================================================

local shipsOnSale = {}

function SpaceStation:GetDealership ()
	assert(self:exists())
	return ShipDealerships.GetDealership(self)
end

function SpaceStation:GetStationProfile ()
	assert(self:exists())
	return StationProfiles.Classify(self)
end

function SpaceStation:GetShipsOnSale ()
	assert(self:exists())
	ensureStationData(self)
	if not shipsOnSale[self] then shipsOnSale[self] = {} end
	return shipsOnSale[self]
end

local function normalizeShipEntry(entry)
	return {
		def          = entry.def,
		skin         = entry.skin,
		pattern      = entry.pattern,
		label        = entry.label,
		condition    = entry.condition or "USED",
		sellerType   = entry.sellerType or (entry.condition == "NEW" and "DEALERSHIP" or "INDEPENDENT_USED"),
		hullPercent  = entry.hullPercent or (entry.condition == "NEW" and 100 or 90),
		flightHours  = entry.flightHours or 0,
		hullPriceMod = entry.hullPriceMod or 1.0,
		provenance   = entry.provenance,
		equipList    = entry.equipList,
	}
end

local function addShipOnSale (station, entry)
	if not shipsOnSale[station] then shipsOnSale[station] = {} end
	table.insert(shipsOnSale[station], entry)
end

function SpaceStation:AddShipOnSale (entry)
	assert(self:exists())
	assert(entry.def)
	assert(entry.skin)
	assert(entry.label)
	addShipOnSale(self, normalizeShipEntry(entry))
	Event.Queue("onShipMarketUpdate", self, shipsOnSale[self])
end

local function removeShipOnSale (station, num)
	if not shipsOnSale[station] then shipsOnSale[station] = {} end
	table.remove(shipsOnSale[station], num)
end

local function findShipOnSale (station, entry)
	if not shipsOnSale[station] then shipsOnSale[station] = {} end
	local num = 0
	for k,v in pairs(shipsOnSale[station]) do
		if v == entry then
			num = k
			break
		end
	end
	return num
end

function SpaceStation:RemoveShipOnSale (entry)
	assert(self:exists())
	local num = findShipOnSale(self, entry)
	if num > 0 then
		removeShipOnSale(self, num)
		Event.Queue("onShipMarketUpdate", self, shipsOnSale[self])
	end
end

function SpaceStation:ReplaceShipOnSale (old, new)
	assert(self:exists())
	assert(new.def)
	assert(new.skin)
	assert(new.label)
	local num = findShipOnSale(self, old)
	if num <= 0 then
		self:AddShipOnSale(new)
	else
		shipsOnSale[self][num] = normalizeShipEntry(new)
	end
	Event.Queue("onShipMarketUpdate", self, shipsOnSale[self])
end

-- Dynamics of dealership lots & ship turnover --
-------------------------------------------------
local function updateShipsOnSale (station)
	if not shipsOnSale[station] then shipsOnSale[station] = {} end
	local list = shipsOnSale[station]
	local dealership = ShipDealerships.GetDealership(station)

	if dealership.kind == "NONE" then
		if #list > 0 then
			shipsOnSale[station] = {}
			Event.Queue("onShipMarketUpdate", station, shipsOnSale[station])
		end
		return
	end

	local newCount, usedCount = 0, 0
	for _, ad in ipairs(list) do
		if ad.condition == "USED" then
			usedCount = usedCount + 1
		else
			newCount = newCount + 1
		end
	end

	local tau = 7 * 24 -- half life of a ship listing in hours
	local lambda = 0.693147 / tau

	-- Iterate backwards safely while respecting minimum dealership showroom/lot floors
	for i = #list, 1, -1 do
		local ad = list[i]
		local isUsed = (ad.condition == "USED")
		local canRemove = false
		if dealership.kind == "FRANCHISE" then
			canRemove = isUsed and (usedCount > 2) or ((not isUsed) and (newCount > 2))
		else
			canRemove = (#list > 4)
		end

		if canRemove and Engine.rand:Number(0, 1) < lambda then
			table.remove(list, i)
			if isUsed then
				usedCount = usedCount - 1
			else
				newCount = newCount - 1
			end
		end
	end

	local targetCount = (dealership.kind == "FRANCHISE") and 7 or 7
	if #list < targetCount or (#list < 10 and Engine.rand:Number(0, 1) < 0.08) then
		local needMin = (dealership.kind == "FRANCHISE") and (newCount < 2 or usedCount < 2) or (#list < 4)
		if needMin or Engine.rand:Number(0, 1) < 0.15 then
			local replacement = ShipDealerships.ReplenishListing(station, list)
			if replacement then
				addShipOnSale(station, normalizeShipEntry(replacement))
			end
		end
	end

	Event.Queue("onShipMarketUpdate", station, list)
end


--
-- Attribute: lawEnforcedRange
--
--   The distance, in meters, at which a station upholds the law,
--   (is 50 km for all at the moment)
--
SpaceStation.lawEnforcedRange = 50000


local police = {}

--
-- Method: LaunchPolice
--
-- Launch station police
--
-- > station:LaunchPolice(targetShip)
--
-- Parameters:
--
--   targetShip - the ship to intercept
--
function SpaceStation:LaunchPolice(targetShip)
	if not targetShip then error("Ship targeted invalid") end

	-- if no police created for this station yet:
	if not police[self] then
		police[self] = {}
		-- decide how many to create
		local lawlessness = Game.system.lawlessness
		local maxPolice = math.min(9, self.numDocks)
		local numberPolice = math.ceil(Engine.rand:Integer(1,maxPolice)*(1-lawlessness))

		-- The more lawless/dangerous the space is, the better equipped the few police ships are
		-- In a high-law area, a spacestation has a bunch of traffic cops due to low crime rates
		local shipThreat = 15.0 + Engine.rand:Number(10, 50) * lawlessness

		local shipTemplate = ShipTemplates.StationPolice:clone {
			shipId = Game.system.faction.policeShip,
			label = Game.system.faction.policeName or l.POLICE,
		}

		-- create and equip them
		for i = 1, numberPolice do
			local policeShip = ShipBuilder.MakeShipDocked(self, shipTemplate, shipThreat)
			if policeShip == nil then
				break
			end

			table.insert(police[self], policeShip)
		end
	end

	for _, policeShip in pairs(police[self]) do
		-- if docked
		if policeShip.flightState == "DOCKED" then
			policeShip:Undock()
		end
		-- if not shot down
		if policeShip:exists() then
			policeShip:AIKill(targetShip)
		end
	end
end


--
-- Method: LandPolice
--
-- Clear any target assigned and land flying station police.
--
-- > station:LandPolice()
--
function SpaceStation:LandPolice()
	-- land command issued before creation of police
	if not police[self] then return end

	for _, policeShip in pairs(police[self]) do
		if not (policeShip.flightState == "DOCKED") and policeShip:exists() then
			policeShip:CancelAI()
			policeShip:AIDockWith(self)
		end
	end
end


--
-- Group: Methods
--

SpaceStation.lockedAdvert = nil
SpaceStation.advertLockCount = 0
SpaceStation.removeOnReleased = false
SpaceStation.adverts = {}

--
-- Method: AddAdvert
--
-- Add an advertisement to the station's bulletin board
--
-- > ref = station:AddAdvert({
-- >     description = description,
-- >     icon        = icon,
-- >     onChat      = onChat,
-- >     onDelete    = onDelete,
-- >     isEnabled   = isEnabled,
-- > })
-- >
-- > -- Legacy form
-- > ref = station:AddAdvert(description, onChat, onDelete)
--
-- Parameters:
--
--   description - text to display in the bulletin board
--
--   icon - optional, filename of an icon to display alongside the advert.
--          Defaults to bullet (data/icons/bbs/default).
--
--   onChat - function to call when the ad is activated. The function is
--            passed three parameters: a <ChatForm> object for the ad
--            conversation display, the ad reference returned by <AddAdvert>
--            when the ad was created, and an integer value corresponding to
--            the action that caused the activation. When the ad is initially
--            selected from the bulletin board, this value is 0. Additional
--            actions (and thus values) are defined by the script via
--            <ChatForm.AddAction>.
--
--   onDelete - optional. function to call when the ad is removed from the
--              bulletin board. This happens when <RemoveAdvert> is called,
--              when the ad is cleaned up after
--              <ChatForm.RemoveAdvertOnClose> is called, and when the
--              <SpaceStation> itself is destroyed (eg the player leaves the
--              system).
--
--   isEnabled - optional. function to call to determine whether the advert is
--               enabled. Disabled adverts are shown in darker tone than enabled
--               ones. When not given, all adverts are considered enabled.
--
-- Return:
--
--   ref - an integer value for referring to the ad in the future. This value
--         will be passed to the ad's chat function and should be passed to
--         <RemoveAdvert> to remove the ad from the bulletin board.
--
-- Example:
--
-- > local ref = station:AddAdvert(
-- >     "FAST SHIP to deliver a package to the Epsilon Eridani system.",
-- >     function (ref, opt) ... end,
-- >     function (ref) ... end
-- > )
--
local nextRef = 0
function SpaceStation:AddAdvert (description, onChat, onDelete)
	assert(self:exists())
	-- XXX legacy arg unpacking
	local args
	if (type(description) == "table") then
		args = description
	else
		args = {
			description = description,
			onChat      = onChat,
			onDelete    = onDelete,
		}
	end

	if not SpaceStation.adverts[self] then SpaceStation.adverts[self] = {} end
	local adverts = SpaceStation.adverts[self]
	nextRef = nextRef+1
	adverts[nextRef] = args

	args.__ref = nextRef
	args.title = args.title or ""

	Event.Queue("onAdvertAdded", self, nextRef)
	return nextRef
end

--
-- Method: RemoveAdvert
--
-- Remove an advertisement from the station's bulletin board
--
-- > station:RemoveAdvert(ref)
--
-- If the onDelete parameter was supplied to <AddAdvert> when the ad was
-- created, it will be called as part of this call.
--
-- Parameters:
--
--   ref - the advert reference number returned by <AddAdvert>
--
function SpaceStation:RemoveAdvert (ref)
	assert(self:exists())
	if not SpaceStation.adverts[self] then return end
	if SpaceStation.lockedAdvert == ref then
		SpaceStation.removeOnReleased = true
		return
	end
	local onDelete = SpaceStation.adverts[self][ref].onDelete
	if onDelete then
		onDelete(ref)
	end
	SpaceStation.adverts[self][ref] = nil
	Event.Queue("onAdvertRemoved", self, ref)
end

--
-- Method: LockAdvert
--
-- > station:LockAdvert(ref)
--
-- Only one advert may be locked at a time. Locked adverts are not removed by
-- RemoveAdvert until they are unlocked.
--
-- Parameters:
--
--   ref - the advert reference number returned by <AddAdvert>
--
function SpaceStation:LockAdvert (ref)
	assert(self:exists())
	if (SpaceStation.advertLockCount > 0) then
		assert(SpaceStation.lockedAdvert == ref, "Attempt to lock ref "..ref
		.."disallowed."
		.." Ref "..(SpaceStation.lockedAdvert or "nil").." is already locked "
		..SpaceStation.advertLockCount.." times.")
		SpaceStation.advertLockCount = SpaceStation.advertLockCount + 1
		return
	end
	assert(SpaceStation.lockedAdvert == nil, "Attempt to lock ref "..ref
		.." disallowed."
		.." Ref "..(SpaceStation.lockedAdvert or "nil").." is already locked.")
	SpaceStation.lockedAdvert = ref
	SpaceStation.removeOnReleased = false
	SpaceStation.advertLockCount = 1
end

local function updateAdverts (station)
	if not SpaceStation.adverts[station] then
		logWarning("SpaceStation.lua: updateAdverts called for station that hasn't been visited")
		Event.Queue("onCreateBB", station)
	else
		Event.Queue("onUpdateBB", station)
	end
end

--
-- Method: UnlockAdvert
--
-- > station:UnlockAdvert(ref)
--
-- Releases the preserved advert. There must be an advert preserved at the
-- time. If RemoveAdvert(ref) was called with the preserved advert's ref while
-- the advert was preserved, it is now removed.
--
-- Parameters:
--
--   ref - the advert reference number returned by <AddAdvert>
--
function SpaceStation:UnlockAdvert (ref)
	assert(SpaceStation.lockedAdvert == ref, "Attempt to unlock ref "..ref
		.." disallowed."
		.." Ref "..(SpaceStation.lockedAdvert or "nil").." is locked"
		..SpaceStation.advertLockCount.." times. Unlock this"
		.." first.")
	if (SpaceStation.advertLockCount > 1) then
		SpaceStation.advertLockCount = SpaceStation.advertLockCount - 1
		return
	end
	local shouldRemove = SpaceStation.removeOnReleased
	SpaceStation.lockedAdvert = nil
	SpaceStation.advertLockCount = 0
	SpaceStation.removeOnReleased = false
	if shouldRemove and self:exists() and SpaceStation.adverts[self] and SpaceStation.adverts[self][ref] then
		self:RemoveAdvert(ref)
	end
end

function SpaceStation:CleanExpiredAdverts (now)
	if not self:exists() or not SpaceStation.adverts[self] then return false end
	local tNow = now or Game.time or 0
	local expiredRefs = {}
	for ref, ad in pairs(SpaceStation.adverts[self]) do
		if type(ad) == "table" and ((type(ad.due) == "number" and (ad.due - tNow) <= 0) or (type(ad.timeout) == "number" and (ad.timeout - tNow) <= 0)) then
			table.insert(expiredRefs, ref)
		end
	end
	for _, ref in ipairs(expiredRefs) do
		self:RemoveAdvert(ref)
	end
	return #expiredRefs > 0
end

function SpaceStation.CleanAllExpiredAdverts (now)
	local tNow = now or Game.time or 0
	local stations = {}
	for station, _ in pairs(SpaceStation.adverts) do
		table.insert(stations, station)
	end
	for _, station in ipairs(stations) do
		if station and station:exists() then
			station:CleanExpiredAdverts(tNow)
		end
	end
end

local expiryTimerActive = false
local systemUpdateTimerActive = false

local function updateSystem ()
	if not Game.player then
		systemUpdateTimerActive = false
		return true
	end

	SpaceStation.CleanAllExpiredAdverts()
	local stations = Space.GetBodies("SpaceStation")
	for i, station in ipairs(stations) do
		Economy.UpdateStationMarket(assert(station:GetSystemBody()), station:GetCommodityMarket())

		if visited[station] then
			restockEquipment(station)
			updateShipsOnSale(station)
			updateAdverts(station)
		end
	end
	return false
end

local function createStationData (station)
	SpaceStation.adverts[station] = {}
	shipsOnSale[station] = {}
	visited[station] = true

	createEquipmentStock(station)
	createCommodityStock(station)

	shipsOnSale[station] = ShipDealerships.GenerateInitialInventory(station)

	Event.Queue("onCreateBB", station)
end

ensureStationData = function (station)
	if not visited[station] or not equipmentStock[station] then
		logVerbose("Lazy-creating station data for station " .. station.label)

		if visited[station] and not equipmentStock[station] then
			createEquipmentStock(station)
		else
			createStationData(station)
		end
	end
end

local function createSystem ()
	Economy.PrecacheSystem(Game.system)

	for _, path in ipairs(Game.system:GetStationPaths()) do
		marketCache[path] = Economy.InitPersistentMarket(path:GetSystemBody())
	end
end

local function destroySystem ()
	Economy.ReleaseCachedSystem(Game.system)

	equipmentStock = {}
	equipmentPrice = {}

	commodityPrice = utils.automagic()
	marketCache = {}

	visited = {}

	police = {}

	shipsOnSale = {}

	SpaceStation.lockedAdvert = nil
	SpaceStation.advertLockCount = 0
	SpaceStation.removeOnReleased = false

	for station,ads in pairs(SpaceStation.adverts) do
		for ref,ad in pairs(ads) do
			station:RemoveAdvert(ref)
		end
	end
	SpaceStation.adverts = {}
end


local loaded_data

Event.Register("_ensureDockedBB", function (station)
	if station:exists() then
		if not SpaceStation.adverts[station] then
			SpaceStation.adverts[station] = {}
			Event.Queue("onCreateBB", station)
		else
			station:CleanExpiredAdverts()
		end
	end
end)

Event.Register("onGameStart", function ()
	if (loaded_data) then
		equipmentStock = loaded_data.equipmentStock or {}
		equipmentPrice = loaded_data.equipmentPrice or {} -- handle missing in old saves
		commodityPrice = utils.automagic(loaded_data.commodityPrice)

		visited = loaded_data.visited or {}
		police = loaded_data.police or {}

		for station,_ in pairs(visited) do
			if station:exists() then
				createCommodityStock(station)
			end
		end

		for station,list in pairs(loaded_data.shipsOnSale or {}) do
			shipsOnSale[station] = {}
			for i,entry in pairs(list) do
				local def = ShipDef[entry.id]
				if (def) then
					shipsOnSale[station][i] = normalizeShipEntry({
						def          = def,
						skin         = entry.skin,
						pattern      = entry.pattern,
						label        = entry.label,
						condition    = entry.condition,
						sellerType   = entry.sellerType,
						hullPercent  = entry.hullPercent,
						flightHours  = entry.flightHours,
						hullPriceMod = entry.hullPriceMod,
						provenance   = entry.provenance,
						equipList    = entry.equipList,
					})
				end
			end
		end

		local loadedVersion = loaded_data.marketVersion or 1
		if loadedVersion < 2 then
			for station,_ in pairs(visited) do
				if station:exists() then
					equipmentStock[station] = nil
					equipmentPrice[station] = nil
					createEquipmentStock(station)
					if not shipsOnSale[station] or #shipsOnSale[station] == 0 then
						shipsOnSale[station] = ShipDealerships.GenerateInitialInventory(station)
					end
				end
			end
		end

		loaded_data = nil
	end

	createSystem()

	local station = Game.player:GetDockedWith()

	if station and station:isa("SpaceStation") then
		if not visited[station] then
			createStationData(station)
		else
			-- Defer until all modules finish onGameStart before checking if adverts were restored
			Event.Queue("_ensureDockedBB", station)
		end
	end

	if not systemUpdateTimerActive then
		systemUpdateTimerActive = true
		Timer:CallEvery(3600, updateSystem)
	end
	if not expiryTimerActive then
		expiryTimerActive = true
		Timer:CallEvery(300, function ()
			if not Game.player then
				expiryTimerActive = false
				return true
			end
			SpaceStation.CleanAllExpiredAdverts()
			return false
		end)
	end
end)

Event.Register("onPlayerDocked", function (ship, station)
	if not visited[station] then
		createStationData(station)
	else
		station:CleanExpiredAdverts()
		Economy.UpdateStationMarket(assert(station:GetSystemBody()), station:GetCommodityMarket())
	end
end, true)

Event.Register("onPlayerRescued", function (_, station)
	if station and station:exists() and station:isa("SpaceStation") then
		ensureStationData(station)
	end
end, true)

Event.Register("onEnterSystem", function(ship)
	if ship ~= Game.player then return end
	createSystem()
end)

Event.Register("onLeaveSystem", function (ship)
	destroySystem()
end)

Event.Register("onShipDestroyed", function (ship, _)
	for _,local_police in pairs(police) do
		for k,police_ship in pairs(local_police) do
			if (ship == police_ship) then
				table.remove(local_police, k)
			end
		end
	end
end)

Event.Register("onGameEnd", function ()
	expiryTimerActive = false
	systemUpdateTimerActive = false
	destroySystem()

	-- XXX clean up for next game
	nextRef = 0

	Economy.OnGameEnd()
end)


Serializer:Register("SpaceStation",
	function ()
		local data = {
			marketVersion = 2,
			equipmentStock = equipmentStock,
			equipmentPrice = equipmentPrice,
			commodityPrice = commodityPrice,
			visited = visited,
			police = police,  --todo fails if a police ship is killed
			shipsOnSale = {},
		}

		for station,list in pairs(shipsOnSale) do
			data.shipsOnSale[station] = {}
			for i,entry in pairs(list) do
				data.shipsOnSale[station][i] = {
					id           = entry.def.id,
					skin         = entry.skin,
					pattern      = entry.pattern,
					label        = entry.label,
					condition    = entry.condition,
					sellerType   = entry.sellerType,
					hullPercent  = entry.hullPercent,
					flightHours  = entry.flightHours,
					hullPriceMod = entry.hullPriceMod,
					provenance   = entry.provenance,
					equipList    = entry.equipList,
				}
			end
		end

		return data
	end,
	function (data)
		loaded_data = data
	end
)


return SpaceStation

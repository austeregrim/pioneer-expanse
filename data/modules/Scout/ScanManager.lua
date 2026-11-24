-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Event = require 'Event'
local Game = require 'Game'
local Timer = require 'Timer'
local Serializer = require 'Serializer'
local Cartography = require 'modules.Cartography.Cartography'

local utils = require 'utils'

--
-- Class: ScanManager
--
-- This file implements a generic ship component to manage and carry out
-- orbital or surface scan missions, provide a relatively realistic abstraction
-- for gathering scan data, and serve as the "backend" for a mission module
-- that generates scans and provides a reward to the player.
--
-- It does not currently have support for arbitrary player-driven scans, nor
-- is it designed to be integrated with some Point-of-Interest system to allow
-- for any kind of discovery-related gameplay. These are features that could be
-- very useful in the future, but there exists no gameplay reason to support
-- them at the time of writing
--
-- The ScanManager assumes that all sensors on the player's ship are 1D beam
-- sensors with a specified aperture and resolution. It is assumed to be able
-- to scan in all directions regardless of the player's orientation relative to
-- the surface.
--
-- Differing scanner capabilities can be provided by ship equipment. It is
-- assumed that an equipment item provides either surface scanning capability
-- or orbital scanning capability, but never both.
--
-- No attempt is made to de-duplicate the orbital coverage of a body - the
-- player can keep scanning in the exact same orbit and will gain scan data
-- at the same rate.
--
-- There is some room for future improvement of this module, as recorded in
-- these TODOs:
--
-- TODO: use either orbital inclination or player velocity relative to the
-- surface rotation of the body to modulate orbital scan data gain rate.
-- This should not be a 100% realistic factor, but provide a small bonus for
-- maneuvering to a more "interesting" orbit (e.g. 30%).
--
-- TODO: Allow defining surface or orbital scan missions to require data be
-- gathered within a certain distance of a surface location (e.g. lat/lon or a
-- SurfaceBookmark abstraction).
-- Missions of this type should have significantly lower coverage requirements.
--
-- TODO: the ScanManager should provide some sort of visual or audio feedback
-- to the player that a scan is ongoing. E.g. a "scan beam" visual element,
-- a visible sensor object on the outside of the ship, etc.
--
-- TODO: the ScanManager should be extensible to provide some kind of planetary
-- discovery scanning capaibility - hidden outposts, mineral concentrations,
-- or other procedurally-generated geological features should be able to create
-- some kind of "sensor return" that is integrated into the ScanManager.
-- This is a very low-priority feature and may require the ScanManager be
-- integrated into a larger "sensors suite" abstraction instead.

--=============================================================================

---@alias ScanID string

---@class ScanData
---@field meta table
--
---@field id ScanID
---@field bodyPath SystemPath
---@field minResolution number
---@field targetCoverage number
---@field orbital boolean
---@field coverage number
---@field complete boolean
--
local ScanData = utils.inherits(nil, "Scout.ScanData")

---@return ScanData
function ScanData.New(id, bodyPath, minResolution, minCoverage, isOrbital)
	return setmetatable({
		id = id,
		bodyPath = bodyPath,
		minResolution = minResolution,
		targetCoverage = (isOrbital and minCoverage) or 1.0,
		orbital = isOrbital or false,
		coverage = 0.0,
		complete = false
	}, ScanData.meta)
end

---@class ScanManager.SensorData
---@field resolutionMs number
---@field minAltitude number
---@field minResolution number
---@field apertureWidth number
---@field orbital boolean
---@field equip unknown

--=============================================================================

-- Update different scan types at different rates
-- TODO: these update rates cause excessive updates at high timewarp factors.
--       This especially impacts the Orbial Scans. It is proposed to replace
--       this mechanism with a timewarp-invariant timer instead.
--       See : https://github.com/pioneerspacesim/pioneer/pull/5932#discussion_r1800544550
local SURFACE_SCAN_UPDATE_RATE = 0.25
local ORBITAL_SCAN_UPDATE_RATE = 0.5

-- Square meters to square kilometers
local SQUARE_KILOMETERS = 10^6

local function makeScanID(count, path, orbital)
	return string.format("scan-%d-%s-%s", count, tostring(path), orbital and "orbit" or "surface")
end

--=============================================================================

---@class ScanManager
---@field New fun(s: Ship): ScanManager
local ScanManager = utils.class("Scout.ScanManager")

---@enum ScanManager.State
ScanManager.State = {
	Inactive = "INACTIVE",
	Scanning = "SCANNING",
	MinAltitude = "MIN_ALTITUDE",
	OutOfRange = "OUT_OF_RANGE",
	NoSensors = "NO_SENSORS",
}

---@param ship Ship
function ScanManager:Constructor(ship)
	self.ship = ship

	---@type ScanData
	self.activeScan = nil
	---@type ScanData[]
	self.pendingScans = {}
	---@type ScanData[]
	self.completedScans = {}

	---@type table<ScanID, ScanData>
	self.scanMap = {}
	self.scanId = 1

	-- The list of available sensors on this craft
	---@type ScanManager.SensorData[]
	self.sensors = {}
	-- The currently activated sensor that will be used for this scan
	---@type ScanManager.SensorData?
	self.activeSensor = nil

	-- is the ship's current position within viable scan parameters?
	self.withinParameters = false

	-- calculate the distance the ship has moved since the last scan step
	---@type Vector3
	self.lastScanPos = nil

	-- is there a currently running scan callback
	self.activeCallback = false

	-- Autopilot Mk 4 autonomous survey state
	self.autoSurveyActive = false
	self.autoSurveyTimerActive = false
	self.autoSurveyEngagedSC = false

	self:SetupShipEquipListener()
end

---@package
-- Register an equipment listener on the player's ship
function ScanManager:SetupShipEquipListener()
	self.ship:GetComponent("EquipSet"):AddListener(function(_, equip, slot)
		if equip.slot and equip.slot.type:match("utility.scanner.planet") then
			self:UpdateSensorEquipInfo()
		end
	end)

	self:UpdateSensorEquipInfo()
end

---@private
-- Scan the ship's equipment and determine its sensor capabilities
-- Note: this function completely rebuilds the list of sensors when a sensor equipment item is changed on the ship
function ScanManager:UpdateSensorEquipInfo()
	local equip = self.ship:GetComponent("EquipSet")

	self.sensors = {}

	local sensors = equip:GetInstalledOfType("utility.scanner.planet")

	if #sensors == 0 then
		self.activeSensor = nil
		self:ClearActiveScan()
		return
	end

	-- rebuild the list of sensors from the ship's equipment
	-- we don't attempt to preserve the existing list because we have no idea
	-- which sensor was added/removed and where
	for i, sensor in ipairs(sensors) do
		local sensorData = {}

		-- width of the aperture at one meter
		sensorData.apertureWidth = math.tan(math.deg2rad(sensor.stats.aperture) * 0.5) * 2
		-- resolution in meters / sample at one meter
		sensorData.resolutionMs = sensorData.apertureWidth / sensor.stats.resolution
		-- minimum altitude required to get sensor data
		sensorData.minAltitude = sensor.stats.minAltitude
		-- minimum effective resolution of sensor data
		sensorData.minResolution = sensorData.resolutionMs * sensorData.minAltitude
		-- is the sensor a surface or orbital scanner?
		sensorData.orbital = sensor.stats.orbital or false

		sensorData.equip = sensor

		table.insert(self.sensors, sensorData)

		if self.activeSensor and self.activeSensor.equip == sensor then
			self.activeSensor = sensorData
		end
	end

	-- if the old active sensor is no longer present on the craft, default to
	-- the first sensor in the list if any
	if not (self.activeSensor and utils.contains(sensors, self.activeSensor.equip)) then
		self.activeSensor = self.sensors[1]
		self:ClearActiveScan()
	end

end

---@param scan ScanData?
---@return Body?
function ScanManager:GetScanBodyByType(scan)
	scan = scan or self.activeScan
	assert(scan, "ScanManager:GetScanBodyByType: Error: scan was nil")
	assert(self.scanMap[scan.id], "ScanManager:GetScanBodyByType: Error: scan doesn't belong to current ScanManager")
	local sbody = scan.bodyPath:GetSystemBody()
	return sbody and sbody.body or nil
end

---@param body Body
---@param scan ScanData?
---@return number altitude
---@return number resolution
function ScanManager:GetBodyState(body, scan)
	scan = scan or self.activeScan
	assert(scan, "ScanManager:GetBodyState: Error: scan was nil")
	assert(self.scanMap[scan.id], "ScanManager:GetBodyState: Error: scan doesn't belong to current ScanManager")
	assert(self.activeSensor, "ScanManager:GetBodyState(): have an active scan without an onboard sensor")

	local altitude
	local radius = body:GetSystemBody().radius

	if scan.orbital then
		-- altitude above sea-level
		altitude = self.ship:GetPositionRelTo(body):length() - radius
	else
		-- altitude above terrain
		altitude = self.ship:GetAltitudeRelTo(body)
	end

	-- calculate effective resolution in meters/sample at this altitude
	local resolution = self.activeSensor.resolutionMs * altitude
	return altitude, resolution
end

--=============================================================================

function ScanManager:GetActiveSensor()
	return self.activeSensor
end

function ScanManager:GetAvailableSensors()
	return self.sensors
end

local SURFACE_VISIBILITY_DOT = 0.35
local SURFACE_COMPLETE_COVERAGE = 0.85

local function getSurfaceGridDimensions(body)
	local sbody = body and body:GetSystemBody()
	local r = sbody and sbody.radius or 6371000
	-- Scale grid resolution with body radius:
	-- Small asteroids/moons: nlat = 10, nlon = 20 (chunky/large triangles)
	-- Earth (~6371km): nlat = 18, nlon = 36 (fine/detailed triangles)
	-- Giants (>=20,000km): nlat = 26, nlon = 52 (dense, high-detail triangles)
	local nlat = math.clamp(math.floor(10 + math.sqrt(math.min(r, 50000000) / 50000000) * 16), 10, 28)
	local nlon = nlat * 2
	return nlat, nlon
end

local function generateSphereNormals(nlat, nlon)
	local normals = {}
	for i = 0, nlat - 1 do
		local lat = -0.5 * math.pi + math.pi * ((i + 0.5) / nlat)
		local clat = math.cos(lat)
		local slat = math.sin(lat)
		for j = 0, nlon - 1 do
			local lon = 2.0 * math.pi * ((j + 0.5) / nlon)
			normals[i * nlon + j + 1] = Vector3(clat * math.cos(lon), slat, clat * math.sin(lon))
		end
	end
	return normals
end

local function getOrbitalScanDuration(body)
	local sbody = body and body:GetSystemBody()
	local r = sbody and sbody.radius or 6371000
	-- Scaled duration based on radius: min 5s, max 45s
	return math.min(45.0, 5.0 + 40.0 * math.sqrt(math.min(r, 70000000) / 70000000))
end

local function getScanMaxDistance(body, isOrbital)
	local radius = body:GetSystemBody().radius
	if isOrbital then
		return math.max(radius * 12.0, 24000000)
	else
		return math.max(radius * 4.0, 8000000)
	end
end

ScanManager.GetScanMaxDistance = getScanMaxDistance

function ScanManager:HasSensorOfType(isOrbital)
	for _, s in ipairs(self.sensors) do
		if s.orbital == isOrbital then
			return true
		end
	end
	return false
end

function ScanManager:GetSensorForType(isOrbital)
	for idx, s in ipairs(self.sensors) do
		if s.orbital == isOrbital then
			return s, idx
		end
	end
	return nil, nil
end

function ScanManager:HasSensorForScan(scan)
	if not scan then return false end
	for idx, s in ipairs(self.sensors) do
		if s.orbital == scan.orbital then
			if scan.freeScan or (s.minResolution <= scan.minResolution) then
				return true, idx
			end
		end
	end
	return false, nil
end

local function isSameBodyPath(p1, p2)
	if not p1 or not p2 then return false end
	if p1 == p2 then return true end
	return tostring(p1) == tostring(p2)
end

local function insertScanGrouped(self, scanData)
	for idx, existing in ipairs(self.pendingScans) do
		if isSameBodyPath(existing.bodyPath, scanData.bodyPath) then
			if scanData.orbital and not existing.orbital then
				table.insert(self.pendingScans, idx, scanData)
			else
				table.insert(self.pendingScans, idx + 1, scanData)
			end
			return
		end
	end
	table.insert(self.pendingScans, scanData)
end

function ScanManager:GetScanStatusForBody(bodyPath, isOrbital)
	if self.activeScan and isSameBodyPath(self.activeScan.bodyPath, bodyPath) and self.activeScan.orbital == isOrbital then
		return "ACTIVE", self.activeScan
	end
	for _, s in ipairs(self.pendingScans) do
		if isSameBodyPath(s.bodyPath, bodyPath) and s.orbital == isOrbital then
			return "QUEUED", s
		end
	end
	for _, s in ipairs(self.completedScans) do
		if isSameBodyPath(s.bodyPath, bodyPath) and s.orbital == isOrbital then
			return "COMPLETED", s
		end
	end
	return nil, nil
end

---@return ScanManager.State
function ScanManager:GetState()
	if not self.activeSensor then
		return self.State.NoSensors
	end

	if self.activeScan then
		local body = self:GetScanBodyByType()
		if not body then
			return self.State.OutOfRange
		end

		local dist = self.ship:GetPositionRelTo(body):length()
		local altitude = self:GetBodyState(body)
		local maxDist = getScanMaxDistance(body, self.activeScan.orbital)
		local isInRange = dist <= maxDist

		if altitude > self.activeSensor.minAltitude then
			return isInRange and self.State.Scanning or self.State.OutOfRange
		else
			return self.State.MinAltitude
		end
	else
		return self.State.Inactive
	end
end

-- Determine if the given scan can be carried out by the selected sensor,
-- and the maximum allowable mission parameters for the scan
---@param sBody SystemBody body to be scanning
---@param maxResolution number maximum scan resolution allowed, effectively meters/sample
function ScanManager:GetScanParameters(sBody, maxResolution, orbital, sensorIndex)
	local sensor = sensorIndex and self.sensors[sensorIndex] or self.activeSensor
	if not sensor then return nil end

	-- sensor cannot carry out this mission
	if not sensor.orbital == orbital then return nil end

	-- maximum altitude for the given resolution
	local maxAlt = maxResolution / sensor.resolutionMs
	-- one-half circumference due to orbit covering the entire sphere
	local bodyHalfCirc = sBody.radius * math.pi

	-- Amount of body coverage per orbit
	-- Math is a little bit cheat-y here, would be better to use great circle distance rather than straight-line
	local coverage = sensor.apertureWidth * maxAlt
	-- number of orbits required to achieve full coverage of the body
	local orbitToCov = bodyHalfCirc / coverage

	return {
		-- whether the given scan can actually be carried out
		canScan = maxAlt > sensor.minAltitude and sensor.minResolution <= maxResolution,
		-- the maximum altitude the ship can fly at to scan the body
		maxAltitude = maxAlt,
		-- the minimum altitude the ship can fly at to scan the body
		minAltitude = sensor.minAltitude,
		-- the number of orbits at maximum altitude required to fully cover the body
		orbitsToCover = orbitToCov
	}
end

-- Return the list of pending scans for display purposes.
---@return ScanData[]
function ScanManager:GetPendingScans()
	return self.pendingScans
end

-- Return the list of completed scans for display purposes.
---@return ScanData[]
function ScanManager:GetCompletedScans()
	return self.completedScans
end

-- Return the active scan for display purposes.
---@return ScanData?
function ScanManager:GetActiveScan()
	return self.activeScan
end

--=============================================================================

-- Add a new surface scan mission profile to the scan manager.
-- Allows the ship's scanner(s) to begin gathering data once the scan is activated.
---@param bodyPath SystemPath path of the body to scan
---@param minResolution number minimum scanner resolution required to accept scan data
---@param requiredCoverage number how many square kilometers need to be covered for this scan to be considered complete
---@return ScanID ID used to look up the resulting scan datum
function ScanManager:AddNewSurfaceScan(bodyPath, minResolution, requiredCoverage)
	local id = makeScanID(self.scanId, bodyPath, false)
	self.scanId = self.scanId + 1

	local scanData = ScanData.New(id, bodyPath, minResolution, 1.0, false)

	self.scanMap[id] = scanData
	insertScanGrouped(self, scanData)

	return id
end

-- Add a new orbital scan mission profile to the scan manager.
-- Allows the ship's scanner(s) to begin gathering data once the scan is activated.
---@param bodyPath SystemPath path of the body to scan
---@param minResolution number minimum scanner resolution required to accept scan data
---@param requiredCoverage number the percentage of the body's surface that needs to be scanned
---@return ScanID ID used to look up the resulting scan datum
function ScanManager:AddNewOrbitalScan(bodyPath, minResolution, requiredCoverage)
	local id = makeScanID(self.scanId, bodyPath, true)
	self.scanId = self.scanId + 1

	local scanData = ScanData.New(id, bodyPath, minResolution, requiredCoverage, true)

	self.scanMap[id] = scanData
	insertScanGrouped(self, scanData)

	return id
end

-- Set the given sensor as the currently active data-source
function ScanManager:SetActiveSensor(index)
	local sensor = self.sensors[index]
	if not sensor then return false end

	self.activeSensor = sensor

	if self.activeScan and self.activeScan.orbital ~= self.activeSensor.orbital then
		self:ClearActiveScan()
	end
end

-- Set the given scan ID as the current scan
---@param id ScanID
function ScanManager:SetActiveScan(id)
	local scan = self.scanMap[id]

	if not scan or scan.complete or self.activeScan == scan then
		return
	end

	local hasSensor, sensorIdx = self:HasSensorForScan(scan)
	if not hasSensor then
		return
	end

	-- Auto-select matching sensor if current active sensor differs
	if not self.activeSensor or self.activeSensor.orbital ~= scan.orbital then
		self:SetActiveSensor(sensorIdx)
	end

	if not self:CanScanBeActivated(id) then
		return
	end

	utils.remove_elem(self.pendingScans, scan)
	if self.activeScan then
		table.insert(self.pendingScans, self.activeScan)
		Event.Queue("onScanPaused", self.ship, self.activeScan.id)
	end

	self.activeScan = scan
	self.withinParameters = false

	self:StartScanCallback()
end

-- Start or queue a free-target cartography scan on a body (without a Scout mission)
---@param body Body
---@param isOrbital boolean
---@return ScanID? id, string? errReason
function ScanManager:StartFreeScan(body, isOrbital)
	if not body or not Game.system then return nil, "INVALID_BODY" end
	if not (body.isa and body:isa("Body")) then return nil, "INVALID_BODY" end
	local sbody = body:GetSystemBody()
	if not sbody or sbody.superType == "STARPORT" then return nil, "INVALID_BODY" end
	if not isOrbital and (sbody.superType == "STAR" or sbody.type == "PLANET_GAS_GIANT") then
		return nil, "NO_SURFACE"
	end
	if Cartography.HasUnsoldScan(body, isOrbital) then
		return nil, "ALREADY_STORED"
	end

	-- If already the active scan, keep it
	if self.activeScan and isSameBodyPath(self.activeScan.bodyPath, body.path) and self.activeScan.orbital == isOrbital then
		return self.activeScan.id
	end

	-- Reuse existing pending scan for this body/mode if any
	for _, s in ipairs(self.pendingScans) do
		if isSameBodyPath(s.bodyPath, body.path) and s.orbital == isOrbital then
			if not self.activeScan then
				local _, sensorIdx = self:GetSensorForType(isOrbital)
				if sensorIdx then
					self:SetActiveSensor(sensorIdx)
					if self:CanScanBeActivated(s.id) then
						self:SetActiveScan(s.id)
					end
				end
			end
			return s.id
		end
	end

	local id = makeScanID(self.scanId, body.path, isOrbital)
	self.scanId = self.scanId + 1

	local targetCov = 1.0
	local scanData = ScanData.New(id, body.path, 1e9, targetCov, isOrbital)
	scanData.freeScan = true
	self.scanMap[id] = scanData
	insertScanGrouped(self, scanData)

	-- If we have no active scan, auto-select sensor and activate immediately!
	if not self.activeScan then
		local _, sensorIdx = self:GetSensorForType(isOrbital)
		if sensorIdx then
			self:SetActiveSensor(sensorIdx)
			if self:CanScanBeActivated(id) then
				self:SetActiveScan(id)
			end
		end
	end

	return id
end

-- Move all scans for the given body to the top of the queue (Orbital before Surface) and activate
---@param body Body
---@return boolean success
function ScanManager:PrioritizeBodyInQueue(body)
	if not body or not body.path then return false end

	local bodyPending = {}
	local others = {}
	for _, s in ipairs(self.pendingScans) do
		if isSameBodyPath(s.bodyPath, body.path) then
			table.insert(bodyPending, s)
		else
			table.insert(others, s)
		end
	end

	table.sort(bodyPending, function(a, b)
		if a.orbital ~= b.orbital then
			return a.orbital == true
		end
		return false
	end)

	if self.activeScan and isSameBodyPath(self.activeScan.bodyPath, body.path) then
		if #bodyPending > 0 then
			self.pendingScans = {}
			for _, s in ipairs(bodyPending) do table.insert(self.pendingScans, s) end
			for _, s in ipairs(others) do table.insert(self.pendingScans, s) end
		end
		return true
	end

	if #bodyPending == 0 then
		return false
	end

	self.pendingScans = {}
	for _, s in ipairs(bodyPending) do table.insert(self.pendingScans, s) end
	for _, s in ipairs(others) do table.insert(self.pendingScans, s) end

	for _, s in ipairs(bodyPending) do
		if self:CanScanBeActivated(s.id) then
			self:SetActiveScan(s.id)
			return true
		end
	end
	return true
end

-- Helper to rebuild active/pending scan slots from a flat ordered array
function ScanManager:applyQueueOrder(ordered)
	local firstScan = ordered[1]
	self.pendingScans = {}
	for i = 2, #ordered do
		table.insert(self.pendingScans, ordered[i])
	end

	if self.activeScan and self.activeScan ~= firstScan then
		Event.Queue("onScanPaused", self.ship, self.activeScan.id)
		self.activeScan = nil
		self.activeCallback = nil
		self.withinParameters = false
		Game.SetSurfaceScanOverlay(nil)
	end

	if not firstScan or self.activeScan == firstScan then
		return
	end

	if self:CanScanBeActivated(firstScan.id) then
		local _, sensorIdx = self:HasSensorForScan(firstScan)
		if sensorIdx and (not self.activeSensor or self.activeSensor.orbital ~= firstScan.orbital) then
			self:SetActiveSensor(sensorIdx)
		end
		self.activeScan = firstScan
		self.withinParameters = false
		self:StartScanCallback()
	else
		table.insert(self.pendingScans, 1, firstScan)
	end
end

-- Group and optionally resort all queued scans by body so orbital & surface scans stay paired
---@param sortMode string? "body" | "distance" | "name"
function ScanManager:GroupQueueByBody(sortMode)
	local all = {}
	if self.activeScan then
		table.insert(all, self.activeScan)
	end
	for _, s in ipairs(self.pendingScans) do
		table.insert(all, s)
	end
	if #all <= 1 then return end

	local groups = {}
	local groupMap = {}
	local curSysPath = Game.system and Game.system.path
	for idx, s in ipairs(all) do
		local key = tostring(s.bodyPath)
		local g = groupMap[key]
		if not g then
			local sb = s.bodyPath.GetSystemBody and s.bodyPath:GetSystemBody()
			local body = self:GetScanBodyByType(s)
			local inCurSys = (curSysPath and s.bodyPath.IsSameSystem and s.bodyPath:IsSameSystem(curSysPath)) or (body ~= nil)
			local dist = (body and self.ship) and self.ship:GetPositionRelTo(body):length() or math.huge
			g = {
				key = key,
				firstIdx = idx,
				inCurSys = inCurSys and 0 or 1,
				dist = dist,
				name = string.lower((sb and sb.name) or key),
				scans = {},
			}
			groupMap[key] = g
			table.insert(groups, g)
		end
		table.insert(g.scans, s)
	end

	for _, g in ipairs(groups) do
		table.sort(g.scans, function(a, b)
			if a.orbital ~= b.orbital then
				return a.orbital == true
			end
			return false
		end)
	end

	table.sort(groups, function(a, b)
		if a.inCurSys ~= b.inCurSys then
			return a.inCurSys < b.inCurSys
		end
		if sortMode == "distance" then
			if a.dist ~= b.dist then return a.dist < b.dist end
		elseif sortMode == "name" then
			if a.name ~= b.name then return a.name < b.name end
		end
		if a.firstIdx ~= b.firstIdx then
			return a.firstIdx < b.firstIdx
		end
		return false
	end)

	local ordered = {}
	for _, g in ipairs(groups) do
		for _, s in ipairs(g.scans) do
			table.insert(ordered, s)
		end
	end
	self:applyQueueOrder(ordered)
end

-- Move an individual scan up (delta < 0) or down (delta > 0) in the queue
function ScanManager:MoveScanInQueue(scanId, delta)
	local all = {}
	if self.activeScan then table.insert(all, self.activeScan) end
	for _, s in ipairs(self.pendingScans) do table.insert(all, s) end

	local curIdx = nil
	for i, s in ipairs(all) do
		if s.id == scanId then curIdx = i; break end
	end
	if not curIdx then return false end

	local newIdx = math.clamp(curIdx + (delta < 0 and -1 or 1), 1, #all)
	if newIdx == curIdx then return false end

	local elem = table.remove(all, curIdx)
	table.insert(all, newIdx, elem)
	self:applyQueueOrder(all)
	return true
end

-- Move all scans for a given bodyPath together up or down past the neighboring body group
function ScanManager:MoveBodyGroupInQueue(bodyPath, delta)
	self:GroupQueueByBody("body")
	local all = {}
	if self.activeScan then table.insert(all, self.activeScan) end
	for _, s in ipairs(self.pendingScans) do table.insert(all, s) end
	if #all <= 1 then return false end

	local groups = {}
	local curKey = nil
	local targetGroupIdx = nil
	for _, s in ipairs(all) do
		local k = tostring(s.bodyPath)
		if k ~= curKey then
			curKey = k
			table.insert(groups, { key = k, scans = {} })
			if isSameBodyPath(s.bodyPath, bodyPath) then
				targetGroupIdx = #groups
			end
		end
		table.insert(groups[#groups].scans, s)
	end
	if not targetGroupIdx then return false end

	local newGIdx = math.clamp(targetGroupIdx + (delta < 0 and -1 or 1), 1, #groups)
	if newGIdx == targetGroupIdx then return false end

	local grp = table.remove(groups, targetGroupIdx)
	table.insert(groups, newGIdx, grp)

	local ordered = {}
	for _, g in ipairs(groups) do
		for _, s in ipairs(g.scans) do table.insert(ordered, s) end
	end
	self:applyQueueOrder(ordered)
	return true
end

-- Cancel all free survey scans while preserving mission contract scans
function ScanManager:ClearFreeScans()
	local toCancel = {}
	if self.activeScan and self.activeScan.freeScan then
		table.insert(toCancel, self.activeScan.id)
	end
	for _, s in ipairs(self.pendingScans) do
		if s.freeScan then
			table.insert(toCancel, s.id)
		end
	end
	for _, id in ipairs(toCancel) do
		self:CancelScan(id)
	end
	if #toCancel > 0 and self.autoSurveyActive and not self.activeScan and #self.pendingScans == 0 then
		self:SetAutoSurveyActive(false)
	end
end

-- Automatically activate the next scan in the queue if one is viable
function ScanManager:AdvanceQueue()
	if self.activeScan then return false end
	for _, s in ipairs(self.pendingScans) do
		if self:CanScanBeActivated(s.id) then
			self:SetActiveScan(s.id)
			local body = self:GetScanBodyByType(s)
			if body and self.ship == Game.player then
				self.ship:SetNavTarget(body)
			end
			return true
		end
	end
	return false
end

-- Clear the currently active scan and running callback
function ScanManager:ClearActiveScan()
	if self.activeScan then
		local paused = self.activeScan
		local inserted = false
		for idx, existing in ipairs(self.pendingScans) do
			if isSameBodyPath(existing.bodyPath, paused.bodyPath) then
				if paused.orbital and not existing.orbital then
					table.insert(self.pendingScans, idx, paused)
				else
					table.insert(self.pendingScans, idx + 1, paused)
				end
				inserted = true
				break
			end
		end
		if not inserted then
			table.insert(self.pendingScans, 1, paused)
		end
		Event.Queue("onScanPaused", self.ship, paused.id)
	end

	self.activeScan = nil
	self.activeCallback = nil
	self.withinParameters = false
	Game.SetSurfaceScanOverlay(nil)
end

-- Check if the given scan is within viable parameters (e.g. in correct star system)
---@param id ScanID id of the scan to activate
---@return boolean
function ScanManager:CanScanBeActivated(id)
	local scan = self.scanMap[id]
	if not scan or scan.complete then return false end

	local hasSensor = self:HasSensorForScan(scan)
	if not hasSensor then return false end

	local body = self:GetScanBodyByType(scan)
	if not body then return false end

	if not isSameBodyPath(body.path, scan.bodyPath) then
		return false
	end

	return true
end

-- Remove a completed scan from the scanner's data storage
---@param id unknown an ID returned from AddNewScan
---@return ScanData? scan the completed scan data
---@nodiscard
function ScanManager:AcceptScanComplete(id)
	local scan = self.scanMap[id]

	if not scan or not scan.complete then
		return nil
	end

	self.scanMap[id] = nil
	utils.remove_elem(self.completedScans, scan)

	return scan
end

-- Cancel a pending or active scan completely (e.g. mission failure or player survey discard)
---@param id unknown an ID returned from AddNewScan
---@return ScanData? scan the completed scan data
---@nodiscard
function ScanManager:CancelScan(id)
	local scan = self.scanMap[id]

	if not scan or scan.complete then
		return nil
	end

	self.scanMap[id] = nil

	if scan == self.activeScan then
		self.activeScan = nil
		self.activeCallback = nil
		self.withinParameters = false
		Game.SetSurfaceScanOverlay(nil)
	else
		utils.remove_elem(self.pendingScans, scan)
	end

	return scan
end

--=============================================================================

-- Triggered when the ship has entered a new frame, updates active scan
---@param body Body
---@package
function ScanManager:OnEnteredFrame(body)
	-- Scans work in Supercruise and across frames now; nothing to cancel on frame change
end

-- Start the scanner callback
---@param force boolean?
---@package
function ScanManager:StartScanCallback(force)
	local updateRate = self.activeScan.orbital and ORBITAL_SCAN_UPDATE_RATE or SURFACE_SCAN_UPDATE_RATE

	-- Immediately trigger a scan update for responsiveness
	self:OnUpdateScan(self.activeScan)

	-- Don't queue a new scan callback if we're already running one at the right frequency
	-- Force this check if this function was called from ScanManager:Unserialize() because
	-- callback is not yet setted up
	if updateRate == self.activeCallback and not force then
		return
	end

	self.activeCallback = updateRate

	Timer:CallEvery(updateRate, function()
		-- cancel this callback if the parameters have changed (it's been orphaned)
		if not self.activeScan or not self.activeSensor or self.activeCallback ~= updateRate then
			return true
		end

		return self:OnUpdateScan(self.activeScan)

	end)
end

-- Update the current active scan, assuming we're in the correct frame
---@param scan ScanData
---@return boolean cancel
---@package
function ScanManager:OnUpdateScan(scan)
	local body = self:GetScanBodyByType(scan)

	-- Somehow we don't have a valid body to be scanning
	if not body then
		logWarning("ScanManager: owning ship does not have a system body to scan!")
		self:ClearActiveScan()
		return true
	end

	local altitude = self:GetBodyState(body)
	local relPos = self.ship:GetPositionRelTo(body)
	local dist = relPos:length()
	local maxDist = getScanMaxDistance(body, scan.orbital)
	local withinParams = dist <= maxDist and altitude > self.activeSensor.minAltitude

	if scan.orbital then
		Game.SetSurfaceScanOverlay(nil)
		if withinParams then
			if not self.withinParameters then
				Event.Queue("onScanRangeEnter", self.ship, scan.id)
			end
			self.withinParameters = true

			if not scan.scanDuration then
				scan.scanDuration = getOrbitalScanDuration(body)
				scan.elapsedTime = 0.0
			end

			local dt = ORBITAL_SCAN_UPDATE_RATE
			scan.elapsedTime = (scan.elapsedTime or 0.0) + dt
			scan.coverage = math.min(scan.targetCoverage, scan.targetCoverage * (scan.elapsedTime / scan.scanDuration))

			if scan.coverage >= scan.targetCoverage or scan.elapsedTime >= scan.scanDuration then
				scan.coverage = scan.targetCoverage
				scan.complete = true
				self.activeScan = nil
				self.activeCallback = nil
				self.withinParameters = false

				if scan.freeScan then
					Cartography.RecordBodyScan(body, true)
				else
					table.insert(self.completedScans, scan)
				end
				Event.Queue("onScanComplete", self.ship, scan.id)
				self:AdvanceQueue()
				return true
			end
			return false
		else
			if self.withinParameters then
				Event.Queue("onScanRangeExit", self.ship, scan.id)
			end
			self.withinParameters = false
			return false
		end
	end

	-- Surface scan: 3D sphere coverage tracking (completes at 85% surface seen)
	if not scan.surfaceGrid or not scan.normals then
		local nlat, nlon = getSurfaceGridDimensions(body)
		scan.nlat = nlat
		scan.nlon = nlon
		scan.totalCells = nlat * nlon
		scan.surfaceGrid = {}
		for k = 1, scan.totalCells do
			scan.surfaceGrid[k] = "0"
		end
		scan.normals = generateSphereNormals(nlat, nlon)
		scan.scannedCells = 0
	end

	if withinParams then
		if not self.withinParameters then
			Event.Queue("onScanRangeEnter", self.ship, scan.id)
		end

		local shipDir = relPos:normalized()
		local grid = scan.surfaceGrid
		local count = scan.scannedCells or 0
		local totalCells = scan.totalCells or #grid

		for k = 1, totalCells do
			if grid[k] == "0" and scan.normals[k]:dot(shipDir) >= SURFACE_VISIBILITY_DOT then
				grid[k] = "1"
				count = count + 1
			end
		end

		scan.scannedCells = count
		local rawCoverage = count / totalCells
		scan.targetCoverage = 1.0

		if rawCoverage >= SURFACE_COMPLETE_COVERAGE then
			scan.coverage = 1.0
			scan.complete = true
			self.activeScan = nil
			self.activeCallback = nil
			self.withinParameters = false
			Game.SetSurfaceScanOverlay(nil)

			if scan.freeScan then
				Cartography.RecordBodyScan(body, false)
			else
				table.insert(self.completedScans, scan)
			end
			Event.Queue("onScanComplete", self.ship, scan.id)
			self:AdvanceQueue()
			return true
		else
			scan.coverage = rawCoverage
			Game.SetSurfaceScanOverlay(body, true, rawCoverage, table.concat(grid))
		end
	else
		if self.withinParameters then
			Event.Queue("onScanRangeExit", self.ship, scan.id)
		end
		-- Hide 3D grid sphere highlight when leaving scan range
		Game.SetSurfaceScanOverlay(nil)
	end

	self.withinParameters = withinParams
	return false
end

--=============================================================================
-- Autopilot Mk 4: Autonomous Multi-Planet Supercruise Survey Orchestrator
--=============================================================================

function ScanManager:HasAutoSurveyModule()
	return self.ship and self.ship.GetSupercruiseAssistLevel and self.ship:GetSupercruiseAssistLevel() >= 3
end

function ScanManager:IsAutoSurveyActive()
	return self.autoSurveyActive == true
end

function ScanManager:GetRecommendedScanOrbitRadius(body, isOrbital)
	local sbody = body and body:GetSystemBody()
	local r = sbody and sbody.radius or 6371000
	local maxDist = getScanMaxDistance(body, isOrbital)
	if isOrbital then
		if sbody and sbody.superType == "STAR" then
			return math.min(maxDist * 0.65, math.max(r * 3.5, 2500000))
		end
		return math.min(maxDist * 0.65, math.max(r * 2.8, 1200000))
	else
		return math.min(maxDist * 0.60, math.max(r * 2.2, 600000))
	end
end

function ScanManager:UpdateAutoSurvey()
	if not self.autoSurveyActive then
		self.autoSurveyTimerActive = false
		return true
	end

	local ship = self.ship
	if not ship or not ship:exists() or ship ~= Game.player or (Game.InHyperspace and Game.InHyperspace()) then
		self.autoSurveyActive = false
		self.autoSurveyTimerActive = false
		return true
	end

	local fs = ship:GetFlightState()
	if fs == "DOCKED" or fs == "LANDED" or not self:HasAutoSurveyModule() or (ship.IsBeingInterdicted and ship:IsBeingInterdicted()) then
		self:SetAutoSurveyActive(false)
		return true
	end

	-- Respect manual disengagement: once SC/charging started, if player drops out or toggles SC Assist off, yield control
	if self.autoSurveyEngagedSC then
		local inSC = ship.IsSupercruiseActive and ship:IsSupercruiseActive()
		local charging = ship.IsSupercruiseCharging and ship:IsSupercruiseCharging()
		local surveyOrbitOn = ship.IsSurveyOrbitActive and ship:IsSurveyOrbitActive()
		if (not inSC and not charging) or (inSC and not surveyOrbitOn) then
			self.autoSurveyActive = false
			self.autoSurveyTimerActive = false
			self.autoSurveyEngagedSC = false
			return true
		end
	end

	if not self.activeScan then
		self:AdvanceQueue()
	end

	local scan = self.activeScan
	if not scan then
		if ship.ClearSurveyOrbit then ship:ClearSurveyOrbit() end
		if ship.IsSupercruiseActive and ship:IsSupercruiseActive() and ship.SetSupercruiseThrottle then
			ship:SetSupercruiseThrottle(0.0)
		end
		self.autoSurveyActive = false
		self.autoSurveyTimerActive = false
		self.autoSurveyEngagedSC = false
		if Game.AddCommsLogLine then
			Game.AddCommsLogLine("Autopilot Mk 4: Auto-Survey complete — all queued system scans finished.")
		end
		return true
	end

	local body = self:GetScanBodyByType(scan)
	if not body then
		-- Next scan is in a different star system; pause auto-survey cleanly
		self:SetAutoSurveyActive(false)
		return true
	end

	local polarSweep = not scan.orbital
	local targetR = self:GetRecommendedScanOrbitRadius(body, scan.orbital)
	local curSurveyOn = ship.IsSurveyOrbitActive and ship:IsSurveyOrbitActive()
	local curTarget = ship:GetNavTarget()

	if (not curSurveyOn) or (curTarget ~= body) or (self._lastAutoSurveyScanId ~= scan.id) then
		self._lastAutoSurveyScanId = scan.id
		if ship.SetSurveyOrbitTarget then
			local ok = ship:SetSurveyOrbitTarget(body, targetR, polarSweep)
			if not ok then
				self.autoSurveyActive = false
				self.autoSurveyTimerActive = false
				return true
			end
		end
	end

	if (ship.IsSupercruiseActive and ship:IsSupercruiseActive()) or (ship.IsSupercruiseCharging and ship:IsSupercruiseCharging()) then
		self.autoSurveyEngagedSC = true
	end

	return false
end

function ScanManager:SetAutoSurveyActive(enabled)
	if not enabled then
		self.autoSurveyActive = false
		self.autoSurveyEngagedSC = false
		self._lastAutoSurveyScanId = nil
		if self.ship and self.ship.ClearSurveyOrbit and self.ship:IsSurveyOrbitActive() then
			self.ship:ClearSurveyOrbit()
		end
		return false
	end

	if not self:HasAutoSurveyModule() then
		return false
	end
	if Game.InHyperspace and Game.InHyperspace() then
		return false
	end
	local fs = self.ship and self.ship:GetFlightState()
	if fs == "DOCKED" or fs == "LANDED" then
		return false
	end

	if not self.activeScan then
		self:AdvanceQueue()
	end
	if not self.activeScan then
		return false
	end

	self.autoSurveyActive = true
	self.autoSurveyEngagedSC = (self.ship.IsSupercruiseActive and self.ship:IsSupercruiseActive()) or false
	self._lastAutoSurveyScanId = nil
	self:UpdateAutoSurvey()

	if self.autoSurveyActive and not self.autoSurveyTimerActive then
		self.autoSurveyTimerActive = true
		Timer:CallEvery(0.5, function()
			return self:UpdateAutoSurvey()
		end)
	end
	return self.autoSurveyActive
end

function ScanManager:ToggleAutoSurvey()
	return self:SetAutoSurveyActive(not self.autoSurveyActive)
end

--=============================================================================

function ScanManager:Unserialize()
	setmetatable(self, ScanManager.meta)

	-- FIXME: the order of component deserialization is undefined
	-- The Unserialize() method should only mutate this component's state;
	-- these calls should be deferred into a PostLoad() method or event
	self:SetupShipEquipListener()

	-- Migrate and sanitize any existing surface scans from prior versions:
	-- Shows true percentage scanned, completing at 85% raw coverage (marking 100% on complete).
	local function migrateScan(scan)
		if not scan then return end
		if not scan.orbital or scan.freeScan then
			scan.targetCoverage = 1.0
		end
		if not scan.orbital then
			if scan.scannedCells and scan.totalCells and scan.totalCells > 0 then
				local rawRatio = scan.scannedCells / scan.totalCells
				if rawRatio >= SURFACE_COMPLETE_COVERAGE then
					scan.coverage = 1.0
					scan.complete = true
				else
					scan.coverage = rawRatio
				end
			elseif scan.coverage then
				if scan.coverage >= SURFACE_COMPLETE_COVERAGE then
					scan.coverage = 1.0
					scan.complete = true
				end
			end
		end
	end

	if self.scanMap then
		for _, s in pairs(self.scanMap) do
			migrateScan(s)
		end
	end
	if self.pendingScans then
		local pendingClean = {}
		for _, s in ipairs(self.pendingScans) do
			migrateScan(s)
			if s.complete then
				local b = self:GetScanBodyByType(s)
				if b and s.freeScan then
					Cartography.RecordBodyScan(b, false)
				end
			else
				table.insert(pendingClean, s)
			end
		end
		self.pendingScans = pendingClean
	end
	if self.activeScan then
		migrateScan(self.activeScan)
		if self.activeScan.complete then
			local b = self:GetScanBodyByType(self.activeScan)
			if b and self.activeScan.freeScan then
				Cartography.RecordBodyScan(b, false)
			end
			self.activeScan = nil
			self.activeCallback = nil
			self.withinParameters = false
			Game.SetSurfaceScanOverlay(nil)
			self:AdvanceQueue()
		end
	end

	-- Restore the scanning callback on loading a saved game
	if self.activeCallback and self.activeScan then
		self:StartScanCallback(true)
	end

	return self
end

Serializer:RegisterClass('Scout.ScanData', ScanData)
Serializer:RegisterClass('Scout.ScanManager', ScanManager)

---@param body Body
Event.Register("onFrameChanged", function(body)
	local scanMgr = body:GetComponent("ScanManager")

	if scanMgr then
		scanMgr:OnEnteredFrame(body)
	end
end)

---@param ship Ship
Event.Register("onShipTypeChanged", function(ship)
	local scanMgr = ship:GetComponent("ScanManager")

	if scanMgr then
		scanMgr:SetupShipEquipListener()
	end
end)

---@param ship Ship
Event.Register("onLeaveSystem", function(ship)
	local scanMgr = ship:GetComponent("ScanManager")

	if scanMgr then
		if scanMgr:IsAutoSurveyActive() then
			scanMgr:SetAutoSurveyActive(false)
		end
		if scanMgr:GetActiveScan() then
			scanMgr:ClearActiveScan()
		end
	end
end)

return ScanManager

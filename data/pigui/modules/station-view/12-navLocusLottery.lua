-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui              = require 'pigui'
local StationView     = require 'pigui.views.station-view'
local NavLocusLottery = require 'modules.Economy.NavLocusLottery'
local Game            = require 'Game'
local Format          = require 'Format'

local colors = ui.theme.colors
local icons = ui.theme.icons
local pionillium = ui.fonts.pionillium
local orbiteer = ui.fonts.orbiteer
local Vector2 = _G.Vector2
local Color = _G.Color

local currentSubTab = "TICKET"
local statusMessage = nil
local statusTime = 0
local selectedTicketIdx = 1
local childFlags = ui.ChildFlags { 'Borders' }

-- Custom coordinate input fields for single ticket
local customRing = 42
local customClassIdx = 5 -- G
local customRA = 284.5
local customDec = 14.2
local customEpoch = 8092

-- True astrophysical spectral colors for the 14 stellar classes
local STELLAR_COLORS = {
	O = Color(110, 180, 255, 255),  -- Electric cyan-blue
	B = Color(175, 215, 255, 255),  -- Blue-white
	A = Color(245, 250, 255, 255),  -- Brilliant diamond white
	F = Color(255, 250, 205, 255),  -- Pale warm yellow-white
	G = Color(255, 225, 75, 255),   -- Solar golden yellow
	K = Color(255, 155, 50, 255),   -- Warm amber-orange
	M = Color(255, 75, 60, 255),    -- Deep stellar crimson
	L = Color(195, 75, 80, 255),    -- Deep brown-red
	T = Color(180, 65, 180, 255),   -- Methane dwarf magenta
	Y = Color(135, 45, 155, 255),   -- Ultra-cool brown violet
	W = Color(40, 255, 230, 255),   -- Wolf-Rayet ion neon teal
	D = Color(225, 245, 255, 255),  -- White dwarf radiant spark
	N = Color(175, 130, 255, 255),  -- Neutron star / pulsar violet
	X = Color(235, 85, 255, 255),   -- Black hole accretion anomaly
}

local function formatCr(val)
	return string.format("%.0f Cr", val)
end

-- Renders a comprehensive 3D Astrolabe sphere on the PiGui canvas
-- Accurately visualizes the 5-vector astrogation coordinates:
-- 1. Sector Ring (00-99): Concentric equatorial armillary disc & highlighted active radius
-- 2. Stellar Class: Physical spectral color of the beacon and target ray
-- 3. Right Ascension (RA): Longitude around the rotating sphere
-- 4. Declination (Dec): Latitude on the sphere with 3D altitude anchor
-- 5. Epoch Vector: Rotating harmonic phase marker and phase pip
local function draw3DCelestialSphere(canvasOrigin, width, height, targetLocus, extraLoci, options)
	options = options or {}
	local cx = canvasOrigin.x + width * (options.centerX or 0.30)
	local cy = canvasOrigin.y + height * (options.centerY or 0.50)
	local radius = height * (options.radiusScale or 0.34)

	local t = ui.getTime()
	local rotY = t * (options.rotSpeed or 0.40)
	local tiltX = 0.38 -- Celestial axial tilt (~22 degrees)

	-- Project 3D spherical coordinate (lon in radians, lat in radians, radius) to 2D canvas
	local function projectPoint(lonRad, latRad, r)
		r = r or radius
		local cosLat = math.cos(latRad)
		local x3 = r * cosLat * math.sin(lonRad + rotY)
		local y3 = r * math.sin(latRad)
		local z3 = r * cosLat * math.cos(lonRad + rotY)

		-- Apply X tilt
		local cosT = math.cos(tiltX)
		local sinT = math.sin(tiltX)
		local yRot = y3 * cosT - z3 * sinT
		local zRot = y3 * sinT + z3 * cosT

		return Vector2(cx + x3, cy - yRot), zRot
	end

	-- 1. Draw Concentric Equatorial Armillary Disc (The 99 Sectors)
	local refRings = { 0, 25, 50, 75, 99 }
	for _, ringVal in ipairs(refRings) do
		local rDist = radius * (0.38 + 0.96 * (ringVal / 99.0))
		local numSegs = 32
		local prevPt, prevZ = nil, 0
		local isEdge = (ringVal == 0 or ringVal == 99)
		local rCol = isEdge and Color(40, 140, 210, 50) or Color(25, 80, 130, 28)

		for s = 0, numSegs do
			local lon = (s / numSegs) * (2 * math.pi)
			local pt, z = projectPoint(lon, 0.0, rDist)
			if prevPt then
				local aMult = (prevZ + z) > 0 and 1.0 or 0.35
				ui.addLine(prevPt, pt, Color(rCol.r, rCol.g, rCol.b, math.floor(rCol.a * aMult)), isEdge and 1.1 or 0.8)
			end
			prevPt = pt
			prevZ = z
		end
	end

	-- Highlight Active Coordinate Ring (00-99)
	local activeR = radius * 0.90
	if targetLocus and targetLocus.ring then
		activeR = radius * (0.38 + 0.96 * (math.clamp(targetLocus.ring, 0, 99) / 99.0))
		local numSegs = 40
		local prevPt, prevZ = nil, 0
		for s = 0, numSegs do
			local lon = (s / numSegs) * (2 * math.pi)
			local pt, z = projectPoint(lon, 0.0, activeR)
			if prevPt then
				local aMult = (prevZ + z) > 0 and 1.0 or 0.35
				local alpha = math.floor(215 * aMult)
				ui.addLine(prevPt, pt, Color(65, 235, 255, alpha), 1.8)
			end
			prevPt = pt
			prevZ = z
		end
	end

	-- Outer boundary halo
	ui.addCircle(Vector2(cx, cy), radius + 2, Color(40, 180, 240, 70), 48, 1.2)
	ui.addCircle(Vector2(cx, cy), radius + 8, Color(40, 180, 240, 30), 48, 1.0)

	-- 2. Draw Latitude Parallel Circles (-60, -30, 0, +30, +60 degrees)
	local latLines = { -1.047, -0.523, 0.0, 0.523, 1.047 }
	for _, lat in ipairs(latLines) do
		local isEquator = (lat == 0.0)
		local baseCol = isEquator and Color(65, 230, 255, 190) or Color(35, 120, 180, 75)
		local numSegments = 32
		local prevPt, prevZ = nil, 0

		for s = 0, numSegments do
			local lon = (s / numSegments) * (2 * math.pi)
			local pt, z = projectPoint(lon, lat, radius)
			if prevPt then
				local alphaMult = (prevZ + z) > 0 and 1.0 or 0.30
				local segCol = Color(baseCol.r, baseCol.g, baseCol.b, math.floor(baseCol.a * alphaMult))
				ui.addLine(prevPt, pt, segCol, isEquator and 1.6 or 0.9)
			end
			prevPt = pt
			prevZ = z
		end
	end

	-- 3. Draw Longitude Meridian Lines (every 45 degrees)
	for m = 0, 7 do
		local lon = (m / 8) * (2 * math.pi)
		local numSegments = 24
		local prevPt, prevZ = nil, 0

		for s = 0, numSegments do
			local lat = -math.pi * 0.5 + (s / numSegments) * math.pi
			local pt, z = projectPoint(lon, lat, radius)
			if prevPt then
				local alphaMult = (prevZ + z) > 0 and 1.0 or 0.25
				local segCol = Color(35, 140, 200, math.floor(75 * alphaMult))
				ui.addLine(prevPt, pt, segCol, 0.9)
			end
			prevPt = pt
			prevZ = z
		end
	end

	-- 4. Draw Extra Loci (Owned player single tickets & batch saturation points)
	if extraLoci and #extraLoci > 0 then
		for _, item in ipairs(extraLoci) do
			local loc = item.locus or item
			if loc.ra and loc.dec then
				local lonRad = math.rad(loc.ra)
				local latRad = math.rad(loc.dec)
				local pt, z = projectPoint(lonRad, latRad, radius)
				local starCol = STELLAR_COLORS[loc.class] or Color(200, 220, 255, 200)

				if item.type == "BATCH" or item.isBatch then
					-- Batch saturation star-cloud point
					if z > 0 then
						ui.addCircleFilled(pt, 1.8, Color(starCol.r, starCol.g, starCol.b, 175), 8)
					else
						ui.addCircleFilled(pt, 1.0, Color(starCol.r, starCol.g, starCol.b, 45), 6)
					end
				else
					-- Single ticket pin
					if z > 0 then
						ui.addCircleFilled(pt, 3.0, Color(starCol.r, starCol.g, starCol.b, 220), 12)
						ui.addCircle(pt, 5.0, Color(starCol.r, starCol.g, starCol.b, 130), 12, 1.0)
					else
						ui.addCircleFilled(pt, 1.8, Color(starCol.r, starCol.g, starCol.b, 60), 8)
					end
				end
			end
		end
	end

	-- 5. Draw Primary Target Astrogation Coordinate Beacon
	if targetLocus then
		local targetLonRad = math.rad(targetLocus.ra or 0.0)
		local targetLatRad = math.rad(targetLocus.dec or 0.0)
		local targetPt, targetZ = projectPoint(targetLonRad, targetLatRad, radius)
		local classCol = STELLAR_COLORS[targetLocus.class] or Color(255, 225, 75, 255)

		-- Central origin to target beacon ray
		local rayCol = (targetZ > 0)
			and Color(classCol.r, classCol.g, classCol.b, 225)
			or Color(classCol.r, classCol.g, classCol.b, 65)
		ui.addLine(Vector2(cx, cy), targetPt, rayCol, 1.5)

		-- 3D Altitude Drop-Line: connects equatorial active ring position to target sphere latitude
		local groundPt, groundZ = projectPoint(targetLonRad, 0.0, activeR)
		local dropAlpha = (targetZ > 0 or groundZ > 0) and 160 or 45
		ui.addLine(groundPt, targetPt, Color(65, 235, 255, dropAlpha), 1.0)
		ui.addCircleFilled(groundPt, 2.5, Color(65, 235, 255, dropAlpha), 8)

		-- Beacon Reticle & Spectral Aura on sphere surface
		if targetZ > 0 then
			local pulse = math.sin(t * 4.0) * 2.2
			local bRadius = math.max(4.0, 7.0 + pulse)

			ui.addCircleFilled(targetPt, 3.8, Color(255, 255, 255, 255), 16)
			ui.addCircle(targetPt, bRadius, classCol, 16, 1.6)
			ui.addCircle(targetPt, bRadius + 6.0, Color(classCol.r, classCol.g, classCol.b, 100), 16, 1.0)

			-- Reticle Crosshairs
			ui.addLine(Vector2(targetPt.x - bRadius - 5, targetPt.y), Vector2(targetPt.x + bRadius + 5, targetPt.y), classCol, 1.1)
			ui.addLine(Vector2(targetPt.x, targetPt.y - bRadius - 5), Vector2(targetPt.x, targetPt.y + bRadius + 5), classCol, 1.1)

			-- Epoch Harmonic Phase Pip (orbits the beacon in phase alignment)
			local epochVal = targetLocus.epoch or 0
			local epochAngle = ((epochVal / 10000.0) * (2 * math.pi)) + (t * 1.8)
			local pipDist = bRadius + 5.0
			local pipPos = Vector2(targetPt.x + math.cos(epochAngle) * pipDist, targetPt.y + math.sin(epochAngle) * pipDist)
			ui.addCircle(targetPt, pipDist, Color(classCol.r, classCol.g, classCol.b, 80), 16, 0.8)
			ui.addCircleFilled(pipPos, 2.2, Color(255, 255, 255, 240), 8)
		end
	end
end

local function drawNavLocusLottery()
	local drawState = NavLocusLottery.GetDrawState()
	local stellarClasses = NavLocusLottery.GetStellarClasses()
	local activeTickets = NavLocusLottery.GetPlayerTickets()
	local allPoints = NavLocusLottery.GetAllActivePoints()

	ui.withFont(orbiteer.title, function()
		ui.textColored(colors.compareBetter, "Pan-Galactic Nav-Locus Sweepstakes Authority")
	end)
	ui.textColored(colors.fontDim, "Synchronized Astrogation Coordinate Lottery — Weekly Tuesday 18:00:00 GST Drawing")
	ui.separator()
	ui.spacing()

	-- Giant Progressive Jackpot Banner with Scheduled Tuesday 18:00 GST Countdown
	ui.child("##jackpotBanner", Vector2(ui.getContentRegion().x, 68), nil, childFlags, function()
		ui.withFont(orbiteer.heading, function()
			ui.textColored(Color(255, 215, 50, 255), string.format("Grand Progressive Jackpot: %s", formatCr(drawState.jackpotPool)))
		end)

		local timeStr = string.format("Next Synchronized Drawing in: %dD %02dH %02dM %02dS (Cycle #%d — Tuesday 18:00 GST)",
			drawState.daysRemaining, drawState.hoursRemaining, drawState.minutesRemaining or 0, drawState.secondsRemaining or 0, drawState.drawNumber)
		ui.textColored(colors.uiPrimaryLight, timeStr)

		ui.sameLine(ui.getContentRegion().x - 240)
		ui.textColored(colors.fontDim, string.format("Total Won: %s", formatCr(NavLocusLottery.GetTotalWinnings())))

		-- Recent winner / rollover status line
		if drawState.lastWinner then
			local lw = drawState.lastWinner
			local winTag = lw.isPlayer and "Commander Claimed" or "NPC Claimed"
			ui.textColored(Color(120, 245, 140, 255), string.format("Cycle #%d Grand Winner (%s): %s (%s) in %s [%s]",
				lw.drawNumber, winTag, lw.name, lw.faction, lw.system, formatCr(lw.amount)))
		else
			ui.textColored(colors.fontDim, "Cycle Status: Progressive Pool Rollover Active (+75M–150M Cr / week)")
		end
	end)

	ui.spacing()

	-- Sub tabs
	ui.group(function()
		local tabs = {
			{ id = "TICKET", label = "3D Astrolabe Ticket & Buy" },
			{ id = "BATCH", label = "Bulk Batch Dispatch" },
			{ id = "MYTICKETS", label = string.format("My Registered Loci (%d)", #activeTickets) },
			{ id = "RULES", label = "Odds & Payout Schedule" },
		}
		for _, t in ipairs(tabs) do
			local isSel = (currentSubTab == t.id)
			local tabStyle = isSel and { Button = colors.uiPrimary or colors.white, Text = colors.black } or {}
			ui.withStyleColors(tabStyle, function()
				if ui.button(t.label .. "##SubTab", Vector2(210, 32)) then
					currentSubTab = t.id
				end
			end)
			ui.sameLine(nil, 8)
		end
		ui.newLine()
	end)

	ui.spacing()

	if statusMessage and (ui.getTime() - statusTime < 6.0) then
		ui.textColored(colors.alertYellow, statusMessage)
		ui.spacing()
	end

	-- Sub Tab 1: 3D Astrolabe Ticket Viewer & Single Buy
	if currentSubTab == "TICKET" then
		local availW = ui.getContentRegion().x
		local canvasH = 390

		-- Holographic Chit Frame
		ui.child("##holographicChit", Vector2(availW, canvasH), nil, childFlags, function()
			local canvasPos = ui.getCursorScreenPos()
			local winLocus = drawState.winningLocus

			local currentFocusLocus = {
				ring = customRing,
				class = stellarClasses[customClassIdx] or "G",
				ra = customRA,
				dec = customDec,
				epoch = customEpoch,
			}

			-- Animate the 3D celestial sphere with active rings, spectral colors, and ghost player tickets
			draw3DCelestialSphere(canvasPos, availW, canvasH, currentFocusLocus, allPoints, {
				centerX = 0.28,
				centerY = 0.50,
				radiusScale = 0.36,
			})

			-- Right pane: The Astrolabe Dials & Readout
			local rightX = availW * 0.54
			ui.setCursorPos(Vector2(rightX, 12))

			ui.group(function()
				ui.withFont(orbiteer.heading, function()
					ui.textColored(colors.uiPrimaryLight, "5-DIMENSIONAL ASTROGATION LOCUS")
				end)
				ui.textColored(colors.fontDim, "Select 5 coordinate vectors to calibrate your sweepstakes chit:")
				ui.separator()
				ui.spacing()

				-- Dial 1: Sector Ring
				ui.text("Vector 1: Sector Ring (00–99):")
				ui.sameLine(rightX + 225)
				ui.textColored(Color(65, 235, 255, 255), string.format("[ RING %02d ]", customRing))
				ui.sameLine()
				if ui.button("-10##R10", Vector2(36, 22)) then customRing = math.max(0, customRing - 10) end
				ui.sameLine(nil, 4)
				if ui.button("-1##R1", Vector2(30, 22)) then customRing = math.max(0, customRing - 1) end
				ui.sameLine(nil, 4)
				if ui.button("+1##R1P", Vector2(30, 22)) then customRing = math.min(99, customRing + 1) end
				ui.sameLine(nil, 4)
				if ui.button("+10##R10P", Vector2(36, 22)) then customRing = math.min(99, customRing + 10) end

				-- Dial 2: Stellar Class (with visual spectral color chips)
				local curClass = stellarClasses[customClassIdx] or "G"
				local curColor = STELLAR_COLORS[curClass] or colors.white
				ui.text("Vector 2: Stellar Class:")
				ui.sameLine(rightX + 225)
				ui.textColored(curColor, string.format("[ CLASS %s ]", curClass))
				ui.sameLine()
				if ui.button("<##ClassPrev", Vector2(30, 22)) then
					customClassIdx = (customClassIdx > 1) and (customClassIdx - 1) or #stellarClasses
				end
				ui.sameLine(nil, 4)
				if ui.button(">##ClassNext", Vector2(30, 22)) then
					customClassIdx = (customClassIdx < #stellarClasses) and (customClassIdx + 1) or 1
				end

				-- Dial 3: Right Ascension
				ui.text("Vector 3: Right Ascension (0–360°):")
				ui.sameLine(rightX + 225)
				ui.textColored(Color(65, 235, 255, 255), string.format("[ %05.1f° ]", customRA))
				ui.sameLine()
				if ui.button("-10°##RA10", Vector2(38, 22)) then customRA = (customRA - 10.0 + 360.0) % 360.0 end
				ui.sameLine(nil, 4)
				if ui.button("-1°##RA1", Vector2(32, 22)) then customRA = (customRA - 1.0 + 360.0) % 360.0 end
				ui.sameLine(nil, 4)
				if ui.button("+1°##RA1P", Vector2(32, 22)) then customRA = (customRA + 1.0) % 360.0 end
				ui.sameLine(nil, 4)
				if ui.button("+10°##RA10P", Vector2(38, 22)) then customRA = (customRA + 10.0) % 360.0 end

				-- Dial 4: Declination
				ui.text("Vector 4: Declination (-90–+90°):")
				ui.sameLine(rightX + 225)
				ui.textColored(Color(65, 235, 255, 255), string.format("[ %+05.1f° ]", customDec))
				ui.sameLine()
				if ui.button("-10°##DEC10", Vector2(38, 22)) then customDec = math.max(-90.0, customDec - 10.0) end
				ui.sameLine(nil, 4)
				if ui.button("-1°##DEC1", Vector2(32, 22)) then customDec = math.max(-90.0, customDec - 1.0) end
				ui.sameLine(nil, 4)
				if ui.button("+1°##DEC1P", Vector2(32, 22)) then customDec = math.min(90.0, customDec + 1.0) end
				ui.sameLine(nil, 4)
				if ui.button("+10°##DEC10P", Vector2(38, 22)) then customDec = math.min(90.0, customDec + 10.0) end

				-- Dial 5: Epoch Vector
				ui.text("Vector 5: Epoch (#0000–#9999):")
				ui.sameLine(rightX + 225)
				ui.textColored(Color(65, 235, 255, 255), string.format("[ #%04d ]", customEpoch))
				ui.sameLine()
				if ui.button("-500##EP500", Vector2(44, 22)) then customEpoch = (customEpoch - 500 + 10000) % 10000 end
				ui.sameLine(nil, 4)
				if ui.button("-50##EP50", Vector2(34, 22)) then customEpoch = (customEpoch - 50 + 10000) % 10000 end
				ui.sameLine(nil, 4)
				if ui.button("+50##EP50P", Vector2(34, 22)) then customEpoch = (customEpoch + 50) % 10000 end
				ui.sameLine(nil, 4)
				if ui.button("+500##EP500P", Vector2(44, 22)) then customEpoch = (customEpoch + 500) % 10000 end

				ui.spacing()
				ui.separator()
				ui.spacing()

				ui.textColored(colors.fontDim, "Last Cycle # Winning Coordinates:")
				ui.textColored(Color(255, 215, 60, 255), string.format("  RING %02d | CLASS %s | %05.1f° | %+05.1f° | #%04d",
					winLocus.ring, winLocus.class, winLocus.ra, winLocus.dec, winLocus.epoch))

				ui.spacing()
				if ui.button("GENERATE RANDOM QUICK-PICK##RandomBtn", Vector2(230, 32)) then
					local rand = require('Rand').New(math.floor(ui.getTime() * 1000))
					customRing = rand:Integer(0, 99)
					customClassIdx = rand:Integer(1, #stellarClasses)
					customRA = math.floor(rand:Number(0.0, 359.9) * 10) / 10
					customDec = math.floor(rand:Number(-90.0, 90.0) * 10) / 10
					customEpoch = rand:Integer(0, 9999)
				end

				ui.sameLine(nil, 12)

				if ui.button("PURCHASE TICKET (10 CR)##BuySingleBtn", Vector2(200, 32)) then
					local locus = {
						ring = customRing,
						class = stellarClasses[customClassIdx],
						ra = customRA,
						dec = customDec,
						epoch = customEpoch,
					}
					local ok, msg = NavLocusLottery.BuySingleTicket(locus)
					statusMessage = msg
					statusTime = ui.getTime()
				end
			end)
		end)

	-- Sub Tab 2: Bulk Batch Purchase
	elseif currentSubTab == "BATCH" then
		ui.child("##batchBuyChit", Vector2(-1, -1), nil, childFlags, function()
			ui.withFont(orbiteer.heading, function()
				ui.textColored(colors.uiPrimaryLight, "HIGH-VOLUME ALGORITHMIC LOCUS SATURATION")
			end)
			ui.textWrapped("Because the Grand Jackpot operates across 90.7 trillion combinations, syndicates and commercial captains frequently saturate coordinate grids using automated algorithmic batch dispatch. Batch points are immediately plotted on your 3D Astrolabe star cloud.")
			ui.separator()
			ui.spacing()

			local batches = {
				{ count = 100, cost = 1000, name = "Cluster Batch (100 Loci)", desc = "Deploys 100 pseudo-random coordinate sets across nearest stellar sectors." },
				{ count = 1000, cost = 10000, name = "Grid Saturation (1,000 Loci)", desc = "High density coordinate saturation with elevated probability of Tier 4 and Tier 5 partial wins." },
				{ count = 10000, cost = 100000, name = "Sector Carpet (10,000 Loci)", desc = "Industrial scale grid saturation spanning thousands of coordinates across all 14 stellar spectral types." },
				{ count = 100000, cost = 1000000, name = "Armillary Blanket (100,000 Loci)", desc = "Mega-consortium investment blanketing expansive astronomical declination arcs." },
			}

			ui.columns(4, "##batchCols", true)
			ui.text("Bundle Name") ui.nextColumn()
			ui.text("Coordinate Volume") ui.nextColumn()
			ui.text("Total Cost") ui.nextColumn()
			ui.text("Action") ui.nextColumn()
			ui.separator()

			for _, b in ipairs(batches) do
				ui.text(b.name)
				ui.textColored(colors.fontDim, b.desc)
				ui.nextColumn()
				ui.text(string.format("%s Loci", formatCr(b.count)))
				ui.nextColumn()
				ui.text(formatCr(b.cost))
				ui.nextColumn()
				if ui.button(string.format("Purchase %s Cr##BuyB%d", formatCr(b.cost), b.count), Vector2(170, 34)) then
					local ok, msg = NavLocusLottery.BuyBatchTickets(b.count)
					statusMessage = msg
					statusTime = ui.getTime()
				end
				ui.nextColumn()
			end
			ui.columns(1)
		end)

	-- Sub Tab 3: My Registered Loci & Interactive 3D Viewer
	elseif currentSubTab == "MYTICKETS" then
		local history = NavLocusLottery.GetTicketHistory()
		local availW = ui.getContentRegion().x
		local leftW = math.floor(availW * 0.46)
		local rightW = availW - leftW - 16

		-- Left Pane: Dedicated 3D Astrolabe Viewport showing ALL owned tickets
		ui.child("##myTickets3D", Vector2(leftW, -1), nil, childFlags, function()
			ui.withFont(orbiteer.heading, function()
				ui.textColored(colors.uiPrimaryLight, "Astrolabe Coordinate Swarm")
			end)
			ui.textColored(colors.fontDim, string.format("Visualizing %d registered loci across celestial sphere", #allPoints))
			ui.separator()

			local canvasPos = ui.getCursorScreenPos()
			local canvasH = 340

			-- Determine selected focus ticket
			local focusTicketLocus = nil
			if #activeTickets > 0 then
				selectedTicketIdx = math.clamp(selectedTicketIdx, 1, #activeTickets)
				local sel = activeTickets[selectedTicketIdx]
				if sel then
					focusTicketLocus = sel.locus or (sel.samplePoints and sel.samplePoints[1])
				end
			end

			-- Render 3D astrolabe containing all owned points
			draw3DCelestialSphere(canvasPos, leftW, canvasH, focusTicketLocus, allPoints, {
				centerX = 0.50,
				centerY = 0.52,
				radiusScale = 0.35,
				rotSpeed = 0.30,
			})

			ui.setCursorPos(Vector2(12, canvasH + 20))
			ui.textColored(colors.uiPrimaryLight, "Coverage Legend:")
			ui.text("• Colored Pins: Single Registered Chits (Star Class Color)")
			ui.text("• Star Cloud: Batch Saturation Dispersion Points")
			ui.text("• Glowing Ring: Galactocentric Sector Distance (00-99)")
		end)

		ui.sameLine(nil, 12)

		-- Right Pane: Ticket Roster & Settled History
		ui.child("##myTicketsList", Vector2(rightW, -1), nil, childFlags, function()
			ui.withFont(orbiteer.heading, function()
				ui.textColored(colors.uiPrimaryLight, string.format("ACTIVE CHITS (CYCLE #%d)", drawState.drawNumber))
			end)
			ui.separator()
			ui.spacing()

			if #activeTickets == 0 then
				ui.textColored(colors.fontDim, "You do not currently have any active Nav-Locus tickets registered for this cycle.")
				ui.textColored(colors.fontDim, "Visit the '3D Astrolabe Ticket' or 'Bulk Batch' tab to enter.")
			else
				ui.child("##activeTicketsScroll", Vector2(-1, 160), nil, childFlags, function()
					for idx, t in ipairs(activeTickets) do
						local isSelected = (selectedTicketIdx == idx)
						local selStyle = isSelected and { Button = colors.uiPrimary or colors.white, Text = colors.black } or {}

						ui.withStyleColors(selStyle, function()
							if t.type == "SINGLE" then
								local loc = t.locus
								local classCol = STELLAR_COLORS[loc.class] or colors.white
								local label = string.format("[%02d] %s: R%02d | %s | %05.1f° | %+05.1f° | #%04d",
									idx, t.id, loc.ring, loc.class, loc.ra, loc.dec, loc.epoch)
								if ui.button(label .. "##TktBtn" .. tostring(idx), Vector2(-1, 26)) then
									selectedTicketIdx = idx
								end
							elseif t.type == "BATCH" then
								local label = string.format("[%02d] %s: %s Algorithmic Loci (Cost: %s)",
									idx, t.id, formatCr(t.count), formatCr(t.cost))
								if ui.button(label .. "##BatchBtn" .. tostring(idx), Vector2(-1, 26)) then
									selectedTicketIdx = idx
								end
							end
						end)
					end
				end)
			end

			ui.spacing()
			ui.separator()
			ui.spacing()

			ui.withFont(orbiteer.heading, function()
				ui.textColored(colors.uiPrimaryLight, "SETTLED TICKET HISTORY & PAST WINNINGS")
			end)
			ui.separator()
			ui.spacing()

			if #history == 0 then
				ui.textColored(colors.fontDim, "No settled ticket history on record.")
			else
				ui.child("##historyScroll", Vector2(-1, -1), nil, childFlags, function()
					for i = 1, math.min(15, #history) do
						local h = history[i]
						local payCol = (h.payout and h.payout > 0) and colors.econProfit or colors.fontDim
						ui.text(string.format("Cycle #%d | %s | Payout: ", h.settledDraw or 0, h.id))
						ui.sameLine()
						ui.textColored(payCol, formatCr(h.payout or 0))
						if h.tierName then
							ui.sameLine()
							ui.textColored(colors.fontDim, "(" .. h.tierName .. ")")
						end
					end
				end)
			end
		end)

	-- Sub Tab 4: Rules & Odds Schedule
	elseif currentSubTab == "RULES" then
		ui.child("##rulesView", Vector2(-1, -1), nil, childFlags, function()
			ui.withFont(orbiteer.heading, function()
				ui.textColored(colors.uiPrimaryLight, "Official Astrogation Locus Payout Schedule")
			end)
			ui.textColored(colors.fontDim, "Mathematical Vector Odds calculated across 90,770,400,000,000 Total Combinations:")
			ui.separator()
			ui.spacing()

			ui.columns(4, "##payoutCols", true)
			ui.text("Tier") ui.nextColumn()
			ui.text("Match Criteria") ui.nextColumn()
			ui.text("Probability") ui.nextColumn()
			ui.text("Payout") ui.nextColumn()
			ui.separator()

			local schedule = {
				{ tier = "Tier 1", criteria = "All 5 Vectors Matched Exactly", odds = "1 in 90.7 Trillion", payout = "Grand Progressive Pool (500M+ Cr)" },
				{ tier = "Tier 2", criteria = "Any 4 of 5 Vectors Matched", odds = "1 in 50 Million", payout = "2,500,000 Cr" },
				{ tier = "Tier 3", criteria = "Any 3 of 5 Vectors Matched", odds = "1 in 5,040,000", payout = "75,000 Cr" },
				{ tier = "Tier 4", criteria = "Any 2 Vectors Matched", odds = "1 in 140,000", payout = "1,500 Cr" },
				{ tier = "Tier 5", criteria = "Sector Ring Matched Exactly", odds = "1 in 100", payout = "40 Cr (4 to 1 Return)" },
			}

			for _, s in ipairs(schedule) do
				ui.text(s.tier) ui.nextColumn()
				ui.text(s.criteria) ui.nextColumn()
				ui.text(s.odds) ui.nextColumn()
				ui.text(s.payout) ui.nextColumn()
			end
			ui.columns(1)

			ui.spacing()
			ui.separator()
			ui.spacing()

			ui.textColored(colors.uiPrimaryLight, "Drawing Synchronisation Directives:")
			ui.textWrapped("1. DRAW SCHEDULE: Synchronized pan-galactic draws occur weekly every Tuesday at 18:00:00 GST across all relay transponders. Draws advance seamlessly whether flying in real-time, waiting docked, or executing hyperspace jumps.")
			ui.textWrapped("2. NPC & CONSORTIUM PARTICIPATION: Billions of interstellar pilots, mining syndicates, and corporate trusts participate in each cycle. When an NPC or consortium verifies a Tier 1 match, the grand pool is claimed and resets to 500M Cr.")
			ui.textWrapped("3. PROGRESSIVE ROLLOVER: If no grand vector alignment is verified across pan-galactic transponders, the jackpot pool compounds by +75,000,000 to +150,000,000 Credits for the following Tuesday's draw.")
		end)
	end
end

StationView:registerView({
	id = "navLocusLottery",
	name = "Nav-Locus Lottery",
	icon = icons.galaxy_map or icons.bbs,
	showView = true,
	draw = drawNavLocusLottery,
	refresh = function(self) end,
	debugReload = function()
		package.reimport()
	end
})

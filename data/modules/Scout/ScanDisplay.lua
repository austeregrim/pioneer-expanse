-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game        = require 'Game'
local Space       = require 'Space'
local Lang        = require 'Lang'
local Cartography = require 'modules.Cartography.Cartography'

local utils = require 'utils'
local ui = require 'pigui'

local lui = Lang.GetResource("ui-core")
local ls = Lang.GetResource("module-scout")

local colors = ui.theme.colors
local icons = ui.theme.icons

local pionillium = ui.fonts.pionillium

local gameView = require 'pigui.views.game'

local scanDisplay = {
	title = ls.SCAN_MANAGER or "Scan Manager",
	side = "left",
	icon = icons.equip_orbit_scanner,
	tooltip = ls.SCAN_MANAGER or "Scan Manager",
	exclusive = false,

	debugReload = function()
		package.reimport('pigui.libs.item-card')
		package.reimport()
	end,

	ship = nil,
	scanMgr = nil,
	activeTab = 1, -- 1: System Survey, 2: Scan Queue, 3: Completed Data
	queueFilter = "all", -- "all", "orbital", "surface"
	surveyUnscannedOnly = true,
	lastNavTarget = nil,
}

local function isSameBodyPath(a, b)
	if not a or not b then return false end
	if a.IsSameSystem and a:IsSameSystem(b) then
		return a.bodyIndex == b.bodyIndex
	end
	return tostring(a) == tostring(b)
end

local function getQueuePos(scanMgr, bodyPath, isOrbital)
	if not scanMgr then return nil end
	local active = scanMgr:GetActiveScan()
	if active and isSameBodyPath(active.bodyPath, bodyPath) and active.orbital == isOrbital then
		return "ACTIVE"
	end
	local pending = scanMgr:GetPendingScans()
	for idx, s in ipairs(pending) do
		if isSameBodyPath(s.bodyPath, bodyPath) and s.orbital == isOrbital then
			return idx
		end
	end
	return nil
end

function scanDisplay:drawHardwareBar()
	if not self.scanMgr then return end
	local hasOrbit = self.scanMgr:HasSensorOfType(true)
	local hasSurface = self.scanMgr:HasSensorOfType(false)
	local hasDisco = Cartography.HasDiscoveryScanner(self.ship)

	ui.withFont(pionillium.details, function()
		ui.textColored(hasOrbit and colors.econMajorImport or colors.fontDim, hasOrbit and "● Orbit Scanner" or "○ No Orbit")
		ui.sameLine()
		ui.textColored(hasSurface and colors.econMajorImport or colors.fontDim, hasSurface and "● Surface Scanner" or "○ No Surface")
		ui.sameLine()
		ui.textColored(hasDisco and colors.econMajorImport or colors.fontDim, hasDisco and "● Discovery" or "○ No Discovery")
	end)
end

function scanDisplay:drawDiscoverySection()
	local width = ui.getContentRegion().x

	if Cartography.IsDiscoveryScanActive() then
		local prog = Cartography.GetDiscoveryScanProgress()
		ui.withStyleColors({ PlotHistogram = colors.uiPrimaryLight }, function()
			ui.progressBar(prog, Vector2(width, 0), string.format("Discovering System... %.0f%%", prog * 100))
		end)
	elseif Game.system and not Game.system.explored then
		if Cartography.HasDiscoveryScanner(self.ship) then
			if ui.button("Discovery Scan System (Honk)", Vector2(width, ui.getButtonHeight())) then
				Cartography.StartDiscoveryScan()
				ui.playSfx("OK")
			end
		else
			ui.textColored(colors.fontDim, "Discovery Scanner not equipped (Buy at Outfitter)")
		end
	elseif Game.system then
		ui.withFont(pionillium.details, function()
			ui.textColored(colors.econMajorImport or colors.uiPrimaryLight, "System Charted ✓  " .. (Game.system.name or ""))
		end)
	end
end

function scanDisplay:drawScanProgress(scan)
	local completion = math.min(1.0, scan.coverage / scan.targetCoverage)
	local width = ui.getContentRegion().x
	local progressBarColor = colors.uiPrimaryLight
	local progressBarText = ls.DATA_COLLECTED_PROGRESS % {
		percent_completed = string.format("%.2f", completion * 100.0)
	}
	ui.withStyleColors({ PlotHistogram = progressBarColor }, function()
		ui.progressBar(completion, Vector2(width, 0), progressBarText)
	end)
end

function scanDisplay:drawActiveScanHUD()
	local scan = self.scanMgr:GetActiveScan()
	if not scan then
		return
	end

	local sBody = scan.bodyPath:GetSystemBody()
	local bodyName = sBody and sBody.name or "Unknown Body"
	local starSys = scan.bodyPath:GetStarSystem()
	local sysName = starSys and starSys.name or ""
	local body = self.scanMgr:GetScanBodyByType(scan)

	ui.spacing()

	-- Header: Tag and system
	local modeLabel = scan.orbital and "ORBITAL SURVEY" or "SURFACE MAPPING"
	local modeCol = scan.orbital and colors.uiPrimaryLight or colors.econMajorImport
	local badgeIcon = scan.orbital and icons.equip_orbit_scanner or icons.planet_grid
	local borderCol = scan.orbital and Color(45, 175, 255, 200) or Color(55, 230, 155, 200)
	local childFlags = ui.ChildFlags { "AlwaysUseWindowPadding", "Borders", "AutoResizeY" }

	ui.withStyleColors({
		ChildBg = Color(16, 26, 42, 240),
		Border = borderCol,
	}, function()
		ui.withStyleVars({
			ChildRounding = 6.0,
			WindowPadding = Vector2(8, 8),
		}, function()
			ui.child("##activeScanCard", Vector2(0, 0), { "NoScrollbar" }, childFlags, function()
				ui.withFont(pionillium.details, function()
					ui.icon(badgeIcon, Vector2(16, 16), modeCol)
					ui.sameLine(0, 6)
					ui.textColored(modeCol, "ACTIVE SCAN: " .. modeLabel)
					ui.sameLine()
					ui.textColored(colors.fontDim, "•  " .. sysName)
				end)

				ui.spacing()
				ui.withFont(pionillium.heading, function()
					ui.text(bodyName)
				end)

				-- Telemetry range & altitude
				if body then
					local dist = self.ship:GetPositionRelTo(body):length()
					local maxDist = self.scanMgr.GetScanMaxDistance(body, scan.orbital)
					local inRange = dist <= maxDist
					ui.withFont(pionillium.details, function()
						if inRange then
							ui.textColored(colors.econMajorImport, "● IN SCAN RANGE — Collecting Telemetry")
						else
							ui.textColored(colors.alertYellow, string.format("Approaching: %s (Engages at %s)", ui.Format.Distance(dist), ui.Format.Distance(maxDist)))
						end
					end)
				else
					ui.withFont(pionillium.details, function()
						ui.textColored(colors.alertYellow, "Target is in remote system (" .. sysName .. ")")
					end)
				end

				ui.spacing()
				self:drawScanProgress(scan)
				ui.spacing()

				-- Controls: Pause & Target
				local availW = ui.getContentRegion().x
				local btnW = (availW - ui.getItemSpacing().x) * 0.5
				local btnH = 22

				if ui.button("Pause Scan##actPause", Vector2(btnW, btnH)) then
					self.scanMgr:ClearActiveScan()
					ui.playSfx("Cancel")
				end
				ui.sameLine()
				if body and ui.button("Target Nav##actNav", Vector2(btnW, btnH)) then
					self.ship:SetNavTarget(body)
					ui.playSfx("OK")
				end
			end)
		end)
	end)

	ui.spacing()
	ui.separator()
	ui.spacing()
end

function scanDisplay:drawSystemSurvey()
	if not Game.system then
		ui.textColored(colors.fontDim, "No Star System Loaded")
		return
	end

	if Game.InHyperspace and Game.InHyperspace() then
		ui.textColored(colors.fontDim, "Hyperspace Transit Active")
		return
	end

	local bodies = Space.GetBodies()
	local player = self.ship

	local list = {}
	for _, b in ipairs(bodies) do
		local sb = b:GetSystemBody()
		if sb and sb.superType ~= "STARPORT" then
			local dist = player and player:GetPositionRelTo(b):length() or 0
			table.insert(list, { body = b, sbody = sb, dist = dist })
		end
	end

	table.sort(list, function(a, b)
		return a.dist < b.dist
	end)

	-- Header with system name and filter toggle
	ui.withFont(pionillium.heading, function()
		ui.text(Game.system.name .. " Survey")
	end)

	ui.withFont(pionillium.details, function()
		ui.textColored(colors.fontDim, string.format("%d celestial bodies detected in system", #list))
	end)

	ui.spacing()

	local changed, newChecked = ui.checkbox("Show Unscanned Only", self.surveyUnscannedOnly)
	if changed then
		self.surveyUnscannedOnly = newChecked
	end

	ui.spacing()

	-- Batch queue buttons
	local batchBtnW = (ui.getContentRegion().x - ui.getItemSpacing().x * 2) / 3
	local bBtnH = 22
	if ui.button("+ All Orbit", Vector2(batchBtnW, bBtnH)) then
		local count = 0
		for _, item in ipairs(list) do
			if not Cartography.HasUnsoldScan(item.body, true) then
				local status = self.scanMgr:GetScanStatusForBody(item.body.path, true)
				if not status then
					local scanId = self.scanMgr:StartFreeScan(item.body, true)
					if scanId then
						count = count + 1
					end
				end
			end
		end
		if count > 0 then ui.playSfx("OK") else ui.playSfx("Cancel") end
	end
	if ui.isItemHovered() then
		ui.setTooltip("Queue orbital scans for all bodies not currently stored in ship computer")
	end

	ui.sameLine()
	if ui.button("+ All Surface", Vector2(batchBtnW, bBtnH)) then
		local count = 0
		for _, item in ipairs(list) do
			local isStar = item.sbody.superType == "STAR"
			local isGasGiant = item.sbody.type == "PLANET_GAS_GIANT"
			if not isStar and not isGasGiant and not Cartography.HasUnsoldScan(item.body, false) then
				local status = self.scanMgr:GetScanStatusForBody(item.body.path, false)
				if not status then
					local scanId = self.scanMgr:StartFreeScan(item.body, false)
					if scanId then
						count = count + 1
					end
				end
			end
		end
		if count > 0 then ui.playSfx("OK") else ui.playSfx("Cancel") end
	end
	if ui.isItemHovered() then
		ui.setTooltip("Queue surface scans for all solid bodies not currently stored in ship computer")
	end

	ui.sameLine()
	if ui.button("+ Queue Both", Vector2(batchBtnW, bBtnH)) then
		local count = 0
		for _, item in ipairs(list) do
			if not Cartography.HasUnsoldScan(item.body, true) then
				local status = self.scanMgr:GetScanStatusForBody(item.body.path, true)
				if not status then
					local scanId = self.scanMgr:StartFreeScan(item.body, true)
					if scanId then
						count = count + 1
					end
				end
			end
			local isStar = item.sbody.superType == "STAR"
			local isGasGiant = item.sbody.type == "PLANET_GAS_GIANT"
			if not isStar and not isGasGiant and not Cartography.HasUnsoldScan(item.body, false) then
				local status = self.scanMgr:GetScanStatusForBody(item.body.path, false)
				if not status then
					local scanId = self.scanMgr:StartFreeScan(item.body, false)
					if scanId then
						count = count + 1
					end
				end
			end
		end
		if count > 0 then ui.playSfx("OK") else ui.playSfx("Cancel") end
	end
	if ui.isItemHovered() then
		ui.setTooltip("Queue both orbital and surface scans for all unrecorded bodies")
	end

	ui.spacing()
	ui.separator()
	ui.spacing()

	local visibleCount = 0

	for _, item in ipairs(list) do
		local b = item.body
		local sb = item.sbody
		local dist = item.dist
		local pathKey = tostring(sb.path)

		local isStar = sb.superType == "STAR"
		local isGasGiant = sb.type == "PLANET_GAS_GIANT"
		local isSolid = not isStar and not isGasGiant

		local orbUnsold = Cartography.HasUnsoldScan(b, true)
		local orbSold = Cartography.HasSoldScan(b, true)

		local surfUnsold = isSolid and Cartography.HasUnsoldScan(b, false) or false
		local surfSold = isSolid and Cartography.HasSoldScan(b, false) or false

		local orbStatus, orbScan = self.scanMgr:GetScanStatusForBody(b.path, true)
		local surfStatus, surfScan = nil, nil
		if isSolid then
			surfStatus, surfScan = self.scanMgr:GetScanStatusForBody(b.path, false)
		end

		local isFullyStored = orbUnsold and (not isSolid or surfUnsold)

		if not (self.surveyUnscannedOnly and isFullyStored) then
			visibleCount = visibleCount + 1

			local bName = b.label or sb.name or "Unknown"
			local typeStr = isStar and "Star" or (isGasGiant and "Gas Giant" or (sb.type == "PLANET_ASTEROID" and "Asteroid" or "Terrestrial Planet"))
			local radiusStr = ui.Format.Distance(sb.radius)
			local distStr = ui.Format.Distance(dist)
			local isNavTarget = player and player:GetNavTarget() == b
			local isScanning = (orbStatus == "ACTIVE") or (surfStatus == "ACTIVE")

			local cardStartPos = ui.getCursorScreenPos()
			local availW = ui.getContentRegion().x
			local btnW = 28
			local btnH = 20
			local cardPad = 6
			local btnGap = 4
			local cardH = cardPad + btnH + btnGap + btnH + cardPad -- 56px total card height
			local infoW = availW - btnW - cardPad * 2 - 10

			local minPos = cardStartPos
			local maxPos = Vector2(cardStartPos.x + availW, cardStartPos.y + cardH)

			-- Card background & border drawn first (behind text and buttons)
			local bgCol = isScanning and Color(20, 36, 54, 225) or Color(18, 22, 32, 215)
			ui.addRectFilled(minPos, maxPos, bgCol, 4.0, ui.RoundCornersAll)
			if isNavTarget then
				ui.addRect(minPos, maxPos, colors.uiPrimaryLight, 4.0, ui.RoundCornersAll, 1.5)
			else
				ui.addRect(minPos, maxPos, Color(45, 55, 75, 130), 4.0, ui.RoundCornersAll, 1.0)
			end

			ui.group(function()
				-- Left: Body Name & Info
				ui.setCursorScreenPos(cardStartPos + Vector2(cardPad, cardPad))
				ui.group(function()
					ui.withFont(pionillium.body, function()
						local nameColor = isNavTarget and colors.uiPrimaryLight or colors.font
						local prefix = isNavTarget and "● " or ""
						if ui.selectable(prefix .. bName .. "##sel" .. pathKey, isNavTarget, nil, Vector2(infoW, 0)) then
							player:SetNavTarget(b)
							self.scanMgr:PrioritizeBodyInQueue(b)
							ui.playSfx("OK")
						end
					end)
					if ui.isItemHovered() then
						ui.setTooltip("Click to target & prioritize in Scan Queue")
					end

					ui.withFont(pionillium.details, function()
						local infoText = string.format("%s • Dist: %s • R: %s", typeStr, distStr, radiusStr)
						if isScanning then
							infoText = infoText .. " • [SCANNING]"
							ui.textColored(colors.econMajorImport, infoText)
						else
							ui.textColored(colors.fontDim, infoText)
						end
					end)
				end)

				-- Right: Vertically Stacked Icon Buttons
				local btnPos = cardStartPos + Vector2(availW - btnW - cardPad, cardPad)
				local btnSz = Vector2(btnW, btnH)
				local btnPad = Vector2(2, 2)
				local qPosOrb = getQueuePos(self.scanMgr, b.path, true)
				local qPosSurf = isSolid and getQueuePos(self.scanMgr, b.path, false) or nil

				-- Top Button: Orbital Scan Icon Button
				ui.setCursorScreenPos(btnPos)
				local orbIcon = icons.equip_orbit_scanner
				if orbStatus == "ACTIVE" or qPosOrb == "ACTIVE" then
					if ui.iconButton("##orb" .. pathKey, orbIcon, "Orbital Scan [ACTIVE] • Click to pause", ui.theme.buttonColors.selected, btnSz, btnPad) then
						self.scanMgr:ClearActiveScan()
						ui.playSfx("Cancel")
					end
				elseif qPosOrb then
					local tip = string.format("Orbital Scan [Queued #%d] • Click to activate now", qPosOrb)
					if ui.iconButton("##orb" .. pathKey, orbIcon, tip, ui.theme.buttonColors.deselected, btnSz, btnPad) then
						if orbScan then
							self.scanMgr:SetActiveScan(orbScan.id)
						else
							self.scanMgr:PrioritizeBodyInQueue(b)
						end
						player:SetNavTarget(b)
						ui.playSfx("OK")
					end
				elseif orbUnsold then
					ui.iconButton("##orb" .. pathKey, icons.map_checkmark, "Orbital Survey Stored ✓", ui.theme.buttonColors.disabled, btnSz, btnPad)
				elseif orbSold then
					if ui.iconButton("##orb" .. pathKey, orbIcon, "Queue Orbital Rescan (10% payout update)", ui.theme.buttonColors.deselected, btnSz, btnPad) then
						local scanId = self.scanMgr:StartFreeScan(b, true)
						if scanId then
							player:SetNavTarget(b)
							ui.playSfx("OK")
						end
					end
				else
					if ui.iconButton("##orb" .. pathKey, orbIcon, "+ Queue Orbital Scan", ui.theme.buttonColors.deselected, btnSz, btnPad) then
						local scanId = self.scanMgr:StartFreeScan(b, true)
						if scanId then
							player:SetNavTarget(b)
							ui.playSfx("OK")
						end
					end
				end

				-- Bottom Button: Surface Scan Icon Button
				ui.setCursorScreenPos(btnPos + Vector2(0, btnH + btnGap))
				local surfIcon = icons.planet_grid
				if not isSolid then
					ui.iconButton("##nosurf" .. pathKey, icons.minus, "No solid surface to map", ui.theme.buttonColors.disabled, btnSz, btnPad)
				elseif surfStatus == "ACTIVE" or qPosSurf == "ACTIVE" then
					if ui.iconButton("##surf" .. pathKey, surfIcon, "Surface Mapping [ACTIVE] • Click to pause", ui.theme.buttonColors.selected, btnSz, btnPad) then
						self.scanMgr:ClearActiveScan()
						ui.playSfx("Cancel")
					end
				elseif qPosSurf then
					local tip = string.format("Surface Mapping [Queued #%d] • Click to activate now", qPosSurf)
					if ui.iconButton("##surf" .. pathKey, surfIcon, tip, ui.theme.buttonColors.deselected, btnSz, btnPad) then
						if surfScan then
							self.scanMgr:SetActiveScan(surfScan.id)
						else
							self.scanMgr:PrioritizeBodyInQueue(b)
						end
						player:SetNavTarget(b)
						ui.playSfx("OK")
					end
				elseif surfUnsold then
					ui.iconButton("##surf" .. pathKey, icons.map_checkmark, "Surface Survey Stored ✓", ui.theme.buttonColors.disabled, btnSz, btnPad)
				elseif surfSold then
					if ui.iconButton("##surf" .. pathKey, surfIcon, "Queue Surface Rescan (10% payout pass)", ui.theme.buttonColors.deselected, btnSz, btnPad) then
						local scanId = self.scanMgr:StartFreeScan(b, false)
						if scanId then
							player:SetNavTarget(b)
							ui.playSfx("OK")
						end
					end
				else
					if ui.iconButton("##surf" .. pathKey, surfIcon, "+ Queue Surface Mapping", ui.theme.buttonColors.deselected, btnSz, btnPad) then
						local scanId = self.scanMgr:StartFreeScan(b, false)
						if scanId then
							player:SetNavTarget(b)
							ui.playSfx("OK")
						end
					end
				end
			end)

			ui.setCursorScreenPos(Vector2(cardStartPos.x, maxPos.y + 6))
			ui.dummy(Vector2(availW, 0))
		end
	end

	if visibleCount == 0 then
		ui.spacing()
		if self.surveyUnscannedOnly then
			ui.textColored(colors.econMajorImport, "All celestial bodies in " .. Game.system.name .. " have been surveyed!")
			ui.textColored(colors.fontDim, "Uncheck 'Show Unscanned Only' above to view all bodies, or sell survey data at Universal Cartographics.")
		else
			ui.textColored(colors.fontDim, "No scannable bodies found in this system.")
		end
	end
end

function scanDisplay:drawScanCard(scan, queueIndex)
	local sBody = scan.bodyPath:GetSystemBody()
	local bodyName = sBody and sBody.name or "Unknown Body"
	local starSys = scan.bodyPath:GetStarSystem()
	local sysName = starSys and starSys.name or ""
	local isCurSystem = Game.system and (Game.system.name == sysName)
	local body = isCurSystem and self.scanMgr:GetScanBodyByType(scan) or nil

	local maxRange = sBody and math.max(sBody.radius * (scan.orbital and 6.0 or 4.0), scan.orbital and 12000000 or 8000000) or 0
	local altitudeStr = ui.Format.Distance(maxRange)

	local isPercentScan = scan.freeScan or (not scan.orbital) or scan.targetCoverage <= 1.0
	local completionRatio = math.min(1.0, scan.coverage / (scan.targetCoverage or 1.0))
	local completionStr = string.format("%.0f%%", completionRatio * 100)

	local isActive = self.scanMgr:GetActiveScan() == scan
	local hasSensor = self.scanMgr:HasSensorForScan(scan)
	local isNavTarget = body and (self.ship:GetNavTarget() == body)

	local childFlags = ui.ChildFlags { "AlwaysUseWindowPadding", "Borders", "AutoResizeY" }
	local bgCol = isActive and Color(20, 36, 54, 225) or Color(18, 22, 32, 215)
	local borderCol = isNavTarget and colors.uiPrimaryLight or Color(45, 55, 75, 130)

	ui.withStyleColors({
		ChildBg = bgCol,
		Border = borderCol,
	}, function()
		ui.withStyleVars({
			ChildRounding = 4.0,
			WindowPadding = Vector2(8, 8),
		}, function()
			ui.child("##qCard_" .. scan.id, Vector2(0, 0), { "NoScrollbar" }, childFlags, function()
				-- Badges row
				ui.withFont(pionillium.details, function()
					local modeCol = scan.orbital and colors.uiPrimaryLight or colors.econMajorImport
					local posBadge = queueIndex and string.format("#%d ", queueIndex) or ""
					ui.textColored(modeCol, posBadge .. (scan.orbital and "[ORBITAL]" or "[SURFACE]"))
					ui.sameLine()
					if scan.freeScan then
						ui.textColored(colors.uiPrimaryLight, "[SURVEY]")
					else
						ui.textColored(colors.alertYellow, "[MISSION CONTRACT]")
					end
					ui.sameLine()
					ui.textColored(colors.fontDim, sysName)
				end)

				-- Body name (Clickable to target and prioritize)
				ui.withFont(pionillium.body, function()
					local nameCol = isNavTarget and colors.uiPrimaryLight or colors.font
					if body and ui.selectable((isNavTarget and "● " or "") .. bodyName .. "##qsel" .. scan.id, isNavTarget) then
						self.ship:SetNavTarget(body)
						self.scanMgr:PrioritizeBodyInQueue(body)
						ui.playSfx("OK")
					elseif not body then
						ui.text(bodyName)
					end
				end)
				if body and ui.isItemHovered() then
					ui.setTooltip("Click to target & prioritize to top of queue")
				end

				-- Details row
				ui.withFont(pionillium.details, function()
					if isPercentScan then
						ui.text(string.format("Progress: %s   •   Max Range: %s", completionStr, altitudeStr))
					else
						local targetStr = ui.Format.Area(scan.targetCoverage * 1e6)
						local curAreaStr = ui.Format.Area(scan.coverage * 1e6)
						ui.text(string.format("Coverage: %s / %s   •   Max Range: %s", curAreaStr, targetStr, altitudeStr))
					end

					if not hasSensor then
						ui.textColored(colors.alertRed, scan.orbital and "Requires Orbital Scanner (Not Equipped)" or "Requires Surface Scanner (Not Equipped)")
					elseif not isCurSystem then
						ui.textColored(colors.fontDim, "Requires Hyperspace Jump to " .. sysName)
					elseif body then
						local dist = self.ship:GetPositionRelTo(body):length()
						if dist <= maxRange then
							ui.textColored(colors.econMajorImport, "In Scan Range (" .. ui.Format.Distance(dist) .. ")")
						else
							ui.textColored(colors.fontDim, "Distance: " .. ui.Format.Distance(dist))
						end
					end
				end)

				ui.spacing()

				-- Actions
				local availW = ui.getContentRegion().x
				local spacing = ui.getItemSpacing().x
				local btnH = 22
				local discardBtnW = scan.freeScan and 24 or 0
				local actBtnW = availW - (discardBtnW > 0 and (discardBtnW + spacing) or 0)

				if isActive then
					if ui.button("Active [Pause]##" .. scan.id, Vector2(actBtnW, btnH), ui.theme.buttonColors.selected) then
						self.scanMgr:ClearActiveScan()
						ui.playSfx("Cancel")
					end
				else
					local canAct = isCurSystem and hasSensor
					if ui.button("Activate / Move to Top##" .. scan.id, Vector2(actBtnW, btnH), canAct and ui.theme.buttonColors.deselected or ui.theme.buttonColors.disabled) then
						if canAct then
							if body then
								self.ship:SetNavTarget(body)
								self.scanMgr:PrioritizeBodyInQueue(body)
							else
								self.scanMgr:SetActiveScan(scan.id)
							end
							ui.playSfx("OK")
						else
							ui.playSfx("Cancel")
						end
					end
				end

				if scan.freeScan then
					ui.sameLine()
					if ui.button("X##del" .. scan.id, Vector2(discardBtnW, btnH)) then
						self.scanMgr:CancelScan(scan.id)
						ui.playSfx("Cancel")
					end
					if ui.isItemHovered() then
						ui.setTooltip("Discard survey job from queue")
					end
				end
			end)
		end)
	end)

	ui.spacing()
end

function scanDisplay:drawScanQueue()
	local active = self.scanMgr:GetActiveScan()
	local pending = self.scanMgr:GetPendingScans()

	local allList = {}
	if active then
		table.insert(allList, active)
	end
	for _, s in ipairs(pending) do
		table.insert(allList, s)
	end

	local allOrbital = {}
	local allSurface = {}

	for _, s in ipairs(allList) do
		if s.orbital then
			table.insert(allOrbital, s)
		else
			table.insert(allSurface, s)
		end
	end

	-- Sub-filter pills
	local filterBtnW = (ui.getContentRegion().x - ui.getItemSpacing().x * 2) / 3
	local btnH = 22
	local selectedBtn = ui.theme.buttonColors.selected
	local deselectedBtn = ui.theme.buttonColors.deselected

	if ui.button(string.format("All (%d)", #allList), Vector2(filterBtnW, btnH), self.queueFilter == "all" and selectedBtn or deselectedBtn) then
		self.queueFilter = "all"
	end
	ui.sameLine()
	if ui.button(string.format("Orbital (%d)", #allOrbital), Vector2(filterBtnW, btnH), self.queueFilter == "orbital" and selectedBtn or deselectedBtn) then
		self.queueFilter = "orbital"
	end
	ui.sameLine()
	if ui.button(string.format("Surface (%d)", #allSurface), Vector2(filterBtnW, btnH), self.queueFilter == "surface" and selectedBtn or deselectedBtn) then
		self.queueFilter = "surface"
	end

	ui.spacing()
	ui.separator()
	ui.spacing()

	-- Hardware auto-switch note
	ui.withFont(pionillium.details, function()
		ui.textColored(colors.fontDim, "Targeting any celestial body prioritizes it to top of queue.")
	end)
	ui.spacing()

	local displayList = allList
	if self.queueFilter == "orbital" then
		displayList = allOrbital
	elseif self.queueFilter == "surface" then
		displayList = allSurface
	end

	if #displayList == 0 then
		ui.spacing()
		ui.textColored(colors.fontDim, "No queued scans matching this filter.")
		ui.textColored(colors.fontDim, "Use 'System Survey' tab to queue unscanned planets in this system.")
	else
		for idx, scan in ipairs(displayList) do
			self:drawScanCard(scan, idx)
		end
	end
end

function scanDisplay:drawCompletedData()
	local unsoldList = Cartography.GetUnsoldList()
	local totalUnsold = Cartography.GetTotalUnsoldValue()
	local completedScans = self.scanMgr:GetCompletedScans()

	ui.withFont(pionillium.heading, function()
		ui.text("Cartography Survey Data")
	end)

	ui.withFont(pionillium.details, function()
		ui.textColored(colors.fontDim, "Survey data ready to sell at Universal Cartographics")
	end)

	ui.spacing()

	if totalUnsold > 0 then
		local Format = require 'Format'
		ui.textColored(colors.econMajorImport, "Total Estimated Payout: " .. Format.Money(totalUnsold))
		ui.spacing()

		for _, sysRec in ipairs(unsoldList) do
			ui.group(function()
				ui.spacing()
				ui.withFont(pionillium.body, function()
					ui.text(sysRec.name)
					ui.sameLine()
					ui.textColored(colors.econMajorImport, Format.Money(sysRec.totalPay or sysRec.payout or 0))
				end)
				ui.withFont(pionillium.details, function()
					local sysTag = sysRec.isKnownSystem and " (Known System - 20%)" or " (Uncharted - 100%)"
					ui.textColored(colors.fontDim, string.format("%d bodies surveyed%s", #sysRec.bodies, sysTag))
				end)
				ui.spacing()
				ui.separator()
			end)
		end
	else
		ui.textColored(colors.fontDim, "No unsold cartographic survey data on file.")
		ui.textColored(colors.fontDim, "Use System Survey to scan unscanned planets.")
	end

	ui.spacing()
	ui.separator()
	ui.spacing()

	ui.withFont(pionillium.heading, function()
		ui.text(string.format("Completed Mission Scans (%d)", #completedScans))
	end)

	ui.spacing()

	if #completedScans > 0 then
		for _, scan in ipairs(completedScans) do
			local sBody = scan.bodyPath:GetSystemBody()
			local bName = sBody and sBody.name or "Unknown Body"
			local starSys = scan.bodyPath:GetStarSystem()
			local sysName = starSys and starSys.name or ""
			ui.group(function()
				ui.spacing()
				ui.withFont(pionillium.body, function()
					ui.text(bName .. ", " .. sysName)
				end)
				ui.withFont(pionillium.details, function()
					ui.textColored(colors.econMajorImport, scan.orbital and "Orbital Scan Complete ✓" or "Surface Scan Complete ✓")
					ui.textColored(colors.fontDim, "Turn in at Bulletin Board in destination system.")
				end)
				ui.spacing()
				ui.separator()
			end)
		end
	else
		ui.textColored(colors.fontDim, "No completed mission scans awaiting turn-in.")
	end
end

function scanDisplay:drawTitle()
	ui.text(ls.SCAN_MANAGER or "Scan Manager")
	ui.sameLine()

	if self.scanMgr then
		local state = self.scanMgr:GetState()
		local stateText = ls["STATE_" .. state] or state
		local color = colors.fontDim
		if state == "SCANNING" then
			color = colors.econMajorImport
		elseif state == "MIN_ALTITUDE" or state == "OUT_OF_RANGE" then
			color = colors.alertYellow
		elseif state == "NO_SENSORS" then
			color = colors.alertRed
		end

		ui.textColored(color, "(" .. stateText .. ")")
		ui.sameLine()
	end

	-- Draw debug display button
	if self.showDebug or (ui.shiftHeld() and ui.altHeld()) then
		local buttonSize = Vector2(ui.getLineHeight())
		ui.addCursorPos(Vector2(ui.getContentRegion().x - buttonSize.x * 1.5, 0))
		if ui.mainMenuButton(icons.alert1, "Debug Display", false, buttonSize) then
			self.showDebug = not self.showDebug
		end
	end
end

function scanDisplay:drawBody()
	ui.spacing()

	-- 1. Hardware status & System Discovery Scanner
	self:drawHardwareBar()
	ui.spacing()
	self:drawDiscoverySection()
	ui.spacing()
	ui.separator()

	-- 2. Active Scan HUD (pinned if active)
	self:drawActiveScanHUD()

	-- 3. Main Navigation Tabs
	local availW = ui.getContentRegion().x
	local tabW = (availW - ui.getItemSpacing().x * 2) / 3
	local btnH = ui.getButtonHeight()
	local selectedBtn = ui.theme.buttonColors.selected
	local deselectedBtn = ui.theme.buttonColors.deselected

	if ui.button("System Survey", Vector2(tabW, btnH), self.activeTab == 1 and selectedBtn or deselectedBtn) then
		self.activeTab = 1
	end
	ui.sameLine()
	local totalQueueCount = #self.scanMgr:GetPendingScans() + (self.scanMgr:GetActiveScan() and 1 or 0)
	if ui.button(string.format("Queue (%d)", totalQueueCount), Vector2(tabW, btnH), self.activeTab == 2 and selectedBtn or deselectedBtn) then
		self.activeTab = 2
	end
	ui.sameLine()
	if ui.button("Completed", Vector2(tabW, btnH), self.activeTab == 3 and selectedBtn or deselectedBtn) then
		self.activeTab = 3
	end

	ui.spacing()
	ui.separator()
	ui.spacing()

	-- 4. Active Tab Content
	if self.activeTab == 1 then
		self:drawSystemSurvey()
	elseif self.activeTab == 2 then
		self:drawScanQueue()
	else
		self:drawCompletedData()
	end
end

function scanDisplay:refresh()
	self.ship = Game.player
	self.scanMgr = self.ship and self.ship:GetComponent("ScanManager")
	if self.ship and self.scanMgr then
		local navTarget = self.ship:GetNavTarget()
		if navTarget and navTarget ~= self.lastNavTarget then
			self.lastNavTarget = navTarget
			self.scanMgr:PrioritizeBodyInQueue(navTarget)
		elseif not navTarget then
			self.lastNavTarget = nil
		end

		-- Ensure surface scan displays true percentage scanned and terminates at 85%
		local active = self.scanMgr:GetActiveScan()
		if active and not active.orbital then
			active.targetCoverage = 1.0
			if active.scannedCells and active.totalCells and active.totalCells > 0 then
				local rawRatio = active.scannedCells / active.totalCells
				if rawRatio >= 0.85 then
					active.coverage = 1.0
					active.complete = true
					self.scanMgr.activeScan = nil
					self.scanMgr.activeCallback = nil
					self.scanMgr.withinParameters = false
					Game.SetSurfaceScanOverlay(nil)
					local b = self.scanMgr:GetScanBodyByType(active)
					if b and active.freeScan then
						Cartography.RecordBodyScan(b, false)
					end
					self.scanMgr:AdvanceQueue()
				else
					active.coverage = rawRatio
				end
			end
		end
	end
end

gameView.registerSidebarModule("scout.scanDisplay", scanDisplay)

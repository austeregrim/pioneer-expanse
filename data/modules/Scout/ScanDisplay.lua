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
	side = "left",
	icon = icons.equip_orbit_scanner,
	tooltip = ls.SCAN_MANAGER,
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
}

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

	ui.spacing()
	ui.group(function()
		ui.separator()
		ui.spacing()

		-- Mode badge & system
		local modeLabel = scan.orbital and "ORBITAL SURVEY" or "SURFACE MAPPING"
		local modeCol = scan.orbital and colors.uiPrimaryLight or colors.econMajorImport
		ui.withFont(pionillium.details, function()
			ui.textColored(modeCol, "[" .. modeLabel .. "]")
			ui.sameLine()
			ui.textColored(colors.fontDim, sysName)
		end)

		ui.withFont(pionillium.heading, function()
			ui.text(bodyName)
		end)

		-- Telemetry range & altitude
		local body = self.scanMgr:GetScanBodyByType(scan)
		if body then
			local dist = self.ship:GetPositionRelTo(body):length()
			local maxDist = self.scanMgr.GetScanMaxDistance(body, scan.orbital)
			local inRange = dist <= maxDist
			ui.withFont(pionillium.details, function()
				if inRange then
					ui.textColored(colors.econMajorImport, "IN SCAN RANGE • Recording Data")
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
		local halfW = (availW - ui.getItemSpacing().x) * 0.5
		local btnH = ui.getButtonHeight()

		if ui.button("Pause Scan", Vector2(halfW, btnH)) then
			self.scanMgr:ClearActiveScan()
			ui.playSfx("Cancel")
		end
		ui.sameLine()
		if body and ui.button("Target Nav", Vector2(halfW, btnH)) then
			self.ship:SetNavTarget(body)
			ui.playSfx("OK")
		end
		ui.spacing()
		ui.separator()
	end)
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
	local bBtnH = ui.getButtonHeight()
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

			local cardStartPos = ui.getCursorScreenPos()
			local availW = ui.getContentRegion().x

			ui.group(function()
				ui.spacing()

				-- Clickable body name selects nav target
				ui.withFont(pionillium.heading, function()
					if ui.selectable(bName .. "##sel" .. pathKey, isNavTarget) then
						player:SetNavTarget(b)
						ui.playSfx("OK")
					end
				end)
				if ui.isItemHovered() then
					ui.setTooltip("Click to select as Navigation Target")
				end

				if isNavTarget then
					ui.withFont(pionillium.details, function()
						ui.textColored(colors.uiPrimaryLight, "● NAV TARGET LOCKED")
					end)
				end

				ui.withFont(pionillium.details, function()
					local isKnownSys = not Cartography.IsSystemOriginallyUnexplored(Game.system)
					local sysTag = isKnownSys and "Known System (20% payout)" or "Uncharted System (Full payout)"
					ui.textColored(colors.fontDim, string.format("%s  •  Radius %s  •  Range: %s  •  %s", typeStr, radiusStr, distStr, sysTag))
				end)

				ui.spacing()

				local spacing = ui.getItemSpacing().x
				local btnH = ui.getButtonHeight()
				local scanBtnW = (availW - spacing) * 0.5

				-- Orbital Scan Button
				if orbStatus == "ACTIVE" then
					if ui.button("Orbital [Scanning]##" .. pathKey, Vector2(scanBtnW, btnH), ui.theme.buttonColors.selected) then
						self.scanMgr:ClearActiveScan()
						ui.playSfx("Cancel")
					end
				elseif orbStatus == "QUEUED" then
					if ui.button("Orbital [Queued]##" .. pathKey, Vector2(scanBtnW, btnH), ui.theme.buttonColors.deselected) then
						self.scanMgr:SetActiveScan(orbScan.id)
						ui.playSfx("OK")
					end
				elseif orbUnsold then
					ui.button("Orbital ✓ [Stored]##" .. pathKey, Vector2(scanBtnW, btnH), ui.theme.buttonColors.disabled)
					if ui.isItemHovered() then
						ui.setTooltip("Survey data stored on ship computer. Sell at Universal Cartographics to clear buffer.")
					end
				elseif orbSold then
					if ui.button("Orbital [Rescan]##" .. pathKey, Vector2(scanBtnW, btnH), ui.theme.buttonColors.deselected) then
						local scanId, err = self.scanMgr:StartFreeScan(b, true)
						if scanId then
							player:SetNavTarget(b)
							ui.playSfx("OK")
						else
							print(string.format("StartFreeScan (orbital rescan) failed for %s: %s", tostring(sb.name), tostring(err)))
							ui.playSfx("Cancel")
						end
					end
					if ui.isItemHovered() then
						ui.setTooltip("Previously sold to Universal Cartographics. Click to queue a fresh telemetry update.")
					end
				else
					if ui.button("+ Orbit Scan##" .. pathKey, Vector2(scanBtnW, btnH)) then
						local scanId, err = self.scanMgr:StartFreeScan(b, true)
						if scanId then
							player:SetNavTarget(b)
							ui.playSfx("OK")
						else
							print(string.format("StartFreeScan (orbital) failed for %s: %s", tostring(sb.name), tostring(err)))
							ui.playSfx("Cancel")
						end
					end
				end

				ui.sameLine()

				-- Surface Scan Button
				if not isSolid then
					ui.button("-##nosurf" .. pathKey, Vector2(scanBtnW, btnH), ui.theme.buttonColors.disabled)
					if ui.isItemHovered() then
						ui.setTooltip("No solid surface to map")
					end
				elseif surfStatus == "ACTIVE" then
					if ui.button("Surface [Scanning]##" .. pathKey, Vector2(scanBtnW, btnH), ui.theme.buttonColors.selected) then
						self.scanMgr:ClearActiveScan()
						ui.playSfx("Cancel")
					end
				elseif surfStatus == "QUEUED" then
					if ui.button("Surface [Queued]##" .. pathKey, Vector2(scanBtnW, btnH), ui.theme.buttonColors.deselected) then
						self.scanMgr:SetActiveScan(surfScan.id)
						ui.playSfx("OK")
					end
				elseif surfUnsold then
					ui.button("Surface ✓ [Stored]##" .. pathKey, Vector2(scanBtnW, btnH), ui.theme.buttonColors.disabled)
					if ui.isItemHovered() then
						ui.setTooltip("Surface mapping stored on ship computer. Sell at Universal Cartographics to clear buffer.")
					end
				elseif surfSold then
					if ui.button("Surface [Rescan]##" .. pathKey, Vector2(scanBtnW, btnH), ui.theme.buttonColors.deselected) then
						local scanId, err = self.scanMgr:StartFreeScan(b, false)
						if scanId then
							player:SetNavTarget(b)
							ui.playSfx("OK")
						else
							print(string.format("StartFreeScan (surface rescan) failed for %s: %s", tostring(sb.name), tostring(err)))
							ui.playSfx("Cancel")
						end
					end
					if ui.isItemHovered() then
						ui.setTooltip("Previously sold to Universal Cartographics. Click to queue a fresh surface mapping pass.")
					end
				else
					if ui.button("+ Surface Scan##" .. pathKey, Vector2(scanBtnW, btnH)) then
						local scanId, err = self.scanMgr:StartFreeScan(b, false)
						if scanId then
							player:SetNavTarget(b)
							ui.playSfx("OK")
						else
							print(string.format("StartFreeScan (surface) failed for %s: %s", tostring(sb.name), tostring(err)))
							ui.playSfx("Cancel")
						end
					end
				end

				ui.spacing()
			end)

			local cardEndPos = ui.getCursorScreenPos()
			if isNavTarget then
				local pad = 2
				local minPos = Vector2(cardStartPos.x - pad, cardStartPos.y)
				local maxPos = Vector2(cardStartPos.x + availW + pad, cardEndPos.y)
				ui.addRect(minPos, maxPos, colors.uiPrimaryLight, 4, ui.RoundCornersAll, 2.0)
			end

			ui.separator()
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

function scanDisplay:drawScanCard(scan)
	local sBody = scan.bodyPath:GetSystemBody()
	local bodyName = sBody and sBody.name or "Unknown Body"
	local starSys = scan.bodyPath:GetStarSystem()
	local sysName = starSys and starSys.name or ""
	local isCurSystem = Game.system and (Game.system.name == sysName)
	local body = isCurSystem and self.scanMgr:GetScanBodyByType(scan) or nil

	local maxRange = sBody and math.max(sBody.radius * (scan.orbital and 6.0 or 4.0), scan.orbital and 12000000 or 8000000) or 0
	local altitudeStr = ui.Format.Distance(maxRange)

	local isPercentScan = scan.freeScan or scan.targetCoverage <= 1.0
	local targetStr = isPercentScan and string.format("%.0f%%", scan.targetCoverage * 100) or ui.Format.Area(scan.targetCoverage * 1e6)
	local completionStr = isPercentScan and string.format("%.0f%%", math.min(100, scan.coverage * 100)) or ui.Format.Area(scan.coverage * 1e6)

	local isActive = self.scanMgr:GetActiveScan() == scan
	local hasSensor = self.scanMgr:HasSensorForScan(scan)
	local isNavTarget = body and (self.ship:GetNavTarget() == body)
	local cardStartPos = ui.getCursorScreenPos()
	local availW = ui.getContentRegion().x

	ui.group(function()
		ui.spacing()
		-- Badges row
		ui.withFont(pionillium.details, function()
			local modeCol = scan.orbital and colors.uiPrimaryLight or colors.econMajorImport
			ui.textColored(modeCol, scan.orbital and "[ORBITAL]" or "[SURFACE]")
			ui.sameLine()
			if scan.freeScan then
				ui.textColored(colors.uiPrimaryLight, "[SURVEY]")
			else
				ui.textColored(colors.alertYellow, "[MISSION CONTRACT]")
			end
			ui.sameLine()
			ui.textColored(colors.fontDim, sysName)
		end)

		-- Body name (Clickable to target)
		ui.withFont(pionillium.heading, function()
			if body and ui.selectable(bodyName .. "##qsel" .. scan.id, isNavTarget) then
				self.ship:SetNavTarget(body)
				ui.playSfx("OK")
			else
				ui.text(bodyName)
			end
		end)
		if body and ui.isItemHovered() then
			ui.setTooltip("Click to select as Navigation Target")
		end

		if isNavTarget then
			ui.withFont(pionillium.details, function()
				ui.textColored(colors.uiPrimaryLight, "● NAV TARGET LOCKED")
			end)
		end

		-- Details row
		ui.withFont(pionillium.details, function()
			ui.text(string.format("Coverage: %s / %s   •   Max Range: %s", completionStr, targetStr, altitudeStr))

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
		local spacing = ui.getItemSpacing().x
		local btnH = ui.getButtonHeight()
		local discardBtnW = scan.freeScan and (btnH + 12) or 0
		local actBtnW = availW - (discardBtnW > 0 and (discardBtnW + spacing) or 0)

		if isActive then
			if ui.button("Active [Pause]##" .. scan.id, Vector2(actBtnW, btnH), ui.theme.buttonColors.selected) then
				self.scanMgr:ClearActiveScan()
				ui.playSfx("Cancel")
			end
		else
			local canAct = isCurSystem and hasSensor
			if ui.button("Activate Scan##" .. scan.id, Vector2(actBtnW, btnH), canAct and ui.theme.buttonColors.deselected or ui.theme.buttonColors.disabled) then
				if canAct then
					self.scanMgr:SetActiveScan(scan.id)
					if body then
						self.ship:SetNavTarget(body)
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

		ui.spacing()
	end)

	local cardEndPos = ui.getCursorScreenPos()
	if isNavTarget then
		local pad = 2
		local minPos = Vector2(cardStartPos.x - pad, cardStartPos.y)
		local maxPos = Vector2(cardStartPos.x + availW + pad, cardEndPos.y)
		ui.addRect(minPos, maxPos, colors.uiPrimaryLight, 4, ui.RoundCornersAll, 2.0)
	end

	ui.separator()
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
	local btnH = ui.getButtonHeight()
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
		ui.textColored(colors.fontDim, "Selecting any job automatically engages matching scanner.")
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
		for _, scan in ipairs(displayList) do
			self:drawScanCard(scan)
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
	local state = self.scanMgr:GetState()
	local stateText = ls["STATE_" .. state] or state
	local color = colors.font
	if state == "SCANNING" then
		color = colors.econMajorImport
	elseif state == "MIN_ALTITUDE" or state == "OUT_OF_RANGE" then
		color = colors.alertYellow
	elseif state == "NO_SENSORS" then
		color = colors.alertRed
	end

	ui.textColored(color, stateText)
	ui.sameLine()

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
	self.scanMgr = self.ship:GetComponent("ScanManager")
end

gameView.registerSidebarModule("scout.scanDisplay", scanDisplay)

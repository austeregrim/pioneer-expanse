-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui = require 'pigui'
local Vector2 = _G.Vector2

-- cache ui
local font_heading = ui.fonts.pionillium.heading
local font_content = ui.fonts.pionillium.body
local colors = ui.theme.colors
local icons = ui.theme.icons

local lc = require 'Lang'.GetResource("core")
local lui = require 'Lang'.GetResource("ui-core")
local gameView = require 'pigui.views.game'
local ShipRegistry = require 'modules.ShipRegistry.ShipRegistry'

-- cache player each frame
local player = nil ---@type Player

local scannerWindowFlags = ui.WindowFlags { "NoTitleBar", "NoResize",
	"NoFocusOnAppearing", "NoBringToFrontOnFocus" }

-- Format the mass in tonnes
-- The ui.Format() function reformats the units whereas we always want to
-- display using tonnes.
local function formatMass(massInTonnes)
	return string.format("%d %s", massInTonnes or 0, lc.UNIT_TONNES)
end

-- draw a 2-column table of name/value data with optional headings
local function drawTable(data, heading1, heading2)
	-- data is a table containing:
	-- - name of item
	-- - value of item
	if ui.beginTable("Data", 2) then
		ui.tableSetupColumn(heading1 or "", { "WidthStretch" })
		ui.tableSetupColumn(heading2 or "", { "WidthFixed" } )
		if heading1 or heading2 then
			ui.withFont(font_heading, function()
				ui.tableHeadersRow()
			end)
		end
		for _, item in pairs(data) do
			ui.tableNextRow()
			ui.tableNextColumn()
			ui.text(item.name)
			ui.tableNextColumn()
			if item.color then
				ui.withStyleColors({ Text = item.color }, function()
					ui.text(item.value)
				end)
			else
				ui.text(item.value)
			end
		end
		ui.endTable()
	end
end

local LIGHT_SPEED = 299792458.0

local function formatSupercruiseSpeed(speed)
	if speed >= 0.1 * LIGHT_SPEED then
		return string.format("%.2f c", speed / LIGHT_SPEED)
	elseif speed >= 1e6 then
		return string.format("%.1f Mm/s", speed / 1e6)
	else
		return string.format("%.0f km/s", speed / 1e3)
	end
end

---@param target Ship
local function buildTargetScannerRows(target, inSupercruise)
	local targetInSC = target:GetFlightState() == "SUPERCRUISE"
	local isWanted = target.IsWanted and target:IsWanted() or false
	local bounty = (isWanted and target.GetBounty) and target:GetBounty() or 0
	local wantedText = isWanted
		and (bounty > 0 and string.format("WANTED (%s)", ui.Format.Money(bounty, false)) or "WANTED")
		or "CLEAN"
	local wantedColor = isWanted and Color(255, 85, 75, 255) or Color(100, 225, 165, 255)

	local rec = ShipRegistry.GetRecord(target:GetLabel())
	local vesselName = (target.shipName and target.shipName ~= "" and target.shipName ~= target.label) and target.shipName or (rec and rec.shipName)

	local data
	if inSupercruise then
		local scSpeed = target.GetSupercruiseSpeed and target:GetSupercruiseSpeed() or 0
		data = {
			{ name = "STATUS", value = wantedText, color = wantedColor },
			{ name = "VELOCITY", value = targetInSC and formatSupercruiseSpeed(scSpeed) or "SUBLIGHT" },
			{ name = lui.HUD_CARGO_MASS, value = "SUBLIGHT SCAN ONLY", color = colors.fontDim },
			{ name = "HULL / SHIELDS", value = "SUBLIGHT SCAN ONLY", color = colors.fontDim },
		}
	else
		local engine = target:GetInstalledHyperdrive()
		local fsdOffline = target.IsFsdOffline and target:IsFsdOffline() or false
		data = {
			{ name = "STATUS", value = wantedText, color = wantedColor },
			{ name = lui.HYPERDRIVE, value = fsdOffline and "FSD OFFLINE" or (engine and engine:GetName() or lui.NO_DRIVE),
			  color = fsdOffline and Color(255, 85, 75, 255) or nil },
			{ name = lui.HUD_MASS, value = formatMass(target.staticMass) },
			{ name = lui.HUD_CARGO_MASS, value = formatMass(target.usedCargo) },
		}
	end

	if rec and rec.commanderName and rec.commanderName ~= "" then
		table.insert(data, { name = "COMMANDER", value = rec.commanderName })
	end
	if vesselName and vesselName ~= "" then
		table.insert(data, { name = "VESSEL", value = vesselName })
	end
	if rec then
		local homePort = (rec.role == "PIRATE") and "Unregistered"
			or ((rec.homeStationName and rec.homeSystemName) and string.format("%s (%s)", rec.homeStationName, rec.homeSystemName) or rec.homeSystemName)
		if homePort and homePort ~= "" then
			table.insert(data, { name = "HOME PORT", value = homePort, color = (rec.role == "PIRATE") and Color(255, 175, 90, 255) or colors.fontDim })
		end
	end

	if not inSupercruise and target.GetSubsystemHealthSummary then
		local tH = target:GetSubsystemHealthSummary()
		if tH <= 0.001 then
			table.insert(data, { name = "PROPULSION", value = "DISABLED (DRIFTING)", color = Color(255, 85, 75, 255) })
		end
	end

	local sub = (not inSupercruise and target == player:GetCombatTarget() and player.GetTargetSubsystem) and player:GetTargetSubsystem() or nil
	if sub then
		local pct = math.floor((sub.integrity or 1.0) * 100 + 0.5)
		local valText = sub.disabled and "OFFLINE (0%)" or string.format("%s %d%%", string.upper(sub.name or sub.id), pct)
		local subCol = sub.disabled and Color(255, 85, 75, 255)
			or ((sub.integrity or 1.0) < 0.75 and Color(255, 195, 50, 255) or Color(100, 225, 165, 255))
		table.insert(data, { name = "SUBSYSTEM [ ] ]", value = valText, color = subCol })
	end

	return data
end

---@param target Ship
local function displayTargetScannerFor(target, maxWidth)
	local playerInSC = player:GetFlightState() == "SUPERCRUISE"
	local targetInSC = target:GetFlightState() == "SUPERCRUISE"
	local inSupercruise = playerInSC or targetInSC
	local data = buildTargetScannerRows(target, inSupercruise)

	if inSupercruise then
		ui.withFont(font_content, function()
			drawTable(data, target.label, target:GetShipType())
		end)
		return
	end

	local hull = target:GetHullPercent()
	local shield = target:GetShieldsPercent() or 0

	ui.withFont(font_content, function()
		drawTable(data, target.label, target:GetShipType())
	end)

	local spacing = ui.gauge_height * 1.4
	local yOff = Vector2(0, ui.gauge_height * 0.5)
	local uiPos = ui.getCursorScreenPos()

	if shield then
		ui.gauge(uiPos + yOff, shield, nil, nil, 0, 100, icons.shield, true,
			colors.gaugeShield, lui.HUD_SHIELD_STRENGTH, maxWidth)
		yOff.y = yOff.y + spacing
	end
	ui.gauge(uiPos + yOff, hull, nil, nil, 0, 100, icons.hull, true,
		colors.gaugeHull, lui.HUD_HULL_STRENGTH, maxWidth)
	yOff.y = yOff.y + spacing
end

local function displayTargetScanner(min, max)
	local scanner_level = (player["target_scanner_level_cap"] or 0)
	local hasSubTarget = (player.HasSubsystemTargeting and player:HasSubsystemTargeting() and player:GetTargetSubsystem() ~= nil)
	if scanner_level == 0 and not hasSubTarget then return end

	-- what is the difference between target_scanner and advanced_target_scanner?
	local target = player:GetNavTarget()
	if (scanner_level == 0 and hasSubTarget) or not target or not target:IsShip() then
		target = player:GetCombatTarget()
	end
	if not target or not target:IsShip() then
		return
	end

	local playerInSC = player:GetFlightState() == "SUPERCRUISE"
	local targetInSC = target:GetFlightState() == "SUPERCRUISE"
	local inSupercruise = playerInSC or targetInSC
	local rows = buildTargetScannerRows(target, inSupercruise)

	local textHeight = ui.getTextLineHeightWithSpacing()
	local headingHeight = textHeight
	ui.withFont(font_heading, function()
		headingHeight = ui.getTextLineHeightWithSpacing()
	end)
	local height = inSupercruise
		and (textHeight * #rows + headingHeight + ui.gauge_height * 0.5)
		or ((ui.gauge_height * 1.4) * 2 + textHeight * #rows + headingHeight + ui.gauge_height * 0.5)

	local pos, size = ui.rectcut(min, max, height, ui.sides.bottom)

	ui.setNextWindowPos(pos, "Always")
	ui.setNextWindowSize(size, "Always")
	ui.setNextWindowPadding(Vector2(0, 0))
	ui.window("TargetScanner", scannerWindowFlags, function()
		displayTargetScannerFor(target, size.x)
	end)
end

local function displayCloudScanner(min, max)
	local hypercloud_level = (player["hypercloud_analyzer_cap"] or 0)
	local target = player:GetNavTarget()

	if hypercloud_level == 0 or not target or not target:IsHyperspaceCloud() then
		return
	end

	local arrival = target:IsArrival()
	local ship = target:GetShip()

	local height = ui.getTextLineHeightWithSpacing(font_heading)
		+ ui.getTextLineHeightWithSpacing() * 4
		+ ui.getItemSpacing().y

	local pos, size = ui.rectcut(min, max, height, ui.sides.bottom)

	ui.setNextWindowPos(pos, "Always")
	ui.setNextWindowSize(size, "Always")
	ui.setNextWindowPadding(Vector2(0, 0))
	ui.window("CloudScanner", scannerWindowFlags, function()
		ui.addRectFilled(pos, pos + Vector2(ui.getContentRegion().x,
		                 ui.getFrameHeight()), colors.TableHeaderBg, 0,
		                 ui.RoundCornersNone)
		ui.withFont(font_heading, function()
			ui.text(target:GetLabel())
		end)
		if ship then
			-- NOTE: ships in arrival clouds have their destination set to the
			-- source system. This should probably get refactored some time in
			-- the future. While clever reuse of existing state, it makes for
			-- challenging maintenance and understanding of the code.
			local _,systemName = ship:GetHyperspaceDestination()
			local systemLabel = arrival and lui.HUD_HYPERSPACE_ORIGIN or lui.HUD_HYPERSPACE_DESTINATION

			local data = {
				{ name = lui.SHIP_TYPE, value = ship:GetShipType()},
				{ name = lui.HUD_MASS, value = formatMass(ship.staticMass) },
				{ name = systemLabel, value = systemName },
				{ name = lui.HUD_ARRIVAL_DATE, value = ui.Format.Datetime(target:GetDueDate()) }
			}
			ui.withFont(font_content, function()
				drawTable(data)
			end)
		end
	end) -- window function
end

local function onDebugReload()
	package.reimport()
end

gameView.registerHudModule('target-scanner', {
	side = "right",
	showInHyperspace = false,
	debugReload = onDebugReload,
	draw = function(_, min, max)
		colors = ui.theme.colors
		icons = ui.theme.icons
		player = gameView.player
		-- restrict this HUD module to the width of the time window
		if ui.timeWindowSize then
			min.x = math.max(min.x, max.x - ui.timeWindowSize.x)
		end
		displayTargetScanner(min, max)
	end
})

gameView.registerHudModule('hyperspacecloud-scanner', {
	side = "right",
	showInHyperspace = false,
	debugReload = onDebugReload,
	draw = function(_, min, max)
		colors = ui.theme.colors
		icons = ui.theme.icons
		player = gameView.player
		-- restrict this HUD module to the width of the time window
		if ui.timeWindowSize then
			min.x = math.max(min.x, max.x - ui.timeWindowSize.x)
		end
		displayCloudScanner(min, max)
	end
})

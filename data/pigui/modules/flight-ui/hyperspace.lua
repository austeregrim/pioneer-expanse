-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui = require 'pigui'
local Engine = require 'Engine'
local Game = require 'Game'
local Vector2 = _G.Vector2
local Color = _G.Color

-- cache ui
local pionillium = ui.fonts.pionillium
local colors = ui.theme.colors

local lui = require 'Lang'.GetResource("ui-core")

local gameView = require 'pigui.views.game'

local colCyan  = Color(70, 210, 255, 230)
local colAmber = Color(255, 185, 40, 240)
local colRed   = Color(255, 80, 55, 240)
local colGreen = Color(75, 235, 130, 240)

local cachedTargetPathKey = nil
local cachedTargetName = ""

local function getSystemNameCached(path)
	if not path then return "" end
	local key = string.format("%d,%d,%d,%d", path.sectorX, path.sectorY, path.sectorZ, path.systemIndex)
	if key ~= cachedTargetPathKey then
		cachedTargetPathKey = key
		local sys = path:GetStarSystem()
		cachedTargetName = sys and sys.name or ""
	end
	return cachedTargetName
end

local function drawDashedCircle(centerPos, radius, col, segments, thickness)
	local step = (2.0 * math.pi) / segments
	for i = 0, segments - 1, 2 do
		local a0 = i * step
		local a1 = (i + 1) * step
		local p0 = Vector2(centerPos.x + math.cos(a0) * radius, centerPos.y + math.sin(a0) * radius)
		local p1 = Vector2(centerPos.x + math.cos(a1) * radius, centerPos.y + math.sin(a1) * radius)
		ui.addLine(p0, p1, col, thickness)
	end
end

local function drawTargetChevron(tipPos, dir2, size, col, thickness)
	local perp = Vector2(-dir2.y, dir2.x)
	local back = tipPos - dir2 * size
	ui.addLine(tipPos, back + perp * (size * 0.65), col, thickness)
	ui.addLine(tipPos, back - perp * (size * 0.65), col, thickness)
end

local function displayHyperspace()
	local uiPos = Vector2(ui.screenWidth / 2, ui.screenHeight / 2 - 10)
	local path,destName = Game.player:GetHyperspaceDestination()
	local label = string.interp(lui.HUD_IN_TRANSIT_TO_N_X_X_X, { system = destName, x = path.sectorX, y = path.sectorY, z = path.sectorZ })
	local r = ui.addStyledText(uiPos, ui.anchor.center, ui.anchor.bottom, label, colors.hyperspaceInfo, pionillium.large, nil, colors.lightBlackBackground)
	uiPos.y = uiPos.y + r.y + 20
	local percent = Game.GetHyperspaceTravelledPercentage() * 100
	label = string.interp(lui.HUD_JUMP_COMPLETE, { percent = string.format("%2.1f", percent) })
	ui.addStyledText(uiPos, ui.anchor.center, ui.anchor.top, label, colors.hyperspaceInfo, pionillium.large, nil, colors.lightBlackBackground)
end

local function displayHyperspaceTargetIndicator(player)
	if not player or player:IsDocked() or player:IsLanded() or not Game.system then
		return
	end

	local targetPath = (player:IsHyperspaceActive() and player:GetHyperspaceDestination()) or player:GetHyperspaceTarget()
	if not targetPath or Game.system.path:IsSameSystem(targetPath) then
		return
	end

	local dir = player:GetHyperspaceTargetDirection(targetPath)
	if not dir then
		return
	end

	local center = gameView.center or Vector2(ui.screenWidth * 0.5, ui.screenHeight * 0.5)
	local reticuleRadius = ui.reticuleCircleRadius or (math.min(ui.screenWidth, ui.screenHeight) / 8)
	local onscreen, pos, dirScreen = Engine.ProjectRelDirection(dir)
	local aligned, angleDeg = player:IsHyperspaceTargetAligned(targetPath)
	local blocker = player:GetHyperspaceTargetObscuredBy(targetPath)
	local jumpActive = player:IsHyperspaceActive()
	local destName = getSystemNameCached(targetPath)

	local col = colCyan
	if blocker then
		col = colRed
	elseif aligned then
		col = colGreen
	elseif jumpActive then
		col = colAmber
	end

	if onscreen then
		local r = 16
		if blocker then
			drawDashedCircle(pos, r, col, 16, 1.8)
		else
			ui.addCircle(pos, r, col, 24, aligned and 2.2 or 1.6)
			if aligned then
				ui.addCircle(pos, r + 5, col, 24, 1.2)
			end
		end
		-- Cross ticks outside the target system circle
		ui.addLine(Vector2(pos.x - r - 5, pos.y), Vector2(pos.x - r + 2, pos.y), col, 1.4)
		ui.addLine(Vector2(pos.x + r - 2, pos.y), Vector2(pos.x + r + 5, pos.y), col, 1.4)
		ui.addLine(Vector2(pos.x, pos.y - r - 5), Vector2(pos.x, pos.y - r + 2), col, 1.4)
		ui.addLine(Vector2(pos.x, pos.y + r - 2), Vector2(pos.x, pos.y + r + 5), col, 1.4)

		local label = destName
		if blocker then
			label = destName .. " [OBSCURED]"
		elseif jumpActive and not aligned then
			label = string.format("%s (%.0f°)", destName, angleDeg)
		elseif aligned and jumpActive then
			label = destName .. " [ALIGNED]"
		end
		ui.addStyledText(Vector2(pos.x, pos.y + r + 8), ui.anchor.center, ui.anchor.top, label, col, pionillium.small, nil, colors.lightBlackBackground)
	end

	-- Directional edge chevron on the center reticule when target is off-screen or outside the reticule ring
	if not onscreen or (pos - center):length() > reticuleRadius * 1.1 then
		local dir2 = Vector2(dirScreen.x, dirScreen.y)
		local len = dir2:length()
		if len > 0.001 then
			dir2 = dir2 / len
			local chevronPos = center + dir2 * (reticuleRadius * 0.94)
			drawTargetChevron(chevronPos, dir2, 9, col, 2.0)
			if jumpActive then
				local hintPos = center + dir2 * (reticuleRadius * 0.78)
				ui.addStyledText(hintPos, ui.anchor.center, ui.anchor.center, string.format("%.0f°", angleDeg), col, pionillium.tiny)
			end
		end
	end
end

local function displayHyperspaceCountdown()
	local player = Game.player
	if not player:IsHyperspaceActive() then
		return
	end

	local center = gameView.center or Vector2(ui.screenWidth * 0.5, ui.screenHeight * 0.5)
	local radius = ui.reticuleCircleRadius or (math.min(ui.screenWidth, ui.screenHeight) / 8)
	local uiPos = Vector2(center.x, center.y - radius - 90)

	local _, destName = player:GetHyperspaceDestination()
	local surging = player.IsHyperspaceJumpSurging and player:IsHyperspaceJumpSurging()
	if surging then
		ui.addStyledText(uiPos, ui.anchor.center, ui.anchor.bottom,
			"HYPERSPACE CONDUIT ENGAGED — " .. string.upper(destName),
			Color(225, 245, 255, 250), pionillium.large, nil, colors.lightBlackBackground)
		return
	end

	local waitingAlign = player:IsHyperspaceWaitingForAlign()
	local aligned, angleDeg = player:IsHyperspaceTargetAligned()
	local blocker = player:GetHyperspaceTargetObscuredBy()

	if waitingAlign then
		local pulse = 0.65 + 0.35 * math.sin(Game.time * 9.0)
		local alertCol = Color(255, math.floor(185 * pulse), 40, 245)
		local msg = string.format("FSD CHARGED — ALIGN WITH %s (%.0f° OFF)", string.upper(destName), angleDeg)
		ui.addStyledText(uiPos, ui.anchor.center, ui.anchor.bottom, msg, alertCol, pionillium.large, nil, colors.lightBlackBackground)
	else
		local countdown = math.ceil(player:GetHyperspaceCountdown())
		ui.addStyledText(uiPos, ui.anchor.center, ui.anchor.bottom,
			string.interp(lui.HUD_HYPERSPACING_TO_N_IN_N_SECONDS, { destination = destName, countdown = countdown }),
			colors.hyperspaceInfo, pionillium.large, nil, colors.lightBlackBackground)
	end

	local subPos = Vector2(uiPos.x, uiPos.y + 4)
	if blocker then
		ui.addStyledText(subPos, ui.anchor.center, ui.anchor.top,
			"TARGET OBSCURED BY " .. blocker:GetLabel(), colRed, pionillium.small, nil, colors.lightBlackBackground)
	elseif not aligned and not waitingAlign then
		ui.addStyledText(subPos, ui.anchor.center, ui.anchor.top,
			string.format("ALIGN WITH TARGET VECTOR (%.0f° OFF)", angleDeg), colAmber, pionillium.small, nil, colors.lightBlackBackground)
	elseif aligned then
		ui.addStyledText(subPos, ui.anchor.center, ui.anchor.top,
			"TARGET VECTOR ALIGNED", colGreen, pionillium.small, nil, colors.lightBlackBackground)
	end
end

gameView.registerModule("hyperspace-percentage", {
    showInHyperspace = true,
    draw = function(self, dT)
        colors = ui.theme.colors
        local player = gameView.player
        if not player then return end
        if Game.InHyperspace() then
            -- Pure white screen after the jump-out animation
            ui.addRectFilled(Vector2(0, 0), Vector2(ui.screenWidth, ui.screenHeight), Color(255, 255, 255, 255), 0, ui.RoundCornersNone)
        else
            displayHyperspaceTargetIndicator(player)
            if player:IsHyperspaceActive() then
                displayHyperspaceCountdown()
            end
            local flashAlpha = Game.GetHyperspaceFlashAlpha and Game.GetHyperspaceFlashAlpha() or 0
            if flashAlpha > 0.005 then
                local a = math.min(255, math.max(0, math.floor(flashAlpha * 255)))
                ui.addRectFilled(Vector2(0, 0), Vector2(ui.screenWidth, ui.screenHeight), Color(255, 255, 255, a), 0, ui.RoundCornersNone)
            end
        end
    end
})

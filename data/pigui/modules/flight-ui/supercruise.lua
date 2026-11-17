-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui = require 'pigui'
local Engine = require 'Engine'
local Game = require 'Game'
local Vector2 = _G.Vector2
local Color = _G.Color

local pionillium = ui.fonts.pionillium
local gameView = require 'pigui.views.game'

local LIGHT_SPEED = 299792458.0
local LIGHT_YEAR = 9460730472580800.0
local SAFE_DROP_DIST = 1000000.0  -- 1,000 km
local SAFE_DROP_SPEED = 1000000.0 -- 1,000 km/s

local colCyan       = Color(70, 210, 255, 240)
local colCyanDim    = Color(35, 145, 205, 130)
local colBlueZone   = Color(30, 165, 240, 140)
local colAmber      = Color(255, 185, 40, 240)
local colRed        = Color(255, 70, 55, 245)
local colGreen      = Color(75, 235, 130, 240)
local colPanelBg    = Color(8, 14, 22, 190)
local colBarBg      = Color(18, 28, 42, 210)
local colBorder     = Color(60, 130, 180, 140)
local colWhite      = Color(235, 245, 255, 240)
local colDimText    = Color(150, 175, 195, 210)

local function formatSupercruiseSpeed(speedMs)
	if speedMs >= LIGHT_SPEED * 0.10 then
		local cVal = speedMs / LIGHT_SPEED
		if cVal >= 100.0 then
			return string.format("%.0f c", cVal)
		elseif cVal >= 10.0 then
			return string.format("%.1f c", cVal)
		else
			return string.format("%.2f c", cVal)
		end
	elseif speedMs >= 1000000.0 then
		return string.format("%.2f Mm/s", speedMs / 1000000.0)
	else
		return string.format("%.0f km/s", speedMs / 1000.0)
	end
end

local function formatSupercruiseDist(distM)
	if distM >= LIGHT_YEAR * 0.01 then
		return string.format("%.2f ly", distM / LIGHT_YEAR)
	elseif distM >= LIGHT_SPEED * 1.0 then
		local ls = distM / LIGHT_SPEED
		if ls >= 1000.0 then
			return string.format("%.0f ls", ls)
		else
			return string.format("%.1f ls", ls)
		end
	elseif distM >= 1000000.0 then
		return string.format("%.2f Mm", distM / 1000000.0)
	elseif distM >= 1000.0 then
		return string.format("%.1f km", distM / 1000.0)
	else
		return string.format("%.0f m", distM)
	end
end

local function formatETA(etaSec)
	if etaSec <= 0.0 or etaSec > 360000.0 then
		return "--:--"
	end
	local totalSec = math.floor(etaSec + 0.5)
	local hrs = math.floor(totalSec / 3600)
	local mins = math.floor((totalSec % 3600) / 60)
	local secs = totalSec % 60
	if hrs > 0 then
		return string.format("%d:%02d:%02d", hrs, mins, secs)
	else
		return string.format("%d:%02d", mins, secs)
	end
end

local function drawStatusBanner(player, center, reticuleRadius)
	local yBase = center.y - reticuleRadius - 48

	-- 1. Charging progress bar
	if player:IsSupercruiseCharging() then
		local prog = player:GetSupercruiseChargeProgress()
		local rem = player:GetSupercruiseChargeCountdown()
		local massLock = player.GetShipMassLockFactor and player:GetShipMassLockFactor() or 1.0
		local barW = 300
		local barH = 12
		local tl = Vector2(center.x - barW * 0.5, yBase)
		local br = Vector2(center.x + barW * 0.5, yBase + barH)

		local extraH = (massLock > 1.05) and 16 or 0
		ui.addRectFilled(tl - Vector2(8, 26), br + Vector2(8, 8 + extraH), colPanelBg, 4, ui.RoundCornersAll)
		ui.addRect(tl - Vector2(8, 26), br + Vector2(8, 8 + extraH), (massLock > 1.05) and colAmber or colCyan, 4, ui.RoundCornersAll, 1.5)

		local title = string.format("FRAMESHIFT DRIVE CHARGING — %.1fs", rem)
		ui.addStyledText(Vector2(center.x, yBase - 6), ui.anchor.center, ui.anchor.bottom, title, colCyan, pionillium.medium)

		ui.addRectFilled(tl, br, colBarBg, 2, ui.RoundCornersAll)
		local fillW = math.max(0.0, math.min(1.0, prog)) * barW
		if fillW > 1 then
			ui.addRectFilled(tl, Vector2(tl.x + fillW, br.y), (massLock > 1.05) and colAmber or colCyan, 2, ui.RoundCornersAll)
		end
		ui.addRect(tl, br, colBorder, 2, ui.RoundCornersAll, 1.0)
		if massLock > 1.05 then
			ui.addStyledText(Vector2(center.x, br.y + 4), ui.anchor.center, ui.anchor.top,
				string.format("INHIBITED BY NEARBY SHIP — MASS LOCK FACTOR x%.1f", massLock), colAmber, pionillium.tiny)
		end
		return
	end

	-- 2. Safe Disengage Ready prompt (prominent, animated pulse, and clickable)
	if player:IsSupercruiseActive() and player:IsSafeDisengageReady() then
		local pulse = 0.70 + 0.30 * math.sin(Game.time * 8.0)
		local promptCol = Color(math.floor(70 * pulse), 215, 255, 250)
		local boxW = 360
		local boxH = 34
		local tl = Vector2(center.x - boxW * 0.5, yBase - 18)
		local br = Vector2(center.x + boxW * 0.5, yBase + boxH - 18)
		local hovered = ui.isMouseHoveringRect(tl, br)

		ui.addRectFilled(tl, br, hovered and Color(16, 36, 52, 230) or colPanelBg, 4, ui.RoundCornersAll)
		ui.addRect(tl, br, promptCol, 4, ui.RoundCornersAll, hovered and 2.5 or 2.0)
		ui.addStyledText(Vector2(center.x, tl.y + boxH * 0.5), ui.anchor.center, ui.anchor.center,
			"SAFE DISENGAGE READY [ PRESS J OR CLICK ]", promptCol, pionillium.medium)

		if hovered and ui.isMouseClicked(0) then
			player:ToggleSupercruise()
		end
		return
	end

	-- 3. Slow Down (Overshoot) warning
	if player:IsSupercruiseActive() and player:IsSlowDownWarning() then
		local pulse = 0.65 + 0.35 * math.sin(Game.time * 10.0)
		local alertCol = Color(255, math.floor(70 * pulse), math.floor(50 * pulse), 245)
		local boxW = 320
		local boxH = 32
		local tl = Vector2(center.x - boxW * 0.5, yBase - 16)
		local br = Vector2(center.x + boxW * 0.5, yBase + boxH - 16)
		ui.addRectFilled(tl, br, colPanelBg, 4, ui.RoundCornersAll)
		ui.addRect(tl, br, alertCol, 4, ui.RoundCornersAll, 2.0)
		ui.addStyledText(Vector2(center.x, tl.y + boxH * 0.5), ui.anchor.center, ui.anchor.center,
			"SLOW DOWN — GRAVITY WELL OVERSHOOT", alertCol, pionillium.medium)
		return
	end

	-- 4. Transient FSD status message
	local msg = player:GetSupercruiseStatusMessage()
	if msg and #msg > 0 then
		local textSize = ui.calcTextSize(msg, pionillium.medium)
		local boxW = math.max(260, textSize.x + 28)
		local boxH = 28
		local tl = Vector2(center.x - boxW * 0.5, yBase - 12)
		local br = Vector2(center.x + boxW * 0.5, yBase + boxH - 12)
		local isError = string.find(msg, "EMERGENCY") or string.find(msg, "LOCKED") or string.find(msg, "ABORTED") or string.find(msg, "CANNOT") or string.find(msg, "BEYOND") or string.find(msg, "TOO SLOW") or string.find(msg, "BLOCKED") or string.find(msg, "OBSCURED") or string.find(msg, "ACCELERATE") or string.find(msg, "BUSY")
		local borderCol = isError and colAmber or colCyan
		ui.addRectFilled(tl, br, colPanelBg, 4, ui.RoundCornersAll)
		ui.addRect(tl, br, borderCol, 4, ui.RoundCornersAll, 1.5)
		ui.addStyledText(Vector2(center.x, tl.y + boxH * 0.5), ui.anchor.center, ui.anchor.center,
			msg, borderCol, pionillium.medium)
		return
	end

	-- 5. FSD status badges (Mass Locked, Cooldown, Gear Down)
	if not player:IsDocked() and not player:IsLanded() then
		local cooldown = player:GetSupercruiseCooldown()
		local label = nil
		local col = colCyan
		if cooldown > 0.05 then
			label = string.format("FSD COOLDOWN: %.1fs", cooldown)
			col = colRed
		elseif not player:IsSupercruiseActive() then
			local status, _ = player:GetSupercruiseStatus()
			if status == "MASS_LOCKED" then
				label = "FSD MASS LOCKED"
				col = colAmber
			elseif status == "GEAR_DOWN" then
				label = "FSD LOCKED: LANDING GEAR DEPLOYED"
				col = colAmber
			end
		end

		if label then
			local ts = ui.calcTextSize(label, pionillium.small)
			local boxW = ts.x + 24
			local boxH = 24
			local tl = Vector2(center.x - boxW * 0.5, yBase - 8)
			local br = Vector2(center.x + boxW * 0.5, yBase + boxH - 8)
			ui.addRectFilled(tl, br, colPanelBg, 3, ui.RoundCornersAll)
			ui.addRect(tl, br, col, 3, ui.RoundCornersAll, 1.0)
			ui.addStyledText(Vector2(center.x, tl.y + boxH * 0.5), ui.anchor.center, ui.anchor.center,
				label, col, pionillium.small)
		end
	end
end

local function drawFuelScoopHUD(player, center, reticuleRadius)
	local active = player.IsFuelScoopActive and player:IsFuelScoopActive()
	local unscoopable = player.IsFuelScoopUnscoopable and player:IsFuelScoopUnscoopable()
	if not active and not unscoopable then
		return
	end

	local boxW = 300
	local boxH = active and 54 or 28
	local tl = Vector2(center.x - boxW * 0.5, center.y + reticuleRadius + 24)
	local br = Vector2(tl.x + boxW, tl.y + boxH)

	if unscoopable then
		ui.addRectFilled(tl, br, colPanelBg, 4, ui.RoundCornersAll)
		ui.addRect(tl, br, colAmber, 4, ui.RoundCornersAll, 1.5)
		ui.addStyledText(Vector2(center.x, tl.y + boxH * 0.5), ui.anchor.center, ui.anchor.center,
			"FUEL SCOOP: UNSCOOPABLE STAR CLASS", colAmber, pionillium.small)
		return
	end

	local rate = player:GetFuelScoopRate()
	local prox = player:GetFuelScoopProximity()
	local hd = player.GetInstalledHyperdrive and player:GetInstalledHyperdrive()
	local hdNeed = (hd and hd.fuel and hd.fuel.name == "hydrogen" and hd.storedFuel < hd:GetMaxFuel())
	local thrNeed = (player.fuel or 100) < 99.9
	local full = (not hdNeed) and (not thrNeed)

	local borderCol = full and colGreen or ((prox > 0.65) and colAmber or colCyan)
	ui.addRectFilled(tl, br, colPanelBg, 4, ui.RoundCornersAll)
	ui.addRect(tl, br, borderCol, 4, ui.RoundCornersAll, 1.5)

	local title = full and "FUEL RESERVOIR FULL" or string.format("FUEL SCOOPING — +%.2f t/s", rate)
	ui.addStyledText(Vector2(tl.x + 10, tl.y + 6), ui.anchor.left, ui.anchor.top, title, borderCol, pionillium.small)

	if hd then
		ui.addStyledText(Vector2(br.x - 10, tl.y + 6), ui.anchor.right, ui.anchor.top,
			string.format("HYP %.1f/%.0ft | THR %.0f%%", hd.storedFuel, hd:GetMaxFuel(), player.fuel or 0),
			colWhite, pionillium.tiny)
	end

	local barX = tl.x + 10
	local barY = tl.y + 30
	local barW = boxW - 20
	local barH = 10
	ui.addRectFilled(Vector2(barX, barY), Vector2(barX + barW, barY + barH), colBarBg, 2, ui.RoundCornersAll)
	local fillW = math.max(0.0, math.min(1.0, prox)) * barW
	if fillW > 1 then
		ui.addRectFilled(Vector2(barX, barY), Vector2(barX + fillW, barY + barH), borderCol, 2, ui.RoundCornersAll)
	end
	ui.addRect(Vector2(barX, barY), Vector2(barX + barW, barY + barH), colBorder, 2, ui.RoundCornersAll, 1.0)
end

local function drawSupercruiseRightGauge(player, center, reticuleRadius)
	local panelW = 168
	local panelH = 176
	local panelX = center.x + reticuleRadius + 36
	local panelY = center.y - panelH * 0.5

	local tl = Vector2(panelX, panelY)
	local br = Vector2(panelX + panelW, panelY + panelH)
	ui.addRectFilled(tl, br, colPanelBg, 5, ui.RoundCornersAll)
	ui.addRect(tl, br, colBorder, 5, ui.RoundCornersAll, 1.0)

	local throttle = player:GetSupercruiseThrottle()
	local speed = player:GetSupercruiseSpeed()
	local envMax = player:GetSupercruiseMaxEnvSpeed()
	local strain = player:GetSupercruiseGravityStrain()
	local assist = player:IsSupercruiseAssistActive()

	-- Vertical Throttle Bar with 75% Blue Zone ([0.65, 0.80])
	local barX = panelX + 12
	local barTop = panelY + 26
	local barH = 116
	local barW = 18
	local barTL = Vector2(barX, barTop)
	local barBR = Vector2(barX + barW, barTop + barH)

	-- Direct mouse interaction with throttle bar
	if ui.isMouseHoveringRect(barTL, barBR) and ui.isMouseClicked(0) then
		local my = ui.getMousePos().y
		local norm = 1.0 - math.max(0.0, math.min(1.0, (my - barTop) / barH))
		player:SetSupercruiseThrottle(norm)
		throttle = norm
	end

	ui.addRectFilled(barTL, barBR, colBarBg, 2, ui.RoundCornersAll)

	-- 75% Blue Zone band (from 65% to 80% up from bottom)
	local bzTop = barTop + barH * (1.0 - 0.80)
	local bzBot = barTop + barH * (1.0 - 0.65)
	ui.addRectFilled(Vector2(barX + 1, bzTop), Vector2(barX + barW - 1, bzBot), colBlueZone, 0, ui.RoundCornersNone)

	-- Current throttle fill
	local fillTop = barTop + barH * (1.0 - math.max(0.0, math.min(1.0, throttle)))
	local inBlueZone = (throttle >= 0.65 and throttle <= 0.80)
	local fillCol = inBlueZone and colCyan or colAmber
	if barTop + barH - fillTop > 1 then
		ui.addRectFilled(Vector2(barX + 3, fillTop), Vector2(barX + barW - 3, barTop + barH), fillCol, 1, ui.RoundCornersNone)
	end

	-- 75% centerline tick
	local tick75Y = barTop + barH * (1.0 - 0.75)
	ui.addLine(Vector2(barX - 3, tick75Y), Vector2(barX + barW + 3, tick75Y), colCyan, 1.5)
	ui.addRect(barTL, barBR, colBorder, 2, ui.RoundCornersAll, 1.0)

	-- Readouts on the right of the throttle bar
	local textX = barX + barW + 12
	ui.addStyledText(Vector2(panelX + 10, panelY + 6), ui.anchor.left, ui.anchor.top,
		"FSD SUPERCRUISE", colCyan, pionillium.small)

	ui.addStyledText(Vector2(textX, panelY + 26), ui.anchor.left, ui.anchor.top,
		"VELOCITY", colDimText, pionillium.tiny)
	ui.addStyledText(Vector2(textX, panelY + 40), ui.anchor.left, ui.anchor.top,
		formatSupercruiseSpeed(speed), colWhite, pionillium.medlarge)

	local thrLabel = string.format("THR: %.0f%%", throttle * 100.0)
	if inBlueZone then
		thrLabel = thrLabel .. " [OPT]"
	end
	ui.addStyledText(Vector2(textX, panelY + 70), ui.anchor.left, ui.anchor.top,
		thrLabel, inBlueZone and colCyan or colDimText, pionillium.small)

	if assist then
		ui.addStyledText(Vector2(textX, panelY + 88), ui.anchor.left, ui.anchor.top,
			"SC ASSIST ON", colGreen, pionillium.small)
	else
		ui.addStyledText(Vector2(textX, panelY + 88), ui.anchor.left, ui.anchor.top,
			"MAX: " .. formatSupercruiseSpeed(envMax), colDimText, pionillium.tiny)
	end

	-- Gravity Well Strain Meter
	ui.addStyledText(Vector2(textX, panelY + 108), ui.anchor.left, ui.anchor.top,
		"GRAV STRAIN", colDimText, pionillium.tiny)
	local gwX = textX
	local gwY = panelY + 122
	local gwW = panelW - (textX - panelX) - 10
	local gwH = 8
	ui.addRectFilled(Vector2(gwX, gwY), Vector2(gwX + gwW, gwY + gwH), colBarBg, 2, ui.RoundCornersAll)
	local strainW = math.max(0.0, math.min(1.0, strain)) * gwW
	local strainCol = (strain > 0.65) and colRed or ((strain > 0.30) and colAmber or colCyan)
	if strainW > 1 then
		ui.addRectFilled(Vector2(gwX, gwY), Vector2(gwX + strainW, gwY + gwH), strainCol, 2, ui.RoundCornersAll)
	end
	ui.addRect(Vector2(gwX, gwY), Vector2(gwX + gwW, gwY + gwH), colBorder, 2, ui.RoundCornersAll, 1.0)

	-- Quick Throttle Buttons (75% and 0%)
	local btn75TL = Vector2(panelX + 10, panelY + panelH - 24)
	local btn75BR = Vector2(panelX + 54, panelY + panelH - 6)
	local h75 = ui.isMouseHoveringRect(btn75TL, btn75BR)
	ui.addRectFilled(btn75TL, btn75BR, h75 and colBlueZone or colBarBg, 2, ui.RoundCornersAll)
	ui.addRect(btn75TL, btn75BR, colCyan, 2, ui.RoundCornersAll, 1.0)
	ui.addStyledText(Vector2((btn75TL.x + btn75BR.x) * 0.5, (btn75TL.y + btn75BR.y) * 0.5),
		ui.anchor.center, ui.anchor.center, "75%", inBlueZone and colCyan or colWhite, pionillium.tiny)
	if h75 and ui.isMouseClicked(0) then
		player:SetSupercruiseThrottle(0.75)
	end

	local btn0TL = Vector2(panelX + 60, panelY + panelH - 24)
	local btn0BR = Vector2(panelX + 96, panelY + panelH - 6)
	local h0 = ui.isMouseHoveringRect(btn0TL, btn0BR)
	ui.addRectFilled(btn0TL, btn0BR, h0 and colBorder or colBarBg, 2, ui.RoundCornersAll)
	ui.addRect(btn0TL, btn0BR, colDimText, 2, ui.RoundCornersAll, 1.0)
	ui.addStyledText(Vector2((btn0TL.x + btn0BR.x) * 0.5, (btn0TL.y + btn0BR.y) * 0.5),
		ui.anchor.center, ui.anchor.center, "0%", (throttle <= 0.01) and colAmber or colDimText, pionillium.tiny)
	if h0 and ui.isMouseClicked(0) then
		player:SetSupercruiseThrottle(0.0)
	end

	ui.addStyledText(Vector2(panelX + panelW - 10, panelY + panelH - 15), ui.anchor.right, ui.anchor.center,
		"[W/S] THR", colDimText, pionillium.tiny)
end

local function drawSupercruiseTargetPanel(player, center, reticuleRadius)
	local target = player:GetNavTarget() or player:GetCombatTarget()
	if not target then
		return
	end

	local isShipTarget = target:IsShip()
	local hasInterdictor = player.HasFSDInterdictor and player:HasFSDInterdictor()
	local showInterdictRow = isShipTarget and hasInterdictor

	local panelW = 196
	local panelH = showInterdictRow and 202 or 176
	local panelX = center.x - reticuleRadius - panelW - 36
	local panelY = center.y - panelH * 0.5

	local tl = Vector2(panelX, panelY)
	local br = Vector2(panelX + panelW, panelY + panelH)
	ui.addRectFilled(tl, br, colPanelBg, 5, ui.RoundCornersAll)
	ui.addRect(tl, br, colBorder, 5, ui.RoundCornersAll, 1.0)

	local dist = player:GetSupercruiseTargetDistance()
	local eta = player:GetSupercruiseTargetETA()
	local speed = player:GetSupercruiseSpeed()
	local safeReady = player:IsSafeDisengageReady()
	local slowDown = player:IsSlowDownWarning()
	local assist = player:IsSupercruiseAssistActive()

	local targetName = target:GetLabel() or "TARGET"
	if #targetName > 22 then
		targetName = string.sub(targetName, 1, 20) .. ".."
	end

	ui.addStyledText(Vector2(panelX + 10, panelY + 6), ui.anchor.left, ui.anchor.top,
		"FSD NAV LOCK", colCyan, pionillium.small)
	ui.addStyledText(Vector2(panelX + 10, panelY + 24), ui.anchor.left, ui.anchor.top,
		targetName, colWhite, pionillium.small)

	-- Distance & ETA row
	ui.addStyledText(Vector2(panelX + 10, panelY + 44), ui.anchor.left, ui.anchor.top,
		"DIST: " .. formatSupercruiseDist(dist), colWhite, pionillium.small)

	local etaColor = colWhite
	if slowDown then
		etaColor = colRed
	elseif eta >= 5.5 and eta <= 8.0 then
		etaColor = colCyan
	end
	ui.addStyledText(Vector2(panelX + panelW - 10, panelY + 44), ui.anchor.right, ui.anchor.top,
		"ETA " .. formatETA(eta), etaColor, pionillium.small)

	-- Safe Disengage Alignment Bar 1: DISTANCE (< 1,000 km)
	local barX = panelX + 10
	local barW = panelW - 20
	local safeZoneW = barW * 0.28

	ui.addStyledText(Vector2(barX, panelY + 68), ui.anchor.left, ui.anchor.top,
		"DROP DISTANCE (<1,000 km)", (dist <= SAFE_DROP_DIST) and colGreen or colDimText, pionillium.tiny)
	local dBarY = panelY + 83
	ui.addRectFilled(Vector2(barX, dBarY), Vector2(barX + barW, dBarY + 8), colBarBg, 2, ui.RoundCornersAll)
	ui.addRectFilled(Vector2(barX, dBarY), Vector2(barX + safeZoneW, dBarY + 8), colCyanDim, 2, ui.RoundCornersAll)

	-- Log-scaled distance marker
	local distNorm = 0.0
	if dist <= SAFE_DROP_DIST then
		distNorm = (dist / SAFE_DROP_DIST) * 0.28
	else
		local logD = math.log(math.max(1.0, dist / SAFE_DROP_DIST)) / math.log(300000.0)
		distNorm = 0.28 + 0.72 * math.max(0.0, math.min(1.0, logD))
	end
	local dMarkerX = barX + math.max(2.0, math.min(barW - 2.0, distNorm * barW))
	ui.addLine(Vector2(dMarkerX, dBarY - 2), Vector2(dMarkerX, dBarY + 10),
		(dist <= SAFE_DROP_DIST) and colGreen or colAmber, 2.5)
	ui.addRect(Vector2(barX, dBarY), Vector2(barX + barW, dBarY + 8), colBorder, 2, ui.RoundCornersAll, 1.0)

	-- Safe Disengage Alignment Bar 2: SPEED (< 1,000 km/s)
	ui.addStyledText(Vector2(barX, panelY + 98), ui.anchor.left, ui.anchor.top,
		"DROP SPEED (<1,000 km/s)", (speed <= SAFE_DROP_SPEED) and colGreen or colDimText, pionillium.tiny)
	local sBarY = panelY + 113
	ui.addRectFilled(Vector2(barX, sBarY), Vector2(barX + barW, sBarY + 8), colBarBg, 2, ui.RoundCornersAll)
	ui.addRectFilled(Vector2(barX, sBarY), Vector2(barX + safeZoneW, sBarY + 8), colCyanDim, 2, ui.RoundCornersAll)

	local speedNorm = 0.0
	if speed <= SAFE_DROP_SPEED then
		speedNorm = (speed / SAFE_DROP_SPEED) * 0.28
	else
		local logS = math.log(math.max(1.0, speed / SAFE_DROP_SPEED)) / math.log(600000.0)
		speedNorm = 0.28 + 0.72 * math.max(0.0, math.min(1.0, logS))
	end
	local sMarkerX = barX + math.max(2.0, math.min(barW - 2.0, speedNorm * barW))
	ui.addLine(Vector2(sMarkerX, sBarY - 2), Vector2(sMarkerX, sBarY + 10),
		(speed <= SAFE_DROP_SPEED) and colGreen or colAmber, 2.5)
	ui.addRect(Vector2(barX, sBarY), Vector2(barX + barW, sBarY + 8), colBorder, 2, ui.RoundCornersAll, 1.0)

	-- Bottom Drop / Assist / Interdictor Action Row inside target panel
	local bottomOffset = showInterdictRow and 52 or 28
	local btnDropTL = Vector2(panelX + 8, panelY + panelH - bottomOffset)
	local btnDropBR = Vector2(panelX + panelW - 8, panelY + panelH - bottomOffset + 22)

	local occluded, blocker = player.IsSupercruiseTargetOccluded and player:IsSupercruiseTargetOccluded()

	if safeReady and not isShipTarget then
		local hDrop = ui.isMouseHoveringRect(btnDropTL, btnDropBR)
		ui.addRectFilled(btnDropTL, btnDropBR, hDrop and Color(30, 80, 50, 230) or Color(15, 45, 30, 210), 3, ui.RoundCornersAll)
		ui.addRect(btnDropTL, btnDropBR, colGreen, 3, ui.RoundCornersAll, 1.5)
		ui.addStyledText(Vector2(panelX + panelW * 0.5, (btnDropTL.y + btnDropBR.y) * 0.5),
			ui.anchor.center, ui.anchor.center, "SAFE DISENGAGE [J]", colGreen, pionillium.small)
		if hDrop and ui.isMouseClicked(0) then
			player:SafeDisengage()
		end
	elseif isShipTarget then
		ui.addStyledText(Vector2(panelX + panelW * 0.5, (btnDropTL.y + btnDropBR.y) * 0.5),
			ui.anchor.center, ui.anchor.center, "SUPERCRUISE INTERCEPT", colCyan, pionillium.tiny)
	elseif occluded then
		local blkName = blocker and blocker:GetLabel() or "PLANET"
		if assist then
			ui.addStyledText(Vector2(panelX + panelW * 0.5, (btnDropTL.y + btnDropBR.y) * 0.5),
				ui.anchor.center, ui.anchor.center, "SC ASSIST: ORBITING " .. blkName, colAmber, pionillium.tiny)
		else
			ui.addStyledText(Vector2(panelX + panelW * 0.5, (btnDropTL.y + btnDropBR.y) * 0.5),
				ui.anchor.center, ui.anchor.center, "TARGET OCCLUDED BY " .. blkName, colAmber, pionillium.tiny)
		end
	elseif assist then
		ui.addStyledText(Vector2(panelX + panelW * 0.5, (btnDropTL.y + btnDropBR.y) * 0.5),
			ui.anchor.center, ui.anchor.center, "SC ASSIST: AUTO-DROP", colGreen, pionillium.small)
	elseif slowDown then
		ui.addStyledText(Vector2(panelX + panelW * 0.5, (btnDropTL.y + btnDropBR.y) * 0.5),
			ui.anchor.center, ui.anchor.center, "SLOW DOWN (THROTTLE BACK)", colRed, pionillium.tiny)
	else
		ui.addStyledText(Vector2(panelX + panelW * 0.5, (btnDropTL.y + btnDropBR.y) * 0.5),
			ui.anchor.center, ui.anchor.center, "APPROACH AT 0:06 (75% THR)", colCyan, pionillium.tiny)
	end

	if showInterdictRow then
		local canInt, reason = player:CanInterdictTarget(target)
		local btnIntTL = Vector2(panelX + 8, panelY + panelH - 26)
		local btnIntBR = Vector2(panelX + panelW - 8, panelY + panelH - 6)
		local intCol = canInt and colGreen or colAmber
		ui.addRectFilled(btnIntTL, btnIntBR, canInt and Color(15, 50, 35, 220) or colBarBg, 3, ui.RoundCornersAll)
		ui.addRect(btnIntTL, btnIntBR, intCol, 3, ui.RoundCornersAll, 1.0)
		local intLabel = canInt and "[M] ENGAGE INTERDICTOR" or (reason or "OUT OF ENVELOPE")
		if #intLabel > 26 then
			intLabel = string.sub(intLabel, 1, 24) .. ".."
		end
		ui.addStyledText(Vector2(panelX + panelW * 0.5, (btnIntTL.y + btnIntBR.y) * 0.5),
			ui.anchor.center, ui.anchor.center, intLabel, intCol, pionillium.tiny)
		if canInt and ui.isMouseHoveringRect(btnIntTL, btnIntBR) and ui.isMouseClicked(0) then
			player:StartInterdiction(target)
		end
	end
end

local function drawInterdictionHUD(player, center, reticuleRadius)
	local isTarget = player.IsBeingInterdicted and player:IsBeingInterdicted()
	local isAttacker = player.IsInterdicting and player:IsInterdicting()
	if not isTarget and not isAttacker then
		return
	end

	local capProg = player:GetInterdictionCaptureProgress()
	local escProg = player:GetInterdictionEscapeProgress()

	-- 1. Escape Vector Reticle (when player is being interdicted)
	if isTarget then
		local escDir = player:GetInterdictionEscapeVector()
		local onscreen, pos, dir = Engine.ProjectRelDirection(escDir)
		local pulse = 0.72 + 0.28 * math.sin(Game.time * 9.0)
		local vecCol = Color(55, 215, 255, math.floor(245 * pulse))

		if onscreen then
			ui.addCircle(pos, 26, vecCol, 24, 2.5)
			ui.addCircle(pos, 14, colWhite, 20, 1.5)
			ui.addLine(pos - Vector2(34, 0), pos - Vector2(16, 0), vecCol, 2.0)
			ui.addLine(pos + Vector2(16, 0), pos + Vector2(34, 0), vecCol, 2.0)
			ui.addLine(pos - Vector2(0, 34), pos - Vector2(0, 16), vecCol, 2.0)
			ui.addLine(pos + Vector2(0, 16), pos + Vector2(0, 34), vecCol, 2.0)
			ui.addStyledText(pos + Vector2(0, 32), ui.anchor.center, ui.anchor.top,
				"ESCAPE VECTOR", vecCol, pionillium.small)
		end

		if not onscreen or (pos - center):length() > reticuleRadius * 0.95 then
			local arrowPos = center + Vector2(dir.x, dir.y) * (reticuleRadius * 0.88)
			ui.addCircleFilled(arrowPos, 6, vecCol, 12, 1.0)
			ui.addStyledText(arrowPos + Vector2(0, 10), ui.anchor.center, ui.anchor.top,
				"ESCAPE", vecCol, pionillium.tiny)
		end
	end

	-- 2. Tug-of-War Progress Bars & Explanatory Banner
	local boxW = 460
	local boxH = 88
	local tl = Vector2(center.x - boxW * 0.5, center.y - reticuleRadius - 122)
	local br = Vector2(tl.x + boxW, tl.y + boxH)
	local borderCol = isTarget and colRed or colCyan

	ui.addRectFilled(tl, br, Color(12, 16, 26, 225), 5, ui.RoundCornersAll)
	ui.addRect(tl, br, borderCol, 5, ui.RoundCornersAll, 2.0)

	local header = isTarget
		and (player:IsSubmittingToInterdiction() and "SUBMITTING TO INTERDICTION..." or "INTERDICTION DETECTED — FSD TETHER LOCKED")
		or "FSD INTERDICTION TETHER ACTIVE"
	local sub = isTarget
		and "ALIGN WITH BLUE ESCAPE VECTOR TO BREAK FREE — OR THROTTLE TO 0% TO SUBMIT"
		or "KEEP TARGET CENTERED IN RETICLE TO PULL FROM SUPERCRUISE"

	ui.addStyledText(Vector2(center.x, tl.y + 10), ui.anchor.center, ui.anchor.top,
		header, borderCol, pionillium.medium)
	ui.addStyledText(Vector2(center.x, tl.y + 30), ui.anchor.center, ui.anchor.top,
		sub, colWhite, pionillium.tiny)

	-- Left bar (Blue/Cyan) vs Right bar (Red/Amber)
	local barW = (boxW - 44) * 0.5
	local barH = 12
	local barY = tl.y + 56

	local leftTL = Vector2(tl.x + 14, barY)
	local leftVal = isTarget and escProg or capProg
	local leftLabel = isTarget and string.format("ESCAPE %.0f%%", escProg * 100) or string.format("CAPTURE %.0f%%", capProg * 100)
	ui.addStyledText(Vector2(leftTL.x, barY - 12), ui.anchor.left, ui.anchor.top, leftLabel, colCyan, pionillium.tiny)
	ui.addRectFilled(leftTL, leftTL + Vector2(barW, barH), colBarBg, 2, ui.RoundCornersAll)
	if leftVal > 0.01 then
		ui.addRectFilled(leftTL, leftTL + Vector2(barW * leftVal, barH), colCyan, 2, ui.RoundCornersAll)
	end
	ui.addRect(leftTL, leftTL + Vector2(barW, barH), colBorder, 2, ui.RoundCornersAll, 1.0)

	local rightTL = Vector2(tl.x + boxW - 14 - barW, barY)
	local rightVal = isTarget and capProg or escProg
	local rightCol = isTarget and colRed or colAmber
	local rightLabel = isTarget and string.format("INTERDICTED %.0f%%", capProg * 100) or string.format("TARGET ESCAPE %.0f%%", escProg * 100)
	ui.addStyledText(Vector2(rightTL.x + barW, barY - 12), ui.anchor.right, ui.anchor.top, rightLabel, rightCol, pionillium.tiny)
	ui.addRectFilled(rightTL, rightTL + Vector2(barW, barH), colBarBg, 2, ui.RoundCornersAll)
	if rightVal > 0.01 then
		ui.addRectFilled(rightTL, rightTL + Vector2(barW * rightVal, barH), rightCol, 2, ui.RoundCornersAll)
	end
	ui.addRect(rightTL, rightTL + Vector2(barW, barH), colBorder, 2, ui.RoundCornersAll, 1.0)
end

gameView.registerModule("supercruise-hud", {
	showInHyperspace = false,
	draw = function()
		local player = Game.player
		if not player then return end

		local center = gameView.center or Vector2(ui.screenWidth * 0.5, ui.screenHeight * 0.5)
		local radius = ui.reticuleCircleRadius or (math.min(ui.screenWidth, ui.screenHeight) / 8)

		drawStatusBanner(player, center, radius)

		if player:IsSupercruiseActive() then
			drawSupercruiseRightGauge(player, center, radius)
			drawSupercruiseTargetPanel(player, center, radius)
			drawInterdictionHUD(player, center, radius)
			drawFuelScoopHUD(player, center, radius)
		end
	end,
	debugReload = function()
		package.reimport()
	end
})

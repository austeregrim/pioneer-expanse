-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local ui = require 'pigui'
local Engine = require 'Engine'
local Game = require 'Game'
local Lang = require 'Lang'
local Vector2 = _G.Vector2
local Color = _G.Color

-- cache ui
local pionillium = ui.fonts.pionillium
local colors = ui.theme.colors

local lc = Lang.GetResource("core")
local lui = Lang.GetResource("ui-core")

local gameView = require 'pigui.views.game'

local HYPERSPACE_TIME_ACCEL = 100000.0 -- Game::s_timeAccelRates[TIMEACCEL_HYPERSPACE]
local LONG_JUMP_THRESHOLD_GAME_SEC = 4.0 * 86400.0 -- >= 4 game days (~3.5s real time) triggers black fade + red clock/countdown

local uiScale = ui.rescaleFraction(1, Vector2(1920, 1080))
local function scaledFontSize(basePx)
	local factor = uiScale
	if factor < 1 then
		factor = factor * 0.8 + 0.2
	elseif factor > 1 then
		factor = 1 + (factor - 1) * 0.45
	end
	return math.max(10, math.round(basePx * factor))
end

local hyperHeaderFont   = { name = "orbiteer",   size = scaledFontSize(18) }
local hyperClockFont    = { name = "orbiteer",   size = scaledFontSize(36) }
local hyperSubLabelFont = { name = "pionillium", size = scaledFontSize(15) }
local hyperCountdownFont = { name = "orbiteer",  size = scaledFontSize(50) }

local months = {
	"MONTH_JAN", "MONTH_FEB", "MONTH_MAR", "MONTH_APR", "MONTH_MAY", "MONTH_JUN",
	"MONTH_JUL", "MONTH_AUG", "MONTH_SEP", "MONTH_OCT", "MONTH_NOV", "MONTH_DEC"
}

local hyperspaceRealTimer = 0.0

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

local function smoothstep(edge0, edge1, x)
	if edge0 == edge1 then
		return (x >= edge1) and 1.0 or 0.0
	end
	local t = math.max(0.0, math.min(1.0, (x - edge0) / (edge1 - edge0)))
	return t * t * (3.0 - 2.0 * t)
end

local function drawRedGlowText(pos, anchorH, anchorV, text, font, alpha, brightCore)
	local s = uiScale
	local outerR = 3.8 * s
	local outerDiag = 2.7 * s
	local innerR = 1.6 * s
	local outerA = math.max(0, math.min(255, math.floor(alpha * 26)))
	local innerA = math.max(0, math.min(255, math.floor(alpha * 56)))
	local coreA  = math.max(0, math.min(255, math.floor(alpha * 245)))

	if outerA > 0 then
		local colOuter = Color(215, 16, 12, outerA)
		ui.addStyledText(pos + Vector2(-outerR, 0), anchorH, anchorV, text, colOuter, font)
		ui.addStyledText(pos + Vector2( outerR, 0), anchorH, anchorV, text, colOuter, font)
		ui.addStyledText(pos + Vector2(0, -outerR), anchorH, anchorV, text, colOuter, font)
		ui.addStyledText(pos + Vector2(0,  outerR), anchorH, anchorV, text, colOuter, font)
		ui.addStyledText(pos + Vector2(-outerDiag, -outerDiag), anchorH, anchorV, text, colOuter, font)
		ui.addStyledText(pos + Vector2( outerDiag, -outerDiag), anchorH, anchorV, text, colOuter, font)
		ui.addStyledText(pos + Vector2(-outerDiag,  outerDiag), anchorH, anchorV, text, colOuter, font)
		ui.addStyledText(pos + Vector2( outerDiag,  outerDiag), anchorH, anchorV, text, colOuter, font)
	end

	if innerA > 0 then
		local colInner = Color(255, 36, 24, innerA)
		ui.addStyledText(pos + Vector2(-innerR, -innerR), anchorH, anchorV, text, colInner, font)
		ui.addStyledText(pos + Vector2( innerR, -innerR), anchorH, anchorV, text, colInner, font)
		ui.addStyledText(pos + Vector2(-innerR,  innerR), anchorH, anchorV, text, colInner, font)
		ui.addStyledText(pos + Vector2( innerR,  innerR), anchorH, anchorV, text, colInner, font)
	end

	local colCore = Color(255, brightCore and 76 or 54, brightCore and 66 or 44, coreA)
	ui.addStyledText(pos, anchorH, anchorV, text, colCore, font)
end

local tabularMetricsCache = {}

local function getTabularMetrics(font)
	local key = font.name .. ":" .. tostring(font.size)
	local cached = tabularMetricsCache[key]
	if cached then
		return cached
	end

	local m = {}
	ui.withFont(font, function()
		local singleW = 0.0
		local advW = 0.0
		for d = 0, 9 do
			local s1 = tostring(d)
			local s2 = s1 .. s1
			local w1 = ui.calcTextSize(s1).x
			local w2 = ui.calcTextSize(s2).x
			if w1 > singleW then singleW = w1 end
			if (w2 - w1) > advW then advW = (w2 - w1) end
		end
		m.digitW = math.ceil(math.max(singleW, advW))

		local maxMonthW = 0.0
		for i = 1, 12 do
			local mon = string.upper(lc[months[i]] or "JAN")
			local mw = ui.calcTextSize(mon).x
			if mw > maxMonthW then maxMonthW = mw end
		end
		m.monthW = math.ceil(maxMonthW)

		m.spaceW = math.max(4, math.ceil(ui.calcTextSize(" ").x))
		m.colonW = math.ceil(ui.calcTextSize(":").x + 2 * uiScale)
		m.dashW  = math.ceil(ui.calcTextSize("—").x)
		m.daysW  = math.ceil(ui.calcTextSize("DAYS").x)
		m.hrsW   = math.ceil(ui.calcTextSize("HRS").x)
		m.minW   = math.ceil(ui.calcTextSize("MIN").x)
		m.unitGapW = math.ceil(m.spaceW * 2.2)
		m.dashGapW = math.ceil(m.spaceW * 1.6)
	end)

	tabularMetricsCache[key] = m
	return m
end

local function drawRedGlowTabularRow(centerPos, font, alpha, brightCore, segments)
	local m = getTabularMetrics(font)
	local totalW = 0.0
	for i = 1, #segments do
		totalW = totalW + segments[i].width
	end

	local x = math.floor(centerPos.x - totalW * 0.5 + 0.5)
	local y = math.floor(centerPos.y + 0.5)

	for i = 1, #segments do
		local seg = segments[i]
		if seg.isDigits then
			local str = seg.text
			for j = 1, #str do
				local ch = str:sub(j, j)
				if ch ~= " " then
					local cxCell = math.floor(x + (j - 0.5) * m.digitW + 0.5)
					drawRedGlowText(Vector2(cxCell, y), ui.anchor.center, ui.anchor.center,
						ch, font, alpha, brightCore)
				end
			end
		elseif seg.text ~= "" then
			local cxSlot = math.floor(x + seg.width * 0.5 + 0.5)
			drawRedGlowText(Vector2(cxSlot, y), ui.anchor.center, ui.anchor.center,
				seg.text, font, alpha, brightCore)
		end
		x = x + seg.width
	end
end

local function drawCurrentClockTabular(centerPos, font, alpha, brightCore)
	local year, month_num, day, hour, minute, second = Game.GetDateTime()
	local monthKey = months[month_num] or "MONTH_JAN"
	local monthStr = string.upper(lc[monthKey] or "JAN")
	local m = getTabularMetrics(font)

	local yearStr = string.format("%04i", year)
	local dayStr  = string.format("%02i", day)
	local hrStr   = string.format("%02i", hour)
	local minStr  = string.format("%02i", minute)
	local secStr  = string.format("%02i", second)

	drawRedGlowTabularRow(centerPos, font, alpha, brightCore, {
		{ width = 4 * m.digitW, text = yearStr,  isDigits = true },
		{ width = m.spaceW,     text = "",       isDigits = false },
		{ width = m.monthW,     text = monthStr, isDigits = false },
		{ width = m.spaceW,     text = "",       isDigits = false },
		{ width = 2 * m.digitW, text = dayStr,   isDigits = true },
		{ width = m.dashGapW,   text = "",       isDigits = false },
		{ width = m.dashW,      text = "—",      isDigits = false },
		{ width = m.dashGapW,   text = "",       isDigits = false },
		{ width = 2 * m.digitW, text = hrStr,    isDigits = true },
		{ width = m.colonW,     text = ":",      isDigits = false },
		{ width = 2 * m.digitW, text = minStr,   isDigits = true },
		{ width = m.colonW,     text = ":",      isDigits = false },
		{ width = 2 * m.digitW, text = secStr,   isDigits = true },
	})
end

local function drawCountdownTabular(centerPos, font, alpha, brightCore, remGameSec, totalDurationSec)
	local totalMins = math.max(0, math.floor(remGameSec / 60))
	local days = math.floor(totalMins / 1440)
	local hours = math.floor((totalMins % 1440) / 60)
	local mins = totalMins % 60
	local m = getTabularMetrics(font)

	local maxDays = math.max(days, math.floor((totalDurationSec or remGameSec or 0) / 86400))
	local daySlots = math.max(2, #tostring(maxDays))
	local daysStr = string.format("%" .. daySlots .. "d", days)
	local hrsStr  = string.format("%02d", hours)
	local minsStr = string.format("%02d", mins)

	drawRedGlowTabularRow(centerPos, font, alpha, brightCore, {
		{ width = daySlots * m.digitW, text = daysStr, isDigits = true },
		{ width = m.spaceW,            text = "",      isDigits = false },
		{ width = m.daysW,             text = "DAYS",  isDigits = false },
		{ width = m.unitGapW,          text = "",      isDigits = false },
		{ width = 2 * m.digitW,        text = hrsStr,  isDigits = true },
		{ width = m.spaceW,            text = "",      isDigits = false },
		{ width = m.hrsW,              text = "HRS",   isDigits = false },
		{ width = m.unitGapW,          text = "",      isDigits = false },
		{ width = 2 * m.digitW,        text = minsStr, isDigits = true },
		{ width = m.spaceW,            text = "",      isDigits = false },
		{ width = m.minW,              text = "MIN",   isDigits = false },
	})
end

local function displayHyperspace(dT)
	local w = ui.screenWidth
	local h = ui.screenHeight
	local cx = w * 0.5
	local cy = h * 0.5

	local duration = Game.GetHyperspaceDuration and Game.GetHyperspaceDuration() or 0
	local endTime = Game.GetHyperspaceEndTime and Game.GetHyperspaceEndTime() or 0
	local progress = Game.GetHyperspaceProgress and Game.GetHyperspaceProgress() or 0

	if duration < LONG_JUMP_THRESHOLD_GAME_SEC then
		-- Short jumps stay crisp pure white without countdown
		ui.addRectFilled(Vector2(0, 0), Vector2(w, h), Color(255, 255, 255, 255), 0, ui.RoundCornersNone)
		return
	end

	hyperspaceRealTimer = hyperspaceRealTimer + (dT or 0.0)

	local remGameSec = (endTime > 0) and math.max(0.0, endTime - Game.time) or math.max(0.0, duration - progress)
	local elapsedReal = progress / HYPERSPACE_TIME_ACCEL
	local remReal = remGameSec / HYPERSPACE_TIME_ACCEL

	-- Smoothly transition white -> black on entry and back black -> white right before exit
	local fadeInBlack = smoothstep(0.45, 1.85, elapsedReal)
	local fadeOutWhite = smoothstep(0.65, 0.05, remReal)
	local darkness = math.max(0.0, math.min(1.0, fadeInBlack * (1.0 - fadeOutWhite)))

	local bgVal = math.max(0, math.min(255, math.floor(255.0 * (1.0 - darkness) + 0.5)))
	ui.addRectFilled(Vector2(0, 0), Vector2(w, h), Color(bgVal, bgVal, bgVal, 255), 0, ui.RoundCornersNone)

	local hudAlpha = smoothstep(0.45, 0.98, darkness)
	if hudAlpha <= 0.01 then
		return
	end

	-- Gentle real-time breathing pulse for the crimson glare
	local pulse = 0.94 + 0.06 * math.sin(hyperspaceRealTimer * 2.2)
	local a = hudAlpha * pulse
	local s = uiScale

	-- Soft ambient radial crimson glare around the centered clock and countdown
	local centerPos = Vector2(cx, cy)
	local haloLayers = {
		{ r = 340 * s, alpha = 6 },
		{ r = 270 * s, alpha = 8 },
		{ r = 210 * s, alpha = 10 },
		{ r = 160 * s, alpha = 12 },
		{ r = 115 * s, alpha = 14 },
		{ r =  75 * s, alpha = 16 },
	}
	for _, layer in ipairs(haloLayers) do
		local la = math.floor(layer.alpha * a)
		if la > 0 then
			ui.addCircleFilled(centerPos, layer.r, Color(210, 14, 12, la), 48)
		end
	end

	local bloomHalfW = 290 * s
	local bloomA = math.floor(11 * a)
	if bloomA > 0 then
		ui.addRectFilled(Vector2(cx - bloomHalfW, cy - 82 * s), Vector2(cx + bloomHalfW, cy - 22 * s),
			Color(220, 18, 12, bloomA), 30 * s, ui.RoundCornersAll)
		ui.addRectFilled(Vector2(cx - bloomHalfW * 1.15, cy + 28 * s), Vector2(cx + bloomHalfW * 1.15, cy + 96 * s),
			Color(235, 22, 14, math.floor(14 * a)), 34 * s, ui.RoundCornersAll)
	end

	-- Destination system header
	local path, destName = Game.player:GetHyperspaceDestination()
	local headerText = (path and destName)
		and string.format("HYPERSPACE TRANSIT  ·  %s (%d, %d, %d)", string.upper(destName), path.sectorX, path.sectorY, path.sectorZ)
		or "HYPERSPACE TRANSIT"
	drawRedGlowText(Vector2(cx, cy - 108 * s), ui.anchor.center, ui.anchor.center,
		headerText, hyperHeaderFont, a * 0.80, false)

	-- Enlarged centered current date/time clock (fixed-width tabular glyphs prevent jitter)
	drawCurrentClockTabular(Vector2(cx, cy - 54 * s), hyperClockFont, a, true)

	-- Subtle crimson divider with soft halo
	local divHalf = 210 * s
	ui.addLine(Vector2(cx - divHalf, cy - 10 * s), Vector2(cx + divHalf, cy - 10 * s),
		Color(255, 35, 28, math.floor(42 * a)), 5.0 * s)
	ui.addLine(Vector2(cx - divHalf, cy - 10 * s), Vector2(cx + divHalf, cy - 10 * s),
		Color(255, 65, 52, math.floor(135 * a)), 1.2 * s)

	-- Countdown caption & large Days / Hours / Minutes timer
	drawRedGlowText(Vector2(cx, cy + 16 * s), ui.anchor.center, ui.anchor.center,
		"ESTIMATED TIME TO DESTINATION", hyperSubLabelFont, a * 0.72, false)

	drawCountdownTabular(Vector2(cx, cy + 62 * s), hyperCountdownFont, a, true, remGameSec, duration)

	-- Thin glowing red progress bar below the countdown
	local frac = (duration > 0) and math.max(0.0, math.min(1.0, progress / duration)) or 0.0
	local barW = 360 * s
	local barH = 3.0 * s
	local barTL = Vector2(cx - barW * 0.5, cy + 114 * s)
	local barBR = Vector2(cx + barW * 0.5, barTL.y + barH)
	ui.addRectFilled(barTL, barBR, Color(85, 10, 10, math.floor(140 * a)), 1.5 * s, ui.RoundCornersAll)
	if frac > 0.002 then
		local fillBR = Vector2(barTL.x + barW * frac, barBR.y)
		ui.addRectFilled(barTL - Vector2(2 * s, 2 * s), fillBR + Vector2(2 * s, 2 * s),
			Color(255, 28, 20, math.floor(45 * a)), 3.0 * s, ui.RoundCornersAll)
		ui.addRectFilled(barTL, fillBR, Color(255, 68, 55, math.floor(220 * a)), 1.5 * s, ui.RoundCornersAll)
	end
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
            displayHyperspace(dT)
        else
            hyperspaceRealTimer = 0.0
            displayHyperspaceTargetIndicator(player)
            if player:IsHyperspaceActive() then
                displayHyperspaceCountdown()
            end
        end
    end
})
